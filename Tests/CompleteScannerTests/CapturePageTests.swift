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
        let cut = PerspectiveStep().apply(captured(image(halfPixels), facts()))
        let quad = sheetQuad.scaled(0.5, 0.5)
        XCTAssertEqual(cut.geometry?.quad, quad)
        XCTAssertEqual(cut.dpi, 16) // 198 px over 11.6929 in
        let expected = try XCTUnwrap(PerspectiveWarp.warp(halfPixels, quad: quad, width: cut.image.width,
                                                          height: cut.image.height))
        XCTAssertEqual(pixels(cut).pixels, expected.pixels)
        // The facts keep the corners as taken.
        XCTAssertEqual(cut.capture?.quad, sheetQuad)
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
        XCTAssertEqual(PageProcessor.forCapture(s).steps.map(\.name), ["perspective", "blank", "separator"])
        s.colorMode = .grayscale
        let processor = PageProcessor.forCapture(s)
        XCTAssertEqual(processor.steps.map(\.name), ["perspective", "blank", "separator", "adjust"])
        let photo = image(WarpFixtures.photo(640, 480))
        let processed = try XCTUnwrap(try processor.process([captured(photo, facts())]).pages.first)
        XCTAssertEqual(processed.geometry?.basis, .perspective)
        XCTAssertEqual(processed.dpi, 33)
        XCTAssertNotNil(processed.blank)
        XCTAssertEqual(processed.colorMode, .grayscale)
        XCTAssertNotNil(processed.capture?.scale)
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
