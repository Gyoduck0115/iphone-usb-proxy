<#
.SYNOPSIS
    0~3단계 동작 검증 스크립트:
    - SOCKS5 단독 출구 IP 확인 (curl --socks5-hostname)
    - TUN 모드 직통 출구 IP 확인
    - UsbMuxBridge 내장 SOCKS5 + UoT v1/v2 셀프테스트
.EXAMPLE
    .\pc\scripts\test-proxy.ps1 -CheckSocks
    .\pc\scripts\test-proxy.ps1 -CheckTun
    .\pc\scripts\test-proxy.ps1 -SelfTest
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
        throw "UsbMuxBridge.exe가 없습니다. 먼저 .\pc\scripts\setup-pc.ps1을 실행하세요."
    }
    Write-Host "=== UsbMuxBridge 프로토콜 및 usbmuxd 셀프테스트 ===" -ForegroundColor Cyan
    & $BridgeExe selftest
    if ($LASTEXITCODE -ne 0) { throw "selftest 실패" }
}

if ($CheckSocks) {
    Write-Host "`n=== SOCKS5(127.0.0.1:$Port) 출구 IP 확인 ===" -ForegroundColor Cyan
    $ip = & curl.exe --silent --show-error --max-time 10 --socks5-hostname "127.0.0.1:$Port" "https://ifconfig.me"
    if ($LASTEXITCODE -ne 0) { throw "SOCKS5 curl 요청 실패" }
    Write-Host "  출구 IP: $ip" -ForegroundColor Green
    Write-Host "  (아이폰 Wi-Fi가 켜져 있어도 셀룰러 통신사 IP가 나와야 1단계 완료 기준 통과입니다.)"
}

if ($CheckTun) {
    Write-Host "`n=== TUN 모드 전체 트래픽 출구 IP 확인 ===" -ForegroundColor Cyan
    $tun = Get-NetAdapter -Name "USBProxyTUN" -ErrorAction SilentlyContinue
    if (-not $tun) {
        Write-Warning "USBProxyTUN 어댑터가 보이지 않습니다. start-proxy.ps1이 실행 중인지 확인하세요."
    } else {
        Write-Host "  어댑터 상태: $($tun.Name) ($($tun.Status))" -ForegroundColor Green
    }
    $ip = & curl.exe --silent --show-error --max-time 10 "https://ifconfig.me"
    if ($LASTEXITCODE -ne 0) { throw "TUN 모드 curl 요청 실패" }
    Write-Host "  출구 IP: $ip" -ForegroundColor Green
}
