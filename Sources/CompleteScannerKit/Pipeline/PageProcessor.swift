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

/// The image adjustments and the color mode (`ImagePipeline.apply`).
public struct AdjustmentStep: PageStep {
    public let adjustments: AdjustmentSettings
    public let colorMode: ColorMode
    public var name: String { "adjust" }

    public init(adjustments: AdjustmentSettings, colorMode: ColorMode) {
        self.adjustments = adjustments
        self.colorMode = colorMode
    }

    public func apply(_ page: ScannedPage) -> ScannedPage {
        page.withImage(ImagePipeline.apply(adjustments, to: page.image, colorMode: colorMode), colorMode: colorMode)
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
    /// The same pages after every step, with the facts the steps found.
    public let pages: [ScannedPage]

    /// Pages the blank-page check found blank at the sensitivity it ran with.
    public var blankCount: Int { pages.filter { $0.blank?.isBlank == true }.count }
}

/// The clean-up stage between the scanner and the page queue, the same for every scanner: the
/// pages are put in reading order with their sides (two-sided scans), then every step runs on
/// every page in order. The order of the steps is fixed: `forScan` builds them from the settings:
/// blank check (document pages), then adjustments. Later page features slot in between (crop and
/// straighten after the blank check, separator sheets after that, turning pages upright before
/// the adjustments). Twin of C# `PageProcessor`.
public struct PageProcessor {
    public let steps: [any PageStep]
    public let arrangement: ScanArrangement
    public let binding: DuplexBinding

    public init(steps: [any PageStep], arrangement: ScanArrangement = .asScanned, binding: DuplexBinding = .longEdge) {
        self.steps = steps
        self.arrangement = arrangement
        self.binding = binding
    }

    /// The steps for a scan made with `settings`: the blank-page check for pages collected in the
    /// document queue (whether or not blank pages are left out, so the page strip can flag them),
    /// then the adjustments unless they change nothing.
    public static func forScan(_ settings: ScanSettings, arrangement: ScanArrangement = .asScanned) -> PageProcessor {
        var steps: [any PageStep] = []
        if checksBlankPages(settings) {
            steps.append(BlankDetectionStep(options: BlankPageOptions(sensitivity: settings.document.blankSensitivity)))
        }
        if !(settings.adjustments.isIdentity && settings.colorMode == .color) {
            steps.append(AdjustmentStep(adjustments: settings.adjustments, colorMode: settings.colorMode))
        }
        return PageProcessor(steps: steps, arrangement: arrangement, binding: settings.backBinding)
    }

    /// Whether scans with these settings get the blank-page check: document pages collected in the
    /// queue, where a flagged page can be seen and kept before saving. Pages saved as soon as they
    /// are scanned are never checked, so none is ever left out unseen.
    public static func checksBlankPages(_ settings: ScanSettings) -> Bool {
        TaskCatalog.flow(of: settings) == .documentQueue && settings.documentMultiPage
    }

    /// Arranges the pages, then runs every step on every page. `shouldContinue` is asked before
    /// each page and each step; when it says no, `ScanError.cancelled` is thrown.
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
            var current = page
            for step in steps {
                guard shouldContinue() else { throw ScanError.cancelled }
                current = step.apply(current)
            }
            pages.append(current)
        }
        return ProcessedScan(arranged: arranged, pages: pages)
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
