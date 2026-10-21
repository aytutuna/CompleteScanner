import XCTest
import Foundation
import CoreGraphics
import ImageIO
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

    func test_packageSize_isTheLengthMakeWrites() {
        let cases: [[ZipStoreEntry]] = [
            [],
            [ZipStoreEntry(name: "a.txt", data: Data("hi".utf8))],
            [
                ZipStoreEntry(name: "[Content_Types].xml", data: Data("<x/>".utf8)),
                ZipStoreEntry(name: "dir/empty.bin", data: Data()),
                ZipStoreEntry(name: "dir/big.bin", data: Data(count: 70_000)),
                ZipStoreEntry(name: "naïve.txt", data: Data("é".utf8)),
            ],
        ]
        for entries in cases {
            XCTAssertEqual(ZipStore.packageSize(entries), ZipStore.make(entries).count)
        }
        XCTAssertEqual(ZipStore.packageSize([]), 22)
        XCTAssertEqual(ZipStore.packageSize([ZipStoreEntry(name: "a.txt", data: Data("hi".utf8))]), 110)
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

/// The page pictures both test suites put in Word documents, as hex: a 16 × 12 gray JPEG and a
/// 16 × 12 one-bit PNG, black where (x + y) is a multiple of 3 (both written once by WIC; the same
/// strings are in DocxWriterTests.cs).
enum DocxFixtures {
    static let jpegHex =
        "FFD8FFE000104A46494600010101012C012C0000FFDB00430006040506050406060506070706080A"
        + "100A0A09090A140E0F0C1017141818171416161A1D251F1A1B231C1616202C20232627292A29191F"
        + "2D302D283025282928FFC0000B08000C001001011100FFC4001F0000010501010101010100000000"
        + "000000000102030405060708090A0BFFC400B5100002010303020403050504040000017D01020300"
        + "041105122131410613516107227114328191A1082342B1C11552D1F02433627282090A161718191A"
        + "25262728292A3435363738393A434445464748494A535455565758595A636465666768696A737475"
        + "767778797A838485868788898A92939495969798999AA2A3A4A5A6A7A8A9AAB2B3B4B5B6B7B8B9BA"
        + "C2C3C4C5C6C7C8C9CAD2D3D4D5D6D7D8D9DAE1E2E3E4E5E6E7E8E9EAF1F2F3F4F5F6F7F8F9FAFFDA"
        + "0008010100003F00E13E1B685FEABE4F4AF6BF166B7FF0807C38BCD560F97529B16761F2E7F7EE0E"
        + "1B9561F2A867C30C1D9B73C8AE73E1B59C3FBAF97D2B9FFDA4A5925F1FF8774D77CD95BE982E228F"
        + "68F96492575739C64E4451F04E06DE3A9CFF00FFD9"

    static let pngHex =
        "89504E470D0A1A0A0000000D49484452000000100000000C0100000000439C002C00000001735247"
        + "4200AECE1CE90000000467414D410000B18F0BFC6105000000097048597300002E2300002E230178"
        + "A53F76000000144944415418D363C8DDC6703B9761DB6D06DC0C0019EB0FF11F837D3C0000000049"
        + "454E44AE426082"

    static var jpeg: Data { bytes(jpegHex) }
    static var png: Data { bytes(pngHex) }
    static var jpegPicture: DocxPicture { DocxPicture(data: jpeg, format: .jpeg) }
    static var pngPicture: DocxPicture { DocxPicture(data: png, format: .png) }

    /// Whether the fixture PNG's pixel (x, y) is black.
    static func pngIsBlack(_ x: Int, _ y: Int) -> Bool { (x + y) % 3 == 0 }

    static func bytes(_ hex: String) -> Data {
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            data.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return data
    }
}

/// An image decoded by ImageIO, and its pixels drawn into 8-bit gray (row 0 at the top).
private struct DecodedImage {
    let type: String
    let image: CGImage

    init?(_ data: Data) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        self.type = type as String
        self.image = image
    }

    var width: Int { image.width }
    var height: Int { image.height }

    var grayPixels: [UInt8] {
        let w = width
        let h = height
        let source = image
        var pixels = [UInt8](repeating: 0, count: w * h)
        pixels.withUnsafeMutableBytes { raw -> Void in
            guard let context = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                          bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            context.draw(source, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return pixels
    }
}

/// Twin of `DocxWriterPictureTests` in DocxWriterTests.cs.
final class DocxWriterPictureTests: XCTestCase {
    private let w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
    private let r = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

    private func part(_ zip: StoredZip, _ name: String) throws -> XMLDocument {
        try XMLDocument(data: XCTUnwrap(zip.data(name)))
    }

    /// Every element named `localName` under `node` ("*" for all), in document order.
    private func all(_ node: XMLNode, _ localName: String) throws -> [XMLElement] {
        let path = localName == "*" ? ".//*" : ".//*[local-name()='\(localName)']"
        return try node.nodes(forXPath: path).compactMap { $0 as? XMLElement }
    }

    private func paragraphs(_ document: XMLDocument) throws -> [XMLElement] {
        let root = try XCTUnwrap(document.rootElement())
        let body = try XCTUnwrap(root.elements(forLocalName: "body", uri: w).first)
        return body.elements(forLocalName: "p", uri: w)
    }

    /// A paragraph's text: its w:t text, a tab for w:tab, a line break for w:br.
    private func text(_ paragraph: XMLElement) throws -> String {
        var result = ""
        for element in try all(paragraph, "*") {
            switch element.localName ?? "" {
            case "t": result += element.stringValue ?? ""
            case "tab": result += "\t"
            case "br": result += "\n"
            default: break
            }
        }
        return result
    }

    private func breaksPage(_ paragraph: XMLElement) throws -> Bool {
        try !all(paragraph, "pageBreakBefore").isEmpty
    }

    private func hasDrawing(_ paragraph: XMLElement) throws -> Bool {
        try !all(paragraph, "drawing").isEmpty
    }

    private func value(_ element: XMLElement?, _ name: String) -> String? {
        element?.attribute(forName: name)?.stringValue
    }

    func test_make_withPageImages_hasTheMediaPartsRelationshipsAndContentTypes() throws {
        let docx = DocxWriter.make(TextExportTests.samplePages(),
                                   pictures: [DocxFixtures.jpegPicture, DocxFixtures.pngPicture])
        let zip = try StoredZip(docx)
        XCTAssertEqual(zip.entries.map(\.name),
                       ["[Content_Types].xml", "_rels/.rels", "word/document.xml", "word/_rels/document.xml.rels",
                        "word/media/image1.jpeg", "word/media/image2.png"])

        let types = try XCTUnwrap(part(zip, "[Content_Types].xml").rootElement())
        let defaults = try all(types, "Default")
        func defaultType(_ fileExtension: String) -> String? {
            value(defaults.first { value($0, "Extension") == fileExtension }, "ContentType")
        }
        XCTAssertEqual(defaultType("jpeg"), "image/jpeg")
        XCTAssertEqual(defaultType("png"), "image/png")
        XCTAssertEqual(defaultType("xml"), "application/xml")
        XCTAssertEqual(value(try all(types, "Override").first, "ContentType"),
                       "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml")

        // Each picture of the document points at its part through the document's relationships.
        let relationships = try all(XCTUnwrap(part(zip, "word/_rels/document.xml.rels").rootElement()), "Relationship")
        XCTAssertEqual(relationships.map { value($0, "Id") }, ["rId1", "rId2"])
        XCTAssertTrue(relationships.allSatisfy { value($0, "Type") == DocxWriter.imageRelationshipType })
        XCTAssertEqual(relationships.map { value($0, "Target") }, ["media/image1.jpeg", "media/image2.png"])
        XCTAssertTrue(relationships.allSatisfy { zip.data("word/" + (value($0, "Target") ?? "")) != nil })

        let document = try part(zip, "word/document.xml")
        let inlines = try all(document, "inline")
        XCTAssertEqual(inlines.count, 2)
        XCTAssertEqual(try all(document, "blip").map { $0.attribute(forLocalName: "embed", uri: r)?.stringValue },
                       ["rId1", "rId2"])
        var ids: [String?] = []
        for inline in inlines {
            ids.append(value(try all(inline, "docPr").first, "id"))
            // The paper is square (1000 pt) with 1-inch margins: each square page fills the space inside them.
            let extent = try all(inline, "extent").first
            XCTAssertEqual(value(extent, "cx"), "10871200")
            XCTAssertEqual(value(extent, "cy"), "10871200")
            let ext = try all(inline, "ext").first
            XCTAssertEqual(value(ext, "cx"), value(extent, "cx"))
            XCTAssertEqual(value(ext, "cy"), value(extent, "cy"))
        }
        XCTAssertEqual(ids, ["1", "2"])

        // The pictures are the bytes given, and they decode.
        let jpeg = try XCTUnwrap(zip.data("word/media/image1.jpeg"))
        XCTAssertEqual(jpeg, DocxFixtures.jpeg)
        XCTAssertEqual(PDFImageEncoding.readJPEGHeader(jpeg), JPEGHeader(width: 16, height: 12, components: 1))
        let decodedJPEG = try XCTUnwrap(DecodedImage(jpeg))
        XCTAssertEqual(decodedJPEG.type, "public.jpeg")
        XCTAssertEqual(decodedJPEG.width, 16)
        XCTAssertEqual(decodedJPEG.height, 12)
        let png = try XCTUnwrap(zip.data("word/media/image2.png"))
        XCTAssertEqual(png, DocxFixtures.png)
        let decodedPNG = try XCTUnwrap(DecodedImage(png))
        XCTAssertEqual(decodedPNG.type, "public.png")
        XCTAssertEqual(decodedPNG.width, 16)
        XCTAssertEqual(decodedPNG.height, 12)
        let gray = decodedPNG.grayPixels
        for y in 0..<12 {
            for x in 0..<16 {
                XCTAssertEqual(gray[y * 16 + x] < 128, DocxFixtures.pngIsBlack(x, y), "pixel (\(x), \(y))")
            }
        }
    }

    func test_make_withPageImages_eachPagePictureThenItsText() throws {
        let docx = DocxWriter.make(TextExportTests.samplePages(),
                                   pictures: [DocxFixtures.jpegPicture, DocxFixtures.pngPicture])
        let elements = try paragraphs(part(StoredZip(docx), "word/document.xml"))
        var texts: [String] = []
        var drawings: [Bool] = []
        var breaks: [Bool] = []
        for paragraph in elements {
            texts.append(try text(paragraph))
            drawings.append(try hasDrawing(paragraph))
            breaks.append(try breaksPage(paragraph))
        }
        XCTAssertEqual(texts, ["", "Café menu", "Soupe à l'oignon\t4,50 €\n東京 ラーメン\t9.00",
                               "This line is forwarding the rest.", "", "שלום עולם", "Fish & Chips <b>"])
        XCTAssertEqual(drawings, [true, false, false, false, true, false, false])
        // The second page starts at its picture; the text after a picture never breaks the page itself.
        XCTAssertEqual(breaks, [false, false, false, false, true, false, false])
    }

    func test_documentXML_pictureParagraph_exactMarkup() throws {
        let letter = OCRPage(lines: [], widthPoints: 612, heightPoints: 792)
        let xml = DocxWriter.documentXML([letter], pictures: [DocxFixtures.jpegPicture])
        var expected = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        expected += "<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\""
        expected += " xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\""
        expected += " xmlns:wp=\"http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing\""
        expected += " xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\""
        expected += " xmlns:pic=\"http://schemas.openxmlformats.org/drawingml/2006/picture\"><w:body>"
        expected += "<w:p><w:pPr><w:spacing w:before=\"0\" w:after=\"0\"/><w:jc w:val=\"center\"/></w:pPr>"
        expected += "<w:r><w:drawing><wp:inline distT=\"0\" distB=\"0\" distL=\"0\" distR=\"0\">"
        expected += "<wp:extent cx=\"5943600\" cy=\"7691717\"/><wp:effectExtent l=\"0\" t=\"0\" r=\"0\" b=\"0\"/>"
        expected += "<wp:docPr id=\"1\" name=\"Page 1\" descr=\"Page 1 as scanned\"/>"
        expected += "<wp:cNvGraphicFramePr><a:graphicFrameLocks noChangeAspect=\"1\"/></wp:cNvGraphicFramePr>"
        expected += "<a:graphic><a:graphicData uri=\"http://schemas.openxmlformats.org/drawingml/2006/picture\"><pic:pic>"
        expected += "<pic:nvPicPr><pic:cNvPr id=\"1\" name=\"image1.jpeg\"/><pic:cNvPicPr><a:picLocks noChangeAspect=\"1\"/></pic:cNvPicPr></pic:nvPicPr>"
        expected += "<pic:blipFill><a:blip r:embed=\"rId1\"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>"
        expected += "<pic:spPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"5943600\" cy=\"7691717\"/></a:xfrm>"
        expected += "<a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></pic:spPr>"
        expected += "</pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>"
        expected += "<w:sectPr><w:pgSz w:w=\"12240\" w:h=\"15840\"/><w:pgMar w:top=\"1440\" w:right=\"1440\" "
        expected += "w:bottom=\"1440\" w:left=\"1440\" w:header=\"720\" w:footer=\"720\" w:gutter=\"0\"/></w:sectPr></w:body></w:document>"
        XCTAssertEqual(xml, expected)
        XCTAssertEqual(try XMLDocument(data: Data(xml.utf8)).rootElement()?.localName, "document")
    }

    func test_pictureSize_realSize_orShrunkInsideTheMargins_keepingItsShape() {
        func size(_ width: Double, _ height: Double, _ paperWidth: Int = 12240, _ paperHeight: Int = 15840) -> [Int] {
            let s = DocxWriter.pictureSizeEMU(OCRPage(lines: [], widthPoints: width, heightPoints: height),
                                              paperWidthTwips: paperWidth, paperHeightTwips: paperHeight)
            return [s.width, s.height]
        }
        // US Letter paper: 8.5 × 11 in with 1-inch margins leaves 6.5 × 9 in (5943600 × 8229600 EMU).
        XCTAssertEqual(size(612, 792), [5943600, 7691717])
        // A landscape page on portrait paper: as wide as the margins allow.
        XCTAssertEqual(size(792, 612), [5943600, 4592781])
        // A long, narrow receipt: as tall as the margins allow.
        XCTAssertEqual(size(216, 2160), [822960, 8229600])
        // A small page keeps its real size (3 × 5 in), never enlarged.
        XCTAssertEqual(size(216, 360), [2743200, 4572000])
        // A page that is its paper (a receipt-sized paper, margins an eighth of its width) fits inside the margins.
        XCTAssertEqual(size(216, 360, 4320, 7200), [2057400, 3429000])
        // No size: the space inside the margins. A huge page is still shrunk to fit.
        XCTAssertEqual(size(0, 792), [5943600, 8229600])
        XCTAssertEqual(size(Double.nan, 792), [5943600, 8229600])
        XCTAssertEqual(size(1e300, 1e300), [5943600, 5943600])
        XCTAssertEqual(72 * DocxWriter.emuPerPoint, 914400)
        XCTAssertEqual(DocxWriter.twipsPerInch * DocxWriter.emuPerTwip, 914400)
    }

    func test_make_withoutPictures_isTheTextOnlyPackage() {
        let pages = TextExportTests.samplePages()
        let textOnly = DocxWriter.make(pages)
        XCTAssertEqual(DocxWriter.make(pages, pictures: []), textOnly)
        XCTAssertEqual(DocxWriter.make(pages, pictures: [nil, nil]), textOnly)
        XCTAssertEqual(DocxWriter.packageContentTypesXML([]), DocxWriter.contentTypesXML)
        // Pictures past the last page are left out.
        XCTAssertEqual(DocxWriter.make([OCRFixtures.page()], pictures: [nil, DocxFixtures.pngPicture]),
                       DocxWriter.make([OCRFixtures.page()]))
    }

    func test_make_somePagesWithPictures_numbersThePicturesInOrder() throws {
        let pages = [OCRFixtures.page(OCRFixtures.line("One", 50, 100, 200)), OCRFixtures.page(), OCRFixtures.page()]
        let docx = DocxWriter.make(pages, pictures: [DocxFixtures.pngPicture, nil, DocxFixtures.pngPicture])
        let zip = try StoredZip(docx)
        XCTAssertEqual(zip.entries.map(\.name),
                       ["[Content_Types].xml", "_rels/.rels", "word/document.xml", "word/_rels/document.xml.rels",
                        "word/media/image1.png", "word/media/image2.png"])
        let types = try XCTUnwrap(part(zip, "[Content_Types].xml").rootElement())
        XCTAssertEqual(try all(types, "Default").map { value($0, "Extension") }, ["rels", "xml", "png"])
        let elements = try paragraphs(part(zip, "word/document.xml"))
        var texts: [String] = []
        var drawings: [Bool] = []
        var breaks: [Bool] = []
        for paragraph in elements {
            texts.append(try text(paragraph))
            drawings.append(try hasDrawing(paragraph))
            breaks.append(try breaksPage(paragraph))
        }
        // Page 1: picture and text; page 2: an empty paragraph starting the page; page 3: its picture alone.
        XCTAssertEqual(texts, ["", "One", "", ""])
        XCTAssertEqual(drawings, [true, false, false, true])
        XCTAssertEqual(breaks, [false, false, true, true])
        let docPr = try XCTUnwrap(all(elements[3], "docPr").first)
        XCTAssertEqual(value(docPr, "id"), "2")
        XCTAssertEqual(value(docPr, "name"), "Page 3")
        XCTAssertEqual(value(docPr, "descr"), "Page 3 as scanned")
        XCTAssertEqual(value(try all(elements[3], "cNvPr").first, "name"), "image2.png")
    }

    func test_pictureFormat_followsThePDFSizePlan_andNames() {
        for size in PDFSizePreset.allCases {
            let blackWhite = PDFImageEncoding.plan(mode: .blackWhite, imageDPI: 300, size: size, looksGray: false)
            let gray = PDFImageEncoding.plan(mode: .grayscale, imageDPI: 300, size: size, looksGray: false)
            let grayLooking = PDFImageEncoding.plan(mode: .color, imageDPI: 300, size: size, looksGray: true)
            let color = PDFImageEncoding.plan(mode: .color, imageDPI: 300, size: size, looksGray: false)
            XCTAssertEqual(DocxWriter.pictureFormat(blackWhite), .png)
            XCTAssertEqual(DocxWriter.pictureFormat(gray), .jpeg)
            XCTAssertEqual(DocxWriter.pictureFormat(grayLooking), .jpeg)
            XCTAssertEqual(DocxWriter.pictureFormat(color), .jpeg)
        }
        XCTAssertEqual(DocxWriter.mediaName(1, format: .jpeg), "image1.jpeg")
        XCTAssertEqual(DocxWriter.mediaName(12, format: .png), "image12.png")
        XCTAssertEqual(DocxWriter.pictureExtension(.jpeg), "jpeg")
        XCTAssertEqual(DocxWriter.pictureContentType(.jpeg), "image/jpeg")
        XCTAssertEqual(DocxWriter.pictureExtension(.png), "png")
        XCTAssertEqual(DocxWriter.pictureContentType(.png), "image/png")
        XCTAssertEqual(DocxWriter.pageImagesLabel, "Include page images")
        XCTAssertEqual(DocxWriter.pageImagesHint(on: true),
                       "Each page's picture, then its editable text")
        XCTAssertEqual(DocxWriter.pageImagesHint(on: false),
                       "Only the editable text, without page pictures")
    }

    func test_make_withPageImages_fingerprint_matchesWindows() {
        // The same numbers in DocxWriterTests.cs: both platforms write the same package.
        let pictures = [DocxFixtures.jpegPicture, DocxFixtures.pngPicture]
        let docx = DocxWriter.make(TextExportTests.samplePages(), pictures: pictures)
        XCTAssertEqual(docx.count, 5482)
        XCTAssertEqual(ZipStore.crc32(docx), 0x8708_C7FC)
        XCTAssertEqual(DocxWriter.make(TextExportTests.samplePages(), pictures: pictures), docx)
        // The fixtures themselves, so a change to them shows here first.
        XCTAssertEqual(DocxFixtures.jpeg.count, 421)
        XCTAssertEqual(DocxFixtures.png.count, 127)
        XCTAssertEqual(ZipStore.crc32(DocxFixtures.jpeg), 0x5854_9185)
        XCTAssertEqual(ZipStore.crc32(DocxFixtures.png), 0xA673_3A06)
    }

    func test_packageSize_isTheLengthMakeWrites() {
        let pages = TextExportTests.samplePages()
        XCTAssertEqual(DocxWriter.packageSize(pages), DocxWriter.make(pages).count)
        XCTAssertEqual(DocxWriter.packageSize(pages, pictures: [DocxFixtures.jpegPicture, DocxFixtures.pngPicture]), 5482)
        let three = [OCRFixtures.page(OCRFixtures.line("One", 50, 100, 200)), OCRFixtures.page(), OCRFixtures.page()]
        let some: [DocxPicture?] = [DocxFixtures.pngPicture, nil, DocxFixtures.jpegPicture]
        XCTAssertEqual(DocxWriter.packageSize(three, pictures: some), DocxWriter.make(three, pictures: some).count)
    }

    func test_packageSize_pastTheLimit_isTold_withoutWritingThePackage() {
        // 64 MiB shared by every page: 29 pictures fit in 2 GB, 30 do not.
        let picture = DocxPicture(data: Data(count: 1 << 26), format: .jpeg)
        let pages = (0..<30).map { _ in OCRFixtures.page() }
        let fits = DocxWriter.packageSize(Array(pages.prefix(29)),
                                          pictures: [DocxPicture?](repeating: picture, count: 29))
        let over = DocxWriter.packageSize(pages, pictures: [DocxPicture?](repeating: picture, count: 30))
        XCTAssertLessThanOrEqual(fits, DocxWriter.maxPackageBytes)
        XCTAssertGreaterThan(over, DocxWriter.maxPackageBytes)
        // The limit is within what a zip without zip64 holds (`ZipStore.make` stops the app past it).
        XCTAssertLessThan(DocxWriter.maxPackageBytes, Int(UInt32.max))
        XCTAssertEqual(DocxWriter.tooLargeMessage,
                       "The Word document would be larger than 2 GB, too large to write. Save fewer pages in each document, "
                       + "choose a smaller page image size, or turn off \"Include page images\".")
    }
}

/// The page pictures of a Word document as the Mac encodes them (`DocxWriter.picture(of:...)`),
/// read back by ImageIO, and a document holding them read back with every picture decoded. Twin of
/// windows/CompleteScanner.App.Tests/DocxPictureTests.cs, which decodes the Windows pictures with WIC.
final class DocxPictureTests: XCTestCase {
    private func page(_ width: Int, _ height: Int, _ color: (Int, Int) -> (UInt8, UInt8, UInt8)) -> CGImage {
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (red, green, blue) = color(x, y)
                let i = (y * width + x) * 4
                rgba[i] = red
                rgba[i + 1] = green
                rgba[i + 2] = blue
            }
        }
        let provider = CGDataProvider(data: Data(rgba) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    /// Text-like black blocks on white, already thresholded as the black & white mode leaves a page.
    private static func ink(_ x: Int, _ y: Int) -> Bool { (y / 6) % 3 == 1 && (x / 5) % 4 != 3 }

    private static func inkColor(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) {
        ink(x, y) ? (0, 0, 0) : (255, 255, 255)
    }

    func test_colorPage_isAColorJPEG_atTheSizesResolution() throws {
        // 2 × 2.5 in at 600 dpi, red on the left half, blue on the right.
        let image = page(1200, 1500) { x, _ in x < 600 ? (220, 30, 30) : (30, 40, 200) }
        let picture = try XCTUnwrap(DocxWriter.picture(of: image, imageDPI: 600, mode: .color, size: .standard))
        XCTAssertEqual(picture.format, .jpeg)
        let decoded = try XCTUnwrap(DecodedImage(picture.data))
        XCTAssertEqual(decoded.type, "public.jpeg")
        // Standard keeps 300 dpi: half the pixels each way.
        XCTAssertEqual(decoded.width, 600)
        XCTAssertEqual(decoded.height, 750)
        XCTAssertEqual(PDFImageEncoding.readJPEGHeader(picture.data)?.components, 3)
        // Best keeps the scan's resolution.
        let best = try XCTUnwrap(DocxWriter.picture(of: image, imageDPI: 600, mode: .color, size: .best))
        XCTAssertEqual(DecodedImage(best.data)?.width, 1200)
        XCTAssertEqual(DecodedImage(best.data)?.height, 1500)
    }

    func test_grayPages_areGrayJPEGs() throws {
        let image = page(300, 400) { x, _ in (UInt8(x % 256), UInt8(x % 256), UInt8(x % 256)) }
        // A color scan without color is stored gray at Standard, as in a PDF; a grayscale scan always.
        let cases: [(ColorMode, PDFSizePreset)] = [(.color, .standard), (.grayscale, .best)]
        for (mode, size) in cases {
            let picture = try XCTUnwrap(DocxWriter.picture(of: image, imageDPI: 300, mode: mode, size: size))
            XCTAssertEqual(picture.format, .jpeg)
            XCTAssertEqual(PDFImageEncoding.readJPEGHeader(picture.data), JPEGHeader(width: 300, height: 400, components: 1))
        }
        // Best keeps a color scan in color, gray or not.
        let best = try XCTUnwrap(DocxWriter.picture(of: image, imageDPI: 300, mode: .color, size: .best))
        XCTAssertEqual(PDFImageEncoding.readJPEGHeader(best.data)?.components, 3)
    }

    func test_blackAndWhitePage_isALosslessGrayPNG() throws {
        let image = page(330, 210, Self.inkColor)
        let picture = try XCTUnwrap(DocxWriter.picture(of: image, imageDPI: 300, mode: .blackWhite, size: .standard))
        XCTAssertEqual(picture.format, .png)
        let bytes = [UInt8](picture.data)
        // A gray PNG (color type 0); ImageIO writes the 1-bit image at 1 bit, or at most 8.
        XCTAssertEqual(Array(bytes.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        XCTAssertEqual(bytes[25], 0)
        XCTAssertTrue(bytes[24] == 1 || bytes[24] == 8, "bit depth \(bytes[24])")
        let decoded = try XCTUnwrap(DecodedImage(picture.data))
        XCTAssertEqual(decoded.type, "public.png")
        XCTAssertEqual(decoded.width, 330)
        XCTAssertEqual(decoded.height, 210)
        let gray = decoded.grayPixels
        var wrong = 0
        for y in 0..<210 {
            for x in 0..<330 where gray[y * 330 + x] != (Self.ink(x, y) ? 0 : 255) {
                wrong += 1
            }
        }
        XCTAssertEqual(wrong, 0)
        // Far smaller than the gray JPEG of the same page.
        let grayJPEG = try XCTUnwrap(DocxWriter.picture(of: image, imageDPI: 300, mode: .grayscale, size: .standard))
        XCTAssertLessThan(picture.data.count * 2, grayJPEG.data.count)

        // 1200 dpi at Compact is stored at 300 dpi, thresholded again after the box filter.
        let fine = page(1320, 840) { x, y in Self.inkColor(x / 4, y / 4) }
        let compact = try XCTUnwrap(DocxWriter.picture(of: fine, imageDPI: 1200, mode: .blackWhite, size: .compact))
        let compactDecoded = try XCTUnwrap(DecodedImage(compact.data))
        XCTAssertEqual(compactDecoded.width, 330)
        XCTAssertEqual(compactDecoded.height, 210)
        XCTAssertEqual(compactDecoded.grayPixels, gray)
    }

    func test_wordDocument_withPictures_readsBackAndEveryPictureDecodes() throws {
        // A Letter page in color and a narrow black & white receipt, both at 300 dpi.
        let color = page(2550, 3300) { x, y in (UInt8(x * 255 / 2550), UInt8(y * 255 / 3300), 128) }
        let receipt = page(900, 3000, Self.inkColor)
        let pages = [OCRPage.of([], pixelWidth: 2550, pixelHeight: 3300, dpi: 300),
                     OCRPage.of([], pixelWidth: 900, pixelHeight: 3000, dpi: 300)]
        let pictures = [DocxWriter.picture(of: color, imageDPI: 300, mode: .color, size: .standard),
                        DocxWriter.picture(of: receipt, imageDPI: 300, mode: .blackWhite, size: .standard)]
        XCTAssertTrue(pictures.allSatisfy { $0 != nil })
        let docx = DocxWriter.make(pages, pictures: pictures)
        let zip = try StoredZip(docx)
        XCTAssertEqual(Array(zip.entries.map(\.name).suffix(2)), ["word/media/image1.jpeg", "word/media/image2.png"])
        let document = try XMLDocument(data: XCTUnwrap(zip.data("word/document.xml")))
        let extents = try document.nodes(forXPath: "//*[local-name()='extent']").compactMap { $0 as? XMLElement }
        XCTAssertEqual(extents.count, 2)
        let names = ["word/media/image1.jpeg", "word/media/image2.png"]
        let expectedTypes = ["public.jpeg", "public.png"]
        for index in 0..<2 {
            let decoded = try XCTUnwrap(DecodedImage(XCTUnwrap(zip.data(names[index]))))
            XCTAssertEqual(decoded.type, expectedTypes[index])
            let cx = try XCTUnwrap(Double(extents[index].attribute(forName: "cx")?.stringValue ?? ""))
            let cy = try XCTUnwrap(Double(extents[index].attribute(forName: "cy")?.stringValue ?? ""))
            // The picture keeps the page's shape on the paper.
            XCTAssertEqual(Double(decoded.width) / Double(decoded.height), cx / cy, accuracy: 0.01)
        }
        // Letter paper from the first page; the Letter page fills the space inside the margins'
        // width, the receipt (3 × 10 in) keeps its width and is shrunk to the 9 in of height.
        XCTAssertEqual(extents[0].attribute(forName: "cx")?.stringValue, "5943600")
        XCTAssertEqual(extents[1].attribute(forName: "cx")?.stringValue, "2468880")
        XCTAssertEqual(extents[1].attribute(forName: "cy")?.stringValue, "8229600")
        // Stored entries: the pictures are already compressed, and the package is about their size.
        let media = zip.entries.filter { $0.name.hasPrefix("word/media/") }.reduce(0) { $0 + $1.data.count }
        XCTAssertLessThan(docx.count, media + 8000)
    }
}
