import Foundation
import CoreGraphics

// MARK: - Core enums

public enum ScanIntent: String, Codable, CaseIterable, Identifiable, Sendable {
    case document
    case photo

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .document: return "Document"
        case .photo: return "Photos"
        }
    }
}

public enum ColorMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case color
    case grayscale
    case blackWhite

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .color: return "Color"
        case .grayscale: return "Grayscale"
        case .blackWhite: return "Black & White"
        }
    }
}

public enum ScanSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case flatbed
    case documentFeeder

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .flatbed: return "Flatbed"
        case .documentFeeder: return "Document Feeder (ADF)"
        }
    }
}

public enum OutputFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case pdf, jpeg, png, tiff

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .pdf: return "PDF"
        case .jpeg: return "JPEG"
        case .png: return "PNG"
        case .tiff: return "TIFF"
        }
    }
    public var fileExtension: String {
        switch self {
        case .pdf: return "pdf"
        case .jpeg: return "jpg"
        case .png: return "png"
        case .tiff: return "tiff"
        }
    }
}

/// How small saved PDFs are made (see `PDFImageEncoding`). `standard` comes first because it is
/// the default for everyone, including settings files written before the setting existed, and
/// the fallback for a size a newer version adds: it neither bloats a file nor drops quality
/// much. The inspector and the start screen list the sizes in `displayOrder` (largest first).
/// Twin of C# `PdfSizePreset` (`ModelLabels.Label` / `Hint`, `PdfSizePresets.DisplayOrder`).
public enum PDFSizePreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case standard
    case best
    case compact
    case smallest

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .standard: return "Standard"
        case .best: return "Best"
        case .compact: return "Compact"
        case .smallest: return "Smallest"
        }
    }

    /// One line saying what the size does, shown under the size picker.
    public var hint: String {
        switch self {
        case .standard: return "Up to 300 dpi, gray pages saved in gray. For most documents."
        case .best: return "Full resolution, high quality. Largest files."
        case .compact: return "Up to 200 dpi, more compression. For email and uploads."
        case .smallest: return "Up to 150 dpi, most compression. For strict size limits."
        }
    }

    /// The sizes as the inspector lists them: largest file first.
    public static let displayOrder: [PDFSizePreset] = [.best, .standard, .compact, .smallest]
}

/// Which sides of each sheet a feeder scan captures (`ScanSettings.duplex`). Only the document
/// feeder scans two-sided; on the flatbed the setting is ignored. See `DocumentSides`. Twin of C#
/// `DuplexMode` (`ModelLabels.Label` / `Hint`).
public enum DuplexMode: String, Codable, CaseIterable, Identifiable, Sendable {
    /// The front of each sheet only.
    case off
    /// Both sides in one pass, by a feeder that can.
    case both
    /// Both sides by hand: the fronts are scanned, the stack is turned over, then the backs are scanned.
    case manual

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .off: return "One side"
        case .both: return "Both sides"
        case .manual: return "Both sides, turned by hand"
        }
    }

    /// One line saying what the choice does, shown under the sides picker.
    public var hint: String {
        switch self {
        case .off: return "Only the front of each sheet is scanned."
        case .both: return "The feeder scans both sides of every sheet in one pass."
        case .manual: return "Scan the fronts, turn the stack over, then scan the backs. The pages are put in order."
        }
    }
}

/// Along which edge the back sides are turned (`ScanSettings.backBinding`): the long edge, like
/// the pages of a book (backs come out upright), or the short edge, like a wall calendar (backs
/// come out upside down and are turned upright). Twin of C# `DuplexBinding`.
public enum DuplexBinding: String, Codable, CaseIterable, Identifiable, Sendable {
    case longEdge
    case shortEdge

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .longEdge: return "Long edge (like a book)"
        case .shortEdge: return "Short edge (like a calendar)"
        }
    }
}

/// How much may be on a page for it to count as blank (`DocumentOptions.blankSensitivity`,
/// `BlankPageDetector`): `.low` only (next to) empty pages, `.high` also pages with a few marks.
/// `.medium` comes first: it is the default and the fallback for a level a newer version adds.
/// Shown in `displayOrder`. Twin of C# `BlankSensitivity` (`ModelLabels.Label` / `Hint`,
/// `BlankSensitivities.DisplayOrder`).
public enum BlankSensitivity: String, Codable, CaseIterable, Identifiable, Sendable {
    case medium
    case low
    case high

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }

    /// One line saying what counts as blank at that level, shown under the picker.
    public var hint: String {
        switch self {
        case .low: return "Only pages with nothing on them count as blank."
        case .medium: return "Empty pages count as blank, also with dust, show-through or a lone page number."
        case .high: return "Pages with a few small marks count as blank too. Check the flagged pages before saving."
        }
    }

    /// The levels as the inspector lists them: least first.
    public static let displayOrder: [BlankSensitivity] = [.low, .medium, .high]
}

/// The user's say over whether a queued page is saved (`ScannedPage.inclusion`): `.automatic`
/// follows the blank-page setting (`PageFilter.isExcluded`); `.keep` and `.skip` are one click on
/// the page, whatever the setting. Not stored in settings files. Twin of C# `PageInclusion`.
public enum PageInclusion: String, Sendable {
    case automatic
    case keep
    case skip
}

// MARK: - Settings

public struct AdjustmentSettings: Codable, Equatable, Sendable {
    public var autoEnhance: Bool = false
    /// -1 ... 1, neutral 0
    public var brightness: Double = 0.0
    /// 0.25 ... 4, neutral 1
    public var contrast: Double = 1.0
    /// 0 ... 2, neutral 1
    public var saturation: Double = 1.0
    /// -2 ... 2, neutral 0; positive sharpens, negative softens (Gaussian blur)
    public var sharpness: Double = 0.0
    /// Reduce moiré from scanning printed material.
    public var descreen: Bool = false
    /// Boost faded colors of old photos.
    public var restoreFadedColors: Bool = false
    /// 0 ... 1 luminance threshold used for ColorMode.blackWhite conversion.
    public var blackWhiteThreshold: Double = 0.5

    public init() {}

    public var isIdentity: Bool {
        !autoEnhance && brightness == 0 && contrast == 1 && saturation == 1
            && sharpness == 0 && !descreen && !restoreFadedColors
    }

    /// Same keys the synthesized implementation used; `encode(to:)` stays synthesized.
    private enum CodingKeys: String, CodingKey {
        case autoEnhance, brightness, contrast, saturation, sharpness
        case descreen, restoreFadedColors, blackWhiteThreshold
    }
}

extension AdjustmentSettings {
    /// Tolerant decoding: a missing or undecodable key keeps the property's default.
    public init(from decoder: Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        autoEnhance = container.decodeLenient(forKey: .autoEnhance, default: autoEnhance)
        brightness = container.decodeLenient(forKey: .brightness, default: brightness)
        contrast = container.decodeLenient(forKey: .contrast, default: contrast)
        saturation = container.decodeLenient(forKey: .saturation, default: saturation)
        sharpness = container.decodeLenient(forKey: .sharpness, default: sharpness)
        descreen = container.decodeLenient(forKey: .descreen, default: descreen)
        restoreFadedColors = container.decodeLenient(forKey: .restoreFadedColors, default: restoreFadedColors)
        blackWhiteThreshold = container.decodeLenient(forKey: .blackWhiteThreshold, default: blackWhiteThreshold)
    }
}

/// Settings for the saved files themselves, kept together as `ScanSettings.output` (the "output"
/// object in settings files): the PDF size and the after-save action. Later output features add
/// their fields here. Twin of C# `OutputOptions`.
public struct OutputOptions: Codable, Equatable, Sendable {
    /// How small saved PDFs are made. Settings without it get `.standard`.
    public var pdfSize: PDFSizePreset = .standard
    /// What happens on its own after a save (see `SaveActions.plan`). Settings without it, or
    /// with an action this version does not know, get `.none`.
    public var afterSave: AfterSaveAction = AfterSaveAction.none

    public init() {}

    /// `encode(to:)` stays synthesized.
    private enum CodingKeys: String, CodingKey {
        case pdfSize
        case afterSave
    }
}

extension OutputOptions {
    /// Tolerant decoding: a missing or undecodable key keeps the property's default.
    public init(from decoder: Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pdfSize = container.decodeLenient(forKey: .pdfSize, default: pdfSize)
        afterSave = container.decodeLenient(forKey: .afterSave, default: afterSave)
    }
}

/// Settings for the clean-up of document pages, kept together as `ScanSettings.document` (the
/// "document" object in settings files). Later page features (crop, straighten, split) add their
/// fields here; every one is off by default. Twin of C# `DocumentOptions`.
public struct DocumentOptions: Codable, Equatable, Sendable {
    /// Pages that look blank are left out when the queue is saved. They are only flagged in the
    /// page strip, where one click keeps one; nothing is deleted while they are queued.
    public var removeBlankPages: Bool = false
    /// How much may be on a page for it to count as blank.
    public var blankSensitivity: BlankSensitivity = .medium

    public init() {}

    /// `encode(to:)` stays synthesized.
    private enum CodingKeys: String, CodingKey {
        case removeBlankPages
        case blankSensitivity
    }
}

extension DocumentOptions {
    /// Tolerant decoding: a missing or undecodable key keeps the property's default.
    public init(from decoder: Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        removeBlankPages = container.decodeLenient(forKey: .removeBlankPages, default: removeBlankPages)
        blankSensitivity = container.decodeLenient(forKey: .blankSensitivity, default: blankSensitivity)
    }
}

public struct ScanSettings: Codable, Equatable, Sendable {
    public var intent: ScanIntent = .document
    public var source: ScanSource = .flatbed
    public var resolution: Int = 300
    public var colorMode: ColorMode = .color
    public var format: OutputFormat = .pdf
    /// 0 ... 1
    public var jpegQuality: Double = 0.9
    public var destinationPath: String = ScanSettings.defaultDestinationPath
    public var namingTemplate: String = "Scan {date} {counter}"

    // Photo mode
    public var photoAutoSplit: Bool = true
    public var photoAutoDeskew: Bool = true
    /// Smallest photo side considered a real photo (inches).
    public var photoMinSideInches: Double = 1.2
    /// Pixels (at scan resolution) shaved off each detected photo edge to remove background slivers.
    public var photoCropInsetPixels: Int = 0

    // Document / PDF mode
    /// true: scans accumulate as pages and are saved together with "Save PDF".
    /// false: every scan is written to disk immediately as its own file.
    public var documentMultiPage: Bool = true
    /// Run OCR and embed an invisible text layer in saved PDFs.
    public var pdfSearchable: Bool = true
    public var ocrLanguages: [String] = ["en-US"]

    public var adjustments: AdjustmentSettings = AdjustmentSettings()

    /// The task these settings were set up for (`ScanTask.rawValue`), or nil for settings
    /// chosen by hand. Kept as text: a task this version does not know (written by a newer
    /// one) reads as no `task` but is written back unchanged. Left out of the file when nil.
    public var taskId: String?

    /// Settings for the saved files (the PDF size, the after-save action).
    public var output: OutputOptions = OutputOptions()

    /// Which sides of each sheet a feeder scan captures. Read by the backends (two-sided feeder
    /// scans) and the app (turning the stack over by hand); ignored on the flatbed. Settings
    /// without it scan one side.
    public var duplex: DuplexMode = .off

    /// Along which edge the back sides are turned; the backs of short-edge sheets are turned upright.
    public var backBinding: DuplexBinding = .longEdge

    /// The size of the paper scanned (`PaperSizes`): the area of the glass scanned when no area
    /// is selected, or the sheet the feeder is asked for. Automatic scans the whole glass, or the
    /// feeder's own sheet size.
    public var paperSize: PaperSize = .auto

    /// Clean-up of document pages (blank pages).
    public var document: DocumentOptions = DocumentOptions()

    public init() {}

    /// The task of `taskId`, when this version knows it.
    public var task: ScanTask? { ScanTask.tryParse(taskId) }

    public static var defaultDestinationPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent("Documents/CompleteScanner")
    }

    /// Same keys the synthesized implementation used; `encode(to:)` stays synthesized.
    private enum CodingKeys: String, CodingKey {
        case intent, source, resolution, colorMode, format, jpegQuality, destinationPath, namingTemplate
        case photoAutoSplit, photoAutoDeskew, photoMinSideInches, photoCropInsetPixels
        case documentMultiPage, pdfSearchable, ocrLanguages
        case adjustments
        case taskId
        case output
        case duplex, backBinding, paperSize
        case document
    }
}

extension ScanSettings {
    /// Tolerant decoding: a missing or undecodable key (including an enum value written by a
    /// newer version, or a corrupt nested `adjustments` object) keeps the property's default.
    public init(from decoder: Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        intent = container.decodeLenient(forKey: .intent, default: intent)
        source = container.decodeLenient(forKey: .source, default: source)
        resolution = container.decodeLenient(forKey: .resolution, default: resolution)
        colorMode = container.decodeLenient(forKey: .colorMode, default: colorMode)
        format = container.decodeLenient(forKey: .format, default: format)
        jpegQuality = container.decodeLenient(forKey: .jpegQuality, default: jpegQuality)
        destinationPath = container.decodeLenient(forKey: .destinationPath, default: destinationPath)
        namingTemplate = container.decodeLenient(forKey: .namingTemplate, default: namingTemplate)
        photoAutoSplit = container.decodeLenient(forKey: .photoAutoSplit, default: photoAutoSplit)
        photoAutoDeskew = container.decodeLenient(forKey: .photoAutoDeskew, default: photoAutoDeskew)
        photoMinSideInches = container.decodeLenient(forKey: .photoMinSideInches, default: photoMinSideInches)
        photoCropInsetPixels = container.decodeLenient(forKey: .photoCropInsetPixels, default: photoCropInsetPixels)
        documentMultiPage = container.decodeLenient(forKey: .documentMultiPage, default: documentMultiPage)
        pdfSearchable = container.decodeLenient(forKey: .pdfSearchable, default: pdfSearchable)
        ocrLanguages = container.decodeLenient(forKey: .ocrLanguages, default: ocrLanguages)
        adjustments = container.decodeLenient(forKey: .adjustments, default: adjustments)
        taskId = container.decodeLenient(forKey: .taskId, default: taskId)
        output = container.decodeLenient(forKey: .output, default: output)
        duplex = container.decodeLenient(forKey: .duplex, default: duplex)
        backBinding = container.decodeLenient(forKey: .backBinding, default: backBinding)
        paperSize = container.decodeLenient(forKey: .paperSize, default: paperSize)
        document = container.decodeLenient(forKey: .document, default: document)
    }
}

// MARK: - Runtime objects

public struct ScannedPage: Identifiable {
    public let id: UUID
    /// Page pixels. When `fileURL` is set this is a lower-resolution preview;
    /// the full-resolution original lives in the file.
    public let image: CGImage
    public let dpi: Int
    public let colorMode: ColorMode
    public let createdAt: Date
    /// Full-resolution spill file (TIFF) backing this page when it was offloaded
    /// from memory. Consumers that need full pixels (PDFBuilder) reload from it.
    public let fileURL: URL?
    /// Pixel dimensions of the full-resolution original (recorded when the page
    /// is spooled), so physical page size stays correct even if only the preview
    /// is available.
    public let fullPixelSize: CGSize?
    /// User-requested rotation applied at save time (0...3 quarter turns clockwise).
    /// `image` already shows the rotation; the full-resolution original (spool file)
    /// stays unrotated until PDFBuilder applies it.
    public var rotationQuarterTurns: Int = 0
    /// Which side of its sheet this page is, for two-sided scans; nil for one-sided ones.
    public var side: PageSide?
    /// The sheet of the stack this page belongs to (0 = first), for two-sided scans; nil otherwise.
    public var sheetIndex: Int?
    /// What the blank-page check found on the page as scanned (`BlankPageDetector`), or nil when it
    /// was not checked (photos, pages scanned one file at a time).
    public var blank: BlankPageResult?
    /// Whether the user keeps or skips this page whatever the blank-page setting.
    public var inclusion: PageInclusion = .automatic

    public init(image: CGImage, dpi: Int, colorMode: ColorMode, id: UUID = UUID(),
                createdAt: Date = Date(), fileURL: URL? = nil, fullPixelSize: CGSize? = nil) {
        self.id = id
        self.image = image
        self.dpi = dpi
        self.colorMode = colorMode
        self.createdAt = createdAt
        self.fileURL = fileURL
        self.fullPixelSize = fullPixelSize
    }

    /// The same page with other pixels: adjusted, or a preview backed by a spool file. The id,
    /// resolution, creation time, rotation and what the scan recorded about the page
    /// (`copyMeta(from:)`) are kept; the color mode is `colorMode` when given; the spool file
    /// and full size are the ones given (none by default), since the old ones belong to the old
    /// pixels. Every place that rebuilds a page goes through this, so new page facts survive.
    /// Twin of C# `ScannedPage.WithImage`.
    public func withImage(_ image: CGImage, colorMode: ColorMode? = nil, fileURL: URL? = nil,
                          fullPixelSize: CGSize? = nil) -> ScannedPage {
        var page = ScannedPage(image: image, dpi: dpi, colorMode: colorMode ?? self.colorMode, id: id,
                               createdAt: createdAt, fileURL: fileURL, fullPixelSize: fullPixelSize)
        page.rotationQuarterTurns = rotationQuarterTurns
        return page.copyMeta(from: self)
    }

    /// This page carrying what the scan recorded about `source`: its side and sheet, the
    /// blank-page check and the user's keep or skip. Pixels, id, file and rotation stay this
    /// page's. Twin of C# `ScannedPage.CopyMeta`.
    public func copyMeta(from source: ScannedPage) -> ScannedPage {
        var page = self
        page.side = source.side
        page.sheetIndex = source.sheetIndex
        page.blank = source.blank
        page.inclusion = source.inclusion
        return page
    }

    /// This page with what the blank-page check found (nil: not checked).
    public func withBlank(_ blank: BlankPageResult?) -> ScannedPage {
        var page = self
        page.blank = blank
        return page
    }

    /// This page kept, skipped, or following the blank-page setting again.
    public func withInclusion(_ inclusion: PageInclusion) -> ScannedPage {
        var page = self
        page.inclusion = inclusion
        return page
    }

    /// This page as `side` of sheet `sheetIndex` (both nil: not two-sided).
    public func withSide(_ side: PageSide?, sheetIndex: Int?) -> ScannedPage {
        var page = self
        page.side = side
        page.sheetIndex = sheetIndex
        return page
    }
}

/// A rotated rectangle found on a scanned flatbed image.
///
/// Coordinate convention: source-image pixels, origin at TOP-LEFT, x right, y down.
/// `angleDegrees` is the rotation of the rectangle; a positive angle appears as a
/// CLOCKWISE rotation on screen. Normalized to (-45, 45]. A point (x, y) in the
/// rectangle's local frame maps to the image as:
///   ix = center.x + x*cos(a) - y*sin(a)
///   iy = center.y + x*sin(a) + y*cos(a)
public struct DetectedPhotoRegion: Identifiable, Equatable {
    public let id: UUID
    public var center: CGPoint
    public var size: CGSize
    public var angleDegrees: Double

    public init(center: CGPoint, size: CGSize, angleDegrees: Double, id: UUID = UUID()) {
        self.id = id
        self.center = center
        self.size = size
        self.angleDegrees = angleDegrees
    }

    /// Corners in source-image pixel coordinates (top-left origin), order: TL, TR, BR, BL of the local frame.
    public var corners: [CGPoint] {
        let a = angleDegrees * .pi / 180
        let (c, s) = (cos(a), sin(a))
        let (hw, hh) = (size.width / 2, size.height / 2)
        return [CGPoint(x: -hw, y: -hh), CGPoint(x: hw, y: -hh), CGPoint(x: hw, y: hh), CGPoint(x: -hw, y: hh)].map {
            CGPoint(x: center.x + $0.x * c - $0.y * s, y: center.y + $0.x * s + $0.y * c)
        }
    }

    /// Axis-aligned bounding box of `corners`.
    public var boundingBox: CGRect {
        let pts = corners
        let xs = pts.map(\.x), ys = pts.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }
}

public struct DetectedPhoto: Identifiable {
    public let id: UUID
    public let region: DetectedPhotoRegion
    public let image: CGImage
    public let dpi: Int
    /// The scanned page this photo was extracted from — a multi-sheet (ADF) photo scan
    /// produces photos from several pages, and manual re-cropping must use the right one.
    public let sourcePageID: UUID?
    public var included: Bool = true
    /// Extra user-requested rotation applied at save time (0...3 quarter turns clockwise).
    public var rotationQuarterTurns: Int = 0

    public init(region: DetectedPhotoRegion, image: CGImage, dpi: Int, id: UUID = UUID(),
                sourcePageID: UUID? = nil) {
        self.id = id
        self.region = region
        self.image = image
        self.dpi = dpi
        self.sourcePageID = sourcePageID
    }
}

/// One entry in the session's scan history ("Scans" tab): a small preview of every scan
/// as it happened, newest first.
public struct ScanHistoryEntry: Identifiable {
    public let id: UUID
    public let date: Date
    public let intent: ScanIntent
    public let dpi: Int
    /// Downsampled preview (≤ ~700 px long side) — history never retains full pixels.
    public let thumbnail: CGImage
    /// True pixel dimensions of the original scan.
    public let pixelSize: CGSize

    public init(date: Date, intent: ScanIntent, dpi: Int, thumbnail: CGImage,
                pixelSize: CGSize, id: UUID = UUID()) {
        self.id = id
        self.date = date
        self.intent = intent
        self.dpi = dpi
        self.thumbnail = thumbnail
        self.pixelSize = pixelSize
    }
}

// MARK: - Devices

/// One device as one backend lists it. The same physical scanner can appear once per
/// backend or connection; `DeviceMerge` groups those entries into one row.
public struct ScannerInfo: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    /// "USB", "Network", "Shared", "Demo", ...
    public let transport: String
    public let isDemo: Bool
    /// The backend listing the device: "wia", "twain", "escl", "ic" (ImageCaptureCore) or
    /// "mock"; empty when unknown. Together with `transport` it names the connection.
    public let backend: String
    /// Manufacturer and model as the device reports them, when known; used to match entries.
    public let model: String?
    /// An identifier of the physical device (eSCL UUID, serial number), when known. Two
    /// entries that both have one are the same scanner only when the identifiers match.
    public let hardwareID: String?

    public init(id: String, name: String, transport: String, isDemo: Bool = false,
                backend: String = "", model: String? = nil, hardwareID: String? = nil) {
        self.id = id
        self.name = name
        self.transport = transport
        self.isDemo = isDemo
        self.backend = backend
        self.model = model
        self.hardwareID = hardwareID
    }
}

public struct ScannerCapabilities: Equatable, Sendable {
    public var supportedResolutions: [Int]
    public var sources: [ScanSource]
    /// Physical flatbed size in inches.
    public var flatbedSizeInches: CGSize
    public var supportsOverview: Bool
    /// Largest sheet the document feeder takes, in inches; nil when the device has no feeder
    /// or does not report it.
    public var feederSizeInches: CGSize?
    /// The document feeder can scan both sides in one pass. Without it, two-sided scanning is
    /// done by turning the stack over by hand (`DocumentSides.effective`). ImageCaptureCore
    /// reports it only once the feeder has been selected (`ScannerSession.feederSupportsDuplex`).
    public var supportsDuplex: Bool

    public init(supportedResolutions: [Int] = [75, 150, 200, 300, 600, 1200],
                sources: [ScanSource] = [.flatbed],
                flatbedSizeInches: CGSize = CGSize(width: 8.5, height: 11.7),
                supportsOverview: Bool = true,
                feederSizeInches: CGSize? = nil,
                supportsDuplex: Bool = false) {
        self.supportedResolutions = supportedResolutions
        self.sources = sources
        self.flatbedSizeInches = flatbedSizeInches
        self.supportsOverview = supportsOverview
        self.feederSizeInches = feederSizeInches
        self.supportsDuplex = supportsDuplex
    }

    public func nearestResolution(to dpi: Int) -> Int {
        supportedResolutions.min(by: { abs($0 - dpi) < abs($1 - dpi) }) ?? dpi
    }
}

public struct ScanProgress: Equatable, Sendable {
    /// nil = indeterminate
    public var fraction: Double?
    public var message: String

    public init(fraction: Double? = nil, message: String) {
        self.fraction = fraction
        self.message = message
    }
}

// MARK: - Presets

public struct Preset: Codable, Identifiable, Equatable {
    public let id: UUID
    public var name: String
    public var settings: ScanSettings

    public init(id: UUID = UUID(), name: String, settings: ScanSettings) {
        self.id = id
        self.name = name
        self.settings = settings
    }

    /// Name given to a stored preset whose name is missing or unreadable.
    static let fallbackName = "Untitled preset"

    /// Same keys the synthesized implementation used; `encode(to:)` stays synthesized.
    private enum CodingKeys: String, CodingKey {
        case id, name, settings
    }
}

extension Preset {
    /// Tolerant decoding: a missing or undecodable key gets a default (fresh id,
    /// `fallbackName`, default settings); `settings` itself decodes tolerantly field by field.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: container.decodeLenient(forKey: .id, default: UUID()),
                  name: container.decodeLenient(forKey: .name, default: Preset.fallbackName),
                  settings: container.decodeLenient(forKey: .settings, default: ScanSettings()))
    }
}

// MARK: - Tolerant decoding

extension KeyedDecodingContainer {
    /// Decodes the value stored under `key`, or returns `fallback` when the key is missing,
    /// null, or holds something that does not decode as `T` (wrong type, an enum raw value
    /// this version does not know, a corrupt nested object). Never throws, so one bad field
    /// only resets that field instead of failing the enclosing settings object or file.
    ///
    /// Every stored property of a type persisted in a settings file decodes through this,
    /// with the property's own default as `fallback`.
    func decodeLenient<T: Decodable>(forKey key: Key, default fallback: T) -> T {
        do {
            return try decodeIfPresent(T.self, forKey: key) ?? fallback
        } catch {
            return fallback
        }
    }
}

// MARK: - Errors

public enum ScanError: LocalizedError {
    case deviceUnavailable(String)
    case sessionFailed(String)
    case scanFailed(String)
    case cancelled
    case exportFailed(String)
    case unsupported(String)
    /// A condition at the scanner the user can fix (see `ScannerProblems.describe`); the
    /// twin of C# `ScanException.ForProblem`.
    case scannerProblem(ScannerProblem)

    public var errorDescription: String? {
        switch self {
        case .deviceUnavailable(let s): return "Scanner unavailable: \(s)"
        case .sessionFailed(let s): return "Could not open a session with the scanner: \(s)"
        case .scanFailed(let s): return "Scan failed: \(s)"
        case .cancelled: return "The scan was cancelled."
        case .exportFailed(let s): return "Saving failed: \(s)"
        case .unsupported(let s): return "Unsupported: \(s)"
        case .scannerProblem(let p): return ScannerProblems.describe(p)
        }
    }

    /// The scanner condition behind this error, when the backend could tell.
    public var problem: ScannerProblem? {
        if case .scannerProblem(let p) = self { return p }
        return nil
    }
}
