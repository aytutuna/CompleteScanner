#if os(iOS)
import CoreGraphics
import Foundation
import UniformTypeIdentifiers
import XCTest
@testable import LazyScanIOS
@testable import LazyScanKit

// Importing photos into the queue on the iPhone (`IOSImportSession`): each photo read, its page found,
// the corner editor asked, and the page brought in through `AppState.ingest` with its capture facts, so
// the clean-up stage cuts it out at its real size; Use whole photo, Skip and Stop; what arrives during
// an import waits for it; each page of a TIFF; no editor while the state cannot take pages; files that
// cannot be read; settings that collect no pages; the page finder's parts. The page search is a stand-in here
// where a test needs known corners; the corner model's own answer is not asserted (it may not be fetched).

/// A 600 × 450 photo with an A4-shaped sheet (200 × 283 px) square on.
private let sheetCorners: [CGPoint] = [CGPoint(x: 150, y: 80), CGPoint(x: 350, y: 80), CGPoint(x: 350, y: 363),
                                       CGPoint(x: 150, y: 363)]
private let sheetQuad = Quad(topLeft: sheetCorners[0], topRight: sheetCorners[1], bottomRight: sheetCorners[2],
                             bottomLeft: sheetCorners[3])

private func sheetPNG() -> Data {
    let photo: CGImage = ImportTestSupport.sheetPhoto(width: 600, height: 450, corners: sheetCorners)
    return ImportTestSupport.file(UTType.png, images: [photo])
}

/// A page search that answers `corners` with `reason`.
private func fixedFinder(_ corners: Quad, reason: PhotoReviewReason) -> @Sendable (RgbaImage) -> IOSFoundPage {
    let found = IOSFoundPage(corners: corners, reason: reason, byModel: false)
    return { (_: RgbaImage) -> IOSFoundPage in
        found
    }
}

final class IOSImportSessionTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = try ImportTestSupport.makeFolder("IOSImportSessionTests")
    }

    override func tearDown() async throws {
        // The settings are written 0.4 s after they change: let that write land before the folder goes.
        try await Task.sleep(nanoseconds: 600_000_000)
        try? FileManager.default.removeItem(at: folder)
    }

    @MainActor
    func test_aPhoto_goesThroughTheCornerEditor_andIsCutOutAtItsRealSize() async throws {
        let state: AppState = ImportTestSupport.makeState(in: folder)
        // The corners as a finger might leave them: starting at the bottom left, the other way round.
        let placed = Quad(topLeft: sheetCorners[3], topRight: sheetCorners[2], bottomRight: sheetCorners[1],
                          bottomLeft: sheetCorners[0])
        let importer = IOSImportSession(state: state, finder: fixedFinder(sheetQuad, reason: .unsure))
        XCTAssertTrue(importer.canImport)
        let item = IOSImportItem(name: "sheet.png", data: sheetPNG(), kind: .image)
        let importing: Task<IOSImportOutcome, Never> = Task { @MainActor in
            await importer.importItems([item])
        }
        try await ImportTestSupport.waitUntil(timeout: 60) { importer.cornerRequest != nil }
        let request: PhotoCornersRequest = try XCTUnwrap(importer.cornerRequest)
        XCTAssertEqual(request.plan.corners, sheetQuad)
        XCTAssertEqual(request.plan.reason, .unsure)
        XCTAssertEqual(request.fileName, "sheet.png")
        XCTAssertEqual(request.number, 1)
        XCTAssertEqual(request.count, 1)
        XCTAssertEqual(request.photo.width, 600)
        XCTAssertEqual(request.photo.height, 450)
        XCTAssertTrue(importer.isImporting)
        XCTAssertFalse(importer.canImport)
        XCTAssertEqual(importer.progressText, PhotoImport.progressMessage(1, of: 1))
        // A file, not a shot, and nothing after it: Skip photo and no Stop.
        XCTAssertFalse(importer.importsShot)
        XCTAssertFalse(importer.canStop)

        importer.answer(PhotoCornersAnswer(choice: .useCorners, corners: placed))
        XCTAssertNil(importer.cornerRequest)
        let outcome: IOSImportOutcome = await importing.value
        XCTAssertEqual(outcome.added, 1)
        XCTAssertEqual(outcome.skipped, 0)
        XCTAssertEqual(outcome.problems, [])
        XCTAssertFalse(importer.isImporting)
        XCTAssertNil(importer.progressText)
        XCTAssertNil(state.errorMessage)

        defer { state.deleteSpoolFiles(of: state.scannedPages) }
        let page: ScannedPage = try XCTUnwrap(state.scannedPages.first)
        XCTAssertEqual(page.source, .photo)
        let capture: CaptureFacts = try XCTUnwrap(page.capture)
        // The corners named again, in the photo's pixels, with the photo's size.
        XCTAssertEqual(capture.quad, sheetQuad)
        XCTAssertEqual(capture.sourceWidth, 600)
        XCTAssertEqual(capture.sourceHeight, 450)
        XCTAssertEqual(capture.kind, .document)
        XCTAssertNil(capture.focalLength)
        let scale: CaptureScaleResult = try XCTUnwrap(capture.scale)
        XCTAssertEqual(scale.size, "a4")
        XCTAssertEqual(page.dpi, scale.dpi)
        XCTAssertEqual(page.geometry?.basis, .perspective)
        XCTAssertEqual(page.fullPixelSize, CGSize(width: scale.pixelWidth, height: scale.pixelHeight))
        XCTAssertEqual(importer.lastOutcome, outcome)
    }

    @MainActor
    func test_skip_thenWholePhoto_countsEachPhoto() async throws {
        let state: AppState = ImportTestSupport.makeState(in: folder)
        let importer = IOSImportSession(state: state, finder: fixedFinder(sheetQuad, reason: .none))
        let data: Data = sheetPNG()
        let items: [IOSImportItem] = [IOSImportItem(name: "a.png", data: data, kind: .image),
                                      IOSImportItem(name: "b.png", data: data, kind: .image)]
        let importing: Task<IOSImportOutcome, Never> = Task { @MainActor in
            await importer.importItems(items)
        }
        try await ImportTestSupport.waitUntil(timeout: 60) { importer.cornerRequest != nil }
        XCTAssertEqual(importer.cornerRequest?.fileName, "a.png")
        importer.answer(PhotoCornersAnswer.skip)
        try await ImportTestSupport.waitUntil(timeout: 60) { importer.cornerRequest != nil }
        let second: PhotoCornersRequest = try XCTUnwrap(importer.cornerRequest)
        XCTAssertEqual(second.fileName, "b.png")
        XCTAssertEqual(second.number, 2)
        XCTAssertEqual(second.count, 2)
        XCTAssertEqual(importer.progressText, PhotoImport.progressMessage(2, of: 2))
        importer.answer(PhotoCornersAnswer(choice: .wholePhoto))
        // A second answer changes nothing.
        importer.answer(PhotoCornersAnswer.skip)
        let outcome: IOSImportOutcome = await importing.value
        XCTAssertEqual(outcome.added, 1)
        XCTAssertEqual(outcome.skipped, 1)
        defer { state.deleteSpoolFiles(of: state.scannedPages) }
        let page: ScannedPage = try XCTUnwrap(state.scannedPages.first)
        XCTAssertEqual(state.scannedPages.count, 1)
        XCTAssertNil(page.capture)
        XCTAssertNil(page.geometry)
        XCTAssertEqual(page.dpi, PhotoImport.wholePhotoDPI(width: 600, height: 450))
        XCTAssertEqual(page.fullPixelSize, CGSize(width: 600, height: 450))
    }

    @MainActor
    func test_stop_endsTheImport_afterThePhotoInHand() async throws {
        let state: AppState = ImportTestSupport.makeState(in: folder)
        let importer = IOSImportSession(state: state, finder: fixedFinder(sheetQuad, reason: .none))
        let data: Data = sheetPNG()
        let items: [IOSImportItem] = [IOSImportItem(name: "a.png", data: data, kind: .image),
                                      IOSImportItem(name: "b.png", data: data, kind: .image)]
        let importing: Task<IOSImportOutcome, Never> = Task { @MainActor in
            await importer.importItems(items)
        }
        try await ImportTestSupport.waitUntil(timeout: 60) { importer.cornerRequest != nil }
        // Another photo follows the one in hand: the editor offers Stop.
        XCTAssertTrue(importer.canStop)
        XCTAssertFalse(importer.importsShot)
        importer.stop()
        let outcome: IOSImportOutcome = await importing.value
        XCTAssertEqual(outcome.added, 0)
        XCTAssertEqual(outcome.skipped, 1)
        XCTAssertNil(importer.cornerRequest)
        XCTAssertFalse(importer.canStop)
        XCTAssertTrue(state.scannedPages.isEmpty)
    }

    @MainActor
    func test_whatArrivesDuringAnImport_waits_andComesInAfterIt() async throws {
        let state: AppState = ImportTestSupport.makeState(in: folder)
        let importer = IOSImportSession(state: state, finder: fixedFinder(sheetQuad, reason: .none))
        let data: Data = sheetPNG()
        let importing: Task<IOSImportOutcome, Never> = Task { @MainActor in
            await importer.importItems([IOSImportItem(name: "a.png", data: data, kind: .image)])
        }
        try await ImportTestSupport.waitUntil(timeout: 60) { importer.cornerRequest != nil }
        XCTAssertFalse(importer.canStop)
        // A file opened in the app ("Open in Lazy Scan") while the editor waits: it waits too,
        // unread, and nothing is said yet; the editor in view now offers Stop.
        let url: URL = folder.appendingPathComponent("b.png")
        try data.write(to: url)
        let queued: IOSImportOutcome = await importer.importFiles([url])
        XCTAssertEqual(queued, IOSImportOutcome())
        XCTAssertEqual(importer.waitingCount, 1)
        XCTAssertNil(state.errorMessage)
        XCTAssertTrue(importer.canStop)
        XCTAssertEqual(importer.cornerRequest?.fileName, "a.png")
        importer.answer(PhotoCornersAnswer.skip)
        try await ImportTestSupport.waitUntil(timeout: 60) { importer.cornerRequest != nil }
        let second: PhotoCornersRequest = try XCTUnwrap(importer.cornerRequest)
        XCTAssertEqual(second.fileName, "b.png")
        XCTAssertEqual(second.number, 2)
        XCTAssertEqual(second.count, 2)
        XCTAssertEqual(importer.waitingCount, 0)
        XCTAssertFalse(importer.canStop)
        importer.answer(PhotoCornersAnswer(choice: .wholePhoto))
        let outcome: IOSImportOutcome = await importing.value
        XCTAssertEqual(outcome.added, 1)
        XCTAssertEqual(outcome.skipped, 1)
        XCTAssertFalse(importer.isImporting)
        defer { state.deleteSpoolFiles(of: state.scannedPages) }
        XCTAssertEqual(state.scannedPages.count, 1)
    }

    @MainActor
    func test_stop_dropsWhatWaits_andWhatComesAfterIsANewImport() async throws {
        let state: AppState = ImportTestSupport.makeState(in: folder)
        let importer = IOSImportSession(state: state, finder: fixedFinder(sheetQuad, reason: .none))
        let data: Data = sheetPNG()
        let importing: Task<IOSImportOutcome, Never> = Task { @MainActor in
            await importer.importItems([IOSImportItem(name: "a.png", data: data, kind: .image),
                                        IOSImportItem(name: "b.png", data: data, kind: .image)])
        }
        try await ImportTestSupport.waitUntil(timeout: 60) { importer.cornerRequest != nil }
        await importer.importPicked([data])
        XCTAssertEqual(importer.waitingCount, 2)
        importer.stop()
        XCTAssertEqual(importer.waitingCount, 0)
        XCTAssertNil(importer.cornerRequest)
        // Opened in the app just after Stop: imported, counted afresh.
        await importer.importItems([IOSImportItem(name: "d.png", data: data, kind: .image)])
        try await ImportTestSupport.waitUntil(timeout: 60) { importer.cornerRequest != nil }
        let after: PhotoCornersRequest = try XCTUnwrap(importer.cornerRequest)
        XCTAssertEqual(after.fileName, "d.png")
        XCTAssertEqual(after.number, 1)
        XCTAssertEqual(after.count, 1)
        importer.answer(PhotoCornersAnswer.skip)
        let outcome: IOSImportOutcome = await importing.value
        XCTAssertEqual(outcome.added, 0)
        XCTAssertEqual(outcome.skipped, 2)
        XCTAssertTrue(state.scannedPages.isEmpty)
        // Stop with no import running changes nothing.
        importer.stop()
        XCTAssertFalse(importer.isImporting)
    }

    @MainActor
    func test_aTiffOfSeveralPages_bringsEachPageThroughTheEditor() async throws {
        let state: AppState = ImportTestSupport.makeState(in: folder)
        let importer = IOSImportSession(state: state, finder: fixedFinder(sheetQuad, reason: .none))
        let photo: CGImage = ImportTestSupport.sheetPhoto(width: 600, height: 450, corners: sheetCorners)
        let tiff: Data = ImportTestSupport.file(UTType.tiff, images: [photo, photo])
        let importing: Task<IOSImportOutcome, Never> = Task { @MainActor in
            await importer.importItems([IOSImportItem(name: "fax.tif", data: tiff, kind: .image)])
        }
        try await ImportTestSupport.waitUntil(timeout: 60) { importer.cornerRequest != nil }
        let first: PhotoCornersRequest = try XCTUnwrap(importer.cornerRequest)
        XCTAssertEqual(first.fileName, "fax.tif, page 1 of 2")
        XCTAssertEqual(first.number, 1)
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(importer.progressText, PhotoImport.progressMessage(1, of: 1, page: 1, pageCount: 2))
        // Stop while a page follows, not on the last.
        XCTAssertTrue(importer.canStop)
        importer.answer(PhotoCornersAnswer(choice: .wholePhoto))
        try await ImportTestSupport.waitUntil(timeout: 60) { importer.cornerRequest != nil }
        let second: PhotoCornersRequest = try XCTUnwrap(importer.cornerRequest)
        XCTAssertEqual(second.fileName, "fax.tif, page 2 of 2")
        XCTAssertEqual(importer.progressText, PhotoImport.progressMessage(1, of: 1, page: 2, pageCount: 2))
        XCTAssertFalse(importer.canStop)
        importer.answer(PhotoCornersAnswer.skip)
        let outcome: IOSImportOutcome = await importing.value
        XCTAssertEqual(outcome.added, 1)
        XCTAssertEqual(outcome.skipped, 1)
        XCTAssertEqual(outcome.problems, [])
        defer { state.deleteSpoolFiles(of: state.scannedPages) }
        XCTAssertEqual(state.scannedPages.count, 1)
    }

    @MainActor
    func test_aPhotoFile_handsPage1OverOnce_andLetsItsBytesGo() {
        let page1 = IOSPreparedPhoto(decoded: nil, found: nil, problem: "page 1")
        let file = IOSPhotoFile(name: "fax.tif", pageCount: 3, first: page1, rest: Data([1, 2, 3]))
        XCTAssertEqual(file.name, "fax.tif")
        XCTAssertEqual(file.pageCount, 3)
        // Page 1 is held only until it is taken.
        XCTAssertEqual(file.takeFirst()?.problem, "page 1")
        XCTAssertNil(file.takeFirst())
        XCTAssertEqual(file.rest, Data([1, 2, 3]))
        file.dropRest()
        XCTAssertNil(file.rest)
    }

    @MainActor
    func test_aStateThatCannotTakePages_opensNoEditor_andSaysSo() async throws {
        let state: AppState = ImportTestSupport.makeState(in: folder)
        let importer = IOSImportSession(state: state, finder: fixedFinder(sheetQuad, reason: .none))
        // The photo review of the Mac's import is up: nothing can be added now.
        state.showPhotoReview = true
        XCTAssertFalse(state.canIngest)
        XCTAssertFalse(importer.canImport)
        let outcome: IOSImportOutcome = await importer.importItems([IOSImportItem(name: "a.png", data: sheetPNG(), kind: .image)])
        XCTAssertNil(importer.cornerRequest)
        XCTAssertEqual(outcome.problems, [IOSImportText.notAddedMessage("a.png")])
        XCTAssertEqual(state.errorMessage, IOSImportText.notAddedMessage("a.png"))
        XCTAssertFalse(importer.isImporting)
        state.showPhotoReview = false
    }

    @MainActor
    func test_text_takesTheFirstPhoto_andSaysTheOthersWereLeftOut() async throws {
        let state: AppState = ImportTestSupport.makeState(in: folder)
        XCTAssertTrue(state.startTask(.quickScan))
        let importer = IOSImportSession(state: state, finder: fixedFinder(sheetQuad, reason: .none))
        let data: Data = sheetPNG()
        let items: [IOSImportItem] = [IOSImportItem(name: "a.png", data: data, kind: .image),
                                      IOSImportItem(name: "b.png", data: data, kind: .image),
                                      IOSImportItem(name: "c.png", data: data, kind: .image)]
        let importing: Task<IOSImportOutcome, Never> = Task { @MainActor in
            await importer.importItems(items)
        }
        try await ImportTestSupport.waitUntil(timeout: 60) { importer.cornerRequest != nil }
        importer.answer(PhotoCornersAnswer(choice: .useCorners, corners: sheetQuad))
        let outcome: IOSImportOutcome = await importing.value
        XCTAssertEqual(outcome.added, 1)
        XCTAssertNotNil(state.quickScanPage)
        XCTAssertEqual(outcome.problems, [IOSImportText.textTakesOneMessage(2)])
        XCTAssertEqual(state.errorMessage, "Text takes one page; the other 2 were not added.")
        XCTAssertNil(importer.cornerRequest)
        XCTAssertEqual(IOSImportText.textTakesOneMessage(1), "Text takes one page; the other one was not added.")
    }

    @MainActor
    func test_whatCannotBeRead_isListed_andTheOthersComeIn() async throws {
        let state: AppState = ImportTestSupport.makeState(in: folder)
        let importer = IOSImportSession(state: state, finder: fixedFinder(sheetQuad, reason: .none))
        let items: [IOSImportItem] = [IOSImportItem(name: "notes.jpg", data: Data("notes".utf8), kind: .image),
                                      IOSImportItem(name: "broken.pdf", data: Data("%PDF-1.7 broken".utf8), kind: .pdf)]
        let outcome: IOSImportOutcome = await importer.importItems(items)
        XCTAssertEqual(outcome.added, 0)
        XCTAssertEqual(outcome.problems, [PhotoImport.unreadableMessage("notes.jpg", detail: PhotoImport.unreadableDetail),
                                          PhotoImport.unreadableMessage("broken.pdf", detail: PhotoImport.unreadableDetail)])
        XCTAssertEqual(state.errorMessage, outcome.problems.joined(separator: "\n"))
        XCTAssertNil(importer.cornerRequest)
        // A photo the library could not hand over is listed too.
        state.errorMessage = nil
        let picked: IOSImportOutcome = await importer.importPicked([nil])
        XCTAssertEqual(picked.problems, [IOSImportText.photoNotLoadedMessage])
        XCTAssertEqual(state.errorMessage, IOSImportText.photoNotLoadedMessage)
        // A file that is gone.
        state.errorMessage = nil
        let gone: URL = folder.appendingPathComponent("gone.jpg")
        let missing: IOSImportOutcome = await importer.importFiles([gone])
        XCTAssertEqual(missing.problems.count, 1)
        XCTAssertTrue(missing.problems[0].hasPrefix("gone.jpg could not be opened: "), missing.problems[0])
        XCTAssertEqual(state.errorMessage, missing.problems[0])
    }

    @MainActor
    func test_aPhotocopy_takesPhotos() {
        let state: AppState = ImportTestSupport.makeState(in: folder)
        // Since I16 a photocopy's page comes from the camera, Photos or Files too, and prints over AirPrint.
        state.settings = TaskCatalog.apply(.copy, to: state.settings)
        XCTAssertTrue(IOSShell.takesPhotos(state.settings))
        let importer = IOSImportSession(state: state, finder: fixedFinder(sheetQuad, reason: .none))
        XCTAssertTrue(importer.canImport)
    }

    @MainActor
    func test_filesFromTheFilesApp_areReadOnce_byTheirKind() async throws {
        let state: AppState = ImportTestSupport.makeState(in: folder)
        let importer = IOSImportSession(state: state, finder: fixedFinder(sheetQuad, reason: .none))
        let url: URL = folder.appendingPathComponent("sheet.png")
        let data: Data = sheetPNG()
        try data.write(to: url)
        let item: IOSImportItem = try IOSImportItem.read(url)
        XCTAssertEqual(item, IOSImportItem(name: "sheet.png", data: data, kind: .image))
        let importing: Task<IOSImportOutcome, Never> = Task { @MainActor in
            await importer.importFiles([url])
        }
        try await ImportTestSupport.waitUntil(timeout: 60) { importer.cornerRequest != nil }
        importer.answer(PhotoCornersAnswer.skip)
        let outcome: IOSImportOutcome = await importing.value
        XCTAssertEqual(outcome.skipped, 1)
        // The file itself is left as it was.
        XCTAssertEqual(try Data(contentsOf: url), data)
        XCTAssertEqual(IOSImportItem.kind(forFileName: "scan.PDF", data: Data()), .pdf)
        XCTAssertEqual(IOSImportItem.kind(forFileName: "scan.bin", data: Data("%PDF-1.4".utf8)), .pdf)
        XCTAssertEqual(IOSImportItem.kind(forFileName: "IMG_0001.HEIC", data: Data([0, 0, 0, 24])), .image)
    }

    // MARK: The page finder

    func test_visionsCorners_mapToThePhotosPixels() {
        // Normalized, origin bottom-left: the top-left corner is at y 0.9.
        let points: [CGPoint] = [CGPoint(x: 0.1, y: 0.9), CGPoint(x: 0.8, y: 0.85), CGPoint(x: 0.75, y: 0.1),
                                 CGPoint(x: 0.15, y: 0.2)]
        let quad: Quad = IOSPageFinder.quad(fromNormalized: points, width: 400, height: 300)
        XCTAssertEqual(Double(quad.topLeft.x), 40, accuracy: 1e-9)
        XCTAssertEqual(Double(quad.topLeft.y), 30, accuracy: 1e-9)
        XCTAssertEqual(Double(quad.topRight.x), 320, accuracy: 1e-9)
        XCTAssertEqual(Double(quad.topRight.y), 45, accuracy: 1e-9)
        XCTAssertEqual(Double(quad.bottomRight.y), 270, accuracy: 1e-9)
        XCTAssertEqual(Double(quad.bottomLeft.x), 60, accuracy: 1e-9)
        XCTAssertTrue(quad.isConvex)
    }

    func test_theModelsOutline_isTakenOnlyWhenSureAndAPagesShape() {
        let page = QuadCandidate(quad: sheetQuad, confidence: 0.9)
        XCTAssertEqual(IOSPageFinder.accepted(page, width: 600, height: 450), sheetQuad)
        XCTAssertNil(IOSPageFinder.accepted(QuadCandidate(quad: sheetQuad, confidence: 0.3), width: 600, height: 450))
        // A sliver, and a speck: no page.
        let sliver = Quad(topLeft: CGPoint(x: 100, y: 100), topRight: CGPoint(x: 500, y: 100),
                          bottomRight: CGPoint(x: 500, y: 140), bottomLeft: CGPoint(x: 100, y: 140))
        XCTAssertNil(IOSPageFinder.accepted(QuadCandidate(quad: sliver, confidence: 0.9), width: 600, height: 450))
        let speck = Quad(topLeft: CGPoint(x: 10, y: 10), topRight: CGPoint(x: 40, y: 10),
                         bottomRight: CGPoint(x: 40, y: 52), bottomLeft: CGPoint(x: 10, y: 52))
        XCTAssertNil(IOSPageFinder.accepted(QuadCandidate(quad: speck, confidence: 0.9), width: 600, height: 450))
    }

    func test_thePageIsFound_inASimplePhoto() throws {
        let photo: RgbaImage = try XCTUnwrap(RgbaImage(cgImage: ImportTestSupport.sheetPhoto(width: 600, height: 450,
                                                                                            corners: sheetCorners)))
        // The shared detector alone: the sheet within 2 % of the diagonal.
        let fallback: IOSFoundPage = IOSPageFinder.fallback(photo)
        XCTAssertFalse(fallback.byModel)
        XCTAssertLessThan(fallback.corners.maxCornerDistance(sheetQuad), 15)
        // The corner model first (when it was fetched): whichever answers, the corners can be used and lie in
        // the photo.
        let found: IOSFoundPage = IOSPageFinder.find(photo)
        XCTAssertTrue(PhotoImport.canUseCorners(found.corners))
        XCTAssertTrue(found.corners.isInside(width: 600, height: 450))
        if !found.byModel {
            XCTAssertEqual(found, fallback)
        }
    }
}
#endif
