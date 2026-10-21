import Combine
import CoreGraphics
import XCTest
@testable import CompleteScannerKit

// The seams each app shell fills in (`PlatformLifecycle`, the scanner connections, the file actions)
// and the one way pages come in (`AppState.ingest`, which the scan path uses too). Swift only: the
// Windows app has one shell, so `AppViewModel` has no such seams. Every AppState here reads and writes
// its settings and presets, spools its pages and writes its devices.txt in a folder of its own
// (`AppStateFiles.all(in:)`) and is given stand-ins for the system, so nothing of the user's is read,
// opened, removed or overwritten: not the settings, not the pages a running app keeps in its spool.

/// Sends the app's lifecycle events by hand.
@MainActor
private final class SeamLifecycle: PlatformLifecycle {
    private var endHandlers: [@MainActor () -> Void] = []
    private var activeHandlers: [@MainActor () -> Void] = []

    var observerCount: Int { endHandlers.count + activeHandlers.count }

    func observeWillTerminate(_ handler: @escaping @MainActor () -> Void) {
        endHandlers.append(handler)
    }

    func observeDidBecomeActive(_ handler: @escaping @MainActor () -> Void) {
        activeHandlers.append(handler)
    }

    func sendWillTerminate() {
        for handler in endHandlers {
            handler()
        }
    }

    func sendDidBecomeActive() {
        for handler in activeHandlers {
            handler()
        }
    }
}

/// Records what is shown; everything else does nothing.
@MainActor
private final class SeamFileActions: FileActionService {
    private(set) var revealed: [[URL]] = []

    func open(_ url: URL) throws {}
    func openWith(_ url: URL) throws {}

    func reveal(_ urls: [URL]) {
        revealed.append(urls)
    }

    func sendProbe(for urls: [URL]) -> SendProbe {
        SendProbe(canCompose: false, canShare: false)
    }

    func share(_ urls: [URL], title: String) throws {}
    func composeEmail(_ urls: [URL]) throws {}
    func copy(_ content: ClipboardContent) throws {}
    func copyText(_ text: String) throws {}
}

/// No printer; counts how often the printers are read.
@MainActor
private final class SeamPrintService: PrintService {
    private(set) var printerReads = 0

    var printerNames: [String] {
        printerReads += 1
        return []
    }

    var defaultPrinterName: String? { nil }

    func setup(printerName: String?, requestedPaper: PaperSize?) -> PrinterSetup? {
        nil
    }

    func print(_ document: Data, job: PrintJob) throws -> Bool {
        throw PrintError.noPrinter
    }
}

/// Text recognition that cannot run, so no page is read with Vision here.
private struct SeamScorer: OrientationScorer {
    var isAvailable: Bool { false }

    func score(_ image: RgbaImage) throws -> OrientationScore {
        OrientationScore.none
    }
}

/// Barcode reading that cannot run.
private struct SeamBarcodes: BarcodeReader {
    var isAvailable: Bool { false }

    func read(_ image: GrayImage) throws -> [BarcodeReading] {
        []
    }
}

/// A light page with a dark bar across it, `width` × `height` pixels.
private func seamPage(width: Int, height: Int, dpi: Int) -> ScannedPage {
    let space: CGColorSpace = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 0.95, green: 0.95, blue: 0.93, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1))
    context.fill(CGRect(x: width / 6, y: height / 2, width: width * 2 / 3, height: max(2, height / 25)))
    let image: CGImage = context.makeImage()!
    return ScannedPage(image: image, dpi: dpi, colorMode: .color)
}

/// Waits on the main actor until `condition` holds, failing after `timeout` seconds.
@MainActor
private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool,
                       file: StaticString = #filePath, line: UInt = #line) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline {
            XCTFail("Timed out after \(timeout) s", file: file, line: line)
            return
        }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
}

final class AppStateSeamTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppStateSeamTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        // The settings are written 0.4 s after they change: let that write land before the folder goes.
        try await Task.sleep(nanoseconds: 600_000_000)
        try? FileManager.default.removeItem(at: folder)
    }

    /// An AppState with stand-ins for the system, its settings, presets, spool and diagnostics in
    /// `folder`, set to collect document pages from the flatbed at 75 dpi.
    @MainActor
    private func makeState(backends: [any ScannerBackend] = [], lifecycle: SeamLifecycle? = nil,
                           files: SeamFileActions? = nil, printer: SeamPrintService? = nil) -> AppState {
        let state = AppState(backends: backends, presetStore: PresetStore(directory: folder),
                             fileActions: files ?? SeamFileActions(),
                             printService: printer ?? SeamPrintService(),
                             orientationScorer: SeamScorer(), barcodeReader: SeamBarcodes(),
                             lifecycle: lifecycle, files: AppStateFiles.all(in: folder))
        var settings = ScanSettings()
        settings.intent = .document
        settings.documentMultiPage = true
        settings.taskId = nil
        settings.source = .flatbed
        settings.duplex = .off
        settings.resolution = 75
        settings.destinationPath = folder.path
        state.settings = settings
        return state
    }

    // MARK: Where the files are

    func test_standardFiles_areTheAppsOwnPlaces() {
        let files = AppStateFiles.standard
        XCTAssertEqual(files.settingsDirectory, StoreFiles.defaultDirectory)
        XCTAssertEqual(files.spoolDirectory, FileManager.default.temporaryDirectory
            .appendingPathComponent("CompleteScanner-pages", isDirectory: true))
        XCTAssertEqual(files.diagnosticsFile?.lastPathComponent, "devices.txt")
        XCTAssertEqual(files.diagnosticsFile?.deletingLastPathComponent().path.hasSuffix("/Logs/CompleteScanner"), true)
    }

    @MainActor
    func test_filesInAFolder_settingsReadFromIt_spoolEmptiedThere_diagnosticsWrittenThere() throws {
        // Settings saved before, and a page a previous run left in the spool.
        var saved = ScanSettings()
        saved.jpegQuality = 0.42
        SettingsStore.save(saved, directory: folder)
        let files = AppStateFiles.all(in: folder)
        try FileManager.default.createDirectory(at: files.spoolDirectory, withIntermediateDirectories: true)
        let leftOver = files.spoolDirectory.appendingPathComponent("left-over.tiff")
        try Data([1, 2, 3]).write(to: leftOver)

        let state = AppState(presetStore: PresetStore(directory: folder), orientationScorer: SeamScorer(),
                             barcodeReader: SeamBarcodes(), files: files)
        XCTAssertFalse(state.isFirstRun)
        XCTAssertEqual(state.settings.jpegQuality, 0.42, accuracy: 0.0001)
        XCTAssertEqual(state.settingsDirectory, folder)
        XCTAssertEqual(state.spoolDirectory, files.spoolDirectory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: leftOver.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: files.spoolDirectory.path))
        state.start()
        let diagnostics = try XCTUnwrap(files.diagnosticsFile)
        XCTAssertFalse(try String(contentsOf: diagnostics, encoding: .utf8).isEmpty)
    }

    // MARK: PlatformLifecycle

    @MainActor
    func test_willTerminate_writesTheSettingsAtOnce() throws {
        let lifecycle = SeamLifecycle()
        let state = makeState(lifecycle: lifecycle)
        state.settings.jpegQuality = 0.55
        // The debounced write has not run: nothing has let it.
        XCTAssertNil(SettingsStore.load(directory: folder))
        lifecycle.sendWillTerminate()
        let saved = try XCTUnwrap(SettingsStore.load(directory: folder))
        XCTAssertEqual(saved.jpegQuality, 0.55, accuracy: 0.0001)
        XCTAssertEqual(saved.resolution, 75)
    }

    @MainActor
    func test_didBecomeActive_readsThePrintersAgain_onceStarted() {
        let lifecycle = SeamLifecycle()
        let printer = SeamPrintService()
        let state = makeState(lifecycle: lifecycle, printer: printer)
        // Only the will-terminate handler until the app starts.
        XCTAssertEqual(lifecycle.observerCount, 1)
        lifecycle.sendDidBecomeActive()
        XCTAssertEqual(printer.printerReads, 0)
        state.start()
        state.start()
        XCTAssertEqual(printer.printerReads, 2)
        // Started twice, observed once.
        XCTAssertEqual(lifecycle.observerCount, 2)
        lifecycle.sendDidBecomeActive()
        XCTAssertEqual(printer.printerReads, 3)
    }

    // MARK: Services each shell passes in

    @MainActor
    func test_revealInFinder_goesThroughTheFileActions() {
        let files = SeamFileActions()
        let state = makeState(files: files)
        let url = folder.appendingPathComponent("Scan 1.pdf")
        state.revealInFinder(url)
        XCTAssertEqual(files.revealed, [[url]])
    }

    @MainActor
    func test_withoutTheShellsServices_onlyTheDemoScanner_noPrinter_andFileActionsRefused() throws {
        let state = AppState(presetStore: PresetStore(directory: folder), orientationScorer: SeamScorer(),
                             barcodeReader: SeamBarcodes(), files: AppStateFiles.all(in: folder))
        state.start()
        XCTAssertEqual(state.devices.map(\.id), ["mock:demo"])
        XCTAssertEqual(state.printerNames, [])
        XCTAssertFalse(state.hasPrinter)
        let file = folder.appendingPathComponent("Scan 1.pdf")
        try Data("%PDF-1.4\n".utf8).write(to: file)
        XCTAssertFalse(state.runFileAction(.open, urls: [file]))
        XCTAssertTrue(state.errorMessage?.contains("Files cannot be opened or shared here.") == true,
                      state.errorMessage ?? "no error")
        XCTAssertNotNil(state.openTroubleshootLink(.openScannerSettings))
        XCTAssertNotNil(state.copyDiagnostics(state.troubleshootSnapshot()))
    }

    // MARK: Bringing pages in

    func test_cleanUpStage_bySource() {
        var settings = ScanSettings()
        settings.intent = .document
        settings.documentMultiPage = true
        settings.document.autoCrop = true
        let scorer = SeamScorer()
        let barcodes = SeamBarcodes()
        let scan = AppState.cleanUpStage(for: .scanner, settings: settings, arrangement: .twoSided,
                                         scorer: scorer, barcodes: barcodes)
        XCTAssertEqual(scan.steps.map(\.name),
                       PageProcessor.forScan(settings, scorer: scorer, barcodes: barcodes).steps.map(\.name))
        XCTAssertEqual(scan.arrangement, .twoSided)
        let photo = AppState.cleanUpStage(for: .photo, settings: settings, arrangement: .asScanned,
                                          scorer: scorer, barcodes: barcodes)
        XCTAssertEqual(photo.steps.map(\.name),
                       PageProcessor.forPhotoImport(settings, scorer: scorer, barcodes: barcodes).steps.map(\.name))
        // A phone's pages were cleaned up on the phone.
        let phone = AppState.cleanUpStage(for: .phone, settings: settings, arrangement: .asScanned,
                                          scorer: scorer, barcodes: barcodes)
        XCTAssertTrue(phone.steps.isEmpty)
    }

    @MainActor
    func test_ingest_queuesThePages_markedWithTheirSource() async throws {
        let state = makeState()
        let pages: [ScannedPage] = [seamPage(width: 400, height: 520, dpi: 50), seamPage(width: 400, height: 520, dpi: 50)]
        XCTAssertTrue(state.ingest(pages, source: .photo))
        XCTAssertTrue(state.isBusy)
        try await waitUntil(timeout: 60) { !state.isBusy }
        defer { state.deleteSpoolFiles(of: state.scannedPages) }
        XCTAssertNil(state.errorMessage)
        XCTAssertEqual(state.scannedPages.map(\.id), pages.map(\.id))
        XCTAssertEqual(state.scannedPages.map(\.source), [.photo, .photo])
        // Spooled in the state's own spool.
        let spool = AppStateFiles.all(in: folder).spoolDirectory
        for page in state.scannedPages {
            XCTAssertEqual(page.fileURL?.deletingLastPathComponent().standardizedFileURL, spool.standardizedFileURL)
        }
        XCTAssertEqual(state.scanHistory.count, 2)
        XCTAssertTrue(state.statusMessage.hasPrefix("Added 2 pages — 2 in queue."), state.statusMessage)
        XCTAssertNotNil(state.lastScanImage)
    }

    @MainActor
    func test_ingest_isRefusedWhileBusy_andSaysSo() async throws {
        let state = makeState()
        XCTAssertTrue(state.canIngest)
        XCTAssertTrue(state.ingest([seamPage(width: 300, height: 400, dpi: 50)], source: .phone))
        XCTAssertFalse(state.canIngest)
        XCTAssertFalse(state.ingest([seamPage(width: 300, height: 400, dpi: 50)], source: .phone))
        XCTAssertFalse(state.ingest([], source: .phone))
        try await waitUntil(timeout: 60) { !state.isBusy }
        defer { state.deleteSpoolFiles(of: state.scannedPages) }
        XCTAssertEqual(state.scannedPages.count, 1)
        XCTAssertEqual(state.scannedPages.first?.source, .phone)
        XCTAssertTrue(state.canIngest)
    }

    @MainActor
    func test_ingest_isRefused_whileAStackIsTurnedOverByHand_orAReviewIsOpen() {
        let state = makeState()
        // Turning the stack over by hand: its steps count the scanner's fronts and backs.
        state.settings.source = .documentFeeder
        state.settings.duplex = .manual
        XCTAssertTrue(state.isTurningOverByHand)
        XCTAssertFalse(state.canIngest)
        XCTAssertFalse(state.ingest([seamPage(width: 300, height: 400, dpi: 50)], source: .phone))
        XCTAssertFalse(state.isBusy)
        XCTAssertTrue(state.scannedPages.isEmpty)
        XCTAssertTrue(state.scanHistory.isEmpty)

        state.settings.source = .flatbed
        state.settings.duplex = .off
        XCTAssertFalse(state.isTurningOverByHand)
        XCTAssertTrue(state.canIngest)

        // The photo or receipt review: new pages would replace what is being reviewed.
        state.showPhotoReview = true
        XCTAssertFalse(state.canIngest)
        XCTAssertFalse(state.ingest([seamPage(width: 300, height: 400, dpi: 50)], source: .photo))
        XCTAssertFalse(state.isBusy)
        state.showPhotoReview = false

        // The ID card's review.
        state.showIdCardReview = true
        XCTAssertFalse(state.canIngest)
        XCTAssertFalse(state.ingest([seamPage(width: 300, height: 400, dpi: 50)], source: .phone))
        XCTAssertFalse(state.isBusy)
        state.showIdCardReview = false

        XCTAssertTrue(state.canIngest)
        XCTAssertTrue(state.scannedPages.isEmpty)
    }

    @MainActor
    func test_ingest_receipts_areKept_whenAnotherScannerIsChosenMeanwhile() async throws {
        let state = makeState()
        var settings = TaskCatalog.apply(.receipt, to: state.settings)
        settings.destinationPath = folder.path
        state.settings = settings
        XCTAssertTrue(state.isReceiptFlow)
        // Another scanner is chosen while the receipts are looked for (the status says so first).
        var switches = 0
        let watch = state.$statusMessage.sink { message in
            guard message.hasPrefix("Finding receipts") else { return }
            MainActor.assumeIsolated {
                state.switchGeneration += 1
            }
            switches += 1
        }
        defer { watch.cancel() }
        XCTAssertTrue(state.ingest([seamPage(width: 600, height: 900, dpi: 100)], source: .phone))
        try await waitUntil(timeout: 60) { !state.isBusy }
        XCTAssertEqual(switches, 1)
        XCTAssertNil(state.errorMessage)
        XCTAssertTrue(state.isReceiptReview)
        XCTAssertTrue(state.statusMessage.hasSuffix("on the glass."), state.statusMessage)
        XCTAssertEqual(state.showPhotoReview, !state.detectedPhotos.isEmpty)
    }

    @MainActor
    func test_scan_goesThroughIngest_twoSidedFeederJam_keepsThePagesAndSaysSo() async throws {
        let demo = MockScannerBackend()
        demo.feederSheetCount = 3
        demo.feederJamsAfter = 2
        let state = makeState(backends: [demo])
        state.settings.source = .documentFeeder
        state.settings.duplex = .both
        state.start()
        // Connected once the demo scanner's capabilities are read and the settings fitted to them.
        try await waitUntil(timeout: 30) { state.capabilities != nil && state.statusMessage.hasPrefix("Ready") }
        XCTAssertEqual(state.settings.duplex, .both)
        state.performScan()
        try await waitUntil(timeout: 120) { !state.isBusy }
        defer { state.deleteSpoolFiles(of: state.scannedPages) }
        // Two sheets, both sides, then the jam.
        XCTAssertEqual(state.scannedPages.count, 4)
        XCTAssertEqual(state.scannedPages.map(\.source), [.scanner, .scanner, .scanner, .scanner])
        XCTAssertEqual(state.scanHistory.count, 4)
        XCTAssertTrue(state.statusMessage.hasPrefix("Added 4 pages from 2 sheets, both sides — 4 in queue."),
                      state.statusMessage)
        XCTAssertEqual(state.errorMessage, ScanStop.from(ScanError.scannerProblem(.paperJam)).message(pagesKept: 4))
    }
}
