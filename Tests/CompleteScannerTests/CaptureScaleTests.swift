import CoreGraphics
import Foundation
import XCTest
@testable import CompleteScannerKit

// Twin of windows/LazyScan.Core.Tests/CaptureScaleTests.cs: the same shots, sizes and answers.

/// cos and sin of the angles the shots are taken at, as literals so both platforms use the same numbers.
private let cos35 = 0.8191520442889918, sin35 = 0.573576436351046
private let cos25 = 0.9063077870366499, sin25 = 0.42261826174069944

/// A 12 MP photo (4032 × 3024) from a camera of focal length 3000 px centered on it.
private let photoWidth = 4032, photoHeight = 3024
private let focal = 3000.0

/// A turn or tilt as its cosine and sine.
private struct Turn {
    let cos: Double
    let sin: Double
}

private let straight = Turn(cos: 1, sin: 0)

/// The quad a flat `width` × `height` mm rectangle makes in the photo: turned by `turn` in its own
/// plane, tilted back about the camera's x axis by `tilt`, its center moved by (`offsetX`, `offsetY`)
/// mm at `distance` mm.
private func shot(_ width: Double, _ height: Double, turn: Turn, tilt: Turn, distance: Double,
                  offsetX: Double = 0, offsetY: Double = 0) -> Quad {
    let us: [Double] = [-width / 2, width / 2, width / 2, -width / 2]
    let vs: [Double] = [-height / 2, -height / 2, height / 2, height / 2]
    var corners: [CGPoint] = []
    for i in 0..<4 {
        let u: Double = us[i] * turn.cos - vs[i] * turn.sin
        let v: Double = us[i] * turn.sin + vs[i] * turn.cos
        let x: Double = u + offsetX
        let y: Double = v * tilt.cos + offsetY
        let z: Double = distance + v * tilt.sin
        let px: Double = Double(photoWidth) / 2.0 + focal * x / z
        let py: Double = Double(photoHeight) / 2.0 + focal * y / z
        corners.append(CGPoint(x: px, y: py))
    }
    return Quad.fromCorners(corners)
}

private func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> Quad {
    Quad(topLeft: CGPoint(x: x, y: y), topRight: CGPoint(x: x + w, y: y),
         bottomRight: CGPoint(x: x + w, y: y + h), bottomLeft: CGPoint(x: x, y: y + h))
}

/// floor(x + 0.5), as the scale rounds.
private func rounded(_ x: Double) -> Int {
    Int((x + 0.5).rounded(.down))
}

final class CaptureScaleTests: XCTestCase {
    func testAnIdCardTiltedBy35DegreesSnapsToId1() throws {
        // Turned 25° in its plane and tilted back 35°: the quad tells the camera's focal length.
        let card = shot(85.6, 53.98, turn: Turn(cos: cos25, sin: sin25), tilt: Turn(cos: cos35, sin: sin35),
                        distance: 260, offsetX: 30, offsetY: -20)
        let estimate = CaptureScale.aspect(card, imageWidth: photoWidth, imageHeight: photoHeight)
        let f = try XCTUnwrap(estimate.focalLength)
        XCTAssertEqual(f, focal, accuracy: focal * 0.01)
        XCTAssertEqual(estimate.longOverShort, 1.5858, accuracy: 1.5858 * 0.01)
        for kind in [CaptureKind.idCard, CaptureKind.document] {
            let scale = CaptureScale.measure(card, imageWidth: photoWidth, imageHeight: photoHeight, kind: kind)
            XCTAssertEqual(scale.basis, .paper)
            XCTAssertEqual(scale.size, "idCard")
            XCTAssertEqual(scale.paper, .idCard)
            XCTAssertTrue(scale.isRealSize)
            // Made at its real size: 85.60 × 53.98 mm within 0.5 mm.
            let longMm = Double(max(scale.pixelWidth, scale.pixelHeight)) * 25.4 / Double(scale.dpi)
            let shortMm = Double(min(scale.pixelWidth, scale.pixelHeight)) * 25.4 / Double(scale.dpi)
            XCTAssertEqual(longMm, 85.6, accuracy: 0.5)
            XCTAssertEqual(shortMm, 53.98, accuracy: 0.5)
            XCTAssertTrue((250...400).contains(scale.dpi), "dpi \(scale.dpi)")
        }
    }

    func testACardTiltedAboutItsOwnEdgeNeedsTheFocalLength() throws {
        // Tilted 35° about an axis along its long edges: the quad alone tells no focal length.
        let card = shot(85.6, 53.98, turn: straight, tilt: Turn(cos: cos35, sin: sin35), distance: 260)
        XCTAssertNil(CaptureScale.aspect(card, imageWidth: photoWidth, imageHeight: photoHeight).focalLength)
        XCTAssertEqual(CaptureScale.measure(card, imageWidth: photoWidth, imageHeight: photoHeight, kind: .idCard).basis,
                       .nominal)
        let known = CaptureScale.measure(card, imageWidth: photoWidth, imageHeight: photoHeight, kind: .idCard,
                                         focalLength: focal)
        XCTAssertEqual(known.size, "idCard")
        XCTAssertGreaterThan(known.pixelWidth, known.pixelHeight)
        // The camera's focal length from its EXIF 35 mm equivalent.
        let w = Double(photoWidth), h = Double(photoHeight)
        let focal35 = focal * CaptureScale.fullFrameDiagonalMm / (w * w + h * h).squareRoot()
        let pixels = try XCTUnwrap(CaptureScale.focalLengthPixels(focal35, width: photoWidth, height: photoHeight))
        XCTAssertEqual(pixels, focal, accuracy: 1e-6)
        XCTAssertNil(CaptureScale.focalLengthPixels(0, width: photoWidth, height: photoHeight))
        XCTAssertNil(CaptureScale.focalLengthPixels(26, width: 0, height: photoHeight))
    }

    func testA4SnapsEitherWayRoundAtTheResolutionTheCameraResolved() {
        let portrait = shot(210, 297, turn: straight, tilt: straight, distance: 600)
        let upright = CaptureScale.measure(portrait, imageWidth: photoWidth, imageHeight: photoHeight, kind: .document)
        XCTAssertEqual(upright.basis, .paper)
        XCTAssertEqual(upright.size, "a4")
        // 297 mm at 600 mm and 3000 px: 1485 px over 11.6929 in = 127.0 dpi.
        XCTAssertEqual(upright.dpi, 127)
        XCTAssertEqual(upright.pixelWidth, rounded(8.2677 * 127))
        XCTAssertEqual(upright.pixelHeight, rounded(11.6929 * 127))
        XCTAssertEqual(upright.widthInches, 8.2677)
        XCTAssertEqual(upright.heightInches, 11.6929)

        let landscape = shot(297, 210, turn: straight, tilt: straight, distance: 600)
        let turned = CaptureScale.measure(landscape, imageWidth: photoWidth, imageHeight: photoHeight, kind: .document)
        XCTAssertEqual(turned.size, "a4")
        XCTAssertEqual(turned.pixelWidth, upright.pixelHeight)
        XCTAssertEqual(turned.pixelHeight, upright.pixelWidth)
        XCTAssertEqual(turned.widthInches, 11.6929)

        let letterShot = shot(215.9, 279.4, turn: straight, tilt: Turn(cos: cos35, sin: sin35), distance: 500, offsetY: 40)
        let letter = CaptureScale.measure(letterShot, imageWidth: photoWidth, imageHeight: photoHeight, kind: .document,
                                          focalLength: focal)
        XCTAssertEqual(letter.size, "letter")
    }

    func testNothingIsUpsampledAndCloseUpsAreCapped() {
        // A small A4 far away: its resolution follows its pixels, the page is no larger than seen.
        let far = CaptureScale.measure(rect(100, 100, 200, 283), imageWidth: 1000, imageHeight: 1000, kind: .document)
        XCTAssertEqual(far.size, "a4")
        XCTAssertEqual(far.dpi, 24) // 283 / 11.6929 = 24.2
        XCTAssertTrue(far.pixelHeight <= 283 && far.pixelWidth <= 200)
        // A card filling a 12 MP photo keeps its pixels: 4000 / 3.370 = 1186.9 dpi.
        let card = CaptureScale.measure(rect(16, 12, 4000, 2522), imageWidth: photoWidth, imageHeight: photoHeight,
                                        kind: .idCard)
        XCTAssertEqual(card.size, "idCard")
        XCTAssertEqual(card.dpi, 1186)
        XCTAssertEqual(card.pixelWidth, rounded(3.370 * 1186))
        XCTAssertEqual(card.pixelHeight, rounded(2.125 * 1186))
        XCTAssertTrue(card.pixelWidth <= 4000 && card.pixelHeight <= 2522)
        // Filling a 24 MP photo (5712 × 4284) it would be 1661 dpi: it is made at 1200.
        let capped = CaptureScale.measure(rect(16, 12, 5600, 3531), imageWidth: 5712, imageHeight: 4284, kind: .idCard)
        XCTAssertEqual(capped.size, "idCard")
        XCTAssertEqual(capped.dpi, CaptureScale.maxDPI)
        XCTAssertEqual(capped.dpi, 1200)
        XCTAssertEqual(capped.pixelWidth, rounded(3.370 * 1200))
        XCTAssertEqual(capped.pixelHeight, rounded(2.125 * 1200))
    }

    func testAPageThatMatchesNothingGetsTheNominalResolution() {
        // 3:2 is no paper size: 200 dpi, the page keeps its pixels, its size is made up.
        let odd = rect(50, 50, 900, 600)
        let scale = CaptureScale.measure(odd, imageWidth: 1000, imageHeight: 800, kind: .document)
        XCTAssertEqual(scale.basis, .nominal)
        XCTAssertNil(scale.size)
        XCTAssertNil(scale.paper)
        XCTAssertFalse(scale.isRealSize)
        XCTAssertEqual(scale.dpi, CaptureScale.nominalDPI)
        XCTAssertEqual(scale.pixelWidth, 900)
        XCTAssertEqual(scale.pixelHeight, 600)
        XCTAssertEqual(scale.widthInches, 4.5)
        XCTAssertEqual(scale.heightInches, 3.0)
        // As a photo it is 4 × 6 in.
        let photo = CaptureScale.measure(odd, imageWidth: 1000, imageHeight: 800, kind: .photo)
        XCTAssertEqual(photo.basis, .photoSize)
        XCTAssertEqual(photo.size, "photo4x6in")
        XCTAssertEqual(photo.dpi, 150)
        XCTAssertEqual(photo.pixelWidth, 900)
        XCTAssertEqual(photo.pixelHeight, 600)
        XCTAssertEqual(photo.widthInches, 6.0)
        XCTAssertEqual(photo.heightInches, 4.0)
    }

    func testAReceiptSnapsToItsWidthWhateverItsLength() {
        // 320 × 1600 px: 80 mm wide (3.15 in) at 101 dpi, its length its own.
        let receipt = rect(100, 100, 320, 1600)
        let scale = CaptureScale.measure(receipt, imageWidth: 1000, imageHeight: 2000, kind: .receipt)
        XCTAssertEqual(scale.basis, .receiptWidth)
        XCTAssertEqual(scale.size, "receipt80mm")
        XCTAssertEqual(scale.dpi, 101)
        XCTAssertEqual(scale.pixelWidth, rounded(80 / 25.4 * 101))
        XCTAssertEqual(scale.pixelHeight, rounded(80 / 25.4 * 5 * 101))
        XCTAssertLessThanOrEqual(scale.pixelHeight, 1600)
        XCTAssertEqual(scale.heightInches, 80 / 25.4 * 5, accuracy: 1e-9)
        // A list naming 57 mm first takes it.
        let narrow = CaptureScale.measure(receipt, imageWidth: 1000, imageHeight: 2000,
                                          candidates: [CaptureScale.receiptWidths[1]])
        XCTAssertEqual(narrow.size, "receipt57mm")
        XCTAssertEqual(narrow.dpi, 142) // 320 px over 2.244 in
    }

    func testMatchTakesTheNearestWithinThreePercentThenAFreeLength() {
        let papers = CaptureScale.papers
        XCTAssertEqual(CaptureScale.match(1.4142, candidates: papers)?.id, "a4")
        XCTAssertEqual(CaptureScale.match(1.4142 * 1.029, candidates: papers)?.id, "a4")
        XCTAssertNil(CaptureScale.match(1.4142 * 1.031 * 1.0, candidates: [papers[0]]))
        XCTAssertEqual(CaptureScale.match(1.30, candidates: papers)?.id, "letter")
        XCTAssertEqual(CaptureScale.match(1.64, candidates: papers)?.id, "legal")
        XCTAssertEqual(CaptureScale.match(1.60, candidates: papers)?.id, "idCard")
        XCTAssertNil(CaptureScale.match(1.50, candidates: papers))
        XCTAssertEqual(CaptureScale.match(1.40, candidates: CaptureScale.photoSizes)?.id, "photo5x7in")
        XCTAssertEqual(CaptureScale.match(1.43, candidates: CaptureScale.photoSizes)?.id, "photo3.5x5in")
        XCTAssertEqual(CaptureScale.match(1.0, candidates: CaptureScale.receiptWidths)?.id, "receipt80mm")
        XCTAssertNil(CaptureScale.match(0.5, candidates: papers))
        XCTAssertNil(CaptureScale.match(Double.nan, candidates: CaptureScale.receiptWidths))
        // 10 × 15 cm has 4 × 6 in's shape: the first listed wins.
        XCTAssertEqual(CaptureScale.match(1.5, candidates: CaptureScale.photoSizes)?.id, "photo4x6in")
        let metricFirst: [CaptureSize] = [CaptureScale.photoSizes[3], CaptureScale.photoSizes[0]]
        XCTAssertEqual(CaptureScale.match(1.5, candidates: metricFirst)?.id, "photo10x15cm")
    }

    func testEveryKindHasItsSizesAndEveryNameIsFound() {
        for kind in CaptureKind.allCases {
            let sizes = CaptureScale.candidates(kind)
            XCTAssertFalse(sizes.isEmpty, "\(kind)")
            for size in sizes {
                XCTAssertEqual(CaptureScale.find(size.id), size)
                XCTAssertGreaterThan(size.shortInches, 0)
                if let longSide = size.longInches { XCTAssertGreaterThanOrEqual(longSide, size.shortInches) }
            }
        }
        var ids: [String] = []
        for size in CaptureScale.papers { ids.append(size.id) }
        XCTAssertEqual(ids, ["a4", "letter", "legal", "idCard"])
        XCTAssertEqual(CaptureScale.candidates(.idCard).count, 1)
        XCTAssertEqual(CaptureScale.candidates(.idCard).first?.id, "idCard")
        XCTAssertEqual(CaptureScale.find("a4")?.paper, .a4)
        XCTAssertNil(CaptureScale.find("a3"))
        XCTAssertNil(CaptureScale.find(nil))
        // Each basis has its sizes.
        for size in CaptureScale.papers { XCTAssertEqual(size.basis, .paper) }
        for size in CaptureScale.receiptWidths { XCTAssertEqual(size.basis, .receiptWidth) }
        for size in CaptureScale.photoSizes { XCTAssertEqual(size.basis, .photoSize) }
    }

    func testFromAspectKeepsThePixelsOfAnUprightPage() {
        // Apple's scanner's A4 page, 2480 × 3508: 300 dpi.
        let a4 = CaptureScale.fromAspect(pixelWidth: 2480, pixelHeight: 3508, kind: .document)
        XCTAssertEqual(a4.size, "a4")
        XCTAssertEqual(a4.dpi, 300)
        XCTAssertEqual(a4.pixelWidth, 2480)
        XCTAssertEqual(a4.pixelHeight, 3508)
        XCTAssertEqual(a4.widthInches, 8.2677)
        XCTAssertEqual(a4.heightInches, 11.6929)
        // A close-up card keeps its 1200 dpi: its pixels are not touched.
        let card = CaptureScale.fromAspect(pixelWidth: 4044, pixelHeight: 2550, kind: .idCard)
        XCTAssertEqual(card.size, "idCard")
        XCTAssertEqual(card.dpi, 1200)
        let odd = CaptureScale.fromAspect(pixelWidth: 1000, pixelHeight: 1000, kind: .document)
        XCTAssertEqual(odd.basis, .nominal)
        XCTAssertEqual(odd.dpi, 200)
        XCTAssertEqual(odd.widthInches, 5.0)
        XCTAssertEqual(odd.heightInches, 5.0)
        let receipt = CaptureScale.fromAspect(pixelWidth: 630, pixelHeight: 3000, kind: .receipt)
        XCTAssertEqual(receipt.size, "receipt80mm")
        XCTAssertEqual(receipt.dpi, 200)
        XCTAssertEqual(CaptureScale.fromAspect(pixelWidth: 0, pixelHeight: 0, kind: .document).pixelWidth, 1)
    }
}
