import Foundation

/// Where the phone keeps the device secret each desktop gave it: the iPhone's Keychain, so a backup
/// or a copy of the app's files does not carry it. The desktop's sync key for the cloud sync folder
/// is kept there too, under "<desktopId>.sync". On the desktop the same store keeps each phone's sync
/// key under the phone's id (`PairedDeviceStore`).
public protocol CompanionSecretStore: Sendable {
    func save(_ secret: Data, for desktopId: String) throws
    /// nil when there is none.
    func load(for desktopId: String) throws -> Data?
    func delete(for desktopId: String) throws
}

/// Why a pairing could not be kept.
public enum PairedDesktopStoreError: Error, Equatable, LocalizedError, Sendable {
    /// The file could not be written (a phone must not believe it is paired when it is not).
    case notSaved

    public var errorDescription: String? { CompanionText.notSavedMessage }
}

/// The desktop this phone is paired with: companion-desktop.json in the folder the shell gives (the
/// iPhone's network folder, kept out of backups), following the settings-file rules (CONTRACTS.md,
/// rule 6), and its secret and sync key in the `CompanionSecretStore`. One desktop at a time; pairing
/// with another replaces it. Safe to use from any thread.
public final class PairedDesktopStore: @unchecked Sendable {
    public static let fileName = "companion-desktop.json"

    private let url: URL
    private let secrets: any CompanionSecretStore
    private let lock = NSLock()

    public init(directory: URL, secrets: any CompanionSecretStore) {
        url = directory.appendingPathComponent(PairedDesktopStore.fileName)
        self.secrets = secrets
    }

    /// The paired desktop; nil when there is none, or its file cannot be read or names no usable
    /// desktop.
    public func load() -> PairedDesktop? {
        lock.lock()
        defer { lock.unlock() }
        guard let desktop = StoreFiles.load(PairedDesktop.self, from: url), CompanionProtocol.isValidId(desktop.id),
              CompanionProtocol.isValidId(desktop.phoneId), desktop.fingerprintBytes != nil, !desktop.addresses.isEmpty
        else { return nil }
        return desktop
    }

    /// Keeps `desktop`, its `secret` and its `syncKey` (nil: it gave none, and one kept before goes),
    /// replacing the desktop paired before (whose secret and sync key go). Throws when the desktop or its
    /// secret cannot be kept; nothing of the new pairing stays then. A sync key that cannot be kept only
    /// leaves the phone without the sync folder.
    public func save(_ desktop: PairedDesktop, secret: Data, syncKey: Data? = nil) throws {
        lock.lock()
        defer { lock.unlock() }
        let previous = StoreFiles.load(PairedDesktop.self, from: url)
        try secrets.save(secret, for: desktop.id)
        guard StoreFiles.write(desktop, to: url) else {
            if previous?.id != desktop.id { try? secrets.delete(for: desktop.id) }
            throw PairedDesktopStoreError.notSaved
        }
        if let syncKey {
            try? secrets.save(syncKey, for: PairedDesktopStore.syncAccount(desktop.id))
        } else {
            try? secrets.delete(for: PairedDesktopStore.syncAccount(desktop.id))
        }
        if let previous = previous, previous.id != desktop.id, !previous.id.isEmpty {
            try? secrets.delete(for: previous.id)
            try? secrets.delete(for: PairedDesktopStore.syncAccount(previous.id))
        }
    }

    /// Writes what changed about the desktop (its name, when it was last seen); best effort.
    public func update(_ desktop: PairedDesktop) {
        lock.lock()
        defer { lock.unlock() }
        StoreFiles.write(desktop, to: url)
    }

    /// The secret of `desktop`; nil when there is none or it cannot be read.
    public func secret(for desktop: PairedDesktop) -> Data? {
        guard let secret = try? secrets.load(for: desktop.id), secret.count == PairedDeviceStore.secretByteCount else {
            return nil
        }
        return secret
    }

    /// The sync key `desktop` gave for the cloud sync folder; nil when it gave none or it cannot be read.
    public func syncKey(for desktop: PairedDesktop) -> Data? {
        guard let key = try? secrets.load(for: PairedDesktopStore.syncAccount(desktop.id)),
              key.count == SyncPackage.keyByteCount else { return nil }
        return key
    }

    /// Drops the secret and sync key of `desktop` (the desktop no longer knows this phone); the desktop
    /// stays, so the app can say which one to pair with again.
    public func forgetSecret(of desktop: PairedDesktop) {
        try? secrets.delete(for: desktop.id)
        try? secrets.delete(for: PairedDesktopStore.syncAccount(desktop.id))
    }

    /// Forgets the paired desktop, its secret and its sync key.
    public func remove() {
        lock.lock()
        defer { lock.unlock() }
        if let desktop = StoreFiles.load(PairedDesktop.self, from: url), !desktop.id.isEmpty {
            try? secrets.delete(for: desktop.id)
            try? secrets.delete(for: PairedDesktopStore.syncAccount(desktop.id))
        }
        try? FileManager.default.removeItem(at: url)
    }

    /// The `CompanionSecretStore` account the sync key of the desktop `id` is kept under.
    static func syncAccount(_ id: String) -> String {
        id + ".sync"
    }
}
