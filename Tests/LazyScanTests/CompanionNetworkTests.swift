import Foundation
import Network
import XCTest
@testable import LazyScanKit

// Mirrors windows/LazyScan.Core.Tests/CompanionNetworkTests.cs: trusted networks, the peers
// answered, rate limits and the phone checks (same cases; the Firewall_* cases read Windows Firewall
// rules and have no twin). The Mac's wording of the checks is Swift only.

/// An address as the server sees a peer's: IPv4 or IPv6.
func companionHost(_ text: String) -> NWEndpoint.Host {
    if let ipv4 = IPv4Address(text) { return .ipv4(ipv4) }
    return .ipv6(IPv6Address(text)!)
}

enum TestNetworks {
    static func adapter(_ index: Int, _ address: String, _ prefix: Int, adapterId: String? = nil) -> CompanionNetworkInterface {
        CompanionNetworkInterface(index: index, adapterId: adapterId ?? "{0000000\(index)-0000-0000-0000-000000000000}",
                                  addresses: [LocalSubnet(address: companionHost(address), prefixLength: prefix)])
    }

    static func home(_ category: CompanionNetworkCategory = .privateNetwork) -> CompanionNetwork {
        CompanionNetwork(id: "{11111111-1111-1111-1111-111111111111}", name: "Home Wi-Fi", category: category,
                         interfaces: [adapter(7, "192.168.1.20", 24)])
    }

    static func college(_ category: CompanionNetworkCategory = .publicNetwork) -> CompanionNetwork {
        CompanionNetwork(id: "{22222222-2222-2222-2222-222222222222}", name: "eduroam", category: category,
                         interfaces: [adapter(9, "141.20.5.17", 16)])
    }
}

final class CompanionNetworkTests: XCTestCase {
    /// 2026-10-20T08:30:00Z.
    private let now = Date(timeIntervalSince1970: 1_792_485_000)
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("LazyScanTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private let none: (String) -> Bool = { _ in false }

    private var fileURL: URL { directory.appendingPathComponent(TrustedNetworkStore.fileName) }

    func testTrust_PrivateOrApprovedOnly() {
        XCTAssertEqual(TrustedNetworkPolicy.trust(TestNetworks.home(), isApproved: none), .privateNetwork)
        XCTAssertEqual(TrustedNetworkPolicy.trust(TestNetworks.college(), isApproved: none), .notTrusted)
        XCTAssertEqual(TrustedNetworkPolicy.trust(TestNetworks.college(.domainNetwork), isApproved: none), .notTrusted)
        let collegeId = TestNetworks.college().id
        XCTAssertEqual(TrustedNetworkPolicy.trust(TestNetworks.college(), isApproved: { $0 == collegeId }), .approved)
        var unnamed = TestNetworks.college()
        unnamed.id = ""
        XCTAssertEqual(TrustedNetworkPolicy.trust(unnamed, isApproved: { _ in true }), .notTrusted)
    }

    func testListenAddresses_AreTheTrustedNetworksOnly() {
        let both = [TestNetworks.college(), TestNetworks.home()]
        XCTAssertEqual(TrustedNetworkPolicy.listenAddresses(both, isApproved: none).map(\.address), [companionHost("192.168.1.20")])
        XCTAssertEqual(TrustedNetworkPolicy.listenAddresses(both, isApproved: { _ in true }).map(\.address),
                       [companionHost("141.20.5.17"), companionHost("192.168.1.20")])
        XCTAssertTrue(TrustedNetworkPolicy.listenAddresses([TestNetworks.college()], isApproved: none).isEmpty)
        // An adapter that also carries an untrusted network is never listened on.
        var shared = TestNetworks.home()
        shared.interfaces = [TestNetworks.adapter(9, "192.168.1.20", 24, adapterId: TestNetworks.college().interfaces[0].adapterId)]
        XCTAssertTrue(TrustedNetworkPolicy.listenAddresses([shared, TestNetworks.college()], isApproved: none).isEmpty)
        // IPv4 first, each address once.
        var dual = TestNetworks.home()
        dual.interfaces = [
            CompanionNetworkInterface(index: 7, adapterId: "a", addresses: [
                LocalSubnet(address: companionHost("fd00::5"), prefixLength: 64),
                LocalSubnet(address: companionHost("192.168.1.20"), prefixLength: 24),
            ]),
            CompanionNetworkInterface(index: 8, adapterId: "b", addresses: [
                LocalSubnet(address: companionHost("192.168.1.20"), prefixLength: 24),
            ]),
        ]
        XCTAssertEqual(TrustedNetworkPolicy.listenAddresses([dual], isApproved: none).map(\.address),
                       [companionHost("192.168.1.20"), companionHost("fd00::5")])
    }

    func testIsLocalAddress_CoversPrivateRanges() {
        let cases: [(String, Bool)] = [
            ("127.0.0.1", true), ("10.1.2.3", true), ("172.16.0.1", true), ("172.31.255.255", true), ("172.32.0.1", false),
            ("192.168.200.1", true), ("169.254.10.10", true), ("100.64.0.1", true), ("100.128.0.1", false), ("8.8.8.8", false),
            ("::1", true), ("fe80::1", true), ("fd12:3456::1", true), ("2001:db8::1", false), ("::ffff:192.168.1.5", true),
        ]
        for (address, local) in cases {
            XCTAssertEqual(TrustedNetworkPolicy.isLocalAddress(companionHost(address)), local, address)
        }
    }

    func testIsAllowedPeer_AlsoTakesTheListenedSubnet() {
        let listening = [LocalSubnet(address: companionHost("141.20.5.17"), prefixLength: 16)]
        XCTAssertTrue(TrustedNetworkPolicy.isAllowedPeer(companionHost("141.20.200.9"), listening: listening))
        XCTAssertTrue(TrustedNetworkPolicy.isAllowedPeer(companionHost("::ffff:141.20.200.9"), listening: listening))
        XCTAssertFalse(TrustedNetworkPolicy.isAllowedPeer(companionHost("141.21.0.1"), listening: listening))
        XCTAssertTrue(TrustedNetworkPolicy.isAllowedPeer(companionHost("192.168.1.5"), listening: listening))
        XCTAssertFalse(TrustedNetworkPolicy.isAllowedPeer(companionHost("8.8.8.8"), listening: listening))
    }

    func testLocalSubnet_ComparesThePrefixOnly() {
        let subnet = LocalSubnet(address: companionHost("10.0.0.130"), prefixLength: 25)
        XCTAssertTrue(subnet.contains(companionHost("10.0.0.255")))
        XCTAssertFalse(subnet.contains(companionHost("10.0.0.127")))
        XCTAssertFalse(subnet.contains(companionHost("fd00::1")))
        XCTAssertTrue(LocalSubnet(address: companionHost("fd00::1"), prefixLength: 64).contains(companionHost("fd00::ffff")))
        XCTAssertTrue(LocalSubnet(address: companionHost("1.2.3.4"), prefixLength: 0).contains(companionHost("9.9.9.9")))
    }

    func testTrustedNetworkStore_ApprovesAndWithdraws() throws {
        let store = TrustedNetworkStore(directory: directory)
        var changes = 0
        store.onChange = { changes += 1 }
        let college = TestNetworks.college()
        XCTAssertFalse(store.isApproved(college.id))
        XCTAssertTrue(store.approve(college, now: now))
        XCTAssertTrue(store.isApproved(college.id))
        let approved = TrustedNetworkStore(directory: directory).approved
        XCTAssertEqual(approved.count, 1)
        XCTAssertEqual(approved.first?.name, "eduroam")
        XCTAssertEqual(approved.first?.approved, now)
        let before = try Data(contentsOf: fileURL)
        store.revoke(college.id)
        XCTAssertFalse(store.isApproved(college.id))
        XCTAssertFalse(TrustedNetworkStore(directory: directory).isApproved(college.id))
        // Withdrawn stays withdrawn for this session, whatever another window writes.
        try before.write(to: fileURL)
        XCTAssertFalse(store.isApproved(college.id))
        XCTAssertTrue(store.approve(college, now: now))
        XCTAssertTrue(store.isApproved(college.id))
        XCTAssertEqual(changes, 3)
        XCTAssertFalse(store.isApproved(""))
    }

    func testTrustedNetworkStore_ReadsBadFilesLeniently() throws {
        try Data(#"{"networks":[{"id":"x","approved":"soon"}],"v":2}"#.utf8).write(to: fileURL)
        let store = TrustedNetworkStore(directory: directory)
        XCTAssertTrue(store.isApproved("x"))
        XCTAssertEqual(store.approved.count, 1)
        XCTAssertNil(store.approved.first?.approved)
        try Data("garbage".utf8).write(to: fileURL)
        XCTAssertTrue(TrustedNetworkStore(directory: directory).approved.isEmpty)
        let kept = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("companion-networks.unreadable-") && $0.hasSuffix(".json") }
        XCTAssertEqual(kept.count, 1)
    }

    func testRateLimiter_CountsPerAddress() {
        let limiter = CompanionRateLimiter()
        let a = companionHost("192.168.1.5")
        let b = companionHost("192.168.1.6")
        for _ in 0..<(CompanionRateLimiter.maxFailures - 1) {
            limiter.recordFailure(a, now: now)
        }
        XCTAssertFalse(limiter.isBlocked(a, now: now))
        limiter.recordFailure(companionHost("::ffff:192.168.1.5"), now: now)
        XCTAssertTrue(limiter.isBlocked(a, now: now))
        XCTAssertFalse(limiter.tryRequest(a, now: now))
        XCTAssertTrue(limiter.tryRequest(b, now: now))
        XCTAssertFalse(limiter.isBlocked(a, now: now.addingTimeInterval(CompanionRateLimiter.window)))
        // b made one request above.
        for _ in 1..<CompanionRateLimiter.maxRequestsPerWindow {
            XCTAssertTrue(limiter.tryRequest(b, now: now))
        }
        XCTAssertFalse(limiter.tryRequest(b, now: now))
        XCTAssertTrue(limiter.tryRequest(b, now: now.addingTimeInterval(CompanionRateLimiter.window)))
    }

    // MARK: - Phone checks

    private func state(_ network: CompanionNetwork, _ trust: NetworkTrust) -> CompanionNetworkState {
        CompanionNetworkState(network: network, trust: trust)
    }

    func testChecks_PublicNetworkNotApproved() {
        let snapshot = CompanionSnapshot(networks: [state(TestNetworks.college(), .notTrusted)], listen: .noTrustedNetwork,
                                         firewall: .willAsk, pairedCount: 1)
        let checks = CompanionTroubleshooter.diagnose(snapshot)
        XCTAssertEqual(checks.map(\.id), ["phoneNetwork:\(TestNetworks.college().id)", "phoneFirewall", "phoneIsolation"])
        let network = checks[0]
        XCTAssertEqual(network.status, .warning)
        XCTAssertEqual(network.title, "Not receiving on eduroam")
        XCTAssertTrue(network.detail.contains("as a public network"))
        XCTAssertTrue(network.detail.contains("Allow receiving on this network"))
        XCTAssertEqual(network.actions, [.openNetworkSettings])
        XCTAssertEqual(CompanionTroubleshooter.summary(checks), "1 warning found.")
        XCTAssertEqual(CompanionTroubleshooter.headline(snapshot), "Not receiving from phones on eduroam.")
        XCTAssertEqual(checks[2].status, .tip)
        XCTAssertTrue(checks[2].detail.contains("hotspot"))
    }

    func testChecks_ApprovedPublicNetworkMentionsTheFirewallQuestion() {
        let snapshot = CompanionSnapshot(networks: [state(TestNetworks.college(), .approved)], listen: .listening, port: 52731,
                                         firewall: .willAsk, pairedCount: 2)
        let checks = CompanionTroubleshooter.diagnose(snapshot)
        XCTAssertEqual(checks.map(\.id),
                       ["phoneListening", "phoneNetwork:\(TestNetworks.college().id)", "phoneFirewall", "phoneIsolation"])
        XCTAssertEqual(checks[0].detail, "Listening on port 52731. 2 phones are paired.")
        XCTAssertEqual(checks[1].title, "Receiving on eduroam, which you allowed")
        XCTAssertEqual(checks[1].detail, "Paired phones on this network can send documents to this PC.")
        XCTAssertTrue(checks[2].detail.contains("Public networks ticked"))
        XCTAssertEqual(CompanionTroubleshooter.summary(checks), "Nothing here stops a paired phone from connecting.")
        XCTAssertEqual(CompanionTroubleshooter.headline(snapshot), "Receiving from phones on eduroam.")
    }

    func testChecks_FirewallBlockIsAProblem() {
        let snapshot = CompanionSnapshot(networks: [state(TestNetworks.home(), .privateNetwork)], listen: .listening, port: 52731,
                                         firewall: .blocked, blockingRules: ["lazyscan.exe"], pairedCount: 1)
        let checks = CompanionTroubleshooter.diagnose(snapshot)
        XCTAssertEqual(checks[0].id, "phoneFirewall")
        XCTAssertEqual(checks[0].status, .problem)
        XCTAssertTrue(checks[0].detail.contains("\"lazyscan.exe\""))
        XCTAssertTrue(checks[0].detail.contains("wf.msc"))
        XCTAssertEqual(checks.first { $0.id.hasPrefix("phoneNetwork:") }?.title, "Home Wi-Fi is a private network")
        XCTAssertEqual(CompanionTroubleshooter.summary(checks), "1 problem found.")
    }

    func testChecks_SayWhyNothingListens() {
        let off = CompanionTroubleshooter.diagnose(CompanionSnapshot(listen: .off, firewall: .willAsk))
        XCTAssertEqual(off.map(\.id).sorted(), ["phoneIsolation", "phoneListening"])
        XCTAssertEqual(off.first { $0.id == "phoneListening" }?.title, "No phone is paired")
        XCTAssertFalse(off.contains { $0.id == "phoneFirewall" })
        let offline = CompanionTroubleshooter.diagnose(CompanionSnapshot(listen: .offline))
        XCTAssertEqual(offline[0].status, .problem)
        XCTAssertEqual(offline[0].title, "Not connected to a network")
        let failed = CompanionTroubleshooter.diagnose(CompanionSnapshot(listen: .failed, listenError: "Port in use"))
        XCTAssertTrue(failed[0].detail.hasPrefix("Port in use. Close other copies"))
        let elsewhere = CompanionTroubleshooter.diagnose(CompanionSnapshot(listen: .elsewhere))
        XCTAssertEqual(elsewhere[0].status, .warning)
        let pairing = CompanionTroubleshooter.diagnose(CompanionSnapshot(listen: .listening, port: 5000, firewall: .allowed,
                                                                         pairingOpen: true))
        XCTAssertEqual(pairing.first { $0.id == "phoneListening" }?.detail,
                       "Listening on port 5000 while the pairing code is shown.")
        XCTAssertEqual(pairing.first { $0.id == "phoneFirewall" }?.status, .ok)
    }

    func testChecks_OnTheMacNameTheMacAndNotWindows() {
        let snapshot = CompanionSnapshot(platform: .mac, networks: [state(TestNetworks.college(), .notTrusted)],
                                         listen: .noTrustedNetwork, pairedCount: 1)
        let checks = CompanionTroubleshooter.diagnose(snapshot)
        XCTAssertEqual(checks.map(\.id), ["phoneNetwork:\(TestNetworks.college().id)", "phoneIsolation"])
        XCTAssertTrue(checks[0].detail.contains("Allow receiving on this network"))
        XCTAssertFalse(checks[0].detail.contains("Windows"))
        XCTAssertEqual(checks[0].actions, [])
        XCTAssertTrue(checks[1].detail.contains("Connect this Mac to your phone's hotspot"))
        let offline = CompanionTroubleshooter.diagnose(CompanionSnapshot(platform: .mac, listen: .offline))
        XCTAssertTrue(offline[0].detail.hasPrefix("This Mac is not on a network"))
    }

    func testChecks_SuggestTheCloudFolderWhenPhonesStayAway() {
        let day: TimeInterval = 24 * 60 * 60
        let quiet = CompanionSnapshot(networks: [state(TestNetworks.home(), .privateNetwork)], listen: .listening, port: 52731,
                                      pairedCount: 1, phonesQuietFor: 4.5 * day)
        let checks = CompanionTroubleshooter.diagnose(quiet)
        let check = checks.first { $0.id == "phoneSyncFolder" }
        XCTAssertEqual(check?.status, .tip)
        XCTAssertEqual(check?.detail.contains("for 4 days"), true)
        XCTAssertEqual(check?.detail.contains("OneDrive or iCloud Drive"), true)
        XCTAssertEqual(checks.last?.id, "phoneIsolation")
        var chosen = quiet
        chosen.syncFolderChosen = true
        XCTAssertFalse(CompanionTroubleshooter.diagnose(chosen).contains { $0.id == "phoneSyncFolder" })
        var recent = quiet
        recent.phonesQuietFor = day
        XCTAssertFalse(CompanionTroubleshooter.diagnose(recent).contains { $0.id == "phoneSyncFolder" })
        var none = quiet
        none.pairedCount = 0
        none.phonesQuietFor = nil
        XCTAssertFalse(CompanionTroubleshooter.diagnose(none).contains { $0.id == "phoneSyncFolder" })
        var mac = quiet
        mac.platform = .mac
        XCTAssertEqual(CompanionTroubleshooter.diagnose(mac).first { $0.id == "phoneSyncFolder" }?.title,
                       "Phone has not reached this Mac lately?")
    }
}
