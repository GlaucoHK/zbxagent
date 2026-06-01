## sojourn/lhm_client.nim — Cliente local para LibreHardwareMonitor.
##
## Última fronteira de leitura de temperatura de CPU em Ryzen / Intel
## onde a cadeia WMI (ACPI/Lenovo/Dell/HP) retorna 0. O LHM expõe
## sensores em http://127.0.0.1:8085/data.json; aqui apenas fazemos
## GET e parseamos.
##
## Estratégia de escolha do sensor (1 = preferido):
##   1. "CPU Package"   — leitura principal Intel, alinhada com HWMonitor
##   2. "Tctl/Tdie"     — leitura principal AMD
##   3. "CCD #N"        — chiplets AMD individuais
##   4. "Core #N"       — core individual; só usado se nada acima existir
##
## Dentro do mesmo nível de prioridade, escolhe o MAIOR valor.
## Devolve também o nome do sensor escolhido para log/diagnóstico.

import httpclient, json, strutils

const LHM_PORT = 8085
const LHM_TIMEOUT_MS = 2000

type CpuTempResult* = object
  celsius*: float       # 0.0 se nada plausível
  sensorName*: string   # nome do sensor escolhido (vazio se nenhum)
  priority*: int        # 1..4, ou 999 se nenhum

proc sensorPriority(text: string): int =
  ## Retorna 1..4 para sensores de CPU temp em ordem de preferência,
  ## 999 para qualquer outra coisa.
  let t = text.toLower()
  # 1: Intel "CPU Package" (a leitura "oficial" do pacote)
  if "cpu package" in t: return 1
  if "package" in t and "cpu" in t: return 1
  # 2: AMD Tctl/Tdie — o que HWMonitor / Ryzen Master mostram
  if "tctl" in t or "tdie" in t: return 2
  # 3: chiplets AMD (CCD)
  if "ccd" in t: return 3
  # 4: cores individuais (último recurso — pode picar bem acima do pacote)
  if "cpu core" in t or ("core" in t and "#" in t): return 4
  return 999

proc looksLikeTempReading(value: string): bool =
  let v = value.toLower()
  "°c" in v or v.endsWith(" c") or v.endsWith(" °c")

proc parseCelsius(value: string): float =
  for token in value.splitWhitespace():
    let clean = token.replace(",", ".").replace("°", "").replace("C", "").replace("c", "")
    if clean.len == 0: continue
    try: return parseFloat(clean)
    except: discard
  return 0.0

proc walkForCpuTemp(node: JsonNode, best: var CpuTempResult) =
  if node.kind == JObject:
    if node.hasKey("Text") and node.hasKey("Value"):
      let text = node["Text"].getStr("")
      let valS = node["Value"].getStr("")
      let prio = sensorPriority(text)
      if prio < 999 and looksLikeTempReading(valS):
        let v = parseCelsius(valS)
        if v > 5.0 and v < 130.0:
          # Preferência por prioridade menor. Dentro da mesma prioridade,
          # MAX (para cobrir múltiplos CCDs ou cores).
          if prio < best.priority or (prio == best.priority and v > best.celsius):
            best.celsius = v
            best.sensorName = text
            best.priority = prio
    if node.hasKey("Children"):
      for child in node["Children"]:
        walkForCpuTemp(child, best)
  elif node.kind == JArray:
    for child in node:
      walkForCpuTemp(child, best)

proc getCpuTemperatureLhmDetailed*(port: int = LHM_PORT): CpuTempResult =
  ## Faz o GET e devolve {celsius, sensorName, priority}.
  result = CpuTempResult(celsius: 0.0, sensorName: "", priority: 999)
  try:
    let client = newHttpClient(timeout = LHM_TIMEOUT_MS)
    defer: client.close()
    let url = "http://127.0.0.1:" & $port & "/data.json"
    let body = client.getContent(url)
    let root = parseJson(body)
    walkForCpuTemp(root, result)
  except CatchableError:
    discard

proc getCpuTemperatureLhm*(port: int = LHM_PORT): float =
  ## Compat: só o valor numérico. 0.0 se nada plausível.
  return getCpuTemperatureLhmDetailed(port).celsius
