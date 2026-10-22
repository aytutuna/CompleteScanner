#if os(iOS)
import CoreGraphics
import UIKit
import XCTest
@testable import CompleteScannerIOS
@testable import CompleteScannerKit

// What the iPhone's app shell passes AppState, the start screen's tiles, and the shell's way through
// a task as the UI smoke test takes it (task, demo scanner, page strip, PDF, share sheet), here
// without a screen. The AppState reads and writes its settings, presets, spool and devices.txt in a
// folder of its own (`AppStateFiles.all(in:)`), saves there, and uses a pasteboard of its own.

/// Text recognition that cannot run, so no page is read with Vision here.
private struct ShellScorer: OrientationScorer {
    var isAvailable: Bool { false }

    func score(_ image: RgbaImage) throws -> OrientationScore {
        OrientationScore.none
    }
}

/// Barcode reading that cannot run.
private struct ShellBarcodes: BarcodeReader {
    var isAvailable: Bool { false }

    func read(_ image: GrayImage) throws -> [BarcodeReading] {
        []
    }
}

/// The addresses the file actions asked the system to open.
@MainActor
private final class ShellOpened {
    var urls: [URL] = []
}

/// Waits on the main actor until `condition` holds, failing after `timeout` seconds.
@MainActor
private func waitFor(timeout: TimeInterval, _ condition: () -> Bool,
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

/// A task card as the start screen gets it.
private func card(_ task: ScanTask, availability: TaskAvailability = .available,
                  isCurrent: Bool = false) -> TaskCard {
    TaskCard(definition: TaskCatalog.definition(task), availability: availability, isCurrent: isCurrent,
             summary: "300 dpi")
}

final class IOSShellTests: XCTestCase {
    private var folder: URL!
    private var pasteboard: UIPasteboard?

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("IOSShellTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        // The settings are written 0.4 s after they change: let that write land before the folder goes.
        try await Task.sleep(nanoseconds: 600_000_000)
        await removeOwnPasteboard()
        try? FileManager.default.removeItem(at: folder)
    }

    @MainActor
    private func removeOwnPasteboard() {
        if let pasteboard {
            UIPasteboard.remove(withName: pasteboard.name)
        }
        pasteboard = nil
    }

    // MARK: Launch options

    func test_launchOptions_demoScannerArgument() {
        XCTAssertTrue(IOSLaunchOptions(arguments: ["CompleteScanner", "-demoScanner"]).demoScannerOnly)
        XCTAssertFalse(IOSLaunchOptions(arguments: ["CompleteScanner"]).demoScannerOnly)
        XCTAssertFalse(IOSLaunchOptions(arguments: ["CompleteScanner", "-demoScannerX"]).demoScannerOnly)
        XCTAssertEqual(IOSLaunchOptions.demoScannerArgument, "-demoScanner")
    }

    @MainActor
    func test_backends_areTheDemoScannerAlone_withOrWithoutTheArgument() {
        for options in [IOSLaunchOptions(demoScannerOnly: true), IOSLaunchOptions(demoScannerOnly: false)] {
            let backends: [any ScannerBackend] = IOSShell.backends(options: options)
            XCTAssertEqual(backends.count, 1)
            let demo: MockScannerBackend? = backends.first as? MockScannerBackend
            XCTAssertNotNil(demo)
            // The app's demo scanner: its second sheet's back is blank.
            XCTAssertEqual(demo?.feederBlankBackSheets, [1])
        }
    }

    // MARK: The step card

    func test_stepCard_speaksOfTheCamera_unlessANetworkScannerIsInUse() {
        let network: ScannerInfo = ScannerInfo(id: "escl:x", name: "Office MFP", transport: "Network", backend: "escl")
        let demo: ScannerInfo = ScannerInfo(id: "mock:demo", name: "Demo Scanner", transport: "Demo", isDemo: true, backend: "mock")
        XCTAssertTrue(IOSShell.usesNetworkScanner(network))
        XCTAssertFalse(IOSShell.usesNetworkScanner(demo))
        XCTAssertFalse(IOSShell.usesNetworkScanner(nil))
        let options = TaskOptions()
        let tasks: [ScanTask] = [.document, .feeder, .quickScan, .email, .twoSided, .word, .batch, .book, .archive]
        for task in tasks {
            let camera: CameraStepText = CameraTaskCatalog.text(task, options: options)
            for device in [nil, demo] as [ScannerInfo?] {
                XCTAssertEqual(IOSShell.cameraLine(task, options: options, sides: nil, newDocument: false,
                                                   turningOverByHand: false, device: device), camera, task.rawValue)
            }
            XCTAssertNil(IOSShell.cameraLine(task, options: options, sides: nil, newDocument: false,
                                             turningOverByHand: false, device: network), task.rawValue)
        }
        // The ID card's steps say which side is next; a stack turned over by hand has its own steps.
        XCTAssertNil(IOSShell.cameraLine(.idCard, options: options, sides: nil, newDocument: false,
                                         turningOverByHand: false, device: nil))
        XCTAssertNil(IOSShell.cameraLine(.twoSided, options: options, sides: nil, newDocument: false,
                                         turningOverByHand: true, device: nil))
        XCTAssertNil(IOSShell.cameraLine(nil, options: options, sides: nil, newDocument: false,
                                         turningOverByHand: false, device: nil))
        // With a network scanner, a back due or a new document pending is still said.
        var flip = CameraSides(mode: .flip)
        flip.took([UUID()])
        XCTAssertEqual(IOSShell.cameraLine(.twoSided, options: options, sides: flip, newDocument: false,
                                           turningOverByHand: false, device: network)?.prompt,
                       CameraTaskCatalog.turnOverPrompt)
        XCTAssertEqual(IOSShell.cameraLine(.batch, options: options, sides: nil, newDocument: true,
                                           turningOverByHand: false, device: network)?.prompt,
                       CameraTaskCatalog.newDocumentPrompt)
    }

    func test_rightToLeft_isShownWhileTheSourceInUseCutsSpreads() {
        let network: ScannerInfo = ScannerInfo(id: "escl:x", name: "Office MFP", transport: "Network", backend: "escl")
        let demo: ScannerInfo = ScannerInfo(id: "mock:demo", name: "Demo Scanner", transport: "Demo", isDemo: true, backend: "mock")
        var book: ScanSettings = TaskCatalog.apply(.book, to: ScanSettings())
        book.source = .flatbed
        XCTAssertTrue(PageProcessor.splitsFacingPages(book))
        // Page by page: the camera takes one page a shot, but a network scanner's spreads are still cut.
        book.taskOptions.cameraSpreads = false
        XCTAssertTrue(IOSShell.showsRightToLeft(book, device: network))
        XCTAssertFalse(IOSShell.showsRightToLeft(book, device: demo))
        XCTAssertFalse(IOSShell.showsRightToLeft(book, device: nil))
        book.taskOptions.cameraSpreads = true
        for device in [nil, demo, network] as [ScannerInfo?] {
            XCTAssertTrue(IOSShell.showsRightToLeft(book, device: device))
        }
        // Nothing is cut once facing pages aren't split.
        book.document.splitFacingPages = false
        XCTAssertFalse(IOSShell.showsRightToLeft(book, device: network))
        XCTAssertFalse(IOSShell.showsRightToLeft(book, device: nil))
    }

    // MARK: Start screen

    func test_offeredTasks_areEveryTask_sinceThePhotocopyPrintsOverAirPrint() {
        for task in ScanTask.allCases {
            XCTAssertTrue(IOSShell.offers(task), task.rawValue)
        }
    }

    func test_groups_followTheCatalogsSections_withEveryTaskOnce() {
        var cards: [TaskCard] = []
        for definition in TaskCatalog.all {
            cards.append(card(definition.task))
        }
        let groups: [IOSTaskGroup] = IOSShell.groups(cards)
        XCTAssertEqual(groups.count, TaskCatalog.sections.count)
        var index: Int = 0
        for section in TaskCatalog.sections {
            XCTAssertEqual(groups[index].group, section.group)
            XCTAssertEqual(groups[index].title, section.group.title)
            var tasks: [ScanTask] = []
            for tile in groups[index].tiles {
                tasks.append(tile.task)
            }
            var expected: [ScanTask] = []
            for definition in section.definitions {
                expected.append(definition.task)
            }
            XCTAssertEqual(tasks, expected)
            index += 1
        }
    }

    func test_tiles_keepTheCatalogsWording_andOfferEveryTask() throws {
        var cards: [TaskCard] = []
        for definition in TaskCatalog.all {
            cards.append(card(definition.task))
        }
        var tiles: [ScanTask: IOSTaskTile] = [:]
        for group in IOSShell.groups(cards) {
            for tile in group.tiles {
                tiles[tile.task] = tile
            }
        }
        let document: IOSTaskTile = try XCTUnwrap(tiles[.document])
        XCTAssertEqual(document.title, TaskCatalog.definition(.document).title)
        XCTAssertEqual(document.subtitle, TaskCatalog.definition(.document).subtitle)
        XCTAssertEqual(document.symbol, "doc.text")
        XCTAssertTrue(document.availability.isAvailable)
        for task in [ScanTask.copy, .quickScan, .archive, .twoSided, .batch, .book, .email] {
            let tile: IOSTaskTile = try XCTUnwrap(tiles[task])
            XCTAssertTrue(tile.availability.isAvailable, task.rawValue)
        }
    }

    func test_anOfferedTask_keepsTheCardsOwnReason() {
        let noFeeder = TaskAvailability(isAvailable: false, reason: TaskCatalog.needsFeederReason)
        let tile = IOSTaskTile(card: card(.feeder, availability: noFeeder))
        XCTAssertEqual(tile.availability, noFeeder)
    }

    func test_theCurrentTask_saysSoToVoiceOver() {
        let current = IOSTaskTile(card: card(.word, isCurrent: true))
        XCTAssertTrue(current.isCurrent)
        XCTAssertEqual(current.accessibilityValue, "Current")
        let other = IOSTaskTile(card: card(.document))
        XCTAssertFalse(other.isCurrent)
        XCTAssertEqual(other.accessibilityValue, "")
    }

    func test_addPagesTile_isPickedWhenDocumentToPDFIs() {
        XCTAssertEqual(IOSAppendTile.title, "Add pages to a PDF")
        XCTAssertEqual(IOSAppendTile.subtitle, "Pick a PDF, then scan the pages to add")
        XCTAssertTrue(IOSAppendTile.availability([card(.photos), card(.document)]).isAvailable)
        let noScanner = TaskAvailability(isAvailable: false, reason: "No scanner")
        XCTAssertEqual(IOSAppendTile.availability([card(.document, availability: noScanner)]), noScanner)
        let none: TaskAvailability = IOSAppendTile.availability([card(.photos)])
        XCTAssertFalse(none.isAvailable)
        XCTAssertEqual(none.reason, IOSShell.notYetReason)
    }

    @MainActor
    func test_save_withATarget_namesTheFile() {
        var settings = ScanSettings()
        settings.format = .pdf
        let plan: SavePlan = SavePlan.make([], options: settings.document)
        let target = URL(fileURLWithPath: "/tmp/Contract.pdf")
        XCTAssertEqual(ScanScreen.saveTitle(settings, plan: plan, target: target), "Add to Contract.pdf")
        XCTAssertEqual(ScanScreen.saveTitle(settings, plan: plan, target: nil), IOSShell.saveTitle(settings, plan: plan))
        XCTAssertEqual(ScanScreen.clearTargetLabel(target), "Stop Adding to Contract.pdf")
    }

    // MARK: The shell's way through a task

    @MainActor
    func test_documentTask_onTheDemoScanner_scansSavesAPDF_andSharesIt() async throws {
        let own: UIPasteboard = UIPasteboard.withUniqueName()
        pasteboard = own
        let opened = ShellOpened()
        let actions = IOSFileActions(pasteboard: own, openSystemURL: { (url: URL) -> Void in
            opened.urls.append(url)
        })
        let options = IOSLaunchOptions(arguments: ["CompleteScanner", IOSLaunchOptions.demoScannerArgument])
        let state = AppState(backends: IOSShell.backends(options: options),
                             presetStore: PresetStore(directory: folder), fileActions: actions,
                             orientationScorer: ShellScorer(), barcodeReader: ShellBarcodes(),
                             files: AppStateFiles.all(in: folder))
        state.start()
        XCTAssertEqual(state.devices.map(\.id), ["mock:demo"])
        try await waitFor(timeout: 30) { state.capabilities != nil }

        XCTAssertTrue(state.startTask(.document))
        let output: URL = folder.appendingPathComponent("Saved", isDirectory: true)
        state.settings.destinationPath = output.path
        state.settings.resolution = 75
        state.settings.pdfSearchable = false
        XCTAssertEqual(state.activeTask, .document)

        state.performScan()
        try await waitFor(timeout: 120) { !state.isBusy }
        XCTAssertNil(state.errorMessage)
        XCTAssertEqual(state.scannedPages.count, 1)
        XCTAssertEqual(state.scannedPages.first?.source, .scanner)
        XCTAssertEqual(PageStripCell.cells(state.scannedPages).map(\.number), [1])

        state.savePDF()
        try await waitFor(timeout: 120) { !state.isBusy }
        XCTAssertNil(state.errorMessage)
        XCTAssertEqual(state.lastSavedURLs.count, 1)
        let pdf: URL = try XCTUnwrap(state.lastSavedURLs.first)
        XCTAssertEqual(pdf.pathExtension, "pdf")
        XCTAssertEqual(pdf.deletingLastPathComponent().standardizedFileURL.path, output.standardizedFileURL.path)
        let bytes: Data = try Data(contentsOf: pdf)
        XCTAssertTrue(bytes.starts(with: Data("%PDF".utf8)))

        // Share opens the share sheet with the saved file; Show in folder opens the Files app there.
        XCTAssertTrue(state.runFileAction(.share, urls: state.lastSavedURLs))
        XCTAssertEqual(actions.shareRequest?.urls, [pdf])
        XCTAssertTrue(state.runFileAction(.reveal, urls: state.lastSavedURLs))
        XCTAssertEqual(opened.urls.first?.scheme, "shareddocuments")

        // No printer is passed yet: the Kit's stand-in has none.
        XCTAssertFalse(state.hasPrinter)
        state.clearPages()
    }

    // MARK: Adding pages to a PDF

    @MainActor
    func test_appendToPDF_goesThroughTheShellsCoordinatedAccess_andItsQuestion() async throws {
        let actions = IOSFileActions(pasteboard: nil, openSystemURL: { (_: URL) -> Void in },
                                     mailAvailable: { () -> Bool in false })
        let plain: AppState = AppState.makeForIOS(options: IOSLaunchOptions(demoScannerOnly: true), fileActions: actions)
        XCTAssertNil(plain.confirmAppend)
        XCTAssertNotNil(plain.accessPDFForAppend)
        var questions: [String] = []
        let made: AppState = AppState.makeForIOS(options: IOSLaunchOptions(demoScannerOnly: true), fileActions: actions,
                                                 networkScanners: nil,
                                                 confirmAppend: { (question: String) async -> Bool in
                                                     questions.append(question)
                                                     return true
                                                 })
        XCTAssertNotNil(made.confirmAppend)

        let state = AppState(presetStore: PresetStore(directory: folder), orientationScorer: ShellScorer(),
                             barcodeReader: ShellBarcodes(), files: AppStateFiles.all(in: folder))
        state.settings.intent = .document
        state.settings.documentMultiPage = true
        state.settings.taskId = nil
        state.settings.format = .pdf
        state.settings.pdfSearchable = false
        state.settings.destinationPath = folder.path
        state.confirmAppend = made.confirmAppend
        state.accessPDFForAppend = made.accessPDFForAppend
        XCTAssertTrue(IOSShell.offersPDFOptions(state.settings))

        let context = CGContext(data: nil, width: 300, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.95, green: 0.95, blue: 0.93, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 300, height: 400))
        let image: CGImage = context.makeImage()!
        let page = ScannedPage(image: image, dpi: 50, colorMode: .color)
        let url: URL = folder.appendingPathComponent("Shared.pdf")
        try PDFBuilder.makePDF(pages: [page], pdfSize: .best, progress: nil, textLayer: nil).write(to: url)
        XCTAssertTrue(state.ingest([page], source: .photo))
        try await waitFor(timeout: 60) { !state.isBusy }
        XCTAssertTrue(state.canAppendPages)

        state.appendToPDF(at: url)
        try await waitFor(timeout: 60) { !state.isBusy }
        XCTAssertNil(state.errorMessage)
        XCTAssertEqual(questions, [])
        XCTAssertTrue(state.scannedPages.isEmpty)
        XCTAssertEqual(try PDFReaderLite(data: Data(contentsOf: url)).pageCount, 2)

        // What fails inside the coordinated access is what the append throws.
        XCTAssertThrowsError(try IOSPDFAppend.access(url, writing: true) { (_: URL) throws -> Void in
            throw CocoaError(.fileWriteOutOfSpace)
        }) { (error: Error) in
            XCTAssertEqual((error as? CocoaError)?.code, .fileWriteOutOfSpace)
        }
        var read: URL?
        try IOSPDFAppend.access(url, writing: false) { (file: URL) throws -> Void in
            read = file
        }
        XCTAssertEqual(read?.standardizedFileURL.path, url.standardizedFileURL.path)
    }
}
#endif
