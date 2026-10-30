import Foundation

/// How the app handles a task's scans. Twin of C# `TaskFlowKind`
/// (`windows/LazyScan.Core/TaskCatalog.cs`).
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

/// The start screen's groups of tasks, in the order it shows them. Twin of C# `TaskGroup`
/// (`TaskGroups.All`, `TaskGroups.Title`).
public enum TaskGroup: String, CaseIterable, Sendable {
    case documents
    case photosAndImages
    case other

    /// "Documents", "Photos & images", "Other".
    public var title: String {
        switch self {
        case .documents: return "Documents"
        case .photosAndImages: return "Photos & images"
        case .other: return "Other"
        }
    }
}

/// A group of the start screen with its tasks, in the order they are shown. Twin of C# `TaskGroupSection`.
public struct TaskGroupSection: Equatable, Sendable {
    public let group: TaskGroup
    public let definitions: [TaskDefinition]

    public init(group: TaskGroup, definitions: [TaskDefinition]) {
        self.group = group
        self.definitions = definitions
    }
}

/// A task card: what it is called, how it looks and how its scans are handled.
public struct TaskDefinition: Equatable, Sendable {
    public let task: ScanTask
    public let title: String
    /// What the task does, in one short line: the tile's tooltip, not shown on the tile.
    public let subtitle: String
    /// Names the card's icon; each platform maps it to its own symbol: "document", "feeder",
    /// "photos", "restore", "quick", "email", "twoSided", "idCard", "copy", "word", "receipt", "batch", "book",
    /// "archive".
    public let iconKey: String
    public let flow: TaskFlowKind
    /// The scan mode the task uses.
    public let intent: ScanIntent
    /// The source the task cannot work without; nil when any source does.
    public let requiredSource: ScanSource?
    /// What the `{task}` naming token becomes ("Document", "Photo").
    public let fileLabel: String
    public let steps: [TaskStep]
    /// The start screen's group the tile is in.
    public let group: TaskGroup
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
    /// Every task, in the order of `ScanTask.allCases`.
    public static let all: [TaskDefinition] = [
        TaskDefinition(
            task: .document, title: "Document to PDF",
            subtitle: "Page by page into a searchable PDF.",
            iconKey: "document", flow: .documentQueue, intent: .document, requiredSource: nil,
            fileLabel: "Document",
            steps: [TaskStep(id: "scan", title: "Scan each page",
                             prompt: "Place each page face down and scan, then save.",
                             primaryActionLabel: "Scan page", repeats: true,
                             help: "Scan the pages one by one. They are collected until you save the PDF.")],
            group: .documents),
        TaskDefinition(
            task: .feeder, title: "Stack from feeder",
            subtitle: "A stack through the feeder into one PDF.",
            iconKey: "feeder", flow: .documentQueue, intent: .document, requiredSource: .documentFeeder,
            fileLabel: "Document",
            steps: [TaskStep(id: "scan", title: "Scan the stack",
                             prompt: "Load the pages in the feeder and scan.",
                             primaryActionLabel: "Scan stack", repeats: true,
                             help: "Add more stacks if you need to, then save the PDF.")],
            group: .documents),
        TaskDefinition(
            task: .photos, title: "Photos",
            subtitle: "Several photos at once, each cropped and straightened.",
            iconKey: "photos", flow: .photoSplit, intent: .photo, requiredSource: nil,
            fileLabel: "Photo",
            steps: [TaskStep(id: "scan", title: "Scan the photos",
                             prompt: "Lay the photos on the glass, apart, and scan.",
                             primaryActionLabel: "Scan photos", repeats: true,
                             help: "Leave a little space between photos and close the lid. Check each photo before saving.")],
            group: .photosAndImages),
        TaskDefinition(
            task: .photoRestore, title: "Restore old photos",
            subtitle: "Brings back faded colors; saved as PNG.",
            iconKey: "restore", flow: .photoSplit, intent: .photo, requiredSource: nil,
            fileLabel: "Restored photo",
            steps: [TaskStep(id: "scan", title: "Scan the old photos",
                             prompt: "Lay the photos on the glass, apart, and scan.",
                             primaryActionLabel: "Scan photos", repeats: true,
                             help: "Colors are restored automatically. Check each photo before saving.")],
            group: .photosAndImages),
        TaskDefinition(
            task: .quickScan, title: "Quick scan",
            subtitle: "Save part of the glass as an image.",
            iconKey: "quick", flow: .documentQueue, intent: .document, requiredSource: .flatbed,
            fileLabel: "Scan",
            steps: [TaskStep(id: "scan", title: "Scan an area",
                             prompt: "Preview, drag over the part you need, then scan.",
                             primaryActionLabel: "Scan", repeats: true,
                             help: "Each scan is saved right away.")],
            group: .photosAndImages),
        TaskDefinition(
            task: .email, title: "Email a document",
            subtitle: "A small PDF, ready to attach.",
            iconKey: "email", flow: .documentQueue, intent: .document, requiredSource: nil,
            fileLabel: "Document",
            steps: [TaskStep(id: "scan", title: "Scan each page",
                             prompt: "Scan each page, then save to email it.",
                             primaryActionLabel: "Scan page", repeats: true,
                             help: "Saving opens the share window, so you can email the PDF.")],
            group: .documents),
        TaskDefinition(
            task: .twoSided, title: "Two-sided document",
            subtitle: "Both sides of every sheet, in page order.",
            iconKey: "twoSided", flow: .documentQueue, intent: .document, requiredSource: .documentFeeder,
            fileLabel: "Document",
            steps: [TaskStep(id: "scan", title: "Scan the stack",
                             prompt: "Load the pages in the feeder and scan.",
                             primaryActionLabel: "Scan stack", repeats: true,
                             help: "Both sides of every sheet are scanned and put in order. Then save the PDF.")],
            group: .documents),
        TaskDefinition(
            task: .idCard, title: "ID card",
            subtitle: "Both sides on one page, at real size.",
            iconKey: "idCard", flow: .idCard, intent: .document, requiredSource: .flatbed,
            fileLabel: "ID card",
            steps: IdCardSteps.steps,
            group: .other),
        TaskDefinition(
            task: .copy, title: "Photocopy",
            subtitle: "Prints at real size, like a photocopier.",
            iconKey: "copy", flow: .copy, intent: .document, requiredSource: nil,
            fileLabel: "Copy",
            steps: [TaskStep(id: "scan", title: "Make a copy",
                             prompt: "Place the original face down, then copy.",
                             primaryActionLabel: "Copy", repeats: true,
                             help: "Or load the feeder. Copies print at real size; choose the printer and number of copies on the right.")],
            group: .other),
        TaskDefinition(
            task: .word, title: "Scan to Word",
            subtitle: "Printed pages into an editable Word file.",
            iconKey: "word", flow: .documentQueue, intent: .document, requiredSource: nil,
            fileLabel: "Document",
            steps: [TaskStep(id: "scan", title: "Scan each page",
                             prompt: "Scan each page, then save as Word.",
                             primaryActionLabel: "Scan page", repeats: true,
                             help: "The text is read from the pages into a Word document you can edit.")],
            group: .documents),
        TaskDefinition(
            task: .receipt, title: "Receipts",
            subtitle: "Several at once, small files named by date.",
            iconKey: "receipt", flow: .receiptSplit, intent: .document, requiredSource: nil,
            fileLabel: "Receipt",
            steps: [TaskStep(id: "scan", title: "Scan the receipts",
                             prompt: "Lay up to six receipts apart and scan.",
                             primaryActionLabel: "Scan receipts", repeats: true,
                             help: "Each one is found, straightened and made easy to read. Check them before saving.")],
            group: .other),
        TaskDefinition(
            task: .batch, title: "Separate documents",
            subtitle: "One stack, a PDF for each document.",
            iconKey: "batch", flow: .documentQueue, intent: .document, requiredSource: .documentFeeder,
            fileLabel: "Document",
            steps: [TaskStep(id: "scan", title: "Scan the stack",
                             prompt: "Put a separator sheet before each document, then scan.",
                             primaryActionLabel: "Scan stack", repeats: true,
                             help: "1. Print separator sheets (Split into documents, on the right). 2. Put one in front of each document after the first. 3. Load the stack and scan. 4. Check the splits in the page strip, then save.")],
            group: .documents),
        TaskDefinition(
            task: .book, title: "Book or magazine",
            subtitle: "Two pages per scan, split at the spine.",
            iconKey: "book", flow: .documentQueue, intent: .document, requiredSource: .flatbed,
            fileLabel: "Book",
            steps: [TaskStep(id: "scan", title: "Scan each spread",
                             prompt: "Open the book face down, spine centered, and scan.",
                             primaryActionLabel: "Scan spread", repeats: true,
                             help: "Press it gently flat. Turn the page and scan the next spread; each one becomes two pages.")],
            group: .other),
        TaskDefinition(
            task: .archive, title: "Archive document",
            subtitle: "A searchable PDF/A, made to be kept.",
            iconKey: "archive", flow: .documentQueue, intent: .document, requiredSource: nil,
            fileLabel: "Document",
            steps: [TaskStep(id: "scan", title: "Scan each page",
                             prompt: "Scan each page, then save as PDF/A.",
                             primaryActionLabel: "Scan page", repeats: true,
                             help: "The PDF keeps its best quality, made to be kept for years.")],
            group: .documents),
    ]

    /// The tasks in the order the start screen shows them, group by group: Documents (Document to
    /// PDF, Stack from feeder, Two-sided document, Separate documents, Scan to Word, Email a
    /// document, Archive document), Photos & images (Photos, Restore old photos, Quick scan), Other
    /// (ID card, Photocopy, Receipts, Book or magazine).
    public static let startOrder: [ScanTask] = [
        .document, .feeder, .twoSided, .batch, .word, .email,
        .archive, .photos, .photoRestore, .quickScan, .idCard,
        .copy, .receipt, .book,
    ]

    /// The start screen's groups in order, each with its tasks in `startOrder`; every task is in one group.
    public static var sections: [TaskGroupSection] {
        TaskGroup.allCases.map { (group: TaskGroup) -> TaskGroupSection in
            let definitions: [TaskDefinition] = startOrder
                .map { (task: ScanTask) -> TaskDefinition in TaskCatalog.definition(task) }
                .filter { (definition: TaskDefinition) -> Bool in definition.group == group }
            return TaskGroupSection(group: group, definitions: definitions)
        }
    }

    /// Why a task that needs the document feeder cannot be started: the tile's one visible line.
    public static let needsFeederReason = "Needs a document feeder"

    /// Why a task that needs the flatbed cannot be started.
    public static let needsFlatbedReason = "Needs a flatbed"

    /// The error when a task that cannot be started is picked anyway: its title and the reason, as a
    /// sentence ("Stack from feeder needs a document feeder.").
    public static func unavailableMessage(_ task: ScanTask, reason: String) -> String {
        var text: String = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix(".") { text.removeLast() }
        if let first: Character = text.first {
            text = String(first).lowercased() + String(text.dropFirst())
        }
        return "\(TaskCatalog.definition(task).title) \(text)."
    }

    public static func definition(_ task: ScanTask) -> TaskDefinition {
        // Every case has an entry in `all` (ScanTaskTests checks it).
        all.first(where: { $0.task == task })!
    }

    /// `current` with the task's settings laid over it: mode, source, resolution, color,
    /// format, JPEG quality, PDF size, the after-save action, the text beside a PDF (off: only the
    /// Scan to Word task saves text), archival PDF (only the Archive document task, at the Best size,
    /// which turns the password off), the photo and document switches,
    /// searchable PDF, adjustments, two-sided scanning, skipping blank pages, crop and straighten,
    /// turning pages upright, splitting facing pages, softening the spine's shadow, file name and the task itself. The password
    /// option (`output.protect`), the page pictures of a Word document (`output.wordPageImages`), the destination folder, the photo detection tuning, the
    /// legacy OCR languages, the paper size, the edge backs are turned on, how much counts as blank
    /// and the choices of each task (`taskOptions`) are kept: they describe the user's paper and how
    /// they want a task done, not the task. The two-sided task asks for `.both`, skips blank pages
    /// (the empty backs of one-sided sheets), straightens pages the feeder pulled in at a slant and
    /// turns upright the sheets put in the wrong way round; the Book or magazine task splits each spread
    /// into its facing pages, straightens each page, softens the shadow along the spine and turns upright a book lying sideways (its reading
    /// order and turn, in `taskOptions`, are kept); no task crops yet; `SettingsAdapter` turns `.both` into turning over by hand on a feeder that
    /// scans one side. The ID card task makes no searchable PDF: the numbers on an ID are better not
    /// indexed; neither does the Copy task, whose PDF (when one is saved too) is a record of the paper
    /// copy. The Receipts task scans in grayscale (thermal print has no color) into Compact PDFs, named
    /// by the receipt's date. Only the Batch task splits the stack into documents (at separator
    /// sheets, skipping blank pages); the others save one document; no task splits at barcode or QR
    /// sheets. The sheets per document of `.sheetCount`, whether a barcode starts a document
    /// (`barcodeStartsDocument`) and the separator codes' prefix (`splitBarcodePrefix`) are kept.
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
        s.output.archival = task == .archive
        // The password is the user's choice for every task; a PDF/A file can't have one.
        if task == .archive { s.output.protect = false }
        s.duplex = .off
        s.document.removeBlankPages = task == .twoSided || task == .batch
        s.document.autoCrop = false
        s.document.autoStraighten = task == .twoSided || task == .book
        s.document.autoRotate = task == .twoSided || task == .book
        s.document.splitMode = task == .batch ? .separatorSheet : SplitMode.none
        s.document.splitFacingPages = task == .book
        s.document.softenSpineShadow = task == .book
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
        case .archive:
            s.intent = .document
            s.resolution = 300
            s.format = .pdf
            s.output.pdfSize = .best
            s.namingTemplate = "Scan {date} {counter}"
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
                                reason: source == .documentFeeder ? needsFeederReason : needsFlatbedReason)
    }

    /// The settings still do what the task is for: the same scan mode, and the task's required
    /// source; for the two-sided task, both sides; for Scan to Word, a Word document; for the Batch
    /// task, a split; for the Book or magazine task, collected pages with their facing pages split;
    /// for Quick scan, each scan saved at once; for the Archive document task, an archival PDF.
    /// Changing the mode by hand (or choosing one side, another format, no split or a plain PDF, or
    /// turning Collect pages before saving off for a book or on for a quick scan), or a scanner
    /// without that source, ends the task.
    public static func fits(_ task: ScanTask, _ settings: ScanSettings) -> Bool {
        let taskDefinition = TaskCatalog.definition(task)
        guard settings.intent == taskDefinition.intent else { return false }
        if task == .twoSided && settings.duplex == .off { return false }
        if task == .word && settings.format != .word { return false }
        if task == .batch && settings.document.splitMode == SplitMode.none { return false }
        if task == .book && !(settings.document.splitFacingPages && settings.documentMultiPage) { return false }
        if task == .quickScan && settings.documentMultiPage { return false }
        if task == .archive && !(settings.output.archival && settings.format == .pdf) { return false }
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

    /// Whether pages queued under another task can still be saved once `task` is started: its pages go to
    /// the queue and are saved together. Photos and receipts are saved from their review, the ID card as a
    /// card, a copy is printed and Quick scan saves each scan at once (or holds it, on the iPhone), so none
    /// of them has a Save for the queue.
    public static func carriesPages(_ task: ScanTask) -> Bool {
        definition(task).flow == .documentQueue && task != .quickScan
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

    /// "Split at separator sheets", "Split at blank sheets", "Split every 3 sheets", "Split at barcode
    /// sheets" ("Split and named at barcodes" when a barcode starts its document) for collected
    /// document pages split into documents; nil otherwise.
    private static func splitSummary(_ settings: ScanSettings) -> String? {
        guard settings.intent == .document, settings.documentMultiPage else { return nil }
        let sheets = DocumentSplitter.clampSheetCount(settings.document.splitSheetCount)
        switch settings.document.splitMode {
        case .separatorSheet: return "Split at separator sheets"
        case .blankSheet: return "Split at blank sheets"
        case .sheetCount: return sheets == 1 ? "Split every sheet" : "Split every \(sheets) sheets"
        case .barcode: return settings.document.barcodeStartsDocument ? "Split and named at barcodes" : "Split at barcode sheets"
        case .none: return nil
        }
    }
}
