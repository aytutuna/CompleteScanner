import CoreGraphics
import Foundation

/// One step of the work done on every scanned page before it is queued or saved. A step gets the
/// page as the earlier steps left it and returns it changed (other pixels through
/// `ScannedPage.withImage`) or with new facts (`ScannedPage.withBlank`). Steps run off the main
/// actor, one page at a time. Twin of C# `IPageStep`.
public protocol PageStep {
    /// A stable name ("blank", "adjust"), for tests and diagnostics.
    var name: String { get }
    func apply(_ page: ScannedPage) -> ScannedPage
}

/// A step that can take long enough to be stopped part way: `PageProcessor.process` hands it the
/// `shouldContinue` it was given. Twin of C# `ICancellablePageStep`.
public protocol CancellablePageStep: PageStep {
    /// Throws `ScanError.cancelled` when `shouldContinue` says no.
    func apply(_ page: ScannedPage, shouldContinue: () -> Bool) throws -> ScannedPage
}

/// Checks whether the page is blank (`BlankPageDetector`) and records the result on it; the
/// pixels are not changed. Runs before any adjustment, on the page as scanned.
public struct BlankDetectionStep: PageStep {
    public let options: BlankPageOptions
    public var name: String { "blank" }

    public init(options: BlankPageOptions) {
        self.options = options
    }

    public func apply(_ page: ScannedPage) -> ScannedPage {
        page.withBlank(BlankPageDetector.analyze(page.image, dpi: page.dpi, options: options))
    }
}

/// Crops the page to the sheet and straightens it (`DocumentGeometry.correct`), keeping the page as
/// it was as the other version (`ScannedPage.withGeometry`); a page the analysis is not sure about
/// stays as it is. Runs after the blank check, before the adjustments. Twin of C# `GeometryStep`.
public struct GeometryStep: PageStep {
    public let crop: Bool
    public let straighten: Bool
    public var name: String { "geometry" }

    public init(crop: Bool, straighten: Bool) {
        self.crop = crop
        self.straighten = straighten
    }

    public func apply(_ page: ScannedPage) -> ScannedPage {
        guard let pixels = RgbaImage(cgImage: page.image),
              let corrected = DocumentGeometry.correct(pixels, dpi: page.dpi, crop: crop, straighten: straighten),
              let image = corrected.image.makeCGImage() else { return page }
        return page.withGeometry(image, geometry: corrected.geometry)
    }
}

/// Looks for a patch code on the page (`PatchCodeDetector`) and records it: the page is then a
/// separator sheet, used when the stack is split at separator sheets (`DocumentSplitter`). The
/// pixels are not changed. Runs after crop and straighten, before the adjustments. Twin of C#
/// `SeparatorStep`.
public struct SeparatorStep: PageStep {
    public var name: String { "separator" }

    public init() {}

    public func apply(_ page: ScannedPage) -> ScannedPage {
        page.withPatch(PatchCodeDetector.detect(page.image, dpi: page.dpi)?.code)
    }
}

/// Turns the page upright when its text reads clearly better another way up
/// (`OrientationDecision.check`, reading with `scorer`), recording the turn so one click undoes it
/// (`ScannedPage.turnedUpright`). Blank pages and separator sheets are not read; a page the reading is
/// not sure about, or that takes longer than `maxSeconds`, stays as it is. Runs after the separator
/// check, before the adjustments, on the page as cropped and straightened. `clock` (seconds) is for
/// tests. Twin of C# `OrientationStep`.
public struct OrientationStep: CancellablePageStep {
    public let scorer: any OrientationScorer
    public let maxSeconds: Double
    private let clock: () -> Double
    public var name: String { "orientation" }

    public init(scorer: any OrientationScorer, maxSeconds: Double = OrientationDecision.maxSecondsPerPage,
                clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.scorer = scorer
        self.maxSeconds = maxSeconds
        self.clock = clock
    }

    /// Reads the page with nothing to stop it (`ScanError.cancelled` cannot happen then).
    public func apply(_ page: ScannedPage) -> ScannedPage {
        (try? apply(page, shouldContinue: { true })) ?? page
    }

    public func apply(_ page: ScannedPage, shouldContinue: () -> Bool) throws -> ScannedPage {
        if page.blank?.isBlank == true || page.patch != nil { return page }
        guard let pixels = RgbaImage(cgImage: page.image) else { return page }
        let check = try OrientationDecision.check(pixels, dpi: page.dpi, scorer: scorer, maxSeconds: maxSeconds,
                                                  clock: clock, shouldContinue: shouldContinue)
        return check.verdict == .turned ? page.turnedUpright(check.quarterTurns) : page
    }
}

/// The image adjustments and the color mode (`ImagePipeline.apply`), on the page and on its other
/// version (the page as scanned, kept by crop and straighten), so either can be shown.
public struct AdjustmentStep: PageStep {
    public let adjustments: AdjustmentSettings
    public let colorMode: ColorMode
    public var name: String { "adjust" }

    public init(adjustments: AdjustmentSettings, colorMode: ColorMode) {
        self.adjustments = adjustments
        self.colorMode = colorMode
    }

    public func apply(_ page: ScannedPage) -> ScannedPage {
        let adjusted = page.withImage(ImagePipeline.apply(adjustments, to: page.image, colorMode: colorMode),
                                      colorMode: colorMode)
        guard var version = page.alternate, let other = version.image else { return adjusted }
        version.image = ImagePipeline.apply(adjustments, to: other, colorMode: colorMode)
        return adjusted.withAlternate(version)
    }
}

/// How the pages of one scan come out of the scanner. Twin of C# `ScanArrangement`.
public enum ScanArrangement: Sendable {
    /// One page per sheet, in the order scanned.
    case asScanned
    /// A two-sided feeder scan: front, back, front, back… (`DocumentSides.arrangeTwoSided`).
    case twoSided
    /// The fronts of a stack turned over by hand (`DocumentSides.markManual`).
    case turnedOverFronts
    /// The backs of a stack turned over by hand, last sheet first.
    case turnedOverBacks
}

/// The pages of one scan after processing. Twin of C# `ProcessedScan`.
public struct ProcessedScan {
    /// The pages in reading order with their sides marked and the backs turned upright, otherwise
    /// as scanned (for the preview and the history).
    public let arranged: [ScannedPage]
    /// The same pages after every step, with the facts the steps found; with facing pages split, the
    /// pages cut from each spread (`ScannedPage.spread`, whose id is the spread's in `arranged`).
    public let pages: [ScannedPage]

    /// Pages the blank-page check found blank at the sensitivity it ran with.
    public var blankCount: Int { pages.filter { $0.blank?.isBlank == true }.count }

    /// The spreads in `arranged` that pages were cut from (or kept whole as), in scan order.
    public var spreads: [ScannedPage] {
        let ids = Set(pages.compactMap(\.spreadID))
        return arranged.filter { ids.contains($0.id) }
    }
}

/// The clean-up stage between the scanner and the page queue, the same for every scanner: the
/// pages are put in reading order with their sides (two-sided scans), each spread of an open book is
/// cut into its two pages when facing pages are split (`book`), then every step runs on every page in
/// order. The order of the steps is fixed: `forScan` builds them from the settings: blank check
/// (document pages), crop and straighten, separator sheets, turning pages upright, then adjustments.
/// Twin of C# `PageProcessor`.
public struct PageProcessor {
    public let steps: [any PageStep]
    public let arrangement: ScanArrangement
    public let binding: DuplexBinding
    /// How the pages of each spread are turned and ordered; nil when spreads are not split.
    public let book: BookSplitOptions?

    public init(steps: [any PageStep], arrangement: ScanArrangement = .asScanned, binding: DuplexBinding = .longEdge,
                book: BookSplitOptions? = nil) {
        self.steps = steps
        self.arrangement = arrangement
        self.binding = binding
        self.book = book
    }

    /// The steps for a scan made with `settings`: the blank-page check for pages collected in the
    /// document queue (whether or not blank pages are left out, so the page strip can flag them),
    /// crop and straighten when asked for those pages, the separator-sheet check for those pages
    /// (whether or not the stack is split, so a split chosen later finds them), turning those pages
    /// upright when asked for and `scorer` can read text, then the adjustments unless they change
    /// nothing. Facing pages are split before the steps when asked for those pages
    /// (`splitsFacingPages`), so each page is checked, straightened and turned on its own.
    public static func forScan(_ settings: ScanSettings, arrangement: ScanArrangement = .asScanned,
                               scorer: (any OrientationScorer)? = nil) -> PageProcessor {
        var steps: [any PageStep] = []
        if checksBlankPages(settings) {
            steps.append(BlankDetectionStep(options: BlankPageOptions(sensitivity: settings.document.blankSensitivity)))
        }
        if correctsGeometry(settings) {
            steps.append(GeometryStep(crop: settings.document.autoCrop, straighten: settings.document.autoStraighten))
        }
        if checksBlankPages(settings) {
            steps.append(SeparatorStep())
        }
        if turnsPagesUpright(settings), let scorer, scorer.isAvailable {
            steps.append(OrientationStep(scorer: scorer))
        }
        if !(settings.adjustments.isIdentity && settings.colorMode == .color) {
            steps.append(AdjustmentStep(adjustments: settings.adjustments, colorMode: settings.colorMode))
        }
        return PageProcessor(steps: steps, arrangement: arrangement, binding: settings.backBinding,
                             book: splitsFacingPages(settings) ? BookSplitOptions.of(settings) : nil)
    }

    /// Whether scans with these settings get the blank-page check: document pages collected in the
    /// queue, where a flagged page can be seen and kept before saving. Pages saved as soon as they
    /// are scanned are never checked, so none is ever left out unseen.
    public static func checksBlankPages(_ settings: ScanSettings) -> Bool {
        TaskCatalog.flow(of: settings) == .documentQueue && settings.documentMultiPage
    }

    /// Whether scans with these settings are cropped or straightened: asked for, on document pages
    /// collected in the queue, where the page strip shows a changed page and one click shows it as
    /// scanned. Pages saved as soon as they are scanned are never changed unseen.
    public static func correctsGeometry(_ settings: ScanSettings) -> Bool {
        checksBlankPages(settings) && (settings.document.autoCrop || settings.document.autoStraighten)
    }

    /// Whether scans with these settings are turned upright: asked for, on document pages collected
    /// in the queue, where the page strip shows a turned page and one click undoes the turn. Pages
    /// saved as soon as they are scanned are never turned unseen.
    public static func turnsPagesUpright(_ settings: ScanSettings) -> Bool {
        checksBlankPages(settings) && settings.document.autoRotate
    }

    /// Whether scans with these settings have their facing pages split: asked for, on document pages
    /// collected in the queue, where the page strip shows the pages and one click joins them again,
    /// scanned one side of each sheet (`BookPages.scansOneSide`). Pages saved as soon as they are
    /// scanned are never cut unseen, and pages scanned on both sides keep their sheet and side.
    public static func splitsFacingPages(_ settings: ScanSettings) -> Bool {
        checksBlankPages(settings) && settings.document.splitFacingPages && BookPages.scansOneSide(settings)
    }

    /// Arranges the pages, splits each spread when facing pages are split (where its gutter is found,
    /// `BookSplitter.findGutter`; whole otherwise), then runs every step on every page. `shouldContinue`
    /// is asked before each page and each step, and handed to the steps that can stop part way
    /// (`CancellablePageStep`); when it says no, `ScanError.cancelled` is thrown.
    public func process(_ scanned: [ScannedPage], shouldContinue: () -> Bool = { true }) throws -> ProcessedScan {
        guard shouldContinue() else { throw ScanError.cancelled }
        let arranged: [ScannedPage]
        switch arrangement {
        case .twoSided: arranged = DocumentSides.arrangeTwoSided(scanned, binding: binding)
        case .turnedOverFronts: arranged = DocumentSides.markManual(scanned, side: .front, binding: binding)
        case .turnedOverBacks: arranged = DocumentSides.markManual(scanned, side: .back, binding: binding)
        case .asScanned: arranged = scanned
        }
        var pages: [ScannedPage] = []
        pages.reserveCapacity(arranged.count)
        for page in arranged {
            guard shouldContinue() else { throw ScanError.cancelled }
            if let book {
                let gutter = BookSplitter.findGutter(page.image, dpi: page.dpi)
                let spreadPages = try processSpread(page, cut: gutter, options: book, shouldContinue: shouldContinue)
                pages.append(contentsOf: spreadPages)
                continue
            }
            let current = try runSteps(page, shouldContinue: shouldContinue)
            pages.append(current)
        }
        return ProcessedScan(arranged: arranged, pages: pages)
    }

    /// The pages of one spread after every step: `spread` (as scanned) cut at `cut`, or kept whole when
    /// it is nil, each page turned as `options` say, then put in reading order: by where they lie once
    /// turned by the book's rotation and the turn reading their text gave them
    /// (`BookSplitter.totalTurns`). Each page records the spread (`SpreadPart`, with the spread's id),
    /// keeps the side and sheet the spread was given (`side`, `sheetIndex`) and gets an id of its own.
    /// Used for every scan when facing pages are split, and to join or split a spread again. Twin of C#
    /// `PageProcessor.ProcessSpread`.
    public func processSpread(_ spread: ScannedPage, cut: GutterResult?, options: BookSplitOptions,
                              shouldContinue: () -> Bool = { true }) throws -> [ScannedPage] {
        guard shouldContinue() else { throw ScanError.cancelled }
        let turns = BookSplitter.normalizedTurns(options.rotationQuarterTurns)
        func part(_ image: CGImage, _ index: Int?, _ gutter: GutterResult?) -> ScannedPage {
            var page = ScannedPage(image: ImagePipeline.rotate(image, quarterTurns: turns), dpi: spread.dpi,
                                   colorMode: spread.colorMode, createdAt: spread.createdAt)
            page.side = spread.side
            page.sheetIndex = spread.sheetIndex
            page.spread = SpreadPart(spreadID: spread.id, part: index, gutter: index == nil ? nil : gutter)
            return page
        }
        guard let cut, let halves = BookSplitter.halves(spread.image, gutter: cut) else {
            let whole = try runSteps(part(spread.image, nil, nil), shouldContinue: shouldContinue)
            return [whole]
        }
        let a = try runSteps(part(halves.first, 0, cut), shouldContinue: shouldContinue)
        let b = try runSteps(part(halves.second, 1, cut), shouldContinue: shouldContinue)
        let total = BookSplitter.totalTurns(turns, a.upright, b.upright)
        return BookSplitter.firstPartLeads(cut.axis, quarterTurns: total, rightToLeft: options.rightToLeft) ? [a, b] : [b, a]
    }

    /// Every step on `page`, in order.
    private func runSteps(_ page: ScannedPage, shouldContinue: () -> Bool) throws -> ScannedPage {
        var current = page
        for step in steps {
            guard shouldContinue() else { throw ScanError.cancelled }
            if let cancellable = step as? any CancellablePageStep {
                current = try cancellable.apply(current, shouldContinue: shouldContinue)
            } else {
                current = step.apply(current)
            }
        }
        return current
    }
}

/// Which queued pages are saved. A page is left out when the user skipped it, or when it looks
/// blank and blank pages are left out, unless the user kept it. Nothing is ever removed from the
/// queue by this: a left-out page stays visible, flagged, until the queue is saved. Twin of C#
/// `PageFilter`.
public enum PageFilter {
    /// The message when every queued page is left out, so there is nothing to save.
    public static let nothingToSaveMessage =
        "Every page in the queue is skipped. Keep a page, or turn off Skip blank pages, to save."

    /// The page looks blank at `sensitivity` (false when it was not checked).
    public static func looksBlank(_ page: ScannedPage, sensitivity: BlankSensitivity) -> Bool {
        page.blank?.isBlankAt(sensitivity) == true
    }

    /// Whether saving the queue with `options` leaves the page out.
    public static func isExcluded(_ page: ScannedPage, options: DocumentOptions) -> Bool {
        switch page.inclusion {
        case .keep: return false
        case .skip: return true
        case .automatic: return options.removeBlankPages && looksBlank(page, sensitivity: options.blankSensitivity)
        }
    }

    /// The inclusion after one click on the page: the opposite of what saving would do now. A
    /// click that agrees with the setting goes back to `.automatic`, so two clicks undo one.
    public static func toggled(_ page: ScannedPage, options: DocumentOptions) -> PageInclusion {
        let excludeNow = !isExcluded(page, options: options)
        let automatic = options.removeBlankPages && looksBlank(page, sensitivity: options.blankSensitivity)
        if excludeNow == automatic { return .automatic }
        return excludeNow ? .skip : .keep
    }

    /// The pages saving the queue writes, in queue order.
    public static func pagesToSave(_ pages: [ScannedPage], options: DocumentOptions) -> [ScannedPage] {
        pages.filter { !isExcluded($0, options: options) }
    }

    /// The page strip's note on a page: "Blank, skipped" for a blank page left out, "Skipped" for
    /// another page the user left out, "Looks blank" for a blank page that will be saved; nil for
    /// other pages.
    public static func badge(_ page: ScannedPage, options: DocumentOptions) -> String? {
        let blank = looksBlank(page, sensitivity: options.blankSensitivity)
        if isExcluded(page, options: options) { return blank ? "Blank, skipped" : "Skipped" }
        return blank ? "Looks blank" : nil
    }

    /// What one click on the page does, for its button and screen readers: "Keep this page" for a
    /// left-out page, "Skip this page" for a blank-looking page that will be saved; nil when the
    /// page has no such button (it is saved and does not look blank).
    public static func toggleLabel(_ page: ScannedPage, options: DocumentOptions) -> String? {
        if isExcluded(page, options: options) { return "Keep this page" }
        return looksBlank(page, sensitivity: options.blankSensitivity) || page.inclusion != .automatic
            ? "Skip this page"
            : nil
    }

    /// "3 pages in queue", "24 pages in queue, 5 blank skipped", "4 pages in queue, 1 skipped".
    public static func queueSummary(_ pages: [ScannedPage], options: DocumentOptions) -> String {
        let total = pages.count
        let excluded = pages.filter { isExcluded($0, options: options) }
        let text = "\(total) page\(total == 1 ? "" : "s") in queue"
        if excluded.isEmpty { return text }
        let allBlank = excluded.allSatisfy { looksBlank($0, sensitivity: options.blankSensitivity) }
        return "\(text), \(excluded.count)\(allBlank ? " blank" : "") skipped"
    }

    /// The status after a scan's pages were queued, when some look blank: " 2 look blank and will
    /// be skipped." or " 1 looks blank." (leading space; empty when none does).
    public static func scanNote(_ added: [ScannedPage], options: DocumentOptions) -> String {
        let blank = added.filter { looksBlank($0, sensitivity: options.blankSensitivity) }.count
        guard blank > 0 else { return "" }
        let verb = blank == 1 ? "looks" : "look"
        return options.removeBlankPages
            ? " \(blank) \(verb) blank and will be skipped."
            : " \(blank) \(verb) blank."
    }
}

/// What the page strip and the status say about crop and straighten: a caption on a changed page,
/// its one-click swap with the page as scanned, and the note after a scan. Twin of C#
/// `PageCorrections`.
public enum PageCorrections {
    /// "Cropped and straightened 2.4°", "Straightened 1.5°" or "Cropped" for a changed page shown
    /// changed; "As scanned" when the user went back to the page as scanned; nil for other pages.
    public static func caption(_ page: ScannedPage) -> String? {
        guard let geometry = page.geometry else { return nil }
        return page.showsOriginal ? "As scanned" : geometry.caption
    }

    /// What one click on the page's swap button does: "Show as scanned", or back: "Show cropped and
    /// straightened", "Show straightened", "Show cropped"; nil when the page cannot swap.
    public static func toggleLabel(_ page: ScannedPage) -> String? {
        guard page.canSwapVersions, let geometry = page.geometry else { return nil }
        return page.showsOriginal ? "Show \(done(geometry))" : "Show as scanned"
    }

    /// The status after a page's versions were swapped: "Page 3 is shown as scanned. It is saved
    /// that way." or "Page 3 is cropped and straightened again."
    public static func swapNote(_ page: ScannedPage, number: Int) -> String {
        guard !page.showsOriginal, let geometry = page.geometry else {
            return "Page \(number) is shown as scanned. It is saved that way."
        }
        return "Page \(number) is \(done(geometry)) again."
    }

    /// The status after a scan's pages were queued, when crop and straighten changed some: " 2
    /// straightened." or " 3 cropped or straightened." (leading space; empty when none was).
    public static func scanNote(_ added: [ScannedPage]) -> String {
        let changed = added.compactMap { page -> String? in
            guard let geometry = page.geometry, !page.showsOriginal else { return nil }
            return done(geometry)
        }
        guard let first = changed.first else { return "" }
        let verb = Set(changed).count == 1 ? first : "cropped or straightened"
        return " \(changed.count) \(verb)."
    }

    /// "cropped and straightened", "straightened" or "cropped".
    private static func done(_ geometry: PageGeometry) -> String {
        geometry.cropped && geometry.straightened ? "cropped and straightened"
            : geometry.straightened ? "straightened"
            : "cropped"
    }
}
