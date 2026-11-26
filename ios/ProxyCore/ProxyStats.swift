import Foundation

/// Monotonic byte counters modeled after `viktor-svirsky/tether`'s `TrafficTotals`.
public struct TrafficTotals: Equatable, Codable, Sendable {
    public var bytesUp: UInt64
    public var bytesDown: UInt64

    public init(bytesUp: UInt64 = 0, bytesDown: UInt64 = 0) {
        self.bytesUp = bytesUp
        self.bytesDown = bytesDown
    }

    public var total: UInt64 {
        bytesUp.addingReportingOverflow(bytesDown).overflow ? .max : bytesUp + bytesDown
    }

    public static func += (lhs: inout TrafficTotals, rhs: TrafficTotals) {
        lhs.bytesUp = lhs.bytesUp.addingReportingOverflow(rhs.bytesUp).overflow ? .max : lhs.bytesUp + rhs.bytesUp
        lhs.bytesDown = lhs.bytesDown.addingReportingOverflow(rhs.bytesDown).overflow ? .max : lhs.bytesDown + rhs.bytesDown
    }
}

/// Carries prior run totals across listener restarts so displayed totals stay monotonic.
public struct CarriedTotals: Equatable, Sendable {
    private var carried = TrafficTotals()

    public init() {}

    public mutating func absorb(_ last: TrafficTotals) {
        carried += last
    }

    public func apply(to current: TrafficTotals) -> TrafficTotals {
        var combined = carried
        combined += current
        return combined
    }

    public mutating func reset() {
        carried = TrafficTotals()
    }
}

/// Computes live upload/download speeds (bits per second) from consecutive `TrafficTotals` samples.
/// Inspired by `viktor-svirsky/tether`'s `TrafficSampler`.
public struct TrafficSampler: Sendable {
    private var last: (totals: TrafficTotals, at: Date)?

    public init() {}

    public mutating func sample(_ totals: TrafficTotals, at now: Date) -> (upBps: Double, downBps: Double)? {
        defer { last = (totals, now) }
        guard let last else { return nil }
        let seconds = now.timeIntervalSince(last.at)
        guard seconds > 0 else { return nil }
        return (
            Self.bps(totals.bytesUp, last.totals.bytesUp, seconds),
            Self.bps(totals.bytesDown, last.totals.bytesDown, seconds)
        )
    }

    public mutating func reset() {
        last = nil
    }

    private static func bps(_ new: UInt64, _ old: UInt64, _ seconds: TimeInterval) -> Double {
        new >= old ? Double(new - old) * 8.0 / seconds : 0
    }
}

/// Point-in-time snapshot exported by `ProxyServer` (and shared over IPC from the Tunnel Extension).
public struct ProxySnapshot: Equatable, Codable, Sendable {
    public var listening: Bool
    public var listenPort: UInt16
    public var requireCellular: Bool
    public var enableUDP: Bool
    public var activeTCPConnections: Int
    public var activeUDPStreams: Int
    public var activeUDPFlows: Int
    public var totalConnectionsHandled: UInt64
    public var rejectedConnections: UInt64
    public var dialFailures: UInt64
    public var listenerRestarts: UInt64
    public var traffic: TrafficTotals
    public var startedAt: Date?
    public var lastError: String?
    public var memoryUsageBytes: UInt64

    public init(
        listening: Bool = false,
        listenPort: UInt16 = 1080,
        requireCellular: Bool = true,
        enableUDP: Bool = true,
        activeTCPConnections: Int = 0,
        activeUDPStreams: Int = 0,
        activeUDPFlows: Int = 0,
        totalConnectionsHandled: UInt64 = 0,
        rejectedConnections: UInt64 = 0,
        dialFailures: UInt64 = 0,
        listenerRestarts: UInt64 = 0,
        traffic: TrafficTotals = TrafficTotals(),
        startedAt: Date? = nil,
        lastError: String? = nil,
        memoryUsageBytes: UInt64 = 0
    ) {
        self.listening = listening
        self.listenPort = listenPort
        self.requireCellular = requireCellular
        self.enableUDP = enableUDP
        self.activeTCPConnections = activeTCPConnections
        self.activeUDPStreams = activeUDPStreams
        self.activeUDPFlows = activeUDPFlows
        self.totalConnectionsHandled = totalConnectionsHandled
        self.rejectedConnections = rejectedConnections
        self.dialFailures = dialFailures
        self.listenerRestarts = listenerRestarts
        self.traffic = traffic
        self.startedAt = startedAt
        self.lastError = lastError
        self.memoryUsageBytes = memoryUsageBytes
    }

    public var activeConnections: Int {
        activeTCPConnections + activeUDPStreams
    }
}

/// Human-readable formatting utilities for bytes, bitrates, and memory footprint.
public enum ProxyFormat {
    public static func bytes(_ count: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: Int64(clamping: count))
    }

    public static func speed(_ bps: Double, locale: Locale = .current) -> String {
        func format(_ value: Double, digits: Int) -> String {
            value.formatted(.number.precision(.fractionLength(digits)).locale(locale))
        }
        switch bps {
        case 1e6...:
            return "\(format(bps / 1e6, digits: 1)) Mbit/s"
        case 1e3...:
            return "\(format(bps / 1e3, digits: 0)) kbit/s"
        default:
            return "\(format(max(0, bps), digits: 0)) bit/s"
        }
    }

    public static func memoryMB(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / (1024.0 * 1024.0)
        return String(format: "%.1f MB", mb)
    }
}
