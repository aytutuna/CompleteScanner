import Foundation
@testable import LazyScanKit

// Twin of windows/LazyScan.Core.Tests/PdfFixtures.cs: the same files, written the same way,
// byte for byte except inside Flate streams. `deflate` wraps Foundation's raw deflate in a zlib
// header and Adler-32 where C# uses ZLibStream, so compressed data (and the offsets after it) may
// differ between the platforms; no case pins them.

/// Small PDFs written by hand, byte by byte, for the reader and the appender: the layouts other
/// PDF writers use and ours does not — cross-reference streams with PNG predictors, objects inside
/// object streams, files already updated (/Prev), hybrid files (/XRefStm), page trees with inherited
/// attributes, nested nodes or an indirect /Kids — and broken or refused ones.
final class PDFFixture {
    private var out: [UInt8] = []
    private var section: [Int: (offset: Int, generation: Int)] = [:]
    private var compressed: [Int: (stream: Int, index: Int)] = [:]

    let newline: String

    init(version: String = "1.4", newline: String? = nil) {
        self.newline = newline ?? "\n"
        raw("%PDF-\(version)\(self.newline)")
        bytes([UInt8(ascii: "%"), 0xE2, 0xE3, 0xCF, 0xD3])
        raw(self.newline)
    }

    var position: Int { out.count }

    @discardableResult
    func raw(_ text: String) -> PDFFixture {
        bytes(PDFFixture.latin1(text))
    }

    @discardableResult
    func bytes(_ bytes: [UInt8]) -> PDFFixture {
        out.append(contentsOf: bytes)
        return self
    }

    /// "n g obj body endobj", listed in the next cross-reference section.
    @discardableResult
    func obj(_ number: Int, _ body: String, generation: Int = 0) -> PDFFixture {
        section[number] = (offset: position, generation: generation)
        return raw("\(number) \(generation) obj\(newline)\(body)\(newline)endobj\(newline)")
    }

    @discardableResult
    func stream(_ number: Int, _ entries: String, _ data: [UInt8], generation: Int = 0) -> PDFFixture {
        section[number] = (offset: position, generation: generation)
        raw("\(number) \(generation) obj\(newline)<<\(entries) /Length \(data.count)>>\(newline)stream\r\n")
        bytes(data)
        return raw("\(newline)endstream\(newline)endobj\(newline)")
    }

    /// An object stream holding `objects` (Flate-compressed unless told not to).
    @discardableResult
    func objectStream(_ number: Int, _ objects: [(number: Int, body: String)], flate: Bool = true) -> PDFFixture {
        var header = ""
        var body = ""
        for i in objects.indices {
            header += "\(objects[i].number) \(body.utf8.count) "
            body += objects[i].body + "\n"
            compressed[objects[i].number] = (stream: number, index: i)
        }
        let data = PDFFixture.latin1(header + body)
        let filter = flate ? " /Filter /FlateDecode" : ""
        return stream(number, "/Type /ObjStm /N \(objects.count) /First \(header.utf8.count)\(filter)",
                      flate ? PDFFixture.deflate(data) : data)
    }

    /// A classic table of the objects written since the last section, its trailer, startxref and
    /// %%EOF. Returns its offset.
    @discardableResult
    func table(_ trailerEntries: String, withZero: Bool = true, free: [(number: Int, generation: Int)] = []) -> Int {
        let at = position
        var entries: [Int: String] = [:]
        if withZero { entries[0] = "0000000000 65535 f" }
        for (n, entry) in section {
            entries[n] = "\(PDFObjectWriter.padded(entry.offset, digits: 10)) \(PDFObjectWriter.padded(entry.generation, digits: 5)) n"
        }
        for entry in free { entries[entry.number] = "0000000000 \(PDFObjectWriter.padded(entry.generation, digits: 5)) f" }
        // utf8, not count: "\r\n" is one Character.
        let entryEnd = newline.utf8.count == 2 ? newline : " " + newline
        var text = "xref\(newline)"
        for run in PDFFixture.runs(entries.keys.sorted()) {
            text += "\(run.first) \(run.count)\(newline)"
            for n in run.first..<(run.first + run.count) { text += entries[n]! + entryEnd }
        }
        text += "trailer\(newline)<<\(trailerEntries)>>\(newline)startxref\(newline)\(at)\(newline)%%EOF\(newline)"
        raw(text)
        section.removeAll()
        return at
    }

    /// A cross-reference stream, object `number`, of the objects written (and put in object
    /// streams) since the last section and itself, /W [1 2 1] or wider, Flate with the PNG Up
    /// predictor unless told otherwise; then startxref and %%EOF unless `end` is false. Returns its
    /// offset.
    @discardableResult
    func xrefStream(_ number: Int, _ entries: String, flate: Bool = true, predictor: Int = 12, offsetWidth: Int = 2,
                    end: Bool = true, free: [(number: Int, generation: Int)] = [], filter: String? = nil) -> Int {
        let at = position
        section[number] = (offset: at, generation: 0)
        var rows: [Int: [UInt8]] = [:]
        for (n, entry) in section { rows[n] = PDFFixture.row(1, entry.offset, entry.generation, offsetWidth) }
        for (n, entry) in compressed { rows[n] = PDFFixture.row(2, entry.stream, entry.index, offsetWidth) }
        for entry in free { rows[entry.number] = PDFFixture.row(0, 0, entry.generation, offsetWidth) }
        let width = 1 + offsetWidth + 1
        let numbers = rows.keys.sorted()
        var data: [UInt8] = []
        for n in numbers { data.append(contentsOf: rows[n]!) }
        var parameters = ""
        if flate && predictor >= 10 {
            data = PDFFixture.pngUp(data, columns: width)
            parameters = " /DecodeParms <</Predictor \(predictor) /Columns \(width)>>"
        }
        if flate { data = PDFFixture.deflate(data) }
        var index: [String] = []
        for run in PDFFixture.runs(numbers) { index.append("\(run.first) \(run.count)") }
        let filterEntry = filter ?? (flate ? " /Filter /FlateDecode" : "")
        section.removeAll()
        compressed.removeAll()
        stream(number, "/Type /XRef /W [1 \(offsetWidth) 1] /Index [\(index.joined(separator: " "))]\(filterEntry)\(parameters) \(entries)", data)
        section.removeAll()
        if end { raw("startxref\(newline)\(at)\(newline)%%EOF\(newline)") }
        return at
    }

    func toArray() -> [UInt8] { out }

    private static func row(_ type: Int, _ second: Int, _ third: Int, _ width: Int) -> [UInt8] {
        var row = [UInt8](repeating: 0, count: 2 + width)
        row[0] = UInt8(type)
        for b in 0..<width { row[1 + b] = UInt8(truncatingIfNeeded: second >> ((width - 1 - b) * 8)) }
        row[1 + width] = UInt8(truncatingIfNeeded: third)
        return row
    }

    /// PNG "Up" on every row (filter byte 2), as cross-reference streams usually are.
    static func pngUp(_ data: [UInt8], columns: Int) -> [UInt8] {
        var output: [UInt8] = []
        var previous = [UInt8](repeating: 0, count: columns)
        var at = 0
        while at < data.count {
            output.append(2)
            for i in 0..<columns {
                let value = data[at + i]
                output.append(value &- previous[i])
                previous[i] = value
            }
            at += columns
        }
        return output
    }

    /// `data` as a zlib stream: Foundation's raw deflate between the header and the Adler-32.
    static func deflate(_ data: [UInt8]) -> [UInt8] {
        let deflated = try! (Data(data) as NSData).compressed(using: .zlib)
        var output: [UInt8] = [0x78, 0x9C]
        output.append(contentsOf: deflated as Data)
        let adler = GlyphlessFont.adler32(data)
        output.append(UInt8(truncatingIfNeeded: adler >> 24))
        output.append(UInt8(truncatingIfNeeded: adler >> 16))
        output.append(UInt8(truncatingIfNeeded: adler >> 8))
        output.append(UInt8(truncatingIfNeeded: adler))
        return output
    }

    /// One byte per scalar, as C#'s Encoding.Latin1 (the fixtures never go past U+00FF).
    static func latin1(_ text: String) -> [UInt8] {
        var bytes: [UInt8] = []
        for scalar in text.unicodeScalars { bytes.append(UInt8(scalar.value)) }
        return bytes
    }

    private static func runs(_ numbers: [Int]) -> [(first: Int, count: Int)] {
        var result: [(first: Int, count: Int)] = []
        var first = -1
        var count = 0
        for n in numbers {
            if count > 0 && n == first + count {
                count += 1
                continue
            }
            if count > 0 { result.append((first: first, count: count)) }
            first = n
            count = 1
        }
        if count > 0 { result.append((first: first, count: count)) }
        return result
    }

    // MARK: - The corpus

    /// A content stream that draws nothing but says which page it is.
    private static func content(_ label: String) -> [UInt8] {
        Array("BT /F1 12 Tf 72 72 Td (\(label)) Tj ET".utf8)
    }

    private static let font = "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica>>"

    /// Two pages, a classic table, never updated (PDF 1.4).
    static func classic(newline: String? = nil, finalNewline: Bool = true) -> [UInt8] {
        let f = PDFFixture(version: "1.4", newline: newline)
        f.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        f.obj(2, "<</Type /Pages /Kids [3 0 R 4 0 R] /Count 2>>")
        f.obj(3, "<</Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources <</Font <</F1 7 0 R>>>> /Contents 5 0 R>>")
        f.obj(4, "<</Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Resources <</Font <</F1 7 0 R>>>> /Contents 6 0 R>>")
        f.stream(5, "", content("one"))
        f.stream(6, "", content("two"))
        f.obj(7, font)
        f.obj(8, "<</Producer (Fixture)>>")
        f.table("/Size 9 /Root 1 0 R /Info 8 0 R /ID [<00112233445566778899AABBCCDDEEFF> <00112233445566778899AABBCCDDEEFF>]")
        var bytes = f.toArray()
        if !finalNewline {
            while let last = bytes.last, last == 10 || last == 13 { bytes.removeLast() }
        }
        return bytes
    }

    /// `classic()` already updated once by another writer: a third page, object 6 freed, the tree
    /// rewritten.
    static func alreadyUpdated() -> [UInt8] {
        let original = classic()
        let previous = startXrefOf(original)
        let f = PDFFixture()
        f.out = []
        f.bytes(original)
        f.obj(2, "<</Type /Pages /Kids [3 0 R 4 0 R 9 0 R] /Count 3>>")
        f.obj(9, "<</Type /Page /Parent 2 0 R /MediaBox [0 0 300 300] /Resources <<>> /Contents 10 0 R>>")
        f.stream(10, "", content("three"))
        f.table("/Size 11 /Root 1 0 R /Info 8 0 R /Prev \(previous)", withZero: false)
        return f.toArray()
    }

    /// PDF 1.5 with a cross-reference stream (Flate, PNG Up) and the catalog, tree and pages in an
    /// object stream.
    static func objectStreams(flateObjectStream: Bool = true, predictor: Int = 12) -> [UInt8] {
        let f = PDFFixture(version: "1.5")
        f.stream(5, "", content("one"))
        f.stream(6, "", content("two"))
        f.objectStream(10, [
            (number: 1, body: "<</Type /Catalog /Pages 2 0 R>>"),
            (number: 2, body: "<</Type /Pages /Kids [3 0 R 4 0 R] /Count 2>>"),
            (number: 3, body: "<</Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources <</Font <</F1 7 0 R>>>> /Contents 5 0 R>>"),
            (number: 4, body: "<</Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Resources <</Font <</F1 7 0 R>>>> /Contents 6 0 R>>"),
            (number: 7, body: font),
        ], flate: flateObjectStream)
        f.xrefStream(11, "/Size 12 /Root 1 0 R /ID [<A0A1A2A3A4A5A6A7A8A9AAABACADAEAF> <A0A1A2A3A4A5A6A7A8A9AAABACADAEAF>]",
                     predictor: predictor, free: [(number: 0, generation: 255)])
        return f.toArray()
    }

    /// A hybrid file: a classic table lists the content streams and says the objects in the object
    /// stream are free; its trailer's /XRefStm points at a stream that lists them.
    static func hybrid() -> [UInt8] {
        let f = PDFFixture(version: "1.5")
        f.stream(5, "", content("one"))
        f.stream(6, "", content("two"))
        f.obj(7, font)
        f.objectStream(10, [
            (number: 1, body: "<</Type /Catalog /Pages 2 0 R>>"),
            (number: 2, body: "<</Type /Pages /Kids [3 0 R 4 0 R] /Count 2>>"),
            (number: 3, body: "<</Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources <</Font <</F1 7 0 R>>>> /Contents 5 0 R>>"),
            (number: 4, body: "<</Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Resources <</Font <</F1 7 0 R>>>> /Contents 6 0 R>>"),
        ])
        // The stream section lists only what a PDF 1.4 reader cannot find: the compressed objects.
        let listed = f.section
        f.section.removeAll()
        let stream = f.xrefStream(11, "/Size 12", end: false)
        for (n, entry) in listed { f.section[n] = entry }
        f.table("/Size 12 /Root 1 0 R /XRefStm \(stream)", free: [
            (number: 1, generation: 0), (number: 2, generation: 0), (number: 3, generation: 0),
            (number: 4, generation: 0), (number: 11, generation: 0),
        ])
        return f.toArray()
    }

    /// The root passes /MediaBox, /CropBox, /Rotate and /Resources down; the pages say none of their own.
    static func inherited() -> [UInt8] {
        let f = PDFFixture()
        f.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        f.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 300] /CropBox [10 10 190 290] /Rotate 90 /Resources <</Font <</F1 7 0 R>>>>>>")
        f.obj(3, "<</Type /Page /Parent 2 0 R /Contents 5 0 R>>")
        f.stream(5, "", content("one"))
        f.obj(7, font)
        f.table("/Size 8 /Root 1 0 R")
        return f.toArray()
    }

    /// A root with an intermediate node holding two pages, then a page of its own; /Kids of the
    /// inner node is an indirect array.
    static func nested() -> [UInt8] {
        let f = PDFFixture()
        f.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        f.obj(2, "<</Type /Pages /Kids [3 0 R 6 0 R] /Count 3>>")
        f.obj(3, "<</Type /Pages /Parent 2 0 R /Kids 9 0 R /Count 2>>")
        f.obj(9, "[4 0 R 5 0 R]")
        f.obj(4, "<</Type /Page /Parent 3 0 R /MediaBox [0 0 100 100] /Resources <<>>>>")
        f.obj(5, "<</Type /Page /Parent 3 0 R /MediaBox [0 0 200 200] /Resources <<>>>>")
        f.obj(6, "<</Type /Page /Parent 2 0 R /MediaBox [0 0 300 300] /Resources <<>>>>")
        f.obj(7, "<<>>")
        f.obj(8, "<<>>")
        f.table("/Size 10 /Root 1 0 R")
        return f.toArray()
    }

    /// The root's /Kids is an indirect array and its /Count an indirect number; the root is
    /// generation 1.
    static func indirectKids() -> [UInt8] {
        let f = PDFFixture()
        f.obj(1, "<</Type /Catalog /Pages 2 1 R>>")
        f.obj(2, "<</Type /Pages /Kids 4 0 R /Count 5 0 R /Odd#20Name (a\\(b\\)c\\\\ \\r end) /Hex <4142> /Real -.5>>", generation: 1)
        f.obj(3, "<</Type /Page /Parent 2 1 R /MediaBox [0 0 612 792] /Resources <<>>>>")
        f.obj(4, "[3 0 R]")
        f.obj(5, "1")
        f.table("/Size 6 /Root 1 0 R")
        return f.toArray()
    }

    /// A one-page file whose catalog adds `catalogEntries` and objects 4 and up (`extra`).
    static func withCatalog(_ catalogEntries: String, extra: ((PDFFixture) -> Void)? = nil, version: String = "1.4") -> [UInt8] {
        let f = PDFFixture(version: version)
        f.obj(1, "<</Type /Catalog /Pages 2 0 R \(catalogEntries)>>")
        f.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1>>")
        f.obj(3, "<</Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources <<>>>>")
        extra?(f)
        f.table("/Size 6 /Root 1 0 R /ID [<0F0E0D0C0B0A09080706050403020100> <0F0E0D0C0B0A09080706050403020100>]")
        return f.toArray()
    }

    /// XMP saying pdfaid part and conformance, as attributes (or as elements).
    static func xmp(part: Int, conformance: String, asElements: Bool = false) -> [UInt8] {
        let id = asElements
            ? "<rdf:Description rdf:about=\"\" xmlns:pdfaid=\"http://www.aiim.org/pdfa/ns/id/\"><pdfaid:part>\(part)</pdfaid:part><pdfaid:conformance>\(conformance)</pdfaid:conformance></rdf:Description>"
            : "<rdf:Description rdf:about=\"\" xmlns:pdfaid=\"http://www.aiim.org/pdfa/ns/id/\" pdfaid:part=\"\(part)\" pdfaid:conformance=\"\(conformance)\"/>"
        let packet = "<?xpacket begin=\"\u{FEFF}\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?>\n"
            + "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\">"
            + id + "</rdf:RDF></x:xmpmeta>\n<?xpacket end=\"w\"?>"
        return Array(packet.utf8)
    }

    /// A file claiming PDF/A `part``conformance` with an output intent of `components` components.
    static func pdfA(part: Int, conformance: String, components: Int = 3, compressedXmp: Bool = false) -> [UInt8] {
        withCatalog("/Metadata 4 0 R /OutputIntents [<</Type /OutputIntent /S /GTS_PDFA1 /OutputConditionIdentifier (x) /DestOutputProfile 5 0 R>>]", extra: { f in
            let xmp = PDFFixture.xmp(part: part, conformance: conformance)
            f.stream(4, "/Type /Metadata /Subtype /XML" + (compressedXmp ? " /Filter /FlateDecode" : ""),
                     compressedXmp ? PDFFixture.deflate(xmp) : xmp)
            f.stream(5, "/N \(components)", [1, 2, 3])
        })
    }

    /// The value after the last "startxref".
    static func startXrefOf(_ pdf: [UInt8]) -> Int {
        let text = String(bytes: pdf, encoding: .isoLatin1)!
        let at = text.range(of: "startxref", options: .backwards)!.upperBound
        let rest = text[at...].trimmingCharacters(in: .whitespacesAndNewlines)
        let line = rest.components(separatedBy: CharacterSet(charactersIn: "\n\r"))[0]
        return Int(line.trimmingCharacters(in: .whitespacesAndNewlines))!
    }
}
