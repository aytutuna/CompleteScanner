import Foundation
@testable import LazyScanKit

// A desktop played by a URLProtocol stub for CompanionClientTests and AppStateCompanionTests, and an
// in-memory secret store. No request leaves the process; TLS is never reached, so the pinning itself
// is tested on `CompanionClient.accepts` (CompanionLoopbackTests runs the client against the real server).

/// One request as the stub desktop saw it.
struct CompanionStubRequest {
    let method: String
    let host: String
    let path: String
    let query: String
    let headers: [String: String]
    let body: Data

    var key: String { "\(method) \(path)" }

    func header(_ name: String) -> String? {
        for (key, value) in headers where key.caseInsensitiveCompare(name) == .orderedSame {
            return value
        }
        return nil
    }
}

/// What the stub desktop answers one request with.
struct CompanionStubAnswer {
    var status = 200
    var body = Data()
    var headers: [String: String] = [:]
    /// Instead of an answer, the connection fails with this.
    var failure: URLError.Code?
    /// How long the answer takes (a long poll with nothing to give).
    var delay: TimeInterval = 0

    static func json(_ status: Int, _ json: String, headers: [String: String] = [:],
                     delay: TimeInterval = 0) -> CompanionStubAnswer {
        var all = headers
        all["Content-Type"] = CompanionProtocol.jsonContentType
        return CompanionStubAnswer(status: status, body: Data(json.utf8), headers: all, delay: delay)
    }

    static func error(_ status: Int, _ error: CompanionError, headers: [String: String] = [:]) -> CompanionStubAnswer {
        json(status, error.toJSON(), headers: headers)
    }

    static func empty(_ status: Int) -> CompanionStubAnswer {
        CompanionStubAnswer(status: status)
    }
}

/// The desktop: answers per "METHOD /path" (a key ending in "*" takes every path it starts),
/// queued answers used in turn and the last one repeated; `GET /v1/health` answers on its own unless
/// scripted. Hosts in `downHosts` do not answer at all. Every request is recorded.
final class CompanionFakeDesktop: @unchecked Sendable {
    let port: Int
    private let lock = NSLock()
    private var routes: [String: [(CompanionStubRequest) -> CompanionStubAnswer]] = [:]
    private var log: [CompanionStubRequest] = []
    private var down: Set<String> = []

    init() {
        port = CompanionStubRegistry.shared.add()
        CompanionStubRegistry.shared.register(self, port: port)
    }

    func on(_ key: String, _ answers: CompanionStubAnswer...) {
        var handlers: [(CompanionStubRequest) -> CompanionStubAnswer] = []
        for answer in answers {
            handlers.append { _ in answer }
        }
        lock.lock()
        routes[key] = handlers
        lock.unlock()
    }

    func on(_ key: String, _ handler: @escaping (CompanionStubRequest) -> CompanionStubAnswer) {
        lock.lock()
        routes[key] = [handler]
        lock.unlock()
    }

    var downHosts: Set<String> {
        get {
            lock.lock()
            defer { lock.unlock() }
            return down
        }
        set {
            lock.lock()
            down = newValue
            lock.unlock()
        }
    }

    var requests: [CompanionStubRequest] {
        lock.lock()
        defer { lock.unlock() }
        return log
    }

    func requests(_ key: String) -> [CompanionStubRequest] {
        requests.filter { $0.key == key }
    }

    func handle(_ request: CompanionStubRequest) -> CompanionStubAnswer {
        lock.lock()
        log.append(request)
        if down.contains(request.host) {
            lock.unlock()
            return CompanionStubAnswer(failure: .cannotConnectToHost)
        }
        var key = request.key
        if routes[key] == nil {
            for route in routes.keys where route.hasSuffix("*") && key.hasPrefix(String(route.dropLast())) {
                key = route
            }
        }
        guard var queue = routes[key], !queue.isEmpty else {
            lock.unlock()
            if request.key == "GET " + CompanionProtocol.healthPath {
                return .json(200, HealthResponse(protocolVersion: CompanionProtocol.version, paired: false).toJSON())
            }
            return .error(404, CompanionError.notFound)
        }
        let next = queue.count > 1 ? queue.removeFirst() : queue[0]
        routes[key] = queue
        lock.unlock()
        return next(request)
    }
}

/// The stub desktops, by port.
final class CompanionStubRegistry: @unchecked Sendable {
    static let shared = CompanionStubRegistry()

    private let lock = NSLock()
    private var nextPort = 40000
    private var desktops: [Int: CompanionFakeDesktop] = [:]

    func add() -> Int {
        lock.lock()
        defer { lock.unlock() }
        nextPort += 1
        return nextPort
    }

    func register(_ desktop: CompanionFakeDesktop, port: Int) {
        lock.lock()
        desktops[port] = desktop
        lock.unlock()
    }

    func desktop(_ port: Int) -> CompanionFakeDesktop? {
        lock.lock()
        defer { lock.unlock() }
        return desktops[port]
    }
}

/// Plays the registered desktop of each request's port. Answers on URLSession's own thread; a delayed
/// answer holds it.
final class CompanionStubProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let current = request
        guard let url = current.url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let port = components.port, let desktop = CompanionStubRegistry.shared.desktop(port) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        let seen = CompanionStubRequest(method: current.httpMethod ?? "GET", host: components.host ?? "",
                                        path: components.path, query: components.query ?? "",
                                        headers: current.allHTTPHeaderFields ?? [:],
                                        body: CompanionStubProtocol.body(of: current))
        let answer = desktop.handle(seen)
        if answer.delay > 0 {
            Thread.sleep(forTimeInterval: answer.delay)
        }
        if let failure = answer.failure {
            client?.urlProtocol(self, didFailWithError: URLError(failure))
            return
        }
        guard let response = HTTPURLResponse(url: url, statusCode: answer.status, httpVersion: "HTTP/1.1",
                                             headerFields: answer.headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !answer.body.isEmpty {
            client?.urlProtocol(self, didLoad: answer.body)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// A request's body: URLSession hands it to a protocol as a stream.
    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 {
                break
            }
            data.append(contentsOf: buffer[0..<count])
        }
        return data
    }
}

/// Device secrets in memory, as the Keychain keeps them on the phone.
final class MemorySecretStore: CompanionSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: [String: Data] = [:]
    private var failing = false
    private var loadCount = 0

    /// Loading throws while set, as a locked keychain does.
    var loadFails: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return failing
        }
        set {
            lock.lock()
            failing = newValue
            lock.unlock()
        }
    }

    func save(_ secret: Data, for desktopId: String) throws {
        lock.lock()
        secrets[desktopId] = secret
        lock.unlock()
    }

    func load(for desktopId: String) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        loadCount += 1
        if failing { throw CocoaError(.fileReadNoPermission) }
        return secrets[desktopId]
    }

    func delete(for desktopId: String) throws {
        lock.lock()
        secrets[desktopId] = nil
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return secrets.count
    }

    /// How many times a secret was loaded.
    var loads: Int {
        lock.lock()
        defer { lock.unlock() }
        return loadCount
    }
}

enum CompanionLink {
    static let desktopId = "desk-0001-abcd"
    static let phoneId = "phone-0001"
    static let address = "192.168.1.20"

    /// The paired desktop the fake plays, pinned by the shared test certificate's key.
    static func desktop(_ fake: CompanionFakeDesktop, addresses: [String] = [address]) -> PairedDesktop {
        PairedDesktop(id: desktopId, name: "Office PC", fingerprint: CompanionVectors.fingerprintText,
                      addresses: addresses, port: fake.port, phoneId: phoneId)
    }

    static func pairResponse() -> CompanionStubAnswer {
        .json(200, PairResponse(desktopId: desktopId, desktopName: "Office PC", deviceSecret: CompanionVectors.secretText,
                                protocolVersion: CompanionProtocol.version).toJSON())
    }

    static func hello(queuedPages: Int = 0) -> CompanionStubAnswer {
        .json(200, HelloResponse(desktopId: desktopId, desktopName: "Office PC", protocolVersion: CompanionProtocol.version,
                                 queuedPages: queuedPages, maxUploadBytes: CompanionProtocol.maxUploadBytes).toJSON())
    }

    static let unauthorized = CompanionStubAnswer.error(401, CompanionError.unauthorized,
                                                        headers: ["WWW-Authenticate": "Bearer"])
}
