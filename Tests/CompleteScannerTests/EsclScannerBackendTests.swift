import Foundation
import XCTest
@testable import CompleteScannerKit

// EsclScannerBackend with its search and the addresses added by hand (I12), as the Windows app's
// Scanning/EsclScannerBackend.cs does it: a URLProtocol stub plays the scanners (no request leaves the
// process), the search is made of stand-ins (EsclDiscoveryFakes.swift: no browsing), and escl-hosts.json and
// escl-trust.json are kept in a folder of the test's own. Swift only: the Windows backend is the Windows
// app's own (it has no Core twin); the rules it shares (EsclEndpoint, EsclHostList, ScannerAddress, the
// troubleshooter) are checked on both platforms.

/// What a stub scanner answers a request with.
private enum BackendStubAnswer {
    case xml(String)
    case status(Int)
    case garbage
    case failure(URLError.Code)
}

/// The scanners the stub plays, by origin ("http://host" or "https://host"); records the requests.
private final class BackendStubScanners: @unchecked Sendable {
    static let shared: BackendStubScanners = BackendStubScanners()

    private let lock: NSLock = NSLock()
    private var scripts: [String: [BackendStubAnswer]] = [:]
    private var counts: [String: Int] = [:]

    /// Queues answers for an origin; the last one repeats.
    func play(_ origin: String, _ answers: [BackendStubAnswer]) {
        lock.lock()
        scripts[origin.lowercased()] = answers
        lock.unlock()
    }

    func requestCount(_ origin: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counts[origin.lowercased()] ?? 0
    }

    func answer(_ url: URL) -> BackendStubAnswer {
        let scheme: String = url.scheme ?? ""
        let host: String = URLComponents(url: url, resolvingAgainstBaseURL: false)?.host ?? ""
        let origin: String = (scheme + "://" + host).lowercased()
        lock.lock()
        defer { lock.unlock() }
        counts[origin] = (counts[origin] ?? 0) + 1
        guard var queue: [BackendStubAnswer] = scripts[origin], !queue.isEmpty else {
            return BackendStubAnswer.failure(URLError.Code.cannotFindHost)
        }
        if queue.count > 1 {
            let next: BackendStubAnswer = queue.removeFirst()
            scripts[origin] = queue
            return next
        }
        return queue[0]
    }
}

/// Answers every request of a session configured with it as the stub scanners say.
private final class BackendStubProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url: URL = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(URLError.Code.badURL))
            return
        }
        let answer: BackendStubAnswer = BackendStubScanners.shared.answer(url)
        var status: Int = 200
        var body: Data = Data()
        switch answer {
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
            return
        case .xml(let text):
            body = Data(text.utf8)
        case .status(let code):
            status = code
        case .garbage:
            body = Data("not a capabilities document".utf8)
        }
        guard let response: HTTPURLResponse = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                                              headerFields: ["Content-Type": "text/xml"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(URLError.Code.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !body.isEmpty {
            client?.urlProtocol(self, didLoad: body)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// A network scanner whose certificate changed since it was trusted and is not trusted again: every
/// connection is refused, as `EsclScannerBackend.openSession` refuses it. Records whether each attempt
/// was the user's choice (`interactive`).
@MainActor
private final class ChangedCertificateBackend: ScannerBackend {
    static let deviceID: String = "escl:changed"

    var onDevicesChanged: (() -> Void)?
    private(set) var devices: [ScannerInfo] = []
    private(set) var opened: [Bool] = []

    let refusal: EsclCertificateError = EsclCertificateError(
        verdict: EsclTrustVerdict.changed, deviceName: "Office Scanner", deviceUuid: nil,
        authority: "office-scanner.test:443", fingerprint: "ab12cd34", subject: "CN=office-scanner")

    func startBrowsing() {
        guard devices.isEmpty else { return }
        devices = [ScannerInfo(id: ChangedCertificateBackend.deviceID, name: "Office Scanner", transport: "Network",
                               backend: "escl")]
        onDevicesChanged?()
    }

    func stopBrowsing() {
        devices = []
    }

    func openSession(deviceID: String) async throws -> any ScannerSession {
        try await openSession(deviceID: deviceID, interactive: false)
    }

    func openSession(deviceID: String, interactive: Bool) async throws -> any ScannerSession {
        opened.append(interactive)
        throw refusal
    }
}

final class EsclScannerBackendTests: XCTestCase {
    private var folder: URL!
    private var browsers: DiscoveryFakeBrowsers!
    private var resolver: DiscoveryFakeResolver!
    private var scheduler: DiscoveryFakeScheduler!

    private let hpUuid: String = "564e4333-4230-3538-3930-a0b3cce51a2b"
    private let hpID: String = "escl:564e4333423035383930a0b3cce51a2b"
    private let hpName: String = "HP Color LaserJet MFP M479fdw"

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("EsclScannerBackendTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Fresh stand-ins for the search; each test starts with it.
    @MainActor
    private func prepare() {
        browsers = DiscoveryFakeBrowsers()
        resolver = DiscoveryFakeResolver()
        scheduler = DiscoveryFakeScheduler()
    }

    /// A host name of its own for each stub scanner.
    @MainActor
    private func stubHost() -> String {
        "scanner-\(UUID().uuidString.lowercased()).test"
    }

    @MainActor
    private func hpCapabilities() throws -> String {
        try EsclFixtures.text(EsclFixtures.platenAndDuplexAdfFile)
    }

    @MainActor
    private func makeBackend(hosts: EsclHostList?, discovery: EsclDiscovery? = nil,
                             endpoints: [EsclEndpoint] = []) -> EsclScannerBackend {
        let configuration: URLSessionConfiguration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BackendStubProtocol.self]
        var options: EsclClientOptions = EsclClientOptions(requestTimeout: 5, jobTimeout: 5, connectivityWait: 1)
        options.configuration = configuration
        options.pageDirectory = folder.appendingPathComponent("pages", isDirectory: true)
        let backend: EsclScannerBackend = EsclScannerBackend(trust: EsclTrustStore(directory: folder), endpoints: endpoints,
                                                             hosts: hosts, discovery: discovery, clientOptions: options)
        backend.reprobeInterval = 0.05
        return backend
    }

    @MainActor
    private func fakeDiscovery() -> EsclDiscovery {
        makeFakeDiscovery(browsers, resolver, scheduler)
    }

    /// Waits until `condition` holds, failing after `timeout` seconds.
    @MainActor
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

    @MainActor
    func test_anAddressAddedByHand_isCheckedListed_andKeptInTheHostsFile() async throws {
        prepare()
        let host: String = stubHost()
        BackendStubScanners.shared.play("http://" + host, [BackendStubAnswer.xml(try hpCapabilities())])
        let address: ScannerAddress = try ScannerAddress.parse(host + ":8080")
        let hosts: EsclHostList = EsclHostList(directory: folder)
        let backend: EsclScannerBackend = makeBackend(hosts: hosts)
        backend.startBrowsing()

        let check: EsclAddressCheck = try await backend.checkAddress(address)
        guard let capabilities = check.capabilities else {
            XCTFail("No capabilities: \(check.error ?? "")")
            return
        }
        XCTAssertFalse(check.noAnswer)
        let id: String = backend.addAddress(address, capabilities: capabilities)
        XCTAssertEqual(id, hpID)
        XCTAssertEqual(backend.devices.map(\.id), [hpID])
        XCTAssertEqual(backend.devices.first?.name, hpName)
        XCTAssertEqual(backend.devices.first?.hardwareID, hpUuid)
        XCTAssertEqual(backend.manualAddresses(id), [address])

        // escl-hosts.json: a JSON list of the canonical address texts, as Windows writes it.
        let data: Data = try Data(contentsOf: hosts.fileURL)
        XCTAssertEqual(try JSONDecoder().decode([String].self, from: data), [host + ":8080"])

        // Read back by a new start: listed again once checked.
        let again: EsclScannerBackend = makeBackend(hosts: EsclHostList(directory: folder))
        again.startBrowsing()
        try await waitFor(10) { again.devices.count == 1 }
        XCTAssertEqual(again.devices.first?.id, hpID)
        XCTAssertEqual(again.manualAddresses(hpID), [address])

        again.removeAddress(address)
        XCTAssertTrue(again.devices.isEmpty)
        XCTAssertEqual(EsclHostList(directory: folder).loadEntries(), [])
        again.stopBrowsing()
        backend.stopBrowsing()
    }

    @MainActor
    func test_anAddressThatDoesNotAnswer_isATroubleshooterCheck_andIsTriedAgainUntilItAnswers() async throws {
        prepare()
        let host: String = stubHost()
        BackendStubScanners.shared.play("http://" + host, [BackendStubAnswer.failure(URLError.Code.cannotConnectToHost),
                                                           BackendStubAnswer.failure(URLError.Code.cannotConnectToHost),
                                                           BackendStubAnswer.xml(try hpCapabilities())])
        let hosts: EsclHostList = EsclHostList(directory: folder)
        let address: ScannerAddress = try ScannerAddress.parse(host)
        hosts.add(address)
        let backend: EsclScannerBackend = makeBackend(hosts: hosts)
        backend.reprobeInterval = 0.3
        backend.startBrowsing()

        try await waitFor(10) { backend.addStatus(to: DiscoverySnapshot(platform: .ios)).manualHosts.count == 1 }
        let snapshot: DiscoverySnapshot = backend.addStatus(to: DiscoverySnapshot(platform: .ios))
        XCTAssertEqual(snapshot.manualHosts.first?.address, host)
        XCTAssertEqual(snapshot.manualHosts.first?.listed, false)
        XCTAssertTrue(snapshot.manualHosts.first?.problem?.hasPrefix("No scanner answered at \(host) (") == true)
        XCTAssertTrue(Troubleshooter.diagnose(snapshot).contains { $0.id == "manualHost:" + host })
        XCTAssertTrue(backend.devices.isEmpty)
        XCTAssertTrue(backend.diagnosticsReport?.contains("eSCL addresses added by hand:\n  \(host): not listed (") == true)

        // Tried again (every reprobeInterval) until it answers; then listed.
        try await waitFor(10) { backend.devices.count == 1 }
        XCTAssertEqual(backend.addStatus(to: DiscoverySnapshot()).manualHosts.first?.listed, true)
        XCTAssertTrue(backend.diagnosticsReport?.contains("\(host): listed as \"\(hpName)\"") == true)
        backend.stopBrowsing()
        XCTAssertTrue(backend.addStatus(to: DiscoverySnapshot()).manualHosts.isEmpty)
    }

    @MainActor
    func test_checkingAnAddress_saysWhyNothingAnswered_asWindowsDoes() async throws {
        prepare()
        let backend: EsclScannerBackend = makeBackend(hosts: nil)
        let garbage: String = stubHost()
        let missing: String = stubHost()
        let slow: String = stubHost()
        BackendStubScanners.shared.play("http://" + garbage, [BackendStubAnswer.garbage])
        BackendStubScanners.shared.play("http://" + missing, [BackendStubAnswer.status(404)])
        BackendStubScanners.shared.play("http://" + slow, [BackendStubAnswer.failure(URLError.Code.timedOut)])

        let notScanner: EsclAddressCheck = try await backend.checkAddress(try ScannerAddress.parse(garbage))
        XCTAssertEqual(notScanner.error, "No scanner answered at \(garbage) (it answered, but not like an eSCL scanner).")
        XCTAssertTrue(notScanner.noAnswer)
        let notFound: EsclAddressCheck = try await backend.checkAddress(try ScannerAddress.parse(missing))
        XCTAssertEqual(notFound.error, "No scanner answered at \(missing) (it answered HTTP 404).")
        let timedOut: EsclAddressCheck = try await backend.checkAddress(try ScannerAddress.parse(slow))
        XCTAssertEqual(timedOut.error, "No scanner answered at \(slow) (it did not answer in time).")
        XCTAssertNil(timedOut.capabilities)
        XCTAssertNil(timedOut.certificate)
    }

    @MainActor
    func test_aDiscoveredScanner_andItsAddressAddedByHand_areOneEntry() async throws {
        prepare()
        let txt: [String] = try EsclFixtures.lines(EsclFixtures.hpTxtFile)
        resolver.answers["HP M479 (A1B2C3)"] = EsclResolveOutcome.resolved(
            EsclResolvedService(hostName: "HPA1B2C3.local", port: 80, addresses: ["192.168.1.20"]))
        let host: String = stubHost()
        BackendStubScanners.shared.play("http://" + host, [BackendStubAnswer.xml(try hpCapabilities())])
        let address: ScannerAddress = try ScannerAddress.parse(host)
        let backend: EsclScannerBackend = makeBackend(hosts: EsclHostList(directory: folder), discovery: fakeDiscovery())
        backend.startBrowsing()
        XCTAssertEqual(browsers.made.count, 2)
        browsers.latest(secure: false)?.report([fakeBrowseResult("HP M479 (A1B2C3)", secure: false, txt: txt)])
        XCTAssertEqual(backend.devices.map(\.id), [hpID])
        XCTAssertEqual(backend.devices.first?.transport, "Network")
        XCTAssertEqual(backend.devices.first?.backend, "escl")

        let check: EsclAddressCheck = try await backend.checkAddress(address)
        guard let capabilities = check.capabilities else {
            XCTFail("No capabilities")
            return
        }
        XCTAssertEqual(backend.addAddress(address, capabilities: capabilities), hpID)
        XCTAssertEqual(backend.devices.count, 1)
        XCTAssertEqual(backend.manualAddresses(hpID), [address])

        // Removing the address leaves the scanner the search found.
        backend.removeAddress(address)
        XCTAssertEqual(backend.devices.map(\.id), [hpID])
        XCTAssertEqual(backend.manualAddresses(hpID), [])
        backend.stopBrowsing()
        XCTAssertTrue(backend.devices.isEmpty)
    }

    @MainActor
    func test_nothingIsSearchedOrChecked_untilTheNetworkIsAllowed() async throws {
        prepare()
        let host: String = stubHost()
        BackendStubScanners.shared.play("http://" + host, [BackendStubAnswer.xml(try hpCapabilities())])
        let hosts: EsclHostList = EsclHostList(directory: folder)
        hosts.add(try ScannerAddress.parse(host))
        let backend: EsclScannerBackend = makeBackend(hosts: hosts, discovery: fakeDiscovery())
        backend.holdNetwork()
        XCTAssertFalse(backend.isNetworkAllowed)
        backend.startBrowsing()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(browsers.made.isEmpty)
        XCTAssertEqual(BackendStubScanners.shared.requestCount("http://" + host), 0)
        XCTAssertEqual(backend.addStatus(to: DiscoverySnapshot(platform: .ios)).discovery, .off)
        backend.rescan()
        XCTAssertTrue(browsers.made.isEmpty)

        backend.allowNetwork()
        XCTAssertEqual(browsers.made.count, 2)
        try await waitFor(10) { backend.devices.count == 1 }
        XCTAssertTrue(BackendStubScanners.shared.requestCount("http://" + host) > 0)
        backend.stopBrowsing()
    }

    @MainActor
    func test_suspendAndResume_pauseTheSearch_andKeepTheScanners() throws {
        prepare()
        let txt: [String] = try EsclFixtures.lines(EsclFixtures.hpTxtFile)
        resolver.answers["HP M479 (A1B2C3)"] = EsclResolveOutcome.resolved(
            EsclResolvedService(hostName: "HPA1B2C3.local", port: 80, addresses: ["192.168.1.20"]))
        let backend: EsclScannerBackend = makeBackend(hosts: nil, discovery: fakeDiscovery())
        backend.startBrowsing()
        browsers.latest(secure: false)?.report([fakeBrowseResult("HP M479 (A1B2C3)", secure: false, txt: txt)])
        XCTAssertEqual(backend.devices.count, 1)

        backend.suspendBrowsing()
        for made in browsers.made {
            XCTAssertEqual(made.cancelCount, 1)
        }
        XCTAssertEqual(backend.devices.count, 1)
        // Refresh in the background does nothing.
        backend.rescan()
        XCTAssertEqual(browsers.made.count, 2)

        backend.resumeBrowsing()
        XCTAssertEqual(browsers.made.count, 4)
        XCTAssertEqual(backend.devices.count, 1)
        backend.stopBrowsing()
        XCTAssertTrue(backend.devices.isEmpty)
    }

    @MainActor
    func test_plainHttpAfterHttpsCouldNotBeUsed_isNotEncrypted() async throws {
        prepare()
        let host: String = stubHost()
        BackendStubScanners.shared.play("https://" + host, [BackendStubAnswer.failure(URLError.Code.secureConnectionFailed)])
        BackendStubScanners.shared.play("http://" + host, [BackendStubAnswer.xml(try hpCapabilities())])
        let secure: ScannerAddress = try ScannerAddress.parse("https://" + host)
        let plain: ScannerAddress = try ScannerAddress.parse(host)
        let both: EsclEndpoint = EsclEndpoint(key: "uuid:hp", name: hpName, txt: EsclTxtRecord.parse(nil), addresses: [secure, plain])
        let plainHost: String = stubHost()
        BackendStubScanners.shared.play("http://" + plainHost, [BackendStubAnswer.xml(try hpCapabilities())])
        let plainOnly: EsclEndpoint = EsclScannerBackend.endpoint(try ScannerAddress.parse(plainHost))
        let backend: EsclScannerBackend = makeBackend(hosts: nil, endpoints: [both, plainOnly])
        backend.startBrowsing()
        XCTAssertEqual(backend.devices.count, 2)

        let session: any ScannerSession = try await backend.openSession(deviceID: "escl:uuid:hp")
        XCTAssertEqual(BackendStubScanners.shared.requestCount("https://" + host), 1)
        XCTAssertTrue(backend.isNotEncrypted("escl:uuid:hp"))
        XCTAssertEqual(EsclScannerBackend.notEncryptedLabel, "Not encrypted")
        XCTAssertTrue(backend.diagnosticsReport?.contains("eSCL connections over plain HTTP: escl:uuid:hp") == true)
        await session.close()

        // A scanner that offers plain HTTP only is not labeled.
        let other: any ScannerSession = try await backend.openSession(deviceID: "escl:" + plainHost)
        XCTAssertFalse(backend.isNotEncrypted("escl:" + plainHost))
        await other.close()

        XCTAssertTrue(EsclScannerBackend.isTLSFailure(URLError(URLError.Code.secureConnectionFailed)))
        XCTAssertFalse(EsclScannerBackend.isTLSFailure(URLError(URLError.Code.timedOut)))
        XCTAssertFalse(EsclScannerBackend.isTLSFailure(URLError(URLError.Code.cancelled)))
        backend.stopBrowsing()
    }

    @MainActor
    func test_theTroubleshooterSeesTheSearch_andTheDiagnosticsListWhatItFound() throws {
        prepare()
        let txt: [String] = try EsclFixtures.lines(EsclFixtures.hpTxtFile)
        resolver.answers["HP M479 (A1B2C3)"] = EsclResolveOutcome.resolved(
            EsclResolvedService(hostName: "HPA1B2C3.local", port: 80, addresses: ["192.168.1.20"]))
        let backend: EsclScannerBackend = makeBackend(hosts: nil, discovery: fakeDiscovery())
        var discoveryChanges: Int = 0
        backend.onDiscoveryChanged = {
            discoveryChanges += 1
        }
        backend.startBrowsing()
        browsers.latest(secure: false)?.send(.ready)
        browsers.latest(secure: true)?.send(.ready)
        browsers.latest(secure: false)?.report([fakeBrowseResult("HP M479 (A1B2C3)", secure: false, txt: txt)])
        XCTAssertTrue(discoveryChanges > 0)

        let snapshot: DiscoverySnapshot = backend.addStatus(to: DiscoverySnapshot(platform: .ios))
        XCTAssertEqual(snapshot.discovery, .running)
        XCTAssertEqual(snapshot.discoveredCount, 1)
        let report: String = backend.diagnosticsReport ?? ""
        XCTAssertTrue(report.hasPrefix("eSCL network discovery (DNS-SD _uscan/_uscans): browsing, ready, 1 service(s)\n"), report)
        XCTAssertTrue(report.contains("  _uscan \"HP M479 (A1B2C3)\" host=\"HPA1B2C3.local\" port=80 addresses=\"192.168.1.20\" "
                                      + "ty=\"\(hpName)\" uuid=\"\(hpUuid)\" rs=\"eSCL\"\n"), report)

        browsers.latest(secure: false)?.send(.waiting(code: EsclLocalNetwork.policyDeniedCode, detail: "PolicyDenied"))
        XCTAssertEqual(backend.discoveryStatus, .denied)
        let denied: DiscoverySnapshot = backend.addStatus(to: DiscoverySnapshot(platform: .ios))
        XCTAssertEqual(denied.discovery, .denied)
        XCTAssertTrue(Troubleshooter.diagnose(denied).contains { $0.id == "localNetwork" && $0.actions == [.openAppSettings] })
        backend.stopBrowsing()
    }

    @MainActor
    func test_theIPhonesStateRanksAndTroubleshootsAsTheIPhone() async throws {
        prepare()
        let txt: [String] = try EsclFixtures.lines(EsclFixtures.hpTxtFile)
        resolver.answers["HP M479 (A1B2C3)"] = EsclResolveOutcome.resolved(
            EsclResolvedService(hostName: "HPA1B2C3.local", port: 80, addresses: ["192.168.1.20"]))
        let backend: EsclScannerBackend = makeBackend(hosts: nil, discovery: fakeDiscovery())
        let state: AppState = AppState(backends: [AppState.makeDemoBackend(), backend],
                                       presetStore: PresetStore(directory: folder), files: AppStateFiles.all(in: folder))
        state.platform = .ios
        XCTAssertEqual(state.rankPatterns, DeviceMerge.iosRanking)
        state.start()
        browsers.latest(secure: false)?.report([fakeBrowseResult("HP M479 (A1B2C3)", secure: false, txt: txt)])
        XCTAssertTrue(state.hasRealDevices)

        let snapshot: DiscoverySnapshot = state.troubleshootSnapshot()
        XCTAssertEqual(snapshot.platform, .ios)
        XCTAssertEqual(snapshot.discoveredCount, 1)
        let text: String = state.diagnosticsText(snapshot)
        XCTAssertTrue(text.contains("eSCL network discovery (DNS-SD _uscan/_uscans)"), text)
        XCTAssertTrue(text.contains("Why isn't my scanner listed?"), text)
        backend.stopBrowsing()
        // The Mac's state keeps its own ranking.
        let mac: AppState = AppState(backends: [AppState.makeDemoBackend()], presetStore: PresetStore(directory: folder),
                                     files: AppStateFiles.all(in: folder))
        XCTAssertEqual(mac.platform, .mac)
        XCTAssertEqual(mac.rankPatterns, DeviceMerge.macRanking)
    }

    /// The phone's camera picked as the source: no scanner, and none chosen again on its own when the list
    /// changes, until the user picks one.
    @MainActor
    func test_noScannerPickedByTheUser_isKeptWhenTheListChanges() async throws {
        let demo: MockScannerBackend = AppState.makeDemoBackend()
        let state: AppState = AppState(backends: [demo], presetStore: PresetStore(directory: folder),
                                       files: AppStateFiles.all(in: folder))
        state.platform = .ios
        state.start()
        try await waitFor(10) { state.capabilities != nil }
        state.settings.duplex = .manual

        state.userSelectNoDevice()
        try await waitFor(10) { state.capabilities == nil }
        XCTAssertNil(state.selectedDeviceID)
        XCTAssertEqual(state.statusMessage, "Ready")
        XCTAssertEqual(state.settings.duplex, .both)
        demo.onDevicesChanged?()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertNil(state.selectedDeviceID)
        XCTAssertNil(state.capabilities)

        state.userSelectDevice("mock:demo")
        try await waitFor(10) { state.capabilities != nil }
        XCTAssertEqual(state.selectedDeviceID, "mock:demo")
    }

    /// Twin of the Windows `AppViewModel` handling of `EsclCertificateException` (spec N3): a scanner the
    /// app chose on its own whose certificate changed is a warning with a hint, the app moves on to
    /// another scanner (here the demo scanner) and does not choose it again; only the user choosing it
    /// opens it interactively, which shows the certificate.
    @MainActor
    func test_aScannerWhoseCertificateChanged_isLeftWhenTheAppChoseIt_andNotChosenAgainOnItsOwn() async throws {
        let network: ChangedCertificateBackend = ChangedCertificateBackend()
        let state: AppState = AppState(backends: [AppState.makeDemoBackend(), network],
                                       presetStore: PresetStore(directory: folder), files: AppStateFiles.all(in: folder))
        state.platform = .ios
        state.start()

        try await waitFor(10) { state.selectedDeviceID == "mock:demo" }
        XCTAssertEqual(network.opened, [false])
        XCTAssertEqual(state.errorMessage,
                       network.refusal.message + " To review the new certificate, choose the scanner in the list.")

        // The list changing again does not choose it again.
        state.errorMessage = nil
        network.onDevicesChanged?()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(state.selectedDeviceID, "mock:demo")
        XCTAssertEqual(network.opened, [false])

        // The user choosing it opens it interactively; refused again, the error has no hint and the
        // selection stays where the user put it.
        state.userSelectDevice(ChangedCertificateBackend.deviceID)
        try await waitFor(10) { state.errorMessage != nil }
        XCTAssertEqual(network.opened, [false, true])
        XCTAssertEqual(state.errorMessage, network.refusal.message)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(state.selectedDeviceID, ChangedCertificateBackend.deviceID)
        network.stopBrowsing()
    }
}
