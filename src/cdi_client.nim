## sojourn/cdi_client.nim — Cliente local para CrystalDiskInfo (CDI).
##
## Última fronteira de detecção de saúde: para drives atrás de Intel VMD/RST
## (alguns NVMe OEM com Wear=0 no Storage Reliability Counter), nem smartctl
## nem PowerShell expõem o dado real. CDI lê via APIs proprietárias da Intel
## RST e mostra o "Life %" correto. Aqui chamamos o próprio CDI via CLI
## (/CopyExit) e parseamos o relatório-texto que ele gera.
##
## Resultados são cacheados por CDI_CACHE_TTL segundos para não pagar o custo
## de spawn (~3s) a cada cycle. O agente já faz disk-LLD a cada 1h, então
## em prática este código roda no máximo 1x/hora.
##
## CDI escreve em UTF-16 LE com BOM; decodificamos manualmente.

import os, osproc, strutils, tables, times

const CDI_CACHE_TTL = 1800.0  # 30 min
const CDI_DEFAULT_DIR = "CDI"
const CDI_EXE = "DiskInfo64.exe"
const CDI_OUTPUT = "DiskInfo.txt"

type CdiDrive* = object
  health*: int       # 0..100, -1 se ausente
  readsGB*: float    # -1.0 se ausente
  writesGB*: float

var cdiCache: TableRef[int, CdiDrive]   # 1-based CDI disk index → métricas
var cdiCacheTime: float = 0.0

# ---------------------------------------------------------------- decode
proc decodeCdiText*(raw: string): string =
  ## CDI 9.x grava em UTF-8 puro. Versões antigas (≤8.x) usavam UTF-16 LE
  ## com BOM. Detectamos automaticamente — se BOM presente, decodificamos
  ## par a par; caso contrário, usamos o conteúdo direto (já é UTF-8).
  if raw.len >= 2 and raw[0] == '\xFF' and raw[1] == '\xFE':
    result = ""
    var i = 2
    while i + 1 < raw.len:
      let code = ord(raw[i]) or (ord(raw[i+1]) shl 8)
      if code < 0x80:
        result.add(chr(code))
      elif code < 0x800:
        result.add(chr(0xC0 or (code shr 6)))
        result.add(chr(0x80 or (code and 0x3F)))
      else:
        result.add(chr(0xE0 or (code shr 12)))
        result.add(chr(0x80 or ((code shr 6) and 0x3F)))
        result.add(chr(0x80 or (code and 0x3F)))
      i += 2
  elif raw.len >= 3 and raw[0] == '\xEF' and raw[1] == '\xBB' and raw[2] == '\xBF':
    # UTF-8 com BOM — strip
    result = raw[3..^1]
  else:
    result = raw

# ---------------------------------------------------------------- run CDI
proc cdiExePath(): string =
  result = getAppDir() / CDI_DEFAULT_DIR / CDI_EXE
  if not fileExists(result):
    result = ""

proc runCdi(): string =
  let exe = cdiExePath()
  if exe.len == 0: return ""
  let cdiDir = exe.parentDir
  let dumpPath = cdiDir / CDI_OUTPUT
  try:
    if fileExists(dumpPath): removeFile(dumpPath)
  except: discard
  # Usa startProcess com workingDir explícito — cmd /c não preserva CWD
  # de forma confiável com paths contendo espaços ou unicode.
  try:
    let p = startProcess(exe, workingDir = cdiDir,
                         args = ["/CopyExit"],
                         options = {poStdErrToStdOut})
    discard p.waitForExit(timeout = 30_000)  # 30s safety
    p.close()
  except CatchableError:
    return ""
  if not fileExists(dumpPath): return ""
  let raw = readFile(dumpPath)
  return decodeCdiText(raw)

# ---------------------------------------------------------------- parse
proc normalizeSerial(s: string): string =
  ## Mantém só letras+dígitos em minúsculo para matching tolerante a
  ## variações ( "707C_1837_02A8" vs "707C183702A8" vs "707c183702a8").
  result = ""
  for c in s:
    if c in {'0'..'9'}: result.add(c)
    elif c in {'a'..'z'}: result.add(c)
    elif c in {'A'..'Z'}: result.add(chr(ord(c) - ord('A') + ord('a')))

proc extractPercent(line: string): int =
  ## Procura "(NN %)" na linha. Retorna -1 se não encontrar.
  let openPos = line.find('(')
  if openPos < 0: return -1
  let closePos = line.find(')', openPos)
  if closePos < 0: return -1
  let inner = line[openPos+1 ..< closePos]
  var digits = ""
  for c in inner:
    if c in {'0'..'9'}: digits.add(c)
    elif c == '%': break
  if digits.len == 0: return -1
  try: return parseInt(digits)
  except: return -1

proc parseDiskHeader(line: string): int =
  ## Extrai N de "(NN) Drive Model ..." — retorna 1-based índice CDI, ou -1.
  let l = line.strip()
  if l.len < 4 or l[0] != '(': return -1
  var i = 1
  while i < l.len and l[i] in {'0'..'9'}: inc i
  if i <= 1 or i >= l.len or l[i] != ')': return -1
  try: return parseInt(l[1 ..< i])
  except: return -1

proc isDiskHeader(line: string): bool = parseDiskHeader(line) > 0

proc extractGB(line: string): float =
  ## Procura "NNNN GB" na linha. Retorna -1.0 se não encontrar.
  ## CDI 9.x sempre usa GB para Host Reads/Writes (mesmo em pt-BR).
  let parts = line.split(":", maxsplit=1)
  if parts.len < 2: return -1.0
  let tail = parts[1].strip()
  var digits = ""
  for c in tail:
    if c in {'0'..'9'}: digits.add(c)
    elif c == '.' or c == ',': digits.add('.')
    elif c == ' ': continue
    else: break
  if digits.len == 0: return -1.0
  try: return parseFloat(digits.replace(",", "."))
  except: return -1.0

proc parseCdiDump*(text: string): Table[int, CdiDrive] =
  ## Retorna {cdiIndex (1-based): healthPct}.
  ##
  ## NÃO usamos serial número como chave: CDI lê o NVMe Identify serial
  ## via APIs da Intel RST, enquanto o agente vê o serial sintético do
  ## driver NVMe genérico do Windows — são strings completamente diferentes
  ## para o mesmo drive em hardware atrás de VMD/RST.
  ##
  ## CDI numera discos "(01) (02) ..." na mesma ordem que Windows enumera
  ## PhysicalDrives (DeviceId). cdiIndex = deviceNum + 1.
  ##
  ## Estrutura CDI 9.x:
  ##   -----------------------       ← linha de dashes
  ##   (01) Drive Friendly Name      ← cabeçalho com índice
  ##   -----------------------
  ##   Model : ...
  ##   Health Status : Saudável (97 %)
  ##   ...
  ##   -- S.M.A.R.T. ----            ← fim do bloco de propriedades
  result = initTable[int, CdiDrive]()
  type Section = tuple[idx: int, body: string]
  var sections: seq[Section] = @[]
  var currentIdx = -1
  var currentBody = ""
  var inDrive = false
  var prevWasDashes = false
  for line in text.splitLines():
    let l = line.strip()
    let isDashes = l.len >= 20 and l.allCharsInSet({'-'})
    if isDashes:
      prevWasDashes = true
      continue
    if l.startsWith("-- ") and inDrive:
      if currentBody.len > 0: sections.add((currentIdx, currentBody))
      currentBody = ""
      inDrive = false
      prevWasDashes = false
      continue
    if prevWasDashes:
      let idx = parseDiskHeader(line)
      if idx > 0:
        # Novo bloco — mas só aceita se vier depois da seção "-- Disk List --"
        # (a Disk List também tem entradas "(NN) Drive Name" sem propriedades).
        # Distinguimos pelo fato de o cabeçalho individual ser PRECEDIDO E
        # SEGUIDO de linhas só de dashes (sandwich), enquanto a Disk List
        # tem múltiplas entradas seguidas. O parser de propriedades a seguir
        # vai naturalmente filtrar — blocos sem "Health Status" são descartados.
        if inDrive and currentBody.len > 0:
          sections.add((currentIdx, currentBody))
        currentIdx = idx
        currentBody = ""
        inDrive = true
        prevWasDashes = false
        continue
    prevWasDashes = false
    if inDrive:
      currentBody.add(line & "\n")
  if inDrive and currentBody.len > 0:
    sections.add((currentIdx, currentBody))

  for (idx, body) in sections:
    var drive = CdiDrive(health: -1, readsGB: -1.0, writesGB: -1.0)
    for line in body.splitLines():
      if ":" notin line: continue
      let parts = line.split(":", maxsplit=1)
      let key = parts[0].strip().toLower()
      if "health status" in key or "saúde" in key or "saude" in key or
         "estado de" in key:
        let p = extractPercent(line)
        if p >= 0: drive.health = p
      elif "host reads" in key or "leituras do host" in key or "leitura do host" in key:
        let v = extractGB(line)
        if v >= 0.0: drive.readsGB = v
      elif "host writes" in key or "gravações do host" in key or "gravacoes do host" in key or
           "escritas do host" in key:
        let v = extractGB(line)
        if v >= 0.0: drive.writesGB = v
    # Aceita o bloco se *alguma* métrica foi extraída (filtra a "-- Disk List")
    if drive.health >= 0 or drive.readsGB >= 0.0 or drive.writesGB >= 0.0:
      result[idx] = drive

# ---------------------------------------------------------------- public API
proc refreshCdiCache() =
  ## Atualiza o cache se estiver vencido ou vazio. Spawn de CDI custa
  ## ~3s; o cache evita rodar a cada cycle.
  let now = epochTime()
  if not cdiCache.isNil and now - cdiCacheTime <= CDI_CACHE_TTL:
    return
  let text = runCdi()
  if text.len == 0: return
  let parsed = parseCdiDump(text)
  if parsed.len == 0: return
  cdiCache = newTable[int, CdiDrive]()
  for k, v in parsed: cdiCache[k] = v
  cdiCacheTime = now

proc getCdiDriveForIndex*(deviceNum: int): CdiDrive =
  ## Retorna o registro CDI para o drive (deviceNum 0-based → CDI 1-based).
  ## Campos não disponíveis vêm com -1/-1.0.
  result = CdiDrive(health: -1, readsGB: -1.0, writesGB: -1.0)
  if deviceNum < 0: return
  refreshCdiCache()
  if cdiCache.isNil: return
  let cdiIdx = deviceNum + 1
  if cdiIdx in cdiCache: return cdiCache[cdiIdx]

proc getCdiHealthForIndex*(deviceNum: int): int =
  ## Atalho histórico: só o health %. -1 se ausente.
  return getCdiDriveForIndex(deviceNum).health
