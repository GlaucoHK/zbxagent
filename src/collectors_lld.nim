## LLD-specific collectors for duality / sojourn.
## Depends on: ../code/collectors.nim, ./config.nim
## Adds:
##   - getFixedDriveLetters     : enumera C/D/E… (Win) ou raiz (Linux/macOS)
##   - getStorageDiscoveryJson  : payload {#DRIVE} para LLD do Zabbix
##   - getAllPhysicalDisks      : enumera discos (deviceNum, friendly, serial, smartDev)
##   - getDiskDiscoveryJson     : payload {#DISKID}, {#DISKNAME}, {#DISKSERIAL}
##   - per-disk variantes: wear/reads/writes/temp/health/poweron por device smartctl

import os, osproc, strutils, json, sequtils
import ./collectors as cc

# -------------------------------------------------------------------
# Helper: quote path
# -------------------------------------------------------------------
proc qq(path: string): string = "\"" & path & "\""

# -------------------------------------------------------------------
# Fixed drive letters (Windows) / mount points (Linux/macOS)
# -------------------------------------------------------------------
proc getFixedDriveLetters*(): seq[string] =
  result = @[]
  when defined(windows):
    try:
      let script = """
      Get-WmiObject Win32_LogicalDisk | Where-Object { $_.DriveType -eq 3 } |
        ForEach-Object { $_.DeviceID.TrimEnd(':') }
      """
      let output = execCmdEx("powershell -Command " & script).output
      for line in output.splitLines():
        let t = line.strip()
        if t.len == 1 and t[0] in {'A'..'Z'}:
          result.add(t)
    except:
      discard
  elif defined(linux):
    # Only one root mount tracked. Extend by parsing /proc/mounts if needed.
    result.add("/")
  elif defined(macosx):
    result.add("/")

# -------------------------------------------------------------------
# Storage discovery JSON for Zabbix LLD
# -------------------------------------------------------------------
proc getStorageDiscoveryJson*(): string =
  var data = newJArray()
  for letter in getFixedDriveLetters():
    data.add(%*{"{#DRIVE}": letter})
  return $(%*{"data": data})

# -------------------------------------------------------------------
# Physical disk enumeration (Windows): index, friendly name, serial.
# smartDev is the smartctl path (/dev/sdX) matching the Windows
# PhysicalDriveN. smartctl on Windows numbers /dev/sd[a-z] in
# Get-PhysicalDisk DeviceId order, so a→0, b→1, …
# -------------------------------------------------------------------
type DiskInfo* = object
  deviceNum*: int
  friendly*:  string
  serial*:    string
  smartDev*:  string  # /dev/sdX on Win, /dev/nvmeN or /dev/sdX on Linux

proc getAllPhysicalDisks*(): seq[DiskInfo] =
  result = @[]
  when defined(windows):
    try:
      let script = """
      Get-PhysicalDisk | Sort-Object DeviceId |
        ForEach-Object {
          [PSCustomObject]@{
            DeviceId     = [int]$_.DeviceId
            FriendlyName = $_.FriendlyName
            SerialNumber = ($_.SerialNumber | Out-String).Trim()
          }
        } | ConvertTo-Json -Compress
      """
      let output = execCmdEx("powershell -Command " & script).output.strip()
      if output.len == 0: return
      var arr: JsonNode
      try:
        let parsed = parseJson(output)
        arr = if parsed.kind == JArray: parsed else: %*[parsed]
      except:
        return
      for entry in arr:
        let idx = entry["DeviceId"].getInt()
        let smart =
          if idx >= 0 and idx < 26: "/dev/sd" & $char(ord('a') + idx)
          else: ""
        result.add(DiskInfo(
          deviceNum: idx,
          friendly:  entry["FriendlyName"].getStr("Unknown").strip(),
          serial:    entry["SerialNumber"].getStr("").strip(),
          smartDev:  smart
        ))
    except:
      discard
  elif defined(linux):
    # Parse smartctl --scan
    try:
      let scanOut = execCmdEx("smartctl --scan").output
      var i = 0
      for line in scanOut.splitLines():
        let t = line.strip()
        if t.startsWith("/dev/"):
          let parts = t.splitWhitespace()
          let dev = parts[0]
          let name = execCmdEx("lsblk -ndo MODEL " & dev).output.strip()
          let ser  = execCmdEx("lsblk -ndo SERIAL " & dev).output.strip()
          result.add(DiskInfo(deviceNum: i, friendly: name,
                              serial: ser, smartDev: dev))
          inc i
    except:
      discard

# -------------------------------------------------------------------
# Disk discovery JSON (one entry per physical disk)
# {#DISKID} is the device index (stable per host).
# -------------------------------------------------------------------
proc getDiskDiscoveryJson*(): string =
  var data = newJArray()
  for d in getAllPhysicalDisks():
    data.add(%*{
      "{#DISKID}":     $d.deviceNum,
      "{#DISKNAME}":   d.friendly,
      "{#DISKSERIAL}": d.serial,
    })
  return $(%*{"data": data})

# -------------------------------------------------------------------
# smartctl -A output for any device
# -------------------------------------------------------------------
proc readSmartAttrFor(dev: string): string =
  if dev.len == 0: return ""
  when defined(windows):
    try:
      let smartctlPath = getAppDir() / "smartctl.exe"
      if not fileExists(smartctlPath): return ""
      return execCmdEx("cmd /c " & qq(smartctlPath) & " -A " & dev).output
    except: return ""
  else:
    try:
      return execCmdEx("sudo smartctl -A " & dev).output
    except: return ""

proc readSmartHealthFor(dev: string): string =
  if dev.len == 0: return ""
  when defined(windows):
    try:
      let smartctlPath = getAppDir() / "smartctl.exe"
      if not fileExists(smartctlPath): return ""
      return execCmdEx("cmd /c " & qq(smartctlPath) & " -H " & dev).output
    except: return ""
  else:
    try:
      return execCmdEx("sudo smartctl -H " & dev).output
    except: return ""

# -------------------------------------------------------------------
# Per-disk: power-on hours
# -------------------------------------------------------------------
proc getPowerOnHoursFor*(dev: string): int =
  let smartOut = readSmartAttrFor(dev)
  for line in smartOut.splitLines():
    let lower = line.toLower()
    if "power" in lower and ("on hours" in lower or "on_hours" in lower):
      let parts = line.splitWhitespace()
      for i in countdown(parts.len - 1, 0):
        let cleaned = parts[i].replace(".", "").replace(",", "")
        if cleaned.len > 0 and cleaned.allCharsInSet({'0'..'9'}):
          try: return parseInt(cleaned)
          except: discard
  return 0

# -------------------------------------------------------------------
# Per-disk: temperature (°C)
# -------------------------------------------------------------------
proc getDiskTemperatureFor*(dev: string): float =
  let smartOut = readSmartAttrFor(dev)
  for line in smartOut.splitLines():
    let lower = line.toLower()
    if lower.startsWith("temperature:") and "celsius" in lower:
      let parts = line.splitWhitespace()
      if parts.len >= 2:
        try: return parseFloat(parts[1].replace(",", "."))
        except: discard
    elif "temperature_celsius" in lower:
      let parts = line.splitWhitespace()
      if parts.len >= 1:
        try: return parseFloat(parts[^1].replace(",", "."))
        except: discard
  return 0.0

# -------------------------------------------------------------------
# Per-disk: SMART health → 0 PASSED, 1 FAILED, -1 unknown
# -------------------------------------------------------------------
proc getSmartStatusFor*(dev: string): int =
  let smartOut = readSmartHealthFor(dev)
  if smartOut.len == 0: return -1
  for line in smartOut.splitLines():
    let l = line.toLower()
    if "smart overall-health" in l or "smart health status" in l:
      if "passed" in l or l.endsWith(": ok"): return 0
      elif "failed" in l: return 1
  return -1

# -------------------------------------------------------------------
# Per-disk: reads (GB), writes (GB), wear (%)
# Same parsers as code/collectors.nim — duplicated locally so each
# can run against an arbitrary device, not just the boot disk.
# -------------------------------------------------------------------
proc parseDataUnitsBytesLocal(output: string, label: string): int64 =
  let labelLower = label.toLower()
  for line in output.splitLines():
    let lower = line.toLower()
    if labelLower in lower and ":" in line:
      let afterColon = line.split(":", maxsplit=1)[1]
      for p in afterColon.splitWhitespace():
        let cleaned = p.replace(",", "").replace(".", "")
        if cleaned.len > 0 and cleaned.allCharsInSet({'0'..'9'}):
          try: return parseBiggestInt(cleaned) * 512_000
          except: discard
      return 0
  return 0

proc parseSataIOBytesLocal(output: string, attrId: int): int64 =
  let idStr = $attrId
  for line in output.splitLines():
    let parts = line.splitWhitespace()
    if parts.len >= 10 and parts[0] == idStr:
      let attrName = parts[1].toLower()
      let rawStr = parts[^1].replace(",", "").replace(".", "")
      if not rawStr.allCharsInSet({'0'..'9'}): return 0
      var raw: int64 = 0
      try: raw = parseBiggestInt(rawStr)
      except: return 0
      if "32mib" in attrName: return raw * 32 * 1_048_576
      if "gib" in attrName:   return raw * 1_073_741_824
      if "gb" in attrName:    return raw * 1_000_000_000
      return raw * 512
  return 0

proc getDiskReadsGBFor*(dev: string): float =
  let smartOut = readSmartAttrFor(dev)
  if smartOut.len == 0: return 0.0
  var bytes = parseDataUnitsBytesLocal(smartOut, "Data Units Read")
  if bytes == 0: bytes = parseSataIOBytesLocal(smartOut, 242)
  return float(bytes) / (1024.0 * 1024.0 * 1024.0)

proc getDiskWritesGBFor*(dev: string): float =
  let smartOut = readSmartAttrFor(dev)
  if smartOut.len == 0: return 0.0
  var bytes = parseDataUnitsBytesLocal(smartOut, "Data Units Written")
  if bytes == 0: bytes = parseSataIOBytesLocal(smartOut, 241)
  return float(bytes) / (1024.0 * 1024.0 * 1024.0)

# -------------------------------------------------------------------
# Helpers: extract individual NVMe / SATA SMART fields used by both
# wear and health calculations.
# -------------------------------------------------------------------
proc parsePctField(smartOut, label: string): int =
  ## Returns -1 if field absent, else 0..100
  let labelLower = label.toLower()
  for line in smartOut.splitLines():
    let lower = line.toLower()
    if labelLower in lower and ":" in line:
      let after = line.split(":", maxsplit=1)[1].strip().replace("%", "").strip()
      if after.allCharsInSet({'0'..'9'}):
        try: return parseInt(after)
        except: discard
  return -1

proc parseCriticalWarning(smartOut: string): int =
  ## NVMe "Critical Warning: 0x00" — any nonzero byte means a failure
  ## condition (spare low, temp, reliability, RO, volatile mem, etc.)
  for line in smartOut.splitLines():
    let lower = line.toLower()
    if "critical warning" in lower and ":" in line:
      let after = line.split(":", maxsplit=1)[1].strip().toLower()
      let hex = after.replace("0x", "").strip()
      try: return parseHexInt(hex)
      except: discard
  return 0

proc parseSataAttrValue(smartOut: string, attrId: int): int =
  ## Returns the VALUE column (normalized, parts[3]) for a SATA attr, or -1.
  let idStr = $attrId
  for line in smartOut.splitLines():
    let parts = line.splitWhitespace()
    if parts.len >= 10 and parts[0] == idStr:
      if parts[3].allCharsInSet({'0'..'9'}):
        try: return parseInt(parts[3])
        except: discard
  return -1

proc parseSataAttrRawInt(smartOut: string, attrId: int): int64 =
  ## RAW column (last) for a SATA attr. Returns -1 if not present.
  let idStr = $attrId
  for line in smartOut.splitLines():
    let parts = line.splitWhitespace()
    if parts.len >= 10 and parts[0] == idStr:
      let raw = parts[^1].replace(",", "").replace(".", "")
      if raw.allCharsInSet({'0'..'9'}):
        try: return parseBiggestInt(raw)
        except: discard
  return -1

const SSD_WEAR_ATTR_IDS = [0xBB, 0xCA, 0xD1, 0xC9, 0xE6, 0xE8, 0xE9, 0xB4]

proc smartDevToDeviceNum(dev: string): int =
  if dev.startsWith("/dev/sd") and dev.len == 8:
    let c = dev[7]
    if c in {'a'..'z'}: return ord(c) - ord('a')
  return -1

proc getDiskWearPS(deviceNum: int): int =
  when defined(windows):
    if deviceNum < 0: return -1
    try:
      let script = """
      $d = Get-PhysicalDisk -DeviceNumber """ & $deviceNum & """ -ErrorAction SilentlyContinue
      if ($d) {
        $c = Get-StorageReliabilityCounter -PhysicalDisk $d -ErrorAction SilentlyContinue
        if ($c -and $c.Wear -ne $null) { $c.Wear } else { -1 }
      } else { -1 }
      """
      let output = execCmdEx("powershell -Command " & script).output.strip()
      if output.len > 0:
        let v = output.splitLines()[0].strip()
        let cleaned = v.replace("-", "")
        if cleaned.allCharsInSet({'0'..'9'}):
          try:
            let n = parseInt(v)
            if n >= 0 and n <= 100: return n
            return -1
          except: discard
    except: discard
  return -1

proc smartctlGotData(smartOut: string): bool =
  if smartOut.len == 0: return false
  let lower = smartOut.toLower()
  if "percentage used:" in lower: return true
  if "smart/health information" in lower: return true
  if "value worst thresh" in lower: return true
  if "raw_value" in lower: return true
  return false

proc getDiskWearPctFor*(dev: string): int =
  ## 0 = pristine, 100 = end of rated life. Pure endurance metric.
  let smartOut = readSmartAttrFor(dev)
  if smartctlGotData(smartOut):
    let pu = parsePctField(smartOut, "percentage used")
    if pu > 0: return pu
    for id in SSD_WEAR_ATTR_IDS:
      let v = parseSataAttrValue(smartOut, id)
      if v >= 0 and v <= 100:
        return 100 - v
  # Fallback PS para VMD/RST
  let psWear = getDiskWearPS(smartDevToDeviceNum(dev))
  if psWear >= 0: return psWear
  return 0

# -------------------------------------------------------------------
# Health % — replica direta da fórmula do CrystalDiskInfo (AtaSmart.cpp).
#
# NVMe:  health = 100 - PercentageUsed (byte 5 do log SMART NVMe).
#        Sem ajuste por AvailableSpare ou Critical Warning — CDI também
#        não faz isso para o cálculo de "Life".
# SATA SSD: health = CurrentValue (coluna VALUE normalizada 0..100) do
#        primeiro atributo de desgaste encontrado, casado por ID:
#          0xBB (Mtron),       0xCA (Micron/Crucial/Intel-DC),
#          0xD1 (Indilinx),    0xC9 (SanDisk-HP/Venus),
#          0xE6 (WDC/SanDisk), 0xE8 (Plextor/OCZ host writes),
#          0xE9 (Intel/OCZ/SKHynix), 0xB4 (vendor variants).
#        Casa por ID, não por nome — CDI faz o mesmo, e nomes variam
#        entre versões do smartctl/vendor.
# HDD ou desconhecido: 100 (CDI mostra "--", indefinido; entregamos 100
#        para não disparar triggers de saúde falsamente).
# -------------------------------------------------------------------
proc getDiskHealthPctFor*(dev: string): int =
  let smartOut = readSmartAttrFor(dev)

  # smartctl funcionou: aplica fórmula CDI
  if smartctlGotData(smartOut):
    # NVMe: byte 5 do log = Percentage Used
    let pu = parsePctField(smartOut, "percentage used")
    if pu >= 0:
      var h = 100 - pu
      if h < 0: h = 0
      if h > 100: h = 100
      return h
    # SATA SSD: atributos casados por ID, usa o menor CurrentValue
    var bestLife = -1
    for id in SSD_WEAR_ATTR_IDS:
      let v = parseSataAttrValue(smartOut, id)
      if v >= 0 and v <= 100:
        if bestLife < 0 or v < bestLife:
          bestLife = v
    if bestLife >= 0:
      return bestLife

  # Fallback PS: drives atrás de Intel VMD/RST (SMI, alguns Samsung OEM)
  # onde smartctl falha. .Wear vem do Storage Reliability Counter.
  let psWear = getDiskWearPS(smartDevToDeviceNum(dev))
  if psWear >= 0:
    return 100 - psWear

  # HDD ou drive completamente opaco — CDI exibe "--".
  return 100
