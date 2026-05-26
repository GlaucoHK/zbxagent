# fetch_lhm.ps1 — baixa o LibreHardwareMonitor mais recente do GitHub e
# extrai no diretório informado. Idempotente: se LibreHardwareMonitor.exe
# já existe em -DestDir, não faz nada.
#
# Uso (chamado pelo install_service.bat):
#   powershell -ExecutionPolicy Bypass -File fetch_lhm.ps1 -DestDir "<path>"
#
# Versão fixada para reprodutibilidade. Se a release for removida,
# atualize $LhmVersion. O hash SHA256 protege contra substituição
# silenciosa (download corrompido ou comprometido).

param(
    [Parameter(Mandatory=$true)][string]$DestDir,
    [string]$LhmVersion = "v0.9.4",
    [string]$ExpectedSha256 = ""   # opcional; deixe vazio para pular
)

$ErrorActionPreference = "Stop"

if (Test-Path (Join-Path $DestDir "LibreHardwareMonitor.exe")) {
    Write-Host "LHM já presente em $DestDir"
    exit 0
}

if (-not (Test-Path $DestDir)) {
    New-Item -ItemType Directory -Path $DestDir -Force | Out-Null
}

$assetUrl = "https://github.com/LibreHardwareMonitor/LibreHardwareMonitor/releases/download/$LhmVersion/LibreHardwareMonitor-net472.zip"
$tmpZip   = Join-Path $env:TEMP ("lhm-" + [guid]::NewGuid().ToString() + ".zip")

Write-Host "Baixando $assetUrl"
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $assetUrl -OutFile $tmpZip -UseBasicParsing
} catch {
    Write-Error "Falha no download: $_"
    exit 1
}

if ($ExpectedSha256 -ne "") {
    $actual = (Get-FileHash -Path $tmpZip -Algorithm SHA256).Hash
    if ($actual -ne $ExpectedSha256.ToUpper()) {
        Write-Error "SHA256 não confere. Esperado=$ExpectedSha256 Atual=$actual"
        Remove-Item $tmpZip -Force
        exit 1
    }
    Write-Host "SHA256 OK: $actual"
}

Write-Host "Extraindo em $DestDir"
Expand-Archive -Path $tmpZip -DestinationPath $DestDir -Force
Remove-Item $tmpZip -Force

# Algumas releases criam subpasta — promove conteúdo se necessário.
$subdirs = Get-ChildItem -Path $DestDir -Directory
if (-not (Test-Path (Join-Path $DestDir "LibreHardwareMonitor.exe"))) {
    foreach ($d in $subdirs) {
        $candidate = Join-Path $d.FullName "LibreHardwareMonitor.exe"
        if (Test-Path $candidate) {
            Get-ChildItem -Path $d.FullName | Move-Item -Destination $DestDir -Force
            Remove-Item $d.FullName -Recurse -Force
            break
        }
    }
}

if (-not (Test-Path (Join-Path $DestDir "LibreHardwareMonitor.exe"))) {
    Write-Error "Extração concluída mas LibreHardwareMonitor.exe não encontrado."
    exit 1
}

Write-Host "LHM instalado em $DestDir"
exit 0
