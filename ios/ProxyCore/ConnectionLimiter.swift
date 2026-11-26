import Foundation

/// Tracks active proxy connections, enforces the concurrency ceiling (essential for the 50 MB
/// Packet Tunnel jetsam limit), sweeps idle connections, and supports emergency trimming under
/// iOS memory pressure.
public final class ConnectionLimiter: @unchecked Sendable {
    public enum Kind: Sendable {
        case tcp
        case udpStream
    }

    private struct Entry {
        let id: UInt64
        let kind: Kind
        let idleTimeout: TimeInterval
        var lastActivity: Date
        let cancel: @Sendable () -> Void
    }

    private let lock = NSLock()
    private let maxConnections: Int
    private var nextID: UInt64 = 1
    private var entries: [UInt64: Entry] = [:]
    private var tcpCount = 0
    private var udpStreamCount = 0
    private var totalAdmitted: UInt64 = 0
    private var totalRejected: UInt64 = 0

    public init(maxConnections: Int) {
        self.maxConnections = max(1, maxConnections)
    }

    /// Reserves a connection slot if below `maxConnections`. Returns the connection ID or `nil` when full.
    public func admit(
        kind: Kind,
        idleTimeout: TimeInterval,
        now: Date = Date(),
        cancel: @escaping @Sendable () -> Void
    ) -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        guard entries.count < maxConnections else {
            totalRejected &+= 1
            return nil
        }
        let id = nextID
        nextID &+= 1
        entries[id] = Entry(id: id, kind: kind, idleTimeout: idleTimeout, lastActivity: now, cancel: cancel)
        switch kind {
        case .tcp: tcpCount += 1
        case .udpStream: udpStreamCount += 1
        }
        totalAdmitted &+= 1
        return id
    }

    /// Refreshes the idle timer for an active connection.
    public func touch(_ id: UInt64, now: Date = Date()) {
        lock.lock()
        entries[id]?.lastActivity = now
        lock.unlock()
    }

    /// Changes a connection's kind (e.g., when a SOCKS5 CONNECT upgrades into a UoT UDP stream).
    public func reclassify(_ id: UInt64, to newKind: Kind, idleTimeout: TimeInterval, now: Date = Date()) {
        lock.lock()
        if let old = entries[id], old.kind != newKind {
            switch old.kind {
            case .tcp: tcpCount = max(0, tcpCount - 1)
            case .udpStream: udpStreamCount = max(0, udpStreamCount - 1)
            }
            switch newKind {
            case .tcp: tcpCount += 1
            case .udpStream: udpStreamCount += 1
            }
            entries[id] = Entry(id: old.id, kind: newKind, idleTimeout: idleTimeout, lastActivity: now, cancel: old.cancel)
        }
        lock.unlock()
    }

    /// Releases a connection slot once closed. Idempotent.
    public func release(_ id: UInt64) {
        lock.lock()
        if let removed = entries.removeValue(forKey: id) {
            switch removed.kind {
            case .tcp: tcpCount = max(0, tcpCount - 1)
            case .udpStream: udpStreamCount = max(0, udpStreamCount - 1)
            }
        }
        lock.unlock()
    }

    /// Cancels all connections that have exceeded their idle timeout. Returns how many were reaped.
    @discardableResult
    public func reapIdle(now: Date = Date()) -> Int {
        let expired: [@Sendable () -> Void]
        lock.lock()
        expired = entries.values.compactMap { entry in
            now.timeIntervalSince(entry.lastActivity) >= entry.idleTimeout ? entry.cancel : nil
        }
        lock.unlock()
        expired.forEach { $0() }
        return expired.count
    }

    /// Under memory pressure, cancels the oldest `fraction` (e.g., 0.25) of active connections.
    @discardableResult
    public func trimOldest(fraction: Double = 0.25) -> Int {
        let clamped = min(max(fraction, 0), 1)
        let victims: [@Sendable () -> Void]
        lock.lock()
        let count = Int(ceil(Double(entries.count) * clamped))
        if count == 0 {
            victims = []
        } else {
            let sorted = entries.values.sorted { $0.lastActivity < $1.lastActivity }
            victims = sorted.prefix(count).map(\.cancel)
        }
        lock.unlock()
        victims.forEach { $0() }
        return victims.count
    }

    /// Cancels every currently tracked connection (used on server stop).
    public func cancelAll() {
        let all: [@Sendable () -> Void]
        lock.lock()
        all = entries.values.map(\.cancel)
        lock.unlock()
        all.forEach { $0() }
    }

    public func counts() -> (tcp: Int, udpStreams: Int, totalHandled: UInt64, rejected: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        return (tcpCount, udpStreamCount, totalAdmitted, totalRejected)
    }
}
