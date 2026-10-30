import XCTest
@testable import LazyScanKit

// Twin of windows/LazyScan.Core.Tests/MaskOpsTests.cs. MaskOps was moved out of
// PhotoDetector; these tests prove it still does exactly what PhotoDetector's private copies did
// (kept below, verbatim, as the reference). The C# suite also pins PhotoDetector's regions on the
// demo bed to the last bit; the Swift demo bed is drawn by CoreGraphics, so PhotoDetectorTests
// (unchanged) cover photo detection here.

// MARK: - Reference implementations (PhotoDetector's private code before the move)

private func referenceDilate(_ mask: [UInt8], _ w: Int, _ h: Int, radius r: Int) -> [UInt8] {
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

private func referenceErode(_ mask: [UInt8], _ w: Int, _ h: Int, radius r: Int) -> [UInt8] {
    // Pixels outside the image count as background, so the mask shrinks at the borders.
    var tmp = [UInt8](repeating: 0, count: w * h)
    for y in 0..<h {
        let row = y * w
        for x in 0..<w {
            var v: UInt8 = (x - r >= 0 && x + r < w) ? 1 : 0
            if v == 1 {
                for xx in (x - r)...(x + r) where mask[row + xx] == 0 { v = 0; break }
            }
            tmp[row + x] = v
        }
    }
    var out = [UInt8](repeating: 0, count: w * h)
    for y in 0..<h {
        for x in 0..<w {
            var v: UInt8 = (y - r >= 0 && y + r < h) ? 1 : 0
            if v == 1 {
                for yy in (y - r)...(y + r) where tmp[yy * w + x] == 0 { v = 0; break }
            }
            out[y * w + x] = v
        }
    }
    return out
}

private struct ReferenceComponent {
    var area = 0
    var rows: [Int: (minX: Int, maxX: Int)] = [:]
}

private func referenceConnectedComponents(mask: [UInt8], width: Int, height: Int) -> [ReferenceComponent] {
    var visited = [Bool](repeating: false, count: mask.count)
    var components: [ReferenceComponent] = []
    var stack: [Int] = []
    for start in 0..<mask.count {
        guard mask[start] == 1, !visited[start] else { continue }
        var comp = ReferenceComponent()
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

/// Rows as comparable values, in row order.
private func flat(_ rows: [Int: (minX: Int, maxX: Int)]) -> [[Int]] {
    rows.keys.sorted().map { [$0, rows[$0]!.minX, rows[$0]!.maxX] }
}

final class MaskOpsTests: XCTestCase {

    /// A random mask, about `percent` % set.
    private func randomMask(_ w: Int, _ h: Int, _ percent: Int, _ seed: UInt32) -> [UInt8] {
        let rng = TestPages.Rng(seed)
        var mask = [UInt8](repeating: 0, count: w * h)
        for i in 0..<mask.count { mask[i] = rng.below(100) < percent ? 1 : 0 }
        return mask
    }

    private let masks: [(w: Int, h: Int, percent: Int, seed: UInt32)] = [
        (1, 1, 50, 1), (7, 1, 50, 2), (1, 9, 50, 3), (13, 11, 30, 4), (64, 48, 10, 5),
        (64, 48, 50, 6), (64, 48, 85, 7), (101, 37, 60, 8), (5, 5, 100, 9), (5, 5, 0, 10),
    ]

    func test_dilateAndErode_matchTheCodeTheyWereMovedFrom() {
        for m in masks {
            let mask = randomMask(m.w, m.h, m.percent, m.seed)
            for r in [0, 1, 2, 3, 7] {
                XCTAssertEqual(MaskOps.dilate(mask, m.w, m.h, radius: r), referenceDilate(mask, m.w, m.h, radius: r))
                XCTAssertEqual(MaskOps.erode(mask, m.w, m.h, radius: r), referenceErode(mask, m.w, m.h, radius: r))
            }
            // PhotoDetector's close and open.
            XCTAssertEqual(MaskOps.erode(MaskOps.dilate(mask, m.w, m.h, radius: 2), m.w, m.h, radius: 2),
                           referenceErode(referenceDilate(mask, m.w, m.h, radius: 2), m.w, m.h, radius: 2))
            XCTAssertEqual(MaskOps.dilate(MaskOps.erode(mask, m.w, m.h, radius: 1), m.w, m.h, radius: 1),
                           referenceDilate(referenceErode(mask, m.w, m.h, radius: 1), m.w, m.h, radius: 1))
        }
    }

    func test_connectedComponents_matchTheCodeTheyWereMovedFrom_inOrder() {
        for m in masks {
            let mask = randomMask(m.w, m.h, m.percent, m.seed)
            let expected = referenceConnectedComponents(mask: mask, width: m.w, height: m.h)
            let actual = MaskOps.connectedComponents(mask: mask, width: m.w, height: m.h)
            XCTAssertEqual(actual.count, expected.count)
            for (a, e) in zip(actual, expected) {
                XCTAssertEqual(a.area, e.area)
                XCTAssertEqual(flat(a.rows), flat(e.rows))
            }
        }
    }

    func test_componentAreas_areTheAreasOfTheComponents() {
        for m in masks {
            let mask = randomMask(m.w, m.h, m.percent, m.seed)
            let set = mask.filter { $0 == 1 }.count
            XCTAssertEqual(MaskOps.componentAreas(mask: mask, width: m.w, height: m.h),
                           MaskOps.connectedComponents(mask: mask, width: m.w, height: m.h).map(\.area))
            XCTAssertEqual(MaskOps.componentAreas(mask: mask, width: m.w, height: m.h).reduce(0, +), set)
            let eight = MaskOps.componentAreas(mask: mask, width: m.w, height: m.h, eightConnected: true)
            XCTAssertEqual(eight.reduce(0, +), set)
            XCTAssertLessThanOrEqual(eight.count, MaskOps.componentAreas(mask: mask, width: m.w, height: m.h).count)
        }
    }

    func test_components_areFourConnected_orEight() {
        // Diagonal neighbors are separate components; a plus sign is one.
        let diagonal: [UInt8] = [1, 0, 0, 1]
        XCTAssertEqual(MaskOps.componentAreas(mask: diagonal, width: 2, height: 2), [1, 1])
        XCTAssertEqual(MaskOps.componentAreas(mask: diagonal, width: 2, height: 2, eightConnected: true), [2])
        let antiDiagonal: [UInt8] = [0, 1, 1, 0]
        XCTAssertEqual(MaskOps.componentAreas(mask: antiDiagonal, width: 2, height: 2, eightConnected: true), [2])
        // A one-pixel staircase is one 8-connected mark, one 4-connected component per pixel.
        var staircase = [UInt8](repeating: 0, count: 36)
        for i in 0..<6 { staircase[i * 6 + i] = 1 }
        XCTAssertEqual(MaskOps.componentAreas(mask: staircase, width: 6, height: 6, eightConnected: true), [6])
        XCTAssertEqual(MaskOps.componentAreas(mask: staircase, width: 6, height: 6).count, 6)
        let plus: [UInt8] = [0, 1, 0, 1, 1, 1, 0, 1, 0]
        XCTAssertEqual(MaskOps.componentAreas(mask: plus, width: 3, height: 3), [5])
        let rows = MaskOps.connectedComponents(mask: plus, width: 3, height: 3)[0].rows
        XCTAssertEqual(flat(rows), [[0, 1, 1], [1, 0, 2], [2, 1, 1]])
    }

    func test_erode_outsideSet_keepsTheEdgeOfARegionAgainstTheBorder() {
        // A 6 x 4 block in the top left corner of a 10 x 8 mask.
        var mask = [UInt8](repeating: 0, count: 80)
        for y in 0..<4 {
            for x in 0..<6 { mask[y * 10 + x] = 1 }
        }
        var kept = [UInt8](repeating: 0, count: 80)
        var shrunk = [UInt8](repeating: 0, count: 80)
        for y in 0..<8 {
            for x in 0..<10 {
                // Outside set: it shrinks only on the sides facing the inside of the mask.
                kept[y * 10 + x] = x < 5 && y < 3 ? 1 : 0
                // Outside clear (the default): it shrinks along the border too.
                shrunk[y * 10 + x] = x >= 1 && x < 5 && y >= 1 && y < 3 ? 1 : 0
            }
        }
        XCTAssertEqual(MaskOps.erode(mask, 10, 8, radius: 1, outsideSet: true), kept)
        XCTAssertEqual(MaskOps.erode(mask, 10, 8, radius: 1), shrunk)
    }

    func test_erodeShrinksAtTheBorders_dilateDoesNotGrowPastThem() {
        let full = [UInt8](repeating: 1, count: 25)
        let eroded = MaskOps.erode(full, 5, 5, radius: 1)
        XCTAssertEqual(eroded.filter { $0 == 1 }.count, 9)
        XCTAssertEqual(eroded[0], 0)
        XCTAssertEqual(eroded[12], 1)
        var dot = [UInt8](repeating: 0, count: 25)
        dot[12] = 1
        XCTAssertEqual(MaskOps.dilate(dot, 5, 5, radius: 1).filter { $0 == 1 }.count, 9)
        XCTAssertEqual(MaskOps.dilate(dot, 5, 5, radius: 2).filter { $0 == 1 }.count, 25)
    }
}
