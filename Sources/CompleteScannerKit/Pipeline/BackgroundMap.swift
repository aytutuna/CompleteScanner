import Foundation

/// How bright the paper is across a page, so that ink can be told from paper whatever the
/// paper's tint, the scanner's uneven lighting or a gradient across the sheet: the area is cut
/// into tiles, each tile's background is a high percentile of its pixels (the paper between the
/// marks), and the background of any pixel is interpolated between tile centers. Twin of C#
/// `BackgroundMap` (windows/CompleteScanner.Core/BackgroundMap.cs): same tiles, same arithmetic.
public struct BackgroundMap: Sendable {
    /// Left edge of the area the map covers, in image pixels.
    public let x: Int
    /// Top edge of the area the map covers, in image pixels.
    public let y: Int
    /// Width of the area the map covers.
    public let width: Int
    /// Height of the area the map covers.
    public let height: Int
    /// Tiles across.
    public let columns: Int
    /// Tiles down.
    public let rows: Int
    /// The background of each tile, row-major (columns × rows).
    public let tiles: [UInt8]

    // Interpolation tables: for each column (row) of the area, the two tiles whose centers
    // surround it and the weight of the second.
    private let x0s: [Int], x1s: [Int], fxs: [Double]
    private let y0s: [Int], y1s: [Int], fys: [Double]

    private init(x: Int, y: Int, width: Int, height: Int, columns: Int, rows: Int, tiles: [UInt8]) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.columns = columns
        self.rows = rows
        self.tiles = tiles
        let across = BackgroundMap.interpolation(length: width, tiles: columns)
        x0s = across.0
        x1s = across.1
        fxs = across.2
        let down = BackgroundMap.interpolation(length: height, tiles: rows)
        y0s = down.0
        y1s = down.1
        fys = down.2
    }

    /// The map of the area (x, y, width, height) of `gray`, clamped to the image: tiles of about
    /// `tileSize` pixels (whole tiles only, so the last ones are a little larger), each one's
    /// background the `percentile` (0...1) of its pixels. nil when the area is empty.
    public static func estimate(_ gray: GrayImage, x: Int, y: Int, width: Int, height: Int,
                                tileSize: Int, percentile: Double = 0.9) -> BackgroundMap? {
        let x0 = min(max(x, 0), gray.width), y0 = min(max(y, 0), gray.height)
        let x1 = min(max(x + width, x0), gray.width), y1 = min(max(y + height, y0), gray.height)
        let w = x1 - x0, h = y1 - y0
        guard w > 0, h > 0 else { return nil }
        let size = max(1, tileSize)
        let columns = max(1, w / size), rows = max(1, h / size)
        var tiles = [UInt8](repeating: 0, count: columns * rows)
        var histogram = [Int](repeating: 0, count: 256)
        for ty in 0..<rows {
            let top = y0 + ty * h / rows, bottom = y0 + (ty + 1) * h / rows
            for tx in 0..<columns {
                let left = x0 + tx * w / columns, right = x0 + (tx + 1) * w / columns
                for v in 0..<256 { histogram[v] = 0 }
                for py in top..<bottom {
                    let row = py * gray.width
                    for px in left..<right { histogram[Int(gray.pixels[row + px])] += 1 }
                }
                tiles[ty * columns + tx] = BackgroundMap.percentile(histogram, count: (bottom - top) * (right - left),
                                                                    fraction: percentile)
            }
        }
        return BackgroundMap(x: x0, y: y0, width: w, height: h, columns: columns, rows: rows, tiles: tiles)
    }

    /// The value at `fraction` (0...1) of a histogram of `count` values: the smallest value with
    /// at least ⌈fraction × count⌉ values at or below it.
    public static func percentile(_ histogram: [Int], count: Int, fraction: Double) -> UInt8 {
        let rank = min(max(Int((fraction * Double(count)).rounded(.up)), 1), max(1, count))
        var seen = 0
        for v in 0..<256 {
            seen += histogram[v]
            if seen >= rank { return UInt8(v) }
        }
        return 255
    }

    /// The middle tile background (the upper middle one for an even count).
    public func medianTile() -> UInt8 {
        let sorted = tiles.sorted()
        return sorted[sorted.count / 2]
    }

    /// Each tile replaced by the brightest of itself and its eight neighbors, so a tile covered
    /// mostly by ink or a dark mark still gets the paper around it.
    public func maxSmoothed() -> BackgroundMap {
        var output = [UInt8](repeating: 0, count: tiles.count)
        for ty in 0..<rows {
            for tx in 0..<columns {
                var best: UInt8 = 0
                for ny in max(0, ty - 1)...min(rows - 1, ty + 1) {
                    for nx in max(0, tx - 1)...min(columns - 1, tx + 1) {
                        best = max(best, tiles[ny * columns + nx])
                    }
                }
                output[ty * columns + tx] = best
            }
        }
        return BackgroundMap(x: x, y: y, width: width, height: height, columns: columns, rows: rows, tiles: output)
    }

    /// Each tile raised to at least `floor`.
    public func clampedBelow(_ floor: UInt8) -> BackgroundMap {
        BackgroundMap(x: x, y: y, width: width, height: height, columns: columns, rows: rows,
                      tiles: tiles.map { max($0, floor) })
    }

    /// The background at image pixel (x, y) inside the area: bilinear between the centers of the
    /// surrounding tiles, the nearest tile's value beyond the outer centers.
    public func valueAt(x px: Int, y py: Int) -> Double {
        let ax = min(max(px - x, 0), width - 1), ay = min(max(py - y, 0), height - 1)
        let top = BackgroundMap.lerp(tiles[y0s[ay] * columns + x0s[ax]], tiles[y0s[ay] * columns + x1s[ax]], fxs[ax])
        let bottom = BackgroundMap.lerp(tiles[y1s[ay] * columns + x0s[ax]], tiles[y1s[ay] * columns + x1s[ax]], fxs[ax])
        return top + (bottom - top) * fys[ay]
    }

    /// The ink of the area: 1 where a pixel is darker than (1 − `contrast`) of the background
    /// there, 0 elsewhere. One byte per pixel, width × height, row-major.
    public func inkMask(_ gray: GrayImage, contrast: Double) -> [UInt8] {
        let keep = 1 - contrast
        var mask = [UInt8](repeating: 0, count: width * height)
        for ay in 0..<height {
            let row = (y + ay) * gray.width + x
            let t0 = y0s[ay] * columns, t1 = y1s[ay] * columns
            let fy = fys[ay]
            for ax in 0..<width {
                let top = BackgroundMap.lerp(tiles[t0 + x0s[ax]], tiles[t0 + x1s[ax]], fxs[ax])
                let bottom = BackgroundMap.lerp(tiles[t1 + x0s[ax]], tiles[t1 + x1s[ax]], fxs[ax])
                let background = top + (bottom - top) * fy
                if Double(gray.pixels[row + ax]) < background * keep { mask[ay * width + ax] = 1 }
            }
        }
        return mask
    }

    private static func lerp(_ a: UInt8, _ b: UInt8, _ t: Double) -> Double {
        Double(a) + Double(Int(b) - Int(a)) * t
    }

    /// For each of `length` pixels split into `tiles` equal tiles: the tiles whose centers
    /// surround the pixel's center and the second one's weight.
    private static func interpolation(length: Int, tiles: Int) -> ([Int], [Int], [Double]) {
        var first = [Int](repeating: 0, count: length)
        var second = [Int](repeating: 0, count: length)
        var weight = [Double](repeating: 0, count: length)
        var centers = [Double](repeating: 0, count: tiles)
        for t in 0..<tiles {
            let start = t * length / tiles, end = (t + 1) * length / tiles
            centers[t] = Double(start + end) / 2
        }
        var k = 0
        for p in 0..<length {
            let c = Double(p) + 0.5
            while k < tiles - 1 && centers[k + 1] <= c { k += 1 }
            if c <= centers[0] {
                first[p] = 0; second[p] = 0; weight[p] = 0
            } else if k >= tiles - 1 {
                first[p] = tiles - 1; second[p] = tiles - 1; weight[p] = 0
            } else {
                first[p] = k; second[p] = k + 1
                weight[p] = (c - centers[k]) / (centers[k + 1] - centers[k])
            }
        }
        return (first, second, weight)
    }
}
