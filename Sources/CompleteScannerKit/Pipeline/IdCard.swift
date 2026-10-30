import CoreGraphics
import Foundation

// Twin of windows/LazyScan.Core/IdCard.cs: the ID card task. The front and the back of a
// card are scanned on the flatbed, the card is found on each scan (PhotoDetector), and both sides
// are laid out on one page at their real size (ID-1 is 85.60 × 53.98 mm).

/// The page an ID card copy is laid out on (`TaskOptions.idCardPaper`). `.auto` comes first: it is
/// the default and the fallback for a value a newer version adds, and it is the paper usual where
/// the user lives (`PaperSizes.defaultForRegion`). Twin of C# `IdCardPaper`.
public enum IdCardPaper: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto
    case a4
    case letter

    public var id: String { rawValue }

    /// "Automatic", "A4", "Letter".
    public var label: String {
        switch self {
        case .auto: return "Automatic"
        case .a4: return "A4"
        case .letter: return "Letter"
        }
    }
}

/// Twin of C# `IdCardPapers`.
public enum IdCardPapers {
    /// The paper the copy is made on: A4 or Letter as chosen. Automatic is the default printer's paper
    /// (`printerPaper`) when it is A4 or Letter, else the usual paper in `regionCode`.
    public static func resolve(_ paper: IdCardPaper, regionCode: String?, printerPaper: PaperSize? = nil) -> PaperSize {
        switch paper {
        case .a4: return .a4
        case .letter: return .letter
        case .auto:
            if let printerPaper, printerPaper == .a4 || printerPaper == .letter { return printerPaper }
            return PaperSizes.defaultForRegion(regionCode)
        }
    }

    /// How a picker names a choice, Automatic with the paper it is now: "Automatic (A4)", "A4", "Letter".
    public static func choiceLabel(_ paper: IdCardPaper, regionCode: String?, printerPaper: PaperSize? = nil) -> String {
        paper == .auto
            ? "Automatic (\(resolve(paper, regionCode: regionCode, printerPaper: printerPaper).label))"
            : paper.label
    }
}

/// The guided steps of the ID card task: the front, the back (skippable), then checking and
/// saving. Twin of C# `IdCardSteps`.
public enum IdCardSteps {
    public static let frontStepID = "front"
    public static let backStepID = "back"
    public static let reviewStepID = "review"

    /// Front, back, review. Only the front must be captured: the back is skipped for a card with
    /// nothing on its back, and the review captures nothing.
    public static let steps: [TaskStep] = [
        TaskStep(id: frontStepID, title: "Front side",
                 prompt: "Place the card face down near a corner and scan.",
                 primaryActionLabel: "Scan front",
                 help: "Close the lid before scanning."),
        TaskStep(id: backStepID, title: "Back side",
                 prompt: "Turn the card over where it lies and scan.",
                 primaryActionLabel: "Scan back", skippable: true, requiresCapture: false,
                 help: "Nothing printed on the back? Select No back side."),
        TaskStep(id: reviewStepID, title: "Check and save",
                 prompt: "Check both sides, then save.",
                 primaryActionLabel: "Review", requiresCapture: false,
                 help: "Both sides go on one page at real size."),
    ]

    /// The button that leaves out the back of a card with nothing printed on it.
    public static let skipBackLabel = "No back side"

    /// The ID card review's line on privacy: the scans stay out of the Scans history.
    public static let privacyNote = "Not kept in Scans history"

    /// The privacy line's full sentence, for its tooltip and VoiceOver.
    public static let privacyHelp = "The scans stay on this computer and are cleared once you save or discard them."

    /// The side a step scans; nil for the review and any other step.
    public static func sideOf(_ stepID: String?) -> PageSide? {
        guard let stepID else { return nil }
        if stepID == frontStepID { return .front }
        if stepID == backStepID { return .back }
        return nil
    }

    /// The step that scans `side`.
    public static func stepID(_ side: PageSide) -> String {
        side == .front ? frontStepID : backStepID
    }

    /// Whether the scan screen offers to skip `step`: only the back of an ID card, which may have
    /// nothing printed on it. The backs of a stack turned over by hand are left out with Keep Fronts
    /// Only instead, which also takes the backs scanned so far out of the queue.
    public static func offersSkip(_ step: TaskStep?) -> Bool {
        guard let step else { return false }
        return step.skippable && step.id == backStepID
    }
}

/// A scan a side of an ID card was found on: its resolution, its size in pixels and the part of the
/// glass it covers (the selection, 0–1 of the glass; nil for the whole glass). Twin of C#
/// `IdCardScanArea`.
public struct IdCardScanArea: Equatable {
    public let dpi: Int
    public let pixelSize: CGSize
    public let selection: CGRect?

    public init(dpi: Int, pixelSize: CGSize, selection: CGRect?) {
        self.dpi = dpi
        self.pixelSize = pixelSize
        self.selection = selection
    }
}

/// How the card was found on a scan (`IdCardDetector.pickCard`). Twin of C# `IdCardPickKind`.
public enum IdCardPickKind: Sendable {
    /// A region the size and shape of a card.
    case card
    /// Nothing card-sized: the largest region found.
    case largestRegion
    /// Nothing card-sized on the back: the place of the front, the card turned over where it lay.
    case frontPlace
    /// Nothing found: the whole scan, to be cropped by hand.
    case wholeScan
}

/// Where the card is on a scan, and how sure that is. Twin of C# `IdCardPick`.
public struct IdCardPick: Equatable {
    public let region: DetectedPhotoRegion
    public let kind: IdCardPickKind

    public init(region: DetectedPhotoRegion, kind: IdCardPickKind) {
        self.region = region
        self.kind = kind
    }

    /// Nothing was found: the crop has to be fixed by hand.
    public var needsManualCrop: Bool { kind == .wholeScan }

    /// What to check, shown under the side; nil when the card was found.
    public var note: String? { IdCardDetector.note(kind) }
}

/// Finds the card on a flatbed scan among what `PhotoDetector` finds: the region closest to an ID-1
/// card in shape and size. Passports (ID-3, up to 4.92 × 3.46 in) qualify too. Twin of C#
/// `IdCardDetector`.
public enum IdCardDetector {
    /// Long side of an ID-1 card: 85.60 mm.
    public static let cardLongSideInches = 3.370
    /// Short side of an ID-1 card: 53.98 mm.
    public static let cardShortSideInches = 2.125
    /// Long side over short side of an ID-1 card (1.586).
    public static let cardAspect = cardLongSideInches / cardShortSideInches
    /// A card-sized region's long side is at least this long…
    public static let minLongSideInches = 2.5
    /// …and at most this long (a passport page fits).
    public static let maxLongSideInches = 6.0
    /// Smaller things on the glass are ignored.
    public static let minSideInches = 1.5
    /// The largest regions considered.
    public static let maxRegions = 4

    /// How the detector is run on a card scan.
    public static func detectionOptions() -> PhotoDetectorOptions {
        var options = PhotoDetectorOptions()
        options.minPhotoSideInches = minSideInches
        options.maxPhotoCount = maxRegions
        return options
    }

    /// The region's long side, in inches.
    public static func longSideInches(_ region: DetectedPhotoRegion, dpi: Int) -> Double {
        Double(max(region.size.width, region.size.height)) / Double(max(1, dpi))
    }

    /// How far a region is from a card: |aspect − 1.586| / 1.586 + |long side − 3.370 in| / 3.370
    /// (0 for an exact card; lower is closer).
    public static func score(_ region: DetectedPhotoRegion, dpi: Int) -> Double {
        let longSide = Double(max(region.size.width, region.size.height))
        let shortSide = Double(min(region.size.width, region.size.height))
        guard shortSide > 0 else { return Double.greatestFiniteMagnitude }
        let longInches = longSide / Double(max(1, dpi))
        return abs(longSide / shortSide - cardAspect) / cardAspect
            + abs(longInches - cardLongSideInches) / cardLongSideInches
    }

    /// The region's long side is between `minLongSideInches` and `maxLongSideInches`.
    public static func qualifies(_ region: DetectedPhotoRegion, dpi: Int) -> Bool {
        let longInches = longSideInches(region, dpi: dpi)
        return longInches >= minLongSideInches && longInches <= maxLongSideInches
    }

    /// The card among `regions` (full-resolution pixels of a scan `imageSize` large at `dpi`): the
    /// qualifying region with the lowest `score` (the first of equals). When none qualifies: the
    /// `fallback` when given (the front's place, for the back of a card turned over where it lay),
    /// else the largest region; with no regions either, the whole scan.
    public static func pickCard(_ regions: [DetectedPhotoRegion], dpi: Int, imageSize: CGSize,
                                fallback: DetectedPhotoRegion? = nil) -> IdCardPick {
        var best: DetectedPhotoRegion?
        var bestScore = Double.greatestFiniteMagnitude
        for region in regions where qualifies(region, dpi: dpi) {
            let regionScore = score(region, dpi: dpi)
            if regionScore < bestScore {
                best = region
                bestScore = regionScore
            }
        }
        if let best { return IdCardPick(region: best, kind: .card) }
        if let fallback { return IdCardPick(region: fallback, kind: .frontPlace) }
        var largest: DetectedPhotoRegion?
        for region in regions {
            if let current = largest {
                if region.size.width * region.size.height > current.size.width * current.size.height {
                    largest = region
                }
            } else {
                largest = region
            }
        }
        if let largest { return IdCardPick(region: largest, kind: .largestRegion) }
        return IdCardPick(region: wholeScan(imageSize), kind: .wholeScan)
    }

    /// The whole scan as a region.
    public static func wholeScan(_ imageSize: CGSize) -> DetectedPhotoRegion {
        DetectedPhotoRegion(center: CGPoint(x: imageSize.width / 2, y: imageSize.height / 2),
                            size: imageSize, angleDegrees: 0)
    }

    /// Where a card lies after being turned over where it lay: the same place and size, its tilt
    /// mirrored.
    public static func flippedInPlace(_ region: DetectedPhotoRegion) -> DetectedPhotoRegion {
        DetectedPhotoRegion(center: region.center, size: region.size,
                            angleDegrees: region.angleDegrees == 0 ? 0 : -region.angleDegrees)
    }

    /// The front's place on the back's scan, for a back that does not stand out (the card turned
    /// over where it lay): `flippedInPlace`, moved to the back's resolution. nil when the two scans
    /// do not cover the same part of the glass (another selection, or sizes that differ once the
    /// resolution is allowed for): the front's place then says nothing about the back's.
    public static func frontPlaceOnBack(_ frontRegion: DetectedPhotoRegion, front: IdCardScanArea,
                                        back: IdCardScanArea) -> DetectedPhotoRegion? {
        guard front.dpi > 0, back.dpi > 0, front.selection == back.selection else { return nil }
        let scale = Double(back.dpi) / Double(front.dpi)
        guard sameLength(Double(front.pixelSize.width) * scale, Double(back.pixelSize.width)),
              sameLength(Double(front.pixelSize.height) * scale, Double(back.pixelSize.height)) else { return nil }
        let flipped = flippedInPlace(frontRegion)
        return DetectedPhotoRegion(center: CGPoint(x: Double(flipped.center.x) * scale, y: Double(flipped.center.y) * scale),
                                   size: CGSize(width: Double(flipped.size.width) * scale,
                                                height: Double(flipped.size.height) * scale),
                                   angleDegrees: flipped.angleDegrees)
    }

    /// Two lengths in pixels agree but for a scanner's rounding: within 2 pixels or 1 %.
    private static func sameLength(_ expected: Double, _ actual: Double) -> Bool {
        abs(expected - actual) <= max(2, 0.01 * abs(actual))
    }

    /// The card on a scan: `PhotoDetector.detectRegions`, then `pickCard`.
    public static func detect(_ image: CGImage, dpi: Int, fallback: DetectedPhotoRegion? = nil) -> IdCardPick {
        pickCard(PhotoDetector.detectRegions(in: image, dpi: dpi, options: detectionOptions()), dpi: dpi,
                 imageSize: CGSize(width: image.width, height: image.height), fallback: fallback)
    }

    /// The card cut out of the scan and turned straight; the scan itself when that fails.
    public static func extract(_ image: CGImage, pick: IdCardPick) -> CGImage {
        PhotoDetector.extractPhoto(from: image, region: pick.region, deskew: true) ?? image
    }

    /// What to check about a side, by how its card was found; nil for a card.
    public static func note(_ kind: IdCardPickKind) -> String? {
        switch kind {
        case .card: return nil
        case .largestRegion: return "This does not look like the size of an ID card. Check the crop."
        case .frontPlace: return "The card did not stand out on this scan, so the place of the front was used. Check the crop."
        case .wholeScan: return "No card was found, so the whole glass was kept. Fix the crop, or scan again with the lid closed."
        }
    }
}

/// Where the sides go on the page, in inches from the top-left corner. `scale` is 1 at real size,
/// below 1 when the sides were made smaller to fit the page. Twin of C# `IdCardLayoutResult`.
public struct IdCardLayoutResult: Equatable {
    public let front: CGRect
    public let back: CGRect?
    public let scale: Double

    public init(front: CGRect, back: CGRect?, scale: Double) {
        self.front = front
        self.back = back
        self.scale = scale
    }

    /// The sides were made smaller to fit: the copy is not at real size.
    public var scaledToFit: Bool { scale < 1 }
}

/// Lays the sides out on the page: centred, one under the other, at real size when they fit. Twin
/// of C# `IdCardLayout`.
public enum IdCardLayout {
    /// The front's top edge is this far below the top of the page.
    public static let topMarginInches = 1.0
    /// Space between the front and the back.
    public static let gapInches = 0.5
    /// Nothing comes closer to the paper's edges than this.
    public static let edgeMarginInches = 0.25

    /// The warning shown when the sides were made smaller to fit the page.
    public static let notRealSizeMessage = "Too large for the page at real size, so it was made smaller to fit. It is not at real size."

    /// The places of a front `front` and back `back` (inches) on `paper`: centred across, the front
    /// 1 in from the top, the back 0.5 in under it, both at real size. When they would come closer
    /// than 0.25 in to an edge, both are made smaller by the same factor (`scaledToFit`).
    public static func place(front: CGSize, back: CGSize?, paper: CGSize) -> IdCardLayoutResult {
        let frontWidth0 = Double(front.width), frontHeight0 = Double(front.height)
        let backWidth0 = back.map { Double($0.width) } ?? 0
        let backHeight0 = back.map { Double($0.height) } ?? 0
        let paperWidth = Double(paper.width), paperHeight = Double(paper.height)
        let widest = max(frontWidth0, backWidth0)
        let stacked = frontHeight0 + backHeight0
        let availableWidth = paperWidth - 2 * edgeMarginInches
        let availableHeight = paperHeight - edgeMarginInches - topMarginInches - (back == nil ? 0 : gapInches)
        var scale = 1.0
        if widest > 0 && widest > availableWidth { scale = min(scale, availableWidth / widest) }
        if stacked > 0 && stacked > availableHeight { scale = min(scale, availableHeight / stacked) }
        scale = max(scale, 0.01)

        let frontWidth = frontWidth0 * scale, frontHeight = frontHeight0 * scale
        let frontRect = CGRect(x: (paperWidth - frontWidth) / 2, y: topMarginInches,
                               width: frontWidth, height: frontHeight)
        var backRect: CGRect?
        if back != nil {
            let backWidth = backWidth0 * scale, backHeight = backHeight0 * scale
            backRect = CGRect(x: (paperWidth - backWidth) / 2, y: topMarginInches + frontHeight + gapInches,
                              width: backWidth, height: backHeight)
        }
        return IdCardLayoutResult(front: frontRect, back: backRect, scale: scale)
    }

    /// "One A4 page, real size", "Front only, one Letter page, made smaller to fit".
    public static func caption(paper: PaperSize, hasBack: Bool, scaledToFit: Bool) -> String {
        let lead: String = hasBack ? "One" : "Front only, one"
        let size: String = scaledToFit ? "made smaller to fit" : "real size"
        return "\(lead) \(paper.label) page, \(size)"
    }
}

/// One side of a card as cut out of its scan, at the resolution it was scanned at. Twin of C#
/// `IdCardSide`.
public struct IdCardSide: Equatable, Sendable {
    public let image: RgbaImage
    public let dpi: Int

    public init(image: RgbaImage, dpi: Int) {
        self.image = image
        self.dpi = dpi
    }

    /// Its size on paper, in inches.
    public var inches: CGSize {
        CGSize(width: Double(image.width) / Double(max(1, dpi)), height: Double(image.height) / Double(max(1, dpi)))
    }
}

/// Puts the sides of a card on one white page (`IdCardLayout`), ready to save or print. Twin of C#
/// `IdCardComposer`.
public enum IdCardComposer {
    /// The highest resolution the page is composed and saved at. The sides print at real size at any
    /// resolution, and a Letter page at 600 dpi is already 5100 × 6600 pixels; at the 2400 dpi many
    /// flatbeds offer, the page would not even fit in one image.
    public static let maxPageDPI = 600

    /// The resolution of the page for sides scanned at `sideDPI`: theirs, at most `maxPageDPI`.
    public static func pageDPI(_ sideDPI: Int) -> Int {
        min(max(sideDPI, 1), maxPageDPI)
    }

    /// The color mode of the page for sides scanned in `front` and `back` (nil: no back), which is what
    /// the page's pixels are: the sides' mode when they agree, color when either is color, else
    /// grayscale (black & white beside gray). The color mode set when the card is saved does not count.
    public static func pageColorMode(front: ColorMode, back: ColorMode?) -> ColorMode {
        guard let back, back != front else { return front }
        if front == .color || back == .color { return .color }
        return .grayscale
    }

    /// The page in pixels: round(paper × dpi), for example 2550 × 3300 for Letter at 300 dpi.
    public static func canvasSize(paperInches: CGSize, dpi: Int) -> (width: Int, height: Int) {
        (max(1, pixels(Double(paperInches.width), dpi: dpi)), max(1, pixels(Double(paperInches.height), dpi: dpi)))
    }

    /// The page at `dpi`: white, `paperInches` large, with each side copied into its place. A side
    /// is resampled only when its place in pixels differs from its own size (another resolution, or
    /// made smaller to fit). Saved with `dpi`, the page is exactly the paper size, so the sides
    /// print at real size.
    public static func compose(front: IdCardSide, back: IdCardSide?, dpi: Int, paperInches: CGSize) -> RgbaImage {
        let size = canvasSize(paperInches: paperInches, dpi: dpi)
        var canvas = RgbaImage.filled(width: size.width, height: size.height, r: 255, g: 255, b: 255)
        let layout = IdCardLayout.place(front: front.inches, back: back?.inches, paper: paperInches)
        copy(front.image, into: layout.front, dpi: dpi, canvas: &canvas)
        if let back, let backRect = layout.back {
            copy(back.image, into: backRect, dpi: dpi, canvas: &canvas)
        }
        return canvas
    }

    /// The name of a side's own file next to the page's: "ID card 2026-10-19 front".
    public static func sideFileBase(_ baseName: String, side: PageSide) -> String {
        "\(baseName) \(side == .front ? "front" : "back")"
    }

    private static func pixels(_ inches: Double, dpi: Int) -> Int {
        Int((inches * Double(dpi)).rounded())
    }

    private static func copy(_ side: RgbaImage, into rectInches: CGRect, dpi: Int, canvas: inout RgbaImage) {
        let x0 = pixels(Double(rectInches.origin.x), dpi: dpi)
        let y0 = pixels(Double(rectInches.origin.y), dpi: dpi)
        let w = max(1, pixels(Double(rectInches.size.width), dpi: dpi))
        let h = max(1, pixels(Double(rectInches.size.height), dpi: dpi))
        let source = w == side.width && h == side.height ? side : side.resized(width: w, height: h)
        let left = max(0, x0), right = min(canvas.width, x0 + w)
        guard right > left else { return }
        let count = (right - left) * 4
        for y in 0..<h {
            let cy = y0 + y
            guard cy >= 0, cy < canvas.height else { continue }
            let from = (y * w + (left - x0)) * 4
            let to = (cy * canvas.width + left) * 4
            canvas.pixels.replaceSubrange(to..<(to + count), with: source.pixels[from..<(from + count)])
        }
    }
}
