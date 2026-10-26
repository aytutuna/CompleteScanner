import CoreGraphics
import Foundation
import XCTest
@testable import CompleteScannerKit

// The queue the iPhone keeps (AppState+QueueRecord.swift): recorded beside its spool files and brought back
// when the next AppState is made, as long as every file is there and the settings save a queue; otherwise
// the spool is emptied as it always was. Swift only: Windows has no queue record.

/// Text recognition that cannot run, so no page is read with Vision here.
private struct RecordScorer: OrientationScorer {
    var isAvailable: Bool { false }

    func score(_ image: RgbaImage) throws -> OrientationScore {
        OrientationScore.none
    }
}

/// Barcode reading that cannot run.
private struct RecordBarcodes: BarcodeReader {
    var isAvailable: Bool { false }

    func read(_ image: GrayImage) throws -> [BarcodeReading] {
        []
    }
}

/// A light page with a dark bar across it.
private func recordPage() -> ScannedPage {
    let space: CGColorSpace = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(data: nil, width: 300, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 0.95, green: 0.95, blue: 0.93, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 300, height: 400))
    context.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1))
    context.fill(CGRect(x: 50, y: 200, width: 200, height: 16))
    return ScannedPage(image: context.makeImage()!, dpi: 50, colorMode: .color)
}

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

final class AppStateQueueRecordTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppStateQueueRecordTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try await Task.sleep(nanoseconds: 600_000_000)
        try? FileManager.default.removeItem(at: folder)
    }

    private func files(keepsQueue: Bool) -> AppStateFiles {
        var files = AppStateFiles.all(in: folder)
        files.keepsQueue = keepsQueue
        return files
    }

    private var spool: URL { folder.appendingPathComponent("pages", isDirectory: true) }

    @MainActor
    private func makeState(keepsQueue: Bool = true) -> AppState {
        AppState(presetStore: PresetStore(directory: folder), orientationScorer: RecordScorer(),
                 barcodeReader: RecordBarcodes(), files: files(keepsQueue: keepsQueue))
    }

    /// An AppState keeping its queue, on Document to PDF with two pages queued, the second skipped by hand
    /// and turned, its record written and `settings` saved as the next launch reads them.
    @MainActor
    private func makeQueue(settings: ((ScanSettings) -> ScanSettings)? = nil) async throws -> AppState {
        let state = makeState()
        XCTAssertTrue(state.startTask(.document))
        state.settings.destinationPath = folder.path
        XCTAssertTrue(state.ingest([recordPage(), recordPage()], source: .photo))
        try await waitUntil(timeout: 60) { !state.isBusy && state.scannedPages.count == 2 }
        state.togglePageInclusion(id: state.scannedPages[1].id)
        state.scannedPages[1].rotationQuarterTurns = 1
        state.writeQueueRecord()
        // The settings' own write lands 0.4 s after they change; this one comes after it.
        try await Task.sleep(nanoseconds: 600_000_000)
        SettingsStore.save(settings?(state.settings) ?? state.settings, directory: folder)
        return state
    }

    @MainActor
    private func spoolNames() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: spool.path)) ?? []).sorted()
    }

    @MainActor
    func test_aKeptQueue_comesBackAtLaunch_asItWas() async throws {
        let before = try await makeQueue()
        XCTAssertTrue(FileManager.default.fileExists(atPath: spool.appendingPathComponent(QueueRecord.fileName).path))
        let pages: [ScannedPage] = before.scannedPages

        let after = makeState()
        after.queueRecordDelay = 20_000_000
        // Until the pages are back nothing can switch the kind past them, save or take a page.
        XCTAssertTrue(after.isBusy)
        XCTAssertEqual(after.statusMessage, "Bringing back 2 pages\u{2026}")
        XCTAssertFalse(after.startTask(.photos))
        XCTAssertFalse(after.canIngest)
        try await waitUntil(timeout: 30) { !after.isBusy }
        XCTAssertEqual(after.activeTask, .document)
        XCTAssertEqual(after.statusMessage, "2 pages are back from last time.")
        XCTAssertEqual(after.scannedPages.map(\.id), pages.map(\.id))
        XCTAssertEqual(after.scannedPages.map(\.fileURL), pages.map(\.fileURL))
        XCTAssertEqual(after.scannedPages.map(\.inclusion), pages.map(\.inclusion))
        XCTAssertEqual(after.scannedPages.map(\.dpi), pages.map(\.dpi))
        XCTAssertEqual(after.scannedPages.map(\.fullPixelSize), pages.map(\.fullPixelSize))
        XCTAssertEqual(after.scannedPages.map(\.source), pages.map(\.source))
        XCTAssertEqual(after.scannedPages[1].rotationQuarterTurns, 1)
        // The preview is read from the file again, turned as the page was.
        XCTAssertEqual(after.scannedPages[0].image.width, pages[0].image.width)
        XCTAssertEqual(after.scannedPages[1].image.width, pages[0].image.height)
        for page in after.scannedPages {
            XCTAssertTrue(FileManager.default.fileExists(atPath: page.fileURL!.path))
        }

        // Saved or discarded, the queue takes its record with it.
        after.clearPages()
        try await waitUntil(timeout: 5) {
            !FileManager.default.fileExists(atPath: spool.appendingPathComponent(QueueRecord.fileName).path)
        }
    }

    @MainActor
    func test_aSavesEnd_dropsOnlyThePagesItSaved() async throws {
        let state = try await makeQueue()
        let saved: ScannedPage = state.scannedPages[0]
        let other: ScannedPage = state.scannedPages[1]
        state.dropSaved([saved])
        XCTAssertEqual(state.scannedPages.map(\.id), [other.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: saved.fileURL!.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.fileURL!.path))
    }

    @MainActor
    func test_aQueueTheSettingsCannotSave_isEmptiedAtLaunch() async throws {
        _ = try await makeQueue { (settings: ScanSettings) -> ScanSettings in
            TaskCatalog.apply(.photos, to: settings)
        }
        let after = makeState()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(after.scannedPages.isEmpty)
        XCTAssertEqual(spoolNames(), [])
    }

    @MainActor
    func test_aPageWhoseFileIsGone_isLeftOut_theOthersComeBack() async throws {
        let before = try await makeQueue()
        let kept: ScannedPage = before.scannedPages[1]
        try FileManager.default.removeItem(at: before.scannedPages[0].fileURL!)
        let after = makeState()
        try await waitUntil(timeout: 30) { !after.isBusy }
        XCTAssertEqual(after.scannedPages.map(\.id), [kept.id])
        XCTAssertTrue(spoolNames().contains(kept.fileURL!.lastPathComponent))
    }

    @MainActor
    func test_aQueueWhoseFilesAreAllGone_isEmptiedAtLaunch() async throws {
        let before = try await makeQueue()
        for page in before.scannedPages {
            try FileManager.default.removeItem(at: page.fileURL!)
        }
        let after = makeState()
        XCTAssertFalse(after.isBusy)
        XCTAssertTrue(after.scannedPages.isEmpty)
        XCTAssertEqual(spoolNames(), [])
    }

    @MainActor
    func test_withoutKeepingTheQueue_theSpoolIsEmptiedAsBefore() async throws {
        _ = try await makeQueue()
        let after = makeState(keepsQueue: false)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(after.scannedPages.isEmpty)
        XCTAssertEqual(spoolNames(), [])
    }

    func test_onlyTheIPhonesFiles_keepTheQueue_inApplicationSupport() {
        XCTAssertFalse(AppStateFiles.standard.keepsQueue)
        let kept = AppStateFiles.keepingQueue
        XCTAssertTrue(kept.keepsQueue)
        XCTAssertEqual(kept.settingsDirectory, AppStateFiles.standard.settingsDirectory)
        XCTAssertEqual(kept.spoolDirectory, StoreFiles.defaultDirectory.appendingPathComponent("Pages", isDirectory: true))
    }
}
