import Darwin
import Foundation
import Network
import Security

// Twin of windows/LazyScan.Core/Companion/CompanionService.cs: the desktop's side of C1 put
// together, without a screen, so the tests drive it end to end over loopback. The certificate is a
// `CompanionIdentity` (the Mac's keychain), and the C# events are closures.

/// Where the companion keeps its files and what the platform provides.
public struct CompanionServiceOptions {
    /// The settings folder (companion-devices.json, companion-networks.json).
    public var settingsDirectory: URL
    /// The folder of the inbox and outbox ("Inbox", "Outbox" inside it).
    public var dataDirectory: URL
    /// The desktop's identity, made on first use; `renew` makes a new key (Reset pairing).
    public var identity: CompanionIdentity
    public var networks: CompanionNetworkSource
    public var advertiser: DnsSdAdvertiser = NoDnsSdAdvertiser()
    /// Where the phones' sync keys for the cloud sync folder are kept (the Mac's Keychain); nil: no keys
    /// are made, and phones pair without the folder.
    public var syncKeyStore: (any CompanionSecretStore)?
    public var clock: () -> Date = { Date() }
    /// The name phones show, the DNS-SD instance's name.
    public var desktopName: String
    public var preferredPort = CompanionProtocol.defaultPort
    public var server = CompanionServerOptions()

    public init(settingsDirectory: URL, dataDirectory: URL, identity: CompanionIdentity, networks: CompanionNetworkSource,
                desktopName: String) {
        self.settingsDirectory = settingsDirectory
        self.dataDirectory = dataDirectory
        self.identity = identity
        self.networks = networks
        self.desktopName = desktopName
    }
}

/// The desktop's companion, put together: the paired phones and approved networks, the inbox and
/// outbox, the server's requests and the host that listens only while it is wanted (a phone is
/// paired, a pairing code is shown, or a phone that presented the code waits for the user's answer)
/// and only on trusted networks, and the cloud sync folder phones put documents in when they cannot
/// reach it (C2, `SyncFolderWatcher`), watched while the service runs. The app adds the platform's
/// pieces (identity, networks, DNS-SD, the sync keys' store) and its window. Safe to use from any thread.
public final class CompanionService: @unchecked Sendable {
    public let devices: PairedDeviceStore
    public let trustedNetworks: TrustedNetworkStore
    public let inbox: CompanionInbox
    public let outbox: CompanionOutbox
    public let limiter: CompanionRateLimiter
    public let router: CompanionRouter
    public let host: CompanionHost

    private let options: CompanionServiceOptions
    private let lock = NSLock()
    private var identity: SecIdentity?
    private var session: PairingSession?
    private var pairingTimer: Task<Void, Never>?
    private var pages = 0
    private var syncWatcher: SyncFolderWatcher?

    /// Called (on any thread) when the status, the paired phones, the networks or the pairing changed.
    public var onChange: (() -> Void)?
    /// A phone was paired (on the request's task).
    public var onDevicePaired: ((PairedDevice) -> Void)?
    /// A paired phone sent a document (on the request's task), or put it in the sync folder (on the
    /// watcher's task). Release it from `inbox` once imported.
    public var onPackageReceived: ((ReceivedPackage, PairedDevice) -> Void)?
    /// A file in the sync folder could not be read: the message for the status, once per file.
    public var onSyncFolderProblem: ((String) -> Void)?

    public init(_ options: CompanionServiceOptions) {
        self.options = options
        devices = PairedDeviceStore(directory: options.settingsDirectory, syncKeyStore: options.syncKeyStore)
        trustedNetworks = TrustedNetworkStore(directory: options.settingsDirectory)
        inbox = CompanionInbox(directory: options.dataDirectory.appendingPathComponent("Inbox", isDirectory: true))
        outbox = CompanionOutbox(directory: options.dataDirectory.appendingPathComponent("Outbox", isDirectory: true))
        limiter = CompanionRateLimiter()
        router = CompanionRouter(devices: devices, inbox: inbox, outbox: outbox, limiter: limiter, clock: options.clock)
        var hostOptions = CompanionHostOptions()
        hostOptions.preferredPort = options.preferredPort
        hostOptions.instanceName = options.desktopName
        hostOptions.server = options.server
        hostOptions.clock = options.clock
        let deviceStore = devices
        hostOptions.desktopId = { deviceStore.desktopId }
        let trusted = trustedNetworks
        // The host and the router hold the service weakly: it owns them.
        weak var service: CompanionService?
        host = CompanionHost(identity: { guard let service else { throw CancellationError() }; return try service.currentIdentity() },
                             router: router, limiter: limiter, networks: options.networks,
                             isApproved: { trusted.isApproved($0) }, advertiser: options.advertiser,
                             wanted: { service?.isWanted ?? false }, options: hostOptions)
        service = self
        let name = options.desktopName
        router.desktopName = { name }
        // The session as it is (used or expired too), so a phone is told why its code no longer works.
        router.currentPairing = { [weak self] in self?.currentSession }
        router.queuedPages = { [weak self] in self?.queuedPages ?? 0 }
        router.onDevicePaired = { [weak self] device in
            guard let self else { return }
            // The session is used now; it stays, so the code's token is answered as used.
            self.cancelPairingTimer()
            self.onDevicePaired?(device)
            self.onChange?()
        }
        router.onPackageReceived = { [weak self] package, device in self?.onPackageReceived?(package, device) }
        router.onDeviceRemoved = { [weak self] _ in self?.refreshQuietly() }
        // A declined (or cut off) pairing no longer keeps the host listening.
        router.onApprovalSettled = { [weak self] in self?.refreshQuietly() }
        host.onStatusChange = { [weak self] in self?.onChange?() }
        devices.onChange = { [weak self] in self?.refreshQuietly() }
        trustedNetworks.onChange = { [weak self] in self?.refreshQuietly() }
    }

    public var status: CompanionHostStatus { host.status }

    /// The pairing session open now; nil when none is (closed, used, or expired).
    public var pairing: PairingSession? {
        guard let session = currentSession, session.state(at: options.clock()) == .open else { return nil }
        return session
    }

    /// A phone presented the pairing code and waits for the user's answer. Its session is used
    /// (`pairing` is nil), but the host keeps listening until the answer is in.
    public var awaitingApproval: Bool { router.awaitingApproval > 0 }

    /// The pages in the app's queue, for `HelloResponse` (set by the app, read by requests).
    public var queuedPages: Int {
        get {
            lock.lock()
            defer { lock.unlock() }
            return pages
        }
        set {
            lock.lock()
            pages = newValue
            lock.unlock()
        }
    }

    /// The certificate's fingerprint (the pin phones keep).
    public func fingerprint() throws -> Data {
        let identity = try currentIdentity()
        guard let der = SelfSignedCertificate.der(of: identity), let pin = SpkiFingerprint.of(der) else {
            throw SelfSignedCertificateError("The certificate cannot be read.")
        }
        return pin
    }

    /// The cloud sync folder (C2); nil when none is chosen.
    public var syncFolder: URL? { devices.syncFolder }

    /// Starts following the networks: listens if a phone is paired and a trusted network is connected;
    /// watches the sync folder when one is chosen.
    public func start() async {
        watchSyncFolder()
        await host.refresh()
    }

    /// Chooses the cloud sync folder (nil: none) and watches it from now on; false when that could not
    /// be saved.
    @discardableResult
    public func setSyncFolder(_ folder: URL?) -> Bool {
        guard devices.setSyncFolder(folder) else { return false }
        watchSyncFolder()
        return true
    }

    public func refresh() async {
        await host.refresh()
    }

    /// Opens a pairing session (replacing an open one) and starts listening for it. Returns the
    /// pairing code to show; nil when the desktop cannot listen now (`status` says why). The session
    /// is then closed again: nothing listens for a code nobody can see.
    public func openPairing() async -> PairingUri? {
        guard let opened = try? PairingSession(opened: options.clock()) else { return nil }
        let timer = Task { [weak self] in
            // When the code expires, the host stops listening again if no phone is paired.
            try? await Task.sleep(nanoseconds: UInt64((PairingSession.lifetime + 1) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.refreshQuietly()
        }
        replaceSession(opened, timer: timer)
        await host.refresh()
        let code = pairingCode()
        if code == nil {
            // Not listening, so nothing needs stopping, and the status keeps its reason (no network,
            // no trusted network, or why listening failed) for the window to show.
            dropSession(ifTimer: timer)
        }
        onChange?()
        return code
    }

    /// The code for the open pairing session at the addresses listened on now; nil when there is none.
    public func pairingCode() -> PairingUri? {
        let status = host.status
        guard let session = pairing, status.state == .listening, status.port > 0,
              let pin = try? fingerprint() else { return nil }
        return PairingUri(desktopId: devices.desktopId, name: CompanionService.pairingName(options.desktopName),
                          fingerprint: SpkiFingerprint.text(pin), addresses: CompanionService.codeAddresses(status.endpoints),
                          port: status.port, token: session.token)
    }

    /// Closes the pairing session; the host stops listening if no phone is paired.
    public func closePairing() async {
        replaceSession(nil, timer: nil)
        await host.refresh()
        onChange?()
    }

    /// Unpairs a phone and deletes what waited for it; it gets 401 from now on.
    public func removeDevice(_ id: String) async {
        devices.remove(id)
        outbox.removeDevice(id)
        await host.refresh()
        onChange?()
    }

    /// Unpairs every phone and makes a new identity with a new key, so a phone that kept the old pin
    /// can no longer connect; phones pair again with a new code. The new identity is made first: when
    /// that fails (the error is passed on), nothing was changed and every phone stays paired.
    public func resetPairing() async throws {
        let renewed = try options.identity.renew(now: options.clock())
        setIdentity(renewed)
        replaceSession(nil, timer: nil)
        for device in devices.devices {
            outbox.removeDevice(device.id)
        }
        devices.removeAll()
        await host.refresh(restart: true)
        onChange?()
    }

    /// Approves `network` for receiving, or withdraws that; false when the approval could not be saved.
    @discardableResult
    public func setNetworkApproved(_ network: CompanionNetwork, _ approved: Bool) async -> Bool {
        var saved = true
        if approved {
            saved = trustedNetworks.approve(network, now: options.clock())
        } else {
            trustedNetworks.revoke(network.id)
        }
        await host.refresh()
        onChange?()
        return saved
    }

    /// The checks for the Phone window.
    public func snapshot(platform: TroubleshootPlatform = .mac) -> CompanionSnapshot {
        let status = host.status
        var networks = status.networks
        if networks.isEmpty && status.state == .off {
            let trusted = trustedNetworks
            for network in options.networks.networks() {
                networks.append(CompanionNetworkState(network: network,
                                                      trust: TrustedNetworkPolicy.trust(network) { trusted.isApproved($0) }))
            }
        }
        let lastSeen = devices.devices.compactMap(\.lastSeen).max()
        return CompanionSnapshot(platform: platform, networks: networks, listen: status.state, port: status.port,
                                 listenError: status.error, pairedCount: devices.count,
                                 pairingOpen: pairing != nil || awaitingApproval, syncFolderChosen: syncFolder != nil,
                                 phonesQuietFor: lastSeen.map { options.clock().timeIntervalSince($0) })
    }

    /// Stops listening and withdraws the advertisements (the app quits).
    public func dispose() async {
        cancelPairingTimer()
        stopSyncWatcher()
        await host.dispose()
    }

    /// The addresses a pairing code carries: IPv4 first, then IPv6 except link-local (its zone is
    /// this computer's), at most `PairingUri.maxAddresses`.
    public static func codeAddresses(_ endpoints: [NWEndpoint]) -> [String] {
        var ipv4: [String] = []
        var ipv6: [String] = []
        for endpoint in endpoints {
            guard case .hostPort(let host, _) = endpoint, let bytes = LocalSubnet.bytes(host) else { continue }
            if bytes.count == 4 {
                var parts: [String] = []
                for byte in bytes {
                    parts.append(String(byte))
                }
                let text = parts.joined(separator: ".")
                if !ipv4.contains(text) { ipv4.append(text) }
            } else if bytes.count == 16 && !(bytes[0] == 0xFE && (bytes[1] & 0xC0) == 0x80) {
                var address = in6_addr()
                withUnsafeMutableBytes(of: &address) { (raw: UnsafeMutableRawBufferPointer) in
                    raw.copyBytes(from: bytes)
                }
                var buffer: [CChar] = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN) + 1)
                guard inet_ntop(AF_INET6, &address, &buffer, socklen_t(buffer.count)) != nil else { continue }
                let text: String = buffer.withUnsafeBufferPointer { (pointer: UnsafeBufferPointer<CChar>) -> String in
                    guard let base = pointer.baseAddress else { return "" }
                    return String(cString: base)
                }
                if !ipv6.contains(text) { ipv6.append(text) }
            }
        }
        return Array((ipv4 + ipv6).prefix(PairingUri.maxAddresses))
    }

    /// The desktop's name as a code carries it: cleaned and cut to fit; "Computer" when nothing is left.
    public static func pairingName(_ name: String) -> String {
        let clean = PairedDeviceStore.cleanName(name)
        return clean.isEmpty ? "Computer" : clean
    }

    /// Application Support/Lazy Scan, where the app's settings are: companion-devices.json and
    /// companion-networks.json go next to them.
    public static var settingsFolder: URL { StoreFiles.defaultDirectory }

    /// Application Support/Lazy Scan/Companion, created and kept out of backups: what phones sent
    /// and what waits for them.
    public static func dataFolder() -> URL {
        var folder = StoreFiles.defaultDirectory.appendingPathComponent("Companion", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
        return folder
    }

    // MARK: - Private

    /// Watches the folder chosen now, and no other.
    private func watchSyncFolder() {
        let folder = devices.syncFolder
        lock.lock()
        defer { lock.unlock() }
        guard syncWatcher?.folder.path != folder?.path else { return }
        syncWatcher?.stop()
        syncWatcher = nil
        guard let folder else { return }
        let watcher = SyncFolderWatcher(folder: folder, devices: devices, inbox: inbox)
        watcher.onPackageReceived = { [weak self] package, device in self?.onPackageReceived?(package, device) }
        watcher.onProblem = { [weak self] message in self?.onSyncFolderProblem?(message) }
        watcher.start()
        syncWatcher = watcher
    }

    private func stopSyncWatcher() {
        lock.lock()
        syncWatcher?.stop()
        syncWatcher = nil
        lock.unlock()
    }

    private var isWanted: Bool {
        devices.count > 0 || pairing != nil || awaitingApproval
    }

    private var currentSession: PairingSession? {
        lock.lock()
        defer { lock.unlock() }
        return session
    }

    private func currentIdentity() throws -> SecIdentity {
        lock.lock()
        defer { lock.unlock() }
        if let identity { return identity }
        let made = try options.identity.current(now: options.clock())
        identity = made
        return made
    }

    private func setIdentity(_ renewed: SecIdentity) {
        lock.lock()
        identity = renewed
        lock.unlock()
    }

    /// Closes the session open now and its timer, then keeps `opened` (nil: none) with its `timer`.
    private func replaceSession(_ opened: PairingSession?, timer: Task<Void, Never>?) {
        lock.lock()
        session?.close()
        pairingTimer?.cancel()
        session = opened
        pairingTimer = timer
        lock.unlock()
    }

    /// Closes and forgets the session, unless another was opened since `timer` was made.
    private func dropSession(ifTimer timer: Task<Void, Never>) {
        lock.lock()
        defer { lock.unlock() }
        guard pairingTimer == timer else { return }
        session?.close()
        session = nil
        timer.cancel()
    }

    private func cancelPairingTimer() {
        lock.lock()
        pairingTimer?.cancel()
        lock.unlock()
    }

    private func refreshQuietly() {
        Task { [weak self] in
            guard let self else { return }
            await self.host.refresh()
            self.onChange?()
        }
    }
}
