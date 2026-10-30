#if os(iOS)
import LazyScanKit
import Foundation
import Security

/// A Keychain call that failed, with its status. Only a failed save is ever shown, as the pairing not
/// kept (`PairedDesktopStoreError`'s message).
public struct IOSKeychainError: Error, Equatable, LocalizedError {
    public let status: OSStatus

    public var errorDescription: String? { CompanionText.notSavedMessage }
}

/// The iPhone's `CompanionSecretStore`: each desktop's device secret as a generic password in the
/// Keychain (service `service`, account the desktop's id) and the sync key of its cloud folder next to it
/// (account "<desktopId>.sync", as `PairedDesktopStore` names it), readable only while the phone is
/// unlocked and never moved to another device, in a backup or otherwise.
public struct IOSCompanionSecrets: CompanionSecretStore {
    public static let service = "com.lazyscan.companion"

    /// The Keychain service the secrets are kept under (tests use one of their own).
    public let service: String

    public init(service: String = IOSCompanionSecrets.service) {
        self.service = service
    }

    public func save(_ secret: Data, for desktopId: String) throws {
        let deleted: OSStatus = SecItemDelete(query(desktopId) as CFDictionary)
        guard deleted == errSecSuccess || deleted == errSecItemNotFound else { throw IOSKeychainError(status: deleted) }
        var item: [String: Any] = query(desktopId)
        item[kSecValueData as String] = secret
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status: OSStatus = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw IOSKeychainError(status: status) }
    }

    public func load(for desktopId: String) throws -> Data? {
        var search: [String: Any] = query(desktopId)
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status: OSStatus = SecItemCopyMatching(search as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw IOSKeychainError(status: status) }
        return result as? Data
    }

    public func delete(for desktopId: String) throws {
        let status: OSStatus = SecItemDelete(query(desktopId) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw IOSKeychainError(status: status) }
    }

    private func query(_ desktopId: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: desktopId,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }
}
#endif
