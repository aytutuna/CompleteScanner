import CoreGraphics
import XCTest
@testable import LazyScanKit

// Mirrors windows/LazyScan.Core.Tests/GlareDetectorTests.cs: the same cards, readings and answers.
// The readings are pinned to an independent model of GlareDetector's description.

/// Made-up cards for the glare tests, drawn pixel by pixel the same way on both platforms: 428 × 270 (an
/// ID-1 card at about 127 dpi), a blue-grey ground, a photo box and six lines of print; glare is a white
/// ellipse (center (300, 120), radii 70 × 40) with a half-light halo around it; specks are 2 × 2 white
/// dots every 30 px on two rows; the edge is a white strip 6 px wide along the left side.
enum GlareCards {
    static let width: Int = 428
    static let height: Int = 270

    static func card(r: UInt8 = 214, g: UInt8 = 220, b: UInt8 = 226, glare: Bool = false, specks: Bool = false,
                     edge: Bool = false) -> RgbaImage {
        var pixels: [UInt8] = [UInt8](repeating: 0, count: width * height * 4)
        let rx: Int = 70
        let ry: Int = 40
        let cx: Int = 300
        let cy: Int = 120
        let r4: Int = 4 * rx * rx * ry * ry
        for y in 0..<height {
            for x in 0..<width {
                var cr: Int = Int(r)
                var cg: Int = Int(g)
                var cb: Int = Int(b)
                if x >= 24 && x < 124 && y >= 60 && y < 200 {
                    cr = 150
                    cg = 130
                    cb = 120
                }
                for i in 0..<6 {
                    let top: Int = 70 + 24 * i
                    if x >= 150 && x < 400 && y >= top && y < top + 8 {
                        cr = 40
                        cg = 44
                        cb = 52
                    }
                }
                if glare {
                    let dx: Int = 2 * x + 1 - 2 * cx
                    let dy: Int = 2 * y + 1 - 2 * cy
                    let d: Int = dx * dx * ry * ry + dy * dy * rx * rx
                    if d <= r4 {
                        cr = 255
                        cg = 255
                        cb = 255
                    } else if d <= 2 * r4 {
                        cr = (cr + 256) / 2
                        cg = (cg + 256) / 2
                        cb = (cb + 256) / 2
                    }
                }
                let speckRow: Bool = y == 20 || y == 21 || y == 240 || y == 241
                if specks && speckRow && x >= 10 && (x - 10) % 30 < 2 {
                    cr = 255
                    cg = 255
                    cb = 255
                }
                if edge && x < 6 {
                    cr = 255
                    cg = 255
                    cb = 255
                }
                let p: Int = (y * width + x) * 4
                pixels[p] = UInt8(cr)
                pixels[p + 1] = UInt8(cg)
                pixels[p + 2] = UInt8(cb)
                pixels[p + 3] = 255
            }
        }
        return RgbaImage(width: width, height: height, pixels: pixels)
    }

    /// FNV-1a over the RGBA bytes.
    static func checksum(_ image: RgbaImage) -> UInt32 {
        var hash: UInt32 = 0x811C_9DC5
        for value in image.pixels {
            hash ^= UInt32(value)
            hash = hash &* 0x0100_0193
        }
        return hash
    }

    static func rect(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> Quad {
        Quad(topLeft: CGPoint(x: x0, y: y0), topRight: CGPoint(x: x1, y: y0),
             bottomRight: CGPoint(x: x1, y: y1), bottomLeft: CGPoint(x: x0, y: y1))
    }
}

final class GlareDetectorTests: XCTestCase {
    func testTheCardsAreTheSameOnBothPlatforms() {
        XCTAssertEqual(GlareCards.checksum(GlareCards.card()), 0x0CE7_17C5)
        XCTAssertEqual(GlareCards.checksum(GlareCards.card(glare: true)), 0x1765_7405)
        XCTAssertEqual(GlareCards.checksum(GlareCards.card(specks: true)), 0x6BF0_9B45)
        XCTAssertEqual(GlareCards.checksum(GlareCards.card(edge: true)), 0xD428_B625)
        XCTAssertEqual(GlareCards.checksum(GlareCards.card(r: 236, g: 238, b: 240)), 0xC076_1E05)
        XCTAssertEqual(GlareCards.checksum(GlareCards.card(glare: true, specks: true, edge: true)), 0xF39E_E005)
    }

    func testACardWithoutAReflectionHasNoGlare() {
        XCTAssertEqual(GlareDetector.measure(GlareCards.card()), GlareReading.none)
        XCTAssertFalse(GlareDetector.hasGlare(GlareCards.card()))
        // A light card whose white is not blown out.
        XCTAssertEqual(GlareDetector.measure(GlareCards.card(r: 236, g: 238, b: 240)), GlareReading.none)
    }

    func testAWhitePatchOnTheCardIsGlare() {
        let reading: GlareReading = GlareDetector.measure(GlareCards.card(glare: true))
        XCTAssertEqual(reading.clippedShare, 0.08509803921568627, accuracy: 1e-12)
        XCTAssertEqual(reading.largestBlobShare, 0.08509803921568627, accuracy: 1e-12)
        XCTAssertTrue(reading.hasGlare)
        XCTAssertTrue(GlareDetector.hasGlare(GlareCards.card(glare: true)))
        XCTAssertEqual(GlareDetector.hint, "Tilt to avoid glare")
    }

    func testWhiteSpecksAndTheEdgeAreNotGlare() {
        let specks: GlareReading = GlareDetector.measure(GlareCards.card(specks: true))
        XCTAssertEqual(specks.clippedShare, 0.0010980392156862745, accuracy: 1e-12)
        XCTAssertEqual(specks.largestBlobShare, 3.9215686274509805e-05, accuracy: 1e-12)
        XCTAssertFalse(specks.hasGlare)
        // A white strip along the edge lies in the band left out.
        XCTAssertEqual(GlareDetector.measure(GlareCards.card(edge: true)), GlareReading.none)
        // All three: the specks count as clipped, the largest patch is the glare's.
        let all: GlareReading = GlareDetector.measure(GlareCards.card(glare: true, specks: true, edge: true))
        XCTAssertEqual(all.clippedShare, 0.08619607843137254, accuracy: 1e-12)
        XCTAssertEqual(all.largestBlobShare, 0.08509803921568627, accuracy: 1e-12)
        XCTAssertTrue(all.hasGlare)
    }

    func testOnlyTheOutlineGivenIsMeasured() {
        let card: RgbaImage = GlareCards.card(glare: true)
        XCTAssertEqual(GlareDetector.measure(card, region: GlareCards.rect(0, 0, 214, 270)), GlareReading.none)
        let right: GlareReading = GlareDetector.measure(card, region: GlareCards.rect(214, 0, 428, 270))
        XCTAssertEqual(right.clippedShare, 0.1780855199222546, accuracy: 1e-12)
        XCTAssertEqual(right.largestBlobShare, 0.1780855199222546, accuracy: 1e-12)
        let tilted = Quad(topLeft: CGPoint(x: 190, y: 30), topRight: CGPoint(x: 410, y: 60),
                          bottomRight: CGPoint(x: 390, y: 230), bottomLeft: CGPoint(x: 170, y: 200))
        let reading: GlareReading = GlareDetector.measure(card, region: tilted)
        XCTAssertEqual(reading.clippedShare, 0.2681216850576114, accuracy: 1e-12)
        XCTAssertEqual(reading.largestBlobShare, 0.2681216850576114, accuracy: 1e-12)
        // An outline that crosses itself, or lies outside the picture, measures nothing.
        let bowTie = Quad(topLeft: CGPoint(x: 0, y: 0), topRight: CGPoint(x: 428, y: 270),
                          bottomRight: CGPoint(x: 428, y: 0), bottomLeft: CGPoint(x: 0, y: 270))
        XCTAssertEqual(GlareDetector.measure(card, region: bowTie), GlareReading.none)
        XCTAssertEqual(GlareDetector.measure(card, region: GlareCards.rect(500, 300, 600, 400)), GlareReading.none)
    }

    func testALargePhotoIsMeasuredInCells() {
        // 1284 × 810: three times the card, so cells of 4 × 4 pixels (1284 / 400 rounded up), the same glare.
        let small: RgbaImage = GlareCards.card(glare: true)
        let width: Int = small.width * 3
        let height: Int = small.height * 3
        var large: [UInt8] = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let from: Int = ((y / 3) * small.width + x / 3) * 4
                let to: Int = (y * width + x) * 4
                for c in 0..<4 {
                    large[to + c] = small.pixels[from + c]
                }
            }
        }
        let reading: GlareReading = GlareDetector.measure(RgbaImage(width: width, height: height, pixels: large))
        XCTAssertTrue(reading.hasGlare)
        XCTAssertGreaterThanOrEqual(reading.largestBlobShare, 0.08)
        XCTAssertLessThanOrEqual(reading.largestBlobShare, 0.09)
    }
}
