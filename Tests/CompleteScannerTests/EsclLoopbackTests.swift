import CoreGraphics
import Foundation
import ImageIO
import Network
import Security
import XCTest
@testable import CompleteScannerKit

// The Swift twins of the two windows/CompleteScanner.Core.Tests/EsclTrustTests.cs cases that go through a
// real TLS connection (AFirstUseCertificateIsPinnedOnlyOnceItsUuidIsChecked,
// HttpsConnectsOnlyOnceTheCertificateIsTrustedAndRefusesAChangedOne), and the network scanner connection
// end to end: a fake eSCL scanner on an NWListener bound to the loopback interface only, over TLS with the
// self-signed identities in Tests/Fixtures/Escl (tls-scanner-a.p12, tls-scanner-b.p12; test fixtures
// only, no key ships in the app), and the client on URLSession with its trust delegate. Nothing is
// advertised (no Bonjour service), nothing listens beyond 127.0.0.1, and every listener is stopped when
// its test ends. Loopback needs no Local Network permission, on the Mac and in the iOS Simulator.
// Differences from C#: the C# server swaps its certificate on the same port; here the second identity is
// served by a second listener, so the changed certificate is recognized by the scanner's UUID rather than
// by its address. On macOS the identities are imported into memory only, which needs macOS 15
// (`kSecImportToMemoryOnly`); earlier systems skip these tests rather than touch a keychain.

/// How the fake scanner answers one request.
private enum LoopbackAnswer {
    case reply(status: Int, headers: [String: String], body: Data)
    /// Keeps the connection open without answering, until the scanner stops.
    case hold
}

private typealias LoopbackResponder = () -> LoopbackAnswer

/// A fake eSCL scanner on 127.0.0.1, over TLS with `identity` or plain HTTP without one. Requests are
/// counted once their headers (and body) have arrived, so a connection refused during the TLS handshake
/// never counts.
private final class LoopbackScanner: @unchecked Sendable {
    private let queue: DispatchQueue = DispatchQueue(label: "EsclLoopbackTests.scanner")
    private let listener: NWListener
    private let lock = NSLock()
    private var scripts: [String: [LoopbackResponder]] = [:]
    private var requestLog: [String] = []
    private var connections: [NWConnection] = []
    private var readyPort: UInt16 = 0

    init(identity: SecIdentity?) throws {
        let parameters: NWParameters
        if let identity {
            let tls: NWProtocolTLS.Options = NWProtocolTLS.Options()
            guard let local: sec_identity_t = sec_identity_create(identity) else {
                throw EsclFormatError("The test identity cannot be used for TLS.")
            }
            sec_protocol_options_set_local_identity(tls.securityProtocolOptions, local)
            // Every connection makes a full handshake, so every one is checked by the client.
            sec_protocol_options_set_tls_tickets_enabled(tls.securityProtocolOptions, false)
            sec_protocol_options_set_tls_resumption_enabled(tls.securityProtocolOptions, false)
            parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        } else {
            parameters = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        }
        // The loopback interface only: nothing on the network can reach it.
        parameters.requiredInterfaceType = .loopback
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: NWEndpoint.Host("127.0.0.1"), port: NWEndpoint.Port.any)
        listener = try NWListener(using: parameters)
    }

    /// Starts listening; returns once the port is known.
    func start() async throws {
        let started: LoopbackStart = LoopbackStart()
        listener.newConnectionHandler = { [weak self] (connection: NWConnection) in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { [weak self] (state: NWListener.State) in
            switch state {
            case .ready:
                if let self, let port = self.listener.port {
                    self.lock.lock()
                    self.readyPort = port.rawValue
                    self.lock.unlock()
                }
                started.finish(nil)
            case .failed(let error):
                started.finish(error)
            case .cancelled:
                started.finish(EsclFormatError("The listener was cancelled."))
            default:
                break
            }
        }
        listener.start(queue: queue)
        try await started.wait(seconds: 10)
    }

    func stop() {
        listener.newConnectionHandler = nil
        listener.cancel()
        lock.lock()
        let open: [NWConnection] = connections
        connections = []
        lock.unlock()
        for connection in open {
            connection.cancel()
        }
    }

    var port: UInt16 {
        lock.lock()
        defer { lock.unlock() }
        return readyPort
    }

    var requests: [String] {
        lock.lock()
        defer { lock.unlock() }
        return requestLog
    }

    func count(_ request: String) -> Int {
        var found: Int = 0
        for logged in requests where logged == request {
            found += 1
        }
        return found
    }

    /// Queues answers for a request ("METHOD /path"); the last one repeats. Others are 404.
    func on(_ request: String, _ answers: LoopbackResponder...) {
        onEach(request, answers)
    }

    /// The same, with the answers in a list.
    func onEach(_ request: String, _ answers: [LoopbackResponder]) {
        lock.lock()
        scripts[request] = answers
        lock.unlock()
    }

    private func accept(_ connection: NWConnection) {
        lock.lock()
        connections.append(connection)
        lock.unlock()
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self]
            (data: Data?, _: NWConnection.ContentContext?, isComplete: Bool, error: NWError?) in
            guard let self else {
                connection.cancel()
                return
            }
            var collected: Data = buffer
            if let data {
                collected.append(data)
            }
            if let request: String = LoopbackScanner.completeRequest(collected) {
                self.answer(request, on: connection)
                return
            }
            if isComplete || error != nil {
                connection.cancel()
                return
            }
            self.receive(connection, buffer: collected)
        }
    }

    /// "METHOD /path" once the request's headers and body are all in; nil before.
    private static func completeRequest(_ data: Data) -> String? {
        let separator: Data = Data("\r\n\r\n".utf8)
        guard let end: Range<Data.Index> = data.range(of: separator) else { return nil }
        let head: String = String(decoding: data[data.startIndex..<end.lowerBound], as: UTF8.self)
        let lines: [String] = head.components(separatedBy: "\r\n")
        var length: Int = 0
        for line in lines.dropFirst() {
            let lowered: String = line.lowercased()
            if lowered.hasPrefix("content-length:") {
                let value: String = String(line.dropFirst("content-length:".count)).trimmingCharacters(in: .whitespaces)
                length = Int(value) ?? 0
            }
        }
        let bodyBytes: Int = data.distance(from: end.upperBound, to: data.endIndex)
        if bodyBytes < length {
            return nil
        }
        guard let first: String = lines.first else { return nil }
        let parts: [String] = first.components(separatedBy: " ")
        guard parts.count >= 2 else { return nil }
        return parts[0] + " " + parts[1]
    }

    private func answer(_ request: String, on connection: NWConnection) {
        lock.lock()
        requestLog.append(request)
        var responder: LoopbackResponder?
        if var queue: [LoopbackResponder] = scripts[request], !queue.isEmpty {
            if queue.count > 1 {
                responder = queue.removeFirst()
                scripts[request] = queue
            } else {
                responder = queue[0]
            }
        }
        lock.unlock()
        var reply: LoopbackAnswer = LoopbackAnswer.reply(status: 404, headers: [:], body: Data())
        if let responder {
            reply = responder()
        }
        switch reply {
        case .hold:
            return
        case .reply(let status, let headers, let body):
            var head: String = "HTTP/1.1 \(status) \(LoopbackScanner.reason(status))\r\n"
            head += "Content-Length: \(body.count)\r\nConnection: close\r\n"
            for (name, value) in headers {
                head += "\(name): \(value)\r\n"
            }
            head += "\r\n"
            var payload: Data = Data(head.utf8)
            payload.append(body)
            connection.send(content: payload, completion: .contentProcessed({ (_: NWError?) in
                connection.cancel()
            }))
        }
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 201: return "Created"
        case 404: return "Not Found"
        case 503: return "Service Unavailable"
        default: return "Status"
        }
    }
}

/// The end of a listener's start: once, with an error or without.
private final class LoopbackStart: @unchecked Sendable {
    private let lock = NSLock()
    private var outcome: Error??
    private var continuation: CheckedContinuation<Void, Error>?

    func finish(_ error: Error?) {
        lock.lock()
        if outcome != nil {
            lock.unlock()
            return
        }
        outcome = .some(error)
        let waiting: CheckedContinuation<Void, Error>? = continuation
        continuation = nil
        lock.unlock()
        if let waiting {
            if let error {
                waiting.resume(throwing: error)
            } else {
                waiting.resume()
            }
        }
    }

    func wait(seconds: TimeInterval) async throws {
        let timeout: Task<Void, Never> = Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            self.finish(EsclFormatError("The listener did not start in time."))
        }
        defer { timeout.cancel() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.lock.lock()
            if let done = self.outcome {
                self.lock.unlock()
                if let error = done {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
                return
            }
            self.continuation = continuation
            self.lock.unlock()
        }
    }
}

/// Background time ended by hand: the test plays the system running out of it.
private typealias LoopbackExpiry = @MainActor () -> Void

@MainActor
private final class LoopbackBackground: BackgroundActivity {
    private(set) var begun: [String] = []
    private(set) var ended: [Int] = []
    /// What `probe` read as each activity was given back.
    private(set) var probedAtEnd: [Int] = []
    /// Read as each activity is given back (the scanner's deletions so far).
    var probe: (() -> Int)?
    private var handlers: [Int: LoopbackExpiry] = [:]
    private var next: Int = 1

    func beginActivity(_ name: String, expired: @escaping @MainActor () -> Void) -> Int? {
        let token: Int = next
        next += 1
        begun.append(name)
        handlers[token] = expired
        return token
    }

    func endActivity(_ token: Int) {
        if handlers.removeValue(forKey: token) != nil {
            ended.append(token)
            if let probe {
                probedAtEnd.append(probe())
            }
        }
    }

    /// The system's time is nearly up for every activity under way: the work is told to stop, and gives
    /// the time back itself once it has wound down.
    func windDownAll() {
        let tokens: [Int] = handlers.keys.sorted()
        for token in tokens {
            if let handler = handlers[token] {
                handler()
            }
        }
    }

    var running: Int { handlers.count }
}

/// Text recognition that cannot run, so no page is read with Vision here.
private struct LoopbackScorer: OrientationScorer {
    var isAvailable: Bool { false }

    func score(_ image: RgbaImage) throws -> OrientationScore {
        OrientationScore.none
    }
}

/// Barcode reading that cannot run.
private struct LoopbackBarcodes: BarcodeReader {
    var isAvailable: Bool { false }

    func read(_ image: GrayImage) throws -> [BarcodeReading] {
        []
    }
}

private let loopbackUuid: String = "564e4333-4230-3538-3930-a0b3cce51a2b"

final class EsclLoopbackTests: XCTestCase {
    private var directory: URL!
    private var scanners: [LoopbackScanner] = []

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("EsclLoopbackTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        for scanner in scanners {
            scanner.stop()
        }
        scanners = []
        // The settings an AppState writes 0.4 s after they change land before the folder goes.
        try await Task.sleep(nanoseconds: 600_000_000)
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Helpers

    /// A loopback identity from the fixtures, imported into memory only.
    private func identity(_ file: String) throws -> SecIdentity {
        let data: Data = try Data(contentsOf: EsclFixtures.url(file))
        var options: [String: Any] = [kSecImportExportPassphrase as String: EsclFixtures.loopbackPassword]
        #if os(macOS)
        if #available(macOS 15.0, *) {
            options[kSecImportToMemoryOnly as String] = true
        } else {
            throw XCTSkip("Importing a test identity without a keychain needs macOS 15.")
        }
        #endif
        var items: CFArray?
        let status: OSStatus = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess, let list = items as? [[String: Any]], let first = list.first,
              let found = first[kSecImportItemIdentity as String] else {
            throw EsclFormatError("\(file) could not be imported (\(status)).")
        }
        return found as! SecIdentity
    }

    /// The SPKI fingerprint of an identity's certificate.
    private func fingerprint(_ identity: SecIdentity) throws -> String {
        var certificate: SecCertificate?
        let status: OSStatus = SecIdentityCopyCertificate(identity, &certificate)
        guard status == errSecSuccess, let found = certificate,
              let print = EsclCertificates.fingerprint(certificateDER: SecCertificateCopyData(found) as Data) else {
            throw EsclFormatError("The identity has no usable certificate.")
        }
        return print
    }

    /// A started loopback scanner, stopped when the test ends.
    private func startScanner(_ identityFile: String?) async throws -> LoopbackScanner {
        var served: SecIdentity?
        if let identityFile {
            served = try identity(identityFile)
        }
        let scanner: LoopbackScanner = try LoopbackScanner(identity: served)
        scanners.append(scanner)
        try await scanner.start()
        XCTAssertGreaterThan(scanner.port, 0)
        return scanner
    }

    private func capabilitiesXml() throws -> String {
        try EsclFixtures.text(EsclFixtures.platenAndDuplexAdfFile)
    }

    private func xml(_ text: String) -> LoopbackResponder {
        return { () -> LoopbackAnswer in
            LoopbackAnswer.reply(status: 200, headers: ["Content-Type": "text/xml"], body: Data(text.utf8))
        }
    }

    private func status(_ code: Int, headers: [String: String] = [:]) -> LoopbackResponder {
        return { () -> LoopbackAnswer in
            LoopbackAnswer.reply(status: code, headers: headers, body: Data())
        }
    }

    private func pngPage(width: Int, height: Int) -> LoopbackResponder {
        let body: Data = EsclLoopbackTests.png(width: width, height: height)
        return { () -> LoopbackAnswer in
            LoopbackAnswer.reply(status: 200, headers: ["Content-Type": "image/png"], body: body)
        }
    }

    private func holding() -> LoopbackResponder {
        return { () -> LoopbackAnswer in
            LoopbackAnswer.hold
        }
    }

    /// A light page with a dark bar, as PNG bytes.
    private static func png(width: Int, height: Int) -> Data {
        let space: CGColorSpace = CGColorSpaceCreateDeviceRGB()
        let context: CGContext = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                           space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.95, green: 0.95, blue: 0.93, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1))
        context.fill(CGRect(x: width / 6, y: height / 2, width: width * 2 / 3, height: max(2, height / 25)))
        let image: CGImage = context.makeImage()!
        let data: NSMutableData = NSMutableData()
        let destination: CGImageDestination = CGImageDestinationCreateWithData(data as CFMutableData, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        _ = CGImageDestinationFinalize(destination)
        return data as Data
    }

    /// A scanner that answers its capabilities and status, and a feeder job: POST, then `pages`.
    private func scriptJob(_ scanner: LoopbackScanner, pages: [LoopbackResponder]) throws {
        scanner.on("GET /eSCL/ScannerCapabilities", xml(try capabilitiesXml()))
        scanner.on("GET /eSCL/ScannerStatus", xml(EsclLoopbackTests.idleStatus))
        scanner.on("POST /eSCL/ScanJobs", status(201, headers: ["Location": "/eSCL/ScanJobs/7"]))
        scanner.on("DELETE /eSCL/ScanJobs/7", status(200))
        var answers: [LoopbackResponder] = pages
        answers.append(status(404))
        scanner.onEach("GET /eSCL/ScanJobs/7/NextDocument", answers)
    }

    private static let idleStatus: String = """
        <?xml version="1.0" encoding="UTF-8"?>
        <scan:ScannerStatus xmlns:scan="http://schemas.hp.com/imaging/escl/2011/05/03" xmlns:pwg="http://www.pwg.org/schemas/2010/12/sm">
          <pwg:Version>2.6</pwg:Version><pwg:State>Idle</pwg:State><scan:AdfState>ScannerAdfLoaded</scan:AdfState>
        </scan:ScannerStatus>
        """

    private func address(_ scanner: LoopbackScanner, secure: Bool = true) throws -> ScannerAddress {
        try ScannerAddress.parse("\(secure ? "https" : "http")://127.0.0.1:\(scanner.port)")
    }

    private func connect(_ validator: EsclCertificateValidator, _ scanner: LoopbackScanner) throws -> EsclClient {
        let base: URL = try XCTUnwrap(try address(scanner).baseURL)
        var options: EsclClientOptions = EsclClientOptions()
        options.pageDirectory = directory.appendingPathComponent("pages", isDirectory: true)
        return EsclClient(baseURL: base, deviceName: "Fake MFP", validator: validator, options: options)
    }

    private func certificateError(_ client: EsclClient, file: StaticString = #filePath,
                                  line: UInt = #line) async -> EsclCertificateError? {
        do {
            _ = try await client.getCapabilities()
            XCTFail("The certificate was not refused", file: file, line: line)
        } catch let error as EsclCertificateError {
            return error
        } catch {
            XCTFail("Unexpected error \(error)", file: file, line: line)
        }
        return nil
    }

    private func fingerprints(_ store: EsclTrustStore) -> [String] {
        var list: [String] = []
        for certificate in store.certificates {
            list.append(certificate.fingerprint)
        }
        return list
    }

    /// A made-up fingerprint: 64 times the letter n places after "a".
    private func madeUp(_ n: Int) -> String {
        let letter: Character = Character(Unicode.Scalar(UInt8(97 + n)))
        return String(repeating: String(letter), count: 64)
    }

    @MainActor
    private func backend(_ addresses: [ScannerAddress], store: EsclTrustStore,
                         background: (any BackgroundActivity)? = nil) -> EsclScannerBackend {
        var endpoints: [EsclEndpoint] = []
        for address in addresses {
            endpoints.append(EsclScannerBackend.endpoint(address))
        }
        // One scanner reached through all the addresses (as discovery would list one device).
        var merged: EsclEndpoint = endpoints[0]
        var all: [ScannerAddress] = []
        for endpoint in endpoints {
            all.append(contentsOf: endpoint.addresses)
        }
        merged.addresses = all
        var options: EsclClientOptions = EsclClientOptions()
        options.pageDirectory = directory.appendingPathComponent("pages", isDirectory: true)
        return EsclScannerBackend(trust: store, endpoints: [merged], clientOptions: options, background: background)
    }

    /// Waits on the main actor until `condition` holds, failing after `timeout` seconds.
    @MainActor
    private func waitFor(_ timeout: TimeInterval, _ condition: () -> Bool,
                         file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline: Date = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("Timed out after \(timeout) s", file: file, line: line)
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    // MARK: - The identities

    func testTheLoopbackIdentitiesHaveTheirFingerprints() throws {
        // The same files and fingerprints as C#'s EsclTrustTests.TheLoopbackIdentitiesHaveTheirFingerprints.
        for vector in EsclFixtures.loopbackIdentities {
            // Imported outside the assertion, so the XCTSkip of earlier systems skips the test.
            let loaded: SecIdentity = try identity(vector.file)
            XCTAssertEqual(try fingerprint(loaded), vector.fingerprint, vector.file)
        }
    }

    // MARK: - Through a real TLS connection (twins of the two C# EsclTrustTests cases)

    func testAFirstUseCertificateIsPinnedOnlyOnceItsUuidIsChecked() async throws {
        let server: LoopbackScanner = try await startScanner("tls-scanner-a.p12")
        server.on("GET /eSCL/ScannerCapabilities", xml(try capabilitiesXml()))
        let presented: String = try fingerprint(try identity("tls-scanner-a.p12"))
        let authority: String = "127.0.0.1:\(server.port)"
        let store: EsclTrustStore = EsclTrustStore(directory: directory)
        // The scanner the server claims to be (its capabilities report the UUID) is trusted with another key, elsewhere.
        try store.trust(madeUp(0), deviceUuid: loopbackUuid, authority: "192.168.1.20:443", name: "HP M479")

        // Reached at an address it was never seen at, without its UUID: the key is new.
        let plain: EsclClient = try connect(EsclCertificateValidator(store: store, deviceUuid: nil, deviceName: "Fake MFP"), server)
        let unknown: EsclCertificateError? = await certificateError(plain)
        XCTAssertEqual(unknown?.verdict, EsclTrustVerdict.unknown)
        XCTAssertEqual(server.requests.count, 0)

        // Used to ask who it is: it reports the trusted scanner's UUID, so it is a change and is not pinned.
        let validator: EsclCertificateValidator = EsclCertificateValidator(store: store, deviceUuid: nil, deviceName: authority,
                                                                           firstUse: presented)
        let client: EsclClient = try connect(validator, server)
        let caps: EsclCapabilities = try await client.getCapabilities()
        do {
            try validator.rememberDevice(caps.uuid)
            XCTFail("A changed certificate was pinned")
        } catch let changed as EsclCertificateError {
            XCTAssertEqual(changed.verdict, EsclTrustVerdict.changed)
            XCTAssertEqual(changed.previous?.fingerprint, madeUp(0))
            XCTAssertEqual(changed.fingerprint, presented)
            XCTAssertEqual(changed.authority, authority)
            XCTAssertEqual(changed.deviceUuid, caps.uuid)
            XCTAssertTrue(changed.canTrust)
        }
        XCTAssertEqual(fingerprints(EsclTrustStore(directory: directory)), [madeUp(0)])
        XCTAssertEqual(store.check(presented, deviceUuid: nil, authority: authority).verdict, EsclTrustVerdict.unknown)
        // Another certificate than the one allowed is still refused.
        let other: EsclClient = try connect(EsclCertificateValidator(store: store, deviceUuid: nil, deviceName: authority,
                                                                     firstUse: madeUp(7)), server)
        let refused: EsclCertificateError? = await certificateError(other)
        XCTAssertEqual(refused?.verdict, EsclTrustVerdict.unknown)
        XCTAssertEqual(server.requests.count, 1)

        // Trusting it for that scanner (the user confirmed the change) replaces the old pin.
        try store.trust(presented, deviceUuid: loopbackUuid, authority: authority, name: "HP M479")
        XCTAssertEqual(fingerprints(store), [presented])

        // A scanner nobody trusted yet: pinned with its UUID once it answered.
        let fresh: URL = directory.appendingPathComponent("fresh", isDirectory: true)
        let freshStore: EsclTrustStore = EsclTrustStore(directory: fresh)
        let firstUse: EsclCertificateValidator = EsclCertificateValidator(store: freshStore, deviceUuid: nil,
                                                                          deviceName: authority, firstUse: presented)
        let freshClient: EsclClient = try connect(firstUse, server)
        let freshCaps: EsclCapabilities = try await freshClient.getCapabilities()
        XCTAssertTrue(freshStore.certificates.isEmpty)
        try firstUse.rememberDevice(freshCaps.uuid)
        let pins: [EsclTrustedCertificate] = EsclTrustStore(directory: fresh).certificates
        XCTAssertEqual(pins.count, 1)
        XCTAssertEqual(pins.first?.fingerprint, presented)
        XCTAssertEqual(pins.first?.deviceUuid, "564e4333423035383930a0b3cce51a2b")
        XCTAssertEqual(pins.first?.addresses ?? [], [authority])
    }

    func testHttpsConnectsOnlyOnceTheCertificateIsTrustedAndRefusesAChangedOne() async throws {
        let first: LoopbackScanner = try await startScanner("tls-scanner-a.p12")
        first.on("GET /eSCL/ScannerCapabilities", xml(try capabilitiesXml()))
        let store: EsclTrustStore = EsclTrustStore(directory: directory)

        let refusing: EsclClient = try connect(EsclCertificateValidator(store: store, deviceUuid: loopbackUuid, deviceName: "Fake MFP"),
                                               first)
        let unknownError: EsclCertificateError? = await certificateError(refusing)
        let unknown: EsclCertificateError = try XCTUnwrap(unknownError)
        XCTAssertEqual(unknown.verdict, EsclTrustVerdict.unknown)
        XCTAssertEqual(unknown.fingerprint, try fingerprint(try identity("tls-scanner-a.p12")))
        XCTAssertEqual(unknown.authority, "127.0.0.1:\(first.port)")
        XCTAssertEqual(first.requests.count, 0) // nothing was sent to an untrusted scanner
        try store.trust(unknown.fingerprint, deviceUuid: loopbackUuid, authority: unknown.authority, name: "Fake MFP")

        let trusted: EsclClient = try connect(EsclCertificateValidator(store: store, deviceUuid: loopbackUuid, deviceName: "Fake MFP"),
                                              first)
        let caps: EsclCapabilities = try await trusted.getCapabilities()
        XCTAssertEqual(caps.makeAndModel, "HP Color LaserJet MFP M479fdw")
        XCTAssertEqual(first.requests.count, 1)

        // The scanner now presents another certificate (here from another listener).
        let second: LoopbackScanner = try await startScanner("tls-scanner-b.p12")
        second.on("GET /eSCL/ScannerCapabilities", xml(try capabilitiesXml()))
        let changedClient: EsclClient = try connect(
            EsclCertificateValidator(store: EsclTrustStore(directory: directory), deviceUuid: loopbackUuid, deviceName: "Fake MFP"),
            second)
        let changedError: EsclCertificateError? = await certificateError(changedClient)
        let changed: EsclCertificateError = try XCTUnwrap(changedError)
        XCTAssertEqual(changed.verdict, EsclTrustVerdict.changed)
        XCTAssertEqual(changed.previous?.fingerprint, unknown.fingerprint)
        XCTAssertTrue(changed.message.hasPrefix("The security certificate of Fake MFP has changed since you trusted it"))
        XCTAssertEqual(second.requests.count, 0)
    }

    // MARK: - The network scanner connection end to end

    @MainActor
    func testAScanJobOverHttpsTrustsTheScannerOnFirstUseAndBringsItsPagesIn() async throws {
        let server: LoopbackScanner = try await startScanner("tls-scanner-a.p12")
        try scriptJob(server, pages: [pngPage(width: 120, height: 160), pngPage(width: 120, height: 160)])
        let store: EsclTrustStore = EsclTrustStore(directory: directory)
        let network: EsclScannerBackend = backend([try address(server)], store: store)
        let state: AppState = AppState(backends: [network], presetStore: PresetStore(directory: directory),
                                       orientationScorer: LoopbackScorer(), barcodeReader: LoopbackBarcodes(),
                                       files: AppStateFiles.all(in: directory))
        var settings: ScanSettings = ScanSettings()
        settings.intent = .document
        settings.documentMultiPage = true
        settings.taskId = nil
        settings.source = .documentFeeder
        settings.duplex = .off
        settings.resolution = 300
        settings.destinationPath = directory.path
        state.settings = settings
        state.start()
        // Connected once the scanner's capabilities are read: its certificate trusted on first use.
        try await waitFor(30) { state.capabilities != nil && state.statusMessage.hasPrefix("Ready") }
        XCTAssertEqual(network.devices.count, 1)
        XCTAssertEqual(network.devices.first?.backend, "escl")
        XCTAssertEqual(fingerprints(EsclTrustStore(directory: directory)), [try fingerprint(try identity("tls-scanner-a.p12"))])
        XCTAssertEqual(EsclTrustStore(directory: directory).certificates.first?.deviceUuid, "564e4333423035383930a0b3cce51a2b")

        state.performScan()
        try await waitFor(60) { !state.isBusy }
        defer { state.deleteSpoolFiles(of: state.scannedPages) }
        XCTAssertNil(state.errorMessage)
        XCTAssertEqual(state.scannedPages.count, 2)
        XCTAssertEqual(state.scannedPages.map(\.source), [PageSource.scanner, PageSource.scanner])
        // Capabilities (the first-use retry; the refused handshake sent nothing), the job, its pages and the
        // end; a job the scanner finished is not deleted.
        XCTAssertGreaterThanOrEqual(server.count("GET /eSCL/ScannerCapabilities"), 1)
        XCTAssertEqual(server.count("POST /eSCL/ScanJobs"), 1)
        XCTAssertEqual(server.count("GET /eSCL/ScanJobs/7/NextDocument"), 3)
        XCTAssertEqual(server.count("DELETE /eSCL/ScanJobs/7"), 0)
        // The pages were downloaded to the page folder and read from there; no download is left.
        let pageFolder: URL = directory.appendingPathComponent("pages", isDirectory: true)
        let left: [String] = (try? FileManager.default.contentsOfDirectory(atPath: pageFolder.path)) ?? []
        XCTAssertFalse(left.contains { (name: String) -> Bool in name.hasPrefix("escl-page-") }, "\(left)")
    }

    @MainActor
    func testCancellingMidJobDeletesTheJobOnTheScanner() async throws {
        let server: LoopbackScanner = try await startScanner("tls-scanner-a.p12")
        try scriptJob(server, pages: [pngPage(width: 80, height: 100), holding()])
        let store: EsclTrustStore = EsclTrustStore(directory: directory)
        let network: EsclScannerBackend = backend([try address(server)], store: store)
        network.startBrowsing()
        let deviceID: String = try XCTUnwrap(network.devices.first?.id)
        let session: any ScannerSession = try await network.openSession(deviceID: deviceID)
        var settings: ScanSettings = ScanSettings()
        settings.source = .documentFeeder
        let feeder: ScanSettings = settings
        let scanning: Task<[ScannedPage], Error> = Task { @MainActor in
            try await session.performScan(settings: feeder, selection: nil)
        }
        // Page 1 is in; the scanner holds page 2.
        try await waitFor(30) { server.count("GET /eSCL/ScanJobs/7/NextDocument") >= 2 }
        session.cancelScan()
        let outcome: Result<[ScannedPage], Error> = await scanning.result
        switch outcome {
        case .success:
            XCTFail("The scan was not cancelled")
        case .failure(let error):
            var cancelled: Bool = false
            if let scanError = error as? ScanError, case .cancelled = scanError {
                cancelled = true
            }
            XCTAssertTrue(cancelled, "\(error)")
        }
        try await waitFor(15) { server.count("DELETE /eSCL/ScanJobs/7") == 1 }
        await session.close()
    }

    @MainActor
    func testTheAppSuspendedMidJobKeepsThePagesAndDeletesTheJob() async throws {
        let server: LoopbackScanner = try await startScanner("tls-scanner-a.p12")
        try scriptJob(server, pages: [pngPage(width: 80, height: 100), holding()])
        let store: EsclTrustStore = EsclTrustStore(directory: directory)
        let cover: LoopbackBackground = LoopbackBackground()
        cover.probe = { () -> Int in
            server.count("DELETE /eSCL/ScanJobs/7")
        }
        let network: EsclScannerBackend = backend([try address(server)], store: store, background: cover)
        network.startBrowsing()
        let deviceID: String = try XCTUnwrap(network.devices.first?.id)
        let session: any ScannerSession = try await network.openSession(deviceID: deviceID)
        var settings: ScanSettings = ScanSettings()
        settings.source = .documentFeeder
        let feeder: ScanSettings = settings
        let scanning: Task<[ScannedPage], Error> = Task { @MainActor in
            try await session.performScan(settings: feeder, selection: nil)
        }
        // Page 1 is in and the scanner holds page 2 when the system's background time is nearly up.
        try await waitFor(30) { server.count("GET /eSCL/ScanJobs/7/NextDocument") >= 2 }
        XCTAssertEqual(cover.begun.count, 1)
        cover.windDownAll()
        let pages: [ScannedPage] = try await scanning.value
        XCTAssertEqual(pages.count, 1)
        XCTAssertEqual(session.lastScanStop?.problem, ScannerProblem.appSuspended)
        XCTAssertEqual(session.lastScanStop?.message(pagesKept: 1),
                       "Scanning stopped after 1 page; it was kept. " + ScannerProblems.describe(.appSuspended))
        // The time is given back only once the deletion has reached the scanner, so the app is not
        // suspended before it is sent.
        try await waitFor(15) { cover.running == 0 }
        XCTAssertEqual(cover.ended.count, 1)
        XCTAssertEqual(cover.probedAtEnd, [1])
        // The deletion was sent once only.
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(server.count("DELETE /eSCL/ScanJobs/7"), 1)
        await session.close()
    }

    @MainActor
    func testAFinishedJobGivesTheBackgroundTimeBack() async throws {
        let server: LoopbackScanner = try await startScanner("tls-scanner-a.p12")
        try scriptJob(server, pages: [pngPage(width: 80, height: 100)])
        let cover: LoopbackBackground = LoopbackBackground()
        let network: EsclScannerBackend = backend([try address(server)], store: EsclTrustStore(directory: directory),
                                                  background: cover)
        network.startBrowsing()
        let deviceID: String = try XCTUnwrap(network.devices.first?.id)
        let session: any ScannerSession = try await network.openSession(deviceID: deviceID)
        var settings: ScanSettings = ScanSettings()
        settings.source = .documentFeeder
        let pages: [ScannedPage] = try await session.performScan(settings: settings, selection: nil)
        XCTAssertEqual(pages.count, 1)
        XCTAssertNil(session.lastScanStop)
        XCTAssertEqual(cover.begun, ["Scanning on 127.0.0.1"])
        try await waitFor(10) { cover.running == 0 }
        XCTAssertEqual(cover.ended.count, 1)
        await session.close()
    }

    @MainActor
    func testARefusedCertificateNeverFallsBackToPlainHttp() async throws {
        // The scanner is trusted with identity A; something at its HTTPS address now presents B, and the
        // same scanner seems to answer over plain HTTP too.
        let impostor: LoopbackScanner = try await startScanner("tls-scanner-b.p12")
        try scriptJob(impostor, pages: [])
        let plain: LoopbackScanner = try await startScanner(nil)
        try scriptJob(plain, pages: [])
        let store: EsclTrustStore = EsclTrustStore(directory: directory)
        try store.trust(try fingerprint(try identity("tls-scanner-a.p12")), deviceUuid: loopbackUuid,
                        authority: "192.168.1.20:443", name: "HP M479")
        let network: EsclScannerBackend = backend([try address(impostor), try address(plain, secure: false)], store: store)
        network.startBrowsing()
        let deviceID: String = try XCTUnwrap(network.devices.first?.id)
        do {
            _ = try await network.openSession(deviceID: deviceID)
            XCTFail("The changed certificate was accepted")
        } catch let error as EsclCertificateError {
            XCTAssertEqual(error.verdict, EsclTrustVerdict.changed)
            XCTAssertTrue(error.canTrust)
        }
        // The plain address was never tried, and nothing new was trusted.
        XCTAssertEqual(plain.requests.count, 0)
        XCTAssertEqual(fingerprints(EsclTrustStore(directory: directory)), [try fingerprint(try identity("tls-scanner-a.p12"))])
    }
}
