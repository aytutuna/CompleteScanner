import CoreGraphics
import Foundation

// Twin of windows/CompleteScanner.Core/OcrText.cs: same rules, same numbers, same text.

/// The recognized text of one page: the lines as the OCR engine returned them and the page's size
/// in points (any unit works, as long as width and height share it: it only sets how far across
/// counts against how far down). Twin of C# `OcrPage`.
public struct OCRPage {
    public var lines: [OCRLine]
    public var widthPoints: Double
    public var heightPoints: Double

    public init(lines: [OCRLine], widthPoints: Double, heightPoints: Double) {
        self.lines = lines
        self.widthPoints = widthPoints
        self.heightPoints = heightPoints
    }

    /// A page `pixelWidth` × `pixelHeight` pixels scanned at `dpi`.
    public static func of(_ lines: [OCRLine], pixelWidth: Int, pixelHeight: Int, dpi: Int) -> OCRPage {
        let scale = 72.0 / Double(max(dpi, 1))
        return OCRPage(lines: lines, widthPoints: Double(pixelWidth) * scale, heightPoints: Double(pixelHeight) * scale)
    }
}

/// Lines of text that belong together, in reading order. Twin of C# `OcrParagraph`.
public struct OCRParagraph {
    public let lines: [OCRLine]

    public init(lines: [OCRLine]) {
        self.lines = lines
    }

    /// The lines as running text, keeping the line breaks that mean something (`OCRText.paragraphText`).
    public var text: String { OCRText.paragraphText(lines) }
}

/// Turns the lines an OCR engine found on a page into text a person reads: in reading order, split
/// into paragraphs. Shared by the text file, the Word document and Copy Text. Twin of C# `OcrText`.
///
/// Reading order: the page is cut along an empty gap, across or down, again and again (a recursive
/// X-Y cut): first along the widest gap across the page when it is at least `blockGap` line heights
/// tall (between blocks: the upper one is read first), else along the widest gap down the page when
/// it is at least `columnGap` line heights wide and the two sides are columns of text, two lines or
/// more each (the left one first), else along any gap across the page. The two sides are a table
/// instead (dishes and their prices) when most lines on each side share their row with a line on
/// the other side and the gap is at least as wide as the narrower side's lines: a table is read row
/// by row. Lines that share a row and have no wide gap between them are one line of text, read left
/// to right; pieces of one row further apart (a price after a dish, a cell of a table) are kept on
/// the row, separated by a tab.
///
/// Paragraphs: a new one starts where the text jumps up (the next column), where the gap above a
/// line is clearly wider than the usual gap (the smaller of the page's median gap and the gaps next
/// to it), where its left edge moves by more than a fifth of the page, and where a line is indented
/// against the one before; lines centred on each other (a heading, a letterhead) are neither
/// indented nor moved. In a paragraph's text a line that wrapped is joined to the next with a space,
/// and a line that ends short (an address, a list, a table's row) keeps its break.
public enum OCRText {
    /// A gap down the page this many line heights wide separates columns, and pieces of one row.
    public static let columnGap = 2.0
    /// A gap across the page this many line heights tall separates blocks before columns are looked for.
    public static let blockGap = 1.5
    /// Side by side, row by row, with a gap at least this share of the narrower side's line width: a table.
    public static let tableGapShare = 1.0
    /// Lines overlapping by this share of the lower one's height are on the same row.
    public static let sameRowOverlap = 0.5
    /// A gap above a line wider than this many line heights (at least) starts a paragraph.
    public static let paragraphGap = 0.75
    /// …or wider than this many times the usual gap between lines.
    public static let paragraphGapFactor = 1.5
    /// A line starting this many line heights right of the one before is indented: a new paragraph.
    public static let indentLines = 1.0
    /// A left edge moving by this share of the page width starts a paragraph.
    public static let leftEdgeShift = 0.2
    /// A line ending this share of the page width before the paragraph's longest line keeps its line break.
    public static let shortLineShare = 0.15
    /// Lines whose centres are this many line heights apart, or less, are centred on each other.
    public static let centredLines = 0.25
    /// A line starting this many line heights above the one before jumps to the next column.
    public static let jumpLines = 0.5
    /// What separates the pieces of one row that are far apart.
    public static let cellSeparator = "\t"

    // MARK: Reading order

    /// The lines in reading order. Lines of one row become one line (its box is theirs together, its
    /// confidence their lowest); empty lines are dropped. `pageWidth` and `pageHeight` are the
    /// page's size in any one unit.
    public static func readingOrder(_ lines: [OCRLine], pageWidth: Double = 1, pageHeight: Double = 1) -> [OCRLine] {
        let w = pageWidth > 0 ? pageWidth : 1
        let h = pageHeight > 0 ? pageHeight : 1
        var items: [TextItem] = []
        for line in lines {
            let text = cleanLine(line.text)
            let box = line.boundingBox.standardized
            if text.isEmpty || box.width <= 0 || box.height <= 0 { continue }
            let cleaned = OCRLine(text: text, boundingBox: line.boundingBox, confidence: line.confidence)
            items.append(TextItem(line: cleaned, index: items.count, left: Double(box.minX) * w,
                                  top: (1 - Double(box.maxY)) * h, right: Double(box.maxX) * w,
                                  bottom: (1 - Double(box.minY)) * h))
        }
        var output: [OCRLine] = []
        cut(items, into: &output)
        return output
    }

    /// The paragraphs of a page: its lines in reading order, then split.
    public static func paragraphs(_ page: OCRPage) -> [OCRParagraph] {
        paragraphs(readingOrder(page.lines, pageWidth: page.widthPoints, pageHeight: page.heightPoints),
                   pageWidth: page.widthPoints, pageHeight: page.heightPoints)
    }

    /// `ordered` (lines already in reading order, as `readingOrder` returns them) split into
    /// paragraphs; the order is kept.
    public static func paragraphs(_ ordered: [OCRLine], pageWidth: Double = 1, pageHeight: Double = 1) -> [OCRParagraph] {
        let w = pageWidth > 0 ? pageWidth : 1
        let h = pageHeight > 0 ? pageHeight : 1
        var items: [TextItem] = []
        for line in ordered {
            let box = line.boundingBox.standardized
            items.append(TextItem(line: line, index: items.count, left: Double(box.minX) * w,
                                  top: (1 - Double(box.maxY)) * h, right: Double(box.maxX) * w,
                                  bottom: (1 - Double(box.minY)) * h))
        }
        guard !items.isEmpty else { return [] }

        let lineHeight = median(items.map(\.height))
        // gaps[i]: from line i - 1 down to line i. The page's usual gap is the median of those
        // going down the page.
        var gaps = [Double](repeating: 0, count: items.count)
        for i in 1..<items.count { gaps[i] = items[i].top - items[i - 1].bottom }
        let positive = gaps.dropFirst().filter { $0 > 0 }
        let pageGap = positive.isEmpty ? 0 : median(Array(positive))

        var result: [OCRParagraph] = []
        var current: [OCRLine] = [items[0].line]
        for i in 1..<items.count {
            let previous = items[i - 1]
            let item = items[i]
            // The usual gap here: the page's, or the smaller gap next to this one when that is less
            // (a page with many short paragraphs has a median gap as wide as a paragraph break).
            var usualGap = pageGap
            if i > 1 && gaps[i - 1] > 0 { usualGap = min(usualGap, gaps[i - 1]) }
            if i + 1 < items.count && gaps[i + 1] > 0 { usualGap = min(usualGap, gaps[i + 1]) }
            let breakGap = max(paragraphGap * lineHeight, paragraphGapFactor * usualGap)
            // Centred on each other (a heading, a letterhead): not indented, not moved.
            let centred = abs((item.left + item.right) - (previous.left + previous.right)) / 2
                <= centredLines * lineHeight
            let jumps = item.top < previous.top - jumpLines * lineHeight
            let wideGap = gaps[i] > breakGap
            let moved = !centred && abs(item.left - previous.left) > leftEdgeShift * w
            let indented = !centred && item.left - previous.left > indentLines * lineHeight
            if jumps || wideGap || moved || indented {
                result.append(OCRParagraph(lines: current))
                current = []
            }
            current.append(item.line)
        }
        result.append(OCRParagraph(lines: current))
        return result
    }

    // MARK: Text

    /// The text of a paragraph's lines: a line that wrapped (it reaches to within `shortLineShare`
    /// of the page width of the paragraph's longest line) is joined to the next by a space, or
    /// without the hyphen of a word broken over the two (`joinLines`); a line that ends short, and a
    /// table's row (a line holding a `cellSeparator`), keep their line break ("\n").
    public static func paragraphText(_ lines: [OCRLine]) -> String {
        guard let right = lines.map({ Double($0.boundingBox.standardized.maxX) }).max() else { return "" }
        var result = ""
        var previous: String?
        var previousRight = 0.0
        for line in lines {
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }
            if let previous {
                if previous.contains(cellSeparator) || text.contains(cellSeparator)
                    || previousRight < right - shortLineShare {
                    result += "\n" + text
                } else {
                    appendJoined(text, to: &result)
                }
            } else {
                result = text
            }
            previous = text
            previousRight = Double(line.boundingBox.standardized.maxX)
        }
        return result
    }

    /// The lines of a paragraph as running text: joined by spaces, and a word broken over two lines
    /// ("forward-" then "ing") joined again ("forwarding").
    public static func joinLines(_ lines: [String]) -> String {
        var result = ""
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            if result.isEmpty {
                result = line
            } else {
                appendJoined(line, to: &result)
            }
        }
        return result
    }

    /// The text of one page: one line of text per line on the page, a blank line between
    /// paragraphs, no line break at the end; empty when nothing was recognized.
    public static func pageText(_ page: OCRPage) -> String {
        paragraphs(page).map { $0.lines.map(\.text).joined(separator: "\n") }.joined(separator: "\n\n")
    }

    /// The text of a document (`TextExport`): each page's `pageText`, two blank lines between
    /// pages, and a line break at the end; empty when no page has text. Line breaks are "\n" only.
    public static func plainText(_ pages: [OCRPage]) -> String {
        let texts = pages.map(pageText)
        if texts.allSatisfy(\.isEmpty) { return "" }
        return texts.joined(separator: "\n\n\n") + "\n"
    }

    /// One line of OCR text made safe to write: line breaks and other control characters become
    /// spaces (a tab stays), runs of spaces one space, no space at either end.
    public static func cleanLine(_ text: String) -> String {
        var cleaned = String.UnicodeScalarView()
        var lastWasSpace = true   // drops spaces at the start
        for scalar in text.unicodeScalars {
            var out = scalar
            if scalar.value != 0x09
                && (scalar.properties.generalCategory == .control || scalar.value == 0x2028 || scalar.value == 0x2029) {
                out = " "
            }
            if out == " " {
                if lastWasSpace { continue }
                lastWasSpace = true
            } else {
                lastWasSpace = false
            }
            cleaned.append(out)
        }
        return trimSpacesAndTabs(String(cleaned))
    }

    // MARK: X-Y cut

    /// Joins `text` to the end of `result`: without the hyphen of a word broken over the two lines
    /// (a letter, then "-", then a lowercase letter), else with a space.
    private static func appendJoined(_ text: String, to result: inout String) {
        let tail = Array(result.suffix(2))
        if tail.count == 2, tail[1] == "-", tail[0].isLetter, let first = text.first, first.isLowercase {
            result.removeLast()
            result += text
        } else {
            result += " " + text
        }
    }

    /// `text` without the spaces and tabs at either end.
    private static func trimSpacesAndTabs(_ text: String) -> String {
        var scalars = Array(text.unicodeScalars)
        while let first = scalars.first, first == " " || first == "\t" { scalars.removeFirst() }
        while let last = scalars.last, last == " " || last == "\t" { scalars.removeLast() }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
    }

    /// A line with its place in the engine's list (the last tie-break of every sort) and its box in
    /// page units, origin top-left.
    private struct TextItem {
        let line: OCRLine
        let index: Int
        let left: Double
        let top: Double
        let right: Double
        let bottom: Double
        var height: Double { bottom - top }
    }

    private static func cut(_ items: [TextItem], into output: inout [OCRLine]) {
        if items.isEmpty { return }
        if items.count == 1 || isOneRow(items) {
            output.append(joinRow(items))
            return
        }
        let lineHeight = median(items.map(\.height))

        // The widest gap across the page (between blocks) and down the page (between columns).
        let byTop = items.sorted { a, b in
            if a.top != b.top { return a.top < b.top }
            if a.left != b.left { return a.left < b.left }
            return a.index < b.index
        }
        let (gapY, splitY) = widestGap(byTop, start: { $0.top }, end: { $0.bottom })
        let byLeft = items.sorted { a, b in
            if a.left != b.left { return a.left < b.left }
            if a.top != b.top { return a.top < b.top }
            return a.index < b.index
        }
        let (gapX, splitX) = widestGap(byLeft, start: { $0.left }, end: { $0.right })

        if gapY >= blockGap * lineHeight {
            cut(Array(byTop[0..<splitY]), into: &output)
            cut(Array(byTop[splitY...]), into: &output)
            return
        }
        if gapX >= columnGap * lineHeight {
            let left = Array(byLeft[0..<splitX])
            let right = Array(byLeft[splitX...])
            // A lone line on one side is a heading's neighbour or a cell, not a column.
            if left.count >= 2 && right.count >= 2 && !isTable(left, right, gap: gapX) {
                cut(left, into: &output)
                cut(right, into: &output)
                return
            }
        }
        if gapY > 0 {
            cut(Array(byTop[0..<splitY]), into: &output)
            cut(Array(byTop[splitY...]), into: &output)
            return
        }

        // No gap across the page: a table whose rows touch, or lines that overlap a little (a
        // slanted page). Sort them into rows.
        for row in rows(byTop) { output.append(joinRow(row)) }
    }

    /// The widest empty gap along one axis of `sorted` (sorted by its start): its width and the
    /// index of the first item after it; (0, 0) when the items overlap all the way.
    private static func widestGap(_ sorted: [TextItem], start: (TextItem) -> Double,
                                  end: (TextItem) -> Double) -> (gap: Double, split: Int) {
        var best = 0.0
        var split = 0
        var reach = end(sorted[0])
        for i in 1..<sorted.count {
            let gap = start(sorted[i]) - reach
            if gap > best {
                best = gap
                split = i
            }
            reach = max(reach, end(sorted[i]))
        }
        return (best, split)
    }

    /// The two sides of a gap down the page are a table, read row by row, rather than two columns:
    /// more than half the lines on each side share their row with a line on the other side, and the
    /// gap is at least `tableGapShare` of the narrower side's typical line width (the gutter between
    /// columns of text, or beside a letterhead's list of names, is narrow next to their lines; the
    /// gap before a column of prices is wide).
    private static func isTable(_ left: [TextItem], _ right: [TextItem], gap: Double) -> Bool {
        func mostlyPaired(_ side: [TextItem], _ other: [TextItem]) -> Bool {
            2 * side.filter { item in other.contains { sameRow(item, $0) } }.count > side.count
        }
        let narrower = min(median(left.map { $0.right - $0.left }), median(right.map { $0.right - $0.left }))
        return mostlyPaired(left, right) && mostlyPaired(right, left) && gap >= tableGapShare * narrower
    }

    /// Two lines share at least `sameRowOverlap` of the lower one's height.
    private static func sameRow(_ a: TextItem, _ b: TextItem) -> Bool {
        min(a.bottom, b.bottom) - max(a.top, b.top) >= sameRowOverlap * min(a.height, b.height)
    }

    /// Every line overlaps one band across the page by `sameRowOverlap` of the lowest line's height.
    private static func isOneRow(_ items: [TextItem]) -> Bool {
        let top = items.map(\.top).max() ?? 0
        let bottom = items.map(\.bottom).min() ?? 0
        let lowest = items.map(\.height).min() ?? 0
        return bottom - top >= sameRowOverlap * lowest
    }

    /// Lines that overlap each other a little, sorted into rows: a line joins the row it shares
    /// enough height with and no width; rows top to bottom.
    private static func rows(_ byTop: [TextItem]) -> [[TextItem]] {
        var found: [[TextItem]] = []
        for item in byTop {
            let home = found.firstIndex { row in
                row.allSatisfy { other in
                    sameRow(other, item) && (item.right <= other.left || item.left >= other.right)
                }
            }
            if let home {
                found[home].append(item)
            } else {
                found.append([item])
            }
        }
        return found.sorted { a, b in
            let topA = a.map(\.top).min() ?? 0
            let topB = b.map(\.top).min() ?? 0
            if topA != topB { return topA < topB }
            return a[0].index < b[0].index
        }
    }

    /// One row's lines left to right as one line: a space between them, a tab across a wide gap.
    private static func joinRow(_ row: [TextItem]) -> OCRLine {
        if row.count == 1 { return row[0].line }
        let sorted = row.sorted { a, b in
            if a.left != b.left { return a.left < b.left }
            return a.index < b.index
        }
        let lineHeight = median(sorted.map(\.height))
        var text = sorted[0].line.text
        var reach = sorted[0].right
        for item in sorted.dropFirst() {
            text += item.left - reach >= columnGap * lineHeight ? cellSeparator : " "
            text += item.line.text
            reach = max(reach, item.right)
        }
        let boxes = sorted.map { $0.line.boundingBox.standardized }
        let minX = boxes.map(\.minX).min() ?? 0
        let minY = boxes.map(\.minY).min() ?? 0
        let maxX = boxes.map(\.maxX).max() ?? 0
        let maxY = boxes.map(\.maxY).max() ?? 0
        let confidence = sorted.map(\.line.confidence).min() ?? 0
        return OCRLine(text: text, boundingBox: CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY),
                       confidence: confidence)
    }

    /// The middle value (the mean of the two middle ones for an even count); 0 for none.
    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        if sorted.isEmpty { return 0 }
        let mid = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
    }
}
