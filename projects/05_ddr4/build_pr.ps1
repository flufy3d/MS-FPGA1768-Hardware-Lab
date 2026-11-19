# Build the partial-reconfiguration flow of 05_ddr4.
#
#   . ..\..\scripts\env.ps1
#   .\build_pr.ps1                 # base + export + implementation
#   .\build_pr.ps1 -Stage impl     # only the implementation revision
#
# Stages:
#   base    compile revision ddr4 (PR_BASE, persona_walk)
#   export  export the static region to output_files\ddr4_static.qdb
#   impl    compile revision ddr4_prbs (PR_IMPL, persona_prbs)
#
# Outputs (output_files\, git-ignored):
#   ddr4.sof                    full base image, load over JTAG
#   ddr4.pr_partition.rbf       PR bitstream, persona_walk (walking one + address test)
#   ddr4_prbs.pr_partition.rbf  PR bitstream, persona_prbs (PRBS-31)
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

$project = 'ddr4'
$base    = 'ddr4'
$impl    = 'ddr4_prbs'
$out     = Join-Path $here 'output_files'
$qdb     = 'output_files/ddr4_static.qdb'

function Invoke-Step([string]$name, [scriptblock]$cmd) {
    Write-Host "== $name ($(Get-Date -Format 'HH:mm:ss'))" -ForegroundColor Cyan
    $sw = [Diagnostics.Stopwatch]::StartNew()
    & $cmd
    if ($LASTEXITCODE -ne 0) { throw "$name failed with exit code $LASTEXITCODE after $($sw.Elapsed)" }
    Write-Host "== $name done in $($sw.Elapsed.ToString('hh\:mm\:ss'))" -ForegroundColor Green
}

# Quartus Prime Pro 25.1 on the lab host sometimes crashes at the start of the
# assembler ("DDM_T::verify_token(token) : Cannot identify the client",
# 2026-11-19); a second run succeeds. If a compile fails after timing
# analysis, run the assembler once more before giving up.
function Invoke-Compile([string]$rev) {
    quartus_sh --flow compile $project -c $rev
    if ($LASTEXITCODE -ne 0) {
        $sta = Join-Path $out "$rev.sta.rpt"
        $asm = Join-Path $out "$rev.asm.rpt"
        if ((Test-Path $sta) -and -not (Test-Path $asm)) {
            Write-Host "== assembler did not run to completion; retrying quartus_asm once" -ForegroundColor Yellow
            quartus_asm $project -c $rev
        }
    }
}

Push-Location $here
try {
    if ($Stage -in 'all', 'base') {
        Invoke-Step 'compile base revision' { Invoke-Compile $base }
    }
    if ($Stage -in 'all', 'export') {
        Invoke-Step 'export static region' {
            quartus_cdb $project -c $base --export_partition root_partition --snapshot final `
                --file $qdb --include_sdc_entity_in_partition --exclude_pr_subblocks
        }
    }
    if ($Stage -in 'all', 'impl') {
        Invoke-Step 'compile implementation revision' { Invoke-Compile $impl }
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
