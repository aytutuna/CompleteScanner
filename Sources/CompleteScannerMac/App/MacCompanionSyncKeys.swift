#if os(macOS)
import CompleteScannerKit
import Foundation
import Security

// Where Windows protects a phone's sync key with the Data Protection API (PairedDevice.SyncKeyProtected
// in windows/LazyScan.Core/Companion/PairedDeviceStore.cs), the Mac keeps it in the login keychain.

/// The Mac's store for the phones' sync keys (C2, `PairedDeviceStore`'s `syncKeyStore`): each key as a
/// generic password in the login keychain (service `service`, account the phone's id). An app built with
/// swift build has no keychain entitlement, so these are the legacy keychain's items, as for
/// `CompanionCertificateStore`, not the data protection keychain's.
struct MacCompanionSyncKeys: CompanionSecretStore {
    static let service = "com.completescanner.companion.sync"
    static let label = "CompleteScanner cloud folder key"

    func save(_ key: Data, for phoneId: String) throws {
        let deleted = SecItemDelete(query(phoneId) as CFDictionary)
        guard deleted == errSecSuccess || deleted == errSecItemNotFound else { throw MacCompanionSyncKeys.failure(deleted) }
        var item = query(phoneId)
        item[kSecAttrLabel as String] = MacCompanionSyncKeys.label
        item[kSecValueData as String] = key
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw MacCompanionSyncKeys.failure(status) }
    }

    func load(for phoneId: String) throws -> Data? {
        var search = query(phoneId)
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(search as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw MacCompanionSyncKeys.failure(status) }
        return result as? Data
    }

    func delete(for phoneId: String) throws {
        let status = SecItemDelete(query(phoneId) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw MacCompanionSyncKeys.failure(status) }
    }

    private func query(_ phoneId: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: MacCompanionSyncKeys.service,
            kSecAttrAccount as String: phoneId,
        ]
    }

    private static func failure(_ status: OSStatus) -> NSError {
        NSError(domain: NSOSStatusErrorDomain, code: Int(status))
    }
}
#endif
