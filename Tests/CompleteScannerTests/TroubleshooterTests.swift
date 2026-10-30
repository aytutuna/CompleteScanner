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
        XCTAssertEqual(Troubleshooter.headline(snapshot), "No scanner found")
        XCTAssertEqual(Troubleshooter.summary(checks), "3 problems and 4 warnings found.")
        XCTAssertEqual(Troubleshooter.overview(snapshot, checks: checks), "No scanner found \u{00B7} 3 problems, 4 warnings")
    }

    func test_overview_isOneLine() {
        let healthy = healthyWindows()
        XCTAssertEqual(Troubleshooter.overview(healthy, checks: Troubleshooter.diagnose(healthy)), "1 scanner found")
        let publicNetwork = DiscoverySnapshot(devices: [demo], network: .publicNetwork)
        XCTAssertEqual(Troubleshooter.overview(publicNetwork, checks: Troubleshooter.diagnose(publicNetwork)),
                       "No scanner found \u{00B7} 1 warning")
        let offline = DiscoverySnapshot(network: .offline)
        XCTAssertEqual(Troubleshooter.overview(offline, checks: Troubleshooter.diagnose(offline)), "No scanner found \u{00B7} 1 problem")
    }

    /// Every check the fixtures make, on both platforms.
    private func everyCheck() -> [TroubleshootCheck] {
        var snapshots: [DiscoverySnapshot] = [healthyWindows(), troubledWindows()]
        for service in [ServiceStatus.unknown, .running, .starting, .stopping, .stopped, .paused, .disabled, .notInstalled] {
            snapshots.append(changed(healthyWindows()) { $0.wiaService = service })
        }
        for twain in [TwainStatus.unknown, .available, .notInstalled, .failed] {
            snapshots.append(changed(healthyWindows()) { $0.twain = twain; $0.twainDriverCount = 0 })
        }
        for network in [NetworkStatus.unknown, .offline, .publicNetwork, .privateNetwork, .domainNetwork] {
            snapshots.append(changed(healthyWindows()) { $0.network = network })
        }
        for discovery in [DiscoveryStatus.unknown, .off, .searching, .running, .unavailable, .denied] {
            snapshots.append(changed(healthyWindows()) { $0.discovery = discovery })
            snapshots.append(DiscoverySnapshot(platform: .mac, discovery: discovery))
        }
        for problem in ScannerProblem.allCases {
            snapshots.append(DiscoverySnapshot(lastFailure: ScannerFailure(deviceName: "Acme", message: "x", problem: problem)))
        }
        snapshots.append(DiscoverySnapshot(lastFailure: ScannerFailure(deviceName: "Office MFP", message: "Office MFP did not answer.")))
        snapshots.append(changed(troubledWindows()) { $0.platform = .mac })
        snapshots.append(healthyPhone())
        snapshots.append(troubledPhone())
        for network in [NetworkStatus.unknown, .offline, .publicNetwork, .privateNetwork, .domainNetwork] {
            snapshots.append(changed(healthyPhone()) { $0.network = network })
        }
        for discovery in [DiscoveryStatus.unknown, .off, .searching, .running, .unavailable, .denied] {
            snapshots.append(changed(healthyPhone()) { $0.discovery = discovery })
        }
        for problem in ScannerProblem.allCases {
            snapshots.append(changed(healthyPhone()) { $0.lastFailure = ScannerFailure(deviceName: "Acme", message: "x", problem: problem) })
        }
        snapshots.append(changed(healthyPhone()) {
            $0.lastFailure = ScannerFailure(deviceName: "Office MFP", message: "Office MFP did not answer.")
        })
        return snapshots.flatMap { (snapshot: DiscoverySnapshot) -> [TroubleshootCheck] in Troubleshooter.diagnose(snapshot) }
    }

    // MARK: - iPhone and iPad (never produced on Windows)

    private let networkScanner = ScannerInfo(id: "escl:uuid", name: "HP Color LaserJet MFP M479fdw", transport: "Network",
                                             backend: "escl")

    /// A phone on Wi-Fi that found a network scanner.
    private func healthyPhone() -> DiscoverySnapshot {
        DiscoverySnapshot(platform: .ios, devices: [demo, networkScanner], network: .privateNetwork,
                          discovery: .running, discoveredCount: 1)
    }

    /// A phone off Wi-Fi, without Local Network access, with an address that does not answer.
    private func troubledPhone() -> DiscoverySnapshot {
        DiscoverySnapshot(platform: .ios, devices: [demo], network: .offline, discovery: .denied,
                          manualHosts: [ManualHostStatus(address: "192.168.1.50", listed: false, problem: "No scanner answered at 192.168.1.50."),
                                        ManualHostStatus(address: "10.0.0.2", listed: true)],
                          lastFailure: ScannerFailure(deviceName: "Office MFP", message: "Office MFP did not answer."))
    }

    func test_phone_healthy_showsWhatIsFineThenItsTips() {
        let snapshot: DiscoverySnapshot = healthyPhone()
        let checks: [TroubleshootCheck] = Troubleshooter.diagnose(snapshot)
        XCTAssertEqual(ids(checks), ["network", "discovery", "networkScanner", "usb", "otherApps"])
        XCTAssertEqual(checks.map { $0.status }, [.ok, .ok, .tip, .tip, .tip])
        XCTAssertEqual(Troubleshooter.overview(snapshot, checks: checks), "1 scanner found")
        let network: TroubleshootCheck = check(checks, "network")
        XCTAssertEqual(network.title, "Connected to a local network")
        XCTAssertEqual(network.detail, "Network scanners on this network can be found.")
        let discovery: TroubleshootCheck = check(checks, "discovery")
        XCTAssertEqual(discovery.status, .ok)
        XCTAssertEqual(discovery.title, "Looking for network scanners")
        XCTAssertEqual(discovery.fullDetail, "1 network scanner found. A scanner that doesn't appear can be added by its address.")
        XCTAssertEqual(discovery.actions, [.addByAddress])
        XCTAssertEqual(check(checks, "networkScanner"), TroubleshootCheck(
            id: "networkScanner", status: .tip, title: "Scanner on the network?",
            detail: "This device and the scanner must be on the same Wi-Fi.",
            more: "Guest networks and some VPNs hide scanners. Try adding the scanner by its address.",
            actions: [.addByAddress]))
        XCTAssertEqual(check(checks, "usb"), TroubleshootCheck(
            id: "usb", status: .tip, title: "Connected by USB?",
            detail: "Use its Wi-Fi connection; iPhone and iPad can't use USB scanners.",
            more: "Most scanners that print or copy also join Wi-Fi. The scanner's manual shows how.",
            actions: []))
        XCTAssertEqual(check(checks, "otherApps").more, "Press a button on the scanner. Close scanning apps on other devices. Some "
                       + "scanners work only with Windows (WSD) or their maker's app.")
    }

    func test_phone_troubled_localNetworkAccessOffComesFirstWithSettings() {
        let snapshot: DiscoverySnapshot = troubledPhone()
        let checks: [TroubleshootCheck] = Troubleshooter.diagnose(snapshot)
        XCTAssertEqual(ids(checks), ["network", "localNetwork", "lastFailure", "manualHost:192.168.1.50", "networkScanner", "usb",
                                     "otherApps"])
        XCTAssertEqual(Troubleshooter.overview(snapshot, checks: checks), "No scanner found \u{00B7} 2 problems, 2 warnings")
        XCTAssertEqual(check(checks, "localNetwork"), TroubleshootCheck(
            id: "localNetwork", status: .problem, title: "Local Network access is off",
            detail: "Turn on Local Network for Lazy Scan in Settings.",
            more: "Without it, the app can't find or reach scanners on your network. Scanners appear as soon as it's on. "
                + "If it's on already, turn it off and on again.",
            actions: [.openAppSettings]))
        XCTAssertEqual(check(checks, "network"), TroubleshootCheck(
            id: "network", status: .problem, title: "Not connected to Wi-Fi",
            detail: "Join the scanner's Wi-Fi network, then tap Refresh.",
            more: "Network scanners are found only on Wi-Fi or a wired network. The camera works without one.",
            actions: [.refresh]))
        XCTAssertEqual(check(checks, "lastFailure").more, "Office MFP did not answer. It must be on the same network as this device.")
        XCTAssertTrue(check(checks, "manualHost:192.168.1.50").more
            .hasPrefix("No scanner answered at 192.168.1.50. Its network settings page"))
        XCTAssertFalse(ids(checks).contains("manualHost:10.0.0.2"))
        let busy: [TroubleshootCheck] = Troubleshooter.diagnose(changed(healthyPhone()) {
            $0.lastFailure = ScannerFailure(deviceName: "Acme", message: "x", problem: .busy)
        })
        XCTAssertTrue(check(busy, "lastFailure").more.contains("another device or app may be using it"))
    }

    func test_phone_searchStates_sayWhatIOSDoes() {
        func detail(_ snapshot: DiscoverySnapshot) -> String {
            check(Troubleshooter.diagnose(snapshot), "discovery").fullDetail
        }
        XCTAssertEqual(detail(changed(healthyPhone()) { $0.discovery = .searching }),
                       "Scanners on the network appear as they answer. The search has just started.")
        let unavailable: TroubleshootCheck = check(Troubleshooter.diagnose(changed(healthyPhone()) {
            $0.discovery = .unavailable
            $0.discoveryDetail = "NoSuchRecord."
        }), "discovery")
        XCTAssertEqual(unavailable.status, .warning)
        XCTAssertEqual(unavailable.title, "Network search is not working")
        XCTAssertEqual(unavailable.more, "iOS could not search the network for scanners (NoSuchRecord).")
        XCTAssertEqual(unavailable.actions, [.addByAddress, .refresh])
        // Before the search has started there is nothing to say; denied access replaces the search's check.
        XCTAssertFalse(ids(Troubleshooter.diagnose(changed(healthyPhone()) { $0.discovery = .off })).contains("discovery"))
        let denied: [TroubleshootCheck] = Troubleshooter.diagnose(changed(healthyPhone()) { $0.discovery = .denied })
        XCTAssertFalse(ids(denied).contains("discovery"))
        XCTAssertTrue(ids(denied).contains("localNetwork"))
        // iOS has no public networks: any local network is fine; an unknown one has no check.
        XCTAssertEqual(check(Troubleshooter.diagnose(changed(healthyPhone()) { $0.network = .publicNetwork }), "network").status, .ok)
        XCTAssertFalse(ids(Troubleshooter.diagnose(changed(healthyPhone()) { $0.network = .unknown })).contains("network"))
    }

    func test_phone_neverOffersTheComputersActions_andTheComputersNeverOfferSettings() {
        let computerActions: [TroubleshootAction] = [.openScannerSettings, .openNetworkSettings, .openImageCapture]
        var phone: [TroubleshootCheck] = []
        for snapshot in [healthyPhone(), troubledPhone()] {
            for network in [NetworkStatus.unknown, .offline, .publicNetwork, .privateNetwork, .domainNetwork] {
                for discovery in [DiscoveryStatus.unknown, .off, .searching, .running, .unavailable, .denied] {
                    phone.append(contentsOf: Troubleshooter.diagnose(changed(snapshot) {
                        $0.network = network
                        $0.discovery = discovery
                    }))
                }
            }
        }
        for found in phone {
            for action in computerActions {
                XCTAssertFalse(found.actions.contains(action), found.id)
            }
        }
        // Windows and the Mac never report denied access, so they never offer the phone's Settings.
        XCTAssertFalse(Troubleshooter.diagnose(troubledWindows()).contains { $0.actions.contains(.openAppSettings) })
        XCTAssertFalse(Troubleshooter.diagnose(changed(healthyWindows()) { $0.platform = .mac })
            .contains { $0.actions.contains(.openAppSettings) })
    }

    func test_everyCheck_hasAShortTitle_andAOneLineDetail_theRestIsMoreHelp() {
        for found in everyCheck() {
            XCTAssertTrue((1...6).contains(StatusLine.words(found.title)), found.title)
            XCTAssertTrue((1...15).contains(StatusLine.words(found.detail)), found.detail)
            XCTAssertEqual(found.fullDetail, found.more.isEmpty ? found.detail : found.detail + " " + found.more)
            XCTAssertFalse(!found.more.isEmpty && found.more.contains(found.detail), found.id)
        }
        let actions: [TroubleshootAction] = [.refresh, .addByAddress, .openScannerSettings, .openNetworkSettings,
                                             .openImageCapture, .copyDiagnostics, .openAppSettings]
        XCTAssertEqual(actions, TroubleshootAction.allCases)
        for action in actions {
            XCTAssertTrue((1...3).contains(StatusLine.words(Troubleshooter.label(action, platform: .windows))))
            XCTAssertTrue((1...3).contains(StatusLine.words(Troubleshooter.label(action, platform: .mac))))
            XCTAssertTrue((1...3).contains(StatusLine.words(Troubleshooter.label(action, platform: .ios))))
        }
    }

    func test_nothingKnown_onlyTheTips() {
        XCTAssertEqual(ids(Troubleshooter.diagnose(DiscoverySnapshot(platform: .windows))), ["usb", "otherApps"])
    }

    func test_busyScanner_saysToCloseOtherApps() {
        XCTAssertEqual(check(Troubleshooter.diagnose(troubledWindows()), "lastFailure"), TroubleshootCheck(
            id: "lastFailure", status: .problem, title: "Acme Scan 100 is busy",
            detail: "Close other apps using it, then choose it again.",
            more: "A scanner works with one app at a time; Windows Scan or the maker's app may be using it. Wait until the "
                + "scanner has finished, then choose it again.",
            actions: [.refresh]))
    }

    func test_otherScannerProblem_usesItsText() {
        let snapshot = DiscoverySnapshot(lastFailure: ScannerFailure(deviceName: "Acme Scan 100", message: "x", problem: .coverOpen))
        let found = check(Troubleshooter.diagnose(snapshot), "lastFailure")
        XCTAssertEqual(found.status, .problem)
        XCTAssertEqual(found.title, "Cover open: Acme Scan 100")
        XCTAssertEqual(found.detail, "Close the cover, then scan again.")
        XCTAssertEqual(found.detail, ScannerProblems.advice(.coverOpen))
        XCTAssertEqual(found.more, "")
    }

    func test_failureWithoutProblem_isAWarningWithTheMessage() {
        let snapshot = DiscoverySnapshot(lastFailure: ScannerFailure(deviceName: "Office MFP",
                                                                     message: "Office MFP did not answer (192.168.1.9: no answer in time)"))
        let found = check(Troubleshooter.diagnose(snapshot), "lastFailure")
        XCTAssertEqual(found.status, .warning)
        XCTAssertEqual(found.title, "Could not connect to Office MFP")
        XCTAssertEqual(found.detail, "Check that it is on, awake and connected.")
        XCTAssertEqual(found.more, "Office MFP did not answer (192.168.1.9: no answer in time). It must be connected by its cable or "
                       + "to the same network as this PC.")
        let mac = check(Troubleshooter.diagnose(changed(snapshot) { $0.platform = .mac }), "lastFailure")
        XCTAssertTrue(mac.more.hasSuffix("to the same network as this Mac."))
    }

    func test_wiaService() {
        let cases: [(ServiceStatus, CheckStatus, String)] = [
            (.running, .ok, "Scanner service is on"),
            (.starting, .warning, "Scanner service is starting"),
            (.stopped, .warning, "Scanner service is not running"),
            (.stopping, .warning, "Scanner service is not running"),
            (.paused, .warning, "Scanner service is not running"),
            (.disabled, .problem, "Scanner service is turned off"),
            (.notInstalled, .problem, "Scanner service is missing"),
        ]
        for (service, status, title) in cases {
            let found = check(Troubleshooter.diagnose(changed(healthyWindows()) { $0.wiaService = service }), "wiaService")
            XCTAssertEqual(found.status, status, "\(service)")
            XCTAssertEqual(found.title, title)
            XCTAssertTrue(found.fullDetail.contains("Windows Image Acquisition (WIA)"))
        }
    }

    func test_wiaService_unknownHasNoCheck() {
        XCTAssertFalse(ids(Troubleshooter.diagnose(changed(healthyWindows()) { $0.wiaService = .unknown })).contains("wiaService"))
    }

    func test_disabledWiaService_saysHowToTurnItOnWithoutDoingIt() {
        let found = check(Troubleshooter.diagnose(changed(healthyWindows()) { $0.wiaService = .disabled }), "wiaService")
        XCTAssertEqual(found.detail, "An administrator can set it to Automatic in Services.")
        XCTAssertEqual(found.more, "Windows Image Acquisition (WIA), which most scanners use, is disabled, so those scanners can't "
                       + "appear. Someone with administrator rights can set its startup type to Automatic in Services, then "
                       + "restart the PC.")
        XCTAssertEqual(found.actions, [.refresh])
    }

    func test_network() {
        let offline = check(Troubleshooter.diagnose(changed(healthyWindows()) { $0.network = .offline }), "network")
        XCTAssertEqual(offline.status, .problem)
        XCTAssertEqual(offline.title, "Not connected to a network")
        XCTAssertEqual(offline.detail, "Connect to the network the scanner is on, then select Refresh.")
        XCTAssertEqual(offline.more, "This PC is not on a network, so network scanners can't be found. Scanners connected by USB are not "
                       + "affected.")
        XCTAssertEqual(offline.actions, [.openNetworkSettings, .refresh])

        let publicNetwork = check(Troubleshooter.diagnose(changed(healthyWindows()) { $0.network = .publicNetwork }), "network")
        XCTAssertEqual(publicNetwork.status, .warning)
        XCTAssertEqual(publicNetwork.title, "Network set to Public")
        XCTAssertEqual(publicNetwork.detail, "Windows won't find network scanners on a Public network.")
        XCTAssertEqual(publicNetwork.more, "If this is your home or office network, set it to Private in network settings. You can also add "
                       + "the scanner by its address.")
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
        XCTAssertEqual(none.detail, "Some scanners need their maker's 64-bit TWAIN driver.")
        XCTAssertEqual(none.more, "Some scanners, often document scanners, work only through their maker's TWAIN driver, which "
                       + "also installs TWAIN. If yours is one of them, install the maker's 64-bit TWAIN driver, then "
                       + "restart Lazy Scan.")
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
        XCTAssertEqual(one.title, "A TWAIN driver is 32-bit only")
        XCTAssertEqual(one.detail, "\"acme.ds\" is installed only for 32-bit apps.")
        let oneMore = [
            "Lazy Scan reaches such drivers through its 32-bit TWAIN helper, which has not listed it yet. ",
            "A 64-bit (x64) driver from the maker, where there is one, works without the helper. Many scanners ",
            "also work through Windows Image Acquisition (WIA) once the maker's full driver package is installed.",
        ].joined()
        XCTAssertEqual(one.more, oneMore)
        let two = check(Troubleshooter.diagnose(changed(healthyWindows()) { $0.thirtyTwoBitOnlyDrivers = ["Acme/acme.ds", "beta.ds"] }), "twain32")
        XCTAssertEqual(two.status, .problem)
        XCTAssertEqual(two.title, "2 TWAIN drivers are 32-bit only")
        XCTAssertEqual(two.detail, "\"acme.ds\", \"beta.ds\" are installed only for 32-bit apps.")
        XCTAssertTrue(two.more.hasPrefix("Lazy Scan reaches such drivers through its 32-bit TWAIN helper, which has not listed them yet. "))
    }

    func test_thirtyTwoBitDrivers_sayWhyTheHelperDoesNotReachThem() {
        let snapshot = changed(troubledWindows()) {
            $0.thirtyTwoBitHelperProblem = " It cannot run: it needs the .NET 10 Desktop Runtime for 32-bit programs (x86), "
                + "which is not installed. Install it, then restart Lazy Scan "
        }
        let found = check(Troubleshooter.diagnose(snapshot), "twain32")
        XCTAssertEqual(found.status, .problem)
        XCTAssertEqual(found.title, "A TWAIN driver is 32-bit only")
        XCTAssertEqual(found.detail, "\"acme.ds\" is installed only for 32-bit apps.")
        let expected = [
            "Lazy Scan reaches such drivers through its 32-bit TWAIN helper. It cannot run: it needs the ",
            ".NET 10 Desktop Runtime for 32-bit programs (x86), which is not installed. Install it, then restart ",
            "Lazy Scan. A 64-bit (x64) driver from the maker, where there is one, works without the helper. ",
            "Many scanners also work through Windows Image Acquisition (WIA) once the maker's full driver package ",
            "is installed.",
        ].joined()
        XCTAssertEqual(found.more, expected)
        XCTAssertEqual(found.actions, [])
        // A blank reason is no reason.
        XCTAssertEqual(check(Troubleshooter.diagnose(troubledWindows()), "twain32"),
                       check(Troubleshooter.diagnose(changed(troubledWindows()) { $0.thirtyTwoBitHelperProblem = "  " }), "twain32"))
        // Without 32-bit-only drivers, or on the Mac, there is nothing to say.
        XCTAssertFalse(ids(Troubleshooter.diagnose(changed(healthyWindows()) { $0.thirtyTwoBitHelperProblem = "It failed." })).contains("twain32"))
        XCTAssertFalse(ids(Troubleshooter.diagnose(changed(snapshot) { $0.platform = .mac })).contains("twain32"))
    }

    func test_networkSearchOnWindows() {
        func detail(_ snapshot: DiscoverySnapshot) -> String { check(Troubleshooter.diagnose(snapshot), "discovery").fullDetail }
        XCTAssertEqual(detail(changed(healthyWindows()) { $0.discoveredCount = 0 }),
                       "No network scanner has been found on this network yet. A scanner that doesn't appear can be added by its address.")
        XCTAssertEqual(detail(healthyWindows()),
                       "1 network scanner found. A scanner that doesn't appear can be added by its address.")
        XCTAssertEqual(detail(changed(healthyWindows()) { $0.discoveredCount = 3 }),
                       "3 network scanners found. A scanner that doesn't appear can be added by its address.")
        XCTAssertEqual(detail(changed(healthyWindows()) { $0.discovery = .searching }),
                       "Scanners on the network appear as they answer. The search has just started.")
        let running = check(Troubleshooter.diagnose(healthyWindows()), "discovery")
        XCTAssertEqual(running.status, .ok)
        XCTAssertEqual(running.title, "Looking for network scanners")
        XCTAssertEqual(running.actions, [.addByAddress])

        let unavailable = check(Troubleshooter.diagnose(troubledWindows()), "discovery")
        XCTAssertEqual(unavailable.status, .warning)
        XCTAssertEqual(unavailable.title, "Network search is not working")
        XCTAssertEqual(unavailable.detail, "You can still add a network scanner by its address.")
        XCTAssertEqual(unavailable.more, "Windows could not search the network for scanners (Access is denied).")
        XCTAssertEqual(unavailable.actions, [.addByAddress, .refresh])
        XCTAssertFalse(ids(Troubleshooter.diagnose(changed(healthyWindows()) { $0.discovery = .off })).contains("discovery"))
    }

    func test_addressesAddedByHand_onlyThoseNotAnsweringAreChecks() {
        let checks = Troubleshooter.diagnose(troubledWindows())
        XCTAssertFalse(ids(checks).contains("manualHost:10.0.0.2"))
        XCTAssertEqual(check(checks, "manualHost:192.168.1.50"), TroubleshootCheck(
            id: "manualHost:192.168.1.50", status: .warning, title: "No scanner answers at 192.168.1.50",
            detail: "Check that it is on and its address hasn't changed.",
            more: "No scanner answered at 192.168.1.50. Its network settings page or control panel shows the current address. "
                + "The app tries the address again every minute.",
            actions: [.refresh]))
        let notChecked = check(Troubleshooter.diagnose(DiscoverySnapshot(manualHosts: [ManualHostStatus(address: "scanner.local", listed: false)])),
                               "manualHost:scanner.local")
        XCTAssertTrue(notChecked.more.hasPrefix("Its network settings page"))
    }

    func test_windowsTips() {
        let checks = Troubleshooter.diagnose(healthyWindows())
        let usb = check(checks, "usb")
        XCTAssertEqual(usb.title, "Connected by USB?")
        XCTAssertEqual(usb.detail, "Connect it directly (no hub) and install the maker's driver.")
        XCTAssertEqual(usb.more, "Windows lists a USB scanner only after its driver is installed. Get it from the maker's website, "
                       + "then select Refresh. Scanner settings show whether Windows sees it.")
        XCTAssertEqual(usb.actions, [.openScannerSettings, .refresh])
        let other = check(checks, "otherApps")
        XCTAssertEqual(other.title, "Still not listed?")
        XCTAssertEqual(other.detail, "Wake the scanner and close other scanning apps.")
        XCTAssertEqual(other.more, "Press a button on the scanner. Close Windows Scan or the maker's app. Some scanners work only with "
                       + "their maker's app.")
    }

    func test_mac_hasNoWindowsChecks_andNeverOffersAddByAddress() {
        let snapshot = changed(troubledWindows()) { $0.platform = .mac; $0.discovery = .running }
        let checks = Troubleshooter.diagnose(snapshot)
        XCTAssertEqual(ids(checks), ["lastFailure", "network", "discovery", "usb", "networkScanner", "sharing", "otherApps"])
        XCTAssertFalse(checks.contains { $0.actions.contains(.addByAddress) })
        XCTAssertTrue(check(checks, "lastFailure").more.contains("Image Capture or the maker's app may be using it"))
        let discovery = check(checks, "discovery")
        XCTAssertEqual(discovery.status, .ok)
        XCTAssertEqual(discovery.title, "Looking for scanners")
        XCTAssertEqual(discovery.detail, "Scanners appear here as macOS finds them.")
        XCTAssertEqual(discovery.more, "macOS looks for scanners connected by USB, on the network and shared by other Macs.")
    }

    func test_macTips() {
        let checks = Troubleshooter.diagnose(DiscoverySnapshot(platform: .mac))
        XCTAssertEqual(ids(checks), ["usb", "networkScanner", "sharing", "otherApps"])
        XCTAssertEqual(check(checks, "usb").actions, [.openImageCapture, .refresh])
        XCTAssertEqual(check(checks, "usb").detail, "Connect it directly (no hub) and install the maker's macOS driver.")
        XCTAssertEqual(check(checks, "usb").more, "macOS lists a USB scanner only when it can scan without a driver or its maker's driver is "
                       + "installed. If Image Capture doesn't show it either, macOS doesn't see it.")
        XCTAssertEqual(check(checks, "networkScanner").detail, "The Mac and the scanner must be on the same network.")
        XCTAssertEqual(check(checks, "networkScanner").more, "If macOS asked whether Lazy Scan may find devices on your local network, "
                       + "allow it in System Settings, Privacy & Security, Local Network. A network printer with a scanner added in "
                       + "Printers & Scanners also appears here.")
        XCTAssertEqual(check(checks, "networkScanner").actions, [.openScannerSettings])
        XCTAssertEqual(check(checks, "sharing").title, "Shared by another Mac?")
        XCTAssertEqual(check(checks, "sharing").detail, "Turn on Scanner Sharing in that Mac's Sharing settings.")
        XCTAssertEqual(check(checks, "sharing").more, "It's in System Settings, General, Sharing. Both Macs must be on the same network.")
        XCTAssertEqual(check(checks, "otherApps").more, "Press a button on the scanner. Close Image Capture or the maker's app. Some "
                       + "scanners work only with their maker's app.")
    }

    func test_mac_searchNotRunning_asksToRefresh() {
        for status in [DiscoveryStatus.off, .unavailable] {
            let found = check(Troubleshooter.diagnose(DiscoverySnapshot(platform: .mac, discovery: status)), "discovery")
            XCTAssertEqual(found.status, .warning)
            XCTAssertEqual(found.title, "Not looking for scanners")
            XCTAssertEqual(found.detail, "Select Refresh to start the search again.")
            XCTAssertEqual(found.more, "The search for scanners is not running.")
            XCTAssertEqual(found.actions, [.refresh])
        }
    }

    func test_headline_countsScannersButNotTheDemo() {
        XCTAssertEqual(Troubleshooter.headline(DiscoverySnapshot()), "No scanner found")
        XCTAssertEqual(Troubleshooter.headline(DiscoverySnapshot(devices: [demo])), "No scanner found")
        XCTAssertEqual(Troubleshooter.headline(DiscoverySnapshot(devices: [demo, wiaScanner])), "1 scanner found")
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
        XCTAssertEqual(Troubleshooter.label(.addByAddress, platform: .windows), "Add by address\u{2026}")
        XCTAssertEqual(Troubleshooter.label(.openScannerSettings, platform: .windows), "Scanner settings")
        XCTAssertEqual(Troubleshooter.label(.openScannerSettings, platform: .mac), "Printers & Scanners")
        XCTAssertEqual(Troubleshooter.label(.openNetworkSettings, platform: .windows), "Network settings")
        XCTAssertEqual(Troubleshooter.label(.openNetworkSettings, platform: .mac), "Network settings")
        XCTAssertEqual(Troubleshooter.label(.openImageCapture, platform: .mac), "Image Capture")
        XCTAssertEqual(Troubleshooter.label(.copyDiagnostics, platform: .mac), "Copy diagnostics")
        XCTAssertEqual(Troubleshooter.label(.openAppSettings, platform: .ios), "Open Settings")
        XCTAssertEqual(Troubleshooter.label(.addByAddress, platform: .ios), "Add by address\u{2026}")
        XCTAssertEqual([CheckStatus.ok, .tip, .warning, .problem].map { Troubleshooter.statusLabel($0) }, ["OK", "Tip", "Warning", "Problem"])
    }

    func test_report_listsEveryCheckWithItsDetail_andItsMoreHelp() {
        let snapshot = healthyWindows()
        let checks = Troubleshooter.diagnose(snapshot)
        let lines = Troubleshooter.report(snapshot, checks: checks).components(separatedBy: "\n")
        XCTAssertEqual(lines[0], "Why isn't my scanner listed?")
        XCTAssertEqual(lines[1], "1 scanner found. Nothing here stops scanners from appearing. The tips below cover the usual causes.")
        XCTAssertEqual(lines[2], "OK: Connected to a private network")
        XCTAssertEqual(lines[3], "  Network scanners on this network can be found.")
        XCTAssertEqual(lines[lines.count - 4], "Tip: Still not listed?")
        XCTAssertEqual(lines[lines.count - 3], "  Wake the scanner and close other scanning apps.")
        XCTAssertEqual(lines[lines.count - 2], "  Press a button on the scanner. Close Windows Scan or the maker's app. Some scanners work "
                       + "only with their maker's app.")
        XCTAssertEqual(lines[lines.count - 1], "")
        let withMore: Int = checks.filter { !$0.more.isEmpty }.count
        XCTAssertEqual(lines.count, 2 + 2 * checks.count + withMore + 1)
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
