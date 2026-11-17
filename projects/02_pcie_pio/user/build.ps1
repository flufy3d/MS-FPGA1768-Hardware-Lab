# Build the user-mode BAR0 test client with the in-box .NET Framework compiler.
#
#   .\build.ps1
#
# Output (git-ignored):
#   build\pcie_bar_test.exe

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) {
    throw "csc.exe not found at $csc"
}

$out = Join-Path $PSScriptRoot 'build'
New-Item -ItemType Directory -Force -Path $out | Out-Null

Write-Host "Compiling pcie_bar_test.cs ..." -ForegroundColor Cyan
& $csc /nologo /platform:x64 /optimize+ /out:"$out\pcie_bar_test.exe" `
    (Join-Path $PSScriptRoot 'pcie_bar_test.cs')

if ($LASTEXITCODE -ne 0) {
    throw "csc.exe failed with exit code $LASTEXITCODE"
}

Write-Host ""
Write-Host "Built:" -ForegroundColor Green
Get-ChildItem $out | Select-Object Name, Length | Format-Table -AutoSize
Write-Host "Run: $out\pcie_bar_test.exe --write" -ForegroundColor Yellow
