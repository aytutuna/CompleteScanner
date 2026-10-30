import CoreGraphics
import Foundation
import XCTest
@testable import LazyScanKit

// Mirrors windows/LazyScan.Core.Tests/EsclClientTests.cs (the same 18 cases, a C# theory being
// one test here over the same rows). EsclClient and EsclScannerSession against a URLProtocol stub that
// plays a device, as the C# stub HttpMessageHandler does; retry waits run on a fake clock. Pages are
// "read" by a stub reader: a file holding "PAGE w h" becomes a w×h image, anything else is unreadable.
// Differences: ScanError.scannerProblem has no detail text, so the "(HTTP 409)" the C# message ends with
// is not checked on the error (it is on a stopped batch's reason); the stub answers on URLSession's own
// thread, so a test that holds the job request first waits until the request has reached the device.

/// What the stub device answers one request with.
private enum EsclStubAnswer {
    case reply(status: Int, body: Data, headers: [String: String])
    case failure(URLError.Code)
}

private typealias EsclStubResponder = () -> EsclStubAnswer

/// Lets requests through once opened; until then they wait (at most 30 s).
private final class EsclStubGate: @unchecked Sendable {
    private let group = DispatchGroup()
    private let lock = NSLock()
    private var opened = false

    init() {
        group.enter()
    }

    func wait() {
        _ = group.wait(timeout: .now() + 30)
    }

    func open() {
        lock.lock()
        defer { lock.unlock() }
        if opened { return }
        opened = true
        group.leave()
    }
}

/// A scripted device: responders per request, keyed by "METHOD /path"; records every request.
private final class EsclFakeDevice: @unchecked Sendable {
    private let lock = NSLock()
    private var scripts: [String: [EsclStubResponder]] = [:]
    private var requestLog: [String] = []
    private var bodyLog: [String] = []
    private let adfState: String
    private let state: String
    /// Holds the job request (POST) until opened (the cancel-during-POST tests).
    private var postGate: EsclStubGate?

    init(adfState: String = "ScannerAdfLoaded", state: String = "Idle") {
        self.adfState = adfState
        self.state = state
    }

    /// Queues responses for a request; the last one repeats.
    @discardableResult
    func on(_ request: String, _ responses: EsclStubResponder...) -> EsclFakeDevice {
        lock.lock()
        scripts[request] = responses
        lock.unlock()
        return self
    }

    /// From now on the job request waits until the gate returned is opened.
    func holdPosts() -> EsclStubGate {
        let gate: EsclStubGate = EsclStubGate()
        lock.lock()
        postGate = gate
        lock.unlock()
        return gate
    }

    var requests: [String] {
        lock.lock()
        defer { lock.unlock() }
        return requestLog
    }

    var bodies: [String] {
        lock.lock()
        defer { lock.unlock() }
        return bodyLog
    }

    func handle(method: String, path: String, body: Data) -> EsclStubAnswer {
        let key: String = "\(method) \(path)"
        lock.lock()
        requestLog.append(key)
        if !body.isEmpty {
            bodyLog.append(String(decoding: body, as: UTF8.self))
        }
        let gate: EsclStubGate? = postGate
        lock.unlock()
        if method == "POST", let gate {
            gate.wait()
        }
        lock.lock()
        if key == "GET /eSCL/ScannerStatus" && scripts[key] == nil {
            let xml: String = EsclFakeDevice.status(state, adfState)
            lock.unlock()
            return EsclStubAnswer.reply(status: 200, body: Data(xml.utf8), headers: ["Content-Type": "text/xml"])
        }
        guard var queue: [EsclStubResponder] = scripts[key], !queue.isEmpty else {
            lock.unlock()
            return EsclStubAnswer.reply(status: 404, body: Data(), headers: [:])
        }
        let next: EsclStubResponder
        if queue.count > 1 {
            next = queue.removeFirst()
            scripts[key] = queue
        } else {
            next = queue[0]
        }
        lock.unlock()
        return next()
    }

    static func status(_ state: String, _ adfState: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <scan:ScannerStatus xmlns:scan="http://schemas.hp.com/imaging/escl/2011/05/03" xmlns:pwg="http://www.pwg.org/schemas/2010/12/sm">
          <pwg:Version>2.6</pwg:Version><pwg:State>\(state)</pwg:State><scan:AdfState>\(adfState)</scan:AdfState>
        </scan:ScannerStatus>
        """
    }
}

/// The devices the stub plays, by host name.
private final class EsclStubRegistry: @unchecked Sendable {
    static let shared: EsclStubRegistry = EsclStubRegistry()

    private let lock = NSLock()
    private var devices: [String: EsclFakeDevice] = [:]

    func register(_ device: EsclFakeDevice, host: String) {
        lock.lock()
        devices[host.lowercased()] = device
        lock.unlock()
    }

    func device(for url: URL) -> EsclFakeDevice? {
        guard let host: String = URLComponents(url: url, resolvingAgainstBaseURL: false)?.host else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return devices[host.lowercased()]
    }
}

/// Plays the registered device for every request of a session configured with it.
private final class EsclStubProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let current: URLRequest = self.request
        guard let url: URL = current.url, let device: EsclFakeDevice = EsclStubRegistry.shared.device(for: url) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        let path: String = URLComponents(url: url, resolvingAgainstBaseURL: false)?.path ?? ""
        let answer: EsclStubAnswer = device.handle(method: current.httpMethod ?? "GET", path: path,
                                                    body: EsclStubProtocol.body(of: current))
        switch answer {
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .reply(let status, let body, let headers):
            guard let response: HTTPURLResponse = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                                                  headerFields: headers) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !body.isEmpty {
                client?.urlProtocol(self, didLoad: body)
            }
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}

    /// A request's body: URLSession hands it to a protocol as a stream.
    private static func body(of request: URLRequest) -> Data {
        if let body: Data = request.httpBody {
            return body
        }
        guard let stream: InputStream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data: Data = Data()
        let capacity: Int = 4096
        var buffer: [UInt8] = [UInt8](repeating: 0, count: capacity)
        while stream.hasBytesAvailable {
            let count: Int = stream.read(&buffer, maxLength: capacity)
            if count <= 0 {
                break
            }
            data.append(contentsOf: buffer[0..<count])
        }
        return data
    }
}

/// Retry waits that take no time, recorded.
private final class EsclFakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var elapsed: TimeInterval = 0
    private var waits: [TimeInterval] = []

    var now: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return elapsed
    }

    var delays: [TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return waits
    }

    func delay(_ wait: TimeInterval) throws {
        try Task.checkCancellation()
        lock.lock()
        waits.append(wait)
        elapsed += wait
        lock.unlock()
    }
}

/// Messages recorded from any thread.
private final class EsclMessages: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [String] = []

    func add(_ message: String) {
        lock.lock()
        list.append(message)
        lock.unlock()
    }

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return list
    }
}

/// The scan task a responder cancels (the user cancelling while page 1 arrives).
private final class EsclTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<EsclJobResult, Error>?

    func set(_ task: Task<EsclJobResult, Error>) {
        lock.lock()
        self.task = task
        lock.unlock()
    }

    func cancel() {
        let deadline: Date = Date().addingTimeInterval(5)
        while Date() < deadline {
            lock.lock()
            let current: Task<EsclJobResult, Error>? = task
            lock.unlock()
            if let current {
                current.cancel()
                return
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }
}

private func respond(_ status: Int) -> EsclStubResponder {
    return { () -> EsclStubAnswer in
        EsclStubAnswer.reply(status: status, body: Data(), headers: [:])
    }
}

private func text(_ status: Int, _ body: String) -> EsclStubResponder {
    return { () -> EsclStubAnswer in
        EsclStubAnswer.reply(status: status, body: Data(body.utf8), headers: ["Content-Type": "text/xml"])
    }
}

private func page(_ width: Int, _ height: Int) -> EsclStubResponder {
    return { () -> EsclStubAnswer in
        EsclStubAnswer.reply(status: 200, body: Data("PAGE \(width) \(height)".utf8), headers: [:])
    }
}

private func garbage() -> EsclStubResponder {
    return { () -> EsclStubAnswer in
        EsclStubAnswer.reply(status: 200, body: Data("not an image".utf8), headers: [:])
    }
}

private func created(_ location: String) -> EsclStubResponder {
    return { () -> EsclStubAnswer in
        EsclStubAnswer.reply(status: 201, body: Data(), headers: ["Location": location])
    }
}

private func failWith(_ code: URLError.Code) -> EsclStubResponder {
    return { () -> EsclStubAnswer in
        EsclStubAnswer.failure(code)
    }
}

/// A blank w×h image.
private func blankImage(width: Int, height: Int) -> CGImage {
    let space: CGColorSpace = CGColorSpaceCreateDeviceRGB()
    let context: CGContext = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                       space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    return context.makeImage()!
}

/// The stub page reader: "PAGE w h" is a w×h page.
private func readStubPage(_ file: URL) throws -> CGImage {
    let content: String = String(decoding: try Data(contentsOf: file), as: UTF8.self)
    let parts: [String] = content.components(separatedBy: " ")
    guard parts.count == 3, parts[0] == "PAGE", let width = Int(parts[1]), let height = Int(parts[2]) else {
        throw EsclFormatError("unknown image format")
    }
    return blankImage(width: width, height: height)
}

private func isCancelled(_ error: ScanError?) -> Bool {
    guard let error else { return false }
    if case .cancelled = error {
        return true
    }
    return false
}

private func isScanFailed(_ error: ScanError?) -> Bool {
    guard let error else { return false }
    if case .scanFailed = error {
        return true
    }
    return false
}

private func isUnsupported(_ error: ScanError?) -> Bool {
    guard let error else { return false }
    if case .unsupported = error {
        return true
    }
    return false
}

/// A host name of its own for each fake device, so a job deletion a test leaves in flight can never
/// reach the device of the test after it.
private func uniqueStubHost() -> String {
    "scanner-\(UUID().uuidString.lowercased()).test"
}

final class EsclClientTests: XCTestCase {
    private var pageFolder: URL!

    override func setUpWithError() throws {
        pageFolder = FileManager.default.temporaryDirectory.appendingPathComponent("EsclClientTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: pageFolder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: pageFolder)
    }

    private func makeClient(_ device: EsclFakeDevice, clock: EsclFakeClock = EsclFakeClock(),
                            host stubHost: String = uniqueStubHost()) -> EsclClient {
        EsclStubRegistry.shared.register(device, host: stubHost)
        let configuration: URLSessionConfiguration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [EsclStubProtocol.self]
        var options: EsclClientOptions = EsclClientOptions()
        options.configuration = configuration
        options.delay = { (wait: TimeInterval) async throws -> Void in
            try clock.delay(wait)
        }
        options.startClock = { () -> (() -> TimeInterval) in
            return { () -> TimeInterval in clock.now }
        }
        options.pageDirectory = pageFolder
        options.readPage = readStubPage
        let base: URL = URL(string: "http://\(stubHost)/eSCL/")!
        return EsclClient(baseURL: base, deviceName: "Fake MFP", validator: nil, options: options)
    }

    private func capabilities(_ file: String = EsclFixtures.platenAndDuplexAdfFile) throws -> EsclCapabilities {
        try EsclCapabilitiesParser.parse(try EsclFixtures.text(file))
    }

    private func feederRequest() throws -> EsclScanRequest {
        EsclScanRequest.create(try capabilities(), source: .documentFeeder, colorMode: .grayscale, dpi: 300, selection: nil)
    }

    private func scan(_ client: EsclClient) async throws -> EsclJobResult {
        try await client.scan(try feederRequest(), colorMode: .grayscale, source: .documentFeeder, progress: nil)
    }

    /// The ScanError a scan fails with; a failure when it does not fail that way.
    private func scanError(_ client: EsclClient, file: StaticString = #filePath, line: UInt = #line) async -> ScanError? {
        do {
            _ = try await scan(client)
            XCTFail("The scan did not fail", file: file, line: line)
        } catch let error as ScanError {
            return error
        } catch {
            XCTFail("Unexpected error \(error)", file: file, line: line)
        }
        return nil
    }

    /// Waits until `condition` holds, failing after `timeout` seconds.
    private func waitFor(_ timeout: TimeInterval, _ condition: () -> Bool,
                         file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline: Date = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("Timed out after \(timeout) s", file: file, line: line)
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func pageFiles() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: pageFolder.path)
    }

    // MARK: - Capabilities

    func testReadsTheCapabilities() async throws {
        let device: EsclFakeDevice = EsclFakeDevice().on("GET /eSCL/ScannerCapabilities",
                                                          text(200, try EsclFixtures.text(EsclFixtures.platenAndDuplexAdfFile)))
        let client: EsclClient = makeClient(device)
        let caps: EsclCapabilities = try await client.getCapabilities()
        XCTAssertEqual(caps.makeAndModel, "HP Color LaserJet MFP M479fdw")
        XCTAssertTrue(caps.hasPlaten && caps.hasAdf)
        XCTAssertEqual(device.requests, ["GET /eSCL/ScannerCapabilities"])
    }

    func testCapabilitiesFailuresKeepTheirKind() async throws {
        let missing: EsclClient = makeClient(EsclFakeDevice())
        do {
            _ = try await missing.getCapabilities()
            XCTFail("No error")
        } catch let error as EsclHttpError {
            XCTAssertEqual(error.statusCode, 404)
        }

        let notXml: EsclClient = makeClient(EsclFakeDevice().on("GET /eSCL/ScannerCapabilities",
                                                                text(200, "<html>printer home page")))
        do {
            _ = try await notXml.getCapabilities()
            XCTFail("No error")
        } catch is EsclFormatError {
            // The kind the C# FormatException is.
        }
    }

    // MARK: - Jobs

    func testBusyAnswersAreRetriedThenPagesUntil404() async throws {
        let device: EsclFakeDevice = EsclFakeDevice()
            .on("POST /eSCL/ScanJobs", respond(503), created("ScanJobs/7"))
            .on("GET /eSCL/ScanJobs/7/NextDocument", respond(503), page(10, 20), page(10, 20), respond(404))
        let clock: EsclFakeClock = EsclFakeClock()
        let client: EsclClient = makeClient(device, clock: clock)
        let progress: EsclMessages = EsclMessages()
        let result: EsclJobResult = try await client.scan(try feederRequest(), colorMode: .grayscale, source: .documentFeeder,
                                                          progress: { (update: ScanProgress) in progress.add(update.message) })

        XCTAssertEqual(result.pages.count, 2)
        XCTAssertNil(result.stop)
        for scanned in result.pages {
            XCTAssertEqual(scanned.dpi, 300)
            XCTAssertEqual(scanned.colorMode, ColorMode.grayscale)
            XCTAssertEqual(scanned.image.width, 10)
        }
        XCTAssertEqual(progress.all, ["Transferring page 1…", "Transferring page 2…"])
        XCTAssertEqual(clock.delays, [0.5, 0.5])
        // A job the device finished (404) is not deleted.
        await client.whenCleanedUp()
        XCTAssertEqual(device.requests, [
            "POST /eSCL/ScanJobs", "POST /eSCL/ScanJobs",
            "GET /eSCL/ScanJobs/7/NextDocument", "GET /eSCL/ScanJobs/7/NextDocument",
            "GET /eSCL/ScanJobs/7/NextDocument", "GET /eSCL/ScanJobs/7/NextDocument",
        ])
        XCTAssertTrue(device.bodies[0].contains("<pwg:InputSource>Feeder</pwg:InputSource>"))
        // The pages went through files in the page folder, which are gone once read.
        XCTAssertEqual(try pageFiles(), [])
    }

    func testJobLocationsResolve() async throws {
        // Relative to the ScanJobs URL, host-relative with a trailing slash, absolute.
        let host: String = uniqueStubHost()
        for location in ["ScanJobs/7", "/eSCL/ScanJobs/7/", "http://\(host)/eSCL/ScanJobs/7"] {
            let device: EsclFakeDevice = EsclFakeDevice()
                .on("POST /eSCL/ScanJobs", created(location))
                .on("GET /eSCL/ScanJobs/7/NextDocument", page(4, 4), respond(404))
            let client: EsclClient = makeClient(device, host: host)
            let result: EsclJobResult = try await scan(client)
            XCTAssertEqual(result.pages.count, 1, location)
        }
    }

    func testAJobEndingBeforeItsFirstPageReportsTheEmptyFeeder() async throws {
        let device: EsclFakeDevice = EsclFakeDevice(adfState: "ScannerAdfEmpty")
            .on("POST /eSCL/ScanJobs", created("ScanJobs/7"))
            .on("GET /eSCL/ScanJobs/7/NextDocument", respond(404))
        let client: EsclClient = makeClient(device)
        let error: ScanError? = await scanError(client)
        XCTAssertEqual(error?.problem, ScannerProblem.feederEmpty)
        XCTAssertEqual(error?.localizedDescription, ScannerProblems.describe(.feederEmpty))
        await client.whenCleanedUp()
        XCTAssertFalse(device.requests.contains { (request: String) -> Bool in request.hasPrefix("DELETE") })
    }

    func testAJobEndingWithoutPagesWhileTheFeederLooksFineReturnsNothing() async throws {
        let device: EsclFakeDevice = EsclFakeDevice()
            .on("POST /eSCL/ScanJobs", created("ScanJobs/7"))
            .on("GET /eSCL/ScanJobs/7/NextDocument", respond(404))
        let client: EsclClient = makeClient(device)
        let result: EsclJobResult = try await scan(client)
        XCTAssertTrue(result.pages.isEmpty)
        XCTAssertNil(result.stop)
    }

    func testARejectedJobIsExplainedByTheStatus() async throws {
        let device: EsclFakeDevice = EsclFakeDevice(adfState: "ScannerAdfJam").on("POST /eSCL/ScanJobs", respond(409))
        let client: EsclClient = makeClient(device)
        let error: ScanError? = await scanError(client)
        XCTAssertEqual(error?.problem, ScannerProblem.paperJam)

        let plain: EsclFakeDevice = EsclFakeDevice().on("POST /eSCL/ScanJobs", respond(400))
        let plainClient: EsclClient = makeClient(plain)
        let rejected: ScanError? = await scanError(plainClient)
        XCTAssertTrue(isScanFailed(rejected))
        XCTAssertEqual(rejected?.localizedDescription, "Scan failed: Fake MFP rejected the scan job (HTTP 400).")
    }

    func testABusyDeviceThatNeverAcceptsIsReportedBusy() async throws {
        let device: EsclFakeDevice = EsclFakeDevice().on("POST /eSCL/ScanJobs", respond(503))
        let clock: EsclFakeClock = EsclFakeClock()
        let client: EsclClient = makeClient(device, clock: clock)
        let error: ScanError? = await scanError(client)
        XCTAssertEqual(error?.problem, ScannerProblem.busy)
        XCTAssertLessThanOrEqual(clock.now, 60)
        var posts: Int = 0
        for request in device.requests where request == "POST /eSCL/ScanJobs" {
            posts += 1
        }
        XCTAssertEqual(posts, 16)
    }

    func testAFailureAfterTheFirstPageKeepsThePagesAndDeletesTheJob() async throws {
        let device: EsclFakeDevice = EsclFakeDevice(adfState: "ScannerAdfJam")
            .on("POST /eSCL/ScanJobs", created("ScanJobs/7"))
            .on("GET /eSCL/ScanJobs/7/NextDocument", page(4, 4), respond(500))
        let client: EsclClient = makeClient(device)
        let result: EsclJobResult = try await scan(client)
        XCTAssertEqual(result.pages.count, 1)
        XCTAssertEqual(result.stop?.problem, ScannerProblem.paperJam)
        XCTAssertEqual(result.stop?.message(pagesKept: 1),
                       "Scanning stopped after 1 page; it was kept. " + ScannerProblems.describe(.paperJam) + " (HTTP 500)")
        await client.whenCleanedUp()
        XCTAssertEqual(device.requests.last, "DELETE /eSCL/ScanJobs/7")
    }

    func testAnUnreadablePageStopsTheBatchOrFailsTheScan() async throws {
        let later: EsclFakeDevice = EsclFakeDevice()
            .on("POST /eSCL/ScanJobs", created("ScanJobs/7"))
            .on("GET /eSCL/ScanJobs/7/NextDocument", page(4, 4), garbage())
        let laterClient: EsclClient = makeClient(later)
        let result: EsclJobResult = try await scan(laterClient)
        XCTAssertEqual(result.pages.count, 1)
        XCTAssertTrue(result.stop?.reason.hasPrefix("Scan failed: Fake MFP sent page 2 in a form that could not be read") == true,
                      result.stop?.reason ?? "no stop")
        await laterClient.whenCleanedUp()
        XCTAssertTrue(later.requests.contains("DELETE /eSCL/ScanJobs/7"))

        let first: EsclFakeDevice = EsclFakeDevice()
            .on("POST /eSCL/ScanJobs", created("ScanJobs/7"))
            .on("GET /eSCL/ScanJobs/7/NextDocument", garbage())
        let firstClient: EsclClient = makeClient(first)
        let error: ScanError? = await scanError(firstClient)
        XCTAssertTrue(isScanFailed(error))
        XCTAssertEqual(try pageFiles(), [])
    }

    func testCancellingMidJobThrowsCancelledAndDeletesTheJob() async throws {
        let box: EsclTaskBox = EsclTaskBox()
        let device: EsclFakeDevice = EsclFakeDevice()
            .on("POST /eSCL/ScanJobs", created("ScanJobs/7"))
            .on("GET /eSCL/ScanJobs/7/NextDocument", { () -> EsclStubAnswer in
                box.cancel() // the user cancels while page 1 arrives
                return page(4, 4)()
            })
        let client: EsclClient = makeClient(device)
        let request: EsclScanRequest = try feederRequest()
        let scanning: Task<EsclJobResult, Error> = Task {
            try await client.scan(request, colorMode: .grayscale, source: .documentFeeder, progress: nil)
        }
        box.set(scanning)
        let outcome: Result<EsclJobResult, Error> = await scanning.result
        switch outcome {
        case .success:
            XCTFail("The scan was not cancelled")
        case .failure(let error):
            XCTAssertTrue(isCancelled(error as? ScanError), "\(error)")
        }
        await client.whenCleanedUp()
        XCTAssertEqual(device.requests.last, "DELETE /eSCL/ScanJobs/7")
    }

    func testCancellingDuringThePostDeletesTheJobOnceItIsCreated() async throws {
        let device: EsclFakeDevice = EsclFakeDevice().on("POST /eSCL/ScanJobs", created("ScanJobs/7"))
        let gate: EsclStubGate = device.holdPosts()
        let client: EsclClient = makeClient(device)
        let request: EsclScanRequest = try feederRequest()
        let scanning: Task<EsclJobResult, Error> = Task {
            try await client.scan(request, colorMode: .grayscale, source: .documentFeeder, progress: nil)
        }
        // The job request has reached the device, which holds its answer.
        try await waitFor(10) { device.requests.count >= 1 }
        scanning.cancel()
        let outcome: Result<EsclJobResult, Error> = await scanning.result
        switch outcome {
        case .success:
            XCTFail("The scan was not cancelled")
        case .failure(let error):
            XCTAssertTrue(isCancelled(error as? ScanError), "\(error)")
        }
        gate.open() // the device answers the POST after the cancel
        await client.whenCleanedUp()
        XCTAssertEqual(device.requests, ["POST /eSCL/ScanJobs", "DELETE /eSCL/ScanJobs/7"])
    }

    func testATimeoutBeforeTheFirstPageIsACommunicationError() async throws {
        let device: EsclFakeDevice = EsclFakeDevice()
            .on("POST /eSCL/ScanJobs", created("ScanJobs/7"))
            .on("GET /eSCL/ScanJobs/7/NextDocument", failWith(.timedOut))
        let client: EsclClient = makeClient(device)
        let error: ScanError? = await scanError(client)
        XCTAssertEqual(error?.problem, ScannerProblem.communicationError)
    }

    func testADroppedConnectionAfterAPageKeepsIt() async throws {
        let device: EsclFakeDevice = EsclFakeDevice()
            .on("POST /eSCL/ScanJobs", created("ScanJobs/7"))
            .on("GET /eSCL/ScanJobs/7/NextDocument", page(4, 4), failWith(.networkConnectionLost))
        let client: EsclClient = makeClient(device)
        let result: EsclJobResult = try await scan(client)
        XCTAssertEqual(result.pages.count, 1)
        XCTAssertEqual(result.stop?.problem, ScannerProblem.communicationError)
    }

    // MARK: - Session

    @MainActor
    private func session(_ device: EsclFakeDevice, _ file: String) throws -> EsclScannerSession {
        let info: ScannerInfo = ScannerInfo(id: "escl:test", name: "Fake MFP", transport: "Network", backend: "escl")
        return EsclScannerSession(info: info, client: makeClient(device), capabilities: try capabilities(file))
    }

    @MainActor
    func testSessionScansAndReportsAStoppedBatch() async throws {
        let device: EsclFakeDevice = EsclFakeDevice(adfState: "ScannerAdfJam")
            .on("POST /eSCL/ScanJobs", created("ScanJobs/7"))
            .on("GET /eSCL/ScanJobs/7/NextDocument", page(4, 4), page(4, 4), respond(500))
        let scanner: EsclScannerSession = try session(device, EsclFixtures.platenAndDuplexAdfFile)
        var settings: ScanSettings = ScanSettings()
        settings.source = .documentFeeder
        settings.resolution = 300
        settings.colorMode = .color
        var pages: [ScannedPage] = try await scanner.performScan(settings: settings, selection: nil)
        XCTAssertEqual(pages.count, 2)
        XCTAssertEqual(scanner.lastScanStop?.problem, ScannerProblem.paperJam)

        // The next scan starts without the old stop.
        device.on("GET /eSCL/ScanJobs/7/NextDocument", page(4, 4), respond(404))
        pages = try await scanner.performScan(settings: settings, selection: nil)
        XCTAssertEqual(pages.count, 1)
        XCTAssertNil(scanner.lastScanStop)
        await scanner.close()
    }

    @MainActor
    func testSessionWithoutPagesOrPlatenFailsClearly() async throws {
        let device: EsclFakeDevice = EsclFakeDevice()
            .on("POST /eSCL/ScanJobs", created("ScanJobs/7"))
            .on("GET /eSCL/ScanJobs/7/NextDocument", respond(404))
        let scanner: EsclScannerSession = try session(device, EsclFixtures.platenAndDuplexAdfFile)
        do {
            _ = try await scanner.performScan(settings: ScanSettings(), selection: nil)
            XCTFail("No error")
        } catch let error as ScanError {
            XCTAssertEqual(error.localizedDescription, "Scan failed: The scanner did not return any image data.")
        }

        let feederOnly: EsclScannerSession = try session(EsclFakeDevice(), EsclFixtures.feederOnlyFile)
        do {
            _ = try await feederOnly.performOverviewScan(settings: ScanSettings())
            XCTFail("No error")
        } catch let error as ScanError {
            XCTAssertTrue(isUnsupported(error))
        }
        let caps: ScannerCapabilities = try await feederOnly.capabilities()
        XCTAssertFalse(caps.supportsOverview)
    }

    @MainActor
    func testSessionOverviewUsesTheFlatbedInColor() async throws {
        let device: EsclFakeDevice = EsclFakeDevice()
            .on("POST /eSCL/ScanJobs", created("ScanJobs/7"))
            .on("GET /eSCL/ScanJobs/7/NextDocument", page(8, 11), respond(404))
        let scanner: EsclScannerSession = try session(device, EsclFixtures.platenAndDuplexAdfFile)
        var settings: ScanSettings = ScanSettings()
        settings.colorMode = .blackWhite
        let image: CGImage = try await scanner.performOverviewScan(settings: settings)
        XCTAssertEqual(image.width, 8)
        XCTAssertTrue(device.bodies[0].contains("<pwg:InputSource>Platen</pwg:InputSource>"))
        XCTAssertTrue(device.bodies[0].contains("<scan:ColorMode>RGB24</scan:ColorMode>"))
    }

    @MainActor
    func testSessionCancelBeforeTheJobStartsCancelsIt() async throws {
        let device: EsclFakeDevice = EsclFakeDevice().on("POST /eSCL/ScanJobs", created("ScanJobs/7"))
        let gate: EsclStubGate = device.holdPosts()
        let scanner: EsclScannerSession = try session(device, EsclFixtures.platenAndDuplexAdfFile)
        var settings: ScanSettings = ScanSettings()
        settings.source = .documentFeeder
        let feeder: ScanSettings = settings
        let scanning: Task<[ScannedPage], Error> = Task { @MainActor in
            try await scanner.performScan(settings: feeder, selection: nil)
        }
        // The job request has reached the device, which holds its answer.
        let deadline: Date = Date().addingTimeInterval(10)
        while device.requests.isEmpty && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        scanner.cancelScan()
        let outcome: Result<[ScannedPage], Error> = await scanning.result
        switch outcome {
        case .success:
            XCTFail("The scan was not cancelled")
        case .failure(let error):
            XCTAssertTrue(isCancelled(error as? ScanError), "\(error)")
        }
        gate.open()
        await scanner.client.whenCleanedUp()
        XCTAssertEqual(device.requests.last, "DELETE /eSCL/ScanJobs/7")
    }
}
