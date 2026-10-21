import Foundation

// The Apple side of windows/CompleteScanner.App/Scanning/EsclDiscovery.cs: finds network scanners that
// announce eSCL over DNS-SD (_uscan._tcp, and _uscans._tcp for HTTPS) and hands them over as the same
// `EsclService` values Windows produces, so `EsclEndpoint.choose` groups and orders them the same way. The
// browsing and the resolving are behind two protocols: the app's are NWBrowser and the dnssd resolver
// (EsclNetworkServices.swift); tests pass stand-ins, so no test ever browses the network. Nothing is
// advertised: the app only looks.

/// One service instance a browser reports: its name, type and domain, the interface it was seen on and its
/// TXT record ("key=value" entries).
public struct EsclBrowseResult: Hashable, Sendable {
    /// The service instance name, e.g. "HP Color LaserJet MFP M479fdw (A1B2C3)".
    public var name: String
    /// "_uscan._tcp" or "_uscans._tcp".
    public var type: String
    /// Usually "local.".
    public var domain: String
    /// The interface it was seen on; 0 when any.
    public var interfaceIndex: Int
    /// TXT record entries ("key=value"), in key order.
    public var txt: [String]

    public init(name: String, type: String, domain: String, interfaceIndex: Int = 0, txt: [String]) {
        self.name = name
        self.type = type
        self.domain = domain
        self.interfaceIndex = interfaceIndex
        self.txt = txt
    }

    /// An _uscans service (eSCL over HTTPS).
    public var secure: Bool {
        type.lowercased().hasPrefix("_uscans.")
    }

    /// Names the instance across reports: name, type and domain, ignoring case.
    public var key: String {
        (name + "." + type + "." + domain).lowercased()
    }
}

/// How a browser is doing, as the system reports it. `code` is the DNS-SD error code when there is one
/// (`kDNSServiceErr_PolicyDenied`, -65570, when Local Network access is off).
public enum EsclBrowserStatus: Equatable, Sendable {
    case setup
    case ready
    case waiting(code: Int32?, detail: String)
    case failed(code: Int32?, detail: String)
    case cancelled
}

/// Where a service is: its host name, port and every address, as text ("192.168.1.20", "fe80::1%4").
public struct EsclResolvedService: Equatable, Sendable {
    public var hostName: String?
    public var port: Int
    public var addresses: [String]

    public init(hostName: String?, port: Int, addresses: [String]) {
        self.hostName = hostName
        self.port = port
        self.addresses = addresses
    }
}

/// What resolving a service came to.
public enum EsclResolveOutcome: Equatable, Sendable {
    case resolved(EsclResolvedService)
    /// Not resolved; the text says why, for the diagnostics.
    case failed(String)
    /// The system refused: Local Network access is off.
    case denied
}

/// How the system says that the app may not use the local network (Local Network privacy on iPhone and
/// iPad; the simulator never enforces it).
public enum EsclLocalNetwork {
    /// kDNSServiceErr_PolicyDenied: the system refused to browse or resolve (Local Network access is off).
    public static let policyDeniedCode: Int32 = -65570

    /// A browser or resolve that failed or waits with `code` was refused for Local Network access.
    public static func isPolicyDenied(_ code: Int32?) -> Bool {
        code == policyDeniedCode
    }
}

/// Something under way that can be stopped (a resolve).
@MainActor
public protocol EsclCancellable: AnyObject {
    func cancel()
}

/// Browses one service type and reports the instances found (each time, all of them) and how browsing
/// goes, on the main actor. The app's is `EsclNWBrowser` (NWBrowser); tests pass a stand-in.
@MainActor
public protocol EsclServiceBrowsing: AnyObject {
    /// Browses _uscans._tcp when true, _uscan._tcp otherwise.
    var secure: Bool { get }
    var onStatus: ((EsclBrowserStatus) -> Void)? { get set }
    var onResults: (([EsclBrowseResult]) -> Void)? { get set }
    func start()
    func cancel()
}

/// Finds a service's host name, port and every address. Calls `completion` once, on the main actor, unless
/// cancelled first. The app's is `EsclDnssdResolver` (DNSServiceResolve and DNSServiceGetAddrInfo); tests
/// pass a stand-in.
@MainActor
public protocol EsclServiceResolving: AnyObject {
    func resolve(_ result: EsclBrowseResult,
                 completion: @escaping @MainActor (EsclResolveOutcome) -> Void) -> any EsclCancellable
}

/// Finds eSCL scanners with one browser per service type and resolves each instance found. Services come
/// and go as the browsers report them; a service is listed once it is resolved. Local Network access that
/// is off is inferred from what the system says (a browser waiting with `EsclLocalNetwork.policyDeniedCode`, a resolve
/// refused, or `reportDenied()` from a connection whose path says `.localNetworkDenied`): `status` is then
/// `.denied`, until a browser is ready again (the system retries by itself once access is granted).
/// Browsing pauses while the app is in the background (`pause`, `resume`): what was found stays listed,
/// and what the new browsers do not report again within `carryTime` of resuming is dropped then.
@MainActor
public final class EsclDiscovery {
    /// Makes the browser of one service type (true: _uscans._tcp).
    public typealias BrowserFactory = @MainActor (Bool) -> any EsclServiceBrowsing
    /// Runs the action after the delay, on the main actor (tests run it by hand).
    public typealias Scheduler = @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void

    /// The two service types, secure first as on Windows.
    public static let serviceTypes: [String] = ["_uscans._tcp", "_uscan._tcp"]

    /// The services changed, or how the search goes.
    public var onChange: (() -> Void)?
    /// How long after `start` or `resume` the search is still taken as looking (`isLooking`) although the browsers are
    /// ready: a browser is ready at once, the services it finds come after, and each takes up to the
    /// resolver's timeout (5 s) to resolve.
    public var firstSearchTime: TimeInterval = 5

    private let makeBrowser: BrowserFactory
    private let resolver: any EsclServiceResolving
    private let schedule: Scheduler
    private let carryTime: TimeInterval
    private var browses: [Browse] = []
    private var found: [Found] = []
    private var paused: Bool = false
    /// Bumped by every start, stop and resume, so a carry timer of an earlier one does nothing.
    private var generation: Int = 0
    /// A resolve or a connection reported the Local Network access off.
    private var deniedElsewhere: Bool = false
    /// Numbers the resolves started, so a late answer of an earlier one is told apart.
    private var resolveCount: Int = 0
    /// The search started or resumed less than `firstSearchTime` ago; cleared by a pause or a stop.
    private var firstSearch: Bool = false

    /// One browser, for one service type.
    @MainActor
    private final class Browse {
        let browser: any EsclServiceBrowsing
        let secure: Bool
        var ready: Bool = false
        var denied: Bool = false
        var failure: String?

        init(browser: any EsclServiceBrowsing) {
            self.browser = browser
            self.secure = browser.secure
        }
    }

    /// A service instance as reported, and what resolving it came to.
    @MainActor
    private final class Found {
        var result: EsclBrowseResult
        var resolved: EsclResolvedService?
        var problem: String?
        /// The resolve under way, to stop it; nil when none is (or it answered at once).
        var resolving: (any EsclCancellable)?
        /// A resolve is under way (set before it starts, since a resolver may answer at once).
        var isResolving: Bool = false
        /// Kept from before a pause; not reported again yet.
        var carried: Bool = false
        /// The number of the resolve started last (`resolveCount`), so a late answer of an earlier one is dropped.
        var attempt: Int = 0

        init(result: EsclBrowseResult) {
            self.result = result
        }
    }

    /// - Parameters:
    ///   - makeBrowser: the browser of each service type.
    ///   - resolver: resolves the instances found.
    ///   - carryTime: how long what was found before a pause stays listed after resuming without being
    ///     reported again.
    ///   - schedule: runs the carry timer; nil = real time.
    public init(makeBrowser: @escaping BrowserFactory, resolver: any EsclServiceResolving, carryTime: TimeInterval = 5,
                schedule: Scheduler? = nil) {
        self.makeBrowser = makeBrowser
        self.resolver = resolver
        self.carryTime = carryTime
        if let schedule {
            self.schedule = schedule
        } else {
            self.schedule = { (delay: TimeInterval, action: @escaping @MainActor () -> Void) -> Void in
                let nanoseconds: UInt64 = UInt64(max(0, delay) * 1_000_000_000)
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: nanoseconds)
                    action()
                }
            }
        }
    }

    // MARK: State

    /// The services resolved so far, in the order they were first reported.
    public var services: [EsclService] {
        var list: [EsclService] = []
        for entry in found {
            guard let resolved = entry.resolved else { continue }
            list.append(EsclService(id: entry.result.key, instanceName: entry.result.name, secure: entry.result.secure,
                                    hostName: resolved.hostName, addresses: resolved.addresses, port: resolved.port,
                                    textAttributes: entry.result.txt))
        }
        return list
    }

    /// Browsing at all (started and not paused or stopped).
    public var isBrowsing: Bool {
        !browses.isEmpty
    }

    /// How the search goes, for the troubleshooter: off (not started, paused, stopped), denied, unavailable
    /// (a browser failed: `failure` says why), running (every browser is ready) or searching.
    public var status: DiscoveryStatus {
        if deniedElsewhere {
            return .denied
        }
        if browses.isEmpty {
            return .off
        }
        for browse in browses where browse.denied {
            return .denied
        }
        for browse in browses where browse.failure != nil {
            return .unavailable
        }
        for browse in browses where !browse.ready {
            return .searching
        }
        return .running
    }

    /// The search may still find scanners soon: it runs (searching or running, not refused nor failed) and
    /// it started or resumed less than `firstSearchTime` ago, or a service it found is being resolved. A screen says
    /// "Looking for scanners…" then rather than that none was found. Never true for long: a browser
    /// waiting for a network that is not there is not looking once the first search time is over.
    public var isLooking: Bool {
        let current: DiscoveryStatus = status
        guard current == .searching || current == .running else { return false }
        if firstSearch {
            return true
        }
        for entry in found where entry.isResolving {
            return true
        }
        return false
    }

    /// Why browsing is unavailable, as the system put it; nil otherwise.
    public var failure: String? {
        for browse in browses {
            if let failure = browse.failure {
                return failure
            }
        }
        return nil
    }

    /// One line on how browsing goes, for the device diagnostics.
    public var statusLine: String {
        switch status {
        case .off:
            return paused ? "paused (the app is in the background)" : "off"
        case .denied:
            return "Local Network access is off"
        case .unavailable:
            return "unavailable (\(failure ?? "unknown error"))"
        case .searching, .running, .unknown:
            let pass: String = status == .running ? "ready" : "starting"
            return "browsing, \(pass), \(services.count) service(s)"
        }
    }

    /// Every instance reported, resolved or not, for the diagnostics: "_uscan \"name\" problem".
    public var unresolvedLines: [String] {
        var lines: [String] = []
        for entry in found where entry.resolved == nil {
            let kind: String = entry.result.secure ? "_uscans" : "_uscan"
            let why: String = entry.problem ?? "resolving"
            lines.append("\(kind) \"\(entry.result.name)\" not resolved (\(why))")
        }
        return lines
    }

    // MARK: Starting and stopping

    /// Starts a browser for each service type; does nothing while browsing.
    public func start() {
        guard browses.isEmpty else { return }
        paused = false
        generation += 1
        deniedElsewhere = false
        firstSearch = true
        startMissing()
        let current: Int = generation
        schedule(firstSearchTime) { [weak self] in
            self?.endFirstSearch(current)
        }
        changed()
    }

    /// Stops browsing and forgets what was found.
    public func stop() {
        generation += 1
        paused = false
        firstSearch = false
        cancelBrowsers()
        for entry in found {
            cancelResolve(entry)
        }
        found = []
        deniedElsewhere = false
        changed()
    }

    /// The app goes to the background: browsing stops, what was found stays listed. Resolves under way stop
    /// too; their instances are resolved again once reported after `resume`.
    public func pause() {
        guard !browses.isEmpty else { return }
        generation += 1
        paused = true
        firstSearch = false
        cancelBrowsers()
        for entry in found {
            cancelResolve(entry)
            entry.carried = true
        }
        changed()
    }

    /// The app is in front again: browsing starts again, and is looking (`isLooking`) for `firstSearchTime`
    /// as after `start`. What the new browsers have not reported again within `carryTime` is dropped then.
    public func resume() {
        guard paused, browses.isEmpty else { return }
        paused = false
        generation += 1
        deniedElsewhere = false
        firstSearch = true
        startMissing()
        let current: Int = generation
        schedule(firstSearchTime) { [weak self] in
            self?.endFirstSearch(current)
        }
        schedule(carryTime) { [weak self] in
            self?.dropCarried(current)
        }
        changed()
    }

    /// The troubleshooter's Refresh: starts again a browser that failed, and resolves again the instances
    /// that could not be resolved. A browser that works, or waits for Local Network access (the system
    /// retries by itself), is left alone.
    public func restart() {
        guard !browses.isEmpty else { return }
        var kept: [Browse] = []
        for browse in browses {
            if browse.failure != nil {
                browse.browser.onStatus = nil
                browse.browser.onResults = nil
                browse.browser.cancel()
            } else {
                kept.append(browse)
            }
        }
        browses = kept
        deniedElsewhere = false
        startMissing()
        for entry in found where entry.resolved == nil && !entry.isResolving {
            startResolve(entry)
        }
        changed()
    }

    /// A connection to the local network was refused for Local Network access (its path's unsatisfied
    /// reason is `.localNetworkDenied`): the search is reported as denied until a browser is ready again.
    public func reportDenied() {
        guard !deniedElsewhere else { return }
        deniedElsewhere = true
        changed()
    }

    /// Creates and starts a browser for each service type that has none.
    private func startMissing() {
        var started: [Browse] = []
        for type in EsclDiscovery.serviceTypes {
            let secure: Bool = type == "_uscans._tcp"
            var has: Bool = false
            for browse in browses where browse.secure == secure {
                has = true
            }
            if has {
                continue
            }
            let browse: Browse = Browse(browser: makeBrowser(secure))
            browse.browser.onStatus = { [weak self, weak browse] (status: EsclBrowserStatus) -> Void in
                guard let self, let browse else { return }
                self.browserStatus(browse, status)
            }
            browse.browser.onResults = { [weak self, weak browse] (results: [EsclBrowseResult]) -> Void in
                guard let self, let browse else { return }
                self.browserResults(browse, results)
            }
            browses.append(browse)
            started.append(browse)
        }
        for browse in started {
            browse.browser.start()
        }
    }

    private func cancelBrowsers() {
        let stopping: [Browse] = browses
        browses = []
        for browse in stopping {
            browse.browser.onStatus = nil
            browse.browser.onResults = nil
            browse.browser.cancel()
        }
    }

    // MARK: What the browsers and the resolver report

    private func isCurrent(_ browse: Browse) -> Bool {
        for current in browses where current === browse {
            return true
        }
        return false
    }

    private func browserStatus(_ browse: Browse, _ status: EsclBrowserStatus) {
        guard isCurrent(browse) else { return }
        switch status {
        case .setup, .cancelled:
            return
        case .ready:
            browse.ready = true
            browse.denied = false
            browse.failure = nil
            // Access granted again (or never refused): what a resolve said about it is over.
            deniedElsewhere = false
        case .waiting(let code, _):
            browse.ready = false
            browse.denied = EsclLocalNetwork.isPolicyDenied(code)
        case .failed(let code, let detail):
            browse.ready = false
            browse.denied = EsclLocalNetwork.isPolicyDenied(code)
            browse.failure = browse.denied ? nil : detail
        }
        changed()
    }

    /// A browser's full list: new instances are resolved, a changed TXT record is taken as it is, and the
    /// instances of its type it no longer reports are gone (except those kept from before a pause, until
    /// their time is up).
    private func browserResults(_ browse: Browse, _ results: [EsclBrowseResult]) {
        guard isCurrent(browse) else { return }
        var reported: Set<String> = []
        for result in results where result.secure == browse.secure {
            reported.insert(result.key)
            if let entry = foundEntry(result.key) {
                entry.carried = false
                entry.result = result
                if entry.resolved == nil && !entry.isResolving {
                    startResolve(entry)
                }
            } else {
                let entry: Found = Found(result: result)
                found.append(entry)
                startResolve(entry)
            }
        }
        var kept: [Found] = []
        for entry in found {
            let gone: Bool = entry.result.secure == browse.secure && !entry.carried && !reported.contains(entry.result.key)
            if gone {
                cancelResolve(entry)
            } else {
                kept.append(entry)
            }
        }
        found = kept
        changed()
    }

    private func foundEntry(_ key: String) -> Found? {
        for entry in found where entry.result.key == key {
            return entry
        }
        return nil
    }

    private func startResolve(_ entry: Found) {
        resolveCount += 1
        entry.attempt = resolveCount
        let attempt: Int = entry.attempt
        let key: String = entry.result.key
        entry.problem = nil
        entry.isResolving = true
        let handle: any EsclCancellable = resolver.resolve(entry.result) { [weak self] (outcome: EsclResolveOutcome) -> Void in
            self?.resolved(key, attempt: attempt, outcome)
        }
        // A resolver that answered at once has nothing left to stop.
        if entry.isResolving && entry.attempt == attempt {
            entry.resolving = handle
        }
    }

    private func cancelResolve(_ entry: Found) {
        entry.isResolving = false
        entry.resolving?.cancel()
        entry.resolving = nil
    }

    private func resolved(_ key: String, attempt: Int, _ outcome: EsclResolveOutcome) {
        // Gone (removed, stopped) or resolved again meanwhile: a late answer is dropped.
        guard let entry = foundEntry(key), entry.attempt == attempt, entry.isResolving else { return }
        entry.isResolving = false
        entry.resolving = nil
        switch outcome {
        case .resolved(let service):
            entry.resolved = service
            entry.problem = nil
        case .failed(let reason):
            entry.problem = reason
        case .denied:
            entry.problem = "Local Network access is off"
            deniedElsewhere = true
        }
        changed()
    }

    private func endFirstSearch(_ startedIn: Int) {
        guard startedIn == generation, firstSearch else { return }
        firstSearch = false
        changed()
    }

    private func dropCarried(_ startedIn: Int) {
        guard startedIn == generation else { return }
        var kept: [Found] = []
        var dropped: Bool = false
        for entry in found {
            if entry.carried {
                cancelResolve(entry)
                dropped = true
            } else {
                kept.append(entry)
            }
        }
        guard dropped else { return }
        found = kept
        changed()
    }

    private func changed() {
        onChange?()
    }
}
