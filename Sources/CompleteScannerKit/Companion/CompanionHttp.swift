import Foundation

// Twin of windows/LazyScan.Core/Companion/CompanionHttp.cs: the same subset of HTTP/1.1, the
// same limits and the same answers to malformed requests (CompanionServer.swift reads requests with it).

/// How far parsing a request's head got.
public enum HttpParseStatus: Equatable, Sendable {
    /// The head has not fully arrived; read more.
    case incomplete
    case complete
    /// The request is refused; answer `HttpParseResult.errorStatus` and close.
    case invalid
}

/// One header line: its name as sent and its value trimmed.
public struct HttpHeader: Equatable, Sendable {
    public var name: String
    public var value: String

    public init(_ name: String, _ value: String) {
        self.name = name
        self.value = value
    }
}

/// A request's line and headers. `target` is the path and, after '?', the query, as sent;
/// `contentLength` is nil when the request has none; `expectsContinue` when the client sent
/// `Expect: 100-continue` and waits before sending its body.
public struct HttpRequestHead: Equatable, Sendable {
    public var method: String
    public var target: String
    public var headers: [HttpHeader]
    public var contentLength: Int64?
    public var expectsContinue: Bool

    public init(method: String, target: String, headers: [HttpHeader], contentLength: Int64?, expectsContinue: Bool) {
        self.method = method
        self.target = target
        self.headers = headers
        self.contentLength = contentLength
        self.expectsContinue = expectsContinue
    }

    /// The target before any '?'.
    public var path: String {
        guard let q = target.firstIndex(of: "?") else { return target }
        return String(target[target.startIndex..<q])
    }

    /// The target after the first '?'; "" without one.
    public var query: String {
        guard let q = target.firstIndex(of: "?") else { return "" }
        return String(target[target.index(after: q)...])
    }

    /// The first header named `name` (ignoring case); nil when there is none.
    public func header(_ name: String) -> String? {
        let wanted = name.lowercased()
        return headers.first { $0.name.lowercased() == wanted }?.value
    }

    /// The token of an `Authorization: Bearer …` header; nil without one.
    public var bearerToken: String? {
        guard let value = header("Authorization"), value.lowercased().hasPrefix("bearer ") else { return nil }
        return String(value.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The outcome of parsing a request's head: `consumed` is the bytes the head took, its blank line
/// included (for `.complete`); `errorStatus` the status to answer with (for `.invalid`).
public struct HttpParseResult: Equatable, Sendable {
    public var status: HttpParseStatus
    public var head: HttpRequestHead?
    public var consumed: Int
    public var errorStatus: Int

    public init(status: HttpParseStatus, head: HttpRequestHead? = nil, consumed: Int = 0, errorStatus: Int = 0) {
        self.status = status
        self.head = head
        self.consumed = consumed
        self.errorStatus = errorStatus
    }
}

/// The small part of HTTP/1.1 the companion link uses, read strictly: one request per connection (the
/// server always closes), a request line of GET, PUT, POST or DELETE with an origin-form target and
/// version HTTP/1.1, CRLF line ends only, no folded headers, at most `maxHeaderCount` headers in
/// `maxHeadBytes` bytes, a Host header, a body only by one plain Content-Length (any
/// Transfer-Encoding is refused, chunked included), and `Expect: 100-continue` as the only expectation.
public enum CompanionHttp {
    public static let maxRequestLineBytes = 2048
    public static let maxHeadBytes = 16 * 1024
    public static let maxHeaderCount = 64
    /// Content-Length digits read (a larger body is refused anyway).
    public static let maxContentLengthDigits = 15

    public static let methods = ["GET", "PUT", "POST", "DELETE"]

    /// Parses the head at the start of `data`.
    public static func parse(_ data: Data) -> HttpParseResult {
        parse([UInt8](data))
    }

    /// Parses the head at the start of `data`.
    public static func parse(_ data: [UInt8]) -> HttpParseResult {
        // Lines end in CRLF; a bare CR or LF is refused as soon as it is seen.
        var lineStart = 0
        var lines: [String] = []
        var i = 0
        while i < data.count {
            let b = data[i]
            if b == 0x0A { return invalid(400) }
            if b != 0x0D {
                i += 1
                continue
            }
            if i + 1 >= data.count { break }
            if data[i + 1] != 0x0A { return invalid(400) }
            if lines.isEmpty && i - lineStart > maxRequestLineBytes { return invalid(414) }
            if i + 2 > maxHeadBytes { return invalid(431) }
            if i == lineStart {
                if lines.isEmpty { return invalid(400) }
                return head(lines, consumed: i + 2)
            }
            if lines.count > maxHeaderCount { return invalid(431) }
            lines.append(latin1(data[lineStart..<i]))
            lineStart = i + 2
            i += 2
        }
        if lines.isEmpty && data.count - lineStart > maxRequestLineBytes { return invalid(414) }
        if data.count >= maxHeadBytes { return invalid(431) }
        return HttpParseResult(status: .incomplete)
    }

    /// The status line's reason phrase.
    public static func reasonPhrase(_ status: Int) -> String {
        switch status {
        case 100: return "Continue"
        case 200: return "OK"
        case 201: return "Created"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 408: return "Request Timeout"
        case 409: return "Conflict"
        case 411: return "Length Required"
        case 413: return "Content Too Large"
        case 414: return "URI Too Long"
        case 417: return "Expectation Failed"
        case 422: return "Unprocessable Content"
        case 429: return "Too Many Requests"
        case 431: return "Request Header Fields Too Large"
        case 500: return "Internal Server Error"
        case 501: return "Not Implemented"
        case 503: return "Service Unavailable"
        case 505: return "HTTP Version Not Supported"
        default: return "Unknown"
        }
    }

    /// A response's head: the status line, `headers` in order, then Content-Length and
    /// `Connection: close`, and the blank line.
    public static func responseHead(status: Int, headers: [HttpHeader], contentLength: Int64) -> Data {
        var text = "HTTP/1.1 \(status) \(reasonPhrase(status))\r\n"
        for header in headers {
            text += "\(header.name): \(header.value)\r\n"
        }
        text += "Content-Length: \(contentLength)\r\n"
        text += "Connection: close\r\n\r\n"
        return Data(text.utf8)
    }

    /// The interim answer that lets a client waiting on `Expect: 100-continue` send its body.
    public static let continueResponse = Data("HTTP/1.1 100 Continue\r\n\r\n".utf8)

    /// A query's parameters (first value of each name kept); names and values as sent, not decoded.
    public static func queryParameters(_ query: String) -> [String: String] {
        var values: [String: String] = [:]
        for part in query.split(separator: "&", omittingEmptySubsequences: false) where !part.isEmpty {
            let name: String
            let value: String
            if let equals = part.firstIndex(of: "=") {
                name = String(part[part.startIndex..<equals])
                value = String(part[part.index(after: equals)...])
            } else {
                name = String(part)
                value = ""
            }
            if values[name] == nil { values[name] = value }
        }
        return values
    }

    private static func invalid(_ status: Int) -> HttpParseResult {
        HttpParseResult(status: .invalid, errorStatus: status)
    }

    /// The bytes as ISO 8859-1 text: one character per byte, so later checks see every byte.
    private static func latin1(_ bytes: ArraySlice<UInt8>) -> String {
        var text = String.UnicodeScalarView()
        for byte in bytes { text.append(Unicode.Scalar(byte)) }
        return String(text)
    }

    private static func head(_ lines: [String], consumed: Int) -> HttpParseResult {
        let parts = lines[0].split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3 else { return invalid(400) }
        let method = parts[0], target = parts[1], version = parts[2]
        guard !method.isEmpty, method.unicodeScalars.allSatisfy(isTokenChar) else { return invalid(400) }
        guard methods.contains(method) else { return invalid(501) }
        if version != "HTTP/1.1" {
            let v = Array(version.unicodeScalars)
            let looksLikeVersion = version.hasPrefix("HTTP/") && v.count == 8 && isDigit(v[5]) && v[6] == "." && isDigit(v[7])
            return invalid(looksLikeVersion ? 505 : 400)
        }
        guard let first = target.unicodeScalars.first, first == "/",
              target.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value < 0x7F && $0 != "#" })
        else { return invalid(400) }

        var headers: [HttpHeader] = []
        var contentLength: Int64?
        var expectsContinue = false
        var hasHost = false
        for line in lines.dropFirst() {
            guard let start = line.unicodeScalars.first, start != " ", start != "\t" else { return invalid(400) }
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex else { return invalid(400) }
            let name = String(line[line.startIndex..<colon])
            guard name.unicodeScalars.allSatisfy(isTokenChar) else { return invalid(400) }
            let value = trimSpacesAndTabs(String(line[line.index(after: colon)...]))
            guard value.unicodeScalars.allSatisfy({ $0 == "\t" || ($0.value >= 0x20 && $0.value < 0x7F) }) else { return invalid(400) }
            headers.append(HttpHeader(name, value))
            switch name.lowercased() {
            case "content-length":
                guard contentLength == nil, !value.isEmpty, value.utf16.count <= maxContentLengthDigits,
                      value.unicodeScalars.allSatisfy(isDigit), let length = Int64(value)
                else { return invalid(400) }
                contentLength = length
            case "transfer-encoding":
                return invalid(501)
            case "host":
                guard !hasHost else { return invalid(400) }
                hasHost = true
            case "expect":
                guard value.lowercased() == "100-continue" else { return invalid(417) }
                expectsContinue = true
            default:
                break
            }
        }
        guard hasHost else { return invalid(400) }
        let head = HttpRequestHead(method: method, target: target, headers: headers, contentLength: contentLength,
                                   expectsContinue: expectsContinue)
        return HttpParseResult(status: .complete, head: head, consumed: consumed)
    }

    private static func trimSpacesAndTabs(_ text: String) -> String {
        var scalars = Array(text.unicodeScalars)
        while let last = scalars.last, last == " " || last == "\t" { scalars.removeLast() }
        var start = 0
        while start < scalars.count && (scalars[start] == " " || scalars[start] == "\t") { start += 1 }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars[start...])
        return String(view)
    }

    private static func isDigit(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value >= 48 && scalar.value <= 57
    }

    /// A tchar of RFC 9110: letters, digits and `!#$%&'*+-.^_`|~`.
    private static func isTokenChar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 97...122, 65...90, 48...57: return true
        default: return "!#$%&'*+-.^_`|~".unicodeScalars.contains(scalar)
        }
    }
}
