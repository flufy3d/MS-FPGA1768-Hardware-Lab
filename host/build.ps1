# Windows build of the fpga1768 host tool with gcc (MSYS2 UCRT64 or
# any MinGW-w64 gcc on PATH; set $env:CC to override).
#
#   .\build.ps1        ->  build\pcie_hot_update.exe
#
# The Windows backend talks to the KMDF test driver in
# projects/02_pcie_pio/driver; install that driver first.

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$cc = if ($env:CC) { $env:CC } else { 'gcc' }
if (-not (Get-Command $cc -ErrorAction SilentlyContinue)) {
    throw "$cc not found on PATH. Install MSYS2 (ucrt64 gcc) or set `$env:CC."
}

$out = Join-Path $PSScriptRoot 'build'
New-Item -ItemType Directory -Force -Path $out | Out-Null
$exe = Join-Path $out 'fpga1768.exe'

# Put the compiler's own directory first on PATH for this call. On the lab
# host, DLLs from other tools earlier on PATH (Anaconda, Quartus) made cc1.exe
# exit with code 1 and no message.
$oldPath = $env:Path
$env:Path = (Split-Path (Get-Command $cc).Source) + ';' + $env:Path

Push-Location $PSScriptRoot
try {
    & $cc -O2 -Wall -Wextra -std=c99 -static -o $exe `
        fpga1768.c ddr.c bar_windows.c sha256.c -lsetupapi
    if ($LASTEXITCODE -ne 0) { throw "$cc failed with exit code $LASTEXITCODE" }
} finally {
    Pop-Location
    $env:Path = $oldPath
}
Write-Host "Built $exe" -ForegroundColor Green
