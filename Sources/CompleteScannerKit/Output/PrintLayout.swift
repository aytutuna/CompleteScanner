import CoreGraphics
import Foundation

// Twin of windows/CompleteScanner.Core/PrintLayout.cs: where a scan goes on the paper when it is
// printed (the Copy task, the ID card page, the ruler test page). Printing at real size is the
// point: a page scanned at 300 dpi prints at pixels / 300 inches, never scaled to the page unless
// the user asks for it.

/// How a page is sized on the paper.
public enum PrintMode: Sendable {
    /// At real size (pixels / dpi), like a photocopier; what does not fit is cut off.
    case actualSize
    /// Made smaller (never larger) to fit the part of the paper the printer prints on.
    case fitToPrintable
}

/// Where a page printed at real size goes on the paper.
public enum PrintAlign: Sendable {
    /// Against the top-left corner of the paper, where the original lay against the corner of the glass.
    case paperOrigin
    /// In the middle of the paper: an area selected on the preview.
    case center
}

/// The paper a printer prints on and the part of it it can print on (inside its margins), in inches
/// with the origin at the top-left corner of the paper, portrait as the paper is fed.
public struct PrinterPaper: Equatable, Sendable {
    public let paper: CGSize
    public let printable: CGRect

    public init(paper: CGSize, printable: CGRect) {
        self.paper = paper
        self.printable = printable
    }

    /// `paper` with `printable` clamped to it; a missing or empty printable area (a driver that does
    /// not say) is the whole sheet.
    public static func make(paper: CGSize, printable: CGRect?) -> PrinterPaper {
        let whole = CGRect(x: 0, y: 0, width: Double(paper.width), height: Double(paper.height))
        guard let printable else { return PrinterPaper(paper: paper, printable: whole) }
        let clamped = printable.standardized.intersection(whole)
        return PrinterPaper(paper: paper, printable: clamped.isNull || clamped.isEmpty ? whole : clamped)
    }

    /// The named size the paper is (`PaperSizes.match`); nil for any other size.
    public var size: PaperSize? { PaperSizes.match(paper) }

    /// The widest edge the printer cannot print on, in inches.
    public var largestMargin: Double {
        max(max(Double(printable.minX), Double(printable.minY)),
            max(Double(paper.width) - Double(printable.maxX), Double(paper.height) - Double(printable.maxY)))
    }

    /// "Letter (8.5 × 11 in)", "A4 (210 × 297 mm)", or "8.27 × 11.69 in" for a size without a name.
    public var description: String {
        if let size { return "\(size.label) (\(size.detail))" }
        return "\(PrintLayout.inchesText(Double(paper.width))) \u{00D7} \(PrintLayout.inchesText(Double(paper.height))) in"
    }
}

/// Where a page goes on the paper, in inches from the paper's top-left corner, and how: its scale (1
/// at real size), how many quarter turns clockwise it is turned first, and how far it runs past the
/// part of the paper the printer prints on.
public struct PrintPlacement: Equatable, Sendable {
    public let rect: CGRect
    public let scale: Double
    public let quarterTurns: Int
    public let clippedInches: Double

    public init(rect: CGRect, scale: Double, quarterTurns: Int, clippedInches: Double) {
        self.rect = rect
        self.scale = scale
        self.quarterTurns = quarterTurns
        self.clippedInches = clippedInches
    }

    /// Enough is cut off to say so (more than `PrintLayout.clipWarningInches`).
    public var isClipped: Bool { clippedInches > PrintLayout.clipWarningInches }
}

/// Places pages on the paper for printing (see `PrintMode` and `PrintAlign`). Twin of C# `PrintLayout`.
public enum PrintLayout {
    /// Less than this much cut off (about 1 mm) is not worth a warning.
    public static let clipWarningInches = 0.05

    /// Wiggle room for comparing lengths in inches.
    private static let epsilon = 1e-9

    /// Where a scan `pixelWidth` × `pixelHeight` at `dpi` goes on `paper` (inches) whose printer
    /// prints on `printable`. At real size the page is pixels / dpi inches, against the paper's corner
    /// or centred on the paper (`align`), turned a quarter only when that cuts off less;
    /// `clippedInches` says how far it runs past the printable area. Fit to the printable area makes
    /// it smaller by min(printable width / width, printable height / height, 1), turned a quarter when
    /// that gives a larger scale, centred in the printable area.
    public static func place(pixelWidth: Int, pixelHeight: Int, dpi: Int, paper: CGSize, printable: CGRect,
                             mode: PrintMode, align: PrintAlign) -> PrintPlacement {
        let resolution = Double(max(1, dpi))
        let width = Double(max(0, pixelWidth)) / resolution
        let height = Double(max(0, pixelHeight)) / resolution
        let paperWidth = Double(paper.width), paperHeight = Double(paper.height)
        var area = printable.standardized
        if area.isEmpty { area = CGRect(x: 0, y: 0, width: paperWidth, height: paperHeight) }

        if mode == .fitToPrintable {
            let upright = fitScale(width, height, area)
            let turned = fitScale(height, width, area)
            let turns = turned > upright + epsilon ? 1 : 0
            let scale = max(upright, turned)
            let w = (turns == 1 ? height : width) * scale
            let h = (turns == 1 ? width : height) * scale
            let fitted = CGRect(x: Double(area.minX) + (Double(area.width) - w) / 2,
                                y: Double(area.minY) + (Double(area.height) - h) / 2,
                                width: w, height: h)
            return PrintPlacement(rect: fitted, scale: scale, quarterTurns: turns,
                                  clippedInches: clippedInches(fitted, printable: area))
        }

        let quarterTurns = overflow(height, width, paperWidth, paperHeight) + epsilon
            < overflow(width, height, paperWidth, paperHeight) ? 1 : 0
        let rw = quarterTurns == 1 ? height : width
        let rh = quarterTurns == 1 ? width : height
        let rect = align == .center
            ? CGRect(x: (paperWidth - rw) / 2, y: (paperHeight - rh) / 2, width: rw, height: rh)
            : CGRect(x: 0, y: 0, width: rw, height: rh)
        return PrintPlacement(rect: rect, scale: 1, quarterTurns: quarterTurns,
                              clippedInches: clippedInches(rect, printable: area))
    }

    /// `place(pixelWidth:pixelHeight:dpi:paper:printable:mode:align:)` on a printer's paper.
    public static func place(pixelWidth: Int, pixelHeight: Int, dpi: Int, on paper: PrinterPaper,
                             mode: PrintMode, align: PrintAlign) -> PrintPlacement {
        place(pixelWidth: pixelWidth, pixelHeight: pixelHeight, dpi: dpi, paper: paper.paper,
              printable: paper.printable, mode: mode, align: align)
    }

    /// How far `rect` runs past `printable` on its worst side, in inches (0 inside it).
    public static func clippedInches(_ rect: CGRect, printable: CGRect) -> Double {
        let r = rect.standardized
        let p = printable.standardized
        let worst = max(max(Double(p.minX) - Double(r.minX), Double(p.minY) - Double(r.minY)),
                        max(Double(r.maxX) - Double(p.maxX), Double(r.maxY) - Double(p.maxY)))
        return worst > epsilon ? worst : 0
    }

    /// A rectangle in inches in other units: 96 for WPF's device-independent pixels, 72 for points.
    public static func toUnits(_ inches: CGRect, unitsPerInch: Double) -> CGRect {
        CGRect(x: Double(inches.origin.x) * unitsPerInch, y: Double(inches.origin.y) * unitsPerInch,
               width: Double(inches.width) * unitsPerInch, height: Double(inches.height) * unitsPerInch)
    }

    /// A size in inches in other units (96 for WPF, 72 for points).
    public static func toUnits(_ inches: CGSize, unitsPerInch: Double) -> CGSize {
        CGSize(width: Double(inches.width) * unitsPerInch, height: Double(inches.height) * unitsPerInch)
    }

    /// A copy of the whole glass or of a page lies against the corner, as it lay on the glass; an
    /// area selected on the preview is centred.
    public static func align(hasSelection: Bool) -> PrintAlign { hasSelection ? .center : .paperOrigin }

    /// What to tell the user about a page cut off by more than `clipWarningInches`: a page larger
    /// than the paper, or edges in the printer's margins; nil when nothing worth saying is cut off.
    public static func clipWarning(_ placement: PrintPlacement, paper: CGSize) -> String? {
        guard placement.isClipped else { return nil }
        let beyondPaper = clippedInches(placement.rect,
                                        printable: CGRect(x: 0, y: 0, width: Double(paper.width), height: Double(paper.height)))
        return beyondPaper > clipWarningInches
            ? "Larger than the paper: up to \(millimetres(beyondPaper)) mm is cut off. Turn on Fit to page to print all of it."
            : "Edges may be cut by up to \(millimetres(placement.clippedInches)) mm (printer margins)."
    }

    /// Inches as whole millimetres, rounded up (at least 1).
    public static func millimetres(_ inches: Double) -> Int {
        let mm = ((inches * 25.4) * 1_000_000).rounded() / 1_000_000
        return max(1, Int(mm.rounded(.up)))
    }

    /// A length in inches with at most two decimals and no trailing zeros: "8.27", "5", "7.5".
    static func inchesText(_ inches: Double) -> String {
        var text = String(format: "%.2f", inches)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    private static func fitScale(_ width: Double, _ height: Double, _ area: CGRect) -> Double {
        guard width > 0, height > 0 else { return 1 }
        return min(min(Double(area.width) / width, Double(area.height) / height), 1)
    }

    /// How far a page runs past the paper across and down together.
    private static func overflow(_ width: Double, _ height: Double, _ paperWidth: Double, _ paperHeight: Double) -> Double {
        max(0, width - paperWidth) + max(0, height - paperHeight)
    }
}

/// How a number of copies is asked of a printer: the copy count of the job, and how many times the
/// pages are put in it, one after the other (collated).
public struct PrintCopiesPlan: Equatable, Sendable {
    public let ticketCopies: Int
    public let documentRepeats: Int

    public init(ticketCopies: Int, documentRepeats: Int) {
        self.ticketCopies = ticketCopies
        self.documentRepeats = documentRepeats
    }
}

/// The number of copies the user can ask for, and how a printer is asked for them. Twin of C# `PrintCopies`.
public enum PrintCopies {
    /// The most copies asked for at once.
    public static let maxCount = 99

    /// `count` within 1 … `maxCount`.
    public static func clamp(_ count: Int) -> Int { min(max(count, 1), maxCount) }

    /// The printer makes the copies (collated) when it says it can make that many and, for more than
    /// one page, that it collates (`canCollate`); otherwise, and when it does not say, the `pageCount`
    /// pages are put in the job that many times, so the copies come out in order whatever the printer does.
    public static func plan(requested: Int, maxCopyCount: Int?, pageCount: Int = 1, canCollate: Bool = true) -> PrintCopiesPlan {
        let count = clamp(requested)
        if count == 1 { return PrintCopiesPlan(ticketCopies: 1, documentRepeats: 1) }
        if let maxCopyCount, maxCopyCount >= count, pageCount <= 1 || canCollate {
            return PrintCopiesPlan(ticketCopies: count, documentRepeats: 1)
        }
        return PrintCopiesPlan(ticketCopies: 1, documentRepeats: count)
    }
}

/// A test page to check that prints come out at real size. Twin of C# `PrintCalibration`.
public enum PrintCalibration {
    /// A white page `paper` large at `dpi` (round(paper × dpi) pixels) with a grey grid line every
    /// inch from the paper's top-left corner, and centimetre ticks in black along the first inch line
    /// across and down: 0.15 in long, 0.3 in at every 5 cm. Printed at real size, the squares measure
    /// 1 inch and the ticks 1 cm with a ruler.
    public static func makeRulerPage(paper: CGSize, dpi: Int) -> RgbaImage {
        let d = max(1, dpi)
        let width = max(1, pixels(Double(paper.width), d))
        let height = max(1, pixels(Double(paper.height), d))
        var page = RgbaImage.filled(width: width, height: height, r: 255, g: 255, b: 255)
        let t = lineWidth(d)
        var k = 1
        while pixels(Double(k), d) < width {
            fill(&page, x: pixels(Double(k), d) - t / 2, y: 0, w: t, h: height, value: 128)
            k += 1
        }
        k = 1
        while pixels(Double(k), d) < height {
            fill(&page, x: 0, y: pixels(Double(k), d) - t / 2, w: width, h: t, value: 128)
            k += 1
        }
        let shortTick = pixels(0.15, d), longTick = pixels(0.3, d)
        k = 0
        while tickPosition(k, dpi: d) < width {
            fill(&page, x: tickPosition(k, dpi: d) - t / 2, y: d, w: t, h: k % 5 == 0 ? longTick : shortTick, value: 0)
            k += 1
        }
        k = 0
        while tickPosition(k, dpi: d) < height {
            fill(&page, x: d, y: tickPosition(k, dpi: d) - t / 2, w: k % 5 == 0 ? longTick : shortTick, h: t, value: 0)
            k += 1
        }
        return page
    }

    /// The width of the ruler's lines: about 1/150 in, at least one pixel.
    public static func lineWidth(_ dpi: Int) -> Int { max(1, pixels(1.0 / 150, max(1, dpi))) }

    /// The pixel of the `k`-th centimetre tick from the first inch line.
    public static func tickPosition(_ k: Int, dpi: Int) -> Int {
        Int((Double(dpi) + Double(k) * Double(dpi) / 2.54).rounded())
    }

    private static func pixels(_ inches: Double, _ dpi: Int) -> Int { Int((inches * Double(dpi)).rounded()) }

    private static func fill(_ page: inout RgbaImage, x: Int, y: Int, w: Int, h: Int, value: UInt8) {
        let x0 = max(0, x), y0 = max(0, y)
        let x1 = min(page.width, x + w), y1 = min(page.height, y + h)
        guard x1 > x0, y1 > y0 else { return }
        for row in y0..<y1 {
            var i = (row * page.width + x0) * 4
            for _ in x0..<x1 {
                page.pixels[i] = value
                page.pixels[i + 1] = value
                page.pixels[i + 2] = value
                page.pixels[i + 3] = 255
                i += 4
            }
        }
    }
}

/// What the app says about printing. Twin of C# `PrintText`.
public enum PrintText {
    /// Why the Copy task (and printing anything) cannot be started: no printer is installed.
    public static let noPrinterReason = "Needs a printer"

    /// The error when there is nothing to print on.
    public static let noPrinterMessage = "No printer is installed. Add a printer, then try again."

    /// "Sent 1 page to Office Printer.", "Sent 2 pages to Office Printer, 3 copies."
    public static func sent(pageCount: Int, copies: Int, printerName: String) -> String {
        let pages = "\(pageCount) page\(pageCount == 1 ? "" : "s")"
        return copies > 1 ? "Sent \(pages) to \(printerName), \(copies) copies." : "Sent \(pages) to \(printerName)."
    }

    /// "Actual size" or "Fit to page".
    public static func modeLabel(fitToPage: Bool) -> String { fitToPage ? "Fit to page" : "Actual size" }

    /// What the paper size picker says for a copy: on the glass, Automatic scans the part the
    /// printer's paper covers (a copier copies the sheet it prints on); otherwise as `PaperSizes.hint`.
    public static func copyPaperHint(_ size: PaperSize, source: ScanSource) -> String {
        size == .auto && source == .flatbed
            ? "The printer's paper size, from the glass corner"
            : PaperSizes.hint(size, source: source)
    }
}
