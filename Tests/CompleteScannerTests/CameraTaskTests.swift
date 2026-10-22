import CoreGraphics
import Foundation
import XCTest
@testable import CompleteScannerKit

// The camera's own ways through the tasks (I14, Swift only: the Windows app takes no camera shots): the
// camera's words for every task (`CameraTaskCatalog`), the two-sided steps (`CameraSides`: flip & capture,
// and fronts first then backs through the manual interleave), Separate documents' New document, Quick
// scan's page held for its screen, the Email task's mail route and a book's whole spread, through the
// app's state as the iPhone brings photos in (`AppState.ingest` from `.photo`). The camera arrangement
// itself (`ScanArrangement.cameraFront`, `.cameraBack`) is checked with its C# twin in PageProcessorTests
// and DocumentSidesTests.

/// Text recognition that cannot run, so nothing is turned.
private struct CameraTaskScorer: OrientationScorer {
    var isAvailable: Bool { false }

    func score(_ image: RgbaImage) throws -> OrientationScore {
        OrientationScore.none
    }
}

/// Barcode reading that cannot run.
private struct CameraTaskBarcodes: BarcodeReader {
    var isAvailable: Bool { false }

    func read(_ image: GrayImage) throws -> [BarcodeReading] {
        []
    }
}

/// Records what the app asks of the system; Mail can be set up or not (`canCompose`).
@MainActor
private final class CameraTaskFileActions: FileActionService {
    var canCompose: Bool = false
    private(set) var shared: [[URL]] = []
    private(set) var composed: [[URL]] = []
    private(set) var copiedTexts: [String] = []

    func open(_ url: URL) throws {}
    func openWith(_ url: URL) throws {}
    func reveal(_ urls: [URL]) {}

    func sendProbe(for urls: [URL]) -> SendProbe {
        SendProbe(canCompose: canCompose, canShare: true)
    }

    func share(_ urls: [URL], title: String) throws {
        shared.append(urls)
    }

    func composeEmail(_ urls: [URL]) throws {
        composed.append(urls)
    }

    func copy(_ content: ClipboardContent) throws {}

    func copyText(_ text: String) throws {
        copiedTexts.append(text)
    }
}

/// Waits on the main actor until `condition` holds, failing after `timeout` seconds.
@MainActor
private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool,
                       file: StaticString = #filePath, line: UInt = #line) async throws {
    let deadline: Date = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline {
            XCTFail("Timed out after \(timeout) s", file: file, line: line)
            return
        }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
}

/// The words of `text`, as the less-text budgets count them.
private func wordCount(_ text: String) -> Int {
    var count: Int = 0
    for word in text.split(separator: " ") where !word.isEmpty {
        count += 1
    }
    return count
}

/// A printed page as a photo brings it in (an imported PDF's page: nothing to cut out).
private func printedPage() throws -> ScannedPage {
    let image: CGImage = try XCTUnwrap(TestPages.singlePageAcross().toRgba().makeCGImage())
    var page: ScannedPage = ScannedPage(image: image, dpi: 100, colorMode: .color)
    page.source = .photo
    return page
}

/// The number of pages of the PDF at `url`; 0 when it cannot be read.
private func pdfPageCount(_ url: URL) -> Int {
    guard let document = CGPDFDocument(url as CFURL) else { return 0 }
    return document.numberOfPages
}

final class CameraTaskTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("CameraTaskTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        // The settings are written 0.4 s after they change: let that write land before the folder goes.
        try await Task.sleep(nanoseconds: 600_000_000)
        try? FileManager.default.removeItem(at: folder)
    }

    private var saved: URL { folder.appendingPathComponent("Saved", isDirectory: true) }

    private func savedFiles() -> [String] {
        let names: [String] = (try? FileManager.default.contentsOfDirectory(atPath: saved.path)) ?? []
        var visible: [String] = []
        for name in names where !name.hasPrefix(".") {
            visible.append(name)
        }
        return visible.sorted()
    }

    /// An AppState with no scanner, its files in `folder`, set up for `task` with `options`, saving into
    /// `folder`/Saved.
    @MainActor
    private func makeState(_ task: ScanTask, options: TaskOptions = TaskOptions(),
                           actions: CameraTaskFileActions? = nil) -> AppState {
        let state = AppState(backends: [], presetStore: PresetStore(directory: folder), fileActions: actions,
                             orientationScorer: CameraTaskScorer(), barcodeReader: CameraTaskBarcodes(),
                             files: AppStateFiles.all(in: folder))
        var settings: ScanSettings = TaskCatalog.apply(task, to: ScanSettings())
        settings.taskOptions = options
        settings.pdfSearchable = false
        settings.destinationPath = saved.path
        state.settings = settings
        return state
    }

    /// Brings `page` in from a photo and waits until it is in.
    @MainActor
    private func bringIn(_ state: AppState, _ page: ScannedPage) async throws {
        XCTAssertTrue(state.ingest([page], source: .photo))
        try await waitUntil(timeout: 60) { !state.isBusy }
        XCTAssertNil(state.errorMessage)
    }

    // MARK: The camera's words

    func test_catalog_hasShortWordsForEveryTask_inEitherWay() {
        var ways: [TaskOptions] = [TaskOptions()]
        var other = TaskOptions()
        other.cameraFrontsFirst = true
        other.cameraSpreads = true
        ways.append(other)
        for options in ways {
            for task in ScanTask.allCases {
                let text: CameraStepText = CameraTaskCatalog.text(task, options: options)
                XCTAssertFalse(text.prompt.isEmpty, task.rawValue)
                XCTAssertFalse(text.help.isEmpty, task.rawValue)
                XCTAssertLessThanOrEqual(wordCount(text.prompt), 10, text.prompt)
                XCTAssertLessThanOrEqual(wordCount(text.help), 25, text.help)
                XCTAssertNotEqual(text.prompt, text.help)
                // The camera's words, not the glass's.
                XCTAssertFalse(text.prompt.lowercased().contains("glass"), text.prompt)
                XCTAssertFalse(text.prompt.lowercased().contains("feeder"), text.prompt)
            }
        }
        XCTAssertNotEqual(CameraTaskCatalog.text(.twoSided), CameraTaskCatalog.text(.twoSided, options: other))
        XCTAssertNotEqual(CameraTaskCatalog.text(.book), CameraTaskCatalog.text(.book, options: other))
        let lines: [String] = [CameraTaskCatalog.turnOverPrompt, CameraTaskCatalog.nextFrontPrompt,
                               CameraTaskCatalog.backsPrompt, CameraTaskCatalog.newDocumentPrompt]
        for line in lines {
            XCTAssertLessThanOrEqual(wordCount(line), 10, line)
        }
        let labels: [String] = [CameraTaskCatalog.noBackLabel, CameraTaskCatalog.startBacksLabel,
                                CameraTaskCatalog.putInOrderLabel, CameraTaskCatalog.combineLabel,
                                CameraTaskCatalog.newDocumentLabel, CameraTaskCatalog.flipLabel,
                                CameraTaskCatalog.frontsFirstLabel, CameraTaskCatalog.pageByPageLabel,
                                CameraTaskCatalog.wholeSpreadLabel, CameraTaskCatalog.separatorSheetLabel,
                                CameraTaskCatalog.patchCodeLabel, CameraTaskCatalog.qrCodeLabel]
        for label in labels {
            XCTAssertLessThanOrEqual(wordCount(label), 3, label)
        }
        XCTAssertLessThanOrEqual(wordCount(CameraTaskCatalog.separatorHint), 8)
    }

    func test_catalog_currentLine_followsTheSidesAndNewDocument() {
        let options = TaskOptions()
        XCTAssertNil(CameraTaskCatalog.current(nil, options: options, sides: nil, newDocument: false))
        var flip = CameraSides(mode: .flip)
        XCTAssertEqual(CameraTaskCatalog.current(.twoSided, options: options, sides: flip, newDocument: false),
                       CameraTaskCatalog.text(.twoSided))
        flip.took([UUID()])
        XCTAssertEqual(CameraTaskCatalog.current(.twoSided, options: options, sides: flip, newDocument: false)?.prompt,
                       CameraTaskCatalog.turnOverPrompt)
        // Once the first sheet is done, the front asked for is the next sheet's, its back taken or skipped.
        flip.took([UUID()])
        XCTAssertEqual(CameraTaskCatalog.current(.twoSided, options: options, sides: flip, newDocument: false)?.prompt,
                       CameraTaskCatalog.nextFrontPrompt)
        flip.took([UUID()])
        flip.skipBack()
        XCTAssertEqual(flip.sheet, 2)
        XCTAssertEqual(CameraTaskCatalog.current(.twoSided, options: options, sides: flip, newDocument: false)?.prompt,
                       CameraTaskCatalog.nextFrontPrompt)
        flip.reset()
        XCTAssertEqual(CameraTaskCatalog.current(.twoSided, options: options, sides: flip, newDocument: false),
                       CameraTaskCatalog.text(.twoSided))
        var frontsFirst = CameraSides(mode: .frontsFirst)
        frontsFirst.took([UUID()])
        frontsFirst.startBacks()
        XCTAssertEqual(CameraTaskCatalog.current(.twoSided, options: options, sides: frontsFirst, newDocument: false)?.prompt,
                       CameraTaskCatalog.backsPrompt)
        XCTAssertEqual(CameraTaskCatalog.current(.batch, options: options, sides: nil, newDocument: true)?.prompt,
                       CameraTaskCatalog.newDocumentPrompt)
        XCTAssertEqual(CameraTaskCatalog.current(.batch, options: options, sides: nil, newDocument: false),
                       CameraTaskCatalog.text(.batch))
    }

    // MARK: The two-sided steps

    func test_sides_flipAndCapture_alternate_andNoBackMovesOn() {
        var sides = CameraSides(mode: .flip)
        XCTAssertEqual(CameraSides.mode(TaskOptions()), .flip)
        XCTAssertEqual(sides.arrangement, .cameraFront)
        XCTAssertEqual(sides.sheetForNext, 0)
        XCTAssertFalse(sides.canSkipBack)
        sides.took([UUID()])
        XCTAssertEqual(sides.next, .back)
        XCTAssertEqual(sides.arrangement, .cameraBack)
        XCTAssertEqual(sides.sheetForNext, 0)
        sides.took([UUID()])
        XCTAssertEqual(sides.next, .front)
        XCTAssertEqual(sides.sheetForNext, 1)
        sides.took([UUID()])
        XCTAssertTrue(sides.canSkipBack)
        sides.skipBack()
        XCTAssertEqual(sides.next, .front)
        XCTAssertEqual(sides.sheetForNext, 2)
        // Nothing taken changes nothing; fronts-first steps do not apply.
        sides.took([])
        XCTAssertEqual(sides.next, .front)
        XCTAssertFalse(sides.canStartBacks)
        XCTAssertFalse(sides.canPutInOrder)
        sides.reset()
        XCTAssertEqual(sides, CameraSides(mode: .flip))
    }

    func test_sides_frontsFirst_interleaveTheBacksFirstSheetFirst() {
        var options = TaskOptions()
        options.cameraFrontsFirst = true
        var sides = CameraSides(mode: CameraSides.mode(options))
        XCTAssertEqual(sides.mode, .frontsFirst)
        XCTAssertNil(sides.sheetForNext)
        XCTAssertFalse(sides.canStartBacks)
        let ids: [UUID] = [UUID(), UUID(), UUID(), UUID(), UUID()]
        let other: UUID = ids[0]
        let f0: UUID = ids[1]
        let f1: UUID = ids[2]
        let b0: UUID = ids[3]
        let b1: UUID = ids[4]
        sides.took([f0])
        sides.took([f1])
        XCTAssertEqual(sides.fronts, [f0, f1])
        XCTAssertEqual(sides.next, .front)
        XCTAssertTrue(sides.canStartBacks)
        sides.startBacks()
        XCTAssertEqual(sides.next, .back)
        XCTAssertFalse(sides.canPutInOrder)
        XCTAssertFalse(sides.canSkipBack)
        sides.took([b0])
        XCTAssertTrue(sides.canPutInOrder)
        XCTAssertFalse(sides.hasEveryBack)
        let early: QueueCollation = sides.collation([other, f0, f1, b0])
        XCTAssertTrue(early.interleave.mismatch)
        XCTAssertEqual(early.interleave.mismatchMessage, "2 fronts but 1 back")
        sides.took([b1])
        XCTAssertTrue(sides.hasEveryBack)
        let collation: QueueCollation = sides.collation([other, f0, f1, b0, b1])
        XCTAssertEqual(collation.order, [other, f0, b0, f1, b1])
        XCTAssertEqual(collation.positions[b0], SheetPosition(sheetIndex: 0, side: .back))
        XCTAssertEqual(collation.positions[b1], SheetPosition(sheetIndex: 1, side: .back))
        XCTAssertFalse(collation.interleave.mismatch)
    }

    func test_sides_removingTheLastShot_stepsBack_andFrontsFirstForgetsThePage() {
        var flip = CameraSides(mode: .flip)
        let front: UUID = UUID()
        let back: UUID = UUID()
        flip.took([front])
        // A page of no shot here changes nothing.
        flip.removed(UUID())
        XCTAssertEqual(flip.next, .back)
        flip.removed(front)
        XCTAssertEqual(flip.next, .front)
        XCTAssertEqual(flip.sheetForNext, 0)
        flip.took([front])
        flip.took([back])
        XCTAssertEqual(flip.sheetForNext, 1)
        flip.removed(back)
        XCTAssertEqual(flip.next, .back)
        XCTAssertEqual(flip.sheetForNext, 0)
        // Only the last shot is taken again: the front before it stays.
        flip.removed(front)
        XCTAssertEqual(flip.next, .back)
        XCTAssertEqual(flip.sheetForNext, 0)
        // A shot of two pages steps back once both are gone; a skipped back is no shot.
        let pair: [UUID] = [UUID(), UUID()]
        flip.took(pair)
        flip.removed(pair[0])
        XCTAssertEqual(flip.next, .front)
        flip.removed(pair[1])
        XCTAssertEqual(flip.next, .back)
        flip.skipBack()
        XCTAssertEqual(flip.sheetForNext, 1)
        flip.removed(pair[1])
        XCTAssertEqual(flip.next, .front)
        XCTAssertEqual(flip.sheetForNext, 1)

        var frontsFirst = CameraSides(mode: .frontsFirst)
        let f0: UUID = UUID()
        let f1: UUID = UUID()
        frontsFirst.took([f0])
        frontsFirst.took([f1])
        frontsFirst.removed(f0)
        XCTAssertEqual(frontsFirst.fronts, [f1])
    }

    @MainActor
    func test_twoSided_flipAndCapture_marksEachSide_andSavesOnePDF() async throws {
        let state: AppState = makeState(.twoSided)
        state.settings.backBinding = .shortEdge
        XCTAssertEqual(state.cameraSides?.mode, .flip)
        XCTAssertFalse(state.isTurningOverByHand)
        let page: ScannedPage = try printedPage()

        try await bringIn(state, page)
        XCTAssertEqual(state.cameraSides?.next, .back)
        try await bringIn(state, page)
        // The back stays as taken whatever the binding: the user turned the sheet over.
        XCTAssertEqual(state.scannedPages.map(\.side), [.front, .back])
        XCTAssertEqual(state.scannedPages.map(\.sheetIndex), [0, 0])
        XCTAssertEqual(state.scannedPages[1].rotationQuarterTurns, 0)
        XCTAssertEqual(state.scannedPages[1].image.width, state.scannedPages[0].image.width)

        // The next sheet has nothing on its back.
        try await bringIn(state, page)
        state.skipCameraBack()
        XCTAssertEqual(state.cameraSides?.next, .front)
        try await bringIn(state, page)
        XCTAssertEqual(state.scannedPages.map(\.side), [.front, .back, .front, .front])
        XCTAssertEqual(state.scannedPages.map(\.sheetIndex), [0, 0, 1, 2])
        XCTAssertEqual(DocumentSides.sideLabel(side: state.scannedPages[1].side, sheetIndex: state.scannedPages[1].sheetIndex),
                       "1 \u{00B7} back")

        state.savePDF()
        try await waitUntil(timeout: 120) { !state.isBusy }
        XCTAssertNil(state.errorMessage)
        XCTAssertEqual(state.lastSavedURLs.count, 1)
        let pdf: URL = try XCTUnwrap(state.lastSavedURLs.first)
        XCTAssertEqual(pdfPageCount(pdf), 4)
        // Saved: the steps start again with a front.
        XCTAssertEqual(state.cameraSides, CameraSides(mode: .flip))
    }

    @MainActor
    func test_twoSided_aRemovedShot_isTakenAgainAsTheSameSide() async throws {
        let state: AppState = makeState(.twoSided)
        let page: ScannedPage = try printedPage()
        try await bringIn(state, page)
        let blurred: UUID = try XCTUnwrap(state.scannedPages.last?.id)
        XCTAssertEqual(state.cameraSides?.next, .back)
        state.removePage(id: blurred)
        XCTAssertTrue(state.scannedPages.isEmpty)
        XCTAssertEqual(state.cameraSides?.next, .front)
        XCTAssertEqual(state.cameraSides?.sheetForNext, 0)
        try await bringIn(state, page)
        try await bringIn(state, page)
        XCTAssertEqual(state.scannedPages.map(\.side), [.front, .back])
        XCTAssertEqual(state.scannedPages.map(\.sheetIndex), [0, 0])
        XCTAssertEqual(state.cameraSides?.next, .front)
        XCTAssertEqual(state.cameraSides?.sheetForNext, 1)
    }

    @MainActor
    func test_twoSided_frontsFirst_anotherBack_clearsAMismatchSaidBefore() async throws {
        var options = TaskOptions()
        options.cameraFrontsFirst = true
        let state: AppState = makeState(.twoSided, options: options)
        let page: ScannedPage = try printedPage()
        for _ in 0..<3 {
            try await bringIn(state, page)
        }
        state.startCameraBacks()
        try await bringIn(state, page)
        state.putCameraSidesInOrder()
        XCTAssertEqual(state.sidesMismatch, "3 fronts but 1 back")
        try await bringIn(state, page)
        XCTAssertNil(state.sidesMismatch)
        // The next press says the new counts rather than combining them unseen.
        state.putCameraSidesInOrder()
        XCTAssertEqual(state.sidesMismatch, "3 fronts but 2 backs")
        XCTAssertEqual(state.cameraSides?.backs.count, 2)
    }

    @MainActor
    func test_twoSided_frontsFirst_putsTheStackInOrder_andFlagsAMismatch() async throws {
        var options = TaskOptions()
        options.cameraFrontsFirst = true
        let state: AppState = makeState(.twoSided, options: options)
        XCTAssertEqual(state.cameraSides?.mode, .frontsFirst)
        let page: ScannedPage = try printedPage()

        try await bringIn(state, page)
        try await bringIn(state, page)
        let fronts: [UUID] = state.scannedPages.map(\.id)
        XCTAssertEqual(state.scannedPages.map(\.side), [.front, .front])
        state.startCameraBacks()
        XCTAssertEqual(state.cameraSides?.next, .back)
        try await bringIn(state, page)
        try await bringIn(state, page)
        let backs: [UUID] = Array(state.scannedPages.map(\.id).suffix(2))
        // As many backs as fronts: put in order by itself, the backs first sheet first.
        XCTAssertEqual(state.scannedPages.map(\.id), [fronts[0], backs[0], fronts[1], backs[1]])
        XCTAssertEqual(state.scannedPages.map(\.side), [.front, .back, .front, .back])
        XCTAssertEqual(state.scannedPages.map(\.sheetIndex), [0, 0, 1, 1])
        XCTAssertEqual(state.cameraSides?.next, .front)
        XCTAssertNil(state.sidesMismatch)

        // A second stack with a back missing: the mismatch is said, then the pages are combined as they are.
        try await bringIn(state, page)
        try await bringIn(state, page)
        state.startCameraBacks()
        try await bringIn(state, page)
        let second: [UUID] = Array(state.scannedPages.map(\.id).suffix(3))
        state.putCameraSidesInOrder()
        XCTAssertEqual(state.sidesMismatch, "2 fronts but 1 back")
        XCTAssertEqual(state.scannedPages.count, 7)
        state.putCameraSidesInOrder()
        XCTAssertNil(state.sidesMismatch)
        XCTAssertEqual(Array(state.scannedPages.map(\.id).suffix(3)), [second[0], second[2], second[1]])
        XCTAssertEqual(state.cameraSides?.next, .front)
    }

    @MainActor
    func test_twoSided_theWayCanChange_otherTasksHaveNoSides() {
        let state: AppState = makeState(.twoSided)
        XCTAssertEqual(state.cameraSides?.mode, .flip)
        state.settings.taskOptions.cameraFrontsFirst = true
        XCTAssertEqual(state.cameraSides?.mode, .frontsFirst)
        XCTAssertTrue(state.startTask(.document))
        XCTAssertNil(state.cameraSides)
    }

    // MARK: Separate documents

    @MainActor
    func test_batch_newDocument_startsADocumentAtTheNextPage_andSavesTwoPDFs() async throws {
        let state: AppState = makeState(.batch)
        XCTAssertTrue(state.offersNewDocument)
        XCTAssertFalse(state.canStartNewDocument)
        let page: ScannedPage = try printedPage()
        try await bringIn(state, page)
        XCTAssertTrue(state.canStartNewDocument)
        state.startNewDocument()
        XCTAssertTrue(state.newDocumentPending)
        XCTAssertFalse(state.canStartNewDocument)
        try await bringIn(state, page)
        XCTAssertFalse(state.newDocumentPending)
        try await bringIn(state, page)
        XCTAssertEqual(state.queuePlan.documents.map(\.pages), [[0], [1, 2]])
        XCTAssertEqual(state.scannedPages[1].documentBreak, .split)

        state.savePDF()
        try await waitUntil(timeout: 120) { !state.isBusy }
        XCTAssertNil(state.errorMessage)
        XCTAssertEqual(state.lastSavedURLs.count, 2)
        XCTAssertEqual(savedFiles().count, 2)
        XCTAssertFalse(state.newDocumentPending)
        // Not for the other tasks.
        XCTAssertTrue(state.startTask(.document))
        XCTAssertFalse(state.offersNewDocument)
    }

    @MainActor
    func test_batch_newDocument_goesWithTheTask() async throws {
        let state: AppState = makeState(.batch)
        let page: ScannedPage = try printedPage()
        try await bringIn(state, page)
        state.startNewDocument()
        XCTAssertTrue(state.newDocumentPending)
        XCTAssertTrue(state.startTask(.document))
        XCTAssertFalse(state.newDocumentPending)
        try await bringIn(state, page)
        XCTAssertEqual(state.scannedPages.count, 2)
        XCTAssertNotEqual(state.scannedPages[1].documentBreak, .split)
    }

    @MainActor
    func test_batch_newDocument_marksANetworkScannersPageToo() async throws {
        let state: AppState = makeState(.batch)
        try await bringIn(state, try printedPage())
        state.startNewDocument()
        var scanned: ScannedPage = try printedPage()
        scanned.source = .scanner
        XCTAssertTrue(state.ingest([scanned], source: .scanner))
        try await waitUntil(timeout: 60) { !state.isBusy }
        XCTAssertNil(state.errorMessage)
        XCTAssertFalse(state.newDocumentPending)
        XCTAssertEqual(state.scannedPages.count, 2)
        XCTAssertEqual(state.scannedPages[1].documentBreak, .split)
        XCTAssertEqual(state.queuePlan.documents.map(\.pages), [[0], [1]])
    }

    // MARK: Quick scan

    @MainActor
    func test_quickScan_holdsTheShot_copiesItsText_thenSavesAJPEG() async throws {
        let actions = CameraTaskFileActions()
        let state: AppState = makeState(.quickScan, actions: actions)
        XCTAssertTrue(AppState.holdsQuickScan(state.settings, source: .photo))
        XCTAssertFalse(AppState.holdsQuickScan(state.settings, source: .scanner))
        let page: ScannedPage = try printedPage()
        try await bringIn(state, page)
        // Held for its screen: nothing saved, nothing queued, no other page taken meanwhile.
        XCTAssertNotNil(state.quickScanPage)
        XCTAssertTrue(state.scannedPages.isEmpty)
        XCTAssertEqual(savedFiles(), [])
        XCTAssertFalse(state.canIngest)
        XCTAssertFalse(state.ingest([page], source: .photo))

        state.copyQuickScanText(reading: { (_: ScannedPage) throws -> String in "Line one\n\nLine two" })
        try await waitUntil(timeout: 30) { !state.isBusy }
        XCTAssertEqual(actions.copiedTexts, ["Line one\n\nLine two"])
        XCTAssertEqual(state.statusMessage, "Text copied.")
        XCTAssertNotNil(state.quickScanPage)

        state.saveQuickScan()
        try await waitUntil(timeout: 60) { !state.isBusy }
        XCTAssertNil(state.errorMessage)
        XCTAssertNil(state.quickScanPage)
        let names: [String] = savedFiles()
        XCTAssertEqual(names.count, 1)
        XCTAssertTrue(names[0].hasSuffix(".jpg"), names[0])

        // Discarded: nothing more is saved.
        try await bringIn(state, page)
        state.discardQuickScan()
        XCTAssertNil(state.quickScanPage)
        XCTAssertTrue(state.canIngest)
        XCTAssertEqual(savedFiles().count, 1)
        // No text on the page: nothing is copied.
        try await bringIn(state, page)
        state.copyQuickScanText(reading: { (_: ScannedPage) throws -> String in "" })
        try await waitUntil(timeout: 30) { !state.isBusy }
        XCTAssertEqual(actions.copiedTexts.count, 1)
        XCTAssertEqual(state.statusMessage, "No text found.")
    }

    // MARK: Email

    func test_email_afterSave_isSentByEmailOnTheIPhoneOnly() {
        XCTAssertEqual(AppState.afterSaveFileAction(.share, task: .email, platform: .ios), .email)
        XCTAssertEqual(AppState.afterSaveFileAction(.share, task: .email, platform: .mac), .share)
        XCTAssertEqual(AppState.afterSaveFileAction(.share, task: .document, platform: .ios), .share)
        XCTAssertEqual(AppState.afterSaveFileAction(.share, task: nil, platform: .ios), .share)
        XCTAssertEqual(AppState.afterSaveFileAction(.open, task: .email, platform: .ios), .open)
    }

    @MainActor
    func test_email_opensAMailMessage_whenMailIsSetUp_elseTheShareSheet() async throws {
        for mail in [true, false] {
            let actions = CameraTaskFileActions()
            actions.canCompose = mail
            let state: AppState = makeState(.email, actions: actions)
            state.platform = .ios
            XCTAssertEqual(state.settings.output.pdfSize, .compact)
            try await bringIn(state, try printedPage())
            state.savePDF()
            try await waitUntil(timeout: 120) { !state.isBusy }
            XCTAssertNil(state.errorMessage)
            let pdf: URL = try XCTUnwrap(state.lastSavedURLs.first)
            if mail {
                XCTAssertEqual(actions.composed, [[pdf]])
                XCTAssertTrue(actions.shared.isEmpty)
            } else {
                XCTAssertTrue(actions.composed.isEmpty)
                XCTAssertEqual(actions.shared, [[pdf]])
            }
        }
    }

    // MARK: Book

    @MainActor
    func test_book_aWholeSpread_comesInAsTwoPages_thatCanBeSplitAgain() async throws {
        var options = TaskOptions()
        options.cameraSpreads = true
        let state: AppState = makeState(.book, options: options)
        let table: TablePhoto = CameraSheets.squareOnATable(TestPages.shadowSpread().toRgba())
        let photo: CGImage = try XCTUnwrap(table.photo.makeCGImage())
        var shot: ScannedPage = ScannedPage(image: photo, dpi: CaptureScale.nominalDPI, colorMode: .color)
            .withCapture(CaptureFacts(quad: table.quad, sourceWidth: table.photo.width, sourceHeight: table.photo.height))
        shot.source = .photo
        try await bringIn(state, shot)
        XCTAssertEqual(state.scannedPages.count, 2)
        XCTAssertTrue(state.scannedPages.allSatisfy { $0.spreadID == shot.id })
        let first: UUID = try XCTUnwrap(state.scannedPages.first?.id)
        XCTAssertTrue(state.canEditSpread(id: first))
        // Joined by hand, as on the Mac: one page again.
        state.joinSpread(id: first)
        try await waitUntil(timeout: 60) { !state.isBusy }
        XCTAssertEqual(state.scannedPages.count, 1)
        state.clearPages()

        // Page by page: one page a shot.
        state.settings.taskOptions.cameraSpreads = false
        try await bringIn(state, shot)
        XCTAssertEqual(state.scannedPages.count, 1)
        XCTAssertNil(state.scannedPages.first?.spread)
    }
}
