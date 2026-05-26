## sojourn/agent.nim — Variante do duality com fallback de CPU temp
## via LibreHardwareMonitor (HTTP localhost).
##
## Ordem de preferência para temperatura da CPU:
##   1. LHM em http://127.0.0.1:8085/data.json  (cobre Ryzen/Intel sem
##      depender de WMI; lê MSRs via driver gerenciado pelo serviço LHM)
##   2. cadeia WMI já existente em collectors.getCpuTemperature
##      (ACPI/Lenovo/Dell/HP)
## Em máquinas com HVCI ligado o driver do LHM não carrega; nesse caso
## retorna 0 e o caminho WMI é usado. Se nenhum funcionar, 0.0.
##
## Build:  nim c -d:release --opt:speed agent.nim
## Needs:  ./config.nim, ../code/collectors.nim,
##         collectors_lld.nim, lhm_client.nim

import os, osproc, times, strutils, sequtils
import ./config
import ./collectors as base
import collectors_lld
import lhm_client
import cdi_client
import updater

const AGENT_VERSION* = "1.0.0"

# -------------------------------------------------------------------
# CPU temp com fallback LHM → WMI
# -------------------------------------------------------------------
proc getCpuTempBest(): float =
  let lhm = getCpuTemperatureLhm()
  if lhm > 0.0: return lhm
  return base.getCpuTemperature()

# -------------------------------------------------------------------
# Envio (idêntico ao duality)
# -------------------------------------------------------------------
proc senderPath(): string =
  when defined(windows): result = getAppDir() / "zabbix_sender.exe"
  elif defined(linux):   result = "/usr/bin/zabbix_sender"
  else:                  result = "zabbix_sender"

proc sendMetric(server, hostname, key, value: string): bool =
  let cmd = "\"" & senderPath() & "\" -z " & server & " -p 10051 -s " &
            hostname & " -k " & key & " -o \"" & value & "\""
  return execCmdEx(cmd).exitCode == 0

proc sendBatch(server, hostname: string, kv: seq[(string, string)]): bool =
  if kv.len == 0: return true
  let tmp = getTempDir() / ("rmm_send_" & $epochTime() & ".txt")
  var lines: seq[string] = @[]
  for (k, v) in kv:
    let escaped = v.replace("\\", "\\\\").replace("\"", "\\\"")
    lines.add(hostname & " " & k & " \"" & escaped & "\"")
  writeFile(tmp, lines.join("\n"))
  let cmd = "\"" & senderPath() & "\" -z " & server & " -p 10051 -i \"" & tmp & "\""
  let res = execCmdEx(cmd)
  try: removeFile(tmp)
  except: discard
  return res.exitCode == 0

# -------------------------------------------------------------------
# Specs
# -------------------------------------------------------------------
proc sendSpecs(server, hostname: string) =
  var kv: seq[(string, string)] = @[]
  kv.add(("spec.cpu_model",      base.getCpuModel()))
  kv.add(("spec.cpu_cores",      $base.getCpuCores()))
  kv.add(("spec.ram_gb",         formatFloat(base.getTotalRamGB(), ffDecimal, 1)))
  kv.add(("spec.disk_model",     base.getDiskModel()))
  kv.add(("spec.disk_size_gb",   formatFloat(base.getDiskSizeGB(), ffDecimal, 1)))
  kv.add(("spec.os_version",     base.getOsVersion()))
  kv.add(("spec.machine_model",  base.getMachineModel()))
  kv.add(("spec.gpu_name",       base.getGpuName()))
  kv.add(("spec.disk_interface", base.getDiskInterface()))
  kv.add(("spec.ram_type",       base.getRamType()))
  kv.add(("spec.motherboard",    base.getMotherboardModel()))
  kv.add(("rmm.os.caption",      base.getOsVersion()))
  kv.add(("rmm.os.arch",         base.getOsArchitecture()))
  kv.add(("rmm.hw.model",        base.getMachineModel()))
  kv.add(("rmm.hw.serial",       base.getMachineSerial()))
  kv.add(("rmm.gpu.name",        base.getGpuName()))
  discard sendBatch(server, hostname, kv)

proc sendScalars(server, hostname: string): bool =
  let cpu  = base.getCpuUsage()
  let mem  = base.getMemoryUsage()
  let disk = base.getDiskUsage("/")
  let cpuT = getCpuTempBest()             # LHM-aware
  let gpuT = base.getGpuTemperature()
  let gpuU = base.getGpuUtilization()
  let gpuM = base.getGpuMemoryUsed()
  let upt  = base.getUptimeHours()

  var kv: seq[(string, string)] = @[
    ("cpu.usage",          formatFloat(cpu,  ffDecimal, 2)),
    ("memory.usage",       formatFloat(mem,  ffDecimal, 2)),
    ("disk.usage",         formatFloat(disk, ffDecimal, 2)),
    ("cpu.temperature",    formatFloat(cpuT, ffDecimal, 2)),
    ("gpu.temperature",    formatFloat(gpuT, ffDecimal, 2)),
    ("rmm.gpu.temp",       formatFloat(gpuT, ffDecimal, 2)),
    ("rmm.gpu.util",       formatFloat(gpuU, ffDecimal, 2)),
    ("rmm.gpu.mem_used",   $gpuM),
    ("sys.uptime_hours",   $upt),
    ("rmm.os.uptime",      $upt),
  ]
  return sendBatch(server, hostname, kv)

proc sendStorageLld(server, hostname: string): bool =
  let letters = getFixedDriveLetters()
  var kv: seq[(string, string)] = @[]
  kv.add(("rmm.storage.discovery", getStorageDiscoveryJson()))
  for letter in letters:
    let total = base.getStorageTotalBytesFor(letter)
    if total <= 0: continue
    let free  = base.getStorageFreeBytesFor(letter)
    let totalGB = float(total) / (1024.0 * 1024.0 * 1024.0)
    let freeGB  = float(free)  / (1024.0 * 1024.0 * 1024.0)
    let usedPct = 100.0 * float(total - free) / float(total)
    let suf = "[" & letter & ":]"
    kv.add(("rmm.storage.total"        & suf, $total))
    kv.add(("rmm.storage.free"         & suf, $free))
    kv.add(("rmm.storage.total_gb"     & suf, formatFloat(totalGB, ffDecimal, 2)))
    kv.add(("rmm.storage.free_gb"      & suf, formatFloat(freeGB,  ffDecimal, 2)))
    kv.add(("rmm.storage.used_pct"     & suf, formatFloat(usedPct, ffDecimal, 2)))
  return sendBatch(server, hostname, kv)

proc sendDiskLld(server, hostname: string): bool =
  let disks = getAllPhysicalDisks()
  var kv: seq[(string, string)] = @[]
  kv.add(("rmm.disk.discovery", getDiskDiscoveryJson()))

  # Backward-compat: agentes antigos enviavam essas chaves (sem [N])
  # com os valores do disco de boot. Mantemos para que triggers
  # legados e itens estáticos do template continuem recebendo dados.
  if disks.len > 0:
    let b = disks[0]
    let bWear   = getDiskWearPctFor(b.smartDev)
    var bHealth = getDiskHealthPctFor(b.smartDev)
    var bReads  = getDiskReadsGBFor(b.smartDev)
    var bWrites = getDiskWritesGBFor(b.smartDev)
    # Fallback CDI: aplicar a TODOS os campos que smartctl/PS não conseguiram
    # ler (drives atrás de Intel VMD/RST). Uma única chamada — o cache do
    # cdi_client garante 1 spawn por hora no máximo.
    if bHealth == 100 and bWear == 0 or bReads == 0.0 or bWrites == 0.0:
      let cdi = getCdiDriveForIndex(b.deviceNum)
      if bHealth == 100 and bWear == 0 and cdi.health >= 0: bHealth = cdi.health
      if bReads  == 0.0 and cdi.readsGB  >= 0.0: bReads  = cdi.readsGB
      if bWrites == 0.0 and cdi.writesGB >= 0.0: bWrites = cdi.writesGB
    let bTemp   = getDiskTemperatureFor(b.smartDev)
    let bSmart  = getSmartStatusFor(b.smartDev)
    let bPoh    = getPowerOnHoursFor(b.smartDev)
    let bHealthTxt =
      case bSmart
      of 0: "Healthy"
      of 1: "Failed"
      else: "Unknown"
    kv.add(("hdd.poweron_hours",  $bPoh))
    kv.add(("hdd.smart_status",   $bSmart))
    kv.add(("rmm.disk.health",    bHealthTxt))
    kv.add(("rmm.disk.health_pct", $bHealth))
    kv.add(("rmm.disk.temp",      formatFloat(bTemp, ffDecimal, 2)))
    kv.add(("rmm.disk.reads_gb",  formatFloat(bReads,  ffDecimal, 2)))
    kv.add(("rmm.disk.writes_gb", formatFloat(bWrites, ffDecimal, 2)))
    kv.add(("rmm.disk.reads",     $int64(bReads  * 1_073_741_824.0)))  # bytes
    kv.add(("rmm.disk.writes",    $int64(bWrites * 1_073_741_824.0)))
    kv.add(("rmm.disk.wear_pct",  $bWear))

  for d in disks:
    let id = $d.deviceNum
    let wear   = getDiskWearPctFor(d.smartDev)
    var health = getDiskHealthPctFor(d.smartDev)
    var reads  = getDiskReadsGBFor(d.smartDev)
    var writes = getDiskWritesGBFor(d.smartDev)
    # Fallback CDI: cobre health + reads + writes em um único spawn (cache 30min)
    if (health == 100 and wear == 0) or reads == 0.0 or writes == 0.0:
      let cdi = getCdiDriveForIndex(d.deviceNum)
      if health == 100 and wear == 0 and cdi.health >= 0: health = cdi.health
      if reads  == 0.0 and cdi.readsGB  >= 0.0: reads  = cdi.readsGB
      if writes == 0.0 and cdi.writesGB >= 0.0: writes = cdi.writesGB
    let temp   = getDiskTemperatureFor(d.smartDev)
    let smart  = getSmartStatusFor(d.smartDev)
    let poh    = getPowerOnHoursFor(d.smartDev)
    let suf = "[" & id & "]"
    kv.add(("rmm.disk.name"            & suf, d.friendly))
    kv.add(("rmm.disk.serial"          & suf, d.serial))
    kv.add(("rmm.disk.wear_pct"        & suf, $wear))
    kv.add(("rmm.disk.health_pct"      & suf, $health))
    kv.add(("rmm.disk.reads_gb"        & suf, formatFloat(reads,  ffDecimal, 2)))
    kv.add(("rmm.disk.writes_gb"       & suf, formatFloat(writes, ffDecimal, 2)))
    kv.add(("rmm.disk.reads"           & suf, $int64(reads  * 1_073_741_824.0)))
    kv.add(("rmm.disk.writes"          & suf, $int64(writes * 1_073_741_824.0)))
    kv.add(("rmm.disk.temp"            & suf, formatFloat(temp,   ffDecimal, 2)))
    kv.add(("rmm.disk.smart_status"    & suf, $smart))
    kv.add(("rmm.disk.poweron_hours"   & suf, $poh))
  return sendBatch(server, hostname, kv)

proc interactiveSetup(cfgFile: string): Config =
  echo "Nenhum arquivo de configuração encontrado. Configurando agente."
  var cfg: Config
  cfg.zabbixServer = "techhousebc.ddns.net"
  cfg.zabbixPort   = 10051
  cfg.hostname     = getSystemHostname()
  cfg.interval     = 60
  writeConfigFile(cfgFile, cfg)
  return cfg

proc main() =
  let cfgFile = getAppDir() / "agent.conf"
  var cfg: Config
  if fileExists(cfgFile): cfg = loadConfigFromFile(cfgFile)
  else:                   cfg = interactiveSetup(cfgFile)

  echo "Agente zbxagent v", AGENT_VERSION, ". Host: ", cfg.hostname,
       "  Zabbix: ", cfg.zabbixServer
  let lhmProbe = getCpuTemperatureLhm()
  if lhmProbe > 0.0:
    echo "LHM detectado em localhost:8085 (CPU=", lhmProbe, "°C)"
  else:
    echo "LHM indisponível — usando WMI para CPU temp."

  # Check de update na inicialização — pega versões novas antes do primeiro
  # ciclo de métricas. Se update existe, sai aqui e NSSM reinicia.
  if checkAndApplyUpdate(AGENT_VERSION): return

  sendSpecs(cfg.zabbixServer, cfg.hostname)
  discard sendDiskLld(cfg.zabbixServer, cfg.hostname)

  var specTimer = 0
  var diskTimer = 0
  var earlyCycles = 5

  while true:
    let startTime = epochTime()
    let okA = sendScalars(cfg.zabbixServer, cfg.hostname)
    let okB = sendStorageLld(cfg.zabbixServer, cfg.hostname)
    if okA and okB:
      echo "[", now().format("HH:mm:ss"), "] Métricas enviadas."
    else:
      echo "[", now().format("HH:mm:ss"), "] Erro parcial no envio."

    specTimer += cfg.interval
    diskTimer += cfg.interval
    if earlyCycles > 0:
      sendSpecs(cfg.zabbixServer, cfg.hostname)
      discard sendDiskLld(cfg.zabbixServer, cfg.hostname)
      earlyCycles -= 1
      specTimer = 0; diskTimer = 0
    else:
      if specTimer >= 3600:
        sendSpecs(cfg.zabbixServer, cfg.hostname); specTimer = 0
        # Update check piggybacks no spec resend (hourly) — sem custo extra
        # de scheduler. Update detectado: sair p/ NSSM reiniciar.
        if checkAndApplyUpdate(AGENT_VERSION): return
      if diskTimer >= 3600:
        discard sendDiskLld(cfg.zabbixServer, cfg.hostname); diskTimer = 0

    let elapsed = epochTime() - startTime
    let sleepMs = (cfg.interval * 1000) - int(elapsed * 1000)
    if sleepMs > 0: sleep(sleepMs)
    else:           sleep(1000)

when isMainModule:
  main()
