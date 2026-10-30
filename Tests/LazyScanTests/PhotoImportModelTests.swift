import CoreGraphics
import XCTest
@testable import LazyScanKit

// Twin of windows/LazyScan.Core.Tests/PhotoImportModelTests.cs: the photo import with a corner model
// tried first, on the wood scene (PhotoScenes) with a fake model that draws its heatmaps where it is told.

/// A corner model that answers `answer` and keeps what it was given.
private final class FakeModel: CornerModel {
    let answer: CornerHeatmaps?
    private(set) var inputs: [[Float]] = []

    init(_ answer: CornerHeatmaps?) {
        self.answer = answer
    }

    func heatmaps(_ input: [Float]) -> CornerHeatmaps? {
        inputs.append(input)
        return answer
    }
}

final class PhotoImportModelTests: XCTestCase {
    private let side: Int = 128

    private var truth: Quad {
        PhotoScenes.woodMap.corners(PhotoScenes.pageWidth, PhotoScenes.pageHeight)
    }

    /// A spot of `peaks[i]` on corner i of `corners` (the wood scene's pixels).
    private func spots(_ corners: Quad, _ peaks: [Double]) -> DrawnHeatmap {
        var heat = DrawnHeatmap(size: side)
        let points: [CGPoint] = corners.corners
        for i in 0..<4 {
            heat.spot(i, x: Double(points[i].x) / Double(PhotoScenes.width) * Double(side),
                      y: Double(points[i].y) / Double(PhotoScenes.height) * Double(side), peak: peaks[i], sigma: 1.5)
        }
        return heat
    }

    private func heatmaps(_ heat: DrawnHeatmap) -> CornerHeatmaps {
        CornerHeatmaps(values: heat.values, width: side, height: side)
    }

    func testAClearPageFromTheModelIsCorrectedWithoutAsking() {
        let photo = PhotoScenes.woodScene()
        let heat = spots(truth, [0.9, 0.9, 0.9, 0.9])
        let model = FakeModel(heatmaps(heat))
        let plan = PhotoImport.plan(photo, model: model)
        XCTAssertEqual(plan.action, .correct)
        XCTAssertEqual(plan.reason, PhotoReviewReason.none)
        XCTAssertLessThan(plan.corners.maxCornerDistance(truth), 1.5, "\(plan.corners)")
        XCTAssertEqual(plan.detection.confidence, heat.weakestPeak)
        XCTAssertEqual(plan.detection.rejection, PhotoDocumentRejection.none)
        XCTAssertEqual(model.inputs.count, 1)
        XCTAssertEqual(model.inputs.first, CornerModelInput.make(photo))
    }

    func testAnUnsurePageFromTheModelGoesToTheCornerEditor() {
        let photo = PhotoScenes.woodScene()
        // Its spots fall between values, so its weakest corner peaks a little under 0.6.
        let heat = spots(truth, [0.9, 0.6, 0.9, 0.9])
        let plan = PhotoImport.plan(photo, model: FakeModel(heatmaps(heat)))
        XCTAssertEqual(plan.action, .review)
        XCTAssertEqual(plan.reason, .unsure)
        XCTAssertLessThan(plan.corners.maxCornerDistance(truth), 1.5, "\(plan.corners)")
        XCTAssertEqual(plan.detection.confidence, heat.weakestPeak)
        XCTAssertGreaterThanOrEqual(plan.detection.confidence, PhotoImport.minModelConfidence)
        XCTAssertLessThan(plan.detection.confidence, PhotoImport.sureConfidence)
    }

    func testWithoutAPageFromTheModelThePageSearchDecides() {
        let photo = PhotoScenes.woodScene()
        let searched = PhotoImport.plan(photo)
        XCTAssertEqual(PhotoImport.plan(photo, model: nil), searched)
        // The model cannot run, is too unsure, finds no corner, or finds an outline too small for a page.
        let weak = heatmaps(spots(truth, [0.9, 0.45, 0.9, 0.9]))
        let square = Quad(topLeft: CGPoint(x: 100, y: 100), topRight: CGPoint(x: 160, y: 100),
                          bottomRight: CGPoint(x: 160, y: 180), bottomLeft: CGPoint(x: 100, y: 180))
        let small = heatmaps(spots(square, [0.9, 0.9, 0.9, 0.9]))
        let empty = CornerHeatmaps(values: [Float](repeating: 0, count: side * side * 4), width: side, height: side)
        for answer in [nil, weak, small, empty] {
            let model = FakeModel(answer)
            XCTAssertEqual(PhotoImport.plan(photo, model: model), searched)
            XCTAssertEqual(model.inputs.count, 1)
        }
    }
}
