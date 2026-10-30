import XCTest
import CoreGraphics
import Foundation
import ImageIO
import PDFKit
@testable import LazyScanKit

// Mirrors windows/LazyScan.Core.Tests/BilevelOutputTests.cs: black & white pages as CCITT G4
// in a PDF (the image dictionary and its data; JPEG and G4 pages with a text layer) and G4 TIFFs of
// one or several pages, field by field, with the C#-pinned golden file. The C# case builds its page
// with its own image pipeline; the gray text page thresholded at 128 has the same bits (C# checks
// that too), so the same file comes from `TestPages.textPage()` here. Decoding is ImageIO's (TIFF)
// and CoreGraphics' (PDF) where C# uses PdfPig; a G4 page in a PDF/A file is in PDFATests' validation
// samples, and the appended cases stay C#-only. The cases of PDFBuilder (the scanned pages as PDFWriter
// stores them) and ImageExporter's black & white TIFFs have no C# twin: the Windows view model is not
// in Core.

final class BilevelOutputTests: XCTestCase {
    /// The blank-page tests' text page (850 × 1100 at 100 dpi) as black & white pixels.
    private static func textPage() -> RgbaImage {
        Bilevel.unpack(Bilevel.pack(TestPages.textPage().toRgba()), width: TestPages.width, height: TestPages.height)
    }

    private static func g4Page(_ image: RgbaImage, dpi: Int = 100, lines: [OCRLine]? = nil) -> PDFPageInput {
        PDFPageInput(image: PDFImageData.encodeCCITTG4(image), pixelWidth: image.width, pixelHeight: image.height,
                     dpi: dpi, ocrLines: lines)
    }

    /// Page 1 of `pdf` drawn at one pixel per point into a `width` × `height` RGBA buffer (row 0 at
    /// the top), over white; nil when CoreGraphics cannot read the file.
    static func renderedFirstPage(_ pdf: Data, width: Int, height: Int) -> [UInt8]? {
        guard let provider = CGDataProvider(data: pdf as CFData),
              let document = CGPDFDocument(provider),
              let page = document.page(at: 1) else {
            return nil
        }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { raw -> Bool in
            let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                return false
            }
            context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.interpolationQuality = .none
            context.setShouldAntialias(false)
            context.drawPDFPage(page)
            return true
        }
        return drawn ? pixels : nil
    }

    /// How many pixels of two packed images differ.
    static func differences(_ a: [UInt8], _ b: [UInt8], width: Int, height: Int) -> Int {
        var count = 0
        for y in 0..<height {
            for x in 0..<width {
                let left = Bilevel.isBlack(a, width: width, x: x, y: y)
                if left != Bilevel.isBlack(b, width: width, x: x, y: y) { count += 1 }
            }
        }
        return count
    }

    // MARK: - PDF

    func test_pdf_g4Page_declaresA1BitGrayCcittImage() throws {
        let image = Self.textPage()
        let g4 = PDFImageData.encodeCCITTG4(image)
        let pdf = try PDFWriter.make([PDFPageInput(image: g4, pixelWidth: image.width, pixelHeight: image.height,
                                                   dpi: 100, ocrLines: nil)])
        var dictionary = "/Type /XObject /Subtype /Image /Width 850 /Height 1100 /ColorSpace /DeviceGray /BitsPerComponent 1 "
        dictionary += "/Filter /CCITTFaxDecode /DecodeParms <</K -1 /Columns 850 /Rows 1100 /BlackIs1 false>> "
        dictionary += "/Length \(g4.data.count)>>\nstream\n"
        XCTAssertTrue(PDFWriterTests.has(pdf, dictionary))
        XCTAssertTrue(PDFWriterTests.has(pdf, "/MediaBox [0 0 612 792]")) // 850 × 1100 px at 100 dpi: Letter
        let start = try XCTUnwrap(PDFWriterTests.offset(pdf, "/CCITTFaxDecode"))
        let data = try XCTUnwrap(PDFWriterTests.offset(pdf, "stream\n", from: start)) + "stream\n".utf8.count
        XCTAssertEqual(pdf.subdata(in: data..<(data + g4.data.count)), g4.data)
        XCTAssertFalse(PDFWriterTests.has(pdf, "/DCTDecode"))
        XCTAssertEqual(PDFWriterTests.text(pdf, at: 0, count: 8), "%PDF-1.4")
        XCTAssertEqual(PDFDocument(data: pdf)?.pageCount, 1)
    }

    func test_pdf_g4Page_rendersItsPixels() throws {
        // At 72 dpi a point is a pixel: CoreGraphics' CCITT decoder draws the page pixel for pixel.
        let image = CCITTG4EncoderTests.image(width: 300, height: 200) { x, y in (x / 7 + y / 5) % 3 == 0 || x == y }
        let pdf = try PDFWriter.make([Self.g4Page(image, dpi: 72)])
        let rendered = try XCTUnwrap(Self.renderedFirstPage(pdf, width: 300, height: 200))
        let drawn = Bilevel.pack(rgba: rendered, width: 300, height: 200)
        let wrong = Self.differences(drawn, Bilevel.pack(image), width: 300, height: 200)
        XCTAssertLessThanOrEqual(wrong, 300 * 200 / 100, "pixels that differ: \(wrong)")
    }

    func test_pdf_mixesJpegAndG4Pages_andATextLayer() throws {
        let image = Self.textPage()
        let line = OCRLine(text: "Siyah beyaz sayfa — Çağrı", boundingBox: CGRect(x: 0.1, y: 0.8, width: 0.6, height: 0.03),
                           confidence: 0.9)
        let jpeg = PDFPageInput(jpegData: PDFWriterTests.tinyJPEGData, pixelWidth: 850, pixelHeight: 1100, dpi: 100,
                                ocrLines: nil)
        let pdf = try PDFWriter.make([jpeg, Self.g4Page(image, lines: [line])])
        let document = try XCTUnwrap(PDFDocument(data: pdf))
        XCTAssertEqual(document.pageCount, 2)
        XCTAssertEqual(PDFWriterTests.count(pdf, "/BitsPerComponent 8"), 1)
        XCTAssertEqual(PDFWriterTests.count(pdf, "/BitsPerComponent 1"), 1)
        let text = document.page(at: 1)?.string ?? ""
        XCTAssertTrue(text.contains("Çağrı"), "PDFKit read: \(text)")
    }

    func test_pdf_jpegDataInitializer_isAJpegPage() {
        let page = PDFPageInput(jpegData: PDFWriterTests.tinyJPEGData, pixelWidth: 100, pixelHeight: 150, dpi: 300,
                                ocrLines: nil)
        XCTAssertEqual(page.image, .jpeg(PDFWriterTests.tinyJPEGData))
        XCTAssertEqual(page.jpegData, PDFWriterTests.tinyJPEGData)
        let g4 = PDFImageData.ccittG4(data: Data([1, 2, 3]), width: 10, height: 4)
        XCTAssertEqual(PDFPageInput(image: g4, pixelWidth: 10, pixelHeight: 4, dpi: 300, ocrLines: nil).jpegData,
                       Data([1, 2, 3]))
    }

    func test_pdf_g4_takesAFractionOfABitPerPixel() {
        // The text page as a 1-bit G4 image: under one bit for every five pixels.
        let image = Self.textPage()
        let bytes = PDFImageData.encodeCCITTG4(image).data.count
        XCTAssertGreaterThanOrEqual(bytes, 1000)
        XCTAssertLessThanOrEqual(bytes, image.width * image.height / 40) // bytes, so 1/5 bit per pixel at most
    }

    // MARK: - The Mac's PDFBuilder (no C# twin)

    func test_pdfBuilder_documentWithABlackAndWhitePage_storesItAsG4() throws {
        let packed = CCITTG4EncoderTests.packed(width: 400, height: 300) { x, y in (x / 9 + y / 4) % 4 == 0 }
        let bilevel = try XCTUnwrap(Bilevel.unpack(packed, width: 400, height: 300).makeCGImage())
        let color = try XCTUnwrap(RgbaImage.filled(width: 400, height: 300, r: 200, g: 40, b: 40).makeCGImage())
        let pages = [ScannedPage(image: bilevel, dpi: 72, colorMode: .blackWhite),
                     ScannedPage(image: color, dpi: 72, colorMode: .color)]
        XCTAssertTrue(PDFBuilder.writesG4(pages))
        let pdf = try PDFBuilder.makePDF(pages: pages, pdfSize: .standard, progress: nil, textLayer: nil)
        XCTAssertTrue(PDFWriterTests.has(pdf, "/Filter /CCITTFaxDecode /DecodeParms <</K -1 /Columns 400 /Rows 300 /BlackIs1 false>>"))
        XCTAssertEqual(PDFWriterTests.count(pdf, "/DCTDecode"), 1)
        XCTAssertTrue(PDFWriterTests.has(pdf, "/MediaBox [0 0 400 300]"))
        XCTAssertEqual(PDFDocument(data: pdf)?.pageCount, 2)
        // The stored G4 image is the page's own bits.
        let start = try XCTUnwrap(PDFWriterTests.offset(pdf, "/CCITTFaxDecode"))
        let data = try XCTUnwrap(PDFWriterTests.offset(pdf, "stream\n", from: start)) + "stream\n".utf8.count
        let g4 = try CCITTG4Encoder.encode(packed, width: 400, height: 300)
        XCTAssertEqual(pdf.subdata(in: data..<(data + g4.count)), Data(g4))
        let rendered = try XCTUnwrap(Self.renderedFirstPage(pdf, width: 400, height: 300))
        let wrong = Self.differences(Bilevel.pack(rgba: rendered, width: 400, height: 300), packed, width: 400, height: 300)
        XCTAssertLessThanOrEqual(wrong, 400 * 300 / 100, "pixels that differ: \(wrong)")
    }

    func test_pdfBuilder_blackAndWhitePage_followsItsSizeLimit() throws {
        // 1200 dpi black & white: G4 keeps 600 dpi at Standard and 300 dpi at Compact (C# plan table).
        let stripes = CCITTG4EncoderTests.image(width: 1200, height: 800) { x, _ in x % 40 < 20 }
        let image = try XCTUnwrap(stripes.makeCGImage())
        let page = ScannedPage(image: image, dpi: 1200, colorMode: .blackWhite)
        let standard = try PDFBuilder.makePDF(pages: [page], pdfSize: .standard, progress: nil, textLayer: nil)
        XCTAssertTrue(PDFWriterTests.has(standard, "/Width 600 /Height 400 /ColorSpace /DeviceGray /BitsPerComponent 1"))
        let compact = try PDFBuilder.makePDF(pages: [page], pdfSize: .compact, progress: nil, textLayer: nil)
        XCTAssertTrue(PDFWriterTests.has(compact, "/Width 300 /Height 200 /ColorSpace /DeviceGray /BitsPerComponent 1"))
        // The page keeps its physical size: 1 × 0.667 in.
        XCTAssertTrue(PDFWriterTests.has(compact, "/MediaBox [0 0 72 48]"))
    }

    func test_pdfBuilder_textLayerAndFile_onTheG4Path() throws {
        let image = try XCTUnwrap(Self.textPage().makeCGImage())
        let page = ScannedPage(image: image, dpi: 100, colorMode: .blackWhite)
        let line = OCRLine(text: "Siyah beyaz — Çağrı", boundingBox: CGRect(x: 0.1, y: 0.8, width: 0.6, height: 0.03),
                           confidence: 0.9)
        var asked: [Int] = []
        let layer: PDFTextLayer = { index, prepared in
            asked.append(index)
            XCTAssertEqual(prepared.pixelWidth, 850)
            return [line]
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("BilevelOutputTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("out.pdf")
        try PDFBuilder.writePDF(pages: [page], pdfSize: .best, to: url, progress: nil, textLayer: layer)
        XCTAssertEqual(asked, [0])
        let pdf = try Data(contentsOf: url)
        XCTAssertTrue(PDFWriterTests.has(pdf, "/BaseFont /GlyphLessFont"))
        XCTAssertTrue(PDFWriterTests.has(pdf, "/CCITTFaxDecode"))
        let document = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(document.pageCount, 1)
        let text = document.page(at: 0)?.string ?? ""
        XCTAssertTrue(text.contains("Çağrı"), "PDFKit read: \(text)")
    }

    func test_pdfBuilder_documentWithoutBlackAndWhitePages_isWrittenByPDFWriterToo() throws {
        let gray = try XCTUnwrap(RgbaImage.filled(width: 200, height: 100, r: 128, g: 128, b: 128).makeCGImage())
        let pages = [ScannedPage(image: gray, dpi: 100, colorMode: .grayscale)]
        XCTAssertFalse(PDFBuilder.writesG4(pages))
        let pdf = try PDFBuilder.makePDF(pages: pages, pdfSize: .standard, progress: nil, textLayer: nil)
        XCTAssertEqual(PDFWriterTests.text(pdf, at: 0, count: 9), "%PDF-1.4\n")
        XCTAssertFalse(PDFWriterTests.has(pdf, "/CCITTFaxDecode"))
        XCTAssertFalse(PDFWriterTests.has(pdf, "/GlyphLessFont"))
        // The gray page is a one-component JPEG on a page of its size, as Windows stores it.
        XCTAssertTrue(PDFWriterTests.has(pdf, "/ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /DCTDecode"))
        XCTAssertTrue(PDFWriterTests.has(pdf, "/MediaBox [0 0 144 72]"))
        XCTAssertTrue(PDFWriterTests.has(pdf, "1 0 obj\n<</Type /Catalog /Pages 2 0 R>>"))
        XCTAssertEqual(PDFDocument(data: pdf)?.pageCount, 1)
    }

    func test_pdfBuilder_writesPDFAAndProtectedFiles_asTheOptionsAsk() throws {
        let gray = try XCTUnwrap(RgbaImage.filled(width: 200, height: 100, r: 128, g: 128, b: 128).makeCGImage())
        let pages = [ScannedPage(image: gray, dpi: 100, colorMode: .grayscale)]
        let line = OCRLine(text: "Arşiv", boundingBox: CGRect(x: 0.1, y: 0.4, width: 0.5, height: 0.2), confidence: 0.9)
        let layer: PDFTextLayer = { _, _ in [line] }
        let archival = try PDFBuilder.makePDF(pages: pages, pdfSize: .best, progress: nil, textLayer: layer,
                                              options: PDFWriteOptions(conformance: .pdfA2b, title: "Arşiv"))
        XCTAssertEqual(PDFWriterTests.text(archival, at: 0, count: 9), "%PDF-1.7\n")
        XCTAssertTrue(PDFWriterTests.has(archival, "/S /GTS_PDFA1"))
        XCTAssertTrue(PDFWriterTests.has(archival, "<pdfaid:part>2</pdfaid:part>"))
        let protection = try PDFProtection("Şifre 2026")
        let locked = try PDFBuilder.makePDF(pages: pages, pdfSize: .best, progress: nil, textLayer: layer,
                                            options: PDFWriteOptions(protection: protection))
        XCTAssertTrue(PDFWriterTests.has(locked, "/Filter /Standard /V 5 /R 6"))
        let document = try XCTUnwrap(PDFDocument(data: locked))
        XCTAssertTrue(document.isLocked)
        XCTAssertTrue(document.unlock(withPassword: "Şifre 2026"))
        XCTAssertTrue((document.page(at: 0)?.string ?? "").contains("Arşiv"))
    }

    func test_pdfBuilder_g4Path_isCancelledBeforeEachPage() throws {
        let image = try XCTUnwrap(Self.textPage().makeCGImage())
        let pages = [ScannedPage(image: image, dpi: 100, colorMode: .blackWhite)]
        XCTAssertThrowsError(try PDFBuilder.makePDF(pages: pages, progress: nil, shouldContinue: { false },
                                                    textLayer: nil)) { error in
            guard case ScanError.cancelled = error else { return XCTFail("\(error)") }
        }
    }

    // MARK: - TIFF

    private struct DirectoryEntry {
        let type: Int
        let count: Int
        let value: Int
    }

    private static func u16(_ b: [UInt8], _ at: Int) -> Int {
        Int(b[at]) | (Int(b[at + 1]) << 8)
    }

    private static func u32(_ b: [UInt8], _ at: Int) -> Int {
        let low = Int(b[at]) | (Int(b[at + 1]) << 8)
        let high = (Int(b[at + 2]) << 16) | (Int(b[at + 3]) << 24)
        return low | high
    }

    /// The directory at `offset`: its entries by tag, in ascending tag order, and the next offset.
    private static func directory(_ tiff: [UInt8], _ offset: Int, file: StaticString = #filePath,
                                  line: UInt = #line) -> (entries: [Int: DirectoryEntry], next: Int) {
        let count = u16(tiff, offset)
        var entries: [Int: DirectoryEntry] = [:]
        var previous = -1
        for e in 0..<count {
            let at = offset + 2 + e * 12
            let tag = u16(tiff, at)
            XCTAssertTrue(tag > previous, "entries in ascending tag order", file: file, line: line)
            previous = tag
            let type = u16(tiff, at + 2)
            let n = u32(tiff, at + 4)
            let value = type == 3 && n == 1 ? u16(tiff, at + 8) : u32(tiff, at + 8)
            entries[tag] = DirectoryEntry(type: type, count: n, value: value)
        }
        XCTAssertEqual(offset % 2, 0, file: file, line: line)
        return (entries, u32(tiff, offset + 2 + count * 12))
    }

    private static func value(_ entries: [Int: DirectoryEntry], _ tag: Int) -> Int? {
        entries[tag]?.value
    }

    func test_tiff_onePage_isAG4StripWithItsResolution() throws {
        let image = TestPages.textPage().toRgba()
        let tiff = [UInt8](BilevelTIFF.make(image, dpi: 300))
        XCTAssertEqual(Array(tiff[0..<4]), [0x49, 0x49, 0x2A, 0x00])
        let read = Self.directory(tiff, Self.u32(tiff, 4))
        let entries = read.entries
        XCTAssertEqual(read.next, 0)
        XCTAssertEqual(entries.keys.sorted(), [256, 257, 258, 259, 262, 273, 277, 278, 279, 282, 283, 293, 296])
        XCTAssertEqual(Self.value(entries, 256), 850)
        XCTAssertEqual(Self.value(entries, 257), 1100)
        XCTAssertEqual(Self.value(entries, 258), 1)
        XCTAssertEqual(Self.value(entries, 259), 4)    // CCITT T.6
        XCTAssertEqual(Self.value(entries, 262), 0)    // WhiteIsZero
        XCTAssertEqual(Self.value(entries, 277), 1)
        XCTAssertEqual(Self.value(entries, 278), 1100) // one strip
        XCTAssertEqual(Self.value(entries, 293), 0)
        XCTAssertEqual(Self.value(entries, 296), 2)    // inch
        let xResolution = try XCTUnwrap(Self.value(entries, 282))
        XCTAssertEqual(Self.u32(tiff, xResolution), 300)
        XCTAssertEqual(Self.u32(tiff, xResolution + 4), 1)
        let yResolution = try XCTUnwrap(Self.value(entries, 283))
        XCTAssertEqual(Self.u32(tiff, yResolution), 300)
        XCTAssertEqual(Self.u32(tiff, yResolution + 4), 1)
        let g4 = CCITTG4Encoder.encode(image)
        XCTAssertEqual(Self.value(entries, 279), g4.count)
        XCTAssertEqual(Self.value(entries, 273), 8)
        XCTAssertEqual(Array(tiff[8..<(8 + g4.count)]), g4)
        XCTAssertEqual(tiff.count, 17852) // 8 + 17666 + 162 + 16
        XCTAssertEqual(CompanionPackage.sha256Hex(Data(tiff)).uppercased(),
                       "EF4F98A030BB642AB198F3FAE98EEE6CD088E24B986A769FCD0EEE92255CA38D")
    }

    func test_tiff_severalPages_areChainedAsPagesOfOneDocument() {
        let text = TestPages.textPage().toRgba()
        let small = CCITTG4EncoderTests.image(width: 13, height: 7) { x, y in (x + y) % 3 == 0 }
        let black = RgbaImage.filled(width: 9, height: 2, r: 0, g: 0, b: 0)
        let pages = [BilevelTIFFPage(image: text, dpi: 100), BilevelTIFFPage(image: small, dpi: 300),
                     BilevelTIFFPage(image: black, dpi: 600)]
        let tiff = [UInt8](BilevelTIFF.make(pages))
        var offset = Self.u32(tiff, 4)
        for i in 0..<pages.count {
            XCTAssertNotEqual(offset, 0)
            let read = Self.directory(tiff, offset)
            let entries = read.entries
            let page = pages[i]
            XCTAssertEqual(Self.value(entries, 254), 2)                  // a page of a document
            XCTAssertEqual(Self.value(entries, 297), i | (3 << 16))     // page i of 3
            XCTAssertEqual(entries[297]?.type, 3)
            XCTAssertEqual(entries[297]?.count, 2)
            XCTAssertEqual(Self.value(entries, 256), page.image.width)
            XCTAssertEqual(Self.value(entries, 257), page.image.height)
            if let resolution = Self.value(entries, 282) {
                XCTAssertEqual(Self.u32(tiff, resolution), page.dpi)
            } else {
                XCTFail("no XResolution on page \(i)")
            }
            let g4 = CCITTG4Encoder.encode(page.image)
            XCTAssertEqual(Self.value(entries, 279), g4.count)
            let strip = Self.value(entries, 273) ?? 0
            XCTAssertEqual(Array(tiff[strip..<(strip + g4.count)]), g4)
            offset = read.next
        }
        XCTAssertEqual(offset, 0)
    }

    func test_tiff_decodesWithImageIO_pageByPage() throws {
        let text = Self.textPage()
        let small = CCITTG4EncoderTests.image(width: 13, height: 7) { x, y in (x + y) % 3 == 0 }
        let pages = [BilevelTIFFPage(image: text, dpi: 100), BilevelTIFFPage(image: small, dpi: 300)]
        let tiff = BilevelTIFF.make(pages)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(tiff as CFData, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 2)
        for i in 0..<pages.count {
            guard let decoded = CGImageSourceCreateImageAtIndex(source, i, nil) else {
                try CCITTG4EncoderTests.imageIODecodedNothing("page \(i) of a two-page G4 TIFF")
                return
            }
            let image = pages[i].image
            XCTAssertEqual(decoded.width, image.width)
            XCTAssertEqual(decoded.height, image.height)
            let rgba = try XCTUnwrap(ColorAnalysis.rgbaPixels(of: decoded))
            XCTAssertEqual(Bilevel.pack(rgba: rgba, width: image.width, height: image.height), Bilevel.pack(image), "page \(i)")
            let properties = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any]
            let tiffProperties = properties?[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
            XCTAssertEqual((tiffProperties?[kCGImagePropertyTIFFCompression] as? NSNumber)?.intValue, 4)
            XCTAssertEqual((properties?[kCGImagePropertyDPIWidth] as? NSNumber)?.intValue, pages[i].dpi)
        }
    }

    func test_tiff_appliesToBlackAndWhiteTiffsOnly() {
        XCTAssertTrue(BilevelTIFF.applies(.tiff, .blackWhite))
        XCTAssertFalse(BilevelTIFF.applies(.tiff, .grayscale))
        XCTAssertFalse(BilevelTIFF.applies(.tiff, .color))
        XCTAssertFalse(BilevelTIFF.applies(.png, .blackWhite))
        XCTAssertFalse(BilevelTIFF.applies(.pdf, .blackWhite))
    }

    // MARK: - ImageExporter (no C# twin: WpfImageCodec is in the Windows app)

    func test_imageExporter_blackAndWhiteTiff_isG4_othersStayLZW() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("BilevelOutputTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let pixels = CCITTG4EncoderTests.image(width: 120, height: 80) { x, y in (x + 2 * y) % 11 < 4 }
        let image = try XCTUnwrap(pixels.makeCGImage())

        let bilevelURL = folder.appendingPathComponent("bw.tiff")
        try ImageExporter.write(image, to: bilevelURL, format: .tiff, dpi: 200, jpegQuality: 0.9, colorMode: .blackWhite)
        XCTAssertEqual(try Data(contentsOf: bilevelURL), BilevelTIFF.make(pixels, dpi: 200))

        let colorURL = folder.appendingPathComponent("color.tiff")
        try ImageExporter.write(image, to: colorURL, format: .tiff, dpi: 200, jpegQuality: 0.9, colorMode: .color)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(colorURL as CFURL, nil))
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let tiffProperties = properties?[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        XCTAssertEqual((tiffProperties?[kCGImagePropertyTIFFCompression] as? NSNumber)?.intValue, 5) // LZW

        // A black & white page saved as PNG is not touched.
        let pngURL = folder.appendingPathComponent("bw.png")
        try ImageExporter.write(image, to: pngURL, format: .png, dpi: 200, jpegQuality: 0.9, colorMode: .blackWhite)
        let png = try Data(contentsOf: pngURL)
        XCTAssertEqual(Array(png.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
    }
}
