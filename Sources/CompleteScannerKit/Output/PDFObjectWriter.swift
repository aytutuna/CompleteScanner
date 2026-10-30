import Foundation

// Twin of windows/LazyScan.Core/PdfObjectWriter.cs: the same header, objects, streams, table
// and trailer, byte for byte, the same encryption of strings and streams (`PDFEncryption`), and the
// same incremental-update sections (M21) for `PDFAppender`.

/// The byte-level layer of the PDF writer: the header, numbered objects with their byte offsets,
/// streams, and the classic cross-reference table and trailer. It knows nothing about pages or
/// fonts (`PDFWriter` decides what the objects are and how they are numbered), and it never holds
/// more than one object in memory: everything goes straight to `output`. Objects may be written in
/// any order, but every number from 1 to the highest one used must be written before `finish(_:)`.
/// With an `encryption`, every stream's data and every string made by `asciiString(_:)` is encrypted
/// as it is written; the dictionaries themselves (and so the /Encrypt dictionary, written as a plain
/// object) are not. Misuse (a number below 1, a number written twice, a gap at the end, a string that is not ASCII)
/// throws `ScanError.exportFailed`, where C# throws an argument or invalid-operation exception.
public final class PDFObjectWriter {
    private let output: (Data) throws -> Void
    private var offsets: [Int] = [] // offsets[i] = byte offset of object i + 1; -1 = not written yet

    /// Every byte goes to `output`, in order, as it is written; `encryption` encrypts the strings and
    /// streams (nil: they are not).
    public init(encryption: PDFEncryption? = nil, output: @escaping (Data) throws -> Void) {
        self.output = output
        self.encryption = encryption
    }

    /// A writer for an incremental update: `position` bytes of the file are already there (the
    /// original, and the end of line after it), so object offsets count from there. Objects are
    /// numbered from the original's next free number on (and the ones it replaces keep theirs);
    /// `finishUpdate(_:)` or `finishUpdateStream(_:_:)` lists only the objects written here.
    public init(position: Int, output: @escaping (Data) throws -> Void) throws {
        guard position >= 0 else {
            throw ScanError.exportFailed("An update starts at a position of 0 or more, got \(position).")
        }
        self.output = output
        self.encryption = nil
        self.position = position
    }

    private var generations: [Int: Int] = [:] // object number → generation, when not 0

    /// What encrypts the file's strings and streams; nil for an open file.
    public let encryption: PDFEncryption?

    /// Bytes written so far: the offset the next byte lands at.
    public private(set) var position = 0

    /// "%PDF-{version}" and the comment line of four bytes above 127 that marks the file as binary.
    public func writeHeader(_ version: String) throws {
        try writeASCII("%PDF-\(version)\n")
        try writeBytes(Data([0x25, 0xE2, 0xE3, 0xCF, 0xD3, 0x0A]))
    }

    /// Record where object `number` starts and write "n 0 obj".
    public func beginObject(_ number: Int) throws {
        guard number >= 1 else {
            throw ScanError.exportFailed("PDF object numbers start at 1, got \(number).")
        }
        while offsets.count < number { offsets.append(-1) }
        if offsets[number - 1] >= 0 {
            throw ScanError.exportFailed("Object \(number) was already written.")
        }
        offsets[number - 1] = position
        try writeASCII("\(number) 0 obj\n")
    }

    /// "n g obj" for an object an update replaces, which keeps its generation `generation` (an
    /// update never writes encrypted files: none are opened).
    public func beginObject(_ number: Int, generation: Int) throws {
        guard generation >= 0 && generation <= 65535 else {
            throw ScanError.exportFailed("PDF generations run from 0 to 65535, got \(generation).")
        }
        if generation == 0 {
            try beginObject(number)
            return
        }
        guard number >= 1 else {
            throw ScanError.exportFailed("PDF object numbers start at 1, got \(number).")
        }
        while offsets.count < number { offsets.append(-1) }
        if offsets[number - 1] >= 0 {
            throw ScanError.exportFailed("Object \(number) was already written.")
        }
        offsets[number - 1] = position
        generations[number] = generation
        try writeASCII("\(number) \(generation) obj\n")
    }

    /// Close the object begun last.
    public func endObject() throws {
        try writeASCII("endobj\n")
    }

    /// A whole object whose value is `value` (a dictionary, an array, ...).
    public func writeObject(_ number: Int, _ value: String) throws {
        try beginObject(number)
        try writeASCII(value)
        try writeASCII("\n")
        try endObject()
    }

    /// A whole object with generation `generation` (see `beginObject(_:generation:)`).
    public func writeObject(_ number: Int, generation: Int, _ value: String) throws {
        try beginObject(number, generation: generation)
        try writeASCII(value)
        try writeASCII("\n")
        try endObject()
    }

    /// A stream object: "<<{entries} /Length n>>", the data between "stream" and "endstream", each
    /// keyword on a line of its own. `entries` are the dictionary's other entries ("" for none); the
    /// length is always added last. The data is encrypted first when the file is (the length is then
    /// the encrypted data's).
    public func writeStream(_ number: Int, _ entries: String, _ data: Data) throws {
        var stored: Data = data
        if let encryption {
            let encrypted: [UInt8] = try encryption.encrypt([UInt8](data))
            stored = Data(encrypted)
        }
        try beginObject(number)
        let separator = entries.isEmpty ? "" : " "
        try writeASCII("<<\(entries)\(separator)/Length \(stored.count)>>\nstream\n")
        try writeBytes(stored)
        try writeASCII("\nendstream\n")
        try endObject()
    }

    /// A string in an object's dictionary: "(text)" with \, ( and ) escaped in an open file, the
    /// encrypted bytes as a hex string in an encrypted one. `text` is ASCII.
    public func asciiString(_ text: String) throws -> String {
        for scalar in text.unicodeScalars where scalar.value >= 0x80 {
            throw ScanError.exportFailed("PDF syntax strings are ASCII.")
        }
        if let encryption {
            let encrypted: [UInt8] = try encryption.encrypt(Array(text.utf8))
            return "<" + PDFEncryption.hex(encrypted) + ">"
        }
        var result = "("
        for scalar in text.unicodeScalars {
            if scalar == "\\" || scalar == "(" || scalar == ")" { result += "\\" }
            result.unicodeScalars.append(scalar)
        }
        result += ")"
        return result
    }

    /// The cross-reference table of every object written, then the trailer with `trailerEntries`
    /// after /Size (e.g. "/Root 1 0 R"), "startxref" and "%%EOF". Throws when an object number
    /// below the highest one was never written.
    public func finish(_ trailerEntries: String) throws {
        if let missing = offsets.firstIndex(of: -1) {
            throw ScanError.exportFailed("Object \(missing + 1) was never written.")
        }
        let xrefStart = position
        var table = "xref\n0 \(offsets.count + 1)\n"
        table += "0000000000 65535 f \n"
        for offset in offsets {
            table += PDFObjectWriter.padded(offset, digits: 10)
            table += " 00000 n \n"
        }
        try writeASCII(table)
        try writeASCII("trailer\n<</Size \(offsets.count + 1) \(trailerEntries)>>\nstartxref\n\(xrefStart)\n%%EOF\n")
    }

    /// An incremental update's classic cross-reference section: "xref", one subsection per run of
    /// consecutive objects written here (no entry 0: the original's free list stands), then the
    /// trailer with `trailerEntries` (the caller's /Size, /Prev, /Root, ...), "startxref" and "%%EOF".
    public func finishUpdate(_ trailerEntries: String) throws {
        let xrefStart = position
        var table = "xref\n"
        for run in writtenRuns() {
            table += "\(run.first) \(run.count)\n"
            for n in run.first..<(run.first + run.count) {
                table += PDFObjectWriter.padded(offsets[n - 1], digits: 10)
                table += " "
                table += PDFObjectWriter.padded(generationOf(n), digits: 5)
                table += " n \n"
            }
        }
        try writeASCII(table)
        try writeASCII("trailer\n<<\(trailerEntries)>>\nstartxref\n\(xrefStart)\n%%EOF\n")
    }

    /// An incremental update's cross-reference stream, object `number` (written last, listing itself
    /// too): uncompressed, /W [1 w 2] with w the bytes the largest offset needs (at least 4), /Index
    /// the runs of objects written here, then `dictionaryEntries` (the caller's /Size, /Prev, /Root,
    /// ...), "startxref" and "%%EOF".
    public func finishUpdateStream(_ number: Int, _ dictionaryEntries: String) throws {
        guard number >= 1 else {
            throw ScanError.exportFailed("PDF object numbers start at 1, got \(number).")
        }
        while offsets.count < number { offsets.append(-1) }
        if offsets[number - 1] >= 0 {
            throw ScanError.exportFailed("Object \(number) was already written.")
        }
        let xrefStart = position
        offsets[number - 1] = xrefStart // listed in its own data
        var offsetWidth = 4
        while offsetWidth < 8 && xrefStart >= 1 << (offsetWidth * 8) { offsetWidth += 1 }
        var data: [UInt8] = []
        var index: [String] = []
        for run in writtenRuns() {
            index.append("\(run.first) \(run.count)")
            for n in run.first..<(run.first + run.count) {
                data.append(1)
                let offset = offsets[n - 1]
                for b in stride(from: offsetWidth - 1, through: 0, by: -1) {
                    data.append(UInt8(truncatingIfNeeded: offset >> (b * 8)))
                }
                let generation = generationOf(n)
                data.append(UInt8(truncatingIfNeeded: generation >> 8))
                data.append(UInt8(truncatingIfNeeded: generation))
            }
        }
        let indexText = index.joined(separator: " ")
        var head = "\(number) 0 obj\n<</Type /XRef /W [1 \(offsetWidth) 2] /Index [\(indexText)] "
        head += "\(dictionaryEntries) /Length \(data.count)>>\nstream\n"
        try writeASCII(head)
        try writeBytes(Data(data))
        try writeASCII("\nendstream\nendobj\n")
        try writeASCII("startxref\n\(xrefStart)\n%%EOF\n")
    }

    /// The objects written, as runs of consecutive numbers.
    private func writtenRuns() -> [(first: Int, count: Int)] {
        var runs: [(first: Int, count: Int)] = []
        var i = 0
        while i < offsets.count {
            if offsets[i] < 0 {
                i += 1
                continue
            }
            let first = i + 1
            var count = 0
            while i < offsets.count && offsets[i] >= 0 {
                count += 1
                i += 1
            }
            runs.append((first: first, count: count))
        }
        return runs
    }

    private func generationOf(_ number: Int) -> Int {
        generations[number] ?? 0
    }

    public func writeBytes(_ bytes: Data) throws {
        try output(bytes)
        position += bytes.count
    }

    /// Text that is ASCII by construction (PDF syntax); anything else would be a bug.
    public func writeASCII(_ text: String) throws {
        try writeBytes(Data(text.utf8))
    }

    /// `value` in decimal, zero-padded to `digits` (C#'s "D10").
    static func padded(_ value: Int, digits: Int) -> String {
        let text = String(value)
        if text.count >= digits { return text }
        return String(repeating: "0", count: digits - text.count) + text
    }
}
