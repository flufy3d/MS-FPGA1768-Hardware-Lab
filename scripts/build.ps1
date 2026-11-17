# Compile a Quartus project.
#
#   .\scripts\build.ps1 -Project projects\01_hello_world\hello_world.qpf
#   .\scripts\build.ps1 -Project projects\01_hello_world\hello_world.qpf -Revision hello_world

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Project,

    [string]$Revision,

    [switch]$Clean
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'env.ps1') | Out-Null

if (-not (Test-Path $Project)) { throw "Project not found: $Project" }
$Project = (Resolve-Path $Project).Path

$projectName = [System.IO.Path]::GetFileNameWithoutExtension($Project)
if (-not $Revision) { $Revision = $projectName }

if ($Clean) {
    Write-Host "Cleaning $Revision ..." -ForegroundColor Yellow
    & quartus_sh --clean $Project -c $Revision
}

Write-Host "Compiling $Project (revision $Revision) ..." -ForegroundColor Cyan
$sw = [System.Diagnostics.Stopwatch]::StartNew()
& quartus_sh --flow compile $Project -c $Revision
$rc = $LASTEXITCODE
$sw.Stop()

if ($rc -ne 0) {
    throw "Quartus compile failed with exit code $rc (after $($sw.Elapsed))"
}

$outDir = Join-Path (Split-Path $Project) 'output_files'
$sof = Join-Path $outDir "$Revision.sof"

Write-Host ""
Write-Host "Build finished in $($sw.Elapsed.ToString('mm\:ss'))" -ForegroundColor Green
if (Test-Path $sof) {
    $size = (Get-Item $sof).Length / 1KB
    Write-Host "Bitstream   : $sof ($([math]::Round($size)) KB)"
    Write-Host "SHA256      : $((Get-FileHash $sof -Algorithm SHA256).Hash)"
    Write-Host ""
    Write-Host "Program with:" -ForegroundColor Cyan
    Write-Host "  .\scripts\program.ps1 -Sof `"$sof`""
} else {
    Write-Warning "No .sof produced. Check the compile log above."
}

# Print a compact timing summary if available
$sta = Join-Path $outDir "$Revision.sta.rpt"
if (Test-Path $sta) {
    $summary = Select-String -Path $sta -Pattern 'Timing requirements (met|not met)' |
               Select-Object -First 1
    if ($summary) { Write-Host "Timing      : $($summary.Line.Trim())" }
}
