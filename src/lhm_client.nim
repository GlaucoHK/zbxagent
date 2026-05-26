## sojourn/lhm_client.nim — Cliente HTTP local para LibreHardwareMonitor.
##
## LHM expõe /data.json no servidor embutido (Run > Remote Web Server).
## Estrutura é uma árvore: Computer → Hardware (CPU/GPU/…) → Categorias
## (Temperatures/Loads/…) → Sensores ({Text, Value, Min, Max}).
## "Value" vem como string formatada ("65.0 °C", "55,2 %"). Parseamos
## o número e validamos a faixa (5–130°C) para descartar leituras
## absurdas que ocorrem quando o driver não consegue ler o MSR.
##
## Sem driver kernel (LHM cuida disso no próprio serviço); falha
## silenciosa retorna 0.0 e o caller decide o fallback.

import httpclient, json, strutils

const LHM_PORT = 8085
const LHM_TIMEOUT_MS = 2000

proc looksLikeCpuTempSensor(text: string): bool =
  let t = text.toLower()
  # CPU package (Intel), Tctl/Tdie (AMD Zen), Core Max, CPU Core #N
  return (("cpu" in t and ("package" in t or "core" in t)) or
          "tctl" in t or "tdie" in t or "ccd" in t)

proc looksLikeTempReading(value: string): bool =
  return "°c" in value.toLower() or " c" in value.toLower()

proc parseCelsius(value: string): float =
  # "65.0 °C" / "55,2 °C" / "65 C" → float
  for token in value.splitWhitespace():
    let clean = token.replace(",", ".").replace("°", "").replace("C", "")
    if clean.len == 0: continue
    try:
      return parseFloat(clean)
    except:
      discard
  return 0.0

proc walkForCpuTemp(node: JsonNode, best: var float) =
  if node.kind == JObject:
    if node.hasKey("Text") and node.hasKey("Value"):
      let text = node["Text"].getStr("")
      let valS = node["Value"].getStr("")
      if looksLikeCpuTempSensor(text) and looksLikeTempReading(valS):
        let v = parseCelsius(valS)
        if v > 5.0 and v < 130.0 and v > best:
          best = v
    if node.hasKey("Children"):
      for child in node["Children"]:
        walkForCpuTemp(child, best)
  elif node.kind == JArray:
    for child in node:
      walkForCpuTemp(child, best)

proc getCpuTemperatureLhm*(port: int = LHM_PORT): float =
  ## Consulta o LHM local. Retorna 0.0 se o serviço não responder ou
  ## se nenhum sensor de CPU plausível for encontrado.
  try:
    let client = newHttpClient(timeout = LHM_TIMEOUT_MS)
    defer: client.close()
    let url = "http://127.0.0.1:" & $port & "/data.json"
    let body = client.getContent(url)
    let root = parseJson(body)
    var best = 0.0
    walkForCpuTemp(root, best)
    return best
  except CatchableError:
    return 0.0
