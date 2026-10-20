import Foundation

/// How the app handles a task's scans. Twin of C# `TaskFlowKind`
/// (`windows/CompleteScanner.Core/TaskCatalog.cs`).
public enum TaskFlowKind: String, Sendable {
    /// Pages go to the queue and are saved together, or each scan is saved at once.
    case documentQueue
    /// Photos are found on the bed, cropped and straightened, then reviewed.
    case photoSplit
    /// The front and back of a card are found on the bed and laid out on one page (`IdCardComposer`).
    case idCard
    /// The scan goes straight to the printer at real size (`PrintLayout`), like a photocopier.
    case copy
    /// Receipts are found on the bed (`ReceiptDetector`), cut out, straightened and cleaned up
    /// (`ReceiptEnhancer`), then reviewed and saved, named by their date.
    case receiptSplit
}

/// A task card: what it is called, how it looks and how its scans are handled.
public struct TaskDefinition: Equatable, Sendable {
    public let task: ScanTask
    public let title: String
    public let subtitle: String
    /// Names the card's icon; each platform maps it to its own symbol: "document", "feeder",
    /// "photos", "restore", "quick", "email", "twoSided", "idCard", "copy", "word", "receipt", "batch", "book".
    public let iconKey: String
    public let flow: TaskFlowKind
    /// The scan mode the task uses.
    public let intent: ScanIntent
    /// The source the task cannot work without; nil when any source does.
    public let requiredSource: ScanSource?
    /// What the `{task}` naming token becomes ("Document", "Photo").
    public let fileLabel: String
    public let steps: [TaskStep]
}

/// Whether a task can be started with the connected scanner, and if not, why.
public struct TaskAvailability: Equatable, Sendable {
    public let isAvailable: Bool
    public let reason: String?

    public init(isAvailable: Bool, reason: String? = nil) {
        self.isAvailable = isAvailable
        self.reason = reason
    }

    public static let available = TaskAvailability(isAvailable: true)
}

/// The tasks of the start screen, in code rather than in a settings file. Picking a task lays
/// its settings over the current ones (`apply`); a preset without a stored task is shown with
/// the task its settings look like (`infer`). Twin of C# `TaskCatalog`.
public enum TaskCatalog {
    /// Every task, in start-screen order.
    public static let all: [TaskDefinition] = [
        TaskDefinition(
            task: .document, title: "Document to PDF",
            subtitle: "Scan pages one at a time into a searchable PDF.",
            iconKey: "document", flow: .documentQueue, intent: .document, requiredSource: nil,
            fileLabel: "Document",
            steps: [TaskStep(id: "scan", title: "Scan each page",
                             prompt: "Place a page face down on the glass and scan it. Repeat for every page, then save the PDF.",
                             primaryActionLabel: "Scan page", repeats: true)]),
        TaskDefinition(
            task: .feeder, title: "Multi-page from feeder",
            subtitle: "Scan a stack of pages through the document feeder into one PDF.",
            iconKey: "feeder", flow: .documentQueue, intent: .document, requiredSource: .documentFeeder,
            fileLabel: "Document",
            steps: [TaskStep(id: "scan", title: "Scan the stack",
                             prompt: "Load the pages in the document feeder and scan. Add more stacks if you need to, then save the PDF.",
                             primaryActionLabel: "Scan stack", repeats: true)]),
        TaskDefinition(
            task: .photos, title: "Photos",
            subtitle: "Scan several photos at once. Each one is found, cropped and straightened.",
            iconKey: "photos", flow: .photoSplit, intent: .photo, requiredSource: nil,
            fileLabel: "Photo",
            steps: [TaskStep(id: "scan", title: "Scan the photos",
                             prompt: "Lay the photos on the glass with a little space between them, close the lid and scan. Check each photo before saving.",
                             primaryActionLabel: "Scan photos", repeats: true)]),
        TaskDefinition(
            task: .photoRestore, title: "Old photo restoration",
            subtitle: "Bring back the faded colors of old prints, saved as lossless PNG.",
            iconKey: "restore", flow: .photoSplit, intent: .photo, requiredSource: nil,
            fileLabel: "Restored photo",
            steps: [TaskStep(id: "scan", title: "Scan the old photos",
                             prompt: "Lay the photos on the glass with a little space between them and scan. Colors are restored automatically; check each photo before saving.",
                             primaryActionLabel: "Scan photos", repeats: true)]),
        TaskDefinition(
            task: .quickScan, title: "Quick scan",
            subtitle: "Preview the glass, drag over the part you need and save it as an image.",
            iconKey: "quick", flow: .documentQueue, intent: .document, requiredSource: .flatbed,
            fileLabel: "Scan",
            steps: [TaskStep(id: "scan", title: "Scan an area",
                             prompt: "Preview the glass, drag over the part you need, then scan. Each scan is saved right away.",
                             primaryActionLabel: "Scan", repeats: true)]),
        TaskDefinition(
            task: .email, title: "Email a document",
            subtitle: "Scan pages into a small PDF that is easy to attach to an email.",
            iconKey: "email", flow: .documentQueue, intent: .document, requiredSource: nil,
            fileLabel: "Document",
            steps: [TaskStep(id: "scan", title: "Scan each page",
                             prompt: "Place a page face down on the glass and scan it. Repeat for every page, then save the PDF: the share window opens so you can email it.",
                             primaryActionLabel: "Scan page", repeats: true)]),
        TaskDefinition(
            task: .twoSided, title: "Two-sided document",
            subtitle: "Both sides of every sheet in the feeder, in page order, in one PDF.",
            iconKey: "twoSided", flow: .documentQueue, intent: .document, requiredSource: .documentFeeder,
            fileLabel: "Document",
            steps: [TaskStep(id: "scan", title: "Scan the stack",
                             prompt: "Load the pages in the document feeder and scan: both sides of every sheet are scanned and put in order. Then save the PDF.",
                             primaryActionLabel: "Scan stack", repeats: true)]),
        TaskDefinition(
            task: .idCard, title: "ID card",
            subtitle: "Both sides of an ID card or driving licence on one page, at real size.",
            iconKey: "idCard", flow: .idCard, intent: .document, requiredSource: .flatbed,
            fileLabel: "ID card",
            steps: IdCardSteps.steps),
        TaskDefinition(
            task: .copy, title: "Copy",
            subtitle: "Scan straight to the printer at real size, like a photocopier.",
            iconKey: "copy", flow: .copy, intent: .document, requiredSource: nil,
            fileLabel: "Copy",
            steps: [TaskStep(id: "scan", title: "Make a copy",
                             prompt: "Place the original face down on the glass, or load the feeder, and copy. It prints at real size; choose the printer and the number of copies first.",
                             primaryActionLabel: "Copy", repeats: true)]),
        TaskDefinition(
            task: .word, title: "Scan to Word",
            subtitle: "Turn printed pages into a Word document you can edit.",
            iconKey: "word", flow: .documentQueue, intent: .document, requiredSource: nil,
            fileLabel: "Document",
            steps: [TaskStep(id: "scan", title: "Scan each page",
                             prompt: "Place a page face down on the glass and scan it. Repeat for every page, then save: the text is read from the pages into a Word document.",
                             primaryActionLabel: "Scan page", repeats: true)]),
        TaskDefinition(
            task: .receipt, title: "Receipts",
            subtitle: "Scan several receipts at once into small, searchable files named by their date.",
            iconKey: "receipt", flow: .receiptSplit, intent: .document, requiredSource: nil,
            fileLabel: "Receipt",
            steps: [TaskStep(id: "scan", title: "Scan the receipts",
                             prompt: "Lay up to six receipts on the glass with a little space between them, close the lid and scan. Each one is found, straightened and made easy to read; check them before saving.",
                             primaryActionLabel: "Scan receipts", repeats: true)]),
        TaskDefinition(
            task: .batch, title: "Batch of separate documents",
            subtitle: "Scan a stack of documents in one go; each one is saved as its own PDF, split at separator sheets.",
            iconKey: "batch", flow: .documentQueue, intent: .document, requiredSource: .documentFeeder,
            fileLabel: "Document",
            steps: [TaskStep(id: "scan", title: "Scan the stack",
                             prompt: "Put a separator sheet in front of each document after the first, load the stack in the feeder and scan. Check where the stack is split, then save.",
                             primaryActionLabel: "Scan stack", repeats: true)]),
        TaskDefinition(
            task: .book, title: "Book or magazine",
            subtitle: "Scan an open book two pages at a time; each spread is split into its pages, in reading order.",
            iconKey: "book", flow: .documentQueue, intent: .document, requiredSource: .flatbed,
            fileLabel: "Book",
            steps: [TaskStep(id: "scan", title: "Scan each spread",
                             prompt: "Open the book face down with the spine in the middle of the glass and press it gently flat, then scan. Turn the page and scan the next spread; each one becomes two pages.",
                             primaryActionLabel: "Scan spread", repeats: true)]),
    ]

    public static func definition(_ task: ScanTask) -> TaskDefinition {
        // Every case has an entry in `all` (ScanTaskTests checks it).
        all.first(where: { $0.task == task })!
    }

    /// `current` with the task's settings laid over it: mode, source, resolution, color,
    /// format, JPEG quality, PDF size, the after-save action, the text beside a PDF (off: only the
    /// Scan to Word task saves text), archival PDF (off: Windows' Archive document task is the only
    /// one that turns it on, and the Mac has no such task until its PDF writer port), the photo and document switches,
    /// searchable PDF, adjustments, two-sided scanning, skipping blank pages, crop and straighten,
    /// turning pages upright, splitting facing pages, file name and the task itself. The password
    /// option (`output.protect`), the destination folder, the photo detection tuning, the
    /// legacy OCR languages, the paper size, the edge backs are turned on, how much counts as blank
    /// and the choices of each task (`taskOptions`) are kept: they describe the user's paper and how
    /// they want a task done, not the task. The two-sided task asks for `.both`, skips blank pages
    /// (the empty backs of one-sided sheets), straightens pages the feeder pulled in at a slant and
    /// turns upright the sheets put in the wrong way round; the Book or magazine task splits each spread
    /// into its facing pages, straightens each page and turns upright a book lying sideways (its reading
    /// order and turn, in `taskOptions`, are kept); no task crops yet; `SettingsAdapter` turns `.both` into turning over by hand on a feeder that
    /// scans one side. The ID card task makes no searchable PDF: the numbers on an ID are better not
    /// indexed; neither does the Copy task, whose PDF (when one is saved too) is a record of the paper
    /// copy. The Receipts task scans in grayscale (thermal print has no color) into Compact PDFs, named
    /// by the receipt's date. Only the Batch task splits the stack into documents (at separator
    /// sheets, skipping blank pages); the others save one document. The sheets per document of
    /// `.sheetCount` are kept.
    public static func apply(_ task: ScanTask, to current: ScanSettings) -> ScanSettings {
        var s = current
        s.source = .flatbed
        s.colorMode = .color
        s.jpegQuality = 0.9
        s.photoAutoSplit = true
        s.photoAutoDeskew = true
        s.documentMultiPage = true
        s.pdfSearchable = task != .idCard && task != .copy
        s.adjustments = AdjustmentSettings()
        s.output.pdfSize = .standard
        s.output.afterSave = AfterSaveAction.none
        s.output.alsoSaveText = false
        s.output.archival = false
        s.duplex = .off
        s.document.removeBlankPages = task == .twoSided || task == .batch
        s.document.autoCrop = false
        s.document.autoStraighten = task == .twoSided || task == .book
        s.document.autoRotate = task == .twoSided || task == .book
        s.document.splitMode = task == .batch ? .separatorSheet : SplitMode.none
        s.document.splitFacingPages = task == .book
        switch task {
        case .document:
            s.intent = .document
            s.resolution = 300
            s.format = .pdf
            s.namingTemplate = "Scan {date} {counter}"
        case .feeder:
            s.intent = .document
            s.source = .documentFeeder
            s.resolution = 300
            s.format = .pdf
            s.namingTemplate = "Scan {date} {counter}"
        case .photos:
            s.intent = .photo
            s.resolution = 600
            s.format = .jpeg
            s.namingTemplate = "Photo {date} {counter}"
        case .photoRestore:
            s.intent = .photo
            s.resolution = 600
            s.format = .png
            s.adjustments.restoreFadedColors = true
            s.adjustments.autoEnhance = true
            s.namingTemplate = "Photo {date} {counter}"
        case .quickScan:
            s.intent = .document
            s.resolution = 150
            s.format = .jpeg
            s.documentMultiPage = false
            s.namingTemplate = "Scan {date} {counter}"
        case .email:
            s.intent = .document
            s.resolution = 300
            s.format = .pdf
            s.output.pdfSize = .compact
            s.output.afterSave = .share
            s.namingTemplate = "Scan {date} {counter}"
        case .twoSided:
            s.intent = .document
            s.source = .documentFeeder
            s.resolution = 300
            s.format = .pdf
            s.duplex = .both
            s.namingTemplate = "Scan {date} {counter}"
        case .idCard:
            s.intent = .document
            s.resolution = 300
            s.format = .pdf
            s.namingTemplate = "ID card {date}"
        case .copy:
            s.intent = .document
            s.resolution = 300
            s.format = .pdf
            s.namingTemplate = "Copy {date} {counter}"
        case .word:
            s.intent = .document
            s.resolution = 300
            s.format = .word
            s.namingTemplate = "Scan {date} {counter}"
        case .receipt:
            s.intent = .document
            s.resolution = 300
            s.colorMode = .grayscale
            s.format = .pdf
            s.output.pdfSize = .compact
            s.namingTemplate = "Receipt {docdate} {counter}"
        case .batch:
            s.intent = .document
            s.source = .documentFeeder
            s.resolution = 300
            s.format = .pdf
            s.namingTemplate = "Document {label} {date} {counter}"
        case .book:
            s.intent = .document
            s.resolution = 300
            s.format = .pdf
            s.namingTemplate = "{task} {date} {counter}"
        }
        s.taskId = task.rawValue
        return s
    }

    /// The task the settings belong to: the stored one when it is known, otherwise the one they
    /// look like. Used for display and file names only; never written back.
    public static func infer(_ settings: ScanSettings) -> ScanTask {
        if let stored = settings.task { return stored }
        if settings.intent == .photo {
            return settings.adjustments.restoreFadedColors ? .photoRestore : .photos
        }
        if settings.document.splitMode != SplitMode.none && settings.documentMultiPage { return .batch }
        if settings.document.splitFacingPages && settings.documentMultiPage { return .book }
        if settings.source == .documentFeeder { return settings.duplex == .off ? .feeder : .twoSided }
        if settings.format == .word { return .word }
        if !settings.documentMultiPage && settings.format.isImageFormat { return .quickScan }
        return .document
    }

    /// Whether the task can be started with a scanner offering `capabilities` (nil: none
    /// connected yet, so nothing is ruled out) and, for the Copy task, a printer (`hasPrinter`: false
    /// only when it is known that none is installed).
    public static func availability(of task: ScanTask, capabilities: ScannerCapabilities?,
                                    hasPrinter: Bool = true) -> TaskAvailability {
        if task == .copy && !hasPrinter {
            return TaskAvailability(isAvailable: false, reason: PrintText.noPrinterReason)
        }
        let taskDefinition = TaskCatalog.definition(task)
        guard let capabilities, let source = taskDefinition.requiredSource,
              !capabilities.sources.contains(source) else {
            return .available
        }
        return TaskAvailability(isAvailable: false,
                                reason: source == .documentFeeder
                                    ? "This scanner has no document feeder."
                                    : "This scanner has no flatbed.")
    }

    /// The settings still do what the task is for: the same scan mode, and the task's required
    /// source; for the two-sided task, both sides; for Scan to Word, a Word document; for the Batch
    /// task, a split; for the Book or magazine task, splitting facing pages. Changing the mode by hand
    /// (or choosing one side, another format or no split), or a scanner without that source, ends the task.
    public static func fits(_ task: ScanTask, _ settings: ScanSettings) -> Bool {
        let taskDefinition = TaskCatalog.definition(task)
        guard settings.intent == taskDefinition.intent else { return false }
        if task == .twoSided && settings.duplex == .off { return false }
        if task == .word && settings.format != .word { return false }
        if task == .batch && settings.document.splitMode == SplitMode.none { return false }
        if task == .book && !settings.document.splitFacingPages { return false }
        if let source = taskDefinition.requiredSource { return settings.source == source }
        return true
    }

    /// The steps the scan screen guides: turning the stack over by hand
    /// (`DocumentSides.manualSteps`) whenever these settings scan both sides that way, otherwise
    /// the stored task's steps while it fits; nil when there is nothing to guide.
    public static func guidedSteps(_ settings: ScanSettings, capabilities: ScannerCapabilities?) -> [TaskStep]? {
        if DocumentSides.usesManualSteps(settings, capabilities: capabilities) { return DocumentSides.manualSteps }
        guard let task = settings.task, fits(task, settings) else { return nil }
        return TaskCatalog.definition(task).steps
    }

    /// How a scan with these settings is handled: the stored task's flow while it fits,
    /// otherwise by mode.
    public static func flow(of settings: ScanSettings) -> TaskFlowKind {
        if let task = settings.task, fits(task, settings) { return TaskCatalog.definition(task).flow }
        return settings.intent == .photo ? .photoSplit : .documentQueue
    }

    /// One line describing the settings, e.g. "300 dpi · Color · PDF". A PDF size other than the
    /// default `.standard` is named ("300 dpi · Color · Compact PDF"), and so is two-sided feeder
    /// scanning ("… · Both sides", "… · Both sides, turned by hand"), splitting into documents
    /// ("… · Split at separator sheets") and facing pages ("… · Facing pages split", "… · Facing pages
    /// split, right to left"), so the line stays short
    /// enough for cards and the preset list. A copy says how it prints instead of a format:
    /// "300 dpi · Color · Actual size", "300 dpi · Grayscale · Fit to page · 3 copies".
    public static func summary(_ settings: ScanSettings) -> String {
        if flow(of: settings) == .copy {
            // A copy is paper, not a file: its size and count matter, not the format.
            let copies = PrintCopies.clamp(settings.taskOptions.copyCount)
            let mode = PrintText.modeLabel(fitToPage: settings.taskOptions.copyFitToPage)
            return "\(settings.resolution) dpi \u{00B7} \(settings.colorMode.label) \u{00B7} \(mode)"
                + (copies > 1 ? " \u{00B7} \(copies) copies" : "")
        }
        let format = settings.format == .pdf && settings.output.pdfSize != .standard
            ? "\(settings.output.pdfSize.label) \(settings.format.label)"
            : settings.format.label
        let sides = DocumentSides.effective(settings, capabilities: nil)
        let twoSided = sides == .off ? "" : " \u{00B7} \(sides.label)"
        let split = splitSummary(settings).map { " \u{00B7} \($0)" } ?? ""
        let book = bookSummary(settings).map { " \u{00B7} \($0)" } ?? ""
        return "\(settings.resolution) dpi \u{00B7} \(settings.colorMode.label) \u{00B7} \(format)\(twoSided)\(split)\(book)"
    }

    /// "Facing pages split" (", right to left") for collected document pages whose spreads are split
    /// (one side of each sheet, `BookPages.scansOneSide`); nil otherwise.
    private static func bookSummary(_ settings: ScanSettings) -> String? {
        guard settings.intent == .document, settings.documentMultiPage, settings.document.splitFacingPages,
              BookPages.scansOneSide(settings) else { return nil }
        return settings.taskOptions.bookRightToLeft ? "Facing pages split, right to left" : "Facing pages split"
    }

    /// "Split at separator sheets", "Split at blank sheets", "Split every 3 sheets" for collected
    /// document pages split into documents; nil otherwise.
    private static func splitSummary(_ settings: ScanSettings) -> String? {
        guard settings.intent == .document, settings.documentMultiPage else { return nil }
        let sheets = DocumentSplitter.clampSheetCount(settings.document.splitSheetCount)
        switch settings.document.splitMode {
        case .separatorSheet: return "Split at separator sheets"
        case .blankSheet: return "Split at blank sheets"
        case .sheetCount: return sheets == 1 ? "Split every sheet" : "Split every \(sheets) sheets"
        case .none: return nil
        }
    }
}
