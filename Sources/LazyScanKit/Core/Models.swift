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
        case .documentFeeder: return "Document feeder"
        }
    }

    /// The source's tooltip: what the plain name stands for.
    public var hint: String {
        switch self {
        case .flatbed: return "The scanner's glass"
        case .documentFeeder: return "Automatic document feeder (ADF)"
        }
    }
}

/// What a save writes. `.text` and `.word` hold the recognized text of the pages instead of their
/// pictures (`TextExport`, `DocxWriter`); which formats a mode offers and what each save does with
/// a format are below. Twin of C# `OutputFormat` and `OutputFormats`.
public enum OutputFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case pdf, jpeg, png, tiff, text, word

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .pdf: return "PDF"
        case .jpeg: return "JPEG"
        case .png: return "PNG"
        case .tiff: return "TIFF"
        case .text: return "Text (.txt)"
        case .word: return "Word (.docx)"
        }
    }
    public var fileExtension: String {
        switch self {
        case .pdf: return "pdf"
        case .jpeg: return "jpg"
        case .png: return "png"
        case .tiff: return "tiff"
        case .text: return "txt"
        case .word: return "docx"
        }
    }

    /// JPEG, PNG and TIFF: a picture of each page. Photos are saved in these only.
    public var isImageFormat: Bool {
        switch self {
        case .jpeg, .png, .tiff: return true
        case .pdf, .text, .word: return false
        }
    }

    /// Text and Word: the recognized text of the pages, read by OCR when the file is saved.
    public var isTextFormat: Bool {
        switch self {
        case .text, .word: return true
        case .pdf, .jpeg, .png, .tiff: return false
        }
    }

    /// The formats the inspector offers: every format for documents, the image formats for photos
    /// (a photo has no text to save, and PDF photos are saved as JPEG).
    public static func offered(for intent: ScanIntent) -> [OutputFormat] {
        intent == .photo ? [.jpeg, .png, .tiff] : [.pdf, .word, .text, .jpeg, .png, .tiff]
    }

    /// The format a photo is saved in: this one when it is an image format, otherwise JPEG.
    public var imageFormatOrJPEG: OutputFormat { isImageFormat ? self : .jpeg }

    /// The format the collected pages are saved in together: Text and Word as chosen, anything
    /// else as one PDF (the image formats apply to scans saved one at a time).
    public var queueFormat: OutputFormat { isTextFormat ? self : .pdf }

    /// Whether a save writes a PDF: the collected pages in any format but Text and Word, a scan
    /// saved at once only in PDF. The text beside a PDF can be asked for then.
    public func savesPDF(collectsPages: Bool) -> Bool {
        collectsPages ? queueFormat == .pdf : self == .pdf
    }

    /// The format of a page made of a scan, like the ID card's: PDF or the image format chosen;
    /// PDF for the text formats.
    public var pageFormat: OutputFormat { isImageFormat ? self : .pdf }

    /// "Save PDF", "Save Word", "Save Text": the button that saves the collected pages.
    public var saveTitle: String {
        switch queueFormat {
        case .word: return "Save Word"
        case .text: return "Save Text"
        default: return "Save PDF"
        }
    }

    /// "Save PDF (3 pages)", or just the `saveTitle` when no page would be saved.
    public func saveTitle(pageCount: Int) -> String {
        pageCount > 0 ? "\(saveTitle) (\(pageCount) page\(pageCount == 1 ? "" : "s"))" : saveTitle
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

    /// What the size is for, in a few words: the segment's tooltip.
    public var hint: String {
        switch self {
        case .standard: return "Good for most documents"
        case .best: return "Full quality, largest files"
        case .compact: return "Smaller, for email and uploads"
        case .smallest: return "Smallest, for strict size limits"
        }
    }

    /// How the size stores the pages, for VoiceOver (the segment's help).
    public var detail: String {
        switch self {
        // Black & white pages are CCITT G4 up to their own, higher limit on both platforms.
        case .standard: return "Up to 300 dpi (black & white 600), gray pages saved in gray."
        case .best: return "Full resolution, high quality."
        case .compact: return "Up to 200 dpi (black & white 300), more compression."
        case .smallest: return "Up to 150 dpi (black & white 300), most compression."
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

    /// What the choice does, in a few words: its tooltip.
    public var hint: String {
        switch self {
        case .off: return "Front only"
        case .both: return "Both sides in one pass"
        case .manual: return "Scan the fronts, flip the stack, scan the backs"
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
        case .longEdge: return "Long edge (book)"
        case .shortEdge: return "Short edge (calendar)"
        }
    }

    /// The Flip on picker's tooltip. Twin of C# `DuplexBindings.PickerHint`.
    public static let pickerHint = "Which edge the sheets turn on"
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

    /// What counts as blank at that level, in a few words: the segment's tooltip.
    public var hint: String {
        switch self {
        case .low: return "Only empty pages"
        case .medium: return "Also dust or a page number"
        case .high: return "Also pages with small marks"
        }
    }

    /// The levels as the inspector lists them: least first.
    public static let displayOrder: [BlankSensitivity] = [.low, .medium, .high]

    /// The line that stays visible under the levels at High: pages with a few marks may be left out.
    /// Twin of C# `BlankSensitivities.HighWarning`.
    public static let highWarning = "Check flagged pages before saving"
}

/// The user's say over whether a queued page is saved (`ScannedPage.inclusion`): `.automatic`
/// follows the blank-page setting (`PageFilter.isExcluded`); `.keep` and `.skip` are one click on
/// the page, whatever the setting. Not stored in settings files. Twin of C# `PageInclusion`.
public enum PageInclusion: String, Codable, Sendable {
    case automatic
    case keep
    case skip
}

/// Where a queued page came from (`ScannedPage.source`): a scanner, a photo of a document imported
/// from a file (`PhotoImport`), or a paired phone over the companion link (`CompanionProtocol`). Not
/// stored in settings files. Twin of C# `PageSource`.
public enum PageSource: String, Codable, Sendable {
    case scanner
    case photo
    case phone
}

/// Where a stack of collected pages is split into separate documents (`DocumentOptions.splitMode`,
/// `DocumentSplitter`). `.none` comes first: it is the default and the fallback for a mode a newer
/// version adds. New modes come after the existing ones. Shown in `displayOrder`. Twin of C#
/// `SplitMode` (`ModelLabels.Label` / `Hint`, `SplitModes.DisplayOrder`).
public enum SplitMode: String, Codable, CaseIterable, Identifiable, Sendable {
    /// The pages are saved as one document.
    case none
    /// At each separator sheet with a patch code (`PatchCodeDetector`); the sheet is left out.
    case separatorSheet
    /// At each empty sheet (with both sides scanned, only a sheet blank on both sides); the sheet is left out.
    case blankSheet
    /// Every `DocumentOptions.splitSheetCount` sheets.
    case sheetCount
    /// At each sheet with a barcode or QR code starting with `DocumentOptions.splitBarcodePrefix`
    /// (`BarcodeSeparators`): the sheet is left out and the rest of the code's text names the document
    /// after it; with `DocumentOptions.barcodeStartsDocument` a page with any code is kept and starts
    /// its document, named by the code.
    case barcode

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .none: return "Off"
        case .separatorSheet: return "At separator sheets"
        case .blankSheet: return "At blank sheets"
        case .sheetCount: return "Every few sheets"
        case .barcode: return "At QR codes or barcodes"
        }
    }

    /// How the stack is split, in a few words: the choice's tooltip.
    public var hint: String {
        switch self {
        case .none: return "All pages in one document"
        case .separatorSheet: return "A separator sheet starts each document"
        case .blankSheet: return "A blank sheet between documents splits them"
        case .sheetCount: return "A new document every few sheets"
        case .barcode: return "A code starts each document and can name it"
        }
    }

    /// The one line under the choice: what happens to the sheets that split ("Separator sheets are
    /// left out"); empty where the choice's own controls say it (every few sheets, codes).
    public var caption: String {
        switch self {
        case .separatorSheet: return "Separator sheets are left out"
        case .blankSheet: return "Blank sheets are left out"
        case .none, .sheetCount, .barcode: return ""
        }
    }

    /// How it works, step by step: what the info button next to "Split into documents" shows.
    public var steps: String {
        switch self {
        case .none:
            return "All the pages are saved as one document. Right-click a page to start a new document there."
        case .separatorSheet:
            return "1. Save or print a separator sheet. 2. Put one in front of each document after the first. 3. Scan the stack. 4. Check the dividers in the page strip, then save."
        case .blankSheet:
            return "Put an empty sheet between documents. With both sides scanned, only a sheet blank on both sides splits."
        case .sheetCount:
            return "A new document starts every few sheets, for forms that all have the same number of sheets. Check the dividers in the page strip, then save."
        case .barcode:
            return "1. Print a QR sheet, one per document, with a name or without. 2. Put it in front of the document. 3. Scan: the sheet is left out and its name names the document. Only codes starting with LS-SEP count."
        }
    }

    /// The modes as the inspector lists them.
    public static let displayOrder: [SplitMode] = [.none, .separatorSheet, .blankSheet, .sheetCount, .barcode]
}

/// The user's say over whether a new document starts at a queued page (`ScannedPage.documentBreak`):
/// `.automatic` follows the split setting; `.split` and `.join` are one click on the gap before the
/// page, whatever the setting. Not stored in settings files. Twin of C# `DocumentBreak`.
public enum DocumentBreak: String, Codable, Sendable {
    case automatic
    case split
    case join
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
/// object in settings files): the PDF size, the after-save action, the text file beside a PDF and
/// the page pictures of a Word document. Later output features add their fields here. Twin of C#
/// `OutputOptions`.
public struct OutputOptions: Codable, Equatable, Sendable {
    /// How small saved PDFs are made. Settings without it get `.standard`.
    public var pdfSize: PDFSizePreset = .standard
    /// What happens on its own after a save (see `SaveActions.plan`). Settings without it, or
    /// with an action this version does not know, get `.none`.
    public var afterSave: AfterSaveAction = AfterSaveAction.none
    /// A saved PDF gets a text file beside it with the same name (`TextExport`): the recognized
    /// text of its pages, read once for both. Settings without it get false.
    public var alsoSaveText: Bool = false
    /// Saved PDFs are PDF/A-2b, made for keeping (`PDFWriteOptions.forOutput`). A PDF/A file cannot
    /// have a password, so the password option (`protect`) and this one exclude each other. Settings
    /// without it get false.
    public var archival: Bool = false
    /// Saved PDFs open only with a password (AES-256, `PDFEncryption`), asked for at each save: only
    /// this switch is stored, never the password. Excludes `archival`; when a settings file has both
    /// on, the password wins. Settings without it get false.
    public var protect: Bool = false
    /// A Word document shows each page as scanned, fitted to the paper, before the page's text
    /// (`DocxWriter`), stored as `pdfSize` stores a PDF page. On by default, also for settings
    /// without it; picking a task keeps it, as the user's choice.
    public var wordPageImages: Bool = true

    public init() {}

    /// `encode(to:)` stays synthesized.
    private enum CodingKeys: String, CodingKey {
        case pdfSize
        case afterSave
        case alsoSaveText
        case archival
        case protect
        case wordPageImages
    }
}

extension OutputOptions {
    /// Tolerant decoding: a missing or undecodable key keeps the property's default.
    public init(from decoder: Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pdfSize = container.decodeLenient(forKey: .pdfSize, default: pdfSize)
        afterSave = container.decodeLenient(forKey: .afterSave, default: afterSave)
        alsoSaveText = container.decodeLenient(forKey: .alsoSaveText, default: alsoSaveText)
        archival = container.decodeLenient(forKey: .archival, default: archival)
        protect = container.decodeLenient(forKey: .protect, default: protect)
        wordPageImages = container.decodeLenient(forKey: .wordPageImages, default: wordPageImages)
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
    /// Each page is cut out of the scanner's background when its edges are clear
    /// (`DocumentGeometry`). One click in the page strip shows a page as scanned.
    public var autoCrop: Bool = false
    /// Each page that lies at a slant is turned straight, by its edges or its lines of text
    /// (`DocumentGeometry`). One click in the page strip shows a page as scanned.
    public var autoStraighten: Bool = false
    /// Where the collected pages are split into separate documents when they are saved
    /// (`DocumentSplitter`): at separator sheets, at blank sheets or every few sheets. The page
    /// strip shows the documents before saving, and one click joins or splits them. Off unless chosen.
    public var splitMode: SplitMode = .none
    /// The sheets in each document for `.sheetCount`; read through `DocumentSplitter.clampSheetCount` (1 to 999).
    public var splitSheetCount: Int = 1
    /// Each page that is upside down or sideways is turned upright when its text makes that clear
    /// (`OrientationDecision`). One click in the page strip undoes the turn.
    public var autoRotate: Bool = false
    /// Each scan of an open book or magazine is cut at the spine into its two facing pages, put in
    /// reading order (`BookSplitter`); a spread whose spine is not clear stays whole. The page strip
    /// joins the pages again or moves the cut. Off unless chosen (the Book or magazine task turns it on).
    public var splitFacingPages: Bool = false
    /// On each page cut from a spread, the shadow along the spine is lightened towards the paper's white,
    /// keeping the text dark and leaving pictures beside it as they are (`SpineShadow`); one click in the
    /// page strip shows a page as scanned. Off unless chosen (the Book or magazine task turns it on).
    public var softenSpineShadow: Bool = false
    /// At QR codes or barcodes (`SplitMode.barcode`): a page with any code is kept, starts a new
    /// document and names it after the code's text. Off: a sheet with a code starting with
    /// `splitBarcodePrefix` is a separator sheet, left out, and the rest of the code's text names the
    /// document after it; other codes are ignored. Off unless chosen.
    public var barcodeStartsDocument: Bool = false
    /// At QR codes or barcodes: the text a separator sheet's code starts with ("LS-SEP",
    /// `BarcodeSeparators.defaultPrefix`; a–z matching A–Z, spaces around it ignored), which the QR
    /// separator sheets the app prints carry, so codes printed on the documents themselves do not split
    /// the stack. Empty: every code makes a separator sheet. Kept in settings files and presets (no
    /// inspector field); files without it read the default.
    public var splitBarcodePrefix: String = BarcodeSeparators.defaultPrefix

    public init() {}

    /// `encode(to:)` stays synthesized.
    private enum CodingKeys: String, CodingKey {
        case removeBlankPages
        case blankSensitivity
        case autoCrop
        case autoStraighten
        case splitMode
        case splitSheetCount
        case autoRotate
        case splitFacingPages
        case softenSpineShadow
        case barcodeStartsDocument
        case splitBarcodePrefix
    }
}

extension DocumentOptions {
    /// Tolerant decoding: a missing or undecodable key keeps the property's default.
    public init(from decoder: Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        removeBlankPages = container.decodeLenient(forKey: .removeBlankPages, default: removeBlankPages)
        blankSensitivity = container.decodeLenient(forKey: .blankSensitivity, default: blankSensitivity)
        autoCrop = container.decodeLenient(forKey: .autoCrop, default: autoCrop)
        autoStraighten = container.decodeLenient(forKey: .autoStraighten, default: autoStraighten)
        splitMode = container.decodeLenient(forKey: .splitMode, default: splitMode)
        splitSheetCount = container.decodeLenient(forKey: .splitSheetCount, default: splitSheetCount)
        autoRotate = container.decodeLenient(forKey: .autoRotate, default: autoRotate)
        splitFacingPages = container.decodeLenient(forKey: .splitFacingPages, default: splitFacingPages)
        softenSpineShadow = container.decodeLenient(forKey: .softenSpineShadow, default: softenSpineShadow)
        barcodeStartsDocument = container.decodeLenient(forKey: .barcodeStartsDocument, default: barcodeStartsDocument)
        splitBarcodePrefix = container.decodeLenient(forKey: .splitBarcodePrefix, default: splitBarcodePrefix)
    }
}

/// Choices that belong to one task, kept together as `ScanSettings.taskOptions` (the "taskOptions"
/// object in settings files). Picking a task keeps them: they say how the user wants that task
/// done. Later tasks add their fields here. Twin of C# `TaskOptions`.
public struct TaskOptions: Codable, Equatable, Sendable {
    /// The page the ID card's sides are laid out on. Settings without it get `.auto`.
    public var idCardPaper: IdCardPaper = .auto
    /// Each side of the ID card is also saved as an image of its own. Off unless chosen.
    public var idCardSaveSidesAsImages: Bool = false
    /// How many copies the Copy task prints; read through `PrintCopies.clamp` (1 to 99). One unless chosen.
    public var copyCount: Int = 1
    /// Copies are made smaller to fit the printable area of the paper. Off: they print at real size,
    /// like a photocopier.
    public var copyFitToPage: Bool = false
    /// The printer the Copy task (and printing the ID card) prints on; nil for the default printer,
    /// which is also used when this one is no longer installed. Left out of the file when nil.
    public var copyPrinterName: String?
    /// Each copy is also saved as a PDF in the save folder. Off unless chosen.
    public var copyAlsoSavePdf: Bool = false
    /// The Receipts task names each file by the date printed on the receipt (the {docdate} token),
    /// read from its text; the scan date when none is found. On unless turned off, also for settings
    /// written before it existed.
    public var receiptNameByDate: Bool = true
    /// The Receipts task saves all the receipts of a scan as one PDF, a page each. Off: a file per receipt.
    public var receiptCombine: Bool = false
    /// The book reads from right to left (Arabic, Hebrew, manga): the right page of each spread comes
    /// first. Off: left to right.
    public var bookRightToLeft: Bool = false
    /// Quarter turns clockwise every page of a book is turned, for a book lying sideways or upside down
    /// on the glass; read through `BookSplitter.normalizedTurns` (0 to 3). None unless chosen.
    public var bookRotationQuarterTurns: Int = 0
    /// The iPhone's camera takes both sides of each sheet for the two-sided task as all the fronts first,
    /// then all the backs. Off: "Flip & capture", each front followed by its back.
    public var cameraFrontsFirst: Bool = false
    /// The iPhone's camera takes a book as whole spreads, each cut at its spine
    /// (`PageProcessor.splitsCameraSpreads`). Off: page by page, one page a shot.
    public var cameraSpreads: Bool = false
    /// The filter the camera's document pages get as they are taken (`DocumentEnhancer.mode(for:)`); each page
    /// can be given another afterwards. Nil: never chosen, which is Enhanced, as before the filters; left out
    /// of the file then. The iPhone starts at Original.
    public var cameraFilter: CaptureFilter?

    public init() {}

    /// `encode(to:)` stays synthesized.
    private enum CodingKeys: String, CodingKey {
        case idCardPaper
        case idCardSaveSidesAsImages
        case copyCount
        case copyFitToPage
        case copyPrinterName
        case copyAlsoSavePdf
        case receiptNameByDate
        case receiptCombine
        case bookRightToLeft
        case bookRotationQuarterTurns
        case cameraFrontsFirst
        case cameraSpreads
        case cameraFilter
    }
}

extension TaskOptions {
    /// Tolerant decoding: a missing or undecodable key keeps the property's default.
    public init(from decoder: Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        idCardPaper = container.decodeLenient(forKey: .idCardPaper, default: idCardPaper)
        idCardSaveSidesAsImages = container.decodeLenient(forKey: .idCardSaveSidesAsImages, default: idCardSaveSidesAsImages)
        copyCount = container.decodeLenient(forKey: .copyCount, default: copyCount)
        copyFitToPage = container.decodeLenient(forKey: .copyFitToPage, default: copyFitToPage)
        copyPrinterName = container.decodeLenient(forKey: .copyPrinterName, default: copyPrinterName)
        copyAlsoSavePdf = container.decodeLenient(forKey: .copyAlsoSavePdf, default: copyAlsoSavePdf)
        receiptNameByDate = container.decodeLenient(forKey: .receiptNameByDate, default: receiptNameByDate)
        receiptCombine = container.decodeLenient(forKey: .receiptCombine, default: receiptCombine)
        bookRightToLeft = container.decodeLenient(forKey: .bookRightToLeft, default: bookRightToLeft)
        bookRotationQuarterTurns = container.decodeLenient(forKey: .bookRotationQuarterTurns, default: bookRotationQuarterTurns)
        cameraFrontsFirst = container.decodeLenient(forKey: .cameraFrontsFirst, default: cameraFrontsFirst)
        cameraSpreads = container.decodeLenient(forKey: .cameraSpreads, default: cameraSpreads)
        cameraFilter = container.decodeLenient(forKey: .cameraFilter, default: cameraFilter)
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
    /// The save folder picked outside the app on the iPhone (iCloud Drive, a USB drive), as a bookmark:
    /// iOS lets the app back into such a folder only through one. `destinationPath` is its path. Not
    /// used on the Mac and Windows. Left out of the file when nil.
    public var destinationBookmark: Data?
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

    /// Settings for the saved files (the PDF size, the after-save action, the text beside a PDF).
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

    /// Choices of particular tasks (the ID card's page).
    public var taskOptions: TaskOptions = TaskOptions()

    public init() {}

    /// The task of `taskId`, when this version knows it.
    public var task: ScanTask? { ScanTask.tryParse(taskId) }

    public static var defaultDestinationPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent("Documents/Lazy Scan")
    }

    /// `path` moved into `documents` when it lies in another iOS app container's Documents folder
    /// (…/Application/<UUID>/Documents/…): the container's path changes with every update of the app, so
    /// a save folder kept as a full path would point into one that is gone. Any other path, and every
    /// path when `documents` is nil (the Mac), is returned as it is.
    public static func rebasedDestinationPath(_ path: String, documents: URL?) -> String {
        guard let documents else { return path }
        let parts: [String] = (path as NSString).pathComponents
        var index: Int = 2
        while index < parts.count {
            if parts[index] == "Documents", parts[index - 2] == "Application", UUID(uuidString: parts[index - 1]) != nil {
                var rebased: String = documents.path
                for part in parts[(index + 1)...] {
                    rebased = (rebased as NSString).appendingPathComponent(part)
                }
                return rebased
            }
            index += 1
        }
        return path
    }

    /// Same keys the synthesized implementation used; `encode(to:)` stays synthesized.
    private enum CodingKeys: String, CodingKey {
        case intent, source, resolution, colorMode, format, jpegQuality, destinationPath, namingTemplate
        case destinationBookmark
        case photoAutoSplit, photoAutoDeskew, photoMinSideInches, photoCropInsetPixels
        case documentMultiPage, pdfSearchable, ocrLanguages
        case adjustments
        case taskId
        case output
        case duplex, backBinding, paperSize
        case document
        case taskOptions
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
        destinationBookmark = container.decodeLenient(forKey: .destinationBookmark, default: destinationBookmark)
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
        taskOptions = container.decodeLenient(forKey: .taskOptions, default: taskOptions)
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
    /// What crop and straighten did to the page (`DocumentGeometry`), or nil when they did nothing
    /// (off, or not sure).
    public var geometry: PageGeometry?
    /// The user went back to the page as scanned: `image` is the page before crop and straighten,
    /// `alternate` the cropped and straightened one.
    public var showsOriginal: Bool = false
    /// The version of the page not shown (the page as scanned, or after crop and straighten), so one
    /// click can swap them; nil when there is none. Its pixels are dropped once it has a spool file.
    /// Pixel steps after crop and straighten change it too (`withAlternate(_:)`).
    public var alternate: PageVersion?
    /// The patch code found on the page (`PatchCodeDetector`), which makes it a separator sheet; nil
    /// when none was found or the page was not checked.
    public var patch: PatchCode?
    /// The barcodes and QR codes read on the page (`BarcodeSeparators`), in reading order, with where
    /// they are on the page as it was read; empty when none was found, nil when the page was not read
    /// (barcodes are read only while the stack is split at barcode or QR sheets), or only its preview
    /// could be and showed none (`BarcodeSeparators.readQueuedPage`).
    public var barcodes: [BarcodeReading]?
    /// Whether the user starts a new document at this page, or joins it to the one before, whatever
    /// the split setting.
    public var documentBreak: DocumentBreak = .automatic
    /// The name the user gave the document this page belongs to (the {label} naming token); nil for
    /// none. A document takes the first name among its pages.
    public var documentLabel: String?
    /// What turning pages upright did to the page (`OrientationDecision`): the turn it was given, and
    /// whether the user turned it back; nil when it was not turned.
    public var upright: UprightTurn?
    /// The spread of an open book this page was cut from, and which part of it the page is
    /// (`BookSplitter`); nil for a page not scanned as part of a spread. In memory only.
    public var spread: SpreadPart?

    /// What softening the spine's shadow did to the page (`SpineShadow`), or nil when it did nothing (off,
    /// not cut from a spread, or no shadow found). In memory only.
    public var spineShadow: SpineShadowResult?

    /// Where the page came from: a scanner, or a photo imported from a file (`PhotoImport`), which the
    /// page strip labels "Photo". In memory only.
    public var source: PageSource = .scanner

    /// What the camera recorded about a page taken by one (`CaptureFacts`): its corners in the photo
    /// and, once `PerspectiveStep` cut it out, the real size it snapped to; nil for pages from scanners
    /// and files. Carried by every rebuild of the page and by companion packages.
    public var capture: CaptureFacts?

    /// Whether the page can be printed at its real size: a scan or an imported file carries a true
    /// resolution (no capture facts), and a camera page only when `CaptureScale` snapped it to a known
    /// size (`CaptureScaleResult.isRealSize`). A camera page whose size was guessed is fitted to the
    /// page instead (`PrintLayout.copyFitsToPage`). Twin of C# `ScannedPage.PrintsAtRealSize`.
    public var printsAtRealSize: Bool { capture == nil || (capture?.scale?.isRealSize ?? false) }

    /// The spread this page was cut from (`spread`); nil for other pages.
    public var spreadID: UUID? { spread?.spreadID }

    /// The page was cropped, straightened or had its spine's shadow softened, and the other version is at
    /// hand: one click swaps them.
    public var canSwapVersions: Bool { (geometry != nil || spineShadow != nil) && alternate != nil }

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
        page.alternate = alternate
        return page.copyMeta(from: self)
    }

    /// This page carrying what the scan recorded about `source`: its side and sheet, the
    /// blank-page check, the user's keep or skip, what crop and straighten did and which version is
    /// shown, the patch code and barcodes found on it, the user's document break and document name, the turn that
    /// made it upright, the spread it was cut from, what softening its spine's shadow did, where it came
    /// from (`source`) and what the camera recorded (`capture`). Pixels, id, file, rotation and the other
    /// version stay this page's. Twin of C# `ScannedPage.CopyMeta`.
    public func copyMeta(from source: ScannedPage) -> ScannedPage {
        var page = self
        page.side = source.side
        page.sheetIndex = source.sheetIndex
        page.blank = source.blank
        page.inclusion = source.inclusion
        page.geometry = source.geometry
        page.showsOriginal = source.showsOriginal
        page.patch = source.patch
        page.barcodes = source.barcodes
        page.documentBreak = source.documentBreak
        page.documentLabel = source.documentLabel
        page.upright = source.upright
        page.spread = source.spread
        page.spineShadow = source.spineShadow
        page.source = source.source
        page.capture = source.capture
        return page
    }

    /// This page cropped or straightened: `corrected` is shown, with what was done (`geometry`),
    /// and the page as it was becomes the `alternate`. Twin of C# `ScannedPage.WithGeometry`.
    public func withGeometry(_ corrected: CGImage, geometry: PageGeometry) -> ScannedPage {
        var page = ScannedPage(image: corrected, dpi: dpi, colorMode: colorMode, id: id, createdAt: createdAt)
        page.rotationQuarterTurns = rotationQuarterTurns
        page.side = side
        page.sheetIndex = sheetIndex
        page.blank = blank
        page.inclusion = inclusion
        page.geometry = geometry
        page.showsOriginal = false
        page.patch = patch
        page.barcodes = barcodes
        page.documentBreak = documentBreak
        page.documentLabel = documentLabel
        page.upright = upright
        page.spread = spread
        page.spineShadow = spineShadow
        page.source = source
        page.capture = capture
        page.alternate = PageVersion(image: image, fileURL: fileURL, fullPixelSize: fullPixelSize)
        return page
    }

    /// This page with its spine's shadow softened (`SpineShadowStep`): `softened` is shown, with what was
    /// done (`result`). The other version stays the page as scanned when crop and straighten kept one;
    /// otherwise the page as it was becomes the `alternate`. Twin of C# `ScannedPage.WithSpineShadow`.
    public func withSpineShadow(_ softened: CGImage, result: SpineShadowResult) -> ScannedPage {
        var page = ScannedPage(image: softened, dpi: dpi, colorMode: colorMode, id: id, createdAt: createdAt)
        page.rotationQuarterTurns = rotationQuarterTurns
        page.side = side
        page.sheetIndex = sheetIndex
        page.blank = blank
        page.inclusion = inclusion
        page.geometry = geometry
        page.showsOriginal = false
        page.patch = patch
        page.barcodes = barcodes
        page.documentBreak = documentBreak
        page.documentLabel = documentLabel
        page.upright = upright
        page.spread = spread
        page.spineShadow = result
        page.source = source
        page.capture = capture
        page.alternate = alternate ?? PageVersion(image: image, fileURL: fileURL, fullPixelSize: fullPixelSize)
        return page
    }

    /// This page with another version not shown (nil: none).
    public func withAlternate(_ alternate: PageVersion?) -> ScannedPage {
        var page = self
        page.alternate = alternate
        return page
    }

    /// The other version shown: the page as scanned instead of the cropped and straightened one, or
    /// back. `shown` is the other version's pixels as the queue shows them (its preview, turned like
    /// this page; `alternate`'s own pixels when it has no spool file). This version becomes the
    /// alternate, without its pixels when it has a spool file. A page with no other version is
    /// returned as it is. Twin of C# `ScannedPage.WithVersionsSwapped`.
    public func withVersionsSwapped(_ shown: CGImage) -> ScannedPage {
        guard let other = alternate else { return self }
        var page = ScannedPage(image: shown, dpi: dpi, colorMode: colorMode, id: id, createdAt: createdAt,
                               fileURL: other.fileURL, fullPixelSize: other.fullPixelSize)
        page.rotationQuarterTurns = rotationQuarterTurns
        page.side = side
        page.sheetIndex = sheetIndex
        page.blank = blank
        page.inclusion = inclusion
        page.geometry = geometry
        page.showsOriginal = !showsOriginal
        page.patch = patch
        page.barcodes = barcodes
        page.documentBreak = documentBreak
        page.documentLabel = documentLabel
        page.upright = upright
        page.spread = spread
        page.spineShadow = spineShadow
        page.source = source
        page.capture = capture
        page.alternate = PageVersion(image: fileURL == nil ? image : nil, fileURL: fileURL, fullPixelSize: fullPixelSize)
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

    /// This page with the patch code found on it (nil: none, the page is no separator sheet).
    public func withPatch(_ patch: PatchCode?) -> ScannedPage {
        var page = self
        page.patch = patch
        return page
    }

    /// This page with the barcodes read on it (nil: not read).
    public func withBarcodes(_ barcodes: [BarcodeReading]?) -> ScannedPage {
        var page = self
        page.barcodes = barcodes
        return page
    }

    /// This page starting a new document, joined to the one before, or following the split setting again.
    public func withDocumentBreak(_ documentBreak: DocumentBreak) -> ScannedPage {
        var page = self
        page.documentBreak = documentBreak
        return page
    }

    /// This page carrying the name of its document (nil: none).
    public func withDocumentLabel(_ documentLabel: String?) -> ScannedPage {
        var page = self
        page.documentLabel = documentLabel
        return page
    }

    /// This page as `side` of sheet `sheetIndex` (both nil: not two-sided).
    public func withSide(_ side: PageSide?, sheetIndex: Int?) -> ScannedPage {
        var page = self
        page.side = side
        page.sheetIndex = sheetIndex
        return page
    }

    /// This page with what turning pages upright did to it (nil: not turned); the pixels are not changed.
    public func withUpright(_ upright: UprightTurn?) -> ScannedPage {
        var page = self
        page.upright = upright
        return page
    }

    /// This page with what the camera recorded about it (nil: not taken by a camera); the pixels are not
    /// changed. Twin of C# `ScannedPage.WithCapture`.
    public func withCapture(_ capture: CaptureFacts?) -> ScannedPage {
        var page = self
        page.capture = capture
        return page
    }

    /// This page as a part of a spread (nil: not cut from one); the pixels are not changed.
    public func withSpread(_ spread: SpreadPart?) -> ScannedPage {
        var page = self
        page.spread = spread
        return page
    }

    /// This page turned upright by the clean-up stage (`OrientationStep`): its pixels and the other
    /// version's pixels in memory turned `quarterTurns` quarter turns clockwise, and the turn recorded
    /// (`upright`). A page not yet spooled is turned for good (its pixels are the page); a spooled
    /// page's file is turned when it is saved, through its rotation. No turn returns the page as it
    /// is. Twin of C# `ScannedPage.TurnedUpright`.
    public func turnedUpright(_ quarterTurns: Int) -> ScannedPage {
        let turns = ((quarterTurns % 4) + 4) % 4
        guard turns != 0 else { return self }
        return turned(turns).withUpright(UprightTurn(quarterTurns: turns))
    }

    /// One click on a turned page's turn button: the turn is undone (the page goes back the way it
    /// was scanned), or made again. The pixels in memory turn at once, and the spool file through the
    /// page's rotation, applied when it is saved, as a turn by hand. A page that was not turned is
    /// returned as it is. Twin of C# `ScannedPage.WithUprightToggled`.
    public func withUprightToggled() -> ScannedPage {
        guard let turn = upright else { return self }
        let back = turn.undone ? turn.quarterTurns : (4 - turn.quarterTurns) % 4
        var toggled = turn
        toggled.undone = !turn.undone
        return turned(back).withUpright(toggled)
    }

    /// The page turned `turns` (1 to 3) quarter turns clockwise: the pixels in memory (the other
    /// version's too); the rotation grows only when a spool file holds an unturned version, this one
    /// or the other (the rotation turns both files, and pixels in memory ignore it).
    private func turned(_ turns: Int) -> ScannedPage {
        var page = withImage(ImagePipeline.rotate(image, quarterTurns: turns), fileURL: fileURL, fullPixelSize: fullPixelSize)
        page.rotationQuarterTurns = fileURL == nil && alternate?.fileURL == nil
            ? rotationQuarterTurns
            : (rotationQuarterTurns + turns) % 4
        if var version = alternate, let other = version.image {
            version.image = ImagePipeline.rotate(other, quarterTurns: turns)
            page = page.withAlternate(version)
        }
        return page
    }
}

/// One version of a queued page (`ScannedPage.alternate`): its pixels as the queue shows them (nil
/// once spooled), its full-resolution spool file and that file's pixel size. Twin of C# `PageVersion`.
public struct PageVersion {
    public var image: CGImage?
    public var fileURL: URL?
    public var fullPixelSize: CGSize?

    public init(image: CGImage?, fileURL: URL?, fullPixelSize: CGSize?) {
        self.image = image
        self.fileURL = fileURL
        self.fullPixelSize = fullPixelSize
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
        let a: Double = angleDegrees * .pi / 180
        let c = CGFloat(cos(a)), s = CGFloat(sin(a))
        let hw: CGFloat = size.width / 2, hh: CGFloat = size.height / 2
        let local: [CGPoint] = [CGPoint(x: -hw, y: -hh), CGPoint(x: hw, y: -hh), CGPoint(x: hw, y: hh), CGPoint(x: -hw, y: hh)]
        return local.map { (p: CGPoint) -> CGPoint in
            let x: CGFloat = center.x + p.x * c - p.y * s
            let y: CGFloat = center.y + p.x * s + p.y * c
            return CGPoint(x: x, y: y)
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
    /// The color mode of the scan the photo was cut from (its `ScannedPage.colorMode`): what its
    /// pixels are, whatever the setting is when it is saved.
    public let colorMode: ColorMode
    public var included: Bool = true
    /// Extra user-requested rotation applied at save time (0...3 quarter turns clockwise).
    public var rotationQuarterTurns: Int = 0

    public init(region: DetectedPhotoRegion, image: CGImage, dpi: Int, id: UUID = UUID(),
                sourcePageID: UUID? = nil, colorMode: ColorMode = .color) {
        self.id = id
        self.region = region
        self.image = image
        self.dpi = dpi
        self.sourcePageID = sourcePageID
        self.colorMode = colorMode
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

    /// The preset's settings put in use over `current`: a preset saved before the camera's filter existed
    /// (none in its file) keeps the filter in use; one that has it brings it. Twin of C# `Preset.SettingsOver`.
    public func settings(over current: ScanSettings) -> ScanSettings {
        var chosen: ScanSettings = settings
        if chosen.taskOptions.cameraFilter == nil {
            chosen.taskOptions.cameraFilter = current.taskOptions.cameraFilter
        }
        return chosen
    }

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
