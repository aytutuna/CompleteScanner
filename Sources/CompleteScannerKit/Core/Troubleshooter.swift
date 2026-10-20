import Foundation

// "Why isn't my scanner listed?": what the app knows about finding scanners, gathered into one
// snapshot and turned into plain-language checks, each with the actions that help. The apps only
// read the system's state and link to the system's settings; they never change a service or a
// setting. Twin of windows/CompleteScanner.Core/Troubleshooter.cs (same checks, same text, same
// order). The Windows-only fields (the WIA service, TWAIN, addresses added by hand) are kept so
// both suites run the same fixtures; the Mac leaves them at their defaults.

/// Which app the snapshot comes from: the checks and their wording follow it.
public enum TroubleshootPlatform: String, Sendable {
    case windows
    case mac
}

/// The network the computer is on, as far as finding network scanners goes.
public enum NetworkStatus: String, Sendable {
    /// Not known (the Mac does not check).
    case unknown
    /// Not connected to any network.
    case offline
    /// Every connected network is public: Windows does not look for devices there.
    case publicNetwork
    case privateNetwork
    case domainNetwork
}

/// The state of a system service (on Windows, Windows Image Acquisition: stisvc).
public enum ServiceStatus: String, Sendable {
    /// Not known (not checked, or the system would not say).
    case unknown
    case running
    case starting
    case stopping
    case stopped
    case paused
    /// Stopped and set not to start.
    case disabled
    case notInstalled
}

/// Whether TWAIN can be used on the PC (Windows only).
public enum TwainStatus: String, Sendable {
    /// Not checked yet, or not a Windows snapshot.
    case unknown
    case available
    /// No TWAIN Data Source Manager (TWAINDSM.dll) is installed.
    case notInstalled
    /// The Data Source Manager is installed but would not open.
    case failed
}

/// The automatic search for scanners: on Windows the DNS-SD search for network (eSCL) scanners,
/// on the Mac ImageCaptureCore's device browser (USB, network and shared scanners).
public enum DiscoveryStatus: String, Sendable {
    /// Not known; no check is shown.
    case unknown
    /// Not running.
    case off
    /// Started; the first pass has not finished.
    case searching
    case running
    /// The system would not search.
    case unavailable
}

/// How a check came out. The order is not the display order (see `Troubleshooter.diagnose`).
public enum CheckStatus: String, CaseIterable, Sendable {
    case ok
    /// Advice that applies whatever the checks found.
    case tip
    case warning
    case problem
}

/// Something the troubleshooter offers to do; the app carries it out.
public enum TroubleshootAction: String, CaseIterable, Sendable {
    /// Look for scanners again.
    case refresh
    /// The "Add scanner by address" dialog (Windows only).
    case addByAddress
    /// Windows: Settings, Printers & scanners. Mac: System Settings, Printers & Scanners.
    case openScannerSettings
    /// Windows: Settings, Network & internet. Mac: System Settings, Network.
    case openNetworkSettings
    /// The Mac's Image Capture app, which shows every scanner macOS sees.
    case openImageCapture
    /// Copies the checks and the device diagnostics as text.
    case copyDiagnostics
}

/// An address added by hand (Windows: escl-hosts.json) and whether a scanner answers there.
public struct ManualHostStatus: Equatable, Sendable {
    /// As the user would write it, e.g. "192.168.1.50" or "https://scanner.local".
    public var address: String
    /// A scanner answered and is listed.
    public var listed: Bool
    /// Why nothing is listed, in plain language; nil when listed or not checked yet.
    public var problem: String?

    public init(address: String, listed: Bool, problem: String? = nil) {
        self.address = address
        self.listed = listed
        self.problem = problem
    }
}

/// The last time connecting to a scanner, or scanning with it, failed.
public struct ScannerFailure: Equatable, Sendable {
    /// The scanner's name as listed.
    public var deviceName: String
    /// The error the user was shown.
    public var message: String
    /// The condition at the scanner behind it, when the connection could tell.
    public var problem: ScannerProblem?

    public init(deviceName: String, message: String, problem: ScannerProblem? = nil) {
        self.deviceName = deviceName
        self.message = message
        self.problem = problem
    }
}

/// Everything the troubleshooter looks at, read at one moment. The app fills in the system's
/// state and the scanners listed; each connection that conforms to `ScannerBackendDiagnostics`
/// adds what it knows. Fields left at their defaults (unknown, empty) produce no check.
public struct DiscoverySnapshot: Equatable, Sendable {
    public var platform: TroubleshootPlatform
    /// The scanners listed, one per row, the demo scanner included.
    public var devices: [ScannerInfo]
    public var network: NetworkStatus
    /// Windows Image Acquisition (stisvc); Windows only.
    public var wiaService: ServiceStatus
    public var twain: TwainStatus
    /// The TWAIN drivers (data sources) the 64-bit Windows app can use.
    public var twainDriverCount: Int
    /// TWAIN driver files installed only for 32-bit apps (paths or file names).
    public var thirtyTwoBitOnlyDrivers: [String]
    /// Why the 32-bit TWAIN helper (Windows) does not reach `thirtyTwoBitOnlyDrivers`, as
    /// sentences about the helper ("It …") with what to do; nil when not known. Never set on the Mac.
    public var thirtyTwoBitHelperProblem: String?
    public var discovery: DiscoveryStatus
    /// Why the search is unavailable, as the system put it; nil otherwise.
    public var discoveryDetail: String?
    /// Network scanners the automatic search found (Windows); unused on the Mac.
    public var discoveredCount: Int
    public var manualHosts: [ManualHostStatus]
    public var lastFailure: ScannerFailure?

    public init(platform: TroubleshootPlatform = .windows, devices: [ScannerInfo] = [],
                network: NetworkStatus = .unknown, wiaService: ServiceStatus = .unknown,
                twain: TwainStatus = .unknown, twainDriverCount: Int = 0,
                thirtyTwoBitOnlyDrivers: [String] = [], thirtyTwoBitHelperProblem: String? = nil,
                discovery: DiscoveryStatus = .unknown,
                discoveryDetail: String? = nil, discoveredCount: Int = 0,
                manualHosts: [ManualHostStatus] = [], lastFailure: ScannerFailure? = nil) {
        self.platform = platform
        self.devices = devices
        self.network = network
        self.wiaService = wiaService
        self.twain = twain
        self.twainDriverCount = twainDriverCount
        self.thirtyTwoBitOnlyDrivers = thirtyTwoBitOnlyDrivers
        self.thirtyTwoBitHelperProblem = thirtyTwoBitHelperProblem
        self.discovery = discovery
        self.discoveryDetail = discoveryDetail
        self.discoveredCount = discoveredCount
        self.manualHosts = manualHosts
        self.lastFailure = lastFailure
    }

    /// The scanners listed other than the demo scanner.
    public var listedScannerCount: Int { devices.filter { !$0.isDemo }.count }
}

/// One line of the troubleshooter: what was checked, how it came out, what to do.
public struct TroubleshootCheck: Equatable, Sendable {
    /// Stable identifier ("network", "wiaService", "manualHost:192.168.1.50", ...).
    public let id: String
    public let status: CheckStatus
    /// One short line.
    public let title: String
    /// What it means and what to do, in full sentences.
    public let detail: String
    /// Buttons offered with it, in order.
    public let actions: [TroubleshootAction]

    public init(id: String, status: CheckStatus, title: String, detail: String, actions: [TroubleshootAction]) {
        self.id = id
        self.status = status
        self.title = title
        self.detail = detail
        self.actions = actions
    }
}

/// A connection that can tell the troubleshooter about itself. Optional, so `ScannerBackend`
/// does not change. Twin of C# `IScannerBackendDiagnostics` (`AddStatus`, `Rescan`).
@MainActor
public protocol ScannerBackendDiagnostics: AnyObject {
    /// The snapshot with what this connection knows filled in.
    func addStatus(to snapshot: DiscoverySnapshot) -> DiscoverySnapshot
    /// Look for scanners again now (the troubleshooter's Refresh). Never changes system settings.
    func rescan()
}

public enum Troubleshooter {

    /// The checks for `snapshot`: problems first, then warnings, then what is fine, then the tips
    /// that always apply; within each, in this order: the last failure, the network, the WIA
    /// service, TWAIN, 32-bit TWAIN drivers, the automatic search, the addresses added by hand,
    /// then the tips.
    public static func diagnose(_ snapshot: DiscoverySnapshot) -> [TroubleshootCheck] {
        let windows = snapshot.platform == .windows
        var checks: [TroubleshootCheck] = []

        if let failure = snapshot.lastFailure { checks.append(failureCheck(failure, platform: snapshot.platform)) }
        if let network = networkCheck(snapshot) { checks.append(network) }
        if windows, let wia = wiaServiceCheck(snapshot.wiaService) { checks.append(wia) }
        if windows, let twain = twainCheck(snapshot) { checks.append(twain) }
        if windows, !snapshot.thirtyTwoBitOnlyDrivers.isEmpty {
            checks.append(thirtyTwoBitCheck(snapshot.thirtyTwoBitOnlyDrivers, helperProblem: snapshot.thirtyTwoBitHelperProblem))
        }
        if let discovery = discoveryCheck(snapshot) { checks.append(discovery) }
        if windows {
            for host in snapshot.manualHosts where !host.listed {
                checks.append(TroubleshootCheck(
                    id: "manualHost:\(host.address)", status: .warning,
                    title: "No scanner answers at \(host.address)",
                    detail: joinSentences(host.problem, "Check that the scanner is on and that its address has not changed; its network settings page or control panel shows the current one. The app tries the address again every minute."),
                    actions: [.refresh]))
            }
        }
        checks.append(contentsOf: tips(snapshot.platform))

        // A stable sort: problems, warnings, what is fine, tips.
        return checks.enumerated()
            .sorted { lhs, rhs in
                let left = rank(lhs.element.status)
                let right = rank(rhs.element.status)
                return left != right ? left < right : lhs.offset < rhs.offset
            }
            .map { $0.element }
    }

    /// "No scanner found yet", "1 scanner found", "3 scanners found" (the demo scanner does not count).
    public static func headline(_ snapshot: DiscoverySnapshot) -> String {
        switch snapshot.listedScannerCount {
        case 0: return "No scanner found yet"
        case 1: return "1 scanner found"
        case let count: return "\(count) scanners found"
        }
    }

    /// "2 problems and 1 warning found.", or that nothing stops scanners from appearing.
    public static func summary(_ checks: [TroubleshootCheck]) -> String {
        let problems = checks.filter { $0.status == .problem }.count
        let warnings = checks.filter { $0.status == .warning }.count
        if problems == 0 && warnings == 0 {
            return "Nothing here stops scanners from appearing. The tips below cover the usual causes."
        }
        var parts: [String] = []
        if problems > 0 { parts.append(problems == 1 ? "1 problem" : "\(problems) problems") }
        if warnings > 0 { parts.append(warnings == 1 ? "1 warning" : "\(warnings) warnings") }
        return parts.joined(separator: " and ") + " found."
    }

    /// The button text for an action.
    public static func label(_ action: TroubleshootAction, platform: TroubleshootPlatform) -> String {
        switch action {
        case .refresh: return "Refresh"
        case .addByAddress: return "Add scanner by address\u{2026}"
        case .openScannerSettings:
            return platform == .windows ? "Open Windows scanner settings" : "Open Printers & Scanners"
        case .openNetworkSettings:
            return platform == .windows ? "Open network settings" : "Open Network settings"
        case .openImageCapture: return "Open Image Capture"
        case .copyDiagnostics: return "Copy diagnostics"
        }
    }

    /// The status as a word, for screen readers and the copied text: "OK", "Tip", "Warning", "Problem".
    public static func statusLabel(_ status: CheckStatus) -> String {
        switch status {
        case .ok: return "OK"
        case .tip: return "Tip"
        case .warning: return "Warning"
        case .problem: return "Problem"
        }
    }

    /// The checks as plain text, for the pasteboard and the device diagnostics file: the heading,
    /// the headline and summary, then one "Status: title" line per check with its detail
    /// indented below.
    public static func report(_ snapshot: DiscoverySnapshot, checks: [TroubleshootCheck]) -> String {
        var text = "Why isn't my scanner listed?\n"
        text += headline(snapshot) + ". " + summary(checks) + "\n"
        for check in checks {
            text += statusLabel(check.status) + ": " + check.title + "\n"
            text += "  " + check.detail + "\n"
        }
        return text
    }

    /// The network status of a computer connected to these networks: none is offline; a domain or
    /// private network among them is enough for network scanners to be found there.
    public static func combineNetworks(_ connected: [NetworkStatus]) -> NetworkStatus {
        let all = connected.filter { $0 != .unknown && $0 != .offline }
        if all.isEmpty { return connected.contains(.unknown) ? .unknown : .offline }
        if all.contains(.domainNetwork) { return .domainNetwork }
        if all.contains(.privateNetwork) { return .privateNetwork }
        return .publicNetwork
    }

    /// What a failed connection or scan tells the troubleshooter; nil for errors that say nothing
    /// about reaching the scanner (cancelled, saving, unsupported settings). Twin of C# `FailureFrom`.
    public static func failure(deviceName: String, error: Error) -> ScannerFailure? {
        if error is CancellationError { return nil }
        if let scanError = error as? ScanError {
            switch scanError {
            case .cancelled, .exportFailed, .unsupported:
                return nil
            case .deviceUnavailable, .sessionFailed, .scanFailed, .scannerProblem:
                return ScannerFailure(deviceName: deviceName,
                                      message: scanError.errorDescription ?? error.localizedDescription,
                                      problem: scanError.problem)
            }
        }
        return ScannerFailure(deviceName: deviceName, message: error.localizedDescription)
    }

    // MARK: - The checks

    private static func rank(_ status: CheckStatus) -> Int {
        switch status {
        case .problem: return 0
        case .warning: return 1
        case .ok: return 2
        case .tip: return 3
        }
    }

    private static func computer(_ platform: TroubleshootPlatform) -> String {
        platform == .windows ? "PC" : "Mac"
    }

    private static func otherApps(_ platform: TroubleshootPlatform) -> String {
        platform == .windows
            ? "Windows Scan or the scanner maker's app"
            : "Image Capture or the scanner maker's app"
    }

    private static func failureCheck(_ failure: ScannerFailure, platform: TroubleshootPlatform) -> TroubleshootCheck {
        let name = failure.deviceName
        if failure.problem == .busy {
            return TroubleshootCheck(
                id: "lastFailure", status: .problem, title: "\(name) is busy or in use by another app",
                detail: "A scanner works with one app at a time. Close other apps that may be using it, such as \(otherApps(platform)), wait until the scanner has finished, then choose it again.",
                actions: [.refresh])
        }
        if let problem = failure.problem {
            return TroubleshootCheck(
                id: "lastFailure", status: .problem, title: "\(name) reported a problem",
                detail: ScannerProblems.describe(problem), actions: [.refresh])
        }
        return TroubleshootCheck(
            id: "lastFailure", status: .warning, title: "Could not connect to \(name)",
            detail: joinSentences(failure.message, "Check that the scanner is on and awake, and connected by its cable or to the same network as this \(computer(platform))."),
            actions: [.refresh])
    }

    private static func networkCheck(_ snapshot: DiscoverySnapshot) -> TroubleshootCheck? {
        let windows = snapshot.platform == .windows
        switch snapshot.network {
        case .offline:
            return TroubleshootCheck(
                id: "network", status: .problem, title: "Not connected to a network",
                detail: "This \(computer(snapshot.platform)) is not on a network, so network scanners cannot be found. Connect to the network the scanner is on, then select Refresh. Scanners connected by USB are not affected.",
                actions: [.openNetworkSettings, .refresh])
        case .publicNetwork:
            let detail = "Windows does not look for devices on public networks, so network scanners may not be found. If this is your home or office network, set its network profile type to Private in Windows network settings."
            return TroubleshootCheck(
                id: "network", status: .warning, title: "The network is set to Public",
                detail: windows ? detail + " You can also add the scanner by its address." : detail,
                actions: windows ? [.openNetworkSettings, .addByAddress] : [.openNetworkSettings])
        case .privateNetwork, .domainNetwork:
            return TroubleshootCheck(
                id: "network", status: .ok, title: "Connected to a private network",
                detail: "Network scanners on this network can be found.", actions: [])
        case .unknown:
            return nil
        }
    }

    private static func wiaServiceCheck(_ status: ServiceStatus) -> TroubleshootCheck? {
        switch status {
        case .running:
            return TroubleshootCheck(
                id: "wiaService", status: .ok, title: "The Windows scanner service is running",
                detail: "Windows Image Acquisition (WIA), which most scanners use, is on.", actions: [])
        case .starting:
            return TroubleshootCheck(
                id: "wiaService", status: .warning, title: "The Windows scanner service is starting",
                detail: "Windows Image Acquisition (WIA), which most scanners use, is starting. Wait a moment, then select Refresh.",
                actions: [.refresh])
        case .stopped, .stopping, .paused:
            return TroubleshootCheck(
                id: "wiaService", status: .warning, title: "The Windows scanner service is not running",
                detail: "Windows Image Acquisition (WIA), which most scanners use, is not running, so those scanners cannot appear. Restarting the PC usually starts it again. To start it now, someone with administrator rights can start Windows Image Acquisition (WIA) in Services.",
                actions: [.refresh])
        case .disabled:
            return TroubleshootCheck(
                id: "wiaService", status: .problem, title: "The Windows scanner service is turned off",
                detail: "Windows Image Acquisition (WIA), which most scanners use, is disabled, so those scanners cannot appear. Someone with administrator rights can set its startup type to Automatic in Services, then restart the PC.",
                actions: [.refresh])
        case .notInstalled:
            return TroubleshootCheck(
                id: "wiaService", status: .problem, title: "The Windows scanner service is missing",
                detail: "This copy of Windows has no Windows Image Acquisition (WIA) service, which most scanners use. Scanners with a TWAIN driver and network scanners can still work.",
                actions: [.addByAddress])
        case .unknown:
            return nil
        }
    }

    private static func twainCheck(_ snapshot: DiscoverySnapshot) -> TroubleshootCheck? {
        switch snapshot.twain {
        case .available:
            let detail: String
            switch snapshot.twainDriverCount {
            case 0: detail = "No 64-bit TWAIN scanner driver is installed. Most scanners work without one."
            case 1: detail = "1 TWAIN scanner driver is installed."
            case let count: detail = "\(count) TWAIN scanner drivers are installed."
            }
            return TroubleshootCheck(id: "twain", status: .ok, title: "TWAIN is installed", detail: detail, actions: [])
        case .notInstalled:
            return TroubleshootCheck(
                id: "twain", status: snapshot.listedScannerCount == 0 ? .warning : .tip, title: "TWAIN is not installed",
                detail: "Some scanners, often document scanners, work only through their maker's TWAIN driver, which also installs TWAIN. If yours is one of them, install the maker's 64-bit TWAIN driver, then restart CompleteScanner.",
                actions: [])
        case .failed:
            return TroubleshootCheck(
                id: "twain", status: .warning, title: "TWAIN did not start",
                detail: "TWAIN is installed but would not open, so scanners that use a TWAIN driver are not listed. Restart CompleteScanner; if that does not help, reinstall the scanner maker's TWAIN driver.",
                actions: [.refresh])
        case .unknown:
            return nil
        }
    }

    /// Drivers the 32-bit helper does not reach, with why when the app knows (`helperProblem`).
    private static func thirtyTwoBitCheck(_ drivers: [String], helperProblem: String?) -> TroubleshootCheck {
        let names = drivers.map { path -> String in
            let name: String
            if let separator = path.lastIndex(where: { $0 == "/" || $0 == "\\" }) {
                name = String(path[path.index(after: separator)...])
            } else {
                name = path
            }
            return "\"\(name)\""
        }
        let one = names.count == 1
        let problem = (helperProblem ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let known = !problem.isEmpty
        var reach = names.joined(separator: ", ") + (one ? " is" : " are")
        reach += " installed only for 32-bit apps. CompleteScanner reaches such drivers through its 32-bit TWAIN helper"
        let pronoun = one ? "it" : "them"
        reach += known ? "." : ", which has not listed \(pronoun) yet."
        return TroubleshootCheck(
            id: "twain32", status: .problem,
            title: one ? "A TWAIN driver works only with 32-bit apps" : "\(names.count) TWAIN drivers work only with 32-bit apps",
            detail: joinSentences(known ? joinSentences(reach, problem) : reach,
                                  "A 64-bit (x64) driver from the maker, where there is one, works without the helper. Many scanners also work through Windows Image Acquisition (WIA) once the maker's full driver package is installed."),
            actions: [])
    }

    private static func discoveryCheck(_ snapshot: DiscoverySnapshot) -> TroubleshootCheck? {
        var reason = (snapshot.discoveryDetail ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        while reason.hasSuffix(".") { reason.removeLast() }
        let detail = reason.isEmpty ? "" : " (\(reason))"
        if snapshot.platform == .mac {
            switch snapshot.discovery {
            case .searching, .running:
                return TroubleshootCheck(
                    id: "discovery", status: .ok, title: "Looking for scanners",
                    detail: "macOS is looking for scanners connected by USB, on the network and shared by other Macs. They appear here as they are found.",
                    actions: [])
            case .off, .unavailable:
                return TroubleshootCheck(
                    id: "discovery", status: .warning, title: "Not looking for scanners",
                    detail: "The search for scanners is not running\(detail). Select Refresh to start it again.",
                    actions: [.refresh])
            case .unknown:
                return nil
            }
        }
        switch snapshot.discovery {
        case .searching:
            return TroubleshootCheck(
                id: "discovery", status: .ok, title: "Looking for network scanners",
                detail: "The search has just started. Scanners on the network appear as they answer.",
                actions: [.addByAddress])
        case .running:
            let found: String
            switch snapshot.discoveredCount {
            case 0: found = "No network scanner has been found on this network yet."
            case 1: found = "1 network scanner found."
            case let count: found = "\(count) network scanners found."
            }
            return TroubleshootCheck(
                id: "discovery", status: .ok, title: "Looking for network scanners",
                detail: found + " A scanner that does not appear can be added by its address.",
                actions: [.addByAddress])
        case .unavailable:
            return TroubleshootCheck(
                id: "discovery", status: .warning, title: "Automatic search for network scanners is not working",
                detail: "Windows could not search the network for scanners\(detail). You can still add a network scanner by its address.",
                actions: [.addByAddress, .refresh])
        case .off, .unknown:
            return nil
        }
    }

    private static func tips(_ platform: TroubleshootPlatform) -> [TroubleshootCheck] {
        var tips: [TroubleshootCheck] = []
        if platform == .windows {
            tips.append(TroubleshootCheck(
                id: "usb", status: .tip, title: "Scanner connected by USB?",
                detail: "Turn the scanner on and connect it straight to the PC, not through a hub. Windows lists a USB scanner only once its driver is installed: get the driver from the scanner maker's website, install it, then select Refresh. Windows scanner settings show whether Windows sees the scanner.",
                actions: [.openScannerSettings, .refresh]))
        } else {
            tips.append(TroubleshootCheck(
                id: "usb", status: .tip, title: "Scanner connected by USB?",
                detail: "Turn the scanner on and connect it straight to the Mac, not through a hub. macOS lists a USB scanner only when it can scan without a driver or its maker's macOS driver is installed: get it from the scanner maker's website. If Image Capture does not show the scanner either, macOS does not see it.",
                actions: [.openImageCapture, .refresh]))
            tips.append(TroubleshootCheck(
                id: "networkScanner", status: .tip, title: "Scanner on the network?",
                detail: "The Mac and the scanner must be on the same network. If macOS asked whether CompleteScanner may find devices on your local network, allow it in System Settings, Privacy & Security, Local Network. A network printer with a scanner added in Printers & Scanners also appears here.",
                actions: [.openScannerSettings]))
            tips.append(TroubleshootCheck(
                id: "sharing", status: .tip, title: "Scanner shared by another Mac?",
                detail: "It appears when Scanner Sharing is on in that Mac's System Settings, General, Sharing, and both Macs are on the same network.",
                actions: []))
        }
        tips.append(TroubleshootCheck(
            id: "otherApps", status: .tip, title: "Still not listed?",
            detail: "Wake the scanner (press a button on it), and close other apps that may be using it, such as \(otherApps(platform)). Some scanners work only with their maker's own app; the maker's website says whether yours does.",
            actions: [.refresh]))
        return tips
    }

    /// The first text as a sentence, then the second; the first may be missing.
    private static func joinSentences(_ first: String?, _ second: String) -> String {
        var head = (first ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if head.isEmpty { return second }
        if let last = head.last, !".!?".contains(last) { head += "." }
        return head + " " + second
    }
}
