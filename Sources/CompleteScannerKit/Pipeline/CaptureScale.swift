import CoreGraphics
import Foundation

// Twin of windows/CompleteScanner.Core/CaptureScale.cs: the same sizes, rules and arithmetic (+ − × ÷
// and square roots on doubles in the same order, rounding with floor(x + 0.5)).

/// What a camera shot shows: it decides the sizes a page can snap to (`CaptureScale.candidates`) and
/// the shapes several objects in one shot are picked by (`MultiQuadPicker`). Stored by its raw value;
/// the first is the default and the fallback for a value a newer version adds. Twin of C# `CaptureKind`.
public enum CaptureKind: String, CaseIterable, Codable, Sendable {
    /// A page of a document: A4, Letter, Legal or an ID card.
    case document
    /// A till receipt: 80 or 57 mm wide, any length.
    case receipt
    /// A printed photo: 4 × 6, 5 × 7 or 3.5 × 5 in (10 × 15 cm has 4 × 6 in's shape and is reported as 4 × 6 in).
    case photo
    /// An ID-1 card (85.6 × 54 mm).
    case idCard
}

/// Where a captured page's real size comes from. Stored by its raw value; the first is the default
/// and the fallback. Twin of C# `CaptureScaleBasis`.
public enum CaptureScaleBasis: String, CaseIterable, Codable, Sendable {
    /// No known size matched: the page is taken at `CaptureScale.nominalDPI`, so its size is made up.
    case nominal
    /// A paper size (`PaperSize`), the ID-1 card included.
    case paper
    /// A receipt roll's width; the length is the page's own.
    case receiptWidth
    /// A photo print size.
    case photoSize
}

/// A size a captured page can snap to. Twin of C# `CaptureSize`.
public struct CaptureSize: Equatable, Sendable {
    /// Its stable name ("a4", "idCard", "receipt80mm", "photo4x6in"), stored with the page.
    public var id: String
    /// What kind of size it is.
    public var basis: CaptureScaleBasis
    /// The short side, in inches.
    public var shortInches: Double
    /// The long side, in inches; nil for a receipt, whose length is free.
    public var longInches: Double?
    /// The paper size it is, for `.paper`.
    public var paper: PaperSize?

    public init(id: String, basis: CaptureScaleBasis, shortInches: Double, longInches: Double?, paper: PaperSize? = nil) {
        self.id = id
        self.basis = basis
        self.shortInches = shortInches
        self.longInches = longInches
        self.paper = paper
    }

    /// The long side over the short side; nil for a free length.
    public var longOverShort: Double? {
        guard let longSide = longInches else { return nil }
        return longSide / shortInches
    }
}

/// A captured page's real size (`CaptureScale.measure`): what it snapped to, the resolution, and the
/// pixel size the page is made at. Twin of C# `CaptureScaleResult`.
public struct CaptureScaleResult: Equatable, Codable, Sendable {
    /// Where the size comes from.
    public var basis: CaptureScaleBasis
    /// The `CaptureSize.id` snapped to; nil for `.nominal`.
    public var size: String?
    /// Pixels per inch of the page.
    public var dpi: Int
    /// The page's size in pixels.
    public var pixelWidth: Int
    public var pixelHeight: Int
    /// The page's real size (the size's own when it snapped, else pixels over `dpi`).
    public var widthInches: Double
    public var heightInches: Double

    public init(basis: CaptureScaleBasis, size: String?, dpi: Int, pixelWidth: Int, pixelHeight: Int,
                widthInches: Double, heightInches: Double) {
        self.basis = basis
        self.size = size
        self.dpi = dpi
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.widthInches = widthInches
        self.heightInches = heightInches
    }

    /// The page snapped to a known size, so it can be printed or measured at real size.
    public var isRealSize: Bool { basis != .nominal }

    /// The paper size it snapped to, for `.paper`; nil otherwise.
    public var paper: PaperSize? { CaptureScale.find(size)?.paper }
}

/// What the camera recorded about a page (`ScannedPage.capture`): the page's corners in the photo as
/// it was taken (continuous pixels of `sourceWidth` × `sourceHeight`, before any turn), that photo's
/// size, what the shot showed, the camera's focal length when known, and, once the page was cut out
/// (`PerspectiveStep`), the real size it snapped to. Twin of C# `CaptureFacts`.
public struct CaptureFacts: Equatable, Codable, Sendable {
    public var quad: Quad
    public var sourceWidth: Int
    public var sourceHeight: Int
    /// What the shot showed.
    public var kind: CaptureKind
    /// The camera's focal length in pixels of the photo (`CaptureScale.focalLengthPixels`); nil when not known.
    public var focalLength: Double?
    /// The real size the page snapped to when it was cut out; nil until then.
    public var scale: CaptureScaleResult?
    /// How the page was cleaned up once cut out (`EnhanceStep`, `DocumentEnhancer`; auto resolved); nil until
    /// then. Kept in memory only.
    public var enhancement: DocumentEnhanceMode? = nil

    public init(quad: Quad, sourceWidth: Int, sourceHeight: Int, kind: CaptureKind = .document,
                focalLength: Double? = nil, scale: CaptureScaleResult? = nil) {
        self.quad = quad
        self.sourceWidth = sourceWidth
        self.sourceHeight = sourceHeight
        self.kind = kind
        self.focalLength = focalLength
        self.scale = scale
    }

    /// These facts for the photo mirrored and turned as `orientation` says (mirrored left to right first,
    /// then turned clockwise, as `PhotoImport.oriented` turns its pixels): each corner moves with its
    /// pixel, (x, y) to (W − x, y) when mirrored and to (H − y, x) for each quarter turn of a W × H photo,
    /// and the corners are named again (`Quad.fromCorners`); the photo's size swaps with an odd turn; the
    /// kind, the focal length (a turn keeps the scale) and the real size stay. An upright orientation
    /// returns the facts as they are. Twin of C# `CaptureFacts.Oriented`.
    public func oriented(_ orientation: PhotoOrientation) -> CaptureFacts {
        let turns: Int = ((orientation.quarterTurns % 4) + 4) % 4
        if turns == 0 && !orientation.mirrored { return self }
        let corners: [CGPoint] = quad.corners
        var moved: [CGPoint] = []
        for corner in corners {
            var x: Double = Double(corner.x)
            var y: Double = Double(corner.y)
            if orientation.mirrored { x = Double(sourceWidth) - x }
            var width: Int = sourceWidth
            var height: Int = sourceHeight
            var turn: Int = 0
            while turn < turns {
                let turnedX: Double = Double(height) - y
                y = x
                x = turnedX
                let oldWidth: Int = width
                width = height
                height = oldWidth
                turn += 1
            }
            moved.append(CGPoint(x: x, y: y))
        }
        let swaps: Bool = turns % 2 == 1
        var result: CaptureFacts = self
        result.quad = Quad.fromCorners(moved)
        result.sourceWidth = swaps ? sourceHeight : sourceWidth
        result.sourceHeight = swaps ? sourceWidth : sourceHeight
        return result
    }

    /// These facts for the photo resized to `width` × `height` pixels: the corners scaled with it, the
    /// focal length by the geometric mean of the two scales (√(sx · sy), the scale itself when the photo
    /// keeps its shape), and the kind and real size kept. The same size, facts without a photo size, or a
    /// size of no pixels return the facts as they are. Twin of C# `CaptureFacts.ScaledTo`.
    public func scaled(toWidth width: Int, height: Int) -> CaptureFacts {
        if sourceWidth <= 0 || sourceHeight <= 0 || width <= 0 || height <= 0 { return self }
        if width == sourceWidth && height == sourceHeight { return self }
        let sx: Double = Double(width) / Double(sourceWidth)
        let sy: Double = Double(height) / Double(sourceHeight)
        var result: CaptureFacts = self
        result.quad = quad.scaled(sx, sy)
        result.sourceWidth = width
        result.sourceHeight = height
        if let f = focalLength {
            result.focalLength = f * (sx * sy).squareRoot()
        }
        return result
    }

    /// Whether a photo of `width` × `height` pixels is the photo these facts were taken on, perhaps
    /// resized: the same shape to within the rounding of a resize (|width · sourceHeight − height ·
    /// sourceWidth| at most the longer source side). A photo turned a quarter since is not, unless it is
    /// nearly square, where its shape cannot tell: whoever turns a photo turns its facts with it
    /// (`oriented`). Twin of C# `CaptureFacts.DescribesPhoto`.
    public func describesPhoto(width: Int, height: Int) -> Bool {
        if sourceWidth <= 0 || sourceHeight <= 0 || width <= 0 || height <= 0 { return false }
        let difference: Int64 = abs(Int64(width) * Int64(sourceHeight) - Int64(height) * Int64(sourceWidth))
        return difference <= Int64(max(sourceWidth, sourceHeight))
    }
}

/// The real size of a page taken by a camera, which has no scale of its own: the page's true shape
/// (`PerspectiveCorrector.estimateAspect` with the camera's focal length when known, else as the quad
/// shows it) is matched against known sizes (`candidates`) within `tolerance`, the nearest winning
/// (the first on a tie). A match fixes the resolution: the whole number of pixels per inch the camera
/// resolved along the page's long side (its short side for a receipt), at most `maxDPI`, and the page
/// is made at that size: never larger than the photo shows it, so nothing is upsampled. A page that
/// matches nothing keeps its pixels at `nominalDPI`, and its size is made up
/// (`CaptureScaleResult.isRealSize` is false), so real-size printing must fit it to the paper instead.
/// Twin of C# `CaptureScale`.
public enum CaptureScale {
    /// A shape matches a size when the long-over-short ratios differ by at most this share (3 %).
    public static let tolerance: Double = PerspectiveCorrector.paperAspectTolerance
    /// The resolution of a page that matches no known size.
    public static let nominalDPI = 200
    /// A snapped page is made at no more than this resolution (a close-up of a card is made smaller).
    public static let maxDPI = 600
    /// The diagonal of a 36 × 24 mm frame, which "35 mm equivalent" focal lengths refer to.
    public static let fullFrameDiagonalMm: Double = 43.266615305567875

    private static let mmPerInch: Double = 25.4

    /// The paper sizes a document page snaps to (`PerspectiveCorrector.matchedSizes`: A4 stands for
    /// every √2 sheet).
    public static let papers: [CaptureSize] = makePaperSizes()

    /// The receipt widths, 80 mm first (the most common roll: two widths cannot be told apart by shape).
    public static let receiptWidths: [CaptureSize] = [
        CaptureSize(id: "receipt80mm", basis: .receiptWidth, shortInches: 80 / mmPerInch, longInches: nil),
        CaptureSize(id: "receipt57mm", basis: .receiptWidth, shortInches: 57 / mmPerInch, longInches: nil),
    ]

    /// The photo print sizes (10 × 15 cm has 4 × 6 in's shape, so it is taken only when listed first).
    public static let photoSizes: [CaptureSize] = [
        CaptureSize(id: "photo4x6in", basis: .photoSize, shortInches: 4, longInches: 6),
        CaptureSize(id: "photo5x7in", basis: .photoSize, shortInches: 5, longInches: 7),
        CaptureSize(id: "photo3.5x5in", basis: .photoSize, shortInches: 3.5, longInches: 5),
        CaptureSize(id: "photo10x15cm", basis: .photoSize, shortInches: 100 / mmPerInch, longInches: 150 / mmPerInch),
    ]

    /// The ID-1 card.
    public static var idCard: CaptureSize {
        for size in papers where size.paper == .idCard { return size }
        preconditionFailure("The paper sizes include the ID-1 card.")
    }

    /// The sizes a page of `kind` snaps to.
    public static func candidates(_ kind: CaptureKind) -> [CaptureSize] {
        switch kind {
        case .document: return papers
        case .receipt: return receiptWidths
        case .photo: return photoSizes
        case .idCard: return [idCard]
        }
    }

    /// The size named `id` among every list here; nil for none.
    public static func find(_ id: String?) -> CaptureSize? {
        guard let id = id else { return nil }
        let lists: [[CaptureSize]] = [papers, receiptWidths, photoSizes]
        for list in lists {
            for size in list where size.id == id { return size }
        }
        return nil
    }

    /// The focal length in pixels of a `width` × `height` photo whose "35 mm equivalent" focal length
    /// (EXIF FocalLenIn35mmFilm) is `focalLength35mm`; nil when either is not a positive number.
    public static func focalLengthPixels(_ focalLength35mm: Double, width: Int, height: Int) -> Double? {
        guard focalLength35mm > 0, focalLength35mm.isFinite, width > 0, height > 0 else { return nil }
        let w = Double(width), h = Double(height)
        let diagonal: Double = (w * w + h * h).squareRoot()
        return focalLength35mm * diagonal / fullFrameDiagonalMm
    }

    /// The true shape of the page `quad` outlines: from the camera's `focalLength` (pixels) when known,
    /// else as `PerspectiveCorrector.estimateAspect` works it out.
    public static func aspect(_ quad: Quad, imageWidth: Int, imageHeight: Int, focalLength: Double? = nil) -> AspectEstimate {
        let w = Double(imageWidth), h = Double(imageHeight)
        if let f = focalLength {
            return PerspectiveCorrector.estimateAspect(quad, imageWidth: w, imageHeight: h, focalLength: f)
        }
        return PerspectiveCorrector.estimateAspect(quad, imageWidth: w, imageHeight: h)
    }

    /// The size among `candidates` a shape of `longOverShort` snaps to: the fixed size whose ratio is
    /// nearest, within `tolerance` of it (as a share of the size's ratio; the first on a tie); else the
    /// first free-length size (a receipt width), which any shape fits; nil when none fits.
    public static func match(_ longOverShort: Double, candidates: [CaptureSize],
                             tolerance: Double = CaptureScale.tolerance) -> CaptureSize? {
        guard longOverShort >= 1, longOverShort.isFinite else { return nil }
        var best: CaptureSize?
        var bestDiff = Double.greatestFiniteMagnitude
        var free: CaptureSize?
        for size in candidates {
            guard let ratio = size.longOverShort else {
                if free == nil { free = size }
                continue
            }
            let diff: Double = abs(longOverShort - ratio) / ratio
            if diff <= tolerance && diff < bestDiff {
                bestDiff = diff
                best = size
            }
        }
        return best ?? free
    }

    /// The real size of the page `quad` outlines in an `imageWidth` × `imageHeight` photo, among the
    /// sizes for `kind`.
    public static func measure(_ quad: Quad, imageWidth: Int, imageHeight: Int, kind: CaptureKind,
                               focalLength: Double? = nil) -> CaptureScaleResult {
        measure(quad, imageWidth: imageWidth, imageHeight: imageHeight, candidates: candidates(kind),
                focalLength: focalLength)
    }

    /// The real size of the page `quad` outlines, among `candidates`: its shape (`aspect`) and the
    /// pixels the camera resolved along its long side (the longer of each pair of opposite edges, kept
    /// within `PerspectiveCorrector.maxPhotoDiagonals` of the photo's diagonal and
    /// `PerspectiveCorrector.maxOutputSide`), then `snap`.
    public static func measure(_ quad: Quad, imageWidth: Int, imageHeight: Int, candidates: [CaptureSize],
                               focalLength: Double? = nil) -> CaptureScaleResult {
        let estimate = aspect(quad, imageWidth: imageWidth, imageHeight: imageHeight, focalLength: focalLength)
        let w0: Double = max(quad.edgeLength(0), quad.edgeLength(2))
        let h0: Double = max(quad.edgeLength(1), quad.edgeLength(3))
        var longSide: Double = max(w0, h0)
        let iw = Double(imageWidth), ih = Double(imageHeight)
        let photoDiagonal: Double = (iw * iw + ih * ih).squareRoot()
        let limit: Double = min(PerspectiveCorrector.maxPhotoDiagonals * photoDiagonal,
                                Double(PerspectiveCorrector.maxOutputSide))
        longSide = min(longSide, limit)
        return snap(widthOverHeight: estimate.widthOverHeight, longSidePixels: longSide, candidates: candidates)
    }

    /// The real size of a page of shape `widthOverHeight` whose long side the camera resolved in
    /// `longSidePixels` pixels, among `candidates` (`match`). Snapped to a fixed size: the resolution is
    /// the whole number of pixels per inch along the long side, 1 to `maxDPI`, and the page is the
    /// size's inches at that resolution. Snapped to a receipt width: the same along the short side, the
    /// length the page's own. Nothing matched: `nominalDPI`, the page keeps its pixels. Landscape when
    /// the shape is at least 1.
    public static func snap(widthOverHeight: Double, longSidePixels: Double, candidates: [CaptureSize]) -> CaptureScaleResult {
        let aspect: Double = widthOverHeight > 0 && widthOverHeight.isFinite ? widthOverHeight : 1
        let landscape = aspect >= 1
        let longOverShort: Double = landscape ? aspect : 1 / aspect
        let longSide: Double = longSidePixels > 1 && longSidePixels.isFinite ? longSidePixels : 1
        guard let size = match(longOverShort, candidates: candidates) else {
            let longPx = max(1, roundHalfUp(longSide))
            let shortPx = max(1, roundHalfUp(longSide / longOverShort))
            let nominal = Double(nominalDPI)
            return oriented(.nominal, nil, nominalDPI, longPx, shortPx,
                            Double(longPx) / nominal, Double(shortPx) / nominal, landscape)
        }
        let shortInches = size.shortInches
        let longInches: Double
        let dpiExact: Double
        if let fixedLong = size.longInches {
            longInches = fixedLong
            dpiExact = longSide / fixedLong
        } else {
            longInches = shortInches * longOverShort
            dpiExact = longSide / longOverShort / shortInches
        }
        let whole: Double = max(1, min(Double(maxDPI), dpiExact.rounded(.down)))
        let dpi = Int(whole)
        let longPixels = max(1, roundHalfUp(longInches * Double(dpi)))
        let shortPixels = max(1, roundHalfUp(shortInches * Double(dpi)))
        return oriented(size.basis, size.id, dpi, longPixels, shortPixels, longInches, shortInches, landscape)
    }

    /// The real size of a page already upright at `pixelWidth` × `pixelHeight` (Apple's document
    /// scanner gives no corners): its shape matched as `snap` does, the resolution the nearest whole
    /// number of pixels per inch of the size (the pixels are kept, so it is not limited to `maxDPI`);
    /// `nominalDPI` when nothing matches.
    public static func fromAspect(pixelWidth: Int, pixelHeight: Int, kind: CaptureKind) -> CaptureScaleResult {
        let w = max(1, pixelWidth), h = max(1, pixelHeight)
        let landscape = w >= h
        let longPx = Double(max(w, h)), shortPx = Double(min(w, h))
        let longOverShort: Double = longPx / shortPx
        guard let size = match(longOverShort, candidates: candidates(kind)) else {
            let nominal = Double(nominalDPI)
            return CaptureScaleResult(basis: .nominal, size: nil, dpi: nominalDPI, pixelWidth: w, pixelHeight: h,
                                      widthInches: Double(w) / nominal, heightInches: Double(h) / nominal)
        }
        let shortInches = size.shortInches
        let longInches: Double = size.longInches ?? shortInches * longOverShort
        let exact: Double
        if let fixedLong = size.longInches {
            exact = longPx / fixedLong
        } else {
            exact = shortPx / shortInches
        }
        let dpi = max(1, roundHalfUp(exact))
        return CaptureScaleResult(basis: size.basis, size: size.id, dpi: dpi, pixelWidth: w, pixelHeight: h,
                                  widthInches: landscape ? longInches : shortInches,
                                  heightInches: landscape ? shortInches : longInches)
    }

    private static func oriented(_ basis: CaptureScaleBasis, _ id: String?, _ dpi: Int, _ longPixels: Int,
                                 _ shortPixels: Int, _ longInches: Double, _ shortInches: Double,
                                 _ landscape: Bool) -> CaptureScaleResult {
        if landscape {
            return CaptureScaleResult(basis: basis, size: id, dpi: dpi, pixelWidth: longPixels, pixelHeight: shortPixels,
                                      widthInches: longInches, heightInches: shortInches)
        }
        return CaptureScaleResult(basis: basis, size: id, dpi: dpi, pixelWidth: shortPixels, pixelHeight: longPixels,
                                  widthInches: shortInches, heightInches: longInches)
    }

    private static func roundHalfUp(_ value: Double) -> Int {
        Int((value + 0.5).rounded(.down))
    }

    private static func makePaperSizes() -> [CaptureSize] {
        var sizes: [CaptureSize] = []
        for paper in PerspectiveCorrector.matchedSizes {
            guard let inches = PaperSizes.inches(paper) else { continue }
            let w = Double(inches.width), h = Double(inches.height)
            sizes.append(CaptureSize(id: paper.rawValue, basis: .paper, shortInches: min(w, h), longInches: max(w, h),
                                     paper: paper))
        }
        return sizes
    }
}
