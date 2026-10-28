#if os(iOS)
import CoreGraphics
import Foundation
import XCTest
@testable import CompleteScannerIOS
@testable import CompleteScannerKit

// DocAligner's models run for real (`DocAligner`) on a page drawn here: a white sheet a little turned on a
// dark, speckled table. Skipped when scripts/fetch_docaligner.sh has not fetched the models.

enum DrawnPage {
    static let width: Int = 360
    static let height: Int = 480
    /// The sheet's corners, top left first, in the picture's pixels (y down).
    static let corners: [CGPoint] = [CGPoint(x: 70, y: 90), CGPoint(x: 300, y: 70), CGPoint(x: 320, y: 420),
                                     CGPoint(x: 50, y: 400)]

    static func image() -> CGImage? {
        let space: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(red: 0.18, green: 0.17, blue: 0.16, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        var seed: UInt32 = 12345
        var speck: Int = 0
        while speck < 1500 {
            seed = seed &* 1_103_515_245 &+ 12345
            let x: Int = Int(seed >> 8) % width
            seed = seed &* 1_103_515_245 &+ 12345
            let y: Int = Int(seed >> 8) % height
            let shade: CGFloat = 0.1 + CGFloat(Int(seed >> 20) % 20) / 100
            context.setFillColor(red: shade, green: shade, blue: shade * 0.9, alpha: 1)
            context.fill(CGRect(x: x, y: y, width: 3, height: 2))
            speck += 1
        }
        // CoreGraphics counts y up from the bottom.
        context.setFillColor(red: 0.96, green: 0.96, blue: 0.94, alpha: 1)
        context.move(to: CGPoint(x: corners[0].x, y: CGFloat(height) - corners[0].y))
        var index: Int = 1
        while index < 4 {
            context.addLine(to: CGPoint(x: corners[index].x, y: CGFloat(height) - corners[index].y))
            index += 1
        }
        context.closePath()
        context.fillPath()
        return context.makeImage()
    }
}

final class DocAlignerTests: XCTestCase {
    func test_eachModel_findsADrawnPage() throws {
        let missing: [DocAlignerModel] = DocAlignerModel.allCases.filter { (model: DocAlignerModel) -> Bool in !model.isAvailable }
        if !missing.isEmpty {
            throw XCTSkip("DocAligner's models are not fetched (scripts/fetch_docaligner.sh)")
        }
        let image: CGImage = try XCTUnwrap(DrawnPage.image())
        let diagonal: Double = (Double(DrawnPage.width * DrawnPage.width + DrawnPage.height * DrawnPage.height)).squareRoot()
        let runner = DocAligner()
        for model in DocAlignerModel.allCases {
            let run: DocAlignerRun = try runner.run(image, model: model, neuralEngine: false)
            let page: QuadCandidate = try XCTUnwrap(run.page, "\(model.title) found no page")
            var index: Int = 0
            for corner in page.quad.corners {
                let dx: Double = Double(corner.x) * Double(DrawnPage.width) - Double(DrawnPage.corners[index].x)
                let dy: Double = Double(corner.y) * Double(DrawnPage.height) - Double(DrawnPage.corners[index].y)
                XCTAssertLessThan((dx * dx + dy * dy).squareRoot(), 0.05 * diagonal, "\(model.title) corner \(index)")
                index += 1
            }
            let timed: (ms: [Double], coreMLProblem: String?) = try runner.time(image, model: model, neuralEngine: false,
                                                                                 warmUps: 1, runs: 10)
            print(String(format: "%@: confidence %.2f, median %.1f ms of 10 runs on the CPU", model.title, page.confidence,
                         DocAligner.percentile(timed.ms, 0.5)))
        }
    }

    func test_aMissingModel_isSaidToBeMissing() {
        XCTAssertEqual(DocAlignerError.missing(.lc100).errorDescription, "LC100 is not in this build")
        XCTAssertEqual(DocAlignerModel.fastvitT8.title, "FastViT-T8")
    }

    func test_percentiles_takeTheNearestValue() {
        let values: [Double] = [9, 1, 5, 3, 7, 2, 8, 4, 6, 10]
        XCTAssertEqual(DocAligner.percentile(values, 0.5), 6)
        XCTAssertEqual(DocAligner.percentile(values, 0.9), 9)
        XCTAssertEqual(DocAligner.percentile(values, 0), 1)
        XCTAssertEqual(DocAligner.percentile(values, 1), 10)
        XCTAssertEqual(DocAligner.percentile([], 0.5), 0)
    }
}
#endif
