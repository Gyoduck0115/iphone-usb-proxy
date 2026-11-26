import AppIntents

/// Shortcuts / Siri / Action Button intents (inspired by `viktor-svirsky/tether/Sources/Shortcuts.swift`).
struct StartUSBProxyIntent: AppIntent {
    static var title: LocalizedStringResource = "USBProxy 시작"
    static var description = IntentDescription("아이폰 127.0.0.1:1080 셀룰러 SOCKS5/UoT 프록시를 시작합니다.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> & ProvidesDialog {
        let model = ProxyModel.shared
        await model.startProxy()
        let ok = model.isRunning
        let msg = ok
            ? "USBProxy가 127.0.0.1:\(model.config.listenPort)에서 대기 중입니다."
            : "USBProxy를 시작하지 못했습니다."
        return .result(value: ok, dialog: IntentDialog(stringLiteral: msg))
    }
}

struct StopUSBProxyIntent: AppIntent {
    static var title: LocalizedStringResource = "USBProxy 중지"
    static var description = IntentDescription("실행 중인 USBProxy 서버를 중지합니다.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        ProxyModel.shared.stopProxy()
        return .result(dialog: IntentDialog("USBProxy를 중지했습니다."))
    }
}

struct USBProxyStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "USBProxy 상태 확인"
    static var description = IntentDescription("USBProxy 실행 여부와 활성 연결 수를 확인합니다.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> & ProvidesDialog {
        let model = ProxyModel.shared
        let snap = model.snapshot
        let text = snap.listening
            ? "실행 중 (활성 연결 \(snap.activeConnections)개, 누적 \(ProxyFormat.bytes(snap.traffic.total)))"
            : "중지됨"
        return .result(value: snap.listening, dialog: IntentDialog(stringLiteral: text))
    }
}

struct USBProxyShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartUSBProxyIntent(),
            phrases: ["Start \(.applicationName)", "\(.applicationName) 시작"],
            shortTitle: "USBProxy 시작",
            systemImageName: "cable.connector.horizontal"
        )
        AppShortcut(
            intent: StopUSBProxyIntent(),
            phrases: ["Stop \(.applicationName)", "\(.applicationName) 중지"],
            shortTitle: "USBProxy 중지",
            systemImageName: "stop.circle"
        )
        AppShortcut(
            intent: USBProxyStatusIntent(),
            phrases: ["\(.applicationName) status", "\(.applicationName) 상태"],
            shortTitle: "USBProxy 상태",
            systemImageName: "info.circle"
        )
    }
}
