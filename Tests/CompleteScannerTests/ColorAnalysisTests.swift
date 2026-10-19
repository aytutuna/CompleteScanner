import XCTest
import CoreGraphics
@testable import CompleteScannerKit

// Mirrors windows/CompleteScanner.Core.Tests/ColorAnalysisTests.cs: the same pages, the same answers.

/// An RGBA8 page of one color.
private struct Page {
    let width: Int
    let height: Int
    var rgba: [UInt8]

    init(width: Int = 400, height: Int = 400, _ r: UInt8, _ g: UInt8, _ b: UInt8) {
        self.width = width
        self.height = height
        rgba = [UInt8](repeating: 255, count: width * height * 4)
        for p in 0..<(width * height) {
            rgba[p * 4] = r
            rgba[p * 4 + 1] = g
            rgba[p * 4 + 2] = b
        }
    }

    mutating func paint(_ x: Int, _ y: Int, _ r: UInt8, _ g: UInt8, _ b: UInt8) {
        let i = (y * width + x) * 4
        rgba[i] = r
        rgba[i + 1] = g
        rgba[i + 2] = b
    }

    var isGray: Bool { ColorAnalysis.isEffectivelyGray(rgba: rgba, width: width, height: height) }
}

/// A 400 × 400 page (10 000 samples) with red on the first `count` sampled pixels.
private func withRedSamples(_ count: Int) -> Page {
    var page = Page(250, 250, 250)
    for n in 0..<count {
        page.paint(n % 100 * ColorAnalysis.sampleStep, n / 100 * ColorAnalysis.sampleStep, 220, 30, 30)
    }
    return page
}

private func makeSolidImage(width: Int, height: Int, red: CGFloat, green: CGFloat, blue: CGFloat) -> CGImage {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return ctx.makeImage()!
}

final class ColorAnalysisTests: XCTestCase {

    func test_pureGrayPages_areGray() {
        XCTAssertTrue(Page(255, 255, 255).isGray)
        XCTAssertTrue(Page(0, 0, 0).isGray)
        var ramp = Page(0, 0, 0)
        for y in 0..<ramp.height {
            for x in 0..<ramp.width {
                let v = UInt8(x * 255 / (ramp.width - 1))
                ramp.paint(x, y, v, v, v)
            }
        }
        XCTAssertTrue(ramp.isGray)
    }

    func test_scannerTintOnWhitePaper_isStillGray() {
        // Warm paper: chroma 30, under the threshold of 32.
        XCTAssertTrue(Page(250, 240, 220).isGray)
        XCTAssertFalse(Page(250, 240, 217).isGray) // chroma 33
    }

    func test_aFewColoredSamples_stayGray_onePercentIsColor() {
        XCTAssertTrue(withRedSamples(5).isGray)    // 0.05 %
        XCTAssertTrue(withRedSamples(9).isGray)    // 0.09 %
        XCTAssertFalse(withRedSamples(10).isGray)  // 0.1 %
        XCTAssertFalse(withRedSamples(100).isGray) // 1 %
    }

    func test_aColoredBlock_isColor_offGridPixelsAreNotSampled() {
        // A 40 × 40 stamp: 1 % of the page.
        var stamp = Page(255, 255, 255)
        for y in 100..<140 {
            for x in 200..<240 { stamp.paint(x, y, 30, 60, 200) }
        }
        XCTAssertFalse(stamp.isGray)

        // Color only between the sampled rows and columns is never looked at.
        var offGrid = Page(255, 255, 255)
        for y in stride(from: 1, to: offGrid.height, by: ColorAnalysis.sampleStep) {
            for x in stride(from: 1, to: offGrid.width, by: ColorAnalysis.sampleStep) { offGrid.paint(x, y, 255, 0, 0) }
        }
        XCTAssertTrue(offGrid.isGray)
    }

    func test_tinyAndOddSizedPages() {
        XCTAssertTrue(Page(width: 1, height: 1, 128, 128, 128).isGray)
        XCTAssertFalse(Page(width: 1, height: 1, 255, 0, 0).isGray)
        var odd = Page(width: 7, height: 5, 200, 200, 200)
        odd.paint(4, 4, 0, 0, 255) // sampled: (0|4, 0|4)
        XCTAssertFalse(odd.isGray)
    }

    func test_grayPixels_useRec601Luma() {
        var page = Page(width: 6, height: 1, 0, 0, 0)
        page.paint(0, 0, 255, 0, 0)
        page.paint(1, 0, 0, 255, 0)
        page.paint(2, 0, 0, 0, 255)
        page.paint(3, 0, 255, 255, 255)
        page.paint(4, 0, 10, 20, 30)
        page.paint(5, 0, 128, 128, 128)
        XCTAssertEqual(ColorAnalysis.grayPixels(rgba: page.rgba, width: 6, height: 1), [76, 150, 29, 255, 18, 128])
    }

    // Mac only: the check on a CGImage reads its pixels through `rgbaPixels(of:)`.

    func test_cgImages_areReadTopRowFirst_andChecked() throws {
        XCTAssertTrue(ColorAnalysis.isEffectivelyGray(makeSolidImage(width: 64, height: 48, red: 0.95, green: 0.95, blue: 0.95)))
        XCTAssertFalse(ColorAnalysis.isEffectivelyGray(makeSolidImage(width: 64, height: 48, red: 0.9, green: 0.2, blue: 0.2)))
        let rgba = try XCTUnwrap(ColorAnalysis.rgbaPixels(of: makeSolidImage(width: 3, height: 2, red: 0, green: 0, blue: 1)))
        XCTAssertEqual(rgba.count, 3 * 2 * 4)
        XCTAssertEqual(Array(rgba[0..<4]), [0, 0, 255, 255])
    }
}
