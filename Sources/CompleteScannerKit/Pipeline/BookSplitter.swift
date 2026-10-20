import CoreGraphics
import Foundation

// Twin of windows/CompleteScanner.Core/BookSplitter.cs: same constants, same steps.

/// Which way the gutter of an open book runs across a scan (`GutterResult`).
public enum GutterAxis: Sendable {
    /// Up and down the scan: the two pages lie side by side.
    case vertical
    /// Across the scan: the two pages lie one above the other (the book lay sideways on the glass).
    case horizontal
}

/// What showed where the gutter is.
public enum GutterKind: Sendable {
    /// The dark shadow along the spine, where the pages curve away from the glass.
    case shadow
    /// The blank inner margins of the two pages, between their text.
    case margin
    /// The user placed the cut.
    case manual
}

/// Where a spread is cut into its two pages. Twin of C# `GutterResult`.
public struct GutterResult: Equatable, Sendable {
    /// Which way the cut runs.
    public var axis: GutterAxis
    /// Where the scan is cut, in its pixels from its left edge (`.vertical`) or its top edge
    /// (`.horizontal`): one page is the pixels before it, the other the pixels from it on. Between 1
    /// and the length of the axis less 1.
    public var position: Int
    /// How clear the gutter is: the depth of the shadow (its darkening, 0...1), or the length of the
    /// blank margin as a share of the axis; 1 for a cut placed by the user.
    public var confidence: Double
    /// What showed it.
    public var kind: GutterKind

    public init(axis: GutterAxis, position: Int, confidence: Double, kind: GutterKind) {
        self.axis = axis
        self.position = position
        self.confidence = confidence
        self.kind = kind
    }

    /// The cut's place along its axis on a scan `width` × `height`, 0...1.
    public func fraction(width: Int, height: Int) -> Double {
        Double(position) / Double(max(1, axis == .vertical ? width : height))
    }
}

/// A page cut from a spread (`ScannedPage.spread`; in memory only, never saved): the spread it was cut
/// from, which part of the scan it is, and where the scan was cut. Unsplitting and splitting again
/// start from the spread. Twin of C# `SpreadPart`.
public struct SpreadPart: Equatable, Sendable {
    /// The spread: the id of the page as scanned.
    public var spreadID: UUID
    /// 0 for the part before the cut (left, or top), 1 for the part after it (right, or bottom); nil
    /// when the spread was not split and the page is the whole spread.
    public var part: Int?
    /// Where the spread was cut; nil when it was not.
    public var gutter: GutterResult?

    public init(spreadID: UUID, part: Int?, gutter: GutterResult?) {
        self.spreadID = spreadID
        self.part = part
        self.gutter = gutter
    }

    /// The page is a whole spread: it was not split (the spine was not found, or the user joined it).
    public var isWhole: Bool { part == nil }
}

/// How the pages of a spread are turned and put in order (`BookSplitter.split`). Twin of C#
/// `BookSplitOptions`.
public struct BookSplitOptions: Equatable, Sendable {
    /// Quarter turns clockwise every page of the book is turned (the book lay sideways or upside down
    /// on the glass).
    public var rotationQuarterTurns: Int
    /// The book reads from right to left (Arabic, Hebrew, manga): the right page comes first.
    public var rightToLeft: Bool

    public init(rotationQuarterTurns: Int = 0, rightToLeft: Bool = false) {
        self.rotationQuarterTurns = rotationQuarterTurns
        self.rightToLeft = rightToLeft
    }

    /// The options of `settings` (`TaskOptions.bookRotationQuarterTurns`, `TaskOptions.bookRightToLeft`).
    public static func of(_ settings: ScanSettings) -> BookSplitOptions {
        BookSplitOptions(rotationQuarterTurns: BookSplitter.normalizedTurns(settings.taskOptions.bookRotationQuarterTurns),
                         rightToLeft: settings.taskOptions.bookRightToLeft)
    }
}

/// What the search for the gutter found along one axis, in the analysis image's pixels. Twin of C#
/// `GutterCandidate`.
public struct GutterCandidate: Equatable, Sendable {
    /// The axis searched.
    public var axis: GutterAxis
    /// The middle of the gutter (continuous coordinates: pixel i spans [i, i + 1)).
    public var center: Double
    /// As `GutterResult.confidence`.
    public var confidence: Double
    /// Shadow or margin.
    public var kind: GutterKind

    public init(axis: GutterAxis, center: Double, confidence: Double, kind: GutterKind) {
        self.axis = axis
        self.center = center
        self.confidence = confidence
        self.kind = kind
    }
}

/// The brightness and text profiles along one axis (`BookSplitter.profile`). Twin of C#
/// `BookSplitter.GutterProfile`.
public struct GutterProfile: Equatable, Sendable {
    public var axis: GutterAxis
    /// The mean gray of each column (or row) over the middle band, smoothed.
    public var brightness: [Double]
    /// The share of its pixels across the band that are an ink edge, smoothed.
    public var ink: [Double]

    public var length: Int { brightness.count }
}

/// Split the facing pages of an open book or magazine scanned on the glass. The gutter is found on a
/// gray copy at the analysis resolution (`GrayImage.analysisDPI`, at most `analysisMaxSide` pixels
/// long), from two profiles along each axis over the middle of the other one: the mean brightness, and
/// the share of neighbouring pixels across it that differ by an ink edge (text). The spine's shadow is a
/// narrow, smooth dip in the brightness with no text in it; without one, the gutter is the blank run
/// between the text of the two pages. Cautious by design: the text lines of a spread run across the
/// gutter, a shadow needs text beside it and a margin text on both sides, and anything unclear leaves
/// the spread whole for the user to split by hand. Twin of C# `BookSplitter`.
public enum BookSplitter {
    /// The longest side of the analysis image, in pixels.
    public static let analysisMaxSide = 1000
    /// The profiles leave out this share of the other axis at each end (the book's edges, the lid).
    public static let bandFraction = 0.1
    /// The profiles are smoothed over this many inches…
    public static let smoothInches = 0.05
    /// …and at least this many pixels.
    public static let minSmoothPixels = 3
    /// The gutter is looked for from this share of the axis…
    public static let searchFrom = 0.25
    /// …to this one.
    public static let searchTo = 0.75
    /// Two neighbouring pixels differing by more than this many gray levels are an ink edge.
    public static let inkStep = 24
    /// The paper level of a scan: this share of the positions in the search window are darker. A high
    /// share, so the paper of the margins counts, not the text.
    public static let paperLevelPercentile = 0.9
    /// The shadow darkens the paper by at least this share of its brightness.
    public static let minShadowDepth = 0.08
    /// The shadow is at least this many inches wide where it darkens the paper by half the least depth (a
    /// page's edge alone is a thin line; inside a shadow it is part of the shadow)…
    public static let minShadowWidthInches = 0.08
    /// …and at most this share of the axis at half its own depth (a dark picture is wider).
    public static let maxShadowWidthFraction = 0.12
    /// The text level of a scan: this share of the positions along the axis hold less text. A high
    /// share, so a spread with one page blank (less than half of it text) still has one.
    public static let textLevelPercentile = 0.8
    /// At the bottom of the shadow there is at most this share of the text level.
    public static let shadowInkFraction = 0.5
    /// The pages of a spread mirror each other: with text on both sides, the shadow lies within this share
    /// of the axis of the middle of the spread's text (a dark picture or a crease inside one page does not).
    public static let shadowSymmetryFraction = 0.12
    /// With text on one side only (the facing page blank), the shadow is at least this deep.
    public static let oneSidedShadowDepth = 0.15
    /// A stretch beside the gutter holds text when at least this share of the text level is there.
    public static let marginInkFraction = 0.25
    /// A margin is blank: less than this share of the text level (a line or two reaching into it, as
    /// ragged lines do, is not blank yet).
    public static let marginBlankFraction = 0.1
    /// The blank run between the pages' text is at least this many inches long: two inner margins, longer
    /// than the gap between the columns of one page.
    public static let minMarginInches = 0.6
    /// The pages of a spread mirror each other, so the blank run lies in the middle of the spread's text:
    /// its middle is at most this share of its length from the middle of the text (a centered title page
    /// facing a page of text is not).
    public static let marginSymmetryFraction = 0.25
    /// The blank run is paper: at least this share of the brightness around it (not a smooth picture).
    public static let marginPaperFraction = 0.97
    /// Text is looked for within this many inches beside the gutter…
    public static let sideInches = 1.5
    /// …and is there when this share of that stretch holds some.
    public static let minSideInk = 0.25
    /// The bottom of a shadow: within this share of its depth from its darkest point.
    public static let bottomFraction = 0.1
    /// Which way the text runs is judged with this many inches either side of a gutter blanked out: the
    /// gutter's own dark line, running along it, is no line of text.
    public static let lineCheckBandInches = 0.3
    /// A gutter cutting the scan's longer side counts this many times its confidence (spreads are wider than tall).
    public static let longSideBonus = 1.25

    // MARK: Finding the gutter

    /// Where `image`, scanned at `dpi`, holds the gutter of an open book, in its pixels; nil when it is
    /// not clear (a single page, a picture across the middle, a dark background): the spread then stays
    /// whole.
    public static func findGutter(_ image: RgbaImage, dpi: Int) -> GutterResult? {
        let gray = analysisImage(image, dpi: dpi)
        guard let found = findGutter(gray) else { return nil }
        return atScale(found, width: image.width, height: image.height, scale: gray.scale)
    }

    /// The same for a page's pixels as CoreGraphics holds them, read in bands of rows; nil also when
    /// they cannot be read.
    public static func findGutter(_ image: CGImage, dpi: Int) -> GutterResult? {
        guard let gray = GrayImage(cgImage: image, sourceDPI: dpi) else { return nil }
        let small = capped(gray)
        guard let found = findGutter(small) else { return nil }
        return atScale(found, width: image.width, height: image.height, scale: small.scale)
    }

    /// The gray copy the gutter is looked for in: the analysis resolution, at most `analysisMaxSide` long.
    public static func analysisImage(_ image: RgbaImage, dpi: Int) -> GrayImage {
        capped(GrayImage.from(image, sourceDPI: dpi))
    }

    /// `gray` at most `analysisMaxSide` long.
    private static func capped(_ gray: GrayImage) -> GrayImage {
        let longest = max(gray.width, gray.height)
        guard longest > analysisMaxSide else { return gray }
        let f = Double(analysisMaxSide) / Double(longest)
        let w = max(1, Int((Double(gray.width) * f).rounded()))
        let h = max(1, Int((Double(gray.height) * f).rounded()))
        return gray.downsampled(width: w, height: h)
    }

    /// The gutter found on `gray` (an analysis image), in its pixels: the clearer of the two axes
    /// (`candidates`), the axis cutting the longer side counting `longSideBonus` times; nil when
    /// neither has one.
    public static func findGutter(_ gray: GrayImage) -> GutterCandidate? {
        var best: GutterCandidate?
        var bestScore = 0.0
        for candidate in candidates(gray) {
            let longSide = candidate.axis == .vertical ? gray.width > gray.height : gray.height > gray.width
            let score = candidate.confidence * (longSide ? longSideBonus : 1)
            if best == nil || score > bestScore {
                best = candidate
                bestScore = score
            }
        }
        return best
    }

    /// The gutter each axis holds, in the analysis image's pixels: the deepest shadow that passes, else the
    /// longest margin that passes, each only when the text does not run along it (the text of a spread
    /// runs across its gutter; `runsAlongText`); nothing for an axis that has neither. Vertical first.
    public static func candidates(_ gray: GrayImage) -> [GutterCandidate] {
        var found: [GutterCandidate] = []
        for axis in [GutterAxis.vertical, GutterAxis.horizontal] {
            let axisProfile = Self.profile(gray, axis: axis)
            if let shadow = findShadow(axisProfile, dpi: gray.dpi), !runsAlongText(gray, shadow) {
                found.append(shadow)
            } else if let margin = findMargin(axisProfile, dpi: gray.dpi), !runsAlongText(gray, margin) {
                found.append(margin)
            }
        }
        return found
    }

    /// Whether the lines of text on `gray` run along `candidate`, judged with `lineCheckBandInches` either
    /// side of it blanked out to paper (`DocumentGeometry.estimateTextLayout`): lines running down the page
    /// lie along a vertical cut, lines across it along a horizontal one. A section gap or a fold across a
    /// single page runs along its lines; a spine runs across them. Unclear text tells nothing.
    public static func runsAlongText(_ gray: GrayImage, _ candidate: GutterCandidate) -> Bool {
        let vertical = candidate.axis == .vertical
        let length = vertical ? gray.width : gray.height
        let band = lineCheckBandInches * gray.dpi
        let from = max(0, Int((candidate.center - band).rounded(.down)))
        let to = min(length, Int((candidate.center + band).rounded(.up)))
        var pixels = gray.pixels
        let paper = paperValue(gray)
        if from < to {
            for i in from..<to {
                if vertical {
                    for y in 0..<gray.height { pixels[y * gray.width + i] = paper }
                } else {
                    for x in 0..<gray.width { pixels[i * gray.width + x] = paper }
                }
            }
        }
        let layout = DocumentGeometry.estimateTextLayout(GrayImage(width: gray.width, height: gray.height, pixels: pixels,
                                                                   dpi: gray.dpi, scale: gray.scale))
        guard layout.isConfident else { return false }
        return vertical ? layout.axis == .vertical : layout.axis == .horizontal
    }

    /// The paper of `gray`: the gray value that nine pixels in ten are no brighter than.
    private static func paperValue(_ gray: GrayImage) -> UInt8 {
        var counts = [Int](repeating: 0, count: 256)
        for v in gray.pixels { counts[Int(v)] += 1 }
        let target = Int(0.9 * Double(gray.pixels.count))
        var seen = 0
        for v in 0..<256 {
            seen += counts[v]
            if seen >= target { return UInt8(v) }
        }
        return 255
    }

    /// The profiles along `axis`: for each column (vertical) or row (horizontal) over the middle of the
    /// other axis (leaving out `bandFraction` at each end), the mean gray and the share of neighbouring
    /// pairs across the axis that differ by more than `inkStep`, both smoothed over `smoothInches`.
    public static func profile(_ gray: GrayImage, axis: GutterAxis) -> GutterProfile {
        let vertical = axis == .vertical
        let length = vertical ? gray.width : gray.height
        let across = vertical ? gray.height : gray.width
        var from = Int((Double(across) * bandFraction).rounded(.down))
        var to = max(from + 2, Int((Double(across) * (1 - bandFraction)).rounded(.up)))
        to = min(to, across)
        from = max(0, min(from, to - 2))
        var brightness = [Double](repeating: 0, count: length)
        var ink = [Double](repeating: 0, count: length)
        let p = gray.pixels
        let w = gray.width
        for i in 0..<length {
            var sum = 0
            var edges = 0
            var j = from
            while j < to {
                let value = Int(vertical ? p[j * w + i] : p[i * w + j])
                sum += value
                if j + 1 < to {
                    let next = Int(vertical ? p[(j + 1) * w + i] : p[i * w + j + 1])
                    if abs(next - value) > inkStep { edges += 1 }
                }
                j += 1
            }
            brightness[i] = Double(sum) / Double(to - from)
            ink[i] = to - from > 1 ? Double(edges) / Double(to - from - 1) : 0
        }
        let box = smoothWidth(gray.dpi)
        return GutterProfile(axis: axis, brightness: smoothed(brightness, box: box), ink: smoothed(ink, box: box))
    }

    /// The smoothing box: `smoothInches` at `dpi`, at least `minSmoothPixels`, odd.
    public static func smoothWidth(_ dpi: Double) -> Int {
        let box = max(minSmoothPixels, Int((smoothInches * dpi).rounded()))
        return box % 2 == 0 ? box + 1 : box
    }

    /// The mean of each value and its neighbours in a box of `box` (odd), the box cut short at the ends.
    public static func smoothed(_ values: [Double], box: Int) -> [Double] {
        let n = values.count, half = box / 2
        var prefix = [Double](repeating: 0, count: n + 1)
        for i in 0..<n { prefix[i + 1] = prefix[i] + values[i] }
        var result = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let a = max(0, i - half), b = min(n, i + half + 1)
            result[i] = (prefix[b] - prefix[a]) / Double(b - a)
        }
        return result
    }

    /// The deepest shadow in the search window that passes: a darkest point with nothing darker within
    /// half the widest shadow, at least `minShadowDepth` darker than the paper beside it (the lower of the
    /// brightest points within that reach on either side, and no brighter than the window's
    /// `paperLevelPercentile` percentile), a valley at least `minShadowWidthInches` wide where it darkens
    /// the paper by half of `minShadowDepth` and at most `maxShadowWidthFraction` wide at half its own
    /// depth, no more than `shadowInkFraction` of the text level at its bottom, and text beside it (within
    /// `sideInches`) on at least one side. Its centre is the middle of its bottom (within `bottomFraction`
    /// of its depth); with text on both sides of it (anywhere) that centre lies within
    /// `shadowSymmetryFraction` of the axis of the middle of the spread's text, and with text on one side
    /// only the shadow is at least `oneSidedShadowDepth` deep. nil when none passes.
    public static func findShadow(_ profile: GutterProfile, dpi: Double) -> GutterCandidate? {
        let m = profile.brightness
        let e = profile.ink
        let n = profile.length
        guard n >= 8 else { return nil }
        let (lo, hi) = window(n)
        let paper = percentile(m, from: lo, to: hi + 1, share: paperLevelPercentile)
        guard paper > 0 else { return nil }
        let level = Self.textLevel(e)
        let middleOfText = textMiddle(e, textLevel: level)
        let reach = max(1, Int(maxShadowWidthFraction * Double(n) / 2))
        let minWidth = minShadowWidthInches * dpi, maxWidth = maxShadowWidthFraction * Double(n)
        var best: GutterCandidate?
        guard lo <= hi else { return nil }
        for x in lo...hi {
            // The darkest point around: nothing darker within reach, and the first of a flat bottom.
            var lowest = true
            var j = max(0, x - reach)
            while j <= min(n - 1, x + reach) && lowest {
                if m[j] < m[x] || (j < x && m[j] == m[x]) { lowest = false }
                j += 1
            }
            if !lowest { continue }
            // The paper beside the dip: the brightest within reach on either side, the lower of the two.
            var leftShoulder = 0.0, rightShoulder = 0.0
            var k = max(0, x - reach)
            while k < x {
                leftShoulder = max(leftShoulder, m[k])
                k += 1
            }
            k = x + 1
            while k <= min(n - 1, x + reach) {
                rightShoulder = max(rightShoulder, m[k])
                k += 1
            }
            let paperBeside = min(paper, min(leftShoulder, rightShoulder))
            if paperBeside <= 0 { continue }
            let depth = (paperBeside - m[x]) / paperBeside
            if depth < minShadowDepth { continue }
            let half = m[x] + (paperBeside - m[x]) / 2
            var left = x, right = x
            while left > 0 && m[left - 1] < half { left -= 1 }
            while right < n - 1 && m[right + 1] < half { right += 1 }
            // A dip that runs to the end of the profile is no valley.
            if left == 0 || right == n - 1 { continue }
            if Double(right - left + 1) > maxWidth { continue }
            // The width of the whole shadow, where it darkens the paper by half the least depth: a thin
            // dark line (the pages' edges) at its bottom does not make it narrow.
            let broad = paperBeside * (1 - minShadowDepth / 2)
            var broadLeft = x, broadRight = x
            while broadLeft > 0 && m[broadLeft - 1] < broad { broadLeft -= 1 }
            while broadRight < n - 1 && m[broadRight + 1] < broad { broadRight += 1 }
            if Double(broadRight - broadLeft + 1) < minWidth { continue }
            if e[x] > shadowInkFraction * level { continue }
            let floor = m[x] + bottomFraction * (paperBeside - m[x])
            var bottomLeft = x, bottomRight = x
            while bottomLeft > 0 && m[bottomLeft - 1] <= floor { bottomLeft -= 1 }
            while bottomRight < n - 1 && m[bottomRight + 1] <= floor { bottomRight += 1 }
            let center = Double(bottomLeft + bottomRight + 1) / 2
            if !hasInk(e, from: left, direction: -1, textLevel: level, dpi: dpi)
                && !hasInk(e, from: right, direction: 1, textLevel: level, dpi: dpi) { continue }
            let textBefore = hasText(e, from: 0, to: left, textLevel: level, dpi: dpi)
            let textAfter = hasText(e, from: right + 1, to: n, textLevel: level, dpi: dpi)
            if textBefore && textAfter {
                guard let middle = middleOfText, abs(center - middle) <= shadowSymmetryFraction * Double(n) else { continue }
            } else if depth < oneSidedShadowDepth {
                continue
            }
            if best == nil || depth > best!.confidence {
                best = GutterCandidate(axis: profile.axis, center: center, confidence: depth, kind: .shadow)
            }
        }
        return best
    }

    /// The longest blank run between the pages' text that passes: text below `marginBlankFraction` of the
    /// text level, at least `minMarginInches` long, its middle in the search window and in the middle of
    /// the spread's text (within `marginSymmetryFraction` of its length of the middle between the first and
    /// the last text), as bright as paper (`marginPaperFraction` of the window's median), with text on both
    /// sides. Its centre is the middle of the run; its confidence the run's share of the axis. nil when none
    /// passes (or the scan holds no text).
    public static func findMargin(_ profile: GutterProfile, dpi: Double) -> GutterCandidate? {
        let m = profile.brightness
        let e = profile.ink
        let n = profile.length
        guard n >= 8 else { return nil }
        let level = Self.textLevel(e)
        guard level > 0 else { return nil }
        let (lo, hi) = window(n)
        let paperMedian = Self.median(m, from: lo, to: hi + 1)
        let threshold = marginBlankFraction * level
        guard let middleOfText = textMiddle(e, textLevel: level) else { return nil }
        let start = Int((Double(n) * bandFraction).rounded())
        let end = Int((Double(n) * (1 - bandFraction)).rounded())
        var best: GutterCandidate?
        var i = start
        while i < end {
            if e[i] >= threshold {
                i += 1
                continue
            }
            let runStart = i
            while i < end && e[i] < threshold { i += 1 }
            let runEnd = i - 1
            let length = runEnd - runStart + 1
            let center = Double(runStart + runEnd + 1) / 2
            if Double(length) < minMarginInches * dpi || center < Double(lo) || center > Double(hi + 1) { continue }
            if abs(center - middleOfText) > marginSymmetryFraction * Double(length) { continue }
            var sum = 0.0
            for k in runStart...runEnd { sum += m[k] }
            if sum / Double(length) < marginPaperFraction * paperMedian { continue }
            if !hasInk(e, from: runStart, direction: -1, textLevel: level, dpi: dpi)
                || !hasInk(e, from: runEnd, direction: 1, textLevel: level, dpi: dpi) { continue }
            let confidence = Double(length) / Double(n)
            if best == nil || confidence > best!.confidence {
                best = GutterCandidate(axis: profile.axis, center: center, confidence: confidence, kind: .margin)
            }
        }
        return best
    }

    /// The middle of the spread's text along the profile: halfway between its first and its last position
    /// holding text (`marginInkFraction` of the text level); nil when it holds none.
    private static func textMiddle(_ ink: [Double], textLevel: Double) -> Double? {
        guard textLevel > 0 else { return nil }
        let inked = marginInkFraction * textLevel
        guard let first = ink.firstIndex(where: { $0 >= inked }),
              let last = ink.lastIndex(where: { $0 >= inked }) else { return nil }
        return Double(first + last + 1) / 2
    }

    /// Whether ink[from..<to] holds text anywhere: at least as many positions at or above
    /// `marginInkFraction` of the text level as `hasInk` asks for beside a gutter.
    private static func hasText(_ ink: [Double], from: Int, to: Int, textLevel: Double, dpi: Double) -> Bool {
        guard textLevel > 0 else { return false }
        let threshold = marginInkFraction * textLevel
        let span = max(1, Int((sideInches * dpi).rounded()))
        var inked = 0
        var i = max(0, from)
        while i < min(ink.count, to) {
            if ink[i] >= threshold { inked += 1 }
            i += 1
        }
        return Double(inked) >= minSideInk * Double(span)
    }

    /// The search window along an axis of `n` pixels: `searchFrom` to `searchTo`, inclusive.
    private static func window(_ n: Int) -> (Int, Int) {
        (Int((Double(n) * searchFrom).rounded(.up)), min(n - 1, Int((Double(n) * searchTo).rounded(.down))))
    }

    /// The text level of the profile over its middle (leaving out `bandFraction` at each end): its
    /// `textLevelPercentile` percentile.
    private static func textLevel(_ ink: [Double]) -> Double {
        let n = ink.count
        let a = Int((Double(n) * bandFraction).rounded())
        let b = min(n, max(a + 1, Int((Double(n) * (1 - bandFraction)).rounded())))
        return percentile(ink, from: a, to: b, share: textLevelPercentile)
    }

    /// Whether the stretch of `sideInches` beside `from` (before it for `direction` −1, after it for 1)
    /// holds text: at least `minSideInk` of it at or above `marginInkFraction` of the text level.
    private static func hasInk(_ ink: [Double], from: Int, direction: Int, textLevel: Double, dpi: Double) -> Bool {
        guard textLevel > 0 else { return false }
        let span = max(1, Int((sideInches * dpi).rounded()))
        let threshold = marginInkFraction * textLevel
        var counted = 0, inked = 0
        for k in 1...span {
            let i = from + direction * k
            if i < 0 || i >= ink.count { break }
            counted += 1
            if ink[i] >= threshold { inked += 1 }
        }
        return counted > 0 && Double(inked) >= minSideInk * Double(span)
    }

    /// The value of values[from..<to] that a share `share` of them lie below (sorted, at that index); 0 when empty.
    private static func percentile(_ values: [Double], from: Int, to: Int, share: Double) -> Double {
        guard to > from else { return 0 }
        let sorted = values[from..<to].sorted()
        return sorted[min(sorted.count - 1, Int(share * Double(sorted.count)))]
    }

    /// The median of values[from..<to] (the mean of the middle two for an even count); 0 when empty.
    private static func median(_ values: [Double], from: Int, to: Int) -> Double {
        guard to > from else { return 0 }
        let sorted = values[from..<to].sorted()
        let c = sorted.count
        return c % 2 == 1 ? sorted[c / 2] : (sorted[c / 2 - 1] + sorted[c / 2]) / 2
    }

    /// `candidate` (on an analysis image `scale` times the size of the scan) as a cut in the scan's
    /// pixels, kept at least one pixel from either end.
    public static func atScale(_ candidate: GutterCandidate, width: Int, height: Int, scale: Double) -> GutterResult {
        let length = candidate.axis == .vertical ? width : height
        let s = scale > 0 ? scale : 1
        let position = Int((candidate.center / s).rounded())
        return GutterResult(axis: candidate.axis, position: clampPosition(position, length: length),
                            confidence: candidate.confidence, kind: candidate.kind)
    }

    /// A cut the user placed: at `fraction` (0...1) of the axis of a scan `width` × `height`.
    public static func manual(_ axis: GutterAxis, fraction: Double, width: Int, height: Int) -> GutterResult {
        let length = axis == .vertical ? width : height
        let f = fraction.isFinite ? min(max(fraction, 0), 1) : 0.5
        let position = Int((f * Double(length)).rounded())
        return GutterResult(axis: axis, position: clampPosition(position, length: length), confidence: 1, kind: .manual)
    }

    private static func clampPosition(_ position: Int, length: Int) -> Int {
        min(max(position, 1), max(1, length - 1))
    }

    // MARK: Splitting

    /// The two parts of `image` cut at `gutter`, as they lie on the scan: left then right, or top then
    /// bottom. Together they are exactly the scan. nil when the scan is too small to cut (one pixel).
    public static func halves(_ image: RgbaImage, gutter: GutterResult) -> (first: RgbaImage, second: RgbaImage)? {
        let vertical = gutter.axis == .vertical
        let length = vertical ? image.width : image.height
        let cut = clampPosition(gutter.position, length: length)
        let w = image.width, h = image.height
        let first = vertical
            ? image.cropped(CGRect(x: 0, y: 0, width: cut, height: h))
            : image.cropped(CGRect(x: 0, y: 0, width: w, height: cut))
        let second = vertical
            ? image.cropped(CGRect(x: cut, y: 0, width: w - cut, height: h))
            : image.cropped(CGRect(x: 0, y: cut, width: w, height: h - cut))
        guard let first, let second else { return nil }
        return (first, second)
    }

    /// The same for a page's pixels as CoreGraphics holds them (`CGImage.cropping(to:)`, top-left origin).
    public static func halves(_ image: CGImage, gutter: GutterResult) -> (first: CGImage, second: CGImage)? {
        let vertical = gutter.axis == .vertical
        let length = vertical ? image.width : image.height
        let cut = clampPosition(gutter.position, length: length)
        let w = image.width, h = image.height
        let first = vertical
            ? image.cropping(to: CGRect(x: 0, y: 0, width: cut, height: h))
            : image.cropping(to: CGRect(x: 0, y: 0, width: w, height: cut))
        let second = vertical
            ? image.cropping(to: CGRect(x: cut, y: 0, width: w - cut, height: h))
            : image.cropping(to: CGRect(x: 0, y: cut, width: w, height: h - cut))
        guard let first, let second else { return nil }
        return (first, second)
    }

    /// The pages of `image` cut at `gutter`, each turned `rotationQuarterTurns` quarter turns clockwise,
    /// in reading order: by where they lie once turned, left before right (right before left with
    /// `rightToLeft`), top before bottom. Each keeps the scan's resolution, so its paper size is right.
    /// Empty when the scan is too small to cut.
    public static func split(_ image: RgbaImage, gutter: GutterResult, rotationQuarterTurns: Int,
                             rightToLeft: Bool) -> [RgbaImage] {
        guard let parts = halves(image, gutter: gutter) else { return [] }
        let turns = normalizedTurns(rotationQuarterTurns)
        let a = parts.first.rotatedQuarterTurns(turns)
        let b = parts.second.rotatedQuarterTurns(turns)
        return firstPartLeads(gutter.axis, quarterTurns: turns, rightToLeft: rightToLeft) ? [a, b] : [b, a]
    }

    /// Whether the part before the cut (left, or top, on the scan) comes first once the spread is turned
    /// `quarterTurns` quarter turns clockwise: when it then lies on the left (on the right with
    /// `rightToLeft`), or on top.
    public static func firstPartLeads(_ axis: GutterAxis, quarterTurns: Int, rightToLeft: Bool) -> Bool {
        // Clockwise, left goes to the top, the top to the right, the right to the bottom: 0 left, 1 top, 2 right, 3 bottom.
        let place = ((axis == .vertical ? 0 : 1) + normalizedTurns(quarterTurns)) % 4
        switch place {
        case 0: return !rightToLeft
        case 2: return rightToLeft
        case 1: return true
        default: return false
        }
    }

    /// The quarter turns clockwise the spread was turned in all to make its pages upright: the book's
    /// rotation, and the turn reading the pages' text gave them (`UprightTurn`) when the two agree, or
    /// when only one page was turned (the other unread, blank or unsure). Pages turned different ways
    /// tell nothing.
    public static func totalTurns(_ rotationQuarterTurns: Int, _ first: UprightTurn?, _ second: UprightTurn?) -> Int {
        let a: Int? = first.flatMap { $0.undone ? nil : $0.quarterTurns }
        let b: Int? = second.flatMap { $0.undone ? nil : $0.quarterTurns }
        let extra: Int
        if a == b {
            extra = a ?? 0
        } else if let b, a == nil {
            extra = b
        } else if let a, b == nil {
            extra = a
        } else {
            extra = 0
        }
        return normalizedTurns(rotationQuarterTurns + extra)
    }

    /// `quarterTurns` as 0 to 3.
    public static func normalizedTurns(_ quarterTurns: Int) -> Int {
        ((quarterTurns % 4) + 4) % 4
    }
}

/// What the page strip says about a page cut from a spread (`BookPages.labels`). Twin of C#
/// `BookPageLabel`.
public struct BookPageLabel: Equatable, Sendable {
    /// "Spread 2 · page 1", "Spread 2 · not split".
    public let label: String
    /// The label's help.
    public let help: String

    public init(label: String, help: String) {
        self.label = label
        self.help = help
    }
}

/// What the page strip, the status and the inspector say about books and magazines: a label on each
/// page cut from a spread, the page's split and join actions, and the notes after a scan or a split.
/// Twin of C# `BookPages`.
public enum BookPages {
    /// Scans with these settings capture one side of each sheet (`DocumentSides.effective` is off):
    /// facing pages are split only then. The pages of a two-sided scan are paired by sheet and side, so
    /// they are kept as scanned.
    public static func scansOneSide(_ settings: ScanSettings) -> Bool {
        DocumentSides.effective(settings, capabilities: nil) == .off
    }

    /// The label and help of every page of the queue, in one pass: "Spread 2 · page 1", "Spread 2 ·
    /// page 2" for the pages cut from the second spread in the queue, by their order in it; "Spread 2 ·
    /// not split" for a spread kept whole, whose help says it can be split; nil for a page not scanned as
    /// part of a spread.
    public static func labels(_ pages: [ScannedPage]) -> [BookPageLabel?] {
        var numbers: [UUID: Int] = [:]
        var counts: [UUID: Int] = [:]
        var result: [BookPageLabel?] = Array(repeating: nil, count: pages.count)
        for (i, page) in pages.enumerated() {
            guard let part = page.spread else { continue }
            let number: Int
            if let known = numbers[part.spreadID] {
                number = known
            } else {
                number = numbers.count + 1
                numbers[part.spreadID] = number
            }
            let ordinal = (counts[part.spreadID] ?? 0) + 1
            counts[part.spreadID] = ordinal
            let text = part.isWhole ? "Spread \(number) \u{00B7} not split" : "Spread \(number) \u{00B7} page \(ordinal)"
            let help = part.isWhole ? "\(text): the spread is one page. Right-click it to split it into two pages." : text
            result[i] = BookPageLabel(label: text, help: help)
        }
        return result
    }

    /// The label of the page at `index` (`labels`); nil for a page not scanned as part of a spread.
    public static func label(_ pages: [ScannedPage], _ index: Int) -> String? {
        guard index >= 0, index < pages.count, pages[index].spread != nil else { return nil }
        return labels(pages)[index]?.label
    }

    /// The label's tooltip: what can be done with a spread kept whole; the label itself otherwise.
    public static func help(_ pages: [ScannedPage], _ index: Int) -> String? {
        guard index >= 0, index < pages.count, pages[index].spread != nil else { return nil }
        return labels(pages)[index]?.help
    }

    /// The pages that take the place of a spread's pages in the queue when it is joined or split again:
    /// `fresh` (`PageProcessor.processSpread`), carrying what the user decided about `queued` (the
    /// spread's pages in the queue, in queue order). When the spread was split and is split again, each
    /// new page replaces the queued page of the same part, with its document break, document name and
    /// keep or skip, and a part the user removed from the queue stays out. Otherwise (joined, or a whole
    /// spread split) every new page is used: the first takes the first queued page's document break and
    /// the first document name among them, and every one the keep or skip they share (automatic when
    /// they differ). Twin of C# `BookPages.ReplacementPages`.
    public static func replacementPages(_ queued: [ScannedPage], fresh: [ScannedPage]) -> [ScannedPage] {
        guard let first = queued.first else { return fresh }
        func isCut(_ page: ScannedPage) -> Bool { page.spread?.part != nil }
        if queued.allSatisfy(isCut) && fresh.allSatisfy(isCut) {
            var kept: [ScannedPage] = []
            for page in fresh {
                guard let old = queued.first(where: { $0.spread?.part == page.spread?.part }) else { continue }
                kept.append(page.withDocumentBreak(old.documentBreak).withDocumentLabel(old.documentLabel)
                    .withInclusion(old.inclusion))
            }
            return kept
        }
        let inclusion: PageInclusion = queued.allSatisfy({ $0.inclusion == first.inclusion }) ? first.inclusion : .automatic
        let label: String? = queued.compactMap(\.documentLabel).first
        return fresh.enumerated().map { item -> ScannedPage in
            item.offset == 0
                ? item.element.withDocumentBreak(first.documentBreak).withDocumentLabel(label).withInclusion(inclusion)
                : item.element.withInclusion(inclusion)
        }
    }

    /// "Split this spread…" for a spread kept whole, "Change the split…" for a page cut from one; nil
    /// for other pages.
    public static func splitActionLabel(_ page: ScannedPage) -> String? {
        guard let part = page.spread else { return nil }
        return part.isWhole ? "Split this spread\u{2026}" : "Change the split\u{2026}"
    }

    /// "Join the two pages" for a page cut from a spread; nil for other pages.
    public static func joinActionLabel(_ page: ScannedPage) -> String? {
        guard let part = page.spread, !part.isWhole else { return nil }
        return "Join the two pages"
    }

    /// The status after a scan's pages were queued, when spreads were split or kept whole: " 2 spreads
    /// split into pages." and " The spine of 1 spread was not found: it was added as one page
    /// (right-click it to split it)." (leading space; empty for no spread).
    public static func scanNote(_ added: [ScannedPage]) -> String {
        let parts = added.compactMap(\.spread)
        let split = Set(parts.filter { !$0.isWhole }.map(\.spreadID)).count
        let whole = Set(parts.filter(\.isWhole).map(\.spreadID)).count
        var note = split == 0 ? "" : " \(split) spread\(split == 1 ? "" : "s") split into pages."
        if whole > 0 {
            note += whole == 1
                ? " The spine of 1 spread was not found: it was added as one page (right-click it to split it)."
                : " The spine of \(whole) spreads was not found: they were added as one page each (right-click one to split it)."
        }
        return note
    }

    /// "Spread 2 is split into two pages." or "Spread 2 is one page again."
    public static func splitNote(spreadNumber: Int, split: Bool) -> String {
        split ? "Spread \(spreadNumber) is split into two pages." : "Spread \(spreadNumber) is one page again."
    }

    /// The choices of the book's rotation (quarter turns clockwise), as the inspector lists them.
    public static let rotationChoices = [0, 1, 2, 3]

    /// "As scanned", "90° clockwise", "180°", "90° counterclockwise".
    public static func rotationLabel(_ quarterTurns: Int) -> String {
        switch BookSplitter.normalizedTurns(quarterTurns) {
        case 1: return "90\u{00B0} clockwise"
        case 2: return "180\u{00B0}"
        case 3: return "90\u{00B0} counterclockwise"
        default: return "As scanned"
        }
    }

    /// The inspector's hint under "Split facing pages": why it is off for copies, receipts, scans saved
    /// at once and two-sided scans, else what it does.
    public static func hint(_ settings: ScanSettings) -> String {
        let flow = TaskCatalog.flow(of: settings)
        if flow == .copy { return "Copies print every page as scanned: spreads are not split." }
        if flow == .receiptSplit { return "Receipts are found on the glass one by one." }
        if !settings.documentMultiPage {
            return "Only for pages collected before saving: a scan saved at once is kept as scanned."
        }
        if !scansOneSide(settings) {
            return "Only for one side of each sheet: pages scanned on both sides are kept as scanned."
        }
        return settings.document.splitFacingPages
            ? "Each scan of an open book or magazine becomes two pages, cut at the spine. When the spine is not clear the spread stays one page: right-click it to split it."
            : "Scan an open book or magazine two pages at a time; each spread is cut at the spine into two pages."
    }
}
