import Foundation

/// Execution mode selected in the iOS app:
/// - `.inApp`: Stage 1 + `viktor-svirsky/tether` silent-audio background KeepAlive (works with free Apple ID!).
/// - `.packetTunnel`: Stage 2 dummy `NEPacketTunnelProvider` extension (requires paid Apple Developer account).
public enum ProxyRunMode: String, CaseIterable, Codable, Sendable {
    case inApp = "inApp"
    case packetTunnel = "packetTunnel"

    public var title: String {
        switch self {
        case .inApp: return "앱 내 실행 (무음 오디오 백그라운드)"
        case .packetTunnel: return "Packet Tunnel 확장 (더미 VPN)"
        }
    }

    public var subtitle: String {
        switch self {
        case .inApp: return "무료 Apple ID 지원 · 1단계 + tether 방식 백그라운드 유지"
        case .packetTunnel: return "유료 개발자 계정 필요 · 2단계 VPN 확장 프로세스(50MB 제한 대응)"
        }
    }
}

/// Messages sent from the main app to the Packet Tunnel extension via `NETunnelProviderSession.sendProviderMessage`.
public enum TunnelIPCRequest: Codable, Equatable, Sendable {
    case status
    case resetCounters
    case updateConfig(ProxyConfig)
    case ensureListening
}

/// Responses returned by the Packet Tunnel extension to the main app.
public struct TunnelIPCResponse: Codable, Equatable, Sendable {
    public let snapshot: ProxySnapshot
    public let recentLogs: [String]
    public let timestamp: Date

    public init(snapshot: ProxySnapshot, recentLogs: [String] = [], timestamp: Date = Date()) {
        self.snapshot = snapshot
        self.recentLogs = recentLogs
        self.timestamp = timestamp
    }
}

/// Shared App Group storage helper so the main app and Packet Tunnel extension share configuration
/// and last-known status even before an IPC message round-trip completes.
public final class SharedProxyStore: @unchecked Sendable {
    public static let defaultAppGroupID: String = {
        (Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String)
            .flatMap { $0.isEmpty ? nil : $0 } ?? "group.com.local.usbproxy"
    }()

    public static let defaultTunnelBundleID: String = {
        (Bundle.main.object(forInfoDictionaryKey: "TunnelBundleIdentifier") as? String)
            .flatMap { $0.isEmpty ? nil : $0 } ?? "com.local.usbproxy.tunnel"
    }()

    private enum Keys {
        static let config = "usbproxy.shared.config"
        static let snapshot = "usbproxy.shared.snapshot"
        static let runMode = "usbproxy.shared.runMode"
        static let preventSleep = "usbproxy.shared.preventSleep"
        static let idleStop = "usbproxy.shared.idleStop"
        static let keepAliveAudio = "usbproxy.shared.keepAliveAudio"
    }

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(appGroupID: String = SharedProxyStore.defaultAppGroupID) {
        self.defaults = UserDefaults(suiteName: appGroupID) ?? .standard
    }

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public func loadConfig(default fallback: ProxyConfig = .appDefault) -> ProxyConfig {
        guard let data = defaults.data(forKey: Keys.config),
              let decoded = try? decoder.decode(ProxyConfig.self, from: data)
        else { return fallback }
        return decoded
    }

    public func saveConfig(_ config: ProxyConfig) {
        if let data = try? encoder.encode(config) {
            defaults.set(data, forKey: Keys.config)
        }
    }

    public func loadSnapshot() -> ProxySnapshot? {
        guard let data = defaults.data(forKey: Keys.snapshot) else { return nil }
        return try? decoder.decode(ProxySnapshot.self, from: data)
    }

    public func saveSnapshot(_ snapshot: ProxySnapshot) {
        if let data = try? encoder.encode(snapshot) {
            defaults.set(data, forKey: Keys.snapshot)
        }
    }

    public func loadRunMode() -> ProxyRunMode {
        guard let raw = defaults.string(forKey: Keys.runMode),
              let mode = ProxyRunMode(rawValue: raw)
        else { return .inApp }
        return mode
    }

    public func saveRunMode(_ mode: ProxyRunMode) {
        defaults.set(mode.rawValue, forKey: Keys.runMode)
    }

    public var preventScreenSleep: Bool {
        get { defaults.object(forKey: Keys.preventSleep) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.preventSleep) }
    }

    public var keepAliveAudioEnabled: Bool {
        get { defaults.object(forKey: Keys.keepAliveAudio) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.keepAliveAudio) }
    }

    public var idleStopTimeout: IdleStopPolicy.Timeout {
        get { IdleStopPolicy.Timeout(rawValue: defaults.integer(forKey: Keys.idleStop)) ?? .never }
        set { defaults.set(newValue.rawValue, forKey: Keys.idleStop) }
    }
}
