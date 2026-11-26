# 아이폰 USB 프록시 테더링 (`USBProxy`)

개인용 핫스팟 없이 USB(`usbmux`)로 연결한 Windows 11 PC의 아웃바운드 트래픽을 아이폰 앱이 셀룰러로 대신 내보내는 구현체입니다.  
계획서(`iphone-usb-proxy-plan.md`)의 **0~3단계 전체**를 구현하면서 [`viktor-svirsky/tether`](https://github.com/viktor-svirsky/tether)의 실전 iOS 운영 패턴을 함께 반영했습니다.

```text
PC 앱 → TUN 어댑터(Wintun) → sing-box(TUN 모드) → 127.0.0.1:1080
      → usbmux 포워딩(iproxy / UsbMuxBridge) ══USB══ 아이폰 앱(SOCKS5 + UoT) → 셀룰러
```

## 계획서 대비 구현 매핑 및 `tether` 참조 반영 사항

| 구분 | 계획서 요구사항 | 구현 파일 / 반영 내용 |
|---|---|---|
| **0단계 (경로 검증)** | Apple Devices/iTunes, `iproxy`, `sing-box` 설치 및 로컬 SOCKS 검증 | `pc/scripts/setup-pc.ps1`, `pc/config/sing-box-tcp.json`, `pc/tools/UsbMuxBridge` (`mock-server`, `devices`, `forward`) |
| **1단계 (최소 앱)** | `127.0.0.1:1080` SOCKS5(무인증, CONNECT, IPv4/IPv6/도메인), `.cellular` 고정, 상태 표시, 화면 꺼짐 방지 | `ios/ProxyCore/SOCKS5Protocol.swift`, `ProxyServer.swift`, `ProxyStats.swift`, `ios/App/MainView.swift` |
| **2단계 (백그라운드)** | 더미 `NEPacketTunnelProvider` 확장, 앱↔확장 제어/통계 공유, 50MB 메모리 제한 대응 | `ios/TunnelExtension/PacketTunnelProvider.swift`, `ios/App/VPNTunnelController.swift`, `ios/ProxyCore/ConnectionLimiter.swift`, `SharedIPC.swift` |
| **3단계 (UDP + 사용성)** | UDP-over-TCP 프레이밍 + `sing-box` 연동 + Windows 통합 시작/종료·경로 원복 스크립트 | `ios/ProxyCore/UoTProtocol.swift`, `UoTRelay.swift` (SagerNet UoT v1/v2 완벽 호환), `pc/config/sing-box-uot.json`, `pc/scripts/start-proxy.ps1` |
| **`tether` 참조 반영** | 무료 Apple ID 백그라운드 유지, 절전/통화 후 복구, Mac 미보유 빌드, 운영 편의성 | `KeepAliveAudio.swift`(8kHz 무음 WAV 루프 + 통화/미디어 리셋 복구), `ProxyServer.ensureListening()`(소켓 자동 재오픈), `KeepAlivePolicy` + `IdleStopPolicy`, `AppExpiry`(7일 서명 만료 경고), `DebugLog` + `LogRedaction`(IP 마스킹 회전 로그), `Shortcuts`(단축어 AppIntents), `Package.swift` + `project.yml` + `scripts/build-ipa.sh` + `.github/workflows/ci.yml` |

---

## 디렉터리 구조

```text
.
├── Package.swift                      # macOS `swift test`용 순수 Swift 코어 패키지
├── project.yml                        # XcodeGen 정의 (USBProxy + USBProxyTunnel / USBProxyFree)
├── scripts/build-ipa.sh               # 무서명 IPA 생성 스크립트 (SideStore/AltStore/Feather용)
├── .github/workflows/ci.yml           # macOS 러너 CI (swift test + 양쪽 IPA 아티팩트 빌드)
├── ios/
│   ├── ProxyCore/                     # 앱·확장 공용 프록시 엔진 (SOCKS5 + UoT v1/v2 + 리미터 + 통계 + 로그)
│   ├── App/                           # SwiftUI 앱 + 무음 오디오 KeepAlive + VPN 제어 + AppIntents
│   ├── TunnelExtension/               # 2단계 더미 NEPacketTunnelProvider (50MB 메모리 압박 대응)
│   └── Tests/                         # SOCKS5 / UoT / Limiter / 루프백 통합 XCTest
└── pc/
    ├── config/
    │   ├── sing-box-tcp.json          # 0~2단계: TUN + DNS 가로채기(DoH/TCP) + SOCKS5 TCP
    │   └── sing-box-uot.json          # 3단계: TUN + DNS 가로채기 + SOCKS5 + udp_over_tcp v2
    ├── tools/UsbMuxBridge/            # .NET 내장 usbmuxd 감지·포워더(iproxy 대체) + 로컬 테스트 서버
    └── scripts/
        ├── setup-pc.ps1               # sing-box 다운로드, UsbMuxBridge 빌드, 설정 검증
        ├── start-proxy.ps1            # 아이폰 감지 -> usbmux 포워딩 -> sing-box TUN -> 종료 시 원복
        ├── stop-proxy.ps1             # 프로세스 정리 및 라우팅 원복 확인
        └── test-proxy.ps1             # 셀프테스트, SOCKS5/TUN 출구 IP 검증
```

---

## 실행 방법

### 1. Windows PC 준비 (0단계)

```powershell
.\pc\scripts\setup-pc.ps1
.\pc\scripts\test-proxy.ps1 -SelfTest
```

- `Apple Devices`(Microsoft Store) 또는 `iTunes`가 설치되어 `127.0.0.1:27015`(usbmuxd)가 대기 중이어야 합니다.
- `iproxy.exe`가 `PATH` 또는 `pc\bin\`에 있으면 `iproxy`를 우선 사용하고, 없으면 자동 빌드된 내장 `UsbMuxBridge.exe`가 Apple `usbmuxd`에 직접 접속해 포트를 포워딩합니다.

### 2. 아이폰 앱 빌드 및 설치 (1~2단계)

#### 방법 A: Mac + Xcode 보유 시
```bash
brew install xcodegen
swift test                       # ProxyCore 단위·루프백 통합 테스트
xcodegen generate
open USBProxy.xcodeproj
```
- **무료 Apple ID**: `USBProxyFree` 스킴 선택 → 앱 내 실행 + `tether` 방식 무음 오디오 백그라운드 유지 사용 (7일마다 재서명, 앱에서 3일 전 자동 경고).
- **유료 Apple 개발자 계정($99/년)**: `USBProxy` 스킴 선택 → App Group 및 Signing Team 설정 후 빌드 → 앱에서 **Packet Tunnel (VPN)** 모드 사용 가능.

#### 방법 B: Mac 미보유 시 (Windows 전용 — `tether` CI 패턴)
1. 이 폴더를 본인 GitHub 저장소에 푸시합니다.
2. GitHub Actions의 **Build & Test iOS** 워크플로가 macOS 러너에서 `swift test` 통과 후 `USBProxyFree.ipa` 및 `USBProxy.ipa` 아티팩트를 생성합니다.
3. `USBProxyFree.ipa`를 내려받아 **SideStore / AltStore / Feather**로 서명해 아이폰에 설치합니다.

### 3. 실제 연결 및 검증 (1~3단계)

1. 아이폰에서 **USBProxy** 앱 실행 → **프록시 시작** 탭 (`127.0.0.1:1080` 대기).
2. USB 데이터 케이블로 PC 연결 후 잠금 해제 및 **이 컴퓨터 신뢰** 확인.
3. **SOCKS5 단독 검증 (관리자 권한 불필요)**:
   ```powershell
   # 터미널 1
   .\pc\scripts\start-proxy.ps1 -SocksOnly
   # 터미널 2 (Wi-Fi 켠 상태에서도 셀룰러 통신사 IP가 나오면 통과)
   .\pc\scripts\test-proxy.ps1 -CheckSocks
   ```
4. **전체 트래픽 TUN + UDP(UoT v2) 실행 (관리자 PowerShell)**:
   ```powershell
   .\pc\scripts\start-proxy.ps1 -Mode uot
   ```
   - TCP 전용(0~2단계)으로 실행하려면 `-Mode tcp`를 지정합니다.
   - `Ctrl+C`로 종료하면 `sing-box`와 포워더가 정리되고 `USBProxyTUN` 어댑터 및 PC 기본 경로가 자동으로 원복됩니다.

## 주의사항

- **통신사 약관**: 모든 아웃바운드 연결이 아이폰 셀룰러에서 직접 생성되므로 테더링 제한 요금제에서는 약관 위반 소지가 있습니다. 사용 전 본인 요금제 조건을 확인하세요.
- **배터리 보호**: 장시간 USB 연결 시 iPhone 15 이상은 충전 한도 80% 설정을 권장하며, 발열이 심하면 5G 대신 LTE 고정을 권장합니다.
