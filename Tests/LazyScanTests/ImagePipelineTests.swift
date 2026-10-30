import XCTest
import CoreGraphics
@testable import LazyScanKit

// MARK: - Helpers

private func makeContext(width: Int, height: Int) -> CGContext {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                     bytesPerRow: width * 4, space: colorSpace,
                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

/// Deterministic RGB gradient: r ramps with x, g with y, b with x+y.
private func makeGradientImage(width: Int = 64, height: Int = 64) -> CGImage {
    let ctx = makeContext(width: width, height: height)
    let ptr = ctx.data!.assumingMemoryBound(to: UInt8.self)
    let rowBytes = ctx.bytesPerRow
    for y in 0..<height {
        for x in 0..<width {
            let i = y * rowBytes + x * 4
            ptr[i] = UInt8(x * 255 / (width - 1))
            ptr[i + 1] = UInt8(y * 255 / (height - 1))
            ptr[i + 2] = UInt8((x + y) * 255 / (width + height - 2))
            ptr[i + 3] = 255
        }
    }
    return ctx.makeImage()!
}

/// Mid-gray image with a 3x3 red marker in the top-left corner (pixel coordinates).
private func makeMarkerImage(width: Int, height: Int) -> CGImage {
    let ctx = makeContext(width: width, height: height)
    ctx.setFillColor(CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
    // Context origin is bottom-left, so the image's top-left corner is at y = height - 3.
    ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
    ctx.fill(CGRect(x: 0, y: CGFloat(height - 3), width: 3, height: 3))
    return ctx.makeImage()!
}

/// Renders any CGImage to a tightly-packed sRGB RGBA8 buffer (row 0 = top of image).
private func renderRGBA(_ image: CGImage) -> [UInt8] {
    let ctx = makeContext(width: image.width, height: image.height)
    ctx.interpolationQuality = .none
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height)))
    let ptr = ctx.data!.assumingMemoryBound(to: UInt8.self)
    return Array(UnsafeBufferPointer(start: ptr, count: image.width * image.height * 4))
}

private func pixel(_ rgba: [UInt8], width: Int, x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
    let i = (y * width + x) * 4
    return (Int(rgba[i]), Int(rgba[i + 1]), Int(rgba[i + 2]))
}

/// Mean and standard deviation of Rec.601 luminance over all pixels (0...255 scale).
private func luminanceStats(_ image: CGImage) -> (mean: Double, stddev: Double) {
    let rgba = renderRGBA(image)
    var values: [Double] = []
    values.reserveCapacity(rgba.count / 4)
    var i = 0
    while i < rgba.count {
        values.append(0.299 * Double(rgba[i]) + 0.587 * Double(rgba[i + 1]) + 0.114 * Double(rgba[i + 2]))
        i += 4
    }
    let mean = values.reduce(0, +) / Double(values.count)
    let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
    return (mean, variance.squareRoot())
}

// MARK: - Tests

final class ImagePipelineTests: XCTestCase {

    func test_brightnessRaisesMeanLuminance() {
        let input = makeGradientImage()
        var settings = AdjustmentSettings()
        settings.brightness = 0.5
        let output = ImagePipeline.apply(settings, to: input, colorMode: .color)
        XCTAssertEqual(output.width, input.width)
        XCTAssertEqual(output.height, input.height)
        XCTAssertGreaterThan(luminanceStats(output).mean, luminanceStats(input).mean + 10,
                             "brightness +0.5 must raise mean luminance")
    }

    func test_contrastRaisesStddev() {
        let input = makeGradientImage()
        var settings = AdjustmentSettings()
        settings.contrast = 2.0
        let output = ImagePipeline.apply(settings, to: input, colorMode: .color)
        XCTAssertGreaterThan(luminanceStats(output).stddev, luminanceStats(input).stddev * 1.2,
                             "contrast 2.0 must widen the luminance distribution")
    }

    func test_identityReturnsUnchangedPixels() {
        let input = makeGradientImage()
        let output = ImagePipeline.apply(AdjustmentSettings(), to: input, colorMode: .color)
        if output === input { return } // returning the same instance is explicitly allowed
        XCTAssertEqual(output.width, input.width)
        XCTAssertEqual(output.height, input.height)
        XCTAssertEqual(renderRGBA(output), renderRGBA(input),
                       "identity settings + .color must be pixel-identical")
    }

    func test_grayscaleMakesChannelsEqual() {
        let input = makeGradientImage()
        let output = ImagePipeline.apply(AdjustmentSettings(), to: input, colorMode: .grayscale)
        let rgba = renderRGBA(output)
        var maxDelta = 0
        var i = 0
        while i < rgba.count {
            let r = Int(rgba[i]), g = Int(rgba[i + 1]), b = Int(rgba[i + 2])
            maxDelta = max(maxDelta, abs(r - g), abs(g - b), abs(r - b))
            i += 4
        }
        XCTAssertLessThanOrEqual(maxDelta, 2, "grayscale output must have r==g==b (±2)")
    }

    func test_blackWhiteBinarizes() {
        let input = makeGradientImage()
        let output = ImagePipeline.apply(AdjustmentSettings(), to: input, colorMode: .blackWhite)
        let rgba = renderRGBA(output)
        var maxMidDistance = 0
        var i = 0
        while i < rgba.count {
            for c in 0..<3 {
                let v = Int(rgba[i + c])
                maxMidDistance = max(maxMidDistance, min(v, 255 - v))
            }
            i += 4
        }
        XCTAssertLessThanOrEqual(maxMidDistance, 6, "blackWhite output must be ~0 or ~255 everywhere")
    }

    func test_rotateOneQuarterTurnClockwise() {
        let input = makeMarkerImage(width: 64, height: 32)
        let output = ImagePipeline.rotate(input, quarterTurns: 1)
        XCTAssertEqual(output.width, 32)
        XCTAssertEqual(output.height, 64)

        // Clockwise: source top-left lands at the destination's top-right.
        // Probe (width-2, 1), which maps back to source (1, 1) inside the red marker.
        let rgba = renderRGBA(output)
        let probe = pixel(rgba, width: output.width, x: output.width - 2, y: 1)
        XCTAssertGreaterThan(probe.r, 200, "expected the red marker at the top-right; got \(probe)")
        XCTAssertLessThan(probe.g, 80, "expected the red marker at the top-right; got \(probe)")
        XCTAssertLessThan(probe.b, 80, "expected the red marker at the top-right; got \(probe)")
    }

    func test_rotateZeroKeepsDimensions() {
        let input = makeGradientImage(width: 64, height: 32)
        let output = ImagePipeline.rotate(input, quarterTurns: 0)
        XCTAssertEqual(output.width, 64)
        XCTAssertEqual(output.height, 32)
    }
}
