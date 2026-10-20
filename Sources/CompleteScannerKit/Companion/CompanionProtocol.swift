import Foundation

// Twin of windows/CompleteScanner.Core/Companion/CompanionProtocol.cs: the same constants, the same
// JSON bytes for the same message and the same lenient reading, so the phone (Swift) and the desktop
// (C# now, Swift on the Mac later) speak exactly one protocol.

/// The companion link between a paired phone and the desktop app: HTTP/1.1 over TLS, the phone always
/// starting the connection. The desktop's certificate is pinned by its `SpkiFingerprint` from the
/// pairing code; every request after pairing carries the phone's device secret as a bearer token with
/// its id. Endpoints (all JSON unless noted):
/// - `GET /v1/health`: reachability, answered to anyone (`HealthResponse`; with credentials it also
///   says whether the phone is still paired, a wrong secret gets 401).
/// - `POST /v1/pair`: the one call an unpaired phone may make, with the pairing code's token
///   (`PairRequest` → `PairResponse`).
/// - `GET /v1/hello`: the desktop's name, its queue and its upload limit (`HelloResponse`).
/// - `PUT /v1/inbox/{packageId}`: a `.csdoc` package (`CompanionPackage`), idempotent by package id
///   (`InboxResponse`); `X-Target: new|current`.
/// - `GET /v1/outbox[?wait=seconds]`, `GET /v1/outbox/{id}` (the file), `DELETE /v1/outbox/{id}`:
///   what the desktop sends the phone (`OutboxList`).
/// - `DELETE /v1/devices/self`: the phone forgets this desktop.
/// Errors are `CompanionError` with a stable code (`CompanionErrorCode`).
public enum CompanionProtocol {
    /// The protocol version, in the pairing code and every response.
    public static let version = 1
    /// The DNS-SD service type the desktop advertises while it receives.
    public static let serviceType = "_completescan._tcp"
    /// The `service` value of `HealthResponse`.
    public static let serviceName = "completescanner"
    /// The port the desktop tries first; another free one is used when it is taken.
    public static let defaultPort = 52731

    public static let healthPath = "/v1/health"
    public static let pairPath = "/v1/pair"
    public static let helloPath = "/v1/hello"
    /// Followed by the package id.
    public static let inboxPrefix = "/v1/inbox/"
    public static let outboxPath = "/v1/outbox"
    /// Followed by the outbox item's id.
    public static let outboxPrefix = "/v1/outbox/"
    public static let deviceSelfPath = "/v1/devices/self"

    /// The phone's id, sent with its secret on every request after pairing.
    public static let deviceIdHeader = "X-Device-Id"
    /// Where an upload goes: `new` (a document of its own, the default) or `current`.
    public static let targetHeader = "X-Target"
    public static let jsonContentType = "application/json; charset=utf-8"
    public static let packageContentType = "application/vnd.completescanner.document"

    /// The largest JSON request body (a pairing request).
    public static let maxJsonBodyBytes = 8192
    /// The longest an outbox listing waits for something to arrive.
    public static let maxOutboxWaitSeconds = 25
    /// The DNS-SD TXT keys: the protocol version and the desktop's id.
    public static let txtVersionKey = "v"
    public static let txtIdKey = "id"

    /// The largest upload: a package's pictures may hold `ZipReadLimits.maxTotalBytes`, plus room for
    /// its manifest and zip headers.
    public static var maxUploadBytes: Int { ZipReadLimits.standard.maxTotalBytes + 16 * 1024 * 1024 }

    /// The page strip's label of a page that came from a paired phone.
    public static let pageLabel = "From phone"
    public static let pageLabelHelp = "Sent from a paired phone"

    /// Whether `id` can be a phone's, desktop's, package's or outbox item's id: 8 to 64 characters,
    /// letters, digits, '-' and '_' (safe as a file name everywhere).
    public static func isValidId(_ id: String?) -> Bool {
        guard let id = id, id.utf16.count >= 8, id.utf16.count <= 64 else { return false }
        for scalar in id.unicodeScalars {
            switch scalar.value {
            case 97...122, 65...90, 48...57, 45, 95: continue
            default: return false
            }
        }
        return true
    }

    private static let base64UrlAlphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".utf8)

    /// Base64url without padding (RFC 4648 section 5).
    public static func encodeBase64Url(_ data: Data) -> String {
        let bytes = [UInt8](data)
        var text: [UInt8] = []
        text.reserveCapacity((bytes.count * 4 + 2) / 3)
        var i = 0
        while i + 3 <= bytes.count {
            let block = Int(bytes[i]) << 16 | Int(bytes[i + 1]) << 8 | Int(bytes[i + 2])
            text.append(base64UrlAlphabet[(block >> 18) & 63])
            text.append(base64UrlAlphabet[(block >> 12) & 63])
            text.append(base64UrlAlphabet[(block >> 6) & 63])
            text.append(base64UrlAlphabet[block & 63])
            i += 3
        }
        let rest = bytes.count - i
        if rest == 1 {
            let block = Int(bytes[i]) << 16
            text.append(base64UrlAlphabet[(block >> 18) & 63])
            text.append(base64UrlAlphabet[(block >> 12) & 63])
        } else if rest == 2 {
            let block = Int(bytes[i]) << 16 | Int(bytes[i + 1]) << 8
            text.append(base64UrlAlphabet[(block >> 18) & 63])
            text.append(base64UrlAlphabet[(block >> 12) & 63])
            text.append(base64UrlAlphabet[(block >> 6) & 63])
        }
        return String(decoding: text, as: UTF8.self)
    }

    /// The bytes of base64url text without padding; nil for anything else: padding, other characters,
    /// a length no encoding has, or unused bits that are not zero (so every value has exactly one text).
    public static func decodeBase64Url(_ text: String?) -> Data? {
        guard let text = text else { return nil }
        let characters = Array(text.utf16)
        guard characters.count % 4 != 1 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(characters.count * 3 / 4)
        var bits = 0
        var bitCount = 0
        for character in characters {
            let value: Int
            switch character {
            case 65...90: value = Int(character) - 65
            case 97...122: value = Int(character) - 97 + 26
            case 48...57: value = Int(character) - 48 + 52
            case 45: value = 62
            case 95: value = 63
            default: return nil
            }
            bits = (bits << 6) | value
            bitCount += 6
            if bitCount >= 8 {
                bitCount -= 8
                bytes.append(UInt8(truncatingIfNeeded: bits >> bitCount))
                bits &= (1 << bitCount) - 1
            }
        }
        guard bits == 0 else { return nil }
        return Data(bytes)
    }

    /// The target an `X-Target` value names; `.new` when missing or unknown.
    public static func target(_ value: String?) -> CompanionTarget {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed == "current" ? .current : .new
    }

    /// The `X-Target` value for `target`.
    public static func targetValue(_ target: CompanionTarget) -> String {
        target == .current ? "current" : "new"
    }

    /// "3 pages from Aytu's iPhone added to the queue."
    public static func addedMessage(_ pageCount: Int, phoneName: String) -> String {
        "\(pageCount == 1 ? "1 page" : "\(pageCount) pages") from \(phoneName) added to the queue."
    }

    static func integer(_ value: Int) -> String { String(value) }

    static func bool(_ value: Bool) -> String { value ? "true" : "false" }

    /// `json` read as `T` the way settings files are read (every property on its own, defaults for
    /// anything missing or wrong-typed); nil when it is not a JSON object.
    static func decode<T: Decodable>(_ type: T.Type, _ json: Data) -> T? {
        try? JSONDecoder().decode(type, from: json)
    }
}

/// Where an upload goes on the desktop.
public enum CompanionTarget: String, Equatable, Sendable {
    /// The pages are added to the queue as a document of their own.
    case new
    /// The pages are added to the document the desktop has open (its queue).
    case current
}

/// The stable error codes of `CompanionError`.
public enum CompanionErrorCode {
    public static let unauthorized = "unauthorized"
    public static let pairingClosed = "pairingClosed"
    public static let tokenInvalid = "tokenInvalid"
    public static let tokenExpired = "tokenExpired"
    public static let tokenUsed = "tokenUsed"
    public static let declined = "declined"
    public static let tooManyDevices = "tooManyDevices"
    public static let tooLarge = "tooLarge"
    public static let invalidPackage = "invalidPackage"
    public static let rateLimited = "rateLimited"
    public static let notFound = "notFound"
    public static let methodNotAllowed = "methodNotAllowed"
    public static let badRequest = "badRequest"
    public static let lengthRequired = "lengthRequired"
    public static let busy = "busy"
    public static let serverError = "serverError"
}

/// What went wrong, for the phone: a stable `code` and a sentence to show.
public struct CompanionError: Equatable, Sendable {
    public var code: String
    public var message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    public func toJSON() -> String {
        "{\"error\":\(CompanionPackage.quote(code)),\"message\":\(CompanionPackage.quote(message))}"
    }

    public static func fromJSON(_ json: Data) -> CompanionError? {
        guard let dto = CompanionProtocol.decode(ErrorDTO.self, json), !dto.error.isEmpty else { return nil }
        return CompanionError(code: dto.error, message: dto.message)
    }

    public static let unauthorized = CompanionError(
        code: CompanionErrorCode.unauthorized, message: "This computer no longer recognizes this phone. Pair it again.")
    public static let pairingClosed = CompanionError(
        code: CompanionErrorCode.pairingClosed,
        message: "Pairing is not open on this computer. Choose Pair a phone there and scan the new code.")
    public static let tokenInvalid = CompanionError(
        code: CompanionErrorCode.tokenInvalid, message: "This pairing code is not valid. Scan the code shown on the computer again.")
    public static let tokenExpired = CompanionError(
        code: CompanionErrorCode.tokenExpired, message: "This pairing code has expired. Show a new code on the computer.")
    public static let tokenUsed = CompanionError(
        code: CompanionErrorCode.tokenUsed, message: "This pairing code was already used. Show a new code on the computer.")
    public static let declined = CompanionError(code: CompanionErrorCode.declined, message: "Pairing was declined on the computer.")
    public static let tooManyDevices = CompanionError(
        code: CompanionErrorCode.tooManyDevices,
        message: "This computer is paired with \(PairedDeviceStore.maxDevices) phones already. Remove one there first.")
    public static let tooLarge = CompanionError(
        code: CompanionErrorCode.tooLarge, message: "This document is too large to send in one piece.")
    public static let rateLimited = CompanionError(
        code: CompanionErrorCode.rateLimited, message: "Too many attempts. Wait a minute, then try again.")
    public static let notFound = CompanionError(code: CompanionErrorCode.notFound, message: "Not found.")
    public static let methodNotAllowed = CompanionError(
        code: CompanionErrorCode.methodNotAllowed, message: "This address does not take that request.")
    public static let badRequest = CompanionError(code: CompanionErrorCode.badRequest, message: "The request was not understood.")
    public static let lengthRequired = CompanionError(
        code: CompanionErrorCode.lengthRequired, message: "The request must say how long it is (Content-Length).")
    public static let busy = CompanionError(
        code: CompanionErrorCode.busy, message: "This document is still being received. Try again in a moment.")
    public static let serverError = CompanionError(
        code: CompanionErrorCode.serverError, message: "The computer could not store this document.")
}

/// The body of `POST /v1/pair`: the pairing code's token and who the phone is.
public struct PairRequest: Equatable, Sendable {
    public var token: String
    public var phoneId: String
    public var phoneName: String
    public var platform: String
    public var appVersion: String

    /// The longest phone name kept, in UTF-8 bytes (longer names are cut).
    public static let maxNameBytes = 128

    public init(token: String, phoneId: String, phoneName: String, platform: String, appVersion: String) {
        self.token = token
        self.phoneId = phoneId
        self.phoneName = phoneName
        self.platform = platform
        self.appVersion = appVersion
    }

    public func toJSON() -> String {
        "{\"token\":\(CompanionPackage.quote(token)),\"phoneId\":\(CompanionPackage.quote(phoneId))"
            + ",\"phoneName\":\(CompanionPackage.quote(phoneName)),\"platform\":\(CompanionPackage.quote(platform))"
            + ",\"appVersion\":\(CompanionPackage.quote(appVersion))}"
    }

    public static func fromJSON(_ json: Data) -> PairRequest? {
        guard let dto = CompanionProtocol.decode(PairRequestDTO.self, json) else { return nil }
        return PairRequest(token: dto.token, phoneId: dto.phoneId, phoneName: dto.phoneName, platform: dto.platform,
                           appVersion: dto.appVersion)
    }
}

/// The answer to a pairing the user allowed: who the desktop is and the phone's secret.
public struct PairResponse: Equatable, Sendable {
    public var desktopId: String
    public var desktopName: String
    public var deviceSecret: String
    public var protocolVersion: Int

    public init(desktopId: String, desktopName: String, deviceSecret: String, protocolVersion: Int) {
        self.desktopId = desktopId
        self.desktopName = desktopName
        self.deviceSecret = deviceSecret
        self.protocolVersion = protocolVersion
    }

    public func toJSON() -> String {
        "{\"protocolVersion\":\(CompanionProtocol.integer(protocolVersion)),\"desktopId\":\(CompanionPackage.quote(desktopId))"
            + ",\"desktopName\":\(CompanionPackage.quote(desktopName)),\"deviceSecret\":\(CompanionPackage.quote(deviceSecret))}"
    }

    public static func fromJSON(_ json: Data) -> PairResponse? {
        guard let dto = CompanionProtocol.decode(PairResponseDTO.self, json) else { return nil }
        return PairResponse(desktopId: dto.desktopId, desktopName: dto.desktopName, deviceSecret: dto.deviceSecret,
                            protocolVersion: Int(dto.protocolVersion))
    }
}

/// The answer to `GET /v1/health`; `paired` only when the phone sent valid credentials.
public struct HealthResponse: Equatable, Sendable {
    public var protocolVersion: Int
    public var paired: Bool

    public init(protocolVersion: Int, paired: Bool) {
        self.protocolVersion = protocolVersion
        self.paired = paired
    }

    public func toJSON() -> String {
        "{\"service\":\(CompanionPackage.quote(CompanionProtocol.serviceName))"
            + ",\"protocolVersion\":\(CompanionProtocol.integer(protocolVersion)),\"paired\":\(CompanionProtocol.bool(paired))}"
    }

    /// nil unless the body says it is CompleteScanner's.
    public static func fromJSON(_ json: Data) -> HealthResponse? {
        guard let dto = CompanionProtocol.decode(HealthDTO.self, json), dto.service == CompanionProtocol.serviceName else {
            return nil
        }
        return HealthResponse(protocolVersion: Int(dto.protocolVersion), paired: dto.paired)
    }
}

/// The answer to `GET /v1/hello`: the desktop, the pages in its queue, the largest upload it takes.
public struct HelloResponse: Equatable, Sendable {
    public var desktopId: String
    public var desktopName: String
    public var protocolVersion: Int
    public var queuedPages: Int
    public var maxUploadBytes: Int

    public init(desktopId: String, desktopName: String, protocolVersion: Int, queuedPages: Int, maxUploadBytes: Int) {
        self.desktopId = desktopId
        self.desktopName = desktopName
        self.protocolVersion = protocolVersion
        self.queuedPages = queuedPages
        self.maxUploadBytes = maxUploadBytes
    }

    public func toJSON() -> String {
        "{\"protocolVersion\":\(CompanionProtocol.integer(protocolVersion)),\"desktopId\":\(CompanionPackage.quote(desktopId))"
            + ",\"desktopName\":\(CompanionPackage.quote(desktopName)),\"queuedPages\":\(CompanionProtocol.integer(queuedPages))"
            + ",\"maxUploadBytes\":\(CompanionProtocol.integer(maxUploadBytes))}"
    }

    public static func fromJSON(_ json: Data) -> HelloResponse? {
        guard let dto = CompanionProtocol.decode(HelloDTO.self, json) else { return nil }
        return HelloResponse(desktopId: dto.desktopId, desktopName: dto.desktopName, protocolVersion: Int(dto.protocolVersion),
                             queuedPages: Int(dto.queuedPages), maxUploadBytes: Int(dto.maxUploadBytes))
    }
}

/// The answer to an upload: the package, its pages, and whether it had arrived before.
public struct InboxResponse: Equatable, Sendable {
    public var packageId: String
    public var pageCount: Int
    public var duplicate: Bool

    public init(packageId: String, pageCount: Int, duplicate: Bool) {
        self.packageId = packageId
        self.pageCount = pageCount
        self.duplicate = duplicate
    }

    public func toJSON() -> String {
        "{\"packageId\":\(CompanionPackage.quote(packageId)),\"pageCount\":\(CompanionProtocol.integer(pageCount))"
            + ",\"duplicate\":\(CompanionProtocol.bool(duplicate))}"
    }

    public static func fromJSON(_ json: Data) -> InboxResponse? {
        guard let dto = CompanionProtocol.decode(InboxDTO.self, json) else { return nil }
        return InboxResponse(packageId: dto.packageId, pageCount: Int(dto.pageCount), duplicate: dto.duplicate)
    }
}

/// A file waiting in a phone's outbox on the desktop.
public struct OutboxItem: Equatable, Sendable {
    public var id: String
    public var name: String
    public var contentType: String
    public var byteCount: Int
    public var created: Date

    public init(id: String, name: String, contentType: String, byteCount: Int, created: Date) {
        self.id = id
        self.name = name
        self.contentType = contentType
        self.byteCount = byteCount
        self.created = created
    }

    public func toJSON() -> String {
        "{\"id\":\(CompanionPackage.quote(id)),\"name\":\(CompanionPackage.quote(name))"
            + ",\"contentType\":\(CompanionPackage.quote(contentType)),\"byteCount\":\(CompanionProtocol.integer(byteCount))"
            + ",\"created\":\(CompanionPackage.quote(CompanionPackage.formatDate(created)))}"
    }
}

/// The answer to `GET /v1/outbox`: what waits for the phone, oldest first.
public struct OutboxList: Equatable, Sendable {
    public var items: [OutboxItem]

    public init(items: [OutboxItem]) {
        self.items = items
    }

    public func toJSON() -> String {
        "{\"items\":[\(items.map { $0.toJSON() }.joined(separator: ","))]}"
    }

    /// The listing; items without a valid id or with an unreadable date are left out.
    public static func fromJSON(_ json: Data) -> OutboxList? {
        guard let dto = CompanionProtocol.decode(OutboxListDTO.self, json) else { return nil }
        var items: [OutboxItem] = []
        for item in dto.items {
            guard CompanionProtocol.isValidId(item.id), let created = CompanionPackage.parseDate(item.created) else { continue }
            items.append(OutboxItem(id: item.id, name: item.name, contentType: item.contentType, byteCount: Int(item.byteCount),
                                    created: created))
        }
        return OutboxList(items: items)
    }
}

// MARK: - The messages as read: every property on its own and leniently (rule 6), the defaults below
// for anything missing, null, wrong-typed or unknown. Whole numbers decode as the C# twin's int and
// long, so both read the same values.

private struct ErrorDTO: Decodable {
    var error = ""
    var message = ""

    enum CodingKeys: String, CodingKey { case error, message }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        error = c.decodeLenient(forKey: .error, default: error)
        message = c.decodeLenient(forKey: .message, default: message)
    }
}

private struct PairRequestDTO: Decodable {
    var token = ""
    var phoneId = ""
    var phoneName = ""
    var platform = ""
    var appVersion = ""

    enum CodingKeys: String, CodingKey { case token, phoneId, phoneName, platform, appVersion }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        token = c.decodeLenient(forKey: .token, default: token)
        phoneId = c.decodeLenient(forKey: .phoneId, default: phoneId)
        phoneName = c.decodeLenient(forKey: .phoneName, default: phoneName)
        platform = c.decodeLenient(forKey: .platform, default: platform)
        appVersion = c.decodeLenient(forKey: .appVersion, default: appVersion)
    }
}

private struct PairResponseDTO: Decodable {
    var protocolVersion: Int32 = 0
    var desktopId = ""
    var desktopName = ""
    var deviceSecret = ""

    enum CodingKeys: String, CodingKey { case protocolVersion, desktopId, desktopName, deviceSecret }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = c.decodeLenient(forKey: .protocolVersion, default: protocolVersion)
        desktopId = c.decodeLenient(forKey: .desktopId, default: desktopId)
        desktopName = c.decodeLenient(forKey: .desktopName, default: desktopName)
        deviceSecret = c.decodeLenient(forKey: .deviceSecret, default: deviceSecret)
    }
}

private struct HealthDTO: Decodable {
    var service = ""
    var protocolVersion: Int32 = 0
    var paired = false

    enum CodingKeys: String, CodingKey { case service, protocolVersion, paired }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        service = c.decodeLenient(forKey: .service, default: service)
        protocolVersion = c.decodeLenient(forKey: .protocolVersion, default: protocolVersion)
        paired = c.decodeLenient(forKey: .paired, default: paired)
    }
}

private struct HelloDTO: Decodable {
    var protocolVersion: Int32 = 0
    var desktopId = ""
    var desktopName = ""
    var queuedPages: Int32 = 0
    var maxUploadBytes: Int64 = 0

    enum CodingKeys: String, CodingKey { case protocolVersion, desktopId, desktopName, queuedPages, maxUploadBytes }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = c.decodeLenient(forKey: .protocolVersion, default: protocolVersion)
        desktopId = c.decodeLenient(forKey: .desktopId, default: desktopId)
        desktopName = c.decodeLenient(forKey: .desktopName, default: desktopName)
        queuedPages = c.decodeLenient(forKey: .queuedPages, default: queuedPages)
        maxUploadBytes = c.decodeLenient(forKey: .maxUploadBytes, default: maxUploadBytes)
    }
}

private struct InboxDTO: Decodable {
    var packageId = ""
    var pageCount: Int32 = 0
    var duplicate = false

    enum CodingKeys: String, CodingKey { case packageId, pageCount, duplicate }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        packageId = c.decodeLenient(forKey: .packageId, default: packageId)
        pageCount = c.decodeLenient(forKey: .pageCount, default: pageCount)
        duplicate = c.decodeLenient(forKey: .duplicate, default: duplicate)
    }
}

private struct OutboxListDTO: Decodable {
    var items: [OutboxItemDTO] = []

    enum CodingKeys: String, CodingKey { case items }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = c.decodeLenient(forKey: .items, default: items)
    }
}

private struct OutboxItemDTO: Decodable {
    var id = ""
    var name = ""
    var contentType = ""
    var byteCount: Int64 = 0
    var created: String?

    enum CodingKeys: String, CodingKey { case id, name, contentType, byteCount, created }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.decodeLenient(forKey: .id, default: id)
        name = c.decodeLenient(forKey: .name, default: name)
        contentType = c.decodeLenient(forKey: .contentType, default: contentType)
        byteCount = c.decodeLenient(forKey: .byteCount, default: byteCount)
        created = c.decodeLenient(forKey: .created, default: created)
    }
}
