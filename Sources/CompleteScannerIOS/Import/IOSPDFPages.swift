#if os(iOS)
import CompleteScannerKit
import CoreGraphics
import Foundation
import PDFKit

/// A PDF's page drawn for the queue: its picture and the resolution it was drawn at.
public struct IOSRenderedPage {
    public let image: CGImage
    public let dpi: Int
}

/// Brings the pages of a PDF into the queue: each page drawn with PDFKit at `dpi` (300) on white, the
/// page's rotation applied, so its physical size survives a save (pixels ÷ dpi). A page so large that
/// its long side would pass `maxLongSide` pixels is drawn at the resolution that fits, recorded on
/// the page. A locked (password-protected) PDF is refused: there is nothing to draw without it.
public enum IOSPDFPages {
    /// The resolution PDF pages are drawn at.
    public static let dpi: Int = 300
    /// The longest side a page is drawn to (a poster is drawn at a lower resolution).
    public static let maxLongSide: Int = 7000
    /// Why a protected PDF is refused.
    public static let lockedDetail = "it needs a password."

    /// The document in `data`, named `fileName` in the messages; throws `IOSImportError` (also for a
    /// document without pages).
    public static func open(_ data: Data, fileName: String) throws -> PDFDocument {
        guard let document = PDFDocument(data: data) else {
            throw IOSImportError(message: PhotoImport.unreadableMessage(fileName, detail: PhotoImport.unreadableDetail))
        }
        if document.isLocked {
            throw IOSImportError(message: PhotoImport.unreadableMessage(fileName, detail: lockedDetail))
        }
        if document.pageCount == 0 {
            throw IOSImportError(message: PhotoImport.unreadableMessage(fileName, detail: PhotoImport.unreadableDetail))
        }
        return document
    }

    /// The page's size in points as it is shown: its crop box, turned by its rotation.
    public static func shownSize(_ page: PDFPage) -> CGSize {
        let box: CGRect = page.bounds(for: .cropBox)
        let turns: Int = ((page.rotation / 90) % 4 + 4) % 4
        if turns % 2 == 1 {
            return CGSize(width: box.height, height: box.width)
        }
        return CGSize(width: box.width, height: box.height)
    }

    /// The resolution page `size` (points) is drawn at: `dpi`, or less so the long side stays within
    /// `maxLongSide` pixels; at least 1.
    public static func resolution(for size: CGSize, dpi: Int = IOSPDFPages.dpi, maxLongSide: Int = IOSPDFPages.maxLongSide) -> Int {
        let longPoints: Double = Double(max(size.width, size.height))
        guard longPoints > 0 else { return dpi }
        let longPixels: Double = longPoints / 72.0 * Double(dpi)
        if longPixels <= Double(maxLongSide) { return dpi }
        let fitted: Int = Int((Double(maxLongSide) * 72.0 / longPoints).rounded(.down))
        return max(1, fitted)
    }

    /// Page `index` (from 0) of `document`, drawn at `resolution(for:)`; nil when there is no such page
    /// or it cannot be drawn.
    public static func render(_ document: PDFDocument, index: Int, dpi: Int = IOSPDFPages.dpi,
                              maxLongSide: Int = IOSPDFPages.maxLongSide) -> IOSRenderedPage? {
        guard index >= 0, index < document.pageCount, let page = document.page(at: index),
              let pageRef = page.pageRef else { return nil }
        let size: CGSize = shownSize(page)
        let drawnDPI: Int = resolution(for: size, dpi: dpi, maxLongSide: maxLongSide)
        let scale: Double = Double(drawnDPI) / 72.0
        let pixelWidth: Int = max(1, Int((Double(size.width) * scale).rounded()))
        let pixelHeight: Int = max(1, Int((Double(size.height) * scale).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        context.interpolationQuality = .high
        context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        // The page's own transform into a rectangle of its shown size in points: its crop box moved to
        // the origin and its rotation applied (no scaling, which getDrawingTransform never does upward).
        let target = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        let transform: CGAffineTransform = pageRef.getDrawingTransform(.cropBox, rect: target, rotate: 0,
                                                                       preserveAspectRatio: true)
        context.concatenate(transform)
        context.drawPDFPage(pageRef)
        guard let image = context.makeImage() else { return nil }
        return IOSRenderedPage(image: image, dpi: drawnDPI)
    }
}
#endif
