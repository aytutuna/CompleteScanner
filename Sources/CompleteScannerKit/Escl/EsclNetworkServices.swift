import Darwin
import Foundation
import Network
import dnssd

// The system's side of EsclDiscovery on Apple platforms: NWBrowser for each service type, with the TXT
// records (`.bonjourWithTXTRecord`), and the DNS-SD C API (dnssd: DNSServiceResolve for the host and port,
// then DNSServiceGetAddrInfo for every IPv4 and IPv6 address, the interface as the zone of a link-local
// one), which NWConnection cannot give (it reaches one address). Both only look: nothing is registered or
// advertised. Neither is ever made by a test (tests pass stand-ins to EsclDiscovery); the app makes them
// only once the user has seen the Local Network explanation, and never under -demoScanner.

/// NWBrowser for _uscan._tcp or _uscans._tcp, peer-to-peer off, on the main queue.
@MainActor
public final class EsclNWBrowser: EsclServiceBrowsing {
    public let secure: Bool
    public var onStatus: ((EsclBrowserStatus) -> Void)?
    public var onResults: (([EsclBrowseResult]) -> Void)?
    private var browser: NWBrowser?

    public init(secure: Bool) {
        self.secure = secure
    }

    public func start() {
        guard browser == nil else { return }
        let type: String = secure ? "_uscans._tcp" : "_uscan._tcp"
        let parameters: NWParameters = NWParameters()
        parameters.includePeerToPeer = false
        let descriptor: NWBrowser.Descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(type: type, domain: nil)
        let made: NWBrowser = NWBrowser(for: descriptor, using: parameters)
        made.stateUpdateHandler = { [weak self] (state: NWBrowser.State) -> Void in
            let status: EsclBrowserStatus = EsclNWBrowser.status(of: state)
            MainActor.assumeIsolated {
                self?.onStatus?(status)
            }
        }
        made.browseResultsChangedHandler = { [weak self] (results: Set<NWBrowser.Result>, _: Set<NWBrowser.Result.Change>) -> Void in
            let found: [EsclBrowseResult] = EsclNWBrowser.browseResults(results)
            MainActor.assumeIsolated {
                self?.onResults?(found)
            }
        }
        browser = made
        made.start(queue: DispatchQueue.main)
    }

    public func cancel() {
        guard let running = browser else { return }
        browser = nil
        running.stateUpdateHandler = nil
        running.browseResultsChangedHandler = nil
        running.cancel()
    }

    /// A browser's state as `EsclBrowserStatus`, with the DNS-SD error code when there is one.
    nonisolated static func status(of state: NWBrowser.State) -> EsclBrowserStatus {
        switch state {
        case .setup:
            return EsclBrowserStatus.setup
        case .ready:
            return EsclBrowserStatus.ready
        case .cancelled:
            return EsclBrowserStatus.cancelled
        case .waiting(let error):
            return EsclBrowserStatus.waiting(code: dnsCode(error), detail: error.debugDescription)
        case .failed(let error):
            return EsclBrowserStatus.failed(code: dnsCode(error), detail: error.debugDescription)
        @unknown default:
            return EsclBrowserStatus.setup
        }
    }

    nonisolated static func dnsCode(_ error: NWError) -> Int32? {
        if case .dns(let code) = error {
            return Int32(code)
        }
        return nil
    }

    /// The service instances in `results`, by name, with their TXT records as "key=value" in key order.
    nonisolated static func browseResults(_ results: Set<NWBrowser.Result>) -> [EsclBrowseResult] {
        var list: [EsclBrowseResult] = []
        for result in results {
            guard case .service(let name, let type, let domain, _) = result.endpoint else { continue }
            var entries: [String] = []
            if case .bonjour(let record) = result.metadata {
                let values: [String: String] = record.dictionary
                let keys: [String] = values.keys.sorted()
                for key in keys {
                    let value: String = values[key] ?? ""
                    entries.append(key + "=" + value)
                }
            }
            var interfaceIndex: Int = 0
            if let first = result.interfaces.first {
                interfaceIndex = first.index
            }
            list.append(EsclBrowseResult(name: name, type: type, domain: domain, interfaceIndex: interfaceIndex, txt: entries))
        }
        list.sort { (left: EsclBrowseResult, right: EsclBrowseResult) -> Bool in
            left.key < right.key
        }
        return list
    }
}

/// Resolves services with the DNS-SD C API: DNSServiceResolve for the host name and port, then
/// DNSServiceGetAddrInfo for every IPv4 and IPv6 address of that host. The answer comes once the first
/// address has had `settleTime` for the others to follow, or `timeout` after the start without any.
@MainActor
public final class EsclDnssdResolver: EsclServiceResolving {
    /// Gives up on a service that has not resolved by then.
    public var timeout: TimeInterval = 5
    /// After the first address, how long to wait for the others (IPv4 and IPv6 come separately).
    public var settleTime: TimeInterval = 1

    public init() {}

    public func resolve(_ result: EsclBrowseResult,
                        completion: @escaping @MainActor (EsclResolveOutcome) -> Void) -> any EsclCancellable {
        let operation: EsclDnssdResolve = EsclDnssdResolve(result: result, timeout: timeout, settleTime: settleTime,
                                                           completion: completion)
        operation.start()
        return operation
    }
}

/// The resolve's answer: the operation is kept alive (retained by hand) until it finishes, since the
/// DNS-SD callbacks only carry a raw pointer to it.
private let esclResolveReply: DNSServiceResolveReply = {
    (_: DNSServiceRef?, _: DNSServiceFlags, interfaceIndex: UInt32, error: DNSServiceErrorType,
     _: UnsafePointer<CChar>?, hostTarget: UnsafePointer<CChar>?, port: UInt16, _: UInt16,
     _: UnsafePointer<UInt8>?, context: UnsafeMutableRawPointer?) -> Void in
    guard let context else { return }
    let operation: EsclDnssdResolve = Unmanaged<EsclDnssdResolve>.fromOpaque(context).takeUnretainedValue()
    var host: String?
    if let hostTarget {
        host = String(cString: hostTarget)
    }
    let hostPort: Int = Int(UInt16(bigEndian: port))
    MainActor.assumeIsolated {
        operation.resolved(error: error, hostTarget: host, port: hostPort, interfaceIndex: interfaceIndex)
    }
}

/// An address of the host: added or removed, and whether more are coming at once.
private let esclAddressReply: DNSServiceGetAddrInfoReply = {
    (_: DNSServiceRef?, flags: DNSServiceFlags, _: UInt32, error: DNSServiceErrorType, _: UnsafePointer<CChar>?,
     address: UnsafePointer<sockaddr>?, _: UInt32, context: UnsafeMutableRawPointer?) -> Void in
    guard let context else { return }
    let operation: EsclDnssdResolve = Unmanaged<EsclDnssdResolve>.fromOpaque(context).takeUnretainedValue()
    var text: String?
    if let address {
        text = EsclDnssdResolve.text(of: address)
    }
    let added: Bool = (flags & DNSServiceFlags(kDNSServiceFlagsAdd)) != 0
    MainActor.assumeIsolated {
        operation.address(error: error, text: text, added: added)
    }
}

/// One resolve: its DNS-SD requests, on the main queue, and what they found so far.
@MainActor
final class EsclDnssdResolve: EsclCancellable {
    private let result: EsclBrowseResult
    private let timeout: TimeInterval
    private let settleTime: TimeInterval
    private var completion: (@MainActor (EsclResolveOutcome) -> Void)?
    private var resolveRef: DNSServiceRef?
    private var addressRef: DNSServiceRef?
    private var retained: Unmanaged<EsclDnssdResolve>?
    private var hostName: String?
    private var port: Int = 0
    private var addresses: [String] = []
    private var settling: Bool = false

    init(result: EsclBrowseResult, timeout: TimeInterval, settleTime: TimeInterval,
         completion: @escaping @MainActor (EsclResolveOutcome) -> Void) {
        self.result = result
        self.timeout = timeout
        self.settleTime = settleTime
        self.completion = completion
    }

    func start() {
        let unmanaged: Unmanaged<EsclDnssdResolve> = Unmanaged<EsclDnssdResolve>.passRetained(self)
        retained = unmanaged
        var ref: DNSServiceRef?
        let interfaceIndex: UInt32 = UInt32(clamping: result.interfaceIndex)
        let error: DNSServiceErrorType = DNSServiceResolve(&ref, 0, interfaceIndex, result.name, result.type, result.domain,
                                                           esclResolveReply, unmanaged.toOpaque())
        guard Int(error) == kDNSServiceErr_NoError, let started = ref else {
            finish(EsclDnssdResolve.outcome(error, doing: "resolve"))
            return
        }
        resolveRef = started
        _ = DNSServiceSetDispatchQueue(started, DispatchQueue.main)
        let wait: TimeInterval = timeout
        DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + wait) { [weak self] in
            MainActor.assumeIsolated {
                self?.timedOut()
            }
        }
    }

    func cancel() {
        completion = nil
        release()
    }

    /// The service's host and port: its addresses are asked for next.
    fileprivate func resolved(error: DNSServiceErrorType, hostTarget: String?, port: Int, interfaceIndex: UInt32) {
        guard completion != nil, addressRef == nil else { return }
        guard Int(error) == kDNSServiceErr_NoError else {
            finish(EsclDnssdResolve.outcome(error, doing: "resolve"))
            return
        }
        if let ref = resolveRef {
            resolveRef = nil
            DNSServiceRefDeallocate(ref)
        }
        guard let target = hostTarget, !target.isEmpty else {
            finish(EsclResolveOutcome.failed("no host name"))
            return
        }
        var shown: String = target
        while shown.hasSuffix(".") {
            shown.removeLast()
        }
        hostName = shown
        self.port = port
        guard let unmanaged = retained else { return }
        var ref: DNSServiceRef?
        let protocols: DNSServiceProtocol = DNSServiceProtocol(kDNSServiceProtocol_IPv4 | kDNSServiceProtocol_IPv6)
        let started: DNSServiceErrorType = DNSServiceGetAddrInfo(&ref, 0, interfaceIndex, protocols, target,
                                                                 esclAddressReply, unmanaged.toOpaque())
        guard Int(started) == kDNSServiceErr_NoError, let lookup = ref else {
            finish(EsclDnssdResolve.outcome(started, doing: "address lookup"))
            return
        }
        addressRef = lookup
        _ = DNSServiceSetDispatchQueue(lookup, DispatchQueue.main)
    }

    /// An address of the host: kept (or dropped when removed); the answer follows `settleTime` after the first.
    fileprivate func address(error: DNSServiceErrorType, text: String?, added: Bool) {
        guard completion != nil else { return }
        guard Int(error) == kDNSServiceErr_NoError else {
            if addresses.isEmpty {
                finish(EsclDnssdResolve.outcome(error, doing: "address lookup"))
            }
            return
        }
        guard let text else { return }
        if added {
            if !addresses.contains(text) {
                addresses.append(text)
            }
        } else {
            addresses.removeAll { (known: String) -> Bool in known == text }
        }
        if !addresses.isEmpty && !settling {
            settling = true
            let wait: TimeInterval = settleTime
            DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + wait) { [weak self] in
                MainActor.assumeIsolated {
                    self?.settled()
                }
            }
        }
    }

    private func settled() {
        guard completion != nil else { return }
        if addresses.isEmpty {
            finish(EsclResolveOutcome.failed("no address"))
            return
        }
        let service: EsclResolvedService = EsclResolvedService(hostName: hostName, port: port, addresses: addresses)
        finish(EsclResolveOutcome.resolved(service))
    }

    private func timedOut() {
        guard completion != nil, !settling else { return }
        finish(EsclResolveOutcome.failed("no answer in time"))
    }

    private func finish(_ outcome: EsclResolveOutcome) {
        let answer: (@MainActor (EsclResolveOutcome) -> Void)? = completion
        completion = nil
        release()
        answer?(outcome)
    }

    /// Ends the DNS-SD requests (no callback comes after this on the main queue) and lets go of the operation.
    private func release() {
        if let ref = resolveRef {
            resolveRef = nil
            DNSServiceRefDeallocate(ref)
        }
        if let ref = addressRef {
            addressRef = nil
            DNSServiceRefDeallocate(ref)
        }
        if let unmanaged = retained {
            retained = nil
            unmanaged.release()
        }
    }

    /// A DNS-SD error as an outcome: PolicyDenied (Local Network access off) is `.denied`.
    nonisolated static func outcome(_ error: DNSServiceErrorType, doing: String) -> EsclResolveOutcome {
        if EsclLocalNetwork.isPolicyDenied(Int32(error)) {
            return EsclResolveOutcome.denied
        }
        return EsclResolveOutcome.failed("\(doing) failed (DNS-SD error \(error))")
    }

    /// An IPv4 or IPv6 address as text; a link-local IPv6 address with its interface as the zone ("fe80::1%4").
    nonisolated static func text(of address: UnsafePointer<sockaddr>) -> String? {
        let family: Int32 = Int32(address.pointee.sa_family)
        if family == AF_INET {
            var ipv4: in_addr = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                (pointer: UnsafePointer<sockaddr_in>) -> in_addr in
                pointer.pointee.sin_addr
            }
            var buffer: [CChar] = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN) + 1)
            let length: socklen_t = socklen_t(buffer.count)
            guard inet_ntop(AF_INET, &ipv4, &buffer, length) != nil else { return nil }
            return EsclDnssdResolve.string(buffer)
        }
        if family == AF_INET6 {
            var ipv6: in6_addr = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                (pointer: UnsafePointer<sockaddr_in6>) -> in6_addr in
                pointer.pointee.sin6_addr
            }
            let scope: UInt32 = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                (pointer: UnsafePointer<sockaddr_in6>) -> UInt32 in
                pointer.pointee.sin6_scope_id
            }
            var buffer: [CChar] = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN) + 1)
            let length: socklen_t = socklen_t(buffer.count)
            guard inet_ntop(AF_INET6, &ipv6, &buffer, length) != nil else { return nil }
            guard let text = EsclDnssdResolve.string(buffer) else { return nil }
            return scope == 0 ? text : text + "%" + String(scope)
        }
        return nil
    }

    private nonisolated static func string(_ buffer: [CChar]) -> String? {
        let text: String = buffer.withUnsafeBufferPointer { (pointer: UnsafeBufferPointer<CChar>) -> String in
            guard let base = pointer.baseAddress else { return "" }
            return String(cString: base)
        }
        return text.isEmpty ? nil : text
    }
}
