import Foundation

// Twin of windows/CompleteScanner.Core/PdfObjectWriter.cs: the same header, objects, streams, table
// and trailer, byte for byte. The C# writer's encryption (M20) arrives here with the Swift
// PdfEncryption (I5); its incremental-update members (M21) have no twin, since the Mac adds pages to
// an existing PDF with PDFKit (see CONTRACTS.md).

/// The byte-level layer of the PDF writer: the header, numbered objects with their byte offsets,
/// streams, and the classic cross-reference table and trailer. It knows nothing about pages or
/// fonts (`PDFWriter` decides what the objects are and how they are numbered), and it never holds
/// more than one object in memory: everything goes straight to `output`. Objects may be written in
/// any order, but every number from 1 to the highest one used must be written before `finish(_:)`.
/// Misuse (a number below 1, a number written twice, a gap at the end, a string that is not ASCII)
/// throws `ScanError.exportFailed`, where C# throws an argument or invalid-operation exception.
public final class PDFObjectWriter {
    private let output: (Data) throws -> Void
    private var offsets: [Int] = [] // offsets[i] = byte offset of object i + 1; -1 = not written yet

    /// Every byte goes to `output`, in order, as it is written.
    public init(output: @escaping (Data) throws -> Void) {
        self.output = output
    }

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

    /// A stream object: "<<{entries} /Length n>>", the data between "stream" and "endstream", each
    /// keyword on a line of its own. `entries` are the dictionary's other entries ("" for none); the
    /// length is always added last.
    public func writeStream(_ number: Int, _ entries: String, _ data: Data) throws {
        try beginObject(number)
        let separator = entries.isEmpty ? "" : " "
        try writeASCII("<<\(entries)\(separator)/Length \(data.count)>>\nstream\n")
        try writeBytes(data)
        try writeASCII("\nendstream\n")
        try endObject()
    }

    /// A string in an object's dictionary: "(text)" with \, ( and ) escaped. `text` is ASCII.
    public func asciiString(_ text: String) throws -> String {
        var result = "("
        for scalar in text.unicodeScalars {
            guard scalar.value < 0x80 else {
                throw ScanError.exportFailed("PDF syntax strings are ASCII.")
            }
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
