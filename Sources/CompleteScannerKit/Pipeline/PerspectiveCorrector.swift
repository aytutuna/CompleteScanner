import CoreGraphics
import Foundation

// Twin of windows/CompleteScanner.Core/PerspectiveCorrector.cs: + − × ÷ and square roots on doubles
// in the same order, rounding halves to even as RgbaImage's bilinear sampler does, so the same
// photo and quad give the same bytes on both platforms.

/// The shape of the sheet a quad shows, worked out from the photo (`PerspectiveCorrector.estimateAspect`).
public struct AspectEstimate: Equatable, Sendable {
    /// The sheet's width (top edge) over its height (left edge), as it lies in the photo.
    public var widthOverHeight: Double
    /// The camera's focal length in pixels that explains the quad, when the quad says (a sheet seen
    /// at an angle); nil when it does not (seen straight on, or the quad fits no camera centered on
    /// the photo), and the shape then comes from the edge lengths.
    public var focalLength: Double?

    public init(widthOverHeight: Double, focalLength: Double?) {
        self.widthOverHeight = widthOverHeight
        self.focalLength = focalLength
    }

    /// The long side over the short side (at least 1).
    public var longOverShort: Double { widthOverHeight >= 1 ? widthOverHeight : 1 / widthOverHeight }
}

/// A known sheet whose shape matched (`PerspectiveCorrector.matchPaper`).
public struct PaperMatch: Equatable, Sendable {
    /// The size taken for the match. A4 stands for every √2 sheet (A4, A5, A6).
    public var size: PaperSize
    /// That size's long side over its short side.
    public var longOverShort: Double

    public init(size: PaperSize, longOverShort: Double) {
        self.size = size
        self.longOverShort = longOverShort
    }
}

/// How the corrected page is resampled.
public enum Supersampling: Sendable {
    /// Four samples per pixel when the page is made smaller than the photo shows it (by more than 1.25), one otherwise.
    case auto
    /// One bilinear sample per pixel.
    case off
    /// Four bilinear samples per pixel (2 × 2), averaged.
    case on
}

/// Options of `PerspectiveCorrector`.
public struct PerspectiveOptions: Equatable, Sendable {
    /// The output size, when the caller knows it (both or neither); otherwise it comes from the quad.
    public var outputWidth: Int?
    public var outputHeight: Int?
    /// The longest output side; 0 for no limit of the caller's own (the output is still kept within
    /// `PerspectiveCorrector.maxPhotoDiagonals` of the photo and `PerspectiveCorrector.maxOutputSide`).
    public var maxLongSide: Int = 0
    /// A sheet's shape matches a known size within this share (`PerspectiveCorrector.paperAspectTolerance`).
    public var paperAspectTolerance: Double = PerspectiveCorrector.paperAspectTolerance
    /// Snap the shape to a known size when it matches.
    public var snapToPaper = true
    public var supersample: Supersampling = .auto
    /// The color of what lies outside the photo (opaque).
    public var fillR: UInt8 = 255
    public var fillG: UInt8 = 255
    public var fillB: UInt8 = 255

    public init() {}

    public static let `default` = PerspectiveOptions()
}

/// What `PerspectiveCorrector.plan` decided.
public struct PerspectivePlan: Equatable, Sendable {
    /// Output size in pixels.
    public var width: Int
    public var height: Int
    /// Maps an output point (continuous pixels) to the photo.
    public var outputToSource: Homography
    /// The shape used for the output.
    public var widthOverHeight: Double
    /// The known size the shape snapped to, if any.
    public var paper: PaperMatch?
    /// The resolution of the output when `paper` is known (output pixels per inch of that size);
    /// nil otherwise (callers use `PerspectiveCorrector.nominalDPI`).
    public var dpi: Double?
    /// Four samples per pixel are taken.
    public var supersampled: Bool
}

/// A page made upright (`PerspectiveCorrector.correct`).
public struct PerspectiveCorrection: Sendable {
    public let image: RgbaImage
    public let plan: PerspectivePlan
}

/// Turns the page a quad outlines in a photo into an upright rectangle: the homography from the
/// output rectangle to the quad, the output size from the quad (the longer of each pair of opposite
/// edges, so the nearer edge keeps its pixels) and the sheet's shape (a known paper size when it
/// matches, else the camera's view of the quad, else the edge lengths), then bilinear resampling,
/// with 2 × 2 supersampling when the page is made smaller. Twin of C# `PerspectiveCorrector`.
public enum PerspectiveCorrector {
    /// A shape matches a known size when the long-over-short ratios differ by at most this share (3 %).
    public static let paperAspectTolerance = 0.03
    /// The resolution taken for a page whose size is unknown.
    public static let nominalDPI = 200.0
    /// A focal length explains a quad only between these multiples of the photo's diagonal…
    public static let minFocalDiagonals = 0.3
    /// …and this many.
    public static let maxFocalDiagonals = 4.0
    /// Supersampling (auto) starts when an output pixel covers more than this many photo pixels across.
    public static let supersampleAbove = 1.25
    /// The output's long side is at most this many times the photo's diagonal (a corner dragged far
    /// outside the photo)…
    public static let maxPhotoDiagonals = 2.0
    /// …and at most this many pixels, so that any output's RGBA bytes fit in one array on both
    /// platforms (23170² × 4 is less than .NET's largest array); a size given by the caller beyond it
    /// has no plan.
    public static let maxOutputSide = 23170

    /// The sizes a camera page is matched against, in this order (the nearest wins).
    public static let matchedSizes: [PaperSize] = [.a4, .letter, .legal, .idCard]

    /// The shape of the flat rectangle seen as `quad` in a photo of `imageWidth` × `imageHeight`
    /// taken by a camera centered on the photo with square pixels (Zhang and He, "Whiteboard
    /// scanning and image enhancement", 2007). When the quad is seen straight on, or no focal length
    /// between `minFocalDiagonals` and `maxFocalDiagonals` diagonals explains it, the shape is the
    /// mean of the opposite edge lengths' ratio.
    public static func estimateAspect(_ quad: Quad, imageWidth: Double, imageHeight: Double) -> AspectEstimate {
        let cx = imageWidth / 2, cy = imageHeight / 2
        // m1 top-left, m2 top-right, m3 bottom-left, m4 bottom-right, centered, homogeneous.
        let m1x = Double(quad.topLeft.x) - cx, m1y = Double(quad.topLeft.y) - cy
        let m2x = Double(quad.topRight.x) - cx, m2y = Double(quad.topRight.y) - cy
        let m3x = Double(quad.bottomLeft.x) - cx, m3y = Double(quad.bottomLeft.y) - cy
        let m4x = Double(quad.bottomRight.x) - cx, m4y = Double(quad.bottomRight.y) - cy
        let top = quad.edgeLength(0), right = quad.edgeLength(1), bottom = quad.edgeLength(2), left = quad.edgeLength(3)
        let sides = (left + right) / 2
        let fallback = sides > 0 ? (top + bottom) / 2 / sides : 1

        let c14 = cross(m1x, m1y, 1, m4x, m4y, 1)
        let c24 = cross(m2x, m2y, 1, m4x, m4y, 1)
        let c34 = cross(m3x, m3y, 1, m4x, m4y, 1)
        let k2den = dot(c24, m3x, m3y, 1), k3den = dot(c34, m2x, m2y, 1)
        if k2den == 0 || k3den == 0 { return AspectEstimate(widthOverHeight: fallback, focalLength: nil) }
        let k2 = dot(c14, m3x, m3y, 1) / k2den
        let k3 = dot(c14, m2x, m2y, 1) / k3den
        let n2x = k2 * m2x - m1x, n2y = k2 * m2y - m1y, n2z = k2 - 1
        let n3x = k3 * m3x - m1x, n3y = k3 * m3y - m1y, n3z = k3 - 1
        let diagonal = (imageWidth * imageWidth + imageHeight * imageHeight).squareRoot()
        let zz = n2z * n3z
        // Seen straight on (opposite edges parallel), the camera's distance cannot be told.
        let scale = abs(n2x) + abs(n2y) + abs(n3x) + abs(n3y)
        if abs(n2z) * diagonal > 1e-3 * scale || abs(n3z) * diagonal > 1e-3 * scale {
            let f2 = -(n2x * n3x + n2y * n3y) / zz
            if zz != 0 && f2 > 0 && f2.isFinite {
                let f = f2.squareRoot()
                if f >= minFocalDiagonals * diagonal && f <= maxFocalDiagonals * diagonal {
                    let num = n2x * n2x + n2y * n2y + f2 * n2z * n2z
                    let den = n3x * n3x + n3y * n3y + f2 * n3z * n3z
                    if num > 0 && den > 0 {
                        return AspectEstimate(widthOverHeight: (num / den).squareRoot(), focalLength: f)
                    }
                }
            }
        }
        return AspectEstimate(widthOverHeight: fallback, focalLength: nil)
    }

    /// The known size (`matchedSizes`) whose long-over-short ratio is nearest to `longOverShort`,
    /// when within `tolerance` of it (as a share of the size's ratio); nil otherwise.
    public static func matchPaper(_ longOverShort: Double,
                                  tolerance: Double = PerspectiveCorrector.paperAspectTolerance) -> PaperMatch? {
        var best: PaperMatch?
        var bestDiff = Double.greatestFiniteMagnitude
        for size in matchedSizes {
            guard let inches = PaperSizes.inches(size) else { continue }
            let w = Double(inches.width), h = Double(inches.height)
            let ratio = max(w, h) / min(w, h)
            let diff = abs(longOverShort - ratio) / ratio
            if diff <= tolerance && diff < bestDiff {
                bestDiff = diff
                best = PaperMatch(size: size, longOverShort: ratio)
            }
        }
        return best
    }

    /// The output size, the map and the resolution for the page `quad` outlines in a photo of
    /// `imageWidth` × `imageHeight`. The long side taken from the quad is cut to
    /// `options.maxLongSide`, `maxPhotoDiagonals` of the photo's diagonal and `maxOutputSide`. nil for
    /// a quad that is not convex, a photo without pixels, or an output size given beyond `maxOutputSide`.
    public static func plan(_ quad: Quad, imageWidth: Int, imageHeight: Int,
                            options: PerspectiveOptions = .default) -> PerspectivePlan? {
        let o = options
        guard quad.isConvex, imageWidth > 0, imageHeight > 0 else { return nil }
        let top = quad.edgeLength(0), right = quad.edgeLength(1), bottom = quad.edgeLength(2), left = quad.edgeLength(3)
        let w0 = max(top, bottom), h0 = max(left, right)
        let estimate = estimateAspect(quad, imageWidth: Double(imageWidth), imageHeight: Double(imageHeight))
        var aspect = estimate.widthOverHeight
        let paper = o.snapToPaper ? matchPaper(estimate.longOverShort, tolerance: o.paperAspectTolerance) : nil
        if let paper = paper { aspect = aspect >= 1 ? paper.longOverShort : 1 / paper.longOverShort }

        let width: Int, height: Int
        if let fw = o.outputWidth, let fh = o.outputHeight, fw > 0, fh > 0 {
            width = fw
            height = fh
        } else {
            var longSide = max(w0, h0)
            if o.maxLongSide > 0 { longSide = min(longSide, Double(o.maxLongSide)) }
            let iw = Double(imageWidth), ih = Double(imageHeight)
            let photoDiagonal = (iw * iw + ih * ih).squareRoot()
            longSide = min(longSide, min(maxPhotoDiagonals * photoDiagonal, Double(maxOutputSide)))
            let wd: Double, hd: Double
            if aspect >= 1 {
                wd = longSide
                hd = longSide / aspect
            } else {
                hd = longSide
                wd = longSide * aspect
            }
            guard wd.isFinite, hd.isFinite else { return nil }
            width = max(1, Int((wd + 0.5).rounded(.down)))
            height = max(1, Int((hd + 0.5).rounded(.down)))
        }
        guard fitsOutput(width, height),
              let map = Homography.rectToQuad(width: Double(width), height: Double(height), quad: quad) else { return nil }

        var dpi: Double?
        if let paper = paper, let inches = PaperSizes.inches(paper.size) {
            dpi = Double(max(width, height)) / max(Double(inches.width), Double(inches.height))
        }
        let supersample: Bool
        switch o.supersample {
        case .on: supersample = true
        case .off: supersample = false
        case .auto: supersample = w0 > Double(width) * supersampleAbove || h0 > Double(height) * supersampleAbove
        }
        return PerspectivePlan(width: width, height: height, outputToSource: map,
                               widthOverHeight: Double(width) / Double(height), paper: paper, dpi: dpi,
                               supersampled: supersample)
    }

    /// `image` resampled as `plan` says.
    public static func warp(_ image: RgbaImage, plan: PerspectivePlan, options: PerspectiveOptions = .default) -> RgbaImage {
        let w = plan.width, h = plan.height
        precondition(fitsOutput(w, h), "A \(w) × \(h) output is not possible.")
        var output = [UInt8](repeating: 0, count: w * h * 4)
        let m = plan.outputToSource
        image.pixels.withUnsafeBufferPointer { pixels in
            for oy in 0..<h {
                for ox in 0..<w {
                    let di = (oy * w + ox) * 4
                    var acc: (Double, Double, Double, Double) = (0, 0, 0, 0)
                    if plan.supersampled {
                        for s in 0..<4 {
                            let px = Double(ox) + ((s & 1) == 0 ? 0.25 : 0.75)
                            let py = Double(oy) + ((s >> 1) == 0 ? 0.25 : 0.75)
                            accumulate(pixels, image.width, image.height, m, px, py, &acc, options)
                        }
                        output[di] = roundByte(acc.0 / 4)
                        output[di + 1] = roundByte(acc.1 / 4)
                        output[di + 2] = roundByte(acc.2 / 4)
                        output[di + 3] = roundByte(acc.3 / 4)
                    } else {
                        accumulate(pixels, image.width, image.height, m, Double(ox) + 0.5, Double(oy) + 0.5, &acc, options)
                        output[di] = roundByte(acc.0)
                        output[di + 1] = roundByte(acc.1)
                        output[di + 2] = roundByte(acc.2)
                        output[di + 3] = roundByte(acc.3)
                    }
                }
            }
        }
        return RgbaImage(width: w, height: h, pixels: output)
    }

    /// The page `quad` outlines, upright; nil for a quad that is not convex.
    public static func correct(_ image: RgbaImage, quad: Quad, options: PerspectiveOptions = .default) -> PerspectiveCorrection? {
        guard let decided = PerspectiveCorrector.plan(quad, imageWidth: image.width, imageHeight: image.height,
                                                      options: options) else { return nil }
        return PerspectiveCorrection(image: warp(image, plan: decided, options: options), plan: decided)
    }

    /// Adds the bilinear sample of the photo at output point (px, py) (continuous) to acc: pixel
    /// centers at i + 0.5, outside the photo the fill color.
    private static func accumulate(_ pixels: UnsafeBufferPointer<UInt8>, _ iw: Int, _ ih: Int, _ m: Homography,
                                   _ px: Double, _ py: Double, _ acc: inout (Double, Double, Double, Double),
                                   _ o: PerspectiveOptions) {
        let w = m.m20 * px + m.m21 * py + m.m22
        let sx = (m.m00 * px + m.m01 * py + m.m02) / w - 0.5
        let sy = (m.m10 * px + m.m11 * py + m.m12) / w - 0.5
        if !sx.isFinite || !sy.isFinite || sx < -2 || sy < -2 || sx > Double(iw) + 1 || sy > Double(ih) + 1 {
            acc.0 += Double(o.fillR)
            acc.1 += Double(o.fillG)
            acc.2 += Double(o.fillB)
            acc.3 += 255
            return
        }
        let fx0 = sx.rounded(.down), fy0 = sy.rounded(.down)
        let x0 = Int(fx0), y0 = Int(fy0)
        let fx = sx - fx0, fy = sy - fy0
        for corner in 0..<4 {
            let cx = x0 + (corner & 1), cy = y0 + (corner >> 1)
            let weight = ((corner & 1) == 0 ? 1 - fx : fx) * ((corner >> 1) == 0 ? 1 - fy : fy)
            if weight == 0 { continue }
            if cx >= 0 && cx < iw && cy >= 0 && cy < ih {
                let si = (cy * iw + cx) * 4
                acc.0 += weight * Double(pixels[si])
                acc.1 += weight * Double(pixels[si + 1])
                acc.2 += weight * Double(pixels[si + 2])
                acc.3 += weight * Double(pixels[si + 3])
            } else {
                acc.0 += weight * Double(o.fillR)
                acc.1 += weight * Double(o.fillG)
                acc.2 += weight * Double(o.fillB)
                acc.3 += weight * 255
            }
        }
    }

    /// An output of `width` × `height` can be made: both sides 1 to `maxOutputSide`.
    private static func fitsOutput(_ width: Int, _ height: Int) -> Bool {
        width >= 1 && height >= 1 && width <= maxOutputSide && height <= maxOutputSide
    }

    /// Rounded to the nearest byte, halves to even (as `RgbaImage`'s sampler), clamped.
    private static func roundByte(_ value: Double) -> UInt8 {
        UInt8(min(255, max(0, value.rounded(.toNearestOrEven))))
    }

    private static func cross(_ ax: Double, _ ay: Double, _ az: Double,
                              _ bx: Double, _ by: Double, _ bz: Double) -> (x: Double, y: Double, z: Double) {
        (ay * bz - az * by, az * bx - ax * bz, ax * by - ay * bx)
    }

    private static func dot(_ a: (x: Double, y: Double, z: Double), _ bx: Double, _ by: Double, _ bz: Double) -> Double {
        a.x * bx + a.y * by + a.z * bz
    }
}
