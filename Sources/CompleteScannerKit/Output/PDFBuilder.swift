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
