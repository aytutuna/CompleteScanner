import CoreGraphics
import Foundation
@testable import CompleteScannerKit

// Twin of windows/LazyScan.Core.Tests/TestPages.cs: the same pages, byte for byte. Integer
// arithmetic only (no floating point, no trigonometry), and one xorshift32 generator consumed in
// the same order, so both platforms draw identical pixels.

/// Synthetic US Letter pages at 100 dpi (850 × 1100 gray pixels) for the blank-page tests: blank
/// pages the way scanners deliver them (noise, dust, gradients, edge shadows, punched holes,
/// show-through) and pages with little on them (one text line, a signature, a page number, a
/// photo, text on tinted paper).
enum TestPages {
    static let width = 850
    static let height = 1100

    /// xorshift32 (13, 17, 5).
    final class Rng {
        private var state: UInt32

        init(_ seed: UInt32) {
            state = seed == 0 ? 1 : seed
        }

        func next() -> UInt32 {
            state ^= state << 13
            state ^= state >> 17
            state ^= state << 5
            return state
        }

        /// 0 ..< n.
        func below(_ n: Int) -> Int {
            Int(next() % UInt32(n))
        }

        /// Scanner noise: the sum of four uniform 0...6 values minus 12 (σ = 4 levels).
        func noise() -> Int {
            let a = below(7)
            let b = below(7)
            let c = below(7)
            let d = below(7)
            return a + b + c + d - 12
        }
    }

    // MARK: - The pages

    /// (a) Clean blank paper.
    static func cleanBlank() -> GrayImage {
        GrayImage.filled(width: width, height: height, value: 245)
    }

    /// (b) Blank paper as a cheap scanner delivers it: noise, a top-to-bottom gradient from 92 %
    /// to 98 % white, 200 specks of dust of 1–2 pixels, a 0.15 in dark shadow along the left edge
    /// and three punched holes.
    static func noisyBlank() -> GrayImage {
        let rng = Rng(0xB1A2_C3D4)
        var p = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            let paper = 255 * (920 + 60 * y / (height - 1)) / 1000
            for x in 0..<width { p[y * width + x] = clamp(paper + rng.noise()) }
        }
        for _ in 0..<200 {
            let size = 1 + rng.below(2)
            let x = rng.below(width - 2)
            let y = rng.below(height - 2)
            fill(&p, x, y, size, size, 60)
        }
        // Edge shadow: darkest at the edge, fading over 15 px.
        for y in 0..<height {
            for x in 0..<15 {
                let i = y * width + x
                p[i] = UInt8(min(Int(p[i]), 40 + x * 12))
            }
        }
        for cy in [200, 550, 900] { disc(&p, 40, cy, 12, 30) }
        return GrayImage(width: width, height: height, pixels: p)
    }

    /// (c) Blank paper with the other side's text showing through: a page of text mirrored left to
    /// right, darkening the paper by 12 %, with noise.
    static func showThrough() -> GrayImage {
        var front = [UInt8](repeating: 0, count: width * height)
        let textRng = Rng(0x5EED_0003)
        for line in 0..<30 { textLine(&front, 75, 110 + line * 28, 700, 1, textRng) }
        let rng = Rng(0x0C0F_FEE3)
        var p = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let paper = front[y * width + (width - 1 - x)] == 1 ? 245 * 88 / 100 : 245
                p[y * width + x] = clamp(paper + rng.noise())
            }
        }
        return GrayImage(width: width, height: height, pixels: p)
    }

    /// (d) One line of text across the page, on noisy paper.
    static func oneTextLine() -> GrayImage {
        noisy(0xD0D0_D0D4, 245) { p in textLine(&p, 100, 400, 650, 50, Rng(0x7E7E_0004)) }
    }

    /// (e) A signature: a 3 px pen stroke zigzagging over about 3 inches, on noisy paper.
    static func signature() -> GrayImage {
        noisy(0xE5E5_E5E5, 245) { p in
            let xs = [450, 470, 490, 505, 520, 540, 560, 580, 610, 640, 670, 700, 730, 760]
            let ys = [880, 840, 900, 850, 905, 845, 895, 860, 890, 865, 885, 870, 880, 872]
            for k in 0..<(xs.count - 1) { stroke(&p, xs[k], ys[k], xs[k + 1], ys[k + 1], 3, 40) }
        }
    }

    /// (f) Nothing but a page number ("12") near the bottom, on noisy paper.
    static func pageNumber() -> GrayImage {
        noisy(0xF0F0_F0F6, 245) { p in
            // "1": a stem and a foot.
            fill(&p, 415, 1000, 2, 12, 50)
            fill(&p, 413, 1011, 6, 1, 50)
            // "2": top, upper right, middle, lower left, bottom.
            fill(&p, 424, 1000, 7, 2, 50)
            fill(&p, 429, 1000, 2, 6, 50)
            fill(&p, 424, 1005, 7, 2, 50)
            fill(&p, 424, 1005, 2, 6, 50)
            fill(&p, 424, 1010, 7, 2, 50)
        }
    }

    /// (g) A mid-gray 3 × 4 in photo with some texture, on noisy paper.
    static func photo() -> GrayImage {
        var page = noisy(0x9A9A_9A97, 245) { _ in }
        let rng = Rng(0x0970_7007)
        for y in 300..<700 {
            for x in 275..<575 {
                page.pixels[y * width + x] = clamp(128 + (x / 20 + y / 30) % 5 * 6 + rng.noise() * 2)
            }
        }
        return page
    }

    /// (h) Recycled paper (85 % gray, flecked) with a short paragraph.
    static func tintedWithText() -> GrayImage {
        var page = noisy(0x8181_818A, 217) { _ in }
        let rng = Rng(0xF1EC_0008)
        for _ in 0..<400 {
            let x = rng.below(width)
            let y = rng.below(height)
            fill(&page.pixels, x, y, 1, 1, 170)
        }
        let text = Rng(0x7E7E_0008)
        for line in 0..<5 { textLine(&page.pixels, 100, 300 + line * 25, 640, 60, text) }
        return page
    }

    /// Every page with its letter, for reports.
    static func all() -> [(name: String, page: GrayImage)] {
        [
            ("a clean blank", cleanBlank()),
            ("b noisy blank", noisyBlank()),
            ("c show-through", showThrough()),
            ("d one text line", oneTextLine()),
            ("e signature", signature()),
            ("f page number", pageNumber()),
            ("g photo", photo()),
            ("h tinted with text", tintedWithText()),
        ]
    }

    // MARK: - Pages for crop and straighten

    /// A turn by a small angle as exact fixed-point sine and cosine (× 65536), so both platforms draw
    /// the same pixels without trigonometry.
    struct Turn {
        let sin: Int
        let cos: Int

        /// The angle drawn, clockwise on screen positive.
        var degrees: Double { atan2(Double(sin), Double(cos)) * 180 / .pi }
    }

    static let straight = Turn(sin: 0, cos: 65536)
    static let plus0Point1 = Turn(sin: 114, cos: 65536)
    static let minus1Point5 = Turn(sin: -1716, cos: 65514)
    static let plus2 = Turn(sin: 2287, cos: 65496)
    static let plus3 = Turn(sin: 3430, cos: 65446)
    static let minus4 = Turn(sin: -4572, cos: 65376)
    static let plus6Point5 = Turn(sin: 7419, cos: 65115)

    /// The sheet of `sheetOnBackdrop`: 6 × 8 in.
    static let sheetWidth = 600
    static let sheetHeight = 800

    /// A page of text: 34 lines of glyphs (`textLine`) 6.5 in long, every 0.28 in, on noisy paper.
    static func textPage() -> GrayImage {
        noisy(0x7E57_AA6E, 245) { p in
            let rng = Rng(0x7E57_AA6F)
            for line in 0..<34 { textLine(&p, 100, 100 + line * 28, 650, 40, rng) }
        }
    }

    /// `page` with its content turned clockwise by `turn` about the center (nearest pixel); what
    /// comes in from outside the page is `fill`.
    static func turned(_ page: GrayImage, _ turn: Turn, fill: UInt8) -> GrayImage {
        let w = page.width, h = page.height
        var p = [UInt8](repeating: 0, count: w * h)
        let unit = 65536
        for y in 0..<h {
            let dy = 2 * y + 1 - h
            for x in 0..<w {
                let dx = 2 * x + 1 - w
                // The pixel's offset from the center (doubled) turned back, in 1/65536 units.
                let sx = floorDiv(dx * turn.cos + dy * turn.sin + w * unit, 2 * unit)
                let sy = floorDiv(-dx * turn.sin + dy * turn.cos + h * unit, 2 * unit)
                p[y * w + x] = sx >= 0 && sx < w && sy >= 0 && sy < h ? page.pixels[sy * w + sx] : fill
            }
        }
        return GrayImage(width: w, height: h, pixels: p)
    }

    /// A 6 × 8 in sheet (`sheetWidth` × `sheetHeight`: `paper` with noise and 24 lines of glyphs)
    /// lying at the center of the 850 × 1100 scan on a noisy `backdrop`, turned clockwise by `turn`,
    /// with a `shadow` px edge shadow (200) all around it when above 0.
    static func sheetOnBackdrop(_ turn: Turn, backdrop: Int, paper: Int, shadow: Int, seed: UInt32) -> GrayImage {
        let sw = sheetWidth, sh = sheetHeight
        var sheet = [UInt8](repeating: 0, count: sw * sh)
        let rng = Rng(seed)
        for i in 0..<sheet.count { sheet[i] = clamp(paper + rng.noise()) }
        let text = Rng(seed ^ 0x5A5A_5A5A)
        for line in 0..<24 { sheetTextLine(&sheet, 60, 60 + line * 28, 480, 40, text) }

        var p = [UInt8](repeating: 0, count: width * height)
        let noise = Rng(seed &+ 1)
        let unit = 65536
        let halfW = sw * unit, halfH = sh * unit
        let outerW = (sw + 2 * shadow) * unit, outerH = (sh + 2 * shadow) * unit
        for y in 0..<height {
            let dy = 2 * y + 1 - height
            for x in 0..<width {
                let dx = 2 * x + 1 - width
                // The pixel in the sheet's frame (doubled, in 1/65536 units).
                let u = dx * turn.cos + dy * turn.sin
                let v = -dx * turn.sin + dy * turn.cos
                let value: Int
                if abs(u) < halfW && abs(v) < halfH {
                    let sx = floorDiv(u + halfW, 2 * unit), sy = floorDiv(v + halfH, 2 * unit)
                    value = Int(sheet[sy * sw + sx])
                } else if shadow > 0 && abs(u) < outerW && abs(v) < outerH {
                    value = 200 + noise.noise()
                } else {
                    value = backdrop + noise.noise()
                }
                p[y * width + x] = clamp(value)
            }
        }
        return GrayImage(width: width, height: height, pixels: p)
    }

    /// `textLine` on the sheet of `sheetOnBackdrop`.
    private static func sheetTextLine(_ p: inout [UInt8], _ x: Int, _ y: Int, _ maxWidth: Int, _ ink: UInt8, _ rng: Rng) {
        let picks = [0b00111, 0b01011, 0b01101, 0b01110, 0b10011, 0b10101, 0b10110, 0b11001, 0b11010, 0b11100]
        func bar(_ bx: Int, _ by: Int, _ bw: Int, _ bh: Int) {
            for py in by..<(by + bh) {
                for px in bx..<(bx + bw) { p[py * sheetWidth + px] = ink }
            }
        }
        var cx = x
        while true {
            let glyphs = 2 + rng.below(7)
            if cx + glyphs * 7 > x + maxWidth { break }
            for _ in 0..<glyphs {
                let bits = picks[rng.below(10)]
                if bits & 1 != 0 { bar(cx, y, 1, 9) }
                if bits & 2 != 0 { bar(cx + 4, y, 1, 9) }
                if bits & 4 != 0 { bar(cx, y, 5, 1) }
                if bits & 8 != 0 { bar(cx, y + 4, 5, 1) }
                if bits & 16 != 0 { bar(cx, y + 8, 5, 1) }
                cx += 7
            }
            cx += 7
        }
    }

    // MARK: - Receipts

    static let minus3 = Turn(sin: -3430, cos: 65446)

    /// The glass of the receipt beds: 8.5 × 11.7 in at 100 dpi.
    static let bedWidth = 850
    static let bedHeight = 1170

    /// A receipt's own pixels, before it is laid on a bed.
    struct ReceiptSheet {
        let pixels: [UInt8]
        let width: Int
        let height: Int
    }

    /// A receipt `width` × `height` px: `paper` with noise and `lines` lines of print (`ink`) every 18 px
    /// from 0.3 in down, 0.2 in from the sides: items from the left (2–4 words) and, on every other line,
    /// a price of 4 glyphs against the right margin, `priceGap` px or more after the items.
    static func receipt(_ width: Int, _ height: Int, paper: Int, ink: UInt8, lines: Int, seed: UInt32,
                        priceGap: Int = 0) -> ReceiptSheet {
        var p = [UInt8](repeating: 0, count: width * height)
        let rng = Rng(seed)
        for i in 0..<p.count { p[i] = clamp(paper + rng.noise()) }
        let text = Rng(seed ^ 0x3EC3_E1F7)
        let priceX = width - 20 - 4 * 7
        let itemsEnd = priceGap > 0 ? priceX - priceGap : width - 20
        for line in 0..<lines {
            let y = 30 + line * 18
            if y + 9 > height { break }
            var x = 20
            let words = 2 + text.below(3)
            for _ in 0..<words {
                let glyphs = 2 + text.below(5)
                if x + glyphs * 7 > itemsEnd { break }
                x = receiptGlyphs(&p, width, x, y, glyphs, ink, text) + 7
            }
            if line % 2 == 1 { _ = receiptGlyphs(&p, width, priceX, y, 4, ink, text) }
        }
        return ReceiptSheet(pixels: p, width: width, height: height)
    }

    /// `glyphs` glyphs (as `textLine` draws them) from (x, y) on a sheet `pitch` px wide; returns the x
    /// after the last.
    private static func receiptGlyphs(_ p: inout [UInt8], _ pitch: Int, _ x: Int, _ y: Int, _ glyphs: Int,
                                      _ ink: UInt8, _ rng: Rng) -> Int {
        let picks = [0b00111, 0b01011, 0b01101, 0b01110, 0b10011, 0b10101, 0b10110, 0b11001, 0b11010, 0b11100]
        func bar(_ bx: Int, _ by: Int, _ bw: Int, _ bh: Int) {
            for py in by..<(by + bh) {
                for px in bx..<(bx + bw) { p[py * pitch + px] = ink }
            }
        }
        var cx = x
        for _ in 0..<glyphs {
            let bits = picks[rng.below(10)]
            if bits & 1 != 0 { bar(cx, y, 1, 9) }
            if bits & 2 != 0 { bar(cx + 4, y, 1, 9) }
            if bits & 4 != 0 { bar(cx, y, 5, 1) }
            if bits & 8 != 0 { bar(cx, y + 4, 5, 1) }
            if bits & 16 != 0 { bar(cx, y + 8, 5, 1) }
            cx += 7
        }
        return cx
    }

    /// A receipt laid on the bed: its center (in pixels) and its turn, clockwise on screen.
    struct Placed {
        let sheet: ReceiptSheet
        let centerX: Int
        let centerY: Int
        let turn: Turn
    }

    /// The 850 × 1170 glass (`backdrop` with noise) with the receipts laid on it, each turned about
    /// its center (nearest pixel).
    static func receiptBed(backdrop: Int, seed: UInt32, _ receipts: [Placed]) -> GrayImage {
        var p = [UInt8](repeating: 0, count: bedWidth * bedHeight)
        let noise = Rng(seed)
        for y in 0..<bedHeight {
            for x in 0..<bedWidth {
                var value = backdrop + noise.noise()
                for r in receipts {
                    if let v = sheetPixel(r, x, y) { value = v }
                }
                p[y * bedWidth + x] = clamp(value)
            }
        }
        return GrayImage(width: bedWidth, height: bedHeight, pixels: p)
    }

    /// The receipt's pixel at bed pixel (x, y), or nil when the receipt does not cover it.
    private static func sheetPixel(_ r: Placed, _ x: Int, _ y: Int) -> Int? {
        let sw = r.sheet.width, sh = r.sheet.height
        let unit = 65536
        let dx = 2 * (x - r.centerX) + 1, dy = 2 * (y - r.centerY) + 1
        let u = dx * r.turn.cos + dy * r.turn.sin
        let v = -dx * r.turn.sin + dy * r.turn.cos
        let halfW = sw * unit, halfH = sh * unit
        if abs(u) >= halfW || abs(v) >= halfH { return nil }
        let sx = floorDiv(u + halfW, 2 * unit), sy = floorDiv(v + halfH, 2 * unit)
        return Int(r.sheet.pixels[sy * sw + sx])
    }

    /// The bed pixels where the receipt's print (pixels at or below `ink`) lands.
    static func printOnBed(_ r: Placed, ink: UInt8) -> [CGPoint] {
        var points: [CGPoint] = []
        for y in 0..<bedHeight {
            for x in 0..<bedWidth {
                if let v = sheetPixel(r, x, y), v <= Int(ink) { points.append(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)) }
            }
        }
        return points
    }

    /// Division rounding down (toward minus infinity), for negative offsets too.
    // MARK: - Patch codes

    /// The turn of ±2.5°, as fixed-point sine and cosine.
    static let plus2Point5 = Turn(sin: 2859, cos: 65474)
    static let minus2Point5 = Turn(sin: -2859, cos: 65474)

    /// A separator sheet drawn at the standard widths at 100 dpi (narrow bars and gaps 8 px, wide bars
    /// 20 px, value 20) on noisy paper: `code`'s bars `length` px long, across the page from (275, 200)
    /// down, or with `vertical` down the page from (200, 400) across; five lines of text from y 850;
    /// the whole page turned clockwise by `turn`.
    static func patchPage(_ code: PatchCode, vertical: Bool, _ turn: Turn, length: Int = 300) -> GrayImage {
        let page = noisy(0x9A7C_0DE5, 245) { p in
            var pos = 200
            for wide in code.bars {
                let thickness = wide ? 20 : 8
                if vertical {
                    fill(&p, pos, 400, thickness, length, 20)
                } else {
                    fill(&p, 275, pos, length, thickness, 20)
                }
                pos += thickness + 8
            }
            let rng = Rng(0x9A7C_0DE6)
            for line in 0..<5 { textLine(&p, 100, 850 + line * 28, 650, 40, rng) }
        }
        return turned(page, turn, fill: 245)
    }

    /// A ruled table on noisy paper, long lines that are no patch code: a dark header band 24 px tall
    /// with a 2 px rule under it, 20 more rules every 28 px, four column rules, and under the table
    /// ten stripes 6 px tall, 8 px apart.
    static func ruledTable() -> GrayImage {
        noisy(0x7AB1_E000, 245) { p in
            fill(&p, 100, 150, 650, 24, 40)
            for row in 0...20 { fill(&p, 100, 174 + row * 28, 650, 2, 40) }
            for x in [100, 300, 500, 748] { fill(&p, x, 150, 2, 24 + 20 * 28 + 2, 40) }
            for k in 0..<10 { fill(&p, 100, 820 + k * 14, 650, 6, 40) }
        }
    }

    /// The page turned half a turn (each pixel to the opposite corner).
    static func halfTurned(_ page: GrayImage) -> GrayImage {
        GrayImage(width: page.width, height: page.height, pixels: Array(page.pixels.reversed()), dpi: page.dpi)
    }

    /// The page turned a quarter turn clockwise.
    static func quarterTurned(_ page: GrayImage) -> GrayImage {
        let w = page.width, h = page.height
        var p = [UInt8](repeating: 0, count: w * h)
        // The new page is h wide and w tall; its pixel (x, y) is the old (y, h - 1 - x).
        for y in 0..<w {
            for x in 0..<h { p[y * h + x] = page.pixels[(h - 1 - x) * w + y] }
        }
        return GrayImage(width: h, height: w, pixels: p, dpi: page.dpi)
    }

    static func floorDiv(_ a: Int, _ b: Int) -> Int {
        a >= 0 ? a / b : -((-a + b - 1) / b)
    }

    // MARK: - Drawing

    /// Paper of one value with noise, then `draw` on top.
    static func noisy(_ seed: UInt32, _ paper: Int, _ draw: (inout [UInt8]) -> Void) -> GrayImage {
        let rng = Rng(seed)
        var p = [UInt8](repeating: 0, count: width * height)
        for i in 0..<p.count { p[i] = clamp(paper + rng.noise()) }
        draw(&p)
        return GrayImage(width: width, height: height, pixels: p)
    }

    /// A line of text-like glyphs from (x, y), up to `maxWidth` wide: words of 2–8 glyphs, each
    /// glyph 5 × 9 px in a 7 px cell made of three of five strokes (left, right, top, middle,
    /// bottom). `ink` is the value written.
    static func textLine(_ p: inout [UInt8], _ x: Int, _ y: Int, _ maxWidth: Int, _ ink: UInt8, _ rng: Rng) {
        // The ten ways to pick three of the five strokes.
        let picks = [0b00111, 0b01011, 0b01101, 0b01110, 0b10011, 0b10101, 0b10110, 0b11001, 0b11010, 0b11100]
        var cx = x
        while true {
            let glyphs = 2 + rng.below(7)
            if cx + glyphs * 7 > x + maxWidth { break }
            for _ in 0..<glyphs {
                let bits = picks[rng.below(10)]
                if bits & 1 != 0 { fill(&p, cx, y, 1, 9, ink) }
                if bits & 2 != 0 { fill(&p, cx + 4, y, 1, 9, ink) }
                if bits & 4 != 0 { fill(&p, cx, y, 5, 1, ink) }
                if bits & 8 != 0 { fill(&p, cx, y + 4, 5, 1, ink) }
                if bits & 16 != 0 { fill(&p, cx, y + 8, 5, 1, ink) }
                cx += 7
            }
            cx += 7
        }
    }

    /// A straight pen stroke `thickness` px wide from (x0, y0) to (x1, y1).
    static func stroke(_ p: inout [UInt8], _ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, _ thickness: Int, _ ink: UInt8) {
        let dx = x1 - x0, dy = y1 - y0
        let steps = max(abs(dx), abs(dy))
        for i in 0...steps {
            let x = x0 + (steps == 0 ? 0 : dx * i / steps)
            let y = y0 + (steps == 0 ? 0 : dy * i / steps)
            fill(&p, x - thickness / 2, y - thickness / 2, thickness, thickness, ink)
        }
    }

    static func fill(_ p: inout [UInt8], _ x: Int, _ y: Int, _ w: Int, _ h: Int, _ value: UInt8) {
        let y0 = max(0, y), y1 = min(height, y + h)
        let x0 = max(0, x), x1 = min(width, x + w)
        guard y0 < y1, x0 < x1 else { return }
        for py in y0..<y1 {
            for px in x0..<x1 { p[py * width + px] = value }
        }
    }

    static func disc(_ p: inout [UInt8], _ cx: Int, _ cy: Int, _ r: Int, _ value: UInt8) {
        for y in (cy - r)...(cy + r) {
            for x in (cx - r)...(cx + r) {
                if x < 0 || y < 0 || x >= width || y >= height { continue }
                if (x - cx) * (x - cx) + (y - cy) * (y - cy) <= r * r { p[y * width + x] = value }
            }
        }
    }

    static func clamp(_ value: Int) -> UInt8 {
        UInt8(min(255, max(0, value)))
    }

    /// A gray page as an RGBA scan at `factor` times the resolution (each pixel repeated).
    static func enlarged(_ page: GrayImage, _ factor: Int) -> RgbaImage {
        let w = page.width * factor, h = page.height * factor
        var rgba = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let v = page.pixels[(y / factor) * page.width + x / factor]
                let i = (y * w + x) * 4
                rgba[i] = v
                rgba[i + 1] = v
                rgba[i + 2] = v
            }
        }
        return RgbaImage(width: w, height: h, pixels: rgba)
    }

    // MARK: - Book spreads

    /// A gray canvas of any size, for the spreads (the pages above are `width` × `height`): paper
    /// with noise, text blocks and the spine's shadow drawn on it.
    final class Canvas {
        let canvasWidth: Int
        let canvasHeight: Int
        var p: [UInt8]

        /// `paper` with scanner noise from `seed`.
        init(_ width: Int, _ height: Int, paper: Int, seed: UInt32) {
            canvasWidth = width
            canvasHeight = height
            p = [UInt8](repeating: 0, count: width * height)
            let rng = Rng(seed)
            for i in 0..<p.count { p[i] = TestPages.clamp(paper + rng.noise()) }
        }

        func fillRect(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ value: UInt8) {
            let y0 = max(0, y), y1 = min(canvasHeight, y + h)
            let x0 = max(0, x), x1 = min(canvasWidth, x + w)
            guard y0 < y1, x0 < x1 else { return }
            for py in y0..<y1 {
                for px in x0..<x1 { p[py * canvasWidth + px] = value }
            }
        }

        /// `lines` lines of glyphs (as `textLine`: words of 2–8 glyphs, 5 × 9 px in 7 px cells) from
        /// (x, y), each up to `maxWidth` wide, every `pitch` px.
        func textBlock(_ x: Int, _ y: Int, maxWidth: Int, lines: Int, pitch: Int, ink: UInt8, _ rng: Rng) {
            let picks = [0b00111, 0b01011, 0b01101, 0b01110, 0b10011, 0b10101, 0b10110, 0b11001, 0b11010, 0b11100]
            for line in 0..<lines {
                var cx = x
                let ly = y + line * pitch
                while true {
                    let glyphs = 2 + rng.below(7)
                    if cx + glyphs * 7 > x + maxWidth { break }
                    for _ in 0..<glyphs {
                        let bits = picks[rng.below(10)]
                        if bits & 1 != 0 { fillRect(cx, ly, 1, 9, ink) }
                        if bits & 2 != 0 { fillRect(cx + 4, ly, 1, 9, ink) }
                        if bits & 4 != 0 { fillRect(cx, ly, 5, 1, ink) }
                        if bits & 8 != 0 { fillRect(cx, ly + 4, 5, 1, ink) }
                        if bits & 16 != 0 { fillRect(cx, ly + 8, 5, 1, ink) }
                        cx += 7
                    }
                    cx += 7
                }
            }
        }

        /// The spine's shadow on the columns around `x0`: each darkened by `depthPerMille`‰ × (r² − d²) / r²
        /// at d columns from it (|d| < r).
        func shadowColumns(_ x0: Int, r: Int, depthPerMille: Int) {
            let from = max(0, x0 - r + 1), to = min(canvasWidth, x0 + r)
            guard from < to else { return }
            for x in from..<to {
                let d = x - x0
                let k = depthPerMille * (r * r - d * d) / (r * r)
                for y in 0..<canvasHeight {
                    let i = y * canvasWidth + x
                    p[i] = UInt8(Int(p[i]) * (1000 - k) / 1000)
                }
            }
        }

        /// A crease across the page: the rows around `y0` darkened as `shadowColumns` darkens columns.
        func shadowRows(_ y0: Int, r: Int, depthPerMille: Int) {
            let from = max(0, y0 - r + 1), to = min(canvasHeight, y0 + r)
            guard from < to else { return }
            for y in from..<to {
                let d = y - y0
                let k = depthPerMille * (r * r - d * d) / (r * r)
                for x in 0..<canvasWidth {
                    let i = y * canvasWidth + x
                    p[i] = UInt8(Int(p[i]) * (1000 - k) / 1000)
                }
            }
        }

        /// A printed picture: the rectangle (x, y, w, h) filled with a mid-tone texture, 60 + (7x + 13y) mod 176
        /// (diagonal ramps from dark gray to near white).
        func picture(_ x: Int, _ y: Int, _ w: Int, _ h: Int) {
            let y0 = max(0, y), y1 = min(canvasHeight, y + h)
            let x0 = max(0, x), x1 = min(canvasWidth, x + w)
            guard y0 < y1, x0 < x1 else { return }
            for py in y0..<y1 {
                for px in x0..<x1 { p[py * canvasWidth + px] = UInt8(60 + (px * 7 + py * 13) % 176) }
            }
        }

        /// The spine's shadow along the right edge, `width` px wide: the column d px from the edge darkened by
        /// k × (width − d)² / width² ‰, where k runs from `depthTop` ‰ on the first row to `depthBottom` ‰ on
        /// the last (a book pressed harder at one end).
        func spineShadow(width: Int, depthTop: Int, depthBottom: Int) {
            let columns = min(width, canvasWidth)
            guard columns > 0 else { return }
            for y in 0..<canvasHeight {
                let depth = depthTop + (depthBottom - depthTop) * y / max(1, canvasHeight - 1)
                for d in 0..<columns {
                    let k = depth * (width - d) * (width - d) / (width * width)
                    let i = y * canvasWidth + canvasWidth - 1 - d
                    p[i] = UInt8(Int(p[i]) * (1000 - k) / 1000)
                }
            }
        }

        func gray() -> GrayImage {
            GrayImage(width: canvasWidth, height: canvasHeight, pixels: p)
        }
    }

    /// An 11 × 8.5 in spread at 100 dpi (1100 × 850 unless given): two pages of text, 33 lines every
    /// 0.2 in from y = 90, each page's text from its outer margin to its inner one (`innerMargin` px
    /// either side of the spine at `gutterX`), with the spine's shadow (`Canvas.shadowColumns`) when
    /// `shadowDepth` is above 0. Either page can be blank.
    static func spread(_ gutterX: Int, innerMargin: Int, outerMargin: Int, shadowDepth: Int, shadowRadius: Int,
                       seed: UInt32, width spreadWidth: Int = 1100, height spreadHeight: Int = 850,
                       blankLeft: Bool = false, blankRight: Bool = false) -> GrayImage {
        let c = Canvas(spreadWidth, spreadHeight, paper: 245, seed: seed)
        let rng = Rng(seed ^ 0x5A5A_5A5A)
        let lines = (spreadHeight - 180) / 20
        if !blankLeft {
            c.textBlock(outerMargin, 90, maxWidth: gutterX - innerMargin - outerMargin, lines: lines, pitch: 20, ink: 40, rng)
        }
        if !blankRight {
            c.textBlock(gutterX + innerMargin, 90, maxWidth: spreadWidth - outerMargin - gutterX - innerMargin,
                        lines: lines, pitch: 20, ink: 40, rng)
        }
        if shadowDepth > 0 { c.shadowColumns(gutterX, r: shadowRadius, depthPerMille: shadowDepth) }
        return c.gray()
    }

    /// A spread with the spine's shadow (25 % deep) at 0.52 of the width and narrow (0.2 in) inner margins.
    static func shadowSpread() -> GrayImage {
        spread(572, innerMargin: 20, outerMargin: 80, shadowDepth: 250, shadowRadius: 17, seed: 0xB00C_0001)
    }

    /// A spread with no shadow, its pages' text 0.6 in either side of the spine at the middle.
    static func marginSpread() -> GrayImage {
        spread(550, innerMargin: 60, outerMargin: 80, shadowDepth: 0, shadowRadius: 0, seed: 0xB00C_0002)
    }

    /// The spread of `shadowSpread`'s kind with a blank left page.
    static func blankFacingSpread() -> GrayImage {
        spread(550, innerMargin: 40, outerMargin: 80, shadowDepth: 250, shadowRadius: 17, seed: 0xB00C_0003, blankLeft: true)
    }

    /// A single letter page: 45 lines of text 6.5 in long across the middle.
    static func singlePageAcross() -> GrayImage {
        let c = Canvas(850, 1100, paper: 245, seed: 0xB00C_0004)
        c.textBlock(100, 100, maxWidth: 650, lines: 45, pitch: 20, ink: 40, Rng(0xB00C_0005))
        return c.gray()
    }

    /// A single letter page in two columns 0.3 in apart.
    static func twoColumnPage() -> GrayImage {
        let c = Canvas(850, 1100, paper: 245, seed: 0xB00C_0006)
        c.textBlock(80, 100, maxWidth: 330, lines: 45, pitch: 20, ink: 40, Rng(0xB00C_0007))
        c.textBlock(440, 100, maxWidth: 330, lines: 45, pitch: 20, ink: 40, Rng(0xB00C_0008))
        return c.gray()
    }

    /// A single letter page with a 1 in gap between two sections, across the middle.
    static func sectionGapPage() -> GrayImage {
        let c = Canvas(850, 1100, paper: 245, seed: 0xB00C_0009)
        c.textBlock(100, 100, maxWidth: 650, lines: 20, pitch: 20, ink: 40, Rng(0xB00C_000A))
        c.textBlock(100, 600, maxWidth: 650, lines: 22, pitch: 20, ink: 40, Rng(0xB00C_000B))
        return c.gray()
    }

    /// A letter folded in three: `singlePageAcross`'s text with two creases between its lines.
    static func foldedLetter() -> GrayImage {
        let c = Canvas(850, 1100, paper: 245, seed: 0xB00C_0004)
        c.textBlock(100, 100, maxWidth: 650, lines: 45, pitch: 20, ink: 40, Rng(0xB00C_0005))
        c.shadowRows(354, r: 10, depthPerMille: 120)
        c.shadowRows(734, r: 10, depthPerMille: 120)
        return c.gray()
    }

    /// A spread whose left page holds a short centered title (2.5 in wide) and whose right page is text, the
    /// spine at 550 of 1100, with the spine's shadow when `shadowDepth` is above 0.
    static func titleFacingText(_ shadowDepth: Int) -> GrayImage {
        let c = Canvas(1100, 850, paper: 245, seed: 0xB00C_000F)
        let rng = Rng(0xB00C_0010)
        c.textBlock(150, 250, maxWidth: 250, lines: 6, pitch: 20, ink: 40, rng)
        c.textBlock(590, 90, maxWidth: 430, lines: 33, pitch: 20, ink: 40, rng)
        if shadowDepth > 0 { c.shadowColumns(550, r: 17, depthPerMille: shadowDepth) }
        return c.gray()
    }

    /// A single page lying on the right half of the glass: its left edge a dark line at x = 420 of 1100.
    static func pageBesideEmptyGlass() -> GrayImage {
        let c = Canvas(1100, 850, paper: 250, seed: 0xB00C_000C)
        c.fillRect(420, 0, 3, 850, 150)
        c.textBlock(500, 90, maxWidth: 520, lines: 34, pitch: 20, ink: 40, Rng(0xB00C_000D))
        return c.gray()
    }

    // MARK: - Book pages with the spine's shadow

    /// One page of a book as cut from its spread, at 100 dpi (5.5 × 8.5 in, 550 × 850), the spine along its
    /// right edge: 36 lines of text every 0.2 in from y = 60, from 0.6 in from the outer edge to 0.3 in from
    /// the spine; with `picture`, a picture 1.3 × 2.2 in at (400, 300), 0.2 in from the spine; with `tint`, a
    /// flat gray band (150) 1.2 in long and 1 in tall reaching the spine at (430, 640); then the spine's
    /// shadow (`Canvas.spineShadow`, `shadowWidth` px wide) when `depthTop` or `depthBottom` is above 0. The
    /// same arguments with no depth give the page as it would be without the shadow.
    static func bookPage(_ depthTop: Int, _ depthBottom: Int, _ shadowWidth: Int, seed: UInt32,
                         picture: Bool = false, tint: Bool = false) -> GrayImage {
        let c = Canvas(550, 850, paper: 245, seed: seed)
        c.textBlock(60, 60, maxWidth: 460, lines: 36, pitch: 20, ink: 40, Rng(seed ^ 0x5A5A_5A5A))
        if picture { c.picture(400, 300, 130, 220) }
        if tint { c.fillRect(430, 640, 120, 100, 150) }
        if depthTop > 0 || depthBottom > 0 { c.spineShadow(width: shadowWidth, depthTop: depthTop, depthBottom: depthBottom) }
        return c.gray()
    }

    /// A book page with a shadow 0.8 in wide, 45 % deep at the top of the spine and 30 % at the bottom.
    static func shadowedBookPage() -> GrayImage { bookPage(450, 300, 80, seed: 0xB00C_0020) }

    /// `shadowedBookPage` as it would be without the shadow.
    static func unshadowedBookPage() -> GrayImage { bookPage(0, 0, 80, seed: 0xB00C_0020) }

    /// A book page with a picture near the spine, in a shadow 0.8 in wide and 40 % deep.
    static func pictureBookPage() -> GrayImage { bookPage(400, 400, 80, seed: 0xB00C_0021, picture: true) }

    /// `pictureBookPage` as it would be without the shadow.
    static func unshadowedPictureBookPage() -> GrayImage { bookPage(0, 0, 80, seed: 0xB00C_0021, picture: true) }

    /// A book page with a flat gray band reaching the spine, in a shadow 0.8 in wide and 40 % deep.
    static func tintBookPage() -> GrayImage { bookPage(400, 400, 80, seed: 0xB00C_0022, tint: true) }

    /// An open book at 100 dpi (11 × 8.5 in): `shadowedBookPage` on the left and the same page mirrored on
    /// the right, so the spine lies at the middle (x = 550) in the shadow of both.
    static func shadowedBookSpread() -> GrayImage {
        let page = shadowedBookPage()
        let w = page.width, h = page.height
        var p = [UInt8](repeating: 0, count: 2 * w * h)
        for y in 0..<h {
            for x in 0..<w {
                let v = page.pixels[y * w + x]
                p[y * 2 * w + x] = v
                p[y * 2 * w + 2 * w - 1 - x] = v
            }
        }
        return GrayImage(width: 2 * w, height: h, pixels: p)
    }

    /// FNV-1a of the pixels: one number per page, the same on both platforms.
    static func checksum(_ page: GrayImage) -> UInt32 {
        var hash: UInt32 = 2_166_136_261
        for b in page.pixels {
            hash ^= UInt32(b)
            hash = hash &* 16_777_619
        }
        return hash
    }
}
