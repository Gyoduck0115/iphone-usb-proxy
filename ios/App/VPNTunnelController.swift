import Foundation
import NetworkExtension

/// Controls the Stage 2 dummy `NEPacketTunnelProvider` extension (`USBProxyTunnel`) from the main app
/// and exchanges live statistics/config over `sendProviderMessage`.
@MainActor
final class VPNTunnelController {
    private var manager: NETunnelProviderManager?
    private var statusObserver: NSObjectProtocol?
    private let log: (String) -> Void
    private let encoder = JSONEncoder()

    var onStatusChange: ((NEVPNStatus) -> Void)?

    static var isSupportedInBuild: Bool {
        #if PACKET_TUNNEL_ENABLED
        return true
        #else
        return false
        #endif
    }

    var status: NEVPNStatus {
        manager?.connection.status ?? .invalid
    }

    var isConnected: Bool {
        status == .connected || status == .connecting || status == .reasserting
    }

    init(log: @escaping (String) -> Void) {
        self.log = log
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let conn = note.object as? NEVPNConnection
            MainActor.assumeIsolated {
                guard let self else { return }
                if let conn, self.manager?.connection === conn {
                    self.onStatusChange?(conn.status)
                } else {
                    self.onStatusChange?(self.status)
                }
            }
        }
    }

    deinit {
        if let observer = statusObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func loadManager() async throws -> NETunnelProviderManager {
        guard Self.isSupportedInBuild else {
            throw TunnelControlError.notEnabledInBuild
        }
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        let bundleID = SharedProxyStore.defaultTunnelBundleID
        if let existing = managers.first(where: {
            ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == bundleID
        }) {
            self.manager = existing
            return existing
        }

        let newManager = NETunnelProviderManager()
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = bundleID
        proto.serverAddress = "127.0.0.1"
        newManager.protocolConfiguration = proto
        newManager.localizedDescription = "USBProxy Background Tunnel"
        newManager.isEnabled = true

        try await newManager.saveToPreferences()
        try await newManager.loadFromPreferences()
        self.manager = newManager
        return newManager
    }

    func start(config: ProxyConfig) async throws {
        let mgr = try await loadManager()
        mgr.isEnabled = true
        if let proto = mgr.protocolConfiguration as? NETunnelProviderProtocol {
            if let data = try? encoder.encode(config) {
                proto.providerConfiguration = ["proxyConfig": data]
            }
            mgr.protocolConfiguration = proto
        }
        try await mgr.saveToPreferences()
        try await mgr.loadFromPreferences()

        var options: [String: NSObject] = [:]
        if let data = try? encoder.encode(config) {
            options["proxyConfig"] = data as NSData
        }
        try mgr.connection.startVPNTunnel(options: options)
        log("requested Packet Tunnel start")
    }

    func stop() {
        manager?.connection.stopVPNTunnel()
        log("requested Packet Tunnel stop")
    }

    func send(_ request: TunnelIPCRequest) async -> TunnelIPCResponse? {
        guard let session = manager?.connection as? NETunnelProviderSession,
              session.status == .connected || session.status == .reasserting,
              let payload = try? encoder.encode(request)
        else { return nil }

        return await withCheckedContinuation { continuation in
            do {
                try session.sendProviderMessage(payload) { responseData in
                    guard let responseData,
                          let decoded = try? JSONDecoder().decode(TunnelIPCResponse.self, from: responseData)
                    else {
                        continuation.resume(returning: nil)
                        return
                    }
                    continuation.resume(returning: decoded)
                }
            } catch {
                continuation.resume(returning: nil)
            }
        }
    }

    enum TunnelControlError: LocalizedError {
        case notEnabledInBuild

        var errorDescription: String? {
            switch self {
            case .notEnabledInBuild:
                return "이 빌드(USBProxyFree)는 무료 Apple ID용이라 Packet Tunnel 확장이 제외되어 있습니다. '앱 내 실행 (무음 오디오)' 모드를 사용하거나 유료 개발자 계정으로 USBProxy 스킴을 빌드하세요."
            }
        }
    }
}
