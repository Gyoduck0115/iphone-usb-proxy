<#
.SYNOPSIS
    Stage 0-3 verification script:
    - SelfTest: UsbMuxBridge usbmuxd + SOCKS5 TCP + UoT v1/v2 loopback test
    - CheckSocks: verifies exit IP through 127.0.0.1:1080 SOCKS5
    - CheckTun: verifies exit IP through active USBProxyTUN adapter
.EXAMPLE
    .\pc\scripts\test-proxy.ps1 -SelfTest
    .\pc\scripts\test-proxy.ps1 -CheckSocks
    .\pc\scripts\test-proxy.ps1 -CheckTun
#>
[CmdletBinding()]
param(
    [int]$Port = 1080,
    [switch]$CheckSocks,
    [switch]$CheckTun,
    [switch]$SelfTest
)

$ErrorActionPreference = "Stop"
$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$BridgeExe = Join-Path $ProjectRoot "pc\bin\UsbMuxBridge\UsbMuxBridge.exe"

if (-not $CheckSocks -and -not $CheckTun -and -not $SelfTest) {
    $SelfTest = $true
}

if ($SelfTest) {
    if (-not (Test-Path $BridgeExe)) {
        throw "UsbMuxBridge.exe not found. Run .\pc\scripts\setup-pc.ps1 first."
    }
    Write-Host "=== UsbMuxBridge protocol and usbmuxd selftest ===" -ForegroundColor Cyan
    & $BridgeExe selftest
    if ($LASTEXITCODE -ne 0) { throw "selftest failed" }
}

if ($CheckSocks) {
    Write-Host "`n=== Checking exit IP via SOCKS5 (127.0.0.1:$Port) ===" -ForegroundColor Cyan
    $ip = & curl.exe --silent --show-error --max-time 10 --socks5-hostname "127.0.0.1:$Port" "https://ifconfig.me"
    if ($LASTEXITCODE -ne 0) { throw "SOCKS5 curl failed" }
    Write-Host "  Exit IP: $ip" -ForegroundColor Green
    Write-Host "  (Should match your cellular carrier IP even when iPhone Wi-Fi is on.)"
}

if ($CheckTun) {
    Write-Host "`n=== Checking exit IP via TUN mode ===" -ForegroundColor Cyan
    $tun = Get-NetAdapter -Name "USBProxyTUN" -ErrorAction SilentlyContinue
    if (-not $tun) {
        Write-Warning "USBProxyTUN adapter not found. Ensure start-proxy.ps1 is running."
    } else {
        Write-Host "  Adapter: $($tun.Name) ($($tun.Status))" -ForegroundColor Green
    }
    $ip = & curl.exe --silent --show-error --max-time 10 "https://ifconfig.me"
    if ($LASTEXITCODE -ne 0) { throw "TUN curl failed" }
    Write-Host "  Exit IP: $ip" -ForegroundColor Green
}
