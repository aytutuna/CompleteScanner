import Foundation

// Twin of windows/CompleteScanner.Core/PdfSyntax.cs: the object syntax of an existing PDF, as the
// reader reads it and the appender writes back the few objects it changes. The values (ISO 32000-1
// 7.3), a lexer over the file's bytes, the FlateDecode filter with its PNG and TIFF predictors
// (7.4.4), and the way each value is written again, with the same limits and error texts. Strings
// and names keep their bytes, numbers their text, so a dictionary written back says exactly what it
// said. C#'s abstract classes are protocols here (`PDFObject`, `PDFBytes`), a value is written into
// a String where C# uses a StringBuilder, and a file is read through a closure (`PDFStreamBytes`)
// where C# takes a Stream. Flate data is inflated by Foundation, whose zlib is raw deflate: the
// zlib header is taken off first and the Adler-32 checked here, where C#'s ZLibStream does both.

/// A PDF value: null, boolean, number, name, string, array, dictionary, reference or stream.
protocol PDFObject: AnyObject, CustomStringConvertible {
    /// The value in PDF syntax, as the appender writes it into an update.
    func write(to output: inout String)
}

extension PDFObject {
    var description: String {
        var output = ""
        write(to: &output)
        return output
    }
}

final class PDFNull: PDFObject {
    static let instance = PDFNull()

    private init() {}

    func write(to output: inout String) {
        output += "null"
    }
}

final class PDFBoolean: PDFObject {
    let value: Bool

    init(_ value: Bool) {
        self.value = value
    }

    func write(to output: inout String) {
        output += value ? "true" : "false"
    }
}

/// An integer or a real, kept as it was written ("-.5", "4.", "0012").
final class PDFNumber: PDFObject {
    let text: String
    let value: Double
    let isInteger: Bool

    init(_ text: String) {
        self.text = text
        self.value = Double(text) ?? 0
        self.isInteger = !text.contains(".")
    }

    convenience init(_ value: Int) {
        self.init(String(value))
    }

    /// The integer value; nil for a real or one out of range.
    var integer: Int? {
        isInteger ? Int(text) : nil
    }

    func write(to output: inout String) {
        output += text
    }
}

/// A name: its bytes once #xx escapes are undone, one scalar per byte (Latin-1).
final class PDFName: PDFObject, Hashable {
    let value: String

    init(_ value: String) {
        self.value = value
    }

    func write(to output: inout String) {
        output += "/"
        // Scalars, not characters: a CR LF pair is one Character.
        for scalar in value.unicodeScalars {
            let c = Int(scalar.value)
            // Regular characters as they are; '#', delimiters, white space and anything outside
            // printable ASCII as #xx.
            if c > 0x20 && c < 0x7F && c != ascii("#") && !PDFLexer.isDelimiter(c) {
                output.unicodeScalars.append(scalar)
            } else {
                output += "#" + PDFEncryption.hex([UInt8(truncatingIfNeeded: c)])
            }
        }
    }

    static func == (lhs: PDFName, rhs: PDFName) -> Bool {
        lhs.value == rhs.value
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(value)
    }
}

/// A string's bytes, and whether it was written in hex.
final class PDFString: PDFObject {
    let bytes: [UInt8]
    let isHex: Bool

    init(_ bytes: [UInt8], isHex: Bool) {
        self.bytes = bytes
        self.isHex = isHex
    }

    func write(to output: inout String) {
        if isHex {
            output += "<" + PDFEncryption.hex(bytes) + ">"
            return
        }
        output += "("
        for b in bytes {
            switch b {
            case UInt8(ascii: "\\"): output += "\\\\"
            case UInt8(ascii: "("): output += "\\("
            case UInt8(ascii: ")"): output += "\\)"
            // A bare CR in a literal string reads back as LF: escape it to keep the byte.
            case 13: output += "\\r"
            case 10: output += "\\n"
            default:
                if b < 0x20 || b >= 0x7F {
                    let octal = String(b, radix: 8)
                    output += "\\" + String(repeating: "0", count: 3 - octal.count) + octal
                } else {
                    output.unicodeScalars.append(Unicode.Scalar(b))
                }
            }
        }
        output += ")"
    }
}

final class PDFArray: PDFObject {
    var items: [any PDFObject]

    init(_ items: [any PDFObject]) {
        self.items = items
    }

    func write(to output: inout String) {
        output += "["
        for i in items.indices {
            if i > 0 { output += " " }
            items[i].write(to: &output)
        }
        output += "]"
    }
}

/// A dictionary, its entries in the order they were written (a repeated key: the last one counts).
final class PDFDictionary: PDFObject {
    private(set) var entries: [(key: String, value: any PDFObject)] = []

    init() {}

    subscript(key: String) -> (any PDFObject)? {
        get {
            entries.last(where: { $0.key == key })?.value
        }
        set {
            let index = entries.lastIndex(where: { $0.key == key })
            if let newValue {
                if let index {
                    entries[index] = (key: key, value: newValue)
                } else {
                    entries.append((key: key, value: newValue))
                }
            } else {
                entries.removeAll(where: { $0.key == key })
            }
        }
    }

    func contains(_ key: String) -> Bool {
        entries.contains(where: { $0.key == key })
    }

    func add(_ key: String, _ value: any PDFObject) {
        entries.append((key: key, value: value))
    }

    /// A copy whose entries can be changed without changing this one (the values are shared).
    func copy() -> PDFDictionary {
        let copy = PDFDictionary()
        copy.entries = entries
        return copy
    }

    func write(to output: inout String) {
        output += "<<"
        // The last of repeated keys only, where it was written.
        for i in entries.indices {
            let key = entries[i].key
            if entries.lastIndex(where: { $0.key == key }) != i { continue }
            PDFName(key).write(to: &output)
            output += " "
            entries[i].value.write(to: &output)
            output += i < entries.count - 1 ? " " : ""
        }
        output += ">>"
    }
}

/// An indirect reference, "12 0 R".
final class PDFReference: PDFObject, Hashable {
    let number: Int
    let generation: Int

    init(_ number: Int, _ generation: Int) {
        self.number = number
        self.generation = generation
    }

    func write(to output: inout String) {
        output += "\(number) \(generation) R"
    }

    static func == (lhs: PDFReference, rhs: PDFReference) -> Bool {
        lhs.number == rhs.number && lhs.generation == rhs.generation
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(number)
        hasher.combine(generation)
    }
}

/// A stream: its dictionary and where its data starts in the bytes it was read from. Its length
/// may be an indirect object, so the reader works the data out.
final class PDFStream: PDFObject {
    let dictionary: PDFDictionary
    let dataOffset: Int

    init(_ dictionary: PDFDictionary, dataOffset: Int) {
        self.dictionary = dictionary
        self.dataOffset = dataOffset
    }

    /// Streams are never written back (an update only adds new ones).
    func write(to output: inout String) {
        preconditionFailure("A stream is written only as an indirect object.")
    }
}

/// The bytes a lexer reads: a whole array, or a file read in blocks as needed.
protocol PDFBytes: AnyObject {
    var length: Int { get }

    /// The byte at `position`; -1 past the end.
    subscript(position: Int) -> Int { get throws }

    /// Up to `count` bytes from `position` (fewer at the end).
    func read(_ position: Int, count: Int) throws -> [UInt8]
}

final class PDFArrayBytes: PDFBytes {
    private let bytes: [UInt8]

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    var length: Int { bytes.count }

    subscript(position: Int) -> Int {
        position >= 0 && position < bytes.count ? Int(bytes[position]) : -1
    }

    func read(_ position: Int, count: Int) -> [UInt8] {
        if position < 0 || position >= bytes.count || count <= 0 { return [] }
        let n = min(count, bytes.count - position)
        return Array(bytes[position..<(position + n)])
    }
}

/// Bytes read through a few cached 64 KB blocks, so a large file is never read whole. `read` gives
/// `count` bytes from `offset` (fewer only at the end); a block that comes back short throws, as
/// C#'s ReadExactly does when the file shrank while it was read.
final class PDFStreamBytes: PDFBytes {
    private static let blockSize = 1 << 16
    private static let cachedBlocks = 16
    private let source: (_ offset: Int, _ count: Int) throws -> [UInt8]
    private var blocks: [Int: [UInt8]] = [:]
    private var recent: [Int] = [] // block numbers, the last used first

    let length: Int

    init(length: Int, read: @escaping (_ offset: Int, _ count: Int) throws -> [UInt8]) {
        self.length = length
        self.source = read
    }

    /// The file `handle` reads, as long as it is now; the handle stays open.
    convenience init(_ handle: FileHandle) throws {
        let end = try handle.seekToEnd()
        self.init(length: Int(clamping: end)) { offset, count in
            try handle.seek(toOffset: UInt64(offset))
            var bytes: [UInt8] = []
            bytes.reserveCapacity(count)
            while bytes.count < count {
                guard let chunk = try handle.read(upToCount: count - bytes.count), !chunk.isEmpty else { break }
                bytes.append(contentsOf: chunk)
            }
            return bytes
        }
    }

    subscript(position: Int) -> Int {
        get throws {
            if position < 0 || position >= length { return -1 }
            let block = try self.block(position / PDFStreamBytes.blockSize)
            let index = position % PDFStreamBytes.blockSize
            return index < block.count ? Int(block[index]) : -1
        }
    }

    func read(_ position: Int, count: Int) throws -> [UInt8] {
        if position < 0 || position >= length || count <= 0 { return [] }
        let n = min(count, length - position)
        var result: [UInt8] = []
        result.reserveCapacity(n)
        while result.count < n {
            let at = position + result.count
            let block = try self.block(at / PDFStreamBytes.blockSize)
            let index = at % PDFStreamBytes.blockSize
            if index >= block.count { break }
            let take = min(n - result.count, block.count - index)
            result.append(contentsOf: block[index..<(index + take)])
        }
        return result
    }

    private func block(_ number: Int) throws -> [UInt8] {
        if let cached = blocks[number] {
            if let at = recent.firstIndex(of: number) { recent.remove(at: at) }
            recent.insert(number, at: 0)
            return cached
        }
        let start = number * PDFStreamBytes.blockSize
        let size = max(min(PDFStreamBytes.blockSize, length - start), 0)
        let block = try source(start, size)
        if block.count < size { throw PDFReadError.damaged("Unable to read beyond the end of the stream.") }
        blocks[number] = block
        recent.insert(number, at: 0)
        if recent.count > PDFStreamBytes.cachedBlocks {
            blocks[recent.removeLast()] = nil
        }
        return block
    }
}

/// A file the reader cannot use: what is wrong, for the message the user sees.
public enum PDFReadProblem: Equatable, Sendable {
    /// Not a PDF at all (no "%PDF-" header).
    case notPdf
    /// The cross-reference data or an object is not where or what it should be.
    case damaged
    /// The file is encrypted (it has an /Encrypt dictionary).
    case encrypted
    /// The file uses something this reader does not handle (a filter other than Flate, say).
    case unsupported
}

/// Thrown by the reader; `detail` is technical, `problem` says what kind. Twin of C#
/// `PdfReadException`, whose message is `detail`.
public struct PDFReadError: LocalizedError, Equatable, Sendable {
    public let problem: PDFReadProblem
    public let detail: String

    public init(_ problem: PDFReadProblem, _ detail: String) {
        self.problem = problem
        self.detail = detail
    }

    public var errorDescription: String? { detail }

    static func damaged(_ detail: String) -> PDFReadError {
        PDFReadError(.damaged, detail)
    }
}

private func ascii(_ c: Unicode.Scalar) -> Int {
    Int(c.value)
}

/// Tokens and objects from PDF bytes (ISO 32000-1 7.2, 7.3): white space and comments skipped,
/// names with #xx escapes, literal strings with their escapes and nested parentheses, hex strings,
/// numbers, "n g R" references, arrays, dictionaries and the start of a stream's data.
final class PDFLexer {
    /// Deeper nesting than this is refused rather than risking the stack.
    private static let maxDepth = 200

    let bytes: any PDFBytes
    var position: Int

    init(_ bytes: any PDFBytes, position: Int = 0) {
        self.bytes = bytes
        self.position = position
    }

    static func isWhiteSpace(_ b: Int) -> Bool {
        switch b {
        case 0, 9, 10, 12, 13, 32: return true
        default: return false
        }
    }

    static func isDelimiter(_ b: Int) -> Bool {
        switch b {
        case ascii("("), ascii(")"), ascii("<"), ascii(">"), ascii("["), ascii("]"),
             ascii("{"), ascii("}"), ascii("/"), ascii("%"):
            return true
        default:
            return false
        }
    }

    private static func isRegular(_ b: Int) -> Bool {
        b >= 0 && !isWhiteSpace(b) && !isDelimiter(b)
    }

    private func peek(_ offset: Int = 0) throws -> Int {
        try bytes[position + offset]
    }

    /// Skips white space and comments.
    func skipWhiteSpace() throws {
        while true {
            let b = try peek()
            if PDFLexer.isWhiteSpace(b) {
                position += 1
            } else if b == ascii("%") {
                while true {
                    let c = try peek()
                    if c == -1 || c == 10 || c == 13 { break }
                    position += 1
                }
            } else {
                return
            }
        }
    }

    /// The next run of regular characters ("obj", "123", "true"); empty at a delimiter or the end.
    func readKeyword() throws -> String {
        try skipWhiteSpace()
        var scalars = String.UnicodeScalarView()
        while true {
            let c = try peek()
            if !PDFLexer.isRegular(c) { break }
            scalars.append(Unicode.Scalar(UInt8(c)))
            position += 1
        }
        return String(scalars)
    }

    /// A non-negative integer token, or nil (the position is then where it was).
    func tryReadUnsigned() throws -> Int? {
        let start = position
        try skipWhiteSpace()
        var value = 0
        var digits = 0
        while true {
            let c = try peek()
            if c < ascii("0") || c > ascii("9") { break }
            if value > (Int.max - 9) / 10 {
                position = start
                return nil
            }
            value = value * 10 + (c - ascii("0"))
            position += 1
            digits += 1
        }
        if try digits == 0 || PDFLexer.isRegular(peek()) {
            position = start
            return nil
        }
        return value
    }

    /// "n g obj" at the current position; the object's number and generation.
    func readObjectHeader() throws -> (number: Int, generation: Int) {
        let numberRead = try tryReadUnsigned()
        var generationRead: Int?
        if numberRead != nil { generationRead = try tryReadUnsigned() }
        guard let number = numberRead, let generation = generationRead, number <= Int(Int32.max), generation <= 65535,
              try readKeyword() == "obj" else {
            throw PDFReadError.damaged("No object header at byte \(position).")
        }
        return (number: number, generation: generation)
    }

    /// One object; a dictionary followed by "stream" becomes a `PDFStream` whose data starts after
    /// the keyword's end of line.
    func readObject(allowStream: Bool = true) throws -> any PDFObject {
        try readObject(depth: 0, allowStream: allowStream)
    }

    private func readObject(depth: Int, allowStream: Bool) throws -> any PDFObject {
        if depth > PDFLexer.maxDepth { throw PDFReadError(.unsupported, "Objects are nested too deeply.") }
        try skipWhiteSpace()
        let b = try peek()
        switch b {
        case -1:
            throw PDFReadError.damaged("The file ends inside an object.")
        case ascii("/"):
            position += 1
            return PDFName(try readNameBody())
        case ascii("("):
            position += 1
            return PDFString(try readLiteralBody(), isHex: false)
        case ascii("["):
            position += 1
            var items: [any PDFObject] = []
            while true {
                try skipWhiteSpace()
                let c = try peek()
                if c == ascii("]") {
                    position += 1
                    break
                }
                if c == -1 { throw PDFReadError.damaged("An array is not closed.") }
                items.append(try readObject(depth: depth + 1, allowStream: false))
            }
            return PDFArray(items)
        case ascii("<"):
            if try peek(1) != ascii("<") {
                position += 1
                return PDFString(try readHexBody(), isHex: true)
            }
            position += 2
            let dictionary = PDFDictionary()
            while true {
                try skipWhiteSpace()
                if try atDictionaryEnd() {
                    position += 2
                    break
                }
                if try peek() != ascii("/") {
                    throw PDFReadError.damaged("A dictionary key is not a name at byte \(position).")
                }
                position += 1
                let key = try readNameBody()
                try skipWhiteSpace()
                // A key without a value before the end (seen in the wild) reads as null.
                var value: any PDFObject = PDFNull.instance
                if try !atDictionaryEnd() { value = try readObject(depth: depth + 1, allowStream: false) }
                dictionary.add(key, value)
            }
            if allowStream, let dataStart = try atStreamKeyword() {
                return PDFStream(dictionary, dataOffset: dataStart)
            }
            return dictionary
        case ascii("0")...ascii("9"), ascii("+"), ascii("-"), ascii("."):
            let number = try readKeyword()
            if !PDFLexer.isNumber(number) { throw PDFReadError.damaged("\"\(number)\" is not a number.") }
            // "n g R": an integer, another, then R.
            if number.utf8.allSatisfy({ $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }) {
                let save = position
                if let generation = try tryReadUnsigned(), try readKeyword() == "R",
                   let n = Int(number), n <= Int(Int32.max), generation <= 65535 {
                    return PDFReference(n, generation)
                }
                position = save
            }
            return PDFNumber(number)
        default:
            let keyword = try readKeyword()
            switch keyword {
            case "true": return PDFBoolean(true)
            case "false": return PDFBoolean(false)
            case "null": return PDFNull.instance
            case "": throw PDFReadError.damaged("Unexpected '\(Character(Unicode.Scalar(UInt8(b))))' at byte \(position).")
            default: throw PDFReadError.damaged("Unexpected \"\(keyword)\" at byte \(position).")
            }
        }
    }

    private func atDictionaryEnd() throws -> Bool {
        try peek() == ascii(">") && peek(1) == ascii(">")
    }

    private static func isNumber(_ text: String) -> Bool {
        var scalars = text.unicodeScalars[...]
        if let sign = scalars.first, sign == "+" || sign == "-" { scalars = scalars.dropFirst() }
        var digits = false
        var dot = false
        for scalar in scalars {
            if scalar >= "0" && scalar <= "9" {
                digits = true
            } else if scalar == "." && !dot {
                dot = true
            } else {
                return false
            }
        }
        return digits
    }

    /// After a dictionary: "stream" and its end of line (CRLF or LF; a lone CR is tolerated). Where
    /// the data starts, or nil (the position is then where it was).
    private func atStreamKeyword() throws -> Int? {
        let save = position
        try skipWhiteSpace()
        if try readKeyword() != "stream" {
            position = save
            return nil
        }
        let c = try peek()
        if try c == 13 && peek(1) == 10 {
            position += 2
        } else if c == 10 || c == 13 {
            position += 1
        }
        return position
    }

    private func readNameBody() throws -> String {
        var scalars = String.UnicodeScalarView()
        while true {
            let c = try peek()
            if !PDFLexer.isRegular(c) { break }
            if c == ascii("#"), let high = try PDFLexer.hexValue(peek(1)), let low = try PDFLexer.hexValue(peek(2)) {
                scalars.append(Unicode.Scalar(UInt8(high * 16 + low)))
                position += 3
                continue
            }
            scalars.append(Unicode.Scalar(UInt8(c)))
            position += 1
        }
        return String(scalars)
    }

    private func readLiteralBody() throws -> [UInt8] {
        var bytes: [UInt8] = []
        var depth = 1
        while true {
            let c = try peek()
            if c == -1 { throw PDFReadError.damaged("A string is not closed.") }
            position += 1
            if c == ascii("\\") {
                let e = try peek()
                if e == -1 { throw PDFReadError.damaged("A string is not closed.") }
                position += 1
                switch e {
                case ascii("n"): bytes.append(10)
                case ascii("r"): bytes.append(13)
                case ascii("t"): bytes.append(9)
                case ascii("b"): bytes.append(8)
                case ascii("f"): bytes.append(12)
                case 13:
                    if try peek() == 10 { position += 1 } // a line continued: nothing
                case 10:
                    break
                case ascii("0")...ascii("7"):
                    var value = e - ascii("0")
                    var k = 0
                    while k < 2 {
                        let d = try peek()
                        if d < ascii("0") || d > ascii("7") { break }
                        value = value * 8 + (d - ascii("0"))
                        position += 1
                        k += 1
                    }
                    bytes.append(UInt8(truncatingIfNeeded: value))
                default:
                    bytes.append(UInt8(e)) // \( \) \\ and any other character stand for themselves
                }
                continue
            }
            if c == ascii("(") { depth += 1 }
            if c == ascii(")") {
                depth -= 1
                if depth == 0 { break }
            }
            // An end of line inside a string reads as LF (7.3.4.2).
            if c == 13 {
                if try peek() == 10 { position += 1 }
                bytes.append(10)
                continue
            }
            bytes.append(UInt8(c))
        }
        return bytes
    }

    private func readHexBody() throws -> [UInt8] {
        var bytes: [UInt8] = []
        var high: Int?
        while true {
            let c = try peek()
            if c == -1 { throw PDFReadError.damaged("A hex string is not closed.") }
            position += 1
            if c == ascii(">") { break }
            if PDFLexer.isWhiteSpace(c) { continue }
            guard let digit = PDFLexer.hexValue(c) else {
                throw PDFReadError.damaged("'\(Character(Unicode.Scalar(UInt8(c))))' in a hex string.")
            }
            if let h = high {
                bytes.append(UInt8(h * 16 + digit))
                high = nil
            } else {
                high = digit
            }
        }
        if let last = high { bytes.append(UInt8(last * 16)) } // an odd last digit is followed by 0
        return bytes
    }

    private static func hexValue(_ c: Int) -> Int? {
        switch c {
        case ascii("0")...ascii("9"): return c - ascii("0")
        case ascii("A")...ascii("F"): return c - ascii("A") + 10
        case ascii("a")...ascii("f"): return c - ascii("a") + 10
        default: return nil
        }
    }
}

/// The filters the reader can undo for the streams it reads (cross-reference and object streams,
/// metadata).
enum PDFFilters {
    /// The data of a stream with its filters undone: none, or FlateDecode (with a /DecodeParms
    /// predictor). Anything else is `PDFReadProblem.unsupported`.
    static func decode(_ data: [UInt8], filter: (any PDFObject)?, parameters: (any PDFObject)?) throws -> [UInt8] {
        var filters: [String] = []
        if let name = filter as? PDFName {
            filters.append(name.value)
        } else if let array = filter as? PDFArray {
            for item in array.items { filters.append((item as? PDFName)?.value ?? "") }
        } else if let filter, !(filter is PDFNull) {
            throw PDFReadError.damaged("A stream's /Filter is not a name.")
        }
        var parameterList: [PDFDictionary?] = []
        if let array = parameters as? PDFArray {
            for item in array.items { parameterList.append(item as? PDFDictionary) }
        } else if let dictionary = parameters as? PDFDictionary {
            parameterList.append(dictionary)
        }
        var data = data
        for i in filters.indices {
            let decodeParms: PDFDictionary? = i < parameterList.count ? parameterList[i] : nil
            switch filters[i] {
            case "FlateDecode", "Fl":
                data = try predict(inflate(data), decodeParms)
            default:
                throw PDFReadError(.unsupported, "The /\(filters[i]) filter is not supported.")
            }
        }
        return data
    }

    /// zlib data inflated; raw deflate data (no zlib header) is accepted too.
    static func inflate(_ data: [UInt8]) throws -> [UInt8] {
        // Foundation's .zlib is raw deflate: a zlib stream goes in without its 2-byte header, with
        // the bytes after the deflate data (the decoder stops at the last block), then without the
        // last four, in case a decoder refuses bytes after the end. A stream whose Adler-32 is wrong
        // is then raw deflate or nothing, as when zlib refuses it.
        if data.count >= 2 && data[0] & 0x0F == 8 && (Int(data[0]) * 256 + Int(data[1])) % 31 == 0 {
            var attempts = [Array(data[2...])]
            if data.count >= 6 { attempts.append(Array(data[2..<(data.count - 4)])) }
            for attempt in attempts {
                guard let inflated = try? decompress(attempt) else { continue }
                if checksumHolds(inflated, data) { return inflated }
                break
            }
        }
        do {
            return try decompress(data)
        } catch {
            throw PDFReadError.damaged("A compressed stream does not inflate: \(error.localizedDescription)")
        }
    }

    private static func decompress(_ data: [UInt8]) throws -> [UInt8] {
        let inflated = try (Data(data) as NSData).decompressed(using: .zlib)
        return [UInt8](inflated as Data)
    }

    /// Whether the zlib stream `data` holds the Adler-32 of what it inflated to after its deflate
    /// data. Where that data ends is not known here, so the checksum may be anywhere after the
    /// header; a stream that ends before its checksum passes, as zlib only checks one that is there.
    private static func checksumHolds(_ inflated: [UInt8], _ data: [UInt8]) -> Bool {
        guard data.count >= 6 else { return true }
        let adler = GlyphlessFont.adler32(inflated)
        let check: [UInt8] = [UInt8(truncatingIfNeeded: adler >> 24), UInt8(truncatingIfNeeded: adler >> 16),
                              UInt8(truncatingIfNeeded: adler >> 8), UInt8(truncatingIfNeeded: adler)]
        for start in 2...(data.count - 4) {
            if data[start] == check[0] && data[start + 1] == check[1] && data[start + 2] == check[2]
                && data[start + 3] == check[3] {
                return true
            }
        }
        // The deflate data runs to the end (no checksum) when its last four bytes are needed.
        guard let shorter = try? decompress(Array(data[2..<(data.count - 4)])) else { return true }
        return shorter != inflated
    }

    /// Undoes a /Predictor: 2 (TIFF, 8 bits per component) or 10–15 (PNG, each row with its own
    /// filter byte).
    static func predict(_ data: [UInt8], _ parameters: PDFDictionary?) throws -> [UInt8] {
        let predictor = integer(parameters?["Predictor"], 1)
        if predictor <= 1 { return data }
        let colors = max(1, integer(parameters?["Colors"], 1))
        let bitsPerComponent = max(1, integer(parameters?["BitsPerComponent"], 8))
        let columns = max(1, integer(parameters?["Columns"], 1))
        let bytesPerPixel = max(1, colors * bitsPerComponent / 8)
        // C# works this out in 32-bit ints, where absurd parameters wrap; here they must not trap.
        let (rowBits, overflow) = (colors * bitsPerComponent).multipliedReportingOverflow(by: columns)
        let rowLength = overflow ? Int.max : rowBits / 8 + (rowBits % 8 == 0 ? 0 : 1)
        if predictor == 2 {
            if bitsPerComponent != 8 {
                throw PDFReadError(.unsupported, "TIFF predictor with other than 8 bits per component.")
            }
            var output = data
            var row = 0
            while rowLength <= output.count - row {
                for i in bytesPerPixel..<rowLength {
                    output[row + i] = output[row + i] &+ output[row + i - bytesPerPixel]
                }
                row += rowLength
            }
            return output
        }
        if predictor < 10 { throw PDFReadError(.unsupported, "Predictor \(predictor) is not supported.") }
        // A row longer than the data is one short row: the buffers need be no longer than the data.
        let width = min(rowLength, data.count)
        var result: [UInt8] = []
        result.reserveCapacity(data.count)
        var previous = [UInt8](repeating: 0, count: width)
        var current = [UInt8](repeating: 0, count: width)
        var at = 0
        while at < data.count {
            let type = Int(data[at])
            let available = min(width, data.count - at - 1)
            for i in 0..<width {
                current[i] = i < available ? data[at + 1 + i] : 0
            }
            for i in 0..<width {
                let x = Int(current[i])
                let left = i >= bytesPerPixel ? Int(current[i - bytesPerPixel]) : 0
                let up = Int(previous[i])
                let upLeft = i >= bytesPerPixel ? Int(previous[i - bytesPerPixel]) : 0
                switch type {
                case 0: break
                case 1: current[i] = UInt8(truncatingIfNeeded: x + left)
                case 2: current[i] = UInt8(truncatingIfNeeded: x + up)
                case 3: current[i] = UInt8(truncatingIfNeeded: x + (left + up) / 2)
                case 4: current[i] = UInt8(truncatingIfNeeded: x + paeth(left, up, upLeft))
                default: throw PDFReadError.damaged("PNG row filter \(type) does not exist.")
                }
            }
            result.append(contentsOf: current[0..<available])
            swap(&previous, &current)
            at += width + 1
        }
        return result
    }

    private static func paeth(_ a: Int, _ b: Int, _ c: Int) -> Int {
        let p = a + b - c
        let pa = abs(p - a)
        let pb = abs(p - b)
        let pc = abs(p - c)
        return pa <= pb && pa <= pc ? a : pb <= pc ? b : c
    }

    private static func integer(_ value: (any PDFObject)?, _ fallback: Int) -> Int {
        if let n = (value as? PDFNumber)?.integer, n >= Int(Int32.min), n <= Int(Int32.max) { return n }
        return fallback
    }
}
