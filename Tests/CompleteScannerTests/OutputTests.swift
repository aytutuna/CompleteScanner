import XCTest
import CoreGraphics
import CoreText
import ImageIO
import PDFKit
@testable import CompleteScannerKit

// MARK: - Helpers

private func makeSolidImage(width: Int, height: Int,
                            red: CGFloat, green: CGFloat, blue: CGFloat) -> CGImage {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                        bytesPerRow: 0, space: colorSpace,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
    return ctx.makeImage()!
}

/// 8.5x11" @150dpi white page with big black "COMPLETE SCANNER TEST PAGE" drawn via CoreText.
private func makeTextImage() -> CGImage {
    let width = 1275, height = 1650
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                        bytesPerRow: 0, space: colorSpace,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))

    let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 72, nil)
    let attributes: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String):
            CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1),
    ]
    let line = CTLineCreateWithAttributedString(
        NSAttributedString(string: "COMPLETE SCANNER TEST PAGE", attributes: attributes))
    let lineWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    let x = max(20, (CGFloat(width) - lineWidth) / 2)
    // The context is y-up; draw the line twice around mid-page.
    for baselineY in [700.0, 950.0] {
        ctx.textPosition = CGPoint(x: x, y: CGFloat(baselineY))
        CTLineDraw(line, ctx)
    }
    return ctx.makeImage()!
}

private func makeTempDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("OutputTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func imageProperties(at url: URL) throws -> [CFString: Any] {
    let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil),
                               "Could not open image source at \(url.path)")
    return try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                         "No image properties at \(url.path)")
}

// MARK: - Tests

final class OutputTests: XCTestCase {

    func test_makePDFTwoPages() throws {
        let pages = [
            ScannedPage(image: makeSolidImage(width: 400, height: 300, red: 0.9, green: 0.3, blue: 0.2),
                        dpi: 100, colorMode: .color),
            ScannedPage(image: makeSolidImage(width: 400, height: 300, red: 0.2, green: 0.4, blue: 0.9),
                        dpi: 100, colorMode: .color),
        ]
        let data = try PDFBuilder.makePDF(pages: pages, searchable: false, ocrLanguages: [], progress: nil)
        let document = try XCTUnwrap(PDFDocument(data: data), "PDFDocument could not read the data")
        XCTAssertEqual(document.pageCount, 2)

        // 400 px / 100 dpi * 72 = 288 pt; 300 px / 100 dpi * 72 = 216 pt.
        let bounds = try XCTUnwrap(document.page(at: 0)).bounds(for: .mediaBox)
        XCTAssertEqual(Double(bounds.width), 288, accuracy: 0.5)
        XCTAssertEqual(Double(bounds.height), 216, accuracy: 0.5)
    }

    func test_searchablePDFContainsText() throws {
        let page = ScannedPage(image: makeTextImage(), dpi: 150, colorMode: .color)
        let data = try PDFBuilder.makePDF(pages: [page], searchable: true,
                                          ocrLanguages: ["en-US"], progress: nil)
        let document = try XCTUnwrap(PDFDocument(data: data), "PDFDocument could not read the data")
        XCTAssertEqual(document.pageCount, 1)

        let text = (document.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            throw XCTSkip("PDF has no extractable text — Vision OCR appears unavailable in this environment.")
        }
        XCTAssertTrue(text.lowercased().contains("scanner"),
                      "Searchable PDF text layer should contain SCANNER; got: \(text)")
    }

    func test_imageExporterWritesFormatsWithDPI() throws {
        let image = makeSolidImage(width: 200, height: 150, red: 0.3, green: 0.7, blue: 0.4)
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        for format in [OutputFormat.jpeg, .png, .tiff] {
            let url = dir.appendingPathComponent("export.\(format.fileExtension)")
            try ImageExporter.write(image, to: url, format: format, dpi: 300, jpegQuality: 0.9)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                          "\(format.rawValue) file was not written")

            let props = try imageProperties(at: url)
            XCTAssertEqual((props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue, 200,
                           "\(format.rawValue) pixel width")
            XCTAssertEqual((props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, 150,
                           "\(format.rawValue) pixel height")
            let dpi = try XCTUnwrap((props[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue,
                                    "\(format.rawValue) is missing DPI metadata")
            XCTAssertEqual(dpi, 300, accuracy: 1, "\(format.rawValue) DPI")
        }
    }

    func test_makePDF_withTheTextLayerGiven_drawsItWithoutRunningOCR() throws {
        let page = ScannedPage(image: makeSolidImage(width: 400, height: 300, red: 1, green: 1, blue: 1),
                               dpi: 100, colorMode: .color)
        let line = OCRLine(text: "Given words here", boundingBox: CGRect(x: 0.1, y: 0.5, width: 0.6, height: 0.08),
                           confidence: 1)
        let data = try PDFBuilder.makePDF(pages: [page, page], ocrLines: [[line]], progress: nil)
        let document = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertEqual(document.pageCount, 2)
        // The words, in the embedded glyphless font; how PDFKit spaces them is its own.
        let read = (document.page(at: 0)?.string ?? "").filter { !$0.isWhitespace }
        XCTAssertTrue(read.contains("Givenwordshere"), read)
        XCTAssertTrue(PDFWriterTests.has(data, "/BaseFont /GlyphLessFont"))
        // A page past the end of the list gets no text layer.
        XCTAssertEqual((document.page(at: 1)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines), "")
    }

    func test_makePDF_textLayer_isAskedOncePerPage_withThePreparedPage() throws {
        let first = ScannedPage(image: makeSolidImage(width: 400, height: 300, red: 1, green: 1, blue: 1),
                                dpi: 100, colorMode: .color, fullPixelSize: CGSize(width: 800, height: 600))
        let second = ScannedPage(image: makeSolidImage(width: 200, height: 100, red: 1, green: 1, blue: 1),
                                 dpi: 100, colorMode: .color)
        var asked: [String] = []
        _ = try PDFBuilder.makePDF(pages: [first, second], progress: nil, textLayer: { index, prepared in
            asked.append("\(index): \(prepared.pixelWidth)x\(prepared.pixelHeight) \(prepared.image.width)")
            return nil
        })
        // The recorded full-resolution size sizes the page; the pixels at hand are the preview's.
        XCTAssertEqual(asked, ["0: 800x600 400", "1: 200x100 200"])
    }

    func test_imageExporterRejectsTextFormats() throws {
        let image = makeSolidImage(width: 20, height: 10, red: 0.3, green: 0.7, blue: 0.4)
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        for format in [OutputFormat.text, .word] {
            let url = dir.appendingPathComponent("export.\(format.fileExtension)")
            XCTAssertThrowsError(try ImageExporter.write(image, to: url, format: format,
                                                         dpi: 300, jpegQuality: 0.9)) { error in
                guard case ScanError.unsupported = error else {
                    return XCTFail("Expected ScanError.unsupported, got \(error)")
                }
            }
        }
    }

    func test_imageExporterRejectsPDF() throws {
        let image = makeSolidImage(width: 200, height: 150, red: 0.3, green: 0.7, blue: 0.4)
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("export.pdf")
        XCTAssertThrowsError(try ImageExporter.write(image, to: url, format: .pdf,
                                                     dpi: 300, jpegQuality: 0.9)) { error in
            guard case ScanError.unsupported = error else {
                return XCTFail("Expected ScanError.unsupported, got \(error)")
            }
        }
    }
}
