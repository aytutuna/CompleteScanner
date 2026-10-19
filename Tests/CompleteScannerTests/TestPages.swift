import Foundation
@testable import CompleteScannerKit

// Twin of windows/CompleteScanner.Core.Tests/TestPages.cs: the same pages, byte for byte. Integer
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

    /// Division rounding down (toward minus infinity), for negative offsets too.
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
