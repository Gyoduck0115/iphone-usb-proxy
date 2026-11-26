<#
.SYNOPSIS
    실행 중인 sing-box 및 usbmux 포워더 프로세스를 강제 정리하고 네트워크 경로 원복 상태를 확인합니다.
#>
[CmdletBinding()]
param()

$names = @("sing-box", "iproxy", "UsbMuxBridge")
foreach ($n in $names) {
    $procs = Get-Process -Name $n -ErrorAction SilentlyContinue
    if ($procs) {
        $procs | Stop-Process -Force -ErrorAction SilentlyContinue
        Write-Host "종료됨: $n ($($procs.Count)개)" -ForegroundColor Yellow
    }
}

Start-Sleep -Milliseconds 500
$tun = Get-NetAdapter -Name "USBProxyTUN" -ErrorAction SilentlyContinue
if ($tun) {
    Write-Warning "USBProxyTUN 어댑터가 아직 남아 있습니다."
} else {
    Write-Host "[OK] USBProxyTUN 어댑터 없음 (경로 원복 완료)" -ForegroundColor Green
}

Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
    Select-Object InterfaceAlias, NextHop, RouteMetric |
    Format-Table -AutoSize
