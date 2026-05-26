import os, osproc, strutils, times, json

when defined(windows):
  import winim

when defined(macosx):
  import posix

# -------------------------------------------------------------------
# Helper: quote a path for use in cmd /c calls (handles spaces)
# -------------------------------------------------------------------
proc q(path: string): string =
  "\"" & path & "\""

# -------------------------------------------------------------------
# Helper: get ALL disk devices (Windows) from smartctl --scan
# -------------------------------------------------------------------
proc getAllDisksWindows(): seq[string] =
  result = @[]
  try:
    let smartctlPath = getAppDir() / "smartctl.exe"
    let scanOut = execCmdEx("cmd /c " & q(smartctlPath) & " --scan").output
    for line in scanOut.splitLines():
      let trimmed = line.strip()
      if trimmed.startsWith("/dev/"):
        let parts = trimmed.splitWhitespace()
        if parts.len >= 1:
          result.add(parts[0])
  except:
    discard

# -------------------------------------------------------------------
# Helper: which Windows physical disk number holds the C: partition?
# smartctl on Windows maps /dev/sd[a-z] to \\.\PhysicalDriveN — same
# numbering as Get-Partition's DiskNumber. Returns -1 if unknown.
# -------------------------------------------------------------------
proc getCBootDiskNumber(): int =
  when defined(windows):
    try:
      let script = """
      $p = Get-Partition -DriveLetter C -ErrorAction SilentlyContinue
      if ($p) { $p.DiskNumber } else { -1 }
      """
      let output = execCmdEx("powershell -Command " & script).output.strip()
      for line in output.splitLines():
        let t = line.strip()
        if t.len > 0:
          try:
            return parseInt(t)
          except:
            discard
    except:
      discard
  return -1

# -------------------------------------------------------------------
# Helper: get boot disk device (Windows) — disk that holds C:, not
# the first one in --scan order. Falls back to disk 0 if detection fails.
# -------------------------------------------------------------------
proc getBootDiskWindows(): string =
  let dn = getCBootDiskNumber()
  if dn >= 0 and dn < 26:
    return "/dev/sd" & $char(ord('a') + dn)
  # Fallback: first disk from --scan
  let disks = getAllDisksWindows()
  if disks.len > 0:
    return disks[0]
  return ""

# -------------------------------------------------------------------
# Helper: get boot disk device (Linux)
# -------------------------------------------------------------------
proc getBootDiskLinux(): string =
  try:
    let source = execCmdEx("findmnt -n -o SOURCE /").output.strip()
    var device = source
    if device.startsWith("/dev/"):
      if device.contains("nvme"):
        let ppos = device.rfind('p')
        if ppos > 0:
          device = device[0..<ppos]
      else:
        var i = device.len - 1
        while i >= 0 and device[i] in {'0'..'9'}:
          dec i
        device = device[0..i]
    return device
  except:
    return "/dev/sda"

# -------------------------------------------------------------------
# Helper: get boot disk device (macOS)
# -------------------------------------------------------------------
proc getBootDiskMacOS(): string =
  try:
    let output = execCmdEx("diskutil info / | grep 'Device Node'").output.strip()
    let parts = output.split(":")
    if parts.len >= 2:
      return parts[1].strip()
    else:
      return "disk0"
  except:
    return "disk0"

# -------------------------------------------------------------------
# Helper: parse power-on hours from smartctl -A output.
# -------------------------------------------------------------------
proc parsePowerOnHours(output: string): int =
  for line in output.splitLines():
    let lower = line.toLower()
    if "power" in lower and ("on hours" in lower or "on_hours" in lower):
      let parts = line.splitWhitespace()
      for i in countdown(parts.len - 1, 0):
        let cleaned = parts[i].replace(".", "").replace(",", "")
        if cleaned.len > 0 and cleaned.allCharsInSet({'0'..'9'}):
          return parseInt(cleaned)
  return 0

# -------------------------------------------------------------------
# Helper: parse drive temperature from smartctl -A output.
# -------------------------------------------------------------------
proc parseDriveTemp(output: string): float =
  for line in output.splitLines():
    let lower = line.toLower()
    if lower.startsWith("temperature:") and "celsius" in lower:
      let parts = line.splitWhitespace()
      if parts.len >= 2:
        try:
          return parseFloat(parts[1].replace(",", "."))
        except:
          discard
    elif "temperature_celsius" in lower:
      let parts = line.splitWhitespace()
      if parts.len >= 1:
        try:
          return parseFloat(parts[^1].replace(",", "."))
        except:
          discard
  return 0.0

# -------------------------------------------------------------------
# Helper: parse NVMe Data Units Read/Written from smartctl -A output.
# NVMe spec: 1 Data Unit = 1,000 × 512 bytes = 512,000 bytes.
# Example line: "Data Units Read:                    36,376,212 [18.6 TB]"
# -------------------------------------------------------------------
proc parseDataUnitsBytes(output: string, label: string): int64 =
  let labelLower = label.toLower()
  for line in output.splitLines():
    let lower = line.toLower()
    if labelLower in lower and ":" in line:
      let afterColon = line.split(":", maxsplit=1)[1]
      let parts = afterColon.splitWhitespace()
      for p in parts:
        let cleaned = p.replace(",", "").replace(".", "")
        if cleaned.len > 0 and cleaned.allCharsInSet({'0'..'9'}):
          try:
            return parseBiggestInt(cleaned) * 512_000
          except:
            discard
      return 0
  return 0

# -------------------------------------------------------------------
# Helper: parse SATA SMART attribute raw value (last column).
# Example: "241 Total_LBAs_Written  0x0030  100  100  ---  Old_age  Offline  -  12345678"
# -------------------------------------------------------------------
proc parseSataAttrRaw(output: string, attrName: string): int64 =
  for line in output.splitLines():
    if attrName in line:
      let parts = line.splitWhitespace()
      if parts.len >= 10:
        let raw = parts[^1].replace(",", "").replace(".", "")
        if raw.allCharsInSet({'0'..'9'}):
          try:
            return parseBiggestInt(raw)
          except:
            discard
  return 0

# -------------------------------------------------------------------
# Helper: match SATA SMART by attribute ID (241=write, 242=read), then
# infer the unit from the attribute NAME — vendor names vary wildly:
#   "Total_LBAs_Written"    → raw × 512 bytes        (Samsung, Crucial)
#   "Host_Writes_GiB"       → raw × 1 GiB            (WD)
#   "Host_Writes_32MiB"     → raw × 32 MiB           (Intel)
#   "Lifetime_Writes_GiB"   → raw × 1 GiB
# Returns bytes.
# -------------------------------------------------------------------
proc parseSataIOBytes(output: string, attrId: int): int64 =
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
      # Default: LBA count × sector size (512 bytes for nearly every SATA SSD)
      return raw * 512
  return 0

# -------------------------------------------------------------------
# Helper: parse NVMe "Percentage Used" — 0 = fresh, 100 = end of rated life.
# Example: "Percentage Used:                    5%"
# -------------------------------------------------------------------
proc parsePercentageUsed(output: string): int =
  for line in output.splitLines():
    let lower = line.toLower()
    if "percentage used" in lower and ":" in line:
      let afterColon = line.split(":", maxsplit=1)[1].strip()
      let digits = afterColon.replace("%", "").strip()
      if digits.allCharsInSet({'0'..'9'}):
        try:
          return parseInt(digits)
        except:
          discard
  return 0

# -------------------------------------------------------------------
# Helper: parse SMART health from smartctl -H output.
# Returns: 0 = PASSED, 1 = FAILED, -1 = unknown/error
# -------------------------------------------------------------------
proc parseSmartStatus(output: string): int =
  # Only check the actual SMART self-assessment line. smartctl error messages
  # (e.g. "Read NVMe Identify Controller failed" on Intel VMD machines) contain
  # the word "failed" and would otherwise produce false SMART-failure alerts.
  if output.len == 0:
    return -1
  for line in output.splitLines():
    let l = line.toLower()
    if "smart overall-health" in l or "smart health status" in l:
      if "passed" in l or l.endsWith(": ok"):
        return 0
      elif "failed" in l:
        return 1
  return -1

# -------------------------------------------------------------------
# Helper: PowerShell fallback for power-on hours (Windows)
# Uses Get-StorageReliabilityCounter when smartctl fails
# -------------------------------------------------------------------
proc getPowerOnHoursPS(): int =
  when defined(windows):
    try:
      let script = """
      $disk = Get-PhysicalDisk | Select-Object -First 1
      $counter = Get-StorageReliabilityCounter -PhysicalDisk $disk
      $counter.PowerOnHours
      """
      let output = execCmdEx("powershell -Command " & script).output.strip()
      if output.len > 0:
        let cleaned = output.replace(",", "").replace(".", "")
        if cleaned.allCharsInSet({'0'..'9'}) and cleaned.len > 0:
          return parseInt(cleaned)
      return 0
    except:
      return 0

# -------------------------------------------------------------------
# Helper: PowerShell fallback for drive temperature (Windows)
# -------------------------------------------------------------------
proc getDriveTempPS(): float =
  when defined(windows):
    try:
      let script = """
      $disk = Get-PhysicalDisk | Select-Object -First 1
      $counter = Get-StorageReliabilityCounter -PhysicalDisk $disk
      $counter.Temperature
      """
      let output = execCmdEx("powershell -Command " & script).output.strip()
      if output.len > 0:
        let cleaned = output.replace(",", ".")
        try:
          return parseFloat(cleaned)
        except:
          return 0.0
      return 0.0
    except:
      return 0.0

# -------------------------------------------------------------------
# Helper: PowerShell fallback for SMART status (Windows)
# -------------------------------------------------------------------
proc getSmartStatusPS(): int =
  when defined(windows):
    try:
      let script = """
      $disks = Get-PhysicalDisk
      $failed = $disks | Where-Object { $_.HealthStatus -ne 'Healthy' }
      if ($failed) { 1 } else { 0 }
      """
      let output = execCmdEx("powershell -Command " & script).output.strip()
      if output == "1": return 1
      elif output == "0": return 0
      else: return -1
    except:
      return -1

# -------------------------------------------------------------------
# CPU Usage (%)
# -------------------------------------------------------------------
proc getCpuUsage*(): float =
  when defined(windows):
    try:
      let script = """
      $cpu = Get-WmiObject -Class Win32_PerfFormattedData_PerfOS_Processor | Where-Object {$_.Name -eq '_Total'} | Select-Object -ExpandProperty PercentProcessorTime
      $cpu
      """
      let output = execCmdEx("powershell -Command " & script).output.strip()
      if output.len > 0:
        result = parseFloat(output.replace(",", "."))
      else:
        result = 0.0
    except:
      result = 0.0
  elif defined(linux):
    try:
      let stat1 = readFile("/proc/stat").splitLines()
      let cpu1 = stat1[0].splitWhitespace()
      var total1 = 0
      for i in 1..<cpu1.len:
        total1 += parseInt(cpu1[i])
      let idle1 = parseInt(cpu1[4])
      sleep(1000)
      let stat2 = readFile("/proc/stat").splitLines()
      let cpu2 = stat2[0].splitWhitespace()
      var total2 = 0
      for i in 1..<cpu2.len:
        total2 += parseInt(cpu2[i])
      let idle2 = parseInt(cpu2[4])
      let diffTotal = total2 - total1
      let diffIdle = idle2 - idle1
      if diffTotal > 0:
        result = 100.0 * float(diffTotal - diffIdle) / float(diffTotal)
      else:
        result = 0.0
    except:
      result = 0.0
  elif defined(macosx):
    try:
      let output = execCmdEx("top -l 1 -n 0 | grep 'CPU usage'").output
      let parts = output.splitWhitespace()
      if parts.len >= 5:
        let user = parts[2].replace("%", "").parseFloat()
        let sys  = parts[4].replace("%", "").parseFloat()
        result = user + sys
      else:
        result = 0.0
    except:
      result = 0.0

# -------------------------------------------------------------------
# Memory Usage (%)
# -------------------------------------------------------------------
proc getMemoryUsage*(): float =
  when defined(windows):
    try:
      let script = """
      $os = Get-WmiObject -Class Win32_OperatingSystem
      $total = $os.TotalVisibleMemorySize
      $free = $os.FreePhysicalMemory
      $used = $total - $free
      $used / $total * 100
      """
      let output = execCmdEx("powershell -Command " & script).output.strip()
      if output.len > 0:
        result = parseFloat(output.replace(",", "."))
      else:
        result = 0.0
    except:
      result = 0.0
  elif defined(linux):
    try:
      let meminfo = readFile("/proc/meminfo")
      var memTotal, memAvailable: float = 0.0
      for line in meminfo.splitLines():
        if line.startsWith("MemTotal:"):
          memTotal = line.splitWhitespace()[1].parseFloat()
        elif line.startsWith("MemAvailable:"):
          memAvailable = line.splitWhitespace()[1].parseFloat()
      if memTotal > 0:
        result = 100.0 * (memTotal - memAvailable) / memTotal
      else:
        result = 0.0
    except:
      result = 0.0
  elif defined(macosx):
    try:
      let output = execCmdEx("vm_stat").output
      var freePages, activePages, inactivePages, wiredPages, specPages: float = 0.0
      for line in output.splitLines():
        let lower = line.toLower()
        if "pages free" in lower:
          freePages = line.splitWhitespace()[^1].replace(".", "").parseFloat()
        elif "pages active" in lower:
          activePages = line.splitWhitespace()[^1].replace(".", "").parseFloat()
        elif "pages inactive" in lower:
          inactivePages = line.splitWhitespace()[^1].replace(".", "").parseFloat()
        elif "pages wired" in lower:
          wiredPages = line.splitWhitespace()[^1].replace(".", "").parseFloat()
        elif "pages speculative" in lower:
          specPages = line.splitWhitespace()[^1].replace(".", "").parseFloat()
      let total = freePages + activePages + inactivePages + wiredPages + specPages
      let used  = activePages + inactivePages + wiredPages
      if total > 0:
        result = 100.0 * used / total
      else:
        result = 0.0
    except:
      result = 0.0

# -------------------------------------------------------------------
# Disk Usage (%)
# -------------------------------------------------------------------
proc getDiskUsage*(path: string = "/"): float =
  when defined(windows):
    try:
      let script = """
      $disk = Get-WmiObject -Class Win32_LogicalDisk | Where-Object {$_.DeviceID -eq 'C:'} | Select-Object -First 1
      if ($disk) {
        $used = $disk.Size - $disk.FreeSpace
        $used / $disk.Size * 100
      } else { 0 }
      """
      let output = execCmdEx("powershell -Command " & script).output.strip()
      if output.len > 0:
        result = parseFloat(output.replace(",", "."))
      else:
        result = 0.0
    except:
      result = 0.0
  elif defined(linux):
    try:
      let output = execCmdEx("df -k " & path).output.splitLines()
      if output.len >= 2:
        let parts = output[1].splitWhitespace()
        if parts.len >= 5:
          let used  = parseInt(parts[2])
          let total = parseInt(parts[1])
          if total > 0:
            result = 100.0 * float(used) / float(total)
          else:
            result = 0.0
        else:
          result = 0.0
      else:
        result = 0.0
    except:
      result = 0.0
  elif defined(macosx):
    try:
      let output = execCmdEx("df -k " & path).output.splitLines()
      if output.len >= 2:
        let parts = output[1].splitWhitespace()
        if parts.len >= 9:
          let used  = parseInt(parts[2])
          let total = parseInt(parts[1])
          if total > 0:
            result = 100.0 * float(used) / float(total)
          else:
            result = 0.0
        else:
          result = 0.0
      else:
        result = 0.0
    except:
      result = 0.0

# -------------------------------------------------------------------
# CPU Temperature (°C)
# Windows: WMI first, then smartctl, then PS StorageReliabilityCounter
# -------------------------------------------------------------------
proc getCpuTemperature*(): float =
  when defined(windows):
    # Multi-vendor WMI chain — all OS-mediated, no kernel driver loading.
    # Order: standard ACPI → Lenovo → Dell DCM → HP CMI. Picks the hottest
    # plausible reading (5-130°C range). Returns 0.0 if no source exposes the
    # sensor — see contract Item 5 ("depende da permissão de leitura dos
    # drivers do hardware de destino"). DO NOT fall back to drive temp.
    try:
      let script = """
      $temps = @()
      # 1. Standard ACPI thermal zone (covered by Microsoft's WMI provider)
      try {
        Get-WmiObject MSAcpi_ThermalZoneTemperature -Namespace 'root/wmi' -ErrorAction Stop |
          ForEach-Object {
            $c = ($_.CurrentTemperature / 10) - 273.15
            if ($c -gt 5 -and $c -lt 130) { $temps += $c }
          }
      } catch {}
      # 2. Lenovo (ThinkPads with Lenovo System Interface Foundation)
      try {
        Get-WmiObject -Namespace 'root/wmi' -Class Lenovo_ThermalSensor -ErrorAction Stop |
          ForEach-Object {
            $c = ($_.CurrentTemperature / 10) - 273.15
            if ($c -gt 5 -and $c -lt 130) { $temps += $c }
          }
      } catch {}
      # 3. Dell Command | Monitor (DCIM_NumericSensor with BaseUnits=2 → degC)
      try {
        Get-WmiObject -Namespace 'root/dcim/sysman' -Class DCIM_NumericSensor -ErrorAction Stop |
          Where-Object { $_.BaseUnits -eq 2 -and $_.CurrentReading } |
          ForEach-Object {
            $c = [double]$_.CurrentReading * [math]::Pow(10, [double]$_.UnitModifier)
            if ($c -gt 5 -and $c -lt 130) { $temps += $c }
          }
      } catch {}
      # 4. HP CMI / Instrumented BIOS (rare, but cheap to try)
      try {
        Get-WmiObject -Namespace 'root/HP/InstrumentedBIOS' -Class HP_BIOSNumericSetting -ErrorAction Stop |
          Where-Object { $_.Name -match 'temp|thermal' -and $_.Value } |
          ForEach-Object {
            $c = [double]$_.Value
            if ($c -gt 5 -and $c -lt 130) { $temps += $c }
          }
      } catch {}
      if ($temps.Count -gt 0) {
        ($temps | Sort-Object -Descending | Select-Object -First 1)
      } else { 0 }
      """
      let output = execCmdEx("powershell -Command " & script).output.strip()
      for line in output.splitLines():
        let trimmed = line.strip()
        if trimmed.len > 0:
          try:
            let val = parseFloat(trimmed.replace(",", "."))
            if val > 0.0:
              return val
          except:
            discard
    except:
      discard
    return 0.0
  elif defined(linux):
    try:
      var cpuTemp = 0.0
      for zone in walkDir("/sys/class/thermal"):
        let typeFile = zone.path / "type"
        if fileExists(typeFile):
          let zoneType = readFile(typeFile).strip()
          if zoneType in ["x86_pkg_temp", "cpu-thermal", "cpu_thermal"]:
            let tempFile = zone.path / "temp"
            if fileExists(tempFile):
              cpuTemp = parseFloat(readFile(tempFile).strip()) / 1000.0
              break
      if cpuTemp == 0.0 and fileExists("/sys/class/thermal/thermal_zone0/temp"):
        cpuTemp = parseFloat(readFile("/sys/class/thermal/thermal_zone0/temp").strip()) / 1000.0
      result = cpuTemp
    except:
      result = 0.0
  elif defined(macosx):
    try:
      let output = execCmdEx("sudo powermetrics --samplers smc -n 1 2>/dev/null").output
      for line in output.splitLines():
        let lower = line.toLower()
        if ("cpu die temperature" in lower or "cpu proximity" in lower) and ":" in line:
          let parts = line.split(":")
          if parts.len >= 2:
            let valStr = parts[1].strip().split(" ")[0].replace(",", ".")
            try:
              let val = parseFloat(valStr)
              if val > 0.0:
                return val
            except:
              discard
      result = 0.0
    except:
      result = 0.0

# -------------------------------------------------------------------
# GPU Temperature (°C)
# -------------------------------------------------------------------
proc getGpuTemperature*(): float =
  when defined(windows):
    try:
      let gpuOut = execCmdEx("cmd /c nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader").output.strip()
      if gpuOut.len > 0:
        result = parseFloat(gpuOut)
      else:
        result = 0.0
    except:
      result = 0.0
  elif defined(linux):
    try:
      let gpuOut = execCmdEx("nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader").output.strip()
      if gpuOut.len > 0:
        result = parseFloat(gpuOut)
      else:
        result = 0.0
    except:
      result = 0.0
  elif defined(macosx):
    try:
      let output = execCmdEx("ioreg -l | grep -i temperature | grep -i gpu").output.strip()
      if output.len > 0:
        let parts = output.split("=")
        if parts.len >= 2:
          let value = parseFloat(parts[1].strip().replace(",", "").replace(";", ""))
          result = if value > 1000: value / 1000.0 else: value
        else:
          result = 0.0
      else:
        result = 0.0
    except:
      result = 0.0

# -------------------------------------------------------------------
# SMART: Power-on Hours (boot device only)
# Windows: smartctl first, PS fallback if 0
# -------------------------------------------------------------------
proc getPowerOnHours*(): int =
  when defined(windows):
    try:
      let smartctlPath = getAppDir() / "smartctl.exe"
      if fileExists(smartctlPath):
        let disk = getBootDiskWindows()
        if disk.len > 0:
          let output = execCmdEx("cmd /c " & q(smartctlPath) & " -A " & disk).output
          let hours = parsePowerOnHours(output)
          if hours > 0:
            return hours
    except:
      discard
    # Fallback: PowerShell StorageReliabilityCounter
    return getPowerOnHoursPS()
  elif defined(linux):
    try:
      let bootDisk = getBootDiskLinux()
      let output = execCmdEx("sudo smartctl -A " & bootDisk).output
      return parsePowerOnHours(output)
    except:
      return 0
  elif defined(macosx):
    try:
      let bootDisk = getBootDiskMacOS()
      let output = execCmdEx("sudo smartctl -A " & bootDisk).output
      return parsePowerOnHours(output)
    except:
      return 0

# -------------------------------------------------------------------
# SMART Overall Health Status (all disks)
# Windows: smartctl first, PS fallback if -1
# Returns: 0 = PASSED, 1 = FAILED, -1 = unknown/error
# -------------------------------------------------------------------
proc getSmartStatus*(): int =
  when defined(windows):
    try:
      let smartctlPath = getAppDir() / "smartctl.exe"
      if fileExists(smartctlPath):
        let disks = getAllDisksWindows()
        if disks.len > 0:
          var anyFailed = false
          var anyPassed = false
          for disk in disks:
            let output = execCmdEx("cmd /c " & q(smartctlPath) & " -H " & disk).output
            let status = parseSmartStatus(output)
            if status == 1: anyFailed = true
            elif status == 0: anyPassed = true
          if anyFailed: return 1
          elif anyPassed: return 0
    except:
      discard
    # Fallback: PowerShell Get-PhysicalDisk
    return getSmartStatusPS()
  elif defined(linux):
    try:
      let bootDisk = getBootDiskLinux()
      let output = execCmdEx("sudo smartctl -H " & bootDisk).output
      return parseSmartStatus(output)
    except:
      return -1
  elif defined(macosx):
    try:
      let bootDisk = getBootDiskMacOS()
      var output = execCmdEx("sudo smartctl -H " & bootDisk).output
      if output.strip().len == 0:
        output = execCmdEx("diskutil info " & bootDisk).output
        let lower = output.toLower()
        if "verified" in lower or "passed" in lower: return 0
        elif lower.len == 0: return -1
        else: return 1
      return parseSmartStatus(output)
    except:
      return -1

# -------------------------------------------------------------------
# Machine Specs — returns a tuple of strings
# Sent once at startup and every 24h after
# -------------------------------------------------------------------
proc getCpuModel*(): string =
  when defined(windows):
    try:
      let output = execCmdEx("powershell -Command \"(Get-WmiObject Win32_Processor).Name\"").output.strip()
      if output.len > 0: return output.splitLines()[0].strip()
      return "Unknown"
    except: return "Unknown"
  elif defined(linux):
    try:
      for line in readFile("/proc/cpuinfo").splitLines():
        if line.startsWith("model name"):
          return line.split(":")[1].strip()
      return "Unknown"
    except: return "Unknown"
  elif defined(macosx):
    try:
      return execCmdEx("sysctl -n machdep.cpu.brand_string").output.strip()
    except: return "Unknown"

proc getCpuCores*(): int =
  when defined(windows):
    try:
      let output = execCmdEx("powershell -Command \"(Get-WmiObject Win32_Processor).NumberOfLogicalProcessors\"").output.strip()
      if output.len > 0: return parseInt(output.splitLines()[0].strip())
      return 0
    except: return 0
  elif defined(linux):
    try:
      let output = execCmdEx("nproc").output.strip()
      return parseInt(output)
    except: return 0
  elif defined(macosx):
    try:
      return parseInt(execCmdEx("sysctl -n hw.logicalcpu").output.strip())
    except: return 0

proc getTotalRamGB*(): float =
  when defined(windows):
    try:
      let script = "(Get-WmiObject Win32_ComputerSystem).TotalPhysicalMemory / 1GB"
      let output = execCmdEx("powershell -Command \"" & script & "\"").output.strip()
      if output.len > 0: return parseFloat(output.replace(",", ".").splitLines()[0].strip())
      return 0.0
    except: return 0.0
  elif defined(linux):
    try:
      for line in readFile("/proc/meminfo").splitLines():
        if line.startsWith("MemTotal:"):
          let kb = parseFloat(line.splitWhitespace()[1])
          return kb / (1024.0 * 1024.0)
      return 0.0
    except: return 0.0
  elif defined(macosx):
    try:
      let bytes = parseFloat(execCmdEx("sysctl -n hw.memsize").output.strip())
      return bytes / (1024.0 * 1024.0 * 1024.0)
    except: return 0.0

# -------------------------------------------------------------------
# RAM type (DDR3 / DDR4 / DDR5 / LPDDR4 / LPDDR5 / Unknown)
# Windows: Win32_PhysicalMemory.SMBIOSMemoryType (DMTF SMBIOS spec)
# Linux:   dmidecode (needs sudo — covered by sudoers in installer)
# macOS:   system_profiler SPMemoryDataType
# -------------------------------------------------------------------
proc getRamType*(): string =
  when defined(windows):
    try:
      let script = """
      $m = Get-WmiObject Win32_PhysicalMemory | Select-Object -First 1
      if ($m) {
        switch ([int]$m.SMBIOSMemoryType) {
          20 { 'DDR' }
          21 { 'DDR2' }
          22 { 'DDR2 FB-DIMM' }
          24 { 'DDR3' }
          26 { 'DDR4' }
          27 { 'LPDDR' }
          28 { 'LPDDR2' }
          29 { 'LPDDR3' }
          30 { 'LPDDR4' }
          34 { 'DDR5' }
          35 { 'LPDDR5' }
          default { "Unknown ($($m.SMBIOSMemoryType))" }
        }
      } else { 'Unknown' }
      """
      let output = execCmdEx("powershell -Command " & script).output.strip()
      if output.len > 0: return output.splitLines()[0].strip()
      return "Unknown"
    except: return "Unknown"
  elif defined(linux):
    try:
      let output = execCmdEx("sudo -n dmidecode -t memory 2>/dev/null").output
      for line in output.splitLines():
        let t = line.strip()
        if t.startsWith("Type:"):
          let v = t[5..^1].strip()
          if v in ["DDR", "DDR2", "DDR3", "DDR4", "DDR5", "LPDDR3", "LPDDR4", "LPDDR5"]: return v
      return "Unknown"
    except: return "Unknown"
  elif defined(macosx):
    try:
      let output = execCmdEx("system_profiler SPMemoryDataType 2>/dev/null").output
      for line in output.splitLines():
        let t = line.strip()
        if t.startsWith("Type:"):
          let v = t[5..^1].strip()
          if v.len > 0: return v
      return "Unknown"
    except: return "Unknown"

proc getDiskModel*(): string =
  when defined(windows):
    try:
      let dn = getCBootDiskNumber()
      let cmd =
        if dn >= 0:
          "(Get-PhysicalDisk -DeviceNumber " & $dn & ").FriendlyName"
        else:
          "(Get-PhysicalDisk | Select-Object -First 1).FriendlyName"
      let output = execCmdEx("powershell -Command \"" & cmd & "\"").output.strip()
      if output.len > 0: return output.splitLines()[0].strip()
      return "Unknown"
    except: return "Unknown"
  elif defined(linux):
    try:
      let bootDisk = getBootDiskLinux()
      let devName = bootDisk.replace("/dev/", "")
      let modelFile = "/sys/block/" & devName & "/device/model"
      if fileExists(modelFile):
        return readFile(modelFile).strip()
      return "Unknown"
    except: return "Unknown"
  elif defined(macosx):
    try:
      let output = execCmdEx("diskutil info / | grep 'Device / Media Name'").output.strip()
      let parts = output.split(":")
      if parts.len >= 2: return parts[1].strip()
      return "Unknown"
    except: return "Unknown"

proc getDiskSizeGB*(): float =
  when defined(windows):
    try:
      let dn = getCBootDiskNumber()
      let script =
        if dn >= 0:
          "(Get-PhysicalDisk -DeviceNumber " & $dn & ").Size / 1GB"
        else:
          "(Get-PhysicalDisk | Select-Object -First 1).Size / 1GB"
      let output = execCmdEx("powershell -Command \"" & script & "\"").output.strip()
      if output.len > 0: return parseFloat(output.replace(",", ".").splitLines()[0].strip())
      return 0.0
    except: return 0.0
  elif defined(linux):
    try:
      let output = execCmdEx("df -k /").output.splitLines()
      if output.len >= 2:
        let parts = output[1].splitWhitespace()
        if parts.len >= 2:
          return parseFloat(parts[1]) / (1024.0 * 1024.0)
      return 0.0
    except: return 0.0
  elif defined(macosx):
    try:
      let output = execCmdEx("df -k /").output.splitLines()
      if output.len >= 2:
        let parts = output[1].splitWhitespace()
        if parts.len >= 2:
          return parseFloat(parts[1]) / (1024.0 * 1024.0)
      return 0.0
    except: return 0.0

proc getOsVersion*(): string =
  when defined(windows):
    try:
      let output = execCmdEx("powershell -Command \"(Get-WmiObject Win32_OperatingSystem).Caption\"").output.strip()
      if output.len > 0: return output.splitLines()[0].strip()
      return "Unknown"
    except: return "Unknown"
  elif defined(linux):
    try:
      if fileExists("/etc/os-release"):
        for line in readFile("/etc/os-release").splitLines():
          if line.startsWith("PRETTY_NAME="):
            return line.split("=")[1].strip().strip(chars={'"'})
      return "Unknown"
    except: return "Unknown"
  elif defined(macosx):
    try:
      return execCmdEx("sw_vers -productVersion").output.strip()
    except: return "Unknown"

proc getMachineModel*(): string =
  when defined(windows):
    try:
      let script = "(Get-WmiObject Win32_ComputerSystem).Model"
      let output = execCmdEx("powershell -Command \"" & script & "\"").output.strip()
      if output.len > 0: return output.splitLines()[0].strip()
      return "Unknown"
    except: return "Unknown"
  elif defined(linux):
    try:
      if fileExists("/sys/class/dmi/id/product_name"):
        return readFile("/sys/class/dmi/id/product_name").strip()
      return "Unknown"
    except: return "Unknown"
  elif defined(macosx):
    try:
      return execCmdEx("sysctl -n hw.model").output.strip()
    except: return "Unknown"

# -------------------------------------------------------------------
# GPU Name (universal — covers NVIDIA, AMD, Intel)
# -------------------------------------------------------------------
proc getGpuName*(): string =
  when defined(windows):
    # Filter out virtual display adapters (Parsec, VMware, IDD samples, etc.)
    # that often enumerate first and mask the real GPU.
    try:
      let script = """
      $virtualPattern = 'Parsec|Virtual|VMware|Hyper-V|Basic Display|IddSample|Idd Sample|Citrix|TeamViewer|Mirror Driver|Remote Display|Spacedesk|DisplayLink|Splashtop'
      $real = Get-WmiObject Win32_VideoController | Where-Object { $_.Name -and ($_.Name -notmatch $virtualPattern) } | Select-Object -First 1
      if ($real) {
        $real.Name
      } else {
        $any = Get-WmiObject Win32_VideoController | Select-Object -First 1
        if ($any) { $any.Name } else { 'Unknown' }
      }
      """
      let output = execCmdEx("powershell -Command " & script).output.strip()
      if output.len > 0: return output.splitLines()[0].strip()
      return "Unknown"
    except: return "Unknown"
  elif defined(linux):
    try:
      let nv = execCmdEx("nvidia-smi --query-gpu=name --format=csv,noheader").output.strip()
      if nv.len > 0 and not nv.toLower().contains("error") and not nv.toLower().contains("not found"):
        return nv.splitLines()[0].strip()
      let lspci = execCmdEx("bash -c \"lspci | grep -iE 'vga|3d|display' | head -1\"").output.strip()
      if lspci.len > 0:
        let parts = lspci.split(":")
        if parts.len >= 3: return parts[2].strip()
        return lspci
      return "Unknown"
    except: return "Unknown"
  elif defined(macosx):
    try:
      let output = execCmdEx("system_profiler SPDisplaysDataType").output
      for line in output.splitLines():
        if "Chipset Model" in line:
          let parts = line.split(":")
          if parts.len >= 2: return parts[1].strip()
      return "Unknown"
    except: return "Unknown"

# -------------------------------------------------------------------
# GPU Utilization (%) — NVIDIA only; returns 0 otherwise
# -------------------------------------------------------------------
proc getGpuUtilization*(): float =
  when defined(windows):
    try:
      let output = execCmdEx("cmd /c nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits").output.strip()
      if output.len > 0:
        return parseFloat(output.splitLines()[0].strip().replace(",", "."))
    except: discard
    return 0.0
  elif defined(linux):
    try:
      let output = execCmdEx("nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits").output.strip()
      if output.len > 0:
        return parseFloat(output.splitLines()[0].strip().replace(",", "."))
    except: discard
    return 0.0
  elif defined(macosx):
    return 0.0

# -------------------------------------------------------------------
# GPU Memory Used (MB) — NVIDIA only; returns 0 otherwise
# -------------------------------------------------------------------
proc getGpuMemoryUsed*(): int =
  when defined(windows):
    try:
      let output = execCmdEx("cmd /c nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits").output.strip()
      if output.len > 0:
        return parseInt(output.splitLines()[0].strip())
    except: discard
    return 0
  elif defined(linux):
    try:
      let output = execCmdEx("nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits").output.strip()
      if output.len > 0:
        return parseInt(output.splitLines()[0].strip())
    except: discard
    return 0
  elif defined(macosx):
    return 0

# -------------------------------------------------------------------
# OS Architecture (e.g. "64-bit", "x86_64", "arm64")
# -------------------------------------------------------------------
proc getOsArchitecture*(): string =
  when defined(windows):
    # WMI's OSArchitecture is localized ("64 bits" on pt-BR, "64-bit" on en-US).
    # PROCESSOR_ARCHITECTURE is locale-stable: AMD64 / x86 / ARM64.
    try:
      let env = getEnv("PROCESSOR_ARCHITECTURE")
      if env.len > 0: return env
      return "Unknown"
    except: return "Unknown"
  elif defined(linux):
    try:
      return execCmdEx("uname -m").output.strip()
    except: return "Unknown"
  elif defined(macosx):
    try:
      return execCmdEx("uname -m").output.strip()
    except: return "Unknown"

# -------------------------------------------------------------------
# Machine Serial Number (BIOS / hardware serial)
# -------------------------------------------------------------------
proc getMotherboardModel*(): string =
  # Win32_BaseBoard exposes the actual mainboard (distinct from ComputerSystem.Model
  # on desktops). On laptops both usually return the same model code.
  when defined(windows):
    try:
      let script = """
      $b = Get-WmiObject Win32_BaseBoard
      if ($b) {
        $m = ($b.Manufacturer + ' ' + $b.Product).Trim()
        if ($m.Length -gt 0) { $m } else { 'Unknown' }
      } else { 'Unknown' }
      """
      let output = execCmdEx("powershell -Command " & script).output.strip()
      if output.len > 0: return output.splitLines()[0].strip()
      return "Unknown"
    except: return "Unknown"
  elif defined(linux):
    try:
      var mfr, prod: string = ""
      if fileExists("/sys/class/dmi/id/board_vendor"):
        mfr = readFile("/sys/class/dmi/id/board_vendor").strip()
      if fileExists("/sys/class/dmi/id/board_name"):
        prod = readFile("/sys/class/dmi/id/board_name").strip()
      let combined = (mfr & " " & prod).strip()
      if combined.len > 0: return combined
      return "Unknown"
    except: return "Unknown"
  elif defined(macosx):
    # Macs don't expose a separate mainboard model — same as machine model.
    try:
      return execCmdEx("sysctl -n hw.model").output.strip()
    except: return "Unknown"

proc getMachineSerial*(): string =
  when defined(windows):
    try:
      let output = execCmdEx("powershell -Command \"(Get-WmiObject Win32_BIOS).SerialNumber\"").output.strip()
      if output.len > 0: return output.splitLines()[0].strip()
      return "Unknown"
    except: return "Unknown"
  elif defined(linux):
    try:
      if fileExists("/sys/class/dmi/id/product_serial"):
        return readFile("/sys/class/dmi/id/product_serial").strip()
      return "Unknown"
    except: return "Unknown"
  elif defined(macosx):
    try:
      let output = execCmdEx("system_profiler SPHardwareDataType").output
      for line in output.splitLines():
        if "Serial Number" in line:
          let parts = line.split(":")
          if parts.len >= 2: return parts[1].strip()
      return "Unknown"
    except: return "Unknown"

# -------------------------------------------------------------------
# Disk Temperature (boot disk, °C) — reuses smartctl + PS fallback
# -------------------------------------------------------------------
proc getDiskTemperature*(): float =
  when defined(windows):
    try:
      let smartctlPath = getAppDir() / "smartctl.exe"
      if fileExists(smartctlPath):
        let disk = getBootDiskWindows()
        if disk.len > 0:
          let output = execCmdEx("cmd /c " & q(smartctlPath) & " -A " & disk).output
          let temp = parseDriveTemp(output)
          if temp > 0.0: return temp
    except: discard
    return getDriveTempPS()
  elif defined(linux):
    try:
      let bootDisk = getBootDiskLinux()
      let output = execCmdEx("sudo smartctl -A " & bootDisk).output
      return parseDriveTemp(output)
    except: return 0.0
  elif defined(macosx):
    try:
      let bootDisk = getBootDiskMacOS()
      let output = execCmdEx("sudo smartctl -A " & bootDisk).output
      return parseDriveTemp(output)
    except: return 0.0

# -------------------------------------------------------------------
# Disk Health (text wrapper around getSmartStatus)
# -------------------------------------------------------------------
proc getDiskHealth*(): string =
  let status = getSmartStatus()
  case status
  of 0: return "Healthy"
  of 1: return "Failed"
  else: return "Unknown"

# -------------------------------------------------------------------
# Helper: run smartctl -A on the boot disk and return raw output.
# Centralizes platform branches for reads/writes/wear collectors.
# -------------------------------------------------------------------
proc readSmartAttrOutput(): string =
  when defined(windows):
    try:
      let smartctlPath = getAppDir() / "smartctl.exe"
      if not fileExists(smartctlPath): return ""
      let disk = getBootDiskWindows()
      if disk.len == 0: return ""
      return execCmdEx("cmd /c " & q(smartctlPath) & " -A " & disk).output
    except: return ""
  elif defined(linux):
    try:
      return execCmdEx("sudo smartctl -A " & getBootDiskLinux()).output
    except: return ""
  elif defined(macosx):
    try:
      return execCmdEx("sudo smartctl -A " & getBootDiskMacOS()).output
    except: return ""

# -------------------------------------------------------------------
# Disk Reads (GB, cumulative since drive manufacture)
# NVMe: Data Units Read × 512,000 bytes. SATA: SMART attr 242 × 512 bytes.
# HDDs and VMD-blocked drives: returns 0.
# -------------------------------------------------------------------
proc getDiskReadsGB*(): float =
  let output = readSmartAttrOutput()
  if output.len == 0: return 0.0
  var bytes = parseDataUnitsBytes(output, "Data Units Read")  # NVMe
  if bytes == 0:
    bytes = parseSataIOBytes(output, 242)  # SATA SSD attr 242 (vendor-aware)
  return float(bytes) / (1024.0 * 1024.0 * 1024.0)

# -------------------------------------------------------------------
# Disk Writes (GB, cumulative since drive manufacture)
# -------------------------------------------------------------------
proc getDiskWritesGB*(): float =
  let output = readSmartAttrOutput()
  if output.len == 0: return 0.0
  var bytes = parseDataUnitsBytes(output, "Data Units Written")  # NVMe
  if bytes == 0:
    bytes = parseSataIOBytes(output, 241)  # SATA SSD attr 241 (vendor-aware)
  return float(bytes) / (1024.0 * 1024.0 * 1024.0)

# -------------------------------------------------------------------
# Disk Wear Percentage (0 = fresh, 100 = end of rated life)
# NVMe: "Percentage Used" SMART log field (clean, standard).
# SATA SSDs: best-effort via vendor attrs (Intel/Samsung use Life-Left
#   semantics so we invert: wear% = 100 - value). HDDs: returns 0.
# -------------------------------------------------------------------
proc getDiskInterface*(): string =
  # "NVMe" / "SATA" / "USB" / "Unknown" — matches what CrystalDiskInfo shows.
  when defined(windows):
    try:
      let dn = getCBootDiskNumber()
      let inner =
        if dn >= 0:
          "Get-PhysicalDisk -DeviceNumber " & $dn
        else:
          "Get-PhysicalDisk | Select-Object -First 1"
      let script = "$d = " & inner & "; if ($d) { $d.BusType.ToString() } else { 'Unknown' }"
      let output = execCmdEx("powershell -Command \"" & script & "\"").output.strip()
      if output.len > 0:
        let v = output.splitLines()[0].strip()
        if v.len > 0: return v
      return "Unknown"
    except: return "Unknown"
  elif defined(linux):
    try:
      let bootDisk = getBootDiskLinux()
      let dev = bootDisk.replace("/dev/", "")
      if dev.startsWith("nvme"): return "NVMe"
      if dev.startsWith("sd"):
        let rotFile = "/sys/block/" & dev & "/queue/rotational"
        if fileExists(rotFile):
          if readFile(rotFile).strip() == "0": return "SATA"  # SSD
          else: return "SATA"  # HDD — still SATA bus
        return "SATA"
      if dev.startsWith("mmc"): return "eMMC"
      return "Unknown"
    except: return "Unknown"
  elif defined(macosx):
    try:
      let output = execCmdEx("diskutil info / | grep -i Protocol").output.strip()
      let parts = output.split(":")
      if parts.len >= 2:
        let p = parts[1].strip()
        if "PCI" in p: return "NVMe"
        if "SATA" in p: return "SATA"
        if "USB"  in p: return "USB"
        return p
      return "Unknown"
    except: return "Unknown"

proc getDiskWearPct*(): int =
  let output = readSmartAttrOutput()
  if output.len == 0: return 0
  # NVMe path
  let nvmeUsed = parsePercentageUsed(output)
  if nvmeUsed > 0: return nvmeUsed
  # SATA SSD fallback — try common "Life Left" attributes (value 100→0)
  for attr in ["Media_Wearout_Indicator", "Wear_Leveling_Count",
               "SSD_Life_Left", "Percent_Lifetime_Remain",
               "Percent_Life_Remaining", "Lifetime_Left"]:
    for line in output.splitLines():
      if attr in line:
        let parts = line.splitWhitespace()
        # Value column is the 4th (index 3): VALUE WORST THRESH ...
        if parts.len >= 4:
          let v = parts[3]
          if v.allCharsInSet({'0'..'9'}):
            try:
              let life = parseInt(v)
              if life >= 0 and life <= 100:
                return 100 - life
            except:
              discard
  return 0

# -------------------------------------------------------------------
# Storage size (bytes) on boot/system volume
# -------------------------------------------------------------------
proc getStorageTotalBytesFor*(letter: string): int64 =
  # letter without colon, e.g. "C", "D". Returns 0 if the drive doesn't
  # exist OR is not a fixed local disk (DriveType=3). Uses Where-Object
  # with single-quoted strings only — nested double quotes in PowerShell's
  # -Filter syntax get eaten by Windows command-line parsing.
  when defined(windows):
    try:
      let script = """
      $disk = Get-WmiObject -Class Win32_LogicalDisk | Where-Object {$_.DeviceID -eq '""" & letter & """:' -and $_.DriveType -eq 3} | Select-Object -First 1
      if ($disk) { $disk.Size } else { 0 }
      """
      let output = execCmdEx("powershell -Command " & script).output.strip()
      if output.len > 0: return parseBiggestInt(output.splitLines()[0].strip())
      return 0
    except: return 0
  else:
    return 0  # Drive letters are Windows-specific

proc getStorageTotalBytes*(): int64 =
  when defined(windows):
    return getStorageTotalBytesFor("C")
  elif defined(linux):
    try:
      let output = execCmdEx("df -B1 /").output.splitLines()
      if output.len >= 2:
        let parts = output[1].splitWhitespace()
        if parts.len >= 2: return parseBiggestInt(parts[1])
      return 0
    except: return 0
  elif defined(macosx):
    try:
      let output = execCmdEx("df -k /").output.splitLines()
      if output.len >= 2:
        let parts = output[1].splitWhitespace()
        if parts.len >= 2: return parseBiggestInt(parts[1]) * 1024
      return 0
    except: return 0

proc getStorageFreeBytesFor*(letter: string): int64 =
  when defined(windows):
    try:
      let script = """
      $disk = Get-WmiObject -Class Win32_LogicalDisk | Where-Object {$_.DeviceID -eq '""" & letter & """:' -and $_.DriveType -eq 3} | Select-Object -First 1
      if ($disk) { $disk.FreeSpace } else { 0 }
      """
      let output = execCmdEx("powershell -Command " & script).output.strip()
      if output.len > 0: return parseBiggestInt(output.splitLines()[0].strip())
      return 0
    except: return 0
  else:
    return 0

proc getStorageFreeBytes*(): int64 =
  when defined(windows):
    return getStorageFreeBytesFor("C")
  elif defined(linux):
    try:
      let output = execCmdEx("df -B1 /").output.splitLines()
      if output.len >= 2:
        let parts = output[1].splitWhitespace()
        if parts.len >= 4: return parseBiggestInt(parts[3])
      return 0
    except: return 0
  elif defined(macosx):
    try:
      let output = execCmdEx("df -k /").output.splitLines()
      if output.len >= 2:
        let parts = output[1].splitWhitespace()
        if parts.len >= 4: return parseBiggestInt(parts[3]) * 1024
      return 0
    except: return 0

proc getUptimeHours*(): int =
  when defined(windows):
    try:
      let script = """
      $uptime = (Get-Date) - (gcim Win32_OperatingSystem).LastBootUpTime
      [int]$uptime.TotalHours
      """
      let output = execCmdEx("powershell -Command " & script).output.strip()
      if output.len > 0: return parseInt(output.splitLines()[0].strip())
      return 0
    except: return 0
  elif defined(linux):
    try:
      let uptime = parseFloat(readFile("/proc/uptime").splitWhitespace()[0])
      return int(uptime / 3600.0)
    except: return 0
  elif defined(macosx):
    try:
      let output = execCmdEx("sysctl -n kern.boottime").output.strip()
      # kern.boottime: { sec = XXXXXXXXXX, usec = XXXXXX } ...
      let parts = output.split("=")
      if parts.len >= 2:
        let secStr = parts[1].strip().split(",")[0].strip()
        let bootSec = parseInt(secStr)
        let nowSec = int(epochTime())
        return (nowSec - bootSec) div 3600
      return 0
    except: return 0