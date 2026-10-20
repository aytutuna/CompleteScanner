import XCTest
@testable import CompleteScannerKit

// Mirrors windows/CompleteScanner.Core.Tests/TroubleshooterTests.cs (same fixtures, same text).
// Swift-only case: CancellationError in failure(deviceName:error:) (C# has
// OperationCanceledException instead, tested there).

final class TroubleshooterTests: XCTestCase {

    private let demo = ScannerInfo(id: "mock:demo", name: "Demo Scanner", transport: "Demo", isDemo: true, backend: "mock")
    private let wiaScanner = ScannerInfo(id: "wia:1", name: "Acme Scan 100", transport: "WIA", backend: "wia")

    private func ids(_ checks: [TroubleshootCheck]) -> [String] { checks.map { $0.id } }

    private func check(_ checks: [TroubleshootCheck], _ id: String, file: StaticString = #filePath, line: UInt = #line) -> TroubleshootCheck {
        guard let found = checks.first(where: { $0.id == id }) else {
            XCTFail("no check \(id) in \(ids(checks))", file: file, line: line)
            return TroubleshootCheck(id: id, status: .tip, title: "", detail: "", actions: [])
        }
        return found
    }

    private func changed(_ snapshot: DiscoverySnapshot, _ change: (inout DiscoverySnapshot) -> Void) -> DiscoverySnapshot {
        var copy = snapshot
        change(&copy)
        return copy
    }

    /// A PC where everything that can be checked is fine.
    private func healthyWindows() -> DiscoverySnapshot {
        DiscoverySnapshot(platform: .windows, devices: [demo, wiaScanner], network: .privateNetwork,
                          wiaService: .running, twain: .available, twainDriverCount: 2,
                          discovery: .running, discoveredCount: 1)
    }

    /// A PC where most things are wrong.
    private func troubledWindows() -> DiscoverySnapshot {
        DiscoverySnapshot(platform: .windows, devices: [demo], network: .publicNetwork, wiaService: .disabled,
                          twain: .notInstalled, thirtyTwoBitOnlyDrivers: ["Acme\\acme.ds"],
                          discovery: .unavailable, discoveryDetail: "Access is denied.",
                          manualHosts: [ManualHostStatus(address: "192.168.1.50", listed: false, problem: "No scanner answered at 192.168.1.50."),
                                        ManualHostStatus(address: "10.0.0.2", listed: true)],
                          lastFailure: ScannerFailure(deviceName: "Acme Scan 100", message: ScannerProblems.describe(.busy), problem: .busy))
    }

    func test_healthyWindows_showsWhatIsFineThenTheTips() {
        let snapshot = healthyWindows()
        let checks = Troubleshooter.diagnose(snapshot)
        XCTAssertEqual(ids(checks), ["network", "wiaService", "twain", "discovery", "usb", "otherApps"])
        XCTAssertEqual(checks.map { $0.status }, [.ok, .ok, .ok, .ok, .tip, .tip])
        XCTAssertEqual(Troubleshooter.headline(snapshot), "1 scanner found")
        XCTAssertEqual(Troubleshooter.summary(checks),
                       "Nothing here stops scanners from appearing. The tips below cover the usual causes.")
    }

    func test_problemsComeFirst_thenWarnings_thenTips() {
        let snapshot = troubledWindows()
        let checks = Troubleshooter.diagnose(snapshot)
        XCTAssertEqual(ids(checks), ["lastFailure", "wiaService", "twain32", "network", "twain", "discovery",
                                     "manualHost:192.168.1.50", "usb", "otherApps"])
        XCTAssertEqual(checks.map { $0.status }, [.problem, .problem, .problem, .warning, .warning, .warning, .warning, .tip, .tip])
        XCTAssertEqual(Troubleshooter.headline(snapshot), "No scanner found yet")
        XCTAssertEqual(Troubleshooter.summary(checks), "3 problems and 4 warnings found.")
    }

    func test_nothingKnown_onlyTheTips() {
        XCTAssertEqual(ids(Troubleshooter.diagnose(DiscoverySnapshot(platform: .windows))), ["usb", "otherApps"])
    }

    func test_busyScanner_saysToCloseOtherApps() {
        XCTAssertEqual(check(Troubleshooter.diagnose(troubledWindows()), "lastFailure"), TroubleshootCheck(
            id: "lastFailure", status: .problem, title: "Acme Scan 100 is busy or in use by another app",
            detail: "A scanner works with one app at a time. Close other apps that may be using it, such as Windows Scan "
                + "or the scanner maker's app, wait until the scanner has finished, then choose it again.",
            actions: [.refresh]))
    }

    func test_otherScannerProblem_usesItsText() {
        let snapshot = DiscoverySnapshot(lastFailure: ScannerFailure(deviceName: "Acme Scan 100", message: "x", problem: .coverOpen))
        let found = check(Troubleshooter.diagnose(snapshot), "lastFailure")
        XCTAssertEqual(found.status, .problem)
        XCTAssertEqual(found.title, "Acme Scan 100 reported a problem")
        XCTAssertEqual(found.detail, ScannerProblems.describe(.coverOpen))
    }

    func test_failureWithoutProblem_isAWarningWithTheMessage() {
        let snapshot = DiscoverySnapshot(lastFailure: ScannerFailure(deviceName: "Office MFP",
                                                                     message: "Office MFP did not answer (192.168.1.9: no answer in time)"))
        let found = check(Troubleshooter.diagnose(snapshot), "lastFailure")
        XCTAssertEqual(found.status, .warning)
        XCTAssertEqual(found.title, "Could not connect to Office MFP")
        XCTAssertEqual(found.detail, "Office MFP did not answer (192.168.1.9: no answer in time). Check that the scanner is on "
                       + "and awake, and connected by its cable or to the same network as this PC.")
        let mac = check(Troubleshooter.diagnose(changed(snapshot) { $0.platform = .mac }), "lastFailure")
        XCTAssertTrue(mac.detail.hasSuffix("to the same network as this Mac."))
    }

    func test_wiaService() {
        let cases: [(ServiceStatus, CheckStatus, String)] = [
            (.running, .ok, "The Windows scanner service is running"),
            (.starting, .warning, "The Windows scanner service is starting"),
            (.stopped, .warning, "The Windows scanner service is not running"),
            (.stopping, .warning, "The Windows scanner service is not running"),
            (.paused, .warning, "The Windows scanner service is not running"),
            (.disabled, .problem, "The Windows scanner service is turned off"),
            (.notInstalled, .problem, "The Windows scanner service is missing"),
        ]
        for (service, status, title) in cases {
            let found = check(Troubleshooter.diagnose(changed(healthyWindows()) { $0.wiaService = service }), "wiaService")
            XCTAssertEqual(found.status, status, "\(service)")
            XCTAssertEqual(found.title, title)
            XCTAssertTrue(found.detail.contains("Windows Image Acquisition (WIA)"))
        }
    }

    func test_wiaService_unknownHasNoCheck() {
        XCTAssertFalse(ids(Troubleshooter.diagnose(changed(healthyWindows()) { $0.wiaService = .unknown })).contains("wiaService"))
    }

    func test_disabledWiaService_saysHowToTurnItOnWithoutDoingIt() {
        let found = check(Troubleshooter.diagnose(changed(healthyWindows()) { $0.wiaService = .disabled }), "wiaService")
        XCTAssertEqual(found.detail, "Windows Image Acquisition (WIA), which most scanners use, is disabled, so those scanners cannot "
                       + "appear. Someone with administrator rights can set its startup type to Automatic in Services, then "
                       + "restart the PC.")
        XCTAssertEqual(found.actions, [.refresh])
    }

    func test_network() {
        let offline = check(Troubleshooter.diagnose(changed(healthyWindows()) { $0.network = .offline }), "network")
        XCTAssertEqual(offline.status, .problem)
        XCTAssertEqual(offline.title, "Not connected to a network")
        XCTAssertEqual(offline.detail, "This PC is not on a network, so network scanners cannot be found. Connect to the network the "
                       + "scanner is on, then select Refresh. Scanners connected by USB are not affected.")
        XCTAssertEqual(offline.actions, [.openNetworkSettings, .refresh])

        let publicNetwork = check(Troubleshooter.diagnose(changed(healthyWindows()) { $0.network = .publicNetwork }), "network")
        XCTAssertEqual(publicNetwork.status, .warning)
        XCTAssertEqual(publicNetwork.title, "The network is set to Public")
        XCTAssertEqual(publicNetwork.detail, "Windows does not look for devices on public networks, so network scanners may not be found. "
                       + "If this is your home or office network, set its network profile type to Private in Windows "
                       + "network settings. You can also add the scanner by its address.")
        XCTAssertEqual(publicNetwork.actions, [.openNetworkSettings, .addByAddress])

        for status in [NetworkStatus.privateNetwork, .domainNetwork] {
            let ok = check(Troubleshooter.diagnose(changed(healthyWindows()) { $0.network = status }), "network")
            XCTAssertEqual(ok.status, .ok)
            XCTAssertEqual(ok.title, "Connected to a private network")
        }
        XCTAssertFalse(ids(Troubleshooter.diagnose(changed(healthyWindows()) { $0.network = .unknown })).contains("network"))
    }

    func test_twainNotInstalled_isAWarningOnlyWhileNoScannerIsListed() {
        let demoOnly = demo
        let none = check(Troubleshooter.diagnose(changed(healthyWindows()) { $0.devices = [demoOnly]; $0.twain = .notInstalled }), "twain")
        XCTAssertEqual(none.status, .warning)
        XCTAssertEqual(none.title, "TWAIN is not installed")
        XCTAssertEqual(none.detail, "Some scanners, often document scanners, work only through their maker's TWAIN driver, which "
                       + "also installs TWAIN. If yours is one of them, install the maker's 64-bit TWAIN driver, then "
                       + "restart CompleteScanner.")
        let some = check(Troubleshooter.diagnose(changed(healthyWindows()) { $0.twain = .notInstalled }), "twain")
        XCTAssertEqual(some.status, .tip)
    }

    func test_twainFailedAndDriverCounts() {
        let failed = check(Troubleshooter.diagnose(changed(healthyWindows()) { $0.twain = .failed }), "twain")
        XCTAssertEqual(failed.status, .warning)
        XCTAssertEqual(failed.title, "TWAIN did not start")
        XCTAssertEqual(failed.actions, [.refresh])
        XCTAssertEqual(check(Troubleshooter.diagnose(changed(healthyWindows()) { $0.twainDriverCount = 0 }), "twain").detail,
                       "No 64-bit TWAIN scanner driver is installed. Most scanners work without one.")
        XCTAssertEqual(check(Troubleshooter.diagnose(changed(healthyWindows()) { $0.twainDriverCount = 1 }), "twain").detail,
                       "1 TWAIN scanner driver is installed.")
        XCTAssertEqual(check(Troubleshooter.diagnose(healthyWindows()), "twain").detail, "2 TWAIN scanner drivers are installed.")
        XCTAssertFalse(ids(Troubleshooter.diagnose(changed(healthyWindows()) { $0.twain = .unknown })).contains("twain"))
    }

    func test_thirtyTwoBitDrivers_areNamedByFile() {
        let one = check(Troubleshooter.diagnose(troubledWindows()), "twain32")
        XCTAssertEqual(one.title, "A TWAIN driver works only with 32-bit apps")
        let oneDetail = [
            "\"acme.ds\" is installed only for 32-bit apps. CompleteScanner reaches such drivers through its ",
            "32-bit TWAIN helper, which has not listed it yet. A 64-bit (x64) driver from the maker, where there ",
            "is one, works without the helper. Many scanners also work through Windows Image Acquisition (WIA) ",
            "once the maker's full driver package is installed.",
        ].joined()
        XCTAssertEqual(one.detail, oneDetail)
        let two = check(Troubleshooter.diagnose(changed(healthyWindows()) { $0.thirtyTwoBitOnlyDrivers = ["Acme/acme.ds", "beta.ds"] }), "twain32")
        XCTAssertEqual(two.status, .problem)
        XCTAssertEqual(two.title, "2 TWAIN drivers work only with 32-bit apps")
        XCTAssertTrue(two.detail.hasPrefix("\"acme.ds\", \"beta.ds\" are installed only for 32-bit apps. CompleteScanner reaches such drivers "
                                           + "through its 32-bit TWAIN helper, which has not listed them yet. "))
    }

    func test_thirtyTwoBitDrivers_sayWhyTheHelperDoesNotReachThem() {
        let snapshot = changed(troubledWindows()) {
            $0.thirtyTwoBitHelperProblem = " It cannot run: it needs the .NET 10 Desktop Runtime for 32-bit programs (x86), "
                + "which is not installed. Install it, then restart CompleteScanner "
        }
        let found = check(Troubleshooter.diagnose(snapshot), "twain32")
        XCTAssertEqual(found.status, .problem)
        XCTAssertEqual(found.title, "A TWAIN driver works only with 32-bit apps")
        let expected = [
            "\"acme.ds\" is installed only for 32-bit apps. CompleteScanner reaches such drivers through its ",
            "32-bit TWAIN helper. It cannot run: it needs the .NET 10 Desktop Runtime for 32-bit programs (x86), ",
            "which is not installed. Install it, then restart CompleteScanner. A 64-bit (x64) driver from the ",
            "maker, where there is one, works without the helper. Many scanners also work through Windows Image ",
            "Acquisition (WIA) once the maker's full driver package is installed.",
        ].joined()
        XCTAssertEqual(found.detail, expected)
        XCTAssertEqual(found.actions, [])
        // A blank reason is no reason.
        XCTAssertEqual(check(Troubleshooter.diagnose(troubledWindows()), "twain32"),
                       check(Troubleshooter.diagnose(changed(troubledWindows()) { $0.thirtyTwoBitHelperProblem = "  " }), "twain32"))
        // Without 32-bit-only drivers, or on the Mac, there is nothing to say.
        XCTAssertFalse(ids(Troubleshooter.diagnose(changed(healthyWindows()) { $0.thirtyTwoBitHelperProblem = "It failed." })).contains("twain32"))
        XCTAssertFalse(ids(Troubleshooter.diagnose(changed(snapshot) { $0.platform = .mac })).contains("twain32"))
    }

    func test_networkSearchOnWindows() {
        func detail(_ snapshot: DiscoverySnapshot) -> String { check(Troubleshooter.diagnose(snapshot), "discovery").detail }
        XCTAssertEqual(detail(changed(healthyWindows()) { $0.discoveredCount = 0 }),
                       "No network scanner has been found on this network yet. A scanner that does not appear can be added by its address.")
        XCTAssertEqual(detail(healthyWindows()),
                       "1 network scanner found. A scanner that does not appear can be added by its address.")
        XCTAssertEqual(detail(changed(healthyWindows()) { $0.discoveredCount = 3 }),
                       "3 network scanners found. A scanner that does not appear can be added by its address.")
        XCTAssertEqual(detail(changed(healthyWindows()) { $0.discovery = .searching }),
                       "The search has just started. Scanners on the network appear as they answer.")
        let running = check(Troubleshooter.diagnose(healthyWindows()), "discovery")
        XCTAssertEqual(running.status, .ok)
        XCTAssertEqual(running.title, "Looking for network scanners")
        XCTAssertEqual(running.actions, [.addByAddress])

        let unavailable = check(Troubleshooter.diagnose(troubledWindows()), "discovery")
        XCTAssertEqual(unavailable.status, .warning)
        XCTAssertEqual(unavailable.title, "Automatic search for network scanners is not working")
        XCTAssertEqual(unavailable.detail, "Windows could not search the network for scanners (Access is denied). You can still add a network "
                       + "scanner by its address.")
        XCTAssertEqual(unavailable.actions, [.addByAddress, .refresh])
        XCTAssertFalse(ids(Troubleshooter.diagnose(changed(healthyWindows()) { $0.discovery = .off })).contains("discovery"))
    }

    func test_addressesAddedByHand_onlyThoseNotAnsweringAreChecks() {
        let checks = Troubleshooter.diagnose(troubledWindows())
        XCTAssertFalse(ids(checks).contains("manualHost:10.0.0.2"))
        XCTAssertEqual(check(checks, "manualHost:192.168.1.50"), TroubleshootCheck(
            id: "manualHost:192.168.1.50", status: .warning, title: "No scanner answers at 192.168.1.50",
            detail: "No scanner answered at 192.168.1.50. Check that the scanner is on and that its address has not changed; "
                + "its network settings page or control panel shows the current one. The app tries the address again every minute.",
            actions: [.refresh]))
        let notChecked = check(Troubleshooter.diagnose(DiscoverySnapshot(manualHosts: [ManualHostStatus(address: "scanner.local", listed: false)])),
                               "manualHost:scanner.local")
        XCTAssertTrue(notChecked.detail.hasPrefix("Check that the scanner is on"))
    }

    func test_windowsTips() {
        let checks = Troubleshooter.diagnose(healthyWindows())
        let usb = check(checks, "usb")
        XCTAssertEqual(usb.title, "Scanner connected by USB?")
        XCTAssertEqual(usb.detail, "Turn the scanner on and connect it straight to the PC, not through a hub. Windows lists a USB "
                       + "scanner only once its driver is installed: get the driver from the scanner maker's website, "
                       + "install it, then select Refresh. Windows scanner settings show whether Windows sees the scanner.")
        XCTAssertEqual(usb.actions, [.openScannerSettings, .refresh])
        let other = check(checks, "otherApps")
        XCTAssertEqual(other.title, "Still not listed?")
        XCTAssertEqual(other.detail, "Wake the scanner (press a button on it), and close other apps that may be using it, such as "
                       + "Windows Scan or the scanner maker's app. Some scanners work only with their maker's own app; "
                       + "the maker's website says whether yours does.")
    }

    func test_mac_hasNoWindowsChecks_andNeverOffersAddByAddress() {
        let snapshot = changed(troubledWindows()) { $0.platform = .mac; $0.discovery = .running }
        let checks = Troubleshooter.diagnose(snapshot)
        XCTAssertEqual(ids(checks), ["lastFailure", "network", "discovery", "usb", "networkScanner", "sharing", "otherApps"])
        XCTAssertFalse(checks.contains { $0.actions.contains(.addByAddress) })
        XCTAssertTrue(check(checks, "lastFailure").detail.contains("such as Image Capture or the scanner maker's app"))
        let discovery = check(checks, "discovery")
        XCTAssertEqual(discovery.status, .ok)
        XCTAssertEqual(discovery.title, "Looking for scanners")
        XCTAssertEqual(discovery.detail, "macOS is looking for scanners connected by USB, on the network and shared by other Macs. They "
                       + "appear here as they are found.")
    }

    func test_macTips() {
        let checks = Troubleshooter.diagnose(DiscoverySnapshot(platform: .mac))
        XCTAssertEqual(ids(checks), ["usb", "networkScanner", "sharing", "otherApps"])
        XCTAssertEqual(check(checks, "usb").actions, [.openImageCapture, .refresh])
        XCTAssertEqual(check(checks, "usb").detail, "Turn the scanner on and connect it straight to the Mac, not through a hub. macOS lists a USB "
                       + "scanner only when it can scan without a driver or its maker's macOS driver is installed: get "
                       + "it from the scanner maker's website. If Image Capture does not show the scanner either, macOS "
                       + "does not see it.")
        XCTAssertEqual(check(checks, "networkScanner").detail, "The Mac and the scanner must be on the same network. If macOS asked whether CompleteScanner may "
                       + "find devices on your local network, allow it in System Settings, Privacy & Security, Local "
                       + "Network. A network printer with a scanner added in Printers & Scanners also appears here.")
        XCTAssertEqual(check(checks, "networkScanner").actions, [.openScannerSettings])
        XCTAssertEqual(check(checks, "sharing").detail, "It appears when Scanner Sharing is on in that Mac's System Settings, General, Sharing, and both "
                       + "Macs are on the same network.")
    }

    func test_mac_searchNotRunning_asksToRefresh() {
        for status in [DiscoveryStatus.off, .unavailable] {
            let found = check(Troubleshooter.diagnose(DiscoverySnapshot(platform: .mac, discovery: status)), "discovery")
            XCTAssertEqual(found.status, .warning)
            XCTAssertEqual(found.title, "Not looking for scanners")
            XCTAssertEqual(found.detail, "The search for scanners is not running. Select Refresh to start it again.")
            XCTAssertEqual(found.actions, [.refresh])
        }
    }

    func test_headline_countsScannersButNotTheDemo() {
        XCTAssertEqual(Troubleshooter.headline(DiscoverySnapshot()), "No scanner found yet")
        XCTAssertEqual(Troubleshooter.headline(DiscoverySnapshot(devices: [demo])), "No scanner found yet")
        let second = ScannerInfo(id: "escl:2", name: "Office MFP", transport: "Network", backend: "escl")
        XCTAssertEqual(Troubleshooter.headline(DiscoverySnapshot(devices: [demo, wiaScanner, second])), "2 scanners found")
    }

    func test_summary_countsProblemsAndWarnings() {
        func make(_ status: CheckStatus) -> TroubleshootCheck { TroubleshootCheck(id: "x", status: status, title: "t", detail: "d", actions: []) }
        XCTAssertEqual(Troubleshooter.summary([make(.problem), make(.ok)]), "1 problem found.")
        XCTAssertEqual(Troubleshooter.summary([make(.warning), make(.tip)]), "1 warning found.")
        XCTAssertEqual(Troubleshooter.summary([make(.problem), make(.warning), make(.problem)]), "2 problems and 1 warning found.")
    }

    func test_labels() {
        XCTAssertEqual(Troubleshooter.label(.refresh, platform: .windows), "Refresh")
        XCTAssertEqual(Troubleshooter.label(.addByAddress, platform: .windows), "Add scanner by address\u{2026}")
        XCTAssertEqual(Troubleshooter.label(.openScannerSettings, platform: .windows), "Open Windows scanner settings")
        XCTAssertEqual(Troubleshooter.label(.openScannerSettings, platform: .mac), "Open Printers & Scanners")
        XCTAssertEqual(Troubleshooter.label(.openNetworkSettings, platform: .windows), "Open network settings")
        XCTAssertEqual(Troubleshooter.label(.openNetworkSettings, platform: .mac), "Open Network settings")
        XCTAssertEqual(Troubleshooter.label(.openImageCapture, platform: .mac), "Open Image Capture")
        XCTAssertEqual(Troubleshooter.label(.copyDiagnostics, platform: .mac), "Copy diagnostics")
        XCTAssertEqual([CheckStatus.ok, .tip, .warning, .problem].map { Troubleshooter.statusLabel($0) }, ["OK", "Tip", "Warning", "Problem"])
    }

    func test_report_listsEveryCheckWithItsDetail() {
        let snapshot = healthyWindows()
        let checks = Troubleshooter.diagnose(snapshot)
        let lines = Troubleshooter.report(snapshot, checks: checks).components(separatedBy: "\n")
        XCTAssertEqual(lines[0], "Why isn't my scanner listed?")
        XCTAssertEqual(lines[1], "1 scanner found. Nothing here stops scanners from appearing. The tips below cover the usual causes.")
        XCTAssertEqual(lines[2], "OK: Connected to a private network")
        XCTAssertEqual(lines[3], "  Network scanners on this network can be found.")
        XCTAssertEqual(lines[lines.count - 3], "Tip: Still not listed?")
        XCTAssertEqual(lines[lines.count - 1], "")
        XCTAssertEqual(lines.count, 2 + 2 * checks.count + 1)
    }

    func test_combineNetworks() {
        XCTAssertEqual(Troubleshooter.combineNetworks([]), .offline)
        XCTAssertEqual(Troubleshooter.combineNetworks([.publicNetwork]), .publicNetwork)
        XCTAssertEqual(Troubleshooter.combineNetworks([.publicNetwork, .privateNetwork]), .privateNetwork)
        XCTAssertEqual(Troubleshooter.combineNetworks([.privateNetwork, .domainNetwork]), .domainNetwork)
        XCTAssertEqual(Troubleshooter.combineNetworks([.unknown]), .unknown)
        XCTAssertEqual(Troubleshooter.combineNetworks([.unknown, .publicNetwork]), .publicNetwork)
    }

    func test_failure_keepsWhatSaysSomethingAboutTheScanner() {
        XCTAssertEqual(Troubleshooter.failure(deviceName: "Acme", error: ScanError.scannerProblem(.busy)),
                       ScannerFailure(deviceName: "Acme", message: ScannerProblems.describe(.busy), problem: .busy))
        XCTAssertEqual(Troubleshooter.failure(deviceName: "Acme", error: ScanError.deviceUnavailable("gone")),
                       ScannerFailure(deviceName: "Acme", message: "Scanner unavailable: gone"))
        XCTAssertEqual(Troubleshooter.failure(deviceName: "Acme", error: ScanError.sessionFailed("x")),
                       ScannerFailure(deviceName: "Acme", message: "Could not open a session with the scanner: x"))
        XCTAssertNil(Troubleshooter.failure(deviceName: "Acme", error: ScanError.cancelled))
        XCTAssertNil(Troubleshooter.failure(deviceName: "Acme", error: ScanError.exportFailed("disk full")))
        XCTAssertNil(Troubleshooter.failure(deviceName: "Acme", error: ScanError.unsupported("1200 dpi")))
    }

    func test_failure_ignoresCancellation() {
        XCTAssertNil(Troubleshooter.failure(deviceName: "Acme", error: CancellationError()))
    }
}
