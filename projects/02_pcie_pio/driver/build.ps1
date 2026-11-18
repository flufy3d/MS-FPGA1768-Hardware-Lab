# Build the KMDF test driver with the installed Visual Studio 2022 + WDK 10.
#
#   .\build.ps1
#
# Outputs (git-ignored):
#   build\pcie_bar.sys
#   build\pcie_bar.inf
#
# Signing and .cat generation are in sign.ps1 because the .sys must be signed
# before inf2cat hashes it.

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$programFilesX86 = ${env:ProgramFiles(x86)}
if (-not $programFilesX86) {
    $programFilesX86 = 'C:\Program Files (x86)'
}

$vswhere = Join-Path $programFilesX86 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path $vswhere)) {
    throw "vswhere.exe not found. Install Visual Studio 2022 with the C++ workload."
}

$vsPath = & $vswhere -latest -products '*' `
    -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
    -property installationPath
if (-not $vsPath) {
    throw "No Visual Studio installation with the C++ toolset was found."
}

$msvc = Get-ChildItem (Join-Path $vsPath 'VC\Tools\MSVC') -Directory |
    Sort-Object Name -Descending |
    Select-Object -First 1
if (-not $msvc) {
    throw "MSVC toolset not found under $vsPath."
}

$cl   = Join-Path $msvc.FullName 'bin\Hostx64\x64\cl.exe'
$link = Join-Path $msvc.FullName 'bin\Hostx64\x64\link.exe'
if (-not (Test-Path $cl) -or -not (Test-Path $link)) {
    throw "cl.exe/link.exe not found in $($msvc.FullName)."
}

$wdkRoot   = Join-Path $programFilesX86 'Windows Kits\10'
$sdkVer    = '10.0.22621.0'

# The KMDF version must not be newer than the framework on the test host, or
# WdfDriverCreate fails and the device shows code 10/31. The WDK 22621 kit ships
# 1.11 through 1.33; the lab host is Windows 10 22H2 (19045), which has 1.31.
# Raise this together with `KmdfLibraryVersion` in pcie_bar.inf if the host moves
# to Windows 11. `(Get-Item C:\Windows\System32\drivers\Wdf01000.sys).VersionInfo`
# reports the installed version.
$kmdfVer   = '1.31'

$includePaths = @(
    (Join-Path $wdkRoot "Include\$sdkVer\km"),
    (Join-Path $wdkRoot "Include\$sdkVer\shared"),
    (Join-Path $wdkRoot "Include\$sdkVer\ucrt"),
    (Join-Path $wdkRoot "Include\wdf\kmdf\$kmdfVer"),
    (Join-Path $msvc.FullName 'include')
)
$libPaths = @(
    (Join-Path $wdkRoot "Lib\$sdkVer\km\x64"),
    (Join-Path $wdkRoot "Lib\wdf\kmdf\x64\$kmdfVer"),
    (Join-Path $msvc.FullName 'lib\x64'),
    (Join-Path $wdkRoot "Lib\$sdkVer\ucrt\x64")
)

foreach ($p in ($includePaths + $libPaths)) {
    if (-not (Test-Path $p)) {
        throw "Required WDK/MSVC path missing: $p"
    }
}

$out = Join-Path $PSScriptRoot 'build'
New-Item -ItemType Directory -Force -Path $out | Out-Null

$clArgs = @(
    '/nologo', '/c', '/kernel', '/GS', '/W4', '/O2',
    '/D_AMD64_', '/DAMD64',
    '/DWIN32=100', '/D_WIN32_WINNT=0x0A00', '/DNTDDI_VERSION=0x0A000000',
    '/DKMDF_VERSION_MAJOR=1', '/DKMDF_VERSION_MINOR=31',
    '/D_CRT_SECURE_NO_WARNINGS',
    "/Fo$out\pcie_bar.obj"
)
$clArgs += $includePaths | ForEach-Object { "/I$_" }
$clArgs += (Join-Path $PSScriptRoot 'pcie_bar.c')

Write-Host "Compiling pcie_bar.c ..." -ForegroundColor Cyan
& $cl @clArgs
if ($LASTEXITCODE -ne 0) { throw "cl.exe failed with exit code $LASTEXITCODE" }

$linkArgs = @(
    '/nologo', '/DRIVER', '/SUBSYSTEM:NATIVE', '/MACHINE:X64',
    '/ENTRY:FxDriverEntry',
    "/OUT:$out\pcie_bar.sys"
)
$linkArgs += $libPaths | ForEach-Object { "/LIBPATH:$_" }
$linkArgs += @(
    "$out\pcie_bar.obj",
    'wdfdriverentry.lib', 'wdfldr.lib',
    'ntoskrnl.lib', 'hal.lib', 'BufferOverflowK.lib'
)

Write-Host "Linking pcie_bar.sys ..." -ForegroundColor Cyan
& $link @linkArgs
if ($LASTEXITCODE -ne 0) { throw "link.exe failed with exit code $LASTEXITCODE" }

Copy-Item (Join-Path $PSScriptRoot 'pcie_bar.inf') (Join-Path $out 'pcie_bar.inf') -Force

Write-Host ""
Write-Host "Built:" -ForegroundColor Green
Get-ChildItem $out | Select-Object Name, Length | Format-Table -AutoSize
Write-Host "Next: .\sign.ps1 (as Administrator) to sign the driver and build the .cat" -ForegroundColor Yellow
