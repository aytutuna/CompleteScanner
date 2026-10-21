import Foundation

// Twin of windows/CompleteScanner.Core/Escl/EsclTrust.cs: trust for eSCL over HTTPS (_uscans).
// Scanners make their own certificates, which the system cannot check, so a scanner's certificate is
// trusted the first time the app connects to it (trust on first use) and pinned: the SHA-256 of its
// public key (SubjectPublicKeyInfo, cut out of the certificate by `SpkiFingerprint`) is kept in
// escl-trust.json, and a scanner that later shows a different key is refused with a clear warning
// until the user trusts the new one. The same rules, messages and file keys as C#; the TLS hook that
// feeds the validator (a URLSession delegate) belongs to the client.

/// What the trust store says about a certificate a scanner presented.
public enum EsclTrustVerdict: String, Sendable {
    /// Neither this certificate nor the scanner has been trusted before.
    case unknown
    /// The certificate is trusted (pinned, or valid for the system).
    case trusted
    /// The scanner was trusted with a different certificate.
    case changed
    /// The scanner presented no certificate that could be pinned.
    case invalid
}

/// One trusted scanner certificate (an entry of escl-trust.json).
public struct EsclTrustedCertificate: Codable, Equatable, Sendable {
    /// SHA-256 of the certificate's public key (SubjectPublicKeyInfo), lowercase hex.
    public var fingerprint = ""
    /// The scanner's UUID (`EsclTxtRecord.uuidKey`); "" when it was not known.
    public var deviceUuid = ""
    /// Where the certificate was seen ("host:port", see `ScannerAddress.authority`).
    public var addresses: [String] = []
    /// The scanner's name when it was trusted (for people reading the file).
    public var name = ""
    /// When the user trusted it. Each platform writes the date its own way (JSONEncoder's number here,
    /// ISO 8601 text in C#); the other platform's form reads as nil.
    public var trusted: Date?

    enum CodingKeys: String, CodingKey {
        case fingerprint, deviceUuid, addresses, name, trusted
    }

    public init() {}
}

extension EsclTrustedCertificate {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        fingerprint = c.decodeLenient(forKey: .fingerprint, default: fingerprint)
        deviceUuid = c.decodeLenient(forKey: .deviceUuid, default: deviceUuid)
        addresses = c.decodeLenient(forKey: .addresses, default: addresses)
        name = c.decodeLenient(forKey: .name, default: name)
        trusted = c.decodeLenient(forKey: .trusted, default: trusted)
    }
}

/// The contents of escl-trust.json.
public struct EsclTrustFile: Codable, Equatable, Sendable {
    public var certificates: [EsclTrustedCertificate] = []

    enum CodingKeys: String, CodingKey {
        case certificates
    }

    public init() {}
}

extension EsclTrustFile {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        certificates = c.decodeLenient(forKey: .certificates, default: certificates)
    }
}

/// What `EsclTrustStore.check` found: the verdict, and for `changed` the certificate trusted before
/// for that scanner (the C# method's `previous` out parameter).
public struct EsclTrustCheck: Equatable, Sendable {
    public let verdict: EsclTrustVerdict
    public let previous: EsclTrustedCertificate?

    public init(verdict: EsclTrustVerdict, previous: EsclTrustedCertificate? = nil) {
        self.verdict = verdict
        self.previous = previous
    }
}

/// Why a certificate could not be trusted.
public enum EsclTrustStoreError: Error, Equatable, Sendable {
    /// There was no certificate (an empty fingerprint).
    case noCertificate
}

/// The trusted scanner certificates (escl-trust.json), safe to use from any thread. The file is
/// re-read for every check and before every write, since another part of the app may share it;
/// certificates trusted while the file could not be written stay trusted for the rest of the session.
/// It follows the settings-file rules (CONTRACTS.md, rule 6).
public final class EsclTrustStore: @unchecked Sendable {
    public static let fileName = "escl-trust.json"
    /// Addresses remembered per certificate; the oldest are dropped beyond this.
    static let maxAddresses = 8

    /// A certificate trusted (and the address it was trusted at) that is not in the file yet: its last
    /// write failed.
    private struct UnsavedPin {
        var pin: EsclTrustedCertificate
        let address: String
    }

    private let url: URL
    private let lock = NSLock()
    private var file: EsclTrustFile
    private var unsaved: [UnsavedPin] = []

    public convenience init() {
        self.init(directory: StoreFiles.defaultDirectory)
    }

    /// Keeps escl-trust.json in `directory` (tests).
    public init(directory: URL) {
        url = directory.appendingPathComponent(EsclTrustStore.fileName)
        file = StoreFiles.load(EsclTrustFile.self, from: url) ?? EsclTrustFile()
    }

    /// Whether `fingerprint` may be trusted for the scanner with `deviceUuid` (nil when unknown) at
    /// `authority`. A pinned public key is trusted wherever it shows up (only the scanner holds its
    /// private key); the address it was reached at, and the scanner's UUID when the pin did not have
    /// one, are remembered. Otherwise, a scanner trusted before with another key (the same UUID, or,
    /// when either UUID is unknown, the same address) is `changed`, with that entry as `previous`. A
    /// pinned key that claims the UUID of a scanner trusted with another key is `changed` too: a key
    /// vouches only for the scanner it was trusted for.
    public func check(_ fingerprint: String, deviceUuid: String?, authority: String) -> EsclTrustCheck {
        if fingerprint.isEmpty {
            return EsclTrustCheck(verdict: .invalid)
        }
        let uuid: String = EsclTxtRecord.uuidKey(deviceUuid) ?? ""
        let address: String = authority.lowercased()
        lock.lock()
        defer { lock.unlock() }
        reload()
        if let index = file.certificates.firstIndex(where: { $0.fingerprint == fingerprint }) {
            var pinned: EsclTrustedCertificate = file.certificates[index]
            if !uuid.isEmpty && pinned.deviceUuid != uuid,
               let other = file.certificates.first(where: { $0.deviceUuid == uuid }) {
                return EsclTrustCheck(verdict: .changed, previous: other)
            }
            var learned = false
            if pinned.deviceUuid.isEmpty && !uuid.isEmpty {
                pinned.deviceUuid = uuid
                learned = true
            }
            if !pinned.addresses.contains(address) {
                pinned.addresses.append(address)
                if pinned.addresses.count > EsclTrustStore.maxAddresses {
                    pinned.addresses.removeFirst()
                }
                learned = true
            }
            if learned {
                file.certificates[index] = pinned
                // An unsaved pin is the same entry: it learns too.
                for k in unsaved.indices where unsaved[k].pin.fingerprint == fingerprint {
                    unsaved[k].pin = pinned
                }
                save()
            }
            return EsclTrustCheck(verdict: .trusted)
        }
        let previous: EsclTrustedCertificate? = file.certificates.first(where: {
            EsclTrustStore.sameScanner($0, uuid: uuid, address: address)
        })
        return EsclTrustCheck(verdict: previous == nil ? .unknown : .changed, previous: previous)
    }

    /// Trusts `fingerprint` for a scanner, replacing whatever was trusted for that scanner before (see
    /// `check`), and saves the file. Throws `EsclTrustStoreError.noCertificate` for an empty one.
    public func trust(_ fingerprint: String, deviceUuid: String?, authority: String, name: String) throws {
        if fingerprint.isEmpty {
            throw EsclTrustStoreError.noCertificate
        }
        let uuid: String = EsclTxtRecord.uuidKey(deviceUuid) ?? ""
        let address: String = authority.lowercased()
        lock.lock()
        defer { lock.unlock() }
        reload()
        unsaved.removeAll(where: { EsclTrustStore.replaces($0.pin, fingerprint: fingerprint, uuid: uuid, address: address) })
        file.certificates.removeAll(where: { EsclTrustStore.replaces($0, fingerprint: fingerprint, uuid: uuid, address: address) })
        var pin = EsclTrustedCertificate()
        pin.fingerprint = fingerprint
        pin.deviceUuid = uuid
        pin.addresses = [address]
        pin.name = name
        pin.trusted = Date()
        file.certificates.append(pin)
        if !save() {
            unsaved.append(UnsavedPin(pin: pin, address: address))
        }
    }

    /// The trusted certificates.
    public var certificates: [EsclTrustedCertificate] {
        lock.lock()
        defer { lock.unlock() }
        return file.certificates
    }

    /// Re-reads the file (with the lock held): another part of the app may have trusted or replaced a
    /// certificate meanwhile, and writing the copy loaded earlier would undo that. Certificates trusted
    /// here that could not be saved are applied to it again. A file that cannot be loaded keeps what
    /// is in memory, unsaved pins included.
    private func reload() {
        guard var loaded = StoreFiles.load(EsclTrustFile.self, from: url) else { return }
        for entry in unsaved {
            loaded.certificates.removeAll(where: {
                EsclTrustStore.replaces($0, fingerprint: entry.pin.fingerprint, uuid: entry.pin.deviceUuid,
                                        address: entry.address)
            })
            loaded.certificates.append(entry.pin)
        }
        file = loaded
    }

    /// Writes the file (with the lock held); false when it could not be written.
    @discardableResult
    private func save() -> Bool {
        guard StoreFiles.write(file, to: url) else { return false }
        unsaved.removeAll()
        return true
    }

    /// Whether trusting `fingerprint` for that scanner replaces `entry`.
    private static func replaces(_ entry: EsclTrustedCertificate, fingerprint: String, uuid: String,
                                 address: String) -> Bool {
        entry.fingerprint == fingerprint || sameScanner(entry, uuid: uuid, address: address)
    }

    private static func sameScanner(_ entry: EsclTrustedCertificate, uuid: String, address: String) -> Bool {
        if !uuid.isEmpty && !entry.deviceUuid.isEmpty {
            return entry.deviceUuid == uuid
        }
        return entry.addresses.contains(address)
    }
}

/// A scanner's certificate was refused: not trusted yet, changed, or unusable. The twin of C#
/// `EsclCertificateException`, with the same messages.
public struct EsclCertificateError: Error, Equatable, LocalizedError, Sendable {
    public let verdict: EsclTrustVerdict
    public let deviceName: String
    /// The scanner's UUID as known when connecting; nil when unknown.
    public let deviceUuid: String?
    /// "host:port" the certificate was presented at.
    public let authority: String
    /// SPKI SHA-256 of the presented certificate, lowercase hex ("" when there was none).
    public let fingerprint: String
    /// The certificate's subject as the platform names it; "" when there was none.
    public let subject: String
    /// The previously trusted certificate, for `changed`.
    public let previous: EsclTrustedCertificate?

    public init(verdict: EsclTrustVerdict, deviceName: String, deviceUuid: String?, authority: String,
                fingerprint: String, subject: String, previous: EsclTrustedCertificate? = nil) {
        self.verdict = verdict
        self.deviceName = deviceName
        self.deviceUuid = deviceUuid
        self.authority = authority
        self.fingerprint = fingerprint
        self.subject = subject
        self.previous = previous
    }

    /// The certificate can be trusted by the user (it exists and can be pinned).
    public var canTrust: Bool {
        (verdict == .unknown || verdict == .changed) && !fingerprint.isEmpty
    }

    public var message: String {
        switch verdict {
        case .changed:
            return "The security certificate of \(deviceName) has changed since you trusted it, so CompleteScanner did not connect. "
                + "A firmware update or a reset of the scanner can change it, but so can another device pretending to be your scanner."
        case .invalid:
            return "\(deviceName) did not present a usable security certificate, so CompleteScanner did not connect."
        default:
            return "\(deviceName) uses a security certificate that has not been trusted yet, so CompleteScanner did not connect."
        }
    }

    public var errorDescription: String? { message }
}

/// Fingerprints of scanner certificates.
public enum EsclCertificates {
    /// SHA-256 of the certificate's SubjectPublicKeyInfo, lowercase hex (the key, not the whole
    /// certificate, is pinned), from the certificate's DER (`SecCertificateCopyData`); nil when the
    /// bytes are not one well-formed certificate.
    public static func fingerprint(certificateDER: Data) -> String? {
        guard let digest = SpkiFingerprint.of(certificateDER) else { return nil }
        return SpkiFingerprint.hex(digest)
    }

    /// "AB:CD:…" for people to compare; groups of `bytesPerLine` bytes per line when positive.
    public static func format(_ fingerprint: String, bytesPerLine: Int = 0) -> String {
        let characters: [Character] = Array(fingerprint)
        var pairs: [String] = []
        var index = 0
        while index + 1 < characters.count {
            pairs.append((String(characters[index]) + String(characters[index + 1])).uppercased())
            index += 2
        }
        if bytesPerLine <= 0 {
            return pairs.joined(separator: ":")
        }
        var lines: [String] = []
        var start = 0
        while start < pairs.count {
            let end: Int = Swift.min(start + bytesPerLine, pairs.count)
            lines.append(pairs[start..<end].joined(separator: ":"))
            start = end
        }
        return lines.joined(separator: "\n")
    }
}

/// Checks the certificates one scanner presents, against `EsclTrustStore`. A certificate the system
/// accepts (valid chain, matching name) is trusted as is; any other is trusted only when pinned, or,
/// for `firstUse`, provisionally until `rememberDevice`. A refusal is kept for `takeRejection`, since
/// the HTTP stack reports it only as a failed connection. Safe to use from any thread.
///
/// `firstUse` is the fingerprint of a certificate the store does not know (`unknown`) that may be used
/// to ask the scanner who it is: it is accepted without being pinned, and `rememberDevice` pins it once
/// the scanner's UUID shows it is not another key for a scanner trusted before (trust on first use).
public final class EsclCertificateValidator: @unchecked Sendable {
    /// A certificate accepted, where, and whether it was pinned or only accepted as `firstUse`.
    private struct Accepted {
        let fingerprint: String
        let authority: String
        let subject: String
        var pinned: Bool
    }

    private let store: EsclTrustStore
    private let lock = NSLock()
    private var rejection: EsclCertificateError?
    /// The certificate accepted last.
    private var accepted: Accepted?
    private var firstUse: String?

    public let deviceName: String
    public let deviceUuid: String?

    public init(store: EsclTrustStore, deviceUuid: String?, deviceName: String, firstUse: String? = nil) {
        self.store = store
        self.deviceUuid = deviceUuid
        self.deviceName = deviceName
        self.firstUse = firstUse
    }

    /// The TLS check for a request to `url`: `certificateDER` is the leaf certificate the scanner
    /// presented (nil when none), `subject` its subject as the platform names it, and `systemTrusted`
    /// whether the system's own evaluation accepted it. A certificate whose public key cannot be found
    /// is refused as `invalid`.
    public func validate(url: URL?, certificateDER: Data?, subject: String, systemTrusted: Bool) -> Bool {
        if systemTrusted && certificateDER != nil {
            return true
        }
        var authority: String = ""
        if let target = url {
            authority = EsclCertificateValidator.authorityOf(target)
        }
        guard let der = certificateDER else {
            setRejection(EsclCertificateError(verdict: .invalid, deviceName: deviceName, deviceUuid: deviceUuid,
                                              authority: authority, fingerprint: "", subject: ""))
            return false
        }
        guard let fingerprint = EsclCertificates.fingerprint(certificateDER: der) else {
            setRejection(EsclCertificateError(verdict: .invalid, deviceName: deviceName, deviceUuid: deviceUuid,
                                              authority: authority, fingerprint: "", subject: subject))
            return false
        }
        let check: EsclTrustCheck = store.check(fingerprint, deviceUuid: deviceUuid, authority: authority)
        lock.lock()
        let isFirstUse: Bool = check.verdict == .unknown && fingerprint == firstUse
        if check.verdict == .trusted || isFirstUse {
            accepted = Accepted(fingerprint: fingerprint, authority: authority, subject: subject,
                                pinned: check.verdict == .trusted)
            lock.unlock()
            return true
        }
        lock.unlock()
        setRejection(EsclCertificateError(verdict: check.verdict, deviceName: deviceName, deviceUuid: deviceUuid,
                                          authority: authority, fingerprint: fingerprint, subject: subject,
                                          previous: check.previous))
        return false
    }

    /// Checks the certificate the scanner was reached through against the UUID it reported (its
    /// capabilities). A pinned certificate learns the UUID when it did not have it yet: a certificate
    /// trusted for an address added by hand then also identifies the scanner when discovery finds it.
    /// A `firstUse` certificate is pinned now, with the UUID. Throws `EsclCertificateError` (`changed`,
    /// nothing pinned or learned) when another certificate is trusted for that scanner.
    public func rememberDevice(_ deviceUuid: String?) throws {
        lock.lock()
        let current: Accepted? = accepted
        lock.unlock()
        guard let chosen = current else { return }
        if chosen.pinned && deviceUuid == nil {
            return
        }
        let uuid: String? = deviceUuid ?? self.deviceUuid
        let check: EsclTrustCheck = store.check(chosen.fingerprint, deviceUuid: uuid, authority: chosen.authority)
        if check.verdict == .changed {
            throw EsclCertificateError(verdict: .changed, deviceName: deviceName, deviceUuid: uuid,
                                       authority: chosen.authority, fingerprint: chosen.fingerprint,
                                       subject: chosen.subject, previous: check.previous)
        }
        if chosen.pinned {
            return
        }
        if check.verdict == .unknown {
            try store.trust(chosen.fingerprint, deviceUuid: uuid, authority: chosen.authority, name: deviceName)
        }
        var updated: Accepted = chosen
        updated.pinned = true
        lock.lock()
        firstUse = nil
        accepted = updated
        lock.unlock()
    }

    /// The last refusal, cleared by reading it; nil when nothing was refused since.
    public func takeRejection() -> EsclCertificateError? {
        lock.lock()
        defer { lock.unlock() }
        let taken: EsclCertificateError? = rejection
        rejection = nil
        return taken
    }

    /// "host:port" of a request, in the form `ScannerAddress.authority` uses.
    static func authorityOf(_ url: URL) -> String {
        EsclUrlText.authority(url.absoluteString)
    }

    private func setRejection(_ error: EsclCertificateError) {
        lock.lock()
        rejection = error
        lock.unlock()
    }
}
