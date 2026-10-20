import CoreGraphics
import XCTest
@testable import CompleteScannerKit

// Twin of windows/CompleteScanner.Core.Tests/PhotoImportTests.cs: the same cases on the same synthetic
// photos (PhotoScenes).

/// A small photo whose every pixel is different, to follow where each one goes.
private func numbered(_ width: Int, _ height: Int) -> RgbaImage {
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    for i in 0..<(width * height) {
        pixels[i * 4] = UInt8(10 + i)
        pixels[i * 4 + 1] = UInt8(100 + i)
        pixels[i * 4 + 2] = UInt8(200 - i)
        pixels[i * 4 + 3] = 255
    }
    return RgbaImage(width: width, height: height, pixels: pixels)
}

private func pixelAt(_ image: RgbaImage, _ x: Int, _ y: Int) -> [UInt8] {
    let i = (y * image.width + x) * 4
    return Array(image.pixels[i..<(i + 4)])
}

private func point(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x, y: y) }

private func quad(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint) -> Quad {
    Quad(topLeft: a, topRight: b, bottomRight: c, bottomLeft: d)
}

/// The page's pixels, read back from its image.
private func pixels(of page: ScannedPage) throws -> RgbaImage {
    try XCTUnwrap(RgbaImage(cgImage: page.image))
}

/// Text recognition that can or cannot run, reading nothing.
private struct StubScorer: OrientationScorer {
    let isAvailable: Bool
    func score(_ image: RgbaImage) throws -> OrientationScore { OrientationScore.none }
}

/// A barcode reader that can run and finds nothing.
private struct EmptyReader: BarcodeReader {
    var isAvailable: Bool { true }
    func read(_ image: GrayImage) throws -> [BarcodeReading] { [] }
}

final class PhotoImportTests: XCTestCase {
    func testEveryOrientationTagHasItsTurn() {
        XCTAssertEqual(PhotoOrientation.fromExif(1), PhotoOrientation(quarterTurns: 0, mirrored: false))
        XCTAssertEqual(PhotoOrientation.fromExif(2), PhotoOrientation(quarterTurns: 0, mirrored: true))
        XCTAssertEqual(PhotoOrientation.fromExif(3), PhotoOrientation(quarterTurns: 2, mirrored: false))
        XCTAssertEqual(PhotoOrientation.fromExif(4), PhotoOrientation(quarterTurns: 2, mirrored: true))
        XCTAssertEqual(PhotoOrientation.fromExif(5), PhotoOrientation(quarterTurns: 3, mirrored: true))
        XCTAssertEqual(PhotoOrientation.fromExif(6), PhotoOrientation(quarterTurns: 1, mirrored: false))
        XCTAssertEqual(PhotoOrientation.fromExif(7), PhotoOrientation(quarterTurns: 1, mirrored: true))
        XCTAssertEqual(PhotoOrientation.fromExif(8), PhotoOrientation(quarterTurns: 3, mirrored: false))
        for unknown in [0, 9, -1, 274] {
            XCTAssertTrue(PhotoOrientation.fromExif(unknown).isUpright)
        }
        XCTAssertTrue(PhotoOrientation.upright.isUpright)
        XCTAssertFalse(PhotoOrientation.fromExif(6).isUpright)
    }

    func testEveryOrientationTagShowsThePhotoAsTheCameraSawIt() {
        // Where each stored pixel (x, y) of a W × H photo is shown, by the tag's definition: the
        // stored first row is shown as the top (1–4) or as a side (5–8) of the picture.
        let w = 3, h = 2
        let stored = numbered(w, h)
        let placed: [Int: (Int, Int) -> (Int, Int)] = [
            1: { x, y in (x, y) },
            2: { x, y in (w - 1 - x, y) },
            3: { x, y in (w - 1 - x, h - 1 - y) },
            4: { x, y in (x, h - 1 - y) },
            5: { x, y in (y, x) },
            6: { x, y in (h - 1 - y, x) },
            7: { x, y in (h - 1 - y, w - 1 - x) },
            8: { x, y in (y, w - 1 - x) },
        ]
        for tag in 1...8 {
            let place = placed[tag]!
            let shown = PhotoImport.oriented(stored, orientation: PhotoOrientation.fromExif(tag))
            let sideways = tag >= 5
            XCTAssertEqual(shown.width, sideways ? h : w)
            XCTAssertEqual(shown.height, sideways ? w : h)
            for y in 0..<h {
                for x in 0..<w {
                    let (sx, sy) = place(x, y)
                    XCTAssertEqual(pixelAt(stored, x, y), pixelAt(shown, sx, sy), "tag \(tag): pixel (\(x), \(y))")
                }
            }
        }
        XCTAssertEqual(PhotoImport.oriented(stored, orientation: .upright), stored)
    }

    func testAPageFoundClearlyIsCorrectedWithoutAsking() {
        let photo = PhotoScenes.woodScene()
        let detection = PhotoDocumentDetector.detect(photo)
        XCTAssertGreaterThanOrEqual(detection.confidence, PhotoImport.sureConfidence)
        let plan = PhotoImport.plan(photo)
        XCTAssertEqual(plan.action, .correct)
        XCTAssertEqual(plan.reason, PhotoReviewReason.none)
        XCTAssertEqual(plan.corners, detection.quad)
        XCTAssertEqual(PhotoImport.reasonText(plan.reason), "")
    }

    func testAnUnsurePageGoesToTheCornerEditorWithItsCorners() {
        let outline = quad(point(40, 30), point(300, 50), point(290, 420), point(30, 400))
        var unsure = PhotoDocumentDetection(quad: outline, confidence: PhotoImport.sureConfidence - 0.01, rejection: .none,
                                            candidate: nil, aspect: nil, paper: nil)
        let plan = PhotoImport.plan(unsure, width: 360, height: 480)
        XCTAssertEqual(plan.action, .review)
        XCTAssertEqual(plan.reason, .unsure)
        XCTAssertEqual(plan.corners, outline)
        unsure.confidence = PhotoImport.sureConfidence
        XCTAssertEqual(PhotoImport.plan(unsure, width: 360, height: 480).action, .correct)
        // An outline seen but not taken is the editor's start too.
        let low = PhotoDocumentDetection(quad: nil, confidence: 0, rejection: .lowConfidence, candidate: outline,
                                         aspect: nil, paper: nil)
        let lowPlan = PhotoImport.plan(low, width: 360, height: 480)
        XCTAssertEqual(lowPlan.action, .review)
        XCTAssertEqual(lowPlan.reason, .unsure)
        XCTAssertEqual(lowPlan.corners, outline)
    }

    func testAPageCutOffByTheFrameStartsFromWhatIsSeenWithinThePhoto() {
        let photo = PhotoScenes.cutOffScene()
        let plan = PhotoImport.plan(photo)
        XCTAssertEqual(plan.action, .review)
        XCTAssertEqual(plan.reason, .cutOff)
        XCTAssertTrue(plan.corners.isInside(width: Double(photo.width), height: Double(photo.height)), "\(plan.corners)")
        XCTAssertTrue(PhotoImport.canUseCorners(plan.corners))
        XCTAssertNotEqual(plan.corners, PhotoImport.startCorners(width: photo.width, height: photo.height))
        XCTAssertFalse(PhotoImport.reasonText(plan.reason).isEmpty)
    }

    func testNoPageOrTwoPagesAskTheUser() {
        let plan = PhotoImport.plan(PhotoDocumentDetection.nothing, width: 360, height: 480)
        XCTAssertEqual(plan.action, .review)
        XCTAssertEqual(plan.reason, .nothingFound)
        XCTAssertEqual(plan.corners, PhotoImport.startCorners(width: 360, height: 480))
        XCTAssertEqual(plan.corners, quad(point(36, 48), point(324, 48), point(324, 432), point(36, 432)))
        // A table with no page on it: nothing found, or nothing clear enough (the detector may answer either).
        for scene in [PhotoScenes.noPageScene(), PhotoScenes.plainScene()] {
            let asked = PhotoImport.plan(scene)
            XCTAssertEqual(asked.action, .review)
            XCTAssertTrue(asked.reason == .nothingFound || asked.reason == .unsure)
            XCTAssertTrue(PhotoImport.canUseCorners(asked.corners)
                          && asked.corners.isInside(width: Double(scene.width), height: Double(scene.height)))
        }
        let two = PhotoImport.plan(PhotoScenes.twoPagesScene())
        XCTAssertEqual(two.action, .review)
        XCTAssertEqual(two.reason, .twoPages)
        XCTAssertTrue(PhotoImport.canUseCorners(two.corners))
        for reason in [PhotoReviewReason.unsure, .cutOff, .twoPages, .nothingFound] {
            XCTAssertFalse(PhotoImport.reasonText(reason).isEmpty)
        }
    }

    func testTheResolutionComesFromThePaperSizeElseItIsNominal() throws {
        XCTAssertEqual(PhotoImport.pageDPI(282.4), 282)
        XCTAssertEqual(PhotoImport.pageDPI(282.5), 283)
        XCTAssertEqual(PhotoImport.pageDPI(nil), 200)
        XCTAssertEqual(PhotoImport.pageDPI(.nan), 200)
        XCTAssertEqual(PhotoImport.pageDPI(0), 200)
        XCTAssertEqual(PhotoImport.pageDPI(12), PhotoImport.minDPI)
        XCTAssertEqual(PhotoImport.pageDPI(5000), PhotoImport.maxDPI)
        // A whole photo of A4's shape takes A4's resolution; a 4:3 photo is no known size.
        let a4 = try XCTUnwrap(PaperSizes.inches(.a4))
        let longSide = 3508
        let shortSide = Int((3508 * Double(a4.width) / Double(a4.height) + 0.5).rounded(.down))
        XCTAssertEqual(PhotoImport.wholePhotoDPI(width: shortSide, height: longSide),
                       Int((3508 / Double(a4.height) + 0.5).rounded(.down)))
        XCTAssertEqual(PhotoImport.wholePhotoDPI(width: longSide, height: shortSide),
                       PhotoImport.wholePhotoDPI(width: shortSide, height: longSide))
        XCTAssertEqual(PhotoImport.wholePhotoDPI(width: 4032, height: 3024), 200)
        XCTAssertEqual(PhotoImport.wholePhotoDPI(width: 0, height: 10), 200)
        // A corrected page takes the resolution of the paper size its shape matched.
        let photo = PhotoScenes.woodScene()
        let plan = PhotoImport.plan(photo)
        let correction = try XCTUnwrap(PerspectiveCorrector.correct(photo, quad: Quad.fromCorners(plan.corners.corners)))
        XCTAssertEqual(correction.plan.paper?.size, .a4)
        let page = try XCTUnwrap(PhotoImport.correctedPage(photo, corners: plan.corners))
        XCTAssertEqual(page.dpi, PhotoImport.pageDPI(correction.plan.dpi))
    }

    func testAPageFromAPhotoKeepsThePhotoAsItsOtherVersion() throws {
        let photo = PhotoScenes.woodScene()
        let plan = PhotoImport.plan(photo)
        let page = try XCTUnwrap(PhotoImport.correctedPage(photo, corners: plan.corners))
        let expected = try XCTUnwrap(PerspectiveCorrector.correct(photo, quad: Quad.fromCorners(plan.corners.corners))).image
        XCTAssertEqual(PhotoScenes.checksum(try pixels(of: page)), PhotoScenes.checksum(expected))
        XCTAssertEqual(page.source, .photo)
        XCTAssertEqual(page.colorMode, .color)
        XCTAssertEqual(page.geometry, PageGeometry(cropped: true, angleDegrees: 0, basis: .perspective))
        let other = try XCTUnwrap(page.alternate?.image)
        XCTAssertEqual(other.width, photo.width)
        XCTAssertEqual(other.height, photo.height)
        XCTAssertNil(page.alternate?.fileURL)
        XCTAssertTrue(page.canSwapVersions)
        XCTAssertEqual(PhotoImport.sourceLabel(page), "Photo")
        XCTAssertEqual(PageCorrections.caption(page), "Corrected from photo")
        XCTAssertEqual(PageCorrections.toggleLabel(page), "Show as photographed")

        let original = page.withVersionsSwapped(other)
        XCTAssertTrue(original.showsOriginal)
        XCTAssertEqual(original.source, .photo)
        XCTAssertEqual(PageCorrections.caption(original), "As photographed")
        XCTAssertEqual(PageCorrections.toggleLabel(original), "Show corrected")
        XCTAssertEqual(PageCorrections.swapNote(original, number: 2), "Page 2 is shown as photographed. It is saved that way.")
        let back = original.withVersionsSwapped(page.image)
        XCTAssertEqual(PageCorrections.swapNote(back, number: 2), "Page 2 is corrected again.")
        // The page's facts follow it through every change.
        XCTAssertEqual(page.withImage(page.image).source, .photo)
        XCTAssertEqual(page.withInclusion(.skip).source, .photo)
        XCTAssertEqual(page.turnedUpright(2).source, .photo)
        XCTAssertEqual(ScannedPage(image: page.image, dpi: 300, colorMode: .color).copyMeta(from: page).source, .photo)
    }

    func testAWholePhotoIsLabelledAndHasNothingToSwap() throws {
        let photo = PhotoScenes.noPageScene()
        let page = try XCTUnwrap(PhotoImport.wholePhotoPage(photo))
        XCTAssertEqual(PhotoScenes.checksum(try pixels(of: page)), PhotoScenes.checksum(photo))
        XCTAssertEqual(page.source, .photo)
        XCTAssertEqual(page.dpi, PhotoImport.wholePhotoDPI(width: photo.width, height: photo.height))
        XCTAssertNil(page.geometry)
        XCTAssertNil(page.alternate)
        XCTAssertFalse(page.canSwapVersions)
        XCTAssertEqual(PhotoImport.sourceLabel(page), "Photo")
        XCTAssertNil(PageCorrections.caption(page))
        let scanned = ScannedPage(image: page.image, dpi: 300, colorMode: .color)
        XCTAssertNil(PhotoImport.sourceLabel(scanned))
        XCTAssertEqual(scanned.source, .scanner)
    }

    func testAPageFromAPhoneIsLabelledAsSuch() throws {
        let photo = PhotoScenes.noPageScene()
        let whole = try XCTUnwrap(PhotoImport.wholePhotoPage(photo))
        var page = ScannedPage(image: whole.image, dpi: 300, colorMode: .color)
        page.source = .phone
        XCTAssertEqual(PhotoImport.sourceLabel(page), "From phone")
        XCTAssertEqual(PhotoImport.sourceHelp(page), "Sent from a paired phone")
        XCTAssertEqual(PhotoImport.sourceHelp(whole), "Imported from a photo")
        XCTAssertNil(PhotoImport.sourceHelp(ScannedPage(image: whole.image, dpi: 300, colorMode: .color)))
        // The page's source follows it through every change.
        XCTAssertEqual(page.withInclusion(.skip).source, .phone)
        XCTAssertEqual(page.turnedUpright(2).source, .phone)
        XCTAssertEqual(ScannedPage(image: page.image, dpi: 300, colorMode: .color).copyMeta(from: page).source, .phone)
    }

    func testThePhotosCornersAreNamedAgainBeforeThePageIsCutOut() throws {
        // Corners dragged around the outline, starting anywhere and either way round, cut out the same page.
        let photo = PhotoScenes.woodScene()
        let q = PhotoImport.plan(photo).corners
        let expected = PhotoScenes.checksum(try pixels(of: try XCTUnwrap(PhotoImport.correctedPage(photo, corners: q))))
        let shifted = quad(q.bottomRight, q.bottomLeft, q.topLeft, q.topRight)
        XCTAssertEqual(PhotoScenes.checksum(try pixels(of: try XCTUnwrap(PhotoImport.correctedPage(photo, corners: shifted)))), expected)
        let reversed = quad(q.topLeft, q.bottomLeft, q.bottomRight, q.topRight)
        XCTAssertEqual(PhotoScenes.checksum(try pixels(of: try XCTUnwrap(PhotoImport.correctedPage(photo, corners: reversed)))), expected)
        let line = quad(point(0, 0), point(10, 0), point(20, 0), point(30, 0))
        XCTAssertNil(PhotoImport.correctedPage(photo, corners: line))
    }

    func testTheCornerEditorKeepsAnOutlineThePageCanBeCutOutAlong() {
        let q = quad(point(50, 50), point(300, 60), point(290, 400), point(40, 380))
        let moved = PhotoImport.movedCorner(q, index: 1, to: point(310, 40), width: 360, height: 480)
        XCTAssertEqual(moved.topRight, point(310, 40))
        XCTAssertEqual(moved.topLeft, q.topLeft)
        // Dragged off the photo: kept on its edge.
        let outside = PhotoImport.movedCorner(q, index: 2, to: point(500, 600), width: 360, height: 480)
        XCTAssertEqual(outside.bottomRight, point(360, 480))
        // Across the outline (a bow tie) or onto another corner: refused.
        XCTAssertEqual(PhotoImport.movedCorner(q, index: 0, to: point(320, 420), width: 360, height: 480), q)
        XCTAssertEqual(PhotoImport.movedCorner(q, index: 0, to: point(295, 62), width: 360, height: 480), q)
        XCTAssertEqual(PhotoImport.movedCorner(q, index: 0, to: point(170, 380), width: 360, height: 480), q)
        // The index wraps like the quad's.
        XCTAssertEqual(PhotoImport.movedCorner(q, index: 7, to: point(45, 385), width: 360, height: 480).bottomLeft, point(45, 385))

        XCTAssertTrue(PhotoImport.canUseCorners(q))
        XCTAssertTrue(PhotoImport.canUseCorners(PhotoImport.wholePhoto(width: 360, height: 480)))
        XCTAssertFalse(PhotoImport.canUseCorners(quad(point(0, 0), point(10, 0), point(10, 10), point(0, 10))))
        XCTAssertFalse(PhotoImport.canUseCorners(quad(q.topLeft, q.bottomLeft, q.bottomRight, q.topRight)))
        // A guess partly off the photo is brought onto it.
        let off = quad(point(-30, 20), point(330, -10), point(400, 500), point(20, 470))
        XCTAssertEqual(PhotoImport.clampedToPhoto(off, width: 360, height: 480),
                       quad(point(0, 20), point(330, 0), point(360, 480), point(20, 470)))
        let flat = quad(point(-30, -20), point(-10, -20), point(-10, -5), point(-30, -5))
        XCTAssertEqual(PhotoImport.clampedToPhoto(flat, width: 360, height: 480), PhotoImport.startCorners(width: 360, height: 480))
    }

    func testPhotoFilesAreTakenByTheirType() {
        XCTAssertTrue(PhotoImport.isPhotoFile("C:\\Photos\\IMG_0042.JPG"))
        XCTAssertTrue(PhotoImport.isPhotoFile("/Users/me/Desktop/scan.jpeg"))
        XCTAssertTrue(PhotoImport.isPhotoFile("letter.HEIC"))
        XCTAssertTrue(PhotoImport.isPhotoFile("page.png"))
        XCTAssertFalse(PhotoImport.isPhotoFile("notes.txt"))
        XCTAssertFalse(PhotoImport.isPhotoFile("report.pdf"))
        XCTAssertFalse(PhotoImport.isPhotoFile("README"))
        XCTAssertFalse(PhotoImport.isPhotoFile("C:\\photos.jpg\\README"))
        XCTAssertFalse(PhotoImport.isPhotoFile("trailing."))
        XCTAssertTrue(PhotoImport.isHeif("IMG_1.heic"))
        XCTAssertTrue(PhotoImport.isHeif("IMG_1.HEIF"))
        XCTAssertFalse(PhotoImport.isHeif("IMG_1.jpg"))
        XCTAssertEqual(PhotoImport.photoFiles(["b.jpg", "notes.txt", "a.PNG", "B.JPG", "c.heic", "a.png"]),
                       ["b.jpg", "a.PNG", "c.heic"])
    }

    func testPhotosAreImportedWhereTheQueueCollectsPages() {
        var document = ScanSettings()
        XCTAssertTrue(PhotoImport.isOffered(document))
        document.documentMultiPage = false
        XCTAssertTrue(PhotoImport.isOffered(document))
        var photos = ScanSettings()
        photos.intent = .photo
        XCTAssertFalse(PhotoImport.isOffered(photos))
        XCTAssertFalse(PhotoImport.isOffered(TaskCatalog.apply(.idCard, to: ScanSettings())))
        XCTAssertFalse(PhotoImport.isOffered(TaskCatalog.apply(.receipt, to: ScanSettings())))
        XCTAssertTrue(PhotoImport.isOffered(TaskCatalog.apply(.document, to: ScanSettings())))
    }

    func testPagesFromPhotosGoThroughTheCleanUpStageButAreNotCroppedAgain() throws {
        var s = ScanSettings()
        s.document.autoCrop = true
        s.document.autoStraighten = true
        s.document.splitFacingPages = true
        s.document.softenSpineShadow = true
        XCTAssertEqual(PageProcessor.forPhotoImport(s).steps.map(\.name), ["blank", "separator"])
        s.document.autoRotate = true
        s.document.splitMode = .barcode
        s.adjustments.brightness = 0.2
        s.colorMode = .grayscale
        let all = PageProcessor.forPhotoImport(s, scorer: StubScorer(isAvailable: true), barcodes: EmptyReader())
        XCTAssertEqual(all.steps.map(\.name), ["blank", "separator", "barcode", "orientation", "adjust"])
        XCTAssertNil(all.book)
        XCTAssertEqual(PageProcessor.forPhotoImport(s, scorer: StubScorer(isAvailable: false)).steps.map(\.name),
                       ["blank", "separator", "adjust"])

        let photo = PhotoScenes.woodScene()
        let page = try XCTUnwrap(PhotoImport.correctedPage(photo, corners: PhotoImport.plan(photo).corners))
        let processed = try XCTUnwrap(try PageProcessor.forPhotoImport(s).process([page]).pages.first)
        XCTAssertEqual(processed.id, page.id)
        XCTAssertNotNil(processed.blank)
        XCTAssertEqual(processed.colorMode, .grayscale)
        XCTAssertEqual(processed.geometry?.basis, .perspective)
        XCTAssertEqual(processed.source, .photo)
        // The photo as it was is adjusted too, so either version can be shown.
        XCTAssertEqual(processed.alternate?.image?.width, photo.width)
        XCTAssertNotEqual(PhotoScenes.checksum(try XCTUnwrap(RgbaImage(cgImage: try XCTUnwrap(processed.alternate?.image)))),
                          PhotoScenes.checksum(photo))
    }

    func testTheStatusTellsWhatTheImportDid() {
        XCTAssertEqual(PhotoImport.addedMessage(added: 3, skipped: 0, failed: 0, queueCount: 5, saveTitle: "save PDF"),
                       "Added 3 pages from photos \u{2014} 5 in queue. Scan more or save PDF.")
        XCTAssertEqual(PhotoImport.addedMessage(added: 1, skipped: 1, failed: 2, queueCount: 1, saveTitle: "save PDF"),
                       "Added 1 page from photos \u{2014} 1 in queue. Scan more or save PDF. 1 photo was skipped. 2 photos could not be opened.")
        XCTAssertEqual(PhotoImport.addedMessage(added: 0, skipped: 2, failed: 1, queueCount: 0, saveTitle: "save PDF"),
                       "No pages were added. 2 photos were skipped. 1 photo could not be opened.")
        XCTAssertEqual(PhotoImport.cancelledMessage(added: 0, queueCount: 3), "Cancelled.")
        XCTAssertEqual(PhotoImport.cancelledMessage(added: 2, queueCount: 4), "Cancelled after adding 2 pages from photos \u{2014} 4 in queue.")
        XCTAssertEqual(PhotoImport.counter(2, of: 5, fileName: "IMG_0042.jpg"), "Photo 2 of 5: IMG_0042.jpg")
        XCTAssertEqual(PhotoImport.counter(1, of: 1, fileName: "IMG_0042.jpg"), "IMG_0042.jpg")
        XCTAssertEqual(PhotoImport.progressMessage(2, of: 5), "Importing photo 2 of 5\u{2026}")
        XCTAssertEqual(PhotoImport.progressMessage(1, of: 1), "Importing photo\u{2026}")
        // A TIFF of several pages: each page is imported, and named, in turn.
        XCTAssertEqual(PhotoImport.progressMessage(2, of: 5, page: 3, pageCount: 7), "Importing photo 2 of 5, page 3 of 7\u{2026}")
        XCTAssertEqual(PhotoImport.progressMessage(1, of: 1, page: 3, pageCount: 7), "Importing page 3 of 7\u{2026}")
        XCTAssertEqual(PhotoImport.progressMessage(2, of: 5, page: 1, pageCount: 1), "Importing photo 2 of 5\u{2026}")
        XCTAssertEqual(PhotoImport.pageName("fax.tif", page: 2, pageCount: 5), "fax.tif, page 2 of 5")
        XCTAssertEqual(PhotoImport.pageName("IMG_0042.jpg", page: 1, pageCount: 1), "IMG_0042.jpg")
        XCTAssertEqual(PhotoImport.counter(2, of: 3, fileName: PhotoImport.pageName("fax.tif", page: 2, pageCount: 5)),
                       "Photo 2 of 3: fax.tif, page 2 of 5")
        XCTAssertEqual(PhotoImport.unreadableMessage("a.jpg", detail: "it is damaged."), "a.jpg could not be opened: it is damaged.")
        XCTAssertTrue(PhotoImport.heifUnavailableMessage("IMG_1.heic")
            .hasPrefix("IMG_1.heic could not be opened: HEIC photos need the free \u{201C}HEIF Image Extensions\u{201D}"))
    }

    func testTheStatusAfterAScanLeavesPagesFromPhotosToTheImport() throws {
        let photo = PhotoScenes.woodScene()
        let fromPhoto = try XCTUnwrap(PhotoImport.correctedPage(photo, corners: PhotoImport.plan(photo).corners))
        let image = try XCTUnwrap(photo.makeCGImage())
        let scanned = ScannedPage(image: image, dpi: 300, colorMode: .color)
            .withGeometry(image, geometry: PageGeometry(cropped: true, angleDegrees: 2.4, basis: .pageEdges))
        XCTAssertEqual(PageCorrections.scanNote([fromPhoto]), "")
        XCTAssertEqual(PageCorrections.scanNote([fromPhoto, scanned]), " 1 cropped and straightened.")
        XCTAssertEqual(PageGeometry(cropped: true, angleDegrees: 0, basis: .perspective).caption, "Corrected from photo")
        XCTAssertEqual(PageCorrections.caption(scanned.withVersionsSwapped(image)), "As scanned")
    }
}
