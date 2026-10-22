import CoreGraphics
import Foundation

// Twin of windows/CompleteScanner.Core/GlareDetector.cs: the same cells, rules and numbers.

/// How much of a card or a glossy print a camera saw blown out by a reflection (`GlareDetector.measure`):
/// the share of the measured cells whose every channel is clipped, and the share the largest patch of
/// them, joined side by side, covers. Twin of C# `GlareReading`.
public struct GlareReading: Equatable, Sendable {
    public var clippedShare: Double
    public var largestBlobShare: Double

    public init(clippedShare: Double, largestBlobShare: Double) {
        self.clippedShare = clippedShare
        self.largestBlobShare = largestBlobShare
    }

    /// A patch of glare large enough to hide what is printed under it (`GlareDetector.minBlobShare`).
    public var hasGlare: Bool { largestBlobShare >= GlareDetector.minBlobShare }

    /// Nothing measured, or no clipped cell.
    public static let none = GlareReading(clippedShare: 0, largestBlobShare: 0)
}

/// Finds glare on a card or a glossy print in a camera photo: a light reflected off a laminate, a
/// hologram or a print's gloss saturates the camera, so a patch of the object turns white in every
/// channel. The area measured is the object's outline (a `Quad`, or the whole picture), less a band
/// along its edges (`insetShare` of its shorter side), where the table and the edge's own highlight
/// would count. It is cut into cells of k × k pixels, k the whole number that brings the area's longer
/// side to at most `analysisLongSide` cells; a cell counts when its center lies in that inner outline,
/// and is clipped when the mean of each of its channels (integer sums, rounded half up) is at least
/// `clipLevel`. Clipped cells side by side (four neighbours) are one patch; the reading is the share of
/// the counted cells clipped and the share the largest patch covers, and there is glare when that is at
/// least `minBlobShare`: white specks in the print stay below it. A light card whose white is not blown
/// out (below the clip level) has none. Measured on the photo as taken, before any clean-up stretches
/// its whites. Twin of C# `GlareDetector`.
public enum GlareDetector {
    /// A cell is clipped when the mean of each of its channels is at least this (0 to 255).
    public static let clipLevel: Int = 250
    /// Glare: the largest clipped patch covers at least this share of the measured cells.
    public static let minBlobShare: Double = 0.01
    /// The band along the outline's edges left out, as a share of its shorter side.
    public static let insetShare: Double = 0.04
    /// The area is cut into at most this many cells along its longer side.
    public static let analysisLongSide: Int = 400

    /// The camera's one line when a card was taken with glare on it.
    public static let hint: String = "Tilt to avoid glare"

    /// The glare on `image` inside `region` (its pixels; nil: the whole picture).
    public static func measure(_ image: RgbaImage, region: Quad? = nil) -> GlareReading {
        let width: Int = image.width
        let height: Int = image.height
        if width <= 0 || height <= 0 { return GlareReading.none }
        let whole = Quad(topLeft: CGPoint(x: 0, y: 0), topRight: CGPoint(x: Double(width), y: 0),
                         bottomRight: CGPoint(x: Double(width), y: Double(height)), bottomLeft: CGPoint(x: 0, y: Double(height)))
        let outline: Quad = region ?? whole
        if !outline.isConvex { return GlareReading.none }
        let corners: [CGPoint] = outline.corners
        var minX: Double = Double(corners[0].x)
        var maxX: Double = Double(corners[0].x)
        var minY: Double = Double(corners[0].y)
        var maxY: Double = Double(corners[0].y)
        for i in 1..<4 {
            minX = min(minX, Double(corners[i].x))
            maxX = max(maxX, Double(corners[i].x))
            minY = min(minY, Double(corners[i].y))
            maxY = max(maxY, Double(corners[i].y))
        }
        if !(minX.isFinite && maxX.isFinite && minY.isFinite && maxY.isFinite) { return GlareReading.none }
        let x0: Int = max(0, Int(minX.rounded(.down)))
        let y0: Int = max(0, Int(minY.rounded(.down)))
        let x1: Int = min(width, Int(maxX.rounded(.up)))
        let y1: Int = min(height, Int(maxY.rounded(.up)))
        if x1 <= x0 || y1 <= y0 { return GlareReading.none }
        let areaWidth: Int = x1 - x0
        let areaHeight: Int = y1 - y0
        let longSide: Int = max(areaWidth, areaHeight)
        let k: Int = max(1, (longSide + analysisLongSide - 1) / analysisLongSide)
        let columns: Int = (areaWidth + k - 1) / k
        let rows: Int = (areaHeight + k - 1) / k
        let across: Double = (outline.edgeLength(0) + outline.edgeLength(2)) / 2
        let down: Double = (outline.edgeLength(1) + outline.edgeLength(3)) / 2
        let inset: Double = insetShare * min(across, down)

        // 0: not measured, 1: measured, 2: measured and clipped.
        var cells: [UInt8] = [UInt8](repeating: 0, count: columns * rows)
        var counted: Int = 0
        var clipped: Int = 0
        let pixels: [UInt8] = image.pixels
        for row in 0..<rows {
            let cy0: Int = y0 + row * k
            let cy1: Int = min(cy0 + k, y1)
            for column in 0..<columns {
                let cx0: Int = x0 + column * k
                let cx1: Int = min(cx0 + k, x1)
                let center = CGPoint(x: Double(cx0 + cx1) / 2.0, y: Double(cy0 + cy1) / 2.0)
                if !outline.contains(center, tolerance: -inset) { continue }
                var sumR: Int = 0
                var sumG: Int = 0
                var sumB: Int = 0
                for y in cy0..<cy1 {
                    var p: Int = (y * width + cx0) * 4
                    for _ in cx0..<cx1 {
                        sumR += Int(pixels[p])
                        sumG += Int(pixels[p + 1])
                        sumB += Int(pixels[p + 2])
                        p += 4
                    }
                }
                let n: Int = (cx1 - cx0) * (cy1 - cy0)
                let meanR: Int = (sumR + n / 2) / n
                let meanG: Int = (sumG + n / 2) / n
                let meanB: Int = (sumB + n / 2) / n
                counted += 1
                if meanR >= clipLevel && meanG >= clipLevel && meanB >= clipLevel {
                    cells[row * columns + column] = 2
                    clipped += 1
                } else {
                    cells[row * columns + column] = 1
                }
            }
        }
        if counted == 0 { return GlareReading.none }
        let largest: Int = largestPatch(cells, columns: columns, rows: rows)
        return GlareReading(clippedShare: Double(clipped) / Double(counted),
                            largestBlobShare: Double(largest) / Double(counted))
    }

    /// Whether `image` shows glare inside `region` (`GlareReading.hasGlare`).
    public static func hasGlare(_ image: RgbaImage, region: Quad? = nil) -> Bool {
        measure(image, region: region).hasGlare
    }

    /// The cells of the largest patch of clipped cells (value 2) joined side by side, found in row-major order.
    private static func largestPatch(_ cells: [UInt8], columns: Int, rows: Int) -> Int {
        var seen: [Bool] = [Bool](repeating: false, count: cells.count)
        var stack: [Int] = []
        var largest: Int = 0
        for start in 0..<cells.count {
            if cells[start] != 2 || seen[start] { continue }
            seen[start] = true
            stack.append(start)
            var size: Int = 0
            while let index = stack.popLast() {
                size += 1
                let column: Int = index % columns
                let row: Int = index / columns
                var neighbours: [Int] = []
                if column > 0 { neighbours.append(index - 1) }
                if column < columns - 1 { neighbours.append(index + 1) }
                if row > 0 { neighbours.append(index - columns) }
                if row < rows - 1 { neighbours.append(index + columns) }
                for neighbour in neighbours where cells[neighbour] == 2 && !seen[neighbour] {
                    seen[neighbour] = true
                    stack.append(neighbour)
                }
            }
            largest = max(largest, size)
        }
        return largest
    }
}
