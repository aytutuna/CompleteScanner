import CoreGraphics
import Foundation
import XCTest
@testable import CompleteScannerKit

// The desktop's side of C1 through the app's state (AppState+CompanionHost.swift): a paired phone's
// document becomes queue pages with the bar's text, or waits. The C# twins are the CompanionPages
// cases of windows/CompleteScanner.App.Tests/CompanionAppTests.cs (the view model's queueing has no
// C# test). The documents are handed over as the server does, without a network. Every AppState
// here keeps its settings, presets and spool in a folder of its own.

private struct HostScorer: OrientationScorer {
    var isAvailable: Bool { false }

    func score(_ image: RgbaImage) throws -> OrientationScore {
        OrientationScore.none
    }
}

private struct HostBarcodes: BarcodeReader {
    var isAvailable: Bool { false }

    func read(_ image: GrayImage) throws -> [BarcodeReading] {
        []
    }
}

/// A light picture with a dark bar across it, `width` × `height` pixels.
private func hostPicture(width: Int, height: Int) -> CGImage {
    let space: CGColorSpace = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 0.95, green: 0.95, blue: 0.93, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1))
    context.fill(CGRect(x: width / 6, y: height / 2, width: width * 2 / 3, height: max(2, height / 25)))
    return context.makeImage()!
}

private func hostJPEG(width: Int, height: Int) -> CompanionImage {
    CompanionImage(data: PDFImageEncoding.encodeJPEG(hostPicture(width: width, height: height), quality: 0.9)!,
                   format: .jpeg, pixelWidth: width, pixelHeight: height, dpi: 200, colorMode: .color)
}

/// The document of CompanionAppTests.cs: a turned front, and a back with its photo.
private func hostDocument() -> CompanionDocument {
    CompanionDocument(title: "Receipt", pages: [
        CompanionPage(image: hostJPEG(width: 40, height: 60), rotationQuarterTurns: 1, side: .front, sheetIndex: 0),
        CompanionPage(image: hostJPEG(width: 40, height: 60), side: .back, sheetIndex: 0,
                      original: hostJPEG(width: 80, height: 100)),
    ], suggestedName: "Lunch 2026-10-20")
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

final class AppStateCompanionHostTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppStateCompanionHostTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        // The settings are written 0.4 s after they change: let that write land before the folder goes.
        try await Task.sleep(nanoseconds: 600_000_000)
        try? FileManager.default.removeItem(at: folder)
    }

    /// An AppState with its files in `folder`, collecting document pages, with `count` pages in its queue.
    @MainActor
    private func makeState(pages count: Int) async throws -> AppState {
        let state = AppState(presetStore: PresetStore(directory: folder), orientationScorer: HostScorer(),
                             barcodeReader: HostBarcodes(), files: AppStateFiles.all(in: folder))
        var settings = ScanSettings()
        settings.intent = .document
        settings.documentMultiPage = true
        settings.taskId = nil
        settings.source = .flatbed
        settings.duplex = .off
        settings.resolution = 75
        settings.format = .pdf
        settings.pdfSearchable = false
        settings.destinationPath = folder.path
        state.settings = settings
        var pages: [ScannedPage] = []
        for _ in 0..<count {
            pages.append(ScannedPage(image: hostPicture(width: 400, height: 520), dpi: 50, colorMode: .color))
        }
        if count > 0 {
            XCTAssertTrue(state.ingest(pages, source: .photo))
            try await waitUntil(timeout: 60) { !state.isBusy }
        }
        XCTAssertEqual(state.scannedPages.count, count)
        return state
    }

    /// A package as the inbox keeps it, sent as `target`.
    private func received(_ target: CompanionTarget = .new, id: String = "package-0001") throws -> ReceivedPackage {
        let document = hostDocument()
        let phoneFolder = folder.appendingPathComponent("Inbox/phone-0001", isDirectory: true)
        try FileManager.default.createDirectory(at: phoneFolder, withIntermediateDirectories: true)
        let url = phoneFolder.appendingPathComponent("\(id).\(CompanionPackage.fileExtension)")
        try CompanionPackage.make(document).write(to: url)
        return ReceivedPackage(deviceId: "phone-0001", packageId: id, url: url, document: document, target: target,
                               received: Date())
    }

    @MainActor
    func test_phoneDocument_becomesQueuePagesWithTheBar() async throws {
        let state = try await makeState(pages: 1)
        let queued = state.scannedPages.map(\.id)
        state.queuePhoneDocument(try received(), phoneName: "Aytu's iPhone")
        try await waitUntil(timeout: 60) { !state.isBusy && state.scannedPages.count == 3 }
        XCTAssertNil(state.errorMessage)
        XCTAssertEqual(Array(state.scannedPages.prefix(1).map(\.id)), queued)
        let added = Array(state.scannedPages.dropFirst())
        XCTAssertEqual(added.map(\.source), [.phone, .phone])
        XCTAssertEqual(added.map(\.documentBreak), [.split, .automatic])
        XCTAssertEqual(added.map(\.documentLabel), ["Lunch 2026-10-20", nil])
        XCTAssertTrue(added[1].canSwapVersions)
        XCTAssertEqual(state.phoneBarMessage, "2 pages from Aytu's iPhone added to the queue.")
        XCTAssertEqual(state.statusMessage, "2 pages from Aytu's iPhone added to the queue. 3 in queue.")
        XCTAssertNil(state.phoneDocumentsWaitingMessage)
        state.dismissPhoneBar()
        XCTAssertNil(state.phoneBarMessage)
    }

    @MainActor
    func test_phoneDocument_addedToTheCurrentOneJoinsIt() async throws {
        let state = try await makeState(pages: 1)
        state.queuePhoneDocument(try received(.current), phoneName: "Aytu's iPhone")
        try await waitUntil(timeout: 60) { !state.isBusy && state.scannedPages.count == 3 }
        let added = Array(state.scannedPages.dropFirst())
        XCTAssertEqual(added.map(\.documentBreak), [.automatic, .automatic])
        XCTAssertEqual(added.map(\.documentLabel), [nil, nil])
    }

    @MainActor
    func test_phoneDocument_waitsWhileBusy() async throws {
        let state = try await makeState(pages: 1)
        XCTAssertTrue(state.ingest([ScannedPage(image: hostPicture(width: 400, height: 520), dpi: 50, colorMode: .color)],
                                   source: .photo))
        XCTAssertTrue(state.isBusy)
        XCTAssertFalse(state.canTakePhonePages)
        state.queuePhoneDocument(try received(), phoneName: "Aytu's iPhone")
        XCTAssertEqual(state.phoneDocumentsWaitingMessage,
                       "2 pages from Aytu's iPhone will be added to the queue when the current step is done.")
        // Being busy passes on its own: nothing is shown on the bar for it.
        XCTAssertNil(state.phoneBarMessage)
        XCTAssertEqual(state.scannedPages.count, 1)
        try await waitUntil(timeout: 60) { !state.isBusy && state.scannedPages.count == 4 }
        XCTAssertNil(state.phoneDocumentsWaitingMessage)
        XCTAssertEqual(state.scannedPages.suffix(2).map(\.source), [.phone, .phone])
        XCTAssertEqual(state.phoneBarMessage, "2 pages from Aytu's iPhone added to the queue.")
    }

    @MainActor
    func test_phoneDocument_waitsWhileTheSettingsDoNotCollectPages() async throws {
        let state = try await makeState(pages: 0)
        state.settings.intent = .photo
        state.queuePhoneDocument(try received(), phoneName: "Aytu's iPhone")
        let waiting = "2 pages from Aytu's iPhone are waiting: choose Document mode, or a document task, "
            + "with Collect pages before saving on, to add them to the queue."
        XCTAssertEqual(state.phoneDocumentsWaitingMessage, waiting)
        XCTAssertEqual(state.phoneBarMessage, waiting)
        XCTAssertTrue(state.scannedPages.isEmpty)
        // Document mode again: the document is added within a second or so.
        state.settings.intent = .document
        try await waitUntil(timeout: 60) { !state.isBusy && state.scannedPages.count == 2 }
        XCTAssertEqual(state.scannedPages.map(\.documentLabel), ["Lunch 2026-10-20", nil])
        // The queue was empty: no split before the first page.
        XCTAssertEqual(state.scannedPages.map(\.documentBreak), [.automatic, .automatic])
        XCTAssertEqual(state.phoneBarMessage, "2 pages from Aytu's iPhone added to the queue.")
    }

    func test_waitingMessage_countsAndNames() {
        XCTAssertEqual(CompanionHostText.waitingMessage(pageCount: 1, from: "your phones", collectsPages: true),
                       "1 page from your phones will be added to the queue when the current step is done.")
        XCTAssertEqual(CompanionHostText.waitingMessage(pageCount: 1, from: "Aytu's iPhone", collectsPages: false),
                       "1 page from Aytu's iPhone is waiting: choose Document mode, or a document task, "
                           + "with Collect pages before saving on, to add it to the queue.")
    }
}
