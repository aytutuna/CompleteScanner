import CoreGraphics
import Foundation
import XCTest
@testable import CompleteScannerKit
@testable import CompleteScannerModel

// DocAligner's FastViT-T8 on the SmartDoc frames in Tests/Fixtures/Pages, with Core ML in front and on the
// CPU alone: every corner within 1.5 % of the photo's diagonal of the ground truth. Skipped when
// scripts/fetch_docaligner.sh has not fetched the model.

final class FastViTCornerModelTests: XCTestCase {
    /// The farthest a corner may lie from the ground truth, as a share of the photo's diagonal.
    private let tolerance: Double = 0.015

    func testEveryPagePhotoReadsAtItsSizeWithItsPageInIt() throws {
        let photos: [PagePhoto] = try PageFixtures.all()
        XCTAssertEqual(photos.count, 6)
        for photo in photos {
            let image: RgbaImage = try PageFixtures.read(photo)
            XCTAssertEqual(image.width, photo.width, photo.file)
            XCTAssertEqual(image.height, photo.height, photo.file)
            XCTAssertTrue(photo.truth.isConvex, photo.file)
            XCTAssertTrue(photo.truth.isInside(width: Double(image.width), height: Double(image.height)), photo.file)
        }
    }

    func testFastViTFindsEveryPageWithinOnePointFivePercentOfTheDiagonal() throws {
        guard FastViTCornerModel.isAvailable else {
            throw XCTSkip("The corner model is not fetched (scripts/fetch_docaligner.sh)")
        }
        let photos: [PagePhoto] = try PageFixtures.all()
        for model in [FastViTCornerModel(), FastViTCornerModel(coreML: false)] {
            let engine: String = model.coreML ? "Core ML" : "CPU"
            for photo in photos {
                let image: RgbaImage = try PageFixtures.read(photo)
                let heat: CornerHeatmaps = try model.run(CornerModelInput.make(image))
                let found: QuadCandidate = try XCTUnwrap(CornerHeatmap.decode(heat.values, width: heat.width,
                                                                               height: heat.height),
                                                         "\(engine): no page in \(photo.file)")
                let w: Double = Double(image.width)
                let h: Double = Double(image.height)
                let diagonal: Double = (w * w + h * h).squareRoot()
                let quad: Quad = Quad.fromCorners(found.quad.scaled(w, h).corners)
                var errors: [String] = []
                var index: Int = 0
                while index < 4 {
                    let dx: Double = Double(quad[index].x) - Double(photo.truth[index].x)
                    let dy: Double = Double(quad[index].y) - Double(photo.truth[index].y)
                    let error: Double = (dx * dx + dy * dy).squareRoot() / diagonal
                    XCTAssertLessThan(error, tolerance, "\(engine): \(photo.file) corner \(index)")
                    errors.append(String(format: "%.2f", error * 100))
                    index += 1
                }
                let plan: PhotoImportPlan = PhotoImport.plan(image, model: model)
                print(String(format: "%@ %@: confidence %.3f, corner errors %@ %% of the diagonal; import plan %@",
                             engine, photo.file, found.confidence, errors.joined(separator: " "),
                             plan.action == .correct ? "corrects it" : "asks"))
            }
            if let problem = model.coreMLProblem {
                print("Core ML was not used: \(problem)")
            }
        }
    }

    func testAnInputOfTheWrongSizeIsRefused() {
        XCTAssertThrowsError(try FastViTCornerModel(coreML: false).run([0, 0, 0])) { (error: Error) -> Void in
            XCTAssertEqual(error as? CornerModelError, CornerModelError.unreadable)
        }
        XCTAssertNil(FastViTCornerModel(coreML: false).heatmaps([]))
    }
}
