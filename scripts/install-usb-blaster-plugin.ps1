# Install the Microsoft Catapult v3 JTAG plugin into Quartus.
#
# Copies jtag_hw_microsoft_catapult.dll into <QuartusRoot>\bin64 so that jtagd
# recognises the on-board FT232H as a programmer.
#
# Requires an elevated PowerShell session (write access to Program Files / install dir).

[CmdletBinding()]
param(
    [string]$QuartusRoot
)

$ErrorActionPreference = 'Stop'

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Admin)) {
    throw "Run this script from an elevated PowerShell (Quartus bin64 is not user-writable)."
}

if (-not $QuartusRoot) {
    . (Join-Path $PSScriptRoot 'env.ps1') | Out-Null
    $QuartusRoot = $env:QUARTUS_ROOTDIR
}

$bin64 = Join-Path $QuartusRoot 'bin64'
if (-not (Test-Path $bin64)) { throw "Not a Quartus installation: $QuartusRoot" }

$source = Join-Path (Split-Path $PSScriptRoot) 'hardware\tools\usb-blaster\jtag_hw_microsoft_catapult.dll'
if (-not (Test-Path $source)) { throw "Plugin not found: $source" }

$target = Join-Path $bin64 'jtag_hw_microsoft_catapult.dll'

if (Test-Path $target) {
    $existing = (Get-FileHash $target -Algorithm SHA256).Hash
    $incoming = (Get-FileHash $source -Algorithm SHA256).Hash
    if ($existing -eq $incoming) {
        Write-Host "Plugin already installed (identical)." -ForegroundColor Green
    } else {
        $backup = "$target.bak"
        Copy-Item $target $backup -Force
        Write-Host "Existing plugin backed up to $backup" -ForegroundColor Yellow
        Copy-Item $source $target -Force
        Write-Host "Plugin replaced." -ForegroundColor Green
    }
} else {
    Copy-Item $source $target
    Write-Host "Plugin installed to $target" -ForegroundColor Green
}

# Remove stale jtagd so the new plugin is loaded on next use
Get-Process -Name jtagd -ErrorAction SilentlyContinue | Stop-Process -Force
Write-Host "jtagd stopped (it will restart automatically)." -ForegroundColor Green

Write-Host ""
Write-Host "Verify with:" -ForegroundColor Cyan
Write-Host "  jtagconfig"
Write-Host "Expected: 1) Microsoft Catapult v3 (64) [USB-0] / 02E060DD  10AX115"
