<#
.SYNOPSIS
    Stage 0 Windows PC setup: checks Apple usbmuxd, downloads sing-box, builds UsbMuxBridge, validates configs.
.EXAMPLE
    .\pc\scripts\setup-pc.ps1
#>
[CmdletBinding()]
param(
    [string]$SingBoxVersion = "latest",
    [switch]$SkipDownload
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$BinDir = Join-Path $ProjectRoot "pc\bin"
$ConfigDir = Join-Path $ProjectRoot "pc\config"
$BridgeProj = Join-Path $ProjectRoot "pc\tools\UsbMuxBridge\UsbMuxBridge.csproj"

New-Item -ItemType Directory -Force -Path $BinDir | Out-Null

Write-Host "=== 1. Checking Apple Mobile Device Service (usbmuxd) ===" -ForegroundColor Cyan
$appleApps = Get-AppxPackage -Name "*Apple*" -ErrorAction SilentlyContinue
if ($appleApps) {
    $appleApps | ForEach-Object { Write-Host "  Installed: $($_.Name) ($($_.Version))" -ForegroundColor Green }
} else {
    Write-Warning "Apple Devices or iTunes was not detected. Install 'Apple Devices' from Microsoft Store."
}

$muxListen = Get-NetTCPConnection -LocalPort 27015 -State Listen -ErrorAction SilentlyContinue
if ($muxListen) {
    Write-Host "  usbmuxd listening on 127.0.0.1:27015 (PID=$($muxListen[0].OwningProcess))" -ForegroundColor Green
} else {
    Write-Warning "usbmuxd (127.0.0.1:27015) is not listening. Launch Apple Devices or iTunes once."
}

Write-Host "`n=== 2. Checking sing-box (Windows amd64) ===" -ForegroundColor Cyan
$singBoxExe = Join-Path $BinDir "sing-box.exe"
if (-not (Test-Path $singBoxExe) -and -not $SkipDownload) {
    $apiUrl = if ($SingBoxVersion -eq "latest") {
        "https://api.github.com/repos/SagerNet/sing-box/releases/latest"
    } else {
        "https://api.github.com/repos/SagerNet/sing-box/releases/tags/$SingBoxVersion"
    }
    Write-Host "  Querying GitHub release: $apiUrl"
    $rel = Invoke-RestMethod -Uri $apiUrl
    $asset = $rel.assets | Where-Object { $_.name -match '^sing-box-.*-windows-amd64\.zip$' -and $_.name -notmatch 'legacy' } | Select-Object -First 1
    if (-not $asset) {
        throw "Could not find windows-amd64 sing-box release asset."
    }
    $zipPath = Join-Path $BinDir $asset.name
    Write-Host "  Downloading: $($asset.name)"
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zipPath
    $extractTmp = Join-Path $BinDir "_extract_singbox"
    if (Test-Path $extractTmp) { Remove-Item -Recurse -Force $extractTmp }
    Expand-Archive -Path $zipPath -DestinationPath $extractTmp -Force
    $foundExe = Get-ChildItem -Path $extractTmp -Recurse -Filter "sing-box.exe" | Select-Object -First 1
    if (-not $foundExe) { throw "sing-box.exe not found after extracting archive." }
    Copy-Item -Path $foundExe.FullName -Destination $singBoxExe -Force
    Remove-Item -Recurse -Force $extractTmp
    Remove-Item -Force $zipPath
    Write-Host "  Installed: $singBoxExe" -ForegroundColor Green
} elseif (Test-Path $singBoxExe) {
    Write-Host "  Already installed: $singBoxExe" -ForegroundColor Green
}

if (Test-Path $singBoxExe) {
    & $singBoxExe version
    Write-Host "  Validating configs (sing-box check)..." -ForegroundColor Cyan
    & $singBoxExe check -c (Join-Path $ConfigDir "sing-box-tcp.json")
    if ($LASTEXITCODE -ne 0) { throw "sing-box-tcp.json validation failed" }
    Write-Host "    [OK] sing-box-tcp.json" -ForegroundColor Green

    & $singBoxExe check -c (Join-Path $ConfigDir "sing-box-uot.json")
    if ($LASTEXITCODE -ne 0) { throw "sing-box-uot.json validation failed" }
    Write-Host "    [OK] sing-box-uot.json" -ForegroundColor Green
}

Write-Host "`n=== 3. Checking USB forwarder (iproxy / pymobiledevice3 / UsbMuxBridge) ===" -ForegroundColor Cyan
$iproxy = Get-Command "iproxy" -ErrorAction SilentlyContinue
if ($iproxy) {
    Write-Host "  Found iproxy: $($iproxy.Source)" -ForegroundColor Green
} else {
    Write-Host "  iproxy not found -> building built-in .NET UsbMuxBridge." -ForegroundColor Yellow
}

$dotnet = Get-Command "dotnet" -ErrorAction SilentlyContinue
if ($dotnet) {
    $bridgeOut = Join-Path $BinDir "UsbMuxBridge"
    Write-Host "  Building UsbMuxBridge..."
    & dotnet build $BridgeProj -c Release -o $bridgeOut --nologo -v minimal
    if ($LASTEXITCODE -ne 0) { throw "UsbMuxBridge build failed" }
    Write-Host "  Built: $(Join-Path $bridgeOut 'UsbMuxBridge.exe')" -ForegroundColor Green
} else {
    Write-Warning ".NET SDK not found. Place iproxy.exe in pc\bin or PATH, or install .NET SDK."
}

Write-Host "`n=== Setup Complete ===" -ForegroundColor Green
Write-Host "Next steps:"
Write-Host "  1) SOCKS5-only test:      .\pc\scripts\start-proxy.ps1 -SocksOnly -DevicePort 10808"
Write-Host "  2) Full TUN + UDP (UoT):  .\pc\scripts\start-proxy.ps1 -Mode uot -DevicePort 10808  (Admin PowerShell)"
