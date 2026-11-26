import Foundation
import Network

/// Relays SagerNet UDP-over-TCP (UoT) v1 and v2 streams over a client TCP `NWConnection`
/// to cellular-pinned outbound UDP `NWConnection`s.
///
/// Memory safety:
/// - Caps outbound UDP flows per stream (`config.maxUDPFlowsPerStream`).
/// - Applies shorter idle timeouts to port-53 DNS flows (`config.udpDNSIdleTimeout`) vs general UDP
///   flows (`config.udpIdleTimeout`), matching `viktor-svirsky/tether/WireGuard/udp.go`.
/// - Caps queued TCP write frames so a burst of inbound UDP replies cannot exhaust extension memory.
final class UoTRelaySession: @unchecked Sendable {
    private final class UDPFlow {
        let key: SOCKS5Endpoint
        let connection: NWConnection
        let isDNSOnly: Bool
        var lastActivity: Date
        var closed = false

        init(key: SOCKS5Endpoint, connection: NWConnection, now: Date) {
            self.key = key
            self.connection = connection
            self.isDNSOnly = (key.port == 53)
            self.lastActivity = now
        }
    }

    private let version: UoTVersion
    private let client: NWConnection
    private let config: ProxyConfig
    private let queue: DispatchQueue
    private let onTraffic: @Sendable (_ up: UInt64, _ down: UInt64) -> Void
    private let onActivity: @Sendable () -> Void
    private let onFlowCountDelta: @Sendable (_ delta: Int) -> Void
    private let onClosed: @Sendable () -> Void
    private let log: @Sendable (String) -> Void

    private var readBuffer = Data()
    private var parsedV2Header = false
    private var isConnectMode = false
    private var connectDestination: SOCKS5Endpoint?
    private var flows: [SOCKS5Endpoint: UDPFlow] = [:]
    private var writeQueue: [Data] = []
    private var isWriting = false
    private var closed = false
    private var reaperTimer: DispatchSourceTimer?
    private var lastActivityTouchUptime: TimeInterval = 0

    private static let maxPendingWriteFrames = 128
    private static let maxReadBufferBytes = 512 * 1024

    init(
        version: UoTVersion,
        client: NWConnection,
        initialData: Data,
        config: ProxyConfig,
        queue: DispatchQueue,
        onTraffic: @escaping @Sendable (_ up: UInt64, _ down: UInt64) -> Void,
        onActivity: @escaping @Sendable () -> Void,
        onFlowCountDelta: @escaping @Sendable (_ delta: Int) -> Void,
        onClosed: @escaping @Sendable () -> Void,
        log: @escaping @Sendable (String) -> Void
    ) {
        self.version = version
        self.client = client
        self.readBuffer = initialData
        self.config = config
        self.queue = queue
        self.onTraffic = onTraffic
        self.onActivity = onActivity
        self.onFlowCountDelta = onFlowCountDelta
        self.onClosed = onClosed
        self.log = log
    }

    func start() {
        queue.async { [weak self] in
            guard let self, !self.closed else { return }
            self.startReaper()
            if self.version == .v1 {
                self.parsedV2Header = true
                self.isConnectMode = false
            }
            if !self.readBuffer.isEmpty {
                self.processBuffer()
            }
            if !self.closed {
                self.receiveNextChunk()
            }
        }
    }

    func cancel() {
        queue.async { [weak self] in
            self?.closeLocked()
        }
    }

    private func startReaper() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let interval = max(2.0, min(config.reaperInterval, 10.0))
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            self?.reapIdleFlowsLocked()
        }
        timer.resume()
        reaperTimer = timer
    }

    private func touchActivityLocked() {
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastActivityTouchUptime >= 2.0 {
            lastActivityTouchUptime = now
            onActivity()
        }
    }

    private func receiveNextChunk() {
        guard !closed else { return }
        client.receive(minimumIncompleteLength: 1, maximumLength: config.bufferSize) { [weak self] content, _, isComplete, error in
            guard let self else { return }
            self.queue.async {
                guard !self.closed else { return }
                if let data = content, !data.isEmpty {
                    self.readBuffer.append(data)
                    if self.readBuffer.count > Self.maxReadBufferBytes {
                        self.log("UoT read buffer overflow, closing stream")
                        self.closeLocked()
                        return
                    }
                    self.touchActivityLocked()
                    self.processBuffer()
                }
                if error != nil || isComplete {
                    self.closeLocked()
                    return
                }
                self.receiveNextChunk()
            }
        }
    }

    private func processBuffer() {
        while !closed && !readBuffer.isEmpty {
            if !parsedV2Header {
                do {
                    switch try UoTProtocol.parseV2Request(readBuffer) {
                    case .needMoreData:
                        return
                    case .parsed(let req, let consumed):
                        readBuffer.removeFirst(consumed)
                        parsedV2Header = true
                        isConnectMode = req.isConnect
                        connectDestination = req.destination
                        if isConnectMode {
                            _ = ensureFlowLocked(for: req.destination)
                        }
                    }
                } catch {
                    log("UoT v2 header error: \(error)")
                    closeLocked()
                    return
                }
            }

            if isConnectMode {
                guard let dest = connectDestination else {
                    closeLocked()
                    return
                }
                switch UoTProtocol.parseConnectFrame(readBuffer) {
                case .needMoreData:
                    return
                case .parsed(let payload, let consumed):
                    readBuffer.removeFirst(consumed)
                    sendDatagramLocked(payload, to: dest)
                }
            } else {
                do {
                    switch try UoTProtocol.parsePacket(readBuffer) {
                    case .needMoreData:
                        return
                    case .parsed(let packet, let consumed):
                        readBuffer.removeFirst(consumed)
                        sendDatagramLocked(packet.payload, to: packet.destination)
                    }
                } catch {
                    log("UoT packet parse error: \(error)")
                    closeLocked()
                    return
                }
            }
        }
        if readBuffer.isEmpty {
            readBuffer.removeAll(keepingCapacity: false)
        }
    }

    private func sendDatagramLocked(_ payload: Data, to destination: SOCKS5Endpoint) {
        guard let flow = ensureFlowLocked(for: destination) else { return }
        flow.lastActivity = Date()
        onTraffic(UInt64(payload.count), 0)
        flow.connection.send(content: payload, completion: .contentProcessed { _ in })
    }

    private func ensureFlowLocked(for destination: SOCKS5Endpoint) -> UDPFlow? {
        if let existing = flows[destination], !existing.closed {
            return existing
        }
        guard destination.port != 0, let endpoint = destination.nwEndpoint else {
            return nil
        }

        if flows.count >= config.maxUDPFlowsPerStream {
            if let oldest = flows.values.min(by: { $0.lastActivity < $1.lastActivity }) {
                removeFlowLocked(oldest.key)
            }
        }

        let params = NWParameters.udp
        params.serviceClass = .interactiveVoice
        if config.requireCellular {
            params.requiredInterfaceType = .cellular
        }
        let conn = NWConnection(to: endpoint, using: params)
        let flow = UDPFlow(key: destination, connection: conn, now: Date())
        flows[destination] = flow
        onFlowCountDelta(1)

        conn.stateUpdateHandler = { [weak self, weak flow] state in
            guard let self, let flow else { return }
            switch state {
            case .failed, .cancelled:
                if self.flows[flow.key] === flow {
                    self.removeFlowLocked(flow.key)
                }
            default:
                break
            }
        }
        conn.start(queue: queue)
        receiveUDPMessage(on: flow)
        return flow
    }

    private func receiveUDPMessage(on flow: UDPFlow) {
        guard !closed, !flow.closed else { return }
        flow.connection.receiveMessage { [weak self, weak flow] content, _, _, error in
            guard let self, let flow, !self.closed, !flow.closed else { return }
            if let data = content, !data.isEmpty {
                flow.lastActivity = Date()
                self.touchActivityLocked()
                self.onTraffic(0, UInt64(data.count))
                self.enqueueReplyFrameLocked(payload: data, from: flow.key)
            }
            if error != nil {
                self.removeFlowLocked(flow.key)
                return
            }
            self.receiveUDPMessage(on: flow)
        }
    }

    private func enqueueReplyFrameLocked(payload: Data, from source: SOCKS5Endpoint) {
        guard writeQueue.count < Self.maxPendingWriteFrames else {
            // Drop excess UDP reply under backpressure (standard UDP behavior, protects extension RAM).
            return
        }
        do {
            let frame: Data
            if isConnectMode {
                frame = try UoTProtocol.encodeConnectFrame(payload)
            } else {
                frame = try UoTProtocol.encodePacket(UoTPacket(destination: source, payload: payload))
            }
            writeQueue.append(frame)
            drainWriteQueueLocked()
        } catch {
            // Oversized payload cannot be framed in u16; ignore datagram.
        }
    }

    private func drainWriteQueueLocked() {
        guard !closed, !isWriting, !writeQueue.isEmpty else { return }
        isWriting = true
        let next = writeQueue.removeFirst()
        client.send(content: next, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.queue.async {
                self.isWriting = false
                if error != nil {
                    self.closeLocked()
                    return
                }
                self.drainWriteQueueLocked()
            }
        })
    }

    private func reapIdleFlowsLocked() {
        guard !closed else { return }
        let now = Date()
        let expiredKeys = flows.values.compactMap { flow -> SOCKS5Endpoint? in
            let limit = flow.isDNSOnly ? config.udpDNSIdleTimeout : config.udpIdleTimeout
            return now.timeIntervalSince(flow.lastActivity) >= limit ? flow.key : nil
        }
        for key in expiredKeys {
            removeFlowLocked(key)
        }
    }

    private func removeFlowLocked(_ key: SOCKS5Endpoint) {
        guard let flow = flows.removeValue(forKey: key), !flow.closed else { return }
        flow.closed = true
        flow.connection.stateUpdateHandler = nil
        flow.connection.cancel()
        onFlowCountDelta(-1)
    }

    private func closeLocked() {
        guard !closed else { return }
        closed = true
        reaperTimer?.cancel()
        reaperTimer = nil
        let removedCount = flows.count
        for flow in flows.values {
            flow.closed = true
            flow.connection.stateUpdateHandler = nil
            flow.connection.cancel()
        }
        flows.removeAll()
        if removedCount > 0 {
            onFlowCountDelta(-removedCount)
        }
        writeQueue.removeAll()
        readBuffer.removeAll()
        client.stateUpdateHandler = nil
        client.cancel()
        onClosed()
    }
}
