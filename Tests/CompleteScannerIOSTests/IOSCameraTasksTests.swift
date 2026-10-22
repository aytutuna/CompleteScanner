#if os(iOS)
import CoreGraphics
import Foundation
import UIKit
import XCTest
@testable import CompleteScannerIOS
@testable import CompleteScannerKit

// The remaining tasks on the iPhone (I14), without a screen: every task the phone offers has the camera's
// words; the PDF's Archive and Password switches exclude each other; the password sheet's form (a
// mismatch, the strength, Save and Cancel) and the prompt behind `AppState.askPDFPassword` (a protected PDF
// saved with the password typed, nothing saved after Cancel); Quick scan's screen model; the page strip's
// side, book and document labels; and the two UI tests' imports (a two-page PDF under the two-sided task
// saving one PDF with both sides, and a PDF with a patch-code sheet between two pages under Separate
// documents saving two PDFs), here through the import session.

/// The PDF of `pages` at Letter size, each picture drawn over the whole page.
private func letterPDF(_ pages: [CGImage]) throws -> Data {
    let data = NSMutableData()
    let consumer: CGDataConsumer = try XCTUnwrap(CGDataConsumer(data: data as CFMutableData))
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    let context: CGContext = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
    for page in pages {
        context.beginPDFPage(nil)
        context.draw(page, in: box)
        context.endPDFPage()
    }
    context.closePDF()
    return data as Data
}

/// A printed page at 60 dpi on Letter paper: grey bars where lines of text would be, a few to a block.
private func printedLetterPage(blocks: Int) throws -> CGImage {
    let ctx: CGContext = ImportTestSupport.context(width: 510, height: 660)
    ctx.setFillColor(CGColor(srgbRed: 0.97, green: 0.97, blue: 0.96, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: 510, height: 660))
    ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.2, blue: 0.22, alpha: 1))
    var line: Int = 0
    while line < blocks * 6 {
        let y: Int = 600 - 60 * (line / 6) - 8 * (line % 6)
        ctx.fill(CGRect(x: 60, y: y, width: line % 6 == 5 ? 240 : 390, height: 4))
        line += 1
    }
    return try XCTUnwrap(ctx.makeImage())
}

/// The number of pages of the PDF at `url`; 0 when it cannot be read.
private func pageCount(_ url: URL) -> Int {
    guard let document = CGPDFDocument(url as CFURL) else { return 0 }
    return document.numberOfPages
}

final class IOSCameraTasksTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = try ImportTestSupport.makeFolder("IOSCameraTasksTests")
    }

    override func tearDown() async throws {
        // The settings are written 0.4 s after they change: let that write land before the folder goes.
        try await Task.sleep(nanoseconds: 600_000_000)
        try? FileManager.default.removeItem(at: folder)
    }

    private var saved: URL { folder.appendingPathComponent("Saved", isDirectory: true) }

    /// An AppState with no scanner set up for `task`, saving into `folder`/Saved without text recognition.
    @MainActor
    private func makeState(_ task: ScanTask) -> AppState {
        let state: AppState = ImportTestSupport.makeState(in: folder)
        XCTAssertTrue(state.startTask(task))
        state.settings.pdfSearchable = false
        state.settings.destinationPath = saved.path
        return state
    }

    // MARK: The camera's words

    func test_everyTaskThePhoneOffers_hasTheCamerasWords() {
        var offered: Int = 0
        for task in ScanTask.allCases where IOSShell.offers(task) {
            offered += 1
            for frontsFirst in [false, true] {
                var options = TaskOptions()
                options.cameraFrontsFirst = frontsFirst
                options.cameraSpreads = frontsFirst
                let text: CameraStepText = CameraTaskCatalog.text(task, options: options)
                XCTAssertFalse(text.prompt.isEmpty, task.rawValue)
                XCTAssertFalse(text.help.isEmpty, task.rawValue)
                XCTAssertNotEqual(text.prompt, TaskCatalog.definition(task).steps.first?.prompt, task.rawValue)
                let current: CameraStepText? = CameraTaskCatalog.current(task, options: options, sides: nil, newDocument: false)
                XCTAssertEqual(current, text, task.rawValue)
            }
        }
        XCTAssertEqual(offered, ScanTask.allCases.count)
    }

    // MARK: Archive and Password

    func test_archiveAndPassword_excludeEachOther() {
        var output = OutputOptions()
        XCTAssertFalse(IOSPDFOptions.archivalShown(output))
        XCTAssertNil(IOSPDFOptions.archivalReason(output))
        XCTAssertNil(IOSPDFOptions.protectReason(output))
        output = IOSPDFOptions.settingArchival(true, in: output)
        XCTAssertTrue(IOSPDFOptions.archivalShown(output))
        XCTAssertEqual(IOSPDFOptions.protectReason(output), PDFProtection.notWithArchivalReason)
        // The password turns archival off; turning it off again leaves archival off.
        output = IOSPDFOptions.settingProtect(true, in: output)
        XCTAssertTrue(output.protect)
        XCTAssertFalse(output.archival)
        XCTAssertEqual(IOSPDFOptions.archivalReason(output), PDFA.notWithPasswordReason)
        XCTAssertNil(IOSPDFOptions.protectReason(output))
        XCTAssertFalse(IOSPDFOptions.settingArchival(true, in: output).archival)
        output = IOSPDFOptions.settingProtect(false, in: output)
        XCTAssertFalse(output.protect)
        XCTAssertFalse(output.archival)
        // A settings file with both on shows the password.
        var both = OutputOptions()
        both.archival = true
        both.protect = true
        XCTAssertFalse(IOSPDFOptions.archivalShown(both))
    }

    @MainActor
    func test_theArchiveTask_offersThePDFsChoices_andQuickScanNone() {
        let archive: AppState = makeState(.archive)
        XCTAssertTrue(IOSShell.offersPDFOptions(archive.settings))
        XCTAssertTrue(IOSPDFOptions.archivalShown(archive.settings.output))
        XCTAssertEqual(archive.settings.output.pdfSize, .best)
        archive.settings.format = .jpeg
        XCTAssertFalse(IOSShell.offersPDFOptions(archive.settings))
        let quick: AppState = makeState(.quickScan)
        XCTAssertFalse(IOSShell.collectsPages(quick.settings))
        XCTAssertFalse(IOSShell.offersPDFOptions(quick.settings))
        XCTAssertFalse(IOSShell.capturesContinuously(quick.settings))
    }

    // MARK: The password sheet

    @MainActor
    func test_passwordForm_saysWhatIsWrong_andGivesThePasswordOnSave() throws {
        let form = IOSPasswordForm()
        XCTAssertEqual(form.strength, PasswordStrength.none)
        XCTAssertEqual(form.strengthLabel, "")
        XCTAssertFalse(form.canSave)
        form.password = "abc"
        XCTAssertEqual(form.strength, .weak)
        XCTAssertEqual(form.strengthSegments, PDFProtection.strengthSegments(.weak))
        form.password = "Tr0ub4dor & 3 Horses!"
        XCTAssertEqual(form.strength, .strong)
        XCTAssertEqual(form.strengthLabel, "Strong")
        // A shorter second box says nothing yet; a full one that differs says so.
        form.confirmation = "Tr0ub"
        form.refresh()
        XCTAssertNil(form.shownProblem)
        form.confirmationLeft()
        XCTAssertEqual(form.shownProblem, "Passwords don't match")
        form.confirmation = "Tr0ub4dor & 3 Horses?"
        form.refresh()
        XCTAssertEqual(form.shownProblem, "Passwords don't match")
        XCTAssertFalse(form.save())
        XCTAssertNil(form.protection)
        form.confirmation = "Tr0ub4dor & 3 Horses!"
        form.refresh()
        XCTAssertNil(form.shownProblem)
        form.allowPrinting = false
        XCTAssertTrue(form.save())
        let given: PDFProtection = try XCTUnwrap(form.protection)
        XCTAssertFalse(given.allowPrinting)
        XCTAssertTrue(given.allowCopying)
        // Nothing typed is kept.
        XCTAssertEqual(form.password, "")
        XCTAssertEqual(form.confirmation, "")
        given.dispose()
    }

    @MainActor
    func test_passwordPrompt_cancelGivesNothing_saveGivesThePassword() async throws {
        let cancelled = IOSPasswordPrompt(present: { (form, finish) in
            form.password = "Tr0ub4dor & 3 Horses!"
            finish(false)
        })
        let none: PDFProtection? = await cancelled.ask()
        XCTAssertNil(none)
        XCTAssertFalse(cancelled.isAsking)

        var shown: IOSPasswordForm?
        let typed = IOSPasswordPrompt(present: { (form, finish) in
            shown = form
            form.password = "Tr0ub4dor & 3 Horses!"
            form.confirmation = "Tr0ub4dor & 3 Horses!"
            XCTAssertTrue(form.save())
            finish(true)
            // A second answer changes nothing.
            finish(false)
        })
        let given: PDFProtection? = await typed.ask()
        XCTAssertNotNil(given)
        XCTAssertEqual(shown?.password, "")
        given?.dispose()
    }

    @MainActor
    func test_aProtectedSave_asksThePrompt_andCancelSavesNothing() async throws {
        var answers: [Bool] = [false, true]
        let prompt = IOSPasswordPrompt(present: { (form, finish) in
            let save: Bool = answers.removeFirst()
            if save {
                form.password = "Tr0ub4dor & 3 Horses!"
                form.confirmation = "Tr0ub4dor & 3 Horses!"
                _ = form.save()
            }
            finish(save)
        })
        let actions = IOSFileActions(pasteboard: nil, openSystemURL: { (_: URL) -> Void in },
                                     mailAvailable: { () -> Bool in false })
        let made: AppState = AppState.makeForIOS(options: IOSLaunchOptions(demoScannerOnly: true), fileActions: actions,
                                                 networkScanners: nil, passwordPrompt: prompt)
        XCTAssertNotNil(made.askPDFPassword)
        XCTAssertEqual(made.platform, .ios)
        XCTAssertNil(AppState.makeForIOS(options: IOSLaunchOptions(demoScannerOnly: true), fileActions: actions).askPDFPassword)

        let state: AppState = makeState(.document)
        state.askPDFPassword = made.askPDFPassword
        state.settings.output = IOSPDFOptions.settingProtect(true, in: state.settings.output)
        let page = ScannedPage(image: try printedLetterPage(blocks: 3), dpi: 60, colorMode: .color)
        XCTAssertTrue(state.ingest([page], source: .photo))
        try await ImportTestSupport.waitUntil(timeout: 60) { !state.isBusy }
        state.savePDF()
        try await ImportTestSupport.waitUntil(timeout: 60) { !state.isBusy }
        XCTAssertEqual(state.statusMessage, PDFProtection.notSavedMessage)
        XCTAssertEqual(state.scannedPages.count, 1)
        state.savePDF()
        try await ImportTestSupport.waitUntil(timeout: 120) { !state.isBusy }
        XCTAssertNil(state.errorMessage)
        let pdf: URL = try XCTUnwrap(state.lastSavedURLs.first)
        let document: CGPDFDocument = try XCTUnwrap(CGPDFDocument(pdf as CFURL))
        XCTAssertTrue(document.isEncrypted)
        XCTAssertTrue(answers.isEmpty)
    }

    // MARK: Quick scan

    @MainActor
    func test_quickScanModel_showsTheShot_savesAJPEG_andDiscards() async throws {
        let state: AppState = makeState(.quickScan)
        let model = IOSQuickScanModel(state: state, liveTextSupported: { () -> Bool in true })
        XCTAssertFalse(model.isShown)
        XCTAssertFalse(model.offersLiveText)
        XCTAssertFalse(model.canAct)
        XCTAssertEqual(model.saveLabel, "Save JPEG")
        let page = ScannedPage(image: try printedLetterPage(blocks: 2), dpi: 60, colorMode: .color)
        XCTAssertTrue(state.ingest([page], source: .photo))
        try await ImportTestSupport.waitUntil(timeout: 60) { !state.isBusy }
        XCTAssertTrue(model.isShown)
        XCTAssertTrue(model.offersLiveText)
        XCTAssertTrue(model.canAct)
        XCTAssertNotNil(model.image)
        XCTAssertFalse(IOSQuickScanModel(state: state, liveTextSupported: { () -> Bool in false }).offersLiveText)
        model.save()
        try await ImportTestSupport.waitUntil(timeout: 60) { !state.isBusy }
        XCTAssertFalse(model.isShown)
        XCTAssertEqual(state.lastSavedURLs.first?.pathExtension, "jpg")

        XCTAssertTrue(state.ingest([page], source: .photo))
        try await ImportTestSupport.waitUntil(timeout: 60) { !state.isBusy }
        model.discard()
        XCTAssertFalse(model.isShown)
        XCTAssertEqual(state.lastSavedURLs.count, 1)
    }

    // MARK: The page strip

    func test_pageStrip_namesTheSides_theSpreads_andTheDocuments() throws {
        let picture: CGImage = try printedLetterPage(blocks: 1)
        let front = ScannedPage(image: picture, dpi: 60, colorMode: .color).withSide(.front, sheetIndex: 0)
        let back = ScannedPage(image: picture, dpi: 60, colorMode: .color).withSide(.back, sheetIndex: 0)
        let next = ScannedPage(image: picture, dpi: 60, colorMode: .color).withDocumentBreak(.split)
        let cells: [PageStripCell] = PageStripCell.cells([front, back, next])
        XCTAssertEqual(cells.map(\.number), [1, 2, 3])
        XCTAssertEqual(cells.map(\.badge), ["1 \u{00B7} front", "1 \u{00B7} back", nil])
        XCTAssertEqual(cells[1].accessibilityLabel, "Page 2, Sheet 1, back")
        XCTAssertEqual(cells[0].divider, "Document 1")
        XCTAssertNil(cells[1].divider)
        XCTAssertEqual(cells[2].divider, "Document 2")
        XCTAssertEqual(cells[2].accessibilityLabel, "Page 3, Document 2")
        var left = ScannedPage(image: picture, dpi: 60, colorMode: .color)
        left.spread = SpreadPart(spreadID: UUID(), part: 0, gutter: nil)
        let book: [PageStripCell] = PageStripCell.cells([left])
        XCTAssertEqual(book.first?.badge, "1 \u{00B7} left")
        XCTAssertEqual(book.first?.spokenBadge, "Spread 1, left page")
    }

    // MARK: The UI tests' imports, without a screen

    @MainActor
    func test_aTwoPagePDF_underTheTwoSidedTask_savesOnePDFWithBothSides() async throws {
        let state: AppState = makeState(.twoSided)
        let session = IOSImportSession(state: state)
        let pdf: Data = try letterPDF([try printedLetterPage(blocks: 3), try printedLetterPage(blocks: 2)])
        let outcome: IOSImportOutcome = await session.importItems([IOSImportItem(name: "two-sided.pdf", data: pdf, kind: .pdf)])
        XCTAssertEqual(outcome.added, 2)
        try await ImportTestSupport.waitUntil(timeout: 60) { !state.isBusy }
        XCTAssertEqual(state.scannedPages.map(\.side), [.front, .back])
        XCTAssertEqual(state.scannedPages.map(\.sheetIndex), [0, 0])
        XCTAssertEqual(PageStripCell.cells(state.scannedPages, options: state.settings.document).map(\.badge),
                       ["1 \u{00B7} front", "1 \u{00B7} back"])
        state.savePDF()
        try await ImportTestSupport.waitUntil(timeout: 120) { !state.isBusy }
        XCTAssertNil(state.errorMessage)
        XCTAssertEqual(state.lastSavedURLs.count, 1)
        XCTAssertEqual(pageCount(try XCTUnwrap(state.lastSavedURLs.first)), 2)
    }

    @MainActor
    func test_aPatchCodeSheetBetweenTwoPages_underSeparateDocuments_savesTwoPDFs() async throws {
        let state: AppState = makeState(.batch)
        let session = IOSImportSession(state: state)
        let sheet: CGImage = try XCTUnwrap(PatchCodeDetector.renderSheet(SeparatorSheet.code, widthInches: 8.5,
                                                                        heightInches: 11, dpi: 60).toRgba().makeCGImage())
        let pdf: Data = try letterPDF([try printedLetterPage(blocks: 3), sheet, try printedLetterPage(blocks: 2)])
        let outcome: IOSImportOutcome = await session.importItems([IOSImportItem(name: "batch.pdf", data: pdf, kind: .pdf)])
        XCTAssertEqual(outcome.added, 3)
        try await ImportTestSupport.waitUntil(timeout: 60) { !state.isBusy }
        XCTAssertEqual(state.scannedPages[1].patch, .patchT)
        XCTAssertEqual(state.queueSavePlan.documents.count, 2)
        state.savePDF()
        try await ImportTestSupport.waitUntil(timeout: 120) { !state.isBusy }
        XCTAssertNil(state.errorMessage)
        XCTAssertEqual(state.lastSavedURLs.count, 2)
        for url in state.lastSavedURLs {
            XCTAssertEqual(pageCount(url), 1)
        }
    }
}
#endif
