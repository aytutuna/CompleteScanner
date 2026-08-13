import CoreGraphics
import CoreText
import Foundation
import ImageIO

public enum PDFBuilder {
    /// Multi-page PDF; each page sized pixels/dpi*72 points. When `searchable`, run OCR per page
    /// and draw an invisible text layer aligned with the words.
    public static func makePDF(pages: [ScannedPage], searchable: Bool, ocrLanguages: [String],
                               progress: ((String) -> Void)?) throws -> Data {
        let output = NSMutableData()
        guard let consumer = CGDataConsumer(data: output as CFMutableData) else {
            throw ScanError.exportFailed("Could not create a PDF data consumer.")
        }
        try write(pages: pages, searchable: searchable, ocrLanguages: ocrLanguages,
                  progress: progress, consumer: consumer)
        return output as Data
    }

    /// Stream the PDF straight to `url` — never holds the whole document in memory.
    public static func writePDF(pages: [ScannedPage], searchable: Bool, ocrLanguages: [String],
                                to url: URL, progress: ((String) -> Void)?) throws {
        guard let consumer = CGDataConsumer(url: url as CFURL) else {
            throw ScanError.exportFailed("Could not write to \(url.path).")
        }
        try write(pages: pages, searchable: searchable, ocrLanguages: ocrLanguages,
                  progress: progress, consumer: consumer)
    }

    private static func write(pages: [ScannedPage], searchable: Bool, ocrLanguages: [String],
                              progress: ((String) -> Void)?, consumer: CGDataConsumer) throws {
        var defaultBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(consumer: consumer, mediaBox: &defaultBox, nil) else {
            throw ScanError.exportFailed("Could not create a PDF context.")
        }

        for (index, page) in pages.enumerated() {
            // Spilled pages hold only a preview in memory — reload the
            // full-resolution pixels one page at a time. The media box comes
            // from the recorded full-resolution size, so the physical page size
            // stays correct even when only the preview pixels are available.
            let turns = ((page.rotationQuarterTurns % 4) + 4) % 4
            let swapsAxes = turns % 2 == 1
            let image: CGImage
            let pixelWidth: Int
            let pixelHeight: Int
            if let full = spoolImage(for: page) {
                // The spool file is unrotated; apply the user's page rotation now, and
                // swap the recorded dimensions for odd quarter turns.
                image = turns == 0 ? full : ImagePipeline.rotate(full, quarterTurns: turns)
                let rawWidth = page.fullPixelSize.map { Int($0.width) } ?? full.width
                let rawHeight = page.fullPixelSize.map { Int($0.height) } ?? full.height
                pixelWidth = swapsAxes ? rawHeight : rawWidth
                pixelHeight = swapsAxes ? rawWidth : rawHeight
            } else {
                // Missing/unreadable spill file (or the page was never spooled): fall
                // back to the in-memory image, which ALREADY carries the rotation.
                image = page.image
                if let full = page.fullPixelSize {
                    // Recorded pre-rotation full-resolution size: swap for odd turns.
                    pixelWidth = swapsAxes ? Int(full.height) : Int(full.width)
                    pixelHeight = swapsAxes ? Int(full.width) : Int(full.height)
                } else {
                    pixelWidth = image.width
                    pixelHeight = image.height
                }
            }
            var box = mediaBox(width: pixelWidth, height: pixelHeight, dpi: page.dpi)
            let boxData = Data(bytes: &box, count: MemoryLayout<CGRect>.size)
            let pageInfo = [kCGPDFContextMediaBox as String: boxData] as CFDictionary
            context.beginPDFPage(pageInfo)
            context.draw(image, in: box)

            if searchable {
                progress?("OCR page \(index + 1) of \(pages.count)…")
                // If OCR fails for a page, the PDF is still produced without a text layer.
                if let lines = try? OCRService.recognizeLines(in: image, languages: ocrLanguages) {
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
