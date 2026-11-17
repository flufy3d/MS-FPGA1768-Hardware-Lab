# Remove the test driver package and its test certificate.
#
#   .\uninstall.ps1      (as Administrator)

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Test-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Admin)) {
    throw "Run this script as Administrator."
}

$text = (& pnputil /enum-drivers 2>&1 | Out-String)
$driverMatches = [regex]::Matches(
    $text,
    'Published Name:\s*(oem\d+\.inf)[\s\S]*?Original Name:\s*pcie_bar\.inf')

if ($driverMatches.Count -eq 0) {
    Write-Host "No pcie_bar.inf driver package is installed." -ForegroundColor Yellow
} else {
    foreach ($match in $driverMatches) {
        $oem = $match.Groups[1].Value
        Write-Host "Removing $oem ..." -ForegroundColor Cyan
        & pnputil /delete-driver $oem /uninstall /force
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "pnputil failed for $oem (exit $LASTEXITCODE)"
        }
    }
}

$subject = 'CN=MS-FPGA1768 Lab Test Driver'
foreach ($store in @('Root', 'TrustedPublisher', 'My')) {
    Get-ChildItem "Cert:\LocalMachine\$store" -ErrorAction SilentlyContinue |
        Where-Object { $_.Subject -eq $subject } |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "Driver package and test certificate removed." -ForegroundColor Green
Write-Host "Run .\disable-testsigning.ps1, reboot, then re-enable Secure Boot in the BIOS." -ForegroundColor Yellow
