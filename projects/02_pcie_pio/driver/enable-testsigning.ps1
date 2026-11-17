# Enable Windows test signing.
#
#   .\enable-testsigning.ps1      (as Administrator)
#
# Secure Boot must be disabled in the BIOS first. This script does not reboot.

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

$secureBoot = $false
try {
    $secureBoot = Confirm-SecureBootUEFI
} catch {
    $secureBoot = $false
}

if ($secureBoot) {
    Write-Host "Secure Boot is ON." -ForegroundColor Red
    Write-Host "Disable it in the BIOS first:" -ForegroundColor Yellow
    Write-Host "  Security -> Secure Boot -> Secure Boot Control -> Disabled"
    Write-Host "  Save changes, boot Windows, then run this script again."
    throw "Secure Boot must be disabled before test signing can be used."
}

& bcdedit /set testsigning on
if ($LASTEXITCODE -ne 0) {
    throw "bcdedit failed with exit code $LASTEXITCODE"
}

Write-Host ""
Write-Host "Test signing is now enabled." -ForegroundColor Green
Write-Host "Reboot Windows, then verify:" -ForegroundColor Yellow
Write-Host "  bcdedit /enum {current}    (look for 'testsigning Yes')"
Write-Host "  Confirm-SecureBootUEFI     (should return False)"
Write-Host ""
Write-Host "After the reboot, run .\sign.ps1 and .\install.ps1." -ForegroundColor Yellow
