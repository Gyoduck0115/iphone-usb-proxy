import SwiftUI

/// Main screen modeled after `viktor-svirsky/tether/Sources/MainView.swift`:
/// Status orb + live traffic card, active connections, cellular exit status, mode selector,
/// wake-lock & keep-alive controls, and diagnostics sheet.
struct MainView: View {
    @ObservedObject private var model = ProxyModel.shared
    @State private var showDiagnostics = false

    var body: some View {
        NavigationStack {
            List {
                // Header
                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("USBProxy")
                                .font(.system(.largeTitle, design: .rounded, weight: .heavy))
                            Text("127.0.0.1:\(String(model.snapshot.listenPort)) · usbmux")
                                .font(.subheadline.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { showDiagnostics = true } label: {
                            Image(systemName: "waveform.path.ecg")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(Color.primary)
                                .frame(width: 44, height: 44)
                                .background(Color(.secondarySystemGroupedBackground), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("진단 및 로그")
                    }
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())

                // Status Card (tether-style orb + live speeds + Start/Stop)
                Section {
                    ProxyStatusCard(model: model)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())

                // 7-day free Apple ID sideload warning (from tether's AppExpiry)
                if let warning = model.expiryWarning {
                    Section {
                        Label {
                            Text(warning)
                                .font(.subheadline)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                }

                // Error banner
                if let err = model.errorMessage ?? model.snapshot.lastError {
                    Section {
                        Label {
                            Text(err)
                                .font(.subheadline)
                        } icon: {
                            Image(systemName: "exclamationmark.circle.fill")
                                .foregroundStyle(.red)
                        }
                    }
                }

                // Live Metrics
                Section("실시간 상태") {
                    LabeledContent("활성 TCP 연결") {
                        Text("\(model.snapshot.activeTCPConnections) / \(model.config.maxConnections)")
                            .monospacedDigit()
                    }
                    LabeledContent("활성 UDP(UoT) 스트림 / 플로우") {
                        Text("\(model.snapshot.activeUDPStreams) / \(model.snapshot.activeUDPFlows)")
                            .monospacedDigit()
                    }
                    LabeledContent("누적 송신 (업로드)") {
                        Text(ProxyFormat.bytes(model.snapshot.traffic.bytesUp))
                            .monospacedDigit()
                    }
                    LabeledContent("누적 수신 (다운로드)") {
                        Text(ProxyFormat.bytes(model.snapshot.traffic.bytesDown))
                            .monospacedDigit()
                    }
                    LabeledContent("셀룰러 인터페이스") {
                        Text(model.cellularStatus.summary)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("메모리 사용량") {
                        let mem = ProxyFormat.memoryMB(model.snapshot.memoryUsageBytes)
                        let suffix = model.runMode == .packetTunnel ? " / 50 MB" : ""
                        Text(mem + suffix)
                            .monospacedDigit()
                            .foregroundStyle(
                                model.runMode == .packetTunnel && model.snapshot.memoryUsageBytes > 35 * 1024 * 1024
                                ? Color.orange : Color.secondary
                            )
                    }
                }

                // Run Mode & Options
                Section("실행 모드 및 설정") {
                    Picker("백그라운드 방식", selection: $model.runMode) {
                        ForEach(ProxyRunMode.allCases, id: \.self) { mode in
                            Text(mode == .inApp ? "앱 내 (무음 오디오)" : "Packet Tunnel (VPN)")
                                .tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text(model.runMode.subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Toggle("셀룰러 인터페이스 고정 (Wi-Fi 무시)", isOn: $model.config.requireCellular)
                        .disabled(model.isRunning)

                    Toggle("UDP-over-TCP (UoT v1/v2) 지원", isOn: $model.config.enableUDP)
                        .disabled(model.isRunning)

                    Toggle("실행 중 화면 꺼짐 방지", isOn: $model.preventScreenSleep)

                    if model.runMode == .inApp {
                        Toggle("무음 오디오 백그라운드 유지", isOn: $model.keepAliveAudioEnabled)
                        Picker("유휴 자동 중지", selection: $model.idleStopTimeout) {
                            ForEach(IdleStopPolicy.Timeout.allCases, id: \.self) { item in
                                Text(item.label).tag(item)
                            }
                        }
                    }
                }

                Section("PC 연결 명령 (Windows)") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("1. USB 포트 포워딩 + sing-box 실행")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(".\\pc\\scripts\\start-proxy.ps1 -Mode uot")
                            .font(.caption.monospaced())
                            .textSelection(.enabled)

                        Text("2. 0/1단계 단독 출구 IP 테스트")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                        Text("curl --socks5-hostname 127.0.0.1:1080 https://ifconfig.me")
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("USBProxy")
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showDiagnostics) {
                DiagnosticsView(model: model)
            }
        }
    }
}

private struct ProxyStatusCard: View {
    @ObservedObject var model: ProxyModel
    @Environment(\.colorScheme) private var colorScheme

    private enum OrbLook { case active, stopped, problem }

    private var look: OrbLook {
        if model.isRunning && model.snapshot.listening { return .active }
        if model.errorMessage != nil { return .problem }
        return .stopped
    }

    private var statusTitle: String {
        if model.isRunning && model.snapshot.listening { return "대기 및 중계 중" }
        if model.isRunning { return "시작 중…" }
        return "중지됨"
    }

    private var statusSubtitle: String {
        if model.isRunning && model.snapshot.listening {
            let modeLabel = model.runMode == .packetTunnel
                ? "Packet Tunnel 확장"
                : (model.audioKeepAliveActive ? "무음 오디오 백그라운드 활성" : "포그라운드 실행")
            return "\(modeLabel) · 연결 \(model.snapshot.activeConnections)개"
        }
        return "USB 케이블로 PC와 연결 후 시작하세요"
    }

    private static let activeGradient = [
        Color(red: 0.12, green: 0.40, blue: 0.94),
        Color(red: 0.08, green: 0.74, blue: 0.75)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(colors: Self.activeGradient, startPoint: .topLeading, endPoint: .bottomTrailing))
                        .opacity(look == .active ? 1 : 0)
                    Circle()
                        .fill(Color(.systemGray5))
                        .opacity(look == .stopped ? 1 : 0)
                    Circle()
                        .fill(Color.orange.opacity(0.2))
                        .opacity(look == .problem ? 1 : 0)
                    Image(systemName: "cable.connector.horizontal")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(
                            look == .active ? AnyShapeStyle(.white)
                            : look == .problem ? AnyShapeStyle(.orange)
                            : AnyShapeStyle(.secondary)
                        )
                }
                .frame(width: 74, height: 74)
                .animation(.easeInOut(duration: 0.25), value: look)

                VStack(alignment: .leading, spacing: 4) {
                    Text(statusTitle)
                        .font(.system(.title2, design: .rounded, weight: .bold))
                    Text(statusSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            if model.isRunning {
                Divider()
                HStack(spacing: 18) {
                    Label(ProxyFormat.speed(model.downSpeedBps), systemImage: "arrow.down")
                        .foregroundStyle(Color.accentColor)
                    Label(ProxyFormat.speed(model.upSpeedBps), systemImage: "arrow.up")
                        .foregroundStyle(Color.teal)
                }
                .font(.headline.monospacedDigit())
            }

            Button {
                Task { await model.toggleProxy() }
            } label: {
                Text(model.isRunning ? "프록시 중지" : "프록시 시작")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(model.isRunning ? .red : .accentColor)
        }
        .padding(18)
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
                .shadow(color: .black.opacity(colorScheme == .dark ? 0 : 0.07), radius: 12, y: 5)
        }
    }
}
