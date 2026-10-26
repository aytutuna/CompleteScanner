import CoreGraphics
import Foundation

// Twin of windows/CompleteScanner.Core/PatchCode.cs.

/// The six patch codes of document scanners: four parallel bars, two wide and two narrow, in an
/// order that names the code. Separator sheets carry one (Patch T by convention). A sheet fed the
/// other way round reads its code backwards (`reversed`), so every code counts as a separator; the
/// code itself is only shown. Twin of C# `PatchCode` and `PatchCodes`.
public enum PatchCode: String, CaseIterable, Codable, Sendable {
    case patch1, patch2, patch3, patch4, patch6, patchT

    /// "Patch 1" … "Patch 6", "Patch T".
    public var label: String {
        switch self {
        case .patch1: return "Patch 1"
        case .patch2: return "Patch 2"
        case .patch3: return "Patch 3"
        case .patch4: return "Patch 4"
        case .patch6: return "Patch 6"
        case .patchT: return "Patch T"
        }
    }

    /// The bars in reading order (top to bottom, or left to right), true for a wide bar: 1 = wide
    /// wide narrow narrow, 2 = wide narrow narrow wide, 3 = wide narrow wide narrow, 4 = narrow wide
    /// wide narrow, 6 = narrow narrow wide wide, T = narrow wide narrow wide.
    public var bars: [Bool] {
        switch self {
        case .patch1: return [true, true, false, false]
        case .patch2: return [true, false, false, true]
        case .patch3: return [true, false, true, false]
        case .patch4: return [false, true, true, false]
        case .patch6: return [false, false, true, true]
        case .patchT: return [false, true, false, true]
        }
    }

    /// The code of four bars in reading order (true: wide); nil unless exactly two are wide.
    public static func fromBars(_ first: Bool, _ second: Bool, _ third: Bool, _ fourth: Bool) -> PatchCode? {
        allCases.first { $0.bars == [first, second, third, fourth] }
    }

    /// The code read from the other end: 1 and 6, 3 and T swap; 2 and 4 read the same.
    public var reversed: PatchCode {
        let b = bars
        return PatchCode.fromBars(b[3], b[2], b[1], b[0]) ?? self
    }
}

/// A patch code found on a page: the code as read, whether its bars run down the page (the sheet lay
/// sideways) rather than across it, and where its bars are (analysis pixels, top-left origin).
/// `length` is how far along the bars it was read, in analysis pixels. Twin of C# `PatchCodeHit`.
public struct PatchCodeHit: Equatable, Sendable {
    public let code: PatchCode
    public let verticalBars: Bool
    public let bounds: CGRect
    public let length: Int

    public init(code: PatchCode, verticalBars: Bool, bounds: CGRect, length: Int) {
        self.code = code
        self.verticalBars = verticalBars
        self.bounds = bounds
        self.length = length
    }
}

/// Finds patch codes on scanned pages, and draws the separator sheet the app prints. Works on the
/// page's gray copy at the analysis resolution (`GrayImage.analysisDPI`), integer arithmetic only,
/// so both platforms find the same codes. Twin of C# `PatchCodeDetector`.
///
/// A patch code is read like a one-dimensional barcode, along lines that cross its bars (the columns
/// of the page for bars running across it, the rows for bars running down it): the ink (darker than
/// half the paper, the page's 90th percentile) along a line gives runs, and four runs in a row match
/// when each is narrow (0.05–0.12 in) or wide (0.15–0.26 in), exactly two are wide, the gaps between
/// them are 0.05–0.12 in and nothing is printed for 0.3 in before and after them. Matches on
/// neighbouring lines that agree on the code and move by at most 0.02 in from one line to the next
/// are one code; it counts when it is read over at least 1.5 in of its length, on at least half the
/// lines it spans.
public enum PatchCodeDetector {
    // Sizes in hundredths of an inch (whole numbers, so both platforms compute the same pixels).
    public static let narrowBarHundredths = 8, wideBarHundredths = 20, gapHundredths = 8
    public static let minNarrowHundredths = 5, maxNarrowHundredths = 12
    public static let minWideHundredths = 15, maxWideHundredths = 26
    public static let minGapHundredths = 5, maxGapHundredths = 12
    public static let quietZoneHundredths = 30
    public static let minLengthHundredths = 150
    public static let maxStepHundredths = 2, maxBreakHundredths = 6
    public static let minCoverage = 0.5
    public static let sheetBarLengthHundredths = 600, sheetMarginHundredths = 100

    private static func floorPixels(_ hundredths: Int, _ dpi: Double) -> Int {
        Int((Double(hundredths) * dpi / 100).rounded(.down))
    }

    private static func ceilingPixels(_ hundredths: Int, _ dpi: Double) -> Int {
        Int((Double(hundredths) * dpi / 100).rounded(.up))
    }

    private static func roundPixels(_ hundredths: Int, _ dpi: Double) -> Int {
        Int((Double(hundredths) * dpi / 100).rounded())
    }

    /// The patch code on `image`, scanned at `dpi`; nil when there is none.
    public static func detect(_ image: RgbaImage, dpi: Int) -> PatchCodeHit? {
        detect(GrayImage.from(image, sourceDPI: dpi))
    }

    /// The patch code on `image`, scanned at `dpi`, read as gray at the analysis resolution; nil when
    /// there is none or the image cannot be read.
    public static func detect(_ image: CGImage, dpi: Int) -> PatchCodeHit? {
        guard let gray = GrayImage(cgImage: image, sourceDPI: dpi) else { return nil }
        return detect(gray)
    }

    /// The patch code on the page, read at the analysis resolution (a finer image is reduced to it
    /// first); nil when there is none. Bars across the page are tried first; the longer of the two
    /// readings wins.
    public static func detect(_ gray: GrayImage) -> PatchCodeHit? {
        let g = gray.dpi > Double(GrayImage.analysisDPI) ? gray.atResolution(GrayImage.analysisDPI) : gray
        let w = g.width, h = g.height
        guard w >= 2, h >= 2 else { return nil }
        var histogram = [Int](repeating: 0, count: 256)
        for value in g.pixels { histogram[Int(value)] += 1 }
        let paper = Int(BackgroundMap.percentile(histogram, count: g.pixels.count, fraction: 0.9))
        var ink = [Bool](repeating: false, count: w * h)
        for i in 0..<ink.count { ink[i] = Int(g.pixels[i]) * 2 < paper }

        let limits = Limits(dpi: g.dpi)
        let across = read(ink, w, h, lineIsRow: false, limits: limits)
        let down = read(ink, w, h, lineIsRow: true, limits: limits)
        var best = across
        var vertical = false
        if let d = down, best == nil || d.length > best!.length {
            best = d
            vertical = true
        }
        guard let chain = best else { return nil }
        // Lines are columns for bars across the page (positions are rows), rows for bars down it.
        let bounds = vertical
            ? CGRect(x: chain.minStart, y: chain.firstLine, width: chain.maxEnd - chain.minStart, height: chain.length)
            : CGRect(x: chain.firstLine, y: chain.minStart, width: chain.length, height: chain.maxEnd - chain.minStart)
        return PatchCodeHit(code: chain.code, verticalBars: vertical, bounds: bounds, length: chain.length)
    }

    /// The detector's sizes in pixels at one resolution.
    private struct Limits {
        let minNarrow, maxNarrow, minWide, maxWide, minGap, maxGap, quiet, minLength, maxStep, maxBreak: Int

        init(dpi: Double) {
            typealias D = PatchCodeDetector
            minNarrow = D.floorPixels(D.minNarrowHundredths, dpi)
            maxNarrow = D.ceilingPixels(D.maxNarrowHundredths, dpi)
            minWide = D.floorPixels(D.minWideHundredths, dpi)
            maxWide = D.ceilingPixels(D.maxWideHundredths, dpi)
            minGap = D.floorPixels(D.minGapHundredths, dpi)
            maxGap = D.ceilingPixels(D.maxGapHundredths, dpi)
            quiet = D.roundPixels(D.quietZoneHundredths, dpi)
            minLength = max(1, D.roundPixels(D.minLengthHundredths, dpi))
            maxStep = max(1, D.roundPixels(D.maxStepHundredths, dpi))
            maxBreak = max(1, D.roundPixels(D.maxBreakHundredths, dpi))
        }
    }

    /// A code read on neighbouring lines.
    private struct Chain {
        let code: PatchCode
        let firstLine: Int
        var lastLine: Int
        var lastStart: Int
        var minStart: Int
        var maxEnd: Int
        var count: Int
        var length: Int { lastLine - firstLine + 1 }
    }

    /// The longest code read along the columns (`lineIsRow` false: bars across the page) or the rows
    /// (true: bars down it); nil when none is long and dense enough.
    private static func read(_ ink: [Bool], _ w: Int, _ h: Int, lineIsRow: Bool, limits: Limits) -> Chain? {
        let lines = lineIsRow ? h : w
        let length = lineIsRow ? w : h
        var chains: [Chain] = []
        var runStarts: [Int] = []
        var runEnds: [Int] = []
        for line in 0..<lines {
            runStarts.removeAll(keepingCapacity: true)
            runEnds.removeAll(keepingCapacity: true)
            var runStart = -1
            for pos in 0..<length {
                let isInk = lineIsRow ? ink[line * w + pos] : ink[pos * w + line]
                if isInk && runStart < 0 {
                    runStart = pos
                } else if !isInk && runStart >= 0 {
                    runStarts.append(runStart)
                    runEnds.append(pos)
                    runStart = -1
                }
            }
            if runStart >= 0 {
                runStarts.append(runStart)
                runEnds.append(length)
            }
            var i = 0
            while i + 3 < runStarts.count {
                defer { i += 1 }
                guard let code = match(runStarts, runEnds, i, limits: limits) else { continue }
                let start = runStarts[i], end = runEnds[i + 3]
                var found: Int?
                for (k, chain) in chains.enumerated()
                where chain.code == code && chain.lastLine < line && line - chain.lastLine <= limits.maxBreak + 1
                    && abs(start - chain.lastStart) <= limits.maxStep {
                    found = k
                    break
                }
                guard let k = found else {
                    chains.append(Chain(code: code, firstLine: line, lastLine: line, lastStart: start,
                                        minStart: start, maxEnd: end, count: 1))
                    continue
                }
                chains[k].lastLine = line
                chains[k].lastStart = start
                chains[k].minStart = min(chains[k].minStart, start)
                chains[k].maxEnd = max(chains[k].maxEnd, end)
                chains[k].count += 1
            }
        }
        var best: Chain?
        for chain in chains {
            if chain.length < limits.minLength || Double(chain.count) < minCoverage * Double(chain.length) { continue }
            if best == nil || chain.length > best!.length { best = chain }
        }
        return best
    }

    /// The code of the four runs from run `i` on, when they read as one; else nil.
    private static func match(_ starts: [Int], _ ends: [Int], _ i: Int, limits: Limits) -> PatchCode? {
        var wide = [false, false, false, false]
        for k in 0..<4 {
            let width = ends[i + k] - starts[i + k]
            if width >= limits.minWide && width <= limits.maxWide {
                wide[k] = true
            } else if width < limits.minNarrow || width > limits.maxNarrow {
                return nil
            }
            if k > 0 {
                let gap = starts[i + k] - ends[i + k - 1]
                if gap < limits.minGap || gap > limits.maxGap { return nil }
            }
        }
        // Nothing printed before the first bar and after the last (the page's edge counts as quiet).
        let before = i > 0 ? starts[i] - ends[i - 1] : Int.max
        let after = i + 4 < starts.count ? starts[i + 4] - ends[i + 3] : Int.max
        if before < limits.quiet || after < limits.quiet { return nil }
        return PatchCode.fromBars(wide[0], wide[1], wide[2], wide[3])
    }

    // MARK: - The separator sheet

    /// The separator sheet to print, `widthInches` × `heightInches` at `dpi`: white, with `code` in
    /// black bars across the sheet 1 in from the top and again 1 in from the bottom, turned half a
    /// turn there, so the sheet reads the same code fed either way round; and in the middle
    /// "SEPARATOR SHEET", the code and how to use and print it. Printed at real size, its bars have
    /// the standard widths.
    public static func renderSheet(_ code: PatchCode, widthInches: Double, heightInches: Double, dpi: Int) -> GrayImage {
        let d = Double(dpi)
        let w = max(1, Int((widthInches * d).rounded()))
        let h = max(1, Int((heightInches * d).rounded()))
        var pixels = [UInt8](repeating: 255, count: w * h)

        let narrow = max(1, roundPixels(narrowBarHundredths, d))
        let wide = max(1, roundPixels(wideBarHundredths, d))
        let gap = max(1, roundPixels(gapHundredths, d))
        let margin = roundPixels(sheetMarginHundredths, d)
        let barLength = max(1, min(roundPixels(sheetBarLengthHundredths, d), w - 2 * roundPixels(50, d)))
        let x0 = (w - barLength) / 2
        let bars = code.bars

        // Near the top, read top to bottom.
        var y = margin
        for isWide in bars {
            let thickness = isWide ? wide : narrow
            fillRect(&pixels, w, h, x0, y, barLength, thickness, 0)
            y += thickness + gap
        }
        // Near the bottom, half a turn round: read bottom to top.
        y = h - margin
        for isWide in bars {
            let thickness = isWide ? wide : narrow
            fillRect(&pixels, w, h, x0, y - thickness, barLength, thickness, 0)
            y -= thickness + gap
        }

        // The words, centred, around the middle of the sheet.
        let middle = h / 2
        let title = max(1, roundPixels(5, d))
        let body = max(1, roundPixels(2, d))
        drawText(&pixels, w, h, "SEPARATOR SHEET", top: middle - roundPixels(80, d), cell: title)
        drawText(&pixels, w, h, code.label.uppercased(), top: middle - roundPixels(20, d), cell: title)
        drawText(&pixels, w, h, "PUT THIS SHEET IN FRONT OF EACH DOCUMENT.", top: middle + roundPixels(50, d), cell: body)
        drawText(&pixels, w, h, "PRINT AT ACTUAL SIZE (100%). DO NOT SHRINK.", top: middle + roundPixels(80, d), cell: body)
        return GrayImage(width: w, height: h, pixels: pixels, dpi: d)
    }

    /// Fills the rectangle at (`x`, `y`), `rw` × `rh` pixels, with `value`, clipped to the sheet. Also
    /// used by the barcode sheets (`QrSeparatorSheet`, `Code39`).
    static func fillRect(_ pixels: inout [UInt8], _ w: Int, _ h: Int, _ x: Int, _ y: Int,
                         _ rw: Int, _ rh: Int, _ value: UInt8) {
        let y0 = max(0, y), y1 = min(h, y + rh)
        let x0 = max(0, x), x1 = min(w, x + rw)
        guard y0 < y1, x0 < x1 else { return }
        for py in y0..<y1 {
            for px in x0..<x1 { pixels[py * w + px] = value }
        }
    }

    /// `text` in the sheet's 5 × 7 type, each dot `cell` pixels, a dot's space between letters,
    /// centred across the sheet with its top at `top`. Characters the type does not have are spaces.
    /// Also used by the barcode sheets.
    static func drawText(_ pixels: inout [UInt8], _ w: Int, _ h: Int, _ text: String, top: Int, cell: Int) {
        let characters = Array(text)
        let width = (characters.count * 6 - 1) * cell
        var x = (w - width) / 2
        for c in characters {
            if let glyph = glyphs[c] {
                let dots = Array(glyph)
                for row in 0..<7 {
                    for col in 0..<5 where dots[row * 5 + col] == "1" {
                        fillRect(&pixels, w, h, x + col * cell, top + row * cell, cell, cell, 0)
                    }
                }
            }
            x += 6 * cell
        }
    }

    /// Whether the sheet's type has `c`.
    static func hasGlyph(_ c: Character) -> Bool { glyphs[c] != nil }

    /// The sheet's type: 5 × 7 dots per character, rows top to bottom.
    private static let glyphs: [Character: String] = [
        "A": "01110100011000111111100011000110001",
        "B": "11110100011000111110100011000111110",
        "C": "01110100011000010000100001000101110",
        "D": "11110100011000110001100011000111110",
        "E": "11111100001000011110100001000011111",
        "F": "11111100001000011110100001000010000",
        "G": "01110100011000010111100011000101111",
        "H": "10001100011000111111100011000110001",
        "I": "01110001000010000100001000010001110",
        "J": "00111000100001000010000101001001100",
        "K": "10001100101010011000101001001010001",
        "L": "10000100001000010000100001000011111",
        "M": "10001110111010110101100011000110001",
        "N": "10001100011100110101100111000110001",
        "O": "01110100011000110001100011000101110",
        "P": "11110100011000111110100001000010000",
        "Q": "01110100011000110001101011001001101",
        "R": "11110100011000111110101001001010001",
        "S": "01111100001000001110000010000111110",
        "T": "11111001000010000100001000010000100",
        "U": "10001100011000110001100011000101110",
        "V": "10001100011000110001100010101000100",
        "W": "10001100011000110101101011010101010",
        "X": "10001100010101000100010101000110001",
        "Y": "10001100010101000100001000010000100",
        "Z": "11111000010001000100010001000011111",
        "0": "01110100011001110101110011000101110",
        "1": "00100011000010000100001000010001110",
        "2": "01110100010000100010001000100011111",
        "3": "11111000100010000010000011000101110",
        "4": "00010001100101010010111110001000010",
        "5": "11111100001111000001000011000101110",
        "6": "00110010001000011110100011000101110",
        "7": "11111000010001000100010000100001000",
        "8": "01110100011000101110100011000101110",
        "9": "01110100011000101111000010001001100",
        ".": "00000000000000000000000000110001100",
        "(": "00010001000100001000010000010000010",
        ")": "01000001000001000010000100010001000",
        "%": "11000110010001000100010001001100011",
        "-": "00000000000000011111000000000000000",
        "?": "01110100010000100010001000000000100",
        ":": "00000011000110000000011000110000000",
        "/": "00000000010001000100010001000000000",
        "_": "00000000000000000000000000000011111",
        "#": "01010010101111101010111110101001010",
        "+": "00000001000010011111001000010000000",
        ",": "00000000000000000000011000010001000",
        "&": "01100100101010001000101011001001101",
        "'": "01100001000100000000000000000000000",
        "!": "00100001000010000100001000000000100",
    ]
}

/// The separator sheet as a PDF to print (`PatchCodeDetector.renderSheet`): Patch T on the paper
/// usual where the user lives, saved in the scans folder, for any printer, here or elsewhere. Twin
/// of C# `SeparatorSheet` (PatchCode.cs).
public enum SeparatorSheet {
    /// The code on the sheet.
    public static let code = PatchCode.patchT

    /// The sheet's resolution.
    public static let dpi = 300

    /// Letter or A4: the paper usual in `regionCode` (`PaperSizes.defaultForRegion`).
    public static func paper(regionCode: String?) -> PaperSize { PaperSizes.defaultForRegion(regionCode) }

    /// "Separator sheet (Patch T, Letter)": the PDF's name, without its extension.
    public static func fileBaseName(_ paper: PaperSize) -> String { "Separator sheet (\(code.label), \(paper.label))" }

    /// The status after the PDF was saved.
    public static func savedMessage(_ fileName: String) -> String {
        "Saved the separator sheet: \(fileName). Print it at actual size (100%), as many as you need, and put one in front of each document after the first."
    }
}
