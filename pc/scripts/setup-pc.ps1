<#
.SYNOPSIS
    0단계 PC 준비 스크립트: Apple Devices/iTunes(usbmuxd), sing-box, UsbMuxBridge 설치 및 설정 검증.
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

Write-Host "=== 1. Apple Mobile Device Service (usbmuxd) 확인 ===" -ForegroundColor Cyan
$appleApps = Get-AppxPackage -Name "*Apple*" -ErrorAction SilentlyContinue
if ($appleApps) {
    $appleApps | ForEach-Object { Write-Host "  설치됨: $($_.Name) ($($_.Version))" -ForegroundColor Green }
} else {
    Write-Warning "Apple Devices 또는 iTunes 앱이 감지되지 않았습니다. Microsoft Store에서 'Apple Devices'를 설치하세요."
}

$muxListen = Get-NetTCPConnection -LocalPort 27015 -State Listen -ErrorAction SilentlyContinue
if ($muxListen) {
    Write-Host "  usbmuxd 포트(127.0.0.1:27015) 정상 대기 중 (PID=$($muxListen[0].OwningProcess))" -ForegroundColor Green
} else {
    Write-Warning "usbmuxd(127.0.0.1:27015)가 대기 중이 아닙니다. Apple Devices 또는 iTunes를 한 번 실행하세요."
}

Write-Host "`n=== 2. sing-box (Windows amd64) 설치 확인 ===" -ForegroundColor Cyan
$singBoxExe = Join-Path $BinDir "sing-box.exe"
if (-not (Test-Path $singBoxExe) -and -not $SkipDownload) {
    $apiUrl = if ($SingBoxVersion -eq "latest") {
        "https://api.github.com/repos/SagerNet/sing-box/releases/latest"
    } else {
        "https://api.github.com/repos/SagerNet/sing-box/releases/tags/$SingBoxVersion"
    }
    Write-Host "  GitHub 릴리스 조회 중: $apiUrl"
    $rel = Invoke-RestMethod -Uri $apiUrl
    $asset = $rel.assets | Where-Object { $_.name -match '^sing-box-.*-windows-amd64\.zip$' -and $_.name -notmatch 'legacy' } | Select-Object -First 1
    if (-not $asset) {
        throw "windows-amd64 sing-box 에셋을 찾을 수 없습니다."
    }
    $zipPath = Join-Path $BinDir $asset.name
    Write-Host "  다운로드 중: $($asset.name)"
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zipPath
    $extractTmp = Join-Path $BinDir "_extract_singbox"
    if (Test-Path $extractTmp) { Remove-Item -Recurse -Force $extractTmp }
    Expand-Archive -Path $zipPath -DestinationPath $extractTmp -Force
    $foundExe = Get-ChildItem -Path $extractTmp -Recurse -Filter "sing-box.exe" | Select-Object -First 1
    if (-not $foundExe) { throw "압축 해제 후 sing-box.exe를 찾지 못했습니다." }
    Copy-Item -Path $foundExe.FullName -Destination $singBoxExe -Force
    Remove-Item -Recurse -Force $extractTmp
    Remove-Item -Force $zipPath
    Write-Host "  설치 완료: $singBoxExe" -ForegroundColor Green
} elseif (Test-Path $singBoxExe) {
    Write-Host "  이미 설치됨: $singBoxExe" -ForegroundColor Green
}

if (Test-Path $singBoxExe) {
    & $singBoxExe version
    Write-Host "  설정 파일 문법 검증(sing-box check)..." -ForegroundColor Cyan
    & $singBoxExe check -c (Join-Path $ConfigDir "sing-box-tcp.json")
    if ($LASTEXITCODE -ne 0) { throw "sing-box-tcp.json 검증 실패" }
    Write-Host "    [OK] sing-box-tcp.json" -ForegroundColor Green

    & $singBoxExe check -c (Join-Path $ConfigDir "sing-box-uot.json")
    if ($LASTEXITCODE -ne 0) { throw "sing-box-uot.json 검증 실패" }
    Write-Host "    [OK] sing-box-uot.json" -ForegroundColor Green
}

Write-Host "`n=== 3. USB 포워딩 도구 (iproxy / pymobiledevice3 / UsbMuxBridge) 확인 ===" -ForegroundColor Cyan
$iproxy = Get-Command "iproxy" -ErrorAction SilentlyContinue
if ($iproxy) {
    Write-Host "  iproxy 발견: $($iproxy.Source)" -ForegroundColor Green
} else {
    Write-Host "  iproxy 미설치 -> 내장 .NET UsbMuxBridge를 빌드하여 기본 포워더로 준비합니다." -ForegroundColor Yellow
}

$dotnet = Get-Command "dotnet" -ErrorAction SilentlyContinue
if ($dotnet) {
    $bridgeOut = Join-Path $BinDir "UsbMuxBridge"
    Write-Host "  UsbMuxBridge 빌드 중..."
    & dotnet build $BridgeProj -c Release -o $bridgeOut --nologo -v minimal
    if ($LASTEXITCODE -ne 0) { throw "UsbMuxBridge 빌드 실패" }
    Write-Host "  빌드 완료: $(Join-Path $bridgeOut 'UsbMuxBridge.exe')" -ForegroundColor Green
} else {
    Write-Warning ".NET SDK가 없습니다. iproxy.exe를 pc\bin 또는 PATH에 배치하거나 .NET SDK를 설치하세요."
}

Write-Host "`n=== 준비 완료 ===" -ForegroundColor Green
Write-Host "다음 명령으로 실행하세요:"
Write-Host "  1) 0/1단계 SOCKS5 단독 검증: .\pc\scripts\start-proxy.ps1 -SocksOnly"
Write-Host "  2) 3단계 전체 TUN + UDP(UoT): .\pc\scripts\start-proxy.ps1 -Mode uot  (관리자 PowerShell)"
