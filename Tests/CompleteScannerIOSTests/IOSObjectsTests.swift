#if os(iOS)
import CoreGraphics
import Foundation
import UniformTypeIdentifiers
import XCTest
@testable import CompleteScannerIOS
@testable import CompleteScannerKit

// Several objects in one shot on the iPhone (I13): what Vision's rectangle search is asked for each kind,
// Vision's outlines mapped into the photo and picked (`IOSObjectFinder`, on hand-made observations and, where
// Vision runs, on a drawn photo); a shot of two prints imported under the Photos task opening the photo
// review, Fix crop through the corner editor's request and Save writing two JPEGs (`IOSPhotoReviewModel`);
// the next shot read only once that review is closed; a shot with no outline coming in whole; the receipts'
// choices; a Document or Photo shot going by Items in frame, and a slip measured as a receipt roll; the ID
// card taken from shots as the step's sides, in memory only (no spool, no history, no file);
// the guide frame, its prompts and the glare line; the launch option of the photos UI test. The object
// search is a stand-in where a test needs known outlines.

/// Two prints with white borders on a plain dark table, 1200 × 900 (the photos UI test's fixture,
/// `ObjectShots.printsOnTable` in the shared tests).
private let printA = Quad(topLeft: CGPoint(x: 120, y: 150), topRight: CGPoint(x: 570, y: 150),
                          bottomRight: CGPoint(x: 570, y: 450), bottomLeft: CGPoint(x: 120, y: 450))
private let printB = Quad(topLeft: CGPoint(x: 650, y: 420), topRight: CGPoint(x: 1070, y: 420),
                          bottomRight: CGPoint(x: 1070, y: 700), bottomLeft: CGPoint(x: 650, y: 700))

private func printsOnTable() -> RgbaImage {
    let w: Int = 1200
    let h: Int = 900
    var pixels: [UInt8] = [UInt8](repeating: 0, count: w * h * 4)
    for y in 0..<h {
        for x in 0..<w {
            var r: Int = 40
            var g: Int = 36
            var b: Int = 34
            if x >= 120 && x < 570 && y >= 150 && y < 450 {
                let inner: Bool = x >= 138 && x < 552 && y >= 168 && y < 432
                r = inner ? 70 + (x - 120) * 120 / 450 : 245
                g = inner ? 110 + (y - 150) * 90 / 300 : 244
                b = inner ? 180 : 238
            } else if x >= 650 && x < 1070 && y >= 420 && y < 700 {
                let inner: Bool = x >= 668 && x < 1052 && y >= 438 && y < 682
                r = inner ? 190 : 245
                g = inner ? 140 - (y - 420) * 70 / 280 : 244
                b = inner ? 60 + (x - 650) * 100 / 420 : 238
            }
            let p: Int = (y * w + x) * 4
            pixels[p] = UInt8(r)
            pixels[p + 1] = UInt8(g)
            pixels[p + 2] = UInt8(b)
            pixels[p + 3] = 255
        }
    }
    return RgbaImage(width: w, height: h, pixels: pixels)
}

/// An ID-1 card (428 × 270 px, blue with a yellow band) square on, on the dark table of a 1200 × 900 photo.
private let cardQuad = Quad(topLeft: CGPoint(x: 386, y: 315), topRight: CGPoint(x: 814, y: 315),
                            bottomRight: CGPoint(x: 814, y: 585), bottomLeft: CGPoint(x: 386, y: 585))

private func cardOnTable() -> RgbaImage {
    let w: Int = 1200
    let h: Int = 900
    var pixels: [UInt8] = [UInt8](repeating: 0, count: w * h * 4)
    for y in 0..<h {
        for x in 0..<w {
            var r: Int = 40
            var g: Int = 36
            var b: Int = 34
            if x >= 386 && x < 814 && y >= 315 && y < 585 {
                let band: Bool = y >= 345 && y < 385
                r = band ? 200 : 40
                g = band ? 170 : 90
                b = band ? 60 : 160
            }
            let p: Int = (y * w + x) * 4
            pixels[p] = UInt8(r)
            pixels[p + 1] = UInt8(g)
            pixels[p + 2] = UInt8(b)
            pixels[p + 3] = 255
        }
    }
    return RgbaImage(width: w, height: h, pixels: pixels)
}

private func png(_ photo: RgbaImage) -> Data {
    ImportTestSupport.file(UTType.png, images: [photo.makeCGImage()!])
}

/// A PDF of `count` Letter pages, each a 6 × 4 in print (a plain blue) on white.
private func printsPDF(_ count: Int) throws -> Data {
    let data = NSMutableData()
    let consumer: CGDataConsumer = try XCTUnwrap(CGDataConsumer(data: data as CFMutableData))
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    let context: CGContext = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
    for _ in 0..<count {
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(box)
        context.setFillColor(CGColor(srgbRed: 0.15, green: 0.3, blue: 0.75, alpha: 1))
        context.fill(CGRect(x: 90, y: 360, width: 432, height: 288))
        context.endPDFPage()
    }
    context.closePDF()
    return data as Data
}

/// An object search that answers `quads` for `kind` and nothing for any other kind.
private func fixedObjects(_ quads: [Quad], for kind: CaptureKind) -> @Sendable (RgbaImage, CaptureKind) -> [Quad] {
    return { (_: RgbaImage, asked: CaptureKind) -> [Quad] in
        asked == kind ? quads : []
    }
}

/// A long slip at the right of the same photo, 96 × 408 px (3.6 % of it).
private let slip = Quad(topLeft: CGPoint(x: 1090, y: 40), topRight: CGPoint(x: 1186, y: 40),
                        bottomRight: CGPoint(x: 1186, y: 448), bottomLeft: CGPoint(x: 1090, y: 448))

/// A page search that finds `corners` clearly.
private func clearPage(_ corners: Quad) -> @Sendable (RgbaImage) -> IOSFoundPage {
    let found = IOSFoundPage(corners: corners, reason: PhotoReviewReason.none, byModel: false)
    return { (_: RgbaImage) -> IOSFoundPage in
        found
    }
}

/// A page search that finds nothing clearly.
private func noPage(_ photo: RgbaImage) -> IOSFoundPage {
    IOSFoundPage(corners: PhotoImport.startCorners(width: photo.width, height: photo.height), reason: .nothingFound,
                 byModel: false)
}

/// Vision's corners of a rectangle given in a photo's pixels: normalized, origin bottom-left, top left first.
private func normalized(_ quad: Quad, width: Int, height: Int) -> [CGPoint] {
    var points: [CGPoint] = []
    for corner in quad.corners {
        points.append(CGPoint(x: Double(corner.x) / Double(width), y: 1 - Double(corner.y) / Double(height)))
    }
    return points
}

private func names(_ folder: URL) -> [String] {
    let found: [String] = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    var visible: [String] = []
    for name in found where !name.hasPrefix(".") {
        visible.append(name)
    }
    return visible.sorted()
}

final class IOSObjectsTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = try ImportTestSupport.makeFolder("IOSObjectsTests")
    }

    override func tearDown() async throws {
        // The settings are written 0.4 s after they change: let that write land before the folder goes.
        try await Task.sleep(nanoseconds: 600_000_000)
        try? FileManager.default.removeItem(at: folder)
    }

    private var saved: URL { folder.appendingPathComponent("Saved", isDirectory: true) }
    private var spool: URL { AppStateFiles.all(in: folder).spoolDirectory }

    @MainActor
    private func makeState(_ task: ScanTask) -> AppState {
        let state: AppState = ImportTestSupport.makeState(in: folder)
        var settings: ScanSettings = TaskCatalog.apply(task, to: state.settings)
        settings.source = .flatbed
        settings.pdfSearchable = false
        settings.destinationPath = saved.path
        state.settings = settings
        return state
    }

    // MARK: Vision's rectangles

    func test_theRectangleSearch_holdsEachKindsShape_andRoomForThePicker() {
        for kind in CaptureKind.allCases {
            let search: IOSRectangleSearch = IOSRectangleSearch.of(kind)
            let picker: MultiQuadOptions = MultiQuadPicker.options(for: kind)
            // Vision measures short over long as the photo shows it: its window holds the picker's real shapes.
            XCTAssertLessThanOrEqual(search.minimumAspectRatio, 1 / picker.maxLongOverShort, "\(kind)")
            XCTAssertGreaterThanOrEqual(search.maximumAspectRatio, 1 / picker.minLongOverShort, "\(kind)")
            XCTAssertLessThanOrEqual(search.maximumAspectRatio, 1)
            XCTAssertGreaterThanOrEqual(search.maximumObservations, picker.maxCount, "\(kind)")
            XCTAssertGreaterThan(search.minimumSize, 0)
            XCTAssertLessThanOrEqual(search.quadratureTolerance, 45)
        }
        XCTAssertEqual(IOSRectangleSearch.of(.photo).maximumObservations, 16)
        XCTAssertEqual(IOSRectangleSearch.of(.idCard).minimumAspectRatio, 0.45)
    }

    func test_visionsOutlines_mapIntoThePhoto_andArePickedAsPrints() {
        let w: Int = 1200
        let h: Int = 900
        // The second print, the picture inside the first one's border, the table's edge around both, and a sliver.
        let picture = Quad(topLeft: CGPoint(x: 138, y: 168), topRight: CGPoint(x: 552, y: 168),
                           bottomRight: CGPoint(x: 552, y: 432), bottomLeft: CGPoint(x: 138, y: 432))
        let table = Quad(topLeft: CGPoint(x: 60, y: 100), topRight: CGPoint(x: 1140, y: 100),
                         bottomRight: CGPoint(x: 1140, y: 780), bottomLeft: CGPoint(x: 60, y: 780))
        let sliver = Quad(topLeft: CGPoint(x: 100, y: 800), topRight: CGPoint(x: 700, y: 800),
                          bottomRight: CGPoint(x: 700, y: 812), bottomLeft: CGPoint(x: 100, y: 812))
        var corners: [[CGPoint]] = []
        for quad in [printB, picture, printA, table, sliver] {
            corners.append(normalized(quad, width: w, height: h))
        }
        corners.append([CGPoint(x: 0.1, y: 0.1)])
        let found: [QuadCandidate] = IOSObjectFinder.candidates(corners, confidences: [0.9, 1, 0.95, 0.8, 1, 1],
                                                                width: w, height: h)
        // Five with four corners each; each in the photo's pixels, named by where it is.
        XCTAssertEqual(found.count, 5)
        XCTAssertLessThan(found[0].quad.maxCornerDistance(printB), 1e-6)
        XCTAssertEqual(found[0].confidence, 0.9)
        XCTAssertLessThan(found[2].quad.maxCornerDistance(printA), 1e-6)
        // The prints, in reading order: the picture is the first print's own, the table is behind both.
        let prints: [Quad] = IOSObjectFinder.pick(found, width: w, height: h, kind: .photo)
        XCTAssertEqual(prints.count, 2)
        guard prints.count == 2 else { return }
        XCTAssertLessThan(prints[0].maxCornerDistance(printA), 1e-6)
        XCTAssertLessThan(prints[1].maxCornerDistance(printB), 1e-6)
        // As receipts, the prints' shape fits and the sliver's is too long; as a card, one outline at most.
        XCTAssertLessThanOrEqual(IOSObjectFinder.pick(found, width: w, height: h, kind: .idCard).count, 1)
        let card: [QuadCandidate] = IOSObjectFinder.candidates([normalized(cardQuad, width: w, height: h)],
                                                               confidences: [1], width: w, height: h)
        let cards: [Quad] = IOSObjectFinder.pick(card, width: w, height: h, kind: .idCard)
        XCTAssertEqual(cards.count, 1)
        XCTAssertLessThan(cards.first?.maxCornerDistance(cardQuad) ?? 99, 1e-6)
    }

    func test_vision_findsBothPrints_whereItRuns() throws {
        let quads: [Quad] = IOSObjectFinder.find(printsOnTable(), kind: .photo)
        if quads.isEmpty {
            throw XCTSkip("Vision found no rectangle here (the Simulator may not run it); the shot then comes in whole.")
        }
        XCTAssertEqual(quads.count, 2)
        guard quads.count == 2 else { return }
        // Within 2 % of the photo's diagonal (1500 px).
        XCTAssertLessThan(quads[0].maxCornerDistance(printA), 30)
        XCTAssertLessThan(quads[1].maxCornerDistance(printB), 30)
    }

    // MARK: The photo review

    @MainActor
    func test_aShotOfTwoPrints_opensTheReview_fixesACrop_andSavesTwoJPEGs() async throws {
        let state: AppState = makeState(.photos)
        let importer = IOSImportSession(state: state, finder: noPage, objectFinder: fixedObjects([printA, printB], for: .photo))
        XCTAssertTrue(importer.canImport)
        let outcome: IOSImportOutcome = await importer.importItems([IOSImportItem(name: "prints.png", data: png(printsOnTable()),
                                                                                  kind: .image)])
        XCTAssertEqual(outcome.added, 2)
        XCTAssertEqual(outcome.problems, [])
        // No corner editor: the review opens on the prints, cut out at their size.
        XCTAssertNil(importer.cornerRequest)
        try await ImportTestSupport.waitUntil(timeout: 60) { state.showPhotoReview && !state.isBusy }
        let review = IOSPhotoReviewModel(state: state)
        XCTAssertEqual(review.title, "Found 2 photos")
        XCTAssertEqual(review.saveTitle, "Save 2 photos")
        XCTAssertFalse(review.isReceipts)
        XCTAssertEqual(review.formats, [])
        XCTAssertEqual(review.photos.count, 2)
        guard review.photos.count == 2 else { return }
        let first: DetectedPhoto = review.photos[0]
        XCTAssertEqual(first.image.width, 450)
        XCTAssertEqual(first.image.height, 300)
        XCTAssertEqual(IOSReviewText.sizeCaption(width: first.image.width, height: first.image.height, dpi: first.dpi),
                       "6.0 \u{00D7} 4.0 in")
        XCTAssertTrue(state.scannedPages.isEmpty)
        XCTAssertEqual(names(spool), [])

        // Keep, rotate.
        review.toggle(first.id)
        XCTAssertFalse(review.isIncluded(first.id))
        XCTAssertEqual(review.saveTitle, "Save 1 photo")
        review.toggle(first.id)
        XCTAssertTrue(review.isIncluded(first.id))
        review.rotate(first.id)
        XCTAssertEqual(review.photos[0].rotationQuarterTurns, 1)

        // Fix crop: the corner editor's request on the photo as taken, with the print's corners, worded for a photo.
        let asked: IOSCropRequest? = await review.cropRequest(for: first, name: PhotoImport.label, number: 1, count: 2)
        let crop: IOSCropRequest = try XCTUnwrap(asked)
        XCTAssertEqual(crop.photoID, first.id)
        XCTAssertEqual(crop.request.photo.width, 1200)
        XCTAssertEqual(crop.request.photo.height, 900)
        XCTAssertEqual(crop.request.plan.corners, printA)
        XCTAssertEqual(crop.request.plan.reason, PhotoReviewReason.none)
        XCTAssertEqual(crop.request.kind, CaptureKind.photo)
        // The border left out: 414 × 264 px, cut again with the perspective warp.
        let inner = Quad(topLeft: CGPoint(x: 138, y: 168), topRight: CGPoint(x: 552, y: 168),
                         bottomRight: CGPoint(x: 552, y: 432), bottomLeft: CGPoint(x: 138, y: 432))
        review.applyCrop(crop, answer: PhotoCornersAnswer(choice: .useCorners, corners: inner))
        try await ImportTestSupport.waitUntil(timeout: 60) { state.detectedPhotos.first?.image.width == 414 }
        XCTAssertEqual(review.photos[0].id, first.id)
        XCTAssertEqual(review.photos[0].rotationQuarterTurns, 1)
        // Cancel in the editor changes nothing.
        review.applyCrop(crop, answer: PhotoCornersAnswer.skip)
        XCTAssertEqual(review.photos[0].image.width, 414)

        XCTAssertTrue(review.canSave)
        review.save()
        try await ImportTestSupport.waitUntil(timeout: 60) { !state.isBusy && !state.showPhotoReview }
        XCTAssertNil(state.errorMessage)
        let files: [String] = names(saved)
        XCTAssertEqual(files.count, 2)
        for name in files {
            XCTAssertTrue(name.hasSuffix(".jpg"), name)
        }
        XCTAssertEqual(state.lastSavedURLs.count, 2)
    }

    @MainActor
    func test_theNextShot_isReadOnceTheReviewIsClosed() async throws {
        let state: AppState = makeState(.photos)
        let importer = IOSImportSession(state: state, finder: noPage, objectFinder: fixedObjects([printA, printB], for: .photo))
        let data: Data = png(printsOnTable())
        let items: [IOSImportItem] = [IOSImportItem(name: "a.png", data: data, kind: .image),
                                      IOSImportItem(name: "b.png", data: data, kind: .image)]
        let importing: Task<IOSImportOutcome, Never> = Task { @MainActor in
            await importer.importItems(items)
        }
        try await ImportTestSupport.waitUntil(timeout: 60) { state.showPhotoReview && !state.isBusy }
        // The second shot waits for the review of the first.
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertTrue(importer.isImporting)
        XCTAssertEqual(state.detectedPhotos.count, 2)
        IOSPhotoReviewModel(state: state).cancel()
        try await ImportTestSupport.waitUntil(timeout: 60) { state.showPhotoReview && !state.isBusy }
        let outcome: IOSImportOutcome = await importing.value
        XCTAssertEqual(outcome.added, 4)
        XCTAssertEqual(outcome.problems, [])
        XCTAssertEqual(state.detectedPhotos.count, 2)
        state.cancelPhotoReview()
    }

    @MainActor
    func test_stop_whileTheReviewIsOpen_endsTheImport_withoutAProblem() async throws {
        let state: AppState = makeState(.photos)
        let importer = IOSImportSession(state: state, finder: noPage, objectFinder: fixedObjects([printA, printB], for: .photo))
        let data: Data = png(printsOnTable())
        let items: [IOSImportItem] = [IOSImportItem(name: "a.png", data: data, kind: .image),
                                      IOSImportItem(name: "b.png", data: data, kind: .image)]
        let importing: Task<IOSImportOutcome, Never> = Task { @MainActor in
            await importer.importItems(items)
        }
        try await ImportTestSupport.waitUntil(timeout: 60) { state.showPhotoReview && !state.isBusy }
        importer.stop()
        let outcome: IOSImportOutcome = await importing.value
        XCTAssertEqual(outcome.added, 2)
        XCTAssertEqual(outcome.problems, [])
        XCTAssertNil(state.errorMessage)
        XCTAssertTrue(state.showPhotoReview)
        state.cancelPhotoReview()
    }

    @MainActor
    func test_aPDFsNextPage_isReadOnceTheReviewIsClosed() async throws {
        let state: AppState = makeState(.photos)
        let importer = IOSImportSession(state: state, finder: noPage, objectFinder: fixedObjects([], for: .photo))
        let data: Data = try printsPDF(2)
        let importing: Task<IOSImportOutcome, Never> = Task { @MainActor in
            await importer.importItems([IOSImportItem(name: "prints.pdf", data: data, kind: .pdf)])
        }
        try await ImportTestSupport.waitUntil(timeout: 120) { state.showPhotoReview && !state.isBusy }
        // The second page waits for the review of the first.
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertTrue(importer.isImporting)
        XCTAssertNil(state.errorMessage)
        let firstPage: Set<UUID> = Set(state.detectedPhotos.map { (photo: DetectedPhoto) -> UUID in photo.id })
        XCTAssertFalse(firstPage.isEmpty)
        IOSPhotoReviewModel(state: state).cancel()
        let outcome: IOSImportOutcome = await importing.value
        XCTAssertEqual(outcome.added, 2)
        XCTAssertEqual(outcome.problems, [])
        XCTAssertNil(state.errorMessage)
        XCTAssertTrue(state.showPhotoReview)
        XCTAssertTrue(firstPage.isDisjoint(with: state.detectedPhotos.map { (photo: DetectedPhoto) -> UUID in photo.id }))
        state.cancelPhotoReview()
    }

    @MainActor
    func test_aShotWithNoOutline_comesInWhole_forThePhotoSearch() async throws {
        let state: AppState = makeState(.photos)
        let importer = IOSImportSession(state: state, finder: noPage, objectFinder: fixedObjects([], for: .photo))
        let outcome: IOSImportOutcome = await importer.importItems([IOSImportItem(name: "prints.png", data: png(printsOnTable()),
                                                                                  kind: .image)])
        XCTAssertEqual(outcome.added, 1)
        try await ImportTestSupport.waitUntil(timeout: 60) { !state.isBusy }
        // The flatbed's photo search of the whole shot at 200 dpi finds both prints.
        XCTAssertTrue(state.showPhotoReview)
        XCTAssertEqual(state.detectedPhotos.count, 2)
        // Fix crop starts from the region found, on the whole shot.
        if let first = state.detectedPhotos.first {
            let crop: IOSCropRequest? = await IOSPhotoReviewModel(state: state).cropRequest(for: first, name: "Photo",
                                                                                           number: 1, count: 2)
            XCTAssertEqual(crop?.request.photo.width, 1200)
        }
        state.cancelPhotoReview()
    }

    @MainActor
    func test_theReceiptsReview_offersNamingByDate_oneForAll_andPDFOrJPEG() async throws {
        let state: AppState = makeState(.receipt)
        let importer = IOSImportSession(state: state, finder: noPage, objectFinder: fixedObjects([printA, printB], for: .receipt))
        let outcome: IOSImportOutcome = await importer.importItems([IOSImportItem(name: "receipts.png", data: png(printsOnTable()),
                                                                                  kind: .image)])
        XCTAssertEqual(outcome.added, 2)
        try await ImportTestSupport.waitUntil(timeout: 60) { state.showPhotoReview && !state.isBusy }
        let review = IOSPhotoReviewModel(state: state)
        XCTAssertTrue(review.isReceipts)
        XCTAssertEqual(review.title, Receipts.reviewTitle(2))
        XCTAssertEqual(review.formats, [.pdf, .jpeg])
        XCTAssertEqual(review.format, .pdf)
        XCTAssertTrue(review.offersCombine)
        XCTAssertTrue(review.nameByDate)
        review.setNameByDate(false)
        XCTAssertFalse(state.settings.taskOptions.receiptNameByDate)
        review.setCombine(true)
        XCTAssertTrue(state.settings.taskOptions.receiptCombine)
        XCTAssertEqual(review.saveTitle, "Save as One PDF")
        review.setFormat(.jpeg)
        XCTAssertEqual(state.settings.format, .jpeg)
        XCTAssertFalse(review.offersCombine)
        review.cancel()
        XCTAssertFalse(state.showPhotoReview)
        XCTAssertEqual(state.statusMessage, "Receipts discarded.")
    }

    // MARK: Items in frame

    private func itemsDefaults(_ items: IOSItemsInFrame) throws -> UserDefaults {
        let defaults: UserDefaults = try XCTUnwrap(UserDefaults(suiteName: "IOSObjectsTests-\(UUID().uuidString)"))
        defaults.set(items.rawValue, forKey: IOSShell.itemsInFrameKey)
        return defaults
    }

    @MainActor
    func test_aDocumentShotOfTwoPages_comesInAsTwoPages_onAuto_aSlipAtARollsWidth() async throws {
        let state: AppState = makeState(.document)
        let defaults: UserDefaults = try itemsDefaults(.auto)
        let importer = IOSImportSession(state: state, finder: clearPage(printB),
                                        objectFinder: fixedObjects([printA, slip], for: .receipt), defaults: defaults)
        let shot = IOSCameraShot(data: png(printsOnTable()), liveOutline: nil)
        let outcome: IOSImportOutcome = await importer.importShot(shot)
        XCTAssertEqual(outcome.added, 2)
        XCTAssertEqual(outcome.problems, [])
        // No corner editor and no review: both go into the queue, cut along their outlines.
        XCTAssertNil(importer.cornerRequest)
        try await ImportTestSupport.waitUntil(timeout: 60) { !state.isBusy }
        XCTAssertFalse(state.showPhotoReview)
        defer { state.deleteSpoolFiles(of: state.scannedPages) }
        XCTAssertEqual(state.scannedPages.count, 2)
        guard state.scannedPages.count == 2 else { return }
        let sheet: CaptureFacts = try XCTUnwrap(state.scannedPages[0].capture)
        XCTAssertEqual(sheet.quad, printA)
        XCTAssertEqual(sheet.kind, .document)
        let roll: CaptureFacts = try XCTUnwrap(state.scannedPages[1].capture)
        XCTAssertEqual(roll.quad, slip)
        XCTAssertEqual(roll.kind, .receipt)
        XCTAssertEqual(roll.scale?.size, "receipt80mm")
        // The Document's own choices: nothing of the receipts' grey Compact PDF.
        XCTAssertEqual(state.settings.task, .document)
        XCTAssertEqual(state.settings.colorMode, .color)
        XCTAssertEqual(state.settings.output.pdfSize, .standard)
    }

    @MainActor
    func test_aDocumentShot_onOne_orWithOnePageFound_isThePageAsBefore() async throws {
        let state: AppState = makeState(.document)
        let data: Data = png(printsOnTable())
        let onOne: UserDefaults = try itemsDefaults(.one)
        let one = IOSImportSession(state: state, finder: clearPage(printB),
                                   objectFinder: fixedObjects([printA, slip], for: .receipt), defaults: onOne)
        let first: IOSImportOutcome = await one.importShot(IOSCameraShot(data: data, liveOutline: nil),
                                                           asksOnlyWhenUnsure: true)
        XCTAssertEqual(first.added, 1)
        let onAuto: UserDefaults = try itemsDefaults(.auto)
        let auto = IOSImportSession(state: state, finder: clearPage(printB),
                                    objectFinder: fixedObjects([printA], for: .receipt), defaults: onAuto)
        let second: IOSImportOutcome = await auto.importShot(IOSCameraShot(data: data, liveOutline: nil),
                                                             asksOnlyWhenUnsure: true)
        XCTAssertEqual(second.added, 1)
        try await ImportTestSupport.waitUntil(timeout: 60) { !state.isBusy }
        defer { state.deleteSpoolFiles(of: state.scannedPages) }
        // Each the page the page finder found, not the loose ones.
        XCTAssertEqual(state.scannedPages.map { (page: ScannedPage) -> Quad? in page.capture?.quad }, [printB, printB])
    }

    @MainActor
    func test_aDocumentShot_onAuto_aSheetAndAPhone_staysOnePage() async throws {
        let state: AppState = makeState(.document)
        let defaults: UserDefaults = try itemsDefaults(.auto)
        // A phone beside the sheet, 120 × 180 px: 2 % of the photo.
        let phone = Quad(topLeft: CGPoint(x: 800, y: 100), topRight: CGPoint(x: 920, y: 100),
                         bottomRight: CGPoint(x: 920, y: 280), bottomLeft: CGPoint(x: 800, y: 280))
        let importer = IOSImportSession(state: state, finder: clearPage(printA),
                                        objectFinder: fixedObjects([printA, phone], for: .receipt), defaults: defaults)
        let outcome: IOSImportOutcome = await importer.importShot(IOSCameraShot(data: png(printsOnTable()), liveOutline: nil),
                                                                  asksOnlyWhenUnsure: true)
        XCTAssertEqual(outcome.added, 1)
        XCTAssertNil(importer.cornerRequest)
        try await ImportTestSupport.waitUntil(timeout: 60) { !state.isBusy }
        defer { state.deleteSpoolFiles(of: state.scannedPages) }
        XCTAssertEqual(state.scannedPages.map { (page: ScannedPage) -> Quad? in page.capture?.quad }, [printA])
        XCTAssertEqual(state.scannedPages.first?.capture?.kind, .document)
    }

    @MainActor
    func test_aDocumentShot_onAuto_printsOnAPageFoundClearly_areThatPage() async throws {
        let state: AppState = makeState(.document)
        let defaults: UserDefaults = try itemsDefaults(.auto)
        let sheet = Quad(topLeft: CGPoint(x: 100, y: 100), topRight: CGPoint(x: 1100, y: 100),
                         bottomRight: CGPoint(x: 1100, y: 800), bottomLeft: CGPoint(x: 100, y: 800))
        let importer = IOSImportSession(state: state, finder: clearPage(sheet),
                                        objectFinder: fixedObjects([printA, printB], for: .receipt), defaults: defaults)
        let outcome: IOSImportOutcome = await importer.importShot(IOSCameraShot(data: png(printsOnTable()), liveOutline: nil),
                                                                  asksOnlyWhenUnsure: true)
        XCTAssertEqual(outcome.added, 1)
        try await ImportTestSupport.waitUntil(timeout: 60) { !state.isBusy }
        defer { state.deleteSpoolFiles(of: state.scannedPages) }
        XCTAssertEqual(state.scannedPages.map { (page: ScannedPage) -> Quad? in page.capture?.quad }, [sheet])
    }

    @MainActor
    func test_aDocumentShot_onSeveral_takesEvenOneLoosePage_withoutTheEditor() async throws {
        let state: AppState = makeState(.document)
        let defaults: UserDefaults = try itemsDefaults(.several)
        let importer = IOSImportSession(state: state, finder: noPage, objectFinder: fixedObjects([slip], for: .receipt),
                                        defaults: defaults)
        let outcome: IOSImportOutcome = await importer.importShot(IOSCameraShot(data: png(printsOnTable()), liveOutline: nil))
        XCTAssertEqual(outcome.added, 1)
        XCTAssertNil(importer.cornerRequest)
        try await ImportTestSupport.waitUntil(timeout: 60) { !state.isBusy }
        defer { state.deleteSpoolFiles(of: state.scannedPages) }
        XCTAssertEqual(state.scannedPages.first?.capture?.quad, slip)
    }

    @MainActor
    func test_aPhotoShot_onOne_keepsTheLargestPrint() async throws {
        let state: AppState = makeState(.photos)
        let defaults: UserDefaults = try itemsDefaults(.one)
        let importer = IOSImportSession(state: state, finder: noPage, objectFinder: fixedObjects([printB, printA], for: .photo),
                                        defaults: defaults)
        let outcome: IOSImportOutcome = await importer.importShot(IOSCameraShot(data: png(printsOnTable()), liveOutline: nil))
        XCTAssertEqual(outcome.added, 1)
        try await ImportTestSupport.waitUntil(timeout: 60) { state.showPhotoReview && !state.isBusy }
        XCTAssertEqual(state.detectedPhotos.count, 1)
        XCTAssertEqual(state.detectedPhotos.first?.image.width, 450)
        state.cancelPhotoReview()
    }

    func test_aDocumentPage_snapsToARollByItsShape_fromTwoPointTwoTimesAsLongAsWide() {
        func rect(_ width: Double, _ height: Double) -> Quad {
            let x: Double = 600 - width / 2
            let y: Double = 450 - height / 2
            return Quad(topLeft: CGPoint(x: x, y: y), topRight: CGPoint(x: x + width, y: y),
                        bottomRight: CGPoint(x: x + width, y: y + height), bottomLeft: CGPoint(x: x, y: y + height))
        }
        let sheets: [(Quad, String)] = [(rect(420, 594), "a4"), (rect(432, 559), "letter"), (rect(432, 711), "legal")]
        for (quad, size) in sheets {
            let kind: CaptureKind = IOSImportSession.documentKind(quad, width: 1200, height: 900, focalLength: nil)
            XCTAssertEqual(kind, .document, size)
            XCTAssertEqual(CaptureScale.measure(quad, imageWidth: 1200, imageHeight: 900, kind: kind).size, size)
        }
        // Legal read at a slight angle, longer than it is, and a DL envelope: still pages.
        for quad in [rect(400, 700), rect(330, 660)] {
            XCTAssertEqual(IOSImportSession.documentKind(quad, width: 1200, height: 900, focalLength: nil), .document)
        }
        // Slips three and four times as long as wide: the 80 mm roll, the first, as the two widths cannot be
        // told apart by shape.
        for quad in [rect(240, 720), rect(171, 684)] {
            let kind: CaptureKind = IOSImportSession.documentKind(quad, width: 1200, height: 900, focalLength: nil)
            XCTAssertEqual(kind, .receipt)
            XCTAssertEqual(CaptureScale.measure(quad, imageWidth: 1200, imageHeight: 900, kind: kind).size, "receipt80mm")
        }
    }

    // MARK: The ID card

    @MainActor
    func test_theIdCard_fromShots_goesInAsTheSteps_sides_inMemoryOnly() async throws {
        let state: AppState = makeState(.idCard)
        XCTAssertTrue(IOSShell.takesPhotos(state.settings))
        XCTAssertFalse(IOSShell.collectsPages(state.settings))
        let importer = IOSImportSession(state: state, finder: noPage, objectFinder: fixedObjects([cardQuad], for: .idCard))
        let shot = IOSCameraShot(data: png(cardOnTable()), liveOutline: nil)
        // Taken by the camera, which asks only when unsure: the card found goes in as the front, no editor.
        let front: IOSImportOutcome = await importer.importShot(shot, asksOnlyWhenUnsure: true)
        XCTAssertEqual(front.added, 1)
        XCTAssertNil(importer.cornerRequest)
        try await ImportTestSupport.waitUntil(timeout: 60) { !state.isBusy }
        let side: DetectedPhoto = try XCTUnwrap(state.idCardFront)
        XCTAssertEqual(state.taskFlow?.current?.id, IdCardSteps.backStepID)
        XCTAssertEqual(IOSIdCardGuide.prompt(stepID: state.taskFlow?.current?.id), IOSReviewText.cardBackPrompt)
        // ID-1's real size: 428 px across 3.370 in is 127 dpi.
        XCTAssertEqual(side.dpi, 127)
        let longMm: Double = Double(max(side.image.width, side.image.height)) * 25.4 / Double(side.dpi)
        XCTAssertEqual(longMm, 85.60, accuracy: 0.5)
        // In memory only: nothing spooled, nothing in the history or the queue, no file.
        XCTAssertEqual(names(spool), [])
        XCTAssertEqual(names(saved), [])
        XCTAssertTrue(state.scanHistory.isEmpty)
        XCTAssertTrue(state.scannedPages.isEmpty)
        XCTAssertTrue(state.lastSavedURLs.isEmpty)
        XCTAssertNil(IOSIdCardGuide.glareLine(stepID: state.taskFlow?.current?.id, frontNote: state.idCardFrontNote))

        // The back: the review opens.
        let back: IOSImportOutcome = await importer.importShot(shot, asksOnlyWhenUnsure: true)
        XCTAssertEqual(back.added, 1)
        try await ImportTestSupport.waitUntil(timeout: 60) { !state.isBusy }
        XCTAssertNotNil(state.idCardBack)
        XCTAssertTrue(state.showIdCardReview)
        XCTAssertFalse(importer.canImport)
        // Fix crop of a side: the photo as taken, with the card's corners, worded for a card.
        let review = IOSPhotoReviewModel(state: state)
        let asked: IOSCropRequest? = await review.cropRequest(for: side, name: IOSReviewText.frontTitle, number: 1, count: 1)
        let crop: IOSCropRequest = try XCTUnwrap(asked)
        XCTAssertEqual(crop.request.photo.width, 1200)
        XCTAssertLessThan(crop.request.plan.corners.maxCornerDistance(cardQuad), 1)
        XCTAssertEqual(crop.request.kind, CaptureKind.idCard)
        XCTAssertEqual(names(spool), [])
        XCTAssertEqual(names(saved), [])
        XCTAssertTrue(state.scanHistory.isEmpty)

        state.discardIdCard()
        XCTAssertNil(state.idCardFront)
        XCTAssertNil(state.idCardBack)
        XCTAssertTrue(state.idCardSourceImages.isEmpty)
        XCTAssertTrue(state.idCardCaptureFacts.isEmpty)
        XCTAssertEqual(names(spool), [])
        XCTAssertEqual(names(saved), [])
    }

    @MainActor
    func test_photosBeyondTheCardsTwoSides_areLeftOut_andSaidOnce() async throws {
        let state: AppState = makeState(.idCard)
        let importer = IOSImportSession(state: state, finder: noPage, objectFinder: fixedObjects([cardQuad], for: .idCard))
        let shot = IOSCameraShot(data: png(cardOnTable()), liveOutline: nil)
        var shots: [IOSImportSource] = []
        for _ in 0..<4 {
            shots.append(IOSImportSource.shot(shot, asksOnlyWhenUnsure: true))
        }
        let outcome: IOSImportOutcome = await importer.importSources(shots)
        XCTAssertEqual(outcome.added, 2)
        XCTAssertEqual(outcome.problems, [IOSImportText.cardFullMessage(2)])
        XCTAssertEqual(state.errorMessage, "The card already has both sides; the other 2 were not added.")
        XCTAssertNotNil(state.idCardFront)
        XCTAssertNotNil(state.idCardBack)
        XCTAssertTrue(state.showIdCardReview)
        XCTAssertFalse(importer.isImporting)
        state.discardIdCard()
    }

    @MainActor
    func test_aCardNotFound_opensTheCornerEditor_andGoesInAsACard() async throws {
        let state: AppState = makeState(.idCard)
        let found = IOSFoundPage(corners: cardQuad, reason: .unsure, byModel: false)
        let importer = IOSImportSession(state: state, finder: { (_: RgbaImage) -> IOSFoundPage in found },
                                        objectFinder: fixedObjects([], for: .idCard))
        let importing: Task<IOSImportOutcome, Never> = Task { @MainActor in
            await importer.importShot(IOSCameraShot(data: png(cardOnTable()), liveOutline: nil), asksOnlyWhenUnsure: true)
        }
        try await ImportTestSupport.waitUntil(timeout: 60) { importer.cornerRequest != nil }
        XCTAssertEqual(importer.cornerRequest?.plan.corners, cardQuad)
        XCTAssertEqual(importer.cornerRequest?.kind, CaptureKind.idCard)
        importer.answer(PhotoCornersAnswer(choice: .useCorners, corners: cardQuad))
        let outcome: IOSImportOutcome = await importing.value
        XCTAssertEqual(outcome.added, 1)
        try await ImportTestSupport.waitUntil(timeout: 60) { !state.isBusy }
        let side: DetectedPhoto = try XCTUnwrap(state.idCardFront)
        XCTAssertEqual(side.dpi, 127)
        XCTAssertNil(state.idCardFrontNote)
        state.discardIdCard()
    }

    @MainActor
    func test_aCardThatDoesNotSnapToID1_opensTheEditor_andIsNotTakenAtRealSize() async throws {
        let state: AppState = makeState(.idCard)
        // 428 × 285 px, 1.50: within the picker's slack, but more than 3 % off ID-1's 1.586.
        let wide = Quad(topLeft: CGPoint(x: 386, y: 308), topRight: CGPoint(x: 814, y: 308),
                        bottomRight: CGPoint(x: 814, y: 593), bottomLeft: CGPoint(x: 386, y: 593))
        let importer = IOSImportSession(state: state, finder: noPage, objectFinder: fixedObjects([wide], for: .idCard))
        let importing: Task<IOSImportOutcome, Never> = Task { @MainActor in
            await importer.importShot(IOSCameraShot(data: png(cardOnTable()), liveOutline: nil), asksOnlyWhenUnsure: true)
        }
        try await ImportTestSupport.waitUntil(timeout: 60) { importer.cornerRequest != nil }
        let request: PhotoCornersRequest = try XCTUnwrap(importer.cornerRequest)
        XCTAssertEqual(request.plan.corners, wide)
        XCTAssertEqual(request.plan.reason, PhotoReviewReason.unsure)
        XCTAssertEqual(request.kind, CaptureKind.idCard)
        // The card is sharp, only its shape is off: the note speaks of its outline, not of a page's edges.
        XCTAssertEqual(PhotoImport.reasonText(request.plan.reason, kind: request.kind),
                       "The card's outline is not certain.")
        importer.answer(PhotoCornersAnswer(choice: .useCorners, corners: wide))
        let outcome: IOSImportOutcome = await importing.value
        XCTAssertEqual(outcome.added, 1)
        try await ImportTestSupport.waitUntil(timeout: 60) { !state.isBusy }
        // Taken anyway: at a made-up size, and the side says so.
        let side: DetectedPhoto = try XCTUnwrap(state.idCardFront)
        XCTAssertEqual(side.dpi, CaptureScale.nominalDPI)
        XCTAssertEqual(state.idCardFrontNote, CaptureObjects.cardNotRealSizeNote)
        state.discardIdCard()
    }

    func test_theGuideFrame_hasTheCardsShape_andFitsTheScreen() {
        let portrait: CGRect = IOSIdCardGuide.frame(in: CGSize(width: 390, height: 844))
        XCTAssertEqual(Double(portrait.width), 390 * 0.86, accuracy: 1e-9)
        XCTAssertEqual(Double(portrait.width / portrait.height), 3.370 / 2.125, accuracy: 1e-9)
        XCTAssertEqual(Double(portrait.midX), 195, accuracy: 1e-9)
        XCTAssertEqual(Double(portrait.midY), 422, accuracy: 1e-9)
        // Held sideways the screen is short: the frame is as tall as 0.6 of it.
        let landscape: CGRect = IOSIdCardGuide.frame(in: CGSize(width: 844, height: 390))
        XCTAssertEqual(Double(landscape.height), 390 * 0.6, accuracy: 1e-9)
        XCTAssertEqual(Double(landscape.width / landscape.height), 3.370 / 2.125, accuracy: 1e-9)
        XCTAssertLessThanOrEqual(Double(landscape.width), 844)
        XCTAssertEqual(IOSIdCardGuide.frame(in: CGSize.zero), CGRect.zero)
        XCTAssertEqual(IOSIdCardGuide.prompt(stepID: IdCardSteps.frontStepID), "Fit the front in the frame")
        XCTAssertEqual(IOSIdCardGuide.prompt(stepID: IdCardSteps.backStepID), "Fit the back in the frame")
        XCTAssertNil(IOSIdCardGuide.prompt(stepID: IdCardSteps.reviewStepID))
        XCTAssertEqual(IOSIdCardGuide.glareLine(stepID: IdCardSteps.backStepID, frontNote: GlareDetector.hint),
                       "Tilt to avoid glare")
        XCTAssertNil(IOSIdCardGuide.glareLine(stepID: IdCardSteps.frontStepID, frontNote: GlareDetector.hint))
        XCTAssertNil(IOSIdCardGuide.glareLine(stepID: IdCardSteps.backStepID, frontNote: nil))
        // A front not at real size with glare on it: the glare line still shows; without glare it does not.
        XCTAssertEqual(IOSIdCardGuide.glareLine(stepID: IdCardSteps.backStepID,
                                                frontNote: CaptureObjects.cardNote(realSize: false, glare: true)),
                       GlareDetector.hint)
        XCTAssertNil(IOSIdCardGuide.glareLine(stepID: IdCardSteps.backStepID, frontNote: CaptureObjects.cardNotRealSizeNote))
        XCTAssertEqual(IOSReviewText.idCardSaveTitle(.pdf), "Save PDF")
        XCTAssertEqual(IOSReviewText.idCardSaveTitle(.jpeg), "Save JPEG")
        XCTAssertEqual(IOSReviewText.sideAction(IOSReviewText.scanAgainLabel, side: .back), "Scan the back again")
        XCTAssertEqual(IOSReviewText.sideAction(IOSReviewText.rotateLabel, side: .front), "Rotate the front")
    }

    // MARK: The photos UI test's launch

    func test_theLaunchOption_namesTheTaskThePhotoGoesInto() {
        let environment: [String: String] = [IOSLaunchOptions.importFixtureVariable: Data([1, 2, 3]).base64EncodedString()]
        let photos = IOSLaunchOptions(arguments: ["CompleteScanner", "-demoScanner", "-importFixture", "-importTask", "photos"],
                                      environment: environment)
        XCTAssertEqual(photos.launchTask, .photos)
        XCTAssertNotNil(photos.launchImport)
        let document = IOSLaunchOptions(arguments: ["CompleteScanner", "-importFixture"], environment: environment)
        XCTAssertNil(document.launchTask)
        let unknown = IOSLaunchOptions(arguments: ["CompleteScanner", "-importFixture", "-importTask", "nothing"],
                                       environment: environment)
        XCTAssertNil(unknown.launchTask)
        // Without a photo to import, no task.
        XCTAssertNil(IOSLaunchOptions(arguments: ["CompleteScanner", "-importTask", "photos"]).launchTask)
        XCTAssertNil(IOSLaunchOptions(demoScannerOnly: true).launchTask)
    }
}
#endif
