import CoreGraphics
import Foundation

// Twin of windows/CompleteScanner.Core/DocumentGeometry.cs: same constants, same steps.

/// Which way the lines of text on a page run (`DocumentGeometry.estimateTextLayout`).
public enum TextAxis: Sendable {
    /// Not enough text, or no clear direction.
    case unknown
    /// Lines run across the page, as on an upright or upside-down page.
    case horizontal
    /// Lines run down the page: the page lies on its side.
    case vertical
}

/// What the lines of text on a page say about how it lies. Twin of C# `TextLayout`.
public struct TextLayout: Equatable, Sendable {
    /// Which way the lines run.
    public let axis: TextAxis
    /// How far the lines are turned, clockwise on screen positive (the `DetectedPhotoRegion`
    /// convention): turning the page back by this much straightens them.
    public let skewDegrees: Double
    /// How much the best angle stands out from the others ((best − mean) / mean of the sweep).
    public let confidence: Double
    /// The ink pixels measured.
    public let inkPoints: Int

    public init(axis: TextAxis, skewDegrees: Double, confidence: Double, inkPoints: Int) {
        self.axis = axis
        self.skewDegrees = skewDegrees
        self.confidence = confidence
        self.inkPoints = inkPoints
    }

    /// Clear enough to straighten the page by: a direction, enough ink, a clear best angle.
    public var isConfident: Bool {
        axis != .unknown
            && inkPoints >= DocumentGeometry.minInkPoints
            && confidence >= DocumentGeometry.minConfidence
    }

    public static let nothing = TextLayout(axis: .unknown, skewDegrees: 0, confidence: 0, inkPoints: 0)
}

/// What told the page's angle.
public enum GeometryBasis: Sendable {
    /// The edges of the sheet against the scanner's background.
    case pageEdges
    /// The lines of text on the page.
    case textLines
}

/// How a page is changed (`GeometryPlan`).
public enum GeometryAction: Sendable {
    /// The sheet is cut out and turned upright.
    case cropStraightened
    /// The sheet is cut out along the rectangle around it, not turned.
    case cropBox
    /// The whole scan is turned about its center, on a canvas big enough to lose nothing.
    case rotate
}

/// What crop and straighten did to a page, for the page strip and for undoing it. Not stored in
/// settings files. Twin of C# `PageGeometry`.
public struct PageGeometry: Equatable, Sendable {
    /// The page was cut out of the scanner's background.
    public let cropped: Bool
    /// The turn taken out, clockwise positive; 0 when the page was not turned.
    public let angleDegrees: Double
    /// What the angle (or the crop) was found from.
    public let basis: GeometryBasis

    public init(cropped: Bool, angleDegrees: Double, basis: GeometryBasis) {
        self.cropped = cropped
        self.angleDegrees = angleDegrees
        self.basis = basis
    }

    /// The page was turned.
    public var straightened: Bool { angleDegrees != 0 }

    /// "Cropped and straightened 2.4°", "Straightened 1.5°" or "Cropped".
    public var caption: String {
        let angle = DocumentGeometry.angleText(angleDegrees)
        if cropped && straightened { return "Cropped and straightened \(angle)" }
        return straightened ? "Straightened \(angle)" : "Cropped"
    }
}

/// What crop and straighten would do to a page, worked out on its analysis image. Twin of C#
/// `GeometryPlan`.
public struct GeometryPlan {
    /// How the page is changed.
    public let action: GeometryAction
    /// The turn taken out (0 for `.cropBox`).
    public let angleDegrees: Double
    /// What the angle or the crop comes from.
    public let basis: GeometryBasis
    /// The sheet found, in analysis pixels; nil when the angle comes from the text alone.
    public let page: DetectedPhotoRegion?
    /// `.rotate` only: the size of the turned scan in analysis pixels, the scan's own size unless
    /// turning it in place would cut off something in its corners.
    public let canvas: CGSize
    /// The text measurement, when one was made.
    public let text: TextLayout?

    /// The facts the page carries once the plan is carried out.
    public var geometry: PageGeometry {
        PageGeometry(cropped: action != .rotate, angleDegrees: angleDegrees, basis: basis)
    }
}

/// A page cropped or straightened (`DocumentGeometry.correct`). Twin of C# `GeometryCorrection`.
public struct GeometryCorrection {
    /// The new pixels.
    public let image: RgbaImage
    /// What was done.
    public let geometry: PageGeometry
    /// The plan carried out, in analysis pixels.
    public let plan: GeometryPlan
    /// The area of the scan taken, in its pixels (for a box crop: the sheet before boxing).
    public let region: DetectedPhotoRegion
}

/// Why no sheet was taken (`DocumentGeometry.findPage`).
public enum PageRejection: Sendable {
    /// A sheet was found.
    case none
    /// Nothing stands out from the background.
    case nothingFound
    /// What stands out is smaller than `DocumentGeometry.minPageAreaFraction` of the scan.
    case tooSmall
    /// It covers more than `DocumentGeometry.maxPageAreaFraction` of the scan: nothing to crop.
    case fillsScan
    /// It does not fill its rectangle, or is too long and thin, to be a sheet.
    case notRectangular
    /// Text-like marks lie around it: it is something on a page, not the page.
    case textAround
    /// Something else of some size lies beside it (another sheet, a photo): cropping would drop it.
    case otherObjects
}

/// The limits a sheet is held to when it is looked for (`DocumentGeometry.findPage(_:options:)`):
/// `.default` is `DocumentGeometry`'s own constants, for pages of any kind. A task that knows its
/// paper can ask for other limits: receipts (`ReceiptDetector.pageSearch`) are thermal paper barely
/// darker than the lid, often curled, and up to many times as long as wide. Twin of C#
/// `PageSearchOptions`.
public struct PageSearchOptions: Equatable, Sendable {
    /// A pixel belongs to something on the glass when it differs from the background by more than this (0...1).
    public var pageContrast: Double = DocumentGeometry.pageContrast
    /// The sheet covers at least this share of the scan.
    public var minPageAreaFraction: Double = DocumentGeometry.minPageAreaFraction
    /// The sheet covers at most this share of the scan.
    public var maxPageAreaFraction: Double = DocumentGeometry.maxPageAreaFraction
    /// The sheet fills at least this share of the rectangle around it.
    public var minPageFill: Double = DocumentGeometry.minPageFill
    /// The sheet's long side is at most this many times its short side.
    public var maxPageAspect: Double = DocumentGeometry.maxPageAspect

    public init() {}

    /// The limits for pages of any kind: `DocumentGeometry`'s constants.
    public static let `default` = PageSearchOptions()
}

/// What the search for the sheet found. Twin of C# `PageSearch`.
public struct PageSearch {
    /// The sheet, or nil.
    public let page: DetectedPhotoRegion?
    /// Why there is none.
    public let rejection: PageRejection
    /// The largest region's rectangle, taken or not.
    public let candidate: DetectedPhotoRegion?
    /// Its share of the scan.
    public let areaFraction: Double
    /// How much of its rectangle the region fills.
    public let fill: Double
    /// Text-like marks found around it (counted only for a candidate of the right size and shape).
    public let outsideMarks: Int
    /// More than `DocumentGeometry.maxBorderContact` of the region's outline is the scan's edge, so
    /// its edges do not tell its angle.
    public let touchesBorder: Bool
    /// The region's convex hull, in analysis pixels (empty when nothing was found).
    public let hull: [CGPoint]

    public static let nothing = PageSearch(page: nil, rejection: .nothingFound, candidate: nil, areaFraction: 0,
                                           fill: 0, outsideMarks: 0, touchesBorder: false, hull: [])
}

/// Crop to the page and straighten it. Works on the page's gray copy at the analysis resolution
/// (`GrayImage.analysisDPI`), so the pixel constants below are 100 dpi sizes, and changes the
/// full-resolution pixels once, at the end. Cautious by design: whenever the page edges or the text
/// are unclear the page is left as scanned, a crop never cuts into the sheet, and turning a page
/// never cuts off anything in its corners.
/// - Page edges (`detectPage`): the scanner's background is the median of the image's outer ring;
///   what differs from it is the sheet, its edge shadow, or something else lying on the glass. The
///   largest such region, closed and with its holes filled (a white sheet on a white lid shows only
///   by its shadow), is the sheet when it is a filled rectangle of a sensible size and nothing that
///   looks like more of a document, or another sheet or photo, lies outside it.
/// - Text lines (`estimateTextLayout`): projection profiles of the ink, swept over
///   ±`maxTextSkewDegrees`: the lines of text line up, and the profile is sharpest, at the angle the
///   page is turned.
/// When a sheet is found its edges give the angle; otherwise the text does. Twin of C#
/// `DocumentGeometry`.
public enum DocumentGeometry {
    // MARK: Page edges

    /// The outer ring of the scan whose median is the scanner's background, as a share of its short side…
    public static let borderRingFraction = 0.02
    /// …and at most this many inches: the backdrop around a sheet in a feeder or an archive scan can be thin.
    public static let borderRingInches = 0.03
    /// The outermost band of the scan, in inches, that a turn in place may cut off whatever it
    /// holds: scanners darken or lighten the very edge of the glass.
    public static let scanEdgeInches = 0.02
    /// A pixel belongs to something on the glass when it differs from the background by more than this (0...1).
    public static let pageContrast = 0.045
    /// On a textured backdrop a pixel must differ from it by this many times the backdrop's median absolute deviation.
    public static let backdropSpread = 3.7
    /// Gaps up to twice this many pixels in the sheet's outline are closed.
    public static let closeRadius = 3
    /// Strands thinner than about twice this many pixels (a thread, a ruler's edge) are cut from the sheet.
    public static let openRadius = 2
    /// The sheet covers at least this share of the scan…
    public static let minPageAreaFraction = 0.15
    /// …and at most this share: a sheet filling the scan has nothing to crop.
    public static let maxPageAreaFraction = 0.99
    /// A sheet with more than this share of its outline on the scan's edge has edges that are the
    /// scan's, not its own: its angle comes from the text.
    public static let maxBorderContact = 0.1
    /// The sheet fills at least this share of the rectangle around it.
    public static let minPageFill = 0.9
    /// The sheet's long side is at most this many times its short side.
    public static let maxPageAspect = 5.0
    /// Marks larger than this many pixels outside the sheet count as text there.
    public static let minOutsideMarkPixels = 6
    /// More text-like marks than this outside the sheet mean it is not the sheet but something on
    /// it (a photo on a page that fills the scan): nothing is cropped.
    public static let maxOutsideMarks = 8
    /// Anything outside the sheet as large as this share of it is another sheet or photo on the
    /// glass, not dust or a ruler's tick: nothing is cropped.
    public static let maxOutsideObjectFraction = 0.02

    // MARK: Text lines

    /// A pixel is ink when darker than (1 − this) of the paper around it.
    public static let inkContrast = 0.30
    /// Marks taller and wider than this many pixels (pictures, stamps, logos) are left out of the text.
    public static let maxGlyphSide = 60
    /// Marks smaller than this many pixels are dust.
    public static let minGlyphPixels = 3
    /// At most this many ink pixels are measured (evenly picked).
    public static let maxInkPoints = 150_000
    /// Fewer ink pixels than this are not enough text to tell.
    public static let minInkPoints = 2000
    /// The text skew searched: ±this many degrees.
    public static let maxTextSkewDegrees = 7.0
    public static let coarseStepDegrees = 0.5
    public static let fineStepDegrees = 0.05
    /// The best angle stands out from the sweep by at least this ((best − mean) / mean).
    public static let minConfidence = 0.15
    /// One direction of the lines is clear when its profile is this much sharper than the other's.
    public static let axisMargin = 1.25

    // MARK: Corrections

    /// Turns smaller than this are left alone: invisible, and not worth resampling the page.
    public static let minCorrectionDegrees = 0.2
    /// A sheet lying at more than this angle is cropped without being turned.
    public static let maxPageAngleDegrees = 15.0
    /// Content pixels a turn in place may cut off (dust); more and the canvas grows instead.
    public static let maxLostContentPixels = 4
    /// The full-resolution snap of the sheet's edges may move an edge by up to this many analysis pixels.
    public static let refineTolerance = 4.0
    /// The band along each cut edge searched for the sheet's shadow or the backdrop, in inches.
    public static let edgeTrimInches = 0.04
    /// A line along a cut edge darker than the paper inside by more than this (0...1) is shadow or backdrop.
    public static let edgeTrimDrop = 0.03

    /// "2.4°": the size of a turn, one decimal (halves rounded up).
    public static func angleText(_ degrees: Double) -> String {
        String(format: "%.1f°", (abs(degrees) * 10).rounded() / 10)
    }

    // MARK: - Correct

    /// `image`, scanned at `dpi`, cropped to the sheet (`crop`) and straightened (`straighten`); nil
    /// when the page stays as it is (nothing asked, nothing found, or not sure).
    public static func correct(_ image: RgbaImage, dpi: Int, crop: Bool, straighten: Bool) -> GeometryCorrection? {
        guard crop || straighten else { return nil }
        let gray = GrayImage.from(image, sourceDPI: dpi)
        guard let plan = Self.plan(gray, crop: crop, straighten: straighten) else { return nil }
        let scale = gray.scale > 0 ? gray.scale : 1
        let fill = borderColor(image, dpi: dpi)
        switch plan.action {
        case .rotate:
            let region = DetectedPhotoRegion(
                center: CGPoint(x: Double(image.width) / 2, y: Double(image.height) / 2),
                size: CGSize(width: max(Double(image.width), (Double(plan.canvas.width) / scale).rounded(.up)),
                             height: max(Double(image.height), (Double(plan.canvas.height) / scale).rounded(.up))),
                angleDegrees: plan.angleDegrees)
            guard let turned = image.extractRotated(center: region.center, size: region.size, angleDegrees: region.angleDegrees,
                                                    fillR: fill.r, fillG: fill.g, fillB: fill.b) else { return nil }
            return GeometryCorrection(image: turned, geometry: plan.geometry, plan: plan, region: region)
        case .cropStraightened, .cropBox:
            guard let page = plan.page else { return nil }
            let coarse = DetectedPhotoRegion(
                center: CGPoint(x: Double(page.center.x) / scale, y: Double(page.center.y) / scale),
                size: CGSize(width: Double(page.size.width) / scale, height: Double(page.size.height) / scale),
                angleDegrees: page.angleDegrees)
            let background = Double(backgroundLuminance(gray)) / 255
            var region = refined(coarse, image: image, background: background, tolerance: refineTolerance / scale + 2)
            let upright = plan.action == .cropStraightened || abs(region.angleDegrees) < minCorrectionDegrees
            let cutOrNil: RgbaImage? = plan.action == .cropStraightened
                ? image.extractRotated(center: region.center, size: region.size, angleDegrees: region.angleDegrees,
                                       fillR: fill.r, fillG: fill.g, fillB: fill.b)
                : image.cropped(region.boundingBox)
            guard var cut = cutOrNil else { return nil }
            // The sheet's edges lie along the cut: trim the shadow or backdrop left along them.
            if upright {
                let insets = edgeInsets(cut, dpi: dpi)
                if insets.left + insets.top + insets.right + insets.bottom > 0,
                   let trimmed = cut.cropped(CGRect(x: insets.left, y: insets.top,
                                                    width: cut.width - insets.left - insets.right,
                                                    height: cut.height - insets.top - insets.bottom)) {
                    cut = trimmed
                    let a = region.angleDegrees * .pi / 180
                    let du = Double(insets.left - insets.right) / 2, dv = Double(insets.top - insets.bottom) / 2
                    region = DetectedPhotoRegion(
                        center: CGPoint(x: Double(region.center.x) + du * cos(a) - dv * sin(a),
                                        y: Double(region.center.y) + du * sin(a) + dv * cos(a)),
                        size: CGSize(width: Double(region.size.width) - Double(insets.left + insets.right),
                                     height: Double(region.size.height) - Double(insets.top + insets.bottom)),
                        angleDegrees: region.angleDegrees)
                }
            }
            return GeometryCorrection(image: cut, geometry: plan.geometry, plan: plan, region: region)
        }
    }

    /// What to do with the page whose analysis image is `gray`; nil to leave it. A sheet found on
    /// the background is cropped (turned upright when asked and it lies at up to
    /// `maxPageAngleDegrees`, else cut out along its box), or, without cropping, the scan is turned
    /// by the sheet's angle. A sheet that runs off the scan has an edge that is the scan's own, so
    /// its angle comes from the text, and its crop is the smallest rectangle at that angle around
    /// it. Without a sheet the text lines give the angle.
    public static func plan(_ gray: GrayImage, crop: Bool, straighten: Bool) -> GeometryPlan? {
        guard crop || straighten else { return nil }
        let search = findPage(gray)
        var text: TextLayout?
        func textSkew() -> Double? {
            let layout = text ?? estimateTextLayout(gray)
            text = layout
            guard layout.isConfident else { return nil }
            let skew = layout.skewDegrees
            return abs(skew) < minCorrectionDegrees || abs(skew) > maxTextSkewDegrees ? nil : skew
        }
        if let page = search.page {
            var angle = page.angleDegrees
            var basis = GeometryBasis.pageEdges
            var region = page
            if search.touchesBorder {
                angle = 0
                if straighten, let skew = textSkew() {
                    angle = skew
                    basis = .textLines
                    region = rectAtAngle(search.hull, angleDegrees: skew)
                }
            }
            let turn = straighten && abs(angle) <= maxPageAngleDegrees && abs(angle) >= minCorrectionDegrees
            if crop {
                if turn {
                    return GeometryPlan(action: .cropStraightened, angleDegrees: angle, basis: basis, page: region,
                                        canvas: region.size, text: text)
                }
                let box = region.boundingBox
                return GeometryPlan(action: .cropBox, angleDegrees: 0, basis: .pageEdges, page: region,
                                    canvas: CGSize(width: box.width, height: box.height), text: text)
            }
            // The sheet's edges say how it lies: straight already, or too far turned to be sure.
            guard turn else { return nil }
            return GeometryPlan(action: .rotate, angleDegrees: angle, basis: basis, page: region,
                                canvas: safeCanvas(gray, angleDegrees: angle), text: text)
        }
        guard straighten, let skew = textSkew() else { return nil }
        return GeometryPlan(action: .rotate, angleDegrees: skew, basis: .textLines, page: nil,
                            canvas: safeCanvas(gray, angleDegrees: skew), text: text)
    }

    /// The smallest rectangle at `angleDegrees` around `points`.
    public static func rectAtAngle(_ points: [CGPoint], angleDegrees: Double) -> DetectedPhotoRegion {
        let a = angleDegrees * .pi / 180
        let c = cos(a), s = sin(a)
        var minU = Double.greatestFiniteMagnitude, maxU = -Double.greatestFiniteMagnitude
        var minV = Double.greatestFiniteMagnitude, maxV = -Double.greatestFiniteMagnitude
        for p in points {
            let px = Double(p.x), py = Double(p.y)
            let u = px * c + py * s, v = -px * s + py * c
            minU = min(minU, u); maxU = max(maxU, u)
            minV = min(minV, v); maxV = max(maxV, v)
        }
        guard minU <= maxU else {
            return DetectedPhotoRegion(center: .zero, size: .zero, angleDegrees: angleDegrees)
        }
        let cu = (minU + maxU) / 2, cv = (minV + maxV) / 2
        return DetectedPhotoRegion(center: CGPoint(x: cu * c - cv * s, y: cu * s + cv * c),
                                   size: CGSize(width: maxU - minU, height: maxV - minV),
                                   angleDegrees: angleDegrees)
    }

    // MARK: - Page edges

    /// The sheet lying on the scanner's background, in `gray`'s pixels; nil when there is no clear
    /// sheet: it fills the scan, is too small or not rectangular, or the area around it holds more
    /// text than a background would, or another sheet or photo (`findPage` says which).
    public static func detectPage(_ gray: GrayImage) -> DetectedPhotoRegion? {
        findPage(gray).page
    }

    /// The search for the sheet (`detectPage`), with what was found and why it was turned down.
    public static func findPage(_ gray: GrayImage) -> PageSearch {
        findPage(gray, options: .default)
    }

    /// The search for the sheet held to `options` instead of the constants (`PageSearchOptions.default`
    /// gives the same result as `findPage(_:)`).
    public static func findPage(_ gray: GrayImage, options: PageSearchOptions) -> PageSearch {
        let w = gray.width, h = gray.height
        guard w >= 16, h >= 16 else { return .nothing }
        let k = (gray.dpi > 0 ? gray.dpi : Double(GrayImage.analysisDPI)) / Double(GrayImage.analysisDPI)

        // 1. The background: the median of the outer ring. 2. What differs from it, after a 3 × 3
        //    median (sensor noise and dust go).
        let smooth = median3x3(gray)
        let backdrop = backdropOf(smooth, w, h, dpi: gray.dpi, contrast: options.pageContrast)
        let content = contentMask(smooth, background: backdrop.median, limit: backdrop.limit)

        // 3. Close the outline (outside the scan counts as set, so a sheet against the glass's
        //    edge keeps its edge), fill what the background cannot reach from the border (the
        //    sheet inside its shadow), then cut thin strands.
        let closeBy = max(1, Int((Double(closeRadius) * k + 0.5).rounded(.down)))
        let openBy = max(1, Int((Double(openRadius) * k + 0.5).rounded(.down)))
        var mask = MaskOps.erode(MaskOps.dilate(content, w, h, radius: closeBy), w, h, radius: closeBy, outsideSet: true)
        mask = fillHoles(mask, w, h)
        mask = MaskOps.dilate(MaskOps.erode(mask, w, h, radius: openBy, outsideSet: true), w, h, radius: openBy)

        // 4. The largest region and the smallest rectangle around it.
        var largestOrNil: MaskComponent?
        for component in MaskOps.connectedComponents(mask: mask, width: w, height: h) {
            if largestOrNil == nil || component.area > largestOrNil!.area { largestOrNil = component }
        }
        guard let largest = largestOrNil else { return .nothing }
        var points: [CGPoint] = []
        points.reserveCapacity(largest.rows.count * 4)
        for (y, span) in largest.rows {
            points.append(CGPoint(x: span.minX, y: y))
            points.append(CGPoint(x: span.minX, y: y + 1))
            points.append(CGPoint(x: span.maxX + 1, y: y))
            points.append(CGPoint(x: span.maxX + 1, y: y + 1))
        }
        let hull = convexHull(points)
        let rect = minAreaRect(of: hull)
        let rectWidth = Double(rect.size.width), rectHeight = Double(rect.size.height)
        let rectArea = rectWidth * rectHeight
        guard rectArea > 0 else { return .nothing }
        let region = DetectedPhotoRegion(center: rect.center, size: rect.size, angleDegrees: rect.angleDegrees)
        // How much of its outline is the scan's edge: a sheet whose corners run off the scan still
        // shows its edges; one lying along the scan's edge does not.
        var onBorder = 0
        for (y, span) in largest.rows {
            if y == 0 || y == h - 1 {
                onBorder += span.maxX - span.minX + 1
            } else {
                if span.minX == 0 { onBorder += 1 }
                if span.maxX == w - 1 { onBorder += 1 }
            }
        }
        let touches = Double(onBorder) > maxBorderContact * 2 * (rectWidth + rectHeight)

        // 5. A sheet: a sensible size and shape, filling its rectangle.
        let areaFraction = rectArea / (Double(w) * Double(h))
        let fill = Double(largest.area) / rectArea
        func rejected(_ why: PageRejection, marks: Int = 0) -> PageSearch {
            PageSearch(page: nil, rejection: why, candidate: region, areaFraction: areaFraction, fill: fill,
                       outsideMarks: marks, touchesBorder: touches, hull: hull)
        }
        if areaFraction < options.minPageAreaFraction { return rejected(.tooSmall) }
        if areaFraction > options.maxPageAreaFraction { return rejected(.fillsScan) }
        if fill < options.minPageFill { return rejected(.notRectangular) }
        let aspect = max(rectWidth, rectHeight) / max(1e-9, min(rectWidth, rectHeight))
        if aspect > options.maxPageAspect { return rejected(.notRectangular) }

        // 6. Around it, the background: a few objects (a ruler, a thread, a color chart) at most,
        //    not the many small marks of text, which mean the "sheet" is a picture on a page. Seen
        //    on the pixels as scanned: the median above wipes out thin print.
        let rawBackdrop = backdropOf(gray.pixels, w, h, dpi: gray.dpi, contrast: options.pageContrast)
        let marks = contentMask(gray.pixels, background: rawBackdrop.median, limit: rawBackdrop.limit)
        let minMark = max(1, Int((Double(minOutsideMarkPixels) * k * k + 0.5).rounded(.down)))
        let outside = marksOutside(marks, w, h, region: region, margin: 2 * closeBy, minArea: minMark)
        if outside.count > maxOutsideMarks { return rejected(.textAround, marks: outside.count) }
        // …nor another sheet or photo lying beside it, which cropping would drop.
        if Double(outside.largestArea) >= maxOutsideObjectFraction * rectArea {
            return rejected(.otherObjects, marks: outside.count)
        }
        return PageSearch(page: region, rejection: .none, candidate: region, areaFraction: areaFraction, fill: fill,
                          outsideMarks: outside.count, touchesBorder: touches, hull: hull)
    }

    /// The thickness of the outer ring, in pixels, of a w × h image at `dpi`.
    public static func ringWidth(_ w: Int, _ h: Int, dpi: Double) -> Int {
        max(1, Int((min(Double(min(w, h)) * borderRingFraction, borderRingInches * dpi) + 0.5).rounded(.down)))
    }

    /// The median of the outer ring (`ringWidth`) of the image, 0...255.
    public static func backgroundLuminance(_ gray: GrayImage) -> Int {
        let w = gray.width, h = gray.height
        let ring = ringWidth(w, h, dpi: gray.dpi > 0 ? gray.dpi : Double(GrayImage.analysisDPI))
        var histogram = [Int](repeating: 0, count: 256)
        var count = 0
        for y in 0..<h {
            let edgeRow = y < ring || y >= h - ring
            let row = y * w
            for x in 0..<w {
                if !edgeRow && x >= ring && x < w - ring { continue }
                histogram[Int(gray.pixels[row + x])] += 1
                count += 1
            }
        }
        return Int(BackgroundMap.percentile(histogram, count: count, fraction: 0.5))
    }

    /// The backdrop's luminance (the median of the outer ring of `pixels`) and how far a pixel must
    /// differ from it to stand out: `contrast` (`pageContrast` unless a search asks for another), or
    /// more on a textured backdrop (black felt, a dark archive frame), `backdropSpread` times the
    /// ring's median absolute deviation.
    private static func backdropOf(_ pixels: [UInt8], _ w: Int, _ h: Int, dpi: Double,
                                   contrast: Double = pageContrast) -> (median: Int, limit: Double) {
        let ring = ringWidth(w, h, dpi: dpi > 0 ? dpi : Double(GrayImage.analysisDPI))
        var histogram = [Int](repeating: 0, count: 256)
        var count = 0
        for y in 0..<h {
            let edgeRow = y < ring || y >= h - ring
            let row = y * w
            for x in 0..<w {
                if !edgeRow && x >= ring && x < w - ring { continue }
                histogram[Int(pixels[row + x])] += 1
                count += 1
            }
        }
        let median = Int(BackgroundMap.percentile(histogram, count: count, fraction: 0.5))
        var deviations = [Int](repeating: 0, count: 256)
        for v in 0..<256 { deviations[abs(v - median)] += histogram[v] }
        let mad = Int(BackgroundMap.percentile(deviations, count: count, fraction: 0.5))
        return (median, max(contrast * 255, backdropSpread * Double(mad)))
    }

    /// Each pixel replaced by the median of itself and its 8 neighbors (edges repeated).
    static func median3x3(_ gray: GrayImage) -> [UInt8] {
        let w = gray.width, h = gray.height
        let src = gray.pixels
        var output = [UInt8](repeating: 0, count: w * h)
        var window = [Int](repeating: 0, count: 9)
        for y in 0..<h {
            let y0 = max(0, y - 1), y2 = min(h - 1, y + 1)
            for x in 0..<w {
                let x0 = max(0, x - 1), x2 = min(w - 1, x + 1)
                window[0] = Int(src[y0 * w + x0]); window[1] = Int(src[y0 * w + x]); window[2] = Int(src[y0 * w + x2])
                window[3] = Int(src[y * w + x0]); window[4] = Int(src[y * w + x]); window[5] = Int(src[y * w + x2])
                window[6] = Int(src[y2 * w + x0]); window[7] = Int(src[y2 * w + x]); window[8] = Int(src[y2 * w + x2])
                // Insertion sort of nine values.
                for i in 1..<9 {
                    let v = window[i]
                    var j = i - 1
                    while j >= 0 && window[j] > v {
                        window[j + 1] = window[j]
                        j -= 1
                    }
                    window[j + 1] = v
                }
                output[y * w + x] = UInt8(window[4])
            }
        }
        return output
    }

    /// 1 where a pixel differs from `background` by more than `limit`.
    private static func contentMask(_ pixels: [UInt8], background: Int, limit: Double) -> [UInt8] {
        var mask = [UInt8](repeating: 0, count: pixels.count)
        for i in 0..<pixels.count where Double(abs(Int(pixels[i]) - background)) > limit {
            mask[i] = 1
        }
        return mask
    }

    /// The mask with every clear area the border cannot reach (4-connected) set.
    private static func fillHoles(_ mask: [UInt8], _ w: Int, _ h: Int) -> [UInt8] {
        var reached = [Bool](repeating: false, count: mask.count)
        var stack: [Int] = []
        func seed(_ i: Int) {
            if mask[i] == 0 && !reached[i] {
                reached[i] = true
                stack.append(i)
            }
        }
        for x in 0..<w {
            seed(x)
            seed((h - 1) * w + x)
        }
        for y in 0..<h {
            seed(y * w)
            seed(y * w + w - 1)
        }
        while let i = stack.popLast() {
            let x = i % w, y = i / w
            if x > 0 { seed(i - 1) }
            if x < w - 1 { seed(i + 1) }
            if y > 0 { seed(i - w) }
            if y < h - 1 { seed(i + w) }
        }
        var output = [UInt8](repeating: 0, count: mask.count)
        for i in 0..<mask.count { output[i] = reached[i] ? 0 : 1 }
        return output
    }

    /// The marks of at least `minArea` pixels (4-connected) of `content` lying wholly outside
    /// `region` grown by `margin` pixels, and the area of the largest.
    private static func marksOutside(_ content: [UInt8], _ w: Int, _ h: Int, region: DetectedPhotoRegion,
                                     margin: Int, minArea: Int) -> (count: Int, largestArea: Int) {
        let a = region.angleDegrees * .pi / 180
        let c = cos(a), s = sin(a)
        let hw = Double(region.size.width) / 2 + Double(margin), hh = Double(region.size.height) / 2 + Double(margin)
        let cx = Double(region.center.x), cy = Double(region.center.y)
        func inside(_ x: Int, _ y: Int) -> Bool {
            let dx = Double(x) + 0.5 - cx, dy = Double(y) + 0.5 - cy
            let u = dx * c + dy * s, v = -dx * s + dy * c
            return abs(u) <= hw && abs(v) <= hh
        }
        var marks = 0, largest = 0
        for component in MaskOps.connectedComponents(mask: content, width: w, height: h) where component.area >= minArea {
            var outside = true
            for (y, span) in component.rows
            where inside(span.minX, y) || inside(span.maxX, y) || inside((span.minX + span.maxX) / 2, y) {
                outside = false
                break
            }
            guard outside else { continue }
            marks += 1
            largest = max(largest, component.area)
        }
        return (marks, largest)
    }

    /// `coarse` snapped to the sheet's edges at full resolution (`PhotoDetector.refineRegion`), when
    /// no edge moves by more than `tolerance` pixels; otherwise `coarse`. The refinement only
    /// sharpens an edge the analysis found: a sheet as light as the background, or a textured
    /// backdrop, would let it wander into the sheet or out over the background.
    static func refined(_ coarse: DetectedPhotoRegion, image: RgbaImage, background: Double,
                        tolerance: Double) -> DetectedPhotoRegion {
        guard let cgImage = image.makeCGImage(),
              let refined = PhotoDetector.refineRegion(coarse, in: cgImage, backgroundLuminance: background) else {
            return coarse
        }
        let a = coarse.angleDegrees * .pi / 180
        let c = cos(a), s = sin(a)
        let dx = Double(refined.center.x - coarse.center.x), dy = Double(refined.center.y - coarse.center.y)
        let du = dx * c + dy * s, dv = -dx * s + dy * c
        let dw = Double(refined.size.width - coarse.size.width) / 2
        let dh = Double(refined.size.height - coarse.size.height) / 2
        // How far each edge moved: left, right, top, bottom.
        let steady = abs(du - dw) <= tolerance && abs(du + dw) <= tolerance
            && abs(dv - dh) <= tolerance && abs(dv + dh) <= tolerance
        return steady ? refined : coarse
    }

    /// The lines along the edges of `cut` (an upright crop of a sheet, scanned at `dpi`) that are
    /// darker than the paper just inside: the sheet's shadow on a light lid, or a sliver of a dark
    /// backdrop. At most `edgeTrimInches` per edge, and only lines clearly darker (`edgeTrimDrop`)
    /// than the median of the band inside them, so print near the edge stays.
    static func edgeInsets(_ cut: RgbaImage, dpi: Int) -> (left: Int, top: Int, right: Int, bottom: Int) {
        let w = cut.width, h = cut.height
        let band = max(1, Int((edgeTrimInches * Double(max(1, dpi)) + 0.5).rounded(.down)))
        guard w >= 4 * band + 4, h >= 4 * band + 4 else { return (0, 0, 0, 0) }
        let px = cut.pixels
        // The mean luma (0...255) of a row or a column, over its middle 80 %.
        func row(_ y: Int) -> Double {
            let x0 = w / 10, x1 = w - w / 10
            var sum = 0
            for x in x0..<x1 { sum += luma(px, (y * w + x) * 4) }
            return Double(sum) / Double(x1 - x0)
        }
        func column(_ x: Int) -> Double {
            let y0 = h / 10, y1 = h - h / 10
            var sum = 0
            for y in y0..<y1 { sum += luma(px, (y * w + x) * 4) }
            return Double(sum) / Double(y1 - y0)
        }
        func trim(_ line: (Int) -> Double) -> Int {
            var inside = [Double](repeating: 0, count: band)
            for i in 0..<band { inside[i] = line(band + i) }
            inside.sort()
            let limit = inside[band / 2] - edgeTrimDrop * 255
            var t = 0
            while t < band && line(t) < limit { t += 1 }
            return t
        }
        let left = trim({ column($0) })
        let top = trim({ row($0) })
        let right = trim({ column(w - 1 - $0) })
        let bottom = trim({ row(h - 1 - $0) })
        return (left, top, right, bottom)
    }

    /// Rec. 601 luma of the RGBA pixel at `i`, rounded (0...255).
    private static func luma(_ px: [UInt8], _ i: Int) -> Int {
        (299 * Int(px[i]) + 587 * Int(px[i + 1]) + 114 * Int(px[i + 2]) + 500) / 1000
    }

    /// The color of the outer ring (each channel's median) of `image`, scanned at `dpi`, to fill
    /// what a turn uncovers.
    public static func borderColor(_ image: RgbaImage, dpi: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        let w = image.width, h = image.height
        let ring = ringWidth(w, h, dpi: Double(max(1, dpi)))
        var r = [Int](repeating: 0, count: 256)
        var g = [Int](repeating: 0, count: 256)
        var b = [Int](repeating: 0, count: 256)
        var count = 0
        let px = image.pixels
        for y in 0..<h {
            let edgeRow = y < ring || y >= h - ring
            for x in 0..<w {
                if !edgeRow && x >= ring && x < w - ring { continue }
                let i = (y * w + x) * 4
                r[Int(px[i])] += 1
                g[Int(px[i + 1])] += 1
                b[Int(px[i + 2])] += 1
                count += 1
            }
        }
        return (BackgroundMap.percentile(r, count: count, fraction: 0.5),
                BackgroundMap.percentile(g, count: count, fraction: 0.5),
                BackgroundMap.percentile(b, count: count, fraction: 0.5))
    }

    /// The size of the scan turned by `angleDegrees` about its center: its own size when what
    /// turning in place cuts off from its corners is background, otherwise grown (evenly about the
    /// center) until nothing is cut off. In analysis pixels.
    public static func safeCanvas(_ gray: GrayImage, angleDegrees: Double) -> CGSize {
        let w = gray.width, h = gray.height
        let smooth = median3x3(gray)
        let backdrop = backdropOf(smooth, w, h, dpi: gray.dpi)
        let a = angleDegrees * .pi / 180
        let c = cos(a), s = sin(a)
        let cx = Double(w) / 2, cy = Double(h) / 2, hw = Double(w) / 2, hh = Double(h) / 2
        var needW = hw, needH = hh
        let k = (gray.dpi > 0 ? gray.dpi : Double(GrayImage.analysisDPI)) / Double(GrayImage.analysisDPI)
        let edge = max(1, Int((scanEdgeInches * k * Double(GrayImage.analysisDPI) + 0.5).rounded(.down)))
        var lost = 0
        if h - edge > edge && w - edge > edge {
            for y in edge..<(h - edge) {
                for x in edge..<(w - edge) {
                    if Double(abs(Int(smooth[y * w + x]) - backdrop.median)) <= backdrop.limit { continue }
                    // The pixel's place in the turned frame, whose axes are the straightened page's.
                    let dx = Double(x) + 0.5 - cx, dy = Double(y) + 0.5 - cy
                    let u = abs(dx * c + dy * s) + 0.5, v = abs(-dx * s + dy * c) + 0.5
                    if u <= hw && v <= hh { continue }
                    lost += 1
                    needW = max(needW, u)
                    needH = max(needH, v)
                }
            }
        }
        if lost <= max(1, Int((Double(maxLostContentPixels) * k * k + 0.5).rounded(.down))) {
            return CGSize(width: w, height: h)
        }
        return CGSize(width: (2 * needW).rounded(.up), height: (2 * needH).rounded(.up))
    }

    // MARK: - Text lines

    /// Which way the text on the page runs and how far it is turned, from projection profiles of its
    /// ink: the ink (darker than (1 − `inkContrast`) of the paper around it), less marks touching the
    /// border (the backdrop, the shadow of a page edge), dust and pictures, is projected across lines
    /// turned by each angle in ±`maxTextSkewDegrees`, in `coarseStepDegrees` steps and then
    /// `fineStepDegrees` steps around the best; the sum of squared line counts peaks where the lines
    /// of text line up. Rows and columns are both tried, for text running across or down the page.
    public static func estimateTextLayout(_ gray: GrayImage) -> TextLayout {
        let w = gray.width, h = gray.height
        let dpi = gray.dpi > 0 ? gray.dpi : Double(GrayImage.analysisDPI)
        let k = dpi / Double(GrayImage.analysisDPI)
        let tileSize = max(4, Int((BlankPageDetector.tileInches * dpi + 0.5).rounded(.down)))
        guard let raw = BackgroundMap.estimate(gray, x: 0, y: 0, width: w, height: h, tileSize: tileSize,
                                               percentile: BlankPageDetector.backgroundPercentile) else {
            return .nothing
        }
        let floor = max(0, Int(raw.medianTile()) - BlankPageDetector.darkAreaDrop)
        let ink = raw.maxSmoothed().clampedBelow(UInt8(floor)).inkMask(gray, contrast: inkContrast)

        // The glyphs: marks that do not touch the border, are not dust and are not pictures.
        let maxSide = max(1, Int((Double(maxGlyphSide) * k + 0.5).rounded(.down)))
        let minPixels = max(1, Int((Double(minGlyphPixels) * k * k + 0.5).rounded(.down)))
        let labelled = labelMarks(ink, w, h)
        var keep = [Bool](repeating: false, count: labelled.marks.count + 1)
        var total = 0
        for (m, mark) in labelled.marks.enumerated() {
            let border = mark.minX == 0 || mark.minY == 0 || mark.maxX == w - 1 || mark.maxY == h - 1
            let picture = mark.maxX - mark.minX + 1 > maxSide && mark.maxY - mark.minY + 1 > maxSide
            if border || picture || mark.area < minPixels { continue }
            keep[m + 1] = true
            total += mark.area
        }
        guard total >= minInkPoints else {
            return TextLayout(axis: .unknown, skewDegrees: 0, confidence: 0, inkPoints: total)
        }

        // Evenly picked ink pixels, centered on the image.
        let stride = (total + maxInkPoints - 1) / maxInkPoints
        var n = (total + stride - 1) / stride
        var xs = [Double](repeating: 0, count: n)
        var ys = [Double](repeating: 0, count: n)
        let cx = Double(w) / 2, cy = Double(h) / 2
        var seen = 0, taken = 0
        let labels = labelled.labels
        var i = 0
        while i < labels.count && taken < n {
            if keep[labels[i]] {
                if seen % stride == 0 {
                    xs[taken] = Double(i % w) + 0.5 - cx
                    ys[taken] = Double(i / w) + 0.5 - cy
                    taken += 1
                }
                seen += 1
            }
            i += 1
        }
        n = taken
        let offset = Int((cx * cx + cy * cy).squareRoot().rounded(.up)) + 2
        var bins = [Int](repeating: 0, count: 2 * offset + 2)

        let horizontal = sweep(xs, ys, n, vertical: false, bins: &bins, offset: offset)
        let vertical = sweep(xs, ys, n, vertical: true, bins: &bins, offset: offset)
        let hSharp = horizontal.sharpness, vSharp = vertical.sharpness
        let axis: TextAxis = hSharp >= axisMargin * vSharp ? .horizontal
            : vSharp >= axisMargin * hSharp ? .vertical
            : .unknown
        let best = axis == .vertical ? vertical : horizontal
        var confidence = best.confidence
        // A best angle at the end of the sweep may lie beyond it: not sure.
        if abs(best.coarseAngle) >= maxTextSkewDegrees - 1e-9 { confidence = 0 }
        if axis == .unknown {
            return TextLayout(axis: axis, skewDegrees: 0, confidence: confidence, inkPoints: n)
        }
        let skew = refine(xs, ys, n, vertical: axis == .vertical, bins: &bins, offset: offset, coarse: best.coarseAngle)
        return TextLayout(axis: axis, skewDegrees: skew, confidence: confidence, inkPoints: n)
    }

    private struct SweepResult {
        let coarseAngle: Double
        let sharpness: Double
        let confidence: Double
    }

    /// The coarse sweep for one direction: the best angle, how sharp its profile is against an even
    /// spread (sum of squares × span / count², 1 for an even spread), and the confidence.
    private static func sweep(_ xs: [Double], _ ys: [Double], _ n: Int, vertical: Bool,
                              bins: inout [Int], offset: Int) -> SweepResult {
        let steps = Int((maxTextSkewDegrees / coarseStepDegrees).rounded())
        var bestScore = -Double.greatestFiniteMagnitude, bestAngle = 0.0, sum = 0.0
        var bestSpan = 1
        for i in -steps...steps {
            let angle = Double(i) * coarseStepDegrees
            let result = score(xs, ys, n, angleDegrees: angle, vertical: vertical, bins: &bins, offset: offset)
            sum += result.score
            if result.score > bestScore {
                bestScore = result.score
                bestAngle = angle
                bestSpan = result.span
            }
        }
        let mean = sum / Double(2 * steps + 1)
        let sharpness = n > 0 ? bestScore * Double(bestSpan) / (Double(n) * Double(n)) : 0
        let confidence = mean > 0 ? (bestScore - mean) / mean : 0
        return SweepResult(coarseAngle: bestAngle, sharpness: sharpness, confidence: confidence)
    }

    /// The fine sweep around `coarse` (± one coarse step), then the peak placed between the best
    /// fine angle and its neighbors (a parabola through the three scores).
    private static func refine(_ xs: [Double], _ ys: [Double], _ n: Int, vertical: Bool,
                               bins: inout [Int], offset: Int, coarse: Double) -> Double {
        let steps = Int((coarseStepDegrees / fineStepDegrees).rounded())
        var scores = [Double](repeating: 0, count: 2 * steps + 1)
        var bestIndex = 0
        for i in -steps...steps {
            let result = score(xs, ys, n, angleDegrees: coarse + Double(i) * fineStepDegrees, vertical: vertical,
                               bins: &bins, offset: offset)
            scores[i + steps] = result.score
            if result.score > scores[bestIndex] { bestIndex = i + steps }
        }
        var angle = coarse + Double(bestIndex - steps) * fineStepDegrees
        if bestIndex > 0 && bestIndex < scores.count - 1 {
            let left = scores[bestIndex - 1], mid = scores[bestIndex], right = scores[bestIndex + 1]
            let denominator = left - 2 * mid + right
            if denominator < 0 {
                let shift = 0.5 * (left - right) / denominator
                angle += min(0.5, max(-0.5, shift)) * fineStepDegrees
            }
        }
        return min(maxTextSkewDegrees, max(-maxTextSkewDegrees, angle))
    }

    /// The sum of squared counts of the points projected, at `angleDegrees`, on the page's vertical
    /// axis (rows of text: y·cos θ − x·sin θ) or its horizontal one (columns: x·cos θ + y·sin θ), in
    /// 1-pixel bins, and the number of bins between the first and the last one used.
    private static func score(_ xs: [Double], _ ys: [Double], _ n: Int, angleDegrees: Double, vertical: Bool,
                              bins: inout [Int], offset: Int) -> (score: Double, span: Int) {
        let a = angleDegrees * .pi / 180
        let c = cos(a), s = sin(a)
        for b in 0..<bins.count { bins[b] = 0 }
        var lo = Int.max, hi = Int.min
        for i in 0..<n {
            let p = vertical ? xs[i] * c + ys[i] * s : ys[i] * c - xs[i] * s
            let b = Int(p.rounded(.down)) + offset
            bins[b] += 1
            if b < lo { lo = b }
            if b > hi { hi = b }
        }
        let span = hi >= lo ? hi - lo + 1 : 1
        var sum = 0.0
        if hi >= lo {
            for b in max(0, lo)...hi { sum += Double(bins[b]) * Double(bins[b]) }
        }
        return (sum, span)
    }

    private struct Mark {
        var area = 0
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
    }

    /// The 8-connected marks of `mask`: a label per pixel (0 = none, else mark index + 1) and each
    /// mark's area and box.
    private static func labelMarks(_ mask: [UInt8], _ w: Int, _ h: Int) -> (labels: [Int], marks: [Mark]) {
        var labels = [Int](repeating: 0, count: mask.count)
        var marks: [Mark] = []
        var stack: [Int] = []
        for start in 0..<mask.count {
            guard mask[start] == 1, labels[start] == 0 else { continue }
            var mark = Mark()
            let label = marks.count + 1
            labels[start] = label
            stack.append(start)
            while let i = stack.popLast() {
                let x = i % w, y = i / w
                mark.area += 1
                if x < mark.minX { mark.minX = x }
                if x > mark.maxX { mark.maxX = x }
                if y < mark.minY { mark.minY = y }
                if y > mark.maxY { mark.maxY = y }
                for ny in max(0, y - 1)...min(h - 1, y + 1) {
                    for nx in max(0, x - 1)...min(w - 1, x + 1) {
                        let j = ny * w + nx
                        if mask[j] == 1 && labels[j] == 0 {
                            labels[j] = label
                            stack.append(j)
                        }
                    }
                }
            }
            marks.append(mark)
        }
        return (labels, marks)
    }
}
