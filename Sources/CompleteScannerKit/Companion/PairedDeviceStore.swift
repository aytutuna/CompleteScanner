import Foundation

// Twin of windows/CompleteScanner.Core/Companion/PairedDeviceStore.cs: the same rules for pairing,
// checking and removing phones; each platform keeps its own file in its own settings folder.

/// A phone paired with this desktop (an entry of companion-devices.json).
public struct PairedDevice: Codable, Equatable, Sendable {
    /// The phone's id (`CompanionProtocol.isValidId`), sent with every request.
    public var id = ""
    /// The phone's name as it gave it when pairing ("Aytu's iPhone").
    public var name = ""
    /// "ios", "ipados", "android"…, as the phone said.
    public var platform = ""
    public var appVersion = ""
    /// SHA-256 of the phone's secret, lowercase hex (`PairedDeviceStore.hashSecret`). The secret itself
    /// is never stored: a copy of this file does not let anyone pose as the phone.
    public var secretHash = ""
    public var paired: Date?
    /// When the phone last made a request, to the minute.
    public var lastSeen: Date?

    enum CodingKeys: String, CodingKey {
        case id, name, platform, appVersion, secretHash, paired, lastSeen
    }

    public init() {}
}

extension PairedDevice {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        id = c.decodeLenient(forKey: .id, default: id)
        name = c.decodeLenient(forKey: .name, default: name)
        platform = c.decodeLenient(forKey: .platform, default: platform)
        appVersion = c.decodeLenient(forKey: .appVersion, default: appVersion)
        secretHash = c.decodeLenient(forKey: .secretHash, default: secretHash)
        paired = c.decodeLenient(forKey: .paired, default: paired)
        lastSeen = c.decodeLenient(forKey: .lastSeen, default: lastSeen)
    }
}

/// The contents of companion-devices.json.
public struct PairedDevicesFile: Codable, Equatable, Sendable {
    /// This desktop's id for phones (32 hex digits), made on first use.
    public var desktopId = ""
    public var devices: [PairedDevice] = []

    enum CodingKeys: String, CodingKey {
        case desktopId, devices
    }

    public init() {}
}

extension PairedDevicesFile {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        desktopId = c.decodeLenient(forKey: .desktopId, default: desktopId)
        devices = c.decodeLenient(forKey: .devices, default: devices)
    }
}

/// Why a phone could not be paired.
public enum PairedDeviceStoreError: Error, Equatable, Sendable {
    case invalidId
    case invalidSecret
    /// `PairedDeviceStore.maxDevices` other phones are paired.
    case tooManyDevices
    /// The pairing could not be saved (a phone must not believe it is paired when it is not).
    case notSaved
}

/// The phones paired with this desktop (companion-devices.json in the settings folder, rule 6 of
/// CONTRACTS.md). Pairing makes a random 256-bit secret, hands it to the phone once and keeps only its
/// SHA-256; a request is accepted when its device id and secret match an entry. The file is re-read
/// for every check and before every change, so a phone removed elsewhere is refused at once; a phone
/// removed while the file could not be written stays removed for the rest of the session. Safe to use
/// from any thread.
public final class PairedDeviceStore: @unchecked Sendable {
    public static let fileName = "companion-devices.json"
    /// The secret's length in bytes.
    public static let secretByteCount = 32
    /// How many phones can be paired at once.
    public static let maxDevices = 16
    /// A phone's last-seen time is written at most this often.
    public static let lastSeenResolution: TimeInterval = 60

    private let url: URL
    private let lock = NSLock()
    private var file: PairedDevicesFile
    /// Phones removed in this session: never accepted again, whatever the file says.
    private var removed: Set<String> = []

    /// Called (on the thread that changed it) after a phone was paired or removed.
    public var onChange: (() -> Void)?

    public convenience init() {
        self.init(directory: StoreFiles.defaultDirectory)
    }

    /// Keeps companion-devices.json in `directory` (tests).
    public init(directory: URL) {
        url = directory.appendingPathComponent(PairedDeviceStore.fileName)
        file = PairedDeviceStore.load(url) ?? PairedDevicesFile()
    }

    /// This desktop's id; made and saved the first time it is asked for.
    public var desktopId: String {
        lock.lock()
        defer { lock.unlock() }
        reload()
        if !CompanionProtocol.isValidId(file.desktopId) {
            file.desktopId = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            StoreFiles.write(file, to: url)
        }
        return file.desktopId
    }

    /// The paired phones, in the order they were paired.
    public var devices: [PairedDevice] {
        lock.lock()
        defer { lock.unlock() }
        reload()
        return file.devices
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        reload()
        return file.devices.count
    }

    /// Pairs the phone `id` (pairing again replaces its entry and secret) and returns its new secret
    /// (base64url of 32 bytes), to be sent to the phone once.
    public func pair(id: String, name: String, platform: String, appVersion: String, now: Date) throws -> String {
        var generator = SystemRandomNumberGenerator()
        let secret = Data((0..<PairedDeviceStore.secretByteCount).map { _ in UInt8.random(in: UInt8.min...UInt8.max, using: &generator) })
        return try pair(id: id, name: name, platform: platform, appVersion: appVersion, now: now, secret: secret)
    }

    /// Same as `pair(id:name:platform:appVersion:now:)` with a given secret (tests).
    func pair(id: String, name: String, platform: String, appVersion: String, now: Date, secret: Data) throws -> String {
        guard CompanionProtocol.isValidId(id) else { throw PairedDeviceStoreError.invalidId }
        guard secret.count == PairedDeviceStore.secretByteCount else { throw PairedDeviceStoreError.invalidSecret }
        lock.lock()
        do {
            defer { lock.unlock() }
            reload()
            let others = file.devices.filter { $0.id != id }
            guard others.count < PairedDeviceStore.maxDevices else { throw PairedDeviceStoreError.tooManyDevices }
            var device = PairedDevice()
            device.id = id
            device.name = PairedDeviceStore.cleanName(name)
            device.platform = PairedDeviceStore.cleanName(platform)
            device.appVersion = PairedDeviceStore.cleanName(appVersion)
            device.secretHash = PairedDeviceStore.hashSecret(secret)
            device.paired = now
            device.lastSeen = now
            let previous = file.devices
            file.devices = others + [device]
            guard StoreFiles.write(file, to: url) else {
                file.devices = previous
                throw PairedDeviceStoreError.notSaved
            }
            removed.remove(id)
        }
        onChange?()
        return CompanionProtocol.encodeBase64Url(secret)
    }

    /// The paired phone `id` when `secret` is its secret (compared in constant time); nil otherwise.
    /// Records when it was last seen.
    public func authenticate(id: String?, secret: String?, now: Date) -> PairedDevice? {
        guard let id = id, CompanionProtocol.isValidId(id),
              let bytes = CompanionProtocol.decodeBase64Url(secret), bytes.count == PairedDeviceStore.secretByteCount
        else { return nil }
        let presented = PairedDeviceStore.hashSecret(bytes)
        lock.lock()
        defer { lock.unlock() }
        reload()
        guard !removed.contains(id), let index = file.devices.firstIndex(where: { $0.id == id }) else { return nil }
        let stored = file.devices[index].secretHash
        guard stored.utf8.count == 64, stored.utf8.count == presented.utf8.count else { return nil }
        var difference: UInt8 = 0
        for (a, b) in zip(stored.utf8, presented.utf8) {
            difference |= a ^ b
        }
        guard difference == 0 else { return nil }
        if let seen = file.devices[index].lastSeen, now.timeIntervalSince(seen) < PairedDeviceStore.lastSeenResolution, now >= seen {
            return file.devices[index]
        }
        file.devices[index].lastSeen = now
        StoreFiles.write(file, to: url)
        return file.devices[index]
    }

    /// Unpairs the phone `id`; it is refused from now on. False when it was not paired.
    @discardableResult
    public func remove(_ id: String) -> Bool {
        lock.lock()
        reload()
        removed.insert(id)
        let before = file.devices.count
        file.devices.removeAll { $0.id == id }
        let wasPaired = file.devices.count != before
        if wasPaired { StoreFiles.write(file, to: url) }
        lock.unlock()
        if wasPaired { onChange?() }
        return wasPaired
    }

    /// Unpairs every phone; returns how many were paired.
    @discardableResult
    public func removeAll() -> Int {
        lock.lock()
        reload()
        let count = file.devices.count
        for device in file.devices { removed.insert(device.id) }
        file.devices = []
        StoreFiles.write(file, to: url)
        lock.unlock()
        if count > 0 { onChange?() }
        return count
    }

    /// SHA-256 of a device secret's bytes, lowercase hex.
    public static func hashSecret(_ secret: Data) -> String {
        CompanionPackage.sha256Hex(secret)
    }

    /// A name as kept: control characters removed, trimmed, cut to `PairRequest.maxNameBytes` UTF-8 bytes.
    public static func cleanName(_ name: String?) -> String {
        var text = String.UnicodeScalarView()
        var bytes = 0
        for scalar in (name ?? "").unicodeScalars {
            if scalar.value < 0x20 || (scalar.value >= 0x7F && scalar.value <= 0x9F) { continue }
            let length = scalar.value < 0x80 ? 1 : scalar.value < 0x800 ? 2 : scalar.value < 0x10000 ? 3 : 4
            if bytes + length > PairRequest.maxNameBytes { break }
            bytes += length
            text.append(scalar)
        }
        return String(text).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Re-reads the file (with the lock held); an unreadable one keeps what was loaded.
    private func reload() {
        guard var loaded = PairedDeviceStore.load(url) else { return }
        if !CompanionProtocol.isValidId(loaded.desktopId) && CompanionProtocol.isValidId(file.desktopId) {
            loaded.desktopId = file.desktopId
        }
        file = loaded
    }

    /// The file as read under the settings-file rules; nil when there is none or it could not be read.
    private static func load(_ url: URL) -> PairedDevicesFile? {
        switch StoreFiles.read(PairedDevicesFile.self, from: url) {
        case .loaded(let loaded):
            return loaded
        case .missing:
            return nil
        case .corrupt(let error):
            StoreFiles.keepUnreadable(url, error: error)
            return nil
        case .inaccessible(let error):
            StoreFiles.leaveInaccessible(url, error: error)
            return nil
        }
    }
}
