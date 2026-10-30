#if os(iOS)
import Security
import UIKit
import XCTest
@testable import LazyScanIOS
@testable import LazyScanKit

// The iPhone's side of the companion without a screen: the Keychain store, My computer's pairing text and
// check code, its cloud folder, what the shell wires into AppState (the secrets, the browse, pulling while
// the app is in front, the cloud folder's bookmark) and when Send to computer is offered. Nothing here reaches a real computer: the paired desktop
// is at 127.0.0.1 on a closed port, and the browse is a stand-in.

private struct CompanionShellScorer: OrientationScorer {
    var isAvailable: Bool { false }

    func score(_ image: RgbaImage) throws -> OrientationScore {
        OrientationScore.none
    }
}

private struct CompanionShellBarcodes: BarcodeReader {
    var isAvailable: Bool { false }

    func read(_ image: GrayImage) throws -> [BarcodeReading] {
        []
    }
}

/// Secrets in memory.
private final class MemorySecrets: CompanionSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: [String: Data] = [:]

    func save(_ secret: Data, for desktopId: String) throws {
        lock.lock()
        secrets[desktopId] = secret
        lock.unlock()
    }

    func load(for desktopId: String) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return secrets[desktopId]
    }

    func delete(for desktopId: String) throws {
        lock.lock()
        secrets[desktopId] = nil
        lock.unlock()
    }
}

/// A browser that reports what the test says.
@MainActor
private final class StubCompanionBrowser: EsclServiceBrowsing {
    let secure: Bool = false
    var onStatus: ((EsclBrowserStatus) -> Void)?
    var onResults: (([EsclBrowseResult]) -> Void)?
    private(set) var running: Bool = false

    func start() {
        running = true
    }

    func cancel() {
        running = false
    }
}

/// The stand-in browsers made, in order.
@MainActor
private final class StubCompanionBrowsers {
    var made: [StubCompanionBrowser] = []

    func make() -> any EsclServiceBrowsing {
        let browser = StubCompanionBrowser()
        made.append(browser)
        return browser
    }
}

@MainActor
private final class StubResolve: EsclCancellable {
    func cancel() {}
}

/// Resolves every service at once to `service`.
@MainActor
private final class StubCompanionResolver: EsclServiceResolving {
    var service: EsclResolvedService = EsclResolvedService(hostName: nil, port: CompanionProtocol.defaultPort,
                                                           addresses: [])

    func resolve(_ result: EsclBrowseResult,
                 completion: @escaping @MainActor (EsclResolveOutcome) -> Void) -> any EsclCancellable {
        completion(EsclResolveOutcome.resolved(service))
        return StubResolve()
    }
}

/// The desktop at its new address: its health check answers on the companion's port, nothing else does.
private final class MovedDesktopProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url, url.port == CompanionProtocol.defaultPort,
              url.path == CompanionProtocol.healthPath,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                             headerFields: nil) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let health: String = HealthResponse(protocolVersion: CompanionProtocol.version, paired: false).toJSON()
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(health.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool,
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

final class IOSCompanionTests: XCTestCase {
    private static let desktopId = "desk-0001-abcd"
    /// A fingerprint whose first four bytes make the check code 066051.
    private static let fingerprint = Data([0x00, 0x01, 0x02, 0x03] + [UInt8](repeating: 0x2A, count: 28))

    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("IOSCompanionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        // The settings are written 0.4 s after they change: let that write land before the folder goes.
        try await Task.sleep(nanoseconds: 600_000_000)
        try? FileManager.default.removeItem(at: folder)
    }

    @MainActor
    private func makeState() -> AppState {
        AppState(presetStore: PresetStore(directory: folder), orientationScorer: CompanionShellScorer(),
                 barcodeReader: CompanionShellBarcodes(), files: AppStateFiles.all(in: folder))
    }

    private func pairedDesktop() -> PairedDesktop {
        // Port 9 on this device: nothing listens, so every request fails at once.
        PairedDesktop(id: IOSCompanionTests.desktopId, name: "Office PC",
                      fingerprint: CompanionProtocol.encodeBase64Url(IOSCompanionTests.fingerprint),
                      addresses: ["127.0.0.1"], port: 9, phoneId: PairedDesktop.makePhoneId())
    }

    private func pairingText() throws -> String {
        let token: String = CompanionProtocol.encodeBase64Url(Data(repeating: 7, count: PairingUri.tokenByteCount))
        return try PairingUri(desktopId: IOSCompanionTests.desktopId, name: "Office PC",
                              fingerprint: CompanionProtocol.encodeBase64Url(IOSCompanionTests.fingerprint),
                              addresses: ["192.168.1.20"], port: CompanionProtocol.defaultPort, token: token).format()
    }

    // MARK: Keychain

    func test_keychain_keepsReplacesAndDeletesTheSecret() throws {
        let secrets = IOSCompanionSecrets(service: "com.lazyscan.companion.tests-\(UUID().uuidString)")
        let first = Data(repeating: 1, count: PairedDeviceStore.secretByteCount)
        let second = Data(repeating: 2, count: PairedDeviceStore.secretByteCount)
        do {
            try secrets.save(first, for: IOSCompanionTests.desktopId)
        } catch let error as IOSKeychainError where error.status == errSecMissingEntitlement {
            throw XCTSkip("This test host has no Keychain access.")
        }
        defer { try? secrets.delete(for: IOSCompanionTests.desktopId) }

        XCTAssertEqual(try secrets.load(for: IOSCompanionTests.desktopId), first)
        XCTAssertNil(try secrets.load(for: "desk-0002-other"))
        try secrets.save(second, for: IOSCompanionTests.desktopId)
        XCTAssertEqual(try secrets.load(for: IOSCompanionTests.desktopId), second)
        try secrets.delete(for: IOSCompanionTests.desktopId)
        XCTAssertNil(try secrets.load(for: IOSCompanionTests.desktopId))
        // Deleting what is not there is fine.
        try secrets.delete(for: IOSCompanionTests.desktopId)
        XCTAssertEqual(IOSKeychainError(status: errSecInteractionNotAllowed).localizedDescription,
                       CompanionText.notSavedMessage)
    }

    func test_keychain_keepsTheSyncKeyNextToTheSecret() throws {
        let secrets = IOSCompanionSecrets(service: "com.lazyscan.companion.tests-\(UUID().uuidString)")
        let secret = Data(repeating: 3, count: PairedDeviceStore.secretByteCount)
        let syncKey = Data((1...32).map { UInt8($0) })
        do {
            try secrets.save(secret, for: IOSCompanionTests.desktopId)
        } catch let error as IOSKeychainError where error.status == errSecMissingEntitlement {
            throw XCTSkip("This test host has no Keychain access.")
        }
        let store = PairedDesktopStore(directory: folder, secrets: secrets)
        defer { store.remove() }
        let desktop: PairedDesktop = pairedDesktop()

        try store.save(desktop, secret: secret, syncKey: syncKey)

        XCTAssertEqual(store.secret(for: desktop), secret)
        XCTAssertEqual(store.syncKey(for: desktop), syncKey)
        XCTAssertEqual(try secrets.load(for: IOSCompanionTests.desktopId + ".sync"), syncKey)
        store.forgetSecret(of: desktop)
        XCTAssertNil(store.syncKey(for: desktop))
        XCTAssertNil(try secrets.load(for: IOSCompanionTests.desktopId + ".sync"))
    }

    // MARK: My computer

    @MainActor
    func test_pairingText_isParsed_andItsCheckCodeShown() throws {
        let model = IOSCompanionModel(state: makeState(), browser: nil)
        XCTAssertTrue(model.needsPairing)
        XCTAssertNil(model.code)
        XCTAssertNil(model.problem)
        XCTAssertNil(model.checkCode)
        XCTAssertFalse(model.canPair)
        XCTAssertEqual(model.phoneName, UIDevice.current.name)

        model.text = "hello"
        XCTAssertNil(model.code)
        XCTAssertEqual(model.problem, PairingUri.notPairingCodeMessage)
        XCTAssertNil(model.checkCode)
        XCTAssertFalse(model.canPair)

        let text: String = try pairingText()
        model.scanned("  " + text + "\n")
        XCTAssertEqual(model.code?.desktopId, IOSCompanionTests.desktopId)
        XCTAssertEqual(model.code?.name, "Office PC")
        XCTAssertNil(model.problem)
        XCTAssertEqual(model.checkCode, "066 051")
        XCTAssertTrue(model.canPair)

        XCTAssertTrue(PairingScannerView.isPairingCode(text))
        XCTAssertTrue(PairingScannerView.isPairingCode(text.uppercased()))
        XCTAssertFalse(PairingScannerView.isPairingCode("https://example.com/?lazyscan://pair?v=1"))
    }

    func test_statusLines() {
        XCTAssertEqual(IOSCompanionText.status(.notPaired), "Not paired")
        XCTAssertEqual(IOSCompanionText.status(.reachable(desktopName: "Office PC", queuedPages: 0)), "Connected")
        XCTAssertEqual(IOSCompanionText.status(.reachable(desktopName: "Office PC", queuedPages: 3)),
                       "Connected \u{00B7} 3 pages queued there")
        XCTAssertEqual(IOSCompanionText.status(.unreachable(reason: "Office PC is not on this network.")),
                       "Office PC is not on this network.")
        XCTAssertEqual(IOSCompanionText.status(.unpaired(byDesktop: "Office PC")),
                       "This phone is no longer paired with Office PC.")
        XCTAssertEqual(IOSCompanionText.waiting(0), "Nothing waiting to be sent")
        XCTAssertEqual(IOSCompanionText.waiting(1), "1 document waiting to be sent")
        XCTAssertEqual(IOSCompanionText.waiting(4), "4 documents waiting to be sent")
        XCTAssertEqual(IOSCompanionText.inCloudFolder(1), "1 document in the cloud folder")
        XCTAssertEqual(IOSCompanionText.inCloudFolder(3), "3 documents in the cloud folder")
    }

    // MARK: The cloud folder

    @MainActor
    func test_cloudFolder_aPickedFolderOpens_andOneThatDoesNotIsNil() throws {
        let picked: URL = folder.appendingPathComponent("OneDrive", isDirectory: true)
        try FileManager.default.createDirectory(at: picked, withIntermediateDirectories: true)
        defer { IOSSyncFolder.close() }
        XCTAssertNil(IOSSyncFolder.resolve(Data("not a bookmark".utf8)))

        let bookmark: Data = try IOSSyncFolder.bookmark(of: picked)
        guard let opened = IOSSyncFolder.resolve(bookmark) else {
            throw XCTSkip("A bookmark of a temporary folder does not resolve here.")
        }
        XCTAssertEqual(opened.folder.resolvingSymlinksInPath().path, picked.resolvingSymlinksInPath().path)
        XCTAssertEqual(IOSSyncFolder.resolve(bookmark)?.folder, opened.folder)

        XCTAssertEqual(IOSSyncFolder.waitingCount(in: picked), 0)
        try Data([1]).write(to: picked.appendingPathComponent(SyncPackage.fileName("pkg_one_0001")))
        try Data([1]).write(to: picked.appendingPathComponent("." + SyncPackage.fileName("pkg_two_0002")))
        try Data([1]).write(to: picked.appendingPathComponent("Notes.txt"))
        XCTAssertEqual(IOSSyncFolder.waitingCount(in: picked), 1)
        XCTAssertEqual(IOSSyncFolder.waitingCount(in: folder.appendingPathComponent("Gone", isDirectory: true)), 0)
    }

    @MainActor
    func test_cloudFolderRow_none_cannotBeOpened_thenThePickedFolder() throws {
        let secrets = MemorySecrets()
        let companionFolder: URL = folder.appendingPathComponent("Network", isDirectory: true)
        try FileManager.default.createDirectory(at: companionFolder, withIntermediateDirectories: true)
        try PairedDesktopStore(directory: companionFolder, secrets: secrets)
            .save(pairedDesktop(), secret: Data(repeating: 3, count: PairedDeviceStore.secretByteCount),
                  syncKey: Data((1...32).map { UInt8($0) }))
        let state: AppState = makeState()
        state.setUpCompanion(in: companionFolder, secrets: secrets)
        state.resolveSyncFolderBookmark = { (bookmark: Data) -> (folder: URL, bookmark: Data)? in
            IOSSyncFolder.resolve(bookmark)
        }
        defer { IOSSyncFolder.close() }
        let model = IOSCompanionModel(state: state, browser: nil)

        model.lookAtCloudFolder()
        XCTAssertTrue(model.offersCloudFolder)
        XCTAssertEqual(IOSCompanionText.cloudFolderLabel, "Cloud folder")
        XCTAssertEqual(IOSCompanionText.chooseFolderButton, "Choose\u{2026}")
        XCTAssertEqual(IOSCompanionText.clearButton, "Clear")
        XCTAssertEqual(CompanionText.syncFolderLine,
                       "A folder in iCloud Drive or OneDrive that your computer also syncs. Documents go here, encrypted, when the computer cannot be reached.")
        XCTAssertEqual(model.cloudFolderValue, "None")
        XCTAssertEqual(model.inCloudFolder, 0)

        // Set, but it does not open now: kept, and said.
        state.setSyncFolder(bookmark: Data("not a bookmark".utf8))
        model.lookAtCloudFolder()
        XCTAssertEqual(model.cloudFolderValue, "Cannot be opened")
        XCTAssertEqual(state.companionDesktop?.syncFolderBookmark, Data("not a bookmark".utf8))

        model.clearCloudFolder()
        XCTAssertNil(state.companionDesktop?.syncFolderBookmark)
        XCTAssertEqual(model.cloudFolderValue, "None")

        let picked: URL = folder.appendingPathComponent("OneDrive", isDirectory: true)
        try FileManager.default.createDirectory(at: picked, withIntermediateDirectories: true)
        try Data([1]).write(to: picked.appendingPathComponent(SyncPackage.fileName("pkg_one_0001")))
        model.chooseCloudFolder(picked)
        XCTAssertNotNil(state.companionDesktop?.syncFolderBookmark)
        XCTAssertNil(state.errorMessage)
        guard model.cloudFolderName != nil else {
            throw XCTSkip("A bookmark of a temporary folder does not resolve here.")
        }
        XCTAssertEqual(model.cloudFolderValue, "OneDrive")
        XCTAssertEqual(model.inCloudFolder, 1)
        XCTAssertNotNil(PairedDesktopStore(directory: companionFolder, secrets: secrets).load()?.syncFolderBookmark)
    }

    @MainActor
    func test_cloudFolderRow_isNotOffered_forAComputerWithoutASyncKey() throws {
        let secrets = MemorySecrets()
        let companionFolder: URL = folder.appendingPathComponent("Network", isDirectory: true)
        try FileManager.default.createDirectory(at: companionFolder, withIntermediateDirectories: true)
        try PairedDesktopStore(directory: companionFolder, secrets: secrets)
            .save(pairedDesktop(), secret: Data(repeating: 3, count: PairedDeviceStore.secretByteCount))
        let state: AppState = makeState()
        state.setUpCompanion(in: companionFolder, secrets: secrets)
        let model = IOSCompanionModel(state: state, browser: nil)

        model.lookAtCloudFolder()

        XCTAssertFalse(model.offersCloudFolder)
        XCTAssertNil(model.cloudFolderName)
    }

    // MARK: The shell's wiring

    @MainActor
    func test_makeForIOS_setsTheCompanionUp() {
        let actions = IOSFileActions(pasteboard: nil, openSystemURL: { (_: URL) -> Void in },
                                     mailAvailable: { () -> Bool in false })
        let state: AppState = AppState.makeForIOS(options: IOSLaunchOptions(demoScannerOnly: true), fileActions: actions)
        XCTAssertNotNil(state.companionStore)
        XCTAssertNotNil(state.companionOutbox)
        // No browser under -demoScanner: whether a desktop is on the network is not known.
        XCTAssertNil(state.companionDesktopSeenOnNetwork)
        XCTAssertNotNil(state.resolveSyncFolderBookmark)
    }

    @MainActor
    func test_pairedDesktop_isPulledFromWhileActive_andBrowsedFor() async throws {
        let secrets = MemorySecrets()
        let companionFolder: URL = folder.appendingPathComponent("Network", isDirectory: true)
        try FileManager.default.createDirectory(at: companionFolder, withIntermediateDirectories: true)
        let desktop: PairedDesktop = pairedDesktop()
        try PairedDesktopStore(directory: companionFolder, secrets: secrets)
            .save(desktop, secret: Data(repeating: 3, count: PairedDeviceStore.secretByteCount))
        let resolver = StubCompanionResolver()
        let browsers = StubCompanionBrowsers()
        let browser = IOSCompanionBrowser(makeBrowser: { () -> any EsclServiceBrowsing in
            browsers.make()
        }, resolver: resolver)
        let center = NotificationCenter()
        let state: AppState = makeState()

        IOSShell.setUpCompanion(state, folder: companionFolder, secrets: secrets, browser: browser,
                                lifecycle: UIKitLifecycle(center: center))

        XCTAssertEqual(state.companionDesktop, desktop)
        XCTAssertEqual(state.companionStatus, .checking)
        XCTAssertNil(state.companionPull)

        center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        try await waitUntil(timeout: 5) { state.companionPull != nil }
        // The check browses while it runs, and a few seconds more when the desktop does not answer.
        try await waitUntil(timeout: 30) {
            state.companionStatus == .unreachable(reason: "Office PC is not on this network.")
        }
        XCTAssertTrue(browser.isBrowsing)
        try await waitUntil(timeout: 40) { !browser.isBrowsing }
        XCTAssertEqual(state.companionStatus, .unreachable(reason: "Office PC is not on this network."))
        XCTAssertEqual(browsers.made.count, 1)

        center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        try await waitUntil(timeout: 5) { state.companionPull == nil }

        // Seen on the network, at a new address where the desktop answers.
        state.companionProtocolClasses = [MovedDesktopProtocol.self]
        resolver.service = EsclResolvedService(hostName: "office-pc.local", port: CompanionProtocol.defaultPort,
                                               addresses: ["fe80::1%1", "127.0.0.2"])
        browser.begin()
        let running: StubCompanionBrowser = try XCTUnwrap(browsers.made.last)
        XCTAssertTrue(running.running)
        running.onResults?([
            EsclBrowseResult(name: "Office PC", type: CompanionProtocol.serviceType, domain: "local.",
                             txt: ["id=" + IOSCompanionTests.desktopId, "v=1"]),
            EsclBrowseResult(name: "Other PC", type: CompanionProtocol.serviceType, domain: "local.", txt: ["v=1"]),
        ])
        XCTAssertEqual(state.companionDesktopSeenOnNetwork?(IOSCompanionTests.desktopId), true)
        XCTAssertEqual(state.companionDesktopSeenOnNetwork?("desk-0002-other"), false)
        try await waitUntil(timeout: 10) { state.companionDesktop?.addresses == ["127.0.0.2", "fe80::1%1"] }
        XCTAssertEqual(state.companionDesktop?.port, CompanionProtocol.defaultPort)
        XCTAssertEqual(PairedDesktopStore(directory: companionFolder, secrets: secrets).load()?.addresses,
                       ["127.0.0.2", "fe80::1%1"])
        browser.end()
        XCTAssertFalse(running.running)
    }

    @MainActor
    func test_withoutAPairedDesktop_nothingIsPulled() async throws {
        let center = NotificationCenter()
        let state: AppState = makeState()
        IOSShell.setUpCompanion(state, folder: folder.appendingPathComponent("Network", isDirectory: true),
                                secrets: MemorySecrets(), browser: nil, lifecycle: UIKitLifecycle(center: center))
        XCTAssertEqual(state.companionStatus, .notPaired)

        center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertNil(state.companionPull)
        XCTAssertEqual(state.companionStatus, .notPaired)
    }

    func test_desktopIdInTheTXTRecord() {
        func result(_ txt: [String]) -> EsclBrowseResult {
            EsclBrowseResult(name: "Office PC", type: CompanionProtocol.serviceType, domain: "local.", txt: txt)
        }
        XCTAssertEqual(IOSCompanionBrowser.desktopId(result(["id=" + IOSCompanionTests.desktopId, "v=1"])),
                       IOSCompanionTests.desktopId)
        XCTAssertNil(IOSCompanionBrowser.desktopId(result(["v=1"])))
        XCTAssertNil(IOSCompanionBrowser.desktopId(result(["id=no"])))
    }

    // MARK: Send to computer

    func test_sendToComputer_isOfferedWhileCollectingPages_withAComputerPaired() {
        var settings = ScanSettings()
        settings.intent = .document
        settings.documentMultiPage = true
        settings.taskId = nil
        XCTAssertTrue(IOSShell.collectsPages(settings))
        XCTAssertTrue(IOSShell.offersSendToComputer(settings, status: .reachable(desktopName: "Office PC", queuedPages: 0)))
        XCTAssertTrue(IOSShell.offersSendToComputer(settings, status: .checking))
        // It waits in the outbox until the computer answers.
        XCTAssertTrue(IOSShell.offersSendToComputer(settings, status: .unreachable(reason: "Office PC is not on this network.")))
        XCTAssertFalse(IOSShell.offersSendToComputer(settings, status: .notPaired))
        XCTAssertFalse(IOSShell.offersSendToComputer(settings, status: .unpaired(byDesktop: "Office PC")))

        settings.documentMultiPage = false
        XCTAssertFalse(IOSShell.offersSendToComputer(settings, status: .reachable(desktopName: "Office PC", queuedPages: 0)))
    }
}
#endif
