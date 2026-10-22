#if os(macOS)
import CompleteScannerKit
import Foundation
import Network
import dnssd

// Twin of windows/CompleteScanner.App/Services/Companion/WindowsDnsSdAdvertiser.cs on the DNS-SD C API.
// NWListener.Service would advertise from the server's own listeners, one per address with no
// interface of its own; DNSServiceRegister takes the interface and the port, as Windows does.

private let companionRegisterReply: DNSServiceRegisterReply = {
    (_: DNSServiceRef?, _: DNSServiceFlags, _: DNSServiceErrorType, _: UnsafePointer<CChar>?, _: UnsafePointer<CChar>?,
     _: UnsafePointer<CChar>?, _: UnsafeMutableRawPointer?) in
    // Name conflicts are settled by mDNSResponder (it renames); nothing to do here.
}

/// Advertises `_completescan._tcp` with its TXT record on one interface each, for as long as the host
/// keeps it; the host and address records are the Mac's own (mDNSResponder's).
final class MacDnsSdAdvertiser: DnsSdAdvertiser, @unchecked Sendable {
    private let queue = DispatchQueue(label: "MacDnsSdAdvertiser")

    func register(_ registration: DnsSdRegistration) throws -> () -> Void {
        var record: [UInt8] = []
        for key in registration.txt.keys.sorted() {
            let entry = Array("\(key)=\(registration.txt[key] ?? "")".utf8.prefix(255))
            record.append(UInt8(entry.count))
            record.append(contentsOf: entry)
        }
        let queue: DispatchQueue = self.queue
        let service: DNSServiceRef = try queue.sync { () throws -> DNSServiceRef in
            var ref: DNSServiceRef?
            let error: DNSServiceErrorType = record.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> DNSServiceErrorType in
                DNSServiceRegister(&ref, 0, UInt32(registration.interfaceIndex), registration.instanceName,
                                   registration.serviceType, nil, nil, UInt16(registration.port).bigEndian,
                                   UInt16(bytes.count), bytes.baseAddress, companionRegisterReply, nil)
            }
            guard Int(error) == kDNSServiceErr_NoError, let started = ref else { throw NWError.dns(error) }
            _ = DNSServiceSetDispatchQueue(started, queue)
            return started
        }
        return {
            queue.async { DNSServiceRefDeallocate(service) }
        }
    }
}
#endif
