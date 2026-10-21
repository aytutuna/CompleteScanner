#if os(iOS)
import CompleteScannerKit
import Foundation
import Network

/// Tells whether a connection to an address on the local network is refused for Local Network access.
@MainActor
public protocol IOSLocalNetworkChecking: AnyObject {
    /// True when the system refuses the app the local network for `host`:`port`.
    func isDenied(host: String, port: Int) async -> Bool
}

/// Local Network access, as far as an app can tell it: there is no API to read or ask for it, so a
/// refusal is inferred from what the system does (TN3179): a browser waiting with
/// `kDNSServiceErr_PolicyDenied` (`EsclDiscovery`), or a connection waiting whose path's unsatisfied
/// reason is `.localNetworkDenied` (this probe). The probe opens a TCP connection to the address only after
/// adding that address found no scanner there, which the user asked for; it is closed at once either way.
@MainActor
public final class IOSLocalNetworkProbe: IOSLocalNetworkChecking {
    /// How long the connection may take to say.
    public var timeout: TimeInterval = 3

    public init() {}

    public func isDenied(host: String, port: Int) async -> Bool {
        guard port > 0, port <= 65535, let target = NWEndpoint.Port(rawValue: UInt16(port)) else { return false }
        let connection: NWConnection = NWConnection(host: NWEndpoint.Host(host), port: target, using: NWParameters.tcp)
        let wait: TimeInterval = timeout
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let once: IOSProbeAnswer = IOSProbeAnswer(continuation)
            connection.stateUpdateHandler = { (state: NWConnection.State) -> Void in
                switch state {
                case .waiting:
                    let reason: NWPath.UnsatisfiedReason? = connection.currentPath?.unsatisfiedReason
                    once.finish(IOSLocalNetworkProbe.isDenied(reason))
                    connection.cancel()
                case .ready, .failed:
                    once.finish(false)
                    connection.cancel()
                default:
                    break
                }
            }
            connection.start(queue: DispatchQueue.main)
            DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + wait) {
                once.finish(false)
                connection.cancel()
            }
        }
    }

    /// A path unsatisfied for this reason is refused the local network.
    public nonisolated static func isDenied(_ reason: NWPath.UnsatisfiedReason?) -> Bool {
        guard let reason else { return false }
        return reason == NWPath.UnsatisfiedReason.localNetworkDenied
    }
}

/// Resumes the probe's wait once, whichever of the connection and the timeout answers first.
private final class IOSProbeAnswer: @unchecked Sendable {
    private let lock: NSLock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func finish(_ denied: Bool) {
        lock.lock()
        let waiting: CheckedContinuation<Bool, Never>? = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(returning: denied)
    }
}
#endif
