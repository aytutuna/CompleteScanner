import XCTest
import CoreGraphics
import Foundation
import PDFKit
@testable import LazyScanKit

// Mirrors the object-level cases of windows/LazyScan.Core.Tests/PdfBuilderTests.cs and
// PdfATests.cs (the object writer, the plain PDF's structure, the text layer, the JPEG headers,
// cancellation) with the same fixtures: the TinyJpeg bytes and SyntheticJpeg generator are copied,
// and the golden files are the C# tests' (PdfATests.Standard_GoldenBytes and
// BilevelOutputTests.Pdf_G4AndJpegPages_GoldenBytes), compared byte for byte through their pinned
// length and SHA-256. The JPEGs are fixed bytes, never encoded here, so WIC and ImageIO play no part.
// C# reads the files back with PdfPig; here PDFKit opens them. PDF/A and protected files are
// PDFATests' and PDFEncryptionTests'; C#'s helpers that move the file into place (WriteFile,
// WriteNewFile) stay C#-only (the Mac's is AppState.writePDFAtomically).

final class PDFWriterTests: XCTestCase {
    /// A tiny valid baseline JPEG (1 × 1, one component) for structure tests: C#'s TinyJpeg.
    static let tinyJPEG: [UInt8] = [
        0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01,
        0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0xFF, 0xDB, 0x00, 0x43,
        0x00, 0x08, 0x06, 0x06, 0x07, 0x06, 0x05, 0x08, 0x07, 0x07, 0x07, 0x09,
        0x09, 0x08, 0x0A, 0x0C, 0x14, 0x0D, 0x0C, 0x0B, 0x0B, 0x0C, 0x19, 0x12,
        0x13, 0x0F, 0x14, 0x1D, 0x1A, 0x1F, 0x1E, 0x1D, 0x1A, 0x1C, 0x1C, 0x20,
        0x24, 0x2E, 0x27, 0x20, 0x22, 0x2C, 0x23, 0x1C, 0x1C, 0x28, 0x37, 0x29,
        0x2C, 0x30, 0x31, 0x34, 0x34, 0x34, 0x1F, 0x27, 0x39, 0x3D, 0x38, 0x32,
        0x3C, 0x2E, 0x33, 0x34, 0x32, 0xFF, 0xC0, 0x00, 0x0B, 0x08, 0x00, 0x01,
        0x00, 0x01, 0x01, 0x01, 0x11, 0x00, 0xFF, 0xC4, 0x00, 0x1F, 0x00, 0x00,
        0x01, 0x05, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
        0x09, 0x0A, 0x0B, 0xFF, 0xC4, 0x00, 0xB5, 0x10, 0x00, 0x02, 0x01, 0x03,
        0x03, 0x02, 0x04, 0x03, 0x05, 0x05, 0x04, 0x04, 0x00, 0x00, 0x01, 0x7D,
        0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12, 0x21, 0x31, 0x41, 0x06,
        0x13, 0x51, 0x61, 0x07, 0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xA1, 0x08,
        0x23, 0x42, 0xB1, 0xC1, 0x15, 0x52, 0xD1, 0xF0, 0x24, 0x33, 0x62, 0x72,
        0x82, 0x09, 0x0A, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x25, 0x26, 0x27, 0x28,
        0x29, 0x2A, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3A, 0x43, 0x44, 0x45,
        0x46, 0x47, 0x48, 0x49, 0x4A, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59,
        0x5A, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6A, 0x73, 0x74, 0x75,
        0x76, 0x77, 0x78, 0x79, 0x7A, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89,
        0x8A, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9A, 0xA2, 0xA3,
        0xA4, 0xA5, 0xA6, 0xA7, 0xA8, 0xA9, 0xAA, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6,
        0xB7, 0xB8, 0xB9, 0xBA, 0xC2, 0xC3, 0xC4, 0xC5, 0xC6, 0xC7, 0xC8, 0xC9,
        0xCA, 0xD2, 0xD3, 0xD4, 0xD5, 0xD6, 0xD7, 0xD8, 0xD9, 0xDA, 0xE1, 0xE2,
        0xE3, 0xE4, 0xE5, 0xE6, 0xE7, 0xE8, 0xE9, 0xEA, 0xF1, 0xF2, 0xF3, 0xF4,
        0xF5, 0xF6, 0xF7, 0xF8, 0xF9, 0xFA, 0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01,
        0x00, 0x00, 0x3F, 0x00, 0xFB, 0xD0, 0xFF, 0xD9,
    ]

    static var tinyJPEGData: Data { Data(tinyJPEG) }

    private static func page(_ lines: [OCRLine]? = nil, dpi: Int = 300) -> PDFPageInput {
        PDFPageInput(jpegData: tinyJPEGData, pixelWidth: 100, pixelHeight: 150, dpi: dpi, ocrLines: lines)
    }

    /// A Letter page at 300 dpi (612 × 792 pt) as PdfATests builds it.
    private static func letterPage(_ lines: [OCRLine]? = nil) -> PDFPageInput {
        PDFPageInput(jpegData: tinyJPEGData, pixelWidth: 2550, pixelHeight: 3300, dpi: 300, ocrLines: lines)
    }

    private static func line(_ text: String, _ x: Double, _ y: Double, _ width: Double, _ height: Double) -> OCRLine {
        OCRLine(text: text, boundingBox: CGRect(x: x, y: y, width: width, height: height), confidence: 0.9)
    }

    // MARK: - Byte search (the files are binary: never decoded into Characters)

    static func has(_ data: Data, _ needle: String) -> Bool {
        data.range(of: Data(needle.utf8)) != nil
    }

    static func count(_ data: Data, _ needle: String) -> Int {
        let pattern = Data(needle.utf8)
        var found = 0
        var start = data.startIndex
        while let range = data.range(of: pattern, options: [], in: start..<data.endIndex) {
            found += 1
            start = range.upperBound
        }
        return found
    }

    /// The offset of the first `needle` at or after `from`; nil when there is none.
    static func offset(_ data: Data, _ needle: String, from: Int = 0) -> Int? {
        let pattern = Data(needle.utf8)
        let start = data.startIndex + from
        guard let range = data.range(of: pattern, options: [], in: start..<data.endIndex) else { return nil }
        return range.lowerBound - data.startIndex
    }

    /// The offset of the last `needle`.
    static func lastOffset(_ data: Data, _ needle: String) -> Int? {
        let pattern = Data(needle.utf8)
        guard let range = data.range(of: pattern, options: .backwards, in: data.startIndex..<data.endIndex) else {
            return nil
        }
        return range.lowerBound - data.startIndex
    }

    /// The ASCII text of `count` bytes at `at`.
    static func text(_ data: Data, at: Int, count: Int) -> String {
        let start = data.startIndex + at
        let end = min(start + count, data.endIndex)
        return String(decoding: data[start..<end], as: UTF8.self)
    }

    /// The image XObject's dictionary of the first image: "/Subtype /Image" up to its ">>".
    static func imageDictionary(_ pdf: Data) -> String {
        guard let start = offset(pdf, "/Subtype /Image"), let end = offset(pdf, ">>", from: start) else { return "" }
        return text(pdf, at: start, count: end - start)
    }

    /// Every xref entry points at its "n 0 obj"; the table has `objects` objects.
    static func assertXrefPointsAtEveryObject(_ pdf: Data, objects: Int, file: StaticString = #filePath, line: UInt = #line) {
        guard let marker = lastOffset(pdf, "startxref\n") else {
            return XCTFail("no startxref", file: file, line: line)
        }
        let numberStart = marker + "startxref\n".utf8.count
        guard let numberEnd = offset(pdf, "\n", from: numberStart),
              let xref = Int(text(pdf, at: numberStart, count: numberEnd - numberStart)) else {
            return XCTFail("no xref offset", file: file, line: line)
        }
        let head = "xref\n0 \(objects + 1)\n0000000000 65535 f \n"
        XCTAssertEqual(text(pdf, at: xref, count: head.utf8.count), head, file: file, line: line)
        var entry = xref + head.utf8.count
        for n in 1...objects {
            guard let objectOffset = Int(text(pdf, at: entry, count: 10)) else {
                return XCTFail("entry \(n) is not a number", file: file, line: line)
            }
            let expected = "\(n) 0 obj\n"
            XCTAssertEqual(text(pdf, at: objectOffset, count: expected.utf8.count), expected, file: file, line: line)
            entry += 20
        }
    }

    /// Hand-assembled JPEG header (C#'s SyntheticJpeg): SOI, APP0 JFIF, optionally an APP1 EXIF
    /// segment whose payload contains a decoy SOF0 and EOI, DQT, DHT, fill bytes, the frame header
    /// with the given marker and size, then SOS, a little scan data and EOI.
    static func syntheticJPEG(width: Int, height: Int, sofMarker: UInt8 = 0xC0, withExif: Bool = false) -> Data {
        var bytes: [UInt8] = [0xFF, 0xD8]
        func segment(_ marker: UInt8, _ payload: [UInt8]) {
            let length = payload.count + 2
            bytes.append(0xFF)
            bytes.append(marker)
            bytes.append(UInt8(truncatingIfNeeded: length >> 8))
            bytes.append(UInt8(truncatingIfNeeded: length))
            bytes.append(contentsOf: payload)
        }
        var app0: [UInt8] = Array("JFIF".utf8)
        app0.append(contentsOf: [0x00, 0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00])
        segment(0xE0, app0)
        if withExif {
            // A decoy frame header (and EOI) inside the APP1 payload: only a length-driven walk skips it.
            var app1: [UInt8] = Array("Exif".utf8)
            app1.append(contentsOf: [0x00, 0x00, 0x4D, 0x4D, 0x00, 0x2A])
            app1.append(contentsOf: [0xFF, 0xC0, 0x00, 0x11, 0x08, 0x0F, 0xFF, 0x0F, 0xFF, 0x03])
            app1.append(contentsOf: [0xFF, 0xD9, 0x00, 0x00])
            segment(0xE1, app1)
        }
        var dqt: [UInt8] = [0x00]
        dqt.append(contentsOf: [UInt8](repeating: 1, count: 64))
        segment(0xDB, dqt)
        var dht: [UInt8] = [0x00]
        dht.append(contentsOf: [UInt8](repeating: 0, count: 16))
        dht.append(0x00)
        segment(0xC4, dht)
        bytes.append(contentsOf: [0xFF, 0xFF]) // fill bytes before the next marker are legal
        var frame: [UInt8] = [0x08]
        frame.append(UInt8(truncatingIfNeeded: height >> 8))
        frame.append(UInt8(truncatingIfNeeded: height))
        frame.append(UInt8(truncatingIfNeeded: width >> 8))
        frame.append(UInt8(truncatingIfNeeded: width))
        frame.append(contentsOf: [0x03, 0x01, 0x22, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01])
        segment(sofMarker, frame)
        segment(0xDA, [0x03, 0x01, 0x00, 0x02, 0x11, 0x03, 0x11, 0x00, 0x3F, 0x00])
        bytes.append(contentsOf: [0x12, 0x34, 0xFF, 0x00, 0x56, 0xFF, 0xD9])
        return Data(bytes)
    }

    // MARK: - The object writer (PdfATests.ObjectWriter_*)

    func test_objectWriter_writesObjectsStreamsAndTheTable() throws {
        var output = Data()
        let w = PDFObjectWriter { chunk in output.append(chunk) }
        try w.writeHeader("1.4")
        try w.writeStream(2, "", Data("abc".utf8))
        try w.writeObject(1, "<</Type /Catalog>>")
        try w.finish("/Root 1 0 R")
        var expected = Data("%PDF-1.4\n".utf8)
        expected.append(contentsOf: [0x25, 0xE2, 0xE3, 0xCF, 0xD3, 0x0A])
        expected.append(Data("2 0 obj\n<</Length 3>>\nstream\nabc\nendstream\nendobj\n".utf8))
        expected.append(Data("1 0 obj\n<</Type /Catalog>>\nendobj\n".utf8))
        expected.append(Data("xref\n0 3\n0000000000 65535 f \n0000000065 00000 n \n0000000015 00000 n \n".utf8))
        expected.append(Data("trailer\n<</Size 3 /Root 1 0 R>>\nstartxref\n99\n%%EOF\n".utf8))
        XCTAssertEqual(output, expected)
        XCTAssertEqual(w.position, expected.count)
    }

    func test_objectWriter_asciiString_isALiteralInAnOpenFile() throws {
        let w = PDFObjectWriter { _ in }
        XCTAssertNil(w.encryption)
        XCTAssertEqual(try w.asciiString("Adobe"), "(Adobe)")
        XCTAssertEqual(try w.asciiString("a(b)\\c"), "(a\\(b\\)\\\\c)")
        XCTAssertThrowsError(try w.asciiString("Çağrı"))
    }

    func test_objectWriter_refusesGapsAndRepeats() throws {
        let w = PDFObjectWriter { _ in }
        try w.writeObject(2, "null")
        XCTAssertThrowsError(try w.writeObject(2, "null"))
        XCTAssertThrowsError(try w.beginObject(0))
        XCTAssertThrowsError(try w.finish("/Root 1 0 R"))
    }

    // MARK: - Structure (PdfBuilderTests)

    func test_headerAndTrailerPresent() throws {
        let pdf = try PDFWriter.make([Self.page()])
        XCTAssertEqual(Self.text(pdf, at: 0, count: 8), "%PDF-1.4")
        XCTAssertEqual(Self.text(pdf, at: pdf.count - 6, count: 6), "%%EOF\n")
        XCTAssertTrue(Self.has(pdf, "startxref"))
    }

    func test_pageCountMatches() throws {
        let pdf = try PDFWriter.make([Self.page(), Self.page(), Self.page()])
        XCTAssertTrue(Self.has(pdf, "/Count 3"))
        XCTAssertTrue(Self.has(pdf, "/Im0"))
        XCTAssertTrue(Self.has(pdf, "/Im2"))
    }

    func test_mediaBoxIsPixelsOverDpiTimes72() throws {
        // 100 px / 300 dpi * 72 = 24 pt; 150 px -> 36 pt.
        let pdf = try PDFWriter.make([Self.page(dpi: 300)])
        XCTAssertTrue(Self.has(pdf, "/MediaBox [0 0 24 36]"))
    }

    func test_invisibleTextLayerEmittedForOcrLines() throws {
        let pdf = try PDFWriter.make([Self.page([Self.line("hello world", 0.1, 0.8, 0.5, 0.05)])])
        XCTAssertTrue(Self.has(pdf, "3 Tr"))                  // invisible text rendering mode
        XCTAssertTrue(Self.has(pdf, "<00680065006C006C006F00200077006F0072006C0064> Tj")) // UTF-16 code units
        XCTAssertTrue(Self.has(pdf, "/Subtype /Type0 /BaseFont /GlyphLessFont /Encoding /Identity-H"))
        XCTAssertFalse(Self.has(pdf, "Helvetica"))
    }

    func test_noTextLayerWithoutOcrLines() throws {
        let pdf = try PDFWriter.make([Self.page()])
        XCTAssertFalse(Self.has(pdf, "3 Tr"))
        XCTAssertFalse(Self.has(pdf, "BT\n"))
        // No page has text: the font is left out altogether.
        XCTAssertFalse(Self.has(pdf, "/Font"))
        XCTAssertTrue(Self.has(pdf, "1 0 obj\n<</Type /Catalog /Pages 2 0 R>>"))
        XCTAssertTrue(Self.has(pdf, "3 0 obj\n<</Type /Page /Parent 2 0 R"))
    }

    func test_textNeedsNoEscaping_itIsWrittenAsHex() throws {
        let pdf = try PDFWriter.make([Self.page([Self.line("a(b)c\\d", 0.1, 0.5, 0.4, 0.05)])])
        XCTAssertTrue(Self.has(pdf, "<00610028006200290063005C0064> Tj"))
    }

    func test_xrefOffsetsPointAtObjects() throws {
        let plain = try PDFWriter.make([Self.page()])
        Self.assertXrefPointsAtEveryObject(plain, objects: 5)
        let withText = try PDFWriter.make([Self.page([Self.line("x", 0, 0, 1, 1)]), Self.page()])
        Self.assertXrefPointsAtEveryObject(withText, objects: 14)
    }

    func test_makePDFTwoPages() throws {
        let one = PDFPageInput(jpegData: Self.tinyJPEGData, pixelWidth: 400, pixelHeight: 300, dpi: 100, ocrLines: nil)
        let pdf = try PDFWriter.make([one, one])
        XCTAssertTrue(Self.has(pdf, "/Count 2"))
        // 400 px / 100 dpi * 72 = 288 pt; 300 px / 100 dpi * 72 = 216 pt.
        XCTAssertEqual(Self.count(pdf, "/MediaBox [0 0 288 216]"), 2)
    }

    func test_standard_isUnchanged_noMetadataIntentOrId() throws {
        let lines = [Self.line("Çağrı", 0.1, 0.8, 0.6, 0.04), Self.line("𠀋 📄", 0.1, 0.7, 0.3, 0.04)]
        let pdf = try PDFWriter.make([Self.letterPage(lines)])
        XCTAssertEqual(Self.text(pdf, at: 0, count: 9), "%PDF-1.4\n")
        XCTAssertFalse(Self.has(pdf, "/Metadata"))
        XCTAssertFalse(Self.has(pdf, "/OutputIntents"))
        XCTAssertFalse(Self.has(pdf, "/ID"))
        XCTAssertFalse(Self.has(pdf, "/Info"))
        XCTAssertTrue(Self.has(pdf, "trailer\n<</Size 12 /Root 1 0 R>>"))
        XCTAssertTrue(Self.has(pdf, "9 0 obj\n<</Type /Page"))
        // Characters beyond the BMP get codes from D800 and come back through the ToUnicode map.
        XCTAssertTrue(Self.has(pdf, "2 beginbfchar\n<D800> <D840DC0B>\n<D801> <D83DDCC4>\nendbfchar\n"))
        Self.assertXrefPointsAtEveryObject(pdf, objects: 11)
    }

    // MARK: - The text layer (PdfATests.TextLayer_*)

    func test_textLayer_linesSitInTheirBoxes() throws {
        // A line 0.8 of the page wide at x 0.1 and 0.05 tall at y 0.5 (bottom-left origin) on Letter.
        let pdf = try PDFWriter.make([Self.letterPage([Self.line("Şehir İçi ığdır", 0.1, 0.5, 0.8, 0.05)])])
        XCTAssertTrue(Self.has(pdf, "/F1 39.6 Tf\n"))
        XCTAssertTrue(Self.has(pdf, "1 0 0 1 61.2 396 Tm\n"))
        // 15 code units × 0.5 em × 39.6 pt = 297 pt measured; 489.6 pt wanted.
        XCTAssertTrue(Self.has(pdf, "164.8485 Tz\n"))
        let placed = try XCTUnwrap(PDFWriter.textLayerLine(Self.line("Şehir İçi ığdır", 0.1, 0.5, 0.8, 0.05),
                                                           codes: GlyphlessCodes.of([]), widthPts: 612, heightPts: 792))
        XCTAssertEqual(placed.fontSize, 39.6, accuracy: 1e-9)
        XCTAssertEqual(placed.x, 61.2, accuracy: 1e-9)
        XCTAssertEqual(placed.baseline, 396, accuracy: 1e-9)
    }

    func test_textLayer_scaleIsClamped_andEmptyLinesAreSkipped() throws {
        let lines = [
            Self.line("x", 0, 0.5, 1, 0.01),                                            // far too wide: 5×
            Self.line("a very long line squeezed into a tiny box", 0, 0.4, 0.01, 0.05), // 0.2×
            Self.line("", 0, 0.3, 0.5, 0.05),
            Self.line("flat", 0, 0.2, 0.5, 0),
        ]
        let pdf = try PDFWriter.make([Self.letterPage(lines)])
        XCTAssertTrue(Self.has(pdf, "500 Tz\n"))
        XCTAssertTrue(Self.has(pdf, "20 Tz\n"))
        XCTAssertEqual(Self.count(pdf, " Tj\n"), 2)
    }

    func test_textLayer_opensInPDFKit_withItsText() throws {
        let lines = [Self.line("Çağrı Işık İzmir'de öğün şüpheli", 0.1, 0.8, 0.6, 0.04)]
        let pdf = try PDFWriter.make([Self.letterPage(lines), Self.letterPage()])
        let document = try XCTUnwrap(PDFDocument(data: pdf))
        XCTAssertEqual(document.pageCount, 2)
        let bounds = try XCTUnwrap(document.page(at: 0)).bounds(for: .mediaBox)
        XCTAssertEqual(Double(bounds.width), 612, accuracy: 0.01)
        XCTAssertEqual(Double(bounds.height), 792, accuracy: 0.01)
        let text = document.page(at: 0)?.string ?? ""
        XCTAssertTrue(text.contains("Çağrı"), "PDFKit read: \(text)")
    }

    // MARK: - Numbers

    func test_numbers_areWrittenAsCSharpWritesThem() {
        // Values and texts from C#'s value.ToString("0.####", CultureInfo.InvariantCulture).
        XCTAssertEqual(PDFWriter.f(0), "0")
        XCTAssertEqual(PDFWriter.f(-0.0), "-0")
        XCTAssertEqual(PDFWriter.f(-0.00001), "-0")
        XCTAssertEqual(PDFWriter.f(0.00005), "0.0001")
        XCTAssertEqual(PDFWriter.f(0.00004999), "0")
        XCTAssertEqual(PDFWriter.f(0.00015), "0.0002")
        XCTAssertEqual(PDFWriter.f(1e-10), "0")
        XCTAssertEqual(PDFWriter.f(123456789.123456), "123456789.1235")
        XCTAssertEqual(PDFWriter.f(1e20), "100000000000000000000")
        XCTAssertEqual(PDFWriter.f(9.99995), "10")
        XCTAssertEqual(PDFWriter.f(9.99994999), "9.9999")
        XCTAssertEqual(PDFWriter.f(0.99995), "1")
        XCTAssertEqual(PDFWriter.f(24), "24")
        XCTAssertEqual(PDFWriter.f(612), "612")
        XCTAssertEqual(PDFWriter.f(164.84848484848484), "164.8485")
        XCTAssertEqual(PDFWriter.f(0.1 * 612), "61.2")
        XCTAssertEqual(PDFWriter.f(0.8 * 792), "633.6")
        XCTAssertEqual(PDFWriter.f(-1.5), "-1.5")
        XCTAssertEqual(PDFWriter.f(-0.00005), "-0.0001")
        XCTAssertEqual(PDFWriter.f(2.5e-5), "0")
        XCTAssertEqual(PDFWriter.f(99999.99995), "100000")
        XCTAssertEqual(PDFWriter.f(1234567.89012345), "1234567.8901")
    }

    // MARK: - The image XObject (PdfBuilderTests)

    func test_jpegHeader_isReadFromTheFrameHeader() {
        let cases: [(UInt8, Bool)] = [(0xC0, false), (0xC0, true), (0xC1, true), (0xC2, false), (0xC2, true)]
        for (marker, exif) in cases {
            let header = PDFImageEncoding.readJPEGHeader(Self.syntheticJPEG(width: 1275, height: 1650, sofMarker: marker,
                                                                            withExif: exif))
            XCTAssertEqual(header, JPEGHeader(width: 1275, height: 1650, components: 3), "\(marker) \(exif)")
        }
        XCTAssertEqual(PDFImageEncoding.readJPEGHeader(Self.tinyJPEGData), JPEGHeader(width: 1, height: 1, components: 1))
    }

    func test_malformedJpegHeadersAreRejected() {
        let good = [UInt8](Self.syntheticJPEG(width: 640, height: 480, withExif: true))
        var sofIndex = 0
        for i in 0..<(good.count - 1) where good[i] == 0xFF && good[i + 1] == 0xC0 {
            sofIndex = i // the real frame header, after the decoy
        }
        XCTAssertNil(PDFImageEncoding.readJPEGHeader(Data()))
        XCTAssertNil(PDFImageEncoding.readJPEGHeader(Data("%PDF-1.4".utf8)))
        XCTAssertNil(PDFImageEncoding.readJPEGHeader(Data(good[0..<(sofIndex + 6)])))   // truncated frame header
        XCTAssertNil(PDFImageEncoding.readJPEGHeader(Data(good[0..<30])))              // truncated APP1
        XCTAssertNil(PDFImageEncoding.readJPEGHeader(Self.syntheticJPEG(width: 640, height: 0))) // height via DNL
        // Scan data before any frame header.
        let scanFirst: [UInt8] = [0xFF, 0xD8, 0xFF, 0xDA, 0x00, 0x02, 0xFF, 0xC0, 0x00, 0x11, 0x08, 0x00, 0x10, 0x00, 0x10]
        XCTAssertNil(PDFImageEncoding.readJPEGHeader(Data(scanFirst)))
    }

    func test_grayJpegIsEmbeddedAsDeviceGray() throws {
        // TinyJpeg has one component: a gray page image.
        let pdf = try PDFWriter.make([Self.page()])
        let image = Self.imageDictionary(pdf)
        XCTAssertTrue(image.contains("/ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /DCTDecode"), image)
        XCTAssertFalse(image.contains("DeviceRGB"))
    }

    func test_colorJpegIsEmbeddedAsDeviceRgb_andBothKindsMix() throws {
        let color = PDFPageInput(jpegData: Self.syntheticJPEG(width: 100, height: 150), pixelWidth: 100,
                                 pixelHeight: 150, dpi: 300, ocrLines: nil)
        let pdf = try PDFWriter.make([color, Self.page(), color])
        XCTAssertTrue(Self.imageDictionary(pdf).contains("/ColorSpace /DeviceRGB"))
        XCTAssertEqual(Self.count(pdf, "/ColorSpace /DeviceRGB"), 2)
        XCTAssertEqual(Self.count(pdf, "/ColorSpace /DeviceGray"), 1)
    }

    func test_unreadableJpegIsDeclaredRgb_atThePagePixelSize() throws {
        let page = PDFPageInput(jpegData: Data([0xFF, 0xD8, 0xFF, 0xD9]), pixelWidth: 100, pixelHeight: 150, dpi: 300,
                                ocrLines: nil)
        let pdf = try PDFWriter.make([page])
        let image = Self.imageDictionary(pdf)
        XCTAssertTrue(image.contains("/ColorSpace /DeviceRGB"), image)
        XCTAssertTrue(image.contains("/Width 100 /Height 150"), image)
    }

    func test_xObjectUsesJpegSizeWhileMediaBoxUsesPageSize() throws {
        // A letter page at 600 dpi (5100 x 6600) whose JPEG is only a 1275 x 1650 preview.
        let page = PDFPageInput(jpegData: Self.syntheticJPEG(width: 1275, height: 1650, sofMarker: 0xC2, withExif: true),
                                pixelWidth: 5100, pixelHeight: 6600, dpi: 600, ocrLines: nil)
        let pdf = try PDFWriter.make([page])
        XCTAssertTrue(Self.imageDictionary(pdf).contains("/Width 1275 /Height 1650"))
        XCTAssertTrue(Self.has(pdf, "/MediaBox [0 0 612 792]"))
        XCTAssertTrue(Self.has(pdf, "612 0 0 792 0 0 cm")) // the image is stretched over the whole page
    }

    // MARK: - Cancellation

    func test_cancelledBeforeFirstPage_throwsCancelled() {
        XCTAssertThrowsError(try PDFWriter.make([Self.page()], shouldContinue: { false })) { error in
            guard case ScanError.cancelled = error else { return XCTFail("\(error)") }
        }
    }

    func test_cancellationIsCheckedBeforeEachPage() {
        var messages: [String] = []
        var stop = false
        let progress: (String) -> Void = { message in
            messages.append(message)
            stop = true // cancel while page 1 is being written
        }
        XCTAssertThrowsError(try PDFWriter.make([Self.page(), Self.page(), Self.page()], progress: progress,
                                                shouldContinue: { !stop })) { error in
            guard case ScanError.cancelled = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(messages, ["Writing page 1 of 3…"]) // page 2 was never started
    }

    func test_writeFile_writesWhatMakeBuilds() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PDFWriterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("out.pdf")
        let pages = [Self.letterPage([Self.line("Çağrı", 0.1, 0.8, 0.6, 0.04)]), Self.page()]
        try PDFWriter.writeFile(pages, to: url)
        XCTAssertEqual(try Data(contentsOf: url), try PDFWriter.make(pages))
    }

    // MARK: - Golden bytes (pinned in C#)

    func test_standard_goldenBytes() throws {
        // PdfATests.Standard_GoldenBytes: a Letter page with a Turkish line, then a plain one.
        let line = Self.line("Çağrı Işık İzmir'de öğün şüpheli", 0.1, 0.8, 0.6, 0.04)
        let pdf = try PDFWriter.make([Self.letterPage([line]), Self.letterPage()])
        XCTAssertEqual(pdf.count, 9866)
        XCTAssertEqual(CompanionPackage.sha256Hex(pdf).uppercased(),
                       "7364F91269282507EE7AAE7006D38A735F96277719C074EE2476BA2D6D3E2594")
    }

    func test_g4AndJpegPages_goldenBytes() throws {
        // BilevelOutputTests.Pdf_G4AndJpegPages_GoldenBytes: the 37 × 23 checkerboard as a G4 page at
        // 100 dpi with a Turkish line, then a JPEG page.
        let packed = CCITTG4EncoderTests.packed(width: 37, height: 23) { x, y in ((x + y) & 1) == 0 }
        let checker = try CCITTG4Encoder.encode(packed, width: 37, height: 23)
        let line = Self.line("Siyah beyaz — Çağrı", 0.1, 0.5, 0.8, 0.2)
        let g4 = PDFPageInput(image: .ccittG4(data: Data(checker), width: 37, height: 23), pixelWidth: 37,
                              pixelHeight: 23, dpi: 100, ocrLines: [line])
        let jpeg = PDFPageInput(jpegData: Self.tinyJPEGData, pixelWidth: 850, pixelHeight: 1100, dpi: 100, ocrLines: nil)
        let pdf = try PDFWriter.make([g4, jpeg])
        XCTAssertEqual(pdf.count, 9892)
        XCTAssertEqual(CompanionPackage.sha256Hex(pdf).uppercased(),
                       "75ED330CDE6CE4BA0D554F7F9C17EA81D2648A3C39E3C5141EBAA73138D4EF29")
    }
}
