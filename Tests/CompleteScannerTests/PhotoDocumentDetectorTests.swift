import CoreGraphics
import XCTest
@testable import CompleteScannerKit

// Twin of windows/CompleteScanner.Core.Tests/PhotoDocumentDetectorTests.cs: the same synthetic photos
// (PhotoScenes, byte-identical, checked by checksum) and the same expectations.

/// 1 % of the photo's diagonal (360 × 480: 6 px).
private let tolerance = 0.01 * (Double(PhotoScenes.width * PhotoScenes.width + PhotoScenes.height * PhotoScenes.height)).squareRoot()

private func expected(_ map: PhotoScenes.IntHomography) -> Quad {
    map.corners(PhotoScenes.pageWidth, PhotoScenes.pageHeight)
}

private func assertFound(_ result: PhotoDocumentDetection, _ expected: Quad, _ tolerance: Double,
                         file: StaticString = #filePath, line: UInt = #line) {
    guard let quad = result.quad else {
        XCTFail("no page: \(result.rejection), candidate \(String(describing: result.candidate))", file: file, line: line)
        return
    }
    XCTAssertEqual(result.rejection, PhotoDocumentRejection.none, file: file, line: line)
    let error = quad.maxCornerDistance(expected)
    XCTAssertLessThanOrEqual(error, tolerance, "corner error \(error): found \(quad), expected \(expected)", file: file, line: line)
    XCTAssertGreaterThanOrEqual(result.confidence, PhotoDocumentDetector.acceptScore, file: file, line: line)
}

final class PhotoDocumentDetectorTests: XCTestCase {
    func testScenesAreTheSameOnBothPlatforms() {
        XCTAssertEqual(PhotoScenes.checksum(PhotoScenes.woodScene()), 0x5D45_6758)
        XCTAssertEqual(PhotoScenes.checksum(PhotoScenes.darkScene()), 0x37A2_8CB9)
        XCTAssertEqual(PhotoScenes.checksum(PhotoScenes.lightScene()), 0xE9BE_D0A0)
        XCTAssertEqual(PhotoScenes.checksum(PhotoScenes.similarScene()), 0xB26B_D827)
        XCTAssertEqual(PhotoScenes.checksum(PhotoScenes.noPageScene()), 0xB93E_AFBA)
        XCTAssertEqual(PhotoScenes.checksum(PhotoScenes.plainScene()), 0x488C_62C7)
        XCTAssertEqual(PhotoScenes.checksum(PhotoScenes.cutOffScene()), 0xB990_DDDA)
        XCTAssertEqual(PhotoScenes.checksum(PhotoScenes.overlapScene()), 0x231A_4514)
        XCTAssertEqual(PhotoScenes.checksum(PhotoScenes.twoPagesScene()), 0x999E_64F6)
        XCTAssertEqual(PhotoScenes.checksum(PhotoScenes.roundTripScene()), 0xB97E_5292)
        XCTAssertEqual(PhotoScenes.checksum(PhotoScenes.bottomGapScene(3)), 0x2A26_4F0E)
        XCTAssertEqual(PhotoScenes.checksum(PhotoScenes.bottomGapScene(5)), 0x1C63_A221)
        XCTAssertEqual(PhotoScenes.checksum(PhotoScenes.bottomGapScene(8)), 0xE83D_D873)
        XCTAssertEqual(PhotoScenes.checksum(PhotoScenes.bottomGapScene(-15)), 0x7DC6_FC59)
        XCTAssertEqual(PhotoScenes.checksum(PhotoScenes.rightGapScene(4)), 0xCDB3_F5EF)
    }

    func testFindsAPageOnAWoodenTable() {
        assertFound(PhotoDocumentDetector.detect(PhotoScenes.woodScene()), expected(PhotoScenes.woodMap), tolerance)
    }

    func testFindsAPageOnADarkDeskWithGlareOnItsEdge() {
        assertFound(PhotoDocumentDetector.detect(PhotoScenes.darkScene()), expected(PhotoScenes.darkMap), tolerance)
    }

    func testFindsAPageOnALightDeskInThePhonesShadow() {
        assertFound(PhotoDocumentDetector.detect(PhotoScenes.lightScene()), expected(PhotoScenes.lightMap), tolerance)
    }

    func testFindsAPageOnATableOfNearlyItsColor() {
        assertFound(PhotoDocumentDetector.detect(PhotoScenes.similarScene()), expected(PhotoScenes.similarMap), tolerance)
    }

    func testFindsNothingWhereThereIsNoPage() {
        for scene in [PhotoScenes.noPageScene(), PhotoScenes.plainScene()] {
            let result = PhotoDocumentDetector.detect(scene)
            XCTAssertNil(result.quad)
            XCTAssertEqual(result.confidence, 0)
            XCTAssertTrue(result.rejection == .nothingFound || result.rejection == .lowConfidence, "\(result.rejection)")
        }
    }

    func testRefusesAPageCutOffByTheFrame() throws {
        let result = PhotoDocumentDetector.detect(PhotoScenes.cutOffScene())
        XCTAssertNil(result.quad)
        XCTAssertEqual(result.rejection, PhotoDocumentRejection.cutOff)
        let candidate = try XCTUnwrap(result.candidate)
        XCTAssertFalse(candidate.isInside(width: Double(PhotoScenes.width), height: Double(PhotoScenes.height)))
    }

    func testFindsAPageWhoseEdgeLiesCloseToTheFramesBorder() {
        // 3 to 8 px of table between the page and the frame's border: every corner is in the frame.
        for gap in [3, 5, 8] {
            let result = PhotoDocumentDetector.detect(PhotoScenes.bottomGapScene(gap))
            assertFound(result, expected(PhotoScenes.bottomGapMap(gap)), tolerance)
        }
        assertFound(PhotoDocumentDetector.detect(PhotoScenes.rightGapScene(4)), expected(PhotoScenes.rightGapMap(4)), tolerance)
    }

    func testRefusesAPageRunningOffTheBottomOfTheFrame() {
        let result = PhotoDocumentDetector.detect(PhotoScenes.bottomGapScene(-15))
        XCTAssertNil(result.quad)
        XCTAssertEqual(result.rejection, PhotoDocumentRejection.cutOff)
        XCTAssertNotNil(result.candidate)
    }

    func testTakesTheLargerOfTwoOverlappingPages() {
        assertFound(PhotoDocumentDetector.detect(PhotoScenes.overlapScene()), expected(PhotoScenes.topMap), tolerance)
    }

    func testRefusesTwoPagesOfTheSameSize() {
        let result = PhotoDocumentDetector.detect(PhotoScenes.twoPagesScene())
        XCTAssertNil(result.quad)
        XCTAssertEqual(result.rejection, PhotoDocumentRejection.ambiguous)
        XCTAssertNotNil(result.candidate)
    }

    func testAnalysesASmallerCopyAndAnswersInThePhotosPixels() {
        // The photo enlarged twice, analysed at 240 px: the corners come back in the large photo's pixels.
        let scene = PhotoScenes.woodScene()
        let lw = scene.width * 2, lh = scene.height * 2
        var pixels = [UInt8](repeating: 0, count: lw * lh * 4)
        for y in 0..<lh {
            for x in 0..<lw {
                let s = ((y / 2) * scene.width + x / 2) * 4, d = (y * lw + x) * 4
                for c in 0..<4 { pixels[d + c] = scene.pixels[s + c] }
            }
        }
        let large = RgbaImage(width: lw, height: lh, pixels: pixels)
        var options = PhotoDocumentOptions()
        options.analysisLongSide = 240
        let result = PhotoDocumentDetector.detect(large, hint: nil, options: options)
        assertFound(result, expected(PhotoScenes.woodMap).scaled(2, 2), 2 * tolerance)
    }

    func testAHintFromThePreviousFrameKeepsThePage() {
        let truth = expected(PhotoScenes.lightMap)
        let plain = PhotoDocumentDetector.detect(PhotoScenes.lightScene())
        let hint = Quad(
            topLeft: CGPoint(x: truth.topLeft.x + 4, y: truth.topLeft.y - 3),
            topRight: CGPoint(x: truth.topRight.x - 3, y: truth.topRight.y + 4),
            bottomRight: CGPoint(x: truth.bottomRight.x + 2, y: truth.bottomRight.y + 3),
            bottomLeft: CGPoint(x: truth.bottomLeft.x - 4, y: truth.bottomLeft.y - 2))
        let hinted = PhotoDocumentDetector.detect(PhotoScenes.lightScene(), hint: hint)
        assertFound(hinted, truth, tolerance)
        XCTAssertGreaterThanOrEqual(hinted.confidence, plain.confidence)
    }

    func testOtsuSplitsTwoLevels() {
        var histogram = [Int](repeating: 0, count: 256)
        histogram[40] = 300
        histogram[45] = 200
        histogram[200] = 400
        histogram[210] = 100
        let t = PhotoDocumentDetector.otsu(histogram, 1000)
        XCTAssertTrue((45...199).contains(t), "\(t)")
    }

    func testALineIsFittedPastAnOutlier() {
        var points: [CGPoint] = []
        for i in 0..<20 {
            let x = 10.0 + 5.0 * Double(i)
            let y = 20.0 + 2.5 * Double(i) + (i % 2 == 0 ? 0.3 : -0.3)
            points.append(CGPoint(x: x, y: y))
        }
        points.append(CGPoint(x: 50, y: 90))
        let line = PhotoDocumentDetector.fitLine(points)
        // y = 20 + 0.5 (x - 10): every inlier within half a pixel of the line.
        for i in 0..<20 { XCTAssertLessThan(abs(line.distance(Double(points[i].x), Double(points[i].y))), 0.5) }
        XCTAssertGreaterThan(abs(line.distance(50, 90)), 40)
    }

    func testTheLargestQuadOfAnOutlineIsItsRectangle() throws {
        // A rectangle with its corners slightly cut, as a mask's hull comes out.
        let hull = [CGPoint(x: 10, y: 12), CGPoint(x: 12, y: 10), CGPoint(x: 98, y: 10), CGPoint(x: 100, y: 12),
                    CGPoint(x: 100, y: 58), CGPoint(x: 98, y: 60), CGPoint(x: 12, y: 60), CGPoint(x: 10, y: 58)]
        let quad = try XCTUnwrap(PhotoDocumentDetector.largestQuad(PhotoDocumentDetector.simplify(hull, 40)))
        XCTAssertTrue(quad.isConvex)
        XCTAssertTrue((4300.0...4500.0).contains(quad.area), "\(quad.area)")
        XCTAssertEqual(PhotoDocumentDetector.simplify(hull, 3).count, 3)
    }

    func testCornerDistanceIgnoresWhichCornerComesFirst() {
        let q = expected(PhotoScenes.woodMap)
        let turned = Quad(topLeft: q.topRight, topRight: q.bottomRight, bottomRight: q.bottomLeft, bottomLeft: q.topLeft)
        XCTAssertEqual(PhotoDocumentDetector.cornerDistance(q, turned), 0, accuracy: 1e-9)
        XCTAssertFalse(PhotoDocumentDetector.separated(q, q.scaled(1, 1).scaled(0.5, 0.5), 0))
        let apart = Quad(topLeft: CGPoint(x: 400, y: 0), topRight: CGPoint(x: 500, y: 0),
                         bottomRight: CGPoint(x: 500, y: 100), bottomLeft: CGPoint(x: 400, y: 100))
        XCTAssertTrue(PhotoDocumentDetector.separated(q, apart, 5))
    }

    func testThePagesShapeIsReported() throws {
        let result = PhotoDocumentDetector.detect(PhotoScenes.woodScene())
        let aspect = try XCTUnwrap(result.aspect)
        XCTAssertTrue((1.2...1.6).contains(aspect.longOverShort), "\(aspect.longOverShort)")
    }
}
