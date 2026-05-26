import os, strutils

type Config* = object
  zabbixServer*: string
  zabbixPort*: int
  hostname*: string
  interval*: int

proc getSystemHostname*(): string =
  when defined(windows):
    result = getEnv("COMPUTERNAME")
  else:
    result = getEnv("HOSTNAME")
  if result == "":
    result = "unknown"

proc loadConfigFromFile*(filename: string): Config =
  result.zabbixServer = "127.0.0.1"
  result.zabbixPort = 10051
  result.hostname = getSystemHostname()
  result.interval = 60

  if not fileExists(filename):
    return

  for line in lines(filename):
    let parts = line.split("=", maxsplit=1)
    if parts.len != 2:
      continue
    let key = parts[0].strip()
    let val = parts[1].strip()
    case key
    of "Server":
      result.zabbixServer = val
    of "Port":
      try:
        result.zabbixPort = parseInt(val)
      except:
        discard
    of "Hostname":
      result.hostname = val
    of "Interval":
      try:
        result.interval = parseInt(val)
      except:
        discard
    else:
      discard

proc writeConfigFile*(filename: string, cfg: Config) =
  let content = "Server=" & cfg.zabbixServer & "\n" &
                "Port=" & $cfg.zabbixPort & "\n" &
                "Hostname=" & cfg.hostname & "\n" &
                "Interval=" & $cfg.interval & "\n"
  writeFile(filename, content)

proc loadConfig*(): Config =
  let cfgFile = getAppDir() / "agent.conf"
  result = loadConfigFromFile(cfgFile)

  let envServer = getEnv("ZABBIX_SERVER")
  if envServer != "":
    result.zabbixServer = envServer
  let envPort = getEnv("ZABBIX_PORT")
  if envPort != "":
    try:
      result.zabbixPort = parseInt(envPort)
    except:
      discard
  let envHost = getEnv("HOSTNAME")
  if envHost != "":
    result.hostname = envHost
  let envInterval = getEnv("INTERVAL")
  if envInterval != "":
    try:
      result.interval = parseInt(envInterval)
    except:
      discard