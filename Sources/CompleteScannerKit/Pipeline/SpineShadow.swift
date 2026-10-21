import Foundation

// Twin of windows/CompleteScanner.Core/SpineShadow.cs: same constants, same steps and the same
// arithmetic (no library functions beyond + − × ÷), so a page gives the same bytes on both platforms.

/// An edge of a page. Twin of C# `PageEdge`; the order is the clockwise order (`SpineShadow.turned`).
public enum PageEdge: Int, Sendable {
    case left, top, right, bottom
}

/// What softening the spine's shadow did to a page (`ScannedPage.spineShadow`; in memory only). Twin of
/// C# `SpineShadowResult`.
public struct SpineShadowResult: Equatable, Sendable {
    /// The page's edge along the spine.
    public var edge: PageEdge
    /// How much the shadow darkened the paper where it was deepest, 0...1 (0.3: to 70 %).
    public var depth: Double
    /// How far from the edge the shadow reached.
    public var widthInches: Double
    /// The most any pixel was brightened by (a factor, at most `SpineShadow.maxGain`).
    public var maxGain: Double
    /// The share of the band along the spine left as it was because it holds a picture.
    public var protectedFraction: Double

    public init(edge: PageEdge, depth: Double, widthInches: Double, maxGain: Double, protectedFraction: Double) {
        self.edge = edge
        self.depth = depth
        self.widthInches = widthInches
        self.maxGain = maxGain
        self.protectedFraction = protectedFraction
    }
}

/// The spine's shadow measured on a page's gray copy (`SpineShadow.estimate`): the gain of every analysis
/// pixel of the band along the edge, in the band's own frame: row v runs along the edge (from the left or
/// top end of the page), column u away from it (0 at the edge). Twin of C# `SpineShadowModel`.
public struct SpineShadowModel: Sendable {
    /// The page's edge along the spine.
    public let edge: PageEdge
    /// Analysis pixels from the edge to the far side of the page (the page's width or height).
    public let extent: Int
    /// Analysis pixels along the edge.
    public let length: Int
    /// Analysis pixels from the edge the band reaches; every pixel beyond keeps its value.
    public let band: Int
    /// The factor each band pixel is brightened by (1 or more): `length` rows of `band`.
    public let gains: [Double]
    /// 1 where the band holds a picture (left as it is), 0 elsewhere: `length` rows of `band`.
    public let pictures: [UInt8]
    /// What was found, for the page.
    public let result: SpineShadowResult

    public init(edge: PageEdge, extent: Int, length: Int, band: Int, gains: [Double], pictures: [UInt8],
                result: SpineShadowResult) {
        self.edge = edge
        self.extent = extent
        self.length = length
        self.band = band
        self.gains = gains
        self.pictures = pictures
        self.result = result
    }
}

/// A page with its spine's shadow softened, and what was done. Twin of C# `SpineShadowCorrection`.
public struct SpineShadowCorrection: Sendable {
    public let image: RgbaImage
    public let result: SpineShadowResult

    public init(image: RgbaImage, result: SpineShadowResult) {
        self.image = image
        self.result = result
    }
}

/// Softens the shadow along the spine on a page cut from a book or magazine spread. The shadow is measured
/// from the paper itself, on a gray copy at the analysis resolution: in blocks of rows along the spine, the
/// paper's brightness at every distance from the edge (a high percentile, so the paper between the text
/// counts and not the ink), divided by the paper's brightness past the shadow. A block whose paper does not
/// look like the shadow of its neighbours (a picture, a tint, the scanner lid) takes the shadow of the blocks
/// beside it; the shadow is smoothed across rows and along the edge. Every pixel is then divided by the
/// shadow there, with a cap: paper comes back to white, and ink keeps its share of the paper's brightness,
/// so text keeps its contrast. Pictures beside the spine (large dark or mid-tone areas, not the thin strokes
/// of text) are left as they are, with a soft border. Page curvature is not corrected. Twin of C# `SpineShadow`.
public enum SpineShadow {
    /// The band along the edge the shadow is looked for in, at most this many inches wide…
    public static let bandInches = 1.5
    /// …and at most half the page.
    public static let maxBandFraction = 0.5
    /// A page whose band would be narrower than this many inches is left alone.
    public static let minBandInches = 0.25
    /// The paper's own brightness is read on this many inches just past the band.
    public static let referenceInches = 0.4
    /// The rows along the edge are measured in blocks this many inches long…
    public static let blockInches = 0.3
    /// …and at least this many pixels.
    public static let minBlockRows = 4
    /// The paper's brightness in a cell (3 columns of a block): this share of its pixels are darker.
    public static let paperPercentile = 0.9
    /// A page whose paper is darker than this gray level is left alone.
    public static let minPaper = 96
    /// A block whose paper differs from the page's by more than this share takes the page's.
    public static let paperTolerance = 0.1
    /// A block shows the spine's shadow when its paper is darker near the edge (by `minDepth`, within
    /// `maxDeepestInches`) and back to within this share of the paper over the last quarter of the band…
    public static let fadeTolerance = 0.05
    /// …and at least this share of the blocks along the edge, and `minShadowedBlocks`, show it (a book can
    /// cover only part of the glass; the rest is the lid).
    public static let minShadowedShare = 0.3
    /// The fewest blocks that must show the shadow.
    public static let minShadowedBlocks = 2
    /// A cell is shadowed paper when it is within this share of the paper's brightness of the shadow those
    /// blocks agree on (their median)…
    public static let consensusTolerance = 0.05
    /// …plus this share of the shadow's depth there (shadows are deeper at one end of the spine than the other).
    public static let consensusSpread = 0.4
    /// The shadow is softened when it darkens the paper by at least this share…
    public static let minDepth = 0.04
    /// …it is deepest within this many inches of the edge (a spine's shadow fades away from the spine), and
    /// it has faded before the end of the band (something dark all across the band is no shadow).
    public static let maxDeepestInches = 0.25
    /// Paper darkened by less than this share is left alone (noise, the last trace of the shadow).
    public static let deadZone = 0.02
    /// A shadow fades gradually: from a quarter of the way back to the paper to within `deadZone` of it takes
    /// at least this many inches (a tint or a bar printed along the spine comes back in a step).
    public static let minFadeInches = 0.04
    /// No pixel is brightened more than this many times (the fold itself can be nearly black).
    public static let maxGain = 2.5
    /// The gain eases to none over the last this many inches of the band.
    public static let taperInches = 0.2
    /// A pixel darker than this share of the shadowed paper there may be part of a picture…
    public static let pictureLevel = 0.85
    /// …once thin strokes (text, lines) are taken away: the mask is opened with this many inches…
    public static let openInches = 0.02
    /// …the parts of a picture split by its light areas are joined across this many inches…
    public static let closeInches = 0.05
    /// …and a picture covers at least a square this many inches on a side; its box is left alone.
    public static let minPictureInches = 0.3
    /// Beyond a picture's box, the gain fades in over twice this many inches.
    public static let featherInches = 0.03

    /// The edge of a page cut from a spread that ran along the spine: the edge of the cut (the right edge of
    /// a left page, the bottom edge of a top page…), turned with the page by the book's rotation
    /// (`rotationQuarterTurns` clockwise). nil for a page not cut from a spread, or a whole one.
    public static func gutterEdge(_ spread: SpreadPart?, rotationQuarterTurns: Int) -> PageEdge? {
        guard let spread, let part = spread.part, let gutter = spread.gutter else { return nil }
        let edge: PageEdge
        if gutter.axis == .vertical {
            edge = part == 0 ? .right : .left
        } else {
            edge = part == 0 ? .bottom : .top
        }
        return turned(edge, quarterTurns: rotationQuarterTurns)
    }

    /// Where `edge` lies once the page is turned `quarterTurns` clockwise.
    public static func turned(_ edge: PageEdge, quarterTurns: Int) -> PageEdge {
        PageEdge(rawValue: (edge.rawValue + BookSplitter.normalizedTurns(quarterTurns)) % 4) ?? edge
    }

    /// The tooltip of "Soften spine shadow", on (`on`) or off: what it does.
    public static func hint(_ on: Bool) -> String {
        "Lightens the dark band along the spine"
    }

    /// `image` (scanned at `dpi`) with the shadow along `edge` softened, and what was done; nil when there
    /// is no shadow to soften (or the page is too small or dark).
    public static func soften(_ image: RgbaImage, dpi: Int, edge: PageEdge) -> SpineShadowCorrection? {
        let gray = GrayImage.from(image, sourceDPI: dpi)
        guard let model = estimate(gray, edge: edge) else { return nil }
        return SpineShadowCorrection(image: apply(image, model: model), result: model.result)
    }

    /// The shadow along `edge` of `gray` (a page's gray copy, at most the analysis resolution), as the gain
    /// of every pixel of the band along it; nil when the paper there is not darkened by at least `minDepth`,
    /// or the page is too small or too dark.
    public static func estimate(_ gray: GrayImage, edge: PageEdge) -> SpineShadowModel? {
        let dpi = gray.dpi
        let alongX = edge == .left || edge == .right
        let extent = alongX ? gray.width : gray.height
        let length = alongX ? gray.height : gray.width
        let band = min(pixels(bandInches, dpi), Int(Double(extent) * maxBandFraction))
        let reference = min(pixels(referenceInches, dpi), extent - band)
        guard band >= pixels(minBandInches, dpi), reference >= 1 else { return nil }
        let span = band + reference
        let strip = oriented(gray, edge: edge, span: span)
        let blockRows = max(minBlockRows, pixels(blockInches, dpi))
        let blocks = max(1, length / blockRows)

        // The paper's brightness in every cell: a block of rows, three columns.
        var level = [Double](repeating: 0, count: blocks * span)
        var histogram = [Int](repeating: 0, count: 256)
        for j in 0..<blocks {
            let r0 = j * length / blocks, r1 = (j + 1) * length / blocks
            for u in 0..<span {
                for k in 0..<256 { histogram[k] = 0 }
                let c0 = max(0, u - 1), c1 = min(span - 1, u + 1)
                for r in r0..<r1 {
                    let row = r * span
                    for c in c0...c1 { histogram[Int(strip[row + c])] += 1 }
                }
                level[j * span + u] = Double(BackgroundMap.percentile(histogram, count: (r1 - r0) * (c1 - c0 + 1),
                                                                      fraction: paperPercentile))
            }
        }

        // The paper of each block, past the shadow: the upper quartile of the reference stretch. A block
        // whose reference is no paper (a picture, the lid) takes the page's.
        var paper = [Double](repeating: 0, count: blocks)
        for j in 0..<blocks {
            let stretch = level[(j * span + band)..<(j * span + span)].sorted()
            paper[j] = stretch[reference * 3 / 4]
        }
        let pagePaper = paper.sorted()[blocks / 2]
        guard pagePaper >= Double(minPaper) else { return nil }
        for j in 0..<blocks where paper[j] < pagePaper * (1 - paperTolerance) || paper[j] > pagePaper * (1 + paperTolerance) {
            paper[j] = pagePaper
        }
        paper = runningMedian(paper, radius: 2)

        // How much of the paper's light is left in each cell.
        var share = [Double](repeating: 0, count: blocks * band)
        for j in 0..<blocks {
            for u in 0..<band { share[j * band + u] = min(1.0, level[j * span + u] / paper[j]) }
        }
        // The blocks that show the spine's shadow: darker near the edge, paper again at the far side of the
        // band (not a picture or a tint running across it, not the lid beside the book). The shadow they
        // agree on is their median.
        let near = min(band, pixels(maxDeepestInches, dpi)), fadeFrom = band - band / 4
        var shadowed: [Int] = []
        for j in 0..<blocks {
            var darkest = 1.0
            for u in 0..<near { darkest = min(darkest, share[j * band + u]) }
            var faded = true
            for u in fadeFrom..<band where share[j * band + u] < 1 - fadeTolerance { faded = false }
            if 1 - darkest >= minDepth && faded { shadowed.append(j) }
        }
        let needed = max(minShadowedBlocks, Int((Double(blocks) * minShadowedShare).rounded(.up)))
        guard shadowed.count >= needed else { return nil }
        var consensus = [Double](repeating: 0, count: band)
        var column = [Double](repeating: 0, count: shadowed.count)
        for u in 0..<band {
            for k in 0..<shadowed.count { column[k] = share[shadowed[k] * band + u] }
            column.sort()
            consensus[u] = column[shadowed.count / 2]
        }
        let profile = smoothed(consensus)
        var deepest = 1.0
        var deepestAt = 0, reach = 0
        for u in 0..<band {
            if profile[u] < deepest {
                deepest = profile[u]
                deepestAt = u
            }
            if profile[u] < 1 - deadZone { reach = u + 1 }
        }
        let depth = 1 - deepest
        guard depth >= minDepth, deepestAt < pixels(maxDeepestInches, dpi), reach < band else { return nil }
        // A shadow fades gradually; a tint or a bar printed all along the spine comes back to the paper in a
        // step, and is no shadow.
        var quarterBack = reach
        for u in deepestAt..<reach where profile[u] >= deepest + depth / 4 {
            quarterBack = u
            break
        }
        guard reach - quarterBack >= pixels(minFadeInches, dpi) else { return nil }

        // Cells that are shadowed paper. A cell darker than the shadow allows is no paper, and neither is
        // anything between it and the edge (a picture or a tint reaching the spine): those take the shadow
        // of the blocks beside them. A lighter cell (less shadow, the lid, a hole) keeps its own.
        var paperCell = [Bool](repeating: false, count: blocks * band)
        for j in 0..<blocks {
            var darkFurther = false
            for u in stride(from: band - 1, through: 0, by: -1) {
                let tolerance = consensusTolerance + consensusSpread * (1 - consensus[u])
                let difference = share[j * band + u] - consensus[u]
                if difference < -tolerance { darkFurther = true }
                paperCell[j * band + u] = !darkFurther
            }
        }
        var shadow = [Double](repeating: 0, count: blocks * band)
        for u in 0..<band {
            for j in 0..<blocks {
                if paperCell[j * band + u] {
                    shadow[j * band + u] = share[j * band + u]
                    continue
                }
                var before = j - 1, after = j + 1
                while before >= 0 && !paperCell[before * band + u] { before -= 1 }
                while after < blocks && !paperCell[after * band + u] { after += 1 }
                let value: Double
                if before >= 0 && after < blocks {
                    let a = share[before * band + u], b = share[after * band + u]
                    value = a + (b - a) * Double(j - before) / Double(after - before)
                } else if before >= 0 {
                    value = share[before * band + u]
                } else if after < blocks {
                    value = share[after * band + u]
                } else {
                    value = consensus[u]
                }
                shadow[j * band + u] = value
            }
        }
        // Smooth across the rows (twice), then along the edge's distance.
        shadow = smoothedRows(smoothedRows(shadow, rows: blocks, columns: band), rows: blocks, columns: band)
        shadow = smoothedColumns(shadow, rows: blocks, columns: band)

        // The gain of each cell: the paper back to white, capped, easing out at the far side of the band.
        let taper = pixels(taperInches, dpi)
        var cellGain = [Double](repeating: 1, count: blocks * band)
        for j in 0..<blocks {
            for u in 0..<band {
                let light = shadow[j * band + u]
                let gain = light <= 0 ? maxGain : min(max((1 - deadZone) / light, 1.0), maxGain)
                let ease = min(1.0, Double(band - u) / Double(taper))
                cellGain[j * band + u] = 1 + (gain - 1) * ease
            }
        }

        // Every band pixel: the cells interpolated between block centres along the edge; pictures left alone.
        let (first, second, weight) = interpolation(length: length, blocks: blocks)
        var dark = [UInt8](repeating: 0, count: length * band)
        for v in 0..<length {
            let j0 = first[v], j1 = second[v]
            let f = weight[v]
            let paperHere = paper[j0] + (paper[j1] - paper[j0]) * f
            for u in 0..<band {
                let s0 = shadow[j0 * band + u], s1 = shadow[j1 * band + u]
                let expected = paperHere * (s0 + (s1 - s0) * f)
                if Double(strip[v * span + u]) < pictureLevel * expected { dark[v * band + u] = 1 }
            }
        }
        let pictures = pictureAreas(dark, width: band, height: length, dpi: dpi)
        let protection = feathered(pictures, width: band, height: length, radius: pixels(featherInches, dpi))
        var gains = [Double](repeating: 1, count: length * band)
        var largestGain = 1.0
        var protectedPixels = 0
        for v in 0..<length {
            let j0 = first[v], j1 = second[v]
            let f = weight[v]
            for u in 0..<band {
                let g0 = cellGain[j0 * band + u], g1 = cellGain[j1 * band + u]
                var gain = g0 + (g1 - g0) * f
                let i = v * band + u
                gain = 1 + (gain - 1) * (1 - protection[i])
                gains[i] = gain
                if gain > largestGain { largestGain = gain }
                if pictures[i] != 0 { protectedPixels += 1 }
            }
        }
        let result = SpineShadowResult(edge: edge, depth: depth, widthInches: Double(reach) / dpi, maxGain: largestGain,
                                       protectedFraction: Double(protectedPixels) / Double(length * band))
        return SpineShadowModel(edge: edge, extent: extent, length: length, band: band, gains: gains,
                                pictures: pictures, result: result)
    }

    /// `image` with every pixel in the model's band brightened by its gain (each of red, green and blue
    /// multiplied, rounded, at most 255; alpha kept): the model's band pixels interpolated (bilinear) at the
    /// image's resolution, easing to no gain past the band. A pixel whose nearest model pixel is on a picture's
    /// box (`SpineShadowModel.pictures`) keeps its value; on an image finer than the model, so does one whose
    /// nearest model pixel is beside a box (the picture's edge may lie in it).
    public static func apply(_ image: RgbaImage, model: SpineShadowModel) -> RgbaImage {
        let alongX = model.edge == .left || model.edge == .right
        let w = image.width, h = image.height
        let extent = alongX ? w : h
        let length = alongX ? h : w
        // Analysis pixels per image pixel, away from the edge and along it.
        let scaleU = Double(model.extent) / Double(extent)
        let scaleV = Double(model.length) / Double(length)
        let band = model.band
        let reach = min(extent, Int(Double(band + 1) / scaleU) + 1)
        var u0s = [Int](repeating: 0, count: reach)
        var u1s = [Int](repeating: 0, count: reach)
        var fus = [Double](repeating: 0, count: reach)
        var nearestUs = [Int](repeating: 0, count: reach)
        for uf in 0..<reach {
            let ua = (Double(uf) + 0.5) * scaleU - 0.5
            if ua > 0 {
                let k = Int(ua)
                u0s[uf] = k
                u1s[uf] = k + 1        // column `band` and beyond: no gain
                fus[uf] = ua - Double(k)
                nearestUs[uf] = Int(ua + 0.5)
            }
        }
        var output = image.pixels
        let gains = model.gains
        // On a finer image, a picture's edge can fall inside an analysis pixel that is lighter than the picture
        // and so outside its box: the boxes are grown by one analysis pixel, so that edge keeps its pixels too.
        let pictures = scaleU < 1 || scaleV < 1
            ? MaskOps.dilate(model.pictures, band, model.length, radius: 1) : model.pictures
        for vf in 0..<length {
            let va = (Double(vf) + 0.5) * scaleV - 0.5
            let v0: Int, v1: Int, nearestV: Int
            let fv: Double
            if va <= 0 {
                v0 = 0; v1 = 0; fv = 0; nearestV = 0
            } else if va >= Double(model.length - 1) {
                v0 = model.length - 1; v1 = model.length - 1; fv = 0; nearestV = model.length - 1
            } else {
                v0 = Int(va); v1 = v0 + 1; fv = va - Double(v0); nearestV = Int(va + 0.5)
            }
            for uf in 0..<reach {
                let a = u0s[uf], b = u1s[uf]
                if a >= band { break }
                // A pixel of a picture's box (grown on a finer image) keeps its value, whatever the gain beside it.
                let nearestU = nearestUs[uf]
                if nearestU < band && pictures[nearestV * band + nearestU] != 0 { continue }
                let g00 = gains[v0 * band + a], g10 = gains[v1 * band + a]
                let g01 = b < band ? gains[v0 * band + b] : 1.0
                let g11 = b < band ? gains[v1 * band + b] : 1.0
                let top = g00 + (g01 - g00) * fus[uf]
                let bottom = g10 + (g11 - g10) * fus[uf]
                let gain = top + (bottom - top) * fv
                if gain <= 1 { continue }
                let x: Int, y: Int
                switch model.edge {
                case .left: x = uf; y = vf
                case .right: x = w - 1 - uf; y = vf
                case .top: x = vf; y = uf
                case .bottom: x = vf; y = h - 1 - uf
                }
                let i = (y * w + x) * 4
                for c in 0..<3 {
                    let value = Int(Double(output[i + c]) * gain + 0.5)
                    output[i + c] = UInt8(value > 255 ? 255 : value)
                }
            }
        }
        return RgbaImage(width: w, height: h, pixels: output)
    }

    // MARK: - Helpers

    /// Inches as whole pixels at `dpi`, rounded, at least 1.
    private static func pixels(_ inches: Double, _ dpi: Double) -> Int {
        max(1, Int(inches * dpi + 0.5))
    }

    /// The first `span` columns of `gray` away from `edge`, as rows along it: pixel (u, v) at v × span + u
    /// is u pixels from the edge, v along it from its left or top end.
    private static func oriented(_ gray: GrayImage, edge: PageEdge, span: Int) -> [UInt8] {
        let w = gray.width, h = gray.height
        let length = edge == .left || edge == .right ? h : w
        var output = [UInt8](repeating: 0, count: length * span)
        for v in 0..<length {
            for u in 0..<span {
                let index: Int
                switch edge {
                case .left: index = v * w + u
                case .right: index = v * w + (w - 1 - u)
                case .top: index = u * w + v
                case .bottom: index = (h - 1 - u) * w + v
                }
                output[v * span + u] = gray.pixels[index]
            }
        }
        return output
    }

    /// Each value replaced by the median of itself and `radius` values either side (fewer at the ends; the
    /// upper middle of an even count).
    private static func runningMedian(_ values: [Double], radius: Int) -> [Double] {
        let n = values.count
        var output = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let from = max(0, i - radius), to = min(n - 1, i + radius)
            let window = values[from...to].sorted()
            output[i] = window[window.count / 2]
        }
        return output
    }

    /// The 1-2-1 filter, the end values repeated.
    private static func smoothed(_ values: [Double]) -> [Double] {
        let n = values.count
        var output = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let before = values[max(0, i - 1)], after = values[min(n - 1, i + 1)]
            output[i] = (before + 2 * values[i] + after) / 4
        }
        return output
    }

    /// The 1-2-1 filter down each column of a rows × columns grid (across the blocks), the end rows repeated.
    private static func smoothedRows(_ grid: [Double], rows: Int, columns: Int) -> [Double] {
        var output = [Double](repeating: 0, count: grid.count)
        for j in 0..<rows {
            let above = max(0, j - 1) * columns, below = min(rows - 1, j + 1) * columns, here = j * columns
            for u in 0..<columns {
                output[here + u] = (grid[above + u] + 2 * grid[here + u] + grid[below + u]) / 4
            }
        }
        return output
    }

    /// The 1-2-1 filter along each row of a rows × columns grid (away from the edge), the end columns repeated.
    private static func smoothedColumns(_ grid: [Double], rows: Int, columns: Int) -> [Double] {
        var output = [Double](repeating: 0, count: grid.count)
        for j in 0..<rows {
            let row = j * columns
            for u in 0..<columns {
                let before = grid[row + max(0, u - 1)], after = grid[row + min(columns - 1, u + 1)]
                output[row + u] = (before + 2 * grid[row + u] + after) / 4
            }
        }
        return output
    }

    /// For each of `length` rows split into `blocks` blocks (as the cells were): the blocks whose centres
    /// surround the row's centre and the second one's weight; the nearest block beyond the outer centres.
    private static func interpolation(length: Int, blocks: Int) -> ([Int], [Int], [Double]) {
        var first = [Int](repeating: 0, count: length)
        var second = [Int](repeating: 0, count: length)
        var weight = [Double](repeating: 0, count: length)
        var centers = [Double](repeating: 0, count: blocks)
        for t in 0..<blocks {
            let start = t * length / blocks, end = (t + 1) * length / blocks
            centers[t] = Double(start + end) / 2.0
        }
        var k = 0
        for p in 0..<length {
            let c = Double(p) + 0.5
            while k < blocks - 1 && centers[k + 1] <= c { k += 1 }
            if c <= centers[0] {
                first[p] = 0; second[p] = 0; weight[p] = 0
            } else if k >= blocks - 1 {
                first[p] = blocks - 1; second[p] = blocks - 1; weight[p] = 0
            } else {
                first[p] = k; second[p] = k + 1
                weight[p] = (c - centers[k]) / (centers[k + 1] - centers[k])
            }
        }
        return (first, second, weight)
    }

    /// The pictures among the dark pixels of the band: the mask opened (thin strokes of text and lines gone)
    /// and closed (a picture's parts joined across its light areas, the band's sides counting as set), then the
    /// box around each part at least `minPictureInches` square in area (printed pictures are rectangles; a
    /// light corner of one is still inside its box).
    private static func pictureAreas(_ dark: [UInt8], width: Int, height: Int, dpi: Double) -> [UInt8] {
        let opening = pixels(openInches, dpi), closing = pixels(closeInches, dpi)
        let opened = MaskOps.dilate(MaskOps.erode(dark, width, height, radius: opening), width, height, radius: opening)
        let closed = MaskOps.erode(MaskOps.dilate(opened, width, height, radius: closing), width, height, radius: closing,
                                   outsideSet: true)
        let side = pixels(minPictureInches, dpi)
        let minArea = side * side
        var output = [UInt8](repeating: 0, count: width * height)
        for component in MaskOps.connectedComponents(mask: closed, width: width, height: height) where component.area >= minArea {
            var top = height, bottom = -1, left = width, right = -1
            for (row, extent) in component.rows {
                top = min(top, row)
                bottom = max(bottom, row)
                left = min(left, extent.minX)
                right = max(right, extent.maxX)
            }
            guard top <= bottom, left <= right else { continue }
            for y in top...bottom {
                for x in left...right { output[y * width + x] = 1 }
            }
        }
        return output
    }

    /// How much each pixel is left alone, 0...1: 1 on a picture's box, fading to 0 over the 2 × `radius` pixels
    /// beyond it (the mask grown by `radius`, then averaged over a square of 2 × radius + 1, clipped to the band).
    /// `apply` keeps the box itself hard at the image's resolution.
    private static func feathered(_ mask: [UInt8], width: Int, height: Int, radius: Int) -> [Double] {
        let grown = MaskOps.dilate(mask, width, height, radius: radius)
        // Summed-area table of the grown mask.
        var sums = [Int](repeating: 0, count: (width + 1) * (height + 1))
        for y in 0..<height {
            var rowSum = 0
            for x in 0..<width {
                rowSum += Int(grown[y * width + x])
                sums[(y + 1) * (width + 1) + x + 1] = sums[y * (width + 1) + x + 1] + rowSum
            }
        }
        var output = [Double](repeating: 0, count: width * height)
        for y in 0..<height {
            let y0 = max(0, y - radius), y1 = min(height, y + radius + 1)
            for x in 0..<width {
                let x0 = max(0, x - radius), x1 = min(width, x + radius + 1)
                let total = sums[y1 * (width + 1) + x1] - sums[y0 * (width + 1) + x1]
                    - sums[y1 * (width + 1) + x0] + sums[y0 * (width + 1) + x0]
                output[y * width + x] = Double(total) / Double((y1 - y0) * (x1 - x0))
            }
        }
        return output
    }
}
