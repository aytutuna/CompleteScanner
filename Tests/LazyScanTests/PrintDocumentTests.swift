import XCTest
import CoreGraphics
import PDFKit
@testable import LazyScanKit

// The print document is what the print panel prints at 100 %: here it is drawn back into pixels at
// one pixel per point, so the paper size and where each image lands are checked without a printer.
// Mac only: no C# twin (the Windows print document is checked by
// windows/LazyScan.App.Tests/PrintDocumentTests.cs).

private let letter = PaperSizes.inches(.letter)!
private let a4 = PaperSizes.inches(.a4)!

private func wholePaper(_ paper: CGSize) -> CGRect {
    CGRect(x: 0, y: 0, width: Double(paper.width), height: Double(paper.height))
}

private func solid(_ width: Int, _ height: Int, r: UInt8, g: UInt8, b: UInt8) -> CGImage {
    RgbaImage.filled(width: width, height: height, r: r, g: g, b: b).makeCGImage()!
}

private func page(_ image: CGImage, dpi: Int, paper: CGSize, printable: CGRect? = nil,
                  mode: PrintMode = .actualSize, align: PrintAlign = .paperOrigin) -> PrintPage {
    PrintPage(image: image, dpi: dpi,
              placement: PrintLayout.place(pixelWidth: image.width, pixelHeight: image.height, dpi: dpi, paper: paper,
                                           printable: printable ?? wholePaper(paper), mode: mode, align: align))
}

/// A page of the PDF drawn at one pixel per point on white, RGBA, row 0 at the top.
private struct Rendered {
    let width: Int
    let height: Int
    let pixels: [UInt8]

    func color(_ x: Int, _ y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        let i = (y * width + x) * 4
        return (pixels[i], pixels[i + 1], pixels[i + 2])
    }

    func isWhite(_ x: Int, _ y: Int) -> Bool {
        let c = color(x, y)
        return c.r > 240 && c.g > 240 && c.b > 240
    }

    func isRed(_ x: Int, _ y: Int) -> Bool {
        let c = color(x, y)
        return c.r > 180 && c.g < 80 && c.b < 80
    }

    func isBlue(_ x: Int, _ y: Int) -> Bool {
        let c = color(x, y)
        return c.b > 180 && c.r < 80 && c.g < 80
    }
}

private func render(_ data: Data, pageIndex: Int) -> Rendered? {
    guard let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider),
          let pdfPage = document.page(at: pageIndex + 1),
          let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
    let box = pdfPage.getBoxRect(.mediaBox)
    let width = Int(Double(box.width).rounded()), height = Int(Double(box.height).rounded())
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let drawn: Bool = pixels.withUnsafeMutableBytes { buffer -> Bool in
        guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.drawPDFPage(pdfPage)
        return true
    }
    return drawn ? Rendered(width: width, height: height, pixels: pixels) : nil
}

final class PrintDocumentTests: XCTestCase {

    func test_pageIsThePaper_theImageAtItsPlace() throws {
        // A 3 × 2 in area selected on the glass, centred on Letter: 216 × 144 pt at (198, 324) from the top left.
        let selected = page(solid(900, 600, r: 220, g: 20, b: 20), dpi: 300, paper: letter, align: .center)
        let data = try XCTUnwrap(PrintDocument.makePDF(pages: [selected], paper: letter))
        let document = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertEqual(document.pageCount, 1)
        let bounds = try XCTUnwrap(document.page(at: 0)).bounds(for: .mediaBox)
        XCTAssertEqual(Double(bounds.width), 612, accuracy: 0.01)
        XCTAssertEqual(Double(bounds.height), 792, accuracy: 0.01)
        let rendered = try XCTUnwrap(render(data, pageIndex: 0))
        XCTAssertTrue(rendered.isRed(306, 396))
        XCTAssertTrue(rendered.isRed(201, 327))
        XCTAssertTrue(rendered.isRed(411, 465))
        XCTAssertTrue(rendered.isWhite(195, 396))
        XCTAssertTrue(rendered.isWhite(417, 396))
        XCTAssertTrue(rendered.isWhite(306, 321))
        XCTAssertTrue(rendered.isWhite(306, 471))
        XCTAssertTrue(rendered.isWhite(20, 20))
    }

    func test_pagesInOrder_aTurnedPageTurnedInItsPixels() throws {
        // 10 × 7 in across fits Letter only turned: 504 × 720 pt from the top left corner.
        let turned = page(solid(3000, 2100, r: 220, g: 20, b: 20), dpi: 300, paper: letter)
        XCTAssertEqual(turned.placement.quarterTurns, 1)
        let small = page(solid(300, 300, r: 20, g: 20, b: 220), dpi: 300, paper: letter)
        let data = try XCTUnwrap(PrintDocument.makePDF(pages: [turned, small], paper: letter))
        XCTAssertEqual(PDFDocument(data: data)?.pageCount, 2)
        let first = try XCTUnwrap(render(data, pageIndex: 0))
        XCTAssertTrue(first.isRed(250, 360))
        XCTAssertTrue(first.isRed(500, 715))
        XCTAssertTrue(first.isWhite(510, 360))
        XCTAssertTrue(first.isWhite(250, 725))
        // The second page: 1 × 1 in in the top left corner.
        let second = try XCTUnwrap(render(data, pageIndex: 1))
        XCTAssertTrue(second.isBlue(36, 36))
        XCTAssertTrue(second.isWhite(76, 36))
        XCTAssertTrue(second.isWhite(36, 76))
    }

    func test_fitToPage_madeSmallerInItsPlace() throws {
        // A landscape Letter page fitted into Letter with 0.25 in margins: turned, 576 pt across.
        let printable = CGRect(x: 0.25, y: 0.25, width: 8.0, height: 10.5)
        let fitted = page(solid(3300, 2550, r: 220, g: 20, b: 20), dpi: 300, paper: letter, printable: printable,
                          mode: .fitToPrintable)
        let data = try XCTUnwrap(PrintDocument.makePDF(pages: [fitted], paper: letter))
        let rendered = try XCTUnwrap(render(data, pageIndex: 0))
        let top = (0.25 + (10.5 - 11 * 8.0 / 8.5) / 2) * 72
        XCTAssertTrue(rendered.isWhite(14, 396))
        XCTAssertTrue(rendered.isRed(22, 396))
        XCTAssertTrue(rendered.isRed(590, 396))
        XCTAssertTrue(rendered.isWhite(598, 396))
        XCTAssertTrue(rendered.isWhite(306, Int(top) - 4))
        XCTAssertTrue(rendered.isRed(306, Int(top) + 4))
    }

    func test_a4Paper_isA4InPoints() throws {
        let ruler = PrintCalibration.makeRulerPage(paper: a4, dpi: 72)
        let image = try XCTUnwrap(ruler.makeCGImage())
        let placed = PrintPage(image: image, dpi: 72,
                               placement: PrintLayout.place(pixelWidth: ruler.width, pixelHeight: ruler.height, dpi: 72,
                                                            paper: a4, printable: wholePaper(a4),
                                                            mode: .actualSize, align: .paperOrigin))
        let data = try XCTUnwrap(PrintDocument.makePDF(pages: [placed], paper: a4))
        let bounds = try XCTUnwrap(PDFDocument(data: data)?.page(at: 0)).bounds(for: .mediaBox)
        XCTAssertEqual(Double(bounds.width), Double(a4.width) * 72, accuracy: 0.01)
        XCTAssertEqual(Double(bounds.height), Double(a4.height) * 72, accuracy: 0.01)
    }

    // The paper asked of a printer is used only when the printer has it (else its own paper, as on
    // Windows): a printer has a size when a name its driver gives that paper has that size.
    func test_printerPapers_offeredOnlyWhenThePrinterHasThatSize() {
        let a4Only: (String) -> CGSize = { name in
            name == "A4" ? CGSize(width: 595, height: 842) : .zero
        }
        XCTAssertTrue(PrinterPapers.offers(.a4, pageSize: a4Only))
        XCTAssertFalse(PrinterPapers.offers(.legal, pageSize: a4Only))
        XCTAssertFalse(PrinterPapers.offers(.letter, pageSize: a4Only))
        // A name the driver gives another size does not count.
        let legalIsLetter: (String) -> CGSize = { name in
            name == "Legal" ? CGSize(width: 612, height: 792) : .zero
        }
        XCTAssertFalse(PrinterPapers.offers(.legal, pageSize: legalIsLetter))
        let legal: (String) -> CGSize = { name in
            name == "na-legal" ? CGSize(width: 612, height: 1008) : .zero
        }
        XCTAssertTrue(PrinterPapers.offers(.legal, pageSize: legal))
        XCTAssertTrue(PrinterPapers.names(.auto).isEmpty)
        XCTAssertTrue(PrinterPapers.names(.idCard).isEmpty)
        for size in PaperSize.allCases where size != .auto && size != .idCard {
            XCTAssertFalse(PrinterPapers.names(size).isEmpty, "\(size)")
        }
    }
}
