import Foundation

// The Swift side of windows/CompleteScanner.App/Scanning/EsclScannerBackend.cs: the same device list
// and the same way of connecting (addresses in order, trust on first use, a changed certificate refused
// unless the user trusts it, never plain HTTP after a refused certificate). For now (I11) it lists the
// scanners it is given; finding them on the network (DNS-SD), the addresses added by hand
// (escl-hosts.json, checked and re-checked), and the troubleshooter's view of them come with the
// iPhone's scanner screens (I12).

/// Driverless network scanners over eSCL (AirScan). Each scanner it was given (`endpoints`: a
/// discovered service, or an address, `endpoint(_:)`) is one entry, listed under its eSCL UUID when
/// known. Connecting tries the scanner's addresses in order; a scanner's certificate is trusted the
/// first time the app connects to it and pinned in escl-trust.json (`EsclTrustStore`), and a changed
/// certificate is refused with a warning unless the user, having chosen the scanner, trusts the new one
/// (`confirmCertificate`).
@MainActor
public final class EsclScannerBackend: ScannerBackend {
    public var onDevicesChanged: (() -> Void)?
    public private(set) var devices: [ScannerInfo] = []

    /// Asks the user whether to trust a scanner certificate that changed since it was trusted; true
    /// trusts it. Called while a scanner the user chose is being opened (`openSession(deviceID:interactive:)`).
    /// Without it, such scanners do not connect.
    public var confirmCertificate: ((EsclCertificateError) async -> Bool)?

    /// The system's background time for the jobs of the sessions opened here.
    public let background: (any BackgroundActivity)?

    private let trust: EsclTrustStore
    private let endpoints: [EsclEndpoint]
    private let clientOptions: EsclClientOptions
    private var records: [EsclDevice] = []

    /// A scanner as listed: the addresses to reach it through, best first.
    private struct EsclDevice {
        let info: ScannerInfo
        let uuid: String?
        let addresses: [ScannerAddress]
    }

    /// - Parameters:
    ///   - trust: the trusted certificates.
    ///   - endpoints: the scanners to list.
    ///   - clientOptions: timeouts, retry timing and the transport; defaults for the app.
    ///   - background: the system's background time for each job (the iPhone's `UIKitBackgroundActivity`).
    public init(trust: EsclTrustStore, endpoints: [EsclEndpoint], clientOptions: EsclClientOptions = EsclClientOptions(),
                background: (any BackgroundActivity)? = nil) {
        self.trust = trust
        self.endpoints = endpoints
        self.clientOptions = clientOptions
        self.background = background
    }

    /// A scanner known only by its address: listed under the address's host until it says its name.
    public static func endpoint(_ address: ScannerAddress) -> EsclEndpoint {
        EsclEndpoint(key: address.description, name: address.host, txt: EsclTxtRecord.parse(nil), addresses: [address])
    }

    public func startBrowsing() {
        rebuild()
    }

    public func stopBrowsing() {
        records = []
        if devices.isEmpty { return }
        devices = []
        onDevicesChanged?()
    }

    /// One entry per scanner, in the order given; two endpoints with the same UUID are one scanner, which
    /// keeps the first one's name and is reached through the addresses of both.
    private func rebuild() {
        var built: [EsclDevice] = []
        for endpoint in endpoints {
            let id: String = "escl:" + (EsclTxtRecord.uuidKey(endpoint.uuid) ?? endpoint.key)
            if let index = built.firstIndex(where: { (device: EsclDevice) -> Bool in device.info.id == id }) {
                let found: EsclDevice = built[index]
                var addresses: [ScannerAddress] = found.addresses
                for address in endpoint.addresses where !addresses.contains(address) {
                    addresses.append(address)
                }
                built[index] = EsclDevice(info: found.info, uuid: found.uuid, addresses: addresses)
                continue
            }
            let info: ScannerInfo = ScannerInfo(id: id, name: endpoint.name, transport: "Network", backend: "escl",
                                                model: endpoint.txt.model, hardwareID: endpoint.uuid)
            built.append(EsclDevice(info: info, uuid: endpoint.uuid, addresses: endpoint.addresses))
        }
        records = built
        var infos: [ScannerInfo] = []
        for record in built {
            infos.append(record.info)
        }
        if infos == devices { return }
        devices = infos
        onDevicesChanged?()
    }

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
    /// between the app and the scanner could cause that. Throws `ScanError`, or the `EsclCertificateError`.
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

    /// Trusts the certificate a connection was refused for.
    public func trustCertificate(_ certificate: EsclCertificateError, deviceUuid: String?, name: String) {
        try? trust.trust(certificate.fingerprint, deviceUuid: deviceUuid ?? certificate.deviceUuid,
                         authority: certificate.authority, name: name)
    }

    /// Why an address did not answer, for the message; nil for an error that is not about the address
    /// (a cancel), which is passed on.
    private static func connectionFailure(_ error: Error) -> String? {
        if let transport = error as? URLError {
            if transport.code == .cancelled {
                return nil
            }
            if transport.code == .timedOut {
                return "no answer in time"
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
}
