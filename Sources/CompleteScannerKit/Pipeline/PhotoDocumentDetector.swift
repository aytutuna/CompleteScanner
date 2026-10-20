import CoreGraphics
import Foundation

// Twin of windows/CompleteScanner.Core/PhotoDocumentDetector.cs: the same steps, constants and
// arithmetic in the same order (integers for the blur and the gradient, + − × ÷ and square roots
// on doubles, no trigonometry: the angle table is built from two constants), and every sort with a
// tie-break, so both platforms find the same corners.

/// Why `PhotoDocumentDetector.detect` returned no page.
public enum PhotoDocumentRejection: Sendable {
    /// A page was found.
    case none
    /// Nothing in the photo looks like the outline of a sheet.
    case nothingFound
    /// The page runs off the photo: a corner lies outside the frame, or an edge along its border.
    case cutOff
    /// Two different sheets of about the same size are equally likely.
    case ambiguous
    /// Something sheet-like was seen, but not clearly enough to trust.
    case lowConfidence
}

/// Options of `PhotoDocumentDetector`; the defaults are its constants.
public struct PhotoDocumentOptions: Equatable, Sendable {
    /// The photo is analysed with its long side at most this many pixels.
    public var analysisLongSide: Int = PhotoDocumentDetector.analysisLongSide
    /// The page covers at least this share of the photo.
    public var minAreaShare: Double = PhotoDocumentDetector.minAreaShare
    /// A page is taken when its score reaches this (0...1)…
    public var acceptScore: Double = PhotoDocumentDetector.acceptScore
    /// …and every edge's own score reaches this.
    public var minSideScore: Double = PhotoDocumentDetector.minSideScore
    /// A page's shape matches a known size within this share.
    public var paperAspectTolerance: Double = PerspectiveCorrector.paperAspectTolerance

    public init() {}

    public static let `default` = PhotoDocumentOptions()
}

/// What `PhotoDocumentDetector.detect` found.
public struct PhotoDocumentDetection: Equatable, Sendable {
    /// The page's corners in the photo's pixels (see `Quad`); nil when none was taken.
    public var quad: Quad?
    /// The page's score, 0...1 (0 when nothing was found).
    public var confidence: Double
    /// Why no page was taken, or `.none`.
    public var rejection: PhotoDocumentRejection
    /// The best outline seen when none was taken (cut off, ambiguous, unclear), in the photo's
    /// pixels, for a live view's hint ("move back"); nil when nothing was seen.
    public var candidate: Quad?
    /// The page's shape (`PerspectiveCorrector.estimateAspect`) when a page was taken.
    public var aspect: AspectEstimate?
    /// The known size the page's shape matches, if any.
    public var paper: PaperMatch?

    public var found: Bool { quad != nil }

    public static let nothing = PhotoDocumentDetection(quad: nil, confidence: 0, rejection: .nothingFound,
                                                       candidate: nil, aspect: nil, paper: nil)
}

/// Finds the four corners of a sheet of paper in a camera photo: a page seen at an angle (any
/// convex quadrilateral, not only a turned rectangle) on a table that may be textured, dark, light
/// or close to the paper's own color, with the phone's shadow, uneven light and glare. Twin of C#
/// `PhotoDocumentDetector`; the summary there describes the steps and the rules of the choice.
public enum PhotoDocumentDetector {
    /// The photo is analysed with its long side at most this many pixels.
    public static let analysisLongSide = 1000
    /// The page covers at least this share of the photo…
    public static let minAreaShare = 0.05
    /// …and at most this share.
    public static let maxAreaShare = 0.995
    /// A page is taken when its score reaches this…
    public static let acceptScore = 0.55
    /// …and every edge's own score reaches this.
    public static let minSideScore = 0.35
    /// Below the acceptance, an outline scoring at least this is reported as an unclear candidate.
    public static let candidateScore = 0.25
    /// A pixel is an edge when its gradient is at least this many levels per pixel (after smoothing).
    public static let edgeThreshold = 3.0
    /// An edge pixel's vote in the Hough transform is its gradient, at most this.
    public static let voteCap = 20.0
    /// Each edge pixel votes for directions within this many degrees of its own.
    public static let houghWindow = 4
    /// An edge pixel's Hough vote counts less the more edge pixels lie within this many pixels of it…
    public static let isolationRadius = 4
    /// …down to this share (1.5 − 2.5 × the share of edge pixels around it, at most 1).
    public static let isolationFloor = 0.25
    /// At most this many straight edges are combined into outlines…
    public static let maxLines = 28
    /// …and this many are tried in place of an edge of the best outlines (`swapKeep` of them),
    /// within 30° of it (|cos| at least `swapMinCos`).
    public static let swapLines = 60
    public static let swapKeep = 4
    public static let swapMinCos = 0.866
    /// A swapped-in edge scoring this much less than the edge it replaces is not tried further.
    public static let swapSideMargin = 0.2
    /// The search near an edge (`corridorLines`): edge pixels at most this many px outside its
    /// neighbors' lines, directions within `corridorBins`° of it, the `corridorPeaks` strongest lines
    /// and the `corridorOutermost` outermost.
    public static let corridorMargin = 3.0
    /// Only an edge scoring below this is searched near (a stronger one is taken as found).
    public static let corridorBelow = 0.95
    public static let corridorBins = 15
    /// …and no deeper inside the outline than this share of its depth there.
    public static let corridorDepth = 0.3
    public static let corridorPeaks = 8
    public static let corridorOutermost = 2
    /// An outermost line is offered only with at least this share of the strongest one's votes.
    public static let corridorOutermostShare = 0.15
    /// A straight edge needs votes worth at least this share of the frame's short side at `edgeThreshold`.
    public static let minLineShare = 0.08
    /// Opposite sides of an outline differ in direction by at most 40° (|cos| at least this).
    public static let oppositeMinCos = 0.766
    /// Corners of an outline are between 40° and 140° (|cos| at most this).
    public static let maxCornerCos = 0.766
    /// Corners between 60° and 120° (|cos| at most this) cost nothing; sharper ones cost up to half the score.
    public static let freeCornerCos = 0.5
    /// Corners of candidate outlines may lie this share of the frame outside it (a sheet cut off by the frame).
    public static let outsideShare = 0.25
    /// A corner more than this many analysis pixels outside the frame cuts the page off.
    public static let cutOffTolerance = 1.0
    /// Edge points nearer the frame's border than this many analysis pixels are not measured: an edge
    /// lying there is where the frame cuts the page off (a page's own edge further in is).
    public static let borderBand = 2.0
    /// Points sampled along each edge when scoring (fewer when screening line combinations).
    public static let scoreSamples = 48
    public static let screenSamples = 12
    /// Distinct outlines kept after screening the line combinations, and refitted after scoring.
    public static let screenKeep = 30
    public static let refineKeep = 8
    /// An edge that runs on past its corners loses up to this share of its score…
    public static let extensionPenalty = 0.6
    /// …judged over this share of its length beyond each corner, and at least `extensionMin` px.
    public static let extensionShare = 0.2
    public static let extensionMin = 8.0
    /// An edge point must be this many times stronger than the texture `textureNear` to
    /// `textureFar` px outside the edge.
    public static let textureRatio = 2.0
    public static let textureNear = 4
    public static let textureFar = 7
    /// A refit keeps the sign of the gradient found within this many pixels of the outline as it is.
    public static let polarityReach = 2
    /// An edge point counts when the gradient within this many pixels across the edge is strong enough.
    public static let supportReach = 2
    /// The color difference across an edge (mean of R, G, B levels) that counts in full…
    public static let contrastFull = 16.0
    /// …and the share of an edge's support that counts with no difference at all (a line drawn on
    /// the table, a seam between planks).
    public static let contrastFloor = 0.25
    /// Shapes up to this long-over-short ratio are plausible; longer ones cost up to half the score
    /// until `maxLongOverShort`.
    public static let plainLongOverShort = 4.0
    public static let maxLongOverShort = 8.0
    /// An outline whose edges do not all have the same polarity (outside darker on some, brighter on
    /// others) counts this share of its score: a sheet's edges all face the same table.
    public static let mixedPolarityFactor = 0.75
    /// A partial outline (one edge outside the frame, unscored) counts this share of its score.
    public static let partialFactor = 0.9
    /// The score bonus for a shape that matches a known paper size.
    public static let paperBonus = 0.04
    /// The score bonus for an outline near the hint (a previous frame's page)…
    public static let hintBonus = 0.05
    /// …within this share of the frame's diagonal.
    public static let hintShare = 0.05
    /// Of two near-identical outlines the outer one is kept when it scores at most this much less.
    public static let outerMargin = 0.1
    /// Two outlines are different sheets when their corners are this share of the diagonal apart on average.
    public static let distinctShare = 0.08
    /// Screened line combinations closer than this share of the diagonal are the same.
    public static let screenDuplicateShare = 0.005
    /// Outlines closer than this share of the diagonal are the same outline.
    public static let duplicateShare = 0.02
    /// Another sheet scoring within this of the best makes the choice uncertain…
    public static let ambiguityMargin = 0.1
    /// …unless it overlaps the best (the best, on top, stays) or one is at least this many times the
    /// other's area (the larger is taken).
    public static let largerPageRatio = 1.4
    /// The outline of a region is simplified to at most this many corners before the largest quad is sought.
    public static let maxHullVertices = 40
    /// A region must differ from the border color by at least this many levels.
    public static let minRegionContrast = 14

    // cos and sin of 0°, 1°, …, 180°, built by turning (1, 0) by one degree at a time.
    private static let cos1 = 0.99984769515639127
    private static let sin1 = 0.017452406437283512
    private static let tables: (cos: [Double], sin: [Double]) = {
        var c = [Double](repeating: 0, count: 181)
        var s = [Double](repeating: 0, count: 181)
        c[0] = 1
        s[0] = 0
        for k in 1...180 {
            let cc = c[k - 1] * PhotoDocumentDetector.cos1 - s[k - 1] * PhotoDocumentDetector.sin1
            let ss = s[k - 1] * PhotoDocumentDetector.cos1 + c[k - 1] * PhotoDocumentDetector.sin1
            c[k] = cc
            s[k] = ss
        }
        return (c, s)
    }()
    private static var cosTable: [Double] { tables.cos }
    private static var sinTable: [Double] { tables.sin }

    /// The page in `image`, or none with the reason. `hint`, a page found in a previous video frame
    /// (in this photo's pixels), is tried as an outline of its own and favors outlines near it.
    public static func detect(_ image: RgbaImage, hint: Quad? = nil,
                              options: PhotoDocumentOptions = .default) -> PhotoDocumentDetection {
        let o = options
        let longSide = max(image.width, image.height)
        var small = image
        if longSide > o.analysisLongSide && o.analysisLongSide > 0 {
            let s = Double(o.analysisLongSide) / Double(longSide)
            let aw = max(1, Int((Double(image.width) * s).rounded()))
            let ah = max(1, Int((Double(image.height) * s).rounded()))
            small = image.resized(width: aw, height: ah)
        }
        if small.width < 16 || small.height < 16 { return .nothing }
        let toFullX = Double(image.width) / Double(small.width)
        let toFullY = Double(image.height) / Double(small.height)
        let smallHint = hint.map { $0.scaled(1 / toFullX, 1 / toFullY) }

        let field = Field.build(small)
        let found = decide(field, pool(field, smallHint, o), o)
        let quad = found.quad.map { $0.scaled(toFullX, toFullY) }
        let candidate = found.candidate.map { $0.scaled(toFullX, toFullY) }
        var aspect: AspectEstimate?
        var paper: PaperMatch?
        if let q = quad {
            let estimate = PerspectiveCorrector.estimateAspect(q, imageWidth: Double(image.width),
                                                               imageHeight: Double(image.height))
            aspect = estimate
            paper = PerspectiveCorrector.matchPaper(estimate.longOverShort, tolerance: o.paperAspectTolerance)
        }
        return PhotoDocumentDetection(quad: quad, confidence: found.confidence, rejection: found.rejection,
                                      candidate: candidate, aspect: aspect, paper: paper)
    }

    // MARK: - The analysis image

    /// The smoothed colors and the gradient of the analysis image.
    final class Field {
        let w: Int
        let h: Int
        /// Smoothed channels, 256 × the level.
        var r: [Int] = []
        var g: [Int] = []
        var b: [Int] = []
        /// The strongest channel's gradient, in levels per pixel (0 on the outermost pixels).
        var gx: [Double] = []
        var gy: [Double] = []
        var mag: [Double] = []

        init(w: Int, h: Int) {
            self.w = w
            self.h = h
        }

        var diagonal: Double { (Double(w) * Double(w) + Double(h) * Double(h)).squareRoot() }

        static func build(_ image: RgbaImage) -> Field {
            let w = image.width, h = image.height
            let f = Field(w: w, h: h)
            f.r = smooth(image.pixels, w, h, 0)
            f.g = smooth(image.pixels, w, h, 1)
            f.b = smooth(image.pixels, w, h, 2)
            var gxs = [Double](repeating: 0, count: w * h)
            var gys = [Double](repeating: 0, count: w * h)
            var mags = [Double](repeating: 0, count: w * h)
            let channels = [f.r, f.g, f.b]
            if h >= 3 && w >= 3 {
                for y in 1..<(h - 1) {
                    for x in 1..<(w - 1) {
                        let i = y * w + x
                        var bestX = 0, bestY = 0
                        var bestM = -1
                        for c in 0..<3 {
                            let ch = channels[c]
                            let right: Int = ch[i - w + 1] + 2 * ch[i + 1] + ch[i + w + 1]
                            let left: Int = ch[i - w - 1] + 2 * ch[i - 1] + ch[i + w - 1]
                            let below: Int = ch[i + w - 1] + 2 * ch[i + w] + ch[i + w + 1]
                            let above: Int = ch[i - w - 1] + 2 * ch[i - w] + ch[i - w + 1]
                            let gx = right - left
                            let gy = below - above
                            let m = gx * gx + gy * gy
                            if m > bestM {
                                bestM = m
                                bestX = gx
                                bestY = gy
                            }
                        }
                        let dx = Double(bestX) / 2048.0, dy = Double(bestY) / 2048.0
                        gxs[i] = dx
                        gys[i] = dy
                        mags[i] = (dx * dx + dy * dy).squareRoot()
                    }
                }
            }
            f.gx = gxs
            f.gy = gys
            f.mag = mags
            return f
        }

        /// Channel `channel` smoothed by 1-4-6-4-1 across and down (edges repeated): 256 × the level.
        private static func smooth(_ rgba: [UInt8], _ w: Int, _ h: Int, _ channel: Int) -> [Int] {
            // Each row smoothed across into rows 2...h+1 of a buffer padded by two repeated rows above and below.
            var row = [Int](repeating: 0, count: w + 4)
            var across = [Int](repeating: 0, count: w * (h + 4))
            for y in 0..<h {
                let src = y * w
                for x in 0..<w { row[x + 2] = Int(rgba[(src + x) * 4 + channel]) }
                row[0] = row[2]
                row[1] = row[2]
                row[w + 2] = row[w + 1]
                row[w + 3] = row[w + 1]
                let dst = (y + 2) * w
                for x in 0..<w {
                    let s: Int = row[x] + 4 * row[x + 1] + 6 * row[x + 2] + 4 * row[x + 3] + row[x + 4]
                    across[dst + x] = s
                }
            }
            for x in 0..<w {
                across[x] = across[2 * w + x]
                across[w + x] = across[2 * w + x]
                across[(h + 2) * w + x] = across[(h + 1) * w + x]
                across[(h + 3) * w + x] = across[(h + 1) * w + x]
            }
            var output = [Int](repeating: 0, count: w * h)
            for y in 0..<h {
                let a = y * w, b = a + w, c = b + w, d = c + w, e = d + w
                for x in 0..<w {
                    let s: Int = across[a + x] + 4 * across[b + x] + 6 * across[c + x] + 4 * across[d + x] + across[e + x]
                    output[a + x] = s
                }
            }
            return output
        }

        /// The gradient at a continuous point, bilinear between pixel centers (clamped inside the gradient's area).
        func gradientAt(_ x: Double, _ y: Double) -> (gx: Double, gy: Double) {
            let fx = x - 0.5, fy = y - 0.5
            let cx = min(max(fx, 1), Double(w) - 2.000001), cy = min(max(fy, 1), Double(h) - 2.000001)
            let x0f = cx.rounded(.down), y0f = cy.rounded(.down)
            let x0 = Int(x0f), y0 = Int(y0f)
            let tx = cx - x0f, ty = cy - y0f
            let i = y0 * w + x0
            let gxTop = gx[i] * (1 - tx) + gx[i + 1] * tx
            let gxBottom = gx[i + w] * (1 - tx) + gx[i + w + 1] * tx
            let gyTop = gy[i] * (1 - tx) + gy[i + 1] * tx
            let gyBottom = gy[i + w] * (1 - tx) + gy[i + w + 1] * tx
            return (gxTop * (1 - ty) + gxBottom * ty, gyTop * (1 - ty) + gyBottom * ty)
        }
    }

    /// A straight line n · p = rho with a unit normal.
    struct Line: Equatable {
        var nx: Double
        var ny: Double
        var rho: Double

        func distance(_ x: Double, _ y: Double) -> Double { nx * x + ny * y - rho }

        static func through(_ p: CGPoint, _ q: CGPoint) -> Line {
            let px = Double(p.x), py = Double(p.y)
            let dx = Double(q.x) - px, dy = Double(q.y) - py
            let len = (dx * dx + dy * dy).squareRoot()
            let nx = dy / len, ny = -dx / len
            return Line(nx: nx, ny: ny, rho: nx * px + ny * py)
        }

        static func intersect(_ a: Line, _ b: Line) -> CGPoint? {
            let det = a.nx * b.ny - a.ny * b.nx
            if abs(det) < 1e-9 { return nil }
            return CGPoint(x: (a.rho * b.ny - b.rho * a.ny) / det, y: (a.nx * b.rho - b.nx * a.rho) / det)
        }
    }

    // MARK: - Finding the page

    /// An outline's score; `partial` when one edge lies outside the frame or along its border (`borderBand`), unscored.
    struct Score {
        var total: Double
        var edge: Double
        var minSide: Double
        var valid: Bool
        var partial: Bool = false
    }

    final class Candidate {
        var quad: Quad
        var score = Score(total: 0, edge: 0, minSide: 0, valid: false)
        let order: Int

        init(_ quad: Quad, _ order: Int) {
            self.quad = quad
            self.order = order
        }
    }

    struct Found {
        var quad: Quad?
        var confidence: Double
        var rejection: PhotoDocumentRejection
        var candidate: Quad?
    }

    /// The scored outlines of the analysis image, best first (for tests and tuning).
    static func explain(_ analysisImage: RgbaImage, hint: Quad? = nil, options: PhotoDocumentOptions = .default)
        -> [(quad: Quad, total: Double, edge: Double, minSide: Double)] {
        let f = Field.build(analysisImage)
        return pool(f, hint, options).map { ($0.quad, $0.score.total, $0.score.edge, $0.score.minSide) }
    }

    /// Every candidate outline, scored, refitted, best first, without repeats.
    private static func pool(_ f: Field, _ hint: Quad?, _ o: PhotoDocumentOptions) -> [Candidate] {
        let diag = f.diagonal
        var pool: [Candidate] = []
        var order = 0

        // Straight edges combined into outlines, screened with a few samples per edge.
        let edges = findEdges(f)
        let allLines = findLines(f, edges, swapLines)
        let lines = allLines.count > maxLines ? Array(allLines[0..<maxLines]) : allLines
        var screened: [Candidate] = []
        for q in lineQuads(f, lines, o) {
            let c = Candidate(q, order)
            order += 1
            c.score = scoreQuad(f, q, screenSamples, hint, o)
            if c.score.valid { screened.append(c) }
        }
        sortByScore(&screened)
        var kept: [Candidate] = []
        for c in screened {
            if kept.count >= screenKeep { break }
            var isRepeat = false
            for k in kept where cornerDistance(c.quad, k.quad) < screenDuplicateShare * diag {
                isRepeat = true
                break
            }
            if !isRepeat { kept.append(c) }
        }
        for c in kept {
            c.score = scoreQuad(f, c.quad, scoreSamples, hint, o)
            if c.score.valid { pool.append(c) }
        }

        // Regions standing out from the table, refined to their edges first (their outline is rough).
        let regionReach = max(4, (0.02 * diag).rounded(.toNearestOrEven))
        for q in regionQuads(f, o) {
            var refined = refineQuad(f, q, regionReach)
            if let r = refined { refined = refineQuad(f, r, 2) ?? r }
            let c = Candidate(refined ?? q, order)
            order += 1
            c.score = scoreQuad(f, c.quad, scoreSamples, hint, o)
            if c.score.valid { pool.append(c) }
        }

        // The previous frame's page.
        if let hq = hint, hq.isConvex {
            var refined = refineQuad(f, hq, regionReach)
            if let r = refined { refined = refineQuad(f, r, 2) ?? r }
            let c = Candidate(refined ?? hq, order)
            order += 1
            c.score = scoreQuad(f, c.quad, scoreSamples, hint, o)
            if c.score.valid { pool.append(c) }
        }

        // The best outlines refitted to their edges.
        sortByScore(&pool)
        let distinct = distinctOutlines(pool, duplicateShare * diag)
        var ranked: [Candidate] = []
        for (i, c) in distinct.enumerated() {
            ranked.append(c)
            if i >= refineKeep { continue }
            if let refined = refineQuad(f, c.quad, 3) {
                let r = Candidate(refined, c.order)
                r.score = scoreQuad(f, refined, scoreSamples, hint, o)
                if r.score.valid && r.score.total >= c.score.total { ranked[ranked.count - 1] = r }
            }
        }
        sortByScore(&ranked)
        ranked = distinctOutlines(ranked, duplicateShare * diag)

        // The best outlines with an edge swapped for another straight edge where that scores better
        // (an outline that took a line printed on the page, or missed a weak edge).
        let count = ranked.count
        var i = 0
        while i < count && i < swapKeep {
            var swapped = swapSides(f, ranked[i], allLines, edges, hint, o)
            if swapped !== ranked[i] {
                if let refined = refineQuad(f, swapped.quad, 3) {
                    let r = Candidate(refined, swapped.order)
                    r.score = scoreQuad(f, refined, scoreSamples, hint, o)
                    if r.score.valid && r.score.total >= swapped.score.total { swapped = r }
                }
                ranked.append(swapped)
            }
            i += 1
        }
        sortByScore(&ranked)
        ranked = distinctOutlines(ranked, duplicateShare * diag)
        sortByScore(&ranked)
        return ranked
    }

    /// `c` with one edge at a time replaced by another straight edge running within 30° of it,
    /// while that scores better (two rounds at most): one of the image's straight edges or one found
    /// near that edge (`corridorLines`, a weak edge the print elsewhere outvoted); `c` itself when no
    /// swap helps.
    private static func swapSides(_ f: Field, _ c: Candidate, _ globalLines: [Line], _ edges: EdgeSet,
                                  _ hint: Quad?, _ o: PhotoDocumentOptions) -> Candidate {
        var best = c
        let frame = Double(f.w) * Double(f.h)
        let minX = -outsideShare * Double(f.w), maxX = (1 + outsideShare) * Double(f.w)
        let minY = -outsideShare * Double(f.h), maxY = (1 + outsideShare) * Double(f.h)
        for _ in 0..<2 {
            let q = best.quad
            var sides: [Line] = []
            for i in 0..<4 { sides.append(Line.through(q[i], q[i + 1])) }
            var roundBest: Candidate?
            var bar = best.score.total
            for side in 0..<4 {
                let held = sideScore(f, q, side, screenSamples)?.value ?? 0
                var lines = globalLines
                if held < corridorBelow { lines.append(contentsOf: corridorLines(f, edges, q, side)) }
                for line in lines {
                    if abs(line.nx * sides[side].nx + line.ny * sides[side].ny) < swapMinCos { continue }
                    guard let a = Line.intersect(sides[(side + 3) & 3], line),
                          let b = Line.intersect(line, sides[(side + 1) & 3]) else { continue }
                    let ax = Double(a.x), ay = Double(a.y), bx = Double(b.x), by = Double(b.y)
                    if ax < minX || ax > maxX || ay < minY || ay > maxY || bx < minX || bx > maxX || by < minY || by > maxY {
                        continue
                    }
                    var corners = q.corners
                    corners[side] = a
                    corners[(side + 1) & 3] = b
                    let candidate = Quad(topLeft: corners[0], topRight: corners[1], bottomRight: corners[2],
                                         bottomLeft: corners[3])
                    if !candidate.isConvex { continue }
                    let share = candidate.area / frame
                    if share < o.minAreaShare || share > maxAreaShare { continue }
                    // The new edge itself first: much weaker than the one it replaces, it cannot help.
                    if (sideScore(f, candidate, side, screenSamples)?.value ?? 0) < held - swapSideMargin { continue }
                    let screen = scoreQuad(f, candidate, screenSamples, hint, o)
                    if !screen.valid || screen.total <= bar - 0.1 { continue }
                    let score = scoreQuad(f, candidate, scoreSamples, hint, o)
                    if !score.valid || score.total <= bar + 1e-9 { continue }
                    bar = score.total
                    let swapped = Candidate(Quad.fromCorners(corners), c.order)
                    swapped.score = score
                    roundBest = swapped
                }
            }
            guard let improved = roundBest else { break }
            best = improved
        }
        return best
    }

    /// The choice among the scored outlines (best first), as C# `PhotoDocumentDetector` says.
    private static func decide(_ f: Field, _ pool: [Candidate], _ o: PhotoDocumentOptions) -> Found {
        if pool.isEmpty { return Found(quad: nil, confidence: 0, rejection: .nothingFound, candidate: nil) }
        let diag = f.diagonal
        let w = Double(f.w), h = Double(f.h)
        let accepted = pool.filter { $0.score.total >= o.acceptScore && $0.score.minSide >= o.minSideScore }
        if accepted.isEmpty {
            let best = pool[0]
            if best.score.total < candidateScore {
                return Found(quad: nil, confidence: 0, rejection: .nothingFound, candidate: nil)
            }
            return Found(quad: nil, confidence: 0, rejection: .lowConfidence, candidate: best.quad)
        }
        let top = accepted[0]
        if !top.quad.isInside(width: w, height: h, margin: -cutOffTolerance) || top.score.partial {
            return Found(quad: nil, confidence: 0, rejection: .cutOff, candidate: top.quad)
        }
        var chosen = top
        for other in accepted.dropFirst() {
            if other.score.total < top.score.total - ambiguityMargin { break }
            if !other.quad.isInside(width: w, height: h, margin: -cutOffTolerance) || other.score.partial { continue }
            let tolerance = duplicateShare * diag
            if cornerDistance(other.quad, chosen.quad) < distinctShare * diag {
                // The same sheet: its outer outline (a card's edge rather than the picture on it) when about as good.
                if other.score.total >= chosen.score.total - outerMargin && containsAll(other.quad, chosen.quad, 1.0) {
                    chosen = other
                }
                continue
            }
            // One inside the other or overlapping it (a sheet on a larger one, a frame printed on the
            // page, a sheet lying across another): the better one, fully seen, stays.
            if containsAll(chosen.quad, other.quad, tolerance) || containsAll(other.quad, chosen.quad, tolerance) { continue }
            if !separated(chosen.quad, other.quad, 0) { continue }
            let a = chosen.quad.area, b = other.quad.area
            if max(a, b) >= largerPageRatio * min(a, b) {
                if b > a { chosen = other }
                continue
            }
            return Found(quad: nil, confidence: 0, rejection: .ambiguous, candidate: top.quad)
        }
        return Found(quad: chosen.quad, confidence: min(max(chosen.score.total, 0), 1), rejection: .none, candidate: nil)
    }

    /// A straight line (one of their edges' lines) runs between the two convex outlines, at least
    /// `gap` from both.
    static func separated(_ a: Quad, _ b: Quad, _ gap: Double) -> Bool {
        for pass in 0..<2 {
            let p = pass == 0 ? a : b
            let o = pass == 0 ? b : a
            for i in 0..<4 {
                let s = p[i], e = p[i + 1]
                let len = Quad.distance(s, e)
                if len <= 0 { continue }
                let sx = Double(s.x), sy = Double(s.y), ex = Double(e.x), ey = Double(e.y)
                var all = true
                for j in 0..<4 {
                    let c = o[j]
                    let outside = ((ex - sx) * (sy - Double(c.y)) - (ey - sy) * (sx - Double(c.x))) / len
                    if outside < gap {
                        all = false
                        break
                    }
                }
                if all { return true }
            }
        }
        return false
    }

    private static func containsAll(_ outer: Quad, _ inner: Quad, _ tolerance: Double) -> Bool {
        for i in 0..<4 where !outer.contains(inner[i], tolerance: tolerance) { return false }
        return true
    }

    /// The mean distance between the corners of two outlines, whichever corner each starts from.
    static func cornerDistance(_ a: Quad, _ b: Quad) -> Double {
        var best = Double.greatestFiniteMagnitude
        for shift in 0..<4 {
            var sum = 0.0
            for i in 0..<4 { sum += Quad.distance(a[i], b[i + shift]) }
            best = min(best, sum / 4)
        }
        return best
    }

    private static func sortByScore(_ list: inout [Candidate]) {
        list.sort { a, b in
            a.score.total != b.score.total ? a.score.total > b.score.total : a.order < b.order
        }
    }

    /// The outlines (best first) without those within `radius` of a better one; of such
    /// near-identical outlines the one kept is the outer one when it scores within `outerMargin` of
    /// the best (a page's edge rather than a bar printed just inside it).
    private static func distinctOutlines(_ sorted: [Candidate], _ radius: Double) -> [Candidate] {
        var kept: [Candidate] = []
        var best: [Double] = []
        for c in sorted {
            var duplicate = -1
            for k in 0..<kept.count where cornerDistance(c.quad, kept[k].quad) < radius {
                duplicate = k
                break
            }
            if duplicate < 0 {
                kept.append(c)
                best.append(c.score.total)
                continue
            }
            let held = kept[duplicate]
            if c.score.total >= best[duplicate] - outerMargin && c.quad.area > held.quad.area
                && containsAll(c.quad, held.quad, 1.0) {
                kept[duplicate] = c
            }
        }
        return kept
    }

    // MARK: - Scoring

    /// How much an outline looks like a sheet's: its edges (`sideScore`), half on average and half on
    /// the weakest, times its corner angles, its shape and its size, plus the bonuses for a known
    /// paper size and for lying near the hint. An edge outside the frame or along its border is left out and the
    /// outline is partial (a sheet the frame cuts off), its score times `partialFactor`; edges of
    /// mixed polarity cost `mixedPolarityFactor`. Not valid (and 0) for an outline that is not
    /// convex, has a corner outside 40°–140°, a shape beyond `maxLongOverShort`, a size outside the
    /// limits, or two edges outside the frame.
    private static func scoreQuad(_ f: Field, _ q: Quad, _ samples: Int, _ hint: Quad?,
                                  _ o: PhotoDocumentOptions) -> Score {
        let invalid = Score(total: 0, edge: 0, minSide: 0, valid: false)
        if !q.isConvex { return invalid }
        let frame = Double(f.w) * Double(f.h)
        let share = q.area / frame
        if share < o.minAreaShare || share > maxAreaShare { return invalid }
        var shape = 1.0
        for i in 0..<4 {
            let p = q[i + 3], c = q[i], n = q[i + 1]
            let ax = Double(p.x) - Double(c.x), ay = Double(p.y) - Double(c.y)
            let bx = Double(n.x) - Double(c.x), by = Double(n.y) - Double(c.y)
            let la = (ax * ax + ay * ay).squareRoot(), lb = (bx * bx + by * by).squareRoot()
            if la < 4 || lb < 4 { return invalid }
            let cosine = abs(ax * bx + ay * by) / (la * lb)
            if cosine > maxCornerCos { return invalid }
            if cosine > freeCornerCos { shape *= 1 - 0.5 * (cosine - freeCornerCos) / (maxCornerCos - freeCornerCos) }
        }
        let estimate = PerspectiveCorrector.estimateAspect(q, imageWidth: Double(f.w), imageHeight: Double(f.h))
        let ratio = estimate.longOverShort
        if !(ratio <= maxLongOverShort) { return invalid }
        let aspectFactor = ratio <= plainLongOverShort
            ? 1
            : 1 - 0.5 * (ratio - plainLongOverShort) / (maxLongOverShort - plainLongOverShort)
        let sizeFactor = 0.85 + 0.15 * min(1, share / 0.3)

        var sum = 0.0, minimum = Double.greatestFiniteMagnitude
        var covered = 0, brighter = 0
        for i in 0..<4 {
            guard let side = sideScore(f, q, i, samples) else { continue }
            sum += side.value
            minimum = min(minimum, side.value)
            covered += 1
            if side.sign > 0 { brighter += 1 }
        }
        if covered < 3 { return invalid }
        let edge = 0.5 * (sum / Double(covered)) + 0.5 * minimum
        var total = edge * shape * aspectFactor * sizeFactor
        if covered < 4 { total *= partialFactor }
        if brighter != 0 && brighter != covered { total *= mixedPolarityFactor }
        if PerspectiveCorrector.matchPaper(ratio, tolerance: o.paperAspectTolerance) != nil { total += paperBonus }
        if let h = hint, cornerDistance(q, h) <= hintShare * f.diagonal { total += hintBonus }
        return Score(total: total, edge: edge, minSide: minimum, valid: true, partial: covered < 4)
    }

    /// How clearly edge `index` of `q` is a sheet's edge, 0...1, with its sign; nil when it lies
    /// outside the frame or along its border (`borderBand`). As C# `SideScore`: its support (`measureSide`) times
    /// `contrastFloor` plus the rest in proportion to its contrast (full at `contrastFull`), less up
    /// to `extensionPenalty` of that when the edge runs on past its corners.
    private static func sideScore(_ f: Field, _ q: Quad, _ index: Int, _ samples: Int) -> (value: Double, sign: Double)? {
        let p = q[index], e = q[index + 1]
        let m = measureSide(f, p, e, samples)
        if !m.covered { return nil }
        let value = m.support * (contrastFloor + (1 - contrastFloor) * min(1, m.contrast / contrastFull))
        let len = Quad.distance(p, e)
        let ext = max(extensionMin, extensionShare * len)
        let px = Double(p.x), py = Double(p.y), ex = Double(e.x), ey = Double(e.y)
        let ux = (ex - px) / len, uy = (ey - py) / len
        let extSamples = max(6, samples / 4)
        let before = measureSide(f, CGPoint(x: px - ux * ext, y: py - uy * ext), p, extSamples)
        let after = measureSide(f, e, CGPoint(x: ex + ux * ext, y: ey + uy * ext), extSamples)
        var through = 0.0
        var ends = 0
        if before.covered {
            through += before.support
            ends += 1
        }
        if after.covered {
            through += after.support
            ends += 1
        }
        if ends == 0 { return (value, m.sign) }
        through /= Double(ends)
        let penalty = extensionPenalty * min(max((through - 0.15) / 0.45, 0), 1)
        return (value * (1 - penalty), m.sign)
    }

    /// What `measureSide` finds along an edge; `sign` is +1 when the outside is brighter, −1 when darker.
    struct SideMeasure {
        var support: Double
        var contrast: Double
        var covered: Bool
        var sign: Double = 0
    }

    /// As C# `MeasureSide`: at `samples` points along the edge (6 % to 94 %) at least `borderBand` px
    /// inside the frame, the gradient across it within `supportReach` px; the edge's sign and offset
    /// are those with the largest sum; a point supports the edge when, at that offset or one pixel
    /// either side, the gradient of that sign is at least `edgeThreshold` and `textureRatio` times the
    /// texture outside (the median along the edge of the mean gradient `textureNear` to `textureFar` px
    /// outside, of the points where some of that strip lies in the frame; none when it lies outside
    /// everywhere); the contrast is the mean color difference between 4 + 0.4 % of the diagonal px
    /// inside and outside, nearer where the frame ends first. Covered when at least a quarter of the
    /// points are measured.
    private static func measureSide(_ f: Field, _ p: CGPoint, _ q: CGPoint, _ samples: Int) -> SideMeasure {
        let px = Double(p.x), py = Double(p.y)
        let dx = Double(q.x) - px, dy = Double(q.y) - py
        let len = (dx * dx + dy * dy).squareRoot()
        if len < 1 { return SideMeasure(support: 0, contrast: 0, covered: false) }
        let ux = dx / len, uy = dy / len
        let nx = uy, ny = -ux // outward for a clockwise outline
        let offset = 4 + 0.004 * f.diagonal
        let w = f.w, h = f.h
        let r = supportReach, span = 2 * r + 1
        var g = [Double](repeating: 0, count: samples * span)
        var texture = [Double](repeating: 0, count: samples)
        var used = [Bool](repeating: false, count: samples)
        var textured = [Bool](repeating: false, count: samples)
        var pos = [Double](repeating: 0, count: span)
        var neg = [Double](repeating: 0, count: span)
        var inFrame = 0, texturedCount = 0
        var contrastSum = 0.0
        for s in 0..<samples {
            let t = 0.06 + 0.88 * (Double(s) + 0.5) / Double(samples)
            let x = px + dx * t, y = py + dy * t
            if !(x >= borderBand && y >= borderBand && x <= Double(w) - borderBand && y <= Double(h) - borderBand) { continue }
            used[s] = true
            inFrame += 1
            for k in -r...r {
                let i = pixelIndex(f, x + nx * Double(k), y + ny * Double(k))
                let v = f.gx[i] * nx + f.gy[i] * ny
                g[s * span + k + r] = v
                if v > 0 { pos[k + r] += v } else { neg[k + r] -= v }
            }
            // The texture strip where it lies within the gradient's area (not the outermost pixels).
            var tex = 0.0
            var probes = 0
            for k in textureNear...textureFar {
                let fx = (x + nx * Double(k)).rounded(.down), fy = (y + ny * Double(k)).rounded(.down)
                if fx < 1 || fy < 1 || fx > Double(w - 2) || fy > Double(h - 2) { continue }
                let i = Int(fy) * w + Int(fx)
                tex += abs(f.gx[i] * nx + f.gy[i] * ny)
                probes += 1
            }
            if probes > 0 {
                texture[s] = tex / Double(probes)
                textured[s] = true
                texturedCount += 1
            }
            let inner = probeReach(f, x, y, -nx, -ny, offset), outer = probeReach(f, x, y, nx, ny, offset)
            let a = pixelIndex(f, x - nx * inner, y - ny * inner)
            let b = pixelIndex(f, x + nx * outer, y + ny * outer)
            let diff = abs(f.r[a] - f.r[b]) + abs(f.g[a] - f.g[b]) + abs(f.b[a] - f.b[b])
            contrastSum += Double(diff) / 768.0
        }
        if inFrame == 0 || inFrame * 4 < samples { return SideMeasure(support: 0, contrast: 0, covered: false) }
        var bestK = 0
        var sign = 1.0, bestSum = -1.0
        for k in 0..<span {
            if pos[k] > bestSum {
                bestSum = pos[k]
                bestK = k
                sign = 1
            }
            if neg[k] > bestSum {
                bestSum = neg[k]
                bestK = k
                sign = -1
            }
        }
        var level = 0.0
        if texturedCount > 0 {
            var levels: [Double] = []
            levels.reserveCapacity(texturedCount)
            for s in 0..<samples where textured[s] { levels.append(texture[s]) }
            levels.sort()
            level = levels[texturedCount / 2]
        }
        var support = 0
        for s in 0..<samples where used[s] {
            var e = -Double.greatestFiniteMagnitude
            for k in max(0, bestK - 1)...min(span - 1, bestK + 1) { e = max(e, sign * g[s * span + k]) }
            if e >= edgeThreshold && e >= textureRatio * level { support += 1 }
        }
        return SideMeasure(support: Double(support) / Double(inFrame), contrast: contrastSum / Double(inFrame),
                           covered: true, sign: sign)
    }

    /// The index of the analysis pixel holding the continuous point (x, y), clamped into the frame.
    private static func pixelIndex(_ f: Field, _ x: Double, _ y: Double) -> Int {
        let px = Int(min(max(x.rounded(.down), 0), Double(f.w - 1)))
        let py = Int(min(max(y.rounded(.down), 0), Double(f.h - 1)))
        return py * f.w + px
    }

    /// How far from (x, y) along the unit direction (ux, uy) a probe can go, at most `limit`, and stay
    /// half a pixel short of where the frame ends (0 at least).
    private static func probeReach(_ f: Field, _ x: Double, _ y: Double, _ ux: Double, _ uy: Double, _ limit: Double) -> Double {
        var room = Double.greatestFiniteMagnitude
        if ux > 0 { room = min(room, (Double(f.w) - x) / ux) } else if ux < 0 { room = min(room, x / -ux) }
        if uy > 0 { room = min(room, (Double(f.h) - y) / uy) } else if uy < 0 { room = min(room, y / -uy) }
        return max(0, min(limit, room - 0.5))
    }

    // MARK: - Straight edges

    /// The thinned edge pixels of the analysis image, with what the line searches need.
    final class EdgeSet {
        var count = 0
        /// Pixel centers.
        var x: [Double] = []
        var y: [Double] = []
        /// Unit gradients, turned to point down (or right when level).
        var nx: [Double] = []
        var ny: [Double] = []
        /// Hough votes: the gradient up to `voteCap`, less when crowded.
        var weight: [Double] = []
        /// Direction bins (0...179), and the pixels by bin: those of bin k are order[start[k]] to order[start[k + 1] - 1].
        var bin: [Int] = []
        var start: [Int] = []
        var order: [Int] = []
    }

    /// The edge pixels: gradients of at least `edgeThreshold` thinned to their ridge (larger than the
    /// neighbor behind across the gradient, at least the one ahead), each with its direction and its
    /// vote: its gradient up to `voteCap`, times 1.5 − 2.5 × the share of edge pixels within
    /// `isolationRadius` px (between `isolationFloor` and 1).
    static func findEdges(_ f: Field) -> EdgeSet {
        let w = f.w, h = f.h
        var edges: [Int] = []
        var isEdge = [Int](repeating: 0, count: w * h)
        if h >= 3 && w >= 3 {
            for y in 1..<(h - 1) {
                for x in 1..<(w - 1) {
                    let i = y * w + x
                    let m = f.mag[i]
                    if m < edgeThreshold { continue }
                    let ax = abs(f.gx[i]), ay = abs(f.gy[i])
                    let a: Int, b: Int
                    if ay <= ax * 0.41421356 {
                        a = i - 1; b = i + 1
                    } else if ax <= ay * 0.41421356 {
                        a = i - w; b = i + w
                    } else if f.gx[i] * f.gy[i] > 0 {
                        a = i - w - 1; b = i + w + 1
                    } else {
                        a = i - w + 1; b = i + w - 1
                    }
                    if m > f.mag[a] && m >= f.mag[b] {
                        edges.append(i)
                        isEdge[i] = 1
                    }
                }
            }
        }

        // The count of edge pixels in every rectangle, from a summed-area table.
        let stride = w + 1
        var integral = [Int](repeating: 0, count: stride * (h + 1))
        for y in 0..<h {
            var run = 0
            for x in 0..<w {
                run += isEdge[y * w + x]
                integral[(y + 1) * stride + x + 1] = integral[y * stride + x + 1] + run
            }
        }

        let ne = edges.count
        let es = EdgeSet()
        es.count = ne
        es.x = [Double](repeating: 0, count: ne)
        es.y = [Double](repeating: 0, count: ne)
        es.nx = [Double](repeating: 0, count: ne)
        es.ny = [Double](repeating: 0, count: ne)
        es.weight = [Double](repeating: 0, count: ne)
        es.bin = [Int](repeating: 0, count: ne)
        for e in 0..<ne {
            let i = edges[e]
            let x = i % w, y = i / w
            let m = f.mag[i]
            var nx = f.gx[i] / m, ny = f.gy[i] / m
            if ny < 0 || (ny == 0 && nx < 0) {
                nx = -nx
                ny = -ny
            }
            es.x[e] = Double(x) + 0.5
            es.y[e] = Double(y) + 0.5
            es.nx[e] = nx
            es.ny[e] = ny
            es.bin[e] = angleBin(nx) % 180
            let x0 = max(0, x - isolationRadius), x1 = min(w, x + isolationRadius + 1)
            let y0 = max(0, y - isolationRadius), y1 = min(h, y + isolationRadius + 1)
            let crowd = integral[y1 * stride + x1] - integral[y0 * stride + x1] - integral[y1 * stride + x0]
                + integral[y0 * stride + x0]
            let density = Double(crowd) / Double((x1 - x0) * (y1 - y0))
            es.weight[e] = min(m, voteCap) * min(max(1.5 - 2.5 * density, isolationFloor), 1)
        }

        // The edge pixels by direction (in the order found within each bin), for refitting.
        var start = [Int](repeating: 0, count: 181)
        for e in 0..<ne { start[es.bin[e] + 1] += 1 }
        for k in 0..<180 { start[k + 1] += start[k] }
        var fill = [Int](repeating: 0, count: 180)
        var order = [Int](repeating: 0, count: ne)
        for e in 0..<ne {
            let k = es.bin[e]
            order[start[k] + fill[k]] = e
            fill[k] += 1
        }
        es.start = start
        es.order = order
        return es
    }

    /// The straight edges of the analysis image, strongest first: the edge pixels vote in a Hough
    /// transform (1° by 1 px, within `houghWindow`° of their own direction, their weight); each peak
    /// is refitted to the edge pixels within 2.5 px of it that face within 12° of its way, and
    /// repeats are dropped. At most `maxLines`, from at most three times as many peaks.
    static func findLines(_ f: Field, _ es: EdgeSet, _ maxLines: Int) -> [Line] {
        let w = f.w, h = f.h
        let maxRho = Int(f.diagonal.rounded(.up)) + 1
        let nr = 2 * maxRho + 1
        var acc = [Double](repeating: 0, count: 180 * nr)
        let cosT = cosTable, sinT = sinTable
        for e in 0..<es.count {
            let k = es.bin[e]
            let weight = es.weight[e]
            for d in -houghWindow...houghWindow {
                let kk = ((k + d) % 180 + 180) % 180
                let rho = es.x[e] * cosT[kk] + es.y[e] * sinT[kk]
                let ri = Int((rho + 0.5).rounded(.down)) + maxRho
                acc[kk * nr + ri] += weight
            }
        }
        let peaks = findPeaks(acc, 180, nr, minLineShare * Double(min(w, h)) * edgeThreshold)
        var lines: [Line] = []
        var tried = 0
        for peak in peaks {
            if lines.count >= maxLines || tried >= 3 * maxLines { break }
            tried += 1
            let k = peak.index / nr, r = peak.index % nr
            var line = Line(nx: cosT[k], ny: sinT[k], rho: Double(r - maxRho))
            line = refitLine(es, k, line) ?? line
            if !isRepeat(lines, line) { lines.append(line) }
        }
        return lines
    }

    /// Lines that could be edge `side` of `q`: a Hough transform of the edge pixels between the lines
    /// of its two neighboring edges (at most `corridorMargin` px outside either), no deeper inside the
    /// outline than `corridorDepth` of its depth there, facing within 20° of the edge's normal, for
    /// directions within `corridorBins`° of the edge's; the `corridorPeaks` strongest peaks and the
    /// `corridorOutermost` outermost others, refitted, without repeats.
    static func corridorLines(_ f: Field, _ es: EdgeSet, _ q: Quad, _ side: Int) -> [Line] {
        var result: [Line] = []
        let p0 = q[side], p1 = q[side + 1]
        if Quad.distance(p0, p1) < 4 { return result }
        let edge = Line.through(p0, p1)
        let before = Line.through(q[side + 3], q[side])
        let after = Line.through(q[side + 1], q[side + 2])
        let mx = (Double(q[side + 2].x) + Double(q[side + 3].x)) / 2
        let my = (Double(q[side + 2].y) + Double(q[side + 3].y)) / 2
        let depth = -edge.distance(mx, my)
        var nx = edge.nx, ny = edge.ny
        if ny < 0 || (ny == 0 && nx < 0) {
            nx = -nx
            ny = -ny
        }
        let k0 = angleBin(nx) % 180
        let cosT = cosTable, sinT = sinTable
        var members: [Int] = []
        for e in 0..<es.count {
            let x = es.x[e], y = es.y[e]
            if before.distance(x, y) > corridorMargin || after.distance(x, y) > corridorMargin { continue }
            if edge.distance(x, y) < -corridorDepth * depth { continue }
            let c = es.nx[e] * edge.nx + es.ny[e] * edge.ny
            if c < 0.94 && c > -0.94 { continue }
            members.append(e)
        }
        if members.count < 10 { return result }
        // Each member votes for the directions within houghWindow of its own (d, relative to the
        // edge's bin k0, within ±corridorBins); first the distances they reach, so the accumulator
        // spans only those, with room for the peak search.
        let span = 2 * corridorBins + 1
        var first = [Int](repeating: 0, count: members.count)
        var last = [Int](repeating: 0, count: members.count)
        var lowest = Int.max, highest = Int.min
        for m in 0..<members.count {
            let e = members[m]
            var rel = es.bin[e] - k0
            if rel > 90 { rel -= 180 }
            if rel < -90 { rel += 180 }
            first[m] = max(-corridorBins, rel - houghWindow)
            last[m] = min(corridorBins, rel + houghWindow)
            if first[m] > last[m] { continue }
            for d in first[m]...last[m] {
                let kk = ((k0 + d) % 180 + 180) % 180
                let ri = Int((es.x[e] * cosT[kk] + es.y[e] * sinT[kk] + 0.5).rounded(.down))
                lowest = min(lowest, ri)
                highest = max(highest, ri)
            }
        }
        if lowest > highest { return result }
        let maxRho = -lowest + 5
        let nr = highest - lowest + 11
        var acc = [Double](repeating: 0, count: span * nr)
        for m in 0..<members.count {
            let e = members[m]
            let x = es.x[e], y = es.y[e]
            if first[m] > last[m] { continue }
            for d in first[m]...last[m] {
                let kk = ((k0 + d) % 180 + 180) % 180
                let rho = x * cosT[kk] + y * sinT[kk]
                let ri = Int((rho + 0.5).rounded(.down)) + maxRho
                acc[(d + corridorBins) * nr + ri] += es.weight[e]
            }
        }
        let peaks = findPeaks(acc, span, nr, 10 * edgeThreshold)
        // The strongest peaks, and the outermost ones (a sheet's edge lies outside the print on it):
        // how far out each crosses the normal through the edge's midpoint.
        let cx = (Double(p0.x) + Double(p1.x)) / 2, cy = (Double(p0.y) + Double(p1.y)) / 2
        var outward: [(offset: Double, rank: Int)] = []
        for i in 0..<peaks.count {
            let d = peaks[i].index / nr - corridorBins, r = peaks[i].index % nr
            let kk = ((k0 + d) % 180 + 180) % 180
            let den = cosT[kk] * edge.nx + sinT[kk] * edge.ny
            if abs(den) < 1e-6 { continue }
            let along = cosT[kk] * cx + sinT[kk] * cy
            outward.append(((Double(r - maxRho) - along) / den, i))
        }
        outward.sort { a, b in a.offset != b.offset ? a.offset > b.offset : a.rank < b.rank }
        var chosen: [Int] = []
        var i = 0
        while i < peaks.count && chosen.count < corridorPeaks {
            chosen.append(i)
            i += 1
        }
        let strongest = peaks.isEmpty ? 0 : peaks[0].votes
        var added = 0
        for entry in outward {
            if added >= corridorOutermost { break }
            if chosen.contains(entry.rank) || peaks[entry.rank].votes < corridorOutermostShare * strongest { continue }
            chosen.append(entry.rank)
            added += 1
        }
        for index in chosen {
            let peak = peaks[index]
            let d = peak.index / nr - corridorBins, r = peak.index % nr
            let kk = ((k0 + d) % 180 + 180) % 180
            var line = Line(nx: cosT[kk], ny: sinT[kk], rho: Double(r - maxRho))
            var points: [CGPoint] = []
            for e in members {
                let dist = line.nx * es.x[e] + line.ny * es.y[e] - line.rho
                if dist > 2.5 || dist < -2.5 { continue }
                let c = es.nx[e] * line.nx + es.ny[e] * line.ny
                if c < 0.978 && c > -0.978 { continue }
                points.append(CGPoint(x: es.x[e], y: es.y[e]))
            }
            if points.count >= 10 { line = fitLine(points) }
            if !isRepeat(result, line) { result.append(line) }
        }
        return result
    }

    /// The local maxima of a Hough accumulator (`bins` directions by `nr` distances) of at least
    /// `minVotes`: no neighbor within two directions and four distances is larger (or equal and
    /// earlier); strongest first, the earlier on a tie.
    private static func findPeaks(_ acc: [Double], _ bins: Int, _ nr: Int, _ minVotes: Double) -> [(votes: Double, index: Int)] {
        var peaks: [(votes: Double, index: Int)] = []
        for k in 0..<bins {
            for r in 0..<nr {
                let idx = k * nr + r
                let v = acc[idx]
                if v < minVotes { continue }
                var isMax = true
                var dk = -2
                while dk <= 2 && isMax {
                    let kk = k + dk
                    if kk >= 0 && kk < bins {
                        for dr in -4...4 {
                            let rr = r + dr
                            if rr < 0 || rr >= nr || (dk == 0 && dr == 0) { continue }
                            let n = kk * nr + rr
                            let nv = acc[n]
                            if nv > v || (nv == v && n < idx) {
                                isMax = false
                                break
                            }
                        }
                    }
                    dk += 1
                }
                if isMax { peaks.append((v, idx)) }
            }
        }
        peaks.sort { a, b in a.votes != b.votes ? a.votes > b.votes : a.index < b.index }
        return peaks
    }

    /// A line within 3° and 6 px of one in `lines`.
    private static func isRepeat(_ lines: [Line], _ line: Line) -> Bool {
        for l in lines {
            let dot = l.nx * line.nx + l.ny * line.ny
            let rhoDiff = dot >= 0 ? abs(l.rho - line.rho) : abs(l.rho + line.rho)
            if abs(dot) >= 0.9986 && rhoDiff <= 6 { return true }
        }
        return false
    }

    /// The bin (0...180) of the angle whose cosine is nearest `nx`.
    private static func angleBin(_ nx: Double) -> Int {
        let cosT = cosTable
        var lo = 0, hi = 180
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if cosT[mid] >= nx { lo = mid } else { hi = mid }
        }
        return cosT[lo] - nx <= nx - cosT[hi] ? lo : hi
    }

    /// The line fitted to the edge pixels within 2.5 px of `line` (of direction bin `bin`) whose
    /// gradient is within 12° of its normal, looked for in the bins within 13° of it; nil when fewer than 10.
    private static func refitLine(_ es: EdgeSet, _ bin: Int, _ line: Line) -> Line? {
        var points: [CGPoint] = []
        for d in -13...13 {
            let k = ((bin + d) % 180 + 180) % 180
            var j = es.start[k]
            while j < es.start[k + 1] {
                let e = es.order[j]
                j += 1
                let dist = line.nx * es.x[e] + line.ny * es.y[e] - line.rho
                if dist > 2.5 || dist < -2.5 { continue }
                let c = es.nx[e] * line.nx + es.ny[e] * line.ny
                if c < 0.978 && c > -0.978 { continue }
                points.append(CGPoint(x: es.x[e], y: es.y[e]))
            }
        }
        if points.count < 10 { return nil }
        return fitLine(points)
    }

    /// Outlines made of the straight edges: two pairs of near-parallel edges (within 40°, at least
    /// 15 % of the short side apart), the pairs crossing at 40° or more; the four crossings,
    /// clockwise, with every corner at most `outsideShare` of the frame outside it.
    private static func lineQuads(_ f: Field, _ lines: [Line], _ o: PhotoDocumentOptions) -> [Quad] {
        var quads: [Quad] = []
        let n = lines.count
        let minGap = 0.15 * Double(min(f.w, f.h))
        var pairs: [(a: Int, b: Int)] = []
        for i in 0..<n {
            for j in (i + 1)..<max(i + 1, n) {
                let dot = lines[i].nx * lines[j].nx + lines[i].ny * lines[j].ny
                if abs(dot) < oppositeMinCos { continue }
                // The gap between the two lines at the frame's center.
                let cx = Double(f.w) / 2.0, cy = Double(f.h) / 2.0
                let pa = project(lines[i], cx, cy)
                let gap = abs(lines[j].distance(Double(pa.x), Double(pa.y)))
                if gap < minGap { continue }
                pairs.append((i, j))
            }
        }
        let minX = -outsideShare * Double(f.w), maxX = (1 + outsideShare) * Double(f.w)
        let minY = -outsideShare * Double(f.h), maxY = (1 + outsideShare) * Double(f.h)
        let frame = Double(f.w) * Double(f.h)
        for p in 0..<pairs.count {
            for r in (p + 1)..<max(p + 1, pairs.count) {
                let (a, b) = pairs[p]
                let (c, d) = pairs[r]
                if a == c || a == d || b == c || b == d { continue }
                let crossing = abs(lines[a].nx * lines[c].nx + lines[a].ny * lines[c].ny)
                if crossing > maxCornerCos { continue }
                guard let p0 = Line.intersect(lines[a], lines[c]),
                      let p1 = Line.intersect(lines[c], lines[b]),
                      let p2 = Line.intersect(lines[b], lines[d]),
                      let p3 = Line.intersect(lines[d], lines[a]) else { continue }
                let corners = [p0, p1, p2, p3]
                var inside = true
                for pt in corners {
                    let x = Double(pt.x), y = Double(pt.y)
                    if x < minX || x > maxX || y < minY || y > maxY { inside = false }
                }
                if !inside { continue }
                let q = Quad.fromCorners(corners)
                if !q.isConvex { continue }
                let share = q.area / frame
                if share < o.minAreaShare || share > maxAreaShare { continue }
                quads.append(q)
            }
        }
        return quads
    }

    private static func project(_ l: Line, _ x: Double, _ y: Double) -> CGPoint {
        let d = l.distance(x, y)
        return CGPoint(x: x - l.nx * d, y: y - l.ny * d)
    }

    // MARK: - Regions

    /// Outlines of the regions that stand out, found at half the analysis resolution (2 × 2 means):
    /// pixels whose color differs from the median color of the frame's border (3 % of the short
    /// side) by more than an Otsu threshold (at least `minRegionContrast`), and pixels brighter than
    /// the Otsu threshold of the brightness; each mask opened by one pixel, its two largest parts of
    /// at least the least page size taken, each part's convex hull simplified to `maxHullVertices`
    /// corners and the four of them enclosing the largest area kept, in analysis pixels.
    private static func regionQuads(_ f: Field, _ o: PhotoDocumentOptions) -> [Quad] {
        let fw = f.w, w = f.w / 2, h = f.h / 2, count = w * h
        var quads: [Quad] = []
        var cr = [Int](repeating: 0, count: count)
        var cg = [Int](repeating: 0, count: count)
        var cb = [Int](repeating: 0, count: count)
        for y in 0..<h {
            for x in 0..<w {
                let a = 2 * y * fw + 2 * x, b = a + fw
                let i = y * w + x
                cr[i] = (f.r[a] + f.r[a + 1] + f.r[b] + f.r[b + 1]) >> 10
                cg[i] = (f.g[a] + f.g[a + 1] + f.g[b] + f.g[b + 1]) >> 10
                cb[i] = (f.b[a] + f.b[a + 1] + f.b[b] + f.b[b + 1]) >> 10
            }
        }
        let ring = max(2, Int((0.03 * Double(min(w, h))).rounded()))
        var hr = [Int](repeating: 0, count: 256)
        var hg = [Int](repeating: 0, count: 256)
        var hb = [Int](repeating: 0, count: 256)
        var ringCount = 0
        for y in 0..<h {
            for x in 0..<w {
                if x >= ring && x < w - ring && y >= ring && y < h - ring { continue }
                let i = y * w + x
                hr[cr[i]] += 1
                hg[cg[i]] += 1
                hb[cb[i]] += 1
                ringCount += 1
            }
        }
        let mr = Int(BackgroundMap.percentile(hr, count: ringCount, fraction: 0.5))
        let mg = Int(BackgroundMap.percentile(hg, count: ringCount, fraction: 0.5))
        let mb = Int(BackgroundMap.percentile(hb, count: ringCount, fraction: 0.5))

        var distance = [Int](repeating: 0, count: count)
        var luma = [Int](repeating: 0, count: count)
        var hd = [Int](repeating: 0, count: 256)
        var hl = [Int](repeating: 0, count: 256)
        for i in 0..<count {
            let r = cr[i], g = cg[i], b = cb[i]
            let d = max(abs(r - mr), max(abs(g - mg), abs(b - mb)))
            distance[i] = d
            hd[d] += 1
            let l = (299 * r + 587 * g + 114 * b + 500) / 1000
            luma[i] = l
            hl[l] += 1
        }
        let td = max(minRegionContrast, otsu(hd, count))
        let tl = otsu(hl, count)
        for pass in 0..<2 {
            var mask = [UInt8](repeating: 0, count: count)
            var marked = 0
            for i in 0..<count {
                let on = pass == 0 ? distance[i] > td : luma[i] > tl
                if on {
                    mask[i] = 1
                    marked += 1
                }
            }
            if Double(marked) < o.minAreaShare * Double(count) || Double(marked) > 0.97 * Double(count) { continue }
            mask = MaskOps.dilate(MaskOps.erode(mask, w, h, radius: 1), w, h, radius: 1)
            let parts = MaskOps.connectedComponents(mask: mask, width: w, height: h)
            var big: [(area: Int, index: Int)] = []
            for i in 0..<parts.count where Double(parts[i].area) >= o.minAreaShare * Double(count) {
                big.append((parts[i].area, i))
            }
            big.sort { a, b in a.area != b.area ? a.area > b.area : a.index < b.index }
            for k in 0..<min(2, big.count) {
                let part = parts[big[k].index]
                var points: [CGPoint] = []
                for (y, span) in part.rows {
                    points.append(CGPoint(x: 2 * span.minX, y: 2 * y))
                    points.append(CGPoint(x: 2 * (span.maxX + 1), y: 2 * y))
                    points.append(CGPoint(x: 2 * span.minX, y: 2 * (y + 1)))
                    points.append(CGPoint(x: 2 * (span.maxX + 1), y: 2 * (y + 1)))
                }
                let hull = simplify(convexHull(points), maxHullVertices)
                if let q = largestQuad(hull) { quads.append(q) }
            }
        }
        return quads
    }

    /// The Otsu threshold of a 256-level histogram: values above it are the brighter class.
    static func otsu(_ histogram: [Int], _ total: Int) -> Int {
        var sumAll = 0.0
        for v in 0..<256 { sumAll += Double(v) * Double(histogram[v]) }
        var sumB = 0.0, best = -1.0
        var wB = 0
        var threshold = 0
        for t in 0..<256 {
            wB += histogram[t]
            if wB == 0 { continue }
            let wF = total - wB
            if wF == 0 { break }
            sumB += Double(t) * Double(histogram[t])
            let mB = sumB / Double(wB), mF = (sumAll - sumB) / Double(wF)
            let between = Double(wB) * Double(wF) * (mB - mF) * (mB - mF)
            if between > best {
                best = between
                threshold = t
            }
        }
        return threshold
    }

    /// A convex polygon cut to at most `max` corners by dropping, one at a time, the corner whose
    /// triangle with its neighbors is smallest (the first on a tie).
    static func simplify(_ polygon: [CGPoint], _ limit: Int) -> [CGPoint] {
        var p = polygon
        while p.count > limit {
            let n = p.count
            var worst = 0
            var smallest = Double.greatestFiniteMagnitude
            for i in 0..<n {
                let a = p[(i + n - 1) % n], b = p[i], c = p[(i + 1) % n]
                let area = abs((Double(b.x) - Double(a.x)) * (Double(c.y) - Double(a.y))
                    - (Double(b.y) - Double(a.y)) * (Double(c.x) - Double(a.x)))
                if area < smallest {
                    smallest = area
                    worst = i
                }
            }
            p.remove(at: worst)
        }
        return p
    }

    /// The four corners of a convex polygon that enclose the largest area, as a quad; nil for fewer
    /// than four corners.
    static func largestQuad(_ hull: [CGPoint]) -> Quad? {
        let n = hull.count
        if n < 4 { return nil }
        var best = -1.0
        var ba = 0, bb = 0, bc = 0, bd = 0
        for a in 0..<n {
            var c = a + 2
            while c < n {
                defer { c += 1 }
                if n - (c - a) < 2 { continue }
                var best1 = -1.0, best2 = -1.0
                var b1 = -1, d1 = -1
                for b in (a + 1)..<c {
                    let t = abs(cross(hull[a], hull[b], hull[c]))
                    if t > best1 {
                        best1 = t
                        b1 = b
                    }
                }
                var d = c + 1
                while d < a + n {
                    let t = abs(cross(hull[c], hull[d % n], hull[a]))
                    if t > best2 {
                        best2 = t
                        d1 = d % n
                    }
                    d += 1
                }
                if b1 < 0 || d1 < 0 { continue }
                let area = best1 + best2
                if area > best {
                    best = area
                    ba = a
                    bb = b1
                    bc = c
                    bd = d1
                }
            }
        }
        if best <= 0 { return nil }
        let q = Quad.fromCorners([hull[ba], hull[bb], hull[bc], hull[bd]])
        return q.isConvex ? q : nil
    }

    private static func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> Double {
        (Double(a.x) - Double(o.x)) * (Double(b.y) - Double(o.y)) - (Double(a.y) - Double(o.y)) * (Double(b.x) - Double(o.x))
    }

    // MARK: - Refitting an outline to its edges

    /// The outline with each edge refitted to the edge points within `reach` px across it
    /// (`refitSide`; an edge with too few keeps its line, at most one), the corners where the new
    /// edges cross; nil when fewer than three edges refit, the result is not convex, or a corner
    /// moved more than twice the reach and 2 px.
    static func refineQuad(_ f: Field, _ q: Quad, _ reach: Double) -> Quad? {
        var lines: [Line] = []
        var refit = 0
        for i in 0..<4 {
            let p0 = q[i], p1 = q[i + 1]
            if Quad.distance(p0, p1) < 4 { return nil }
            if let line = refitSide(f, p0, p1, reach) {
                lines.append(line)
                refit += 1
            } else {
                lines.append(Line.through(p0, p1))
            }
        }
        if refit < 3 { return nil }
        var corners: [CGPoint] = []
        for i in 0..<4 {
            guard let c = Line.intersect(lines[(i + 3) & 3], lines[i]) else { return nil }
            corners.append(c)
        }
        let result = Quad(topLeft: corners[0], topRight: corners[1], bottomRight: corners[2], bottomLeft: corners[3])
        if !result.isConvex { return nil }
        for i in 0..<4 where Quad.distance(result[i], q[i]) > 2 * reach + 2 { return nil }
        return result
    }

    /// As C# `RefitSide`: at points every 2 px along the edge (8 % to 92 %), the gradient across it
    /// within `reach` px of the sign that prevails within `polarityReach` px of the edge as it is,
    /// the strongest (nearer ones favored: one at the reach counts half), placed to a fraction of a
    /// pixel by a parabola through its neighbors; those of at least `edgeThreshold` fitted by
    /// `fitLine`. nil when fewer than a third of the points (and 6) are found.
    private static func refitSide(_ f: Field, _ p: CGPoint, _ q: CGPoint, _ reach: Double) -> Line? {
        let px = Double(p.x), py = Double(p.y)
        let dx = Double(q.x) - px, dy = Double(q.y) - py
        let len = (dx * dx + dy * dy).squareRoot()
        if !(len >= 1) || len > 1e6 { return nil }
        let ux = dx / len, uy = dy / len
        let nx = uy, ny = -ux
        let r = Int(reach.rounded(.up))
        let span = 2 * r + 1
        let samples = min(max(Int(len / 2), 8), 300)
        var values = [Double](repeating: 0, count: samples * span)
        var usable = [Bool](repeating: false, count: samples)
        var xs = [Double](repeating: 0, count: samples)
        var ys = [Double](repeating: 0, count: samples)
        var sumPos = 0.0, sumNeg = 0.0
        let lo = 1.5, hiX = Double(f.w) - 1.5, hiY = Double(f.h) - 1.5
        for s in 0..<samples {
            let t = 0.08 + 0.84 * (Double(s) + 0.5) / Double(samples)
            let x = px + dx * t, y = py + dy * t
            xs[s] = x
            ys[s] = y
            let rr = Double(r)
            let ex0 = x - nx * rr, ey0 = y - ny * rr, ex1 = x + nx * rr, ey1 = y + ny * rr
            if ex0 < lo || ey0 < lo || ex1 < lo || ey1 < lo || ex0 > hiX || ex1 > hiX || ey0 > hiY || ey1 > hiY {
                continue
            }
            usable[s] = true
            var bestPos = 0.0, bestNeg = 0.0
            for k in -r...r {
                let gradient = f.gradientAt(x + nx * Double(k), y + ny * Double(k))
                let g = gradient.gx * nx + gradient.gy * ny
                values[s * span + k + r] = g
                if k < -polarityReach || k > polarityReach { continue }
                if g > bestPos { bestPos = g }
                if -g > bestNeg { bestNeg = -g }
            }
            sumPos += bestPos
            sumNeg += bestNeg
        }
        let sign: Double = sumPos >= sumNeg ? 1 : -1
        var points: [CGPoint] = []
        for s in 0..<samples where usable[s] {
            // The strongest response of that sign, nearer ones favored (a full-strength edge at the
            // reach counts half), so a stronger parallel edge further off does not pull the line.
            var best = -1
            var bestWeighted = 0.0
            for k in 0..<span {
                let v = sign * values[s * span + k]
                if v < edgeThreshold { continue }
                let weighted = v * (1 - 0.5 * Double(abs(k - r)) / (Double(r) + 1.0))
                if weighted > bestWeighted {
                    bestWeighted = weighted
                    best = k
                }
            }
            if best < 0 { continue }
            let bestValue = sign * values[s * span + best]
            var delta = 0.0
            if best > 0 && best < span - 1 {
                let a = sign * values[s * span + best - 1], c = sign * values[s * span + best + 1]
                let den = a - 2 * bestValue + c
                if den < 0 { delta = min(max(0.5 * (a - c) / den, -0.5), 0.5) }
            }
            let off = Double(best - r) + delta
            points.append(CGPoint(x: xs[s] + nx * off, y: ys[s] + ny * off))
        }
        if points.count < max(6, samples / 3) { return nil }
        return fitLine(points)
    }

    /// The total-least-squares line through `points`, refitted twice without the points farther from
    /// it than 2.5 times the median distance (and 0.75 px).
    static func fitLine(_ points: [CGPoint]) -> Line {
        var current = points
        var line = fit(current)
        for _ in 0..<2 {
            var distances = [Double](repeating: 0, count: current.count)
            for i in 0..<current.count { distances[i] = abs(line.distance(Double(current[i].x), Double(current[i].y))) }
            let sorted = distances.sorted()
            let limit = max(0.75, 2.5 * sorted[sorted.count / 2])
            var kept: [CGPoint] = []
            for i in 0..<current.count where distances[i] <= limit { kept.append(current[i]) }
            if kept.count < 4 || kept.count == current.count { break }
            current = kept
            line = fit(current)
        }
        return line
    }

    private static func fit(_ points: [CGPoint]) -> Line {
        var mx = 0.0, my = 0.0
        for p in points {
            mx += Double(p.x)
            my += Double(p.y)
        }
        mx /= Double(points.count)
        my /= Double(points.count)
        var sxx = 0.0, sxy = 0.0, syy = 0.0
        for p in points {
            let dx = Double(p.x) - mx, dy = Double(p.y) - my
            sxx += dx * dx
            sxy += dx * dy
            syy += dy * dy
        }
        // The direction of largest spread: the eigenvector of the larger eigenvalue.
        let half = (sxx - syy) / 2
        let lambda = (sxx + syy) / 2 + (half * half + sxy * sxy).squareRoot()
        let ax = lambda - syy, ay = sxy
        let bx = sxy, by = lambda - sxx
        var dirX: Double, dirY: Double
        if abs(ax) + abs(ay) >= abs(bx) + abs(by) {
            dirX = ax
            dirY = ay
        } else {
            dirX = bx
            dirY = by
        }
        var len = (dirX * dirX + dirY * dirY).squareRoot()
        if len == 0 {
            dirX = 1
            dirY = 0
            len = 1
        }
        let nx = -dirY / len, ny = dirX / len
        return Line(nx: nx, ny: ny, rho: nx * mx + ny * my)
    }
}
