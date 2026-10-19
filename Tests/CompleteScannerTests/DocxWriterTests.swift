import XCTest
import Foundation
@testable import CompleteScannerKit

// Mirrors windows/CompleteScanner.Core.Tests/DocxWriterTests.cs: the same cases. Foundation has no
// zip reader, so the package is read here by `StoredZip`, which walks its records and checks each
// entry's CRC-32 (the Windows tests open it with System.IO.Compression.ZipArchive).

/// A zip of stored entries, read record by record: the local headers in order, then the central
/// directory and its end record, which must agree with them.
private struct StoredZip {
    struct Entry {
        let name: String
        let data: Data
        let flags: UInt16
        let date: UInt16
        let time: UInt16
    }

    struct Malformed: Error {
        let reason: String
    }

    let entries: [Entry]

    init(_ zip: Data) throws {
        let bytes = [UInt8](zip)
        func u16(_ at: Int) throws -> Int {
            guard at + 2 <= bytes.count else { throw Malformed(reason: "truncated at \(at)") }
            return Int(bytes[at]) | Int(bytes[at + 1]) << 8
        }
        func u32(_ at: Int) throws -> UInt32 {
            guard at + 4 <= bytes.count else { throw Malformed(reason: "truncated at \(at)") }
            return UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
        }
        var entries: [Entry] = []
        var offsets: [Int] = []
        var offset = 0
        while try u32(offset) == 0x0403_4B50 {
            let flags = try u16(offset + 6)
            guard try u16(offset + 8) == 0 else { throw Malformed(reason: "not stored") }
            let time = try u16(offset + 10)
            let date = try u16(offset + 12)
            let crc = try u32(offset + 14)
            let compressed = try Int(u32(offset + 18))
            let size = try Int(u32(offset + 22))
            let nameLength = try u16(offset + 26)
            let extraLength = try u16(offset + 28)
            guard compressed == size else { throw Malformed(reason: "sizes differ") }
            let nameStart = offset + 30
            let dataStart = nameStart + nameLength + extraLength
            guard dataStart + size <= bytes.count else { throw Malformed(reason: "data runs past the end") }
            let name = String(decoding: bytes[nameStart..<(nameStart + nameLength)], as: UTF8.self)
            let data = Data(bytes[dataStart..<(dataStart + size)])
            guard ZipStore.crc32(data) == crc else { throw Malformed(reason: "CRC-32 of \(name)") }
            entries.append(Entry(name: name, data: data, flags: UInt16(flags), date: UInt16(date), time: UInt16(time)))
            offsets.append(offset)
            offset = dataStart + size
        }
        // The end record (no comment) points at the central directory, right after the data.
        let end = bytes.count - 22
        guard end >= 0, try u32(end) == 0x0605_4B50 else { throw Malformed(reason: "no end record") }
        guard try u16(end + 8) == entries.count, try u16(end + 10) == entries.count else {
            throw Malformed(reason: "entry count")
        }
        guard try Int(u32(end + 16)) == offset, try Int(u32(end + 12)) == end - offset else {
            throw Malformed(reason: "directory place")
        }
        var record = offset
        for (index, entry) in entries.enumerated() {
            guard try u32(record) == 0x0201_4B50 else { throw Malformed(reason: "central record \(index)") }
            let nameLength = try u16(record + 28)
            let extraLength = try u16(record + 30)
            let commentLength = try u16(record + 32)
            guard try Int(u32(record + 42)) == offsets[index] else { throw Malformed(reason: "header offset \(index)") }
            let name = String(decoding: bytes[(record + 46)..<(record + 46 + nameLength)], as: UTF8.self)
            guard name == entry.name else { throw Malformed(reason: "central name \(index)") }
            record += 46 + nameLength + extraLength + commentLength
        }
        guard record == end else { throw Malformed(reason: "directory size") }
        self.entries = entries
    }

    func data(_ name: String) -> Data? {
        entries.first { $0.name == name }?.data
    }
}

final class ZipStoreTests: XCTestCase {
    func test_crc32_knownValues() {
        XCTAssertEqual(ZipStore.crc32([UInt8]()), 0)
        XCTAssertEqual(ZipStore.crc32("123456789".utf8), 0xCBF4_3926)
        XCTAssertEqual(ZipStore.crc32("The quick brown fox jumps over the lazy dog".utf8), 0x414F_A339)
        XCTAssertEqual(ZipStore.crc32([UInt8(0)]), 0xD202_EF8D)
    }

    func test_make_exactBytesOfOneEntry() {
        let zip = ZipStore.make([ZipStoreEntry(name: "a.txt", data: Data("hi".utf8))])
        let crc = ZipStore.crc32("hi".utf8)
        var expected: [UInt8] = []
        func u16(_ v: Int) { expected.append(UInt8(v & 0xFF)); expected.append(UInt8((v >> 8) & 0xFF)) }
        func u32(_ v: UInt32) { for i in 0..<4 { expected.append(UInt8((v >> (8 * UInt32(i))) & 0xFF)) } }
        // Local header, name, data.
        u32(0x0403_4B50); u16(10); u16(0); u16(0); u16(0); u16(0x21); u32(crc); u32(2); u32(2); u16(5); u16(0)
        expected += Array("a.txt".utf8)
        expected += Array("hi".utf8)
        // Central directory at 37.
        u32(0x0201_4B50); u16(20); u16(10); u16(0); u16(0); u16(0); u16(0x21); u32(crc); u32(2); u32(2); u16(5)
        u16(0); u16(0); u16(0); u16(0); u32(0); u32(0)
        expected += Array("a.txt".utf8)
        // End of central directory: one entry, 51 bytes of directory at 37.
        u32(0x0605_4B50); u16(0); u16(0); u16(1); u16(1); u32(51); u32(37); u16(0)
        XCTAssertEqual([UInt8](zip), expected)
    }

    func test_make_readsBack_entriesInOrder() throws {
        let big = Data((0..<70_000).map { UInt8(truncatingIfNeeded: $0 * 7) })
        let zip = ZipStore.make([
            ZipStoreEntry(name: "[Content_Types].xml", data: Data("<x/>".utf8)),
            ZipStoreEntry(name: "dir/empty.bin", data: Data()),
            ZipStoreEntry(name: "dir/big.bin", data: big),
            ZipStoreEntry(name: "naïve.txt", data: Data("é".utf8)),
        ])
        let read = try StoredZip(zip)
        XCTAssertEqual(read.entries.map(\.name), ["[Content_Types].xml", "dir/empty.bin", "dir/big.bin", "naïve.txt"])
        XCTAssertEqual(read.data("dir/big.bin"), big)
        XCTAssertEqual(read.data("dir/empty.bin"), Data())
        XCTAssertEqual(read.data("naïve.txt").flatMap { String(data: $0, encoding: .utf8) }, "é")
        // UTF-8 names are flagged; every entry is dated 1980-01-01 00:00.
        XCTAssertEqual(read.entries.map(\.flags), [0, 0, 0, 0x0800])
        XCTAssertTrue(read.entries.allSatisfy { $0.date == 0x21 && $0.time == 0 })
    }
}

final class DocxWriterTests: XCTestCase {
    private let wordNamespace = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"

    private func L(_ text: String, _ left: Double, _ top: Double, _ width: Double, _ height: Double = 20) -> OCRLine {
        OCRFixtures.line(text, left, top, width, height)
    }

    private func open(_ docx: Data) throws -> (zip: StoredZip, document: XMLDocument) {
        let zip = try StoredZip(docx)
        let xml = try XCTUnwrap(zip.data("word/document.xml"))
        return (zip, try XMLDocument(data: xml))
    }

    private func body(_ document: XMLDocument) throws -> XMLElement {
        let root = try XCTUnwrap(document.rootElement())
        return try XCTUnwrap(root.elements(forLocalName: "body", uri: wordNamespace).first)
    }

    private func paragraphs(_ document: XMLDocument) throws -> [XMLElement] {
        try body(document).elements(forLocalName: "p", uri: wordNamespace)
    }

    /// A paragraph's text: its w:t text, a tab for w:tab, a line break for w:br.
    private func text(of element: XMLElement) -> String {
        var result = ""
        for child in element.children ?? [] {
            guard let child = child as? XMLElement else { continue }
            switch child.localName ?? "" {
            case "t": result += child.stringValue ?? ""
            case "tab": result += "\t"
            case "br": result += "\n"
            default: result += text(of: child)
            }
        }
        return result
    }

    private func paragraphTexts(_ document: XMLDocument) throws -> [String] {
        try paragraphs(document).map { text(of: $0) }
    }

    func test_make_isAWordPackage_withTheRequiredPartsAndRelationships() throws {
        let docx = DocxWriter.make(TextExportTests.samplePages())
        XCTAssertEqual(Array(docx.prefix(4)), [0x50, 0x4B, 0x03, 0x04])
        let (zip, document) = try open(docx)
        XCTAssertEqual(zip.entries.map(\.name), ["[Content_Types].xml", "_rels/.rels", "word/document.xml"])

        let types = try XCTUnwrap(XMLDocument(data: XCTUnwrap(zip.data("[Content_Types].xml"))).rootElement())
        let typesNamespace = "http://schemas.openxmlformats.org/package/2006/content-types"
        XCTAssertEqual(types.localName, "Types")
        XCTAssertEqual(types.uri, typesNamespace)
        func contentType(_ name: String, key: String, value: String) -> String? {
            types.elements(forLocalName: name, uri: typesNamespace)
                .first { $0.attribute(forName: key)?.stringValue == value }?
                .attribute(forName: "ContentType")?.stringValue
        }
        XCTAssertEqual(contentType("Default", key: "Extension", value: "rels"),
                       "application/vnd.openxmlformats-package.relationships+xml")
        XCTAssertEqual(contentType("Default", key: "Extension", value: "xml"), "application/xml")
        XCTAssertEqual(contentType("Override", key: "PartName", value: "/word/document.xml"),
                       "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml")

        let relationships = try XCTUnwrap(XMLDocument(data: XCTUnwrap(zip.data("_rels/.rels"))).rootElement())
        let relationshipElements = relationships.elements(
            forLocalName: "Relationship", uri: "http://schemas.openxmlformats.org/package/2006/relationships")
        XCTAssertEqual(relationshipElements.count, 1)
        let main = try XCTUnwrap(relationshipElements.first)
        XCTAssertEqual(main.attribute(forName: "Type")?.stringValue,
                       "http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument")
        XCTAssertEqual(main.attribute(forName: "Target")?.stringValue, "word/document.xml")
        XCTAssertEqual(main.attribute(forName: "Id")?.stringValue, "rId1")

        let root = try XCTUnwrap(document.rootElement())
        XCTAssertEqual(root.localName, "document")
        XCTAssertEqual(root.uri, wordNamespace)
        let last = try body(document).children?.last as? XMLElement
        XCTAssertEqual(last?.localName, "sectPr")
    }

    func test_make_oneParagraphPerParagraph_newPageForEachPage() throws {
        let (_, document) = try open(DocxWriter.make(TextExportTests.samplePages()))
        XCTAssertEqual(try paragraphTexts(document),
                       ["Café menu", "Soupe à l'oignon\t4,50 €\n東京 ラーメン\t9.00", "This line is forwarding the rest.",
                        "שלום עולם", "Fish & Chips <b>"])
        let elements = try paragraphs(document)
        XCTAssertEqual(elements.map { paragraph in
            !(paragraph.elements(forLocalName: "pPr", uri: wordNamespace).first?
                .elements(forLocalName: "pageBreakBefore", uri: wordNamespace).isEmpty ?? true)
        }, [false, false, false, true, false])
        // Text keeps its spaces; a tab is a tab element between two pieces of text, and the rows
        // of a table are lines of one paragraph.
        let xml = DocxWriter.documentXML(TextExportTests.samplePages())
        XCTAssertFalse(xml.contains("<w:t>"))
        XCTAssertEqual(xml.components(separatedBy: "<w:t xml:space=\"preserve\">").count - 1, 8)
        XCTAssertEqual(xml.components(separatedBy: "<w:tab/>").count - 1, 2)
        XCTAssertEqual(xml.components(separatedBy: "<w:br/>").count - 1, 1)
    }

    func test_documentXML_escapesMarkup_andLeavesOutWhatXMLCannotHold() throws {
        let page = OCRFixtures.page(L("A & B <tag> \"q\" 'a'", 50, 100, 600))
        let xml = DocxWriter.documentXML([page])
        XCTAssertTrue(xml.contains("<w:t xml:space=\"preserve\">A &amp; B &lt;tag&gt; \"q\" 'a'</w:t>"))
        XCTAssertEqual(DocxWriter.escapeXML("A & B <tag>"), "A &amp; B &lt;tag&gt;")
        XCTAssertEqual(DocxWriter.escapeXML("a\u{0001}b\u{0008}\tc\u{FFFE}\u{FFFF}"), "ab\tc")
        XCTAssertEqual(DocxWriter.escapeXML("x\u{1F600}y"), "x\u{1F600}y")
        XCTAssertEqual(DocxWriter.escapeXML("\n\r"), "\n\r")
        XCTAssertTrue(DocxWriter.documentXML([OCRFixtures.page(L("a", 50, 100, 50), L("b", 500, 100, 50),
                                                               L("c", 50, 130, 50), L("d", 500, 130, 50))])
            .contains("<w:p><w:r><w:t xml:space=\"preserve\">a</w:t><w:tab/><w:t xml:space=\"preserve\">b</w:t><w:br/>"
                      + "<w:t xml:space=\"preserve\">c</w:t><w:tab/><w:t xml:space=\"preserve\">d</w:t></w:r></w:p>"))
        XCTAssertEqual(try paragraphTexts(XMLDocument(data: Data(xml.utf8))), ["A & B <tag> \"q\" 'a'"])
    }

    func test_make_unicodeRoundTrip() throws {
        let samples = ["東京都の天気は晴れ", "שלום עולם", "مرحبا بالعالم", "Ελληνικά", "emoji \u{1F600} ok", "\u{01C4}emal \u{FB01}ne"]
        let pages = samples.map { OCRFixtures.page(L($0, 50, 100, 500)) }
        let (_, document) = try open(DocxWriter.make(pages))
        XCTAssertEqual(try paragraphTexts(document), samples)
    }

    func test_pageSize_fromTheFirstPage_inTwips_withOneInchMargins() {
        let a4 = OCRPage(lines: [], widthPoints: 595.28, heightPoints: 841.89)
        let xml = DocxWriter.documentXML([a4, OCRPage(lines: [], widthPoints: 1000, heightPoints: 300)])
        XCTAssertTrue(xml.contains("<w:sectPr><w:pgSz w:w=\"11906\" w:h=\"16838\"/><w:pgMar w:top=\"1440\" w:right=\"1440\" "
                                   + "w:bottom=\"1440\" w:left=\"1440\" w:header=\"720\" w:footer=\"720\" w:gutter=\"0\"/></w:sectPr>"))
        let letterLandscape = DocxWriter.pageSizeTwips(OCRPage(lines: [], widthPoints: 792, heightPoints: 612))
        XCTAssertEqual(letterLandscape.width, 15840)
        XCTAssertEqual(letterLandscape.height, 12240)
        XCTAssertTrue(DocxWriter.documentXML([OCRPage(lines: [], widthPoints: 792, heightPoints: 612)])
            .contains("<w:pgSz w:w=\"15840\" w:h=\"12240\" w:orient=\"landscape\"/>"))
        // Without a page: US Letter. Outside Word's range: kept within it.
        XCTAssertEqual(DocxWriter.pageSizeTwips(nil).width, 12240)
        XCTAssertEqual(DocxWriter.pageSizeTwips(nil).height, 15840)
        XCTAssertEqual(DocxWriter.pageSizeTwips(OCRPage(lines: [], widthPoints: 5000, heightPoints: 1)).width, 31680)
        XCTAssertEqual(DocxWriter.pageSizeTwips(OCRPage(lines: [], widthPoints: 5000, heightPoints: 1)).height, 144)
        // A receipt-sized page gets margins an eighth of its width.
        XCTAssertEqual(DocxWriter.marginTwips(width: 4320, height: 20000), 540)
        XCTAssertEqual(DocxWriter.marginTwips(width: 12240, height: 15840), 1440)
    }

    func test_emptyPages_stillGiveAParagraphEach() throws {
        let (_, document) = try open(DocxWriter.make([OCRFixtures.page(), OCRFixtures.page()]))
        XCTAssertEqual(try paragraphTexts(document), ["", ""])
        XCTAssertEqual(
            DocxWriter.documentXML([]),
            "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\">"
            + "<w:body><w:p></w:p><w:sectPr><w:pgSz w:w=\"12240\" w:h=\"15840\"/><w:pgMar w:top=\"1440\" w:right=\"1440\" "
            + "w:bottom=\"1440\" w:left=\"1440\" w:header=\"720\" w:footer=\"720\" w:gutter=\"0\"/></w:sectPr></w:body></w:document>")
    }

    func test_make_fingerprint_matchesWindows() {
        // The same numbers in DocxWriterTests.cs: both platforms write the same package.
        let docx = DocxWriter.make(TextExportTests.samplePages())
        XCTAssertEqual(docx.count, 1964)
        XCTAssertEqual(ZipStore.crc32(docx), 0x0F9B_A5A4)
        XCTAssertEqual(DocxWriter.make(TextExportTests.samplePages()), docx)
    }
}
