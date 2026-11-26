<#
.SYNOPSIS
    iPhone USB Proxy launcher (Stage 3):
    Detects USB iPhone -> auto-detects active USBProxy SOCKS5 port -> starts usbmux forwarder -> runs sing-box TUN -> restores routes on exit.
.EXAMPLE
    .\pc\scripts\start-proxy.ps1
    .\pc\scripts\start-proxy.ps1 -Mode uot -DevicePort 10808
    .\pc\scripts\start-proxy.ps1 -Mode tcp
    .\pc\scripts\start-proxy.ps1 -SocksOnly
#>
[CmdletBinding()]
param(
    [ValidateSet("uot", "tcp")]
    [string]$Mode = "uot",

    [int]$LocalPort = 1080,

    # 0 = auto-detect active USBProxy SOCKS5 port on iPhone (checks 1080, 10808, 18080, 21080)
    [int]$DevicePort = 0,

    [ValidateSet("auto", "iproxy", "pymobiledevice3", "bridge")]
    [string]$Forwarder = "auto",

    [string]$Udid = "",

    # Open usbmux SOCKS5 port (127.0.0.1:1080) without starting sing-box TUN (no Admin needed)
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

function Ensure-LocalPortFree([int]$Port) {
    $listeners = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    foreach ($c in $listeners) {
        $proc = Get-Process -Id $c.OwningProcess -ErrorAction SilentlyContinue
        if ($proc -and ($proc.ProcessName -in @("UsbMuxBridge", "iproxy"))) {
            Write-Host "  Stopping stale $($proc.ProcessName) (PID=$($proc.Id)) holding 127.0.0.1:$Port..." -ForegroundColor Yellow
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 300
        } else {
            $pname = if ($proc) { $proc.ProcessName } else { "unknown" }
            throw "Local port 127.0.0.1:$Port is already in use by '$pname' (PID=$($c.OwningProcess)). Stop it or pass -LocalPort."
        }
    }
}

function Find-DeviceSocks5Port([int]$DeviceId, [int[]]$CandidatePorts) {
    if (-not ("UsbMuxSocksProbe" -as [type])) {
        $probeCode = @'
using System;
using System.Net;
using System.Net.Sockets;
using System.Text;

public static class UsbMuxSocksProbe {
    public static bool IsSocks5Ready(int deviceId, ushort port) {
        try {
            using (var tcp = new TcpClient()) {
                tcp.Connect(IPAddress.Loopback, 27015);
                tcp.ReceiveTimeout = 2000;
                tcp.SendTimeout = 2000;
                var s = tcp.GetStream();
                ushort swapped = (ushort)(((port & 0xff) << 8) | (port >> 8));
                string xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\"><plist version=\"1.0\"><dict><key>BundleID</key><string>com.local.usbproxy</string><key>ClientVersionString</key><string>1.0</string><key>DeviceID</key><integer>" + deviceId + "</integer><key>MessageType</key><string>Connect</string><key>PortNumber</key><integer>" + swapped + "</integer><key>ProgName</key><string>start-proxy</string></dict></plist>";
                byte[] payload = Encoding.UTF8.GetBytes(xml);
                byte[] hdr = new byte[16];
                BitConverter.GetBytes((uint)(16 + payload.Length)).CopyTo(hdr, 0);
                BitConverter.GetBytes((uint)1).CopyTo(hdr, 4);
                BitConverter.GetBytes((uint)8).CopyTo(hdr, 8);
                BitConverter.GetBytes((uint)1).CopyTo(hdr, 12);
                s.Write(hdr, 0, 16);
                s.Write(payload, 0, payload.Length);

                byte[] rhdr = new byte[16];
                int off = 0; while (off < 16) { int n = s.Read(rhdr, off, 16 - off); if (n == 0) return false; off += n; }
                uint len = BitConverter.ToUInt32(rhdr, 0);
                if (len < 16 || len > 1048576) return false;
                byte[] rbody = new byte[len - 16];
                off = 0; while (off < rbody.Length) { int n = s.Read(rbody, off, rbody.Length - off); if (n == 0) return false; off += n; }
                string reply = Encoding.UTF8.GetString(rbody);
                if (!reply.Contains("<integer>0</integer>")) return false;

                s.Write(new byte[] { 0x05, 0x01, 0x00 }, 0, 3);
                byte[] g = new byte[2];
                int gn = s.Read(g, 0, 2);
                return (gn == 2 && g[0] == 0x05 && g[1] == 0x00);
            }
        } catch {
            return false;
        }
    }
}
'@
        Add-Type -TypeDefinition $probeCode
    }
    foreach ($p in $CandidatePorts) {
        if ([UsbMuxSocksProbe]::IsSocks5Ready($DeviceId, [uint16]$p)) {
            return $p
        }
    }
    return 0
}

function Test-Socks5Handshake([string]$TargetHost, [int]$Port) {
    $tcp = New-Object System.Net.Sockets.TcpClient
    try {
        $tcp.ReceiveTimeout = 2500
        $tcp.SendTimeout = 2500
        $ar = $tcp.BeginConnect($TargetHost, $Port, $null, $null)
        if (-not $ar.AsyncWaitHandle.WaitOne(1500)) {
            return @{ Ok = $false; Reason = "Timed out connecting to local port $Port" }
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
            return @{ Ok = $false; Reason = "iPhone port $DevicePort closed immediately (USBProxy stopped or another app owns port $DevicePort)" }
        }
        return @{ Ok = $false; Reason = "iPhone port $DevicePort did not return SOCKS5 reply (got bytes: $($buf[0]), $($buf[1]))" }
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
            if (-not $iproxyCmd) { throw "iproxy was not found." }
            return @{ Kind = "iproxy"; Path = $iproxyCmd.Source }
        }
        "pymobiledevice3" {
            if (-not $pyCmd) { throw "pymobiledevice3 was not found." }
            return @{ Kind = "pymobiledevice3"; Path = $pyCmd.Source }
        }
        "bridge" {
            if (-not $hasBridge) { throw "UsbMuxBridge.exe not found. Run .\pc\scripts\setup-pc.ps1 first." }
            return @{ Kind = "bridge"; Path = $BridgeExe }
        }
        default {
            if ($iproxyCmd) { return @{ Kind = "iproxy"; Path = $iproxyCmd.Source } }
            if ($hasBridge) { return @{ Kind = "bridge"; Path = $BridgeExe } }
            if ($pyCmd) { return @{ Kind = "pymobiledevice3"; Path = $pyCmd.Source } }
            throw "No usbmux forwarder found (iproxy / UsbMuxBridge / pymobiledevice3). Run setup-pc.ps1 first."
        }
    }
}

# 1. Admin check (required for Wintun TUN adapter)
if (-not $SocksOnly -and -not (Test-IsAdmin)) {
    throw "Administrator privileges are required for TUN mode (Wintun). Re-run in an Admin PowerShell or pass -SocksOnly."
}

if (-not $SocksOnly -and -not (Test-Path $SingBoxExe)) {
    throw "sing-box.exe not found at $SingBoxExe. Run .\pc\scripts\setup-pc.ps1 first."
}

# 2. Check usbmuxd and detect USB iPhone
$muxListen = Get-NetTCPConnection -LocalPort 27015 -State Listen -ErrorAction SilentlyContinue
if (-not $muxListen) {
    throw "Apple Mobile Device Service (127.0.0.1:27015) is not listening. Check Apple Devices or iTunes."
}

$targetDeviceId = 0
if (Test-Path $BridgeExe) {
    Write-Host "[1/4] Detecting USB-connected iPhone..." -ForegroundColor Cyan
    $devJson = & $BridgeExe devices --json
    $devices = $devJson | ConvertFrom-Json
    $usbDevices = @($devices | Where-Object { $_.ConnectionType -eq "USB" })
    if ($usbDevices.Count -eq 0) {
        throw "No USB iPhone detected. Check your data cable, unlock the iPhone, and tap 'Trust This Computer'."
    }
    $selected = if ($Udid) {
        $usbDevices | Where-Object { $_.SerialNumber -eq $Udid } | Select-Object -First 1
    } else {
        $usbDevices | Select-Object -First 1
    }
    if (-not $selected) {
        throw "No USB iPhone matching UDID '$Udid' was found."
    }
    $targetDeviceId = [int]$selected.DeviceId
    Write-Host "  Detected: DeviceID=$($selected.DeviceId), Serial=$($selected.SerialNumber)" -ForegroundColor Green
}

# Auto-detect active USBProxy SOCKS5 port if -DevicePort was not specified
if ($DevicePort -le 0) {
    if ($targetDeviceId -gt 0) {
        $detectedPort = Find-DeviceSocks5Port -DeviceId $targetDeviceId -CandidatePorts @(1080, 10808, 18080, 21080)
        if ($detectedPort -gt 0) {
            $DevicePort = $detectedPort
            Write-Host "  Auto-detected active USBProxy SOCKS5 on iPhone:$DevicePort" -ForegroundColor Green
        } else {
            throw "USBProxy SOCKS5 did not answer on iPhone ports 1080, 10808, 18080, or 21080. Start USBProxy on the iPhone first (or pass -DevicePort explicitly)."
        }
    } else {
        $DevicePort = 1080
    }
}

# Clean up stale UsbMuxBridge/iproxy holding LocalPort before starting a new forwarder
Ensure-LocalPortFree -Port $LocalPort

# 3. Capture pre-start default routes
$beforeRoutes = Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
    Select-Object InterfaceAlias, NextHop, RouteMetric

$fwd = Resolve-Forwarder -Preference $Forwarder
Write-Host "[2/4] Starting usbmux forwarder ($($fwd.Kind)): 127.0.0.1:$LocalPort -> iPhone:$DevicePort" -ForegroundColor Cyan

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

    $ready = $false
    for ($i = 0; $i -lt 20; $i++) {
        if ($fwdProc.HasExited) { throw "usbmux forwarder exited unexpectedly (ExitCode=$($fwdProc.ExitCode))." }
        if (Test-PortOpen -TargetHost "127.0.0.1" -Port $LocalPort) {
            $ready = $true
            break
        }
        Start-Sleep -Milliseconds 250
    }
    if (-not $ready) {
        throw "Local port 127.0.0.1:$LocalPort did not open."
    }
    Write-Host "  usbmux forwarder ready (PID=$($fwdProc.Id))" -ForegroundColor Green

    # Verify iPhone USBProxy SOCKS5 handshake BEFORE switching Windows default route to TUN
    $probe = Test-Socks5Handshake -TargetHost "127.0.0.1" -Port $LocalPort
    if (-not $probe.Ok) {
        if ($SocksOnly) {
            Write-Warning "iPhone SOCKS5 handshake check failed: $($probe.Reason)"
        } else {
            throw "iPhone USBProxy SOCKS5 check failed: $($probe.Reason)`n-> Confirm USBProxy is listening on iPhone:$DevicePort. If port 1080 conflicts, switch to 10808 in the iPhone app."
        }
    } else {
        Write-Host "  [OK] iPhone USBProxy SOCKS5 handshake succeeded (iPhone:$DevicePort)" -ForegroundColor Green
    }

    if ($SocksOnly) {
        Write-Host "`n[SOCKS5-only mode active] 127.0.0.1:$LocalPort -> iPhone:$DevicePort (press Ctrl+C to stop)" -ForegroundColor Yellow
        Write-Host "  Test command: curl.exe --socks5-hostname 127.0.0.1:$LocalPort https://ifconfig.me"
        while (-not $fwdProc.HasExited) {
            Start-Sleep -Milliseconds 500
        }
        return
    }

    Write-Host "[3/4] Validating sing-box config: $ConfigPath" -ForegroundColor Cyan
    & $SingBoxExe check -c $ConfigPath
    if ($LASTEXITCODE -ne 0) { throw "sing-box config check failed" }

    Write-Host "[4/4] Starting sing-box TUN mode (Mode=$Mode, press Ctrl+C to stop and restore routes)..." -ForegroundColor Green
    $singProc = Start-Process -FilePath $SingBoxExe -ArgumentList @("run", "-c", $ConfigPath) -PassThru -NoNewWindow
    $singProc.WaitForExit()
}
finally {
    Write-Host "`n[Cleanup] Stopping processes and verifying Windows route restoration..." -ForegroundColor Yellow

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
        Write-Warning "USBProxyTUN adapter is still tearing down; it should clear shortly."
    } else {
        Write-Host "  [OK] USBProxyTUN adapter removed cleanly." -ForegroundColor Green
    }

    $afterRoutes = Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
        Select-Object InterfaceAlias, NextHop, RouteMetric
    if ($afterRoutes) {
        Write-Host "  Current default routes:" -ForegroundColor Cyan
        $afterRoutes | Format-Table -AutoSize
    } elseif ($beforeRoutes) {
        Write-Host "  Previous default routes restored." -ForegroundColor Green
    } else {
        Write-Host "  Returned cleanly to offline (USB-only) state." -ForegroundColor Green
    }
}
