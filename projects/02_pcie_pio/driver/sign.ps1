# Sign the test driver and build/sign its catalog.
#
#   .\sign.ps1      (as Administrator)
#
# Creates a self-signed code-signing certificate in LocalMachine\My, installs
# it into Root and TrustedPublisher, signs pcie_bar.sys, runs inf2cat, and signs
# pcie_bar.cat. The .pfx and password stay in build\ (git-ignored).
#
# This is a lab/test certificate. The driver only loads with test signing on and
# Secure Boot disabled.

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

$out = Join-Path $PSScriptRoot 'build'
$sys = Join-Path $out 'pcie_bar.sys'
$inf = Join-Path $out 'pcie_bar.inf'
$cat = Join-Path $out 'pcie_bar.cat'

if (-not (Test-Path $sys) -or -not (Test-Path $inf)) {
    & (Join-Path $PSScriptRoot 'build.ps1')
}

$subject = 'CN=MS-FPGA1768 Lab Test Driver'
$pfx = Join-Path $out 'pcie_bar_test.pfx'
$cer = Join-Path $out 'pcie_bar_test.cer'
$pwdFile = Join-Path $out 'cert_password.txt'

if (-not (Test-Path $pfx) -or -not (Test-Path $pwdFile)) {
    Write-Host "Creating self-signed code-signing certificate ..." -ForegroundColor Cyan
    $plain = [Guid]::NewGuid().ToString('N')
    $secure = ConvertTo-SecureString $plain -AsPlainText -Force

    $cert = Get-ChildItem Cert:\LocalMachine\My |
        Where-Object { $_.Subject -eq $subject } |
        Select-Object -First 1

    if (-not $cert) {
        $cert = New-SelfSignedCertificate `
            -Type CodeSigningCert `
            -Subject $subject `
            -CertStoreLocation Cert:\LocalMachine\My `
            -KeyExportPolicy Exportable `
            -KeyUsage DigitalSignature
    }

    Export-PfxCertificate -Cert $cert -FilePath $pfx -Password $secure | Out-Null
    Export-Certificate -Cert $cert -FilePath $cer | Out-Null
    Set-Content -Path $pwdFile -Value $plain -Encoding ascii
} else {
    $plain = (Get-Content $pwdFile -Raw).Trim()
    $cert = Get-ChildItem Cert:\LocalMachine\My |
        Where-Object { $_.Subject -eq $subject } |
        Select-Object -First 1
}

if (-not $cert) {
    throw "Code-signing certificate not found. Delete build\pcie_bar_test.pfx and retry."
}

foreach ($store in @('Root', 'TrustedPublisher')) {
    $existing = Get-ChildItem "Cert:\LocalMachine\$store" |
        Where-Object { $_.Thumbprint -eq $cert.Thumbprint }
    if (-not $existing) {
        Write-Host "Installing certificate into LocalMachine\$store ..." -ForegroundColor Cyan
        Import-Certificate -FilePath $cer -CertStoreLocation "Cert:\LocalMachine\$store" | Out-Null
    }
}

$programFilesX86 = ${env:ProgramFiles(x86)}
if (-not $programFilesX86) {
    $programFilesX86 = 'C:\Program Files (x86)'
}
$wdkRoot = Join-Path $programFilesX86 'Windows Kits\10'
$sdkVer  = '10.0.22621.0'
$signtool = Join-Path $wdkRoot "bin\$sdkVer\x64\signtool.exe"
$inf2cat  = Join-Path $wdkRoot "bin\$sdkVer\x86\Inf2Cat.exe"
if (-not (Test-Path $signtool)) { throw "signtool.exe not found: $signtool" }
if (-not (Test-Path $inf2cat))  { throw "Inf2Cat.exe not found: $inf2cat" }

Write-Host "Signing pcie_bar.sys ..." -ForegroundColor Cyan
& $signtool sign /fd SHA256 /f $pfx /p $plain `
    /tr http://timestamp.digicert.com /td SHA256 $sys
if ($LASTEXITCODE -ne 0) {
    Write-Warning "Timestamped signing failed; retrying without a timestamp."
    & $signtool sign /fd SHA256 /f $pfx /p $plain $sys
    if ($LASTEXITCODE -ne 0) { throw "signtool failed on pcie_bar.sys" }
}

Write-Host "Generating pcie_bar.cat ..." -ForegroundColor Cyan
& $inf2cat /driver:$out /os:10_X64
if ($LASTEXITCODE -ne 0) { throw "inf2cat failed with exit code $LASTEXITCODE" }

Write-Host "Signing pcie_bar.cat ..." -ForegroundColor Cyan
& $signtool sign /fd SHA256 /f $pfx /p $plain `
    /tr http://timestamp.digicert.com /td SHA256 $cat
if ($LASTEXITCODE -ne 0) {
    Write-Warning "Timestamped signing failed; retrying without a timestamp."
    & $signtool sign /fd SHA256 /f $pfx /p $plain $cat
    if ($LASTEXITCODE -ne 0) { throw "signtool failed on pcie_bar.cat" }
}

Write-Host "Verifying signatures ..." -ForegroundColor Cyan
& $signtool verify /pa /v $cat
& $signtool verify /pa /v $sys

Write-Host ""
Write-Host "Signed with certificate:" -ForegroundColor Green
Write-Host "  Subject:   $($cert.Subject)"
Write-Host "  Thumbprint: $($cert.Thumbprint)"
Write-Host ""
Write-Host "Next: .\enable-testsigning.ps1 (as Administrator), reboot, then .\install.ps1" -ForegroundColor Yellow
