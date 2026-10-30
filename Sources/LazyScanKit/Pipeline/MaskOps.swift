import Foundation

/// One 4-connected region of a binary mask. Twin of C# `MaskComponent`.
struct MaskComponent {
    var area = 0
    /// Per-row horizontal extent: y -> (minX, maxX).
    var rows: [Int: (minX: Int, maxX: Int)] = [:]
}

/// Binary-mask operations shared by the detectors (photos, blank pages, and later receipts and
/// page edges). A mask is one byte per pixel, row-major, 1 = set and 0 = clear. Moved out of
/// `PhotoDetector` unchanged, so photo detection gives exactly the same regions. Twin of C#
/// `MaskOps` (windows/LazyScan.Core/MaskOps.cs).
enum MaskOps {

    // MARK: - Morphology (square kernel, separable passes)

    /// Dilation with a (2r+1)×(2r+1) square: a pixel is set when any pixel within r (per axis) is.
    static func dilate(_ mask: [UInt8], _ w: Int, _ h: Int, radius r: Int) -> [UInt8] {
        var tmp = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            let row = y * w
            for x in 0..<w {
                var v: UInt8 = 0
                for xx in max(0, x - r)...min(w - 1, x + r) where mask[row + xx] == 1 { v = 1; break }
                tmp[row + x] = v
            }
        }
        var out = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                var v: UInt8 = 0
                for yy in max(0, y - r)...min(h - 1, y + r) where tmp[yy * w + x] == 1 { v = 1; break }
                out[y * w + x] = v
            }
        }
        return out
    }

    /// Erosion with a (2r+1)×(2r+1) square: a pixel stays set when every pixel within r is.
    /// Pixels outside the image count as clear, so the mask shrinks at the borders, unless
    /// `outsideSet` says they count as set (a region touching the border then keeps its edge there,
    /// as when closing the mask of a page laid against the glass's edge).
    static func erode(_ mask: [UInt8], _ w: Int, _ h: Int, radius r: Int, outsideSet: Bool = false) -> [UInt8] {
        var tmp = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            let row = y * w
            for x in 0..<w {
                var v: UInt8 = (outsideSet || (x - r >= 0 && x + r < w)) ? 1 : 0
                if v == 1 {
                    for xx in max(0, x - r)...min(w - 1, x + r) where mask[row + xx] == 0 { v = 0; break }
                }
                tmp[row + x] = v
            }
        }
        var out = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                var v: UInt8 = (outsideSet || (y - r >= 0 && y + r < h)) ? 1 : 0
                if v == 1 {
                    for yy in max(0, y - r)...min(h - 1, y + r) where tmp[yy * w + x] == 0 { v = 0; break }
                }
                out[y * w + x] = v
            }
        }
        return out
    }

    // MARK: - Connected components

    /// The 4-connected components of the set pixels, in the order their first pixel appears
    /// (row-major), each with its area and per-row extent.
    static func connectedComponents(mask: [UInt8], width: Int, height: Int) -> [MaskComponent] {
        var visited = [Bool](repeating: false, count: mask.count)
        var components: [MaskComponent] = []
        var stack: [Int] = []
        for start in 0..<mask.count {
            guard mask[start] == 1, !visited[start] else { continue }
            var comp = MaskComponent()
            visited[start] = true
            stack.removeAll(keepingCapacity: true)
            stack.append(start)
            while let idx = stack.popLast() {
                let x = idx % width, y = idx / width
                comp.area += 1
                if let span = comp.rows[y] {
                    comp.rows[y] = (min(span.minX, x), max(span.maxX, x))
                } else {
                    comp.rows[y] = (x, x)
                }
                if x > 0, mask[idx - 1] == 1, !visited[idx - 1] { visited[idx - 1] = true; stack.append(idx - 1) }
                if x < width - 1, mask[idx + 1] == 1, !visited[idx + 1] { visited[idx + 1] = true; stack.append(idx + 1) }
                if y > 0, mask[idx - width] == 1, !visited[idx - width] { visited[idx - width] = true; stack.append(idx - width) }
                if y < height - 1, mask[idx + width] == 1, !visited[idx + width] { visited[idx + width] = true; stack.append(idx + width) }
            }
            components.append(comp)
        }
        return components
    }

    /// The areas of the components of the set pixels, in the order their first pixel appears;
    /// cheaper than `connectedComponents` when only the sizes matter (dust filtering).
    /// 4-connected like `connectedComponents`, or 8-connected (diagonal neighbors join too, so a
    /// thin slanted pen stroke stays one mark).
    static func componentAreas(mask: [UInt8], width: Int, height: Int, eightConnected: Bool = false) -> [Int] {
        var visited = [Bool](repeating: false, count: mask.count)
        var areas: [Int] = []
        var stack: [Int] = []
        for start in 0..<mask.count {
            guard mask[start] == 1, !visited[start] else { continue }
            var area = 0
            visited[start] = true
            stack.removeAll(keepingCapacity: true)
            stack.append(start)
            while let idx = stack.popLast() {
                let x = idx % width, y = idx / width
                area += 1
                if x > 0, mask[idx - 1] == 1, !visited[idx - 1] { visited[idx - 1] = true; stack.append(idx - 1) }
                if x < width - 1, mask[idx + 1] == 1, !visited[idx + 1] { visited[idx + 1] = true; stack.append(idx + 1) }
                if y > 0, mask[idx - width] == 1, !visited[idx - width] { visited[idx - width] = true; stack.append(idx - width) }
                if y < height - 1, mask[idx + width] == 1, !visited[idx + width] { visited[idx + width] = true; stack.append(idx + width) }
                guard eightConnected else { continue }
                if x > 0, y > 0, mask[idx - width - 1] == 1, !visited[idx - width - 1] {
                    visited[idx - width - 1] = true; stack.append(idx - width - 1)
                }
                if x < width - 1, y > 0, mask[idx - width + 1] == 1, !visited[idx - width + 1] {
                    visited[idx - width + 1] = true; stack.append(idx - width + 1)
                }
                if x > 0, y < height - 1, mask[idx + width - 1] == 1, !visited[idx + width - 1] {
                    visited[idx + width - 1] = true; stack.append(idx + width - 1)
                }
                if x < width - 1, y < height - 1, mask[idx + width + 1] == 1, !visited[idx + width + 1] {
                    visited[idx + width + 1] = true; stack.append(idx + width + 1)
                }
            }
            areas.append(area)
        }
        return areas
    }
}
