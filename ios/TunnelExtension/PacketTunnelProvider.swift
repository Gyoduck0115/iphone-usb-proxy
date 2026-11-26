import Foundation
import NetworkExtension
import OSLog

/// Stage 2 Packet Tunnel Extension:
/// Creates a dummy VPN tunnel that routes NO device traffic (`includedRoutes = []`) solely to keep
/// the background process alive while the screen is locked, and hosts `ProxyServer` on `127.0.0.1:1080`
/// with strict ~50 MB jetsam memory guards.
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let logger = Logger(subsystem: "com.local.usbproxy", category: "tunnel")
    private let store = SharedProxyStore()
    private let debugLog = DebugLog()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private var server: ProxyServer?
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var snapshotTimer: DispatchSourceTimer?
    private let providerQueue = DispatchQueue(label: "com.local.usbproxy.tunnel.provider", qos: .utility)

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        let config = resolveConfig(options: options)
        appendLog("starting dummy Packet Tunnel (port=\(config.listenPort), maxConn=\(config.maxConnections), buf=\(config.bufferSize / 1024)KB, window=\(config.maxInFlightBytes / 1024)KB)")

        // Dummy tunnel settings: RFC 2544 address space, NO included routes, default route excluded,
        // and no DNS override so iOS traffic and outbound `.cellular` sockets bypass the dummy utun.
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "198.18.0.1")
        let ipv4 = NEIPv4Settings(addresses: ["198.18.0.2"], subnetMasks: ["255.255.255.252"])
        ipv4.includedRoutes = []
        ipv4.excludedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4
        settings.mtu = 1500

        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self else {
                completionHandler(error)
                return
            }
            if let error {
                self.appendLog("setTunnelNetworkSettings failed: \(error)")
                completionHandler(error)
                return
            }

            let proxy = ProxyServer(config: config) { [weak self] line in
                self?.appendLog(line)
            }
            self.server = proxy
            self.installMemoryPressureMonitor()
            self.startSnapshotSyncTimer()
            self.drainDummyPacketFlow()

            proxy.start { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let port):
                    self.appendLog("tunnel proxy listening on 127.0.0.1:\(port)")
                    self.store.saveSnapshot(proxy.snapshot())
                    completionHandler(nil)
                case .failure(let startError):
                    self.appendLog("tunnel proxy start failed: \(startError)")
                    completionHandler(startError)
                }
            }
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        appendLog("stopping Packet Tunnel (reason=\(reason.rawValue))")
        snapshotTimer?.cancel()
        snapshotTimer = nil
        memoryPressureSource?.cancel()
        memoryPressureSource = nil
        server?.stop()
        if let snap = server?.snapshot() {
            store.saveSnapshot(snap)
        }
        server = nil
        completionHandler()
    }

    override func wake() {
        appendLog("device woke, verifying loopback listener")
        server?.ensureListening()
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        guard let completionHandler else { return }
        guard let request = try? decoder.decode(TunnelIPCRequest.self, from: messageData) else {
            completionHandler(nil)
            return
        }

        switch request {
        case .status:
            break
        case .resetCounters:
            server?.resetCounters()
        case .ensureListening:
            server?.ensureListening()
        case .updateConfig(let updated):
            let bounded = enforceExtensionLimits(updated)
            store.saveConfig(bounded)
            restartServer(with: bounded)
        }

        let snap = server?.snapshot() ?? ProxySnapshot()
        store.saveSnapshot(snap)
        let response = TunnelIPCResponse(snapshot: snap, recentLogs: debugLog.recent())
        completionHandler(try? encoder.encode(response))
    }

    // MARK: - Helpers

    private func resolveConfig(options: [String: NSObject]?) -> ProxyConfig {
        if let data = options?["proxyConfig"] as? Data,
           let decoded = try? decoder.decode(ProxyConfig.self, from: data) {
            return enforceExtensionLimits(decoded)
        }
        if let proto = protocolConfiguration as? NETunnelProviderProtocol,
           let data = proto.providerConfiguration?["proxyConfig"] as? Data,
           let decoded = try? decoder.decode(ProxyConfig.self, from: data) {
            return enforceExtensionLimits(decoded)
        }
        return enforceExtensionLimits(store.loadConfig(default: .tunnelExtension))
    }

    /// Ensures the extension never exceeds safe buffer/connection bounds for iOS's ~50 MB jetsam limit.
    private func enforceExtensionLimits(_ raw: ProxyConfig) -> ProxyConfig {
        var cfg = raw
        cfg.maxConnections = min(max(1, cfg.maxConnections), ProxyConfig.tunnelExtension.maxConnections)
        cfg.bufferSize = min(max(4096, cfg.bufferSize), ProxyConfig.tunnelExtension.bufferSize)
        cfg.maxInFlightBytes = min(max(cfg.bufferSize, cfg.maxInFlightBytes), ProxyConfig.tunnelExtension.maxInFlightBytes)
        cfg.maxUDPFlowsPerStream = min(max(4, cfg.maxUDPFlowsPerStream), ProxyConfig.tunnelExtension.maxUDPFlowsPerStream)
        cfg.tcpIdleTimeout = min(cfg.tcpIdleTimeout, ProxyConfig.tunnelExtension.tcpIdleTimeout)
        return cfg
    }

    private func restartServer(with config: ProxyConfig) {
        server?.stop()
        let proxy = ProxyServer(config: config) { [weak self] line in
            self?.appendLog(line)
        }
        server = proxy
        proxy.start(completion: nil)
    }

    /// Drains any stray packets sent to the dummy utun interface so kernel buffers never stall.
    private func drainDummyPacketFlow() {
        packetFlow.readPackets { [weak self] _, _ in
            guard let self, self.server != nil else { return }
            self.drainDummyPacketFlow()
        }
    }

    private func installMemoryPressureMonitor() {
        memoryPressureSource?.cancel()
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: providerQueue)
        source.setEventHandler { [weak self] in
            self?.appendLog("tunnel extension memory pressure event")
            self?.server?.handleMemoryPressure()
        }
        source.resume()
        memoryPressureSource = source
    }

    private func startSnapshotSyncTimer() {
        snapshotTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: providerQueue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            guard let self, let snap = self.server?.snapshot() else { return }
            self.store.saveSnapshot(snap)
        }
        timer.resume()
        snapshotTimer = timer
    }

    private func appendLog(_ text: String) {
        let redacted = LogRedaction.redact(text)
        logger.info("\(redacted, privacy: .public)")
        debugLog.append(text)
    }
}
