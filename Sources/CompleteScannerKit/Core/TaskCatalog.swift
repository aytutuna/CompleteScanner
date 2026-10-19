import Foundation

/// How the app handles a task's scans. Twin of C# `TaskFlowKind`
/// (`windows/CompleteScanner.Core/TaskCatalog.cs`).
public enum TaskFlowKind: String, Sendable {
    /// Pages go to the queue and are saved together, or each scan is saved at once.
    case documentQueue
    /// Photos are found on the bed, cropped and straightened, then reviewed.
    case photoSplit
}

/// A task card: what it is called, how it looks and how its scans are handled.
public struct TaskDefinition: Equatable, Sendable {
    public let task: ScanTask
    public let title: String
    public let subtitle: String
    /// Names the card's icon; each platform maps it to its own symbol: "document", "feeder",
    /// "photos", "restore", "quick", "email".
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
    ]

    public static func definition(_ task: ScanTask) -> TaskDefinition {
        // Every case has an entry in `all` (ScanTaskTests checks it).
        all.first(where: { $0.task == task })!
    }

    /// `current` with the task's settings laid over it: mode, source, resolution, color,
    /// format, JPEG quality, PDF size, the after-save action, the photo and document switches,
    /// searchable PDF, adjustments, file name and the task itself. The destination folder, the photo detection tuning and
    /// the legacy OCR languages are kept.
    public static func apply(_ task: ScanTask, to current: ScanSettings) -> ScanSettings {
        var s = current
        s.source = .flatbed
        s.colorMode = .color
        s.jpegQuality = 0.9
        s.photoAutoSplit = true
        s.photoAutoDeskew = true
        s.documentMultiPage = true
        s.pdfSearchable = true
        s.adjustments = AdjustmentSettings()
        s.output.pdfSize = .standard
        s.output.afterSave = AfterSaveAction.none
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
        if settings.source == .documentFeeder { return .feeder }
        if !settings.documentMultiPage && settings.format != .pdf { return .quickScan }
        return .document
    }

    /// Whether the task can be started with a scanner offering `capabilities` (nil: none
    /// connected yet, so nothing is ruled out).
    public static func availability(of task: ScanTask, capabilities: ScannerCapabilities?) -> TaskAvailability {
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
    /// source. Changing the mode by hand, or a scanner without that source, ends the task.
    public static func fits(_ task: ScanTask, _ settings: ScanSettings) -> Bool {
        let taskDefinition = TaskCatalog.definition(task)
        guard settings.intent == taskDefinition.intent else { return false }
        if let source = taskDefinition.requiredSource { return settings.source == source }
        return true
    }

    /// How a scan with these settings is handled: the stored task's flow while it fits,
    /// otherwise by mode.
    public static func flow(of settings: ScanSettings) -> TaskFlowKind {
        if let task = settings.task, fits(task, settings) { return TaskCatalog.definition(task).flow }
        return settings.intent == .photo ? .photoSplit : .documentQueue
    }

    /// One line describing the settings, e.g. "300 dpi · Color · PDF". A PDF size other than the
    /// default `.standard` is named ("300 dpi · Color · Compact PDF"), so the line stays short
    /// enough for cards and the preset list.
    public static func summary(_ settings: ScanSettings) -> String {
        let format = settings.format == .pdf && settings.output.pdfSize != .standard
            ? "\(settings.output.pdfSize.label) \(settings.format.label)"
            : settings.format.label
        return "\(settings.resolution) dpi \u{00B7} \(settings.colorMode.label) \u{00B7} \(format)"
    }
}
