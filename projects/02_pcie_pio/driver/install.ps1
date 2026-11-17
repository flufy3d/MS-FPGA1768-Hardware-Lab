# Install the test driver package.
#
#   .\install.ps1      (as Administrator)
#
# Requires:
#   - Secure Boot disabled in the BIOS
#   - test signing enabled and a reboot completed
#   - sign.ps1 already run (pcie_bar.sys + pcie_bar.cat signed)

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
    throw "Secure Boot is ON. Disable it in the BIOS (Security -> Secure Boot -> Disabled), save, boot Windows, then retry."
}

$bcd = (& bcdedit /enum '{current}' 2>&1 | Out-String)
if ($bcd -notmatch 'testsigning\s+Yes') {
    throw "Test signing is OFF. Run .\enable-testsigning.ps1 as Administrator, reboot, then retry."
}

$out = Join-Path $PSScriptRoot 'build'
$inf = Join-Path $out 'pcie_bar.inf'
$sys = Join-Path $out 'pcie_bar.sys'
$cat = Join-Path $out 'pcie_bar.cat'

foreach ($file in @($inf, $sys, $cat)) {
    if (-not (Test-Path $file)) {
        throw "Missing $file. Run .\build.ps1 and .\sign.ps1 first."
    }
}

Write-Host "Adding driver package ..." -ForegroundColor Cyan
& pnputil /add-driver $inf /install
if ($LASTEXITCODE -ne 0) {
    throw "pnputil failed with exit code $LASTEXITCODE"
}

Write-Host ""
Write-Host "Device state:" -ForegroundColor Cyan
$devices = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
    Where-Object { $_.InstanceId -like 'PCI\VEN_1172&DEV_E003*' }

if (-not $devices) {
    Write-Warning "No 1172:E003 device is present right now."
    Write-Host "The driver is staged. Load pcie_pio.sof and re-enumerate the card." -ForegroundColor Yellow
} else {
    $devices | Select-Object Status, Class, FriendlyName, InstanceId | Format-Table -AutoSize

    foreach ($device in $devices) {
        $problem = Get-PnpDeviceProperty -InstanceId $device.InstanceId `
            -KeyName 'DEVPKEY_Device_ProblemCode' -ErrorAction SilentlyContinue
        if ($problem -and $problem.Data -ne 0) {
            Write-Warning "Problem code $($problem.Data) on $($device.InstanceId)"
        }
    }
}

Write-Host ""
Write-Host "Next: ..\user\build.ps1, then ..\user\build\pcie_bar_test.exe --write" -ForegroundColor Yellow
