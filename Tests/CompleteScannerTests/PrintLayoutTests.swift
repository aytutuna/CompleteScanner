import XCTest
import CoreGraphics
@testable import CompleteScannerKit

// Mirrors windows/LazyScan.Core.Tests/PrintLayoutTests.cs: the same cases.

private let letter = PaperSizes.inches(.letter)!
private let a4 = PaperSizes.inches(.a4)!

private func whole(_ paper: CGSize) -> CGRect {
    CGRect(x: 0, y: 0, width: Double(paper.width), height: Double(paper.height))
}

private func assertRect(_ x: Double, _ y: Double, _ width: Double, _ height: Double, _ actual: CGRect,
                        accuracy: Double = 0.0001, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(Double(actual.origin.x), x, accuracy: accuracy, file: file, line: line)
    XCTAssertEqual(Double(actual.origin.y), y, accuracy: accuracy, file: file, line: line)
    XCTAssertEqual(Double(actual.width), width, accuracy: accuracy, file: file, line: line)
    XCTAssertEqual(Double(actual.height), height, accuracy: accuracy, file: file, line: line)
}

private func gray(_ image: RgbaImage, _ x: Int, _ y: Int) -> UInt8 { image.pixels[(y * image.width + x) * 4] }

final class PrintLayoutTests: XCTestCase {

    // MARK: Actual size

    func test_actualSize_a4PageAt300Dpi_printsAtItsRealSize() {
        let placement = PrintLayout.place(pixelWidth: 2480, pixelHeight: 3508, dpi: 300, paper: a4, printable: whole(a4),
                                          mode: .actualSize, align: .paperOrigin)
        assertRect(0, 0, 8.2667, 11.6933, placement.rect)
        XCTAssertEqual(placement.scale, 1)
        XCTAssertEqual(placement.quarterTurns, 0)
        // 2480 × 3508 is A4 rounded to whole pixels: 0.0004 in too tall is nothing to warn about.
        XCTAssertLessThan(placement.clippedInches, 0.001)
        XCTAssertFalse(placement.isClipped)
        XCTAssertNil(PrintLayout.clipWarning(placement, paper: a4))
    }

    func test_actualSize_fullGlassOnA4_isCutOffBeyondThePaper() {
        // A whole 8.5 × 11.7 in glass at 300 dpi.
        let placement = PrintLayout.place(pixelWidth: 2550, pixelHeight: 3510, dpi: 300, paper: a4, printable: whole(a4),
                                          mode: .actualSize, align: .paperOrigin)
        assertRect(0, 0, 8.5, 11.7, placement.rect)
        XCTAssertEqual(placement.quarterTurns, 0)
        XCTAssertEqual(placement.clippedInches, 0.2323, accuracy: 0.0001)
        XCTAssertTrue(placement.isClipped)
        XCTAssertEqual(PrintLayout.clipWarning(placement, paper: a4),
                       "Larger than the paper: up to 6 mm is cut off. Turn on Fit to page to print all of it.")
    }

    func test_actualSize_againstTheCorner_printerMarginsCutTheEdges() {
        let printable = CGRect(x: 0.25, y: 0.25, width: 8.0, height: 10.5)
        let placement = PrintLayout.place(pixelWidth: 2550, pixelHeight: 3300, dpi: 300, paper: letter, printable: printable,
                                          mode: .actualSize, align: .paperOrigin)
        assertRect(0, 0, 8.5, 11, placement.rect)
        XCTAssertEqual(placement.clippedInches, 0.25, accuracy: 1e-9)
        XCTAssertEqual(PrintLayout.clipWarning(placement, paper: letter), "Edges may be cut by up to 7 mm (printer margins).")
        // The same page on the printer's paper record.
        let onPrinter = PrintLayout.place(pixelWidth: 2550, pixelHeight: 3300, dpi: 300,
                                          on: PrinterPaper.make(paper: letter, printable: printable),
                                          mode: .actualSize, align: .paperOrigin)
        XCTAssertEqual(placement, onPrinter)
    }

    func test_actualSize_aSelectionIsCentredOnThePaper() {
        let placement = PrintLayout.place(pixelWidth: 900, pixelHeight: 600, dpi: 300, paper: letter, printable: whole(letter),
                                          mode: .actualSize, align: .center)
        assertRect(2.75, 4.5, 3, 2, placement.rect)
        XCTAssertEqual(placement.clippedInches, 0)
        XCTAssertEqual(PrintLayout.align(hasSelection: true), .center)
        XCTAssertEqual(PrintLayout.align(hasSelection: false), .paperOrigin)
    }

    func test_actualSize_turnsOnlyWhenThatCutsOffLess() {
        // 10 × 7 in across does not fit Letter upright but does turned.
        let turned = PrintLayout.place(pixelWidth: 3000, pixelHeight: 2100, dpi: 300, paper: letter, printable: whole(letter),
                                       mode: .actualSize, align: .paperOrigin)
        XCTAssertEqual(turned.quarterTurns, 1)
        assertRect(0, 0, 7, 10, turned.rect)
        XCTAssertEqual(turned.clippedInches, 0)
        // 4 × 3 in fits either way: left as it is.
        let upright = PrintLayout.place(pixelWidth: 1200, pixelHeight: 900, dpi: 300, paper: letter, printable: whole(letter),
                                        mode: .actualSize, align: .paperOrigin)
        XCTAssertEqual(upright.quarterTurns, 0)
        assertRect(0, 0, 4, 3, upright.rect)
        // At another resolution the inches count, not the pixels: 600 dpi halves the size.
        let fine = PrintLayout.place(pixelWidth: 3000, pixelHeight: 2100, dpi: 600, paper: letter, printable: whole(letter),
                                     mode: .actualSize, align: .paperOrigin)
        XCTAssertEqual(fine.quarterTurns, 0)
        assertRect(0, 0, 10 / 2.0, 7 / 2.0, fine.rect)
    }

    // MARK: Fit to page

    func test_fit_turnsWhenThatGivesALargerScale() {
        let printable = CGRect(x: 0.25, y: 0.25, width: 8.0, height: 10.5)
        // A landscape Letter page: upright it would be 0.727 of its size, turned 0.941.
        let placement = PrintLayout.place(pixelWidth: 3300, pixelHeight: 2550, dpi: 300, paper: letter, printable: printable,
                                          mode: .fitToPrintable, align: .paperOrigin)
        XCTAssertEqual(placement.quarterTurns, 1)
        XCTAssertEqual(placement.scale, 8.0 / 8.5, accuracy: 1e-9)
        assertRect(0.25, 0.25 + (10.5 - 11 * 8.0 / 8.5) / 2, 8.0, 11 * 8.0 / 8.5, placement.rect)
        XCTAssertEqual(placement.clippedInches, 0)
        XCTAssertNil(PrintLayout.clipWarning(placement, paper: letter))
    }

    func test_fit_neverEnlarges_andCentresInThePrintableArea() {
        let printable = CGRect(x: 0.25, y: 0.5, width: 8.0, height: 10.0)
        let placement = PrintLayout.place(pixelWidth: 600, pixelHeight: 300, dpi: 300, paper: letter, printable: printable,
                                          mode: .fitToPrintable, align: .paperOrigin)
        XCTAssertEqual(placement.scale, 1)
        XCTAssertEqual(placement.quarterTurns, 0)
        assertRect(0.25 + 3, 0.5 + 4.5, 2, 1, placement.rect)
    }

    func test_fit_fullGlassOnA4_shrinksToTheMargins() {
        let a4Width = Double(a4.width), a4Height = Double(a4.height)
        let printable = CGRect(x: 0.17, y: 0.17, width: a4Width - 0.34, height: a4Height - 0.34)
        let placement = PrintLayout.place(pixelWidth: 2550, pixelHeight: 3510, dpi: 300, paper: a4, printable: printable,
                                          mode: .fitToPrintable, align: .paperOrigin)
        XCTAssertEqual(placement.quarterTurns, 0)
        let scale = min((a4Width - 0.34) / 8.5, (a4Height - 0.34) / 11.7)
        XCTAssertEqual(placement.scale, scale, accuracy: 1e-9)
        XCTAssertEqual(Double(placement.rect.width), a4Width - 0.34, accuracy: 1e-9)
        XCTAssertEqual(placement.clippedInches, 0)
    }

    // MARK: Units, paper, copies

    func test_toUnits_devicePixelsAndPoints() {
        let rect = CGRect(x: 1, y: 2, width: 8.5, height: 11)
        assertRect(96, 192, 816, 1056, PrintLayout.toUnits(rect, unitsPerInch: 96))
        assertRect(72, 144, 612, 792, PrintLayout.toUnits(rect, unitsPerInch: 72))
        XCTAssertEqual(PrintLayout.toUnits(letter, unitsPerInch: 96), CGSize(width: 816, height: 1056))
        XCTAssertEqual(PrintLayout.toUnits(letter, unitsPerInch: 72), CGSize(width: 612, height: 792))
    }

    func test_printerPaper_clampsThePrintableArea_andNamesTheSize() {
        XCTAssertEqual(PrinterPaper.make(paper: letter, printable: nil).printable, whole(letter))
        XCTAssertEqual(PrinterPaper.make(paper: letter, printable: CGRect(x: -1, y: -1, width: 20, height: 20)).printable,
                       whole(letter))
        XCTAssertEqual(PrinterPaper.make(paper: letter, printable: CGRect(x: 9, y: 12, width: 1, height: 1)).printable,
                       whole(letter))
        let a4Paper = PrinterPaper.make(paper: a4, printable: CGRect(x: 0.17, y: 0.2, width: Double(a4.width) - 0.34,
                                                                     height: Double(a4.height) - 0.5))
        XCTAssertEqual(a4Paper.size, .a4)
        XCTAssertEqual(a4Paper.largestMargin, 0.3, accuracy: 1e-9)
        XCTAssertEqual(a4Paper.description, "A4 (210 \u{00D7} 297 mm)")
        XCTAssertEqual(PrinterPaper.make(paper: letter, printable: nil).description, "Letter (8.5 \u{00D7} 11 in)")
        let photo = PrinterPaper.make(paper: CGSize(width: 5, height: 7), printable: nil)
        XCTAssertNil(photo.size)
        XCTAssertEqual(photo.description, "5 \u{00D7} 7 in")
        XCTAssertEqual(photo.largestMargin, 0)
    }

    func test_clippedInches_worstSide() {
        let printable = CGRect(x: 0.25, y: 0.25, width: 8.0, height: 10.5)
        XCTAssertEqual(PrintLayout.clippedInches(CGRect(x: 1, y: 1, width: 2, height: 2), printable: printable), 0)
        XCTAssertEqual(PrintLayout.clippedInches(CGRect(x: 0, y: 1, width: 2, height: 2), printable: printable), 0.25, accuracy: 1e-9)
        XCTAssertEqual(PrintLayout.clippedInches(CGRect(x: 7, y: 1, width: 1.75, height: 2), printable: printable), 0.5, accuracy: 1e-9)
        XCTAssertEqual(PrintLayout.clippedInches(CGRect(x: 1, y: 9, width: 2, height: 2.75), printable: printable), 1, accuracy: 1e-9)
        XCTAssertEqual(PrintLayout.millimetres(0.01), 1)
        XCTAssertEqual(PrintLayout.millimetres(0.25), 7)
        XCTAssertEqual(PrintLayout.millimetres(25 / 25.4), 25)
    }

    func test_copies_thePrinterMakesThemWhenItSaysItCan() {
        XCTAssertEqual(PrintCopies.plan(requested: 1, maxCopyCount: nil), PrintCopiesPlan(ticketCopies: 1, documentRepeats: 1))
        XCTAssertEqual(PrintCopies.plan(requested: 3, maxCopyCount: 99), PrintCopiesPlan(ticketCopies: 3, documentRepeats: 1))
        XCTAssertEqual(PrintCopies.plan(requested: 3, maxCopyCount: 3), PrintCopiesPlan(ticketCopies: 3, documentRepeats: 1))
        XCTAssertEqual(PrintCopies.plan(requested: 3, maxCopyCount: 2), PrintCopiesPlan(ticketCopies: 1, documentRepeats: 3))
        XCTAssertEqual(PrintCopies.plan(requested: 3, maxCopyCount: nil), PrintCopiesPlan(ticketCopies: 1, documentRepeats: 3))
        XCTAssertEqual(PrintCopies.plan(requested: 150, maxCopyCount: 999), PrintCopiesPlan(ticketCopies: 99, documentRepeats: 1))
        XCTAssertEqual(PrintCopies.plan(requested: 0, maxCopyCount: nil), PrintCopiesPlan(ticketCopies: 1, documentRepeats: 1))
        XCTAssertEqual(PrintCopies.clamp(-5), 1)
        XCTAssertEqual(PrintCopies.clamp(99), 99)
        XCTAssertEqual(PrintCopies.maxCount, 99)
    }

    func test_copies_severalPages_thePrinterMakesThemOnlyWhenItCollates() {
        // Pages in order in every copy (1, 2, 3, 1, 2, 3): a printer that does not collate would
        // give 1, 1, 2, 2, 3, 3, so the pages are repeated in the job instead.
        XCTAssertEqual(PrintCopies.plan(requested: 3, maxCopyCount: 99, pageCount: 3, canCollate: true),
                       PrintCopiesPlan(ticketCopies: 3, documentRepeats: 1))
        XCTAssertEqual(PrintCopies.plan(requested: 3, maxCopyCount: 99, pageCount: 3, canCollate: false),
                       PrintCopiesPlan(ticketCopies: 1, documentRepeats: 3))
        // One page needs no collating.
        XCTAssertEqual(PrintCopies.plan(requested: 3, maxCopyCount: 99, pageCount: 1, canCollate: false),
                       PrintCopiesPlan(ticketCopies: 3, documentRepeats: 1))
        XCTAssertEqual(PrintCopies.plan(requested: 3, maxCopyCount: 2, pageCount: 3, canCollate: true),
                       PrintCopiesPlan(ticketCopies: 1, documentRepeats: 3))
        XCTAssertEqual(PrintCopies.plan(requested: 1, maxCopyCount: 99, pageCount: 3, canCollate: false),
                       PrintCopiesPlan(ticketCopies: 1, documentRepeats: 1))
    }

    func test_text() {
        XCTAssertEqual(PrintText.sent(pageCount: 1, copies: 1, printerName: "Office Printer"), "Sent 1 page to Office Printer.")
        XCTAssertEqual(PrintText.sent(pageCount: 2, copies: 3, printerName: "Office Printer"),
                       "Sent 2 pages to Office Printer, 3 copies.")
        XCTAssertEqual(PrintText.modeLabel(fitToPage: false), "Actual size")
        XCTAssertEqual(PrintText.modeLabel(fitToPage: true), "Fit to page")
        XCTAssertEqual(PrintText.noPrinterReason, "Needs a printer")
        XCTAssertEqual(PrintText.copyPaperHint(.auto, source: .flatbed), "The printer's paper size, from the glass corner")
        XCTAssertEqual(PrintText.copyPaperHint(.auto, source: .documentFeeder), PaperSizes.hint(.auto, source: .documentFeeder))
        XCTAssertEqual(PrintText.copyPaperHint(.a4, source: .flatbed), PaperSizes.hint(.a4, source: .flatbed))
    }

    // MARK: Ruler test page

    func test_rulerPage_inchGridAndCentimetreTicks() {
        let page = PrintCalibration.makeRulerPage(paper: letter, dpi: 300)
        XCTAssertEqual(page.width, 2550)
        XCTAssertEqual(page.height, 3300)
        XCTAssertEqual(PrintCalibration.lineWidth(300), 2)
        XCTAssertEqual(PrintCalibration.lineWidth(72), 1)
        XCTAssertEqual(PrintCalibration.lineWidth(600), 4)
        XCTAssertEqual(gray(page, 0, 0), 255)
        XCTAssertEqual(gray(page, 150, 150), 255)
        // Grid lines every inch, two pixels wide at 300 dpi, centred on the inch.
        XCTAssertEqual(gray(page, 299, 1450), 128)
        XCTAssertEqual(gray(page, 300, 1450), 128)
        XCTAssertEqual(gray(page, 301, 1450), 255)
        XCTAssertEqual(gray(page, 298, 1450), 255)
        XCTAssertEqual(gray(page, 1500, 600), 128)
        XCTAssertEqual(gray(page, 2400, 3000), 128)
        // Centimetre ticks from the first inch line: 0.15 in, 0.3 in every 5 cm.
        XCTAssertEqual(PrintCalibration.tickPosition(1, dpi: 300), 418)
        XCTAssertEqual(PrintCalibration.tickPosition(5, dpi: 300), 891)
        XCTAssertEqual(gray(page, 418, 340), 0)
        XCTAssertEqual(gray(page, 418, 380), 255)
        XCTAssertEqual(gray(page, 891, 380), 0)
        XCTAssertEqual(gray(page, 891, 400), 255)
        XCTAssertEqual(gray(page, 340, 418), 0)
        XCTAssertEqual(gray(page, 380, 891), 0)
        XCTAssertEqual(gray(page, 380, 418), 255)
        XCTAssertEqual(page.pixels[(1450 * page.width + 299) * 4 + 3], 255)
        // Ten centimetres from the first inch line is 3.937 in, 1181 pixels further on.
        XCTAssertEqual(PrintCalibration.tickPosition(10, dpi: 300), 300 + 1181)
    }

    func test_rulerPage_sizeFollowsThePaperAndResolution() {
        let a4Page = PrintCalibration.makeRulerPage(paper: a4, dpi: 200)
        XCTAssertEqual(a4Page.width, 1654)
        XCTAssertEqual(a4Page.height, 2339)
        let small = PrintCalibration.makeRulerPage(paper: CGSize(width: 2, height: 1.5), dpi: 72)
        XCTAssertEqual(small.width, 144)
        XCTAssertEqual(small.height, 108)
        XCTAssertEqual(gray(small, 72, 10), 128)
        XCTAssertEqual(gray(small, 100, 80), 0)
    }

    // MARK: - Real size or fit to page

    func test_copyFitsToPage_realSizePages_followsTheUsersChoice() {
        XCTAssertFalse(PrintLayout.copyFitsToPage(chosenFit: false, allPagesRealSize: true))
        XCTAssertTrue(PrintLayout.copyFitsToPage(chosenFit: true, allPagesRealSize: true))
    }

    func test_copyFitsToPage_aGuessedSize_isForcedToFit() {
        XCTAssertTrue(PrintLayout.copyFitsToPage(chosenFit: false, allPagesRealSize: false))
        XCTAssertTrue(PrintLayout.copyFitsToPage(chosenFit: true, allPagesRealSize: false))
    }

    func test_printsAtRealSize_scannerAndImportedPages_areRealSize() {
        XCTAssertTrue(scannerPage().printsAtRealSize)
    }

    func test_printsAtRealSize_cameraPageSnappedToAKnownSize_isRealSize() {
        let scale = CaptureScaleResult(basis: .paper, size: "a4", dpi: 300, pixelWidth: 2480, pixelHeight: 3508,
                                       widthInches: 8.2667, heightInches: 11.6933)
        XCTAssertTrue(cameraPage(scale).printsAtRealSize)
    }

    func test_printsAtRealSize_cameraPageWithAGuessedSize_isNotRealSize() {
        let nominal = CaptureScaleResult(basis: .nominal, size: nil, dpi: 200, pixelWidth: 2000, pixelHeight: 1500,
                                         widthInches: 10, heightInches: 7.5)
        XCTAssertFalse(cameraPage(nominal).printsAtRealSize)
        // Not yet cut out (no scale): treated as not real size, so a copy is fitted to the page.
        XCTAssertFalse(cameraPage(nil).printsAtRealSize)
    }

    private func scannerPage() -> ScannedPage {
        ScannedPage(image: RgbaImage.filled(width: 10, height: 10, r: 255, g: 255, b: 255).makeCGImage()!,
                    dpi: 300, colorMode: .color)
    }

    private func cameraPage(_ scale: CaptureScaleResult?) -> ScannedPage {
        let quad = Quad(topLeft: CGPoint(x: 0, y: 0), topRight: CGPoint(x: 100, y: 0),
                        bottomRight: CGPoint(x: 100, y: 100), bottomLeft: CGPoint(x: 0, y: 100))
        let facts = CaptureFacts(quad: quad, sourceWidth: 100, sourceHeight: 100, scale: scale)
        return scannerPage().withCapture(facts)
    }
}
