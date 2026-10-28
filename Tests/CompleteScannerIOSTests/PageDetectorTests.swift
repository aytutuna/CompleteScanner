#if os(iOS)
import CoreGraphics
import Foundation
import XCTest
@testable import CompleteScannerIOS
@testable import CompleteScannerKit

// The page detector test's switch (`PageDetector`) as kept in the user's defaults, and the turn the live
// frames take for DocAligner: the frame turned upright by `RgbaImage.rotatedQuarterTurns` and the corners
// turned back by `LiveQuadTracker.photoOutline` land on the same pixels.

final class PageDetectorTests: XCTestCase {
    private func makeDefaults() throws -> UserDefaults {
        let name: String = "PageDetectorTests-\(UUID().uuidString)"
        let defaults: UserDefaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: name)
        }
        return defaults
    }

    func test_theDetector_isApple_unlessAnotherIsKept() throws {
        let defaults: UserDefaults = try makeDefaults()
        XCTAssertEqual(PageDetector.stored(defaults), PageDetector.apple)
        XCTAssertFalse(PageDetector.usesNeuralEngine(defaults))
        defaults.set("fastvitT8", forKey: PageDetector.key)
        XCTAssertEqual(PageDetector.stored(defaults), PageDetector.fastvitT8)
        XCTAssertEqual(PageDetector.stored(defaults).model, DocAlignerModel.fastvitT8)
        defaults.set("builtIn", forKey: PageDetector.key)
        XCTAssertNil(PageDetector.stored(defaults).model)
        defaults.set("someday", forKey: PageDetector.key)
        XCTAssertEqual(PageDetector.stored(defaults), PageDetector.apple)
        defaults.set(true, forKey: PageDetector.neuralEngineKey)
        XCTAssertTrue(PageDetector.usesNeuralEngine(defaults))
    }

    func test_cornersFoundOnTheUprightFrame_turnBackOntoTheSensorsPixels() throws {
        let width: Int = 48
        let height: Int = 36
        let marks: [(x: Int, y: Int)] = [(5, 4), (40, 7), (37, 30), (8, 27)]
        var pixels: [UInt8] = [UInt8](repeating: 0, count: width * height * 4)
        var index: Int = 0
        for mark in marks {
            let at: Int = (mark.y * width + mark.x) * 4
            pixels[at] = UInt8(100 + index * 40)
            pixels[at + 3] = 255
            index += 1
        }
        let frame = RgbaImage(width: width, height: height, pixels: pixels)
        for turn in [0, 90, 180, 270] {
            let upright: RgbaImage = frame.rotatedQuarterTurns(turn / 90)
            // Where each mark is in the upright frame, as shares of it (the pixel's centre).
            var found: [CGPoint] = []
            index = 0
            while index < 4 {
                let wanted = UInt8(100 + index * 40)
                var at: Int = 0
                while at < upright.width * upright.height {
                    if upright.pixels[at * 4] == wanted {
                        found.append(CGPoint(x: (Double(at % upright.width) + 0.5) / Double(upright.width),
                                             y: (Double(at / upright.width) + 0.5) / Double(upright.height)))
                    }
                    at += 1
                }
                index += 1
            }
            XCTAssertEqual(found.count, 4, "turn \(turn)")
            let back: Quad = try XCTUnwrap(LiveQuadTracker.photoOutline(Quad.fromCorners(found),
                                                                        rotationDegrees: (360 - turn) % 360))
            let sensor: Quad = back.scaled(Double(width), Double(height))
            for mark in marks {
                let centre = CGPoint(x: Double(mark.x) + 0.5, y: Double(mark.y) + 0.5)
                let nearest: Double = sensor.corners.map { (corner: CGPoint) -> Double in
                    let dx: Double = Double(corner.x - centre.x)
                    let dy: Double = Double(corner.y - centre.y)
                    return (dx * dx + dy * dy).squareRoot()
                }.min() ?? Double.infinity
                XCTAssertLessThan(nearest, 1e-6, "turn \(turn), mark \(mark)")
            }
        }
    }
}
#endif
