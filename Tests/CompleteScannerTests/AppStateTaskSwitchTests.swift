import CoreGraphics
import Foundation
import XCTest
@testable import CompleteScannerKit

// Picking a task over a queue (AppState+Tasks.swift): a task that collects pages keeps them, their spooled
// files and the scan history; the others leave them behind until Discard drops them with their files. Swift
// only, as `AppStateAppendTests`: the Windows view model is not in Core and never discards on a task switch;
// the rule itself, `TaskCatalog.carriesPages`, is in `ScanTaskTests` on both sides.

/// Text recognition that cannot run, so no page is read with Vision here.
private struct SwitchScorer: OrientationScorer {
    var isAvailable: Bool { false }

    func score(_ image: RgbaImage) throws -> OrientationScore {
        OrientationScore.none
    }
}

/// Barcode reading that cannot run.
private struct SwitchBarcodes: BarcodeReader {
    var isAvailable: Bool { false }

    func read(_ image: GrayImage) throws -> [BarcodeReading] {
        []
    }
}

/// A light page with a dark bar across it.
private func switchPage() -> ScannedPage {
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

final class AppStateTaskSwitchTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppStateTaskSwitchTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        // The settings are written 0.4 s after they change: let that write land before the folder goes.
        try await Task.sleep(nanoseconds: 600_000_000)
        try? FileManager.default.removeItem(at: folder)
    }

    /// An AppState with its files in `folder`, on Document to PDF with `count` photos of pages queued.
    @MainActor
    private func makeState(pages count: Int) async throws -> AppState {
        let state = AppState(presetStore: PresetStore(directory: folder), orientationScorer: SwitchScorer(),
                             barcodeReader: SwitchBarcodes(), files: AppStateFiles.all(in: folder))
        XCTAssertTrue(state.startTask(.document))
        state.settings.destinationPath = folder.path
        var pages: [ScannedPage] = []
        for _ in 0..<count {
            pages.append(switchPage())
        }
        XCTAssertTrue(state.ingest(pages, source: .photo))
        try await waitUntil(timeout: 60) { !state.isBusy }
        XCTAssertEqual(state.scannedPages.count, count)
        return state
    }

    @MainActor
    private func spoolFiles(_ state: AppState) -> [URL] {
        state.scannedPages.compactMap(\.fileURL)
    }

    @MainActor
    func test_aTaskThatCollectsPages_keepsTheQueue_itsFiles_theHistoryAndThePDFPicked() async throws {
        let state = try await makeState(pages: 2)
        let ids: [UUID] = state.scannedPages.map(\.id)
        let files: [URL] = spoolFiles(state)
        XCTAssertEqual(files.count, 2)
        let history: Int = state.scanHistory.count
        XCTAssertGreaterThan(history, 0)
        let target = folder.appendingPathComponent("Contract.pdf")
        state.setAppendTarget(target)

        XCTAssertEqual(state.pagesLeftBehind(by: .book), 0)
        XCTAssertTrue(state.startTask(.book))
        XCTAssertEqual(state.activeTask, .book)
        XCTAssertEqual(state.scannedPages.map(\.id), ids)
        for file in files {
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), file.lastPathComponent)
        }
        XCTAssertEqual(state.scanHistory.count, history)
        // Whether the PDF picked still takes the pages is the platform's call: the iPhone lets it go.
        XCTAssertEqual(state.appendTarget, target)

        XCTAssertTrue(state.startTask(.document))
        XCTAssertEqual(state.scannedPages.map(\.id), ids)
        XCTAssertTrue(state.canAppendPages)
    }

    @MainActor
    func test_aTaskThatDoesNotCollectPages_leavesThemBehind_untilDiscarded() async throws {
        let state = try await makeState(pages: 2)
        let files: [URL] = spoolFiles(state)
        let history: Int = state.scanHistory.count
        for task in [ScanTask.photos, .photoRestore, .receipt, .idCard, .quickScan, .copy] {
            XCTAssertEqual(state.pagesLeftBehind(by: task), 2, task.rawValue)
        }

        // A share or a send reading the spooled pages: nothing is dropped, nothing started.
        state.queueReaders = 1
        XCTAssertFalse(state.discardPages(andStart: .photos))
        XCTAssertEqual(state.activeTask, .document)
        XCTAssertEqual(state.scannedPages.count, 2)
        state.queueReaders = 0

        XCTAssertTrue(state.discardPages(andStart: .photos))
        XCTAssertEqual(state.activeTask, .photos)
        XCTAssertTrue(state.scannedPages.isEmpty)
        for file in files {
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), file.lastPathComponent)
        }
        XCTAssertEqual(state.scanHistory.count, history)
        XCTAssertEqual(state.pagesLeftBehind(by: .receipt), 0)
    }

    @MainActor
    func test_startTask_alone_neverDropsTheQueue() async throws {
        let state = try await makeState(pages: 1)
        let ids: [UUID] = state.scannedPages.map(\.id)
        XCTAssertTrue(state.startTask(.receipt))
        XCTAssertEqual(state.scannedPages.map(\.id), ids)
        XCTAssertEqual(state.pagesLeftBehind(by: .receipt), 1)
    }
}
