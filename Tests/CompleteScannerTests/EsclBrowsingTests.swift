import Foundation
import XCTest
@testable import CompleteScannerKit

// EsclDiscovery over stand-ins for the system's browsers and resolver (EsclDiscoveryFakes.swift): what the
// iPhone's search for eSCL scanners hands over (the same EsclService values Windows produces, merged by
// EsclEndpoint.choose), how Local Network access that is off is inferred, and how the search pauses in the
// background. No test browses the network. Swift only: the Windows search (EsclDiscovery.cs) is the
// Windows app's own, over its device watcher; what both hand over is checked by EsclDiscoveryTests on both
// platforms.

final class EsclBrowsingTests: XCTestCase {
    private var browsers: DiscoveryFakeBrowsers!
    private var resolver: DiscoveryFakeResolver!
    private var scheduler: DiscoveryFakeScheduler!
    private var discovery: EsclDiscovery!
    private var changes: Int = 0

    /// Fresh stand-ins and a discovery over them; each test starts with it.
    @MainActor
    private func prepare() {
        browsers = DiscoveryFakeBrowsers()
        resolver = DiscoveryFakeResolver()
        scheduler = DiscoveryFakeScheduler()
        discovery = makeFakeDiscovery(browsers, resolver, scheduler)
        changes = 0
        discovery.onChange = { [weak self] in
            self?.changes += 1
        }
    }

    @MainActor
    private func hpTxt() throws -> [String] {
        try EsclFixtures.lines(EsclFixtures.hpTxtFile)
    }

    @MainActor
    private func resolved(_ host: String?, _ port: Int, _ addresses: [String]) -> EsclResolveOutcome {
        EsclResolveOutcome.resolved(EsclResolvedService(hostName: host, port: port, addresses: addresses))
    }

    @MainActor
    private func browser(secure: Bool, file: StaticString = #filePath, line: UInt = #line) -> DiscoveryFakeBrowser {
        guard let found = browsers.latest(secure: secure) else {
            XCTFail("No browser for \(secure ? "_uscans" : "_uscan")", file: file, line: line)
            return DiscoveryFakeBrowser(secure: secure)
        }
        return found
    }

    @MainActor
    func test_nothingIsBrowsedBeforeStart_thenOneBrowserPerServiceType() {
        prepare()
        XCTAssertTrue(browsers.made.isEmpty)
        XCTAssertEqual(discovery.status, .off)
        XCTAssertFalse(discovery.isBrowsing)

        discovery.start()
        XCTAssertEqual(browsers.made.count, 2)
        XCTAssertEqual(browser(secure: true).startCount, 1)
        XCTAssertEqual(browser(secure: false).startCount, 1)
        XCTAssertEqual(discovery.status, .searching)
        // Starting again while browsing changes nothing.
        discovery.start()
        XCTAssertEqual(browsers.made.count, 2)

        browser(secure: true).send(.ready)
        XCTAssertEqual(discovery.status, .searching)
        browser(secure: false).send(.ready)
        XCTAssertEqual(discovery.status, .running)
        XCTAssertEqual(discovery.statusLine, "browsing, ready, 0 service(s)")
    }

    @MainActor
    func test_aServiceIsListedOnceResolved_withEveryAddressAndItsTxtRecord() throws {
        prepare()
        discovery.start()
        let txt: [String] = try hpTxt()
        browser(secure: false).report([fakeBrowseResult("HP M479 (A1B2C3)", secure: false, txt: txt)])
        // Reported, not resolved yet: not listed.
        XCTAssertTrue(discovery.services.isEmpty)
        XCTAssertEqual(discovery.unresolvedLines, ["_uscan \"HP M479 (A1B2C3)\" not resolved (resolving)"])

        resolver.latest("HP M479 (A1B2C3)")?.answer(resolved("HPA1B2C3.local", 80, ["192.168.1.20", "fe80::1%4", "2001:db8::20"]))
        XCTAssertEqual(discovery.services, [EsclService(id: "hp m479 (a1b2c3)._uscan._tcp.local.", instanceName: "HP M479 (A1B2C3)",
                                                        secure: false, hostName: "HPA1B2C3.local",
                                                        addresses: ["192.168.1.20", "fe80::1%4", "2001:db8::20"],
                                                        port: 80, textAttributes: txt)])
        XCTAssertTrue(discovery.unresolvedLines.isEmpty)
    }

    @MainActor
    func test_bothServicesOfOneScanner_becomeOneEndpoint_httpsFirst() throws {
        prepare()
        let txt: [String] = try hpTxt()
        resolver.answers["HP M479 (A1B2C3)"] = resolved("HPA1B2C3.local", 443, ["192.168.1.20"])
        discovery.start()
        browser(secure: true).report([fakeBrowseResult("HP M479 (A1B2C3)", secure: true, txt: txt)])
        resolver.answers["HP M479 (A1B2C3)"] = resolved("HPA1B2C3.local", 80, ["192.168.1.20", "2001:db8::20"])
        browser(secure: false).report([fakeBrowseResult("HP M479 (A1B2C3)", secure: false, txt: txt)])

        XCTAssertEqual(discovery.services.count, 2)
        let endpoints: [EsclEndpoint] = EsclEndpoint.choose(discovery.services)
        XCTAssertEqual(endpoints.count, 1)
        var addresses: [String] = []
        for address in endpoints.first?.addresses ?? [] {
            addresses.append(address.description)
        }
        XCTAssertEqual(addresses, ["https://192.168.1.20", "https://hpa1b2c3.local", "192.168.1.20", "hpa1b2c3.local", "[2001:db8::20]"])
        XCTAssertEqual(endpoints.first?.name, "HP Color LaserJet MFP M479fdw")
    }

    @MainActor
    func test_aServiceNoLongerReported_isGone_andItsResolveStopped() {
        prepare()
        resolver.answers["Epson"] = resolved("EPSON1.local", 80, ["192.168.1.30"])
        discovery.start()
        let plain: DiscoveryFakeBrowser = browser(secure: false)
        plain.report([fakeBrowseResult("Epson", secure: false, txt: ["ty=Epson ET-4850"]),
                      fakeBrowseResult("Canon", secure: false, txt: ["ty=Canon MF743C"])])
        XCTAssertEqual(discovery.services.count, 1)
        let canon: DiscoveryFakeResolve? = resolver.latest("Canon")
        XCTAssertEqual(canon?.cancelled, false)

        // The other type's list says nothing about these.
        browser(secure: true).report([])
        XCTAssertEqual(discovery.services.count, 1)

        plain.report([])
        XCTAssertTrue(discovery.services.isEmpty)
        XCTAssertEqual(canon?.cancelled, true)
    }

    @MainActor
    func test_aLateAnswer_forAServiceGoneOrAStoppedSearch_isIgnored() {
        prepare()
        discovery.start()
        let plain: DiscoveryFakeBrowser = browser(secure: false)
        plain.report([fakeBrowseResult("Canon", secure: false, txt: [])])
        let first: DiscoveryFakeResolve? = resolver.latest("Canon")
        plain.report([])
        first?.answer(resolved("CANON.local", 80, ["10.0.0.7"]))
        XCTAssertTrue(discovery.services.isEmpty)

        // Reported again: a new resolve, whose answer counts; the earlier one's still does not.
        plain.report([fakeBrowseResult("Canon", secure: false, txt: [])])
        let second: DiscoveryFakeResolve? = resolver.latest("Canon")
        XCTAssertFalse(first === second)
        first?.answer(resolved("OLD.local", 80, ["10.0.0.99"]))
        XCTAssertTrue(discovery.services.isEmpty)
        second?.answer(resolved("CANON.local", 80, ["10.0.0.7"]))
        XCTAssertEqual(discovery.services.first?.addresses, ["10.0.0.7"])

        discovery.stop()
        plain.report([fakeBrowseResult("Late", secure: false, txt: [])])
        XCTAssertTrue(discovery.services.isEmpty)
        XCTAssertNil(resolver.latest("Late"))
    }

    @MainActor
    func test_aChangedTxtRecord_isTakenWithoutResolvingAgain() {
        prepare()
        resolver.answers["Brother"] = resolved("BRN1.local", 80, ["192.168.1.40"])
        discovery.start()
        let plain: DiscoveryFakeBrowser = browser(secure: false)
        plain.report([fakeBrowseResult("Brother", secure: false, txt: ["ty=Brother ADS-1700W"])])
        plain.report([fakeBrowseResult("Brother", secure: false, txt: ["rs=eSCL", "ty=Brother ADS-1700W"])])
        XCTAssertEqual(resolver.requests.count, 1)
        XCTAssertEqual(discovery.services.first?.textAttributes, ["rs=eSCL", "ty=Brother ADS-1700W"])
    }

    @MainActor
    func test_aResolveThatFails_listsNothing_andRefreshTriesAgain() {
        prepare()
        discovery.start()
        browser(secure: false).report([fakeBrowseResult("Canon", secure: false, txt: [])])
        resolver.latest("Canon")?.answer(.failed("no answer in time"))
        XCTAssertTrue(discovery.services.isEmpty)
        XCTAssertEqual(discovery.unresolvedLines, ["_uscan \"Canon\" not resolved (no answer in time)"])
        XCTAssertEqual(resolver.requests.count, 1)

        discovery.restart()
        XCTAssertEqual(resolver.requests.count, 2)
        resolver.latest("Canon")?.answer(resolved("CANON.local", 80, ["10.0.0.7"]))
        XCTAssertEqual(discovery.services.count, 1)
        // Both browsers work: Refresh leaves them alone.
        XCTAssertEqual(browsers.made.count, 2)
    }

    @MainActor
    func test_aBrowserWaitingWithPolicyDenied_isDenied_untilItIsReady() {
        prepare()
        XCTAssertEqual(EsclLocalNetwork.policyDeniedCode, -65570)
        XCTAssertTrue(EsclLocalNetwork.isPolicyDenied(-65570))
        XCTAssertFalse(EsclLocalNetwork.isPolicyDenied(-65563))
        XCTAssertFalse(EsclLocalNetwork.isPolicyDenied(nil))

        discovery.start()
        // Waiting for another reason (no network yet) is still searching.
        browser(secure: false).send(.waiting(code: -65563, detail: "ServiceNotRunning"))
        XCTAssertEqual(discovery.status, .searching)
        browser(secure: false).send(.waiting(code: EsclLocalNetwork.policyDeniedCode, detail: "PolicyDenied"))
        XCTAssertEqual(discovery.status, .denied)
        XCTAssertEqual(discovery.statusLine, "Local Network access is off")
        // The user turns access on in Settings: the system retries and the browser is ready.
        browser(secure: false).send(.ready)
        browser(secure: true).send(.ready)
        XCTAssertEqual(discovery.status, .running)
        // A browser that fails for that reason is denied too, not unavailable.
        browser(secure: true).send(.failed(code: EsclLocalNetwork.policyDeniedCode, detail: "PolicyDenied"))
        XCTAssertEqual(discovery.status, .denied)
        XCTAssertNil(discovery.failure)
    }

    @MainActor
    func test_aRefusedResolve_orAConnectionRefusedForTheLocalNetwork_isDenied() {
        prepare()
        discovery.start()
        browser(secure: false).send(.ready)
        browser(secure: true).send(.ready)
        browser(secure: false).report([fakeBrowseResult("Canon", secure: false, txt: [])])
        resolver.latest("Canon")?.answer(.denied)
        XCTAssertEqual(discovery.status, .denied)
        XCTAssertEqual(discovery.unresolvedLines, ["_uscan \"Canon\" not resolved (Local Network access is off)"])

        // A browser ready again means access is on.
        browser(secure: false).send(.ready)
        XCTAssertEqual(discovery.status, .running)

        // A connection's path refused for the local network (an address added by hand) says the same,
        // even before the search runs.
        discovery.stop()
        discovery.reportDenied()
        XCTAssertEqual(discovery.status, .denied)
        discovery.start()
        XCTAssertEqual(discovery.status, .searching)
    }

    @MainActor
    func test_aFailedBrowser_isUnavailable_andRefreshStartsItAgain() {
        prepare()
        discovery.start()
        let failed: DiscoveryFakeBrowser = browser(secure: true)
        browser(secure: false).send(.ready)
        failed.send(.failed(code: -65539, detail: "BadParam."))
        XCTAssertEqual(discovery.status, .unavailable)
        XCTAssertEqual(discovery.failure, "BadParam.")
        XCTAssertEqual(discovery.statusLine, "unavailable (BadParam.)")

        discovery.restart()
        XCTAssertEqual(failed.cancelCount, 1)
        XCTAssertEqual(browsers.made.count, 3)
        XCTAssertFalse(browser(secure: true) === failed)
        XCTAssertEqual(browser(secure: false).cancelCount, 0)
        XCTAssertEqual(discovery.status, .searching)
        // The old browser's late news is ignored.
        failed.send(.failed(code: -65539, detail: "BadParam."))
        XCTAssertEqual(discovery.status, .searching)
    }

    @MainActor
    func test_pauseKeepsWhatWasFound_resumeDropsWhatIsNotReportedAgain() {
        prepare()
        resolver.answers["Epson"] = resolved("EPSON1.local", 80, ["192.168.1.30"])
        resolver.answers["Canon"] = resolved("CANON.local", 80, ["10.0.0.7"])
        discovery.start()
        browser(secure: false).report([fakeBrowseResult("Epson", secure: false, txt: []),
                                       fakeBrowseResult("Canon", secure: false, txt: [])])
        XCTAssertEqual(discovery.services.count, 2)
        let before: DiscoveryFakeBrowser = browser(secure: false)

        discovery.pause()
        XCTAssertEqual(before.cancelCount, 1)
        XCTAssertFalse(discovery.isBrowsing)
        XCTAssertEqual(discovery.statusLine, "paused (the app is in the background)")
        XCTAssertEqual(discovery.services.count, 2)
        // Paused, a stopped browser's late list changes nothing.
        before.report([])
        XCTAssertEqual(discovery.services.count, 2)

        discovery.resume()
        XCTAssertEqual(browsers.made.count, 4)
        // The first search's time (from start), then the first search's time and the carry time (from resume).
        XCTAssertEqual(scheduler.delays, [discovery.firstSearchTime, discovery.firstSearchTime, 5])
        browser(secure: false).report([fakeBrowseResult("Epson", secure: false, txt: [])])
        // Not reported again yet, but still within its time: kept.
        XCTAssertEqual(discovery.services.count, 2)
        scheduler.fireAll()
        var names: [String] = []
        for service in discovery.services {
            names.append(service.instanceName)
        }
        XCTAssertEqual(names, ["Epson"])
    }

    @MainActor
    func test_theSearchIsLooking_forItsFirstSearchTime_andWhileAServiceResolves() {
        prepare()
        XCTAssertFalse(discovery.isLooking)
        discovery.start()
        XCTAssertTrue(discovery.isLooking)
        XCTAssertEqual(scheduler.delays, [5])
        // Ready at once, nothing found yet: still looking until the first search time is over.
        browser(secure: false).send(.ready)
        browser(secure: true).send(.ready)
        XCTAssertTrue(discovery.isLooking)
        let changesBefore: Int = changes
        scheduler.fireAll()
        XCTAssertFalse(discovery.isLooking)
        XCTAssertTrue(changes > changesBefore)

        // A service found later is looked for while it resolves.
        browser(secure: false).report([fakeBrowseResult("Canon", secure: false, txt: [])])
        XCTAssertTrue(discovery.isLooking)
        resolver.latest("Canon")?.answer(resolved("CANON.local", 80, ["10.0.0.7"]))
        XCTAssertFalse(discovery.isLooking)

        // Refused for the local network: not looking.
        discovery.stop()
        discovery.start()
        XCTAssertTrue(discovery.isLooking)
        browser(secure: false).send(.waiting(code: EsclLocalNetwork.policyDeniedCode, detail: "PolicyDenied"))
        XCTAssertFalse(discovery.isLooking)

        // Paused: not looking. Resumed: looking again for the first search time, even with nothing found
        // before the pause; the start's timer from before the pause does not end it.
        discovery.stop()
        // The timers of the searches stopped above do nothing.
        scheduler.fireAll()
        discovery.start()
        discovery.pause()
        XCTAssertFalse(discovery.isLooking)
        discovery.resume()
        XCTAssertTrue(discovery.isLooking)
        XCTAssertEqual(discovery.status, .searching)
        browser(secure: false).send(.ready)
        browser(secure: true).send(.ready)
        XCTAssertTrue(discovery.isLooking)
        // The start's timer.
        scheduler.fireOldest()
        XCTAssertTrue(discovery.isLooking)
        // The resume's first search timer.
        let changesBeforeResumeEnds: Int = changes
        scheduler.fireOldest()
        XCTAssertFalse(discovery.isLooking)
        XCTAssertTrue(changes > changesBeforeResumeEnds)
        discovery.stop()
    }

    @MainActor
    func test_stopForgetsEverything_andCancelsTheBrowsers() {
        prepare()
        resolver.answers["Epson"] = resolved("EPSON1.local", 80, ["192.168.1.30"])
        discovery.start()
        browser(secure: false).report([fakeBrowseResult("Epson", secure: false, txt: [])])
        browser(secure: false).report([fakeBrowseResult("Epson", secure: false, txt: []),
                                       fakeBrowseResult("Slow", secure: false, txt: [])])
        let slow: DiscoveryFakeResolve? = resolver.latest("Slow")
        let changesBefore: Int = changes

        discovery.stop()
        XCTAssertTrue(changes > changesBefore)
        XCTAssertTrue(discovery.services.isEmpty)
        XCTAssertEqual(discovery.status, .off)
        XCTAssertEqual(slow?.cancelled, true)
        for made in browsers.made {
            XCTAssertEqual(made.cancelCount, 1)
        }
        // A pause or a resume after a stop does nothing; a start makes new browsers.
        discovery.resume()
        XCTAssertEqual(browsers.made.count, 2)
        discovery.start()
        XCTAssertEqual(browsers.made.count, 4)
    }
}
