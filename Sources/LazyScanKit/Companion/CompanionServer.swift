import Foundation
import Network
import Security

// Twin of windows/LazyScan.Core/Companion/CompanionServer.cs on the Network framework: one
// NWListener per address with TLS from the desktop's identity, one request per connection, the same
// limits and timeouts. A connection is offered by the listener before it is started, so a peer that is
// refused is closed before TLS.

/// Limits and timeouts of the companion server.
public struct CompanionServerOptions {
    /// Connections served at once; more are closed at once.
    public var maxConnections = 8
    public var handshakeTimeout: TimeInterval = 10
    /// How long the request line and headers may take to arrive.
    public var headTimeout: TimeInterval = 10
    /// How long a body may stall between two reads, and a response between two writes.
    public var idleTimeout: TimeInterval = 30
    /// A refused request's unread body is read and dropped up to this size before closing.
    public var maxDiscardBytes: Int64 = 1024 * 1024
    /// Which peers are answered (others are closed before TLS); every peer when nil.
    public var allowPeer: ((NWEndpoint.Host) -> Bool)?
    /// When stopping, how long requests already being served may take to finish before they are cut off.
    public var stopGrace: TimeInterval = 2

    public init() {}
}

/// Why the server did not start (besides the listeners' own `NWError`).
public enum CompanionServerError: Error, Equatable, Sendable {
    case alreadyRunning
    case nothingToListenOn
    /// The identity cannot be used for TLS.
    case unusableIdentity
}

/// The companion server: TLS 1.2/1.3 over TCP with the desktop's own identity, one request per
/// connection, the small HTTP/1.1 subset of `CompanionHttp`, every request handed to
/// `CompanionRouter`. It listens only on the endpoints it is given (the trusted networks' addresses),
/// closes connections from peers `CompanionServerOptions.allowPeer` refuses or `CompanionRateLimiter`
/// blocks before TLS, and bounds every step in time.
public final class CompanionServer: @unchecked Sendable {
    private struct Served {
        let link: CompanionLink
        var task: Task<Void, Never>?
    }

    private let identity: SecIdentity
    private let router: CompanionRouter
    private let limiter: CompanionRateLimiter
    private let options: CompanionServerOptions
    private let clock: () -> Date
    private let queue = DispatchQueue(label: "CompanionServer")
    private let lock = NSLock()
    private var listeners: [NWListener] = []
    private var served: [Int: Served] = [:]
    private var nextNumber = 0
    private var running = false
    private var bound: [NWEndpoint] = []

    public init(identity: SecIdentity, router: CompanionRouter, limiter: CompanionRateLimiter,
                options: CompanionServerOptions = CompanionServerOptions(), clock: @escaping () -> Date = { Date() }) {
        self.identity = identity
        self.router = router
        self.limiter = limiter
        self.options = options
        self.clock = clock
    }

    /// The endpoints listened on (with the port actually bound); empty when stopped.
    public var localEndpoints: [NWEndpoint] {
        lock.lock()
        defer { lock.unlock() }
        return bound
    }

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    /// The connections being served now.
    public var activeConnections: Int {
        lock.lock()
        defer { lock.unlock() }
        return served.count
    }

    /// Listens on `endpoints` (`.hostPort` each; an address scoped to an interface is listened on there
    /// only). A port of `.any` takes one the system picks; the first
    /// endpoint's port is then used for the others, so all share one port. Throws the listener's
    /// `NWError` (nothing left listening) when one cannot be bound.
    @discardableResult
    public func start(_ endpoints: [NWEndpoint]) async throws -> [NWEndpoint] {
        guard !endpoints.isEmpty else { throw CompanionServerError.nothingToListenOn }
        guard let tlsIdentity = sec_identity_create(identity) else { throw CompanionServerError.unusableIdentity }
        guard begin() else { throw CompanionServerError.alreadyRunning }
        var started: [NWListener] = []
        var endpointsBound: [NWEndpoint] = []
        var sharedPort: NWEndpoint.Port = .any
        do {
            for endpoint in endpoints {
                guard case .hostPort(let host, let port) = endpoint else { throw NWError.posix(.EINVAL) }
                let listener = try NWListener(using: parameters(tlsIdentity, host: host, port: port != .any ? port : sharedPort))
                started.append(listener)
                let actual = try await listen(listener)
                if sharedPort == .any { sharedPort = actual }
                endpointsBound.append(NWEndpoint.hostPort(host: host, port: actual))
            }
        } catch {
            for listener in started {
                listener.cancel()
            }
            finishStart(nil, endpoints: [])
            throw error
        }
        finishStart(started, endpoints: endpointsBound)
        return endpointsBound
    }

    /// Stops listening at once, lets the requests being served finish for `CompanionServerOptions.stopGrace`
    /// (a phone removing itself still gets its answer), then cuts off the rest; nothing listens once it
    /// returns.
    public func stop() async {
        guard let stopping = takeListeners() else { return }
        for listener in stopping {
            listener.newConnectionHandler = nil
            listener.cancel()
        }
        await waitUntilCancelled(stopping)
        await waitForConnections(seconds: options.stopGrace)
        for entry in servedNow() {
            entry.task?.cancel()
            entry.link.cancel()
        }
        await waitForConnections(seconds: 10)
        finishStart(nil, endpoints: [])
    }

    // MARK: - Listening

    private func parameters(_ identity: sec_identity_t, host: NWEndpoint.Host, port: NWEndpoint.Port) -> NWParameters {
        let tls: NWProtocolTLS.Options = NWProtocolTLS.Options()
        let security: sec_protocol_options_t = tls.securityProtocolOptions
        sec_protocol_options_set_local_identity(security, identity)
        sec_protocol_options_set_min_tls_protocol_version(security, .TLSv12)
        sec_protocol_options_set_tls_tickets_enabled(security, false)
        sec_protocol_options_set_tls_resumption_enabled(security, false)
        let tcp: NWProtocolTCP.Options = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters: NWParameters = NWParameters(tls: tls, tcp: tcp)
        parameters.includePeerToPeer = false
        // The port can be taken again at once after a restart, while closed connections still hold it.
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: host, port: port)
        if host == .ipv4(.loopback) || host == .ipv6(.loopback) {
            parameters.requiredInterfaceType = .loopback
        } else if let interface = host.interface {
            // macOS takes a packet for an address on any interface; only the address's own adapter is answered.
            parameters.requiredInterface = interface
        }
        return parameters
    }

    /// Starts `listener`; returns its port once it listens.
    private func listen(_ listener: NWListener) async throws -> NWEndpoint.Port {
        let queue: DispatchQueue = self.queue
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NWEndpoint.Port, Error>) in
            let once: Once<NWEndpoint.Port> = Once(continuation)
            listener.stateUpdateHandler = { (state: NWListener.State) in
                switch state {
                case .ready:
                    once.resume(.success(listener.port ?? .any))
                case .failed(let error), .waiting(let error):
                    if once.resume(.failure(error)) { listener.cancel() }
                case .cancelled:
                    once.resume(.failure(NWError.posix(.ECANCELED)))
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] (connection: NWConnection) in
                self?.accept(connection)
            }
            listener.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 10) {
                if once.resume(.failure(NWError.posix(.ETIMEDOUT))) { listener.cancel() }
            }
        }
    }

    private func accept(_ connection: NWConnection) {
        guard case .hostPort(let remote, _) = connection.endpoint, let link = admit(connection, from: remote) else {
            connection.cancel()
            return
        }
        let task: Task<Void, Never> = Task {
            await self.serve(link.link, remote: remote)
            self.finished(link.number)
        }
        lock.lock()
        served[link.number]?.task = task
        lock.unlock()
    }

    /// The connection counted as served; nil when it is refused (stopped, too many, a peer not answered
    /// or blocked).
    private func admit(_ connection: NWConnection, from remote: NWEndpoint.Host) -> (link: CompanionLink, number: Int)? {
        lock.lock()
        defer { lock.unlock() }
        guard running, served.count < options.maxConnections, options.allowPeer?(remote) ?? true,
              !limiter.isBlocked(remote, now: clock())
        else { return nil }
        nextNumber += 1
        let link = CompanionLink(connection, queue: queue)
        served[nextNumber] = Served(link: link, task: nil)
        return (link, nextNumber)
    }

    // MARK: - Serving

    private func serve(_ link: CompanionLink, remote: NWEndpoint.Host) async {
        defer { link.cancel() }
        guard await link.ready(timeout: options.handshakeTimeout) else { return }
        do {
            try await serveRequest(link, remote: remote)
        } catch {
            // A client that went away or timed out: nothing to answer.
        }
    }

    private func serveRequest(_ link: CompanionLink, remote: NWEndpoint.Host) async throws {
        let capacity = CompanionHttp.maxHeadBytes + 4096
        var buffer = Data()
        var parsed = HttpParseResult(status: .incomplete)
        let deadline = Date().addingTimeInterval(options.headTimeout)
        while parsed.status == .incomplete {
            let left = deadline.timeIntervalSinceNow
            guard left > 0 else { return }
            let chunk = try await link.receive(maxLength: capacity - buffer.count, timeout: left)
            if chunk.isEmpty { return }
            buffer.append(chunk)
            parsed = CompanionHttp.parse(buffer)
            if parsed.status == .incomplete && buffer.count >= capacity {
                parsed = HttpParseResult(status: .invalid, errorStatus: 431)
            }
        }
        guard parsed.status == .complete, let head = parsed.head else {
            try await write(.error(parsed.errorStatus, .badRequest), to: link)
            return
        }

        let idle = options.idleTimeout
        var sendContinue: (() async throws -> Void)?
        if head.expectsContinue {
            sendContinue = { try await link.send(CompanionHttp.continueResponse, timeout: idle) }
        }
        let body = CompanionRequestBody(length: head.contentLength ?? 0, prefix: Data(buffer.dropFirst(parsed.consumed)),
                                        sendContinue: sendContinue) { (maxLength: Int) in
            try await link.receive(maxLength: maxLength, timeout: idle)
        }
        let response = await router.handle(CompanionRequest(head: head, body: body, remote: remote))
        try await write(response, to: link)
        // Leave the client its whole send when it is small, so closing does not cut off the answer.
        _ = try? await body.discard(maxBytes: options.maxDiscardBytes)
    }

    private func write(_ response: CompanionResponse, to link: CompanionLink) async throws {
        defer { try? response.bodyFile?.close() }
        var first = CompanionHttp.responseHead(status: response.status, headers: response.headers,
                                               contentLength: response.length)
        first.append(response.body)
        try await link.send(first, timeout: options.idleTimeout)
        if let file = response.bodyFile {
            while let chunk = try file.read(upToCount: 81920), !chunk.isEmpty {
                try await link.send(chunk, timeout: options.idleTimeout)
            }
        }
    }

    // MARK: - Bookkeeping (with the lock)

    private func begin() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !running else { return false }
        running = true
        return true
    }

    /// Ends a start: listening on `started`, or not at all when it is nil.
    private func finishStart(_ started: [NWListener]?, endpoints: [NWEndpoint]) {
        lock.lock()
        defer { lock.unlock() }
        listeners = started ?? []
        bound = endpoints
        running = started != nil
    }

    private func takeListeners() -> [NWListener]? {
        lock.lock()
        defer { lock.unlock() }
        guard running else { return nil }
        running = false
        let taken = listeners
        listeners = []
        return taken
    }

    private func servedNow() -> [Served] {
        lock.lock()
        defer { lock.unlock() }
        return Array(served.values)
    }

    private func finished(_ number: Int) {
        lock.lock()
        served.removeValue(forKey: number)
        lock.unlock()
    }

    /// Waits (2 s at most) until the listeners have let go of their sockets, so nothing answers on
    /// their addresses once `stop()` returns.
    private func waitUntilCancelled(_ stopped: [NWListener]) async {
        let end = Date().addingTimeInterval(2)
        while Date() < end && stopped.contains(where: { (listener: NWListener) -> Bool in
            if case .cancelled = listener.state { return false }
            return true
        }) {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func waitForConnections(seconds: TimeInterval) async {
        let end = Date().addingTimeInterval(seconds)
        while activeConnections > 0 && Date() < end && !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}

/// One accepted connection: its handshake, reads and writes as async calls, each bounded in time.
/// When one takes too long it fails with ETIMEDOUT, and the server then cancels the connection.
private final class CompanionLink: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue

    init(_ connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    /// Starts the connection; true once its TLS handshake is done.
    func ready(timeout: TimeInterval) async -> Bool {
        let connection: NWConnection = self.connection
        let queue: DispatchQueue = self.queue
        let result: Bool? = try? await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
            let once: Once<Bool> = Once(continuation)
            connection.stateUpdateHandler = { (state: NWConnection.State) in
                switch state {
                case .ready:
                    once.resume(.success(true))
                case .failed, .waiting, .cancelled:
                    once.resume(.success(false))
                default:
                    break
                }
            }
            queue.asyncAfter(deadline: .now() + timeout) {
                once.resume(.success(false))
            }
            connection.start(queue: queue)
        }
        return result ?? false
    }

    /// At most `maxLength` bytes; empty once the peer closed.
    func receive(maxLength: Int, timeout: TimeInterval) async throws -> Data {
        let connection: NWConnection = self.connection
        let queue: DispatchQueue = self.queue
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            let once: Once<Data> = Once(continuation)
            let timer: DispatchWorkItem = DispatchWorkItem {
                once.resume(.failure(NWError.posix(.ETIMEDOUT)))
            }
            queue.asyncAfter(deadline: .now() + timeout, execute: timer)
            connection.receive(minimumIncompleteLength: 1, maximumLength: max(maxLength, 1)) {
                (data: Data?, _: NWConnection.ContentContext?, _: Bool, error: NWError?) in
                timer.cancel()
                if let data, !data.isEmpty {
                    once.resume(.success(data))
                } else if let error {
                    once.resume(.failure(error))
                } else {
                    once.resume(.success(Data()))
                }
            }
        }
    }

    func send(_ data: Data, timeout: TimeInterval) async throws {
        let connection: NWConnection = self.connection
        let queue: DispatchQueue = self.queue
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once: Once<Void> = Once(continuation)
            let timer: DispatchWorkItem = DispatchWorkItem {
                once.resume(.failure(NWError.posix(.ETIMEDOUT)))
            }
            queue.asyncAfter(deadline: .now() + timeout, execute: timer)
            connection.send(content: data, completion: .contentProcessed({ (error: NWError?) in
                timer.cancel()
                if let error {
                    once.resume(.failure(error))
                } else {
                    once.resume(.success(()))
                }
            }))
        }
    }

    func cancel() {
        connection.cancel()
    }
}

/// A continuation resumed by whichever of its callbacks comes first.
private final class Once<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    /// Resumes with `result`; false when it was resumed before.
    @discardableResult
    func resume(_ result: Result<Value, Error>) -> Bool {
        lock.lock()
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(with: result)
        return waiting != nil
    }
}
