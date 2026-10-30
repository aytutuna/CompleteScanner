import Foundation

// The Swift side of windows/LazyScan.App/Scanning/EsclScannerBackend.cs: the same device list,
// the same way of connecting (addresses in order, trust on first use, a changed certificate refused
// unless the user trusts it, never plain HTTP after a refused certificate), the same addresses added by
// hand (escl-hosts.json, checked and re-checked every minute while they do not answer) and the same
// troubleshooter view. Scanners are found by `EsclDiscovery` (DNS-SD) where the app passes one (the
// iPhone and iPad), and by the endpoints it was made with. A connection made over plain HTTP although the
// scanner also has an HTTPS address (its TLS handshake failed or it did not answer there) is marked "Not
// encrypted" (`isNotEncrypted`); a refused certificate never leads to plain HTTP.

/// The outcome of checking an address for an eSCL scanner; exactly one of the three is set. Twin of the
/// Windows app's `EsclAddressCheck`.
public struct EsclAddressCheck: Equatable, Sendable {
    public let address: ScannerAddress
    /// The scanner answered.
    public let capabilities: EsclCapabilities?
    /// The scanner's certificate needs the user's confirmation (or cannot be used).
    public let certificate: EsclCertificateError?
    /// Nothing usable answered; the text says so, for the user.
    public let error: String?

    public init(address: ScannerAddress, capabilities: EsclCapabilities?, certificate: EsclCertificateError?, error: String?) {
        self.address = address
        self.capabilities = capabilities
        self.certificate = certificate
        self.error = error
    }

    /// The scanner did not answer at all (nothing to do with its certificate): for an address typed by
    /// hand, Local Network access may be the reason.
    public var noAnswer: Bool {
        capabilities == nil && certificate == nil
    }
}

/// Driverless network scanners over eSCL (AirScan). Scanners are found three ways: by `discovery`
/// (DNS-SD: _uscan._tcp and _uscans._tcp), by the addresses added by hand (`hosts`, escl-hosts.json), and
/// as the `endpoints` it was made with. A scanner found several ways is one entry (matched by its eSCL
/// UUID, which is also its hardware ID for `DeviceMerge`). Connecting tries the scanner's addresses in
/// order, HTTPS first; a scanner's certificate is trusted the first time the app connects to it and pinned
/// in escl-trust.json (`EsclTrustStore`), and a changed certificate is refused with a warning unless the
/// user, having chosen the scanner, trusts the new one (`confirmCertificate`).
@MainActor
public final class EsclScannerBackend: ScannerBackend, ScannerBackendDiagnostics {
    public var onDevicesChanged: (() -> Void)?
    public private(set) var devices: [ScannerInfo] = []
    /// The search found or lost a service, or its state changed (`discoveryStatus`): for screens that show it.
    public var onDiscoveryChanged: (() -> Void)?

    /// Asks the user whether to trust a scanner certificate that changed since it was trusted; true
    /// trusts it. Called while a scanner the user chose is being opened (`openSession(deviceID:interactive:)`).
    /// Without it, such scanners do not connect.
    public var confirmCertificate: ((EsclCertificateError) async -> Bool)?

    /// The system's background time for the jobs of the sessions opened here.
    public let background: (any BackgroundActivity)?
    /// The DNS-SD search; nil when scanners are not searched for (the Mac, tests of the connection).
    public let discovery: EsclDiscovery?
    /// The addresses added by hand; nil when there are none to keep.
    public let hosts: EsclHostList?
    /// How often addresses that did not answer are tried again while browsing (tests shorten it).
    public var reprobeInterval: TimeInterval = 60
    /// The app may use the local network: searching and checking the addresses added by hand start only
    /// then. The iPhone and iPad first explain why the system is about to ask (`allowNetwork()`); true by
    /// default.
    public private(set) var isNetworkAllowed: Bool

    private let trust: EsclTrustStore
    private let endpoints: [EsclEndpoint]
    private let clientOptions: EsclClientOptions
    private var records: [EsclDevice] = []
    /// What the last check of each address added by hand found, in the order checked.
    private var manual: [ManualHost] = []
    /// Counts adds and removals per address, so a check that ran meanwhile is not applied.
    private var manualEdits: [ScannerAddress: Int] = [:]
    private var discovered: [EsclEndpoint] = []
    private var lastSignature: String?
    private var browseGeneration: Int = 0
    private var browsing: Bool = false
    private var suspended: Bool = false
    /// Devices whose last session runs over plain HTTP although they have an HTTPS address.
    private var plainConnections: Set<String> = []

    /// A scanner as listed: the addresses to reach it through, best first.
    private struct EsclDevice {
        let info: ScannerInfo
        let uuid: String?
        let addresses: [ScannerAddress]
        let manualAddresses: [ScannerAddress]
    }

    /// An address added by hand and what answered there.
    private struct ManualHost {
        let address: ScannerAddress
        /// The scanner answered (or presented a certificate to confirm): it is listed.
        var listed: Bool
        var name: String?
        var uuid: String?
        /// Why it is not listed, for the diagnostics.
        var problem: String?
    }

    /// A check under way of an address added by hand.
    private struct PendingCheck {
        let address: ScannerAddress
        let edit: Int
        let task: Task<EsclAddressCheck, Never>
    }

    /// - Parameters:
    ///   - trust: the trusted certificates.
    ///   - endpoints: scanners to list as they are (none when they are found).
    ///   - hosts: the addresses added by hand (escl-hosts.json); nil for none.
    ///   - discovery: the DNS-SD search; nil for none.
    ///   - clientOptions: timeouts, retry timing and the transport; defaults for the app.
    ///   - background: the system's background time for each job (the iPhone's `UIKitBackgroundActivity`).
    public init(trust: EsclTrustStore, endpoints: [EsclEndpoint] = [], hosts: EsclHostList? = nil,
                discovery: EsclDiscovery? = nil, clientOptions: EsclClientOptions = EsclClientOptions(),
                background: (any BackgroundActivity)? = nil) {
        self.trust = trust
        self.endpoints = endpoints
        self.hosts = hosts
        self.discovery = discovery
        self.clientOptions = clientOptions
        self.background = background
        self.isNetworkAllowed = true
        discovery?.onChange = { [weak self] in
            self?.discoveryChanged()
        }
    }

    /// A scanner known only by its address: listed under the address's host until it says its name.
    public static func endpoint(_ address: ScannerAddress) -> EsclEndpoint {
        EsclEndpoint(key: address.description, name: address.host, txt: EsclTxtRecord.parse(nil), addresses: [address])
    }

    // MARK: Browsing

    public func startBrowsing() {
        if browsing {
            rebuild()
            return
        }
        browsing = true
        suspended = false
        browseGeneration += 1
        let generation: Int = browseGeneration
        if isNetworkAllowed {
            discovery?.start()
            startProbing(generation)
        }
        rebuild()
    }

    public func stopBrowsing() {
        browsing = false
        suspended = false
        browseGeneration += 1
        discovery?.stop()
        discovered = []
        manual = []
        rebuild()
    }

    /// The app may use the local network now (the user has read why the system asks): the search and the
    /// checks of the addresses added by hand start, if browsing.
    public func allowNetwork() {
        guard !isNetworkAllowed else { return }
        isNetworkAllowed = true
        guard browsing, !suspended else { return }
        browseGeneration += 1
        discovery?.start()
        startProbing(browseGeneration)
        rebuild()
    }

    /// Starts with the local network not to be used until `allowNetwork()` (set before browsing starts).
    public func holdNetwork() {
        isNetworkAllowed = false
    }

    /// The app goes to the background: the search and the re-checks stop; the scanners found stay listed.
    public func suspendBrowsing() {
        guard browsing, !suspended else { return }
        suspended = true
        browseGeneration += 1
        discovery?.pause()
    }

    /// The app is in front again: the search goes on, and every address added by hand is checked again.
    public func resumeBrowsing() {
        guard browsing, suspended else { return }
        suspended = false
        guard isNetworkAllowed else { return }
        browseGeneration += 1
        discovery?.resume()
        startProbing(browseGeneration)
    }

    /// How the search goes (`.off` until it may start).
    public var discoveryStatus: DiscoveryStatus {
        guard let discovery else { return .unknown }
        return discovery.status
    }

    /// The search may still find scanners soon (`EsclDiscovery.isLooking`): it just started or resumed, or a service it
    /// found is being resolved. False while the network is held, in the background or without a search.
    public var isSearching: Bool {
        guard browsing, !suspended, isNetworkAllowed, let discovery else { return false }
        return discovery.isLooking
    }

    private func discoveryChanged() {
        guard let discovery else { return }
        discovered = EsclEndpoint.choose(discovery.services)
        rebuild()
        onDiscoveryChanged?()
    }

    // MARK: Addresses added by hand

    private func startProbing(_ generation: Int) {
        guard hosts != nil else { return }
        Task { @MainActor [weak self] in
            await self?.probeManualHosts(generation)
        }
    }

    /// Checks every address in escl-hosts.json, then keeps re-checking the ones that do not answer (and
    /// any added to the file meanwhile) every `reprobeInterval`, so a scanner that was off at start appears
    /// once it is on. Ends when every address answers, or browsing stops or pauses.
    private func probeManualHosts(_ generation: Int) async {
        guard let hosts else { return }
        var onlyUnlisted: Bool = false
        while true {
            let addresses: [ScannerAddress] = hosts.load()
            // Entries removed from the file since the last check go away.
            var kept: [ManualHost] = []
            for host in manual where addresses.contains(host.address) {
                kept.append(host)
            }
            manual = kept
            var checks: [PendingCheck] = []
            for address in addresses {
                if onlyUnlisted, let known = manualHost(address), known.listed {
                    continue
                }
                let task: Task<EsclAddressCheck, Never> = Task { @MainActor [weak self] () -> EsclAddressCheck in
                    guard let self else {
                        return EsclAddressCheck(address: address, capabilities: nil, certificate: nil, error: nil)
                    }
                    return await self.probeAddress(address)
                }
                checks.append(PendingCheck(address: address, edit: editOf(address), task: task))
            }
            for check in checks {
                let result: EsclAddressCheck = await check.task.value
                if generation != browseGeneration {
                    return
                }
                // Added again or removed (the add sheet, the row's menu) while this check ran: that is newer.
                if editOf(check.address) != check.edit {
                    continue
                }
                setManualHost(EsclScannerBackend.manualHost(check.address, result))
            }
            rebuild()
            var waiting: Bool = false
            for host in manual where !host.listed {
                waiting = true
            }
            if !waiting {
                return
            }
            let nanoseconds: UInt64 = UInt64(max(0.01, reprobeInterval) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            if generation != browseGeneration {
                return
            }
            onlyUnlisted = true
        }
    }

    private func manualHost(_ address: ScannerAddress) -> ManualHost? {
        for host in manual where host.address == address {
            return host
        }
        return nil
    }

    /// Records a check's result, in the place of the address's earlier one (or last).
    private func setManualHost(_ host: ManualHost) {
        if let index = manual.firstIndex(where: { (known: ManualHost) -> Bool in known.address == host.address }) {
            manual[index] = host
        } else {
            manual.append(host)
        }
    }

    /// How often `address` was added or removed (only compared, never reset).
    private func editOf(_ address: ScannerAddress) -> Int {
        manualEdits[address] ?? 0
    }

    private func edited(_ address: ScannerAddress) {
        manualEdits[address] = editOf(address) + 1
    }

    /// `checkAddress` for an address in escl-hosts.json. A certificate seen for the first time is trusted,
    /// as on any first connection, so the scanner is listed under its own name and UUID and joins its
    /// discovered entry; but when the UUID it reports belongs to a scanner trusted with another
    /// certificate, nothing is trusted and the address is listed as that scanner's, with the changed
    /// certificate to confirm.
    private func probeAddress(_ address: ScannerAddress) async -> EsclAddressCheck {
        do {
            let result: EsclAddressCheck = try await checkAddress(address)
            if let certificate = result.certificate, certificate.verdict == .unknown, certificate.canTrust {
                return try await checkAddress(address, firstUse: certificate.fingerprint)
            }
            return result
        } catch {
            return EsclAddressCheck(address: address, capabilities: nil, certificate: nil,
                                    error: "No scanner answered at \(address) (the check was stopped).")
        }
    }

    private static func manualHost(_ address: ScannerAddress, _ result: EsclAddressCheck) -> ManualHost {
        // A changed certificate still lists the scanner (choosing it asks the user), under the UUID it was
        // trusted with, so it stays one entry with its discovered one. (The name in the pin is often just
        // the address, so it is not used.)
        var previous: EsclTrustedCertificate?
        var confirmable: Bool = false
        if let certificate = result.certificate, certificate.canTrust {
            previous = certificate.previous
            confirmable = true
        }
        var uuid: String? = result.capabilities?.uuid
        if uuid == nil, let pinned = previous?.deviceUuid, !pinned.isEmpty {
            uuid = pinned
        }
        var problem: String?
        if result.capabilities == nil {
            problem = result.certificate?.message ?? result.error
        }
        return ManualHost(address: address, listed: result.capabilities != nil || confirmable,
                          name: result.capabilities?.makeAndModel, uuid: uuid, problem: problem)
    }

    /// Asks `address` for its capabilities: what adding a scanner by address checks first. `firstUse`
    /// is the fingerprint of a certificate an earlier check found `.unknown`: it is trusted once the UUID
    /// the scanner reports shows it is not a changed certificate (otherwise the result is that `.changed`
    /// certificate, and nothing is trusted). Throws only `CancellationError`, when the task is cancelled.
    public func checkAddress(_ address: ScannerAddress, firstUse: String? = nil) async throws -> EsclAddressCheck {
        let name: String = address.description
        let validator: EsclCertificateValidator = EsclCertificateValidator(store: trust, deviceUuid: nil, deviceName: name,
                                                                           firstUse: firstUse)
        guard let base: URL = address.baseURL else {
            return EsclAddressCheck(address: address, capabilities: nil, certificate: nil,
                                    error: "No scanner answered at \(address) (it is not a usable address).")
        }
        let client: EsclClient = EsclClient(baseURL: base, deviceName: name, validator: validator, options: clientOptions)
        do {
            let capabilities: EsclCapabilities = try await client.getCapabilities()
            try validator.rememberDevice(capabilities.uuid)
            return EsclAddressCheck(address: address, capabilities: capabilities, certificate: nil, error: nil)
        } catch let certificate as EsclCertificateError {
            return EsclAddressCheck(address: address, capabilities: nil, certificate: certificate, error: nil)
        } catch {
            if Task.isCancelled || error is CancellationError {
                throw CancellationError()
            }
            let reason: String = EsclScannerBackend.checkFailure(error)
            return EsclAddressCheck(address: address, capabilities: nil, certificate: nil,
                                    error: "No scanner answered at \(address) (\(reason)).")
        }
    }

    /// Adds a checked address to escl-hosts.json and lists its scanner. Returns the device ID the scanner
    /// is listed under.
    @discardableResult
    public func addAddress(_ address: ScannerAddress, capabilities: EsclCapabilities) -> String {
        hosts?.add(address)
        edited(address)
        setManualHost(ManualHost(address: address, listed: true, name: capabilities.makeAndModel, uuid: capabilities.uuid,
                                 problem: nil))
        rebuild()
        for record in records where record.manualAddresses.contains(address) {
            return record.info.id
        }
        return "escl:" + address.description
    }

    /// The addresses added by hand that reach the scanner listed as `deviceID`.
    public func manualAddresses(_ deviceID: String) -> [ScannerAddress] {
        for record in records where record.info.id == deviceID {
            return record.manualAddresses
        }
        return []
    }

    /// Removes an address from escl-hosts.json; its scanner stays listed while discovery still finds it.
    public func removeAddress(_ address: ScannerAddress) {
        hosts?.remove(address)
        edited(address)
        manual.removeAll { (host: ManualHost) -> Bool in host.address == address }
        rebuild()
    }

    /// Trusts the certificate a check or connection was refused for.
    public func trustCertificate(_ certificate: EsclCertificateError, deviceUuid: String?, name: String) {
        try? trust.trust(certificate.fingerprint, deviceUuid: deviceUuid ?? certificate.deviceUuid,
                         authority: certificate.authority, name: name)
    }

    // MARK: The device list

    /// One entry per scanner: the endpoints given and the discovered ones in discovery order (two with the
    /// same UUID are one scanner, reached through the addresses of both), then the addresses added by hand
    /// (an address that reaches a listed scanner, by UUID, joins its entry and is tried after its other
    /// addresses). Nothing is listed while not browsing.
    private func rebuild() {
        var built: [EsclDevice] = []
        if browsing {
            var all: [EsclEndpoint] = endpoints
            all.append(contentsOf: discovered)
            for endpoint in all {
                let id: String = "escl:" + (EsclTxtRecord.uuidKey(endpoint.uuid) ?? endpoint.key)
                if let index = built.firstIndex(where: { (device: EsclDevice) -> Bool in device.info.id == id }) {
                    let found: EsclDevice = built[index]
                    var addresses: [ScannerAddress] = found.addresses
                    for address in endpoint.addresses where !addresses.contains(address) {
                        addresses.append(address)
                    }
                    built[index] = EsclDevice(info: found.info, uuid: found.uuid, addresses: addresses,
                                              manualAddresses: found.manualAddresses)
                    continue
                }
                let info: ScannerInfo = ScannerInfo(id: id, name: endpoint.name, transport: "Network", backend: "escl",
                                                    model: endpoint.txt.model, hardwareID: endpoint.uuid)
                built.append(EsclDevice(info: info, uuid: endpoint.uuid, addresses: endpoint.addresses, manualAddresses: []))
            }
            for host in manual where host.listed {
                let uuidKey: String? = EsclTxtRecord.uuidKey(host.uuid)
                var index: Int?
                if let uuidKey {
                    index = built.firstIndex(where: { (device: EsclDevice) -> Bool in
                        EsclTxtRecord.uuidKey(device.uuid) == uuidKey
                    })
                }
                if let index {
                    let found: EsclDevice = built[index]
                    // The scanner's own name (its capabilities) over the advertised one.
                    var info: ScannerInfo = found.info
                    if let name = host.name {
                        info = ScannerInfo(id: found.info.id, name: name, transport: found.info.transport,
                                           isDemo: found.info.isDemo, backend: found.info.backend, model: name,
                                           hardwareID: found.info.hardwareID)
                    }
                    var addresses: [ScannerAddress] = found.addresses
                    if !addresses.contains(host.address) {
                        addresses.append(host.address)
                    }
                    var manualAddresses: [ScannerAddress] = found.manualAddresses
                    manualAddresses.append(host.address)
                    built[index] = EsclDevice(info: info, uuid: found.uuid, addresses: addresses, manualAddresses: manualAddresses)
                    continue
                }
                let id: String = "escl:" + (uuidKey ?? host.address.description)
                if built.contains(where: { (device: EsclDevice) -> Bool in device.info.id == id }) {
                    continue
                }
                let info: ScannerInfo = ScannerInfo(id: id, name: host.name ?? host.address.host, transport: "Network",
                                                    backend: "escl", model: host.name, hardwareID: host.uuid)
                built.append(EsclDevice(info: info, uuid: host.uuid, addresses: [host.address], manualAddresses: [host.address]))
            }
        }
        records = built

        // Raised when the list or the diagnostics change (devices.txt is written from them).
        var parts: [String] = []
        for record in built {
            parts.append("\(record.info)")
        }
        let signature: String = parts.joined(separator: "\u{1E}") + "\u{1D}" + (diagnosticsReport ?? "")
        if signature == lastSignature {
            return
        }
        lastSignature = signature
        var infos: [ScannerInfo] = []
        for record in built {
            infos.append(record.info)
        }
        devices = infos
        onDevicesChanged?()
    }

    // MARK: Sessions

    /// A connection the app opens on its own: a changed certificate is not asked about.
    public func openSession(deviceID: String) async throws -> any ScannerSession {
        try await openSession(deviceID: deviceID, interactive: false)
    }

    /// Connects through the scanner's addresses in order. A certificate seen for the first time is
    /// trusted and pinned (trust on first use) once the UUID the scanner reports shows it is not another
    /// certificate for a scanner trusted before. A certificate that changed since it was trusted is shown
    /// to the user (`confirmCertificate`) only when `interactive`, i.e. the user just chose this scanner;
    /// the app never asks unprompted. Once trusted, the same address is tried again. A refused
    /// certificate fails the connection: it never falls back to a plain HTTP address, since anyone
    /// between the app and the scanner could cause that. An HTTPS address that does not answer, or whose
    /// TLS handshake fails (an old TLS version), is passed over for the next one, which may be the
    /// scanner's own plain HTTP address: the connection is then "Not encrypted" (`isNotEncrypted`).
    /// Throws `ScanError`, or the `EsclCertificateError`.
    public func openSession(deviceID: String, interactive: Bool) async throws -> any ScannerSession {
        guard let record: EsclDevice = records.first(where: { (device: EsclDevice) -> Bool in device.info.id == deviceID }) else {
            throw ScanError.deviceUnavailable("The selected scanner is not connected.")
        }
        var failures: [String] = []
        for address in record.addresses {
            var firstUse: String?
            var trustedHere: Bool = false
            while true {
                let validator: EsclCertificateValidator = EsclCertificateValidator(
                    store: trust, deviceUuid: record.uuid, deviceName: record.info.name, firstUse: firstUse)
                guard let base: URL = address.baseURL else {
                    failures.append("\(address): not a usable address")
                    break
                }
                let client: EsclClient = EsclClient(baseURL: base, deviceName: record.info.name, validator: validator,
                                                    options: clientOptions)
                do {
                    let caps: EsclCapabilities = try await client.getCapabilities()
                    try validator.rememberDevice(caps.uuid)
                    notePlainConnection(record, over: address)
                    return EsclScannerSession(info: record.info, client: client, capabilities: caps, background: background)
                } catch let error as EsclCertificateError {
                    if error.canTrust && error.verdict == .unknown && firstUse == nil {
                        firstUse = error.fingerprint
                        continue
                    }
                    // Trusting the same address twice in a row means the pin did not take: stop.
                    if !trustedHere && error.canTrust && error.verdict == .changed && interactive,
                       let confirm = confirmCertificate {
                        if await confirm(error) {
                            trustCertificate(error, deviceUuid: record.uuid, name: record.info.name)
                            trustedHere = true
                            continue
                        }
                    }
                    throw error
                } catch {
                    guard let reason: String = EsclScannerBackend.connectionFailure(error) else {
                        throw error
                    }
                    failures.append("\(address): \(reason)")
                    break
                }
            }
        }
        throw ScanError.sessionFailed("\(record.info.name) did not answer (\(failures.joined(separator: "; "))).")
    }

    /// The scanner listed as `deviceID` is connected over plain HTTP although it also has an HTTPS address
    /// (its own advertised HTTP address, used when HTTPS could not be): shown as "Not encrypted".
    public func isNotEncrypted(_ deviceID: String) -> Bool {
        plainConnections.contains(deviceID)
    }

    /// The label a connection made over plain HTTP after HTTPS could not be used carries.
    public static let notEncryptedLabel = "Not encrypted"

    private func notePlainConnection(_ record: EsclDevice, over address: ScannerAddress) {
        var hasSecure: Bool = false
        for candidate in record.addresses where candidate.secure {
            hasSecure = true
        }
        if !address.secure && hasSecure {
            plainConnections.insert(record.info.id)
        } else {
            plainConnections.remove(record.info.id)
        }
    }

    /// Why an address did not answer, for the message; nil for an error that is not about the address
    /// (a cancel), which is passed on. A TLS failure that is not about trust (an old TLS version, a
    /// handshake error) counts as an address that did not answer.
    private static func connectionFailure(_ error: Error) -> String? {
        if let transport = error as? URLError {
            if transport.code == .cancelled {
                return nil
            }
            if transport.code == .timedOut {
                return "no answer in time"
            }
            if isTLSFailure(transport) {
                return "no secure connection (\(transport.localizedDescription))"
            }
            return transport.localizedDescription
        }
        if let status = error as? EsclHttpError {
            return status.localizedDescription
        }
        if let format = error as? EsclFormatError {
            return format.message
        }
        return nil
    }

    /// The TLS handshake failed for a reason other than the certificate's trust, which the trust delegate
    /// decides (its refusals are `EsclCertificateError`s and never pass over to another address).
    static func isTLSFailure(_ error: URLError) -> Bool {
        switch error.code {
        case .secureConnectionFailed, .clientCertificateRejected, .clientCertificateRequired:
            return true
        default:
            return false
        }
    }

    /// Why an address checked by hand did not answer, as the Windows dialog says it.
    private static func checkFailure(_ error: Error) -> String {
        if error is EsclFormatError {
            return "it answered, but not like an eSCL scanner"
        }
        if let status = error as? EsclHttpError {
            return "it answered HTTP \(status.statusCode)"
        }
        if let transport = error as? URLError {
            if transport.code == .timedOut || transport.code == .cancelled {
                return "it did not answer in time"
            }
            return transport.localizedDescription
        }
        return error.localizedDescription
    }

    // MARK: Diagnostics

    /// The troubleshooter's view: how the automatic search goes, how many scanners it found, and each
    /// address added by hand that has been checked, with why nothing answers there.
    public func addStatus(to snapshot: DiscoverySnapshot) -> DiscoverySnapshot {
        var updated: DiscoverySnapshot = snapshot
        if let discovery {
            updated.discovery = discovery.status
            updated.discoveryDetail = discovery.failure
        }
        updated.discoveredCount = discovered.count
        var hostsChecked: [ManualHostStatus] = snapshot.manualHosts
        for host in manual {
            hostsChecked.append(ManualHostStatus(address: host.address.description, listed: host.listed, problem: host.problem))
        }
        updated.manualHosts = hostsChecked
        return updated
    }

    /// The troubleshooter's Refresh: checks every address added by hand again now (the regular re-check of
    /// those that do not answer continues from there) and restarts a search that failed. Scanners already
    /// found stay listed meanwhile, and a search that works is left alone.
    public func rescan() {
        guard browsing, !suspended, isNetworkAllowed else { return }
        discovery?.restart()
        // A new generation ends the previous check loop, which this one replaces.
        browseGeneration += 1
        startProbing(browseGeneration)
    }

    /// What the search found and what each address added by hand answered, for devices.txt and Copy
    /// diagnostics; nil when there is nothing to say.
    public var diagnosticsReport: String? {
        var text: String = ""
        if let discovery {
            text += "eSCL network discovery (DNS-SD _uscan/_uscans): \(discovery.statusLine)\n"
            for service in discovery.services {
                let txt: EsclTxtRecord = EsclTxtRecord.parse(service.textAttributes)
                let kind: String = service.secure ? "_uscans" : "_uscan"
                text += "  \(kind) \"\(service.instanceName)\" host=\"\(service.hostName ?? "")\" port=\(service.port) "
                text += "addresses=\"\(service.addresses.joined(separator: ","))\" ty=\"\(txt.model ?? "")\" "
                text += "uuid=\"\(txt.uuid ?? "")\" rs=\"\(txt.resourcePath)\"\n"
            }
            for line in discovery.unresolvedLines {
                text += "  \(line)\n"
            }
        }
        if !manual.isEmpty {
            text += "eSCL addresses added by hand:\n"
            for host in manual {
                if host.listed {
                    text += "  \(host.address): listed as \"\(host.name ?? host.address.host)\"\n"
                } else {
                    text += "  \(host.address): not listed (\(host.problem ?? ""))\n"
                }
            }
        }
        if !plainConnections.isEmpty {
            text += "eSCL connections over plain HTTP: \(plainConnections.sorted().joined(separator: ", "))\n"
        }
        return text.isEmpty ? nil : text
    }
}
