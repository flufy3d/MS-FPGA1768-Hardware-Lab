# Dot-source this file:  . .\scripts\env.ps1
#
# Locates a Quartus Prime installation and puts its tools on PATH for the current
# PowerShell session. Safe to call repeatedly.

$ErrorActionPreference = 'Stop'

function Find-QuartusRoot {
    $candidates = @()

    if ($env:QUARTUS_ROOTDIR) { $candidates += $env:QUARTUS_ROOTDIR }

    $candidates += @(
        'D:\altera_pro\25.1\quartus',
        'C:\altera_pro\25.1\quartus',
        'C:\altera\25.1\quartus',
        'C:\intelFPGA_pro\25.1\quartus',
        'C:\intelFPGA\25.1\quartus'
    )

    foreach ($pattern in @(
        'D:\altera_pro\*\quartus',
        'C:\altera_pro\*\quartus',
        'C:\intelFPGA_pro\*\quartus',
        'C:\intelFPGA\*\quartus'
    )) {
        $candidates += Get-ChildItem -Path $pattern -Directory -ErrorAction SilentlyContinue |
                       Sort-Object Name -Descending |
                       ForEach-Object { $_.FullName }
    }

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path (Join-Path $candidate 'bin64\quartus_sh.exe'))) {
            return (Resolve-Path $candidate).Path
        }
    }

    throw "Quartus not found. Set QUARTUS_ROOTDIR or pass -QuartusRoot. See docs/toolchain/quartus-install.md"
}

$root = Find-QuartusRoot
$env:QUARTUS_ROOTDIR = $root

# The Quartus Programmer data (devices\programmer\pgm_dev_info.pcf) is a separate
# package. If the main tree lacks it but a standalone programmer install exists,
# remember that tree so program.ps1 can use its quartus_pgm.
$progRoot = $null
$mainDevices = Split-Path $root -Parent
if (Test-Path (Join-Path $mainDevices 'devices\programmer\pgm_dev_info.pcf')) {
    $progRoot = $root
}
if (-not $progRoot) {
    $candidates = @(
        (Split-Path $root -Parent) + '\qprogrammer\quartus',
        'D:\altera_pro\25.1\qprogrammer\quartus',
        'C:\altera_pro\25.1\qprogrammer\quartus'
    )
    foreach ($candidate in $candidates) {
        if (Test-Path (Join-Path $candidate 'bin64\quartus_pgm.exe')) {
            $pcf = Join-Path (Split-Path $candidate -Parent) 'devices\programmer\pgm_dev_info.pcf'
            if (Test-Path $pcf) { $progRoot = $candidate; break }
        }
    }
}
$env:QUARTUS_PROGRAMMER_ROOT = $progRoot

# Quartus reads the licence path from LM_LICENSE_FILE. A shell started before the
# user set it will not have it, so import the per-user value when missing.
if (-not $env:LM_LICENSE_FILE) {
    $userLicense = [Environment]::GetEnvironmentVariable('LM_LICENSE_FILE', 'User')
    if ($userLicense) {
        $env:LM_LICENSE_FILE = $userLicense
        Write-Host "Licence      : $userLicense" -ForegroundColor Green
    }
}

$bin64 = Join-Path $root 'bin64'
$bin   = Join-Path $root 'bin'
foreach ($p in @($bin64, $bin)) {
    if ((Test-Path $p) -and ($env:Path -notlike "*$p*")) {
        $env:Path = "$p;$env:Path"
    }
}

Write-Host "Quartus root : $root" -ForegroundColor Green
$version = & (Join-Path $bin64 'quartus_sh.exe') --version 2>&1 | Select-Object -First 3
$version | ForEach-Object { Write-Host "  $_" }

Write-Host "Plugins      :" -ForegroundColor Green
Get-ChildItem (Join-Path $bin64 'jtag_hw_*.dll') -ErrorAction SilentlyContinue |
    ForEach-Object { Write-Host "  $($_.Name)" }
