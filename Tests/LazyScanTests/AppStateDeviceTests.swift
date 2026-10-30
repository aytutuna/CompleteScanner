import Combine
import XCTest
@testable import LazyScanKit

// How AppState keeps its scanner as the list changes and connections fail: the phone waits for its scanner
// when it drops off the list (the Mac moves on to another), Refresh opens a scanner that could not be
// connected to, and a scanner left while it was connecting fails without a word. Windows: the same rules in
// `AppViewModel.RefreshScanners` and `SwitchSession`, which have no tests of their own.

/// Scanners the test lists and takes away, each opened as the demo scanner. The first `failures` opens fail;
/// an open of `held` waits for `release()` and then fails, as a scanner that does not answer.
@MainActor
private final class ListedScannersBackend: ScannerBackend {
    var onDevicesChanged: (() -> Void)?
    private(set) var devices: [ScannerInfo] = []
    private(set) var opened: [String] = []
    var failures: Int = 0
    var held: String?
    private var waiting: CheckedContinuation<Void, Never>?
    private let demo: MockScannerBackend = MockScannerBackend()

    func list(_ scanners: [ScannerInfo]) {
        devices = scanners
        onDevicesChanged?()
    }

    func startBrowsing() {
        demo.startBrowsing()
    }

    func stopBrowsing() {}

    func openSession(deviceID: String) async throws -> any ScannerSession {
        opened.append(deviceID)
        if deviceID == held {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                waiting = continuation
            }
            throw ScanError.deviceUnavailable("The scanner did not respond.")
        }
        if failures > 0 {
            failures -= 1
            throw ScanError.deviceUnavailable("The scanner did not respond.")
        }
        return try await demo.openSession(deviceID: "mock:demo")
    }

    func release() {
        waiting?.resume()
        waiting = nil
    }
}

final class AppStateDeviceTests: XCTestCase {
    private var folder: URL!

    private let office: ScannerInfo = ScannerInfo(id: "test:office", name: "Office MFP", transport: "Network",
                                                  backend: "test")
    private let library: ScannerInfo = ScannerInfo(id: "test:library", name: "Library MFP", transport: "Network",
                                                   backend: "test")

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppStateDeviceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        // The settings are written 0.4 s after they change: let that write land before the folder goes.
        try await Task.sleep(nanoseconds: 600_000_000)
        try? FileManager.default.removeItem(at: folder)
    }

    @MainActor
    private func makeState(_ backends: [any ScannerBackend]) -> AppState {
        AppState(backends: backends, presetStore: PresetStore(directory: folder), files: AppStateFiles.all(in: folder))
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

    /// The phone's scanner dropping off the list (switched off, out of the Wi-Fi): no other scanner is opened
    /// meanwhile, the status is the phone's "Ready", and the scanner is opened again once it is listed.
    @MainActor
    func test_thePhonesScannerGoneFromTheList_isWaitedFor_andNoOtherIsOpened() async throws {
        let backend: ListedScannersBackend = ListedScannersBackend()
        backend.list([office, library])
        let state: AppState = makeState([backend])
        state.platform = .ios
        state.start(onlySelecting: office.id)
        try await waitFor(10) { state.capabilities != nil }
        XCTAssertEqual(state.selectedDeviceID, office.id)

        backend.list([library])
        XCTAssertNil(state.selectedDeviceID)
        try await waitFor(10) { state.capabilities == nil && state.statusMessage == "Ready" }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertNil(state.selectedDeviceID)
        XCTAssertEqual(state.statusMessage, "Ready")
        XCTAssertEqual(backend.opened, [office.id])

        backend.list([office, library])
        try await waitFor(10) { state.capabilities != nil }
        XCTAssertEqual(state.selectedDeviceID, office.id)
        XCTAssertEqual(backend.opened, [office.id, office.id])
        XCTAssertNil(state.errorMessage)
    }

    /// The Mac's rule stays: a scanner gone from the list is left for the preferred one, named at once.
    @MainActor
    func test_theMacsScannerGoneFromTheList_isLeftForAnother() async throws {
        let backend: ListedScannersBackend = ListedScannersBackend()
        backend.list([office])
        let state: AppState = makeState([backend])
        state.start()
        try await waitFor(10) { state.capabilities != nil }
        XCTAssertEqual(state.selectedDeviceID, office.id)

        backend.list([library])
        XCTAssertEqual(state.selectedDeviceID, library.id)
        XCTAssertEqual(state.statusMessage, "Connecting to Library MFP…")
        try await waitFor(10) { backend.opened.count == 2 && state.statusMessage.hasPrefix("Ready — ") }
        XCTAssertEqual(backend.opened, [office.id, library.id])
        XCTAssertNotNil(state.capabilities)
    }

    /// After "Could not connect", the troubleshooter's Refresh opens the scanner again; not while a photo
    /// review is open, which the switch would close.
    @MainActor
    func test_refresh_opensAScannerThatCouldNotBeConnectedTo_unlessAReviewIsOpen() async throws {
        let backend: ListedScannersBackend = ListedScannersBackend()
        backend.list([office])
        backend.failures = 1
        let state: AppState = makeState([backend])
        state.platform = .ios
        state.start(onlySelecting: office.id)
        try await waitFor(10) { state.lastFailure != nil }
        XCTAssertNil(state.capabilities)
        XCTAssertEqual(state.selectedDeviceID, office.id)
        XCTAssertEqual(state.statusMessage, "Could not connect to Office MFP.")
        state.errorMessage = nil

        state.showPhotoReview = true
        state.refreshScanners()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(backend.opened, [office.id])
        XCTAssertNil(state.capabilities)

        state.showPhotoReview = false
        state.refreshScanners()
        try await waitFor(10) { state.capabilities != nil }
        XCTAssertEqual(backend.opened, [office.id, office.id])
        XCTAssertEqual(state.selectedDeviceID, office.id)
        XCTAssertNil(state.lastFailure)
    }

    /// Another scanner picked while the first is still connecting (a sleeping network scanner): the status
    /// names the one picked at once, and the first one's failure, when it comes, shows no alert, offers no
    /// troubleshooter and never says it could not connect.
    @MainActor
    func test_aScannerLeftWhileItConnects_failsWithoutAWord() async throws {
        let backend: ListedScannersBackend = ListedScannersBackend()
        backend.list([office])
        backend.held = office.id
        let state: AppState = makeState([backend, AppState.makeDemoBackend()])
        var statuses: [String] = []
        let watch = state.$statusMessage.sink { message in
            statuses.append(message)
        }
        defer { watch.cancel() }
        state.start()
        try await waitFor(10) { backend.opened == [office.id] }
        XCTAssertEqual(state.statusMessage, "Connecting to Office MFP…")

        state.userSelectDevice("mock:demo")
        XCTAssertEqual(state.statusMessage, "Connecting to Demo Scanner…")
        backend.release()
        try await waitFor(10) { state.capabilities != nil && state.statusMessage.hasPrefix("Ready — ") }
        XCTAssertEqual(state.selectedDeviceID, "mock:demo")
        XCTAssertNil(state.errorMessage)
        XCTAssertFalse(state.errorSuggestsTroubleshooter)
        XCTAssertNil(state.lastFailure)
        XCTAssertFalse(statuses.contains("Could not connect to Office MFP."), "\(statuses)")
        XCTAssertTrue(state.statusMessage.hasPrefix("Ready — Demo Scanner"), state.statusMessage)
    }
}
