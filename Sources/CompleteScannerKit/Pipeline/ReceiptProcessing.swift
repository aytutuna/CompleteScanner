import CoreGraphics
import Foundation

// Twin of windows/LazyScan.Core/ReceiptProcessing.cs: same constants, same steps, same patterns.

/// How a receipt's edges were found (`ReceiptDetector`).
public enum ReceiptBasis: Sendable {
    /// The paper stands out from the lid: the receipt is cut along its own edges.
    case paper
    /// The paper does not stand out (thermal paper on a white lid): the receipt is cut around its print, with a margin.
    case text
}

/// One receipt found on a scan.
public struct ReceiptRegion: Equatable {
    /// Where it lies, in the pixels of the image searched.
    public let region: DetectedPhotoRegion
    /// What its edges come from.
    public let basis: ReceiptBasis

    public init(region: DetectedPhotoRegion, basis: ReceiptBasis) {
        self.region = region
        self.basis = basis
    }
}

/// How receipts are looked for.
public struct ReceiptDetectorOptions: Equatable, Sendable {
    /// At most this many receipts are taken from one scan (the largest).
    public var maxReceipts: Int = ReceiptDetector.maxReceipts
    /// The scan holds one receipt (a sheet from the feeder): everything printed on it is one receipt,
    /// however far apart.
    public var singleReceipt: Bool = false

    public init(maxReceipts: Int = ReceiptDetector.maxReceipts, singleReceipt: Bool = false) {
        self.maxReceipts = maxReceipts
        self.singleReceipt = singleReceipt
    }
}

/// Finds the receipts lying on a scan, several at once. Thermal paper on a white lid hardly differs
/// from the lid, so receipts are found by their print and cut out along their paper when it shows:
/// 1. Marks: on the scan's gray copy at the analysis resolution, what differs from the lid (the
///    median of the outer ring) by more than `markContrast`: print, and paper edges with some contrast.
/// 2. Blocks: the marks closed by `closeInches` (letters and lines run together) and opened by one
///    pixel (specks go); the blocks one above the other (overlapping across by at least
///    `columnOverlap` of the narrower, less than `columnGapInches` apart) are one receipt, and a block
///    too small to be a receipt joins the receipt it lies next to (less than `columnGapInches` away),
///    or beside (a column of prices, up to `sideGapInches` away). Where the paper shows, blocks on
///    different sheets are never joined, and a small block joins the receipt on its own sheet.
/// 3. Receipts: blocks at least `minShortSideInches` by `minLongSideInches` and
///    `minAreaSquareInches`, at most `maxReceipts`.
/// 4. Edges: around each one, the paper is looked for as a sheet (`DocumentGeometry.findPage(_:options:)`
///    held to `pageSearch`: thermal paper's low contrast, curled edges, receipts many times as long as
///    wide); when it holds all the print, the receipt is cut along it (`.paper`). Otherwise it is cut
///    around its print at the angle of its lines of text (`DocumentGeometry.estimateTextLayout`), with
///    `paddingInches` of margin (`.text`).
/// Regions are sorted top to bottom, then left to right, as photos are. Twin of C# `ReceiptDetector`.
public enum ReceiptDetector {
    /// A pixel is a mark when it differs from the lid by more than this (0...1).
    public static let markContrast = 0.09
    /// Marks closer than about twice this many inches run together into a block.
    public static let closeInches = 0.12
    /// Blocks smaller than this many square inches (dust) take no part.
    public static let minBlockSquareInches = 0.01
    /// Blocks one above the other overlap across by at least this share of the narrower…
    public static let columnOverlap = 0.5
    /// …and are less than this many inches apart to be one receipt; a small block joins a receipt this close.
    public static let columnGapInches = 0.6
    /// A small block beside a receipt (most of its height within the receipt's) joins it up to this
    /// many inches away: the prices printed far right of short items.
    public static let sideGapInches = 1.5
    /// A receipt is at least this many inches wide…
    public static let minShortSideInches = 0.5
    /// …this many inches long…
    public static let minLongSideInches = 1.0
    /// …and covers this many square inches.
    public static let minAreaSquareInches = 0.75
    /// The most receipts taken from one scan.
    public static let maxReceipts = 12
    /// A receipt cut around its print gets this margin on every side, in inches.
    public static let paddingInches = 0.08
    /// The paper is looked for this far around the print, in inches, and, when it is not found there
    /// (it may run further: a blank tail), this far.
    public static let searchMarginsInches: [Double] = [0.4, 1.2]
    /// The paper's edges hold all the print, give or take this many inches.
    public static let paperToleranceInches = 0.05
    /// A sheet of paper that shows is at least this many square inches.
    public static let minPaperSquareInches = 0.5

    /// The limits a receipt's paper is held to: thermal paper differs from a white lid by a few levels
    /// only, its edges curl, and a long receipt is many times as long as wide. Only the Receipts task
    /// relaxes `DocumentGeometry`'s limits this way.
    public static let pageSearch: PageSearchOptions = {
        var options = PageSearchOptions()
        options.pageContrast = 0.02
        options.minPageFill = 0.85
        options.maxPageAspect = 15
        return options
    }()

    /// The receipts on `image`, scanned at `dpi`, in its pixels, sorted top to bottom, then left to
    /// right. Empty when nothing looks like a receipt.
    public static func detectRegions(in image: RgbaImage, dpi: Int,
                                     options: ReceiptDetectorOptions = ReceiptDetectorOptions()) -> [DetectedPhotoRegion] {
        find(image, dpi: dpi, options: options).map(\.region)
    }

    /// `detectRegions(in:dpi:options:)`, with what each receipt's edges come from.
    public static func find(_ image: RgbaImage, dpi: Int,
                            options: ReceiptDetectorOptions = ReceiptDetectorOptions()) -> [ReceiptRegion] {
        guard image.width > 0, image.height > 0 else { return [] }
        let gray = GrayImage.from(image, sourceDPI: max(1, dpi))
        let found = find(gray, options: options)
        let scale = gray.scale > 0 ? gray.scale : 1
        let background = Double(DocumentGeometry.backgroundLuminance(gray)) / 255.0
        return found.map { receipt in
            let r = receipt.region
            let coarse = DetectedPhotoRegion(center: CGPoint(x: Double(r.center.x) / scale, y: Double(r.center.y) / scale),
                                             size: CGSize(width: Double(r.size.width) / scale,
                                                          height: Double(r.size.height) / scale),
                                             angleDegrees: r.angleDegrees)
            // Paper edges are snapped at full resolution when that moves no edge far: on a dark lid
            // the snap is exact, on a white one it would wander into the paper and is not taken.
            let region = receipt.basis == .paper
                ? DocumentGeometry.refined(coarse, image: image, background: background,
                                           tolerance: DocumentGeometry.refineTolerance / scale + 2)
                : coarse
            return ReceiptRegion(region: region, basis: receipt.basis)
        }
    }

    /// The receipts on `gray` (a scan's gray copy, normally at `GrayImage.analysisDPI`), in its pixels,
    /// sorted top to bottom, then left to right.
    public static func find(_ gray: GrayImage, options: ReceiptDetectorOptions = ReceiptDetectorOptions()) -> [ReceiptRegion] {
        let w = gray.width, h = gray.height
        guard w >= 16, h >= 16, options.maxReceipts > 0 else { return [] }
        let dpi = gray.dpi > 0 ? gray.dpi : Double(GrayImage.analysisDPI)

        // 1. Marks: what differs from the lid.
        let lid = DocumentGeometry.backgroundLuminance(gray)
        let limit = markContrast * 255
        var mask = [UInt8](repeating: 0, count: w * h)
        for i in 0..<mask.count where Double(abs(Int(gray.pixels[i]) - lid)) > limit {
            mask[i] = 1
        }

        // 2. Blocks: close (letters and lines run together), then open by one pixel (specks go).
        let close = max(2, Int((closeInches * dpi + 0.5).rounded(.down)))
        mask = MaskOps.erode(MaskOps.dilate(mask, w, h, radius: close), w, h, radius: close)
        mask = MaskOps.dilate(MaskOps.erode(mask, w, h, radius: 1), w, h, radius: 1)
        let minBlock = minBlockSquareInches * dpi * dpi
        var blocks: [ReceiptBlock] = []
        for component in MaskOps.connectedComponents(mask: mask, width: w, height: h) where Double(component.area) >= minBlock {
            blocks.append(ReceiptBlock(component))
        }
        guard !blocks.isEmpty else { return [] }
        // The sheet each block lies on, where the paper shows.
        if !options.singleReceipt {
            let papers = paperLabels(gray, dpi: dpi)
            for i in 0..<blocks.count {
                let b = blocks[i]
                blocks[i].paper = papers[(b.minY + b.maxY) / 2 * w + (b.minX + b.maxX) / 2]
            }
        }

        // 3. Receipts: blocks in a column are one receipt; small blocks join the receipt beside them.
        let groups = options.singleReceipt ? [ReceiptBlock.union(blocks)] : group(blocks, dpi: dpi)

        // 4. Each receipt's rectangle, size checked; the largest maxReceipts.
        var candidates: [(group: ReceiptBlock, rect: MinAreaRect, hull: [CGPoint])] = []
        for group in groups {
            let hull = convexHull(group.points)
            let rect = minAreaRect(of: hull)
            guard sized(rect, dpi: dpi) else { continue }
            candidates.append((group, rect, hull))
        }
        candidates.sort { Double($0.rect.size.width * $0.rect.size.height) > Double($1.rect.size.width * $1.rect.size.height) }
        if candidates.count > options.maxReceipts { candidates.removeSubrange(options.maxReceipts...) }

        // 5. Each receipt's edges: its paper when that shows and holds all its print, else its print.
        let receipts = candidates.map { edges(gray, group: $0.group, rect: $0.rect, hull: $0.hull, dpi: dpi) }

        // Two blocks of one receipt (a wide blank gap between them) both find its paper: one region.
        let merged = PhotoDetector.mergingOverlaps(receipts.map(\.region))
        let sorted = PhotoDetector.sortedRowMajor(merged)
        return sorted.map { region in
            if let match = receipts.first(where: { $0.region.id == region.id }) {
                return ReceiptRegion(region: region, basis: match.basis)
            }
            // A region made by merging two holds paper when either did.
            let paper = receipts.contains { $0.basis == .paper && overlaps($0.region, region) }
            return ReceiptRegion(region: region, basis: paper ? .paper : .text)
        }
    }

    /// The receipt's region: its paper, looked for around its print (and further when it is not found
    /// there: the paper may run on), when the paper is found as a sheet that holds all the print; else
    /// the print at the angle of its lines (or of its outline when the lines do not tell), with a margin.
    private static func edges(_ gray: GrayImage, group: ReceiptBlock, rect: MinAreaRect, hull: [CGPoint],
                              dpi: Double) -> ReceiptRegion {
        var first: GrayImage?
        for margin in searchMarginsInches {
            let m = Int((margin * dpi + 0.5).rounded(.down))
            let x0 = max(0, group.minX - m), y0 = max(0, group.minY - m)
            let x1 = min(gray.width, group.maxX + 1 + m), y1 = min(gray.height, group.maxY + 1 + m)
            guard let area = crop(gray, x: x0, y: y0, width: x1 - x0, height: y1 - y0) else { break }
            if first == nil { first = area }
            let search = DocumentGeometry.findPage(area, options: pageSearch)
            if let page = search.page, !search.touchesBorder {
                let paper = DetectedPhotoRegion(center: CGPoint(x: Double(page.center.x) + Double(x0),
                                                                y: Double(page.center.y) + Double(y0)),
                                                size: page.size, angleDegrees: page.angleDegrees)
                if holds(paper, points: hull, tolerance: paperToleranceInches * dpi) {
                    return ReceiptRegion(region: paper, basis: .paper)
                }
            }
            // Not found, or not all of it: the paper may run past the area searched (a blank tail,
            // wide margins), which also leaves paper in the area's outer ring. Look further.
        }

        var angle = rect.angleDegrees
        if let area = first {
            let layout = DocumentGeometry.estimateTextLayout(area)
            if layout.isConfident && abs(layout.skewDegrees) <= DocumentGeometry.maxTextSkewDegrees {
                angle = layout.skewDegrees
            }
        }
        let around = DocumentGeometry.rectAtAngle(hull, angleDegrees: angle)
        let pad = 2 * paddingInches * dpi
        return ReceiptRegion(region: DetectedPhotoRegion(center: around.center,
                                                         size: CGSize(width: Double(around.size.width) + pad,
                                                                      height: Double(around.size.height) + pad),
                                                         angleDegrees: angle),
                             basis: .text)
    }

    /// Whether every point lies inside `region` grown by `tolerance` pixels.
    private static func holds(_ region: DetectedPhotoRegion, points: [CGPoint], tolerance: Double) -> Bool {
        let a = region.angleDegrees * .pi / 180
        let c = cos(a), s = sin(a)
        let hw = Double(region.size.width) / 2 + tolerance, hh = Double(region.size.height) / 2 + tolerance
        let cx = Double(region.center.x), cy = Double(region.center.y)
        for p in points {
            let dx = Double(p.x) - cx, dy = Double(p.y) - cy
            let u = dx * c + dy * s, v = -dx * s + dy * c
            if abs(u) > hw || abs(v) > hh { return false }
        }
        return true
    }

    /// Whether the centers of the two regions lie inside each other's rectangles.
    private static func overlaps(_ a: DetectedPhotoRegion, _ b: DetectedPhotoRegion) -> Bool {
        holds(b, points: [a.center], tolerance: 0) || holds(a, points: [b.center], tolerance: 0)
    }

    /// The sheets of paper that show on `gray` (scanned at `dpi`): a label per pixel (1, 2, … per sheet,
    /// 0 where none shows). What differs from the lid by more than `pageSearch`'s contrast (or the lid's
    /// own spread, on a textured lid), after a 3 × 3 median, opened so print and specks go, in pieces of
    /// at least `minPaperSquareInches`; each piece is labelled row by row from its leftmost to its
    /// rightmost pixel.
    private static func paperLabels(_ gray: GrayImage, dpi: Double) -> [Int] {
        let w = gray.width, h = gray.height
        let smooth = DocumentGeometry.median3x3(gray)
        let ring = DocumentGeometry.ringWidth(w, h, dpi: dpi)
        var histogram = [Int](repeating: 0, count: 256)
        var count = 0
        for y in 0..<h {
            let edgeRow = y < ring || y >= h - ring
            for x in 0..<w {
                if !edgeRow && x >= ring && x < w - ring { continue }
                histogram[Int(smooth[y * w + x])] += 1
                count += 1
            }
        }
        let median = Int(BackgroundMap.percentile(histogram, count: count, fraction: 0.5))
        var deviations = [Int](repeating: 0, count: 256)
        for v in 0..<256 { deviations[abs(v - median)] += histogram[v] }
        let spread = Int(BackgroundMap.percentile(deviations, count: count, fraction: 0.5))
        let limit = max(pageSearch.pageContrast * 255, DocumentGeometry.backdropSpread * Double(spread))
        var mask = [UInt8](repeating: 0, count: w * h)
        for i in 0..<mask.count where Double(abs(Int(smooth[i]) - median)) > limit {
            mask[i] = 1
        }
        let open = max(1, Int((Double(DocumentGeometry.openRadius) * dpi / Double(GrayImage.analysisDPI) + 0.5).rounded(.down)))
        mask = MaskOps.dilate(MaskOps.erode(mask, w, h, radius: open), w, h, radius: open)
        var labels = [Int](repeating: 0, count: w * h)
        let minPaper = minPaperSquareInches * dpi * dpi
        var label = 0
        for component in MaskOps.connectedComponents(mask: mask, width: w, height: h) where Double(component.area) >= minPaper {
            label += 1
            for (y, span) in component.rows {
                for x in span.minX...span.maxX { labels[y * w + x] = label }
            }
        }
        return labels
    }

    /// Whether two groups may be one receipt: not when each lies on a sheet of its own.
    private static func samePaper(_ a: ReceiptBlock, _ b: ReceiptBlock) -> Bool {
        a.paper == 0 || b.paper == 0 || a.paper == b.paper
    }

    /// The part (x, y, width, height) of `gray`; nil when empty.
    private static func crop(_ gray: GrayImage, x: Int, y: Int, width: Int, height: Int) -> GrayImage? {
        guard width > 0, height > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height)
        for row in 0..<height {
            let source = (y + row) * gray.width + x
            pixels.replaceSubrange(row * width..<(row + 1) * width, with: gray.pixels[source..<source + width])
        }
        return GrayImage(width: width, height: height, pixels: pixels, dpi: gray.dpi, scale: gray.scale)
    }

    /// Whether the rectangle is the size of a receipt (`minShortSideInches`, `minLongSideInches`,
    /// `minAreaSquareInches`), measured along its smallest rectangle, so a tilted column of prices is
    /// as narrow as it looks.
    private static func sized(_ rect: MinAreaRect, dpi: Double) -> Bool {
        let width = Double(rect.size.width), height = Double(rect.size.height)
        let shortSide = min(width, height) / dpi, longSide = max(width, height) / dpi
        return shortSide >= minShortSideInches && longSide >= minLongSideInches
            && shortSide * longSide >= minAreaSquareInches
    }

    private static func sized(_ group: ReceiptBlock, dpi: Double) -> Bool {
        sized(minAreaRect(of: convexHull(group.points)), dpi: dpi)
    }

    /// The receipts among `blocks`: blocks one above the other, overlapping across by `columnOverlap`
    /// of the narrower and less than `columnGapInches` apart, joined until nothing changes; then each
    /// group too small to be a receipt joined to the nearest receipt-sized one less than
    /// `columnGapInches` away, or less than `sideGapInches` away beside it with at least half its
    /// height within the receipt's (a column of prices beside the items), or dropped. Groups on
    /// different sheets (`paperLabels`) are never joined; a small group on a sheet joins the nearest
    /// receipt on the same sheet, however far.
    private static func group(_ blocks: [ReceiptBlock], dpi: Double) -> [ReceiptBlock] {
        let gap = columnGapInches * dpi, side = sideGapInches * dpi
        var groups = blocks
        var changed = true
        while changed {
            changed = false
            outer: for i in 0..<groups.count {
                for j in (i + 1)..<groups.count {
                    let a = groups[i], b = groups[j]
                    let overlap = min(a.maxX, b.maxX) - max(a.minX, b.minX) + 1
                    let narrower = min(a.maxX - a.minX + 1, b.maxX - b.minX + 1)
                    let apart = max(a.minY, b.minY) - min(a.maxY, b.maxY) - 1
                    if Double(overlap) < columnOverlap * Double(narrower) || Double(apart) >= gap || !samePaper(a, b) {
                        continue
                    }
                    groups[i] = ReceiptBlock.union([a, b])
                    groups.remove(at: j)
                    changed = true
                    break outer
                }
            }
        }
        var receipts = groups.filter { sized($0, dpi: dpi) }
        for small in groups where !sized(small, dpi: dpi) {
            var best = -1
            var bestDistance = Double.greatestFiniteMagnitude
            let onItsSheet = small.paper != 0 && receipts.contains { $0.paper == small.paper }
            for k in 0..<receipts.count {
                let r = receipts[k]
                if !samePaper(r, small) { continue }
                let dx = max(0, max(r.minX, small.minX) - min(r.maxX, small.maxX) - 1)
                let dy = max(0, max(r.minY, small.minY) - min(r.maxY, small.maxY) - 1)
                let distance = Double(max(dx, dy))
                let alongside = min(r.maxY, small.maxY) - max(r.minY, small.minY) + 1
                let beside = dy == 0 && 2 * alongside >= small.maxY - small.minY + 1 && Double(dx) < side
                let sameSheet = onItsSheet && r.paper == small.paper
                if (sameSheet || (!onItsSheet && (distance < gap || beside))) && distance < bestDistance {
                    best = k
                    bestDistance = distance
                }
            }
            if best >= 0 { receipts[best] = ReceiptBlock.union([receipts[best], small]) }
        }
        return receipts
    }

    /// The receipt cut out of `image` and turned upright; outside the scan is white. nil when the
    /// region is empty.
    public static func extract(_ image: RgbaImage, region: DetectedPhotoRegion) -> RgbaImage? {
        image.extractRotated(center: region.center, size: region.size, angleDegrees: region.angleDegrees)
    }

    /// Cut out, turned upright and made easy to read (`ReceiptEnhancer.enhance`): what is saved of a
    /// receipt. nil when the region is empty.
    public static func extractEnhanced(_ image: RgbaImage, region: DetectedPhotoRegion, dpi: Int) -> RgbaImage? {
        extract(image, region: region).map { ReceiptEnhancer.enhance($0, dpi: dpi) }
    }
}

/// Marks run together: their outline points (pixel corners of each row's ends), their box and the
/// sheet they lie on (`paperLabels`; 0 when no paper shows there).
private struct ReceiptBlock {
    var points: [CGPoint] = []
    var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
    var paper = 0

    init() {}

    init(_ component: MaskComponent) {
        points.reserveCapacity(component.rows.count * 4)
        for (y, span) in component.rows {
            points.append(CGPoint(x: span.minX, y: y))
            points.append(CGPoint(x: span.minX, y: y + 1))
            points.append(CGPoint(x: span.maxX + 1, y: y))
            points.append(CGPoint(x: span.maxX + 1, y: y + 1))
            minX = min(minX, span.minX)
            maxX = max(maxX, span.maxX)
            minY = min(minY, y)
            maxY = max(maxY, y)
        }
    }

    static func union(_ blocks: [ReceiptBlock]) -> ReceiptBlock {
        var union = ReceiptBlock()
        for block in blocks {
            union.points.append(contentsOf: block.points)
            union.minX = min(union.minX, block.minX)
            union.maxX = max(union.maxX, block.maxX)
            union.minY = min(union.minY, block.minY)
            union.maxY = max(union.maxY, block.maxY)
            if union.paper == 0 { union.paper = block.paper }
        }
        return union
    }
}

/// Makes faded thermal print easy to read: gray, the paper evened out to white and the print darkened.
/// Pure arithmetic on the image's gray copy, so both platforms give the same pixels.
/// 1. The paper's brightness across the receipt (`BackgroundMap`): tiles of `tileInches`, the
///    `backgroundPercentile` of each, the brightest of each tile and its neighbors (a tile covered by
///    print still gets the paper around it), never less than `BlankPageDetector.darkAreaDrop` below the
///    middle tile (a dark logo stays dark).
/// 2. Each pixel against the paper there: n = L / max(paper, `minBackground`), at most 1.
/// 3. Stretched: the darkest print (the `blackPercentile` of n, at most `maxBlackPoint`) becomes black
///    and `whitePoint` white, then darkened by the power `gamma`.
/// Twin of C# `ReceiptEnhancer`.
public enum ReceiptEnhancer {
    /// The paper's brightness is measured in tiles of this many inches.
    public static let tileInches = 0.25
    /// A tile's paper is this percentile of its pixels.
    public static let backgroundPercentile = 0.9
    /// The share of the paper's brightness that becomes white.
    public static let whitePoint = 0.90
    /// The share of pixels taken as the darkest print.
    public static let blackPercentile = 0.01
    /// The darkest print is taken as at most this share of the paper's brightness (a receipt with little print).
    public static let maxBlackPoint = 0.6
    /// The power the stretched value is raised to: below 1 lightens, above 1 darkens the print.
    public static let gamma = 1.6
    /// The paper's brightness is taken as at least this (0...1), so dark areas do not blow up.
    public static let minBackground = 0.2
    /// The steps n is counted in.
    public static let levels = 1024

    /// `image` (a receipt, scanned at `dpi`) made easy to read: gray (R = G = B), the same size.
    public static func enhance(_ image: RgbaImage, dpi: Int) -> RgbaImage {
        let gray = GrayImage.luma(image, dpi: Double(max(1, dpi)))
        let w = gray.width, h = gray.height
        let tile = max(4, Int((tileInches * Double(max(1, dpi)) + 0.5).rounded(.down)))
        guard let raw = BackgroundMap.estimate(gray, x: 0, y: 0, width: w, height: h, tileSize: tile,
                                               percentile: backgroundPercentile) else { return image }
        let floor = max(0, Int(raw.medianTile()) - BlankPageDetector.darkAreaDrop)
        let paper = raw.maxSmoothed().clampedBelow(UInt8(floor))

        var levelOf = [Int](repeating: 0, count: w * h)
        var histogram = [Int](repeating: 0, count: levels + 1)
        let minimum = minBackground * 255
        for y in 0..<h {
            for x in 0..<w {
                let b = max(paper.valueAt(x: x, y: y), minimum)
                let n = min(1.0, Double(gray.pixels[y * w + x]) / b)
                let k = Int((n * Double(levels) + 0.5).rounded(.down))
                levelOf[y * w + x] = k
                histogram[k] += 1
            }
        }
        let lo = min(Double(percentile(histogram, count: w * h, fraction: blackPercentile)) / Double(levels), maxBlackPoint)
        let hi = whitePoint
        var lut = [UInt8](repeating: 0, count: levels + 1)
        for k in 0...levels {
            let v = min(1, max(0, (Double(k) / Double(levels) - lo) / (hi - lo)))
            lut[k] = UInt8((pow(v, gamma) * 255 + 0.5).rounded(.down))
        }
        var rgba = [UInt8](repeating: 255, count: w * h * 4)
        for i in 0..<levelOf.count {
            let value = lut[levelOf[i]]
            rgba[i * 4] = value
            rgba[i * 4 + 1] = value
            rgba[i * 4 + 2] = value
        }
        return RgbaImage(width: w, height: h, pixels: rgba)
    }

    /// The smallest level with at least ⌈fraction × count⌉ values at or below it.
    private static func percentile(_ histogram: [Int], count: Int, fraction: Double) -> Int {
        let rank = min(max(Int((fraction * Double(count)).rounded(.up)), 1), max(1, count))
        var seen = 0
        for k in 0..<histogram.count {
            seen += histogram[k]
            if seen >= rank { return k }
        }
        return histogram.count - 1
    }
}

/// Reads the date a receipt was issued from its text (the OCR lines in reading order). Numeric dates
/// (ISO 2026-03-12, 12/03/2026, 03/12/2026, 12.03.2026, 12-03-26), dates with month names in English,
/// Turkish, German, French, Spanish, Italian, Portuguese and Dutch (12 Mar 2026, Mar 12, 2026,
/// 12-MAR-26, 12 Mart 2026, 12. März 2026, 12 de marzo de 2026), and Chinese, Japanese and Korean
/// dates (2026年3月12日). A date must exist and lie between ten years before today and tomorrow, which
/// rules out times, phone numbers, amounts and card expiry dates. The first date on a line that says
/// "date" (Date, Datum, Tarih, Fecha, Data…) wins; else the first date in reading order, leaving out
/// lines about validity (Exp, Valid until, Son kullanma…). Twin of C# `ReceiptDateExtractor`.
public enum ReceiptDateExtractor {
    /// A date at most this many years before today counts.
    public static let maxAgeYears = 10

    /// Month names and their usual abbreviations, folded (lower case, no accents), with their month.
    public static let monthNames: [String: Int] = {
        let months: [[String]] = [
            ["jan", "january", "januar", "janvier", "janv", "enero", "ene", "gennaio", "gen", "janeiro", "januari", "ocak", "oca"],
            ["feb", "february", "februar", "fevrier", "fev", "fevr", "febrero", "febbraio", "fevereiro", "februari", "subat", "sub"],
            ["mar", "march", "marz", "maerz", "mars", "marzo", "marco", "maart", "mrt", "mart"],
            ["apr", "april", "avril", "avr", "abril", "abr", "aprile", "nisan", "nis"],
            ["may", "mai", "mayo", "maggio", "mag", "maio", "mei", "mayis"],
            ["jun", "june", "juni", "juin", "junio", "giugno", "giu", "junho", "haziran", "haz"],
            ["jul", "july", "juli", "juillet", "juil", "julio", "luglio", "lug", "julho", "temmuz", "tem"],
            ["aug", "august", "aout", "agosto", "ago", "augustus", "agustos", "agu"],
            ["sep", "sept", "september", "septembre", "septiembre", "settembre", "set", "setembro", "eylul", "eyl"],
            ["oct", "october", "oktober", "okt", "octobre", "octubre", "ottobre", "ott", "outubro", "out", "ekim", "eki"],
            ["nov", "november", "novembre", "noviembre", "novembro", "kasim", "kas"],
            ["dec", "december", "dezember", "dez", "decembre", "diciembre", "dicembre", "dezembro", "aralik", "ara"],
        ]
        var names: [String: Int] = [:]
        for (index, list) in months.enumerated() {
            for name in list { names[name] = index + 1 }
        }
        return names
    }()

    /// The month names as a pattern's alternatives, longest first ("septiembre|...|mar|..."): the patterns
    /// that read a month name take only these, so a word that is not a month ("4 sat 18 apr 2026") never
    /// makes a match that hides the date after it.
    static let monthAlternation: String = monthNames.keys
        .sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }
        .joined(separator: "|")

    /// Words of a line that gives the receipt's date (folded).
    public static let dateWords = ["date", "datum", "tarih", "tarihi", "fecha", "data", "dated", "issued"]

    /// Words of a line about something else's date: expiry, validity, returns (folded).
    public static let otherDateWords = ["exp", "expiry", "expires", "expiration", "valid", "until", "gultig", "gecerli",
                                        "gecerlilik", "son kullanma", "skt", "best before", "use by", "return by", "retour"]

    // ISO: 2026-03-12, 2026/3/5, 2026.03.12 (the same separator twice).
    private static let isoPattern = pattern(#"(?<![0-9])((?:19|20)[0-9]{2})([-./]) ?([0-9]{1,2})\2 ?([0-9]{1,2})(?![0-9])(?![.,][0-9])"#)
    // Day and month as numbers: 12/03/2026, 12.03.26, 1-5-2026.
    private static let numericPattern = pattern(#"(?<![0-9])(?<![0-9][-./])([0-9]{1,2})([-./]) ?([0-9]{1,2})\2 ?([0-9]{4}|[0-9]{2})(?![0-9])(?![.,][0-9])"#)
    // Day, month name, year: 12 Mar 2026, 12-MAR-26, 12. marz 2026, 1st january 2026, 12 de marzo de 2026.
    private static let dayNamePattern = pattern(#"(?<![0-9])([0-9]{1,2})(?:st|nd|rd|th)?\.?[-./ ]{0,2}(?:de )?("#
        + monthAlternation + #")\.?,?[-./ ]{0,2}(?:de )?((?:19|20)?[0-9]{2})(?![0-9])(?![.,][0-9])"#)
    // Month name, day, year: Mar 12, 2026, march 12th 2026, dec. 3 2025 (four-digit year only).
    private static let nameDayPattern = pattern(#"(?<![a-z])("# + monthAlternation
        + #")\.? ?([0-9]{1,2})(?:st|nd|rd|th)?,? ?((?:19|20)[0-9]{2})(?![0-9])(?![.,][0-9])"#)
    // Chinese, Japanese, Korean: 2026年3月12日, 2026년 3월 12일.
    private static let cjkPattern = pattern(#"((?:19|20)[0-9]{2}) ?[年년] ?([0-9]{1,2}) ?[月월] ?([0-9]{1,2})(?![0-9])"#)

    private static func pattern(_ source: String) -> NSRegularExpression {
        // The patterns are constants: a failure here is a programming error the tests catch.
        try! NSRegularExpression(pattern: source, options: [])
    }

    /// The receipt's date in `lines` (its text in reading order); nil when none is found. `today` bounds
    /// the dates that count; `preferDayFirst` reads 03/04/2026 as 3 April (else as 4 March) when nothing
    /// else tells: a part above 12 is the day, and dots (03.04.2026) always put the day first.
    public static func findDate(_ lines: [String], today: DocumentDate, preferDayFirst: Bool) -> DocumentDate? {
        let earliest = today.addingYears(-maxAgeYears)
        let latest = today.dayNumber + 1
        var first: DocumentDate?
        for line in lines {
            let folded = fold(line)
            let other = otherDateWords.contains { containsWord(folded, $0) }
            guard let candidate = datesIn(folded, preferDayFirst: preferDayFirst)
                .first(where: { $0 >= earliest && $0.dayNumber <= latest }) else { continue }
            if dateWords.contains(where: { containsWord(folded, $0) }) && !other { return candidate }
            if !other && first == nil { first = candidate }
        }
        return first
    }

    /// The dates written on one folded line (`fold`), in the order they appear; the calendar check is
    /// done, the range check is not.
    static func datesIn(_ folded: String, preferDayFirst: Bool) -> [DocumentDate] {
        var found: [(index: Int, order: Int, date: DocumentDate)] = []
        let whole = NSRange(folded.startIndex..<folded.endIndex, in: folded)
        func group(_ match: NSTextCheckingResult, _ n: Int) -> String {
            guard let range = Range(match.range(at: n), in: folded) else { return "" }
            return String(folded[range])
        }
        func add(_ match: NSTextCheckingResult, year: Int, month: Int, day: Int) {
            if let date = DocumentDate.make(year: year, month: month, day: day) {
                found.append((match.range.location, found.count, date))
            }
        }
        for m in isoPattern.matches(in: folded, options: [], range: whole) {
            add(m, year: number(group(m, 1)), month: number(group(m, 3)), day: number(group(m, 4)))
        }
        for m in cjkPattern.matches(in: folded, options: [], range: whole) {
            add(m, year: number(group(m, 1)), month: number(group(m, 2)), day: number(group(m, 3)))
        }
        for m in numericPattern.matches(in: folded, options: [], range: whole) {
            let a = number(group(m, 1)), b = number(group(m, 3))
            let year = yearOf(group(m, 4))
            let dayFirst = a > 12 ? true : b > 12 ? false : (group(m, 2) == "." || preferDayFirst)
            add(m, year: year, month: dayFirst ? b : a, day: dayFirst ? a : b)
        }
        for m in dayNamePattern.matches(in: folded, options: [], range: whole) {
            if let month = monthNames[group(m, 2)] {
                add(m, year: yearOf(group(m, 3)), month: month, day: number(group(m, 1)))
            }
        }
        for m in nameDayPattern.matches(in: folded, options: [], range: whole) {
            if let month = monthNames[group(m, 1)] {
                add(m, year: number(group(m, 3)), month: month, day: number(group(m, 2)))
            }
        }
        // In the order they appear; at one place, the patterns' order.
        return found.sorted { ($0.index, $0.order) < ($1.index, $1.order) }.map(\.date)
    }

    private static func number(_ digits: String) -> Int { Int(digits) ?? 0 }

    /// A four-digit year as written; a two-digit one in this century.
    private static func yearOf(_ digits: String) -> Int { digits.count == 2 ? 2000 + number(digits) : number(digits) }

    /// Whether `word` stands in `folded` with no letter right before or after it.
    private static func containsWord(_ folded: String, _ word: String) -> Bool {
        let text = Array(folded.utf16), needle = Array(word.utf16)
        guard !needle.isEmpty, text.count >= needle.count else { return false }
        func isLetter(_ unit: UInt16) -> Bool { unit >= 97 && unit <= 122 }
        for at in 0...(text.count - needle.count) where Array(text[at..<at + needle.count]) == needle {
            let before = at == 0 || !isLetter(text[at - 1])
            let end = at + needle.count
            let after = end == text.count || !isLetter(text[end])
            if before && after { return true }
        }
        return false
    }

    /// The line as the patterns read it: A–Z in lower case, the letters with accents and the Turkish
    /// letters without them (Ş → s, ı and İ → i, ğ → g), combining accents dropped, every kind of space
    /// a plain space; everything else as it is.
    public static func fold(_ line: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in line.unicodeScalars {
            let value = scalar.value
            if value >= 65 && value <= 90 {
                scalars.append(Unicode.Scalar(value + 32)!)
            } else if value >= 0x300 && value <= 0x36F {
                continue
            } else if value == 9 || value == 0xA0 || value == 0x2007 || value == 0x202F || value == 0x3000 {
                scalars.append(" ")
            } else if let folded = foldedLetters[Character(scalar)] {
                scalars.append(folded)
            } else {
                scalars.append(scalar)
            }
        }
        return String(scalars)
    }

    private static let foldedLetters: [Character: Unicode.Scalar] = {
        var table: [Character: Unicode.Scalar] = [:]
        let groups: [(String, Unicode.Scalar)] = [
            ("áàâäãåÁÀÂÄÃÅ", "a"), ("çÇ", "c"), ("éèêëÉÈÊË", "e"), ("ğĞ", "g"),
            ("íìîïıÍÌÎÏİ", "i"), ("ñÑ", "n"), ("óòôöõÓÒÔÖÕ", "o"), ("şŞ", "s"), ("úùûüÚÙÛÜ", "u"),
        ]
        for (letters, plain) in groups {
            for letter in letters { table[letter] = plain }
        }
        return table
    }()

    /// Whether a short date pattern (the pattern the formatter gives for day, month and year, or
    /// .NET's ShortDatePattern) puts the day before the month: "dd.MM.yyyy" and "d/M/yyyy" do, "M/d/yyyy"
    /// and "yyyy-MM-dd" do not.
    public static func prefersDayFirst(_ shortDatePattern: String) -> Bool {
        guard let day = shortDatePattern.firstIndex(of: "d") else { return false }
        guard let month = shortDatePattern.firstIndex(of: "M") else { return true }
        return day < month
    }

    /// Whether the user's region writes the day first: its pattern for day, month and year.
    public static func prefersDayFirst(locale: Locale = .current) -> Bool {
        prefersDayFirst(DateFormatter.dateFormat(fromTemplate: "ddMMyyyy", options: 0, locale: locale) ?? "")
    }
}

/// What the Receipts task shows and saves: titles, the date a file is named by, messages. Twin of C#
/// `Receipts`.
public enum Receipts {
    /// "Found 4 receipts", "Found 1 receipt".
    public static func reviewTitle(_ found: Int) -> String {
        "Found \(found) receipt\(found == 1 ? "" : "s")"
    }

    /// The review's save button: "Save 3 Receipts", "Save 1 Receipt"; "Save as One PDF" when the
    /// receipts go into one PDF (`TaskOptions.receiptCombine`, several kept).
    public static func saveTitle(included: Int, combine: Bool, format: OutputFormat) -> String {
        combines(combine, format: format, count: included)
            ? "Save as One PDF"
            : "Save \(included) Receipt\(included == 1 ? "" : "s")"
    }

    /// The receipts go into one PDF: asked for, saved as PDF, and more than one.
    public static func combines(_ combine: Bool, format: OutputFormat, count: Int) -> Bool {
        combine && format.pageFormat == .pdf && count > 1
    }

    /// Whether the files are named by the date printed on each receipt: asked for
    /// (`TaskOptions.receiptNameByDate`) and the naming template has {docdate}, the only place the date goes.
    public static func namesByDate(_ settings: ScanSettings) -> Bool {
        settings.taskOptions.receiptNameByDate && settings.namingTemplate.contains("{docdate}")
    }

    /// Whether saving reads the receipts' text with OCR: for their date (`namesByDate`), a searchable PDF,
    /// or the text beside it.
    public static func readsText(_ settings: ScanSettings) -> Bool {
        namesByDate(settings)
            || (settings.format.pageFormat == .pdf && (settings.pdfSearchable || settings.output.alsoSaveText))
    }

    /// The text of a receipt as the date is looked for in it: the OCR lines in reading order, on a
    /// receipt `pixelWidth` × `pixelHeight` pixels.
    public static func textLines(_ lines: [OCRLine], pixelWidth: Int, pixelHeight: Int) -> [String] {
        OCRText.readingOrder(lines, pageWidth: Double(max(1, pixelWidth)), pageHeight: Double(max(1, pixelHeight)))
            .map(\.text)
    }

    /// The date one PDF of several receipts is named by: the earliest found; nil when none was.
    public static func combinedDate(_ dates: [DocumentDate?]) -> DocumentDate? {
        dates.compactMap { $0 }.min()
    }

    /// After saving: "Saved 3 receipts: a.pdf, b.pdf, c.pdf", "Saved 3 receipts in one PDF: a.pdf", with
    /// ". No date was found on 1 of them; it is named by today's date." when receipts were to be named by
    /// their date (`undated` of them were not). One PDF is named by the earliest date found, so it gets the
    /// note only when no receipt had a date.
    public static func savedMessage(count: Int, fileNames: [String], combined: Bool, undated: Int) -> String {
        let what = "\(count) receipt\(count == 1 ? "" : "s")"
        let saved = combined
            ? "Saved \(what) in one PDF: \(fileNames.first ?? "")"
            : "Saved \(what): \(fileNames.joined(separator: ", "))"
        guard undated > 0, !(combined && undated < count) else { return saved }
        let note: String
        if combined {
            note = "No date was found on them; the PDF is named by today's date."
        } else if count == 1 {
            note = "No date was found on it; it is named by today's date."
        } else if undated == count {
            note = "No date was found on them; they are named by today's date."
        } else {
            note = "No date was found on \(undated) of them; \(undated == 1 ? "it is" : "they are") named by today's date."
        }
        return "\(saved). \(note)"
    }
}
