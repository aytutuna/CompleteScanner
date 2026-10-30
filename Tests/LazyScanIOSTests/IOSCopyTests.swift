#if os(iOS)
import CoreGraphics
import Foundation
import UniformTypeIdentifiers
import XCTest
@testable import LazyScanIOS
@testable import LazyScanKit

// The photocopy on the iPhone (I16), without a screen: a page brought in is held, not printed; Print prints
// it and it stays for another copy, Copy again goes to the printer picked last, a cancelled print records
// nothing; a camera page of no known size is fitted to the page; Discard and another task let it go; and
// the copy screen's model. Nothing here presents the print UI.

/// A printer that prints whatever it is sent (or is cancelled, `answer`), counting what came through
/// Copy again.
@MainActor
private final class CopyPrintService: PrintService {
    var answer = true
    /// Thrown by every print when set, as AirPrint reports a printer that is offline.
    var failure: Error?
    private(set) var jobs: [PrintJob] = []
    private(set) var againCount = 0

    var printerNames: [String] { ["Office Printer"] }

    var defaultPrinterName: String? { "Office Printer" }

    func setup(printerName: String?, requestedPaper: PaperSize?) -> PrinterSetup? {
        PrinterSetup(printerName: "Office Printer",
                     paper: PrinterPaper.make(paper: CGSize(width: 8.5, height: 11), printable: nil))
    }

    func print(_ document: Data, job: PrintJob) async throws -> Bool {
        if let failure { throw failure }
        if answer { jobs.append(job) }
        return answer
    }

    func printAgain(_ document: Data, job: PrintJob) async throws -> Bool {
        againCount += 1
        return try await print(document, job: job)
    }
}

/// A white page `inches` square at 100 dpi.
private func page(inches: Int) -> ScannedPage {
    let image: CGImage = RgbaImage.filled(width: inches * 100, height: inches * 100, r: 255, g: 255, b: 255).makeCGImage()!
    return ScannedPage(image: image, dpi: 100, colorMode: .color)
}

final class IOSCopyTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = try ImportTestSupport.makeFolder("IOSCopyTests")
    }

    override func tearDown() async throws {
        // The settings are written 0.4 s after they change: let that write land before the folder goes.
        try await Task.sleep(nanoseconds: 600_000_000)
        try? FileManager.default.removeItem(at: folder)
    }

    /// The iPhone's AppState set up for the photocopy, printing on `printer`.
    @MainActor
    private func makeState(_ printer: CopyPrintService) -> AppState {
        let state = AppState(backends: [], presetStore: PresetStore(directory: folder),
                             fileActions: IOSFileActions(pasteboard: nil, openSystemURL: { (_: URL) -> Void in }),
                             printService: printer,
                             orientationScorer: ImportTestScorer(), barcodeReader: ImportTestBarcodes(),
                             files: AppStateFiles.all(in: folder))
        state.platform = .ios
        state.settings.destinationPath = folder.appendingPathComponent("Saved", isDirectory: true).path
        XCTAssertTrue(state.startTask(.copy))
        return state
    }

    @MainActor
    private func idle(_ state: AppState) async throws {
        try await ImportTestSupport.waitUntil(timeout: 60) { !state.isBusy }
    }

    @MainActor
    func test_aPageBroughtIn_isHeld_thenPrinted_andKeptForAnotherCopy() async throws {
        let printer = CopyPrintService()
        let state: AppState = makeState(printer)
        state.setCopyCount(2)
        XCTAssertTrue(state.ingest([page(inches: 4)], source: .photo))
        try await idle(state)
        XCTAssertEqual(state.copyPages.count, 1)
        XCTAssertFalse(state.canIngest)
        XCTAssertFalse(state.copyNeedsFit)
        XCTAssertTrue(printer.jobs.isEmpty)
        XCTAssertTrue(state.scannedPages.isEmpty)
        XCTAssertTrue(state.scanHistory.isEmpty)

        // Cancelled in the picker: nothing printed, nothing recorded.
        printer.answer = false
        state.printHeldCopy()
        try await idle(state)
        XCTAssertEqual(state.statusMessage, "Printing cancelled.")
        XCTAssertTrue(state.scanHistory.isEmpty)

        printer.answer = true
        state.printHeldCopy()
        try await idle(state)
        XCTAssertNil(state.errorMessage)
        XCTAssertEqual(printer.jobs.count, 1)
        XCTAssertEqual(printer.jobs.first?.copies, 2)
        XCTAssertEqual(state.statusMessage, PrintText.sent(pageCount: 1, copies: 2, printerName: "Office Printer"))
        XCTAssertEqual(state.scanHistory.count, 1)
        XCTAssertEqual(state.copyPages.count, 1)

        state.printHeldCopyAgain()
        try await idle(state)
        XCTAssertEqual(printer.againCount, 1)
        XCTAssertEqual(printer.jobs.count, 2)
        // In the history once, however often it prints.
        XCTAssertEqual(state.scanHistory.count, 1)

        state.discardHeldCopy()
        XCTAssertTrue(state.copyPages.isEmpty)
        XCTAssertTrue(state.canIngest)
    }

    @MainActor
    func test_printFromSave_holdsTheQueuesPages_atFullSize_andClosingKeepsTheQueue() async throws {
        let printer = CopyPrintService()
        let state: AppState = makeState(printer)
        XCTAssertTrue(state.startTask(.document))
        XCTAssertTrue(state.ingest([page(inches: 20)], source: .photo))
        try await idle(state)
        XCTAssertEqual(state.scannedPages.count, 1)
        XCTAssertTrue(state.copyPages.isEmpty)
        let queued: ScannedPage = try XCTUnwrap(state.scannedPages.first)

        state.printQueueAsCopy()
        try await idle(state)
        XCTAssertNil(state.errorMessage)
        XCTAssertEqual(state.copyPages.count, 1)
        XCTAssertTrue(state.copyIsOfQueue)
        XCTAssertEqual(state.activeTask, .document)
        XCTAssertEqual(state.scannedPages.count, 1)
        // The full pixels, not the strip's preview of a spooled page.
        let held: ScannedPage = try XCTUnwrap(state.copyPages.first)
        let fullWidth: CGFloat = queued.fullPixelSize?.width ?? CGFloat(queued.image.width)
        XCTAssertEqual(CGFloat(held.image.width), fullWidth)

        // The copy screen's own choices change the settings; the copy stays held outside the copy task.
        state.setCopyCount(2)
        // Also save a PDF is left to the queue's own Save: no second file of the same pages.
        state.setCopyAlsoSavePdf(true)
        XCTAssertEqual(state.copyPages.count, 1)
        state.printHeldCopy()
        try await idle(state)
        XCTAssertNil(state.errorMessage)
        XCTAssertEqual(printer.jobs.count, 1)
        XCTAssertEqual(printer.jobs.first?.copies, 2)
        XCTAssertTrue(state.lastSavedURLs.isEmpty)

        state.discardHeldCopy()
        XCTAssertTrue(state.copyPages.isEmpty)
        XCTAssertFalse(state.copyIsOfQueue)
        XCTAssertEqual(state.scannedPages.count, 1)
        XCTAssertEqual(state.statusMessage, "1 page in the queue.")
    }

    @MainActor
    func test_aCameraPageOfNoKnownSize_isFittedToThePage() async throws {
        let printer = CopyPrintService()
        let state: AppState = makeState(printer)
        let nominal = CaptureScaleResult(basis: .nominal, size: nil, dpi: 100, pixelWidth: 1200, pixelHeight: 1200,
                                         widthInches: 12, heightInches: 12)
        let quad = Quad(topLeft: CGPoint(x: 0, y: 0), topRight: CGPoint(x: 1200, y: 0),
                        bottomRight: CGPoint(x: 1200, y: 1200), bottomLeft: CGPoint(x: 0, y: 1200))
        let shot: ScannedPage = page(inches: 12)
            .withCapture(CaptureFacts(quad: quad, sourceWidth: 1200, sourceHeight: 1200, scale: nominal))
        XCTAssertTrue(state.ingest([shot], source: .photo))
        try await idle(state)
        XCTAssertTrue(state.copyNeedsFit)
        XCTAssertFalse(state.settings.taskOptions.copyFitToPage)

        state.printHeldCopy()
        try await idle(state)
        // At real size the 12-inch page would lose its edges to Letter paper, and the status would say so.
        let paper = PrinterPaper.make(paper: CGSize(width: 8.5, height: 11), printable: nil)
        let real = PrintLayout.place(pixelWidth: 1200, pixelHeight: 1200, dpi: 100, on: paper, mode: .actualSize,
                                     align: .paperOrigin)
        XCTAssertNotNil(PrintLayout.clipWarning(real, paper: paper.paper))
        XCTAssertEqual(state.statusMessage, PrintText.sent(pageCount: 1, copies: 1, printerName: "Office Printer"))
    }

    @MainActor
    func test_aFailedPrint_withNoPassword_keepsTheCopyHeld_notQueued() async throws {
        let printer = CopyPrintService()
        let state: AppState = makeState(printer)
        state.settings.output.protect = true
        state.setCopyAlsoSavePdf(true)
        XCTAssertTrue(state.ingest([page(inches: 4)], source: .photo))
        try await idle(state)

        printer.failure = PrintError.failed("Could not print on Office Printer: offline")
        state.printHeldCopy()
        try await idle(state)
        state.printHeldCopy()
        try await idle(state)
        XCTAssertNotNil(state.errorMessage)
        XCTAssertEqual(state.copyPages.count, 1)
        XCTAssertTrue(state.scannedPages.isEmpty)
        XCTAssertTrue(state.scanHistory.isEmpty)
    }

    @MainActor
    func test_aPrintedCopy_isRecorded_whenItsPDFCannotBeWritten() async throws {
        let printer = CopyPrintService()
        let state: AppState = makeState(printer)
        // A file where the save folder should be: the PDF cannot be written.
        let blocked: URL = folder.appendingPathComponent("blocked")
        try Data().write(to: blocked)
        state.settings.destinationPath = blocked.path
        state.setCopyAlsoSavePdf(true)
        XCTAssertTrue(state.ingest([page(inches: 4)], source: .photo))
        try await idle(state)

        state.printHeldCopy()
        try await idle(state)
        XCTAssertEqual(printer.jobs.count, 1)
        XCTAssertNotNil(state.errorMessage)
        XCTAssertEqual(state.scanHistory.count, 1)
    }

    @MainActor
    func test_aWholePhoto_isMeasured_soOneOfNoPaperShapeIsFitted() async throws {
        let state: AppState = makeState(CopyPrintService())
        let corners: [CGPoint] = [CGPoint(x: 100, y: 100), CGPoint(x: 400, y: 100), CGPoint(x: 400, y: 400),
                                  CGPoint(x: 100, y: 400)]
        let found = IOSFoundPage(corners: Quad(topLeft: corners[0], topRight: corners[1], bottomRight: corners[2],
                                               bottomLeft: corners[3]),
                                 reason: .unsure, byModel: false)
        let importer = IOSImportSession(state: state, finder: { (_: RgbaImage) -> IOSFoundPage in found })
        // A square photo: no paper has its shape.
        let data: Data = ImportTestSupport.file(UTType.png,
                                                images: [ImportTestSupport.sheetPhoto(width: 500, height: 500, corners: corners)])
        let importing: Task<IOSImportOutcome, Never> = Task { @MainActor in
            await importer.importItems([IOSImportItem(name: "square.png", data: data, kind: .image)])
        }
        try await ImportTestSupport.waitUntil(timeout: 60) { importer.cornerRequest != nil }
        importer.answer(PhotoCornersAnswer(choice: .wholePhoto))
        let outcome: IOSImportOutcome = await importing.value
        XCTAssertEqual(outcome.added, 1)
        try await idle(state)
        let held: ScannedPage = try XCTUnwrap(state.copyPages.first)
        XCTAssertNotNil(held.capture)
        XCTAssertFalse(held.printsAtRealSize)
        XCTAssertTrue(state.copyNeedsFit)
    }

    @MainActor
    func test_anotherTask_dropsTheHeldCopy() async throws {
        let printer = CopyPrintService()
        let state: AppState = makeState(printer)
        XCTAssertTrue(state.ingest([page(inches: 4)], source: .photo))
        try await idle(state)
        XCTAssertFalse(state.copyPages.isEmpty)
        XCTAssertTrue(state.startTask(.document))
        XCTAssertTrue(state.copyPages.isEmpty)
        XCTAssertTrue(state.canIngest)
        XCTAssertTrue(printer.jobs.isEmpty)
    }

    @MainActor
    func test_copyModel_namesThePrinterPickedLast_andKeepsTheCopiesInRange() async throws {
        let state: AppState = makeState(CopyPrintService())
        // Not the AirPrint service: no printer picked.
        XCTAssertNil(IOSCopyModel(state: state).printerName)
        let unpicked = IOSCopyModel(state: state, pickedPrinter: { () -> String? in nil })
        XCTAssertEqual(unpicked.printerLine, IOSCopyText.noPrinterYet)
        XCTAssertFalse(unpicked.offersCopyAgain)
        let model = IOSCopyModel(state: state, pickedPrinter: { () -> String? in "Office Printer" })
        XCTAssertEqual(model.printerLine, "Prints on Office Printer")
        XCTAssertTrue(model.offersCopyAgain)
        XCTAssertFalse(model.isShown)
        XCTAssertFalse(model.canAct)

        model.setCopies(500)
        XCTAssertEqual(model.copies, PrintCopies.maxCount)
        model.setCopies(0)
        XCTAssertEqual(model.copies, 1)
        model.setFitsToPage(true)
        XCTAssertTrue(model.fitsToPage)
        XCTAssertFalse(model.fitIsForced)

        XCTAssertTrue(state.ingest([page(inches: 2), page(inches: 2)], source: .photo))
        try await idle(state)
        XCTAssertTrue(model.isShown)
        XCTAssertEqual(model.pageCountLine, "2 pages")
        XCTAssertNotNil(model.image)
        model.discard()
        XCTAssertFalse(model.isShown)
        XCTAssertEqual(state.statusMessage, "Copy discarded.")
    }
}
#endif
