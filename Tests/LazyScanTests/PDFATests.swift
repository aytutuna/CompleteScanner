import XCTest
import CoreGraphics
import Foundation
import PDFKit
@testable import LazyScanKit

// Mirrors windows/LazyScan.Core.Tests/PdfATests.cs: PDF/A-2b output (the dates, text strings
// and titles, the information dictionary and XMP packet, the sRGB profile, the archival file's
// header, catalog, numbering and trailer, its golden bytes pinned in C#, the validation samples)
// with the same fixtures. The object writer's cases, the plain file's structure and its text layer
// are PDFWriterTests'. C# reads the files back with PdfPig and parses the XMP with XDocument; here
// PDFKit opens the files and XMLParser reads the packet. PDFKit's text extraction is checked for
// the scripts it gives back in reading order; for the others the content stream's codes and the
// ToUnicode map are checked. The file helpers that pick a free name (WriteNewFile) stay C#-only:
// the Mac moves its temporary file into place itself (AppState.writePDFAtomically).

/// Collects the text of each element of an XML document by namespace and local name.
private final class XMLTextReader: NSObject, XMLParserDelegate {
    private(set) var texts: [String: [String]] = [:]
    private var stack: [String] = []
    private var current = ""

    static func read(_ data: Data) -> XMLTextReader? {
        let reader = XMLTextReader()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = reader
        return parser.parse() ? reader : nil
    }

    func values(_ namespace: String, _ name: String) -> [String] {
        texts[namespace + "|" + name] ?? []
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        stack.append((namespaceURI ?? "") + "|" + elementName)
        current = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        current += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        guard let key = stack.popLast() else { return }
        var list: [String] = texts[key] ?? []
        list.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
        texts[key] = list
        current = ""
    }
}

final class PDFATests: XCTestCase {
    private static let zone: TimeZone = TimeZone(secondsFromGMT: 3 * 3600)!
    /// 2026-10-19 21:30:05 +03:00.
    private static let date = Date(timeIntervalSince1970: 1_792_434_605)
    private static let id: [UInt8] = [0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7,
                                      0xA8, 0xA9, 0xAA, 0xAB, 0xAC, 0xAD, 0xAE, 0xAF]
    private static let idHex = "A0A1A2A3A4A5A6A7A8A9AAABACADAEAF"

    private static func archival(_ title: String? = "Tapu belgesi — Çağrı") -> PDFWriteOptions {
        PDFWriteOptions(conformance: .pdfA2b, title: title, creationDate: date, timeZone: zone, documentId: id)
    }

    /// Recognized lines in several scripts, top to bottom, each with its own box.
    private static let scripts: [String] = [
        "Çağrı Işık İzmir'de öğün şüpheli ılık su içti", // Turkish: ç ğ ı İ ö ş ü
        "ÇĞIİÖŞÜ çğıiöşü",
        "Καλημέρα κόσμε",                                 // Greek
        "Привет, мир",                                    // Cyrillic
        "مرحبا بالعالم",                                  // Arabic
        "שלום עולם",                                      // Hebrew
        "日本語のテキストと中文 𠀋",                         // Japanese and Chinese, with an ideograph beyond the BMP
        "नमस्ते दुनिया",                                    // Devanagari
        "Naïve café — 25 € 📄",                            // Latin with symbols outside Latin-1 and the BMP
    ]

    private static func scriptLines() -> [OCRLine] {
        var lines: [OCRLine] = []
        for (index, text) in scripts.enumerated() {
            let box = CGRect(x: 0.1, y: 0.9 - Double(index) * 0.09, width: 0.8, height: 0.05)
            lines.append(OCRLine(text: text, boundingBox: box, confidence: 0.9))
        }
        return lines
    }

    /// A US Letter page at 300 dpi (612 × 792 pt) with C#'s TinyJpeg.
    private static func page(_ lines: [OCRLine]? = nil) -> PDFPageInput {
        PDFPageInput(jpegData: PDFWriterTests.tinyJPEGData, pixelWidth: 2550, pixelHeight: 3300, dpi: 300,
                     ocrLines: lines)
    }

    /// The blank-page tests' text page in black & white, as a G4 Letter page at 100 dpi.
    private static func blackAndWhitePage() -> PDFPageInput {
        let image = Bilevel.unpack(Bilevel.pack(TestPages.textPage().toRgba()), width: TestPages.width,
                                   height: TestPages.height)
        return PDFPageInput(image: PDFImageData.encodeCCITTG4(image), pixelWidth: image.width,
                            pixelHeight: image.height, dpi: 100, ocrLines: scriptLines())
    }

    private static func has(_ pdf: Data, _ needle: String) -> Bool { PDFWriterTests.has(pdf, needle) }

    // MARK: - Dates, strings, titles

    func test_dates_areWrittenTheSameInBothPlaces() {
        XCTAssertEqual(PDFA.pdfDate(Self.date, timeZone: Self.zone), "D:20261019213005+03'00'")
        XCTAssertEqual(PDFA.xmpDate(Self.date, timeZone: Self.zone), "2026-10-19T21:30:05+03:00")
        let westZone: TimeZone = TimeZone(secondsFromGMT: -(5 * 3600 + 30 * 60))!
        let west = Date(timeIntervalSince1970: 1_767_342_845) // 2026-01-02 03:04:05 -05:30
        XCTAssertEqual(PDFA.pdfDate(west, timeZone: westZone), "D:20260102030405-05'30'")
        XCTAssertEqual(PDFA.xmpDate(west, timeZone: westZone), "2026-01-02T03:04:05-05:30")
        let utcZone: TimeZone = TimeZone(secondsFromGMT: 0)!
        let utc = Date(timeIntervalSince1970: 1_798_761_599) // 2026-12-31 23:59:59 +00:00
        XCTAssertEqual(PDFA.pdfDate(utc, timeZone: utcZone), "D:20261231235959+00'00'")
        XCTAssertEqual(PDFA.xmpDate(utc, timeZone: utcZone), "2026-12-31T23:59:59+00:00")
    }

    func test_textString_isLiteralForAscii_utf16OtherwiseWithItsByteOrderMark() {
        XCTAssertEqual(PDFA.textString("Scan 2026-10-19 1"), "(Scan 2026-10-19 1)")
        XCTAssertEqual(PDFA.textString("a(b)\\c"), "(a\\(b\\)\\\\c)")
        XCTAssertEqual(PDFA.textString("Çağrı"), "<FEFF00C70061011F00720131>")
        XCTAssertEqual(PDFA.textString("\u{1F4C4}"), "<FEFFD83DDCC4>")
        XCTAssertEqual(PDFA.textString(""), "()")
    }

    func test_cleanTitle_dropsWhatXmlCannotHold() {
        // C#'s case also has lone surrogates, which a Swift string cannot hold.
        XCTAssertEqual(PDFA.cleanTitle("A\u{01}BC\u{1F4C4}\u{7F} \u{FFFE}ı"), "ABC\u{1F4C4} ı")
        XCTAssertEqual(PDFA.cleanTitle("Tapu belgesi — Çağrı"), "Tapu belgesi — Çağrı")
        XCTAssertEqual(PDFA.cleanTitle("tab\there\u{FFFF}"), "tabhere")
    }

    func test_infoDictionary_hasTheTitleProducerAndDates() {
        var expected = "<</Title (Scan 1) /Producer (Lazy Scan) /Creator (Lazy Scan) "
        expected += "/CreationDate (D:20261019213005+03'00') /ModDate (D:20261019213005+03'00')>>"
        XCTAssertEqual(PDFA.infoDictionary(title: "Scan 1", date: Self.date, timeZone: Self.zone), expected)
        XCTAssertFalse(PDFA.infoDictionary(title: nil, date: Self.date, timeZone: Self.zone).contains("/Title"))
    }

    func test_xmp_isWellFormed_andNamesPdfA2b() throws {
        let xmp = PDFA.xmp(title: "Fatura <özel> & \"ek\"", date: Self.date, timeZone: Self.zone)
        XCTAssertNotEqual(Array(xmp.prefix(3)), [0xEF, 0xBB, 0xBF]) // no byte order mark before the packet
        let text = String(decoding: xmp, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("<?xpacket begin=\"\u{FEFF}\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?>"))
        XCTAssertTrue(text.hasSuffix("<?xpacket end=\"w\"?>"))
        let reader = try XCTUnwrap(XMLTextReader.read(xmp), "the packet is not well-formed XML")
        let pdfaid = "http://www.aiim.org/pdfa/ns/id/"
        let dc = "http://purl.org/dc/elements/1.1/"
        let rdf = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
        let xmpNs = "http://ns.adobe.com/xap/1.0/"
        let pdf = "http://ns.adobe.com/pdf/1.3/"
        XCTAssertEqual(reader.values(pdfaid, "part"), ["2"])
        XCTAssertEqual(reader.values(pdfaid, "conformance"), ["B"])
        XCTAssertEqual(reader.values(rdf, "li"), ["Fatura <özel> & \"ek\""])
        XCTAssertTrue(text.contains("<rdf:li xml:lang=\"x-default\">"))
        for name in ["CreateDate", "ModifyDate", "MetadataDate"] {
            XCTAssertEqual(reader.values(xmpNs, name), ["2026-10-19T21:30:05+03:00"], name)
        }
        XCTAssertEqual(reader.values(xmpNs, "CreatorTool"), ["Lazy Scan"])
        XCTAssertEqual(reader.values(pdf, "Producer"), ["Lazy Scan"])
        let untitled = try XCTUnwrap(XMLTextReader.read(PDFA.xmp(title: nil, date: Self.date, timeZone: Self.zone)))
        XCTAssertEqual(untitled.values(dc, "title"), [])
    }

    func test_srgbProfile_isTheCc0IccV2DisplayProfile() {
        let icc = PDFA.srgbProfile
        XCTAssertEqual(icc.count, 736)
        let declared = (Int(icc[0]) << 24) | (Int(icc[1]) << 16) | (Int(icc[2]) << 8) | Int(icc[3])
        XCTAssertEqual(declared, 736)                                         // size in the header
        XCTAssertEqual(Array(icc[8...9]), [2, 0x10])                          // version 2.1
        XCTAssertEqual(String(decoding: icc[12..<16], as: UTF8.self), "mntr") // display device
        XCTAssertEqual(String(decoding: icc[16..<20], as: UTF8.self), "RGB ")
        XCTAssertEqual(String(decoding: icc[20..<24], as: UTF8.self), "XYZ ")
        XCTAssertEqual(String(decoding: icc[36..<40], as: UTF8.self), "acsp")
        XCTAssertNotNil(Data(icc).range(of: Data("CC0".utf8)))
        XCTAssertEqual(CompanionPackage.sha256Hex(Data(icc)).uppercased(),
                       "AF4EFE28F6D311799865F325BA39184A2E978B113CA74124D60AF7DE22B105F4")
    }

    func test_writeOptions_followTheArchivalSetting() throws {
        var output = OutputOptions()
        XCTAssertEqual(try PDFWriteOptions.forOutput(output, title: "Scan 1").conformance, .standard)
        XCTAssertEqual(PDFWriteOptions().conformance, .standard)
        XCTAssertEqual(PDFConformance.allCases.first, .standard)
        output.archival = true
        let options = try PDFWriteOptions.forOutput(output, title: "Scan 1")
        XCTAssertEqual(options.conformance, .pdfA2b)
        XCTAssertEqual(options.title, "Scan 1")
        XCTAssertTrue(options.isArchival)
        XCTAssertNil(options.creationDate)
        XCTAssertNil(options.documentId)
    }

    // MARK: - The archival file

    func test_archival_headerTrailerAndCatalog() throws {
        let pdf = try PDFWriter.make([Self.page(Self.scriptLines())], options: Self.archival())
        XCTAssertEqual(PDFWriterTests.text(pdf, at: 0, count: 10), "%PDF-1.7\n%")
        for i in 10..<14 { XCTAssertGreaterThan(pdf[pdf.startIndex + i], 127, "binary comment") }
        XCTAssertEqual(PDFWriterTests.text(pdf, at: pdf.count - 6, count: 6), "%%EOF\n")
        XCTAssertTrue(Self.has(pdf, "/Root 1 0 R /Info 9 0 R /ID [<\(Self.idHex)> <\(Self.idHex)>]>>"))
        XCTAssertFalse(Self.has(pdf, "/Encrypt"))
        XCTAssertFalse(Self.has(pdf, "/Interpolate"))
        XCTAssertFalse(Self.has(pdf, "LZWDecode"))
        // Fixed numbering: 1 Catalog, 2 Pages, 3-8 the font, 9 Info, 10 Metadata, 11 profile, then the page.
        var catalog = "1 0 obj\n<</Type /Catalog /Pages 2 0 R /Metadata 10 0 R /OutputIntents "
        catalog += "[<</Type /OutputIntent /S /GTS_PDFA1 /OutputConditionIdentifier (sRGB IEC61966-2.1) "
        catalog += "/Info (sRGB IEC61966-2.1) /DestOutputProfile 11 0 R>>]>>\nendobj\n"
        XCTAssertTrue(Self.has(pdf, catalog))
        XCTAssertTrue(Self.has(pdf, "2 0 obj\n<</Type /Pages /Kids [12 0 R] /Count 1>>"))
        XCTAssertTrue(Self.has(pdf, "3 0 obj\n<</Type /Font /Subtype /Type0 /BaseFont /GlyphLessFont /Encoding /Identity-H /DescendantFonts [4 0 R] /ToUnicode 8 0 R>>"))
        var cidFont = "4 0 obj\n<</Type /Font /Subtype /CIDFontType2 /BaseFont /GlyphLessFont "
        cidFont += "/CIDSystemInfo <</Registry (Adobe) /Ordering (Identity) /Supplement 0>> "
        cidFont += "/FontDescriptor 5 0 R /DW 500 /CIDToGIDMap 7 0 R>>"
        XCTAssertTrue(Self.has(pdf, cidFont))
        var descriptor = "5 0 obj\n<</Type /FontDescriptor /FontName /GlyphLessFont /Flags 5 /FontBBox [0 0 500 1000] "
        descriptor += "/ItalicAngle 0 /Ascent 1000 /Descent -1 /CapHeight 1000 /StemV 80 /FontFile2 6 0 R>>"
        XCTAssertTrue(Self.has(pdf, descriptor))
        let program = GlyphlessFont.program.count
        XCTAssertTrue(Self.has(pdf, "6 0 obj\n<</Length1 \(program) /Length \(program)>>\nstream\n"))
        XCTAssertTrue(Self.has(pdf, "7 0 obj\n<</Filter /FlateDecode /Length \(GlyphlessFont.cidToGidMap.count)>>\nstream\n"))
        XCTAssertTrue(Self.has(pdf, "9 0 obj\n<</Title <FEFF"))
        // The metadata is not compressed; the profile is the sRGB one with three components.
        let xmpLength = PDFA.xmp(title: PDFA.cleanTitle("Tapu belgesi — Çağrı"), date: Self.date, timeZone: Self.zone).count
        XCTAssertTrue(Self.has(pdf, "10 0 obj\n<</Type /Metadata /Subtype /XML /Length \(xmpLength)>>\nstream\n<?xpacket"))
        XCTAssertTrue(Self.has(pdf, "11 0 obj\n<</N 3 /Length 736>>\nstream\n"))
        var pageObject = "12 0 obj\n<</Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] "
        pageObject += "/Resources <</XObject <</Im0 13 0 R>> /Font <</F1 3 0 R>>>> /Contents 14 0 R>>"
        XCTAssertTrue(Self.has(pdf, pageObject))
        PDFWriterTests.assertXrefPointsAtEveryObject(pdf, objects: 14)
    }

    func test_archival_withoutText_hasNoFont_andNumbersOnFromThree() throws {
        let pdf = try PDFWriter.make([Self.page(), Self.page()], options: Self.archival(nil))
        XCTAssertFalse(Self.has(pdf, "/Font"))
        XCTAssertTrue(Self.has(pdf, "/Metadata 4 0 R"))
        XCTAssertTrue(Self.has(pdf, "/DestOutputProfile 5 0 R"))
        XCTAssertTrue(Self.has(pdf, "3 0 obj\n<</Producer (Lazy Scan)"))
        XCTAssertTrue(Self.has(pdf, "/Kids [6 0 R 9 0 R] /Count 2"))
        XCTAssertTrue(Self.has(pdf, "/Info 3 0 R /ID"))
        PDFWriterTests.assertXrefPointsAtEveryObject(pdf, objects: 11)
    }

    func test_archival_opensWithMatchingMetadata() throws {
        let pdf = try PDFWriter.make([Self.page(Self.scriptLines())], options: Self.archival())
        let document = try XCTUnwrap(PDFDocument(data: pdf))
        XCTAssertEqual(document.majorVersion, 1)
        XCTAssertEqual(document.minorVersion, 7)
        XCTAssertFalse(document.isEncrypted)
        XCTAssertEqual(document.pageCount, 1)
        let attributes: [AnyHashable: Any] = document.documentAttributes ?? [:]
        XCTAssertEqual(attributes[PDFDocumentAttribute.titleAttribute] as? String, "Tapu belgesi — Çağrı")
        XCTAssertEqual(attributes[PDFDocumentAttribute.producerAttribute] as? String, "Lazy Scan")
        XCTAssertEqual(attributes[PDFDocumentAttribute.creatorAttribute] as? String, "Lazy Scan")
        XCTAssertEqual(attributes[PDFDocumentAttribute.creationDateAttribute] as? Date, Self.date)
        XCTAssertEqual(attributes[PDFDocumentAttribute.modificationDateAttribute] as? Date, Self.date)
        // Each XMP property says what the information dictionary says.
        let start = try XCTUnwrap(PDFWriterTests.offset(pdf, "<?xpacket begin"))
        let end = try XCTUnwrap(PDFWriterTests.offset(pdf, "<?xpacket end=\"w\"?>", from: start)) + 19
        let packet = pdf.subdata(in: (pdf.startIndex + start)..<(pdf.startIndex + end))
        let reader = try XCTUnwrap(XMLTextReader.read(packet))
        XCTAssertEqual(reader.values("http://www.aiim.org/pdfa/ns/id/", "part"), ["2"])
        XCTAssertEqual(reader.values("http://www.aiim.org/pdfa/ns/id/", "conformance"), ["B"])
        XCTAssertEqual(reader.values("http://www.w3.org/1999/02/22-rdf-syntax-ns#", "li"), ["Tapu belgesi — Çağrı"])
        XCTAssertEqual(reader.values("http://ns.adobe.com/pdf/1.3/", "Producer"), ["Lazy Scan"])
        XCTAssertEqual(reader.values("http://ns.adobe.com/xap/1.0/", "CreatorTool"), ["Lazy Scan"])
        XCTAssertEqual(reader.values("http://ns.adobe.com/xap/1.0/", "CreateDate"), [PDFA.xmpDate(Self.date, timeZone: Self.zone)])
        XCTAssertEqual(reader.values("http://ns.adobe.com/xap/1.0/", "ModifyDate"), [PDFA.xmpDate(Self.date, timeZone: Self.zone)])
    }

    func test_textLayer_givesBackEveryScript_plainAndArchival() throws {
        for archival in [false, true] {
            let options: PDFWriteOptions? = archival ? Self.archival() : nil
            let pdf = try PDFWriter.make([Self.page(Self.scriptLines())], options: options)
            let codes = GlyphlessCodes.of(Self.scripts)
            // Every line's codes are in the content stream, in order, and the map gives the
            // characters beyond the BMP back as their pairs.
            for line in Self.scripts {
                XCTAssertTrue(Self.has(pdf, codes.hexString(line) + " Tj\n"), line)
            }
            XCTAssertTrue(Self.has(pdf, "<D800> <D840DC0B>\n"))
            XCTAssertTrue(Self.has(pdf, "<D801> <D83DDCC4>\n"))
            // PDFKit reads back the scripts written left to right without combining marks.
            let document = try XCTUnwrap(PDFDocument(data: pdf))
            let read = (document.page(at: 0)?.string ?? "").filter { !$0.isWhitespace }
            for line in Self.scripts[0...3] {
                XCTAssertTrue(read.contains(line.filter { !$0.isWhitespace }), "\(archival): PDFKit read \(read)")
            }
        }
    }

    // MARK: - Golden bytes

    func test_archival_sameInputSameBytes_randomIdOtherwise() throws {
        let pages = [Self.page(Self.scriptLines())]
        XCTAssertEqual(try PDFWriter.make(pages, options: Self.archival()), try PDFWriter.make(pages, options: Self.archival()))
        var undated = Self.archival()
        undated.documentId = nil
        let first = try Self.trailerId(PDFWriter.make(pages, options: undated))
        let second = try Self.trailerId(PDFWriter.make(pages, options: undated))
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first.count, 32)
    }

    private static func trailerId(_ pdf: Data) throws -> String {
        let marker = "/ID [<"
        let start = try XCTUnwrap(PDFWriterTests.offset(pdf, marker)) + marker.utf8.count
        let end = try XCTUnwrap(PDFWriterTests.offset(pdf, ">", from: start))
        return PDFWriterTests.text(pdf, at: start, count: end - start)
    }

    func test_archival_goldenBytes() throws {
        // PdfATests.Archival_GoldenBytes: one Letter page with a Turkish line, dated and identified.
        let line = OCRLine(text: "Çağrı Işık İzmir'de öğün şüpheli", boundingBox: CGRect(x: 0.1, y: 0.8, width: 0.6, height: 0.04),
                           confidence: 0.9)
        let pdf = try PDFWriter.make([Self.page([line])], options: Self.archival("Tapu belgesi — Çağrı"))
        XCTAssertEqual(pdf.count, 11473)
        XCTAssertEqual(CompanionPackage.sha256Hex(pdf).uppercased(),
                       "387107CDC430BDF0BD348CD837BF6BFB673C168706F4C310570D1231C86A8FD8")
    }

    // MARK: - Files

    func test_writeFile_writesTheArchivalFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PDFATests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("Arşiv.pdf")
        try PDFWriter.writeFile([Self.page(Self.scriptLines())], to: url, options: Self.archival())
        XCTAssertEqual(try Data(contentsOf: url), try PDFWriter.make([Self.page(Self.scriptLines())], options: Self.archival()))
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertEqual(names.count, 1)
    }

    /// PDF/A files for an outside validator: with LAZYSCAN_PDFA_SAMPLES naming a folder they are
    /// written there and kept (the macOS CI job runs veraPDF on them, see .github/workflows/ci.yml);
    /// without it they are written to a temporary folder, read back and removed. Twin of
    /// `Archival_ValidationSamples`.
    func test_archival_validationSamples() throws {
        let samples: String = ProcessInfo.processInfo.environment["LAZYSCAN_PDFA_SAMPLES"] ?? ""
        let keep = !samples.trimmingCharacters(in: .whitespaces).isEmpty
        let folder: URL = keep
            ? URL(fileURLWithPath: samples, isDirectory: true)
            : FileManager.default.temporaryDirectory.appendingPathComponent("PDFATests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            if !keep { try? FileManager.default.removeItem(at: folder) }
        }
        let files: [(name: String, pages: [PDFPageInput], title: String?)] = [
            (name: "pdfa-text-layer.pdf", pages: [Self.page(Self.scriptLines()), Self.page()], title: "Tapu belgesi — Çağrı"),
            (name: "pdfa-image-only.pdf", pages: [Self.page()], title: nil),
            // A black & white page: a 1-bit CCITT G4 image in /DeviceGray.
            (name: "pdfa-black-and-white.pdf", pages: [Self.blackAndWhitePage(), Self.page()], title: "Siyah beyaz"),
        ]
        for file in files {
            let url = folder.appendingPathComponent(file.name)
            try PDFWriter.writeFile(file.pages, to: url, options: PDFWriteOptions(conformance: .pdfA2b, title: file.title))
            let document = try XCTUnwrap(PDFDocument(url: url), file.name)
            XCTAssertEqual(document.pageCount, file.pages.count, file.name)
            XCTAssertFalse(document.isEncrypted, file.name)
        }
    }
}
