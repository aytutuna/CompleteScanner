#if os(macOS)
import LazyScanKit
import Foundation
import Security

// Twin of windows/LazyScan.App/Services/Companion/CompanionCertificateStore.cs on the keychain.

/// The Mac's own identity for the phone link: a permanent P-256 key in the login keychain (tagged
/// `keyTag`, labelled `label`) and a self-signed certificate for it (`SelfSignedCertificate`, labelled
/// the same), which the keychain pairs into the `SecIdentity` the server serves with. Phones pin the
/// key, so the certificate is renewed with the same key `renewBefore` its end and every pin stays
/// valid; only `renew` (Reset pairing) makes a new key. The key never leaves the keychain.
final class CompanionCertificateStore: CompanionIdentity {
    static let label = "Lazy Scan companion"
    static let keyTag = Data("com.lazyscan.companion".utf8)
    static let renewBefore: TimeInterval = 60 * 24 * 60 * 60

    private let hostName: String
    private let lock = NSLock()

    /// `hostName` goes in the certificate's name ("Aytus-MacBook Lazy Scan").
    init(hostName: String) {
        self.hostName = hostName
    }

    func current(now: Date) throws -> SecIdentity {
        lock.lock()
        defer { lock.unlock() }
        for entry in try certificates() {
            // A certificate whose key was deleted pairs into no identity.
            guard let identity = CompanionCertificateStore.identity(for: entry.certificate) else { continue }
            if entry.notAfter > now.addingTimeInterval(CompanionCertificateStore.renewBefore) {
                removeOthers(keeping: entry.der)
                return identity
            }
            guard let key = CompanionCertificateStore.privateKey(of: identity) else { continue }
            let renewed = try addCertificate(for: key, now: now)
            removeOthers(keeping: renewed.der)
            return renewed.identity
        }
        let made = try makeIdentity(now: now)
        removeOthers(keeping: made.der)
        return made.identity
    }

    /// A new key and certificate; the others and their keys go only once it is in the keychain, so
    /// when it cannot be made the current one stays in use.
    func renew(now: Date) throws -> SecIdentity {
        lock.lock()
        defer { lock.unlock() }
        let made = try makeIdentity(now: now)
        removeOthers(keeping: made.der)
        return made.identity
    }

    // MARK: - Keychain

    /// The app's certificates, the one valid longest first.
    private func certificates() throws -> [(certificate: SecCertificate, der: Data, notAfter: Date)] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecAttrLabel as String: CompanionCertificateStore.label,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let items = result as? [Any] else {
            throw CompanionCertificateStore.failure("The keychain could not be read", status)
        }
        var found: [(certificate: SecCertificate, der: Data, notAfter: Date)] = []
        for item in items {
            let certificate = item as! SecCertificate
            let der = SecCertificateCopyData(certificate) as Data
            guard let notAfter = SelfSignedCertificate.notAfter(der) else { continue }
            found.append((certificate, der, notAfter))
        }
        found.sort { $0.notAfter > $1.notAfter }
        return found
    }

    /// A new permanent key with a certificate for it; the key is deleted again when the certificate
    /// cannot be added.
    private func makeIdentity(now: Date) throws -> (identity: SecIdentity, der: Data) {
        let privateAttributes: [String: Any] = [
            kSecAttrIsPermanent as String: true,
            kSecAttrApplicationTag as String: CompanionCertificateStore.keyTag,
            kSecAttrLabel as String: CompanionCertificateStore.label,
        ]
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecPrivateKeyAttrs as String: privateAttributes,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            let reason = error?.takeRetainedValue().localizedDescription ?? "unknown error"
            throw SelfSignedCertificateError("The key could not be made: \(reason)")
        }
        do {
            return try addCertificate(for: key, now: now)
        } catch {
            CompanionCertificateStore.delete(key)
            throw error
        }
    }

    private func addCertificate(for key: SecKey, now: Date) throws -> (identity: SecIdentity, der: Data) {
        let der = try SelfSignedCertificate.make(hostName: hostName, key: key, now: now)
        guard let certificate = SelfSignedCertificate.certificate(der) else {
            throw SelfSignedCertificateError("The certificate that was made does not read.")
        }
        let item: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: certificate,
            kSecAttrLabel as String: CompanionCertificateStore.label,
        ]
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else {
            throw CompanionCertificateStore.failure("The certificate could not be added to the keychain", added)
        }
        guard let identity = CompanionCertificateStore.identity(for: certificate) else {
            CompanionCertificateStore.delete(certificate)
            throw SelfSignedCertificateError("The keychain did not pair the key with its certificate.")
        }
        return (identity, der)
    }

    /// Removes the app's certificates but `der`, and their keys unless `der` has the same key. One that
    /// cannot be removed now goes the next time.
    private func removeOthers(keeping der: Data) {
        guard let others = try? certificates() else { return }
        let pin = SpkiFingerprint.of(der)
        for entry in others where entry.der != der {
            if SpkiFingerprint.of(entry.der) != pin, let identity = CompanionCertificateStore.identity(for: entry.certificate),
               let key = CompanionCertificateStore.privateKey(of: identity) {
                CompanionCertificateStore.delete(key)
            }
            CompanionCertificateStore.delete(entry.certificate)
        }
    }

    private static func identity(for certificate: SecCertificate) -> SecIdentity? {
        var identity: SecIdentity?
        guard SecIdentityCreateWithCertificate(nil, certificate, &identity) == errSecSuccess else { return nil }
        return identity
    }

    private static func privateKey(of identity: SecIdentity) -> SecKey? {
        var key: SecKey?
        guard SecIdentityCopyPrivateKey(identity, &key) == errSecSuccess else { return nil }
        return key
    }

    private static func delete(_ key: SecKey) {
        let query: [String: Any] = [kSecClass as String: kSecClassKey, kSecValueRef as String: key]
        SecItemDelete(query as CFDictionary)
    }

    private static func delete(_ certificate: SecCertificate) {
        let query: [String: Any] = [kSecClass as String: kSecClassCertificate, kSecValueRef as String: certificate]
        SecItemDelete(query as CFDictionary)
    }

    private static func failure(_ what: String, _ status: OSStatus) -> SelfSignedCertificateError {
        let reason = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
        return SelfSignedCertificateError("\(what): \(reason)")
    }
}
#endif
