#if os(macOS)
import CompleteScannerKit
import Darwin
import Foundation
import Network
import SystemConfiguration

// Twin of windows/LazyScan.App/Services/Companion/WindowsNetworkSource.cs on the Mac's own
// interfaces (getifaddrs), since macOS has no network list with categories.

/// The networks this Mac is on: each IPv4 subnet of an interface that is up and running is a network
/// of its own, identified by the interface's BSD name, the subnet and the network signature of the
/// interface's IPv4 service ("en0 192.168.1.0/24 IPv4.Router=192.168.1.1;IPv4.RouterHardwareAddress=…",
/// so another network handing out the same subnet is another network) and named by the interface's
/// display name ("Wi-Fi (192.168.1.0/24)"). Each is its own adapter too, so an untrusted subnet on the
/// same interface does not shut out the approved one. Loopback interfaces and link-local
/// addresses (169.254/16) never count. There are no categories (`.publicNetwork`), so every network
/// needs the user's approval once. Changes are seen from `NWPathMonitor` and a check every
/// `pollInterval`, as on Windows. Only reads; never changes a network setting.
final class MacNetworkSource: CompanionNetworkSource, @unchecked Sendable {
    static let pollInterval: TimeInterval = 15

    private let queue = DispatchQueue(label: "MacNetworkSource")
    private var handler: (() -> Void)?
    private var monitor: NWPathMonitor?
    private var timer: DispatchSourceTimer?
    private var last: [CompanionNetwork] = []

    /// Following starts when the host sets it and stops when it is cleared.
    var onChange: (() -> Void)? {
        get { queue.sync { handler } }
        set {
            queue.sync {
                handler = newValue
                if newValue == nil {
                    stop()
                } else {
                    start()
                }
            }
        }
    }

    func networks() -> [CompanionNetwork] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return [] }
        defer { freeifaddrs(first) }
        let names = MacNetworkSource.displayNames()
        let signatures = MacNetworkSource.signatures()
        var found: [CompanionNetwork] = []
        var cursor = first
        while let entry = cursor {
            cursor = entry.pointee.ifa_next
            let flags = Int32(bitPattern: entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0,
                  let address = entry.pointee.ifa_addr, let mask = entry.pointee.ifa_netmask,
                  address.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            let bytes = MacNetworkSource.ipv4Bytes(address)
            let maskBytes = MacNetworkSource.ipv4Bytes(mask)
            guard !(bytes[0] == 169 && bytes[1] == 254), let ipv4 = IPv4Address(Data(bytes)) else { continue }
            var prefix = 0
            var subnet: [UInt8] = []
            for i in 0..<4 {
                prefix += maskBytes[i].nonzeroBitCount
                subnet.append(bytes[i] & maskBytes[i])
            }
            let bsdName = String(cString: entry.pointee.ifa_name)
            var parts: [String] = []
            for byte in subnet {
                parts.append(String(byte))
            }
            let range = "\(parts.joined(separator: "."))/\(prefix)"
            // Without the router's signature (no router, or the system has not published it yet) the
            // network has no id, so it cannot be approved: an approval must never carry over to another
            // network on the same interface and subnet.
            let id: String = signatures[bsdName].map { "\(bsdName) \(range) \($0)" } ?? ""
            let adapter = CompanionNetworkInterface(index: Int(if_nametoindex(entry.pointee.ifa_name)), adapterId: "\(bsdName) \(range)",
                                                    addresses: [LocalSubnet(address: .ipv4(ipv4), prefixLength: prefix)])
            found.append(CompanionNetwork(id: id, name: "\(names[bsdName] ?? bsdName) (\(range))",
                                          category: .publicNetwork, interfaces: [adapter]))
        }
        return found
    }

    /// Starts following (on the queue).
    private func start() {
        guard monitor == nil else { return }
        last = networks()
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] (_: NWPath) in
            guard let self else { return }
            self.check()
            // Addresses can come a moment after the path changed.
            self.queue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.check() }
        }
        monitor.start(queue: queue)
        self.monitor = monitor
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + MacNetworkSource.pollInterval, repeating: MacNetworkSource.pollInterval)
        timer.setEventHandler { [weak self] in self?.check() }
        timer.resume()
        self.timer = timer
    }

    private func stop() {
        monitor?.cancel()
        monitor = nil
        timer?.cancel()
        timer = nil
    }

    /// Tells the host when the networks are not what they were (on the queue).
    private func check() {
        let now = networks()
        guard now != last else { return }
        last = now
        handler?()
    }

    private static func ipv4Bytes(_ address: UnsafeMutablePointer<sockaddr>) -> [UInt8] {
        let raw: in_addr = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
            (pointer: UnsafeMutablePointer<sockaddr_in>) -> in_addr in
            pointer.pointee.sin_addr
        }
        return withUnsafeBytes(of: raw) { (buffer: UnsafeRawBufferPointer) -> [UInt8] in
            Array(buffer)
        }
    }

    /// The NetworkSignature of each IPv4 service by BSD name (the router's address and hardware address);
    /// missing until the router is known, and on a network without one.
    private static func signatures() -> [String: String] {
        var found: [String: String] = [:]
        guard let store = SCDynamicStoreCreate(nil, "CompleteScanner" as CFString, nil, nil) else { return found }
        let pattern = SCDynamicStoreKeyCreateNetworkServiceEntity(nil, kSCDynamicStoreDomainState, kSCCompAnyRegex, kSCEntNetIPv4)
        guard let values = SCDynamicStoreCopyMultiple(store, nil, [pattern] as CFArray) as? [String: Any] else { return found }
        for value in values.values {
            guard let entity = value as? [String: Any], let bsdName = entity[kSCPropInterfaceName as String] as? String,
                  let signature = entity["NetworkSignature"] as? String, !signature.isEmpty else { continue }
            found[bsdName] = signature
        }
        return found
    }

    /// "Wi-Fi", "Ethernet", "Thunderbolt Bridge" by BSD name.
    private static func displayNames() -> [String: String] {
        var names: [String: String] = [:]
        guard let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return names }
        for interface in interfaces {
            guard let bsdName = SCNetworkInterfaceGetBSDName(interface) as String?,
                  let name = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String? else { continue }
            names[bsdName] = name
        }
        return names
    }
}
#endif
