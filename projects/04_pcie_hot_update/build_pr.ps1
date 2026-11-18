# Build the partial-reconfiguration flow of 04_pcie_hot_update.
#
#   . ..\..\scripts\env.ps1
#   .\build_pr.ps1                 # base + export + implementation
#   .\build_pr.ps1 -Stage impl     # only the implementation revision
#
# Stages:
#   base    compile revision pcie_hot_update (PR_BASE, persona_add)
#   export  export the static region to output_files\pcie_hot_update_static.qdb
#   impl    compile revision pcie_hot_update_sub (PR_IMPL, persona_sub)
#
# Outputs (output_files\, git-ignored):
#   pcie_hot_update.sof                   full base image, load over JTAG
#   pcie_hot_update.pr_partition.rbf      PR bitstream, persona 1 (A + B)
#   pcie_hot_update_sub.pr_partition.rbf  PR bitstream, persona 2 (A - B)
#
# Every persona .rbf is valid only with the .sof of the same base build.
# Rebuilding the base invalidates all previously built .rbf files.

[CmdletBinding()]
param(
    [ValidateSet('all', 'base', 'export', 'impl')]
    [string]$Stage = 'all'
)

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
. (Join-Path $here '..\..\scripts\env.ps1') | Out-Null

$project = 'pcie_hot_update'
$base    = 'pcie_hot_update'
$impl    = 'pcie_hot_update_sub'
$out     = Join-Path $here 'output_files'
$qdb     = 'output_files/pcie_hot_update_static.qdb'

function Invoke-Step([string]$name, [scriptblock]$cmd) {
    Write-Host "== $name ($(Get-Date -Format 'HH:mm:ss'))" -ForegroundColor Cyan
    $sw = [Diagnostics.Stopwatch]::StartNew()
    & $cmd
    if ($LASTEXITCODE -ne 0) { throw "$name failed with exit code $LASTEXITCODE after $($sw.Elapsed)" }
    Write-Host "== $name done in $($sw.Elapsed.ToString('hh\:mm\:ss'))" -ForegroundColor Green
}

Push-Location $here
try {
    if ($Stage -in 'all', 'base') {
        Invoke-Step 'compile base revision' { quartus_sh --flow compile $project -c $base }
    }
    if ($Stage -in 'all', 'export') {
        Invoke-Step 'export static region' {
            quartus_cdb $project -c $base --export_partition root_partition --snapshot final `
                --file $qdb --include_sdc_entity_in_partition --exclude_pr_subblocks
        }
    }
    if ($Stage -in 'all', 'impl') {
        Invoke-Step 'compile implementation revision' { quartus_sh --flow compile $project -c $impl }
    }

    Write-Host ''
    Write-Host 'Artifacts:' -ForegroundColor Cyan
    foreach ($f in @("$base.sof", "$base.pr_partition.rbf", "$impl.pr_partition.rbf", "$impl.sof")) {
        $p = Join-Path $out $f
        if (Test-Path $p) {
            $item = Get-Item $p
            '{0,-38} {1,12:N0} bytes  SHA-256 {2}' -f $f, $item.Length, (Get-FileHash $p -Algorithm SHA256).Hash
        }
    }
    foreach ($rev in $base, $impl) {
        $sta = Join-Path $out "$rev.sta.rpt"
        if (Test-Path $sta) {
            $m = Select-String -Path $sta -Pattern 'Timing requirements (met|not met)' | Select-Object -First 1
            if ($m) { "{0,-22} {1}" -f $rev, $m.Line.Trim(' ;') }
        }
    }
}
finally {
    Pop-Location
}
