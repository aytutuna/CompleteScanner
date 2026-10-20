import Foundation

// Twin of windows/CompleteScanner.Core/Companion/PairingUri.cs: the same text for the same pairing
// code, the same checks and the same refusals.

/// Why a scanned code is not a pairing code this app can use.
public enum PairingUriErrorKind: Equatable, Sendable {
    /// Not a CompleteScanner pairing code at all (another app's QR code, a web address).
    case notPairingCode
    /// A pairing code of a newer protocol version than this app speaks.
    case newerVersion
    /// A CompleteScanner pairing code with a missing or malformed part.
    case damaged
}

/// A pairing code that cannot be used, with a message for the user.
public struct PairingUriError: LocalizedError, Equatable, Sendable {
    public let kind: PairingUriErrorKind
    public let message: String

    public init(_ kind: PairingUriErrorKind, _ message: String) {
        self.kind = kind
        self.message = message
    }

    public var errorDescription: String? { message }
}

/// What the desktop's QR code carries so a phone can pair with it, as a URI:
/// `completescanner://pair?v=1&id=…&n=…&fp=…&a=…&p=…&t=…`: the protocol version, the desktop's id
/// and name, its certificate's `SpkiFingerprint` (base64url), the addresses it listens on
/// (comma-separated, each percent-encoded), its port and the pairing session's one-time token
/// (base64url of 16 bytes). Values are percent-encoded UTF-8 (everything but letters, digits and
/// `-._~`); unknown parameters are ignored, so later versions can add some.
public struct PairingUri: Equatable, Sendable, CustomStringConvertible {
    public var desktopId: String
    public var name: String
    public var fingerprint: String
    public var addresses: [String]
    public var port: Int
    public var token: String

    public static let scheme = "completescanner"
    public static let prefix = "completescanner://pair?"
    /// The longest code read, in UTF-8 bytes.
    public static let maxLength = 2048
    public static let maxAddresses = 8
    /// The longest address, in characters.
    public static let maxAddressLength = 64
    /// The longest desktop name, in UTF-8 bytes.
    public static let maxNameBytes = 128
    /// The token's length in bytes.
    public static let tokenByteCount = 16

    public static let notPairingCodeMessage = "This is not a CompleteScanner pairing code."
    public static let newerVersionMessage =
        "This pairing code is from a newer version of CompleteScanner. Update the app on this phone, then scan it again."
    public static let damagedMessage =
        "This pairing code could not be read. Show the code on the computer again and scan it once more."

    public init(desktopId: String, name: String, fingerprint: String, addresses: [String], port: Int, token: String) {
        self.desktopId = desktopId
        self.name = name
        self.fingerprint = fingerprint
        self.addresses = addresses
        self.port = port
        self.token = token
    }

    /// The fingerprint's bytes; nil when `fingerprint` is not 32 bytes of base64url.
    public var fingerprintBytes: Data? {
        guard let bytes = CompanionProtocol.decodeBase64Url(fingerprint), bytes.count == SpkiFingerprint.byteCount else {
            return nil
        }
        return bytes
    }

    /// The code as text. Throws `PairingUriError` (`.damaged`) for a code `parse` would refuse.
    public func format() throws -> String {
        try PairingUri.validate(desktopId: desktopId, name: name, fingerprint: fingerprint, addresses: addresses, port: port,
                                token: token)
        var text = PairingUri.prefix
        text += "v=" + String(CompanionProtocol.version)
        text += "&id=" + PairingUri.percentEncode(desktopId)
        text += "&n=" + PairingUri.percentEncode(name)
        text += "&fp=" + PairingUri.percentEncode(fingerprint)
        if !addresses.isEmpty {
            text += "&a=" + addresses.map { PairingUri.percentEncode($0) }.joined(separator: ",")
        }
        text += "&p=" + String(port)
        text += "&t=" + PairingUri.percentEncode(token)
        return text
    }

    public var description: String { (try? format()) ?? "" }

    /// The pairing code in `text`; throws `PairingUriError` when it cannot be used.
    public static func parse(_ text: String) throws -> PairingUri {
        guard text.utf8.count <= maxLength else { throw damaged() }
        guard hasPrefixIgnoringASCIICase(text, scheme + ":") else {
            throw PairingUriError(.notPairingCode, notPairingCodeMessage)
        }
        // Only printable ASCII: every split and comparison below is then the same on both platforms
        // (a combining mark after '&' would otherwise join it into one Swift Character).
        guard hasPrefixIgnoringASCIICase(text, prefix), text.utf16.allSatisfy({ $0 > 0x20 && $0 < 0x7F }),
              !text.contains("#")
        else { throw damaged() }
        let query = String(decoding: Array(text.utf16.dropFirst(prefix.utf16.count)), as: UTF16.self)
        // Each parameter as written (still percent-encoded): the address list is split at its commas
        // before its addresses are decoded.
        var raw: [String: String] = [:]
        for part in query.split(separator: "&", omittingEmptySubsequences: false) {
            if part.isEmpty { continue }
            let key: String
            let value: String
            if let equals = part.firstIndex(of: "=") {
                key = String(part[part.startIndex..<equals])
                value = String(part[part.index(after: equals)...])
            } else {
                key = String(part)
                value = ""
            }
            guard !key.isEmpty, percentDecode(value) != nil, raw[key] == nil else { throw damaged() }
            raw[key] = value
        }
        func value(_ key: String) -> String? {
            guard let encoded = raw[key] else { return nil }
            return percentDecode(encoded)
        }
        // The version first: a newer code may have other parts this version would call damaged.
        guard let versionText = value("v"), isDigits(versionText, maxLength: 9), let version = Int(versionText) else {
            throw damaged()
        }
        if version > CompanionProtocol.version {
            throw PairingUriError(.newerVersion, newerVersionMessage)
        }
        guard version >= 1 else { throw damaged() }
        guard let id = value("id"), let name = value("n"), let fingerprint = value("fp"), let portText = value("p"),
              let token = value("t")
        else { throw damaged() }
        var addresses: [String] = []
        if let addressList = raw["a"], !addressList.isEmpty {
            for encoded in addressList.split(separator: ",", omittingEmptySubsequences: false) {
                guard let address = percentDecode(String(encoded)) else { throw damaged() }
                addresses.append(address)
            }
        }
        guard isDigits(portText, maxLength: 5), let port = Int(portText) else { throw damaged() }
        try validate(desktopId: id, name: name, fingerprint: fingerprint, addresses: addresses, port: port, token: token)
        return PairingUri(desktopId: id, name: name, fingerprint: fingerprint, addresses: addresses, port: port, token: token)
    }

    /// Whether `address` is an IP address a code may carry: IPv4 in dotted decimal (no leading zeros),
    /// or IPv6 (with "::", an embedded IPv4 tail and a zone after '%').
    public static func isValidAddress(_ address: String) -> Bool {
        guard !address.isEmpty, address.utf16.count <= maxAddressLength else { return false }
        return address.contains(":") ? isIPv6(address) : isIPv4(address)
    }

    /// Everything but letters, digits and `-._~` as %XX of its UTF-8 bytes (uppercase hex).
    public static func percentEncode(_ value: String) -> String {
        var text = ""
        for byte in value.utf8 {
            switch byte {
            case 97...122, 65...90, 48...57, 45, 46, 95, 126:
                text.unicodeScalars.append(Unicode.Scalar(byte))
            default:
                text += String(format: "%%%02X", byte)
            }
        }
        return text
    }

    /// The text of a percent-encoded value; nil for a bad escape, a character that must be escaped, or
    /// bytes that are not UTF-8.
    public static func percentDecode(_ value: String) -> String? {
        let characters = Array(value.utf16)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(characters.count)
        var i = 0
        while i < characters.count {
            let c = characters[i]
            if c == 37 {   // '%'
                guard i + 2 < characters.count, let high = hexValue(characters[i + 1]), let low = hexValue(characters[i + 2]) else {
                    return nil
                }
                bytes.append(UInt8(high << 4 | low))
                i += 3
            } else if c > 0x20 && c < 0x7F && c != 38 && c != 61 && c != 35 && c != 63 {   // not & = # ?
                bytes.append(UInt8(c))
                i += 1
            } else {
                return nil
            }
        }
        return String(bytes: bytes, encoding: .utf8)
    }

    private static func damaged() -> PairingUriError { PairingUriError(.damaged, damagedMessage) }

    private static func validate(desktopId: String, name: String, fingerprint: String, addresses: [String], port: Int,
                                 token: String) throws {
        guard CompanionProtocol.isValidId(desktopId),
              !name.isEmpty, name.utf8.count <= maxNameBytes, !hasControlCharacter(name),
              let fingerprintBytes = CompanionProtocol.decodeBase64Url(fingerprint), fingerprintBytes.count == SpkiFingerprint.byteCount,
              addresses.count <= maxAddresses, addresses.allSatisfy({ isValidAddress($0) }),
              port >= 1, port <= 65535,
              let tokenBytes = CompanionProtocol.decodeBase64Url(token), tokenBytes.count == tokenByteCount
        else { throw damaged() }
    }

    /// Any C0 or C1 control character, or DEL.
    static func hasControlCharacter(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.value < 0x20 || ($0.value >= 0x7F && $0.value <= 0x9F) }
    }

    /// `text` starts with `prefix`, letters compared without regard to (ASCII) case.
    private static func hasPrefixIgnoringASCIICase(_ text: String, _ prefix: String) -> Bool {
        let a = Array(text.utf16)
        let b = Array(prefix.utf16)
        guard a.count >= b.count else { return false }
        for i in 0..<b.count where lowerASCII(a[i]) != lowerASCII(b[i]) {
            return false
        }
        return true
    }

    private static func lowerASCII(_ c: UInt16) -> UInt16 { (65...90).contains(c) ? c + 32 : c }

    private static func hexValue(_ c: UInt16) -> Int? {
        switch c {
        case 48...57: return Int(c) - 48
        case 65...70: return Int(c) - 55
        case 97...102: return Int(c) - 87
        default: return nil
        }
    }

    private static func isDigits<S: StringProtocol>(_ text: S, maxLength: Int) -> Bool {
        !text.isEmpty && text.utf16.count <= maxLength && text.unicodeScalars.allSatisfy { $0.value >= 48 && $0.value <= 57 }
    }

    private static func isHex(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 48...57, 65...70, 97...102: return true
        default: return false
        }
    }

    private static func isIPv4<S: StringProtocol>(_ text: S) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        for part in parts {
            guard isDigits(part, maxLength: 3), !(part.count > 1 && part.first == "0"), let number = Int(part), number <= 255 else {
                return false
            }
        }
        return true
    }

    private static func isIPv6(_ address: String) -> Bool {
        var text = Substring(address)
        if let percent = text.firstIndex(of: "%") {
            let zone = text[text.index(after: percent)...]
            guard !zone.isEmpty, zone.utf16.count <= 32,
                  zone.unicodeScalars.allSatisfy({ scalar in
                      switch scalar.value {
                      case 97...122, 65...90, 48...57, 45, 95, 46: return true
                      default: return false
                      }
                  })
            else { return false }
            text = text[text.startIndex..<percent]
        }
        let compressed = text.range(of: "::")
        if let first = compressed, text.range(of: "::", range: text.index(after: first.lowerBound)..<text.endIndex) != nil {
            return false
        }
        let head = compressed.map { text[text.startIndex..<$0.lowerBound] } ?? text
        let tail = compressed.map { text[$0.upperBound...] } ?? Substring("")
        let headGroups: [Substring] = head.isEmpty ? [] : head.split(separator: ":", omittingEmptySubsequences: false)
        let tailGroups: [Substring] = tail.isEmpty ? [] : tail.split(separator: ":", omittingEmptySubsequences: false)
        let all: [Substring] = headGroups + tailGroups
        var groups = 0
        for (i, group) in all.enumerated() {
            let last = i == all.count - 1
            if last && group.contains(".") {
                guard isIPv4(group) else { return false }
                groups += 2
                continue
            }
            guard !group.isEmpty, group.utf16.count <= 4, group.unicodeScalars.allSatisfy(isHex) else { return false }
            groups += 1
        }
        return compressed != nil ? groups <= 7 : groups == 8
    }
}
