# Simulate the DDR test persona body behind ddr_port (tb_shell_ddr.sv) with
# Questa. The simulator is a standalone install; scripts/env.ps1 finds it via
# QUESTA_ROOTDIR or D:\questasim64_2024.1.
#
#   . ..\..\..\scripts\env.ps1
#   .\run_sim.ps1            # both personas (MODE 0 walking, MODE 1 PRBS)
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
    $src = @('..\sync_bits.sv', '..\ddr_port.sv', '..\personas\ddr_test_engine.sv',
             '..\personas\ddr_test_csr.sv', 'tb_shell_ddr.sv')
    if (Test-Path work) { Remove-Item -Recurse -Force work }
    & $vlib work | Out-Null
    & $vlog -sv -quiet @src 2>&1 | Where-Object { $_ -notmatch "0x80096010" }
    if ($LASTEXITCODE -ne 0) { throw "vlog failed" }
    $rc = 0
    foreach ($mode in 0, 1) {
        & $vsim -c -quiet "-GMODE=$mode" tb_shell_ddr -do "run -all; quit -f" 2>&1 |
            Tee-Object -FilePath "sim_mode$mode.log" | Where-Object { $_ -match '^# (ok|FAIL|====)' }
        if (-not (Select-String -Path "sim_mode$mode.log" -Pattern '==== PASSED' -Quiet)) { $rc = 1 }
    }
    exit $rc
} finally {
    Pop-Location
}
