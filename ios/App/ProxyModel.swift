import Foundation
import NetworkExtension
import OSLog
import SwiftUI
import UIKit

/// Main observable state container driving SwiftUI views and AppIntents Shortcuts.
/// Combines Stage 1 (in-app SOCKS5 + screen wake lock), `viktor-svirsky/tether` silent-audio
/// background keep-alive, Stage 2 (dummy Packet Tunnel extension), and Stage 3 (UoT UDP).
@MainActor
final class ProxyModel: ObservableObject {
    static let shared = ProxyModel()

    @Published var runMode: ProxyRunMode {
        didSet {
            store.saveRunMode(runMode)
            if isRunning {
                Task { await restartForModeChange() }
            }
        }
    }

    @Published var config: ProxyConfig {
        didSet {
            store.saveConfig(config)
            if !isRunning {
                snapshot.listenPort = config.listenPort
            }
        }
    }

    @Published var preventScreenSleep: Bool {
        didSet {
            store.preventScreenSleep = preventScreenSleep
            applyIdleTimer()
        }
    }

    @Published var keepAliveAudioEnabled: Bool {
        didSet {
            store.keepAliveAudioEnabled = keepAliveAudioEnabled
            syncAudioKeepAlive()
        }
    }

    @Published var idleStopTimeout: IdleStopPolicy.Timeout {
        didSet {
            store.idleStopTimeout = idleStopTimeout
        }
    }

    @Published private(set) var isRunning = false
    @Published private(set) var vpnStatus: NEVPNStatus = .invalid
    @Published private(set) var snapshot = ProxySnapshot()
    @Published private(set) var upSpeedBps: Double = 0
    @Published private(set) var downSpeedBps: Double = 0
    @Published private(set) var cellularStatus: CellularStatus = CellularProbe.current()
    @Published private(set) var expiryWarning: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var recentLogs: [String] = []
    @Published private(set) var audioKeepAliveActive = false

    private let store = SharedProxyStore()
    private let debugLog = DebugLog()
    private let logger = Logger(subsystem: "com.local.usbproxy", category: "app")
    private var localServer: ProxyServer?
    private lazy var keepAliveAudio: KeepAliveAudio = KeepAliveAudio(
        log: { [weak self] line in self?.appendLog(line) },
        onRecovered: { [weak self] in
            self?.localServer?.ensureListening()
            self?.audioKeepAliveActive = self?.keepAliveAudio.isSounding ?? false
        }
    )
    private lazy var tunnelController: VPNTunnelController = VPNTunnelController { [weak self] line in
        self?.appendLog(line)
    }

    private var sampler = TrafficSampler()
    private var idleStop = IdleStopPolicy()
    private var lastIdleCheckTraffic = TrafficTotals()
    private var pollTask: Task<Void, Never>?
    private var sceneActive = true
    private let expiresAt: Date? = AppExpiry.installed

    nonisolated static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }

    private init() {
        var initialMode = store.loadRunMode()
        if initialMode == .packetTunnel && !VPNTunnelController.isSupportedInBuild {
            initialMode = .inApp
        }
        self.runMode = initialMode
        self.config = store.loadConfig(default: .appDefault)
        self.snapshot.listenPort = self.config.listenPort
        self.preventScreenSleep = store.preventScreenSleep
        self.keepAliveAudioEnabled = store.keepAliveAudioEnabled
        self.idleStopTimeout = store.idleStopTimeout

        #if targetEnvironment(simulator)
        if config.requireCellular {
            config.requireCellular = false
        }
        #endif

        refreshExpiryWarning()
        appendLog("USBProxy \(Self.appVersion) launched (mode=\(runMode.rawValue))")

        tunnelController.onStatusChange = { [weak self] status in
            guard let self else { return }
            self.vpnStatus = status
            if self.runMode == .packetTunnel {
                self.isRunning = (status == .connected || status == .connecting || status == .reasserting)
                if status == .disconnected {
                    self.snapshot.listening = false
                    self.upSpeedBps = 0
                    self.downSpeedBps = 0
                }
            }
            self.applyIdleTimer()
        }

        observeLifecycle()
        startPollingLoop()

        if VPNTunnelController.isSupportedInBuild {
            Task {
                if let mgr = try? await tunnelController.loadManager() {
                    self.vpnStatus = mgr.connection.status
                    if self.runMode == .packetTunnel && self.tunnelController.isConnected {
                        self.isRunning = true
                        await self.refreshOnce()
                    }
                }
            }
        }
    }

    // MARK: - Controls

    func startProxy() async {
        errorMessage = nil
        idleStop.reset()
        sampler.reset()
        upSpeedBps = 0
        downSpeedBps = 0

        switch runMode {
        case .inApp:
            startInAppServer()
        case .packetTunnel:
            await startPacketTunnel()
        }
        applyIdleTimer()
        await refreshOnce()
    }

    func stopProxy() {
        errorMessage = nil
        switch runMode {
        case .inApp:
            localServer?.stop()
            localServer = nil
            keepAliveAudio.stop()
            audioKeepAliveActive = false
            isRunning = false
            snapshot.listening = false
        case .packetTunnel:
            tunnelController.stop()
            isRunning = false
        }
        sampler.reset()
        upSpeedBps = 0
        downSpeedBps = 0
        applyIdleTimer()
    }

    func toggleProxy() async {
        if isRunning {
            stopProxy()
        } else {
            await startProxy()
        }
    }

    func switchPortAndRestart(to newPort: UInt16) async {
        stopProxy()
        config.listenPort = newPort
        snapshot.listenPort = newPort
        snapshot.lastError = nil
        errorMessage = nil
        try? await Task.sleep(for: .milliseconds(250))
        await startProxy()
    }

    var hasAddressInUseError: Bool {
        let combined = (errorMessage ?? "") + " " + (snapshot.lastError ?? "")
        return combined.contains("EADDRINUSE") || combined.contains("Address already in use") || combined.contains("rawValue: 48")
    }

    func resetCounters() async {
        sampler.reset()
        upSpeedBps = 0
        downSpeedBps = 0
        if runMode == .inApp {
            localServer?.resetCounters()
        } else {
            _ = await tunnelController.send(.resetCounters)
        }
        await refreshOnce()
    }

    func exportLogFile() -> URL? {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let header = "USBProxy \(Self.appVersion), iOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion), mode=\(runMode.rawValue), cellular=\(cellularStatus.summary)"
        return try? debugLog.writeExport(header: header, to: FileManager.default.temporaryDirectory)
    }

    // MARK: - In-App Server (Stage 1 + tether KeepAlive Audio)

    private func startInAppServer() {
        localServer?.stop()
        let server = ProxyServer(config: config) { [weak self] line in
            Task { @MainActor in
                self?.appendLog(line)
            }
        }
        self.localServer = server
        self.isRunning = true
        syncAudioKeepAlive()

        server.start { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(let port):
                    self.errorMessage = nil
                    self.appendLog("in-app proxy ready on 127.0.0.1:\(port)")
                case .failure(let error):
                    let snap = server.snapshot()
                    self.errorMessage = snap.lastError ?? "리스너 시작 실패: \(error.localizedDescription)"
                    self.appendLog("in-app proxy start failed: \(error)")
                }
                self.snapshot = server.snapshot()
            }
        }
    }

    private func syncAudioKeepAlive() {
        guard runMode == .inApp, isRunning, keepAliveAudioEnabled else {
            keepAliveAudio.stop()
            audioKeepAliveActive = false
            return
        }
        keepAliveAudio.start()
        audioKeepAliveActive = keepAliveAudio.isSounding
    }

    // MARK: - Packet Tunnel Extension (Stage 2)

    private func startPacketTunnel() async {
        localServer?.stop()
        localServer = nil
        keepAliveAudio.stop()
        audioKeepAliveActive = false

        var extConfig = config
        // Enforce Stage 2 memory-safe caps inside the ~50 MB NEPacketTunnelProvider extension.
        extConfig.maxConnections = min(extConfig.maxConnections, ProxyConfig.tunnelExtension.maxConnections)
        extConfig.bufferSize = min(extConfig.bufferSize, ProxyConfig.tunnelExtension.bufferSize)
        extConfig.maxUDPFlowsPerStream = min(extConfig.maxUDPFlowsPerStream, ProxyConfig.tunnelExtension.maxUDPFlowsPerStream)

        do {
            try await tunnelController.start(config: extConfig)
            isRunning = true
        } catch {
            isRunning = false
            errorMessage = error.localizedDescription
            appendLog("packet tunnel start failed: \(error)")
        }
    }

    private func restartForModeChange() async {
        localServer?.stop()
        localServer = nil
        keepAliveAudio.stop()
        audioKeepAliveActive = false
        if tunnelController.isConnected {
            tunnelController.stop()
        }
        isRunning = false
        try? await Task.sleep(for: .milliseconds(350))
        await startProxy()
    }

    // MARK: - Polling, Speeds, Idle Stop, Lifecycle

    private func startPollingLoop() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshOnce()
                let interval = KeepAlivePolicy.watchInterval(sceneActive: self?.sceneActive ?? false)
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    private func refreshOnce() async {
        let now = Date()
        refreshExpiryWarning(now: now)
        cellularStatus = CellularProbe.current()

        if runMode == .inApp {
            if let server = localServer {
                snapshot = server.snapshot()
                if isRunning && keepAliveAudioEnabled && !keepAliveAudio.isSounding {
                    keepAliveAudio.start()
                }
                audioKeepAliveActive = keepAliveAudio.isSounding
            }
            recentLogs = debugLog.recent()
        } else {
            if let response = await tunnelController.send(.status) {
                snapshot = response.snapshot
                recentLogs = response.recentLogs.isEmpty ? debugLog.recent() : response.recentLogs
            } else if let saved = store.loadSnapshot() {
                snapshot = saved
            }
        }

        if isRunning && sceneActive {
            if let speeds = sampler.sample(snapshot.traffic, at: now) {
                upSpeedBps = speeds.upBps
                downSpeedBps = speeds.downBps
            }
        } else {
            upSpeedBps = 0
            downSpeedBps = 0
        }

        // Background idle auto-stop (in-app silent-audio mode battery protection, from tether).
        if runMode == .inApp && isRunning {
            let trafficMoved = (snapshot.traffic != lastIdleCheckTraffic)
            lastIdleCheckTraffic = snapshot.traffic
            if idleStop.check(
                running: isRunning,
                activeConnections: snapshot.activeConnections,
                trafficChanged: trafficMoved,
                sceneActive: sceneActive,
                timeout: idleStopTimeout,
                now: now
            ) {
                appendLog("idle auto-stop triggered after \(idleStopTimeout.label)")
                stopProxy()
            }
        }
    }

    private func refreshExpiryWarning(now: Date = Date()) {
        let next = expiresAt.flatMap { AppExpiry.warning(expires: $0, now: now) }
        if next != expiryWarning {
            expiryWarning = next
        }
    }

    private func applyIdleTimer() {
        let keepAwake = preventScreenSleep && isRunning && sceneActive
        UIApplication.shared.isIdleTimerDisabled = keepAwake
    }

    private func observeLifecycle() {
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.sceneActive = true
                self.sampler.reset()
                self.applyIdleTimer()
                if self.runMode == .inApp && self.isRunning {
                    self.localServer?.ensureListening()
                    self.syncAudioKeepAlive()
                } else if self.runMode == .packetTunnel && self.isRunning {
                    Task { _ = await self.tunnelController.send(.ensureListening) }
                }
                Task { await self.refreshOnce() }
            }
        }
        center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.sceneActive = false
                self.sampler.reset()
                UIApplication.shared.isIdleTimerDisabled = false
            }
        }
        center.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.appendLog("UIApplication memory warning received")
                self?.localServer?.handleMemoryPressure()
            }
        }
    }

    private func appendLog(_ text: String) {
        let redacted = LogRedaction.redact(text)
        logger.info("\(redacted, privacy: .public)")
        debugLog.append(text)
        if sceneActive {
            recentLogs = debugLog.recent()
        }
    }
}
