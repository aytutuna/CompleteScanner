import Foundation

// Twin of windows/CompleteScanner.Core/Escl/EsclEndpoint.cs: the same grouping and address order.

/// One DNS-SD service instance of a network scanner, as the operating system reports it: _uscan._tcp
/// (`secure` false) or _uscans._tcp (true).
public struct EsclService: Equatable, Sendable {
    /// The system's id for the service instance.
    public var id: String
    /// e.g. "HP Color LaserJet MFP M479fdw (A1B2C3)".
    public var instanceName: String
    public var secure: Bool
    /// e.g. "HPA1B2C3.local"; nil when not reported.
    public var hostName: String?
    /// IP addresses as text, e.g. "192.168.1.20", "fe80::1%12" or "fe80::1%en0" (the zone as an interface
    /// index or name; an address whose zone names no interface here is skipped).
    public var addresses: [String]
    public var port: Int
    /// TXT record entries ("key=value").
    public var textAttributes: [String]

    public init(id: String, instanceName: String, secure: Bool, hostName: String?, addresses: [String], port: Int,
                textAttributes: [String]) {
        self.id = id
        self.instanceName = instanceName
        self.secure = secure
        self.hostName = hostName
        self.addresses = addresses
        self.port = port
        self.textAttributes = textAttributes
    }
}

/// A discovered network scanner: its _uscan and _uscans services merged, with the addresses to
/// connect through in the order to try them.
public struct EsclEndpoint: Equatable, Sendable {
    /// "uuid:" + `EsclTxtRecord.uuidKey`, or "name:" + the instance name (lowercase) without a UUID.
    public var key: String
    /// The model from the TXT record, else the service instance name.
    public var name: String
    /// The TXT record of the first service (the secure one when both are advertised).
    public var txt: EsclTxtRecord
    /// Where to connect, best first: every HTTPS address before every HTTP one, and within each, IPv4
    /// addresses, then the host name, then IPv6 addresses.
    public var addresses: [ScannerAddress]

    public init(key: String, name: String, txt: EsclTxtRecord, addresses: [ScannerAddress]) {
        self.key = key
        self.name = name
        self.txt = txt
        self.addresses = addresses
    }

    /// The device UUID from the TXT record, as advertised; nil when there is none.
    public var uuid: String? { txt.uuid }

    /// One service with its TXT record read.
    private struct Entry {
        let service: EsclService
        let txt: EsclTxtRecord
    }

    /// The services of one device.
    private struct Group {
        let key: String
        var members: [Entry]
    }

    /// Groups services by device (TXT UUID; services without one by instance name, which the _uscan
    /// and _uscans instances of one device share) and orders each device's addresses: HTTPS first (a
    /// failed TLS handshake falls back to the HTTP ones), IPv4 before the .local host name (which needs
    /// another lookup), IPv6 last. IPv6 link-local addresses without a zone cannot be connected to and
    /// are skipped. Devices keep the order their first service was listed in; devices left without an
    /// address are dropped.
    public static func choose(_ services: [EsclService]) -> [EsclEndpoint] {
        var entries: [Entry] = []
        for service in services where service.port >= 1 && service.port <= 65535 {
            entries.append(Entry(service: service, txt: EsclTxtRecord.parse(service.textAttributes)))
        }
        // Instance names are compared ignoring case.
        var uuidByInstance: [String: String] = [:]
        for entry in entries {
            let instance: String = entry.service.instanceName.lowercased()
            if let uuid = EsclTxtRecord.uuidKey(entry.txt.uuid), uuidByInstance[instance] == nil {
                uuidByInstance[instance] = uuid
            }
        }

        var groups: [Group] = []
        for entry in entries {
            let key: String
            if let uuid = EsclTxtRecord.uuidKey(entry.txt.uuid) {
                key = "uuid:" + uuid
            } else if let shared = uuidByInstance[entry.service.instanceName.lowercased()] {
                key = "uuid:" + shared
            } else {
                key = "name:" + entry.service.instanceName.lowercased()
            }
            if let index = groups.firstIndex(where: { $0.key == key }) {
                groups[index].members.append(entry)
            } else {
                groups.append(Group(key: key, members: [entry]))
            }
        }

        var endpoints: [EsclEndpoint] = []
        for group in groups {
            // Secure first, otherwise in the order listed.
            var ordered: [Entry] = []
            for member in group.members where member.service.secure {
                ordered.append(member)
            }
            for member in group.members where !member.service.secure {
                ordered.append(member)
            }
            var addresses: [ScannerAddress] = []
            for member in ordered {
                for host in hosts(member.service) {
                    guard let address = ScannerAddress.create(secure: member.service.secure, host: host,
                                                              port: member.service.port,
                                                              resourcePath: member.txt.resourcePath) else { continue }
                    if !addresses.contains(address) {
                        addresses.append(address)
                    }
                }
            }
            if addresses.isEmpty {
                continue
            }
            let first: Entry = ordered[0]
            var name: String = first.service.instanceName
            for member in ordered {
                if let model = member.txt.model {
                    name = model
                    break
                }
            }
            endpoints.append(EsclEndpoint(key: group.key, name: name, txt: first.txt, addresses: addresses))
        }
        return endpoints
    }

    /// One service's hosts to try: IPv4 addresses, the host name, then usable IPv6 addresses.
    private static func hosts(_ service: EsclService) -> [String] {
        var v4: [String] = []
        var v6: [String] = []
        for text in service.addresses {
            let trimmed: String = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.contains(":") {
                guard let ip = EsclHostText.ipv6(trimmed) else { continue }
                if ip.isLinkLocal && ip.zone == 0 {
                    continue
                }
                v6.append(ip.text)
            } else if let ip = EsclHostText.ipv4(trimmed) {
                v4.append(ip)
            }
        }
        var hosts: [String] = v4
        if let hostName = service.hostName {
            let trimmed: String = hostName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                hosts.append(trimmed)
            }
        }
        hosts.append(contentsOf: v6)
        return hosts
    }
}
