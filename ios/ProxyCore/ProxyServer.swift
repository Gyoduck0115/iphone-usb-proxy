import Darwin
import Foundation
import Network

/// Loopback SOCKS5 + SagerNet UDP-over-TCP (UoT) proxy server built on Apple's `Network.framework`.
///
/// Key properties (from the plan & `viktor-svirsky/tether`):
/// - Listens ONLY on `127.0.0.1:<port>` (no Local Network permission required; reached via usbmux/`iproxy`).
/// - Pins outbound TCP/UDP connections to `.cellular` (`requiredInterfaceType = .cellular`) so Wi-Fi can stay on.
/// - Bounds memory per connection with strict 1-in-flight backpressure, concurrency limits, and idle reaping.
/// - Automatically reopens its listener with exponential backoff if iOS closes sockets during suspension/calls.
public final class ProxyServer: @unchecked Sendable {
    public private(set) var config: ProxyConfig

    private let controlQueue = DispatchQueue(label: "com.local.usbproxy.server", qos: .userInitiated)
    private let statsLock = NSLock()
    private let limiter: ConnectionLimiter
    private let logHandler: @Sendable (String) -> Void

    private var listener: NWListener?
    private var reaperTimer: DispatchSourceTimer?
    private var reopenWorkItem: DispatchWorkItem?
    private var reopenDelay: TimeInterval = 1.0
    private var shouldRun = false
    private var isListening = false
    private var actualPort: UInt16 = 0
    private var startedAt: Date?
    private var lastError: String?

    private var bytesUp: UInt64 = 0
    private var bytesDown: UInt64 = 0
    private var dialFailures: UInt64 = 0
    private var listenerRestarts: UInt64 = 0
    private var activeUDPFlows: Int = 0

    public var onStateChanged: (@Sendable (ProxySnapshot) -> Void)?

    public init(config: ProxyConfig = .appDefault, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.config = config
        self.limiter = ConnectionLimiter(maxConnections: config.maxConnections)
        self.logHandler = log
    }

    /// Starts listening on `127.0.0.1:<config.listenPort>`. Safe to call repeatedly.
    public func start(completion: (@Sendable (Result<UInt16, Error>) -> Void)? = nil) {
        controlQueue.async { [weak self] in
            guard let self else { return }
            if self.shouldRun && self.listener != nil && self.isListening {
                completion?(.success(self.actualPort))
                return
            }
            self.shouldRun = true
            self.reopenDelay = 1.0
            if self.startedAt == nil {
                self.startedAt = Date()
            }
            self.startReaperLocked()
            self.openListenerLocked(isRestart: false, completion: completion)
        }
    }

    /// Stops listening and terminates all active TCP and UDP relays cleanly.
    public func stop() {
        controlQueue.async { [weak self] in
            guard let self else { return }
            self.shouldRun = false
            self.reopenWorkItem?.cancel()
            self.reopenWorkItem = nil
            self.reaperTimer?.cancel()
            self.reaperTimer = nil
            self.listener?.stateUpdateHandler = nil
            self.listener?.newConnectionHandler = nil
            self.listener?.cancel()
            self.listener = nil
            self.statsLock.lock()
            self.isListening = false
            self.actualPort = 0
            self.startedAt = nil
            self.statsLock.unlock()
            self.limiter.cancelAll()
            self.logHandler("proxy stopped")
            self.notifyStateChanged()
        }
    }

    /// Called when returning from background or after an audio/call interruption (tether `reopen` pattern).
    /// Immediately rebinds the loopback listener if iOS tore down the socket while suspended.
    public func ensureListening() {
        controlQueue.async { [weak self] in
            guard let self, self.shouldRun else { return }
            let healthy: Bool
            if let listener = self.listener, case .ready = listener.state {
                healthy = true
            } else {
                healthy = false
            }
            guard !healthy else { return }
            self.reopenWorkItem?.cancel()
            self.reopenWorkItem = nil
            self.reopenDelay = 1.0
            self.logHandler("listener not ready on wake, reopening 127.0.0.1:\(self.config.listenPort)")
            self.openListenerLocked(isRestart: true, completion: nil)
        }
    }

    /// Trims idle and oldest connections under iOS memory warning / jetsam pressure.
    public func handleMemoryPressure() {
        let reaped = limiter.reapIdle()
        let trimmed = limiter.trimOldest(fraction: 0.25)
        logHandler("memory pressure: reaped \(reaped) idle, trimmed \(trimmed) oldest connections (footprint \(ProxyFormat.memoryMB(Self.currentMemoryFootprintBytes())))")
        notifyStateChanged()
    }

    /// Resets cumulative traffic & error counters without stopping the server.
    public func resetCounters() {
        statsLock.lock()
        bytesUp = 0
        bytesDown = 0
        dialFailures = 0
        lastError = nil
        statsLock.unlock()
        notifyStateChanged()
    }

    /// Returns an atomic snapshot of server state, traffic totals, active counts, and resident memory.
    public func snapshot() -> ProxySnapshot {
        let counts = limiter.counts()
        statsLock.lock()
        let snap = ProxySnapshot(
            listening: isListening,
            listenPort: actualPort > 0 ? actualPort : config.listenPort,
            requireCellular: config.requireCellular,
            enableUDP: config.enableUDP,
            activeTCPConnections: counts.tcp,
            activeUDPStreams: counts.udpStreams,
            activeUDPFlows: max(0, activeUDPFlows),
            totalConnectionsHandled: counts.totalHandled,
            rejectedConnections: counts.rejected,
            dialFailures: dialFailures,
            listenerRestarts: listenerRestarts,
            traffic: TrafficTotals(bytesUp: bytesUp, bytesDown: bytesDown),
            startedAt: startedAt,
            lastError: lastError,
            memoryUsageBytes: Self.currentMemoryFootprintBytes()
        )
        statsLock.unlock()
        return snap
    }

    // MARK: - Listener Lifecycle

    private func openListenerLocked(
        isRestart: Bool,
        completion: (@Sendable (Result<UInt16, Error>) -> Void)?
    ) {
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        if let tcpOptions = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcpOptions.noDelay = true
        }
        let nwPort: NWEndpoint.Port
        if config.listenPort == 0 {
            nwPort = .any
        } else if let p = NWEndpoint.Port(rawValue: config.listenPort) {
            nwPort = p
        } else {
            let err = SOCKS5Error.malformedAddress
            recordError("invalid listen port \(config.listenPort)")
            completion?(.failure(err))
            return
        }
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: nwPort)

        do {
            let newListener = try NWListener(using: params)
            self.listener = newListener

            var completed = false
            let finish: (Result<UInt16, Error>) -> Void = { result in
                guard !completed else { return }
                completed = true
                completion?(result)
            }

            newListener.stateUpdateHandler = { [weak self, weak newListener] state in
                guard let self, let newListener, self.listener === newListener else { return }
                switch state {
                case .ready:
                    let boundPort = newListener.port?.rawValue ?? self.config.listenPort
                    self.reopenDelay = 1.0
                    self.statsLock.lock()
                    self.isListening = true
                    self.actualPort = boundPort
                    self.lastError = nil
                    if isRestart { self.listenerRestarts &+= 1 }
                    self.statsLock.unlock()
                    self.logHandler("listening on 127.0.0.1:\(boundPort) (cellular=\(self.config.requireCellular), udp=\(self.config.enableUDP))")
                    self.notifyStateChanged()
                    finish(.success(boundPort))

                case .failed(let error):
                    let message: String
                    if case .posix(.EADDRINUSE) = error {
                        message = "포트 \(self.config.listenPort)이(가) 이미 사용 중입니다 (EADDRINUSE). 다른 VPN/프록시 앱을 종료하거나 대기 포트를 10808 등으로 변경하세요."
                    } else {
                        message = "listener failed: \(error)"
                    }
                    self.statsLock.lock()
                    self.isListening = false
                    self.lastError = message
                    self.statsLock.unlock()
                    self.logHandler("listener failed on 127.0.0.1:\(self.config.listenPort): \(error)")
                    self.notifyStateChanged()
                    finish(.failure(error))
                    if self.shouldRun {
                        self.scheduleReopenLocked()
                    }

                case .cancelled:
                    self.statsLock.lock()
                    self.isListening = false
                    self.statsLock.unlock()
                    self.notifyStateChanged()

                case .waiting(let error):
                    self.recordError("listener waiting: \(error)")

                default:
                    break
                }
            }

            newListener.newConnectionHandler = { [weak self] connection in
                self?.acceptConnection(connection)
            }

            newListener.start(queue: controlQueue)
        } catch {
            recordError("failed to create listener: \(error)")
            completion?(.failure(error))
            if shouldRun {
                scheduleReopenLocked()
            }
        }
    }

    private func scheduleReopenLocked() {
        reopenWorkItem?.cancel()
        let delay = reopenDelay
        reopenDelay = min(reopenDelay * 2.0, 30.0)
        logHandler("scheduling listener reopen in \(Int(delay))s")
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.shouldRun else { return }
            self.openListenerLocked(isRestart: true, completion: nil)
        }
        reopenWorkItem = work
        controlQueue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func startReaperLocked() {
        reaperTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: controlQueue)
        let interval = max(1.0, config.reaperInterval)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            guard let self, self.shouldRun else { return }
            let reaped = self.limiter.reapIdle()
            if reaped > 0 {
                self.logHandler("reaped \(reaped) idle connections")
                self.notifyStateChanged()
            }
        }
        timer.resume()
        reaperTimer = timer
    }

    // MARK: - Connection Acceptance

    private func acceptConnection(_ client: NWConnection) {
        let sessionQueue = DispatchQueue(label: "com.local.usbproxy.conn", qos: .userInitiated)
        let session = ClientSession(
            client: client,
            config: config,
            queue: sessionQueue,
            onTraffic: { [weak self] up, down in
                self?.addTraffic(up: up, down: down)
            },
            onDialFailure: { [weak self] reason in
                self?.recordDialFailure(reason)
            },
            onUDPFlowDelta: { [weak self] delta in
                self?.adjustUDPFlows(delta)
            },
            log: logHandler
        )

        guard let id = limiter.admit(
            kind: .tcp,
            idleTimeout: config.tcpIdleTimeout,
            cancel: { session.cancel() }
        ) else {
            client.cancel()
            notifyStateChanged()
            return
        }

        session.bindLifecycle(
            onActivity: { [weak self] in self?.limiter.touch(id) },
            onUpgradeToUoT: { [weak self] in
                guard let self else { return }
                self.limiter.reclassify(id, to: .udpStream, idleTimeout: max(self.config.udpIdleTimeout * 2, 120))
                self.notifyStateChanged()
            },
            onFinished: { [weak self] in
                self?.limiter.release(id)
                self?.notifyStateChanged()
            }
        )
        session.start()
        notifyStateChanged()
    }

    // MARK: - Stats Helpers

    private func addTraffic(up: UInt64, down: UInt64) {
        statsLock.lock()
        bytesUp &+= up
        bytesDown &+= down
        statsLock.unlock()
    }

    private func recordDialFailure(_ reason: String) {
        statsLock.lock()
        dialFailures &+= 1
        lastError = reason
        statsLock.unlock()
    }

    private func recordError(_ message: String) {
        statsLock.lock()
        lastError = message
        statsLock.unlock()
        logHandler(message)
        notifyStateChanged()
    }

    private func adjustUDPFlows(_ delta: Int) {
        statsLock.lock()
        activeUDPFlows = max(0, activeUDPFlows + delta)
        statsLock.unlock()
    }

    private func notifyStateChanged() {
        guard let handler = onStateChanged else { return }
        handler(snapshot())
    }

    /// Current process physical memory footprint (`phys_footprint`), the exact metric enforced by iOS jetsam.
    public static func currentMemoryFootprintBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), intPtr, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return UInt64(info.phys_footprint)
    }
}

// MARK: - Per-Client SOCKS5 + TCP/UoT Session

private final class ClientSession: @unchecked Sendable {
    private enum Phase {
        case greeting
        case request
        case dialing
        case relayingTCP
        case relayingUoT
        case closed
    }

    private let client: NWConnection
    private let config: ProxyConfig
    private let queue: DispatchQueue
    private let onTraffic: @Sendable (_ up: UInt64, _ down: UInt64) -> Void
    private let onDialFailure: @Sendable (String) -> Void
    private let onUDPFlowDelta: @Sendable (_ delta: Int) -> Void
    private let log: @Sendable (String) -> Void

    private var onActivity: @Sendable () -> Void = {}
    private var onUpgradeToUoT: @Sendable () -> Void = {}
    private var onFinished: @Sendable () -> Void = {}

    private var phase: Phase = .greeting
    private var handshakeBuffer = Data()
    private var handshakeTimer: DispatchWorkItem?
    private var dialTimer: DispatchWorkItem?
    private var halfCloseTimer: DispatchWorkItem?

    private var remote: NWConnection?
    private var uotSession: UoTRelaySession?
    private var clientEOF = false
    private var remoteEOF = false

    private static let maxHandshakeBytes = 1024

    init(
        client: NWConnection,
        config: ProxyConfig,
        queue: DispatchQueue,
        onTraffic: @escaping @Sendable (_ up: UInt64, _ down: UInt64) -> Void,
        onDialFailure: @escaping @Sendable (String) -> Void,
        onUDPFlowDelta: @escaping @Sendable (_ delta: Int) -> Void,
        log: @escaping @Sendable (String) -> Void
    ) {
        self.client = client
        self.config = config
        self.queue = queue
        self.onTraffic = onTraffic
        self.onDialFailure = onDialFailure
        self.onUDPFlowDelta = onUDPFlowDelta
        self.log = log
    }

    func bindLifecycle(
        onActivity: @escaping @Sendable () -> Void,
        onUpgradeToUoT: @escaping @Sendable () -> Void,
        onFinished: @escaping @Sendable () -> Void
    ) {
        self.onActivity = onActivity
        self.onUpgradeToUoT = onUpgradeToUoT
        self.onFinished = onFinished
    }

    func start() {
        queue.async { [weak self] in
            guard let self, self.phase != .closed else { return }
            let timer = DispatchWorkItem { [weak self] in
                guard let self, self.phase == .greeting || self.phase == .request else { return }
                self.closeLocked()
            }
            self.handshakeTimer = timer
            self.queue.asyncAfter(deadline: .now() + self.config.handshakeTimeout, execute: timer)

            self.client.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.readHandshakeChunkLocked()
                case .failed, .cancelled:
                    self.closeLocked()
                default:
                    break
                }
            }
            self.client.start(queue: self.queue)
        }
    }

    func cancel() {
        queue.async { [weak self] in
            self?.closeLocked()
        }
    }

    // MARK: - SOCKS5 Handshake

    private func readHandshakeChunkLocked() {
        guard phase == .greeting || phase == .request else { return }
        client.receive(minimumIncompleteLength: 1, maximumLength: 512) { [weak self] content, _, isComplete, error in
            guard let self, self.phase == .greeting || self.phase == .request else { return }
            if let data = content, !data.isEmpty {
                self.handshakeBuffer.append(data)
                if self.handshakeBuffer.count > Self.maxHandshakeBytes {
                    self.closeLocked()
                    return
                }
                self.onActivity()
                self.processHandshakeLocked()
            }
            if error != nil || (isComplete && (self.phase == .greeting || self.phase == .request)) {
                self.closeLocked()
                return
            }
            if self.phase == .greeting || self.phase == .request {
                self.readHandshakeChunkLocked()
            }
        }
    }

    private func processHandshakeLocked() {
        if phase == .greeting {
            do {
                switch try SOCKS5Protocol.parseGreeting(handshakeBuffer) {
                case .needMoreData:
                    return
                case .parsed(let methods, let consumed):
                    handshakeBuffer.removeFirst(consumed)
                    guard methods.contains(SOCKS5Protocol.authNone) else {
                        let reject = SOCKS5Protocol.encodeMethodSelection(SOCKS5Protocol.authNoAcceptable)
                        client.send(content: reject, completion: .contentProcessed { [weak self] _ in
                            self?.closeLocked()
                        })
                        return
                    }
                    phase = .request
                    let accept = SOCKS5Protocol.encodeMethodSelection(SOCKS5Protocol.authNone)
                    client.send(content: accept, completion: .contentProcessed { [weak self] error in
                        if error != nil {
                            self?.closeLocked()
                        }
                    })
                }
            } catch {
                closeLocked()
                return
            }
        }

        if phase == .request && !handshakeBuffer.isEmpty {
            do {
                switch try SOCKS5Protocol.parseRequest(handshakeBuffer) {
                case .needMoreData:
                    return
                case .parsed(let request, let consumed):
                    handshakeBuffer.removeFirst(consumed)
                    handshakeTimer?.cancel()
                    handshakeTimer = nil
                    handleRequestLocked(request)
                }
            } catch let err as SOCKS5Error {
                let code: SOCKS5Reply
                switch err {
                case .unsupportedCommand: code = .commandNotSupported
                case .unsupportedAddressType: code = .addressTypeNotSupported
                default: code = .generalFailure
                }
                sendReplyAndCloseLocked(code)
            } catch {
                sendReplyAndCloseLocked(.generalFailure)
            }
        }
    }

    private func handleRequestLocked(_ request: SOCKS5Request) {
        guard request.command == .connect else {
            sendReplyAndCloseLocked(.commandNotSupported)
            return
        }

        // Stage 3: SagerNet UDP-over-TCP (UoT) v1/v2 magic domains.
        if let uotVersion = UoTProtocol.detectVersion(for: request.destination) {
            guard config.enableUDP else {
                sendReplyAndCloseLocked(.commandNotSupported)
                return
            }
            startUoTSessionLocked(version: uotVersion)
            return
        }

        guard request.destination.port != 0, let nwEndpoint = request.destination.nwEndpoint else {
            sendReplyAndCloseLocked(.hostUnreachable)
            return
        }

        phase = .dialing
        let params = NWParameters.tcp
        if config.requireCellular {
            params.requiredInterfaceType = .cellular
        }
        if let tcpOptions = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcpOptions.noDelay = true
            tcpOptions.enableKeepalive = true
            tcpOptions.keepaliveIdle = config.tcpKeepaliveIdle
            tcpOptions.keepaliveInterval = 30
            tcpOptions.keepaliveCount = 4
            tcpOptions.connectionTimeout = Int(max(1, config.dialTimeout))
        }

        let outbound = NWConnection(to: nwEndpoint, using: params)
        self.remote = outbound

        let timer = DispatchWorkItem { [weak self] in
            guard let self, self.phase == .dialing else { return }
            self.onDialFailure("dial timeout: \(request.destination)")
            self.sendReplyAndCloseLocked(.ttlExpired)
        }
        self.dialTimer = timer
        queue.asyncAfter(deadline: .now() + config.dialTimeout, execute: timer)

        outbound.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard self.phase == .dialing else { return }
                self.dialTimer?.cancel()
                self.dialTimer = nil
                self.phase = .relayingTCP
                let reply = SOCKS5Protocol.encodeReply(.succeeded)
                self.client.send(content: reply, completion: .contentProcessed { [weak self] error in
                    guard let self, self.phase == .relayingTCP else { return }
                    if error != nil {
                        self.closeLocked()
                        return
                    }
                    self.startTCPRelayLocked(outbound: outbound)
                })

            case .failed(let error):
                if self.phase == .dialing {
                    self.dialTimer?.cancel()
                    self.dialTimer = nil
                    self.onDialFailure("dial failed \(request.destination): \(error)")
                    self.sendReplyAndCloseLocked(SOCKS5Protocol.replyCode(for: error))
                } else {
                    self.closeLocked()
                }

            case .cancelled:
                if self.phase != .closed {
                    self.closeLocked()
                }

            default:
                break
            }
        }
        outbound.start(queue: queue)
    }

    private func startUoTSessionLocked(version: UoTVersion) {
        phase = .relayingUoT
        onUpgradeToUoT()
        let trailing = handshakeBuffer
        handshakeBuffer.removeAll(keepingCapacity: false)
        let reply = SOCKS5Protocol.encodeReply(.succeeded)
        client.send(content: reply, completion: .contentProcessed { [weak self] error in
            guard let self, self.phase == .relayingUoT else { return }
            if error != nil {
                self.closeLocked()
                return
            }
            let session = UoTRelaySession(
                version: version,
                client: self.client,
                initialData: trailing,
                config: self.config,
                queue: self.queue,
                onTraffic: self.onTraffic,
                onActivity: self.onActivity,
                onFlowCountDelta: self.onUDPFlowDelta,
                onClosed: { [weak self] in
                    self?.closeLocked()
                },
                log: self.log
            )
            self.uotSession = session
            session.start()
        })
    }

    // MARK: - Bidirectional TCP Relay with Backpressure & Half-Close

    private func startTCPRelayLocked(outbound: NWConnection) {
        let initialClientData = handshakeBuffer
        handshakeBuffer.removeAll(keepingCapacity: false)

        // Remote -> Client direction starts immediately.
        pump(from: outbound, to: client, isUpload: false)

        // Client -> Remote: flush any pipelined bytes received during handshake first.
        if !initialClientData.isEmpty {
            onTraffic(UInt64(initialClientData.count), 0)
            outbound.send(content: initialClientData, completion: .contentProcessed { [weak self] error in
                guard let self, self.phase == .relayingTCP else { return }
                if error != nil {
                    self.closeLocked()
                    return
                }
                self.pump(from: self.client, to: outbound, isUpload: true)
            })
        } else {
            pump(from: client, to: outbound, isUpload: true)
        }
    }

    private func pump(from source: NWConnection, to destination: NWConnection, isUpload: Bool) {
        guard phase == .relayingTCP else { return }
        source.receive(minimumIncompleteLength: 1, maximumLength: config.bufferSize) { [weak self] content, _, isComplete, error in
            guard let self, self.phase == .relayingTCP else { return }

            if let data = content, !data.isEmpty {
                self.onActivity()
                if isUpload {
                    self.onTraffic(UInt64(data.count), 0)
                } else {
                    self.onTraffic(0, UInt64(data.count))
                }
                destination.send(content: data, completion: .contentProcessed { [weak self] sendError in
                    guard let self, self.phase == .relayingTCP else { return }
                    if sendError != nil {
                        self.closeLocked()
                        return
                    }
                    if isComplete || error != nil {
                        self.handleDirectionEOF(destination: destination, isUpload: isUpload)
                    } else {
                        self.pump(from: source, to: destination, isUpload: isUpload)
                    }
                })
                return
            }

            if isComplete || error != nil {
                self.handleDirectionEOF(destination: destination, isUpload: isUpload)
            } else {
                self.pump(from: source, to: destination, isUpload: isUpload)
            }
        }
    }

    private func handleDirectionEOF(destination: NWConnection, isUpload: Bool) {
        if isUpload {
            clientEOF = true
        } else {
            remoteEOF = true
        }

        // Propagate TCP FIN to the opposite side.
        destination.send(
            content: nil,
            contentContext: .finalMessage,
            isComplete: true,
            completion: .contentProcessed { [weak self] _ in
                guard let self else { return }
                if self.clientEOF && self.remoteEOF {
                    self.closeLocked()
                }
            }
        )

        if clientEOF && remoteEOF {
            closeLocked()
            return
        }

        // Guard against peers that never close their half after receiving FIN.
        if halfCloseTimer == nil {
            let timer = DispatchWorkItem { [weak self] in
                self?.closeLocked()
            }
            halfCloseTimer = timer
            queue.asyncAfter(deadline: .now() + config.halfCloseTimeout, execute: timer)
        }
    }

    private func sendReplyAndCloseLocked(_ reply: SOCKS5Reply) {
        let data = SOCKS5Protocol.encodeReply(reply)
        client.send(content: data, completion: .contentProcessed { [weak self] _ in
            self?.closeLocked()
        })
    }

    private func closeLocked() {
        guard phase != .closed else { return }
        phase = .closed
        handshakeTimer?.cancel()
        handshakeTimer = nil
        dialTimer?.cancel()
        dialTimer = nil
        halfCloseTimer?.cancel()
        halfCloseTimer = nil

        let uot = uotSession
        uotSession = nil
        uot?.cancel()

        remote?.stateUpdateHandler = nil
        remote?.cancel()
        remote = nil

        client.stateUpdateHandler = nil
        client.cancel()

        handshakeBuffer.removeAll()
        onFinished()
    }
}
