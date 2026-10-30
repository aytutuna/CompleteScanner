import CoreGraphics
import Foundation

// Twin of windows/LazyScan.Core/MultiQuadPicker.cs: the same filters, order and numbers.

/// An outline a finder proposed (Vision's rectangles, a page finder), with how sure it is (0 to 1).
/// Twin of C# `QuadCandidate`.
public struct QuadCandidate: Equatable, Sendable {
    public var quad: Quad
    public var confidence: Double

    public init(quad: Quad, confidence: Double) {
        self.quad = quad
        self.confidence = confidence
    }
}

/// What `MultiQuadPicker` keeps (`MultiQuadPicker.options(for:)` gives each kind's). Twin of C#
/// `MultiQuadOptions`.
public struct MultiQuadOptions: Equatable, Sendable {
    /// The shape's long side over its short side (`CaptureScale.aspect`) is at least this…
    public var minLongOverShort: Double = 1
    /// …and at most this.
    public var maxLongOverShort: Double = 2
    /// The outline covers at least this share of the photo…
    public var minAreaFraction: Double = 0
    /// …and at most this.
    public var maxAreaFraction: Double = 1
    /// Two outlines sharing more than this share of their joint area (intersection over union) are one
    /// object: the surer stays.
    public var maxOverlap: Double = MultiQuadPicker.maxOverlap
    /// At most this many outlines are kept.
    public var maxCount: Int = 1

    public init() {}
}

/// Picks the objects in one camera shot (several receipts or photos, a card, a page) from the outlines
/// a finder proposed: each named and checked for a convex outline, kept when its size and shape fit
/// the kind of object, dropped when it is the only object inside a larger outline of the right size
/// and shape (a picture printed on a photo, a logo on a receipt), while a larger outline holding
/// several separate objects that cover at least `minBackgroundCoverage` of it is the background and
/// dropped instead (an album page, a sheet under receipts; only when more than one object is wanted;
/// small features inside one object, such as windows in a print's picture, leave the object whole),
/// then taken surest first (larger, then earlier, on a tie) unless it overlaps one already taken by more than `MultiQuadOptions.maxOverlap`, up to
/// `MultiQuadOptions.maxCount`, and returned in reading order: rows from the top, left to right in
/// each (`PhotoDetector`'s row grouping on their bounding boxes). Twin of C# `MultiQuadPicker`.
public enum MultiQuadPicker {
    /// Two outlines overlapping by more than this (intersection over union) are the same object.
    public static let maxOverlap = 0.3
    /// An outline is inside another when each of its corners is at most this many pixels outside it.
    public static let insideTolerance = 2.0
    /// An outline holding several separate objects is the background behind them only when they cover
    /// at least this share of it: prints on an album page and receipts on a sheet cover a fifth to a
    /// third, windows in the picture on a print far less.
    public static let minBackgroundCoverage = 0.15
    /// The ID-1 card's long side over its short side (85.6 / 53.98 mm).
    public static let idCardLongOverShort: Double = 3.370 / 2.125
    /// A card's shape may differ from `idCardLongOverShort` by this much.
    public static let idCardShapeSlack = 0.12

    /// What is kept for `kind`: receipts long and narrow (short over long side 0.12 to 0.8) and at
    /// least 0.5 % of the photo, up to 6; photos up to twice as long as wide and at least 1 % of the
    /// photo, up to 8; one card of the ID-1 shape (± `idCardShapeSlack`) of at least 2 %; one document
    /// page up to twice as long as wide of at least 10 %.
    public static func options(for kind: CaptureKind) -> MultiQuadOptions {
        var o = MultiQuadOptions()
        switch kind {
        case .receipt:
            o.minLongOverShort = 1 / 0.8
            o.maxLongOverShort = 1 / 0.12
            o.minAreaFraction = 0.005
            o.maxAreaFraction = 0.9
            o.maxCount = 6
        case .photo:
            o.minLongOverShort = 1
            o.maxLongOverShort = 2
            o.minAreaFraction = 0.01
            o.maxAreaFraction = 0.95
            o.maxCount = 8
        case .idCard:
            o.minLongOverShort = idCardLongOverShort - idCardShapeSlack
            o.maxLongOverShort = idCardLongOverShort + idCardShapeSlack
            o.minAreaFraction = 0.02
            o.maxAreaFraction = 1
            o.maxCount = 1
        case .document:
            o.minLongOverShort = 1
            o.maxLongOverShort = 2
            o.minAreaFraction = 0.1
            o.maxAreaFraction = 1
            o.maxCount = 1
        }
        return o
    }

    /// The outlines of the `kind` objects among `candidates`, in reading order.
    public static func pick(_ candidates: [QuadCandidate], imageWidth: Int, imageHeight: Int, kind: CaptureKind) -> [Quad] {
        pick(candidates, imageWidth: imageWidth, imageHeight: imageHeight, options: options(for: kind))
    }

    /// The outlines among `candidates` that `options` keep, in reading order.
    public static func pick(_ candidates: [QuadCandidate], imageWidth: Int, imageHeight: Int,
                            options: MultiQuadOptions) -> [Quad] {
        if imageWidth <= 0 || imageHeight <= 0 || options.maxCount <= 0 { return [] }
        let photoArea: Double = Double(imageWidth) * Double(imageHeight)

        // Outlines of the right size and shape, with their input order.
        var fitting: [Fitting] = []
        for i in 0..<candidates.count {
            let quad = Quad.fromCorners(candidates[i].quad.corners)
            if !quad.isConvex { continue }
            let area = quad.area
            let fraction: Double = area / photoArea
            if fraction < options.minAreaFraction || fraction > options.maxAreaFraction { continue }
            let shape: Double = CaptureScale.aspect(quad, imageWidth: imageWidth, imageHeight: imageHeight).longOverShort
            if shape < options.minLongOverShort || shape > options.maxLongOverShort { continue }
            let given = candidates[i].confidence
            let confidence: Double = given.isFinite ? given : 0
            fitting.append(Fitting(quad: quad, confidence: confidence, area: area, index: i))
        }

        // Outlines nest: each hangs under the smallest larger one holding it (the earlier on a tie).
        let n = fitting.count
        var parent = [Int](repeating: -1, count: n)
        for i in 0..<n {
            for j in 0..<n {
                if j == i || fitting[j].area <= fitting[i].area || !isInside(fitting[i].quad, fitting[j].quad) { continue }
                if parent[i] < 0 || fitting[j].area < fitting[parent[i]].area { parent[i] = j }
            }
        }

        // Folded from the smallest up: an outline is the background behind what it holds (an album page,
        // a sheet under receipts) when it holds several separate objects covering enough of it, unless
        // only one object is wanted; otherwise it is one object (a print and the picture on it, a print
        // and the windows of the house it shows).
        let smallestFirst: [Int] = (0..<n).sorted { a, b in
            if fitting[a].area != fitting[b].area { return fitting[a].area < fitting[b].area }
            return a < b
        }
        var held = [[Int]](repeating: [], count: n)
        var objects = [[Int]](repeating: [], count: n)
        for i in smallestFirst {
            let background = options.maxCount > 1
                && isBackground(fitting, held: held[i], containerArea: fitting[i].area, maxOverlap: options.maxOverlap)
            objects[i] = background ? held[i] : [i]
            if parent[i] >= 0 { held[parent[i]].append(contentsOf: objects[i]) }
        }
        var outer: [Fitting] = []
        for i in 0..<n where parent[i] < 0 {
            for k in objects[i] { outer.append(fitting[k]) }
        }

        // Surest first; an outline overlapping one taken is the same object.
        outer.sort(by: surerFirst)
        var taken: [Quad] = []
        for item in outer {
            if taken.count >= options.maxCount { break }
            var overlaps = false
            for kept in taken where overlap(item.quad, kept) > options.maxOverlap {
                overlaps = true
                break
            }
            if !overlaps { taken.append(item.quad) }
        }
        return inReadingOrder(taken)
    }

    /// The share of their joint area two convex outlines have in common (intersection over union, 0 to 1).
    public static func overlap(_ a: Quad, _ b: Quad) -> Double {
        let shared = a.intersectionArea(b)
        let union: Double = a.area + b.area - shared
        return union > 0 ? shared / union : 0
    }

    /// One outline that fits, with what it is sorted by.
    private struct Fitting {
        let quad: Quad
        let confidence: Double
        let area: Double
        let index: Int
    }

    /// Surer first, then larger, then earlier (a total order).
    private static func surerFirst(_ a: Fitting, _ b: Fitting) -> Bool {
        if a.confidence != b.confidence { return a.confidence > b.confidence }
        if a.area != b.area { return a.area > b.area }
        return a.index < b.index
    }

    /// `held` are objects laid on an outline of `containerArea`, not features inside one object: at
    /// least two of them are separate (taken surest first, one overlapping one counted by more than
    /// `maxOverlap` is the same object) and those cover at least `minBackgroundCoverage` of the outline.
    private static func isBackground(_ fitting: [Fitting], held: [Int], containerArea: Double, maxOverlap: Double) -> Bool {
        if held.count < 2 { return false }
        let surest: [Int] = held.sorted { a, b in surerFirst(fitting[a], fitting[b]) }
        var counted: [Quad] = []
        var covered: Double = 0
        for k in surest {
            var same = false
            for quad in counted where overlap(fitting[k].quad, quad) > maxOverlap {
                same = true
                break
            }
            if same { continue }
            counted.append(fitting[k].quad)
            covered += fitting[k].area
        }
        return counted.count >= 2 && covered >= minBackgroundCoverage * containerArea
    }

    /// Every corner of `inner` lies in `outer`, or at most `insideTolerance` outside it.
    private static func isInside(_ inner: Quad, _ outer: Quad) -> Bool {
        for i in 0..<4 where !outer.contains(inner[i], tolerance: insideTolerance) {
            return false
        }
        return true
    }

    /// `quads` in rows from the top, left to right in each, by their bounding boxes.
    private static func inReadingOrder(_ quads: [Quad]) -> [Quad] {
        if quads.count <= 1 { return quads }
        var regions: [DetectedPhotoRegion] = []
        var byRegion: [UUID: Quad] = [:]
        for quad in quads {
            var minX = Double(quad[0].x), maxX = Double(quad[0].x)
            var minY = Double(quad[0].y), maxY = Double(quad[0].y)
            for i in 1..<4 {
                let p = quad[i]
                minX = min(minX, Double(p.x))
                maxX = max(maxX, Double(p.x))
                minY = min(minY, Double(p.y))
                maxY = max(maxY, Double(p.y))
            }
            let center = CGPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2)
            let size = CGSize(width: maxX - minX, height: maxY - minY)
            let region = DetectedPhotoRegion(center: center, size: size, angleDegrees: 0)
            regions.append(region)
            byRegion[region.id] = quad
        }
        var ordered: [Quad] = []
        for region in PhotoDetector.sortedRowMajor(regions) {
            if let quad = byRegion[region.id] { ordered.append(quad) }
        }
        return ordered
    }
}
