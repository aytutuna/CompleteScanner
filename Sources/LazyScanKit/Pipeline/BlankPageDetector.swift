import CoreGraphics
import Foundation

/// What `BlankPageDetector.analyze` looks for. Twin of C# `BlankPageOptions`.
public struct BlankPageOptions: Equatable, Sendable {
    /// How much may be on the page for it to count as blank.
    public var sensitivity: BlankSensitivity
    /// The band along every edge that is not looked at: edge shadows, staples and punched holes
    /// live there. Pages whose short side is under `BlankPageDetector.smallPageInches` use
    /// `BlankPageDetector.smallPageMarginFraction` of it instead.
    public var marginInches: Double

    public init(sensitivity: BlankSensitivity = .medium, marginInches: Double = BlankPageDetector.marginInches) {
        self.sensitivity = sensitivity
        self.marginInches = marginInches
    }
}

/// What the blank-page check found on a page. Twin of C# `BlankPageResult`.
public struct BlankPageResult: Equatable, Codable, Sendable {
    /// Share of the area looked at covered by marks larger than dust (0...1).
    public let inkCoverage: Double
    /// Marks larger than dust.
    public let inkComponents: Int
    /// A photo, a dark block or a dark band covers part of the page: such a page is never blank.
    public let hasLargeDarkArea: Bool
    /// The page counts as blank at the sensitivity it was checked with.
    public let isBlank: Bool

    public init(inkCoverage: Double, inkComponents: Int, hasLargeDarkArea: Bool, isBlank: Bool) {
        self.inkCoverage = inkCoverage
        self.inkComponents = inkComponents
        self.hasLargeDarkArea = hasLargeDarkArea
        self.isBlank = isBlank
    }

    /// Whether the page counts as blank at `sensitivity`.
    public func isBlankAt(_ sensitivity: BlankSensitivity) -> Bool {
        !hasLargeDarkArea && inkCoverage < BlankPageDetector.threshold(sensitivity)
    }
}

/// Tells blank pages (the empty back of a one-sided sheet in a two-sided scan, a separator left
/// in the stack) from pages with something on them, robust to what scanners add to an empty
/// page: noise, dust, tinted or uneven paper, edge shadows, punched holes and the other side
/// showing through. All at `GrayImage.analysisDPI`:
/// 1. The edges are left out (`BlankPageOptions.marginInches`).
/// 2. The paper's brightness is mapped in tiles (`BackgroundMap`, 90th percentile), each tile
///    raised to the brightest of its neighbors, and to no less than the page's median minus
///    `darkAreaDrop`, so a photo or a dark block is never taken for paper. When more than
///    `darkTileFraction` of the tiles are that dark, the page has a large dark area and is never
///    blank.
/// 3. A pixel is ink when it is darker than (1 − `inkContrast`) of the paper there: print and
///    pencil are, show-through and paper texture are not.
/// 4. Marks (8-connected, so a thin slanted pencil stroke stays one mark) smaller than
///    `minMarkPixels` are dust and dropped.
/// 5. The page is blank when the remaining ink covers less than `threshold` of the area.
/// The decision only flags a page: the app leaves flagged pages out at save time, and the user can
/// keep any of them (`PageFilter`). Twin of C# `BlankPageDetector`: same constants, same steps,
/// same arithmetic, so a page gives the same result on both platforms.
public enum BlankPageDetector {
    /// Edge band left out on normal pages, in inches.
    public static let marginInches = 0.7
    /// Pages with a shorter side than this (cards, receipts) use `smallPageMarginFraction`.
    public static let smallPageInches = 2.5
    /// Edge band of small pages, as a share of their short side.
    public static let smallPageMarginFraction = 0.15
    /// Side of a background tile, in inches (25 pixels at the analysis resolution).
    public static let tileInches = 0.25
    /// A tile's background is this percentile of its pixels.
    public static let backgroundPercentile = 0.9
    /// Tiles darker than the page's median tile by more than this (of 255) are a dark area, not paper.
    public static let darkAreaDrop = 64
    /// A page with more than this share of dark-area tiles is never blank.
    public static let darkTileFraction = 0.01
    /// A pixel is ink when darker than (1 − this) of the paper around it.
    public static let inkContrast = 0.30
    /// Marks smaller than this many pixels at the analysis resolution are dust.
    public static let minMarkPixels = 6

    /// The largest ink coverage a blank page may have: Low 0.01 %, Medium 0.03 %, High 0.1 %. A
    /// lone page number (about 0.02 %) is blank at Medium; one line of text or a signature (about
    /// 0.15 % and more) is never blank.
    public static func threshold(_ sensitivity: BlankSensitivity) -> Double {
        switch sensitivity {
        case .low: return 0.0001
        case .high: return 0.001
        case .medium: return 0.0003
        }
    }

    /// Checks `image`, scanned at `dpi`, read as gray at the analysis resolution
    /// (`GrayImage(cgImage:sourceDPI:analysisDPI:)`). A page that cannot be read is not blank.
    public static func analyze(_ image: CGImage, dpi: Int, options: BlankPageOptions = BlankPageOptions()) -> BlankPageResult {
        guard let gray = GrayImage(cgImage: image, sourceDPI: dpi) else {
            return BlankPageResult(inkCoverage: 0, inkComponents: 0, hasLargeDarkArea: false, isBlank: false)
        }
        return analyze(gray, options: options)
    }

    /// Checks `page`, scanned at `dpi`: converted to gray at the analysis resolution first
    /// (`GrayImage.from(_:sourceDPI:analysisDPI:)`).
    public static func analyze(_ page: RgbaImage, dpi: Int, options: BlankPageOptions = BlankPageOptions()) -> BlankPageResult {
        analyze(GrayImage.from(page, sourceDPI: dpi), options: options)
    }

    /// Checks a gray page. Pixel sizes follow `GrayImage.dpi`, so a page at another resolution
    /// than `GrayImage.analysisDPI` gives about the same result. A page whose area inside the
    /// margins is smaller than one background tile is not blank: it is too small to tell.
    public static func analyze(_ gray: GrayImage, options: BlankPageOptions = BlankPageOptions()) -> BlankPageResult {
        let notBlank = BlankPageResult(inkCoverage: 0, inkComponents: 0, hasLargeDarkArea: false, isBlank: false)
        let dpi = gray.dpi > 0 ? gray.dpi : Double(GrayImage.analysisDPI)
        let k = dpi / Double(GrayImage.analysisDPI)

        // 1. Leave out the edges.
        let shortSide = min(gray.width, gray.height)
        let marginPixels = Double(shortSide) / dpi < smallPageInches
            ? smallPageMarginFraction * Double(shortSide)
            : max(0, options.marginInches) * dpi
        let margin = min(Int((marginPixels + 0.5).rounded(.down)), (shortSide - 1) / 2)
        let width = gray.width - 2 * margin, height = gray.height - 2 * margin
        let tileSize = max(4, Int((tileInches * dpi + 0.5).rounded(.down)))
        guard width >= tileSize, height >= tileSize,
              let raw = BackgroundMap.estimate(gray, x: margin, y: margin, width: width, height: height,
                                               tileSize: tileSize, percentile: backgroundPercentile) else {
            return notBlank
        }

        // 2. The paper's brightness, never lower than the median paper minus the dark-area drop.
        let floor = max(0, Int(raw.medianTile()) - darkAreaDrop)
        let darkTiles = raw.tiles.filter { Int($0) < floor }.count
        let hasLargeDarkArea = Double(darkTiles) > darkTileFraction * Double(raw.tiles.count)
        let background = raw.maxSmoothed().clampedBelow(UInt8(floor))

        // 3. Ink: clearly darker than the paper around it.
        let ink = background.inkMask(gray, contrast: inkContrast)

        // 4. Drop dust; 5. measure what is left.
        let minMark = max(1, Int((Double(minMarkPixels) * k * k + 0.5).rounded(.down)))
        var inkPixels = 0
        var marks = 0
        for area in MaskOps.componentAreas(mask: ink, width: background.width, height: background.height,
                                           eightConnected: true) where area >= minMark {
            inkPixels += area
            marks += 1
        }
        let coverage = Double(inkPixels) / Double(background.width * background.height)
        let isBlank = !hasLargeDarkArea && coverage < threshold(options.sensitivity)
        return BlankPageResult(inkCoverage: coverage, inkComponents: marks,
                               hasLargeDarkArea: hasLargeDarkArea, isBlank: isBlank)
    }
}
