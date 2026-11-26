<#
.SYNOPSIS
    Stops any running sing-box / iproxy / UsbMuxBridge processes and checks Windows route restoration.
#>
[CmdletBinding()]
param()

$names = @("sing-box", "iproxy", "UsbMuxBridge")
foreach ($n in $names) {
    $procs = Get-Process -Name $n -ErrorAction SilentlyContinue
    if ($procs) {
        $procs | Stop-Process -Force -ErrorAction SilentlyContinue
        Write-Host "Stopped: $n ($($procs.Count))" -ForegroundColor Yellow
    }
}

Start-Sleep -Milliseconds 500
$tun = Get-NetAdapter -Name "USBProxyTUN" -ErrorAction SilentlyContinue
if ($tun) {
    Write-Warning "USBProxyTUN adapter is still present."
} else {
    Write-Host "[OK] No USBProxyTUN adapter present (routes clean)." -ForegroundColor Green
}

Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
    Select-Object InterfaceAlias, NextHop, RouteMetric |
    Format-Table -AutoSize
