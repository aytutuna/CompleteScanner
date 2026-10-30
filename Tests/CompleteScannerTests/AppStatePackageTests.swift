import CoreGraphics
import Foundation
import XCTest
@testable import CompleteScannerKit

// A .csdoc opened by hand and the queue written as one, through the app's state
// (AppState+Package.swift). Twin of windows/CompleteScanner.App.Tests/PackageAppTests.cs, which tests
// the same pieces without the view model (it reads the user's settings); adding and opening as new
// are tested here only. A package the Swift writer makes is read by the C# suite through the golden
// package: CompanionPackageTests.test_golden_packageBytesArePinned writes the bytes the C# suite reads.
// Every AppState here keeps its settings, presets and spool in a folder of its own and saves there.

private struct PackageScorer: OrientationScorer {
    var isAvailable: Bool { false }

    func score(_ image: RgbaImage) throws -> OrientationScore {
        OrientationScore.none
    }
}

private struct PackageBarcodes: BarcodeReader {
    var isAvailable: Bool { false }

    func read(_ image: GrayImage) throws -> [BarcodeReading] {
        []
    }
}

/// A light picture with a dark bar across it, `width` × `height` pixels.
private func packagePicture(width: Int, height: Int) -> CGImage {
    let space: CGColorSpace = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 0.95, green: 0.95, blue: 0.93, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1))
    context.fill(CGRect(x: width / 6, y: height / 2, width: width * 2 / 3, height: max(2, height / 25)))
    return context.makeImage()!
}

private func packageJPEG(width: Int, height: Int, dpi: Int = 200) -> CompanionImage {
    CompanionImage(data: PDFImageEncoding.encodeJPEG(packagePicture(width: width, height: height), quality: 0.9)!,
                   format: .jpeg, pixelWidth: width, pixelHeight: height, dpi: dpi, colorMode: .color)
}

/// The document PackageAppTests.cs packages too: a turned front, and a back with its photo.
private func packageDocument() -> CompanionDocument {
    CompanionDocument(title: "Receipt", pages: [
        CompanionPage(image: packageJPEG(width: 40, height: 60), rotationQuarterTurns: 1, side: .front, sheetIndex: 0),
        CompanionPage(image: packageJPEG(width: 40, height: 60), side: .back, sheetIndex: 0,
                      original: packageJPEG(width: 80, height: 100)),
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

final class AppStatePackageTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppStatePackageTests-\(UUID().uuidString)", isDirectory: true)
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
        let state = AppState(presetStore: PresetStore(directory: folder), orientationScorer: PackageScorer(),
                             barcodeReader: PackageBarcodes(), files: AppStateFiles.all(in: folder))
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
            pages.append(ScannedPage(image: packagePicture(width: 400, height: 520), dpi: 50, colorMode: .color))
        }
        if count > 0 {
            XCTAssertTrue(state.ingest(pages, source: .photo))
            try await waitUntil(timeout: 60) { !state.isBusy }
        }
        XCTAssertEqual(state.scannedPages.count, count)
        return state
    }

    private func write(_ name: String, _ package: Data) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try package.write(to: url)
        return url
    }

    @MainActor
    func test_openPackage_offersItsPagesWithoutTouchingTheQueue() async throws {
        let state = try await makeState(pages: 1)
        let queued = state.scannedPages.map(\.id)
        let url = try write("Receipt.csdoc", CompanionPackage.make(packageDocument()))
        await state.openPackage(at: url)
        XCTAssertNil(state.errorMessage)
        let offered = try XCTUnwrap(state.pendingPackage)
        XCTAssertEqual(offered.fileName, "Receipt.csdoc")
        XCTAssertEqual(offered.pageCount, 2)
        XCTAssertEqual(offered.documentName, "Lunch 2026-10-20")
        XCTAssertEqual(PackageText.openedMessage(offered.fileName, pageCount: offered.pageCount), "Opened Receipt.csdoc: 2 pages")
        XCTAssertEqual(PackageText.openedMessage(offered.fileName, pageCount: 1), "Opened Receipt.csdoc: 1 page")
        XCTAssertEqual(PackageText.addToPages, "Add to pages")
        XCTAssertEqual(PackageText.openAsNew, "Open as new")
        XCTAssertEqual(offered.pages.map(\.source), [.phone, .phone])
        XCTAssertEqual(offered.pages[0].image.width, 60)
        XCTAssertEqual(offered.pages[0].image.height, 40)
        XCTAssertTrue(offered.pages[1].canSwapVersions)
        XCTAssertEqual(offered.pages.map(\.documentLabel), [nil, nil])
        XCTAssertEqual(offered.asNewDocument.map(\.documentLabel), ["Lunch 2026-10-20", nil])
        XCTAssertEqual(state.scannedPages.map(\.id), queued)
        state.dismissPendingPackage()
        XCTAssertNil(state.pendingPackage)
    }

    @MainActor
    func test_addPendingPackageToPages_appendsAfterTheQueuedPages() async throws {
        let state = try await makeState(pages: 1)
        let queued = state.scannedPages.map(\.id)
        let url = try write("Receipt.csdoc", CompanionPackage.make(packageDocument()))
        await state.openPackage(at: url)
        let offered = try XCTUnwrap(state.pendingPackage)
        XCTAssertTrue(state.addPendingPackageToPages())
        try await waitUntil(timeout: 60) { !state.isBusy }
        XCTAssertNil(state.errorMessage)
        XCTAssertNil(state.pendingPackage)
        XCTAssertEqual(state.scannedPages.map(\.id), queued + offered.pages.map(\.id))
        XCTAssertEqual(state.scannedPages.dropFirst().map(\.source), [.phone, .phone])
        XCTAssertEqual(state.scannedPages.map(\.documentLabel), [nil, nil, nil])
        XCTAssertFalse(state.addPendingPackageToPages())
    }

    @MainActor
    func test_openPendingPackageAsNew_replacesTheQueue() async throws {
        let state = try await makeState(pages: 2)
        let url = try write("Receipt.csdoc", CompanionPackage.make(packageDocument()))
        await state.openPackage(at: url)
        let offered = try XCTUnwrap(state.pendingPackage)
        XCTAssertTrue(state.openPendingPackageAsNew())
        try await waitUntil(timeout: 60) { !state.isBusy }
        XCTAssertNil(state.errorMessage)
        XCTAssertNil(state.pendingPackage)
        XCTAssertEqual(state.scannedPages.map(\.id), offered.pages.map(\.id))
        XCTAssertEqual(state.scannedPages.map(\.documentLabel), ["Lunch 2026-10-20", nil])
    }

    @MainActor
    func test_pendingPackage_waitsWhileTheSettingsDoNotCollectPages() async throws {
        let state = try await makeState(pages: 1)
        let url = try write("Receipt.csdoc", CompanionPackage.make(packageDocument()))
        await state.openPackage(at: url)
        state.settings.intent = .photo
        XCTAssertFalse(state.openPendingPackageAsNew())
        XCTAssertEqual(state.errorMessage, PackageText.notOfferedMessage)
        XCTAssertNotNil(state.pendingPackage)
        XCTAssertEqual(state.scannedPages.count, 1)
        // Without Collect pages before saving the pages would be saved at once, not queued.
        state.settings.intent = .document
        state.settings.documentMultiPage = false
        state.errorMessage = nil
        XCTAssertFalse(state.addPendingPackageToPages())
        XCTAssertEqual(state.errorMessage, PackageText.notOfferedMessage)
        XCTAssertNotNil(state.pendingPackage)
        XCTAssertEqual(state.scannedPages.count, 1)
    }

    @MainActor
    func test_pendingPackage_waitsWhileBusy_andOpensWhileBusy() async throws {
        let state = try await makeState(pages: 1)
        let url = try write("Receipt.csdoc", CompanionPackage.make(packageDocument()))
        await state.openPackage(at: url)
        XCTAssertTrue(state.ingest([ScannedPage(image: packagePicture(width: 400, height: 520), dpi: 50, colorMode: .color)],
                                   source: .photo))
        XCTAssertTrue(state.isBusy)
        XCTAssertFalse(state.addPendingPackageToPages())
        XCTAssertFalse(state.openPendingPackageAsNew())
        XCTAssertNil(state.errorMessage)
        XCTAssertEqual(state.pendingPackage?.pageCount, 2)
        // Opening again while the page is processed offers the file afresh.
        state.dismissPendingPackage()
        await state.openPackage(at: url)
        XCTAssertEqual(state.pendingPackage?.pageCount, 2)
        try await waitUntil(timeout: 60) { !state.isBusy }
        XCTAssertEqual(state.scannedPages.count, 2)
        XCTAssertTrue(state.addPendingPackageToPages())
        try await waitUntil(timeout: 60) { !state.isBusy }
        XCTAssertNil(state.pendingPackage)
        XCTAssertEqual(state.scannedPages.count, 4)
    }

    @MainActor
    func test_newerPackage_isRefusedWithTheMessage() async throws {
        let state = try await makeState(pages: 0)
        var entries = try CompanionPackage.entries(packageDocument())
        let manifest = String(decoding: entries[0].data, as: UTF8.self)
            .replacingOccurrences(of: "\"formatVersion\":1", with: "\"formatVersion\":2")
        entries[0] = ZipStoreEntry(name: entries[0].name, data: Data(manifest.utf8))
        let url = try write("Newer.csdoc", ZipStore.make(entries))
        await state.openPackage(at: url)
        XCTAssertNil(state.pendingPackage)
        XCTAssertEqual(state.errorMessage,
                       "This document was made by a newer version of Lazy Scan (package format 2). Update Lazy Scan to open it.")
    }

    @MainActor
    func test_packageWithAPictureThatCannotBeDecoded_isRefused() async throws {
        let state = try await makeState(pages: 0)
        let broken = Data([0xFF, 0xD8, 0xFF, 0xE0, 0, 0, 0, 0])
        let document = CompanionDocument(title: "Scan", pages: [CompanionPage(image: CompanionImage(
            data: broken, format: .jpeg, pixelWidth: 8, pixelHeight: 8, dpi: 300, colorMode: .color))])
        let url = try write("Broken.csdoc", CompanionPackage.make(document))
        await state.openPackage(at: url)
        XCTAssertNil(state.pendingPackage)
        XCTAssertEqual(state.errorMessage, "Broken.csdoc cannot be opened: one of its pictures cannot be read.")
    }

    @MainActor
    func test_packageWithAPictureThatClaimsTooManyPixels_isRefused() async throws {
        let state = try await makeState(pages: 0)
        // A real JPEG whose start-of-frame is changed to claim 20000 × 10000 pixels.
        var bytes = [UInt8](packageJPEG(width: 40, height: 30).data)
        let sof = try XCTUnwrap((2..<bytes.count - 9).first { bytes[$0] == 0xFF && bytes[$0 + 1] == 0xC0 })
        bytes.replaceSubrange(sof + 5..<sof + 9, with: [0x27, 0x10, 0x4E, 0x20])
        let document = CompanionDocument(title: "Scan", pages: [CompanionPage(image: CompanionImage(
            data: Data(bytes), format: .jpeg, pixelWidth: 40, pixelHeight: 30, dpi: 200, colorMode: .color))])
        let url = try write("Huge.csdoc", CompanionPackage.make(document))
        await state.openPackage(at: url)
        XCTAssertNil(state.pendingPackage)
        XCTAssertEqual(state.errorMessage, "Huge.csdoc cannot be opened: one of its pictures cannot be read.")
    }

    @MainActor
    func test_exportPackage_writesTheQueueThatOpensAgain() async throws {
        let state = try await makeState(pages: 2)
        let pages = state.scannedPages
        let url = try await state.exportPackage(to: folder)
        XCTAssertEqual(url.pathExtension, "csdoc")
        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL, folder.standardizedFileURL)
        let read = try CompanionPackage.read(contentsOf: url)
        let name = url.deletingPathExtension().lastPathComponent
        XCTAssertEqual(read.title, name)
        XCTAssertEqual(read.suggestedName, name)
        XCTAssertEqual(read.namingTemplate, state.settings.namingTemplate)
        XCTAssertEqual(read.pages.count, 2)
        XCTAssertEqual(read.pages.map(\.image.format), [.jpeg, .jpeg])
        XCTAssertEqual(read.pages.map(\.image.dpi), pages.map(\.dpi))
        for (page, packaged) in zip(pages, read.pages) {
            let full = AppState.fullImage(of: page)
            XCTAssertEqual(packaged.image.pixelWidth, full.width)
            XCTAssertEqual(packaged.image.pixelHeight, full.height)
        }
        // A second export the same moment takes the next free name.
        let again = try await state.exportPackage(to: folder)
        XCTAssertNotEqual(again, url)

        await state.openPackage(at: url)
        XCTAssertEqual(state.pendingPackage?.pageCount, 2)
        XCTAssertEqual(state.pendingPackage?.documentName, name)
    }

    func test_packageDocument_writesBlackAndWhiteAsTIFF_andKeepsSideAndSheet() throws {
        var front = ScannedPage(image: packagePicture(width: 64, height: 32), dpi: 300, colorMode: .blackWhite)
        front.side = .front
        front.sheetIndex = 0
        var back = ScannedPage(image: packagePicture(width: 40, height: 60), dpi: 150, colorMode: .grayscale)
        back.side = .back
        back.sheetIndex = 0
        let document = try AppState.packageDocument([front, back], name: "Scan 7", jpegQuality: 0.9)
        let read = try CompanionPackage.read(CompanionPackage.make(document))
        XCTAssertEqual(read.pages.map(\.image.format), [.tiff, .jpeg])
        XCTAssertEqual(read.pages.map(\.image.colorMode), [.blackWhite, .grayscale])
        XCTAssertEqual(read.pages.map(\.image.dpi), [300, 150])
        XCTAssertEqual(read.pages.map(\.side), [.front, .back])
        XCTAssertEqual(read.pages.map(\.sheetIndex), [0, 0])
        XCTAssertEqual(read.pages[0].image.pixelWidth, 64)
        XCTAssertEqual(read.pages[0].image.pixelHeight, 32)
    }

    @MainActor
    func test_exportPackage_refusesAPageWhoseSpoolFileWent() async throws {
        let state = try await makeState(pages: 2)
        let url = try XCTUnwrap(state.scannedPages[1].fileURL)
        try FileManager.default.removeItem(at: url)
        do {
            _ = try await state.exportPackage(to: folder)
            XCTFail("Not refused")
        } catch let error as CompanionPackageError {
            XCTAssertEqual(error.message, "\(CompanionPackage.subject(2, original: false)) could not be written.")
        }
    }

    @MainActor
    func test_exportPackage_refusesAnEmptyQueue() async throws {
        let state = try await makeState(pages: 0)
        do {
            _ = try await state.exportPackage(to: folder)
            XCTFail("Not refused")
        } catch let error as CompanionPackageError {
            XCTAssertEqual(error.message, CompanionPackage.noPagesMessage)
        }
    }
}
