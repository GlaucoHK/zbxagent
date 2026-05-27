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
  ## Retorna corpo da resposta como UTF-8 string, ou vazio em erro.
  ## Decodifica explicitamente: -UseBasicParsing devolve .Content como
  ## byte[], que via stdout vira "uma-linha-por-byte". O GetString fixa.
  let script = "[Net.ServicePointManager]::SecurityProtocol='Tls12'; " &
               "try { [System.Text.Encoding]::UTF8.GetString( " &
               "(Invoke-WebRequest -Uri '" & psQuote(url) &
               "' -UseBasicParsing -TimeoutSec 10).Content) } " &
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

proc spawnSwapScript(): bool =
  ## Escreve _zbxagent_swap.bat ao lado do agente e o spawna detached
  ## (start /b via cmd). O script:
  ##   1. dorme ~4s (deixa o agente atual continuar / NSSM se acomodar)
  ##   2. net stop RMM-Agent  (mata o processo do agente)
  ##   3. move agent.exe.new → agent.exe
  ##   4. net start RMM-Agent
  ##   5. apaga a si mesmo
  ## NSSM não suporta pre-start hooks — esta é a forma simples e
  ## confiável de fazer um in-place swap sem corrida com AutoRestart.
  let bat = getAppDir() / "_zbxagent_swap.bat"
  let content = """@echo off
ping -n 5 127.0.0.1 >nul
net stop RMM-Agent >nul 2>&1
ping -n 2 127.0.0.1 >nul
if exist "%~dp0agent.exe.new" move /Y "%~dp0agent.exe.new" "%~dp0agent.exe" >nul 2>&1
net start RMM-Agent
del "%~f0"
"""
  try:
    writeFile(bat, content)
  except: return false
  try:
    # cmd /c start "" /b — spawn detached, sem nova janela, sem espera
    let cmd = "cmd /c start \"\" /b cmd /c \"" & bat & "\""
    discard execCmdEx(cmd)
    return true
  except: return false

proc checkAndApplyUpdate*(currentVersion: string): bool =
  ## Retorna true APENAS se um update foi staged E o swap-batch foi
  ## spawnado com sucesso. Caller pode sair (mas não precisa: o batch
  ## faz net stop que kill o agente em ~4s e troca o binário).
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
         " staged em ", newPath, ". Spawnando swap-batch…"
    if not spawnSwapScript():
      echo "[update] falha ao spawnar swap script — abortando"
      try: removeFile(newPath)
      except: discard
      return false
    echo "[update] swap-batch rodando; net stop em ~4s, restart com novo binário."
    return true
  except CatchableError as e:
    echo "[update] exceção: ", e.msg
    return false
