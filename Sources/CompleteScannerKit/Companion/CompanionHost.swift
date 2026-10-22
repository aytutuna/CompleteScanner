import Foundation
import Network
import Security

// Twin of windows/CompleteScanner.Core/Companion/CompanionHost.cs: the server started, moved and
// stopped as the networks change, and advertised by DNS-SD only on the trusted networks' interfaces.
// The Mac fills in the network source (its interfaces), the advertiser (dnssd) and the identity (the
// keychain); the tests give stand-ins. C# events are closures here, as in `CompanionRouter`.

/// The networks this computer is connected to, and when they change (the Mac: its interfaces).
public protocol CompanionNetworkSource: AnyObject {
    /// The connected networks with their interfaces. Any thread; empty when unknown.
    func networks() -> [CompanionNetwork]
    /// Called (on any thread) when a network connects, disconnects or changes its addresses. Set by the host.
    var onChange: (() -> Void)? { get set }
}

/// A DNS-SD service to advertise on one interface. The host's own name and addresses are the
/// system's (C# also carries the host record, which Windows registers itself).
public struct DnsSdRegistration: Equatable {
    /// The service instance's name (the computer's name).
    public var instanceName: String
    public var port: Int
    /// The interface to advertise on, and only there.
    public var interfaceIndex: Int
    public var txt: [String: String]

    public var serviceType: String { CompanionProtocol.serviceType }

    public init(instanceName: String, port: Int, interfaceIndex: Int, txt: [String: String]) {
        self.instanceName = instanceName
        self.port = port
        self.interfaceIndex = interfaceIndex
        self.txt = txt
    }
}

/// Advertises the companion service by DNS-SD (the Mac: DNSServiceRegister); tests stand in for it.
public protocol DnsSdAdvertiser: AnyObject {
    /// Starts advertising and returns what withdraws it. Throws when the system refuses.
    func register(_ registration: DnsSdRegistration) throws -> () -> Void
}

/// Advertises nothing (phones use the address from the pairing code).
public final class NoDnsSdAdvertiser: DnsSdAdvertiser {
    public init() {}

    public func register(_ registration: DnsSdRegistration) throws -> () -> Void {
        {}
    }
}

/// What the host is doing, and on which networks.
public struct CompanionHostStatus: Equatable {
    public var state: CompanionListenState
    public var networks: [CompanionNetworkState]
    public var endpoints: [NWEndpoint]
    public var error: String?

    public static let initial = CompanionHostStatus(state: .off, networks: [], endpoints: [])

    public init(state: CompanionListenState, networks: [CompanionNetworkState], endpoints: [NWEndpoint], error: String? = nil) {
        self.state = state
        self.networks = networks
        self.endpoints = endpoints
        self.error = error
    }

    /// The port listened on; 0 when not listening.
    public var port: Int { CompanionHostStatus.port(of: endpoints) }

    /// The first endpoint's port; 0 for none.
    public static func port(of endpoints: [NWEndpoint]) -> Int {
        guard let first = endpoints.first, case .hostPort(_, let port) = first else { return 0 }
        return Int(port.rawValue)
    }
}

/// How the host listens and advertises.
public struct CompanionHostOptions {
    /// The port tried first (after the one used last); 0 lets the system pick.
    public var preferredPort = CompanionProtocol.defaultPort
    public var instanceName = "CompleteScanner"
    /// The desktop's id for the TXT record, asked for when advertising starts.
    public var desktopId: () -> String = { "" }
    public var server = CompanionServerOptions()
    /// The clock the server's rate limits read (the router's).
    public var clock: () -> Date = { Date() }

    public init() {}
}

/// Starts and stops the companion server as the networks change: it listens only while it is wanted
/// (a phone is paired, or a pairing code is shown) and only on the addresses of trusted networks
/// (`TrustedNetworkPolicy`), and advertises by DNS-SD only on those networks' interfaces and only
/// while listening. When the last trusted network goes away (or is no longer approved) the server
/// stops and every advertisement is withdrawn. Refreshes run one at a time; call `refresh` whenever
/// something it depends on changed. Safe to use from any thread.
public final class CompanionHost: @unchecked Sendable {
    private let identity: () throws -> SecIdentity
    private let router: CompanionRouter
    private let limiter: CompanionRateLimiter
    private let source: CompanionNetworkSource
    private let isApproved: (String) -> Bool
    private let advertiser: DnsSdAdvertiser
    private let wanted: () -> Bool
    private let options: CompanionHostOptions
    private let lock = NSLock()
    /// The last refresh asked for; the next one waits for it.
    private var tail: Task<Void, Never>?
    private var current = CompanionHostStatus.initial
    private var advertisements: [Int: (registration: DnsSdRegistration, withdraw: () -> Void)] = [:]
    // Touched only by the refresh running.
    private var server: CompanionServer?
    private var listening: [LocalSubnet] = []
    private var lastPort = 0
    private var disposed = false

    /// - Parameters:
    ///   - identity: The server's identity; asked for each time the server starts.
    ///   - isApproved: Whether the user approved the network with this id (`TrustedNetworkStore.isApproved`).
    ///   - wanted: Whether anything needs the server now.
    public init(identity: @escaping () throws -> SecIdentity, router: CompanionRouter, limiter: CompanionRateLimiter,
                networks: CompanionNetworkSource, isApproved: @escaping (String) -> Bool, advertiser: DnsSdAdvertiser,
                wanted: @escaping () -> Bool, options: CompanionHostOptions = CompanionHostOptions()) {
        self.identity = identity
        self.router = router
        self.limiter = limiter
        source = networks
        self.isApproved = isApproved
        self.advertiser = advertiser
        self.wanted = wanted
        self.options = options
        networks.onChange = { [weak self] in
            guard let self else { return }
            Task { await self.refresh() }
        }
    }

    public var status: CompanionHostStatus {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    /// Called (on the refreshing task) when `status` changed.
    public var onStatusChange: (() -> Void)?

    /// What is advertised now, by interface (tests, diagnostics).
    public var advertised: [DnsSdRegistration] {
        lock.lock()
        defer { lock.unlock() }
        var registrations: [DnsSdRegistration] = []
        for entry in advertisements.values {
            registrations.append(entry.registration)
        }
        return registrations.sorted { $0.interfaceIndex < $1.interfaceIndex }
    }

    /// Checks the networks and what is wanted, then starts, moves or stops the server and the
    /// advertisements; `restart` starts the server afresh (a new identity).
    public func refresh(restart: Bool = false) async {
        await enqueue { await self.update(restart: restart) }
    }

    /// Stops listening and withdraws every advertisement for good.
    public func dispose() async {
        source.onChange = nil
        await enqueue {
            self.disposed = true
            await self.stopServer()
            self.updateAdvertisements([])
        }
    }

    /// Runs `work` after the refreshes asked for before it.
    private func enqueue(_ work: @escaping @Sendable () async -> Void) async {
        let task = chain(work)
        await task.value
    }

    private func chain(_ work: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        lock.lock()
        defer { lock.unlock() }
        let previous = tail
        let task = Task {
            await previous?.value
            await work()
        }
        tail = task
        return task
    }

    private func update(restart: Bool) async {
        guard !disposed else { return }
        let networks = source.networks()
        var states: [CompanionNetworkState] = []
        for network in networks {
            states.append(CompanionNetworkState(network: network, trust: TrustedNetworkPolicy.trust(network, isApproved: isApproved)))
        }
        let addresses = TrustedNetworkPolicy.listenAddresses(networks, isApproved: isApproved)
        var state: CompanionListenState
        if !wanted() {
            state = .off
        } else if networks.isEmpty {
            state = .offline
        } else if addresses.isEmpty {
            state = .noTrustedNetwork
        } else {
            state = .listening
        }
        var error: String?
        if state != .listening {
            await stopServer()
        } else if restart || server == nil || !CompanionHost.sameAddresses(listening, addresses) {
            await stopServer()
            error = await start(addresses, networks)
            if error != nil { state = .failed }
        }
        updateAdvertisements(state == .listening ? states : [])
        let status = CompanionHostStatus(state: state, networks: states, endpoints: server?.localEndpoints ?? [], error: error)
        if setStatus(status) { onStatusChange?() }
    }

    /// Starts the server on `addresses`; nil when it listens, else why not.
    private func start(_ addresses: [LocalSubnet], _ networks: [CompanionNetwork]) async -> String? {
        let served: SecIdentity
        do {
            served = try identity()
        } catch {
            return "The security certificate could not be made or read: \(CompanionHost.message(error))"
        }
        var serverOptions = options.server
        let allowed = addresses
        serverOptions.allowPeer = { TrustedNetworkPolicy.isAllowedPeer($0, listening: allowed) }
        var ports: [Int] = []
        for port in [lastPort, options.preferredPort] where port > 0 && !ports.contains(port) {
            ports.append(port)
        }
        ports.append(0)
        var failure: Error?
        for port in ports {
            let candidate = CompanionServer(identity: served, router: router, limiter: limiter, options: serverOptions,
                                            clock: options.clock)
            var endpoints: [NWEndpoint] = []
            for subnet in addresses {
                let bindPort: NWEndpoint.Port = port > 0 ? NWEndpoint.Port(rawValue: UInt16(port)) ?? .any : .any
                endpoints.append(NWEndpoint.hostPort(host: CompanionHost.scoped(subnet.address, networks), port: bindPort))
            }
            do {
                let bound = try await candidate.start(endpoints)
                server = candidate
                listening = addresses
                lastPort = CompanionHostStatus.port(of: bound)
                return nil
            } catch {
                failure = error
                guard case .posix(let code)? = error as? NWError, code == .EADDRINUSE || code == .EACCES else { break }
            }
        }
        if case .unusableIdentity? = failure as? CompanionServerError {
            return "The security certificate cannot be used to receive from phones."
        }
        return "macOS did not let CompleteScanner listen for phones (\(failure.map(CompanionHost.message) ?? "unknown error"))."
    }

    /// `address` scoped to the interface of its adapter, so the server answers only what comes in there.
    private static func scoped(_ address: NWEndpoint.Host, _ networks: [CompanionNetwork]) -> NWEndpoint.Host {
        guard address != .ipv4(.loopback) && address != .ipv6(.loopback) else { return address }
        for network in networks {
            for adapter in network.interfaces where adapter.index > 0 && adapter.addresses.contains(where: { $0.address == address }) {
                var name: [CChar] = [CChar](repeating: 0, count: Int(IF_NAMESIZE) + 1)
                guard if_indextoname(UInt32(adapter.index), &name) != nil,
                      let interface = IPv4Address("0.0.0.0%" + String(cString: name))?.interface else { return address }
                switch address {
                case .ipv4(let ip):
                    return IPv4Address(ip.rawValue, interface).map { NWEndpoint.Host.ipv4($0) } ?? address
                case .ipv6(let ip):
                    return IPv6Address(ip.rawValue, interface).map { NWEndpoint.Host.ipv6($0) } ?? address
                default:
                    return address
                }
            }
        }
        return address
    }

    private func stopServer() async {
        guard let running = server else { return }
        server = nil
        listening = []
        await running.stop()
    }

    /// Advertises on each interface of a trusted network (and withdraws everything else).
    private func updateAdvertisements(_ states: [CompanionNetworkState]) {
        var wanted: [Int: DnsSdRegistration] = [:]
        let port = CompanionHostStatus.port(of: server?.localEndpoints ?? [])
        if port > 0 {
            let txt = [CompanionProtocol.txtVersionKey: String(CompanionProtocol.version),
                       CompanionProtocol.txtIdKey: options.desktopId()]
            var untrusted: Set<String> = []
            for state in states where state.trust == .notTrusted {
                for adapter in state.network.interfaces {
                    untrusted.insert(adapter.adapterId)
                }
            }
            for state in states where state.trust != .notTrusted {
                for adapter in state.network.interfaces
                where !untrusted.contains(adapter.adapterId) && adapter.index > 0 && wanted[adapter.index] == nil {
                    wanted[adapter.index] = DnsSdRegistration(instanceName: options.instanceName, port: port,
                                                              interfaceIndex: adapter.index, txt: txt)
                }
            }
        }
        lock.lock()
        defer { lock.unlock() }
        for (index, entry) in advertisements where wanted[index] != entry.registration {
            advertisements.removeValue(forKey: index)
            entry.withdraw()
        }
        for (index, registration) in wanted where advertisements[index] == nil {
            // When this fails, phones still find the desktop by the address from the pairing code.
            if let withdraw = try? advertiser.register(registration) {
                advertisements[index] = (registration, withdraw)
            }
        }
    }

    private func setStatus(_ status: CompanionHostStatus) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard status != current else { return false }
        current = status
        return true
    }

    private static func sameAddresses(_ a: [LocalSubnet], _ b: [LocalSubnet]) -> Bool {
        var left: Set<[UInt8]> = []
        for subnet in a {
            left.insert(LocalSubnet.bytes(subnet.address) ?? [])
        }
        var right: Set<[UInt8]> = []
        for subnet in b {
            right.insert(LocalSubnet.bytes(subnet.address) ?? [])
        }
        return left == right
    }

    static func message(_ error: Error) -> String {
        if let error = error as? SelfSignedCertificateError { return error.message }
        return error.localizedDescription
    }
}
