## sojourn/updater.nim — Auto-update via GitHub Releases.
##
## Protocolo:
##   1. GET https://github.com/GlaucoHK/zbxagent/releases/latest/download/version.txt
##      Conteúdo (2 linhas):
##        <versão>
##        sha256:<hex64>
##   2. Se a versão remota > AGENT_VERSION (semver compare):
##      a) Baixa agent.exe → agent.exe.new
##      b) Verifica SHA256
##      c) Retorna true → caller sai → NSSM reinicia → pre_start.bat
##         move agent.exe.new para agent.exe → agente novo roda
##   3. Falhas silenciosas: log + retorna false. Nunca derruba o agente
##      por causa de update.
##
## HTTPS via PowerShell (TLS 1.2 nativo) para evitar dependência de
## OpenSSL DLLs no bundle do agente.

import os, osproc, strutils, times

const REPO_URL = "https://github.com/GlaucoHK/zbxagent"
const VERSION_URL = REPO_URL & "/releases/latest/download/version.txt"
const AGENT_URL   = REPO_URL & "/releases/latest/download/agent.exe"

proc psQuote(s: string): string =
  ## Escapa para uso dentro de single-quotes do PowerShell.
  s.replace("'", "''")

proc httpGet(url: string): string =
  ## Retorna corpo da resposta, ou string vazia em erro.
  let script = "[Net.ServicePointManager]::SecurityProtocol='Tls12'; " &
               "try { (Invoke-WebRequest -Uri '" & psQuote(url) &
               "' -UseBasicParsing -TimeoutSec 10).Content } " &
               "catch { '' }"
  let res = execCmdEx("powershell -NoProfile -Command \"" & script & "\"")
  if res.exitCode == 0: return res.output
  return ""

proc httpDownload(url, destPath: string): bool =
  let script = "[Net.ServicePointManager]::SecurityProtocol='Tls12'; " &
               "try { Invoke-WebRequest -Uri '" & psQuote(url) &
               "' -OutFile '" & psQuote(destPath) &
               "' -UseBasicParsing -TimeoutSec 60; 'OK' } catch { 'FAIL' }"
  let res = execCmdEx("powershell -NoProfile -Command \"" & script & "\"")
  return res.exitCode == 0 and "OK" in res.output and fileExists(destPath)

proc sha256OfFile(path: string): string =
  let script = "(Get-FileHash -Path '" & psQuote(path) &
               "' -Algorithm SHA256).Hash.ToLower()"
  let res = execCmdEx("powershell -NoProfile -Command \"" & script & "\"")
  if res.exitCode != 0: return ""
  for line in res.output.splitLines():
    let s = line.strip()
    if s.len == 64 and s.allCharsInSet(HexDigits + {'a'..'f'}):
      return s
  return ""

proc parseSemver(v: string): seq[int] =
  ## "1.2.3" → @[1, 2, 3]. Strings não numéricas viram 0.
  result = @[]
  for part in v.strip().split('.'):
    var n = 0
    var digits = ""
    for c in part:
      if c in {'0'..'9'}: digits.add(c)
      else: break
    if digits.len > 0:
      try: n = parseInt(digits)
      except: n = 0
    result.add(n)

proc versionGreater(a, b: string): bool =
  ## True se `a` > `b` em ordem semver. "1.2.0" > "1.1.9".
  let aP = parseSemver(a)
  let bP = parseSemver(b)
  for i in 0 ..< max(aP.len, bP.len):
    let av = if i < aP.len: aP[i] else: 0
    let bv = if i < bP.len: bP[i] else: 0
    if av > bv: return true
    if av < bv: return false
  return false

proc checkAndApplyUpdate*(currentVersion: string): bool =
  ## Retorna true se um update foi baixado e está pronto. Caller deve
  ## sair (return / quit) imediatamente; NSSM reinicia o serviço e o
  ## pre_start.bat troca agent.exe.new → agent.exe.
  ##
  ## Falhas (rede, hash incorreto, etc.) retornam false e logam — o
  ## agente continua rodando normalmente com a versão atual.
  try:
    let txt = httpGet(VERSION_URL)
    if txt.len == 0:
      return false  # sem internet ou release ausente — silencioso

    let lines = txt.strip().splitLines()
    if lines.len < 2:
      echo "[update] version.txt inválido (", lines.len, " linhas)"
      return false

    let remoteVersion = lines[0].strip()
    var remoteHash = lines[1].strip()
    if remoteHash.startsWith("sha256:"):
      remoteHash = remoteHash[7 .. ^1]
    remoteHash = remoteHash.toLower()

    if remoteVersion.len == 0 or remoteHash.len != 64:
      echo "[update] formato malformado: v='", remoteVersion, "' h='", remoteHash, "'"
      return false

    if not versionGreater(remoteVersion, currentVersion):
      return false  # mesmo ou mais antigo — nada a fazer

    echo "[update] versão remota ", remoteVersion, " > atual ",
         currentVersion, ", baixando…"

    let newPath = getAppDir() / "agent.exe.new"
    if fileExists(newPath):
      try: removeFile(newPath)
      except: discard

    if not httpDownload(AGENT_URL, newPath):
      echo "[update] download falhou"
      return false

    let actualHash = sha256OfFile(newPath)
    if actualHash != remoteHash:
      echo "[update] SHA256 não confere: esperado=", remoteHash,
           " recebido=", actualHash
      try: removeFile(newPath)
      except: discard
      return false

    echo "[update] ", currentVersion, " → ", remoteVersion,
         " staged em ", newPath, ". Saindo para NSSM reiniciar."
    return true
  except CatchableError as e:
    echo "[update] exceção: ", e.msg
    return false
