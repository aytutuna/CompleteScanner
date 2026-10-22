#if os(iOS)
import CompleteScannerKit
import Foundation

/// The desktops a phone pairs with, seen on the network: their `CompanionProtocol.serviceType` services
/// (TXT `id`), browsed with `EsclNWBrowser` and resolved with `EsclDnssdResolver` as network scanners
/// are, only while something needs it (`begin`, `end`): the companion screen while it is open, a check of
/// the paired desktop while it runs. What it saw says whether a desktop that does not answer is on this
/// network at all (`isSeen`, the state's `companionDesktopSeenOnNetwork`) and where each desktop is now
/// (`onFound`, for an address that changed). The app makes one only when launched without `-demoScanner`.
@MainActor
public final class IOSCompanionBrowser: ObservableObject {
    /// The browser waits for Local Network access, which is off for the app.
    @Published public private(set) var accessDenied: Bool = false
    /// A desktop resolved: its id, addresses and port. Once for each desktop while browsing runs.
    public var onFound: ((String, [String], Int) -> Void)?

    private let makeBrowser: @MainActor () -> any EsclServiceBrowsing
    private let resolver: any EsclServiceResolving
    private var browser: (any EsclServiceBrowsing)?
    private var users: Int = 0
    private var seen: Set<String> = []
    private var resolving: [String: any EsclCancellable] = [:]
    private var done: Set<String> = []

    /// The app's: NWBrowser and DNS-SD.
    public convenience init() {
        self.init(makeBrowser: { () -> any EsclServiceBrowsing in
            EsclNWBrowser(type: CompanionProtocol.serviceType)
        }, resolver: EsclDnssdResolver())
    }

    /// Browses with what `makeBrowser` makes and resolves with `resolver` (tests: stand-ins).
    init(makeBrowser: @escaping @MainActor () -> any EsclServiceBrowsing, resolver: any EsclServiceResolving) {
        self.makeBrowser = makeBrowser
        self.resolver = resolver
    }

    public var isBrowsing: Bool { browser != nil }

    /// Browsing is needed: it starts unless it runs already. Each `begin` is ended by an `end`.
    public func begin() {
        users += 1
        guard browser == nil else { return }
        seen = []
        done = []
        let made: any EsclServiceBrowsing = makeBrowser()
        made.onStatus = { [weak self] (status: EsclBrowserStatus) -> Void in
            self?.statusChanged(status)
        }
        made.onResults = { [weak self] (results: [EsclBrowseResult]) -> Void in
            self?.found(results)
        }
        browser = made
        made.start()
    }

    /// No longer needed by one of those that began it; stops once none needs it. What was seen stays
    /// until the next start.
    public func end() {
        guard users > 0 else { return }
        users -= 1
        guard users == 0, let running = browser else { return }
        browser = nil
        running.onStatus = nil
        running.onResults = nil
        running.cancel()
        for operation in resolving.values {
            operation.cancel()
        }
        resolving = [:]
    }

    /// Whether the desktop with this id was among the services last reported.
    public func isSeen(_ desktopId: String) -> Bool {
        seen.contains(desktopId)
    }

    /// The desktop id in a service's TXT record; nil without a valid one.
    nonisolated static func desktopId(_ result: EsclBrowseResult) -> String? {
        let prefix: String = CompanionProtocol.txtIdKey + "="
        for entry in result.txt where entry.hasPrefix(prefix) {
            let id: String = String(entry.dropFirst(prefix.count))
            return CompanionProtocol.isValidId(id) ? id : nil
        }
        return nil
    }

    private func statusChanged(_ status: EsclBrowserStatus) {
        switch status {
        case .waiting(let code, _), .failed(let code, _):
            accessDenied = EsclLocalNetwork.isPolicyDenied(code)
        case .ready:
            accessDenied = false
        case .setup, .cancelled:
            break
        }
    }

    private func found(_ results: [EsclBrowseResult]) {
        var ids: Set<String> = []
        for result in results {
            guard let id = IOSCompanionBrowser.desktopId(result) else { continue }
            ids.insert(id)
            guard !done.contains(id), resolving[id] == nil else { continue }
            let operation: any EsclCancellable = resolver.resolve(result) { [weak self] (outcome: EsclResolveOutcome) -> Void in
                self?.resolved(id, outcome)
            }
            // A resolver that answered at once has nothing left to stop.
            if !done.contains(id) {
                resolving[id] = operation
            }
        }
        seen = ids
    }

    private func resolved(_ id: String, _ outcome: EsclResolveOutcome) {
        resolving[id] = nil
        done.insert(id)
        if case .resolved(let service) = outcome {
            onFound?(id, service.addresses, service.port)
        }
    }
}
#endif
