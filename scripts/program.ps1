# Program a .sof over JTAG (volatile) or a .jic into the config flash (persistent).
#
# Volatile:
#   .\scripts\program.ps1 -Sof projects\01_hello_world\output_files\hello_world.sof
#
# Persistent (DESTRUCTIVE - reads/writes the config flash; back it up first):
#   .\scripts\program.ps1 -Jic build\hello_world.jic -Flash

[CmdletBinding(DefaultParameterSetName = 'Sof')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'Sof')]
    [string]$Sof,

    [Parameter(Mandatory = $true, ParameterSetName = 'Jic')]
    [string]$Jic,

    [Parameter(ParameterSetName = 'Jic')]
    [switch]$Flash,

    [switch]$FlashSfl
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'env.ps1') | Out-Null

function Get-Cable {
    $lines = & jtagconfig 2>&1
    $index = 0
    $cables = @()
    foreach ($line in $lines) {
        if ($line -match '^\s*(\d+)\)\s*(.+)$') {
            $cables += [pscustomobject]@{ Index = $matches[1]; Name = $matches[2].Trim() }
        }
    }
    return $cables
}

$cables = Get-Cable
if (-not $cables) {
    throw "No JTAG cable found. Install the USB-Blaster plugin: .\scripts\install-usb-blaster-plugin.ps1"
}

Write-Host "JTAG cables:" -ForegroundColor Green
$cables | ForEach-Object { Write-Host "  $($_.Index)) $($_.Name)" }

$hwArgs = @()
if ($cables.Count -gt 1) {
    $hwArgs = @('-c', $cables[0].Index)
}

if ($PSCmdlet.ParameterSetName -eq 'Sof') {
    if (-not (Test-Path $Sof)) { throw "SOF not found: $Sof" }
    $Sof = (Resolve-Path $Sof).Path
    Write-Host ""
    Write-Host "Loading (volatile) $Sof" -ForegroundColor Cyan
    & quartus_pgm @hwArgs -m jtag -o "p;$Sof"
    if ($LASTEXITCODE -ne 0) { throw "quartus_pgm failed ($LASTEXITCODE)" }
    Write-Host "Done. The design is running from SRAM; a power cycle restores the flash image." -ForegroundColor Green
    return
}

if (-not $Flash) {
    throw "Pass -Flash to confirm that you want to write the persistent configuration flash."
}

if (-not (Test-Path $Jic)) { throw "JIC not found: $Jic" }
$Jic = (Resolve-Path $Jic).Path

$sfl = Join-Path (Split-Path $PSScriptRoot) 'firmware\prebuilt\Catapult_v3_sfl.sof'
if (-not (Test-Path $sfl)) { throw "Serial Flash Loader not found: $sfl" }

Write-Warning "This will overwrite the on-board configuration flash at $Jic"
Write-Host "Step 1/2: loading Serial Flash Loader (volatile)" -ForegroundColor Cyan
& quartus_pgm @hwArgs -m jtag -o "p;$sfl"
if ($LASTEXITCODE -ne 0) { throw "Failed to load SFL ($LASTEXITCODE)" }

Write-Host "Step 2/2: writing flash" -ForegroundColor Cyan
& quartus_pgm @hwArgs -m jtag -o "p;$Jic"
if ($LASTEXITCODE -ne 0) { throw "Flash programming failed ($LASTEXITCODE)" }

Write-Host "Flash written. Power-cycle the card to boot from flash." -ForegroundColor Green
