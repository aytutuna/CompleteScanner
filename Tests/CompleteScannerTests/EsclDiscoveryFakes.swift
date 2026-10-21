import Foundation
@testable import CompleteScannerKit

// Stand-ins for the system's DNS-SD browsing and resolving (EsclServiceBrowsing, EsclServiceResolving), so
// EsclDiscovery and EsclScannerBackend are checked without ever browsing the network: no NWBrowser and no
// dnssd request is made by any test. Shared by EsclBrowsingTests and EsclScannerBackendTests.

/// A browser that reports what the test says, when it says it.
@MainActor
final class DiscoveryFakeBrowser: EsclServiceBrowsing {
    let secure: Bool
    var onStatus: ((EsclBrowserStatus) -> Void)?
    var onResults: (([EsclBrowseResult]) -> Void)?
    private(set) var startCount: Int = 0
    private(set) var cancelCount: Int = 0

    init(secure: Bool) {
        self.secure = secure
    }

    func start() {
        startCount += 1
    }

    func cancel() {
        cancelCount += 1
    }

    /// The system reports this state.
    func send(_ status: EsclBrowserStatus) {
        onStatus?(status)
    }

    /// The system reports these instances (all of them, as NWBrowser does).
    func report(_ results: [EsclBrowseResult]) {
        onResults?(results)
    }
}

/// Makes the fake browsers and keeps them, newest last.
@MainActor
final class DiscoveryFakeBrowsers {
    private(set) var made: [DiscoveryFakeBrowser] = []

    func make(_ secure: Bool) -> any EsclServiceBrowsing {
        let browser: DiscoveryFakeBrowser = DiscoveryFakeBrowser(secure: secure)
        made.append(browser)
        return browser
    }

    /// The newest browser of a service type.
    func latest(secure: Bool) -> DiscoveryFakeBrowser? {
        var found: DiscoveryFakeBrowser?
        for browser in made where browser.secure == secure {
            found = browser
        }
        return found
    }
}

/// One resolve the test answers by hand.
@MainActor
final class DiscoveryFakeResolve: EsclCancellable {
    let result: EsclBrowseResult
    private let completion: @MainActor (EsclResolveOutcome) -> Void
    private(set) var cancelled: Bool = false

    init(result: EsclBrowseResult, completion: @escaping @MainActor (EsclResolveOutcome) -> Void) {
        self.result = result
        self.completion = completion
    }

    func cancel() {
        cancelled = true
    }

    func answer(_ outcome: EsclResolveOutcome) {
        completion(outcome)
    }
}

/// Resolves at once the instances it has an answer for (by instance name), and keeps the others for the
/// test to answer.
@MainActor
final class DiscoveryFakeResolver: EsclServiceResolving {
    var answers: [String: EsclResolveOutcome] = [:]
    private(set) var requests: [DiscoveryFakeResolve] = []

    func resolve(_ result: EsclBrowseResult,
                 completion: @escaping @MainActor (EsclResolveOutcome) -> Void) -> any EsclCancellable {
        let request: DiscoveryFakeResolve = DiscoveryFakeResolve(result: result, completion: completion)
        requests.append(request)
        if let outcome = answers[result.name] {
            completion(outcome)
        }
        return request
    }

    /// The newest request for an instance.
    func latest(_ name: String) -> DiscoveryFakeResolve? {
        var found: DiscoveryFakeResolve?
        for request in requests where request.result.name == name {
            found = request
        }
        return found
    }
}

/// Timers the test fires by hand.
@MainActor
final class DiscoveryFakeScheduler {
    private(set) var delays: [TimeInterval] = []
    private var actions: [@MainActor () -> Void] = []

    func schedule(_ delay: TimeInterval, _ action: @escaping @MainActor () -> Void) {
        delays.append(delay)
        actions.append(action)
    }

    /// Runs the timer scheduled first of those not run yet; does nothing when there is none.
    func fireOldest() {
        guard !actions.isEmpty else { return }
        let action: @MainActor () -> Void = actions.removeFirst()
        action()
    }

    /// Runs every timer scheduled so far.
    func fireAll() {
        let due: [@MainActor () -> Void] = actions
        actions = []
        for action in due {
            action()
        }
    }
}

/// A discovery over the fakes.
@MainActor
func makeFakeDiscovery(_ browsers: DiscoveryFakeBrowsers, _ resolver: DiscoveryFakeResolver,
                       _ scheduler: DiscoveryFakeScheduler) -> EsclDiscovery {
    EsclDiscovery(makeBrowser: { (secure: Bool) -> any EsclServiceBrowsing in
        browsers.make(secure)
    }, resolver: resolver, carryTime: 5, schedule: { (delay: TimeInterval, action: @escaping @MainActor () -> Void) -> Void in
        scheduler.schedule(delay, action)
    })
}

/// An _uscan or _uscans instance as NWBrowser reports it.
func fakeBrowseResult(_ name: String, secure: Bool, txt: [String]) -> EsclBrowseResult {
    EsclBrowseResult(name: name, type: secure ? "_uscans._tcp" : "_uscan._tcp", domain: "local.", interfaceIndex: 0, txt: txt)
}
