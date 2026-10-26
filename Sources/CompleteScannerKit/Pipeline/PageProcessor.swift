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

/// Cuts a page taken by a camera out of its photo (`ScannedPage.capture` not yet measured, no geometry
/// yet): its real size from `CaptureScale.measure` (the capture's facts scaled to the pixels at hand,
/// `CaptureFacts.scaled(toWidth:height:)`, when the photo in memory is the one taken at another size),
/// the page made upright at that size by `PerspectiveWarp`, the resolution set to the size's and
/// recorded on the capture (`CaptureFacts.scale`), and the photo kept as the other version
/// (`ScannedPage.withGeometry`, `GeometryBasis.perspective` with the corners), the facts in that photo's
/// pixels. Other pages, corners that outline no page, and a photo whose shape is not the facts' (turned
/// without them, `CaptureFacts.describesPhoto`) stay as they are. Runs first, before the blank check. A
/// book's whole spread (`spread`) is matched against no size and keeps its pixels at
/// `CaptureScale.nominalDPI`: two facing pages have the shape of no single sheet, and a spread snapped to one
/// would be shrunk to it. Twin of C# `PerspectiveStep`.
public struct PerspectiveStep: PageStep {
    public let spread: Bool
    public var name: String { "perspective" }

    public init(spread: Bool = false) {
        self.spread = spread
    }

    public func apply(_ page: ScannedPage) -> ScannedPage {
        guard let capture = page.capture, capture.scale == nil, page.geometry == nil,
              let photo = RgbaImage(cgImage: page.image) else { return page }
        var facts: CaptureFacts = capture
        if capture.sourceWidth > 0 && capture.sourceHeight > 0
            && (capture.sourceWidth != photo.width || capture.sourceHeight != photo.height) {
            // A photo turned since its facts were taken (without them) cannot be cut out along them.
            guard capture.describesPhoto(width: photo.width, height: photo.height) else { return page }
            facts = capture.scaled(toWidth: photo.width, height: photo.height)
        }
        let quad: Quad = facts.quad
        guard quad.isConvex else { return page }
        let sizes: [CaptureSize] = spread ? [] : CaptureScale.candidates(facts.kind)
        let scale = CaptureScale.measure(quad, imageWidth: photo.width, imageHeight: photo.height,
                                         candidates: sizes, focalLength: facts.focalLength)
        guard let warped = PerspectiveWarp.warp(photo, quad: quad, width: scale.pixelWidth, height: scale.pixelHeight),
              let image = warped.makeCGImage() else { return page }
        // The facts follow the photo kept as the other version, so its corners and its pixels agree.
        var measuredFacts: CaptureFacts = facts
        measuredFacts.scale = scale
        var measured = ScannedPage(image: page.image, dpi: scale.dpi, colorMode: page.colorMode, id: page.id,
                                   createdAt: page.createdAt, fileURL: page.fileURL, fullPixelSize: page.fullPixelSize)
        measured.rotationQuarterTurns = page.rotationQuarterTurns
        measured.alternate = page.alternate
        measured = measured.copyMeta(from: page).withCapture(measuredFacts)
        let geometry = PageGeometry(cropped: true, angleDegrees: 0, basis: .perspective, quad: quad)
        return measured.withGeometry(image, geometry: geometry)
    }
}

/// Cleans up a page `PerspectiveStep` cut out of a camera's photo (`DocumentEnhancer`: the lighting evened
/// out, the paper white, the print black) in `mode`, or as a photo when the shot was of a photo print or an ID
/// card (`DocumentEnhancer.mode(_:kind:)`), and records the mode applied on its capture
/// (`CaptureFacts.enhancement`); a gray or black and white result sets the page's color mode. Once only:
/// pages cleaned up already, pages not cut out along their corners (Apple's document scanner hands its pages
/// over cleaned up and whole) and pages from scanners stay as they are; the photo kept as the other version
/// is not changed. Runs right after `PerspectiveStep`. Twin of C# `EnhanceStep`.
public struct EnhanceStep: PageStep {
    public let mode: DocumentEnhanceMode
    public var name: String { "enhance" }

    public init(mode: DocumentEnhanceMode) {
        self.mode = mode
    }

    public func apply(_ page: ScannedPage) -> ScannedPage {
        guard let capture = page.capture, capture.scale != nil, capture.enhancement == nil,
              page.geometry?.basis == .perspective,
              let photo = RgbaImage(cgImage: page.image) else { return page }
        let applied: DocumentEnhanceMode = DocumentEnhancer.mode(mode, kind: capture.kind)
        let result: DocumentEnhancement = DocumentEnhancer.enhance(photo, mode: applied)
        guard let image = result.image.makeCGImage() else { return page }
        var colorMode: ColorMode = page.colorMode
        if result.mode == .gray {
            colorMode = .grayscale
        } else if result.mode == .blackAndWhite {
            colorMode = .blackWhite
        }
        var facts: CaptureFacts = capture
        facts.enhancement = result.mode
        return page.withImage(image, colorMode: colorMode).withCapture(facts)
    }
}

/// Crops the page to the sheet and straightens it (`DocumentGeometry.correct`), keeping the page as
/// it was as the other version (`ScannedPage.withGeometry`); a page the analysis is not sure about
/// stays as it is, and so does a page from a camera or a photo (`ScannedPage.capture`,
/// `GeometryBasis.perspective`), which was cut out along its corners already and lies on no scanner
/// background. Runs after the blank check, before the adjustments. Twin of C# `GeometryStep`.
public struct GeometryStep: PageStep {
    public let crop: Bool
    public let straighten: Bool
    public var name: String { "geometry" }

    public init(crop: Bool, straighten: Bool) {
        self.crop = crop
        self.straighten = straighten
    }

    public func apply(_ page: ScannedPage) -> ScannedPage {
        if page.capture != nil || page.geometry?.basis == .perspective { return page }
        guard let pixels = RgbaImage(cgImage: page.image),
              let corrected = DocumentGeometry.correct(pixels, dpi: page.dpi, crop: crop, straighten: straighten),
              let image = corrected.image.makeCGImage() else { return page }
        return page.withGeometry(image, geometry: corrected.geometry)
    }
}

/// Softens the shadow along the spine on a page cut from a spread (`SpineShadow.soften`), keeping the page
/// as scanned as the other version (`ScannedPage.withSpineShadow`): the edge along the spine is the edge of
/// the cut, turned by the book's rotation (`rotationQuarterTurns`, the turn every page of the spread was
/// given before the steps). Pages not cut from a spread, and pages with no shadow to soften, stay as they
/// are. Runs after crop and straighten, before the separator check. Twin of C# `SpineShadowStep`.
public struct SpineShadowStep: PageStep {
    public let rotationQuarterTurns: Int
    public var name: String { "spineShadow" }

    public init(rotationQuarterTurns: Int) {
        self.rotationQuarterTurns = BookSplitter.normalizedTurns(rotationQuarterTurns)
    }

    public func apply(_ page: ScannedPage) -> ScannedPage {
        guard let edge = SpineShadow.gutterEdge(page.spread, rotationQuarterTurns: rotationQuarterTurns),
              let pixels = RgbaImage(cgImage: page.image),
              let softened = SpineShadow.soften(pixels, dpi: page.dpi, edge: edge),
              let image = softened.image.makeCGImage() else { return page }
        return page.withSpineShadow(image, result: softened.result)
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

/// Reads the barcodes and QR codes on the page with `reader` (`BarcodeSeparators.readPage`) and records
/// them, so the stack can be split at barcode or QR sheets and the documents named by them
/// (`DocumentSplitter`). The pixels are not changed. A page the reader fails on stays unread
/// (`ScannedPage.barcodes` nil). Runs after the separator check, before turning pages upright and the
/// adjustments. Twin of C# `BarcodeStep`.
public struct BarcodeStep: CancellablePageStep {
    public let reader: any BarcodeReader
    public var name: String { "barcode" }

    public init(reader: any BarcodeReader) {
        self.reader = reader
    }

    /// Reads the page with nothing to stop it (`ScanError.cancelled` cannot happen then).
    public func apply(_ page: ScannedPage) -> ScannedPage {
        (try? apply(page, shouldContinue: { true })) ?? page
    }

    public func apply(_ page: ScannedPage, shouldContinue: () -> Bool) throws -> ScannedPage {
        guard shouldContinue() else { throw ScanError.cancelled }
        do {
            let found = try BarcodeSeparators.readPage(page, reader: reader)
            return page.withBarcodes(found)
        } catch ScanError.cancelled {
            throw ScanError.cancelled
        } catch {
            // A reading that failed leaves the page as it was: no code is made up, none is lost.
            return page
        }
    }
}

/// Turns the page upright when its text reads clearly better another way up
/// (`OrientationDecision.check`, reading with `scorer`), recording the turn so one click undoes it
/// (`ScannedPage.turnedUpright`). Blank pages and separator sheets are not read: patch-code sheets,
/// and under `split` (the scan's document options) barcode or QR separator sheets
/// (`BarcodeSeparators.isSeparatorPage`); a page the reading is not sure about, or that takes longer
/// than `maxSeconds`, stays as it is. Runs after the separator and barcode checks, before the
/// adjustments, on the page as cropped and straightened. `clock` (seconds) is for tests. Twin of C#
/// `OrientationStep`.
public struct OrientationStep: CancellablePageStep {
    public let scorer: any OrientationScorer
    public let maxSeconds: Double
    /// The document options whose barcode or QR separator sheets are not read; nil: none are known.
    public let split: DocumentOptions?
    private let clock: () -> Double
    public var name: String { "orientation" }

    public init(scorer: any OrientationScorer, maxSeconds: Double = OrientationDecision.maxSecondsPerPage,
                clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime },
                split: DocumentOptions? = nil) {
        self.scorer = scorer
        self.maxSeconds = maxSeconds
        self.split = split
        self.clock = clock
    }

    /// Reads the page with nothing to stop it (`ScanError.cancelled` cannot happen then).
    public func apply(_ page: ScannedPage) -> ScannedPage {
        (try? apply(page, shouldContinue: { true })) ?? page
    }

    public func apply(_ page: ScannedPage, shouldContinue: () -> Bool) throws -> ScannedPage {
        if page.blank?.isBlank == true || page.patch != nil { return page }
        if let split, BarcodeSeparators.isSeparatorPage(page, options: split) { return page }
        guard let pixels = RgbaImage(cgImage: page.image) else { return page }
        let check = try OrientationDecision.check(pixels, dpi: page.dpi, scorer: scorer, maxSeconds: maxSeconds,
                                                  clock: clock, shouldContinue: shouldContinue)
        return check.verdict == .turned ? page.turnedUpright(check.quarterTurns) : page
    }
}

/// The image adjustments and the color mode (`ImagePipeline.apply`), on the page and on its other
/// version (the page as scanned, kept by crop and straighten or by softening the spine's shadow), so either
/// can be shown. A camera page `EnhanceStep` made gray or black and white in a color task (a page without
/// color) keeps that mode (`mode(for:)`); its other version, the photo, takes the task's. With
/// `adjustsAlternate` false the other version stays as it is. Twin of C# `AdjustmentStep`.
public struct AdjustmentStep: PageStep {
    public let adjustments: AdjustmentSettings
    public let colorMode: ColorMode
    /// The other version is adjusted too. False for the objects of a camera's shot, whose other version is the
    /// whole shot they share, kept as taken for Fix crop and the glare check.
    public let adjustsAlternate: Bool
    public var name: String { "adjust" }

    public init(adjustments: AdjustmentSettings, colorMode: ColorMode, adjustsAlternate: Bool = true) {
        self.adjustments = adjustments
        self.colorMode = colorMode
        self.adjustsAlternate = adjustsAlternate
    }

    /// The color mode `page` is adjusted in: the page's own when the task is color and the camera's
    /// clean-up made it gray or black and white (`CaptureFacts.enhancement`), else `colorMode`. Twin of C#
    /// `AdjustmentStep.ModeFor`.
    public func mode(for page: ScannedPage) -> ColorMode {
        guard colorMode == .color, let enhanced = page.capture?.enhancement else { return colorMode }
        if enhanced == .gray || enhanced == .blackAndWhite { return page.colorMode }
        return colorMode
    }

    public func apply(_ page: ScannedPage) -> ScannedPage {
        let pageMode: ColorMode = self.mode(for: page)
        let adjusted = page.withImage(ImagePipeline.apply(adjustments, to: page.image, colorMode: pageMode),
                                      colorMode: pageMode)
        guard adjustsAlternate, var version = page.alternate, let other = version.image else { return adjusted }
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
    /// Fronts a camera took (`DocumentSides.markCamera`): the iPhone's two-sided task. The Windows app never
    /// takes camera shots.
    case cameraFront
    /// Backs a camera took, the user having turned each sheet over: never turned for the binding
    /// (`DocumentSides.markCamera`).
    case cameraBack
}

/// The pages of one scan after processing. Twin of C# `ProcessedScan`.
public struct ProcessedScan {
    /// The pages in reading order with their sides marked and the backs turned upright, otherwise
    /// as scanned, or for a camera's page as cut out of its photo and cleaned up (`prepare`): for the
    /// preview and the history.
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
/// (document pages), crop and straighten, softening the spine's shadow, separator sheets, barcodes,
/// turning pages upright, then adjustments. `prepare` runs on each arranged page before the steps and
/// before it is cut: a camera's page or spread is cut out of its photo first (`forCapture`).
/// Twin of C# `PageProcessor`.
public struct PageProcessor {
    public let steps: [any PageStep]
    public let arrangement: ScanArrangement
    public let binding: DuplexBinding
    /// How the pages of each spread are turned and ordered; nil when spreads are not split.
    public let book: BookSplitOptions?
    /// The steps each arranged page goes through before the others, and before a spread is cut: a camera's
    /// page or spread is cut out of its photo here, so the preview and the history show it, not the
    /// photo; none for a scan.
    public let prepare: [any PageStep]

    public init(steps: [any PageStep], arrangement: ScanArrangement = .asScanned, binding: DuplexBinding = .longEdge,
                book: BookSplitOptions? = nil, prepare: [any PageStep] = []) {
        self.steps = steps
        self.arrangement = arrangement
        self.binding = binding
        self.book = book
        self.prepare = prepare
    }

    /// The steps for a scan made with `settings`: the blank-page check for pages collected in the
    /// document queue (whether or not blank pages are left out, so the page strip can flag them),
    /// crop and straighten when asked for those pages, softening the spine's shadow when asked for on split
    /// spreads (`softensSpineShadow`), the separator-sheet check for those pages
    /// (whether or not the stack is split, so a split chosen later finds them), reading their barcodes
    /// when the stack is split at barcode or QR sheets (`readsBarcodes`) and `barcodes` can read them,
    /// turning those pages upright when asked for and `scorer` can read text, then the adjustments
    /// unless they change nothing. Facing pages are split before the steps when asked for those pages
    /// (`splitsFacingPages`), so each page is checked, straightened and turned on its own.
    public static func forScan(_ settings: ScanSettings, arrangement: ScanArrangement = .asScanned,
                               scorer: (any OrientationScorer)? = nil,
                               barcodes: (any BarcodeReader)? = nil) -> PageProcessor {
        var steps: [any PageStep] = []
        if checksBlankPages(settings) {
            steps.append(BlankDetectionStep(options: BlankPageOptions(sensitivity: settings.document.blankSensitivity)))
        }
        if correctsGeometry(settings) {
            steps.append(GeometryStep(crop: settings.document.autoCrop, straighten: settings.document.autoStraighten))
        }
        if softensSpineShadow(settings) {
            steps.append(SpineShadowStep(rotationQuarterTurns: BookSplitOptions.of(settings).rotationQuarterTurns))
        }
        if checksBlankPages(settings) {
            steps.append(SeparatorStep())
        }
        if readsBarcodes(settings), let barcodes, barcodes.isAvailable {
            steps.append(BarcodeStep(reader: barcodes))
        }
        if turnsPagesUpright(settings), let scorer, scorer.isAvailable {
            steps.append(OrientationStep(scorer: scorer, split: settings.document))
        }
        if !(settings.adjustments.isIdentity && settings.colorMode == .color) {
            steps.append(AdjustmentStep(adjustments: settings.adjustments, colorMode: settings.colorMode))
        }
        return PageProcessor(steps: steps, arrangement: arrangement, binding: settings.backBinding,
                             book: splitsFacingPages(settings) ? BookSplitOptions.of(settings) : nil)
    }

    /// The steps for pages made from imported photos of documents (`PhotoImport`), which always go to
    /// the queue: the blank-page check, the separator-sheet check, reading barcodes when the stack is
    /// split at barcode or QR sheets and `barcodes` can read them, turning pages upright when asked for
    /// and `scorer` can read text, then the adjustments unless they change nothing. Crop and
    /// straighten, the spine's shadow and splitting facing pages are left out: the page was cut out of
    /// the photo along its corners already, and the photo as it was is the page's other version. Twin
    /// of C# `PageProcessor.ForPhotoImport`.
    public static func forPhotoImport(_ settings: ScanSettings, scorer: (any OrientationScorer)? = nil,
                                      barcodes: (any BarcodeReader)? = nil) -> PageProcessor {
        var steps: [any PageStep] = [
            BlankDetectionStep(options: BlankPageOptions(sensitivity: settings.document.blankSensitivity)),
            SeparatorStep(),
        ]
        if settings.document.splitMode == .barcode, let barcodes, barcodes.isAvailable {
            steps.append(BarcodeStep(reader: barcodes))
        }
        if settings.document.autoRotate, let scorer, scorer.isAvailable {
            steps.append(OrientationStep(scorer: scorer, split: settings.document))
        }
        if !(settings.adjustments.isIdentity && settings.colorMode == .color) {
            steps.append(AdjustmentStep(adjustments: settings.adjustments, colorMode: settings.colorMode))
        }
        return PageProcessor(steps: steps)
    }

    /// The steps for pages taken by a camera (`ScannedPage.capture`), which go to the queue like imported
    /// photos: `PerspectiveStep` cuts each page out of its photo at its real size, `EnhanceStep` cleans it up
    /// in the task's mode (`DocumentEnhancer.mode(for:)`), both in `prepare`, then the steps of
    /// `forPhotoImport` for pages that go to the queue. The objects of the other tasks (photos, receipts, an
    /// ID card: `CaptureObjects`) get only the adjustments after that, unless they change nothing, and not on the shot kept as their other
    /// version: no blank-page or separator check, no barcodes, and no text recognition to turn them upright,
    /// so an ID card is never read. A book's spread taken whole (`splitsCameraSpreads`) is cut out of its photo
    /// at its own pixels (`PerspectiveStep.spread`) and cleaned up before it is cut at its spine;
    /// its pages then get the spine's softening when
    /// asked for, between the blank-page and separator checks as on a scan. `arrangement` marks the sides of
    /// the iPhone's two-sided pages (`ScanArrangement.cameraFront`, `.cameraBack`). Twin of C#
    /// `PageProcessor.ForCapture`.
    public static func forCapture(_ settings: ScanSettings, scorer: (any OrientationScorer)? = nil,
                                  barcodes: (any BarcodeReader)? = nil,
                                  arrangement: ScanArrangement = .asScanned) -> PageProcessor {
        let spreads: Bool = splitsCameraSpreads(settings)
        let cut: [any PageStep] = [PerspectiveStep(spread: spreads),
                                   EnhanceStep(mode: DocumentEnhancer.mode(for: settings))]
        var steps: [any PageStep] = []
        if TaskCatalog.flow(of: settings) == .documentQueue {
            steps = forPhotoImport(settings, scorer: scorer, barcodes: barcodes).steps
            if spreads {
                if softensSpineShadow(settings) {
                    let turns: Int = BookSplitOptions.of(settings).rotationQuarterTurns
                    steps.insert(SpineShadowStep(rotationQuarterTurns: turns), at: 1)
                }
                return PageProcessor(steps: steps, arrangement: arrangement, book: BookSplitOptions.of(settings),
                                     prepare: cut)
            }
        } else if !(settings.adjustments.isIdentity && settings.colorMode == .color) {
            steps.append(AdjustmentStep(adjustments: settings.adjustments, colorMode: settings.colorMode,
                                        adjustsAlternate: false))
        }
        return PageProcessor(steps: steps, arrangement: arrangement, prepare: cut)
    }

    /// Whether a camera's shot of a book is a whole spread, cut at its spine (the iPhone's "Whole spread"):
    /// facing pages are split (`splitsFacingPages`) and the task's camera takes spreads
    /// (`TaskOptions.cameraSpreads`). Otherwise each shot is one page. Twin of C#
    /// `PageProcessor.SplitsCameraSpreads`.
    public static func splitsCameraSpreads(_ settings: ScanSettings) -> Bool {
        splitsFacingPages(settings) && settings.taskOptions.cameraSpreads
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

    /// Whether scans with these settings have their barcodes read: document pages collected in the
    /// queue, split at barcode or QR sheets. Reading takes time, so other splits don't read them;
    /// choosing this split reads the pages already queued (`AppState.readQueuedBarcodes`).
    public static func readsBarcodes(_ settings: ScanSettings) -> Bool {
        checksBlankPages(settings) && settings.document.splitMode == .barcode
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

    /// Whether the pages cut from spreads have their spine's shadow softened: asked for, while facing pages
    /// are split (`splitsFacingPages`), where the page strip shows a softened page and one click shows it as
    /// scanned.
    public static func softensSpineShadow(_ settings: ScanSettings) -> Bool {
        splitsFacingPages(settings) && settings.document.softenSpineShadow
    }

    /// Arranges the pages, splits each spread when facing pages are split (where its gutter is found,
    /// `BookSplitter.findGutter`; whole otherwise), then runs every step on every page. `shouldContinue`
    /// is asked before each page and each step, and handed to the steps that can stop part way
    /// (`CancellablePageStep`); when it says no, `ScanError.cancelled` is thrown.
    public func process(_ scanned: [ScannedPage], shouldContinue: () -> Bool = { true }) throws -> ProcessedScan {
        guard shouldContinue() else { throw ScanError.cancelled }
        var arranged: [ScannedPage]
        switch arrangement {
        case .twoSided: arranged = DocumentSides.arrangeTwoSided(scanned, binding: binding)
        case .turnedOverFronts: arranged = DocumentSides.markManual(scanned, side: .front, binding: binding)
        case .turnedOverBacks: arranged = DocumentSides.markManual(scanned, side: .back, binding: binding)
        case .cameraFront: arranged = DocumentSides.markCamera(scanned, side: .front)
        case .cameraBack: arranged = DocumentSides.markCamera(scanned, side: .back)
        case .asScanned: arranged = scanned
        }
        if !prepare.isEmpty {
            var prepared: [ScannedPage] = []
            for page in arranged {
                guard shouldContinue() else { throw ScanError.cancelled }
                prepared.append(try Self.runAll(prepare, on: page, shouldContinue: shouldContinue))
            }
            arranged = prepared
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
    /// (`BookSplitter.totalTurns`). Each page records the spread (`SpreadPart`, with the spread's id,
    /// and whether it is the left or the right page, `SpreadPart.left`), keeps the side and sheet the spread
    /// was given (`side`, `sheetIndex`), where it came from and what a camera recorded (`source`, `capture`, so
    /// a page the clean-up made gray stays gray), and gets an id of its own.
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
            page.source = spread.source
            page.capture = spread.capture
            return page
        }
        guard let cut, let halves = BookSplitter.halves(spread.image, gutter: cut) else {
            let whole = try runSteps(part(spread.image, nil, nil), shouldContinue: shouldContinue)
            return [whole]
        }
        var a = try runSteps(part(halves.first, 0, cut), shouldContinue: shouldContinue)
        var b = try runSteps(part(halves.second, 1, cut), shouldContinue: shouldContinue)
        let total = BookSplitter.totalTurns(turns, a.upright, b.upright)
        let firstLeads = BookSplitter.firstPartLeads(cut.axis, quarterTurns: total, rightToLeft: options.rightToLeft)
        // The page that leads is the left one, or the right one in a book read from right to left.
        let firstIsLeft = firstLeads != options.rightToLeft
        a.spread?.left = firstIsLeft
        b.spread?.left = !firstIsLeft
        return firstLeads ? [a, b] : [b, a]
    }

    /// Every step on `page`, in order.
    private func runSteps(_ page: ScannedPage, shouldContinue: () -> Bool) throws -> ScannedPage {
        try Self.runAll(steps, on: page, shouldContinue: shouldContinue)
    }

    /// `steps` on `page`, in order.
    private static func runAll(_ steps: [any PageStep], on page: ScannedPage,
                               shouldContinue: () -> Bool) throws -> ScannedPage {
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

    /// The page strip's label: "3 pages", "24 pages · 5 blank skipped", "4 pages · 1 skipped".
    public static func queueSummary(_ pages: [ScannedPage], options: DocumentOptions) -> String {
        let total = pages.count
        let excluded = pages.filter { isExcluded($0, options: options) }
        let text = "\(total) page\(total == 1 ? "" : "s")"
        if excluded.isEmpty { return text }
        let allBlank = excluded.allSatisfy { looksBlank($0, sensitivity: options.blankSensitivity) }
        return "\(text) \u{00B7} \(excluded.count)\(allBlank ? " blank" : "") skipped"
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

/// What the page strip and the status say about crop and straighten and the softened spine shadow: a
/// caption on a changed page, its one-click swap with the page as scanned, and the note after a scan.
/// Twin of C# `PageCorrections`.
public enum PageCorrections {
    /// "Cropped and straightened 2.4°", "Straightened 1.5°" or "Cropped" for a changed page shown
    /// changed, followed by ", spine shadow softened" ("Spine shadow softened" alone) when the shadow was
    /// softened; "As scanned" when the user went back to the page as scanned; "Corrected from photo"
    /// and "As photographed" for a page taken from a photo; nil for other pages.
    public static func caption(_ page: ScannedPage) -> String? {
        if page.geometry == nil && page.spineShadow == nil { return nil }
        if page.showsOriginal { return fromPhoto(page) ? PhotoImport.originalCaption : "As scanned" }
        guard let geometry = page.geometry else { return "Spine shadow softened" }
        return page.spineShadow == nil ? geometry.caption : "\(geometry.caption), spine shadow softened"
    }

    /// What one click on the page's swap button does: "Show as scanned", or back: "Show cropped and
    /// straightened", "Show straightened", "Show cropped", "Show with the spine shadow softened", "Show
    /// straightened, with the spine shadow softened"; "Show as photographed" and "Show corrected" for a
    /// page taken from a photo; nil when the page cannot swap.
    public static func toggleLabel(_ page: ScannedPage) -> String? {
        guard page.canSwapVersions else { return nil }
        if !page.showsOriginal { return fromPhoto(page) ? "Show as photographed" : "Show as scanned" }
        guard let geometry = page.geometry else { return "Show with the spine shadow softened" }
        return page.spineShadow == nil ? "Show \(done(geometry))" : "Show \(done(geometry)), with the spine shadow softened"
    }

    /// The status after a page's versions were swapped: "Page 3 is shown as scanned. It is saved that
    /// way.", "Page 3 is cropped and straightened again.", "Page 3 is shown with the spine shadow softened
    /// again." or "Page 3 is straightened again, with the spine shadow softened."; for a page taken from
    /// a photo "Page 3 is shown as photographed. It is saved that way." or "Page 3 is corrected again."
    public static func swapNote(_ page: ScannedPage, number: Int) -> String {
        if page.showsOriginal || (page.geometry == nil && page.spineShadow == nil) {
            return fromPhoto(page)
                ? "Page \(number) is shown as photographed. It is saved that way."
                : "Page \(number) is shown as scanned. It is saved that way."
        }
        guard let geometry = page.geometry else { return "Page \(number) is shown with the spine shadow softened again." }
        return page.spineShadow == nil
            ? "Page \(number) is \(done(geometry)) again."
            : "Page \(number) is \(done(geometry)) again, with the spine shadow softened."
    }

    /// The status after a scan's pages were queued, when crop and straighten changed some: " 2
    /// straightened." or " 3 cropped or straightened."; then, when the spine's shadow was softened on
    /// some, " Spine shadow softened on 2 pages." (leading space; empty when nothing was changed).
    /// Pages taken from photos are left out: the import's own status tells about them
    /// (`PhotoImport.addedMessage`).
    public static func scanNote(_ added: [ScannedPage]) -> String {
        let changed = added.compactMap { page -> String? in
            guard let geometry = page.geometry, geometry.basis != .perspective, !page.showsOriginal else { return nil }
            return done(geometry)
        }
        var note = ""
        if let first = changed.first {
            let verb = Set(changed).count == 1 ? first : "cropped or straightened"
            note = " \(changed.count) \(verb)."
        }
        let softened = added.filter { $0.spineShadow != nil && !$0.showsOriginal }.count
        if softened > 0 { note += " Spine shadow softened on \(softened) page\(softened == 1 ? "" : "s")." }
        return note
    }

    /// The page was taken from a photo along its corners: its other version is the photo.
    private static func fromPhoto(_ page: ScannedPage) -> Bool { page.geometry?.basis == .perspective }

    /// "cropped and straightened", "straightened" or "cropped"; "corrected" for a page taken from a photo.
    private static func done(_ geometry: PageGeometry) -> String {
        geometry.basis == .perspective ? "corrected"
            : geometry.cropped && geometry.straightened ? "cropped and straightened"
            : geometry.straightened ? "straightened"
            : "cropped"
    }
}
