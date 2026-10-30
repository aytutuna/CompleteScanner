import Foundation
#if canImport(Darwin)
import Darwin
#endif

// Twin of windows/LazyScan.Core/Escl/ScannerAddress.cs: the same accepted forms, messages and
// canonical text (the text kept in escl-hosts.json). The C# code leans on System.Uri and IPAddress;
// here the address text is read by hand (EsclUrlText) and IPv6 addresses by inet_pton/inet_ntop, to
// the same results for every form a user types or discovery reports.

/// Where an eSCL scanner answers: scheme, host, port and resource path. Parsed from what a user types
/// ("192.168.1.50", "scanner.local:8080", "https://10.0.0.7", "[fe80::1%12]:80",
/// "http://host:8080/eSCL") and written back in one canonical form, `description`, the text kept in
/// escl-hosts.json. Two addresses are equal when their canonical texts are, ignoring case.
public struct ScannerAddress: Hashable, CustomStringConvertible, Sendable {
    /// HTTPS (eSCL over TLS, _uscans) instead of plain HTTP.
    public let secure: Bool
    /// Host name (lowercase) or IP address; IPv6 without brackets, with its zone (%12) when it has one.
    public let host: String
    public let port: Int
    /// The eSCL resource path below the host, without slashes ("eSCL" unless given).
    public let resourcePath: String

    private init(secure: Bool, host: String, port: Int, resourcePath: String) {
        self.secure = secure
        self.host = host
        self.port = port
        self.resourcePath = resourcePath
    }

    public var defaultPort: Int { secure ? 443 : 80 }

    private var isIPv6: Bool { host.contains(":") }

    /// The host in brackets when it is an IPv6 address, as "host:port" and the canonical text write it.
    private var bracketedHost: String { isIPv6 ? "[" + host + "]" : host }

    /// "host:port" (IPv6 in brackets, with its zone), lowercase: identifies the endpoint, e.g. for
    /// certificate trust.
    public var authority: String { bracketedHost + ":" + String(port) }

    /// The eSCL root as URL text, ending in a slash so relative paths ("ScannerCapabilities") resolve
    /// below it; the default port is left out. The same text as C#'s `BaseUri.AbsoluteUri`, except that
    /// an IPv6 zone is kept, written "%25" + zone as RFC 6874 asks (System.Uri drops it from the text).
    public var baseURLText: String {
        var urlHost: String = host
        if isIPv6 {
            urlHost = "[" + host.replacingOccurrences(of: "%", with: "%25") + "]"
        }
        var text: String = (secure ? "https://" : "http://") + urlHost
        if port != defaultPort {
            text += ":" + String(port)
        }
        text += "/"
        if !resourcePath.isEmpty {
            text += EsclUrlText.escapePath(resourcePath) + "/"
        }
        return text
    }

    /// `baseURLText` as a URL; nil only when Foundation does not take the text.
    public var baseURL: URL? { URL(string: baseURLText) }

    /// The canonical text: the bare host for the plain default ("192.168.1.50"), "host:port" for plain
    /// HTTP on another port, otherwise a URL ("https://10.0.0.7", "http://host:8080/scan"). Parsing it
    /// gives an equal address, except for a resource at the root of the host, which only a discovered
    /// service can name (it reads back as /eSCL).
    public var description: String {
        if !secure && resourcePath == "eSCL" {
            return port == 80 ? bracketedHost : bracketedHost + ":" + String(port)
        }
        var text: String = (secure ? "https://" : "http://") + bracketedHost
        if port != defaultPort {
            text += ":" + String(port)
        }
        if resourcePath != "eSCL" {
            text += "/" + resourcePath
        }
        return text
    }

    public static func == (lhs: ScannerAddress, rhs: ScannerAddress) -> Bool {
        lhs.description.lowercased() == rhs.description.lowercased()
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(description.lowercased())
    }

    /// An address from its parts (a discovered service); nil when the host or the port is not usable.
    public static func create(secure: Bool, host: String, port: Int, resourcePath: String) -> ScannerAddress? {
        guard port >= 1 && port <= 65535 else { return nil }
        var bare: String = host.trimmingCharacters(in: .whitespacesAndNewlines)
        while bare.hasPrefix("[") {
            bare.removeFirst()
        }
        while bare.hasSuffix("]") {
            bare.removeLast()
        }
        guard let normalized = EsclHostText.normalizeHost(bare) else { return nil }
        let path: String = resourcePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return ScannerAddress(secure: secure, host: normalized, port: port, resourcePath: path)
    }

    /// Parses an address; throws `EsclFormatError` with a user-facing message.
    public static func parse(_ text: String) throws -> ScannerAddress {
        var error: String = ""
        guard let address = tryParse(text, error: &error) else { throw EsclFormatError(error) }
        return address
    }

    /// Parses what a user typed. Accepted: an IPv4 or IPv6 address or host name, optionally with a
    /// port ("host:8080", "[fe80::1]:8080"), or an http(s) URL with an optional port and resource path
    /// (a trailing "/ScannerCapabilities" is dropped). Plain addresses mean HTTP on port 80 at /eSCL.
    /// nil when it is none of these, with what is wrong, for the user, in `error`.
    public static func tryParse(_ text: String?, error: inout String) -> ScannerAddress? {
        error = ""
        let value: String = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            error = "Enter the scanner's IP address or host name."
            return nil
        }
        for character in value where character.isWhitespace {
            error = "An address cannot contain spaces."
            return nil
        }

        let hasScheme: Bool = value.contains("://")
        // "192.168.1.5/eSCL": a path without a scheme means plain HTTP.
        if !hasScheme && value.contains("/") {
            return tryParse("http://" + value, error: &error)
        }
        if hasScheme {
            return tryParseUrl(value, error: &error)
        }

        let host: String
        var port: String?
        var colonCount: Int = 0
        for character in value where character == ":" {
            colonCount += 1
        }
        if value.hasPrefix("[") {
            guard let close = value.firstIndex(of: "]") else {
                error = "An IPv6 address in brackets needs its closing \"]\"."
                return nil
            }
            host = String(value[value.index(after: value.startIndex)..<close])
            let rest: String = String(value[value.index(after: close)...])
            if !rest.isEmpty {
                guard rest.hasPrefix(":") else {
                    error = "That is not a valid address."
                    return nil
                }
                port = String(rest.dropFirst())
            }
        } else if colonCount >= 2 {
            host = value   // a bare IPv6 address: no port
        } else if let colon = value.firstIndex(of: ":") {
            host = String(value[..<colon])
            port = String(value[value.index(after: colon)...])
        } else {
            host = value
        }

        var portNumber: Int = 80
        if let portText = port {
            guard let number = EsclHostText.port(portText), number >= 1 else {
                error = "The port must be a number from 1 to 65535."
                return nil
            }
            portNumber = number
        }
        guard let normalized = EsclHostText.normalizeHost(host) else {
            error = "\"\(host)\" is not a valid IP address or host name."
            return nil
        }
        return ScannerAddress(secure: false, host: normalized, port: portNumber, resourcePath: "eSCL")
    }

    private static func tryParseUrl(_ value: String, error: inout String) -> ScannerAddress? {
        guard let parts = EsclUrlText.split(value), !parts.host.isEmpty,
              parts.bracketed || EsclHostText.isPlausibleHost(parts.host) else {
            error = "That is not a valid address."
            return nil
        }
        let secure: Bool
        if parts.scheme == "http" {
            secure = false
        } else if parts.scheme == "https" {
            secure = true
        } else {
            error = "Use an address that starts with http:// or https://, or just the IP address or host name."
            return nil
        }
        if let userInfo = parts.userInfo, !userInfo.isEmpty {
            error = "Leave out the user name and password; scanners do not need them."
            return nil
        }
        guard let host = EsclHostText.normalizeHost(parts.host) else {
            if parts.bracketed {
                error = "That is not a valid address."
            } else {
                error = "\"\(parts.host.lowercased())\" is not a valid IP address or host name."
            }
            return nil
        }
        let decoded: String = EsclUrlText.removeDotSegments(parts.path).removingPercentEncoding
            ?? EsclUrlText.removeDotSegments(parts.path)
        var path: String = decoded.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let capabilities: String = "scannercapabilities"
        let folded: String = path.lowercased()
        if folded == capabilities {
            path = ""
        } else if folded.hasSuffix("/" + capabilities) {
            path = String(path.dropLast(capabilities.count + 1))
        }
        let port: Int = parts.port ?? (secure ? 443 : 80)
        return ScannerAddress(secure: secure, host: host, port: port, resourcePath: path.isEmpty ? "eSCL" : path)
    }
}

/// An IPv6 address as `EsclHostText.ipv6` reads it.
struct EsclIPv6Address: Equatable {
    /// Its standard text: lowercase, the longest run of zero groups as "::", with "%zone" when it has a
    /// zone other than 0 (the same text as .NET's `IPAddress.ToString`).
    let text: String
    /// fe80::/10.
    let isLinkLocal: Bool
    /// The zone (interface index; a name is read as its index); 0 when none was given.
    let zone: UInt32
}

/// The host rules of the eSCL addresses, the C# code's `NormalizeHost`, `IPAddress.TryParse` and
/// `Uri.CheckHostName` as far as addresses use them.
enum EsclHostText {
    /// A host name in lowercase (without a trailing dot) or an IP address in its standard form (IPv6
    /// keeps its zone); nil when it is neither.
    static func normalizeHost(_ host: String) -> String? {
        if host.isEmpty {
            return nil
        }
        if host.contains(":") {
            return ipv6(host)?.text
        }
        if isDigitsAndDots(host) {
            // Digits and dots only: it has to be a complete dotted IPv4 address ("192.168.1" would
            // otherwise pass as a host name).
            return ipv4(host)
        }
        guard isDnsName(host) else { return nil }
        var name: String = host
        while name.hasSuffix(".") {
            name.removeLast()
        }
        return name.lowercased()
    }

    /// Four decimal numbers of up to three digits, each at most 255, written without leading zeros.
    static func ipv4(_ text: String) -> String? {
        let parts: [Substring] = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var numbers: [String] = []
        for part in parts {
            guard part.count >= 1, part.count <= 3, isDigits(part), let number = Int(part), number <= 255 else {
                return nil
            }
            numbers.append(String(number))
        }
        return numbers.joined(separator: ".")
    }

    /// An IPv6 address with an optional zone, an interface number ("fe80::1%12") or the name of an
    /// interface on this device ("fe80::1%en0"), read as its number as .NET does; nil when it is not
    /// one, or when its zone is neither (a link-local address without its interface cannot be reached).
    static func ipv6(_ text: String) -> EsclIPv6Address? {
        var addressText: String = text
        var zone: UInt32 = 0
        if let percent = text.firstIndex(of: "%") {
            addressText = String(text[..<percent])
            let zoneText: String = String(text[text.index(after: percent)...])
            if !zoneText.isEmpty {
                if isDigits(zoneText) {
                    guard let number = UInt32(zoneText) else { return nil }
                    zone = number
                } else {
                    let index: UInt32 = if_nametoindex(zoneText)
                    guard index > 0 else { return nil }
                    zone = index
                }
            }
        }
        if addressText.isEmpty {
            return nil
        }
        var address = in6_addr()
        guard inet_pton(AF_INET6, addressText, &address) == 1 else { return nil }
        var buffer: [CChar] = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN) + 1)
        let length: socklen_t = socklen_t(buffer.count)
        guard inet_ntop(AF_INET6, &address, &buffer, length) != nil else { return nil }
        let formatted: String = buffer.withUnsafeBufferPointer { (pointer: UnsafeBufferPointer<CChar>) -> String in
            guard let base = pointer.baseAddress else { return "" }
            return String(cString: base)
        }
        if formatted.isEmpty {
            return nil
        }
        let bytes: [UInt8] = withUnsafeBytes(of: &address) { (raw: UnsafeRawBufferPointer) -> [UInt8] in
            [UInt8](raw)
        }
        let linkLocal: Bool = bytes.count == 16 && bytes[0] == 0xFE && (bytes[1] & 0xC0) == 0x80
        let standard: String = zone == 0 ? formatted.lowercased() : formatted.lowercased() + "%" + String(zone)
        return EsclIPv6Address(text: standard, isLinkLocal: linkLocal, zone: zone)
    }

    /// A DNS host name as .NET's `Uri.CheckHostName` accepts one: labels of 1 to 63 characters
    /// separated by dots (one trailing dot allowed), each starting with a letter or digit and made of
    /// letters, digits, '-' and '_'; letters beyond ASCII are taken as an internationalized name.
    static func isDnsName(_ host: String) -> Bool {
        var labels: [Substring] = host.split(separator: ".", omittingEmptySubsequences: false)
        if labels.count > 1, let last = labels.last, last.isEmpty {
            labels.removeLast()
        }
        for label in labels {
            guard label.count >= 1, label.count <= 63 else { return false }
            var first = true
            for scalar in label.unicodeScalars {
                let value: UInt32 = scalar.value
                let isAsciiAlphanumeric: Bool = (value >= 0x30 && value <= 0x39) || (value >= 0x41 && value <= 0x5A)
                    || (value >= 0x61 && value <= 0x7A)
                let isOther: Bool = value > 0x7F && !scalar.properties.isWhitespace
                    && scalar.properties.generalCategory != .control
                let isJoiner: Bool = value == 0x2D || value == 0x5F   // '-' and '_'
                if first {
                    if !isAsciiAlphanumeric && !isOther {
                        return false
                    }
                    first = false
                } else if !isAsciiAlphanumeric && !isOther && !isJoiner {
                    return false
                }
            }
        }
        return true
    }

    /// What a URL's host may be before `normalizeHost` reads it: digits and dots, or a DNS name.
    static func isPlausibleHost(_ host: String) -> Bool {
        isDigitsAndDots(host) || isDnsName(host)
    }

    /// A port as typed: digits only (no sign or spaces) and at most 65535; nil otherwise.
    static func port<S: StringProtocol>(_ text: S) -> Int? {
        guard !text.isEmpty, isDigits(text) else { return nil }
        var value: Int = 0
        for scalar in text.unicodeScalars {
            value = value * 10 + Int(scalar.value - 0x30)
            if value > 65535 {
                return nil
            }
        }
        return value
    }

    static func isDigits<S: StringProtocol>(_ text: S) -> Bool {
        for scalar in text.unicodeScalars where scalar.value < 0x30 || scalar.value > 0x39 {
            return false
        }
        return true
    }

    private static func isDigitsAndDots(_ text: String) -> Bool {
        for scalar in text.unicodeScalars where scalar != "." && (scalar.value < 0x30 || scalar.value > 0x39) {
            return false
        }
        return true
    }
}

/// The parts of an http(s) URL's text, as `EsclUrlText.split` reads them.
struct EsclUrlParts: Equatable {
    /// Lowercase.
    var scheme: String
    /// What came before an "@"; nil when there was none.
    var userInfo: String?
    /// As written, without brackets; "" when there is none.
    var host: String
    /// The host was in brackets (an IPv6 address).
    var bracketed: Bool
    /// nil when the URL names none (or only a ":").
    var port: Int?
    /// The path as written (still percent-encoded), "" when there is none.
    var path: String
}

/// URL text read by hand, so the eSCL rules do not depend on how a Foundation version reads URLs.
enum EsclUrlText {
    /// "scheme://userinfo@host:port/path?query#fragment" in its parts; nil when the text is not of that
    /// shape, its port is not a number up to 65535, or a bracketed host does not close.
    static func split(_ text: String) -> EsclUrlParts? {
        guard let separator = text.range(of: "://") else { return nil }
        let scheme: String = String(text[..<separator.lowerBound])
        guard isScheme(scheme) else { return nil }
        let rest: Substring = text[separator.upperBound...]
        var authorityEnd: String.Index = rest.endIndex
        if let index = rest.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
            authorityEnd = index
        }
        var authority: Substring = rest[..<authorityEnd]
        let afterAuthority: Substring = rest[authorityEnd...]
        var pathEnd: String.Index = afterAuthority.endIndex
        if let index = afterAuthority.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            pathEnd = index
        }
        let path: String = String(afterAuthority[..<pathEnd])

        var userInfo: String?
        if let at = authority.lastIndex(of: "@") {
            userInfo = String(authority[..<at])
            authority = authority[authority.index(after: at)...]
        }

        let host: String
        var bracketed = false
        var portText: Substring?
        if authority.hasPrefix("[") {
            guard let close = authority.firstIndex(of: "]") else { return nil }
            host = String(authority[authority.index(after: authority.startIndex)..<close])
            bracketed = true
            let after: Substring = authority[authority.index(after: close)...]
            if !after.isEmpty {
                guard after.hasPrefix(":") else { return nil }
                portText = after.dropFirst()
            }
        } else if let colon = authority.firstIndex(of: ":") {
            host = String(authority[..<colon])
            portText = authority[authority.index(after: colon)...]
        } else {
            host = String(authority)
        }

        var port: Int?
        if let given = portText, !given.isEmpty {
            guard let number = EsclHostText.port(given) else { return nil }
            port = number
        }
        return EsclUrlParts(scheme: scheme.lowercased(), userInfo: userInfo, host: host, bracketed: bracketed,
                            port: port, path: path)
    }

    /// "a/./b/../c" → "a/c": the path's "." and ".." segments resolved, as System.Uri does before the
    /// path is read; the leading slash is dropped.
    static func removeDotSegments(_ path: String) -> String {
        var output: [Substring] = []
        var segments: [Substring] = path.split(separator: "/", omittingEmptySubsequences: false)
        if let first = segments.first, first.isEmpty {
            segments.removeFirst()
        }
        for segment in segments {
            if segment == "." {
                continue
            }
            if segment == ".." {
                if !output.isEmpty {
                    output.removeLast()
                }
                continue
            }
            output.append(segment)
        }
        return output.joined(separator: "/")
    }

    /// A resource path for a URL: every byte percent-encoded (uppercase hex) except the unreserved
    /// characters and '/', as C#'s `Uri.EscapeDataString` with "%2F" put back.
    static func escapePath(_ path: String) -> String {
        let hex: [Character] = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "A", "B", "C", "D", "E", "F"]
        var text: String = ""
        for byte in path.utf8 {
            let isAlphanumeric: Bool = (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A)
                || (byte >= 0x61 && byte <= 0x7A)
            let isKept: Bool = byte == 0x2D || byte == 0x2E || byte == 0x5F || byte == 0x7E || byte == 0x2F
            if isAlphanumeric || isKept {
                text.unicodeScalars.append(Unicode.Scalar(byte))
            } else {
                text.append("%")
                text.append(hex[Int(byte >> 4)])
                text.append(hex[Int(byte & 0x0F)])
            }
        }
        return text
    }

    /// "host:port" of a URL's text in the form `ScannerAddress.authority` uses: the host lowercase, an
    /// IPv6 address in brackets with its zone ("%25" read as "%", RFC 6874), the port the URL names or
    /// its scheme's default; "" when the text is not a URL.
    static func authority(_ text: String) -> String {
        guard let parts = split(text) else { return "" }
        var host: String = parts.host.lowercased()
        if parts.bracketed {
            if let range = host.range(of: "%25") {
                host.replaceSubrange(range, with: "%")
            }
            host = "[" + host + "]"
        }
        var port: Int = -1
        if let given = parts.port {
            port = given
        } else if parts.scheme == "http" {
            port = 80
        } else if parts.scheme == "https" {
            port = 443
        }
        return host + ":" + String(port)
    }

    private static func isScheme(_ text: String) -> Bool {
        var first = true
        for scalar in text.unicodeScalars {
            let value: UInt32 = scalar.value
            let isLetter: Bool = (value >= 0x41 && value <= 0x5A) || (value >= 0x61 && value <= 0x7A)
            let isDigit: Bool = value >= 0x30 && value <= 0x39
            let isMark: Bool = value == 0x2B || value == 0x2D || value == 0x2E   // + - .
            if first {
                if !isLetter {
                    return false
                }
                first = false
            } else if !isLetter && !isDigit && !isMark {
                return false
            }
        }
        return !first
    }
}
