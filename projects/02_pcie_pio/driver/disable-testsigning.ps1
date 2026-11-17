# Disable Windows test signing.
#
#   .\disable-testsigning.ps1      (as Administrator)
#
# Reboot afterwards. You can re-enable Secure Boot in the BIOS once test signing
# is off and the test driver is uninstalled.

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

& bcdedit /set testsigning off
if ($LASTEXITCODE -ne 0) {
    throw "bcdedit failed with exit code $LASTEXITCODE"
}

Write-Host ""
Write-Host "Test signing is now disabled. Reboot Windows." -ForegroundColor Green
Write-Host "After the reboot you can re-enable Secure Boot in the BIOS." -ForegroundColor Yellow
