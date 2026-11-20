# Simulate dma_port (tb_dma.sv) with Questa against a behavioural model of the
# hard IP's DMA data movers (descriptor sinks, Avalon masters, TX slave).
# The simulator is a standalone install; scripts/env.ps1 finds it via
# QUESTA_ROOTDIR or D:\questasim64_2024.1.
#
#   . ..\..\..\scripts\env.ps1
#   .\run_sim.ps1
#
# Work files: sim\work, sim\transcript, sim\*.log (git-ignored).

[CmdletBinding()]
param()
# Native tools print a harmless 'Error is: 0x80096010.' on stderr (signature
# check message); do not turn stderr into terminating errors.
$ErrorActionPreference = 'Continue'
$here = $PSScriptRoot
. (Join-Path $here '..\..\..\scripts\env.ps1') | Out-Null

$questa = $env:QUESTA_BIN
if (-not $questa -or -not (Test-Path (Join-Path $questa 'vsim.exe'))) {
    throw "Questa not found. Set QUESTA_ROOTDIR (or install to D:\questasim64_2024.1) and dot-source scripts\env.ps1."
}
$vlib = Join-Path $questa 'vlib.exe'
$vlog = Join-Path $questa 'vlog.exe'
$vsim = Join-Path $questa 'vsim.exe'

Push-Location $here
try {
    $src = @('..\dma_pkg.sv', '..\dma_ram.sv', '..\dma_beats.sv', '..\dma_engine.sv',
             '..\dma_port.sv', 'tb_dma.sv')
    if (Test-Path work) { Remove-Item -Recurse -Force work }
    & $vlib work | Out-Null
    & $vlog -sv -quiet @src 2>&1 | Where-Object { $_ -notmatch "0x80096010" }
    if ($LASTEXITCODE -ne 0) { throw "vlog failed" }
    & $vsim -c -quiet tb_dma -do "run -all; quit -f" 2>&1 |
        Tee-Object -FilePath "sim.log" | Where-Object { $_ -match '^# (ok|FAIL|====| {5}|\*\* (Error|Warning))' }
    if (Select-String -Path "sim.log" -Pattern '==== PASSED' -Quiet) { exit 0 } else { exit 1 }
} finally {
    Pop-Location
}
