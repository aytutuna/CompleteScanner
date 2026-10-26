import CoreGraphics
import Foundation
import XCTest
@testable import CompleteScannerKit

// A camera's queued page cut out of its photo again with another filter or along new corners
// (AppState+Recut.swift). Swift only: the Windows app takes no camera shots.

private struct RecutScorer: OrientationScorer {
    var isAvailable: Bool { false }

    func score(_ image: RgbaImage) throws -> OrientationScore {
        OrientationScore.none
    }
}

private struct RecutBarcodes: BarcodeReader {
    var isAvailable: Bool { false }

    func read(_ image: GrayImage) throws -> [BarcodeReading] {
        []
    }
}

private func pixels(_ image: CGImage) -> [UInt8] {
    RgbaImage(cgImage: image)!.pixels
}

/// The shadowed page on a table, as the camera takes it: the photo and the shot with its corners.
private func shot() -> (photo: CGImage, page: ScannedPage) {
    let table: TablePhoto = CameraSheets.squareOnATable(EnhancerPages.shadowed())
    let photo: CGImage = table.photo.makeCGImage()!
    var page = ScannedPage(image: photo, dpi: CaptureScale.nominalDPI, colorMode: .color)
        .withCapture(CaptureFacts(quad: table.quad, sourceWidth: table.photo.width, sourceHeight: table.photo.height))
    page.source = .photo
    return (photo, page)
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

final class PageRecutTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("PageRecutTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try await Task.sleep(nanoseconds: 600_000_000)
        try? FileManager.default.removeItem(at: folder)
    }

    func testOriginalIsTheCutWithNoCleanUp_andTheFiltersGoBackAndForth() throws {
        let (photo, page) = shot()
        let cut: ScannedPage = PerspectiveStep().apply(page)
        let enhanced: ScannedPage = try XCTUnwrap(PageProcessor.forCapture(ScanSettings()).process([page]).pages.first)
        XCTAssertEqual(PageRecut.filter(of: enhanced), .enhanced)

        let original: ScannedPage = try XCTUnwrap(PageRecut.recut(enhanced, photo: photo, filter: .original))
        XCTAssertEqual(pixels(original.image), pixels(cut.image))
        XCTAssertEqual(original.capture?.filter, .original)
        XCTAssertNil(original.capture?.enhancement)
        XCTAssertEqual(original.colorMode, .color)
        XCTAssertEqual(original.dpi, cut.dpi)
        XCTAssertEqual(original.geometry, cut.geometry)
        XCTAssertEqual(original.id, page.id)
        XCTAssertTrue(original.alternate?.image === enhanced.alternate?.image)
        XCTAssertEqual(original.blank, enhanced.blank)

        let gray: ScannedPage = try XCTUnwrap(PageRecut.recut(original, photo: photo, filter: .grayscale))
        XCTAssertEqual(pixels(gray.image), DocumentEnhancer.enhance(RgbaImage(cgImage: cut.image)!, mode: .gray).image.pixels)
        XCTAssertEqual(gray.colorMode, .grayscale)
        XCTAssertEqual(PageRecut.filter(of: gray), .grayscale)
        XCTAssertEqual(try XCTUnwrap(PageRecut.recut(gray, photo: photo, filter: .blackAndWhite)).colorMode, .blackWhite)

        let back: ScannedPage = try XCTUnwrap(PageRecut.recut(gray, photo: photo, filter: .original))
        XCTAssertEqual(pixels(back.image), pixels(cut.image))
        XCTAssertEqual(back.colorMode, .color)
        let again: ScannedPage = try XCTUnwrap(PageRecut.recut(back, photo: photo, filter: .enhanced))
        XCTAssertEqual(pixels(again.image), pixels(enhanced.image))
        XCTAssertEqual(again.capture, enhanced.capture)
    }

    func testAPageTurnedUpright_isCutInTheTurnItsFileHolds() throws {
        let (photo, page) = shot()
        let enhanced: ScannedPage = try XCTUnwrap(PageProcessor.forCapture(ScanSettings()).process([page]).pages.first)
        let turned: ScannedPage = enhanced.turnedUpright(1)
        let stored: CGImage = ImagePipeline.rotate(photo, quarterTurns: 1)
        let recut: ScannedPage = try XCTUnwrap(PageRecut.recut(turned, photo: stored, filter: .enhanced))
        XCTAssertEqual(pixels(recut.image), pixels(turned.image))
        XCTAssertEqual(recut.upright, turned.upright)
        // A smaller copy of the photo gives the page at its size.
        let small: CGImage = AppState.makePreview(stored, maxSide: stored.width / 2)!
        let preview: ScannedPage = try XCTUnwrap(PageRecut.recut(turned, photo: small, filter: .original))
        XCTAssertLessThan(preview.image.width, recut.image.width)
        XCTAssertGreaterThan(preview.image.width, preview.image.height)
    }

    func testCrop_cutsAlongNewCorners_andKeepsTheFilter() throws {
        let (photo, page) = shot()
        var settings = ScanSettings()
        settings.taskOptions.cameraFilter = .original
        let original: ScannedPage = try XCTUnwrap(PageProcessor.forCapture(settings).process([page]).pages.first)
        let facts: CaptureFacts = try XCTUnwrap(page.capture)
        let inner = Quad(topLeft: CGPoint(x: 80, y: 80), topRight: CGPoint(x: 260, y: 80),
                         bottomRight: CGPoint(x: 260, y: 330), bottomLeft: CGPoint(x: 80, y: 330))
        let cropped: ScannedPage = try XCTUnwrap(PageRecut.recut(original, photo: photo, filter: .original, corners: inner))
        XCTAssertEqual(cropped.capture?.quad, inner)
        XCTAssertEqual(cropped.geometry?.quad, inner)
        XCTAssertEqual(cropped.capture?.filter, .original)
        XCTAssertLessThan(cropped.image.width, original.image.width)
        // Corners placed on the photo turned as the page is shown are put back on the photo as taken.
        for turns in 0..<4 {
            let shown: Quad = facts.oriented(PhotoOrientation(quarterTurns: turns, mirrored: false)).quad
            XCTAssertLessThan(PageRecut.cornersAsTaken(shown, facts: facts, quarterTurns: turns).maxCornerDistance(facts.quad), 1e-9)
        }
    }

    func testOnlyACameraPageWithAFilterCanBeCutAgain() throws {
        let (_, page) = shot()
        let scanned = ScannedPage(image: page.image, dpi: 300, colorMode: .color)
        XCTAssertNil(PageRecut.filter(of: scanned))
        XCTAssertFalse(PageRecut.canRecut(scanned))
        let enhanced: ScannedPage = try XCTUnwrap(PageProcessor.forCapture(ScanSettings()).process([page]).pages.first)
        // In memory only, it has no files to cut from and to replace.
        XCTAssertFalse(PageRecut.canRecut(enhanced))
        // A photo print is a photo: no filter.
        let print: ScannedPage = page.withCapture(CaptureFacts(quad: page.capture!.quad, sourceWidth: page.image.width,
                                                                sourceHeight: page.image.height, kind: .photo))
        XCTAssertNil(PageRecut.filter(of: EnhanceStep(mode: .auto).apply(PerspectiveStep().apply(print))))
        // Queued before filters: the clean-up it had.
        var older: CaptureFacts = try XCTUnwrap(enhanced.capture)
        older.filter = nil
        older.enhancement = .gray
        XCTAssertEqual(PageRecut.filter(of: enhanced.withCapture(older)), .grayscale)
        XCTAssertEqual(PageRecut.filterNote(.blackAndWhite, number: 3), "Page 3: B&W.")
        XCTAssertEqual(PageRecut.cropNote(number: 2), "Page 2 is cut out again.")
    }

    @MainActor
    func testAQueuedPage_takesAnotherFilter_keepsItsPhoto_andTheRecordKeepsIt() async throws {
        var files = AppStateFiles.all(in: folder)
        files.keepsQueue = true
        let state = AppState(presetStore: PresetStore(directory: folder), orientationScorer: RecutScorer(),
                             barcodeReader: RecutBarcodes(), files: files)
        XCTAssertTrue(state.startTask(.document))
        state.settings.taskOptions.cameraFilter = .original
        state.settings.destinationPath = folder.path
        let (photo, taken) = shot()
        XCTAssertTrue(state.ingest([taken], source: .photo))
        try await waitUntil(timeout: 60) { !state.isBusy && state.scannedPages.count == 1 }
        defer { state.deleteSpoolFiles(of: state.scannedPages) }
        let page: ScannedPage = state.scannedPages[0]
        XCTAssertEqual(PageRecut.filter(of: page), .original)
        XCTAssertTrue(PageRecut.canRecut(page))
        let firstFile: URL = try XCTUnwrap(page.fileURL)
        let photoFile: URL = try XCTUnwrap(page.alternate?.fileURL)
        let firstPixels: [UInt8] = pixels(try XCTUnwrap(AppState.imageInFile(firstFile)))

        state.setPageFilter(id: page.id, .grayscale)
        try await waitUntil(timeout: 60) { state.scannedPages.first?.capture?.filter == .grayscale }
        let gray: ScannedPage = state.scannedPages[0]
        XCTAssertEqual(gray.id, page.id)
        XCTAssertEqual(gray.colorMode, .grayscale)
        XCTAssertNotEqual(gray.fileURL, firstFile)
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(gray.fileURL).path))
        XCTAssertEqual(gray.alternate?.fileURL, photoFile)
        XCTAssertTrue(FileManager.default.fileExists(atPath: photoFile.path))
        XCTAssertEqual(state.statusMessage, "Page 1: Grayscale.")
        XCTAssertTrue(state.recuttingPages.isEmpty)

        // Gray, then Enhanced and back to Gray before the first lands: the last tap wins.
        state.setPageFilter(id: page.id, .enhanced)
        state.setPageFilter(id: page.id, .grayscale)
        try await waitUntil(timeout: 60) { state.pageEditChain == nil }
        XCTAssertEqual(state.scannedPages.first?.capture?.filter, .grayscale)
        XCTAssertEqual(state.scannedPages.first?.colorMode, .grayscale)

        let data = try Data(contentsOf: state.spoolDirectory.appendingPathComponent(QueueRecord.fileName))
        let record: QueueRecord = try JSONDecoder().decode(QueueRecord.self, from: data)
        XCTAssertEqual(record.pages.first?.capture?.filter, .grayscale)
        XCTAssertEqual(record.pages.first?.file, state.scannedPages.first?.fileURL?.lastPathComponent)

        state.setPageFilter(id: page.id, .original)
        try await waitUntil(timeout: 60) { state.scannedPages.first?.capture?.filter == .original }
        let back: ScannedPage = state.scannedPages[0]
        XCTAssertEqual(back.colorMode, .color)
        XCTAssertEqual(pixels(try XCTUnwrap(AppState.imageInFile(try XCTUnwrap(back.fileURL)))), firstPixels)

        let previews: [CaptureFilter: CGImage] = await state.filterPreviews(id: page.id, maxSide: 80)
        XCTAssertEqual(Set(previews.keys), Set(CaptureFilter.allCases))

        let cropStart: PhotoCropStart? = await state.pageCropStart(id: page.id)
        let start: PhotoCropStart = try XCTUnwrap(cropStart)
        XCTAssertEqual(start.source.width, photo.width)
        XCTAssertLessThan(start.corners.maxCornerDistance(try XCTUnwrap(taken.capture).quad), 1e-9)
        let inner = Quad(topLeft: CGPoint(x: 80, y: 80), topRight: CGPoint(x: 260, y: 80),
                         bottomRight: CGPoint(x: 260, y: 330), bottomLeft: CGPoint(x: 80, y: 330))
        // Corners placed while the page had another turn are not used.
        state.recropPage(id: page.id, corners: inner, rotation: 1)
        XCTAssertNil(state.pageEditChain)
        state.recropPage(id: page.id, corners: inner, rotation: 0)
        try await waitUntil(timeout: 60) { state.scannedPages.first?.geometry?.quad == inner }
        XCTAssertEqual(state.scannedPages[0].capture?.filter, .original)
        XCTAssertEqual(state.statusMessage, "Page 1 is cut out again.")
    }
}
