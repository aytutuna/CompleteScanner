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
    /// The iPhone and iPad app (never produced on Windows).
    case ios
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
    /// The user turned off the app's access to the local network (iPhone and iPad: Local Network
    /// privacy). Windows never produces it.
    case denied
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
    /// The app's own page in the Settings app (iPhone and iPad), where Local Network access is turned on.
    case openAppSettings
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
    /// Six words at most.
    public let title: String
    /// What it means or what to do, in one line of fifteen words at most.
    public let detail: String
    /// The rest of the explanation, behind "More help"; empty when the detail says it all.
    public let more: String
    /// Buttons offered with it, in order.
    public let actions: [TroubleshootAction]

    public init(id: String, status: CheckStatus, title: String, detail: String, more: String = "",
                actions: [TroubleshootAction]) {
        self.id = id
        self.status = status
        self.title = title
        self.detail = detail
        self.more = more
        self.actions = actions
    }

    /// The detail and the more help as one text, for VoiceOver and the copied diagnostics.
    public var fullDetail: String {
        more.isEmpty ? detail : detail + " " + more
    }
}

/// A connection that can tell the troubleshooter about itself. Optional, so `ScannerBackend`
/// does not change. Twin of C# `IScannerBackendDiagnostics` (`AddStatus`, `Rescan`), with the C#
/// `IBackendDiagnostics.DiagnosticsReport` (devices.txt) as `diagnosticsReport`.
@MainActor
public protocol ScannerBackendDiagnostics: AnyObject {
    /// The snapshot with what this connection knows filled in.
    func addStatus(to snapshot: DiscoverySnapshot) -> DiscoverySnapshot
    /// Look for scanners again now (the troubleshooter's Refresh). Never changes system settings.
    func rescan()
    /// What this connection found, as lines for devices.txt and Copy diagnostics; nil when it has
    /// nothing to add (the default).
    var diagnosticsReport: String? { get }
}

extension ScannerBackendDiagnostics {
    public var diagnosticsReport: String? { nil }
}

public enum Troubleshooter {

    /// The checks for `snapshot`: problems first, then warnings, then what is fine, then the tips
    /// that always apply; within each, in this order: the last failure, the network, the WIA
    /// service, TWAIN, 32-bit TWAIN drivers, the automatic search (or the local network access it
    /// was refused), the addresses added by hand, then the tips. The iPhone and iPad get their own
    /// wording and tips, never the Windows or Mac checks.
    public static func diagnose(_ snapshot: DiscoverySnapshot) -> [TroubleshootCheck] {
        let windows = snapshot.platform == .windows
        // The phone adds network scanners by address too (Mac: ImageCaptureCore finds them).
        let addsByAddress: Bool = windows || snapshot.platform == .ios
        var checks: [TroubleshootCheck] = []

        if let failure = snapshot.lastFailure { checks.append(failureCheck(failure, platform: snapshot.platform)) }
        if let network = networkCheck(snapshot) { checks.append(network) }
        if windows, let wia = wiaServiceCheck(snapshot.wiaService) { checks.append(wia) }
        if windows, let twain = twainCheck(snapshot) { checks.append(twain) }
        if windows, !snapshot.thirtyTwoBitOnlyDrivers.isEmpty {
            checks.append(thirtyTwoBitCheck(snapshot.thirtyTwoBitOnlyDrivers, helperProblem: snapshot.thirtyTwoBitHelperProblem))
        }
        if let discovery = discoveryCheck(snapshot) { checks.append(discovery) }
        if addsByAddress {
            for host in snapshot.manualHosts where !host.listed {
                checks.append(TroubleshootCheck(
                    id: "manualHost:\(host.address)", status: .warning,
                    title: "No scanner answers at \(host.address)",
                    detail: "Check that it is on and its address hasn't changed.",
                    more: joinSentences(host.problem, "Its network settings page or control panel shows the current address. The app tries the address again every minute."),
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

    /// "No scanner found", "1 scanner found", "3 scanners found" (the demo scanner does not count).
    public static func headline(_ snapshot: DiscoverySnapshot) -> String {
        switch snapshot.listedScannerCount {
        case 0: return "No scanner found"
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

    /// The troubleshooter's one-line headline: what is listed, then how many problems and warnings
    /// there are ("No scanner found · 2 problems, 1 warning"); just what is listed when there are none.
    public static func overview(_ snapshot: DiscoverySnapshot, checks: [TroubleshootCheck]) -> String {
        let problems: Int = checks.filter { $0.status == .problem }.count
        let warnings: Int = checks.filter { $0.status == .warning }.count
        var parts: [String] = []
        if problems > 0 { parts.append(problems == 1 ? "1 problem" : "\(problems) problems") }
        if warnings > 0 { parts.append(warnings == 1 ? "1 warning" : "\(warnings) warnings") }
        let line: String = headline(snapshot)
        return parts.isEmpty ? line : line + " \u{00B7} " + parts.joined(separator: ", ")
    }

    /// The button text for an action.
    public static func label(_ action: TroubleshootAction, platform: TroubleshootPlatform) -> String {
        switch action {
        case .refresh: return "Refresh"
        case .addByAddress: return "Add by address\u{2026}"
        case .openScannerSettings:
            return platform == .windows ? "Scanner settings" : "Printers & Scanners"
        case .openNetworkSettings: return "Network settings"
        case .openImageCapture: return "Image Capture"
        case .copyDiagnostics: return "Copy diagnostics"
        case .openAppSettings: return "Open Settings"
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
    /// indented below, and its more help (when it has some) on the line after.
    public static func report(_ snapshot: DiscoverySnapshot, checks: [TroubleshootCheck]) -> String {
        var text = "Why isn't my scanner listed?\n"
        text += headline(snapshot) + ". " + summary(checks) + "\n"
        for check in checks {
            text += statusLabel(check.status) + ": " + check.title + "\n"
            text += "  " + check.detail + "\n"
            if !check.more.isEmpty { text += "  " + check.more + "\n" }
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
        switch platform {
        case .windows: return "PC"
        case .ios: return "device"
        case .mac: return "Mac"
        }
    }

    private static func otherApps(_ platform: TroubleshootPlatform) -> String {
        switch platform {
        case .windows: return "Windows Scan or the maker's app"
        case .ios: return "another device or app"
        case .mac: return "Image Capture or the maker's app"
        }
    }

    /// The system that searches the network, in the discovery check's more help.
    private static func searchingSystem(_ platform: TroubleshootPlatform) -> String {
        platform == .ios ? "iOS" : "Windows"
    }

    private static func failureCheck(_ failure: ScannerFailure, platform: TroubleshootPlatform) -> TroubleshootCheck {
        let name = failure.deviceName
        if failure.problem == .busy {
            return TroubleshootCheck(
                id: "lastFailure", status: .problem, title: "\(name) is busy",
                detail: "Close other apps using it, then choose it again.",
                more: "A scanner works with one app at a time; \(otherApps(platform)) may be using it. Wait until the scanner has finished, then choose it again.",
                actions: [.refresh])
        }
        if let problem = failure.problem {
            return TroubleshootCheck(
                id: "lastFailure", status: .problem, title: "\(ScannerProblems.title(problem)): \(name)",
                detail: ScannerProblems.advice(problem), actions: [.refresh])
        }
        return TroubleshootCheck(
            id: "lastFailure", status: .warning, title: "Could not connect to \(name)",
            detail: "Check that it is on, awake and connected.",
            more: joinSentences(failure.message, platform == .ios
                                    ? "It must be on the same network as this \(computer(platform))."
                                    : "It must be connected by its cable or to the same network as this \(computer(platform))."),
            actions: [.refresh])
    }

    private static func networkCheck(_ snapshot: DiscoverySnapshot) -> TroubleshootCheck? {
        if snapshot.platform == .ios { return phoneNetworkCheck(snapshot.network) }
        let windows = snapshot.platform == .windows
        switch snapshot.network {
        case .offline:
            return TroubleshootCheck(
                id: "network", status: .problem, title: "Not connected to a network",
                detail: "Connect to the network the scanner is on, then select Refresh.",
                more: "This \(computer(snapshot.platform)) is not on a network, so network scanners can't be found. Scanners connected by USB are not affected.",
                actions: [.openNetworkSettings, .refresh])
        case .publicNetwork:
            let more = "If this is your home or office network, set it to Private in network settings."
            return TroubleshootCheck(
                id: "network", status: .warning, title: "Network set to Public",
                detail: "Windows won't find network scanners on a Public network.",
                more: windows ? more + " You can also add the scanner by its address." : more,
                actions: windows ? [.openNetworkSettings, .addByAddress] : [.openNetworkSettings])
        case .privateNetwork, .domainNetwork:
            return TroubleshootCheck(
                id: "network", status: .ok, title: "Connected to a private network",
                detail: "Network scanners on this network can be found.", actions: [])
        case .unknown:
            return nil
        }
    }

    /// The iPhone's and iPad's network: Wi-Fi or a wired network, or none (cellular only counts as
    /// none, since scanners are not found there). iOS has no public or private networks.
    private static func phoneNetworkCheck(_ network: NetworkStatus) -> TroubleshootCheck? {
        switch network {
        case .offline:
            return TroubleshootCheck(
                id: "network", status: .problem, title: "Not connected to Wi-Fi",
                detail: "Join the scanner's Wi-Fi network, then tap Refresh.",
                more: "Network scanners are found only on Wi-Fi or a wired network. The camera works without one.",
                actions: [.refresh])
        case .publicNetwork, .privateNetwork, .domainNetwork:
            return TroubleshootCheck(
                id: "network", status: .ok, title: "Connected to a local network",
                detail: "Network scanners on this network can be found.", actions: [])
        case .unknown:
            return nil
        }
    }

    /// The app may not use the local network (iPhone and iPad: Local Network privacy turned off for
    /// it), so it can neither find scanners nor reach the addresses added by hand. The same check on
    /// every platform, though only the iPhone and iPad report it.
    private static func localNetworkDeniedCheck() -> TroubleshootCheck {
        TroubleshootCheck(
            id: "localNetwork", status: .problem, title: "Local Network access is off",
            detail: "Turn on Local Network for CompleteScanner in Settings.",
            more: "Without it, the app can't find or reach scanners on your network. Scanners appear as soon as it's on. "
                + "If it's on already, turn it off and on again.",
            actions: [.openAppSettings])
    }

    private static func wiaServiceCheck(_ status: ServiceStatus) -> TroubleshootCheck? {
        switch status {
        case .running:
            return TroubleshootCheck(
                id: "wiaService", status: .ok, title: "Scanner service is on",
                detail: "Windows Image Acquisition (WIA), which most scanners use, is on.", actions: [])
        case .starting:
            return TroubleshootCheck(
                id: "wiaService", status: .warning, title: "Scanner service is starting",
                detail: "Wait a moment, then select Refresh.",
                more: "Windows Image Acquisition (WIA), which most scanners use, is starting.",
                actions: [.refresh])
        case .stopped, .stopping, .paused:
            return TroubleshootCheck(
                id: "wiaService", status: .warning, title: "Scanner service is not running",
                detail: "Restarting the PC usually starts it again.",
                more: "Windows Image Acquisition (WIA), which most scanners use, is not running, so those scanners can't appear. To start it now, someone with administrator rights can start Windows Image Acquisition (WIA) in Services.",
                actions: [.refresh])
        case .disabled:
            return TroubleshootCheck(
                id: "wiaService", status: .problem, title: "Scanner service is turned off",
                detail: "An administrator can set it to Automatic in Services.",
                more: "Windows Image Acquisition (WIA), which most scanners use, is disabled, so those scanners can't appear. Someone with administrator rights can set its startup type to Automatic in Services, then restart the PC.",
                actions: [.refresh])
        case .notInstalled:
            return TroubleshootCheck(
                id: "wiaService", status: .problem, title: "Scanner service is missing",
                detail: "Scanners with a TWAIN driver and network scanners can still work.",
                more: "This copy of Windows has no Windows Image Acquisition (WIA) service, which most scanners use.",
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
                detail: "Some scanners need their maker's 64-bit TWAIN driver.",
                more: "Some scanners, often document scanners, work only through their maker's TWAIN driver, which also installs TWAIN. If yours is one of them, install the maker's 64-bit TWAIN driver, then restart CompleteScanner.",
                actions: [])
        case .failed:
            return TroubleshootCheck(
                id: "twain", status: .warning, title: "TWAIN did not start",
                detail: "Restart CompleteScanner; if that fails, reinstall the maker's TWAIN driver.",
                more: "TWAIN is installed but would not open, so scanners that use a TWAIN driver are not listed.",
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
        let pronoun = one ? "it" : "them"
        var reach = "CompleteScanner reaches such drivers through its 32-bit TWAIN helper"
        reach += known ? "." : ", which has not listed \(pronoun) yet."
        let installed: String = names.joined(separator: ", ") + (one ? " is" : " are") + " installed only for 32-bit apps."
        return TroubleshootCheck(
            id: "twain32", status: .problem,
            title: one ? "A TWAIN driver is 32-bit only" : "\(names.count) TWAIN drivers are 32-bit only",
            detail: installed,
            more: joinSentences(known ? joinSentences(reach, problem) : reach,
                                "A 64-bit (x64) driver from the maker, where there is one, works without the helper. Many scanners also work through Windows Image Acquisition (WIA) once the maker's full driver package is installed."),
            actions: [])
    }

    private static func discoveryCheck(_ snapshot: DiscoverySnapshot) -> TroubleshootCheck? {
        if snapshot.discovery == .denied { return localNetworkDeniedCheck() }
        var reason = (snapshot.discoveryDetail ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        while reason.hasSuffix(".") { reason.removeLast() }
        let detail = reason.isEmpty ? "" : " (\(reason))"
        if snapshot.platform == .mac {
            switch snapshot.discovery {
            case .searching, .running:
                return TroubleshootCheck(
                    id: "discovery", status: .ok, title: "Looking for scanners",
                    detail: "Scanners appear here as macOS finds them.",
                    more: "macOS looks for scanners connected by USB, on the network and shared by other Macs.",
                    actions: [])
            case .off, .unavailable:
                return TroubleshootCheck(
                    id: "discovery", status: .warning, title: "Not looking for scanners",
                    detail: "Select Refresh to start the search again.",
                    more: "The search for scanners is not running\(detail).",
                    actions: [.refresh])
            case .unknown, .denied:
                return nil
            }
        }
        switch snapshot.discovery {
        case .searching:
            return TroubleshootCheck(
                id: "discovery", status: .ok, title: "Looking for network scanners",
                detail: "Scanners on the network appear as they answer.",
                more: "The search has just started.",
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
                detail: found,
                more: "A scanner that doesn't appear can be added by its address.",
                actions: [.addByAddress])
        case .unavailable:
            return TroubleshootCheck(
                id: "discovery", status: .warning, title: "Network search is not working",
                detail: "You can still add a network scanner by its address.",
                more: "\(searchingSystem(snapshot.platform)) could not search the network for scanners\(detail).",
                actions: [.addByAddress, .refresh])
        case .off, .unknown, .denied:
            return nil
        }
    }

    private static func tips(_ platform: TroubleshootPlatform) -> [TroubleshootCheck] {
        if platform == .ios {
            return phoneTips()
        }
        var tips: [TroubleshootCheck] = []
        if platform == .windows {
            tips.append(TroubleshootCheck(
                id: "usb", status: .tip, title: "Connected by USB?",
                detail: "Connect it directly (no hub) and install the maker's driver.",
                more: "Windows lists a USB scanner only after its driver is installed. Get it from the maker's website, then select Refresh. Scanner settings show whether Windows sees it.",
                actions: [.openScannerSettings, .refresh]))
        } else {
            tips.append(TroubleshootCheck(
                id: "usb", status: .tip, title: "Connected by USB?",
                detail: "Connect it directly (no hub) and install the maker's macOS driver.",
                more: "macOS lists a USB scanner only when it can scan without a driver or its maker's driver is installed. If Image Capture doesn't show it either, macOS doesn't see it.",
                actions: [.openImageCapture, .refresh]))
            tips.append(TroubleshootCheck(
                id: "networkScanner", status: .tip, title: "Scanner on the network?",
                detail: "The Mac and the scanner must be on the same network.",
                more: "If macOS asked whether CompleteScanner may find devices on your local network, allow it in System Settings, Privacy & Security, Local Network. A network printer with a scanner added in Printers & Scanners also appears here.",
                actions: [.openScannerSettings]))
            tips.append(TroubleshootCheck(
                id: "sharing", status: .tip, title: "Shared by another Mac?",
                detail: "Turn on Scanner Sharing in that Mac's Sharing settings.",
                more: "It's in System Settings, General, Sharing. Both Macs must be on the same network.",
                actions: []))
        }
        tips.append(TroubleshootCheck(
            id: "otherApps", status: .tip, title: "Still not listed?",
            detail: "Wake the scanner and close other scanning apps.",
            more: "Press a button on the scanner. Close \(otherApps(platform)). Some scanners work only with their maker's app.",
            actions: [.refresh]))
        return tips
    }

    /// The iPhone's and iPad's tips: network scanners only (they can't use USB scanners), with the
    /// address as the way round a network that hides them.
    private static func phoneTips() -> [TroubleshootCheck] {
        var tips: [TroubleshootCheck] = []
        tips.append(TroubleshootCheck(
            id: "networkScanner", status: .tip, title: "Scanner on the network?",
            detail: "This device and the scanner must be on the same Wi-Fi.",
            more: "Guest networks and some VPNs hide scanners. Try adding the scanner by its address.",
            actions: [.addByAddress]))
        tips.append(TroubleshootCheck(
            id: "usb", status: .tip, title: "Connected by USB?",
            detail: "Use its Wi-Fi connection; iPhone and iPad can't use USB scanners.",
            more: "Most scanners that print or copy also join Wi-Fi. The scanner's manual shows how.",
            actions: []))
        tips.append(TroubleshootCheck(
            id: "otherApps", status: .tip, title: "Still not listed?",
            detail: "Wake the scanner and close other scanning apps.",
            more: "Press a button on the scanner. Close scanning apps on other devices. Some scanners work only with "
                + "Windows (WSD) or their maker's app.",
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
