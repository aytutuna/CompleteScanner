import CoreGraphics
import XCTest
@testable import CompleteScannerKit

// Twin of windows/CompleteScanner.Core.Tests/QuadRefinerTests.cs: outlines put 2 % of the diagonal off the
// pages of the synthetic photos (PhotoScenes) and moved back onto their edges, and a table with no page.

private let diagonal = (Double(PhotoScenes.width * PhotoScenes.width + PhotoScenes.height * PhotoScenes.height)).squareRoot()

private func truth(_ map: PhotoScenes.IntHomography) -> Quad {
    map.corners(PhotoScenes.pageWidth, PhotoScenes.pageHeight)
}

/// `quad` with every corner moved 2 % of the diagonal, each its own way (four patterns).
private func off(_ quad: Quad, _ pattern: Int) -> Quad {
    let corners = quad.corners
    var moved: [CGPoint] = []
    for i in 0..<4 {
        let angle = Double(i) * 1.7 + Double(pattern) * 2.3
        moved.append(CGPoint(x: Double(corners[i].x) + 0.02 * diagonal * cos(angle),
                             y: Double(corners[i].y) + 0.02 * diagonal * sin(angle)))
    }
    return Quad(topLeft: moved[0], topRight: moved[1], bottomRight: moved[2], bottomLeft: moved[3])
}

final class QuadRefinerTests: XCTestCase {
    func testAnOutlineOffThePageIsMovedBackOntoItsEdges() {
        let scenes: [(String, RgbaImage, Quad)] = [
            ("wood", PhotoScenes.woodScene(), truth(PhotoScenes.woodMap)),
            ("dark", PhotoScenes.darkScene(), truth(PhotoScenes.darkMap)),
            ("light", PhotoScenes.lightScene(), truth(PhotoScenes.lightMap)),
            ("similar", PhotoScenes.similarScene(), truth(PhotoScenes.similarMap)),
            ("roundTrip", PhotoScenes.roundTripScene(), truth(PhotoScenes.roundTripMap)),
            ("bottomGap", PhotoScenes.bottomGapScene(8), truth(PhotoScenes.bottomGapMap(8))),
            ("rightGap", PhotoScenes.rightGapScene(4), truth(PhotoScenes.rightGapMap(4))),
        ]
        for (name, photo, page) in scenes {
            // The page's own outline is backed by its edges all round; one 2 % off is not.
            XCTAssertGreaterThanOrEqual(QuadRefiner.supportOf(photo, page), 0.95, name)
            for pattern in 0..<4 {
                let start = off(page, pattern)
                XCTAssertLessThan(QuadRefiner.supportOf(photo, start), 0.7, "\(name) \(pattern)")
                let result = QuadRefiner.refine(photo, start)
                XCTAssertTrue(result.refined, "\(name) \(pattern)")
                XCTAssertLessThanOrEqual(result.quad.maxCornerDistance(page), 0.003 * diagonal,
                                         "\(name) \(pattern): refined to \(result.quad)")
                XCTAssertGreaterThanOrEqual(result.support, 0.95, "\(name) \(pattern)")
            }
        }
    }

    func testAHeaderBarJustInsideThePageDoesNotPullItsTopEdge() {
        // Moved straight down 2 %: the header bar's edges lie nearer than the page's top edge.
        let photo = PhotoScenes.darkScene()
        let page = truth(PhotoScenes.darkMap)
        var start = page
        start.topLeft = CGPoint(x: Double(page.topLeft.x), y: Double(page.topLeft.y) + 0.02 * diagonal)
        start.topRight = CGPoint(x: Double(page.topRight.x), y: Double(page.topRight.y) + 0.02 * diagonal)
        let result = QuadRefiner.refine(photo, start)
        XCTAssertLessThanOrEqual(result.quad.maxCornerDistance(page), 0.003 * diagonal, "\(result.quad)")
    }

    func testATableWithNoPageLeavesTheOutlineAlone() {
        let photo = PhotoScenes.plainScene()
        let start = off(truth(PhotoScenes.woodMap), 0)
        let result = QuadRefiner.refine(photo, start)
        XCTAssertFalse(result.refined)
        XCTAssertEqual(result.quad, start)
        XCTAssertLessThan(result.support, 0.2)
    }

    func testALargePhotoIsSearchedSmall_andTheCornersComeBackInItsPixels() {
        // The wood scene three times as large (1080 × 1440): searched at 1000 px long, answered in its own pixels.
        let small = PhotoScenes.woodScene()
        let photo = small.resized(width: small.width * 3, height: small.height * 3)
        let page = truth(PhotoScenes.woodMap).scaled(3, 3)
        let result = QuadRefiner.refine(photo, off(page, 1))
        XCTAssertTrue(result.refined)
        XCTAssertLessThanOrEqual(result.quad.maxCornerDistance(page), 0.003 * 3 * diagonal, "\(result.quad)")
    }
}
