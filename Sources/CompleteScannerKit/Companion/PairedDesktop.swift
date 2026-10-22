import Foundation

// The phone's side of a pairing: the desktop it is paired with (companion-desktop.json). The desktop
// keeps its own list of phones (PairedDeviceStore.swift); this is what the phone keeps of it.

/// The desktop this phone is paired with: who it is, where it was reached and the key it is pinned
/// by. The device secret is not part of it (`CompanionSecretStore`).
public struct PairedDesktop: Codable, Equatable, Sendable {
    /// How many received outbox item ids are kept (`received`).
    public static let maxReceived = 200

    /// The desktop's id (`CompanionProtocol.isValidId`), from its pairing code and its answers.
    public var id = ""
    /// The desktop's name as it last gave it ("Office PC").
    public var name = ""
    /// Its certificate's `SpkiFingerprint`, base64url (43 characters), as the pairing code carried it.
    public var fingerprint = ""
    /// The addresses from the pairing code, tried in this order.
    public var addresses: [String] = []
    public var port = CompanionProtocol.defaultPort
    /// This phone's id for the desktop (`X-Device-Id`), made once and kept when pairing again.
    public var phoneId = ""
    public var pairedAt: Date?
    /// When the desktop last answered.
    public var lastSeen: Date?
    /// The ids of the outbox items taken from the desktop, oldest first, the last `maxReceived`: one the
    /// desktop lists again (its acknowledgement was lost) is acknowledged again, not saved twice.
    public var received: [String] = []
    /// The cloud sync folder documents go into when the desktop cannot be reached (C2), as the bookmark
    /// the shell made of the folder picked (`AppState.resolveSyncFolderBookmark` opens it); nil for none.
    public var syncFolderBookmark: Data?

    enum CodingKeys: String, CodingKey {
        case id, name, fingerprint, addresses, port, phoneId, pairedAt, lastSeen, received, syncFolderBookmark
    }

    public init() {}

    public init(id: String, name: String, fingerprint: String, addresses: [String], port: Int, phoneId: String,
                pairedAt: Date? = nil, lastSeen: Date? = nil) {
        self.id = id
        self.name = name
        self.fingerprint = fingerprint
        self.addresses = addresses
        self.port = port
        self.phoneId = phoneId
        self.pairedAt = pairedAt
        self.lastSeen = lastSeen
    }

    /// The fingerprint's bytes; nil when `fingerprint` is not 32 bytes of base64url.
    public var fingerprintBytes: Data? {
        guard let bytes = CompanionProtocol.decodeBase64Url(fingerprint), bytes.count == SpkiFingerprint.byteCount else {
            return nil
        }
        return bytes
    }

    /// Keeps `id` among the received ones, as the newest.
    public mutating func noteReceived(_ id: String) {
        received = Array((received.filter { $0 != id } + [id]).suffix(PairedDesktop.maxReceived))
    }

    /// A new phone id: 32 lowercase hex digits, as the desktop makes its own.
    public static func makePhoneId() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
}

extension PairedDesktop {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        id = c.decodeLenient(forKey: .id, default: id)
        name = c.decodeLenient(forKey: .name, default: name)
        fingerprint = c.decodeLenient(forKey: .fingerprint, default: fingerprint)
        addresses = c.decodeLenient(forKey: .addresses, default: addresses)
        port = c.decodeLenient(forKey: .port, default: port)
        phoneId = c.decodeLenient(forKey: .phoneId, default: phoneId)
        pairedAt = c.decodeLenient(forKey: .pairedAt, default: pairedAt)
        lastSeen = c.decodeLenient(forKey: .lastSeen, default: lastSeen)
        received = c.decodeLenient(forKey: .received, default: received)
        syncFolderBookmark = c.decodeLenient(forKey: .syncFolderBookmark, default: syncFolderBookmark)
    }
}
