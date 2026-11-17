# Print the state of the card from the host's point of view (Windows).
#
#   .\scripts\board-status.ps1
#
# Shows: PCIe endpoint(s), link speed/width, FTDI programmer, Quartus JTAG chain.

$ErrorActionPreference = 'SilentlyContinue'

function Section($name) {
    Write-Host ""
    Write-Host "=== $name ===" -ForegroundColor Cyan
}

Section 'PCIe devices (Microsoft 1414:*)'
$pci = Get-CimInstance Win32_PnPEntity |
    Where-Object { $_.PNPDeviceID -like 'PCI\VEN_1414*' }
if (-not $pci) {
    Write-Host "  none - FPGA unconfigured, card not seated, or no PCIe bitstream loaded" -ForegroundColor Yellow
} else {
    foreach ($d in $pci) {
        Write-Host "  $($d.PNPDeviceID)"
        Write-Host "  Name   : $($d.Name)"
        $props = Get-PnpDeviceProperty -InstanceId $d.PNPDeviceID
        $speed = ($props | Where-Object KeyName -eq 'DEVPKEY_PciDevice_CurrentLinkSpeed').Data
        $width = ($props | Where-Object KeyName -eq 'DEVPKEY_PciDevice_CurrentLinkWidth').Data
        $mspeed = ($props | Where-Object KeyName -eq 'DEVPKEY_PciDevice_MaxLinkSpeed').Data
        $mwidth = ($props | Where-Object KeyName -eq 'DEVPKEY_PciDevice_MaxLinkWidth').Data
        $speedName = @{ 1='2.5 GT/s (Gen1)'; 2='5 GT/s (Gen2)'; 3='8 GT/s (Gen3)' }[$speed]
        $mspeedName = @{ 1='2.5 GT/s (Gen1)'; 2='5 GT/s (Gen2)'; 3='8 GT/s (Gen3)' }[$mspeed]
        Write-Host "  Link   : x$width @ $speedName   (capable: x$mwidth @ $mspeedName)"
    }
}

Section 'FTDI programmer'
$ft = Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -like 'USB\VID_0403&PID_6014*' }
if ($ft) {
    foreach ($d in $ft) { Write-Host "  $($d.Status)  $($d.FriendlyName)  $($d.InstanceId)" }
} else {
    Write-Host "  not found - check the USB-B cable and card power" -ForegroundColor Yellow
}

Section 'JTAG chain'
$jtag = Get-Command jtagconfig -ErrorAction SilentlyContinue
if ($jtag) {
    & jtagconfig 2>&1 | ForEach-Object { Write-Host "  $_" }
} else {
    Write-Host "  jtagconfig not on PATH - dot-source scripts\env.ps1 first" -ForegroundColor Yellow
}

Section 'Board temperature (if I2C reachable from host)'
Write-Host "  not available from the host; requires an FPGA I2C master (see docs/hardware/i2c.md)"
