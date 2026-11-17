# Scan the JTAG chain through the on-board FT232H programmer.
#
#   .\scripts\jtag-scan.ps1
#
# Expected: cable "Microsoft Catapult v3" and IDCODE 0x02E060DD.

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'env.ps1') | Out-Null

Write-Host "`n=== jtagconfig ===" -ForegroundColor Cyan
$output = & jtagconfig 2>&1
$output | ForEach-Object { Write-Host $_ }

$text = ($output | Out-String)
if ($text -match '02E060DD') {
    Write-Host "`nOK: Arria 10 10AX115 detected (IDCODE 0x02E060DD)." -ForegroundColor Green
} elseif ($text -match '<no cable found>' -or $text -match 'No cables') {
    Write-Host "`nNo cable. Install the plugin: .\scripts\install-usb-blaster-plugin.ps1" -ForegroundColor Yellow
} else {
    Write-Host "`nCable found but no expected IDCODE. Check power, J5 pin 10, and the JTAG chain." -ForegroundColor Yellow
}

Write-Host "`n=== device details ===" -ForegroundColor Cyan
& jtagconfig --enum 2>&1 | ForEach-Object { Write-Host $_ }
