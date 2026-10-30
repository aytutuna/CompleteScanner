import XCTest
import CoreGraphics
@testable import LazyScanKit

// MARK: - Synthetic flatbed helpers

/// One rectangle "photo" laid on the synthetic flatbed.
private struct BedPhoto {
    let center: CGPoint
    let size: CGSize
    let angleDegrees: Double
    let color: (r: CGFloat, g: CGFloat, b: CGFloat)
}

/// 8.5 x 11 inches at 150 dpi.
private let bedWidthPx = 1275
private let bedHeightPx = 1650

/// Renders a flatbed scan: light-gray background (0.96) with saturated filled rectangles,
/// each rotated about its center. Drawing happens in the same convention as
/// `DetectedPhotoRegion`: pixels, origin top-left, positive angle = clockwise on screen.
private func renderBed(photos: [BedPhoto], width: Int = bedWidthPx, height: Int = bedHeightPx) -> CGImage {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                        bytesPerRow: 0, space: colorSpace,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(srgbRed: 0.96, green: 0.96, blue: 0.96, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))

    // Flip so context coordinates match top-left-origin pixel coordinates (y down);
    // after the flip a positive `rotate(by:)` appears clockwise on screen, matching
    // the DetectedPhotoRegion angle convention.
    ctx.translateBy(x: 0, y: CGFloat(height))
    ctx.scaleBy(x: 1, y: -1)

    for photo in photos {
        ctx.saveGState()
        ctx.translateBy(x: photo.center.x, y: photo.center.y)
        ctx.rotate(by: CGFloat(photo.angleDegrees) * .pi / 180)
        ctx.setFillColor(CGColor(srgbRed: photo.color.r, green: photo.color.g, blue: photo.color.b, alpha: 1))
        ctx.fill(CGRect(x: -photo.size.width / 2, y: -photo.size.height / 2,
                        width: photo.size.width, height: photo.size.height))
        ctx.restoreGState()
    }
    return ctx.makeImage()!
}

/// Reads one pixel (top-left-origin coordinates) as 0...255 RGBA.
private func pixelRGBA(of image: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
    var buffer = [UInt8](repeating: 0, count: 4)
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    buffer.withUnsafeMutableBytes { raw in
        let ctx = CGContext(data: raw.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                            bytesPerRow: 4, space: colorSpace,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.interpolationQuality = .none
        // Position the image so that pixel (x, y) covers the context's single pixel.
        ctx.draw(image, in: CGRect(x: -CGFloat(x), y: CGFloat(y - image.height + 1),
                                   width: CGFloat(image.width), height: CGFloat(image.height)))
    }
    return (Int(buffer[0]), Int(buffer[1]), Int(buffer[2]), Int(buffer[3]))
}

private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
    hypot(a.x - b.x, a.y - b.y)
}

private func nearestRegion(to center: CGPoint, in regions: [DetectedPhotoRegion]) -> DetectedPhotoRegion? {
    regions.min { distance($0.center, center) < distance($1.center, center) }
}

/// Angular difference folded into the (-45, 45] convention (mod 90).
private func angleDelta(_ a: Double, _ b: Double) -> Double {
    var d = (a - b).truncatingRemainder(dividingBy: 90)
    if d > 45 { d -= 90 }
    if d < -45 { d += 90 }
    return abs(d)
}

/// The standard three-photo bed used by several tests.
private let threePhotos: [BedPhoto] = [
    BedPhoto(center: CGPoint(x: 300, y: 350), size: CGSize(width: 450, height: 300),
             angleDegrees: -15, color: (0.80, 0.12, 0.12)),
    BedPhoto(center: CGPoint(x: 900, y: 400), size: CGSize(width: 350, height: 350),
             angleDegrees: 0, color: (0.10, 0.25, 0.80)),
    BedPhoto(center: CGPoint(x: 550, y: 1150), size: CGSize(width: 500, height: 350),
             angleDegrees: 20, color: (0.10, 0.60, 0.18)),
]

// MARK: - Tests

final class PhotoDetectorTests: XCTestCase {

    func test_detectsThreePhotos() throws {
        let bed = renderBed(photos: threePhotos)
        let regions = PhotoDetector.detectRegions(in: bed, dpi: 150)
        XCTAssertEqual(regions.count, 3, "Expected exactly 3 detected regions, got \(regions.count)")

        for expected in threePhotos {
            let match = try XCTUnwrap(nearestRegion(to: expected.center, in: regions),
                                      "No region found near \(expected.center)")
            XCTAssertLessThanOrEqual(distance(match.center, expected.center), 25,
                                     "Center \(match.center) too far from expected \(expected.center)")
            XCTAssertEqual(Double(match.size.width), Double(expected.size.width),
                           accuracy: Double(expected.size.width) * 0.08,
                           "Width off for photo at \(expected.center)")
            XCTAssertEqual(Double(match.size.height), Double(expected.size.height),
                           accuracy: Double(expected.size.height) * 0.08,
                           "Height off for photo at \(expected.center)")
            // The 0° square has a 90° orientation ambiguity — skip its angle assert.
            if expected.size.width != expected.size.height {
                XCTAssertLessThanOrEqual(angleDelta(match.angleDegrees, expected.angleDegrees), 2.5,
                                         "Angle \(match.angleDegrees)° too far from \(expected.angleDegrees)°")
            }
        }
    }

    func test_extractUpright() throws {
        let bed = renderBed(photos: threePhotos)
        let regions = PhotoDetector.detectRegions(in: bed, dpi: 150)
        let expected = threePhotos[0] // the -15° red photo
        let region = try XCTUnwrap(nearestRegion(to: expected.center, in: regions),
                                   "No region found near \(expected.center)")
        XCTAssertLessThanOrEqual(distance(region.center, expected.center), 25)

        let extracted = try XCTUnwrap(PhotoDetector.extractPhoto(from: bed, region: region, deskew: true),
                                      "extractPhoto returned nil")
        XCTAssertEqual(Double(extracted.width), Double(region.size.width),
                       accuracy: Double(region.size.width) * 0.05)
        XCTAssertEqual(Double(extracted.height), Double(region.size.height),
                       accuracy: Double(region.size.height) * 0.05)

        // Center pixel must be the photo's fill color: sRGB (0.80, 0.12, 0.12) -> (204, 31, 31).
        let px = pixelRGBA(of: extracted, x: extracted.width / 2, y: extracted.height / 2)
        XCTAssertLessThanOrEqual(abs(px.r - 204), 40, "Red channel was \(px.r)")
        XCTAssertLessThanOrEqual(abs(px.g - 31), 40, "Green channel was \(px.g)")
        XCTAssertLessThanOrEqual(abs(px.b - 31), 40, "Blue channel was \(px.b)")
    }

    func test_singlePhotoFullBed() throws {
        let photo = BedPhoto(center: CGPoint(x: 637, y: 825), size: CGSize(width: 600, height: 420),
                             angleDegrees: 10, color: (0.85, 0.55, 0.10))
        let bed = renderBed(photos: [photo])
        let regions = PhotoDetector.detectRegions(in: bed, dpi: 150)
        XCTAssertEqual(regions.count, 1, "Expected exactly 1 region, got \(regions.count)")
        let region = try XCTUnwrap(regions.first)
        XCTAssertLessThanOrEqual(distance(region.center, photo.center), 25)
        XCTAssertEqual(Double(region.size.width), Double(photo.size.width),
                       accuracy: Double(photo.size.width) * 0.08)
        XCTAssertEqual(Double(region.size.height), Double(photo.size.height),
                       accuracy: Double(photo.size.height) * 0.08)
    }

    func test_emptyBedReturnsNothing() {
        let bed = renderBed(photos: [])
        let regions = PhotoDetector.detectRegions(in: bed, dpi: 150)
        XCTAssertEqual(regions.count, 0, "Blank bed must yield no regions, got \(regions.count)")
    }

    func test_minSizeFilter() throws {
        // 100x100 px at 150 dpi is 0.67", below the 1.0" minimum — it must be dropped.
        let keeper = BedPhoto(center: CGPoint(x: 300, y: 350), size: CGSize(width: 450, height: 300),
                              angleDegrees: -15, color: (0.80, 0.12, 0.12))
        let scrap = BedPhoto(center: CGPoint(x: 900, y: 1300), size: CGSize(width: 100, height: 100),
                             angleDegrees: 0, color: (0.20, 0.15, 0.75))
        let bed = renderBed(photos: [keeper, scrap])

        var options = PhotoDetectorOptions()
        options.minPhotoSideInches = 1.0
        let regions = PhotoDetector.detectRegions(in: bed, dpi: 150, options: options)
        XCTAssertEqual(regions.count, 1, "Scrap below minPhotoSideInches must be filtered out")
        let region = try XCTUnwrap(regions.first)
        XCTAssertLessThanOrEqual(distance(region.center, keeper.center), 25,
                                 "Surviving region should be the large photo")
    }
}
