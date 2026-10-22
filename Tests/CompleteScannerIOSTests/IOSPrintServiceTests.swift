#if os(iOS)
import CoreGraphics
import UIKit
import XCTest
@testable import CompleteScannerIOS
@testable import CompleteScannerKit

// The iPhone's and iPad's AirPrint printing (I16): what the service reports before a printer is picked,
// the paper it lays pages out on, and the page renderer that repeats the pages for the copies. Nothing
// here presents the print UI or sends a job.

final class IOSPrintServiceTests: XCTestCase {
    @MainActor
    func test_reportsAPrinter_whenPrintingIsAvailable() {
        let service = IOSPrintService()
        XCTAssertNil(service.lastPrinter)
        XCTAssertFalse(service.hasPickedPrinter)
        guard UIPrintInteractionController.isPrintingAvailable else {
            // The runner can't print at all: then the service offers nothing, and Copy stays gated.
            XCTAssertTrue(service.printerNames.isEmpty)
            XCTAssertNil(service.defaultPrinterName)
            XCTAssertNil(service.setup(printerName: nil, requestedPaper: nil))
            return
        }
        XCTAssertEqual(service.printerNames.count, 1)
        XCTAssertEqual(service.defaultPrinterName, IOSPrintService.genericPrinterName)
    }

    @MainActor
    func test_setup_laysPagesOutOnTheRequestedPaper() throws {
        let service = IOSPrintService()
        try XCTSkipUnless(UIPrintInteractionController.isPrintingAvailable)
        let a4 = try XCTUnwrap(service.setup(printerName: nil, requestedPaper: .a4))
        let inches = try XCTUnwrap(PaperSizes.inches(.a4))
        XCTAssertEqual(Double(a4.paper.paper.width), Double(inches.width), accuracy: 0.001)
        XCTAssertEqual(a4.paper.size, .a4)
        // No printer is known yet, so its margins are assumed.
        XCTAssertEqual(a4.paper.largestMargin, IOSPrintService.assumedMarginInches, accuracy: 0.001)
        XCTAssertEqual(Double(a4.paper.printable.minX), IOSPrintService.assumedMarginInches, accuracy: 0.001)
    }

    func test_renderer_repeatsThePagesForTheCopies() throws {
        let page = PrintPage(image: whiteImage(100, 140), dpi: 72,
                             placement: PrintPlacement(rect: CGRect(x: 0, y: 0, width: 100.0 / 72, height: 140.0 / 72),
                                                       scale: 1, quarterTurns: 0, clippedInches: 0))
        let data = try XCTUnwrap(PrintDocument.makePDF(pages: [page, page], paper: CGSize(width: 8.5, height: 11)))
        let pdf = try XCTUnwrap(IOSPrintRenderer.pdf(from: data))
        XCTAssertEqual(pdf.numberOfPages, 2)
        let renderer = IOSPrintRenderer(pdf: pdf, copies: 3)
        XCTAssertEqual(renderer.numberOfPages, 6)
        XCTAssertEqual(IOSPrintRenderer(pdf: pdf, copies: 1).numberOfPages, 2)
    }

    /// A camera page that snapped to nothing forces Copy to fit the page; a scan prints at real size.
    func test_copyFitDecision_matchesTheCameraPagesSize() {
        let scan = ScannedPage(image: whiteImage(10, 10), dpi: 300, colorMode: .color)
        XCTAssertTrue(scan.printsAtRealSize)
        XCTAssertFalse(PrintLayout.copyFitsToPage(chosenFit: false, allPagesRealSize: scan.printsAtRealSize))

        let guessed = CaptureScaleResult(basis: .nominal, size: nil, dpi: 200, pixelWidth: 2000, pixelHeight: 1500,
                                         widthInches: 10, heightInches: 7.5)
        let quad = Quad(topLeft: CGPoint(x: 0, y: 0), topRight: CGPoint(x: 100, y: 0),
                        bottomRight: CGPoint(x: 100, y: 100), bottomLeft: CGPoint(x: 0, y: 100))
        let camera = scan.withCapture(CaptureFacts(quad: quad, sourceWidth: 100, sourceHeight: 100, scale: guessed))
        XCTAssertFalse(camera.printsAtRealSize)
        XCTAssertTrue(PrintLayout.copyFitsToPage(chosenFit: false, allPagesRealSize: camera.printsAtRealSize))
    }

    private func whiteImage(_ width: Int, _ height: Int) -> CGImage {
        RgbaImage.filled(width: width, height: height, r: 255, g: 255, b: 255).makeCGImage()!
    }
}
#endif
