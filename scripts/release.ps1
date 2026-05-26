# release.ps1 — Builds agent.exe, generates version.txt with SHA256,
# and (optionally) uploads to a new GitHub Release.
#
# Usage:
#   .\scripts\release.ps1 -Version 1.0.1
#   .\scripts\release.ps1 -Version 1.0.1 -Upload      # requires gh CLI
#
# Pre-requisites:
#   - Nim toolchain in PATH
#   - For -Upload: GitHub CLI (`gh auth login` done once)

param(
    [Parameter(Mandatory=$true)][string]$Version,
    [switch]$Upload
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$srcDir = Join-Path $repoRoot "src"
$distDir = Join-Path $repoRoot "dist"

if (-not (Test-Path $distDir)) { New-Item -ItemType Directory -Path $distDir | Out-Null }

# Stamp the version into agent.nim before build (replace AGENT_VERSION literal)
$agentNim = Join-Path $srcDir "agent.nim"
$content = Get-Content $agentNim -Raw
$pattern = 'const AGENT_VERSION\* = "[^"]+"'
$replacement = "const AGENT_VERSION* = `"$Version`""
if ($content -notmatch $pattern) {
    Write-Error "Could not find AGENT_VERSION constant in agent.nim"
}
$content -replace $pattern, $replacement | Set-Content $agentNim -NoNewline

Write-Host "Building agent.exe v$Version..."
Push-Location $srcDir
try {
    & nim c -d:release --opt:speed --hints:off -o:"$distDir\agent.exe" agent.nim
    if ($LASTEXITCODE -ne 0) { throw "Build failed" }
} finally {
    Pop-Location
}

$agentPath = Join-Path $distDir "agent.exe"
$hash = (Get-FileHash -Path $agentPath -Algorithm SHA256).Hash.ToLower()
$versionTxt = "$Version`nsha256:$hash"
$versionPath = Join-Path $distDir "version.txt"
[System.IO.File]::WriteAllText($versionPath, $versionTxt, [System.Text.UTF8Encoding]::new($false))

Write-Host ""
Write-Host "Built:"
Write-Host "  $agentPath  ($((Get-Item $agentPath).Length) bytes)"
Write-Host "  $versionPath"
Write-Host ""
Write-Host "version.txt:"
Get-Content $versionPath
Write-Host ""

if ($Upload) {
    Write-Host "Uploading release v$Version to GitHub..."
    & gh release create "v$Version" `
        --title "v$Version" `
        --notes "Auto-released by release.ps1" `
        "$agentPath" "$versionPath"
    if ($LASTEXITCODE -ne 0) { throw "gh release create failed" }
    Write-Host "Release v$Version published."
} else {
    Write-Host "To upload: gh release create v$Version --title v$Version $agentPath $versionPath"
}
