import CoreGraphics
import XCTest
@testable import CompleteScannerKit

// Mirrors windows/LazyScan.Core.Tests/CaptureObjectsTests.cs: the same shots, pages and answers.

/// Made-up camera shots for the objects of one photo, drawn the same way on both platforms: two prints on
/// a dark table, and an ID card photographed turned and tilted.
enum ObjectShots {
    /// The dark table the objects lie on.
    static let table: (r: UInt8, g: UInt8, b: UInt8) = (34, 30, 28)

    /// Two 6 × 4 in prints square on in a 900 × 600 photo: 300 × 200 and 360 × 240 pixels.
    static let printA: Quad = rect(60, 80, 360, 280)
    static let printB: Quad = rect(480, 300, 840, 540)

    static func rect(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> Quad {
        Quad(topLeft: CGPoint(x: x0, y: y0), topRight: CGPoint(x: x1, y: y0),
             bottomRight: CGPoint(x: x1, y: y1), bottomLeft: CGPoint(x: x0, y: y1))
    }

    /// The two prints on the table: each a soft gradient (no picture of anything).
    static func twoPrints() -> RgbaImage {
        let w: Int = 900
        let h: Int = 600
        var pixels: [UInt8] = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                var r: Int = Int(table.r)
                var g: Int = Int(table.g)
                var b: Int = Int(table.b)
                if x >= 60 && x < 360 && y >= 80 && y < 280 {
                    r = 90 + (x - 60) * 100 / 300
                    g = 120 + (y - 80) * 60 / 200
                    b = 170
                } else if x >= 480 && x < 840 && y >= 300 && y < 540 {
                    r = 200
                    g = 150 - (y - 300) * 80 / 240
                    b = 80 + (x - 480) * 90 / 360
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

    /// Two prints with white borders on a plain dark table, as the photos UI test's fixture lays them out
    /// (scripts/make_ios_ui_fixture.py): a 1200 × 900 shot, a 450 × 300 print at (120, 150) and a 420 × 280
    /// print at (650, 420), each with an 18 px border around a soft gradient.
    static let borderedA: Quad = rect(120, 150, 570, 450)
    static let borderedB: Quad = rect(650, 420, 1070, 700)

    static func printsOnTable() -> RgbaImage {
        let w: Int = 1200
        let h: Int = 900
        let border: Int = 18
        var pixels: [UInt8] = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                var r: Int = 40
                var g: Int = 36
                var b: Int = 34
                if x >= 120 && x < 570 && y >= 150 && y < 450 {
                    let inner: Bool = x >= 120 + border && x < 570 - border && y >= 150 + border && y < 450 - border
                    if inner {
                        r = 70 + (x - 120) * 120 / 450
                        g = 110 + (y - 150) * 90 / 300
                        b = 180
                    } else {
                        r = 245
                        g = 244
                        b = 238
                    }
                } else if x >= 650 && x < 1070 && y >= 420 && y < 700 {
                    let inner: Bool = x >= 650 + border && x < 1070 - border && y >= 420 + border && y < 700 - border
                    if inner {
                        r = 190
                        g = 140 - (y - 420) * 70 / 280
                        b = 60 + (x - 650) * 100 / 420
                    } else {
                        r = 245
                        g = 244
                        b = 238
                    }
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

    /// The camera of the card shot: a 1200 × 900 photo, focal length 1000 px, centered.
    static let cardPhotoWidth: Int = 1200
    static let cardPhotoHeight: Int = 900
    static let cardFocal: Double = 1000
    private static let cos25: Double = 0.9063077870366499
    private static let sin25: Double = 0.42261826174069944
    private static let cos35: Double = 0.8191520442889918
    private static let sin35: Double = 0.573576436351046

    /// An ID-1 card (85.6 × 53.98 mm) turned 25° in its plane and tilted back 35°, its center 10 mm right
    /// of and 5 mm above the camera's axis at 180 mm: its corners in the photo.
    static func cardQuad() -> Quad {
        let us: [Double] = [-42.8, 42.8, 42.8, -42.8]
        let vs: [Double] = [-26.99, -26.99, 26.99, 26.99]
        var corners: [CGPoint] = []
        for i in 0..<4 {
            let u: Double = us[i] * cos25 - vs[i] * sin25
            let v: Double = us[i] * sin25 + vs[i] * cos25
            let x: Double = u + 10
            let y: Double = v * cos35 - 5
            let z: Double = 180 + v * sin35
            let px: Double = Double(cardPhotoWidth) / 2.0 + cardFocal * x / z
            let py: Double = Double(cardPhotoHeight) / 2.0 + cardFocal * y / z
            corners.append(CGPoint(x: px, y: py))
        }
        return Quad.fromCorners(corners)
    }

    /// The card shot: each pixel's center mapped onto the card (856 × 540 units), blue with a yellow band
    /// and a grey photo box, on the table elsewhere.
    static func cardPhoto() -> RgbaImage? {
        guard let toQuad = Homography.rectToQuad(width: 856, height: 540, quad: cardQuad()),
              let toCard = toQuad.inverse() else { return nil }
        let w: Int = cardPhotoWidth
        let h: Int = cardPhotoHeight
        var pixels: [UInt8] = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let c: CGPoint = toCard.map(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5))
                let cx: Double = Double(c.x)
                let cy: Double = Double(c.y)
                var r: Int = Int(table.r)
                var g: Int = Int(table.g)
                var b: Int = Int(table.b)
                if cx >= 0 && cx < 856 && cy >= 0 && cy < 540 {
                    r = 40
                    g = 90
                    b = 160
                    if cy >= 60 && cy < 140 {
                        r = 200
                        g = 170
                        b = 60
                    } else if cx >= 60 && cx < 260 && cy >= 200 && cy < 460 {
                        r = 120
                        g = 100
                        b = 90
                    }
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

    /// The smallest rectangle holding every pixel of `page` that is not white (a channel below 250):
    /// x0, y0, x1, y1; nil for a white page.
    static func printed(_ page: RgbaImage) -> [Int]? {
        var x0: Int = Int.max
        var y0: Int = Int.max
        var x1: Int = -1
        var y1: Int = -1
        for y in 0..<page.height {
            for x in 0..<page.width {
                let p: Int = (y * page.width + x) * 4
                if page.pixels[p] >= 250 && page.pixels[p + 1] >= 250 && page.pixels[p + 2] >= 250 { continue }
                x0 = min(x0, x)
                y0 = min(y0, y)
                x1 = max(x1, x + 1)
                y1 = max(y1, y + 1)
            }
        }
        if x1 < 0 { return nil }
        return [x0, y0, x1, y1]
    }
}

/// Text recognition that can run, reading nothing.
private struct ReadingScorer: OrientationScorer {
    var isAvailable: Bool { true }

    func score(_ image: RgbaImage) throws -> OrientationScore {
        OrientationScore.none
    }
}

private func taskSettings(_ task: ScanTask) -> ScanSettings {
    TaskCatalog.apply(task, to: ScanSettings())
}

private func stepNames(_ processor: PageProcessor) -> [String] {
    var names: [String] = []
    for step in processor.prepare + processor.steps {
        names.append(step.name)
    }
    return names
}

final class CaptureObjectsTests: XCTestCase {
    func testTheTaskDecidesWhatIsPhotographed() {
        XCTAssertEqual(CaptureObjects.kind(for: taskSettings(.photos)), .photo)
        XCTAssertEqual(CaptureObjects.kind(for: taskSettings(.photoRestore)), .photo)
        XCTAssertEqual(CaptureObjects.kind(for: taskSettings(.receipt)), .receipt)
        XCTAssertEqual(CaptureObjects.kind(for: taskSettings(.idCard)), .idCard)
        let documents: [ScanTask] = [.document, .feeder, .email, .word, .book]
        for task in documents {
            XCTAssertEqual(CaptureObjects.kind(for: taskSettings(task)), .document, "\(task)")
        }
        // Without a task: photos in photo mode, else pages.
        var photoMode = ScanSettings()
        photoMode.intent = .photo
        XCTAssertEqual(CaptureObjects.kind(for: photoMode), .photo)
        XCTAssertEqual(CaptureObjects.kind(for: ScanSettings()), .document)
        XCTAssertTrue(CaptureObjects.findsSeveral(.receipt))
        XCTAssertTrue(CaptureObjects.findsSeveral(.photo))
        XCTAssertFalse(CaptureObjects.findsSeveral(.idCard))
        XCTAssertFalse(CaptureObjects.findsSeveral(.document))
        XCTAssertEqual(CaptureObjects.fallbackDPI, 200)
    }

    func testEachObjectOfAShotIsAPageOfThePhoto() throws {
        let photo: CGImage = try XCTUnwrap(ObjectShots.twoPrints().makeCGImage())
        let when = Date(timeIntervalSince1970: 1_792_600_000)
        // The second outline given the other way round, from its bottom left: named again.
        let b: Quad = ObjectShots.printB
        let reversed = Quad(topLeft: b.bottomLeft, topRight: b.bottomRight, bottomRight: b.topRight, bottomLeft: b.topLeft)
        let pages: [ScannedPage] = CaptureObjects.pages(photo, quads: [ObjectShots.printA, reversed], kind: .photo,
                                                        focalLength: 750, createdAt: when)
        XCTAssertEqual(pages.count, 2)
        guard pages.count == 2 else { return }
        XCTAssertNotEqual(pages[0].id, pages[1].id)
        for page in pages {
            XCTAssertTrue(page.image === photo)
            XCTAssertEqual(page.dpi, CaptureScale.nominalDPI)
            XCTAssertEqual(page.colorMode, .color)
            XCTAssertEqual(page.source, .photo)
            XCTAssertEqual(page.createdAt, when)
            XCTAssertEqual(page.capture?.sourceWidth, 900)
            XCTAssertEqual(page.capture?.sourceHeight, 600)
            XCTAssertEqual(page.capture?.kind, .photo)
            XCTAssertEqual(page.capture?.focalLength, 750)
            XCTAssertNil(page.capture?.scale)
            XCTAssertNil(page.geometry)
            XCTAssertFalse(CaptureObjects.isCutOut(page))
        }
        XCTAssertEqual(pages[0].capture?.quad, ObjectShots.printA)
        XCTAssertEqual(pages[1].capture?.quad, ObjectShots.printB)
        XCTAssertTrue(CaptureObjects.pages(photo, quads: [], kind: .receipt).isEmpty)
    }

    func testAShotWithNothingFoundComesInWhole() throws {
        let photo: CGImage = try XCTUnwrap(ObjectShots.twoPrints().makeCGImage())
        let page: ScannedPage = CaptureObjects.fallbackPage(photo)
        XCTAssertTrue(page.image === photo)
        XCTAssertEqual(page.dpi, CaptureObjects.fallbackDPI)
        XCTAssertEqual(page.source, .photo)
        XCTAssertNil(page.capture)
        XCTAssertFalse(CaptureObjects.isCutOut(page))
        // Nothing cuts it: the clean-up leaves its pixels as they are.
        let processed: ScannedPage = try XCTUnwrap(try PageProcessor.forCapture(taskSettings(.photos)).process([page]).pages.first)
        XCTAssertTrue(processed.image === photo)
        XCTAssertNil(processed.geometry)
    }

    func testTheRegionAroundAnOutlineIsItsBoundingBox() {
        let quad = Quad(topLeft: CGPoint(x: 10, y: 30), topRight: CGPoint(x: 110, y: 20),
                        bottomRight: CGPoint(x: 130, y: 90), bottomLeft: CGPoint(x: 5, y: 80))
        let region: DetectedPhotoRegion = CaptureObjects.region(around: quad)
        XCTAssertEqual(region.center, CGPoint(x: 67.5, y: 55))
        XCTAssertEqual(region.size, CGSize(width: 125, height: 70))
        XCTAssertEqual(region.angleDegrees, 0)
    }

    func testACardsNoteSaysWhenItIsNotAtRealSizeThenTheGlare() {
        XCTAssertNil(CaptureObjects.cardNote(realSize: true, glare: false))
        XCTAssertEqual(CaptureObjects.cardNote(realSize: true, glare: true), "Tilt to avoid glare")
        XCTAssertEqual(CaptureObjects.cardNote(realSize: false, glare: false),
                       "This does not look like the shape of an ID card, so it is not at real size. Fix the crop, or take it again.")
        XCTAssertEqual(CaptureObjects.cardNote(realSize: false, glare: true),
                       CaptureObjects.cardNotRealSizeNote + " " + GlareDetector.hint)
    }

    func testForCaptureReadsNothingOnObjectsOutsideTheQueue() throws {
        let scorer = ReadingScorer()
        // Pages for the queue, as before: the photo import's steps, with the text read to turn them upright.
        var document: ScanSettings = taskSettings(.document)
        document.document.autoRotate = true
        XCTAssertEqual(stepNames(PageProcessor.forCapture(document, scorer: scorer)),
                       ["perspective", "enhance", "blank", "separator", "orientation"])
        // Photos, receipts and the ID card: cut out and cleaned up, then only their adjustments.
        let objects: [ScanTask] = [.photos, .idCard]
        for task in objects {
            var s: ScanSettings = taskSettings(task)
            s.document.autoRotate = true
            XCTAssertEqual(stepNames(PageProcessor.forCapture(s, scorer: scorer)), ["perspective", "enhance"], "\(task)")
        }
        XCTAssertEqual(stepNames(PageProcessor.forCapture(taskSettings(.photoRestore), scorer: scorer)),
                       ["perspective", "enhance", "adjust"])
        XCTAssertEqual(stepNames(PageProcessor.forCapture(taskSettings(.receipt), scorer: scorer)),
                       ["perspective", "enhance", "adjust"])
        let photos: EnhanceStep = try XCTUnwrap(PageProcessor.forCapture(taskSettings(.photos)).prepare[1] as? EnhanceStep)
        XCTAssertEqual(photos.mode, .photo)
        let receipts: EnhanceStep = try XCTUnwrap(PageProcessor.forCapture(taskSettings(.receipt)).prepare[1] as? EnhanceStep)
        XCTAssertEqual(receipts.mode, .gray)
    }

    func testTwoPrintsInOneShotAreCutOutAtTheirSize() throws {
        let photo: CGImage = try XCTUnwrap(ObjectShots.twoPrints().makeCGImage())
        let pages: [ScannedPage] = CaptureObjects.pages(photo, quads: [ObjectShots.printA, ObjectShots.printB], kind: .photo)
        let cut: [ScannedPage] = try PageProcessor.forCapture(taskSettings(.photos)).process(pages).pages
        XCTAssertEqual(cut.count, 2)
        guard cut.count == 2 else { return }
        for page in cut {
            XCTAssertTrue(CaptureObjects.isCutOut(page))
            XCTAssertEqual(page.capture?.scale?.basis, .photoSize)
            XCTAssertEqual(page.capture?.scale?.size, "photo4x6in")
            // A photo is cleaned up as a photo, never evened out, and stays in color.
            XCTAssertEqual(page.capture?.enhancement, .photo)
            XCTAssertEqual(page.colorMode, .color)
            XCTAssertTrue(page.alternate?.image === photo)
        }
        // 300 px across 6 in: 50 dpi; 360 px: 60 dpi; each the print's own pixels.
        XCTAssertEqual(cut[0].dpi, 50)
        XCTAssertEqual(cut[0].image.width, 300)
        XCTAssertEqual(cut[0].image.height, 200)
        XCTAssertEqual(cut[1].dpi, 60)
        XCTAssertEqual(cut[1].image.width, 360)
        XCTAssertEqual(cut[1].image.height, 240)
        XCTAssertEqual(cut[0].capture?.quad, ObjectShots.printA)
    }

    func testAdjustedObjectsShareTheShotAsTaken() throws {
        let photo: CGImage = try XCTUnwrap(ObjectShots.twoPrints().makeCGImage())
        let receipts: PageProcessor = PageProcessor.forCapture(taskSettings(.receipt))
        let adjust: AdjustmentStep? = receipts.steps.compactMap { (step: any PageStep) -> AdjustmentStep? in step as? AdjustmentStep }.first
        XCTAssertEqual(adjust?.adjustsAlternate, false)
        // Receipts are made gray; the shot they were cut from stays one, as taken.
        let pages: [ScannedPage] = CaptureObjects.pages(photo, quads: [ObjectShots.printA, ObjectShots.printB], kind: .receipt)
        let cut: [ScannedPage] = try receipts.process(pages).pages
        XCTAssertEqual(cut.count, 2)
        for page in cut {
            XCTAssertTrue(CaptureObjects.isCutOut(page))
            XCTAssertEqual(page.colorMode, .grayscale)
            XCTAssertTrue(page.alternate?.image === photo)
        }
        // A page for the queue has its photo adjusted with it, so either can be shown.
        var document: ScanSettings = taskSettings(.document)
        document.colorMode = .grayscale
        let queued: AdjustmentStep? = PageProcessor.forCapture(document).steps.compactMap { (step: any PageStep) -> AdjustmentStep? in
            step as? AdjustmentStep
        }.first
        XCTAssertEqual(queued?.adjustsAlternate, true)
    }

    func testTheCameraIdCardComesOutAtItsRealSizeOnThePage() throws {
        let rgba: RgbaImage = try XCTUnwrap(ObjectShots.cardPhoto())
        let photo: CGImage = try XCTUnwrap(rgba.makeCGImage())
        let quad: Quad = ObjectShots.cardQuad()
        let settings: ScanSettings = taskSettings(.idCard)
        let pages: [ScannedPage] = CaptureObjects.pages(photo, quads: [quad], kind: .idCard, focalLength: ObjectShots.cardFocal)
        let cut: ScannedPage = try XCTUnwrap(try PageProcessor.forCapture(settings).process(pages).pages.first)
        XCTAssertTrue(CaptureObjects.isCutOut(cut))
        let scale: CaptureScaleResult = try XCTUnwrap(cut.capture?.scale)
        XCTAssertEqual(scale.size, "idCard")
        XCTAssertTrue(scale.isRealSize)
        XCTAssertEqual(cut.capture?.enhancement, .photo)
        XCTAssertEqual(cut.image.width, scale.pixelWidth)
        XCTAssertEqual(cut.image.height, scale.pixelHeight)

        // Composed on A4 at the side's resolution, as the review saves it: 85.60 × 53.98 mm within 0.5 mm.
        let paper: CGSize = try XCTUnwrap(PaperSizes.inches(.a4))
        let pageDPI: Int = IdCardComposer.pageDPI(cut.dpi)
        let sideImage: RgbaImage = try XCTUnwrap(RgbaImage(cgImage: cut.image))
        let side = IdCardSide(image: sideImage, dpi: cut.dpi)
        XCTAssertFalse(IdCardLayout.place(front: side.inches, back: nil, paper: paper).scaledToFit)
        let composed: RgbaImage = IdCardComposer.compose(front: side, back: nil, dpi: pageDPI, paperInches: paper)
        let printed: [Int] = try XCTUnwrap(ObjectShots.printed(composed))
        let widthMm: Double = Double(printed[2] - printed[0]) * 25.4 / Double(pageDPI)
        let heightMm: Double = Double(printed[3] - printed[1]) * 25.4 / Double(pageDPI)
        XCTAssertEqual(max(widthMm, heightMm), 85.60, accuracy: 0.5)
        XCTAssertEqual(min(widthMm, heightMm), 53.98, accuracy: 0.5)
        // No glare on this card.
        XCTAssertFalse(GlareDetector.hasGlare(rgba, region: quad))
    }

    func testReceiptsOnAWhiteTableAreFoundInTheWholeShotWhenNoOutlineWas() throws {
        // Thermal paper three levels darker than the white table: the shot at 200 dpi (the bed doubled).
        let left = TestPages.Placed(sheet: TestPages.receipt(300, 800, paper: 237, ink: 153, lines: 40, seed: 0xC0FF_EE01),
                                    centerX: 220, centerY: 585, turn: TestPages.plus3)
        let right = TestPages.Placed(sheet: TestPages.receipt(300, 800, paper: 237, ink: 153, lines: 40, seed: 0xC0FF_EE02),
                                     centerX: 630, centerY: 585, turn: TestPages.minus3)
        let bed: GrayImage = TestPages.receiptBed(backdrop: 245, seed: 0xBED0_0001, [left, right])
        let photo: CGImage = try XCTUnwrap(TestPages.enlarged(bed, 2).makeCGImage())
        let page: ScannedPage = CaptureObjects.fallbackPage(photo)
        let processed: ScannedPage = try XCTUnwrap(try PageProcessor.forCapture(taskSettings(.receipt)).process([page]).pages.first)
        XCTAssertEqual(processed.colorMode, .grayscale)
        let image: RgbaImage = try XCTUnwrap(RgbaImage(cgImage: processed.image))
        let regions: [DetectedPhotoRegion] = ReceiptDetector.detectRegions(in: image, dpi: processed.dpi)
        XCTAssertEqual(regions.count, 2)
        guard regions.count == 2 else { return }
        XCTAssertEqual(Double(regions[0].center.x), 440, accuracy: 20)
        XCTAssertEqual(Double(regions[1].center.x), 1260, accuracy: 20)
        for region in regions {
            XCTAssertEqual(Double(region.center.y), 1170, accuracy: 20)
            let shortSide: Double = Double(min(region.size.width, region.size.height))
            XCTAssertGreaterThanOrEqual(shortSide, 560)
            XCTAssertLessThanOrEqual(shortSide, 640)
        }
    }

    func testPhotosOnAPlainTableAreFoundInTheWholeShotWhenNoOutlineWas() throws {
        // The photos UI test's fixture (scripts/make_ios_ui_fixture.py photos) has these very pixels.
        XCTAssertEqual(GlareCards.checksum(ObjectShots.printsOnTable()), 0xE0C9_00E1)
        // The flatbed's search of the whole shot at the fallback resolution, as the Photos task runs it.
        let photo: CGImage = try XCTUnwrap(ObjectShots.printsOnTable().makeCGImage())
        let page: ScannedPage = CaptureObjects.fallbackPage(photo)
        let processed: ScannedPage = try XCTUnwrap(try PageProcessor.forCapture(taskSettings(.photos)).process([page]).pages.first)
        var options = PhotoDetectorOptions()
        options.minPhotoSideInches = ScanSettings().photoMinSideInches
        let regions: [DetectedPhotoRegion] = PhotoDetector.detectRegions(in: processed.image, dpi: processed.dpi, options: options)
        XCTAssertEqual(regions.count, 2)
        guard regions.count == 2 else { return }
        XCTAssertEqual(Double(regions[0].center.x), 345, accuracy: 6)
        XCTAssertEqual(Double(regions[0].center.y), 300, accuracy: 6)
        XCTAssertEqual(Double(regions[1].center.x), 860, accuracy: 6)
        XCTAssertEqual(Double(regions[1].center.y), 560, accuracy: 6)
        XCTAssertEqual(Double(max(regions[0].size.width, regions[0].size.height)), 448, accuracy: 8)
        XCTAssertEqual(Double(max(regions[1].size.width, regions[1].size.height)), 418, accuracy: 8)
    }

    func testThePhotoReviewSaysWhatItFoundAndSaves() {
        XCTAssertEqual(PhotoReview.title(3), "Found 3 photos")
        XCTAssertEqual(PhotoReview.title(1), "Found 1 photo")
        XCTAssertEqual(PhotoReview.saveTitle(2), "Save 2 photos")
        XCTAssertEqual(PhotoReview.saveTitle(1), "Save 1 photo")
    }
}
