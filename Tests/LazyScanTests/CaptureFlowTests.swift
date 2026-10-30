import CoreGraphics
import Foundation
import XCTest
@testable import LazyScanKit

// The objects of a camera's shot through the app's state (I13, Swift only: the Windows app takes no camera
// shots): two prints in one shot open the photo review cut out at their size and save as JPEGs; Fix crop
// along four corners cuts one again; receipts of a shot are cut out and made easy to read, and a shot in
// which no outline was found falls back to the receipt search of the whole shot; an ID card's sides from
// the camera come out at their real size, are kept in memory only (no spool, no history, no saved file
// until Save) and carry the glare hint when the photo shows glare on the card.

/// Text recognition that cannot run, so nothing is read in these tests.
private struct FlowScorer: OrientationScorer {
    var isAvailable: Bool { false }

    func score(_ image: RgbaImage) throws -> OrientationScore {
        OrientationScore.none
    }
}

/// Barcode reading that cannot run.
private struct FlowBarcodes: BarcodeReader {
    var isAvailable: Bool { false }

    func read(_ image: GrayImage) throws -> [BarcodeReading] {
        []
    }
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

/// The names of the files in `folder` (none when it does not exist).
private func fileNames(_ folder: URL) -> [String] {
    let names: [String] = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    var visible: [String] = []
    for name in names where !name.hasPrefix(".") {
        visible.append(name)
    }
    return visible.sorted()
}

/// `photo` with a white disk of `radius` pixels around `center`: a reflection on the card.
private func withGlare(_ photo: RgbaImage, center: CGPoint, radius: Double) -> RgbaImage {
    var pixels: [UInt8] = photo.pixels
    for y in 0..<photo.height {
        for x in 0..<photo.width {
            let dx: Double = Double(x) + 0.5 - Double(center.x)
            let dy: Double = Double(y) + 0.5 - Double(center.y)
            if dx * dx + dy * dy > radius * radius { continue }
            let p: Int = (y * photo.width + x) * 4
            pixels[p] = 255
            pixels[p + 1] = 255
            pixels[p + 2] = 255
        }
    }
    return RgbaImage(width: photo.width, height: photo.height, pixels: pixels)
}

/// The largest difference of one channel between two pictures of the same size (255 when the sizes differ).
private func largestDifference(_ a: RgbaImage, _ b: RgbaImage) -> Int {
    guard a.width == b.width, a.height == b.height else { return 255 }
    var largest: Int = 0
    for i in 0..<a.pixels.count {
        largest = max(largest, abs(Int(a.pixels[i]) - Int(b.pixels[i])))
    }
    return largest
}

final class CaptureFlowTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptureFlowTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        // The settings are written 0.4 s after they change: let that write land before the folder goes.
        try await Task.sleep(nanoseconds: 600_000_000)
        try? FileManager.default.removeItem(at: folder)
    }

    private var saved: URL { folder.appendingPathComponent("Saved", isDirectory: true) }
    private var spool: URL { AppStateFiles.all(in: folder).spoolDirectory }

    /// An AppState with no scanner, its files in `folder`, set up for `task`, saving into `folder`/Saved.
    @MainActor
    private func makeState(_ task: ScanTask) -> AppState {
        let state = AppState(backends: [], presetStore: PresetStore(directory: folder),
                             orientationScorer: FlowScorer(), barcodeReader: FlowBarcodes(),
                             files: AppStateFiles.all(in: folder))
        var settings: ScanSettings = TaskCatalog.apply(task, to: ScanSettings())
        settings.source = .flatbed
        settings.pdfSearchable = false
        settings.destinationPath = saved.path
        state.settings = settings
        return state
    }

    @MainActor
    func test_twoPrintsOfAShot_openTheReview_cutOut_andSaveAsJPEGs() async throws {
        let state: AppState = makeState(.photos)
        let photo: CGImage = try XCTUnwrap(ObjectShots.twoPrints().makeCGImage())
        let pages: [ScannedPage] = CaptureObjects.pages(photo, quads: [ObjectShots.printA, ObjectShots.printB], kind: .photo)
        XCTAssertTrue(state.ingest(pages, source: .photo))
        try await waitFor(timeout: 60) { !state.isBusy }
        XCTAssertNil(state.errorMessage)
        XCTAssertTrue(state.showPhotoReview)
        XCTAssertFalse(state.isReceiptReview)
        XCTAssertEqual(state.reviewTitle, "Found 2 photos")
        XCTAssertEqual(state.reviewSaveTitle, "Save 2 photos")
        XCTAssertEqual(state.detectedPhotos.count, 2)
        guard state.detectedPhotos.count == 2 else { return }
        let first: DetectedPhoto = state.detectedPhotos[0]
        XCTAssertEqual(first.image.width, 300)
        XCTAssertEqual(first.image.height, 200)
        XCTAssertEqual(first.dpi, 50)
        XCTAssertEqual(state.detectedPhotos[1].image.width, 360)
        XCTAssertEqual(state.detectedPhotos[1].dpi, 60)
        // Nothing spooled; the shot is in the scan history as a scan is.
        XCTAssertEqual(fileNames(spool), [])
        XCTAssertTrue(state.scannedPages.isEmpty)

        // Fix crop starts from the photo as taken and the print's corners.
        let start: PhotoCropStart = try XCTUnwrap(state.cropStart(for: first))
        XCTAssertTrue(start.source === photo)
        XCTAssertEqual(start.corners, ObjectShots.printA)
        XCTAssertEqual(start.kind, .photo)
        // Cut again along a smaller outline inside the print: 240 × 160 px, still a 6 × 4 in print.
        let inner: Quad = ObjectShots.rect(90, 100, 330, 260)
        state.recropPhoto(id: first.id, corners: inner)
        try await waitFor(timeout: 60) { state.detectedPhotos.first?.image.width == 240 }
        let recut: DetectedPhoto = state.detectedPhotos[0]
        XCTAssertEqual(recut.id, first.id)
        XCTAssertEqual(recut.image.height, 160)
        XCTAssertEqual(recut.dpi, 40)
        XCTAssertEqual(state.cropStart(for: recut)?.corners, inner)

        // Leave the second out, turn the first, and save: one JPEG.
        state.detectedPhotos[1].included = false
        state.detectedPhotos[0].rotationQuarterTurns = 1
        XCTAssertEqual(state.reviewSaveTitle, "Save 1 photo")
        state.saveReviewedPhotos()
        try await waitFor(timeout: 60) { !state.isBusy && !state.showPhotoReview }
        XCTAssertNil(state.errorMessage)
        XCTAssertEqual(state.lastSavedURLs.count, 1)
        let names: [String] = fileNames(saved)
        XCTAssertEqual(names.count, 1)
        XCTAssertTrue(names.allSatisfy { (name: String) -> Bool in name.hasSuffix(".jpg") }, "\(names)")
        // The review's pictures and corners are gone with it.
        XCTAssertTrue(state.photoSourceImages.isEmpty)
        XCTAssertTrue(state.photoCaptureFacts.isEmpty)
    }

    @MainActor
    func test_fixCropInRestoreOldPhotos_keepsTheRestoredColors() async throws {
        let state: AppState = makeState(.photoRestore)
        let photo: CGImage = try XCTUnwrap(ObjectShots.twoPrints().makeCGImage())
        let pages: [ScannedPage] = CaptureObjects.pages(photo, quads: [ObjectShots.printA, ObjectShots.printB], kind: .photo)
        XCTAssertTrue(state.ingest(pages, source: .photo))
        try await waitFor(timeout: 60) { !state.isBusy }
        XCTAssertNil(state.errorMessage)
        XCTAssertEqual(state.detectedPhotos.count, 2)
        let first: DetectedPhoto = try XCTUnwrap(state.detectedPhotos.first)
        let restored: RgbaImage = try XCTUnwrap(RgbaImage(cgImage: first.image))
        let start: PhotoCropStart = try XCTUnwrap(state.cropStart(for: first))

        // The print as cut with no adjustments differs, so the colors were restored.
        var plain: ScanSettings = state.settings
        plain.adjustments = AdjustmentSettings()
        let unadjusted: CapturedCut = try XCTUnwrap(AppState.cutAlong(start.source, corners: start.corners, kind: .photo,
                                                                      focalLength: nil, settings: plain))
        let unadjustedPixels: RgbaImage = try XCTUnwrap(RgbaImage(cgImage: unadjusted.image))
        XCTAssertGreaterThan(largestDifference(unadjustedPixels, restored), 4)

        // Cut again along the same corners: the same pixels, restored as before.
        state.recropPhoto(id: first.id, corners: start.corners)
        try await waitFor(timeout: 60) { state.detectedPhotos.first?.image !== first.image }
        let recut: DetectedPhoto = try XCTUnwrap(state.detectedPhotos.first)
        XCTAssertEqual(recut.id, first.id)
        XCTAssertEqual(recut.dpi, first.dpi)
        XCTAssertEqual(recut.colorMode, first.colorMode)
        let again: RgbaImage = try XCTUnwrap(RgbaImage(cgImage: recut.image))
        XCTAssertEqual(again.width, restored.width)
        XCTAssertEqual(again.height, restored.height)
        // Within a level, in case Core Image renders a step a hair differently the second time.
        XCTAssertLessThanOrEqual(largestDifference(again, restored), 1)
        state.cancelPhotoReview()
    }

    @MainActor
    func test_receiptsOfAShot_areCutOutAndMadeEasyToRead() async throws {
        let state: AppState = makeState(.receipt)
        let photo: CGImage = try XCTUnwrap(ObjectShots.twoPrints().makeCGImage())
        // Two outlines of a receipt's shape: each cut out at an 80 mm roll's width.
        let pages: [ScannedPage] = CaptureObjects.pages(photo, quads: [ObjectShots.printA, ObjectShots.printB], kind: .receipt)
        XCTAssertTrue(state.ingest(pages, source: .photo))
        try await waitFor(timeout: 60) { !state.isBusy }
        XCTAssertNil(state.errorMessage)
        XCTAssertTrue(state.showPhotoReview)
        XCTAssertTrue(state.isReceiptReview)
        XCTAssertEqual(state.reviewTitle, Receipts.reviewTitle(2))
        XCTAssertEqual(state.detectedPhotos.count, 2)
        for receipt in state.detectedPhotos {
            // Gray (R = G = B), as a receipt found on the glass is made.
            let pixels: RgbaImage = try XCTUnwrap(RgbaImage(cgImage: receipt.image))
            XCTAssertTrue(ColorAnalysis.isEffectivelyGray(receipt.image))
            XCTAssertGreaterThan(pixels.width, 0)
        }
        let start: PhotoCropStart = try XCTUnwrap(state.cropStart(for: state.detectedPhotos[0]))
        XCTAssertEqual(start.kind, .receipt)
        // The shot as taken, in color: made gray only in the receipts cut from it.
        XCTAssertEqual(start.source.width, 900)
        XCTAssertEqual(start.source.height, 600)
        XCTAssertTrue(start.source === photo)
        state.cancelPhotoReview()
        XCTAssertEqual(state.statusMessage, "Receipts discarded.")
        XCTAssertTrue(state.photoCaptureFacts.isEmpty)
    }

    @MainActor
    func test_aShotWithNoOutline_fallsBackToTheReceiptSearchOfTheWholeShot() async throws {
        let state: AppState = makeState(.receipt)
        // Thermal paper on a white table (the bed doubled: 200 dpi, the shot's fallback resolution).
        let left = TestPages.Placed(sheet: TestPages.receipt(300, 800, paper: 237, ink: 153, lines: 40, seed: 0xC0FF_EE01),
                                    centerX: 220, centerY: 585, turn: TestPages.plus3)
        let right = TestPages.Placed(sheet: TestPages.receipt(300, 800, paper: 237, ink: 153, lines: 40, seed: 0xC0FF_EE02),
                                     centerX: 630, centerY: 585, turn: TestPages.minus3)
        let bed: GrayImage = TestPages.receiptBed(backdrop: 245, seed: 0xBED0_0001, [left, right])
        let photo: CGImage = try XCTUnwrap(TestPages.enlarged(bed, 2).makeCGImage())
        XCTAssertTrue(state.ingest([CaptureObjects.fallbackPage(photo)], source: .photo))
        try await waitFor(timeout: 120) { !state.isBusy }
        XCTAssertNil(state.errorMessage)
        XCTAssertTrue(state.isReceiptReview)
        XCTAssertEqual(state.detectedPhotos.count, 2)
        // Found on the whole shot: Fix crop starts from the region found there.
        if let first = state.detectedPhotos.first {
            let start: PhotoCropStart? = state.cropStart(for: first)
            XCTAssertEqual(start?.kind, .receipt)
            XCTAssertEqual(start?.source.width, 1700)
            // Cut again along those corners as found on a scan: at the shot's 200 dpi, with no camera facts.
            if let corners = start?.corners {
                let before: CGImage = first.image
                state.recropPhoto(id: first.id, corners: corners)
                try await waitFor(timeout: 60) { state.detectedPhotos.first?.image !== before }
                let recut: DetectedPhoto? = state.detectedPhotos.first
                XCTAssertEqual(recut?.id, first.id)
                XCTAssertEqual(recut?.dpi, CaptureObjects.fallbackDPI)
                XCTAssertEqual(recut?.region.angleDegrees ?? 99, first.region.angleDegrees, accuracy: 0.01)
                XCTAssertTrue(state.photoCaptureFacts.isEmpty)
            }
        }
        state.cancelPhotoReview()
    }

    func test_theRegionAlongCorners_isTheRegionTheyCameFrom() {
        let angles: [Double] = [0, 10, -30, 60, 95]
        for angle in angles {
            let region = DetectedPhotoRegion(center: CGPoint(x: 400, y: 300), size: CGSize(width: 200, height: 120),
                                             angleDegrees: angle)
            let back: DetectedPhotoRegion = AppState.region(along: Quad.fromCorners(region.corners), near: region)
            XCTAssertEqual(back.angleDegrees, angle, accuracy: 1e-6, "\(angle)")
            XCTAssertEqual(Double(back.size.width), 200, accuracy: 1e-6, "\(angle)")
            XCTAssertEqual(Double(back.size.height), 120, accuracy: 1e-6, "\(angle)")
            XCTAssertEqual(Double(back.center.x), 400, accuracy: 1e-6, "\(angle)")
            XCTAssertEqual(Double(back.center.y), 300, accuracy: 1e-6, "\(angle)")
        }
    }

    @MainActor
    func test_theIdCardFromTheCamera_isKeptInMemoryOnly_atItsRealSize_withTheGlareHint() async throws {
        let state: AppState = makeState(.idCard)
        XCTAssertTrue(state.isIdCardFlow)
        let card: RgbaImage = try XCTUnwrap(ObjectShots.cardPhoto())
        let quad: Quad = ObjectShots.cardQuad()
        let front: CGImage = try XCTUnwrap(card.makeCGImage())
        let frontPages: [ScannedPage] = CaptureObjects.pages(front, quads: [quad], kind: .idCard,
                                                             focalLength: ObjectShots.cardFocal)
        XCTAssertTrue(state.ingest(frontPages, source: .photo))
        try await waitFor(timeout: 60) { !state.isBusy }
        XCTAssertNil(state.errorMessage)
        let side: DetectedPhoto = try XCTUnwrap(state.idCardFront)
        XCTAssertNil(state.idCardFrontNote)
        XCTAssertEqual(state.taskFlow?.current?.id, IdCardSteps.backStepID)
        // At its real size: 85.60 × 53.98 mm within 0.5 mm.
        let longMm: Double = Double(max(side.image.width, side.image.height)) * 25.4 / Double(side.dpi)
        let shortMm: Double = Double(min(side.image.width, side.image.height)) * 25.4 / Double(side.dpi)
        XCTAssertEqual(longMm, 85.60, accuracy: 0.5)
        XCTAssertEqual(shortMm, 53.98, accuracy: 0.5)
        // In memory only: nothing spooled, nothing in the history or the queue, no file saved.
        XCTAssertEqual(fileNames(spool), [])
        XCTAssertEqual(fileNames(saved), [])
        XCTAssertTrue(state.scanHistory.isEmpty)
        XCTAssertTrue(state.scannedPages.isEmpty)
        XCTAssertTrue(state.lastSavedURLs.isEmpty)
        // Fix crop starts from the photo as taken, along the card's corners.
        let start: PhotoCropStart = try XCTUnwrap(state.cropStart(for: side))
        XCTAssertTrue(start.source === front)
        XCTAssertEqual(start.kind, .idCard)
        XCTAssertLessThan(start.corners.maxCornerDistance(quad), 1)

        // The back, with a reflection on the card: the review opens with the glare hint on the back.
        let glare: CGImage = try XCTUnwrap(withGlare(card, center: quad.centroid, radius: 70).makeCGImage())
        let backPages: [ScannedPage] = CaptureObjects.pages(glare, quads: [quad], kind: .idCard,
                                                            focalLength: ObjectShots.cardFocal)
        XCTAssertTrue(state.ingest(backPages, source: .photo))
        try await waitFor(timeout: 60) { !state.isBusy }
        XCTAssertNotNil(state.idCardBack)
        XCTAssertEqual(state.idCardBackNote, GlareDetector.hint)
        XCTAssertTrue(state.showIdCardReview)
        try await waitFor(timeout: 60) { state.idCardPreview != nil }
        XCTAssertNil(state.idCardSizeWarning)
        XCTAssertEqual(fileNames(spool), [])
        XCTAssertEqual(fileNames(saved), [])
        XCTAssertTrue(state.scanHistory.isEmpty)
        // A new page while the review is open is not taken.
        XCTAssertFalse(state.ingest(backPages, source: .photo))

        // Discard: nothing of the card is left.
        state.discardIdCard()
        XCTAssertNil(state.idCardFront)
        XCTAssertNil(state.idCardBack)
        XCTAssertTrue(state.idCardSourceImages.isEmpty)
        XCTAssertTrue(state.idCardCaptureFacts.isEmpty)
        XCTAssertFalse(state.showIdCardReview)
        XCTAssertEqual(fileNames(spool), [])
        XCTAssertEqual(fileNames(saved), [])
        XCTAssertTrue(state.scanHistory.isEmpty)
    }

    @MainActor
    func test_aCardOfAnotherShape_isNotAtRealSize_andSaysSo() async throws {
        let state: AppState = makeState(.idCard)
        let card: CGImage = try XCTUnwrap(ObjectShots.cardPhoto()?.makeCGImage())
        // Twice as long as it is wide: no ID-1 card, so its size is made up.
        let quad: Quad = ObjectShots.rect(300, 300, 900, 600)
        XCTAssertTrue(state.ingest(CaptureObjects.pages(card, quads: [quad], kind: .idCard), source: .photo))
        try await waitFor(timeout: 60) { !state.isBusy }
        XCTAssertNil(state.errorMessage)
        let side: DetectedPhoto = try XCTUnwrap(state.idCardFront)
        XCTAssertEqual(side.dpi, CaptureScale.nominalDPI)
        XCTAssertEqual(state.idCardFrontNote, CaptureObjects.cardNotRealSizeNote)
        state.discardIdCard()
    }

    @MainActor
    func test_theIdCardFromTheCamera_savesOnePDF_andDropsTheCard() async throws {
        let state: AppState = makeState(.idCard)
        let card: CGImage = try XCTUnwrap(ObjectShots.cardPhoto()?.makeCGImage())
        let quad: Quad = ObjectShots.cardQuad()
        XCTAssertTrue(state.ingest(CaptureObjects.pages(card, quads: [quad], kind: .idCard), source: .photo))
        try await waitFor(timeout: 60) { !state.isBusy }
        // No back side.
        XCTAssertTrue(state.canSkipStep)
        state.skipStep()
        XCTAssertTrue(state.showIdCardReview)
        state.saveIdCard()
        try await waitFor(timeout: 120) { !state.isBusy && !state.showIdCardReview }
        XCTAssertNil(state.errorMessage)
        let names: [String] = fileNames(saved)
        XCTAssertEqual(names.count, 1)
        XCTAssertTrue(names.first?.hasSuffix(".pdf") == true, "\(names)")
        XCTAssertEqual(state.lastSavedURLs.count, 1)
        XCTAssertNil(state.idCardFront)
        XCTAssertTrue(state.idCardSourceImages.isEmpty)
        XCTAssertTrue(state.idCardCaptureFacts.isEmpty)
        XCTAssertEqual(fileNames(spool), [])
        XCTAssertTrue(state.scanHistory.isEmpty)
    }
}
