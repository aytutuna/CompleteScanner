import Foundation
import Network
import Security
import XCTest
@testable import CompleteScannerKit

// The Swift server end to end, the twin of the windows/CompleteScanner.Core.Tests/CompanionLoopbackTests.cs
// cases about the server: CompanionServer on 127.0.0.1 (loopback only, nothing advertised) with a fixed
// identity from Tests/Fixtures/Companion, and the phone's CompanionClient pinned to that certificate's key,
// as the C# FakePhone is. The cases about the host (networks, advertising, listening only while wanted,
// Reset pairing) are in CompanionHostTests. The identity is imported to memory, so no keychain is needed:
// a runner's keychain refuses new keys (errSecMissingEntitlement).

extension CompanionFixtures {
    /// The desktop identities the loopback server serves: test fixtures only, no key ships in the app.
    static let desktopA = "tls-desktop-a.p12"
    static let desktopB = "tls-desktop-b.p12"

    /// The SHA-256 of the SubjectPublicKeyInfo of `desktopA` and `desktopB`.
    static let desktopAFingerprint = "d0b8817381596dee250bb3b57b81b2fbbe172d3369226ecccd87eea543cd97a2"
    static let desktopBFingerprint = "e648402792146a52071a9fd3c170c3793cfaffaaf3ba4c8d9078276483a6f7da"

    /// The password of the `desktopA` and `desktopB` files.
    static let loopbackPassword = "loopback-desktop"

    /// Tests/Fixtures/Companion in the repository.
    static func url(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CompleteScannerTests
            .deletingLastPathComponent()   // Tests
            .appendingPathComponent("Fixtures/Companion", isDirectory: true)
            .appendingPathComponent(name)
    }
}

/// The server identity of the tests: `desktopA`, and `desktopB` once renewed, so Reset pairing still
/// changes the key.
final class FixtureIdentity: CompanionIdentity {
    private var served: SecIdentity?

    func current(now: Date) throws -> SecIdentity {
        if let served { return served }
        let loaded = try FixtureIdentity.load(CompanionFixtures.desktopA)
        served = loaded
        return loaded
    }

    func renew(now: Date) throws -> SecIdentity {
        let loaded = try FixtureIdentity.load(CompanionFixtures.desktopB)
        served = loaded
        return loaded
    }

    /// A fixture identity, imported into memory only.
    static func load(_ file: String) throws -> SecIdentity {
        let data = try Data(contentsOf: CompanionFixtures.url(file))
        var options: [String: Any] = [kSecImportExportPassphrase as String: CompanionFixtures.loopbackPassword]
        #if os(macOS)
        if #available(macOS 15.0, *) {
            options[kSecImportToMemoryOnly as String] = true
        } else {
            throw XCTSkip("Importing a test identity without a keychain needs macOS 15.")
        }
        #endif
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess, let list = items as? [[String: Any]], let first = list.first,
              let found = first[kSecImportItemIdentity as String] else {
            throw SelfSignedCertificateError("\(file) could not be imported (\(status)).")
        }
        return found as! SecIdentity
    }
}

/// The time the router and the server read, moved by the tests.
private final class LoopbackClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date) {
        current = start
    }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(seconds)
        lock.unlock()
    }
}

/// A hand-written client: plain TCP, or TLS that takes any certificate.
private final class RawConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue

    init(port: Int, tls: Bool) {
        let queue: DispatchQueue = DispatchQueue(label: "CompanionLoopbackTests.raw")
        self.queue = queue
        var options: NWProtocolTLS.Options?
        if tls {
            let made: NWProtocolTLS.Options = NWProtocolTLS.Options()
            sec_protocol_options_set_verify_block(made.securityProtocolOptions, {
                (_: sec_protocol_metadata_t, _: sec_trust_t, complete: @escaping sec_protocol_verify_complete_t) in
                complete(true)
            }, queue)
            options = made
        }
        let parameters: NWParameters = NWParameters(tls: options, tcp: NWProtocolTCP.Options())
        connection = NWConnection(host: NWEndpoint.Host("127.0.0.1"), port: NWEndpoint.Port(rawValue: UInt16(port))!,
                                  using: parameters)
    }

    /// Connects (and makes the TLS handshake); false when that fails within 10 s.
    func open() async -> Bool {
        let connection: NWConnection = self.connection
        let queue: DispatchQueue = self.queue
        let flag: Guarded<Bool> = Guarded(false)
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let finish: (Bool) -> Void = { (ready: Bool) in
                guard !flag.value else { return }
                flag.value = true
                continuation.resume(returning: ready)
            }
            connection.stateUpdateHandler = { (state: NWConnection.State) in
                switch state {
                case .ready: finish(true)
                case .failed, .cancelled, .waiting: finish(false)
                default: break
                }
            }
            queue.asyncAfter(deadline: .now() + 10) { finish(false) }
            connection.start(queue: queue)
        }
    }

    func send(_ data: Data) async {
        let connection: NWConnection = self.connection
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(content: data, completion: .contentProcessed({ (_: NWError?) in
                continuation.resume()
            }))
        }
    }

    /// The next bytes; empty once the server closed, on an error or after `timeout`.
    func receive(timeout: TimeInterval) async -> Data {
        let connection: NWConnection = self.connection
        let queue: DispatchQueue = self.queue
        let flag: Guarded<Bool> = Guarded(false)
        return await withCheckedContinuation { (continuation: CheckedContinuation<Data, Never>) in
            let finish: (Data) -> Void = { (data: Data) in
                guard !flag.value else { return }
                flag.value = true
                continuation.resume(returning: data)
            }
            queue.asyncAfter(deadline: .now() + timeout) { finish(Data()) }
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
                (data: Data?, _: NWConnection.ContentContext?, _: Bool, _: NWError?) in
                finish(data ?? Data())
            }
        }
    }

    func cancel() {
        connection.cancel()
    }
}

final class CompanionLoopbackTests: XCTestCase {
    private var directory: URL!
    private var clock: LoopbackClock!
        private var devices: PairedDeviceStore!
    private var inbox: CompanionInbox!
    private var outbox: CompanionOutbox!
    private var server: CompanionServer?
    private let session = Guarded<PairingSession?>(nil)
    private let received = Guarded<[ReceivedPackage]>([])
    private var port = 0
    private var pin = Data()

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("CompanionLoopbackTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // To the second, as packages and the outbox write dates.
        let clock = LoopbackClock(Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)))
        self.clock = clock
        let serverIdentity = try FixtureIdentity().current(now: clock.now)
        pin = try XCTUnwrap(SelfSignedCertificate.der(of: serverIdentity).flatMap { SpkiFingerprint.of($0) })

        devices = PairedDeviceStore(directory: directory.appendingPathComponent("Settings", isDirectory: true))
        let data = directory.appendingPathComponent("Data", isDirectory: true)
        inbox = CompanionInbox(directory: data.appendingPathComponent("Inbox", isDirectory: true))
        outbox = CompanionOutbox(directory: data.appendingPathComponent("Outbox", isDirectory: true))
        let limiter = CompanionRateLimiter()
        let router = CompanionRouter(devices: devices, inbox: inbox, outbox: outbox, limiter: limiter, clock: { clock.now })
        router.desktopName = { "TEST-MAC" }
        let session = self.session
        router.currentPairing = { session.value }
        let received = self.received
        router.onPackageReceived = { package, _ in received.value.append(package) }
        let server = CompanionServer(identity: serverIdentity, router: router, limiter: limiter, clock: { clock.now })
        self.server = server
        let bound = try await server.start([NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)])
        if case .hostPort(_, let actual) = bound[0] {
            port = Int(actual.rawValue)
        }
        XCTAssertNotEqual(port, 0)
    }

    override func tearDown() async throws {
        await server?.stop()
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    // MARK: - Helpers

    /// A phone pinned to `pin` (the server's by default), paired already when it has a secret.
    private func phone(_ id: String = "phone-0001", pin: Data? = nil, secret: Data? = nil) -> CompanionClient {
        let desktop = PairedDesktop(id: "", name: "", fingerprint: SpkiFingerprint.text(pin ?? self.pin),
                                    addresses: ["127.0.0.1"], port: port, phoneId: id)
        return CompanionClient(desktop: desktop, secret: secret)
    }

    private func openPairing() throws -> PairingSession {
        let opened = try PairingSession(opened: clock.now)
        session.value = opened
        return opened
    }

    private func pair(_ client: CompanionClient, _ token: String, _ id: String = "phone-0001") async throws -> PairResponse {
        try await client.pair(token: token, phoneId: id, phoneName: "Test phone", platform: "ios", appVersion: "1.0")
    }

    /// A paired phone and its secret.
    private func pairedPhone(_ id: String = "phone-0001") async throws -> (client: CompanionClient, secret: String) {
        let opened = try openPairing()
        let client = phone(id)
        let answer = try await pair(client, opened.token, id)
        return (client, answer.deviceSecret)
    }

    /// The status and error code of a refusal; nil when `body` did not fail with one.
    private func refusal(_ body: () async throws -> Void) async -> (status: Int, code: String)? {
        do {
            try await body()
            return nil
        } catch CompanionClientError.refused(let status, let error) {
            return (status, error.code)
        } catch {
            return nil
        }
    }

    private func isUnauthorized(_ body: () async throws -> Void) async -> Bool {
        do {
            try await body()
            return false
        } catch CompanionClientError.unauthorized {
            return true
        } catch {
            return false
        }
    }

    /// Sends a hand-written request over TLS (any certificate) and reads the status and the whole answer.
    private func raw(_ head: String, body: Data? = nil, waitForContinue: Bool = false) async throws -> (status: Int, text: String) {
        let connection = RawConnection(port: port, tls: true)
        defer { connection.cancel() }
        guard await connection.open() else {
            XCTFail("The TLS connection did not open.")
            return (0, "")
        }
        await connection.send(Data(head.utf8))
        if let body {
            if waitForContinue {
                let interim = await connection.receive(timeout: 10)
                XCTAssertEqual(String(decoding: interim, as: UTF8.self), "HTTP/1.1 100 Continue\r\n\r\n")
            }
            await connection.send(body)
        }
        var answer = Data()
        while true {
            let chunk = await connection.receive(timeout: 10)
            if chunk.isEmpty { break }
            answer.append(chunk)
        }
        let text = String(decoding: answer, as: UTF8.self)
        let parts = text.split(separator: " ")
        return (parts.count > 1 ? Int(parts[1]) ?? 0 : 0, text)
    }

    // MARK: - Cases

    func testTheFixtureIdentitiesHaveTheirFingerprints() throws {
        let pinned = [CompanionFixtures.desktopA: CompanionFixtures.desktopAFingerprint,
                      CompanionFixtures.desktopB: CompanionFixtures.desktopBFingerprint]
        for (file, fingerprint) in pinned {
            // Loaded outside the assertion, so the XCTSkip of earlier systems skips the test.
            let identity = try FixtureIdentity.load(file)
            let der = try XCTUnwrap(SelfSignedCertificate.der(of: identity), file)
            let digest = try XCTUnwrap(SpkiFingerprint.of(der), file)
            XCTAssertEqual(SpkiFingerprint.hex(digest), fingerprint, file)
        }
        XCTAssertEqual(SpkiFingerprint.hex(pin), CompanionFixtures.desktopAFingerprint)
    }

    func testPair_ThenSend_AddsTheDocumentOnce() async throws {
        let opened = try openPairing()
        let client = phone()
        let answer = try await pair(client, opened.token)
        XCTAssertEqual(devices.count, 1)
        let device = try XCTUnwrap(devices.devices.first)
        XCTAssertEqual(device.name, "Test phone")
        let secret = try XCTUnwrap(CompanionProtocol.decodeBase64Url(answer.deviceSecret))
        XCTAssertEqual(device.secretHash, PairedDeviceStore.hashSecret(secret))

        let hello = try await client.hello()
        XCTAssertEqual(hello.desktopName, "TEST-MAC")
        let health = try await client.health()
        XCTAssertEqual(health, HealthResponse(protocolVersion: 1, paired: true))

        let package = try CompanionPackage.make(CompanionFixtures.sample)
        let first = try await client.send(packageId: "package-0001", data: package, target: .current)
        XCTAssertEqual(first, InboxResponse(packageId: "package-0001", pageCount: 2, duplicate: false))
        let second = try await client.send(packageId: "package-0001", data: package, target: .new)
        XCTAssertEqual(second, InboxResponse(packageId: "package-0001", pageCount: 2, duplicate: true))

        XCTAssertEqual(received.value.count, 1)
        let arrived = try XCTUnwrap(received.value.first)
        XCTAssertEqual(arrived.target, .current)
        XCTAssertEqual(arrived.document.title, CompanionFixtures.sample.title)
        XCTAssertEqual(try Data(contentsOf: arrived.url), package)
        inbox.release(arrived)
        XCTAssertFalse(FileManager.default.fileExists(atPath: arrived.url.path))
    }

    func testWrongFingerprint_IsRefusedBeforeAnythingIsSent() async throws {
        let opened = try openPairing()
        var other = pin
        other[other.startIndex] ^= 0xFF
        do {
            _ = try await pair(phone(pin: other), opened.token)
            XCTFail("A desktop with another key was paired.")
        } catch CompanionClientError.wrongCertificate {
        } catch {
            XCTFail("\(error)")
        }
        XCTAssertEqual(devices.count, 0)
        XCTAssertEqual(opened.state(at: clock.now), .open)
        // The right pin still pairs with the same code.
        _ = try await pair(phone(), opened.token)
        XCTAssertEqual(devices.count, 1)
    }

    func testExpiredAndReusedTokens_AreRefused() async throws {
        let opened = try openPairing()
        _ = try await pair(phone("phone-0001"), opened.token, "phone-0001")
        let second = phone("phone-0002")
        let reused = await refusal { _ = try await self.pair(second, opened.token, "phone-0002") }
        XCTAssertEqual(reused?.status, 403)
        XCTAssertEqual(reused?.code, CompanionErrorCode.tokenUsed)

        let fresh = try openPairing()
        clock.advance(PairingSession.lifetime)
        let expired = await refusal { _ = try await self.pair(second, fresh.token, "phone-0002") }
        XCTAssertEqual(expired?.code, CompanionErrorCode.tokenExpired)
        let wrong = await refusal { _ = try await self.pair(second, CompanionVectors.tokenText, "phone-0002") }
        XCTAssertEqual(wrong?.status, 403)
        XCTAssertEqual(devices.count, 1)
    }

    func testRemovedPhone_Gets401AndOthersKeepWorking() async throws {
        let kept = try await pairedPhone("phone-0001").client
        let removed = try await pairedPhone("phone-0002").client
        _ = try await removed.hello()
        devices.remove("phone-0002")
        inbox.removeDevice("phone-0002")
        outbox.removeDevice("phone-0002")
        let hello = await isUnauthorized { _ = try await removed.hello() }
        XCTAssertTrue(hello)
        let package = try CompanionPackage.make(CompanionFixtures.minimal)
        let upload = await isUnauthorized { _ = try await removed.send(packageId: "package-0001", data: package, target: .new) }
        XCTAssertTrue(upload)
        XCTAssertTrue(received.value.isEmpty)
        _ = try await kept.hello()
        // The phone forgetting the desktop works the same way.
        try await kept.unpair()
        XCTAssertEqual(devices.count, 0)
    }

    func testMaliciousPackages_AreRefusedAndNotKept() async throws {
        let client = try await pairedPhone().client
        let traversal = ZipStore.make([ZipStoreEntry(name: "manifest.json", data: Data(CompanionFixtures.minimalManifest.utf8)),
                                       ZipStoreEntry(name: "../../evil.txt", data: Data("x".utf8))])
        var damaged = try CompanionPackage.make(CompanionFixtures.minimal)
        damaged[damaged.count - 200] ^= 0xFF
        let uploads: [(String, Data)] = [("package-0001", traversal), ("package-0002", damaged),
                                         ("package-0003", Data("PK\u{3}\u{4} not really".utf8))]
        for (id, bytes) in uploads {
            do {
                _ = try await client.send(packageId: id, data: bytes, target: .new)
                XCTFail("\(id) was received.")
            } catch CompanionClientError.invalidPackage(let error) {
                XCTAssertEqual(error.code, CompanionErrorCode.invalidPackage)
            } catch {
                XCTFail("\(id): \(error)")
            }
        }
        XCTAssertTrue(received.value.isEmpty)
        XCTAssertTrue(inbox.pending().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("Data/evil.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("evil.txt").path))
    }

    func testOversizeAndChunkedUploads_AreRefusedWithoutTheirBody() async throws {
        let secret = try await pairedPhone().secret
        let auth = "Authorization: Bearer \(secret)\r\n\(CompanionProtocol.deviceIdHeader): phone-0001\r\n"
        let tooLarge = CompanionProtocol.maxUploadBytes + 1
        var (status, text) = try await raw(
            "PUT /v1/inbox/package-0001 HTTP/1.1\r\nHost: x\r\n\(auth)Content-Length: \(tooLarge)\r\nExpect: 100-continue\r\n\r\n")
        XCTAssertEqual(status, 413)
        XCTAssertFalse(text.contains("100 Continue"))
        XCTAssertTrue(text.contains("\"tooLarge\""))
        (status, _) = try await raw("PUT /v1/inbox/package-0001 HTTP/1.1\r\nHost: x\r\n\(auth)Content-Length: \(tooLarge)\r\n\r\n")
        XCTAssertEqual(status, 413)
        (status, _) = try await raw("PUT /v1/inbox/package-0001 HTTP/1.1\r\nHost: x\r\n\(auth)Transfer-Encoding: chunked\r\n\r\n")
        XCTAssertEqual(status, 501)
        (status, _) = try await raw("GET /v1/health HTTP/1.1\r\nHost: x\r\nHost: y\r\n\r\n")
        XCTAssertEqual(status, 400)
        // An upload that asks to wait gets "100 Continue", then its answer.
        let package = try CompanionPackage.make(CompanionFixtures.minimal)
        (status, text) = try await raw(
            "PUT /v1/inbox/package-0009 HTTP/1.1\r\nHost: x\r\n\(auth)Content-Length: \(package.count)\r\nExpect: 100-continue\r\n\r\n",
            body: package, waitForContinue: true)
        XCTAssertEqual(status, 201, text)
        XCTAssertEqual(received.value.count, 1)
    }

    func testPlainHttp_GetsNoAnswer() async throws {
        _ = try openPairing()
        let connection = RawConnection(port: port, tls: false)
        defer { connection.cancel() }
        let opened = await connection.open()
        XCTAssertTrue(opened)
        await connection.send(Data("GET /v1/health HTTP/1.1\r\nHost: x\r\n\r\n".utf8))
        let answer = await connection.receive(timeout: 15)
        XCTAssertFalse(String(decoding: answer, as: UTF8.self).hasPrefix("HTTP/"))
    }

    func testRepeatedWrongSecrets_AreCutOff() async throws {
        let good = try await pairedPhone().client
        let bad = phone(secret: CompanionVectors.secret)
        for _ in 0..<CompanionRateLimiter.maxFailures {
            let refused = await isUnauthorized { _ = try await bad.hello() }
            XCTAssertTrue(refused)
        }
        // Blocked: the connection is closed before TLS, even with the right secret.
        do {
            _ = try await good.hello()
            XCTFail("A blocked address was answered.")
        } catch CompanionClientError.unreachable {
        } catch {
            XCTFail("\(error)")
        }
        clock.advance(CompanionRateLimiter.window)
        _ = try await good.hello()
    }

    func testOutbox_ReachesThePhone() async throws {
        let client = try await pairedPhone().client
        let file = directory.appendingPathComponent("Scan.pdf")
        try Data("%PDF-1.7 hello".utf8).write(to: file)
        async let waiting = client.outbox(wait: 10)
        try await Task.sleep(nanoseconds: 200_000_000)
        let item = try outbox.add(deviceId: "phone-0001", source: file, name: "Scan.pdf", contentType: "application/pdf",
                                  now: clock.now)
        let list = try await waiting
        XCTAssertEqual(list.items, [item])
        let download = try await client.outboxItem(id: item.id)
        XCTAssertEqual(String(decoding: download, as: UTF8.self), "%PDF-1.7 hello")
        try await client.ack(id: item.id)
        XCTAssertTrue(outbox.list(deviceId: "phone-0001", now: clock.now).isEmpty)
    }
}
