import CoreGraphics
import Foundation
import XCTest
@testable import CompleteScannerKit

// Twin of windows/CompleteScanner.Core.Tests/CapturePageTests.cs: camera pages in the clean-up stage,
// their capture facts kept by every rebuild, and the geometry of perspective pages. (The C# rebuild
// list also turns the page with `RotatedClockwise`, which the Mac keeps on `AppState`.)

/// A sheet photographed square on: an A4-shaped outline (280 × 396 px) in a 640 × 480 photo.
private let sheetQuad = Quad(topLeft: CGPoint(x: 100, y: 40), topRight: CGPoint(x: 380, y: 40),
                             bottomRight: CGPoint(x: 380, y: 436), bottomLeft: CGPoint(x: 100, y: 436))

private func image(_ pixels: RgbaImage) -> CGImage {
    pixels.makeCGImage()!
}

private func pixels(_ page: ScannedPage) -> RgbaImage {
    RgbaImage(cgImage: page.image)!
}

private func facts() -> CaptureFacts {
    CaptureFacts(quad: sheetQuad, sourceWidth: 640, sourceHeight: 480, kind: .document, focalLength: 500)
}

private func captured(_ photo: CGImage, _ capture: CaptureFacts) -> ScannedPage {
    ScannedPage(image: photo, dpi: 72, colorMode: .color).withCapture(capture)
}

/// A sheet photographed square on, and its outline in the photo (`CameraSheets.squareOnATable`).
struct TablePhoto {
    let photo: RgbaImage
    let quad: Quad
}

/// Sheets as the camera takes them, for the camera's clean-up stage. Twin of C#
/// `CapturePageTests.SquareOnATable`.
enum CameraSheets {
    /// `sheet` photographed square on, on a dark table with `margin` px of table round it.
    static func squareOnATable(_ sheet: RgbaImage, margin: Int = 60) -> TablePhoto {
        let w: Int = sheet.width + 2 * margin
        let h: Int = sheet.height + 2 * margin
        var pixels: [UInt8] = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let i: Int = (y * w + x) * 4
                let sx: Int = x - margin
                let sy: Int = y - margin
                if sx >= 0 && sx < sheet.width && sy >= 0 && sy < sheet.height {
                    let j: Int = (sy * sheet.width + sx) * 4
                    pixels[i] = sheet.pixels[j]
                    pixels[i + 1] = sheet.pixels[j + 1]
                    pixels[i + 2] = sheet.pixels[j + 2]
                } else {
                    pixels[i] = 52
                    pixels[i + 1] = 40
                    pixels[i + 2] = 34
                }
                pixels[i + 3] = 255
            }
        }
        let left: Double = Double(margin)
        let top: Double = Double(margin)
        let right: Double = Double(margin + sheet.width)
        let bottom: Double = Double(margin + sheet.height)
        let quad = Quad(topLeft: CGPoint(x: left, y: top), topRight: CGPoint(x: right, y: top),
                        bottomRight: CGPoint(x: right, y: bottom), bottomLeft: CGPoint(x: left, y: bottom))
        return TablePhoto(photo: RgbaImage(width: w, height: h, pixels: pixels), quad: quad)
    }
}

final class CapturePageTests: XCTestCase {
    func testPerspectiveStepCutsTheSheetOutAtItsRealSize() throws {
        let photoPixels = WarpFixtures.photo(640, 480)
        let photo = image(photoPixels)
        let page = captured(photo, facts()).withSide(.front, sheetIndex: 0)
        let step = PerspectiveStep()
        XCTAssertEqual(step.name, "perspective")
        let cut = step.apply(page)

        let scale = try XCTUnwrap(cut.capture?.scale)
        XCTAssertEqual(scale.basis, .paper)
        XCTAssertEqual(scale.size, "a4")
        XCTAssertEqual(scale.dpi, 33) // 396 px over 11.6929 in
        XCTAssertEqual(cut.dpi, 33)
        XCTAssertEqual(cut.image.width, 273)
        XCTAssertEqual(cut.image.height, 386)
        XCTAssertEqual(scale.pixelWidth, cut.image.width)
        XCTAssertEqual(scale.pixelHeight, cut.image.height)
        let expected = try XCTUnwrap(PerspectiveWarp.warp(photoPixels, quad: sheetQuad, width: 273, height: 386))
        XCTAssertEqual(pixels(cut).pixels, expected.pixels)
        XCTAssertEqual(cut.geometry, PageGeometry(cropped: true, angleDegrees: 0, basis: .perspective, quad: sheetQuad))
        XCTAssertTrue(cut.alternate?.image === photo)
        XCTAssertTrue(cut.canSwapVersions)
        XCTAssertEqual(cut.id, page.id)
        XCTAssertEqual(cut.side, .front)
        XCTAssertEqual(cut.sheetIndex, 0)
        var measured = facts()
        measured.scale = scale
        XCTAssertEqual(cut.capture, measured)
        XCTAssertEqual(PageCorrections.caption(cut), "Corrected from photo")
        XCTAssertEqual(PageCorrections.toggleLabel(cut), "Show as photographed")

        // Done once: a page cut out already, or with a geometry, stays as it is.
        let again = step.apply(cut)
        XCTAssertTrue(again.image === cut.image)
        XCTAssertEqual(again.dpi, cut.dpi)
        let straightened = captured(photo, facts())
            .withGeometry(photo, geometry: PageGeometry(cropped: false, angleDegrees: 1, basis: .textLines))
        XCTAssertEqual(step.apply(straightened).geometry?.basis, .textLines)
        XCTAssertNil(step.apply(straightened).capture?.scale)
        let scanned = ScannedPage(image: photo, dpi: 300, colorMode: .color)
        XCTAssertNil(step.apply(scanned).geometry)
        XCTAssertEqual(step.apply(scanned).dpi, 300)
        var crossed = facts()
        crossed.quad = Quad(topLeft: CGPoint(x: 100, y: 40), topRight: CGPoint(x: 380, y: 436),
                            bottomRight: CGPoint(x: 380, y: 40), bottomLeft: CGPoint(x: 100, y: 436))
        let bowTie = step.apply(captured(photo, crossed))
        XCTAssertNil(bowTie.geometry)
        XCTAssertTrue(bowTie.image === photo)
    }

    func testPerspectiveStepScalesTheCornersToASmallerPhotoInMemory() throws {
        let halfPixels = WarpFixtures.photo(320, 240)
        let half: CGImage = image(halfPixels)
        let cut = PerspectiveStep().apply(captured(half, facts()))
        let quad = sheetQuad.scaled(0.5, 0.5)
        XCTAssertEqual(cut.geometry?.quad, quad)
        XCTAssertEqual(cut.dpi, 16) // 198 px over 11.6929 in
        let expected = try XCTUnwrap(PerspectiveWarp.warp(halfPixels, quad: quad, width: cut.image.width,
                                                          height: cut.image.height))
        XCTAssertEqual(pixels(cut).pixels, expected.pixels)
        // The facts follow the photo kept as the other version: its corners, its size, its focal length.
        XCTAssertTrue(cut.alternate?.image === half)
        let kept: CaptureFacts = try XCTUnwrap(cut.capture)
        XCTAssertEqual(kept.quad, quad)
        XCTAssertEqual(kept.sourceWidth, 320)
        XCTAssertEqual(kept.sourceHeight, 240)
        XCTAssertEqual(kept.focalLength, 250)
        XCTAssertEqual(cut.geometry?.quad, kept.quad)
        XCTAssertEqual(kept.scale?.dpi, 16)
    }

    func testPerspectiveStepLeavesAPhotoTurnedWithoutItsFactsAlone() {
        let turnedPixels: RgbaImage = PhotoImport.oriented(WarpFixtures.photo(640, 480),
                                                          orientation: PhotoOrientation(quarterTurns: 1, mirrored: false))
        XCTAssertEqual(turnedPixels.width, 480)
        XCTAssertEqual(turnedPixels.height, 640)
        let turned: CGImage = image(turnedPixels)
        let page: ScannedPage = captured(turned, facts())
        let result: ScannedPage = PerspectiveStep().apply(page)
        XCTAssertTrue(result.image === turned)
        XCTAssertNil(result.geometry)
        XCTAssertEqual(result.capture, facts())
        XCTAssertEqual(result.dpi, 72)
    }

    func testPerspectiveStepCutsAPhotoTurnedWithItsFacts() throws {
        let quarter = PhotoOrientation(quarterTurns: 1, mirrored: false)
        let turned: CGImage = image(PhotoImport.oriented(WarpFixtures.photo(640, 480), orientation: quarter))
        let turnedFacts: CaptureFacts = facts().oriented(quarter)
        let cut: ScannedPage = PerspectiveStep().apply(captured(turned, turnedFacts))
        let scale: CaptureScaleResult = try XCTUnwrap(cut.capture?.scale)
        XCTAssertEqual(scale.size, "a4")
        XCTAssertEqual(cut.dpi, 33)
        // The sheet lies on its side in the turned photo: the same page, turned.
        XCTAssertEqual(cut.image.width, 386)
        XCTAssertEqual(cut.image.height, 273)
        var measured: CaptureFacts = turnedFacts
        measured.scale = scale
        XCTAssertEqual(cut.capture, measured)
        XCTAssertEqual(cut.geometry?.quad, turnedFacts.quad)
    }

    func testCaptureFactsTurnWithThePhoto() {
        // Four marked pixels at the corners of an outline in a 64 × 48 photo: for every orientation tag,
        // the turned facts' corners land on the same marks in the photo turned the same way.
        let w: Int = 64
        let h: Int = 48
        var photo: RgbaImage = RgbaImage.filled(width: w, height: h, r: 0, g: 0, b: 0)
        let markXs: [Int] = [10, 49, 52, 7]
        let markYs: [Int] = [5, 8, 40, 37]
        let markValues: [UInt8] = [50, 100, 150, 200]
        for index in 0..<4 {
            photo.pixels[(markYs[index] * w + markXs[index]) * 4] = markValues[index]
        }
        let quad = Quad(topLeft: CGPoint(x: 10.5, y: 5.5), topRight: CGPoint(x: 49.5, y: 8.5),
                        bottomRight: CGPoint(x: 52.5, y: 40.5), bottomLeft: CGPoint(x: 7.5, y: 37.5))
        let capture = CaptureFacts(quad: quad, sourceWidth: w, sourceHeight: h, kind: .receipt, focalLength: 70)
        for tag in 1...8 {
            let orientation: PhotoOrientation = PhotoOrientation.fromExif(tag)
            let turnedPhoto: RgbaImage = PhotoImport.oriented(photo, orientation: orientation)
            let turned: CaptureFacts = capture.oriented(orientation)
            XCTAssertEqual(turned.sourceWidth, turnedPhoto.width, "tag \(tag)")
            XCTAssertEqual(turned.sourceHeight, turnedPhoto.height, "tag \(tag)")
            XCTAssertTrue(turned.quad.isConvex, "tag \(tag)")
            XCTAssertEqual(turned.kind, .receipt)
            XCTAssertEqual(turned.focalLength, 70)
            XCTAssertNil(turned.scale)
            var found: [UInt8] = []
            for corner in turned.quad.corners {
                let px: Int = Int(Double(corner.x).rounded(.down))
                let py: Int = Int(Double(corner.y).rounded(.down))
                found.append(turnedPhoto.pixels[(py * turnedPhoto.width + px) * 4])
            }
            found.sort()
            XCTAssertEqual(found, markValues, "tag \(tag)")
        }
        // A quarter turn clockwise: (x, y) to (48 − y, x), named again from the top edge.
        let quarter = PhotoOrientation(quarterTurns: 1, mirrored: false)
        XCTAssertEqual(capture.oriented(quarter).quad,
                       Quad(topLeft: CGPoint(x: 10.5, y: 7.5), topRight: CGPoint(x: 42.5, y: 10.5),
                            bottomRight: CGPoint(x: 39.5, y: 49.5), bottomLeft: CGPoint(x: 7.5, y: 52.5)))
        // Turned all the way round, and upright, the facts are as they were.
        XCTAssertEqual(capture.oriented(quarter).oriented(PhotoOrientation(quarterTurns: 3, mirrored: false)), capture)
        let flipped = PhotoOrientation(quarterTurns: 2, mirrored: true)
        XCTAssertEqual(capture.oriented(flipped).oriented(flipped), capture)
        XCTAssertEqual(capture.oriented(.upright), capture)
    }

    func testCaptureFactsScaleWithThePhoto() {
        let capture: CaptureFacts = facts()
        let half: CaptureFacts = capture.scaled(toWidth: 320, height: 240)
        XCTAssertEqual(half.quad, sheetQuad.scaled(0.5, 0.5))
        XCTAssertEqual(half.sourceWidth, 320)
        XCTAssertEqual(half.sourceHeight, 240)
        XCTAssertEqual(half.focalLength, 250)
        XCTAssertEqual(half.kind, capture.kind)
        // Another shape: each way by its own scale, the focal length by their geometric mean.
        let wide: CaptureFacts = capture.scaled(toWidth: 1280, height: 240)
        XCTAssertEqual(wide.quad, sheetQuad.scaled(2, 0.5))
        XCTAssertEqual(wide.focalLength, 500)
        // No focal length is made up; the same size and no size change nothing.
        var unknown: CaptureFacts = capture
        unknown.focalLength = nil
        XCTAssertNil(unknown.scaled(toWidth: 320, height: 240).focalLength)
        XCTAssertEqual(capture.scaled(toWidth: 640, height: 480), capture)
        XCTAssertEqual(capture.scaled(toWidth: 0, height: 480), capture)
        // The photos the facts describe: the same shape, to within a resize's rounding.
        XCTAssertTrue(capture.describesPhoto(width: 640, height: 480))
        XCTAssertTrue(capture.describesPhoto(width: 320, height: 240))
        XCTAssertTrue(capture.describesPhoto(width: 321, height: 240))
        XCTAssertTrue(capture.describesPhoto(width: 4000, height: 3000))
        XCTAssertFalse(capture.describesPhoto(width: 480, height: 640))
        XCTAssertFalse(capture.describesPhoto(width: 640, height: 400))
        XCTAssertFalse(capture.describesPhoto(width: 0, height: 0))
        XCTAssertFalse(CaptureFacts(quad: sheetQuad, sourceWidth: 0, sourceHeight: 480).describesPhoto(width: 640, height: 480))
        // A nearly square photo turned a quarter is not taken for the same photo either.
        XCTAssertFalse(CaptureFacts(quad: sheetQuad, sourceWidth: 1000, sourceHeight: 999).describesPhoto(width: 999, height: 1000))
    }

    func testGeometryStepLeavesCameraAndPhotoPagesAlone() throws {
        let photo = image(WarpFixtures.photo(640, 480))
        let step = GeometryStep(crop: true, straighten: true)
        let page = captured(photo, facts())
        let kept = step.apply(page)
        XCTAssertNil(kept.geometry)
        XCTAssertTrue(kept.image === photo)
        let cut = PerspectiveStep().apply(page)
        XCTAssertTrue(step.apply(cut).image === cut.image)
        let wood = PhotoScenes.woodScene()
        let imported = try XCTUnwrap(PhotoImport.correctedPage(
            wood, corners: PhotoScenes.woodMap.corners(PhotoScenes.pageWidth, PhotoScenes.pageHeight)))
        XCTAssertTrue(step.apply(imported).image === imported.image)
    }

    func testForCaptureCutsThePageOutFirst() throws {
        var s = ScanSettings()
        s.document.autoCrop = true
        XCTAssertEqual(PageProcessor.forCapture(s).prepare.map(\.name), ["perspective", "enhance"])
        XCTAssertEqual(PageProcessor.forCapture(s).steps.map(\.name), ["blank", "separator"])
        s.colorMode = .grayscale
        let processor = PageProcessor.forCapture(s)
        XCTAssertEqual(processor.steps.map(\.name), ["blank", "separator", "adjust"])
        let enhance: EnhanceStep = try XCTUnwrap(processor.prepare[1] as? EnhanceStep)
        XCTAssertEqual(enhance.mode, .gray)
        let photo = image(WarpFixtures.photo(640, 480))
        let result = try processor.process([captured(photo, facts())])
        let processed = try XCTUnwrap(result.pages.first)
        // The preview and the history show the page cut out, not the photo around it.
        let shown = try XCTUnwrap(result.arranged.first)
        XCTAssertEqual(shown.geometry?.basis, .perspective)
        XCTAssertEqual(shown.image.width, processed.image.width)
        XCTAssertEqual(shown.image.height, processed.image.height)
        XCTAssertEqual(processed.geometry?.basis, .perspective)
        XCTAssertEqual(processed.dpi, 33)
        XCTAssertNotNil(processed.blank)
        XCTAssertEqual(processed.colorMode, .grayscale)
        XCTAssertNotNil(processed.capture?.scale)
        XCTAssertEqual(processed.capture?.enhancement, .gray)
    }

    func testForCaptureCutsAWholeSpreadOutOfItsPhotoThenSplitsItAtItsSpine() throws {
        var s = TaskCatalog.apply(.book, to: ScanSettings())
        // Page by page, the phone's default: each shot is one page, as any camera page.
        XCTAssertFalse(PageProcessor.splitsCameraSpreads(s))
        let single = PageProcessor.forCapture(s)
        XCTAssertNil(single.book)
        XCTAssertEqual(single.prepare.map(\.name), ["perspective", "enhance"])
        XCTAssertEqual(single.steps.map(\.name), ["blank", "separator"])

        s.taskOptions.cameraSpreads = true
        XCTAssertTrue(PageProcessor.splitsCameraSpreads(s))
        let processor = PageProcessor.forCapture(s)
        XCTAssertEqual(processor.prepare.map(\.name), ["perspective", "enhance"])
        XCTAssertEqual((processor.prepare.first as? PerspectiveStep)?.spread, true)
        XCTAssertEqual((single.prepare.first as? PerspectiveStep)?.spread, false)
        XCTAssertEqual(processor.steps.map(\.name), ["blank", "spineShadow", "separator"])
        XCTAssertEqual(processor.book, BookSplitOptions.of(s))
        // Not for another task, nor for a scan.
        var document = TaskCatalog.apply(.document, to: ScanSettings())
        document.taskOptions.cameraSpreads = true
        XCTAssertFalse(PageProcessor.splitsCameraSpreads(document))
        XCTAssertTrue(PageProcessor.forScan(s).prepare.isEmpty)

        // The open book as the camera takes it: TestPages.shadowSpread (1100 × 850, its spine at x = 572).
        let table: TablePhoto = CameraSheets.squareOnATable(TestPages.shadowSpread().toRgba())
        var page = captured(image(table.photo),
                            CaptureFacts(quad: table.quad, sourceWidth: table.photo.width, sourceHeight: table.photo.height))
        page.source = .photo
        let result = try processor.process([page])
        // The spread as cut out of the photo is what is kept to split it again by hand: at its own pixels,
        // matched against no sheet.
        XCTAssertEqual(result.spreads.count, 1)
        let spread = try XCTUnwrap(result.spreads.first)
        XCTAssertEqual(spread.id, page.id)
        XCTAssertEqual(spread.geometry?.basis, .perspective)
        XCTAssertEqual(spread.capture?.scale?.basis, .nominal)
        XCTAssertEqual(spread.image.width, 1100)
        XCTAssertEqual(spread.image.height, 850)
        XCTAssertEqual(spread.dpi, CaptureScale.nominalDPI)
        XCTAssertEqual(result.pages.count, 2)
        XCTAssertTrue(result.pages.allSatisfy { $0.spreadID == page.id })
        XCTAssertEqual(result.pages.map { $0.spread?.isLeft }, [true, false])
        // Cut at the spine: the left page ends near x = 572.
        XCTAssertEqual(result.pages[0].spread?.gutter?.axis, .vertical)
        XCTAssertGreaterThanOrEqual(result.pages[0].image.width, 540)
        XCTAssertLessThanOrEqual(result.pages[0].image.width, 600)
        XCTAssertTrue(result.pages.allSatisfy { $0.dpi == CaptureScale.nominalDPI })
        // Each page keeps where it came from and what the camera recorded.
        XCTAssertTrue(result.pages.allSatisfy { $0.source == .photo })
        XCTAssertTrue(result.pages.allSatisfy { $0.capture == spread.capture })

        // A book read from right to left: its right page comes first.
        s.taskOptions.bookRightToLeft = true
        let rtl = try PageProcessor.forCapture(s).process([page]).pages
        XCTAssertEqual(rtl.map { $0.spread?.isLeft }, [false, true])
    }

    func testForCaptureAWholeSpreadKeepsItsPixelsNotASingleSheetsSize() throws {
        var s = TaskCatalog.apply(.book, to: ScanSettings())
        s.taskOptions.cameraSpreads = true
        // A Letter book's 17 × 11 in spread has nearly an ID card's shape; an A4 book's spread is A3, A4's shape.
        let cases: [(width: Int, height: Int, lookalike: PaperSize)] = [(1700, 1100, .idCard), (1414, 1000, .a4)]
        for (width, height, lookalike) in cases {
            let sheet: RgbaImage = TestPages.spread(width / 2, innerMargin: 20, outerMargin: 80, shadowDepth: 250,
                                                    shadowRadius: 17, seed: 0xB00C_0011, width: width, height: height).toRgba()
            let table: TablePhoto = CameraSheets.squareOnATable(sheet)
            // As one page, the spread would snap to a sheet it only looks like.
            XCTAssertEqual(CaptureScale.match(Double(width) / Double(height), candidates: CaptureScale.papers)?.paper, lookalike)

            let page = captured(image(table.photo),
                                CaptureFacts(quad: table.quad, sourceWidth: table.photo.width, sourceHeight: table.photo.height))
            let result = try PageProcessor.forCapture(s).process([page])
            let spread = try XCTUnwrap(result.spreads.first)
            XCTAssertEqual(spread.capture?.scale?.basis, .nominal)
            XCTAssertEqual(spread.image.width, width)
            XCTAssertEqual(spread.image.height, height)
            XCTAssertEqual(spread.dpi, CaptureScale.nominalDPI)
            XCTAssertEqual(result.pages.count, 2)
            for half in result.pages {
                XCTAssertEqual(half.image.height, height)
                XCTAssertGreaterThanOrEqual(half.image.width, width / 2 - 60)
                XCTAssertLessThanOrEqual(half.image.width, width / 2 + 60)
                XCTAssertEqual(half.dpi, CaptureScale.nominalDPI)
            }
        }
    }

    func testForCaptureThePagesOfASpreadMadeGrayStayGrayInAColorTask() throws {
        var s = TaskCatalog.apply(.book, to: ScanSettings())
        s.taskOptions.cameraSpreads = true
        s.colorMode = .color
        s.adjustments.brightness = 0.1
        let processor = PageProcessor.forCapture(s)
        XCTAssertEqual(processor.steps.last?.name, "adjust")
        let table: TablePhoto = CameraSheets.squareOnATable(TestPages.shadowSpread().toRgba())
        let page = captured(image(table.photo),
                            CaptureFacts(quad: table.quad, sourceWidth: table.photo.width, sourceHeight: table.photo.height))
        let result = try processor.process([page])
        XCTAssertEqual(result.spreads.first?.capture?.enhancement, .gray)
        XCTAssertEqual(result.pages.count, 2)
        for half in result.pages {
            XCTAssertEqual(half.capture?.enhancement, .gray)
            XCTAssertEqual(half.colorMode, .grayscale)
        }
    }

    func testAdjustmentsKeepACameraPageWithoutColorGrayInAColorTask() throws {
        var s = ScanSettings()
        s.adjustments.brightness = 0.1
        let processor = PageProcessor.forCapture(s)
        XCTAssertEqual(processor.steps.map(\.name), ["blank", "separator", "adjust"])
        func shot(_ sheet: RgbaImage) -> ScannedPage {
            let photo: RgbaImage = EnhancerPages.onATable(sheet)
            var page: ScannedPage = ScannedPage(image: image(photo), dpi: CaptureScale.nominalDPI, colorMode: .color)
                .withCapture(CaptureFacts(quad: EnhancerPages.tableQuad, sourceWidth: photo.width,
                                          sourceHeight: photo.height))
            page.source = .photo
            return page
        }
        // Black print on white paper: made gray by the clean-up, and still gray after the brightness.
        let plain: ScannedPage = try XCTUnwrap(try processor.process([shot(EnhancerPages.shadowed(stamp: false))]).pages.first)
        XCTAssertEqual(plain.capture?.enhancement, .gray)
        XCTAssertEqual(plain.colorMode, .grayscale)
        XCTAssertTrue(ColorAnalysis.isEffectivelyGray(plain.image))
        // The photo kept as the other version is adjusted in the task's color mode: its warm paper stays warm.
        let alternate: RgbaImage = try XCTUnwrap(RgbaImage(cgImage: try XCTUnwrap(plain.alternate?.image)))
        var warm: Bool = false
        var p: Int = 0
        while p < alternate.width * alternate.height && !warm {
            warm = alternate.pixels[p * 4] != alternate.pixels[p * 4 + 2]
            p += 1
        }
        XCTAssertTrue(warm)
        // With the red stamp: color.
        let stamped: ScannedPage = try XCTUnwrap(try processor.process([shot(EnhancerPages.shadowed())]).pages.first)
        XCTAssertEqual(stamped.capture?.enhancement, .color)
        XCTAssertEqual(stamped.colorMode, .color)
        // The mode the step adjusts a page in.
        let flat: CGImage = image(RgbaImage.filled(width: 8, height: 8, r: 200, g: 200, b: 200))
        var grayFacts: CaptureFacts = facts()
        grayFacts.enhancement = .gray
        var bwFacts: CaptureFacts = facts()
        bwFacts.enhancement = .blackAndWhite
        var colorFacts: CaptureFacts = facts()
        colorFacts.enhancement = .color
        let grayPage: ScannedPage = ScannedPage(image: flat, dpi: 72, colorMode: .grayscale).withCapture(grayFacts)
        let bwPage: ScannedPage = ScannedPage(image: flat, dpi: 72, colorMode: .blackWhite).withCapture(bwFacts)
        let colorPage: ScannedPage = ScannedPage(image: flat, dpi: 72, colorMode: .color).withCapture(colorFacts)
        let scanned = ScannedPage(image: flat, dpi: 72, colorMode: .grayscale)
        let colorStep = AdjustmentStep(adjustments: s.adjustments, colorMode: .color)
        XCTAssertEqual(colorStep.mode(for: grayPage), .grayscale)
        XCTAssertEqual(colorStep.mode(for: bwPage), .blackWhite)
        XCTAssertEqual(colorStep.mode(for: colorPage), .color)
        XCTAssertEqual(colorStep.mode(for: scanned), .color)
        XCTAssertEqual(colorStep.apply(grayPage).colorMode, .grayscale)
        XCTAssertEqual(AdjustmentStep(adjustments: s.adjustments, colorMode: .blackWhite).mode(for: grayPage), .blackWhite)
    }

    func testCaptureFactsSurviveEveryRebuildOfThePage() {
        var capture = facts()
        capture.kind = .receipt
        capture.scale = CaptureScaleResult(basis: .receiptWidth, size: "receipt80mm", dpi: 101, pixelWidth: 318,
                                           pixelHeight: 1591, widthInches: 3.15, heightInches: 15.75)
        let photo = image(WarpFixtures.photo(64, 48))
        let other = image(RgbaImage.filled(width: 3, height: 3, r: 0, g: 0, b: 0))
        let page = ScannedPage(image: photo, dpi: 101, colorMode: .color).withCapture(capture)
        let shadow = SpineShadowResult(edge: .left, depth: 0.2, widthInches: 0.5, maxGain: 1.4, protectedFraction: 0.1)
        let corrected = PageGeometry(cropped: true, angleDegrees: 0, basis: .perspective, quad: sheetQuad)
        let rebuilt: [ScannedPage] = [
            page.withImage(other),
            page.withSide(.front, sheetIndex: 0),
            page.withBlank(nil),
            page.withInclusion(.skip),
            page.withPatch(nil),
            page.withBarcodes([]),
            page.withDocumentBreak(.split),
            page.withDocumentLabel("Receipts"),
            page.withUpright(UprightTurn(quarterTurns: 2)),
            page.turnedUpright(1),
            page.turnedUpright(1).withUprightToggled(),
            page.withAlternate(nil),
            page.withSpread(nil),
            page.withSpineShadow(other, result: shadow),
            page.withGeometry(other, geometry: corrected),
            page.withGeometry(other, geometry: PageGeometry(cropped: true, angleDegrees: 0, basis: .perspective))
                .withVersionsSwapped(photo),
            ScannedPage(image: other, dpi: 300, colorMode: .color).copyMeta(from: page),
        ]
        for rebuiltPage in rebuilt {
            XCTAssertEqual(rebuiltPage.capture, capture)
        }
        XCTAssertNil(ScannedPage(image: photo, dpi: 300, colorMode: .color).capture)
        XCTAssertNil(page.withCapture(nil).capture)
    }

    func testACutPageSwapsToThePhotoAndBackWithItsFacts() throws {
        let photo = image(WarpFixtures.photo(640, 480))
        let cut = PerspectiveStep().apply(captured(photo, facts()))
        let shown = cut.withVersionsSwapped(try XCTUnwrap(cut.alternate?.image))
        XCTAssertTrue(shown.showsOriginal)
        XCTAssertTrue(shown.image === photo)
        XCTAssertEqual(shown.capture, cut.capture)
        XCTAssertEqual(shown.geometry, cut.geometry)
        XCTAssertEqual(PageCorrections.caption(shown), "As photographed")
        XCTAssertEqual(PageCorrections.toggleLabel(shown), "Show corrected")
        let back = shown.withVersionsSwapped(try XCTUnwrap(shown.alternate?.image))
        XCTAssertFalse(back.showsOriginal)
        XCTAssertEqual(pixels(back).pixels, pixels(cut).pixels)
        XCTAssertEqual(back.capture, cut.capture)
        XCTAssertEqual(back.dpi, cut.dpi)
    }

    func testEveryGeometryBasisHasItsWords() {
        // Each basis, as a switch over all of them would: a caption, a swap label, a note.
        for basis in GeometryBasis.allCases {
            let geometry = PageGeometry(cropped: true, angleDegrees: basis == .perspective ? 0 : 2.4, basis: basis)
            let page = ScannedPage(image: image(WarpFixtures.photo(8, 8)), dpi: 100, colorMode: .color)
                .withGeometry(image(WarpFixtures.photo(6, 6)), geometry: geometry)
            XCTAssertFalse(geometry.caption.isEmpty, "\(basis)")
            XCTAssertFalse((PageCorrections.toggleLabel(page) ?? "").isEmpty, "\(basis)")
            XCTAssertFalse(PageCorrections.swapNote(page, number: 1).isEmpty, "\(basis)")
            XCTAssertEqual(basis == .perspective, PageCorrections.caption(page) == PhotoImport.correctedCaption, "\(basis)")
        }
        XCTAssertEqual(GeometryBasis.allCases.count, 3)
        // The quad is part of what a geometry is.
        XCTAssertNotEqual(PageGeometry(cropped: true, angleDegrees: 0, basis: .perspective, quad: sheetQuad),
                          PageGeometry(cropped: true, angleDegrees: 0, basis: .perspective))
        XCTAssertNil(PageGeometry(cropped: true, angleDegrees: 2, basis: .pageEdges).quad)
    }
}
