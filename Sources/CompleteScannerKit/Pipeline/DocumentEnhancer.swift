import CoreGraphics
import Foundation

/// How a page taken by a camera is cleaned up (`DocumentEnhancer`). Twin of C# `DocumentEnhanceMode`.
public enum DocumentEnhanceMode: String, CaseIterable, Codable, Sendable {
    /// As `.color`, then gray when the page has no color left (`ColorAnalysis.isEffectivelyGray`).
    case auto
    /// The lighting evened out, the paper made white and neutral, the print stretched to black, in color.
    case color
    /// As `.color`, in gray.
    case gray
    /// The gray page thresholded: black print on white paper, every pixel 0 or 255.
    case blackAndWhite
    /// A photo: its levels stretched as a whole, nothing evened out.
    case photo
}

/// A page cleaned up: its pixels and the mode applied (`.auto` resolved to color or gray). Twin of C#
/// `DocumentEnhancement`.
public struct DocumentEnhancement: Sendable {
    public let image: RgbaImage
    public let mode: DocumentEnhanceMode

    public init(image: RgbaImage, mode: DocumentEnhanceMode) {
        self.image = image
        self.mode = mode
    }
}

/// The paper's color as gains per channel: a channel times its gain is the paper's luma. Twin of C#
/// `PaperWhiteBalance`.
public struct PaperWhiteBalance: Equatable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double

    public init(r: Double, g: Double, b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    public static let neutral = PaperWhiteBalance(r: 1, g: 1, b: 1)
}

/// Cleans up a page taken by a camera, after it was cut out of its photo: the lighting evened out, so a
/// shadow across the sheet or a lamp's falloff leaves the paper one white, the paper's tint taken out, and
/// the print stretched to black. How bright the paper is everywhere is estimated in large tiles
/// (`tileSize`: about a sixteenth of the page's long side), each tile's paper the `backgroundPercentile`
/// of its luma (`BackgroundMap`), tiles much darker than the paper beside them (a picture, a black bar)
/// filled in from it (`BackgroundMap.raisedDarkTiles` at `darkTileShare`; a dark region that reaches the
/// page's edge is a shadow cast across it and is evened out instead), every tile at least
/// `minBackgroundShare` of the median tile and `minBackground`, and interpolated between tile centers.
/// Each pixel is then divided by the paper there, as a level of `levels`: its luma for gray, each channel
/// times the paper's white balance (`whiteBalance`: the paper's mean luma over each channel's mean, over
/// the pixels at least `paperShare` of the paper there, within `minGain`...`maxGain`) for color, at most 1.
/// The levels are stretched linearly: `whitePoint` and above becomes white, the black point (the
/// `blackPercentile` of the sampled luma levels, at most `maxBlackPoint`) and below black. Black and white
/// thresholds the gray result at `Bilevel.threshold`; since the levels are against the paper where each
/// pixel is, the threshold follows the lighting, and print in a shadow stays black. Photos are only
/// stretched as a whole (`.photo`). A page whose ground is dark with light print on it (a chalkboard, a
/// dark flyer, a slide: `isLightOnDark`) has no paper to even out against, so it is stretched as a whole
/// like a photo and then made gray or black and white as the mode says. The samples (white balance, black
/// point, light on dark) are every `sampleStep`-th pixel of every `sampleStep`-th row. Pure arithmetic in a
/// fixed order: the same bytes as the C# twin (`windows/CompleteScanner.Core/DocumentEnhancer.cs`).
public enum DocumentEnhancer {
    /// The paper is estimated in tiles of about the long side over this.
    public static let tilesAlongLongSide: Int = 16
    /// The smallest tile, in pixels.
    public static let minTileSize: Int = 8
    /// A tile's paper is this percentile of its luma (the paper between the print).
    public static let backgroundPercentile: Double = 0.9
    /// A tile darker than this share of its brightest neighbor is no paper and is filled from it.
    public static let darkTileShare: Double = 0.7
    /// Every tile is at least this share of the median tile…
    public static let minBackgroundShare: Double = 0.4
    /// …and at least this luma, so a dark area is not blown up.
    public static let minBackground: Int = 32
    /// A pixel at least this share of the paper there counts as paper for the white balance.
    public static let paperShare: Double = 0.9
    /// The white balance's gains are kept within minGain...maxGain.
    public static let minGain: Double = 0.625
    public static let maxGain: Double = 1.6
    /// Levels at or above this share of the paper become white.
    public static let whitePoint: Double = 0.9
    /// The share of the sampled levels taken as the darkest print.
    public static let blackPercentile: Double = 0.005
    /// The black point is at most this level, so a page with little print is not stretched into noise.
    public static let maxBlackPoint: Double = 0.5
    /// The steps a level is counted in.
    public static let levels: Int = 1024
    /// The samples are every sampleStep-th pixel of every sampleStep-th row.
    public static let sampleStep: Int = 2
    /// A photo's levels are stretched from this share of its pixels at the dark end to as many at the
    /// bright end…
    public static let photoClip: Double = 0.005
    /// …when those two lumas are at least this far apart; a flatter photo is left as it is.
    public static let minPhotoRange: Int = 64
    /// The ground of a page, to tell light print on a dark ground, is this percentile of each tile's luma.
    public static let groundPercentile: Double = 0.5
    /// A pixel this many times as bright as the ground there is light print; this many times darker, dark print.
    public static let lightContrast: Double = 1.5
    /// A page is light on dark only with at least this share of the samples light print.
    public static let minLightShare: Double = 0.005

    /// The mode for the pages of a task with `settings`: `.photo` for photo tasks; else by the color mode:
    /// gray, black and white, or `.auto` for color (color where the page has color). Twin of C#
    /// `DocumentEnhancer.ModeFor(ScanSettings)`.
    public static func mode(for settings: ScanSettings) -> DocumentEnhanceMode {
        if settings.intent == .photo { return .photo }
        switch settings.colorMode {
        case .grayscale:
            return .gray
        case .blackWhite:
            return .blackAndWhite
        case .color:
            return .auto
        }
    }

    /// `mode` for a shot of `kind`: a photo print or an ID card is a photo, never evened out. Twin of C#
    /// `DocumentEnhancer.ModeFor(DocumentEnhanceMode, CaptureKind)`.
    public static func mode(_ mode: DocumentEnhanceMode, kind: CaptureKind) -> DocumentEnhanceMode {
        if kind == .photo || kind == .idCard { return .photo }
        return mode
    }

    /// The tile the paper is estimated in, for a page of `width` × `height`.
    public static func tileSize(width: Int, height: Int) -> Int {
        max(minTileSize, max(width, height) / tilesAlongLongSide)
    }

    /// How bright the paper is across `gray` (see the type); nil only for an image without pixels.
    public static func paperMap(_ gray: GrayImage) -> BackgroundMap? {
        let size: Int = tileSize(width: gray.width, height: gray.height)
        guard let raw = BackgroundMap.estimate(gray, x: 0, y: 0, width: gray.width, height: gray.height,
                                               tileSize: size, percentile: backgroundPercentile) else { return nil }
        let filled: BackgroundMap = raw.raisedDarkTiles(share: darkTileShare)
        let median: Double = Double(filled.medianTile())
        let floorValue: Int = max(minBackground, Int(floor(median * minBackgroundShare)))
        return filled.clampedBelow(UInt8(min(255, floorValue)))
    }

    /// Whether `gray` is light print on a dark ground (a chalkboard, a dark flyer with white text, a slide),
    /// whose ground no division by the paper can make white: the ground is the `groundPercentile` of each
    /// tile (`BackgroundMap`, tiles as for the paper). A sampled pixel at least `lightContrast` times the
    /// brightest ground of its tile and the eight around it (`BackgroundMap.maxSmoothed`, interpolated, at
    /// least `minBackground`) is light print; one at most the darkest of them (`BackgroundMap.minSmoothed`,
    /// at least `minBackground`) over `lightContrast` dark print. So the paper beside a hard step (the edge
    /// of a shadow, a dark picture), which is the ground of a tile next to it, counts as neither. Light on
    /// dark when there is more light print than dark, and at least `minLightShare` of the samples. Twin of
    /// C# `DocumentEnhancer.IsLightOnDark`.
    public static func isLightOnDark(_ gray: GrayImage) -> Bool {
        let w: Int = gray.width
        let h: Int = gray.height
        let size: Int = tileSize(width: w, height: h)
        guard let ground = BackgroundMap.estimate(gray, x: 0, y: 0, width: w, height: h, tileSize: size,
                                                  percentile: groundPercentile) else { return false }
        let highest: BackgroundMap = ground.maxSmoothed()
        let lowest: BackgroundMap = ground.minSmoothed()
        let lumas: [UInt8] = gray.pixels
        var light: Int = 0
        var dark: Int = 0
        var samples: Int = 0
        var y: Int = 0
        while y < h {
            var x: Int = 0
            while x < w {
                let luma: Double = Double(lumas[y * w + x])
                let above: Double = max(highest.valueAt(x: x, y: y), Double(minBackground))
                let below: Double = max(lowest.valueAt(x: x, y: y), Double(minBackground))
                if luma >= above * lightContrast {
                    light += 1
                } else if luma * lightContrast <= below {
                    dark += 1
                }
                samples += 1
                x += sampleStep
            }
            y += sampleStep
        }
        return light > dark && Double(light) >= minLightShare * Double(samples)
    }

    /// The paper's white balance: over the sampled pixels at least `paperShare` of the paper there, each
    /// channel's gain is the luma's sum over that channel's sum, within `minGain`...`maxGain`; neutral when
    /// no paper is seen.
    public static func whiteBalance(_ image: RgbaImage, gray: GrayImage, paper: BackgroundMap) -> PaperWhiteBalance {
        let w: Int = image.width
        let h: Int = image.height
        let src: [UInt8] = image.pixels
        let lumas: [UInt8] = gray.pixels
        var sumR: Int = 0
        var sumG: Int = 0
        var sumB: Int = 0
        var sumL: Int = 0
        var y: Int = 0
        while y < h {
            var x: Int = 0
            while x < w {
                let p: Int = y * w + x
                let luma: Int = Int(lumas[p])
                let background: Double = paper.valueAt(x: x, y: y)
                if Double(luma) >= background * paperShare {
                    sumR += Int(src[p * 4])
                    sumG += Int(src[p * 4 + 1])
                    sumB += Int(src[p * 4 + 2])
                    sumL += luma
                }
                x += sampleStep
            }
            y += sampleStep
        }
        if sumL == 0 || sumR == 0 || sumG == 0 || sumB == 0 { return PaperWhiteBalance.neutral }
        return PaperWhiteBalance(r: gain(sumL, sumR), g: gain(sumL, sumG), b: gain(sumL, sumB))
    }

    /// The black point: the `blackPercentile` of the sampled pixels' luma levels against the paper there,
    /// at most `maxBlackPoint`.
    public static func blackPoint(_ gray: GrayImage, paper: BackgroundMap) -> Double {
        let w: Int = gray.width
        let h: Int = gray.height
        let lumas: [UInt8] = gray.pixels
        var histogram: [Int] = [Int](repeating: 0, count: levels + 1)
        var samples: Int = 0
        var y: Int = 0
        while y < h {
            var x: Int = 0
            while x < w {
                let k: Int = level(Double(lumas[y * w + x]), paper.valueAt(x: x, y: y))
                histogram[k] += 1
                samples += 1
                x += sampleStep
            }
            y += sampleStep
        }
        let darkest: Int = percentile(histogram, count: samples, fraction: blackPercentile)
        return min(Double(darkest) / Double(levels), maxBlackPoint)
    }

    /// `image` cleaned up as `mode` says (see the type).
    public static func enhance(_ image: RgbaImage, mode: DocumentEnhanceMode) -> DocumentEnhancement {
        if mode == .photo {
            return DocumentEnhancement(image: photo(image), mode: .photo)
        }
        let w: Int = image.width
        let h: Int = image.height
        let gray: GrayImage = GrayImage.luma(image)
        if isLightOnDark(gray) {
            return lightOnDark(image, mode: mode)
        }
        guard let paper = paperMap(gray) else {
            let resolved: DocumentEnhanceMode = mode == .auto ? DocumentEnhanceMode.color : mode
            return DocumentEnhancement(image: image, mode: resolved)
        }
        let lut: [UInt8] = stretch(blackPoint(gray, paper: paper), whitePoint)
        let color: Bool = mode == .auto || mode == .color
        var balance: PaperWhiteBalance = PaperWhiteBalance.neutral
        if color {
            balance = whiteBalance(image, gray: gray, paper: paper)
        }
        let src: [UInt8] = image.pixels
        let lumas: [UInt8] = gray.pixels
        let threshold: Int = Bilevel.threshold
        var output: [UInt8] = [UInt8](repeating: 0, count: w * h * 4)
        var y: Int = 0
        while y < h {
            var x: Int = 0
            while x < w {
                let p: Int = y * w + x
                let i: Int = p * 4
                let background: Double = paper.valueAt(x: x, y: y)
                if color {
                    output[i] = lut[level(Double(src[i]) * balance.r, background)]
                    output[i + 1] = lut[level(Double(src[i + 1]) * balance.g, background)]
                    output[i + 2] = lut[level(Double(src[i + 2]) * balance.b, background)]
                } else {
                    var v: UInt8 = lut[level(Double(lumas[p]), background)]
                    if mode == .blackAndWhite {
                        v = Int(v) < threshold ? 0 : 255
                    }
                    output[i] = v
                    output[i + 1] = v
                    output[i + 2] = v
                }
                output[i + 3] = 255
                x += 1
            }
            y += 1
        }
        if mode == .auto {
            if !ColorAnalysis.isEffectivelyGray(rgba: output, width: w, height: h) {
                return DocumentEnhancement(image: RgbaImage(width: w, height: h, pixels: output), mode: .color)
            }
            // No color left: the gray page, as the gray mode makes it.
            y = 0
            while y < h {
                var x: Int = 0
                while x < w {
                    let p: Int = y * w + x
                    let i: Int = p * 4
                    let v: UInt8 = lut[level(Double(lumas[p]), paper.valueAt(x: x, y: y))]
                    output[i] = v
                    output[i + 1] = v
                    output[i + 2] = v
                    x += 1
                }
                y += 1
            }
            return DocumentEnhancement(image: RgbaImage(width: w, height: h, pixels: output), mode: .gray)
        }
        return DocumentEnhancement(image: RgbaImage(width: w, height: h, pixels: output), mode: mode)
    }

    /// A light on dark page (`isLightOnDark`) in `mode`: stretched as a whole (`photo`), in color for `.color`
    /// and for `.auto` where it has color; else its luma, thresholded at `Bilevel.threshold` for
    /// `.blackAndWhite`.
    private static func lightOnDark(_ image: RgbaImage, mode: DocumentEnhanceMode) -> DocumentEnhancement {
        let stretched: RgbaImage = photo(image)
        let w: Int = stretched.width
        let h: Int = stretched.height
        if mode == .color {
            return DocumentEnhancement(image: stretched, mode: .color)
        }
        if mode == .auto && !ColorAnalysis.isEffectivelyGray(rgba: stretched.pixels, width: w, height: h) {
            return DocumentEnhancement(image: stretched, mode: .color)
        }
        let lumas: [UInt8] = GrayImage.luma(stretched).pixels
        let threshold: Int = Bilevel.threshold
        var output: [UInt8] = [UInt8](repeating: 0, count: w * h * 4)
        var p: Int = 0
        while p < w * h {
            var v: UInt8 = lumas[p]
            if mode == .blackAndWhite {
                v = Int(v) < threshold ? 0 : 255
            }
            output[p * 4] = v
            output[p * 4 + 1] = v
            output[p * 4 + 2] = v
            output[p * 4 + 3] = 255
            p += 1
        }
        let applied: DocumentEnhanceMode = mode == .auto ? .gray : mode
        return DocumentEnhancement(image: RgbaImage(width: w, height: h, pixels: output), mode: applied)
    }

    /// A photo's levels stretched as a whole, the same for each channel: the `photoClip` and 1 − `photoClip`
    /// percentiles of its luma become 0 and 255; a photo whose two are less than `minPhotoRange` apart is
    /// returned as it is.
    public static func photo(_ image: RgbaImage) -> RgbaImage {
        let gray: GrayImage = GrayImage.luma(image)
        var histogram: [Int] = [Int](repeating: 0, count: 256)
        for value in gray.pixels {
            histogram[Int(value)] += 1
        }
        let count: Int = image.width * image.height
        let lo: Int = Int(BackgroundMap.percentile(histogram, count: count, fraction: photoClip))
        let hi: Int = Int(BackgroundMap.percentile(histogram, count: count, fraction: 1 - photoClip))
        if hi - lo < minPhotoRange { return image }
        var lut: [UInt8] = [UInt8](repeating: 0, count: 256)
        var index: Int = 0
        while index < 256 {
            let stretched: Double = floor(Double(index - lo) * 255.0 / Double(hi - lo) + 0.5)
            lut[index] = UInt8(min(max(stretched, 0), 255))
            index += 1
        }
        let src: [UInt8] = image.pixels
        var output: [UInt8] = [UInt8](repeating: 0, count: src.count)
        var i: Int = 0
        while i < src.count {
            output[i] = lut[Int(src[i])]
            output[i + 1] = lut[Int(src[i + 1])]
            output[i + 2] = lut[Int(src[i + 2])]
            output[i + 3] = src[i + 3]
            i += 4
        }
        return RgbaImage(width: image.width, height: image.height, pixels: output)
    }

    /// `value` against the paper's `background`, as a level 0...`levels` (at most the paper's own).
    public static func level(_ value: Double, _ background: Double) -> Int {
        let share: Double = min(1.0, value / background)
        return Int(floor(share * Double(levels) + 0.5))
    }

    /// The levels 0...`levels` stretched linearly from `lo` (black) to `hi` (white).
    public static func stretch(_ lo: Double, _ hi: Double) -> [UInt8] {
        var lut: [UInt8] = [UInt8](repeating: 0, count: levels + 1)
        var k: Int = 0
        while k <= levels {
            let raw: Double = (Double(k) / Double(levels) - lo) / (hi - lo)
            let v: Double = min(max(raw, 0), 1)
            lut[k] = UInt8(floor(v * 255 + 0.5))
            k += 1
        }
        return lut
    }

    private static func gain(_ luma: Int, _ channel: Int) -> Double {
        min(max(Double(luma) / Double(channel), minGain), maxGain)
    }

    /// The smallest level with at least ⌈fraction × count⌉ values at or below it.
    private static func percentile(_ histogram: [Int], count: Int, fraction: Double) -> Int {
        let rank: Int = min(max(Int((fraction * Double(count)).rounded(.up)), 1), max(1, count))
        var seen: Int = 0
        var k: Int = 0
        while k < histogram.count {
            seen += histogram[k]
            if seen >= rank { return k }
            k += 1
        }
        return histogram.count - 1
    }
}
