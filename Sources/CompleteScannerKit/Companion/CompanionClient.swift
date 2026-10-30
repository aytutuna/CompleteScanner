import Foundation
import Security

// The phone's side of the companion link (CompanionProtocol.swift). The requests are the ones the C#
// FakePhone sends in windows/LazyScan.Core.Tests/CompanionLoopbackTests.cs, the desktop's
// only other client: the same paths, Authorization and X-Device-Id after pairing, X-Target on an
// upload. An upload also says what it is (`packageContentType`), where .NET's ByteArrayContent sends
// no Content-Type and URLSession would send a form's.

/// Why a request to the paired desktop failed. A refusal carries the code and message of the
/// desktop's error body, or a message made from the status when it has none.
public enum CompanionClientError: Error, LocalizedError {
    /// No address answered, or the connection broke (the `URLError`).
    case unreachable(Error)
    /// The desktop presented a certificate whose key is not the pinned one.
    case wrongCertificate
    /// 401: the secret is wrong, or the phone was removed on the desktop.
    case unauthorized
    /// 429: too many failures from this address; ask again after `retryAfter` seconds.
    case rateLimited(retryAfter: Int)
    /// 413.
    case tooLarge(CompanionError)
    /// 422: the desktop could not read the package.
    case invalidPackage(CompanionError)
    /// 409 `busy`: the package is still being received.
    case busy(CompanionError)
    /// Any other error status.
    case refused(status: Int, CompanionError)
    /// A success whose body is not the answer expected.
    case badResponse

    public var errorDescription: String? {
        switch self {
        case .unreachable:
            return CompanionText.unreachableMessage
        case .wrongCertificate:
            return CompanionText.wrongCertificateMessage
        case .unauthorized:
            return CompanionError.unauthorized.message
        case .rateLimited:
            return CompanionError.rateLimited.message
        case .tooLarge(let error), .invalidPackage(let error), .busy(let error), .refused(_, let error):
            return error.message
        case .badResponse:
            return CompanionText.badResponseMessage
        }
    }
}

/// Accepts a desktop's TLS certificate only when its key is the pinned one (`CompanionClient.accepts`).
/// The system's trust is not asked: the certificate is self-signed. A refusal cancels the connection
/// before any request is sent and is kept for its host, so the client can tell it from a desktop that
/// does not answer.
final class CompanionTrustDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let fingerprint: Data?
    private let lock = NSLock()
    private var refusedHosts: Set<String> = []

    init(fingerprint: Data?) {
        self.fingerprint = fingerprint
        super.init()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust, let trust = space.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        var certificateDER: Data?
        if let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first {
            certificateDER = SecCertificateCopyData(leaf) as Data
        }
        if CompanionClient.accepts(certificateDER, pinned: fingerprint) {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            lock.lock()
            refusedHosts.insert(CompanionTrustDelegate.key(space.host))
            lock.unlock()
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    /// Whether a certificate was refused at `host` since the last time this was asked.
    func takeRefusal(_ host: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return refusedHosts.remove(CompanionTrustDelegate.key(host)) != nil
    }

    /// A host as both sides name it: IPv6 with or without brackets.
    private static func key(_ host: String) -> String {
        host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
    }
}

/// The companion protocol over URLSession for one desktop: HTTPS to its addresses in turn, its
/// certificate pinned by the fingerprint the pairing code carried. The first address that answers a
/// health check is used for the client's life; when it stops answering, the addresses are tried again
/// once (not for pairing, whose token works once). Ephemeral sessions: nothing cached, no cookies.
/// Errors are `CompanionClientError`s, or `CancellationError` when the task is cancelled.
public final class CompanionClient: @unchecked Sendable {
    /// How long an address may take to answer its health check.
    public static let probeTimeout: TimeInterval = 5
    public static let requestTimeout: TimeInterval = 15
    /// Pairing waits for the user's answer on the desktop (up to 2 minutes there).
    public static let pairTimeout: TimeInterval = 150

    public let desktop: PairedDesktop

    private let session: URLSession
    private let trust: CompanionTrustDelegate
    private let lock = NSLock()
    private var phoneId: String
    private var secret: Data?
    private var current: String?

    /// `protocolClasses` go first in the session's configuration (tests stub the desktop with them).
    public init(desktop: PairedDesktop, secret: Data?, protocolClasses: [AnyClass] = []) {
        self.desktop = desktop
        self.phoneId = desktop.phoneId
        self.secret = secret
        trust = CompanionTrustDelegate(fingerprint: desktop.fingerprintBytes)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = CompanionClient.requestTimeout
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldUsePipelining = false
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        if !protocolClasses.isEmpty {
            configuration.protocolClasses = protocolClasses + (configuration.protocolClasses ?? [])
        }
        session = URLSession(configuration: configuration, delegate: trust, delegateQueue: nil)
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    /// The address that answered; nil until one has.
    public var address: String? {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    /// Whether `certificateDER` is the desktop's: the SHA-256 of its key (`SpkiFingerprint.of`) is
    /// `pinned`. Nothing else about the certificate counts.
    public static func accepts(_ certificateDER: Data?, pinned: Data?) -> Bool {
        guard let der = certificateDER, let pinned = pinned, let fingerprint = SpkiFingerprint.of(der) else { return false }
        return SpkiFingerprint.matches(fingerprint, pinned)
    }

    /// The URL of `path` at `address` (IPv6 in brackets, its zone as %25).
    static func url(_ address: String, port: Int, path: String) -> URL? {
        var host = address
        if host.contains(":") {
            host = "[" + host.replacingOccurrences(of: "%", with: "%25") + "]"
        }
        return URL(string: "https://\(host):\(port)\(path)")
    }

    // MARK: - Requests

    /// `GET /v1/health`, with the credentials when the client has them (a wrong secret is `.unauthorized`).
    public func health() async throws -> HealthResponse {
        let (data, _) = try await perform("GET", CompanionProtocol.healthPath)
        guard let health = HealthResponse.fromJSON(data) else { throw CompanionClientError.badResponse }
        return health
    }

    /// `POST /v1/pair`: waits while the desktop asks its user. On success the client uses the secret it
    /// got; an answer without a valid desktop id or a 32-byte secret is `.badResponse`.
    public func pair(token: String, phoneId: String, phoneName: String, platform: String,
                     appVersion: String) async throws -> PairResponse {
        let request = PairRequest(token: token, phoneId: phoneId, phoneName: phoneName, platform: platform,
                                  appVersion: appVersion)
        let (data, _) = try await perform("POST", CompanionProtocol.pairPath, body: Data(request.toJSON().utf8),
                                          contentType: CompanionProtocol.jsonContentType,
                                          timeout: CompanionClient.pairTimeout)
        guard let response = PairResponse.fromJSON(data), CompanionProtocol.isValidId(response.desktopId),
              let secret = CompanionProtocol.decodeBase64Url(response.deviceSecret),
              secret.count == PairedDeviceStore.secretByteCount
        else { throw CompanionClientError.badResponse }
        lock.lock()
        self.phoneId = phoneId
        self.secret = secret
        lock.unlock()
        return response
    }

    /// `GET /v1/hello`.
    public func hello() async throws -> HelloResponse {
        let (data, _) = try await perform("GET", CompanionProtocol.helloPath)
        guard let hello = HelloResponse.fromJSON(data) else { throw CompanionClientError.badResponse }
        return hello
    }

    /// `PUT /v1/inbox/{packageId}` with the package as its body (Content-Length, never chunked, and
    /// `Expect: 100-continue`, so a desktop that refuses it before reading it is not sent it):
    /// 201 for a new package, 200 with `duplicate` for one the desktop has already.
    public func send(packageId: String, data: Data, target: CompanionTarget) async throws -> InboxResponse {
        // The desktop reads the whole package before it answers; a slow link needs the time.
        let timeout = CompanionClient.pairTimeout + Double(data.count) / 1_000_000
        let headers = [CompanionProtocol.targetHeader: CompanionProtocol.targetValue(target), "Expect": "100-continue"]
        let (body, _) = try await perform("PUT", CompanionProtocol.inboxPrefix + packageId, body: data,
                                          contentType: CompanionProtocol.packageContentType, headers: headers,
                                          timeout: timeout)
        guard let response = InboxResponse.fromJSON(body) else { throw CompanionClientError.badResponse }
        return response
    }

    /// `GET /v1/outbox?wait=N`: what the desktop holds for this phone, waiting up to `wait` seconds
    /// (at most `CompanionProtocol.maxOutboxWaitSeconds`) for something to arrive.
    public func outbox(wait: Int) async throws -> OutboxList {
        let seconds = min(max(wait, 0), CompanionProtocol.maxOutboxWaitSeconds)
        let path = seconds > 0 ? CompanionProtocol.outboxPath + "?wait=\(seconds)" : CompanionProtocol.outboxPath
        let (data, _) = try await perform("GET", path, timeout: CompanionClient.requestTimeout + Double(seconds))
        guard let list = OutboxList.fromJSON(data) else { throw CompanionClientError.badResponse }
        return list
    }

    /// `GET /v1/outbox/{id}`: the file.
    public func outboxItem(id: String) async throws -> Data {
        guard CompanionProtocol.isValidId(id) else { throw CompanionClientError.badResponse }
        let (data, _) = try await perform("GET", CompanionProtocol.outboxPrefix + id, timeout: CompanionClient.pairTimeout)
        return data
    }

    /// `DELETE /v1/outbox/{id}`: the file arrived.
    public func ack(id: String) async throws {
        guard CompanionProtocol.isValidId(id) else { throw CompanionClientError.badResponse }
        _ = try await perform("DELETE", CompanionProtocol.outboxPrefix + id)
    }

    /// `DELETE /v1/devices/self`: the desktop forgets this phone.
    public func unpair() async throws {
        _ = try await perform("DELETE", CompanionProtocol.deviceSelfPath)
    }

    // MARK: - Private

    /// The request at the address in use, found first when there is none; a refusal status is thrown.
    /// When the address in use stops answering, the addresses are tried again once, except for pairing
    /// and for a body the connection broke under. That one is an upload the desktop may have answered
    /// before reading it all, closing on the rest (if CFNetwork did not wait for 100 Continue), so a
    /// bodiless `hello` asks there: 401 is `.unauthorized`, an answer sends the upload once more (the
    /// inbox is idempotent per package id), no answer leaves it `.unreachable`.
    private func perform(_ method: String, _ path: String, body: Data? = nil, contentType: String? = nil,
                         headers: [String: String] = [:],
                         timeout: TimeInterval = CompanionClient.requestTimeout) async throws -> (Data, HTTPURLResponse) {
        var retry = method != "POST"
        var asked = false
        while true {
            let target: String
            if let remembered = address {
                target = remembered
            } else {
                target = try await locate()
                retry = false
            }
            do {
                let answer = try await exchange(method, path, at: target, body: body, contentType: contentType,
                                                headers: headers, timeout: timeout, authenticated: true)
                try CompanionClient.check(answer.0, answer.1)
                return answer
            } catch CompanionClientError.unreachable(let error) {
                if method == "PUT", !asked, let code = (error as? URLError)?.code,
                   !CompanionClient.unconnected.contains(code) {
                    asked = true
                    if try await answersHello(at: target) { continue }
                }
                forget(target)
                let unsent = body == nil || (error as? URLError)?.code == .cannotConnectToHost
                guard retry, unsent else { throw CompanionClientError.unreachable(error) }
                retry = false
            }
        }
    }

    /// Transport errors that mean no connection was made, so nothing of a request was sent.
    private static let unconnected: Set<URLError.Code> = [.cannotConnectToHost, .cannotFindHost, .timedOut,
                                                          .notConnectedToInternet]

    /// Whether the desktop at `address` answers an authenticated `hello`; a 401 is thrown.
    private func answersHello(at address: String) async throws -> Bool {
        do {
            let answer = try await exchange("GET", CompanionProtocol.helloPath, at: address,
                                            timeout: CompanionClient.requestTimeout, authenticated: true)
            try CompanionClient.check(answer.0, answer.1)
            return true
        } catch CompanionClientError.unauthorized {
            throw CompanionClientError.unauthorized
        } catch is CompanionClientError {
            return false
        }
    }

    /// The first address that answers a health check (any status counts), remembered.
    private func locate() async throws -> String {
        var refused = false
        var failure: Error = URLError(.cannotConnectToHost)
        for address in desktop.addresses {
            do {
                _ = try await exchange("GET", CompanionProtocol.healthPath, at: address, timeout: CompanionClient.probeTimeout,
                                       authenticated: false)
                lock.lock()
                current = address
                lock.unlock()
                return address
            } catch CompanionClientError.wrongCertificate {
                refused = true
            } catch CompanionClientError.unreachable(let error) {
                failure = error
            }
        }
        throw refused ? CompanionClientError.wrongCertificate : CompanionClientError.unreachable(failure)
    }

    private func forget(_ address: String) {
        lock.lock()
        if current == address { current = nil }
        lock.unlock()
    }

    /// One request and its answer, whatever its status. A transport failure is `.unreachable`, or
    /// `.wrongCertificate` when the certificate was refused.
    private func exchange(_ method: String, _ path: String, at address: String, body: Data? = nil,
                          contentType: String? = nil, headers: [String: String] = [:], timeout: TimeInterval,
                          authenticated: Bool) async throws -> (Data, HTTPURLResponse) {
        guard let url = CompanionClient.url(address, port: desktop.port, path: path) else {
            throw CompanionClientError.unreachable(URLError(.badURL))
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = method
        lock.lock()
        let id = phoneId
        let key = authenticated ? secret : nil
        lock.unlock()
        if let key = key {
            request.setValue("Bearer " + CompanionProtocol.encodeBase64Url(key), forHTTPHeaderField: "Authorization")
            request.setValue(id, forHTTPHeaderField: CompanionProtocol.deviceIdHeader)
        }
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if let body = body {
            request.httpBody = body
            request.setValue(String(body.count), forHTTPHeaderField: "Content-Length")
            if let contentType = contentType {
                request.setValue(contentType, forHTTPHeaderField: "Content-Type")
            }
        }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw CompanionClientError.unreachable(URLError(.badServerResponse))
            }
            return (data, http)
        } catch let error as URLError {
            if Task.isCancelled { throw CancellationError() }
            if trust.takeRefusal(url.host ?? "") { throw CompanionClientError.wrongCertificate }
            throw CompanionClientError.unreachable(error)
        }
    }

    /// Throws the error an answer's status says; nothing for 2xx.
    static func check(_ data: Data, _ response: HTTPURLResponse) throws {
        let status = response.statusCode
        guard !(200..<300).contains(status) else { return }
        let error = CompanionError.fromJSON(data) ?? CompanionError(code: "", message: CompanionText.refusedMessage(status))
        switch status {
        case 401:
            throw CompanionClientError.unauthorized
        case 429:
            let header = response.value(forHTTPHeaderField: "Retry-After")?.trimmingCharacters(in: .whitespaces)
            throw CompanionClientError.rateLimited(retryAfter: header.flatMap { Int($0) } ?? 60)
        case 413:
            throw CompanionClientError.tooLarge(error)
        case 422:
            throw CompanionClientError.invalidPackage(error)
        case 409 where error.code == CompanionErrorCode.busy:
            throw CompanionClientError.busy(error)
        default:
            throw CompanionClientError.refused(status: status, error)
        }
    }
}
