import Foundation
import Network
import Security
import XCTest
@testable import CompleteScannerKit

// The host's cases of windows/CompleteScanner.Core.Tests/CompanionLoopbackTests.cs: CompanionService
// with a stand-in network source and advertiser, so nothing listens on or is advertised to the real
// network, and the server on loopback with the fixture identity of CompanionLoopbackTests. The phone is
// the I20 `CompanionClient`. The second network is ::1, since macOS has no 127.0.0.2 unless it is added
// by hand.

/// Networks a test sets and changes.
final class FakeNetworkSource: CompanionNetworkSource, @unchecked Sendable {
    private let current: Guarded<[CompanionNetwork]>

    var onChange: (() -> Void)?

    init(_ networks: [CompanionNetwork]) {
        current = Guarded(networks)
    }

    func networks() -> [CompanionNetwork] {
        current.value
    }

    func set(_ networks: [CompanionNetwork]) {
        current.value = networks
        onChange?()
    }

    static func loopback(_ category: CompanionNetworkCategory = .privateNetwork, address: NWEndpoint.Host = .ipv4(.loopback),
                         index: Int = 1, id: String = "{loopback}") -> CompanionNetwork {
        let subnet = LocalSubnet(address: address, prefixLength: LocalSubnet.bytes(address)?.count == 4 ? 8 : 128)
        return CompanionNetwork(id: id, name: "Test network", category: category,
                                interfaces: [CompanionNetworkInterface(index: index, adapterId: "adapter-\(index)",
                                                                       addresses: [subnet])])
    }
}

/// Records what would be advertised, and what was withdrawn.
final class FakeAdvertiser: DnsSdAdvertiser, @unchecked Sendable {
    private let lock = NSLock()
    private var registered: [Int: DnsSdRegistration] = [:]
    private var entries: [String] = []

    var active: [Int: DnsSdRegistration] {
        lock.lock()
        defer { lock.unlock() }
        return registered
    }

    var log: [String] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    func register(_ registration: DnsSdRegistration) throws -> () -> Void {
        lock.lock()
        registered[registration.interfaceIndex] = registration
        entries.append("register \(registration.interfaceIndex):\(registration.port)")
        lock.unlock()
        return { [weak self] in self?.withdraw(registration) }
    }

    private func withdraw(_ registration: DnsSdRegistration) {
        lock.lock()
        registered.removeValue(forKey: registration.interfaceIndex)
        entries.append("withdraw \(registration.interfaceIndex):\(registration.port)")
        lock.unlock()
    }
}

/// The fixture identity, or a failure to renew it when `renewFails`.
private final class RenewableTestIdentity: CompanionIdentity {
    private let fixture = FixtureIdentity()
    var renewFails = false

    func current(now: Date) throws -> SecIdentity {
        try fixture.current(now: now)
    }

    func renew(now: Date) throws -> SecIdentity {
        if renewFails { throw SelfSignedCertificateError("The key could not be made.") }
        return try fixture.renew(now: now)
    }
}

final class CompanionHostTests: XCTestCase {
    private var directory: URL!
    private let networks = FakeNetworkSource([FakeNetworkSource.loopback()])
    private let advertiser = FakeAdvertiser()
    private let identity = RenewableTestIdentity()
    // To the second, as packages and the outbox write dates.
    private let clock = Guarded(Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)))
    private var service: CompanionService!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("CompanionHostTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Skipped here when the system cannot import the test identity to memory.
        _ = try identity.current(now: clock.value)
        let clock = self.clock
        var options = CompanionServiceOptions(settingsDirectory: directory.appendingPathComponent("Settings", isDirectory: true),
                                              dataDirectory: directory.appendingPathComponent("Data", isDirectory: true),
                                              identity: identity, networks: networks, desktopName: "TEST-MAC")
        options.advertiser = advertiser
        options.clock = { clock.value }
        options.preferredPort = 0
        service = CompanionService(options)
        await service.start()
    }

    override func tearDown() async throws {
        await service?.dispose()
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    // MARK: - Helpers

    /// A phone pinned to `pin` (the service's by default) at the code's addresses.
    private func phone(_ code: PairingUri, id: String = "phone-0001", pin: Data? = nil, secret: Data? = nil) throws
        -> CompanionClient {
        let fingerprint = try pin.map { SpkiFingerprint.text($0) } ?? SpkiFingerprint.text(service.fingerprint())
        let desktop = PairedDesktop(id: "", name: "", fingerprint: fingerprint, addresses: code.addresses, port: code.port,
                                    phoneId: id)
        return CompanionClient(desktop: desktop, secret: secret)
    }

    private func pair(_ client: CompanionClient, _ code: PairingUri, id: String = "phone-0001") async throws -> PairResponse {
        try await client.pair(token: code.token, phoneId: id, phoneName: "Test phone", platform: "ios", appVersion: "1.0")
    }

    /// A paired phone, with the code it paired with.
    private func pairedPhone(_ id: String = "phone-0001") async throws -> (code: PairingUri, client: CompanionClient) {
        let opened = await service.openPairing()
        let code = try XCTUnwrap(opened)
        let answer = try await pair(phone(code, id: id), code, id: id)
        let secret = try XCTUnwrap(CompanionProtocol.decodeBase64Url(answer.deviceSecret))
        let client = try phone(code, id: id, secret: secret)
        return (code, client)
    }

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(15)
        while !condition() {
            if Date() > deadline {
                XCTFail("Timed out waiting.", file: file, line: line)
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// Whether a plain TCP connection to `host`:`port` is taken within 5 s.
    private func isListening(_ port: Int, _ host: NWEndpoint.Host = .ipv4(.loopback)) async -> Bool {
        let queue: DispatchQueue = DispatchQueue(label: "CompanionHostTests.probe")
        let connection: NWConnection = NWConnection(host: host, port: NWEndpoint.Port(rawValue: UInt16(port))!, using: .tcp)
        defer { connection.cancel() }
        let flag: Guarded<Bool> = Guarded(false)
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let finish: (Bool) -> Void = { (ready: Bool) in
                guard !flag.value else { return }
                flag.value = true
                continuation.resume(returning: ready)
            }
            connection.stateUpdateHandler = { (state: NWConnection.State) in
                switch state {
                case .ready: finish(true)
                case .failed, .cancelled, .waiting: finish(false)
                default: break
                }
            }
            queue.asyncAfter(deadline: .now() + 5) { finish(false) }
            connection.start(queue: queue)
        }
    }

    private func isUnreachable(_ body: () async throws -> Void) async -> Bool {
        do {
            try await body()
            return false
        } catch CompanionClientError.unreachable {
            return true
        } catch {
            return false
        }
    }

    private func hosts(_ endpoints: [NWEndpoint]) -> [String] {
        CompanionService.codeAddresses(endpoints)
    }

    // MARK: - Cases

    func testNothingListens_UntilAPhoneIsPairedOrACodeIsShown() async throws {
        XCTAssertEqual(service.status.state, .off)
        XCTAssertTrue(service.status.endpoints.isEmpty)
        XCTAssertTrue(advertiser.active.isEmpty)
        XCTAssertNil(service.pairingCode())
        let opened = await service.openPairing()
        let code = try XCTUnwrap(opened)
        XCTAssertEqual(service.status.state, .listening)
        XCTAssertEqual(code.addresses, ["127.0.0.1"])
        XCTAssertEqual(service.status.port, code.port)
        let der = try XCTUnwrap(SelfSignedCertificate.der(of: identity.current(now: clock.value)))
        XCTAssertEqual(code.fingerprint, SpkiFingerprint.text(try XCTUnwrap(SpkiFingerprint.of(der))))
        XCTAssertEqual(try PairingUri.parse(code.format()), code)
        XCTAssertEqual(advertiser.active.count, 1)
        let advertised = try XCTUnwrap(advertiser.active.values.first)
        XCTAssertEqual(advertised.interfaceIndex, 1)
        XCTAssertEqual(advertised.port, code.port)
        XCTAssertEqual(advertised.serviceType, "_completescan._tcp")
        XCTAssertEqual(advertised.txt, ["v": "1", "id": service.devices.desktopId])
        XCTAssertEqual(advertised.instanceName, "TEST-MAC")
        // Closing the code without pairing stops listening again.
        await service.closePairing()
        XCTAssertEqual(service.status.state, .off)
        XCTAssertTrue(advertiser.active.isEmpty)
        let listening = await isListening(code.port)
        XCTAssertFalse(listening)
    }

    func testListener_StopsWhenTheNetworkIsNoLongerTrusted() async throws {
        let (code, client) = try await pairedPhone()
        _ = try await client.health()
        XCTAssertEqual(advertiser.active.count, 1)

        // The network is no longer trusted (public, not approved): nothing listens or is advertised any more.
        networks.set([FakeNetworkSource.loopback(.publicNetwork)])
        await service.refresh()
        XCTAssertEqual(service.status.state, .noTrustedNetwork)
        XCTAssertTrue(advertiser.active.isEmpty)
        XCTAssertTrue(advertiser.log.contains("withdraw 1:\(code.port)"))
        let stillListening = await isListening(code.port)
        XCTAssertFalse(stillListening)
        let refused = await isUnreachable { _ = try await client.health() }
        XCTAssertTrue(refused)

        // The user allows receiving on it: listening again, on the same port.
        let saved = await service.setNetworkApproved(FakeNetworkSource.loopback(.publicNetwork), true)
        XCTAssertTrue(saved)
        XCTAssertEqual(service.status.state, .listening)
        XCTAssertEqual(service.status.port, code.port)
        XCTAssertEqual(advertiser.active.count, 1)
        _ = try await client.hello()

        // Withdrawn again, then offline.
        await service.setNetworkApproved(FakeNetworkSource.loopback(.publicNetwork), false)
        let afterWithdrawal = await isListening(code.port)
        XCTAssertFalse(afterWithdrawal)
        networks.set([])
        await service.refresh()
        XCTAssertEqual(service.status.state, .offline)
        XCTAssertTrue(advertiser.active.isEmpty)
    }

    func testOnlyTrustedInterfaces_AreListenedOnAndAdvertised() async throws {
        let other = FakeNetworkSource.loopback(.publicNetwork, address: .ipv6(.loopback), index: 2, id: "{public}")
        networks.set([FakeNetworkSource.loopback(), other])
        let opened = await service.openPairing()
        let code = try XCTUnwrap(opened)
        XCTAssertEqual(hosts(service.status.endpoints), ["127.0.0.1"])
        XCTAssertEqual(advertiser.active.keys.sorted(), [1])
        let onOther = await isListening(code.port, .ipv6(.loopback))
        XCTAssertFalse(onOther)

        await service.setNetworkApproved(other, true)
        XCTAssertEqual(hosts(service.status.endpoints), ["127.0.0.1", "::1"])
        XCTAssertEqual(advertiser.active.keys.sorted(), [1, 2])
        XCTAssertEqual(service.status.endpoints.count, 2)
        for endpoint in service.status.endpoints {
            XCTAssertEqual(CompanionHostStatus.port(of: [endpoint]), code.port)
        }
    }

    func testResetPairing_ChangesTheKeyAndUnpairsEveryone() async throws {
        _ = try await pairedPhone()
        let before = try service.fingerprint()
        try await service.resetPairing()
        XCTAssertTrue(service.devices.devices.isEmpty)
        XCTAssertNotEqual(try service.fingerprint(), before)
        XCTAssertEqual(service.status.state, .off)
        let opened = await service.openPairing()
        let code = try XCTUnwrap(opened)
        // The old pin no longer connects.
        do {
            _ = try await phone(code, pin: before).health()
            XCTFail("The old pin was taken.")
        } catch CompanionClientError.wrongCertificate {
        } catch {
            XCTFail("\(error)")
        }
    }

    func testAPhoneWaitingForTheAnswer_KeepsTheHostListening() async throws {
        let answer = Guarded<Bool?>(nil)
        service.router.approvePairing = { _ in
            while answer.value == nil && !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            return answer.value ?? false
        }
        let opened = await service.openPairing()
        let code = try XCTUnwrap(opened)
        let client = try phone(code)
        let pairing = Task { try await self.pair(client, code) }
        try await waitUntil { service.awaitingApproval && service.pairing == nil }
        // The session is used, and the code's five minutes run out while the user reads the question;
        // refreshes (the code's timer, a network change) keep listening for the phone.
        clock.value = clock.value.addingTimeInterval(PairingSession.lifetime + 60)
        await service.refresh()
        networks.set([FakeNetworkSource.loopback()])
        await service.refresh()
        XCTAssertEqual(service.status.state, .listening)
        XCTAssertTrue(service.snapshot().pairingOpen)
        answer.value = true
        _ = try await pairing.value
        XCTAssertFalse(service.awaitingApproval)
        XCTAssertEqual(service.devices.count, 1)
        XCTAssertEqual(service.status.state, .listening)
    }

    func testADeclinedPhone_StopsTheListeningItKeptUp() async throws {
        let answer = Guarded<Bool?>(nil)
        service.router.approvePairing = { _ in
            while answer.value == nil && !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            return answer.value ?? false
        }
        let opened = await service.openPairing()
        let code = try XCTUnwrap(opened)
        let client = try phone(code)
        let pairing = Task { try await self.pair(client, code) }
        try await waitUntil { service.awaitingApproval }
        answer.value = false
        do {
            _ = try await pairing.value
            XCTFail("A declined phone was paired.")
        } catch CompanionClientError.refused(let status, let error) {
            XCTAssertEqual(status, 403)
            XCTAssertEqual(error.code, CompanionErrorCode.declined)
        }
        // Nothing is wanted any more: no phone, the code used.
        try await waitUntil { service.status.state == .off }
        XCTAssertTrue(advertiser.active.isEmpty)
        let listening = await isListening(code.port)
        XCTAssertFalse(listening)
    }

    func testOpenPairing_WithoutATrustedNetwork_LeavesNoSessionOpen() async throws {
        networks.set([FakeNetworkSource.loopback(.publicNetwork)])
        let refused = await service.openPairing()
        XCTAssertNil(refused)
        // The status keeps the reason for the window, and no session waits for a code nobody saw.
        XCTAssertEqual(service.status.state, .noTrustedNetwork)
        XCTAssertNil(service.pairing)
        XCTAssertFalse(service.snapshot().pairingOpen)
        // Allowing the network later starts nothing: no code is shown, no phone is paired.
        let saved = await service.setNetworkApproved(FakeNetworkSource.loopback(.publicNetwork), true)
        XCTAssertTrue(saved)
        XCTAssertEqual(service.status.state, .off)
        XCTAssertTrue(advertiser.active.isEmpty)
        XCTAssertTrue(service.status.endpoints.isEmpty)
        // Pairing again now shows a code.
        let code = await service.openPairing()
        XCTAssertNotNil(code)
    }

    func testResetPairing_WithoutANewKey_ChangesNothing() async throws {
        let client = try await pairedPhone().client
        let before = try service.fingerprint()
        identity.renewFails = true
        do {
            try await service.resetPairing()
            XCTFail("Pairing was reset without a new key.")
        } catch is SelfSignedCertificateError {
        }
        XCTAssertEqual(service.devices.count, 1)
        XCTAssertEqual(try service.fingerprint(), before)
        _ = try await client.hello()
    }
}

/// The code's addresses and name, apart from the host's cases so they run where the keychain cannot.
final class CompanionCodeTests: XCTestCase {
    func testCodeAddresses_IPv4First_WithoutLinkLocal() throws {
        let port: NWEndpoint.Port = 52731
        let endpoints: [NWEndpoint] = [
            .hostPort(host: .ipv6(try XCTUnwrap(IPv6Address("fd00::5"))), port: port),
            .hostPort(host: .ipv6(try XCTUnwrap(IPv6Address("fe80::1"))), port: port),
            .hostPort(host: .ipv4(try XCTUnwrap(IPv4Address("192.168.1.20"))), port: port),
            .hostPort(host: .ipv4(try XCTUnwrap(IPv4Address("192.168.1.20"))), port: port),
        ]
        XCTAssertEqual(CompanionService.codeAddresses(endpoints), ["192.168.1.20", "fd00::5"])
        XCTAssertEqual(CompanionService.pairingName("  "), "Computer")
        XCTAssertEqual(CompanionService.pairingName("Aytu's Mac"), "Aytu's Mac")
    }
}
