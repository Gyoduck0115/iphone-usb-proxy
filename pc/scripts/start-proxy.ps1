#
.SYNOPSIS
    아이폰 USB 프록시 통합 실행 스크립트 (3단계 완성판).
    아이폰 USB 연결 감지 -> usbmux 포워딩 시작 -> sing-box TUN 시작 -> 종료 시 프로세스 정리 및 경로 원복.
.EXAMPLE
    .\pc\scripts\start-proxy.ps1 -Mode uot
    .\pc\scripts\start-proxy.ps1 -Mode tcp
    .\pc\scripts\start-proxy.ps1 -SocksOnly
#>
[CmdletBinding()]
param(
    [ValidateSet("uot", "tcp")]
    [string]$Mode = "uot",

    [int]$LocalPort = 1080,
    [int]$DevicePort = 1080,

    [ValidateSet("auto", "iproxy", "pymobiledevice3", "bridge")]
    [string]$Forwarder = "auto",

    [string]$Udid = "",

    # TUN 어댑터를 켜지 않고 usbmux SOCKS5 포트(127.0.0.1:1080)만 열기 (0/1단계 curl 테스트용)
    [switch]$SocksOnly
)

$ErrorActionPreference = "Stop"
$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$BinDir = Join-Path $ProjectRoot "pc\bin"
$ConfigPath = Join-Path $ProjectRoot ("pc\config\sing-box-{0}.json" -f $Mode)
$SingBoxExe = Join-Path $BinDir "sing-box.exe"
$BridgeExe = Join-Path $BinDir "UsbMuxBridge\UsbMuxBridge.exe"

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($id)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-PortOpen([string]$TargetHost, [int]$Port) {
    $tcp = New-Object System.Net.Sockets.TcpClient
    try {
        $ar = $tcp.BeginConnect($TargetHost, $Port, $null, $null)
        if ($ar.AsyncWaitHandle.WaitOne(500)) {
            $tcp.EndConnect($ar)
            return $true
        }
        return $false
    } catch {
        return $false
    } finally {
        $tcp.Dispose()
    }
}

function Test-Socks5Handshake([string]$TargetHost, [int]$Port) {
    $tcp = New-Object System.Net.Sockets.TcpClient
    try {
        $tcp.ReceiveTimeout = 2500
        $tcp.SendTimeout = 2500
        $ar = $tcp.BeginConnect($TargetHost, $Port, $null, $null)
        if (-not $ar.AsyncWaitHandle.WaitOne(1500)) {
            return @{ Ok = $false; Reason = "로컬 포트 $Port 연결 시간 초과" }
        }
        $tcp.EndConnect($ar)
        $stream = $tcp.GetStream()
        [byte[]]$greeting = @(0x05, 0x01, 0x00)
        $stream.Write($greeting, 0, $greeting.Length)
        $buf = New-Object byte[] 2
        $read = $stream.Read($buf, 0, 2)
        if ($read -eq 2 -and $buf[0] -eq 0x05 -and $buf[1] -eq 0x00) {
            return @{ Ok = $true; Reason = "OK" }
        }
        if ($read -eq 0) {
            return @{ Ok = $false; Reason = "아이폰 포트 $DevicePort 연결이 즉시 닫혔습니다 (USBProxy가 중지되었거나 다른 앱이 포트 $DevicePort 을(를) 점유 중)" }
        }
        return @{ Ok = $false; Reason = "아이폰 포트 $DevicePort 응답이 SOCKS5가 아닙니다 (수신: $($buf[0]), $($buf[1]))" }
    } catch {
        return @{ Ok = $false; Reason = $_.Exception.Message }
    } finally {
        $tcp.Dispose()
    }
}

function Resolve-Forwarder {
    param([string]$Preference)
    $iproxyCmd = Get-Command (Join-Path $BinDir "iproxy.exe") -ErrorAction SilentlyContinue
    if (-not $iproxyCmd) { $iproxyCmd = Get-Command "iproxy" -ErrorAction SilentlyContinue }
    $pyCmd = Get-Command "pymobiledevice3" -ErrorAction SilentlyContinue
    $hasBridge = Test-Path $BridgeExe

    switch ($Preference) {
        "iproxy" {
            if (-not $iproxyCmd) { throw "iproxy를 찾을 수 없습니다." }
            return @{ Kind = "iproxy"; Path = $iproxyCmd.Source }
        }
        "pymobiledevice3" {
            if (-not $pyCmd) { throw "pymobiledevice3를 찾을 수 없습니다." }
            return @{ Kind = "pymobiledevice3"; Path = $pyCmd.Source }
        }
        "bridge" {
            if (-not $hasBridge) { throw "UsbMuxBridge.exe가 없습니다. 먼저 .\pc\scripts\setup-pc.ps1을 실행하세요." }
            return @{ Kind = "bridge"; Path = $BridgeExe }
        }
        default {
            if ($iproxyCmd) { return @{ Kind = "iproxy"; Path = $iproxyCmd.Source } }
            if ($hasBridge) { return @{ Kind = "bridge"; Path = $BridgeExe } }
            if ($pyCmd) { return @{ Kind = "pymobiledevice3"; Path = $pyCmd.Source } }
            throw "사용 가능한 usbmux 포워더(iproxy / UsbMuxBridge / pymobiledevice3)가 없습니다. setup-pc.ps1을 먼저 실행하세요."
        }
    }
}

# 1. 관리자 권한 확인 (TUN 모드일 때 필수)
if (-not $SocksOnly -and -not (Test-IsAdmin)) {
    throw "TUN 어댑터(Wintun) 생성에는 Windows 관리자 권한이 필요합니다. 관리자 PowerShell에서 다시 실행하거나 -SocksOnly 옵션을 사용하세요."
}

if (-not $SocksOnly -and -not (Test-Path $SingBoxExe)) {
    throw "sing-box.exe가 없습니다 ($SingBoxExe). 먼저 .\pc\scripts\setup-pc.ps1을 실행하세요."
}

# 2. usbmuxd 및 아이폰 USB 연결 감지
$muxListen = Get-NetTCPConnection -LocalPort 27015 -State Listen -ErrorAction SilentlyContinue
if (-not $muxListen) {
    throw "Apple Mobile Device Service(127.0.0.1:27015)가 실행 중이지 않습니다. Apple Devices 또는 iTunes를 확인하세요."
}

if (Test-Path $BridgeExe) {
    Write-Host "[1/4] USB 연결 아이폰 감지 중..." -ForegroundColor Cyan
    $devJson = & $BridgeExe devices --json
    $devices = $devJson | ConvertFrom-Json
    $usbDevices = @($devices | Where-Object { $_.ConnectionType -eq "USB" })
    if ($usbDevices.Count -eq 0) {
        throw "USB로 연결된 아이폰을 찾지 못했습니다. 데이터 케이블 연결, 잠금 해제, '이 컴퓨터 신뢰' 상태를 확인하세요."
    }
    foreach ($d in $usbDevices) {
        Write-Host "  감지됨: DeviceID=$($d.DeviceId), Serial=$($d.SerialNumber)" -ForegroundColor Green
    }
}

# 3. 기본 경로 스냅샷 저장 (종료 시 원복 확인용)
$beforeRoutes = Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
    Select-Object InterfaceAlias, NextHop, RouteMetric

$fwd = Resolve-Forwarder -Preference $Forwarder
Write-Host "[2/4] usbmux 포워딩 시작 ($($fwd.Kind)): 127.0.0.1:$LocalPort -> iPhone:$DevicePort" -ForegroundColor Cyan

$fwdArgs = switch ($fwd.Kind) {
    "iproxy" {
        if ($Udid) { @("$LocalPort`:$DevicePort", "-u", $Udid) } else { @("$LocalPort`:$DevicePort") }
    }
    "pymobiledevice3" {
        if ($Udid) { @("usbmux", "forward", "$LocalPort", "$DevicePort", "--udid", $Udid) } else { @("usbmux", "forward", "$LocalPort", "$DevicePort") }
    }
    "bridge" {
        if ($Udid) { @("forward", "$LocalPort", "$DevicePort", "--udid", $Udid) } else { @("forward", "$LocalPort", "$DevicePort") }
    }
}

$fwdProc = $null
$singProc = $null

try {
    $fwdProc = Start-Process -FilePath $fwd.Path -ArgumentList $fwdArgs -PassThru -NoNewWindow

    # 포워더 포트 대기
    $ready = $false
    for ($i = 0; $i -lt 20; $i++) {
        if ($fwdProc.HasExited) { throw "usbmux 포워더가 비정상 종료되었습니다 (ExitCode=$($fwdProc.ExitCode))." }
        if (Test-PortOpen -TargetHost "127.0.0.1" -Port $LocalPort) {
            $ready = $true
            break
        }
        Start-Sleep -Milliseconds 250
    }
    if (-not $ready) {
        throw "127.0.0.1:$LocalPort 포트가 열리지 않았습니다."
    }
    Write-Host "  usbmux 포트 준비 완료 (PID=$($fwdProc.Id))" -ForegroundColor Green

    # TUN 어댑터로 PC 기본 경로를 넘기기 전에 아이폰 USBProxy SOCKS5 응답을 먼저 검증
    $probe = Test-Socks5Handshake -TargetHost "127.0.0.1" -Port $LocalPort
    if (-not $probe.Ok) {
        if ($SocksOnly) {
            Write-Warning "아이폰 SOCKS5 응답 확인 실패: $($probe.Reason)"
        } else {
            throw "아이폰 USBProxy SOCKS5 응답 확인 실패: $($probe.Reason)`n-> 아이폰 USBProxy 앱에서 '대기 및 중계 중' 상태인지 확인하고, 포트 충돌 시 앱에서 포트를 10808로 바꾼 뒤 '-DevicePort 10808'로 다시 실행하세요."
        }
    } else {
        Write-Host "  [OK] 아이폰 USBProxy SOCKS5 핸드셰이크 정상 응답 확인 (iPhone:$DevicePort)" -ForegroundColor Green
    }

    if ($SocksOnly) {
        Write-Host "`n[SOCKS5 전용 모드 실행 중] 127.0.0.1:$LocalPort (Ctrl+C로 종료)" -ForegroundColor Yellow
        Write-Host "  테스트 명령: curl.exe --socks5-hostname 127.0.0.1:$LocalPort https://ifconfig.me"
        while (-not $fwdProc.HasExited) {
            Start-Sleep -Milliseconds 500
        }
        return
    }

    Write-Host "[3/4] sing-box 설정 검증: $ConfigPath" -ForegroundColor Cyan
    & $SingBoxExe check -c $ConfigPath
    if ($LASTEXITCODE -ne 0) { throw "sing-box 설정 검증 실패" }

    Write-Host "[4/4] sing-box TUN 모드 시작 (Mode=$Mode, Ctrl+C로 종료 및 네트워크 원복)..." -ForegroundColor Green
    $singProc = Start-Process -FilePath $SingBoxExe -ArgumentList @("run", "-c", $ConfigPath) -PassThru -NoNewWindow
    $singProc.WaitForExit()
}
finally {
    Write-Host "`n[정리] 프로세스 종료 및 Windows 네트워크 경로 원복 확인..." -ForegroundColor Yellow

    if ($singProc -and -not $singProc.HasExited) {
        try { Stop-Process -Id $singProc.Id -Force -ErrorAction SilentlyContinue } catch {}
        $singProc.WaitForExit(3000) | Out-Null
    }
    if ($fwdProc -and -not $fwdProc.HasExited) {
        try { Stop-Process -Id $fwdProc.Id -Force -ErrorAction SilentlyContinue } catch {}
        $fwdProc.WaitForExit(3000) | Out-Null
    }

    Start-Sleep -Milliseconds 500
    $tunLeft = Get-NetAdapter -Name "USBProxyTUN" -ErrorAction SilentlyContinue
    if ($tunLeft) {
        Write-Warning "USBProxyTUN 어댑터가 아직 정리 중입니다. 잠시 후 자동 해제됩니다."
    } else {
        Write-Host "  [OK] USBProxyTUN 어댑터 정상 해제됨" -ForegroundColor Green
    }

    $afterRoutes = Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
        Select-Object InterfaceAlias, NextHop, RouteMetric
    if ($afterRoutes) {
        Write-Host "  현재 기본 경로:" -ForegroundColor Cyan
        $afterRoutes | Format-Table -AutoSize
    } elseif ($beforeRoutes) {
        Write-Host "  종료 전과 동일하게 기존 기본 경로가 복원되었습니다." -ForegroundColor Green
    } else {
        Write-Host "  오프라인(USB 전용) 상태로 정상 복귀했습니다." -ForegroundColor Green
    }
}
