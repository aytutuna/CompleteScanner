#if os(iOS)
import CoreGraphics
import Network
import UIKit
import XCTest
@testable import LazyScanIOS
@testable import LazyScanKit

// The iPhone's network scanner screens without a screen (I12): the scanner picker's rows and states, the
// Local Network explanation card and how a refusal shows, searching only in front, the question about a
// changed certificate, adding a scanner by address (the Windows rules and messages, trust on first use),
// the troubleshooter's system side, the crop on the flatbed preview and the screen kept awake. The search
// is made of stand-ins and the user's defaults are a suite of the test's own: no test browses the network.

/// A browser that reports what the test says.
@MainActor
private final class PickerFakeBrowser: EsclServiceBrowsing {
    let secure: Bool
    var onStatus: ((EsclBrowserStatus) -> Void)?
    var onResults: (([EsclBrowseResult]) -> Void)?
    var cancelCount: Int = 0

    init(secure: Bool) {
        self.secure = secure
    }

    @MainActor
    func start() {}

    @MainActor
    func cancel() {
        cancelCount += 1
    }
}

/// Keeps the browsers made.
@MainActor
private final class PickerFakeBrowsers {
    var made: [PickerFakeBrowser] = []

    @MainActor
    func make(_ secure: Bool) -> any EsclServiceBrowsing {
        let browser: PickerFakeBrowser = PickerFakeBrowser(secure: secure)
        made.append(browser)
        return browser
    }
}

/// A resolve never answered.
@MainActor
private final class PickerFakeResolve: EsclCancellable {
    @MainActor
    func cancel() {}
}

/// Resolves nothing (the picker's tests only need the search's state).
@MainActor
private final class PickerFakeResolver: EsclServiceResolving {
    @MainActor
    func resolve(_ result: EsclBrowseResult,
                 completion: @escaping @MainActor (EsclResolveOutcome) -> Void) -> any EsclCancellable {
        PickerFakeResolve()
    }
}

/// What adding by address asked the network connection, and what it answers.
@MainActor
private final class FakeAddressChecker: IOSAddressChecking {
    var results: [EsclAddressCheck] = []
    var firstUses: [String?] = []
    var added: [ScannerAddress] = []
    var trusted: [String] = []

    @MainActor
    func checkAddress(_ address: ScannerAddress, firstUse: String?) async throws -> EsclAddressCheck {
        firstUses.append(firstUse)
        if results.count > 1 {
            return results.removeFirst()
        }
        return results[0]
    }

    @MainActor
    func addAddress(_ address: ScannerAddress, capabilities: EsclCapabilities) -> String {
        added.append(address)
        return "escl:added"
    }

    @MainActor
    func trustCertificate(_ certificate: EsclCertificateError, deviceUuid: String?, name: String) {
        trusted.append(certificate.fingerprint)
    }
}

/// Local Network access as the test says it is.
@MainActor
private final class FakeLocalNetwork: IOSLocalNetworkChecking {
    var denied: Bool = false
    var asked: [String] = []

    @MainActor
    func isDenied(host: String, port: Int) async -> Bool {
        asked.append("\(host):\(port)")
        return denied
    }
}

/// The network the troubleshooter reads, as the test says it is.
@MainActor
private final class FakeNetworkStatus: IOSNetworkStatusReading {
    var status: NetworkStatus = .privateNetwork
}

/// The addresses the troubleshooter service asked the system to open.
@MainActor
private final class OpenedURLs {
    var urls: [URL] = []
}

/// How many times something happened.
@MainActor
private final class Counter {
    var value: Int = 0
}

/// Waits on the main actor until `condition` holds, failing after `timeout` seconds.
@MainActor
private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool,
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

final class IOSScannerPickerTests: XCTestCase {
    private var folder: URL!
    private var suiteName: String = ""
    private var defaults: UserDefaults!
    private var center: NotificationCenter!
    private var browsers: PickerFakeBrowsers!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("IOSScannerPickerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        suiteName = "IOSScannerPickerTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        center = NotificationCenter()
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: folder)
    }

    /// Fresh stand-in browsers; each test starts with it.
    @MainActor
    private func prepare() {
        browsers = PickerFakeBrowsers()
    }

    /// Network scanners over a search of stand-ins, files in the test's folder.
    @MainActor
    private func makeNetwork(endpoints: [EsclEndpoint] = []) -> IOSNetworkScanners {
        let made: PickerFakeBrowsers = browsers
        let discovery: EsclDiscovery = EsclDiscovery(makeBrowser: { (secure: Bool) -> any EsclServiceBrowsing in
            made.make(secure)
        }, resolver: PickerFakeResolver())
        let backend: EsclScannerBackend = EsclScannerBackend(trust: EsclTrustStore(directory: folder), endpoints: endpoints,
                                                             hosts: EsclHostList(directory: folder), discovery: discovery)
        return IOSNetworkScanners(backend: backend, defaults: defaults, center: center)
    }

    @MainActor
    private func makeState(_ backends: [any ScannerBackend]) -> AppState {
        AppState(backends: backends, presetStore: PresetStore(directory: folder), files: AppStateFiles.all(in: folder))
    }

    @MainActor
    private func certificate(_ verdict: EsclTrustVerdict) -> EsclCertificateError {
        EsclCertificateError(verdict: verdict, deviceName: "192.168.1.50", deviceUuid: nil, authority: "192.168.1.50:443",
                             fingerprint: verdict == .changed ? "bbbb" : "aaaa", subject: "CN=Scanner")
    }

    // MARK: The picker's rows

    @MainActor
    func test_rows_showEachScannerWithItsConnection_theChosenOneMarked() throws {
        prepare()
        let demo: ScannerInfo = ScannerInfo(id: "mock:demo", name: "Demo Scanner", transport: "Demo", isDemo: true, backend: "mock")
        let office: ScannerInfo = ScannerInfo(id: "escl:office", name: "Office MFP", transport: "Network", backend: "escl")
        let rows: [IOSScannerRow] = IOSScannerPickerModel.rows(devices: [demo, office], selected: "escl:office", backend: nil)
        XCTAssertEqual(rows.map(\.id), ["mock:demo", "escl:office"])
        XCTAssertEqual(rows.map(\.connection), ["Demo", "Network (eSCL)"])
        XCTAssertEqual(rows.map(\.isSelected), [false, true])
        XCTAssertEqual(rows[1].detail, "Network (eSCL)")
        XCTAssertNil(rows[1].note)
        XCTAssertFalse(rows[1].canRemoveAddress)
        XCTAssertEqual(rows[0].symbol, "sparkles.rectangle.stack")
        XCTAssertEqual(rows[1].symbol, "scanner")

        let added: IOSScannerRow = IOSScannerRow(id: "escl:x", name: "X", connection: "Network (eSCL)",
                                                 note: EsclScannerBackend.notEncryptedLabel, isSelected: false, isDemo: false,
                                                 addedAddresses: [try ScannerAddress.parse("192.168.1.50")])
        XCTAssertTrue(added.canRemoveAddress)
        XCTAssertEqual(added.detail, "Network (eSCL) \u{00B7} Not encrypted")
    }

    @MainActor
    func test_picker_onTheDemoScannerAlone_offersAddByAddress_andSaysNoScannerFound() {
        prepare()
        let state: AppState = makeState(IOSShell.backends(options: IOSLaunchOptions(demoScannerOnly: true)))
        state.start()
        let picker: IOSScannerPickerModel = IOSScannerPickerModel(state: state, network: nil)
        XCTAssertEqual(picker.rows.map(\.id), ["mock:demo"])
        XCTAssertFalse(picker.showsExplanation)
        XCTAssertFalse(picker.showsDenied)
        XCTAssertTrue(picker.showsEmpty)
        XCTAssertTrue(picker.offersAddByAddress)
    }

    @MainActor
    func test_picker_saysItIsLooking_beforeItSaysNoScannerFound() async throws {
        prepare()
        defaults.set(true, forKey: IOSNetworkScanners.explainedKey)
        let network: IOSNetworkScanners = makeNetwork()
        network.backend.discovery?.firstSearchTime = 0.3
        let state: AppState = makeState([AppState.makeDemoBackend(), network.backend])
        let picker: IOSScannerPickerModel = IOSScannerPickerModel(state: state, network: network)
        state.start()
        XCTAssertTrue(picker.showsSearching)
        XCTAssertFalse(picker.showsEmpty)
        XCTAssertEqual(IOSNetworkText.searching, "Looking for scanners\u{2026}")

        // The browsers are ready at once; nothing found yet is still looking, for the first search time.
        browsers.made[0].onStatus?(.ready)
        browsers.made[1].onStatus?(.ready)
        XCTAssertTrue(picker.showsSearching)
        let revisions: Int = network.revision
        try await waitUntil(5) { !picker.showsSearching }
        XCTAssertTrue(picker.showsEmpty)
        XCTAssertTrue(network.revision > revisions)

        // Refused for the local network: the reason with Settings, never "Looking for scanners…".
        network.reportDenied()
        XCTAssertTrue(picker.showsDenied)
        XCTAssertFalse(picker.showsSearching)
        network.backend.stopBrowsing()
        XCTAssertFalse(network.backend.isSearching)
    }

    // MARK: Local Network access

    @MainActor
    func test_theExplanationCardComesFirst_andNothingIsSearchedUntilContinue() {
        prepare()
        let network: IOSNetworkScanners = makeNetwork()
        let state: AppState = makeState([AppState.makeDemoBackend(), network.backend])
        let picker: IOSScannerPickerModel = IOSScannerPickerModel(state: state, network: network)
        state.start()
        XCTAssertTrue(network.needsExplanation)
        XCTAssertTrue(picker.showsExplanation)
        XCTAssertFalse(picker.offersAddByAddress)
        XCTAssertTrue(browsers.made.isEmpty)

        picker.continueAfterExplanation()
        XCTAssertFalse(network.needsExplanation)
        XCTAssertTrue(defaults.bool(forKey: IOSNetworkScanners.explainedKey))
        XCTAssertEqual(browsers.made.count, 2)
        XCTAssertTrue(picker.offersAddByAddress)

        // Read once: a later start searches at once.
        let again: IOSNetworkScanners = makeNetwork()
        XCTAssertFalse(again.needsExplanation)
        XCTAssertTrue(again.backend.isNetworkAllowed)
        network.backend.stopBrowsing()
    }

    @MainActor
    func test_aBrowserRefusedForTheLocalNetwork_showsTheReasonWithSettings_untilAccessIsBack() {
        prepare()
        defaults.set(true, forKey: IOSNetworkScanners.explainedKey)
        let network: IOSNetworkScanners = makeNetwork()
        let state: AppState = makeState([AppState.makeDemoBackend(), network.backend])
        let picker: IOSScannerPickerModel = IOSScannerPickerModel(state: state, network: network)
        let revisions: Int = network.revision
        state.start()
        XCTAssertEqual(browsers.made.count, 2)
        XCTAssertFalse(picker.showsDenied)

        browsers.made[1].onStatus?(.waiting(code: EsclLocalNetwork.policyDeniedCode, detail: "PolicyDenied"))
        XCTAssertTrue(network.accessDenied)
        XCTAssertTrue(picker.showsDenied)
        XCTAssertTrue(network.revision > revisions)
        let check: TroubleshootCheck? = Troubleshooter.diagnose(state.troubleshootSnapshot())
            .first(where: { (found: TroubleshootCheck) -> Bool in found.id == "localNetwork" })
        XCTAssertEqual(check?.actions, [.openAppSettings])
        XCTAssertEqual(IOSNetworkText.deniedLine, "Local Network access is off.")

        // Access turned on again in Settings: the system retries and the browsers are ready.
        browsers.made[0].onStatus?(.ready)
        browsers.made[1].onStatus?(.ready)
        XCTAssertFalse(picker.showsDenied)

        // A connection refused for the local network says the same.
        network.reportDenied()
        XCTAssertTrue(picker.showsDenied)
        network.backend.stopBrowsing()
    }

    @MainActor
    func test_theSearchRunsOnlyWhileTheAppIsInFront() async throws {
        prepare()
        defaults.set(true, forKey: IOSNetworkScanners.explainedKey)
        let network: IOSNetworkScanners = makeNetwork()
        let made: PickerFakeBrowsers = browsers
        network.backend.startBrowsing()
        XCTAssertEqual(made.made.count, 2)

        center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        try await waitUntil(5) { made.made[0].cancelCount == 1 && made.made[1].cancelCount == 1 }
        XCTAssertEqual(made.made.count, 2)
        center.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        try await waitUntil(5) { made.made.count == 4 }
        // Back in front with nothing found yet: looking again, not "No scanner found".
        XCTAssertTrue(network.backend.isSearching)
        network.backend.stopBrowsing()
    }

    @MainActor
    func test_aChangedCertificate_isAskedAbout_andTheAnswerIsTheUsers() async throws {
        prepare()
        let network: IOSNetworkScanners = makeNetwork()
        guard let confirm = network.backend.confirmCertificate else {
            XCTFail("No question for a changed certificate")
            return
        }
        let changed: EsclCertificateError = certificate(.changed)
        let asking: Task<Bool, Never> = Task { @MainActor () -> Bool in
            await confirm(changed)
        }
        try await waitUntil(5) { network.certificateQuestion != nil }
        XCTAssertEqual(network.certificateQuestion, changed)
        network.answerCertificate(true)
        let answer: Bool = await asking.value
        XCTAssertTrue(answer)
        XCTAssertNil(network.certificateQuestion)

        let refusing: Task<Bool, Never> = Task { @MainActor () -> Bool in
            await confirm(changed)
        }
        try await waitUntil(5) { network.certificateQuestion != nil }
        network.answerCertificate(false)
        let refused: Bool = await refusing.value
        XCTAssertFalse(refused)
    }

    // MARK: Adding by address

    @MainActor
    func test_addByAddress_saysWhatIsWrongWithTheAddress_asWindowsDoes() async {
        prepare()
        let model: IOSAddScannerModel = IOSAddScannerModel(checker: FakeAddressChecker(), localNetwork: nil)
        let cases: [String: String] = [
            "": "Enter the scanner's IP address or host name.",
            "300.1.1.1": "\"300.1.1.1\" is not a valid IP address or host name.",
            "my scanner": "An address cannot contain spaces.",
            "scanner:0": "The port must be a number from 1 to 65535.",
            "ftp://10.0.0.7": "Use an address that starts with http:// or https://, or just the IP address or host name.",
        ]
        for text in cases.keys.sorted() {
            model.text = text
            let added: Bool = await model.add()
            XCTAssertFalse(added, text)
            XCTAssertEqual(model.message, cases[text], text)
            XCTAssertFalse(model.isChecking)
        }
        // Typing again clears the message.
        model.textChanged()
        XCTAssertNil(model.message)
    }

    @MainActor
    func test_addByAddress_withoutNetworkScanners_saysTheyAreOff() async {
        prepare()
        let model: IOSAddScannerModel = IOSAddScannerModel(checker: nil, localNetwork: nil)
        model.text = "192.168.1.50"
        let added: Bool = await model.add()
        XCTAssertFalse(added)
        XCTAssertEqual(model.message, IOSNetworkText.networkOff)
    }

    @MainActor
    func test_addByAddress_trustsANewCertificateOnFirstUse_andAddsTheScanner() async throws {
        prepare()
        let address: ScannerAddress = try ScannerAddress.parse("https://192.168.1.50")
        let checker: FakeAddressChecker = FakeAddressChecker()
        checker.results = [
            EsclAddressCheck(address: address, capabilities: nil, certificate: certificate(.unknown), error: nil),
            EsclAddressCheck(address: address, capabilities: EsclCapabilities(makeAndModel: "Office MFP", uuid: "u-1"),
                             certificate: nil, error: nil),
        ]
        let model: IOSAddScannerModel = IOSAddScannerModel(checker: checker, localNetwork: FakeLocalNetwork())
        model.text = "https://192.168.1.50"
        let added: Bool = await model.add()
        XCTAssertTrue(added)
        XCTAssertEqual(checker.firstUses, [nil, "aaaa"])
        XCTAssertEqual(checker.added, [address])
        XCTAssertEqual(model.addedDeviceID, "escl:added")
        XCTAssertNil(model.message)
        XCTAssertNil(model.certificateQuestion)
        XCTAssertTrue(checker.trusted.isEmpty)
    }

    @MainActor
    func test_addByAddress_asksAboutAChangedCertificate() async throws {
        prepare()
        let address: ScannerAddress = try ScannerAddress.parse("https://192.168.1.50")
        let changed: EsclCertificateError = certificate(.changed)
        let checker: FakeAddressChecker = FakeAddressChecker()
        checker.results = [EsclAddressCheck(address: address, capabilities: nil, certificate: changed, error: nil)]
        let model: IOSAddScannerModel = IOSAddScannerModel(checker: checker, localNetwork: nil)
        model.text = "https://192.168.1.50"

        // Not trusted: nothing is added.
        let refusing: Task<Bool, Never> = Task { @MainActor () -> Bool in
            await model.add()
        }
        try await waitUntil(5) { model.certificateQuestion != nil }
        model.answerCertificate(false)
        let refused: Bool = await refusing.value
        XCTAssertFalse(refused)
        XCTAssertEqual(model.message, IOSNetworkText.notTrusted)
        XCTAssertTrue(checker.added.isEmpty)

        // Trusted: the new certificate is pinned and the address checked again.
        checker.results = [
            EsclAddressCheck(address: address, capabilities: nil, certificate: changed, error: nil),
            EsclAddressCheck(address: address, capabilities: EsclCapabilities(makeAndModel: "Office MFP"), certificate: nil, error: nil),
        ]
        let trusting: Task<Bool, Never> = Task { @MainActor () -> Bool in
            await model.add()
        }
        try await waitUntil(5) { model.certificateQuestion != nil }
        model.answerCertificate(true)
        let trusted: Bool = await trusting.value
        XCTAssertTrue(trusted)
        XCTAssertEqual(checker.trusted, ["bbbb"])
        XCTAssertEqual(checker.added, [address])
    }

    @MainActor
    func test_addByAddress_whenNothingAnswers_tellsARefusedLocalNetworkApart() async throws {
        prepare()
        let address: ScannerAddress = try ScannerAddress.parse("192.168.1.50")
        let checker: FakeAddressChecker = FakeAddressChecker()
        checker.results = [EsclAddressCheck(address: address, capabilities: nil, certificate: nil,
                                            error: "No scanner answered at 192.168.1.50 (it did not answer in time).")]
        let probe: FakeLocalNetwork = FakeLocalNetwork()
        let reported: Counter = Counter()
        let model: IOSAddScannerModel = IOSAddScannerModel(checker: checker, localNetwork: probe, onDenied: { () -> Void in
            reported.value += 1
        })
        model.text = "192.168.1.50"
        let first: Bool = await model.add()
        XCTAssertFalse(first)
        XCTAssertEqual(model.message, "No scanner answered at 192.168.1.50 (it did not answer in time).")
        XCTAssertFalse(model.accessDenied)
        XCTAssertEqual(probe.asked, ["192.168.1.50:80"])

        probe.denied = true
        let second: Bool = await model.add()
        XCTAssertFalse(second)
        XCTAssertTrue(model.accessDenied)
        XCTAssertEqual(model.message, IOSNetworkText.deniedLine)
        XCTAssertEqual(reported.value, 1)
        XCTAssertTrue(checker.added.isEmpty)
    }

    @MainActor
    func test_networkTexts_areShort() {
        prepare()
        let titles: [String] = [IOSNetworkText.explanationTitle, IOSNetworkText.addTitle, IOSNetworkText.certificateTitle,
                                IOSNetworkText.pickerTitle, IOSNetworkText.noScanner, TroubleshooterScreen.title]
        for title in titles {
            XCTAssertTrue(StatusLine.words(title) <= 5, title)
        }
        let lines: [String] = [IOSNetworkText.explanationLine, IOSNetworkText.deniedLine, IOSNetworkText.addLine,
                               IOSNetworkText.certificateLine, IOSNetworkText.networkOff]
        for line in lines {
            XCTAssertTrue(StatusLine.words(line) <= 9, line)
        }
        let buttons: [String] = [IOSNetworkText.explanationButton, IOSNetworkText.settingsButton, IOSNetworkText.add,
                                 IOSNetworkText.troubleshoot, IOSNetworkText.removeAddress, IOSNetworkText.addButton]
        for button in buttons {
            XCTAssertTrue(StatusLine.words(button) <= 3, button)
        }
        XCTAssertEqual(IOSNetworkText.connecting(ScannerAddress.create(secure: false, host: "192.168.1.50", port: 80,
                                                                      resourcePath: "eSCL")!),
                       "Connecting to 192.168.1.50\u{2026}")
    }

    // MARK: The shell

    @MainActor
    func test_shell_offersNetworkScannersWithoutTheDemoScanner_neverUnderDemoScanner() {
        prepare()
        defaults.set(true, forKey: IOSNetworkScanners.explainedKey)
        let network: IOSNetworkScanners = makeNetwork()
        let real: [any ScannerBackend] = IOSShell.backends(options: IOSLaunchOptions(demoScannerOnly: false), networkScanners: network)
        XCTAssertEqual(real.count, 1)
        XCTAssertTrue(real[0] === network.backend)
        let demo: [any ScannerBackend] = IOSShell.backends(options: IOSLaunchOptions(arguments: ["LazyScan", "-demoScanner"]),
                                                            networkScanners: network)
        XCTAssertEqual(demo.count, 1)
        // The demo scanner's state never starts the network connection, so nothing is searched.
        let state: AppState = makeState(demo)
        state.start()
        XCTAssertTrue(browsers.made.isEmpty)
        XCTAssertEqual(state.devices.map(\.id), ["mock:demo"])
    }

    @MainActor
    func test_theScreenStaysAwake_onlyWhileANetworkScannerWorks() {
        prepare()
        let network: ScannerInfo = ScannerInfo(id: "escl:x", name: "Office MFP", transport: "Network", backend: "escl")
        let demo: ScannerInfo = ScannerInfo(id: "mock:demo", name: "Demo Scanner", transport: "Demo", isDemo: true, backend: "mock")
        XCTAssertTrue(IOSShell.keepsScreenAwake(isBusy: true, device: network))
        XCTAssertFalse(IOSShell.keepsScreenAwake(isBusy: false, device: network))
        XCTAssertFalse(IOSShell.keepsScreenAwake(isBusy: true, device: demo))
        XCTAssertFalse(IOSShell.keepsScreenAwake(isBusy: true, device: nil))
    }

    // MARK: The troubleshooter's system side

    @MainActor
    func test_troubleshooterService_opensTheAppsSettingsOnly_copies_andReadsTheNetwork() throws {
        prepare()
        let opened: OpenedURLs = OpenedURLs()
        let pasteboard: UIPasteboard = UIPasteboard.withUniqueName()
        defer { UIPasteboard.remove(withName: pasteboard.name) }
        let status: FakeNetworkStatus = FakeNetworkStatus()
        let service: IOSTroubleshooterService = IOSTroubleshooterService(openURL: { (url: URL) -> Void in
            opened.urls.append(url)
        }, pasteboard: pasteboard, network: status)

        try service.open(.openAppSettings)
        XCTAssertEqual(opened.urls, [URL(string: UIApplication.openSettingsURLString)!])
        for action in [TroubleshootAction.openScannerSettings, .openNetworkSettings, .openImageCapture, .refresh] {
            XCTAssertThrowsError(try service.open(action))
        }
        try service.copy("devices")
        XCTAssertEqual(pasteboard.string, "devices")

        status.status = .offline
        XCTAssertEqual(service.addSystemStatus(to: DiscoverySnapshot(platform: .ios)).network, .offline)
        XCTAssertEqual(IOSNetworkPath.status(satisfied: true, wifi: true, wired: false), .privateNetwork)
        XCTAssertEqual(IOSNetworkPath.status(satisfied: true, wifi: false, wired: true), .privateNetwork)
        XCTAssertEqual(IOSNetworkPath.status(satisfied: true, wifi: false, wired: false), .offline)
        XCTAssertEqual(IOSNetworkPath.status(satisfied: false, wifi: true, wired: false), .offline)

        XCTAssertTrue(IOSLocalNetworkProbe.isDenied(NWPath.UnsatisfiedReason.localNetworkDenied))
        XCTAssertFalse(IOSLocalNetworkProbe.isDenied(NWPath.UnsatisfiedReason.notAvailable))
        XCTAssertFalse(IOSLocalNetworkProbe.isDenied(nil))
    }

    // MARK: The crop on the flatbed preview

    @MainActor
    func test_crop_aDragMakesMovesAndResizesTheScanArea_onTheGlass() {
        prepare()
        let frame: CGRect = IOSCropGeometry.fitted(imageSize: CGSize(width: 850, height: 1170), in: CGSize(width: 400, height: 400))
        XCTAssertEqual(frame.height, 400, accuracy: 0.001)
        XCTAssertEqual(frame.midX, 200, accuracy: 0.001)

        // A new area from the drag; a tap makes none.
        let start: CGPoint = CGPoint(x: frame.minX + frame.width * 0.1, y: frame.minY + frame.height * 0.2)
        let end: CGPoint = CGPoint(x: frame.minX + frame.width * 0.6, y: frame.minY + frame.height * 0.7)
        XCTAssertEqual(IOSCropGeometry.mode(at: start, area: nil, frame: frame), .creating)
        let made: CGRect = IOSCropGeometry.dragged(.creating, from: start, to: end, frame: frame)
        XCTAssertEqual(made.minX, 0.1, accuracy: 0.0001)
        XCTAssertEqual(made.minY, 0.2, accuracy: 0.0001)
        XCTAssertEqual(made.width, 0.5, accuracy: 0.0001)
        XCTAssertNil(IOSCropGeometry.finished(.creating, area: CGRect(x: 0.5, y: 0.5, width: 0.005, height: 0.3)))

        // Inside it moves, kept on the glass.
        let inside: CGPoint = CGPoint(x: frame.minX + frame.width * 0.3, y: frame.minY + frame.height * 0.4)
        XCTAssertEqual(IOSCropGeometry.mode(at: inside, area: made, frame: frame), .moving(original: made))
        let moved: CGRect = IOSCropGeometry.moved(made, dx: 0.9, dy: -0.9)
        XCTAssertEqual(moved.maxX, 1, accuracy: 0.0001)
        XCTAssertEqual(moved.minY, 0, accuracy: 0.0001)
        XCTAssertEqual(moved.width, made.width, accuracy: 0.0001)

        // A corner resizes, never below the smallest side.
        let corner: CGPoint = IOSCropGeometry.point(.bottomRight, of: IOSCropGeometry.viewRect(made, in: frame))
        XCTAssertEqual(IOSCropGeometry.mode(at: corner, area: made, frame: frame), .resizing(handle: .bottomRight, original: made))
        let shrunk: CGRect = IOSCropGeometry.resized(made, handle: .bottomRight, dx: -1, dy: -1)
        XCTAssertEqual(shrunk.width, IOSCropGeometry.minSide, accuracy: 0.0001)
        XCTAssertEqual(shrunk.height, IOSCropGeometry.minSide, accuracy: 0.0001)
        let grown: CGRect = IOSCropGeometry.resized(made, handle: .topLeft, dx: -1, dy: -1)
        XCTAssertEqual(grown.minX, 0, accuracy: 0.0001)
        XCTAssertEqual(grown.minY, 0, accuracy: 0.0001)
        XCTAssertEqual(grown.maxX, made.maxX, accuracy: 0.0001)
        // Outside the area, a drag makes a new one.
        XCTAssertEqual(IOSCropGeometry.mode(at: CGPoint(x: frame.maxX - 2, y: frame.maxY - 2), area: made, frame: frame), .creating)
    }

    @MainActor
    func test_crop_withoutDragging_choosesMovesAndResizesTheScanArea_onTheGlass() {
        prepare()
        // Parts of the glass.
        XCTAssertNil(IOSCropGeometry.apply(.wholeGlass, to: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)))
        XCTAssertEqual(IOSCropGeometry.apply(.topHalf, to: nil), CGRect(x: 0, y: 0, width: 1, height: 0.5))
        XCTAssertEqual(IOSCropGeometry.apply(.bottomHalf, to: nil), CGRect(x: 0, y: 0.5, width: 1, height: 0.5))
        XCTAssertEqual(IOSCropGeometry.apply(.leftHalf, to: nil), CGRect(x: 0, y: 0, width: 0.5, height: 1))
        XCTAssertEqual(IOSCropGeometry.apply(.rightHalf, to: nil), CGRect(x: 0.5, y: 0, width: 0.5, height: 1))
        XCTAssertEqual(IOSCropCommand.presets, [.wholeGlass, .topHalf, .bottomHalf, .leftHalf, .rightHalf])

        // Smaller from the whole glass makes an area in its middle; larger brings it back.
        guard let smaller = IOSCropGeometry.apply(.smaller, to: nil) else {
            XCTFail("No area")
            return
        }
        XCTAssertEqual(smaller.minX, 0.05, accuracy: 0.0001)
        XCTAssertEqual(smaller.width, 0.9, accuracy: 0.0001)
        let larger: CGRect? = IOSCropGeometry.apply(.larger, to: smaller)
        XCTAssertEqual(larger?.minX ?? -1, 0, accuracy: 0.0001)
        XCTAssertEqual(larger?.width ?? -1, 1, accuracy: 0.0001)
        // Never smaller than the smallest side.
        var tiny: CGRect? = smaller
        for _ in 0..<40 {
            tiny = IOSCropGeometry.apply(.smaller, to: tiny)
        }
        XCTAssertEqual(tiny?.width ?? -1, IOSCropGeometry.minSide, accuracy: 0.0001)

        // Moves keep the area on the glass; the whole glass has nothing to move.
        let top: CGRect = CGRect(x: 0, y: 0, width: 1, height: 0.5)
        XCTAssertEqual(IOSCropGeometry.apply(.moveUp, to: top), top)
        XCTAssertEqual(IOSCropGeometry.apply(.moveDown, to: top)?.minY ?? -1, 0.05, accuracy: 0.0001)
        XCTAssertEqual(IOSCropGeometry.apply(.moveLeft, to: top), top)
        XCTAssertNil(IOSCropGeometry.apply(.moveRight, to: nil))
        XCTAssertNil(IOSCropGeometry.apply(.larger, to: nil))

        // What VoiceOver reads.
        XCTAssertEqual(IOSCropGeometry.describe(nil), "Whole glass")
        XCTAssertEqual(IOSCropGeometry.describe(CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.25)),
                       "50% wide, 25% high, 10% from the left, 20% from the top")
        for command in IOSCropCommand.allCases {
            XCTAssertTrue(StatusLine.words(command.name) <= 4, command.name)
        }
    }
}
#endif
