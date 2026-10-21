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

    // MARK: Start screen

    func test_offeredTasks_areTheCollectedDocumentTasks() {
        var offered: [ScanTask] = []
        for task in ScanTask.allCases where IOSShell.offers(task) {
            offered.append(task)
        }
        XCTAssertEqual(offered, [.document, .feeder, .email, .twoSided, .word, .batch, .book])
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

    func test_tiles_keepTheCatalogsWording_andSayWhyATaskIsNotHereYet() throws {
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
        for task in [ScanTask.photos, .photoRestore, .quickScan, .idCard, .copy, .receipt] {
            let tile: IOSTaskTile = try XCTUnwrap(tiles[task])
            XCTAssertFalse(tile.availability.isAvailable, task.rawValue)
            XCTAssertEqual(tile.availability.reason, IOSShell.notYetReason, task.rawValue)
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
}
#endif
