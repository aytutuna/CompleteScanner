import CoreGraphics
import CoreText
import Foundation
import ImageIO

/// The text layer of one page of a PDF being built: called with the page's index and its full
/// pixels (the user's rotation applied, with the page's full-resolution size) before the page is
/// drawn; the lines it returns are drawn as invisible text over the words, nil draws none. The app
/// reads each page with OCR here once, and keeps the lines for the text file beside the PDF
/// (`OutputOptions.alsoSaveText`).
public typealias PDFTextLayer = (_ index: Int, _ page: PDFBuilder.PreparedPage) -> [OCRLine]?

public enum PDFBuilder {
    /// The pixels and media-box size of one queued page, with the user's page rotation applied
    /// (twin of C# `PdfBuilder.PreparedPage`). `pixelWidth` × `pixelHeight` is the full-resolution
    /// size, which sizes the page even when only the preview's pixels are at hand.
    public struct PreparedPage {
        public let image: CGImage
        public let pixelWidth: Int
        public let pixelHeight: Int
    }

    /// Multi-page PDF; each page sized pixels/dpi*72 points. When `searchable`, run OCR per page
    /// and draw an invisible text layer aligned with the words. Each page image is stored as
    /// `pdfSize` plans it (`PDFImageEncoding`): a JPEG at the size's quality, downsampled and
    /// gray where the size says so; OCR reads the full pixels first. `shouldContinue` is polled
    /// before each page; returning false aborts with ScanError.cancelled.
    ///
    /// A document with a black & white page (`writesG4(_:)`) is written by `PDFWriter`, the port of
    /// the Windows writer: its black & white pages are 1-bit CCITT G4 images, its other pages the
    /// planned JPEGs, and its text layer the embedded `GlyphlessFont`. Every other document is
    /// drawn by CoreGraphics' PDF context, with a CoreText text layer.
    public static func makePDF(pages: [ScannedPage], searchable: Bool, ocrLanguages: [String],
                               pdfSize: PDFSizePreset = .best, progress: ((String) -> Void)?,
                               shouldContinue: (() -> Bool)? = nil) throws -> Data {
        try makePDF(pages: pages, pdfSize: pdfSize, progress: progress, shouldContinue: shouldContinue,
                    textLayer: ocrTextLayer(searchable: searchable, languages: ocrLanguages))
    }

    /// The same, with the text layer read beforehand: `ocrLines[i]` is drawn on page `i` (nil, or
    /// a page past the end of the list, gets none). OCR does not run.
    public static func makePDF(pages: [ScannedPage], ocrLines: [[OCRLine]?], pdfSize: PDFSizePreset = .best,
                               progress: ((String) -> Void)?, shouldContinue: (() -> Bool)? = nil) throws -> Data {
        try makePDF(pages: pages, pdfSize: pdfSize, progress: progress, shouldContinue: shouldContinue,
                    textLayer: { index, _ in index < ocrLines.count ? ocrLines[index] : nil })
    }

    /// The same, with each page's text layer from `textLayer` (no text layer when nil).
    public static func makePDF(pages: [ScannedPage], pdfSize: PDFSizePreset = .best, progress: ((String) -> Void)?,
                               shouldContinue: (() -> Bool)? = nil, textLayer: PDFTextLayer?) throws -> Data {
        if writesG4(pages) {
            let inputs = try pageInputs(pages, pdfSize: pdfSize, progress: progress, shouldContinue: shouldContinue,
                                        textLayer: textLayer)
            return try PDFWriter.make(inputs, progress: progress, shouldContinue: shouldContinue)
        }
        let output = NSMutableData()
        guard let consumer = CGDataConsumer(data: output as CFMutableData) else {
            throw ScanError.exportFailed("Could not create a PDF data consumer.")
        }
        try write(pages: pages, pdfSize: pdfSize, progress: progress, shouldContinue: shouldContinue,
                  textLayer: textLayer, consumer: consumer)
        return output as Data
    }

    /// Stream the PDF straight to `url` — never holds the whole document in memory.
    public static func writePDF(pages: [ScannedPage], searchable: Bool, ocrLanguages: [String],
                                pdfSize: PDFSizePreset = .best, to url: URL, progress: ((String) -> Void)?,
                                shouldContinue: (() -> Bool)? = nil) throws {
        try writePDF(pages: pages, pdfSize: pdfSize, to: url, progress: progress, shouldContinue: shouldContinue,
                     textLayer: ocrTextLayer(searchable: searchable, languages: ocrLanguages))
    }

    /// The same, with the text layer read beforehand (see `makePDF(pages:ocrLines:...)`).
    public static func writePDF(pages: [ScannedPage], ocrLines: [[OCRLine]?], pdfSize: PDFSizePreset = .best,
                                to url: URL, progress: ((String) -> Void)?,
                                shouldContinue: (() -> Bool)? = nil) throws {
        try writePDF(pages: pages, pdfSize: pdfSize, to: url, progress: progress, shouldContinue: shouldContinue,
                     textLayer: { index, _ in index < ocrLines.count ? ocrLines[index] : nil })
    }

    /// The same, with each page's text layer from `textLayer` (no text layer when nil): the app's
    /// one OCR pass per save runs there.
    public static func writePDF(pages: [ScannedPage], pdfSize: PDFSizePreset = .best, to url: URL,
                                progress: ((String) -> Void)?, shouldContinue: (() -> Bool)? = nil,
                                textLayer: PDFTextLayer?) throws {
        if writesG4(pages) {
            let inputs = try pageInputs(pages, pdfSize: pdfSize, progress: progress, shouldContinue: shouldContinue,
                                        textLayer: textLayer)
            try PDFWriter.writeFile(inputs, to: url, progress: progress, shouldContinue: shouldContinue)
            return
        }
        guard let consumer = CGDataConsumer(url: url as CFURL) else {
            throw ScanError.exportFailed("Could not write to \(url.path).")
        }
        try write(pages: pages, pdfSize: pdfSize, progress: progress, shouldContinue: shouldContinue,
                  textLayer: textLayer, consumer: consumer)
    }

    /// The image and media-box size of one queued page: the full-resolution pixels from its spill
    /// file with the page's rotation applied, else the in-memory image (which already shows it).
    /// Twin of C# `PdfBuilder.PreparePage`.
    public static func preparePage(_ page: ScannedPage) -> PreparedPage {
        // Spilled pages hold only a preview in memory — reload the full-resolution pixels one
        // page at a time. The media box comes from the recorded full-resolution size, so the
        // physical page size stays correct even when only the preview pixels are available.
        let turns = ((page.rotationQuarterTurns % 4) + 4) % 4
        let swapsAxes = turns % 2 == 1
        if let full = spoolImage(for: page) {
            // The spool file is unrotated; apply the user's page rotation now, and swap the
            // recorded dimensions for odd quarter turns.
            let image = turns == 0 ? full : ImagePipeline.rotate(full, quarterTurns: turns)
            let rawWidth = page.fullPixelSize.map { Int($0.width) } ?? full.width
            let rawHeight = page.fullPixelSize.map { Int($0.height) } ?? full.height
            return PreparedPage(image: image, pixelWidth: swapsAxes ? rawHeight : rawWidth,
                                pixelHeight: swapsAxes ? rawWidth : rawHeight)
        }
        // Missing/unreadable spill file (or the page was never spooled): fall back to the
        // in-memory image, which ALREADY carries the rotation.
        if let full = page.fullPixelSize {
            // Recorded pre-rotation full-resolution size: swap for odd turns.
            return PreparedPage(image: page.image,
                                pixelWidth: swapsAxes ? Int(full.height) : Int(full.width),
                                pixelHeight: swapsAxes ? Int(full.width) : Int(full.height))
        }
        return PreparedPage(image: page.image, pixelWidth: page.image.width, pixelHeight: page.image.height)
    }

    // MARK: - Documents with black & white pages (PDFWriter, CCITT G4)

    /// Whether the document has a black & white page: such a document is written by `PDFWriter`,
    /// which stores those pages as CCITT G4 (the plan's `.bilevelG4`); CoreGraphics' PDF context
    /// cannot embed G4 data. The mode a page was scanned in decides, never the color mode set now.
    static func writesG4(_ pages: [ScannedPage]) -> Bool {
        for page in pages where page.colorMode == .blackWhite {
            return true
        }
        return false
    }

    /// The pages as `PDFWriter` stores them (twin of the Windows view model's `PdfPageInputs`): each
    /// one prepared at full resolution with its rotation, read by `textLayer` (its lines become the
    /// page's text layer), and stored as `pdfSize` plans it (`storedImage`). `shouldContinue` is
    /// polled before each page.
    static func pageInputs(_ pages: [ScannedPage], pdfSize: PDFSizePreset, progress: ((String) -> Void)?,
                           shouldContinue: (() -> Bool)?, textLayer: PDFTextLayer?) throws -> [PDFPageInput] {
        var inputs: [PDFPageInput] = []
        for index in 0..<pages.count {
            if shouldContinue?() == false { throw ScanError.cancelled }
            let page = pages[index]
            let prepared = preparePage(page)
            var lines: [OCRLine]? = nil
            if let textLayer {
                progress?("OCR page \(index + 1) of \(pages.count)…")
                // A page without lines (OCR failed or found nothing) is still written, without a text layer.
                lines = textLayer(index, prepared)
            }
            guard let stored = storedImage(prepared, colorMode: page.colorMode, dpi: page.dpi, pdfSize: pdfSize) else {
                throw ScanError.exportFailed("Page \(index + 1) could not be stored in the PDF.")
            }
            inputs.append(PDFPageInput(image: stored, pixelWidth: prepared.pixelWidth,
                                       pixelHeight: prepared.pixelHeight, dpi: page.dpi, ocrLines: lines))
        }
        return inputs
    }

    /// One page's image as the PDF size plans it (`PDFImageEncoding`): a black & white page
    /// downsampled with the box filter to its planned resolution, thresholded (`Bilevel.pack`) and
    /// encoded as CCITT G4; any other page as the planned JPEG (`PDFImageEncoding.encodedPage`), or,
    /// when that fails, as a JPEG of its pixels at the size's color quality. Nil when the pixels
    /// cannot be read or encoded.
    static func storedImage(_ prepared: PreparedPage, colorMode: ColorMode, dpi: Int,
                            pdfSize: PDFSizePreset) -> PDFImageData? {
        let image = prepared.image
        let imageDPI = PDFImageEncoding.effectiveDPI(imageWidth: image.width, pagePixelWidth: prepared.pixelWidth,
                                                     pageDPI: dpi)
        if colorMode == .blackWhite {
            let plan = PDFImageEncoding.plan(mode: .blackWhite, imageDPI: imageDPI, size: pdfSize, looksGray: false)
            guard var rgba = ColorAnalysis.rgbaPixels(of: image) else { return nil }
            var width = image.width
            var height = image.height
            let target = PDFImageEncoding.targetSize(width: width, height: height, imageDPI: imageDPI,
                                                     targetDPI: plan.targetDPI)
            if target.width != width || target.height != height {
                rgba = PDFImageEncoding.downsample(rgba: rgba, width: width, height: height,
                                                   newWidth: target.width, newHeight: target.height)
                width = target.width
                height = target.height
            }
            let packed = Bilevel.pack(rgba: rgba, width: width, height: height)
            guard let g4 = try? CCITTG4Encoder.encode(packed, width: width, height: height) else { return nil }
            return .ccittG4(data: Data(g4), width: width, height: height)
        }
        if let stored = PDFImageEncoding.encodedPage(image, imageDPI: imageDPI, mode: colorMode, size: pdfSize) {
            return .jpeg(stored.jpegData)
        }
        let quality = PDFImageEncoding.profile(pdfSize).colorQuality
        guard let jpeg = PDFImageEncoding.encodeJPEG(image, quality: quality) else { return nil }
        return .jpeg(jpeg)
    }

    // MARK: - CoreGraphics

    /// The text layer of the older overloads: OCR on every page when `searchable` (a page whose OCR
    /// fails gets none), else none.
    private static func ocrTextLayer(searchable: Bool, languages: [String]) -> PDFTextLayer? {
        guard searchable else { return nil }
        return { _, page in try? OCRService.recognizeLines(in: page.image, languages: languages) }
    }

    private static func write(pages: [ScannedPage], pdfSize: PDFSizePreset, progress: ((String) -> Void)?,
                              shouldContinue: (() -> Bool)?, textLayer: PDFTextLayer?,
                              consumer: CGDataConsumer) throws {
        var defaultBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(consumer: consumer, mediaBox: &defaultBox, nil) else {
            throw ScanError.exportFailed("Could not create a PDF context.")
        }

        for (index, page) in pages.enumerated() {
            if shouldContinue?() == false { throw ScanError.cancelled }
            let prepared = preparePage(page)
            let image = prepared.image
            let pixelWidth = prepared.pixelWidth
            let pixelHeight = prepared.pixelHeight
            var box = mediaBox(width: pixelWidth, height: pixelHeight, dpi: page.dpi)
            let boxData = Data(bytes: &box, count: MemoryLayout<CGRect>.size)
            let pageInfo = [kCGPDFContextMediaBox as String: boxData] as CFDictionary
            context.beginPDFPage(pageInfo)
            // The stored image follows the PDF size; the page keeps its physical size. When the
            // page cannot be encoded, its pixels are drawn as they are (CoreGraphics compresses them).
            let imageDPI = PDFImageEncoding.effectiveDPI(imageWidth: image.width, pagePixelWidth: pixelWidth,
                                                         pageDPI: page.dpi)
            let stored = PDFImageEncoding.encodedPage(image, imageDPI: imageDPI, mode: page.colorMode, size: pdfSize)
            context.draw(stored?.image ?? image, in: box)

            if let textLayer {
                progress?("OCR page \(index + 1) of \(pages.count)…")
                // A page without lines (OCR failed or found nothing) is still drawn, without a text layer.
                if let lines = textLayer(index, prepared) {
                    drawInvisibleTextLayer(lines, in: context, pageSize: box.size)
                }
            }

            context.endPDFPage()
        }
        context.closePDF()
    }

    /// The full-resolution UNROTATED pixels from the page's spill file, or nil when the
    /// page was never spooled (or the file is unreadable) — the caller then falls back to
    /// the in-memory image, which already carries any user rotation.
    private static func spoolImage(for page: ScannedPage) -> CGImage? {
        guard let url = page.fileURL,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        return image
    }

    /// PDF media box in points: pixels / dpi × 72.
    private static func mediaBox(width: Int, height: Int, dpi: Int) -> CGRect {
        let dpi = Double(max(dpi, 1))
        return CGRect(x: 0, y: 0,
                      width: Double(width) / dpi * 72.0,
                      height: Double(height) / dpi * 72.0)
    }

    /// Draw each OCR line as invisible text positioned over the word image.
    /// Vision boxes are normalized with a bottom-left origin — the same origin as
    /// PDF user space — so they map straight into points with no flip.
    private static func drawInvisibleTextLayer(_ lines: [OCRLine], in context: CGContext, pageSize: CGSize) {
        let pageWidth = pageSize.width
        let pageHeight = pageSize.height

        for line in lines {
            guard !line.text.isEmpty else { continue }
            let box = line.boundingBox
            let x = box.minX * pageWidth
            let y = box.minY * pageHeight
            let targetWidth = box.width * pageWidth
            let boxHeightPts = box.height * pageHeight

            let fontSize = boxHeightPts * 0.85
            guard fontSize > 0, targetWidth > 0 else { continue }

            let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
            let attributed = NSAttributedString(
                string: line.text,
                attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]
            )
            let ctLine = CTLineCreateWithAttributedString(attributed)

            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            let measuredWidth = CGFloat(CTLineGetTypographicBounds(ctLine, &ascent, &descent, &leading))
            guard measuredWidth > 0 else { continue }

            let scaleX = min(max(targetWidth / measuredWidth, 0.2), 5.0)

            context.saveGState()
            context.setTextDrawingMode(.invisible)
            context.textMatrix = CGAffineTransform(scaleX: scaleX, y: 1)
            // Baseline sits a little above the box bottom so descenders line up.
            context.textPosition = CGPoint(x: x, y: y + descent)
            CTLineDraw(ctLine, context)
            context.restoreGState()
        }
    }
}
