import Foundation

/// Runtime configuration for the loopback SOCKS5 + UDP-over-TCP proxy server.
/// Two presets are provided:
/// - `.appDefault`: Foreground / KeepAlive-audio mode inside the main app process.
/// - `.tunnelExtension`: Tighter memory budget for iOS NEPacketTunnelProvider (~50 MB jetsam limit).
public struct ProxyConfig: Equatable, Codable, Sendable {
    /// Loopback TCP port listened on 127.0.0.1 for usbmux (`iproxy 1080 1080`).
    public var listenPort: UInt16
    /// Forces outbound NWConnection sockets to use `.cellular` even while Wi-Fi is on.
    public var requireCellular: Bool
    /// Enables SagerNet UDP-over-TCP v1/v2 (`sp.udp-over-tcp.arpa`, `sp.v2.udp-over-tcp.arpa`).
    public var enableUDP: Bool
    /// Upper bound on concurrent client TCP connections (including UoT streams).
    public var maxConnections: Int
    /// Maximum number of concurrent outbound UDP flows per UoT non-connect stream.
    public var maxUDPFlowsPerStream: Int
    /// Maximum read/write chunk size per direction.
    public var bufferSize: Int
    /// Maximum unacknowledged bytes in flight per direction (sliding-window pipelining).
    /// Larger windows in app mode eliminate stop-and-wait stalls for 30+ MB/s 5G transfers;
    /// smaller windows in extension mode keep worst-case memory well under the ~50 MB jetsam limit.
    public var maxInFlightBytes: Int
    /// SOCKS5 handshake deadline in seconds.
    public var handshakeTimeout: TimeInterval
    /// Outbound TCP dial timeout in seconds.
    public var dialTimeout: TimeInterval
    /// Idle timeout for TCP relay connections in seconds.
    public var tcpIdleTimeout: TimeInterval
    /// Grace window after one side sends FIN before forcing cleanup of a stuck half-open peer.
    public var halfCloseTimeout: TimeInterval
    /// Idle timeout for non-DNS UDP flows in seconds (matches tether's full-cone timeout strategy).
    public var udpIdleTimeout: TimeInterval
    /// Shorter idle timeout for DNS-only (port 53) UDP flows in seconds.
    public var udpDNSIdleTimeout: TimeInterval
    /// Outbound TCP keepalive idle interval in seconds (600s avoids waking cellular radio every 15s, per tether).
    public var tcpKeepaliveIdle: Int
    /// Interval between periodic idle-connection sweeps in seconds.
    public var reaperInterval: TimeInterval

    public init(
        listenPort: UInt16 = 1080,
        requireCellular: Bool = true,
        enableUDP: Bool = true,
        maxConnections: Int = 256,
        maxUDPFlowsPerStream: Int = 64,
        bufferSize: Int = 128 * 1024,
        maxInFlightBytes: Int = 512 * 1024,
        handshakeTimeout: TimeInterval = 10,
        dialTimeout: TimeInterval = 15,
        tcpIdleTimeout: TimeInterval = 300,
        halfCloseTimeout: TimeInterval = 15,
        udpIdleTimeout: TimeInterval = 60,
        udpDNSIdleTimeout: TimeInterval = 20,
        tcpKeepaliveIdle: Int = 600,
        reaperInterval: TimeInterval = 15
    ) {
        self.listenPort = listenPort
        self.requireCellular = requireCellular
        self.enableUDP = enableUDP
        self.maxConnections = maxConnections
        self.maxUDPFlowsPerStream = maxUDPFlowsPerStream
        self.bufferSize = bufferSize
        self.maxInFlightBytes = maxInFlightBytes
        self.handshakeTimeout = handshakeTimeout
        self.dialTimeout = dialTimeout
        self.tcpIdleTimeout = tcpIdleTimeout
        self.halfCloseTimeout = halfCloseTimeout
        self.udpIdleTimeout = udpIdleTimeout
        self.udpDNSIdleTimeout = udpDNSIdleTimeout
        self.tcpKeepaliveIdle = tcpKeepaliveIdle
        self.reaperInterval = reaperInterval
    }

    private enum CodingKeys: String, CodingKey {
        case listenPort, requireCellular, enableUDP, maxConnections, maxUDPFlowsPerStream
        case bufferSize, maxInFlightBytes, handshakeTimeout, dialTimeout, tcpIdleTimeout
        case halfCloseTimeout, udpIdleTimeout, udpDNSIdleTimeout, tcpKeepaliveIdle, reaperInterval
    }

    /// Backward-compatible decoder: preserves saved user settings (e.g. `listenPort = 10808`)
    /// from pre-pipelining builds lacking `maxInFlightBytes`, while upgrading legacy 16 KB
    /// app defaults to the high-throughput 128 KB / 512 KB sliding-window defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ProxyConfig.appDefault
        self.listenPort = try c.decodeIfPresent(UInt16.self, forKey: .listenPort) ?? d.listenPort
        self.requireCellular = try c.decodeIfPresent(Bool.self, forKey: .requireCellular) ?? d.requireCellular
        self.enableUDP = try c.decodeIfPresent(Bool.self, forKey: .enableUDP) ?? d.enableUDP
        self.maxConnections = try c.decodeIfPresent(Int.self, forKey: .maxConnections) ?? d.maxConnections
        self.maxUDPFlowsPerStream = try c.decodeIfPresent(Int.self, forKey: .maxUDPFlowsPerStream) ?? d.maxUDPFlowsPerStream

        let decodedBuffer = try c.decodeIfPresent(Int.self, forKey: .bufferSize) ?? d.bufferSize
        let decodedInFlight = try c.decodeIfPresent(Int.self, forKey: .maxInFlightBytes)
        if let decodedInFlight {
            self.bufferSize = decodedBuffer
            self.maxInFlightBytes = decodedInFlight
        } else {
            self.bufferSize = decodedBuffer <= 32 * 1024 ? d.bufferSize : decodedBuffer
            self.maxInFlightBytes = max(self.bufferSize, d.maxInFlightBytes)
        }

        self.handshakeTimeout = try c.decodeIfPresent(TimeInterval.self, forKey: .handshakeTimeout) ?? d.handshakeTimeout
        self.dialTimeout = try c.decodeIfPresent(TimeInterval.self, forKey: .dialTimeout) ?? d.dialTimeout
        self.tcpIdleTimeout = try c.decodeIfPresent(TimeInterval.self, forKey: .tcpIdleTimeout) ?? d.tcpIdleTimeout
        self.halfCloseTimeout = try c.decodeIfPresent(TimeInterval.self, forKey: .halfCloseTimeout) ?? d.halfCloseTimeout
        self.udpIdleTimeout = try c.decodeIfPresent(TimeInterval.self, forKey: .udpIdleTimeout) ?? d.udpIdleTimeout
        self.udpDNSIdleTimeout = try c.decodeIfPresent(TimeInterval.self, forKey: .udpDNSIdleTimeout) ?? d.udpDNSIdleTimeout
        self.tcpKeepaliveIdle = try c.decodeIfPresent(Int.self, forKey: .tcpKeepaliveIdle) ?? d.tcpKeepaliveIdle
        self.reaperInterval = try c.decodeIfPresent(TimeInterval.self, forKey: .reaperInterval) ?? d.reaperInterval
    }

    /// Standard configuration when running inside the main app process.
    /// Uses 128 KB chunks with 512 KB sliding-window pipelining to sustain 30+ MB/s on 5G + USB.
    public static let appDefault = ProxyConfig(
        listenPort: 1080,
        requireCellular: true,
        enableUDP: true,
        maxConnections: 512,
        maxUDPFlowsPerStream: 64,
        bufferSize: 128 * 1024,
        maxInFlightBytes: 512 * 1024,
        handshakeTimeout: 10,
        dialTimeout: 15,
        tcpIdleTimeout: 120,
        halfCloseTimeout: 10,
        udpIdleTimeout: 60,
        udpDNSIdleTimeout: 20,
        tcpKeepaliveIdle: 600,
        reaperInterval: 15
    )

    /// Memory-constrained configuration for NEPacketTunnelProvider (~50 MB jetsam limit).
    /// Worst-case relay window ceiling: 200 * 2 * 64 KB = 25.6 MB.
    public static let tunnelExtension = ProxyConfig(
        listenPort: 1080,
        requireCellular: true,
        enableUDP: true,
        maxConnections: 200,
        maxUDPFlowsPerStream: 32,
        bufferSize: 16 * 1024,
        maxInFlightBytes: 64 * 1024,
        handshakeTimeout: 8,
        dialTimeout: 15,
        tcpIdleTimeout: 180,
        halfCloseTimeout: 10,
        udpIdleTimeout: 45,
        udpDNSIdleTimeout: 15,
        tcpKeepaliveIdle: 600,
        reaperInterval: 10
    )

    /// Loopback-only configuration for local unit tests on macOS (no cellular interface required).
    public static func testing(port: UInt16 = 0, maxConnections: Int = 64) -> ProxyConfig {
        ProxyConfig(
            listenPort: port,
            requireCellular: false,
            enableUDP: true,
            maxConnections: maxConnections,
            maxUDPFlowsPerStream: 32,
            bufferSize: 32 * 1024,
            maxInFlightBytes: 128 * 1024,
            handshakeTimeout: 5,
            dialTimeout: 5,
            tcpIdleTimeout: 30,
            halfCloseTimeout: 5,
            udpIdleTimeout: 10,
            udpDNSIdleTimeout: 5,
            tcpKeepaliveIdle: 60,
            reaperInterval: 2
        )
    }
}
