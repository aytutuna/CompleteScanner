import Foundation
import Network

// Twin of the pure parts of windows/CompleteScanner.Core/Companion/CompanionNetworks.cs: the networks
// approved for receiving (companion-networks.json), the addresses listened on and the peers answered.
// Windows fills `CompanionNetwork` from the Network List Manager; the Mac fills it from its own
// interfaces and has no categories (see `CompanionNetworkCategory`).

/// How the system treats a network (Windows: NLM_NETWORK_CATEGORY). A system without categories
/// reports `.publicNetwork`, so only the networks the user approved are received on.
public enum CompanionNetworkCategory: String, Equatable, Sendable {
    case publicNetwork
    case privateNetwork
    /// A work network whose domain Windows has authenticated.
    case domainNetwork
}

/// One address of an interface and the length of its subnet's prefix.
public struct LocalSubnet: Equatable {
    public var address: NWEndpoint.Host
    public var prefixLength: Int

    public init(address: NWEndpoint.Host, prefixLength: Int) {
        self.address = address
        self.prefixLength = prefixLength
    }

    /// Whether `other` is in this subnet.
    public func contains(_ other: NWEndpoint.Host) -> Bool {
        guard let a = LocalSubnet.bytes(other), let b = LocalSubnet.bytes(address), a.count == b.count else { return false }
        var bits = min(max(prefixLength, 0), a.count * 8)
        var i = 0
        while i < a.count && bits > 0 {
            let mask: UInt8 = bits >= 8 ? 0xFF : UInt8(truncatingIfNeeded: 0xFF << (8 - bits))
            if a[i] & mask != b[i] & mask { return false }
            i += 1
            bits -= 8
        }
        return true
    }

    /// The address's bytes (4 or 16), an IPv4-mapped IPv6 address as its IPv4 address; nil for a name.
    static func bytes(_ host: NWEndpoint.Host) -> [UInt8]? {
        switch host {
        case .ipv4(let address):
            return [UInt8](address.rawValue)
        case .ipv6(let address):
            let b = [UInt8](address.rawValue)
            if b.count == 16 && b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xFF && b[11] == 0xFF {
                return Array(b[12..<16])
            }
            return b
        default:
            return nil
        }
    }
}

/// A network adapter of a connected network: its interface index and addresses.
public struct CompanionNetworkInterface: Equatable {
    public var index: Int
    /// What identifies the adapter across networks (Windows: its GUID; the Mac: the network's id, since
    /// each subnet of an interface is a network of its own there).
    public var adapterId: String
    public var addresses: [LocalSubnet]

    public init(index: Int, adapterId: String, addresses: [LocalSubnet]) {
        self.index = index
        self.adapterId = adapterId
        self.addresses = addresses
    }
}

/// A connected network as the system names and categorizes it, with its adapters.
public struct CompanionNetwork: Equatable {
    /// What identifies the network while the system remembers it (Windows: the Network List Manager's id).
    public var id: String
    /// Its name ("Home Wi-Fi", "eduroam").
    public var name: String
    public var category: CompanionNetworkCategory
    public var interfaces: [CompanionNetworkInterface]

    public init(id: String, name: String, category: CompanionNetworkCategory, interfaces: [CompanionNetworkInterface]) {
        self.id = id
        self.name = name
        self.category = category
        self.interfaces = interfaces
    }
}

/// Why the desktop receives on a network, or that it does not.
public enum NetworkTrust: String, Equatable, Sendable {
    /// A public or work network the user has not approved: nothing listens or is advertised there.
    case notTrusted
    /// The system treats it as private.
    case privateNetwork
    /// The user chose "Allow receiving on this network".
    case approved
}

/// A network the user approved for receiving (an entry of companion-networks.json).
public struct ApprovedNetwork: Codable, Equatable, Sendable {
    public var id = ""
    /// Its name when approved, for people reading the file and the list in the app.
    public var name = ""
    public var approved: Date?

    enum CodingKeys: String, CodingKey {
        case id, name, approved
    }

    public init() {}
}

extension ApprovedNetwork {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        id = c.decodeLenient(forKey: .id, default: id)
        name = c.decodeLenient(forKey: .name, default: name)
        approved = c.decodeLenient(forKey: .approved, default: approved)
    }
}

/// The contents of companion-networks.json.
public struct ApprovedNetworksFile: Codable, Equatable, Sendable {
    public var networks: [ApprovedNetwork] = []

    enum CodingKeys: String, CodingKey {
        case networks
    }

    public init() {}
}

extension ApprovedNetworksFile {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        networks = c.decodeLenient(forKey: .networks, default: networks)
    }
}

/// The networks the user approved for receiving from phones (companion-networks.json in the
/// settings folder, rule 6 of CONTRACTS.md), by `CompanionNetwork.id`. Re-read for every check, so
/// another window's change counts at once. Safe to use from any thread.
public final class TrustedNetworkStore: @unchecked Sendable {
    public static let fileName = "companion-networks.json"

    private let url: URL
    private let lock = NSLock()
    private var file: ApprovedNetworksFile
    /// Approvals withdrawn in this session: never trusted again, whatever the file says.
    private var revoked: Set<String> = []

    /// Called (on the thread that changed it) after a network was approved or its approval withdrawn.
    public var onChange: (() -> Void)?

    public convenience init() {
        self.init(directory: StoreFiles.defaultDirectory)
    }

    public init(directory: URL) {
        url = directory.appendingPathComponent(TrustedNetworkStore.fileName)
        file = StoreFiles.load(ApprovedNetworksFile.self, from: url) ?? ApprovedNetworksFile()
    }

    public var approved: [ApprovedNetwork] {
        lock.lock()
        defer { lock.unlock() }
        reload()
        return file.networks.filter { !revoked.contains($0.id) }
    }

    public func isApproved(_ networkId: String) -> Bool {
        guard !networkId.isEmpty else { return false }
        lock.lock()
        defer { lock.unlock() }
        reload()
        return !revoked.contains(networkId) && file.networks.contains { $0.id == networkId }
    }

    /// Approves `network` for receiving; false when that could not be saved (it is not approved then).
    @discardableResult
    public func approve(_ network: CompanionNetwork, now: Date) -> Bool {
        guard !network.id.isEmpty else { return false }
        lock.lock()
        reload()
        let previous = file.networks
        var entry = ApprovedNetwork()
        entry.id = network.id
        entry.name = network.name
        entry.approved = now
        file.networks = previous.filter { $0.id != network.id } + [entry]
        guard StoreFiles.write(file, to: url) else {
            file.networks = previous
            lock.unlock()
            return false
        }
        revoked.remove(network.id)
        lock.unlock()
        onChange?()
        return true
    }

    /// Withdraws the approval of `networkId`; it holds for this session even when the file cannot be written.
    public func revoke(_ networkId: String) {
        lock.lock()
        reload()
        revoked.insert(networkId)
        let before = file.networks.count
        file.networks.removeAll { $0.id == networkId }
        if file.networks.count != before { StoreFiles.write(file, to: url) }
        lock.unlock()
        onChange?()
    }

    /// Re-reads the file (with the lock held); an unreadable one keeps what was loaded.
    private func reload() {
        file = StoreFiles.load(ApprovedNetworksFile.self, from: url) ?? file
    }
}

/// The rule for which networks the desktop receives on, and which peers it answers.
public enum TrustedNetworkPolicy {
    /// Private networks are trusted; any other (public, or a work domain network) only when the user
    /// approved it by its id.
    public static func trust(_ network: CompanionNetwork, isApproved: (String) -> Bool) -> NetworkTrust {
        if network.category == .privateNetwork { return .privateNetwork }
        return !network.id.isEmpty && isApproved(network.id) ? .approved : .notTrusted
    }

    /// The addresses to listen on: every address of every adapter of a trusted network, never one of
    /// an untrusted network (an adapter shared by both is left out). Each address once, IPv4 first.
    public static func listenAddresses(_ networks: [CompanionNetwork], isApproved: (String) -> Bool) -> [LocalSubnet] {
        var untrustedAdapters: Set<String> = []
        for network in networks where trust(network, isApproved: isApproved) == .notTrusted {
            for adapter in network.interfaces {
                untrustedAdapters.insert(adapter.adapterId)
            }
        }
        var addresses: [LocalSubnet] = []
        for network in networks where trust(network, isApproved: isApproved) != .notTrusted {
            for adapter in network.interfaces where !untrustedAdapters.contains(adapter.adapterId) {
                for subnet in adapter.addresses where !addresses.contains(where: { $0.address == subnet.address }) {
                    addresses.append(subnet)
                }
            }
        }
        let ipv4 = addresses.filter { LocalSubnet.bytes($0.address)?.count == 4 }
        let others = addresses.filter { LocalSubnet.bytes($0.address)?.count != 4 }
        return ipv4 + others
    }

    /// Whether a connection from `remote` is answered: from this computer, a private, link-local,
    /// shared (100.64.0.0/10) or unique-local address, or an address in the subnet of an address the
    /// desktop listens on (networks that give their devices public addresses). Anything else is closed
    /// before TLS starts.
    public static func isAllowedPeer(_ remote: NWEndpoint.Host, listening: [LocalSubnet]) -> Bool {
        isLocalAddress(remote) || listening.contains { $0.contains(remote) }
    }

    /// Loopback, RFC 1918, link-local, shared address space, unique-local.
    public static func isLocalAddress(_ remote: NWEndpoint.Host) -> Bool {
        guard let b = LocalSubnet.bytes(remote) else { return false }
        if b.count == 4 {
            return b[0] == 127
                || b[0] == 10
                || (b[0] == 172 && (b[1] & 0xF0) == 16)
                || (b[0] == 192 && b[1] == 168)
                || (b[0] == 169 && b[1] == 254)
                || (b[0] == 100 && (b[1] & 0xC0) == 64)
        }
        if b.count == 16 {
            let loopback = b[0..<15].allSatisfy { $0 == 0 } && b[15] == 1
            return loopback || (b[0] == 0xFE && (b[1] & 0xC0) == 0x80) || (b[0] & 0xFE) == 0xFC
        }
        return false
    }
}
