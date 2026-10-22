import Foundation

// The settings column's sections: which of them start open, which a task opens, and the summary a
// collapsed section's header shows. Both apps lay their settings out in these sections. Twin of
// windows/CompleteScanner.Core/InspectorSections.cs (same rules, same tests).

/// The settings column's sections, in order: the task's own section (Photocopy or Receipts), Scanner,
/// Output, Adjustments, Pages, Split into documents, Archive & password and More options. The task's
/// section, Scanner and Output start open; a collapsed header shows what is on in it, so a setting
/// other than the default is never out of sight. Twin of C# `InspectorSections`.
public enum InspectorSections {
    public static let task = "task"
    public static let scanner = "scanner"
    public static let output = "output"
    public static let adjustments = "adjustments"
    public static let pages = "pages"
    public static let split = "split"
    public static let archive = "archive"
    public static let more = "more"

    /// Every section, in the order the column shows them.
    public static let all: [String] = [task, scanner, output, adjustments, pages, split, archive, more]

    /// The section's header: "Scanner", "Split into documents"; the task's section is named by its task.
    public static func title(_ section: String) -> String {
        switch section {
        case task: return "Task"
        case scanner: return "Scanner"
        case output: return "Output"
        case adjustments: return "Adjustments"
        case pages: return "Pages"
        case split: return "Split into documents"
        case archive: return "Archive & password"
        case more: return "More options"
        default: return section
        }
    }

    /// The task section, Scanner and Output start open; the rest start collapsed.
    public static func openByDefault(_ section: String) -> Bool {
        section == task || section == scanner || section == output
    }

    /// The section a task opens when it is started, if any.
    public static func openedBy(_ scanTask: ScanTask) -> String? {
        switch scanTask {
        case .photoRestore: return adjustments
        case .book: return pages
        case .batch: return split
        case .archive: return archive
        default: return nil
        }
    }

    /// "Flatbed · 300 dpi · Color", "Feeder · both sides · 300 dpi · Gray".
    public static func scannerSummary(_ s: ScanSettings) -> String {
        var parts: [String] = [s.source == .documentFeeder ? "Feeder" : "Flatbed"]
        if s.source == .documentFeeder && s.duplex != .off { parts.append("both sides") }
        parts.append("\(s.resolution) dpi")
        let color: String
        switch s.colorMode {
        case .grayscale: color = "Gray"
        case .blackWhite: color = "B&W"
        case .color: color = "Color"
        }
        parts.append(color)
        return parts.joined(separator: " \u{00B7} ")
    }

    /// A scanner setting differs from a fresh install's.
    public static func scannerChanged(_ s: ScanSettings) -> Bool {
        let d: ScanSettings = ScanSettings()
        return s.source != d.source || s.duplex != d.duplex || s.paperSize != d.paperSize
            || s.resolution != d.resolution || s.colorMode != d.colorMode
    }

    /// "PDF · Standard", "Word", "JPEG": the format the save uses, and a PDF's size. `shownFormat`: the
    /// format the column shows (photos save an image, receipts a PDF or an image).
    public static func outputSummary(_ s: ScanSettings, shownFormat: OutputFormat) -> String {
        let format: String
        switch shownFormat {
        case .word: format = "Word"
        case .text: format = "Text"
        default: format = shownFormat.label
        }
        if shownFormat == .pdf && s.intent == .document {
            return format + " \u{00B7} " + s.output.pdfSize.label
        }
        return format
    }

    /// The format differs from a fresh install's for the mode (JPEG for photos, PDF otherwise), or a
    /// PDF shown has a size other than a fresh install's.
    public static func outputChanged(_ s: ScanSettings, shownFormat: OutputFormat) -> Bool {
        let d: ScanSettings = ScanSettings()
        let defaultFormat: OutputFormat = s.intent == .photo ? .jpeg : d.format
        return shownFormat != defaultFormat
            || (shownFormat == .pdf && s.output.pdfSize != d.output.pdfSize)
    }

    /// "Edited" when a slider or a switch other than Auto enhance is changed, "Auto" for Auto enhance
    /// alone, else "".
    public static func adjustmentsSummary(_ a: AdjustmentSettings) -> String {
        let sliders: Bool = a.brightness != 0 || a.contrast != 1 || a.saturation != 1 || a.sharpness != 0
        let edited: Bool = sliders || a.descreen || a.restoreFadedColors
        if edited { return "Edited" }
        return a.autoEnhance ? "Auto" : ""
    }

    /// The page options that are on, at most two then "+N": "Skip blank · Upright +1"; "" when none is.
    public static func pagesSummary(_ d: DocumentOptions) -> String {
        var on: [String] = []
        if d.removeBlankPages { on.append("Skip blank") }
        if d.autoCrop { on.append("Crop") }
        if d.autoStraighten { on.append("Straighten") }
        if d.autoRotate { on.append("Upright") }
        if d.splitFacingPages { on.append("Facing pages") }
        if on.count <= 2 { return on.joined(separator: " \u{00B7} ") }
        return "\(on[0]) \u{00B7} \(on[1]) +\(on.count - 2)"
    }

    /// How many page options are on (the header's accessibility label: "Pages, 2 options on").
    public static func pagesOn(_ d: DocumentOptions) -> Int {
        let flags: [Bool] = [d.removeBlankPages, d.autoCrop, d.autoStraighten, d.autoRotate, d.splitFacingPages]
        return flags.filter { (on: Bool) -> Bool in on }.count
    }

    /// "Off", "Separator sheets", "Blank sheets", "Every 3 sheets", "QR codes".
    public static func splitSummary(_ d: DocumentOptions) -> String {
        let sheets: Int = DocumentSplitter.clampSheetCount(d.splitSheetCount)
        switch d.splitMode {
        case .separatorSheet: return "Separator sheets"
        case .blankSheet: return "Blank sheets"
        case .sheetCount: return sheets == 1 ? "Every sheet" : "Every \(sheets) sheets"
        case .barcode: return "QR codes"
        case .none: return "Off"
        }
    }

    /// "Off", "PDF/A" or "Password on" (the password wins: the two can't be on together).
    public static func archiveSummary(_ o: OutputOptions) -> String {
        if o.protect { return "Password on" }
        return o.archival ? "PDF/A" : "Off"
    }

    /// "Open after saving", ".txt", both, or "". `textShown`: Also save text applies (a PDF is saved),
    /// so it counts.
    public static func moreSummary(_ o: OutputOptions, textShown: Bool) -> String {
        var parts: [String] = []
        if o.afterSave != AfterSaveAction.none {
            var label: String = o.afterSave.label
            while label.hasSuffix("\u{2026}") { label.removeLast() }
            parts.append(label + " after saving")
        }
        if textShown && o.alsoSaveText { parts.append(".txt") }
        return parts.joined(separator: " \u{00B7} ")
    }

    /// The header's accessibility label: the title, then the summary when there is one ("Scanner,
    /// Flatbed · 300 dpi · Color").
    public static func headerName(_ title: String, summary: String) -> String {
        summary.isEmpty ? title : title + ", " + summary
    }

    /// The Pages header's accessibility label: how many options are on ("Pages, 2 options on"), or just "Pages".
    public static func pagesHeaderName(_ d: DocumentOptions) -> String {
        let on: Int = pagesOn(d)
        let heading: String = title(pages)
        return on == 0 ? heading : "\(heading), \(on) option\(on == 1 ? "" : "s") on"
    }

    // MARK: The sections for a setting

    /// The sections shown for `s`, in order (hide what can't apply): the task's own for Photocopy and
    /// Receipts; Scanner, Output and Adjustments always; Pages and Split into documents for document pages
    /// outside those two tasks; Archive & password while a save writes a PDF (`writesPDF`); More options always.
    public static func shown(_ s: ScanSettings) -> [String] {
        let flow: TaskFlowKind = TaskCatalog.flow(of: s)
        let pageSections: Bool = s.intent == .document && flow != .copy && flow != .receiptSplit
        var result: [String] = []
        for section in all {
            switch section {
            case task:
                if taskTitle(s) != nil { result.append(section) }
            case pages, split:
                if pageSections { result.append(section) }
            case archive:
                if writesPDF(s) { result.append(section) }
            default:
                result.append(section)
            }
        }
        return result
    }

    /// The task's own section's header: "Photocopy" or "Receipts"; nil for a task without one.
    public static func taskTitle(_ s: ScanSettings) -> String? {
        switch TaskCatalog.flow(of: s) {
        case .copy: return "Photocopy"
        case .receiptSplit: return "Receipts"
        default: return nil
        }
    }

    /// A section's header for `s`: the task's own named by its task, Output named "Photos" in Photos mode,
    /// the others by `title(_:)`.
    public static func title(_ section: String, for s: ScanSettings) -> String {
        if section == task { return taskTitle(s) ?? title(task) }
        if section == output && s.intent == .photo { return "Photos" }
        return title(section)
    }

    /// The format the column shows: receipts save a PDF or an image, photos an image, else the format.
    public static func shownFormat(_ s: ScanSettings) -> OutputFormat {
        if TaskCatalog.flow(of: s) == .receiptSplit { return s.format.pageFormat }
        if s.intent == .photo { return s.format.imageFormatOrJPEG }
        return s.format
    }

    /// A save of `s` writes a PDF, so Archive & password apply: a queue of image pages too, receipts and the
    /// ID card saved as a PDF, and a copy also saved as a PDF; never photos.
    public static func writesPDF(_ s: ScanSettings) -> Bool {
        guard s.intent == .document else { return false }
        switch TaskCatalog.flow(of: s) {
        case .copy:
            return s.taskOptions.copyAlsoSavePdf
        case .receiptSplit, .idCard:
            return s.format.pageFormat == .pdf
        default:
            return s.format.savesPDF(collectsPages: s.documentMultiPage)
        }
    }

    /// Also save text applies: document pages collected or saved as a PDF, and receipts saved as PDFs.
    public static func textApplies(_ s: ScanSettings) -> Bool {
        guard s.intent == .document else { return false }
        let flow: TaskFlowKind = TaskCatalog.flow(of: s)
        if flow == .receiptSplit { return s.format.pageFormat == .pdf }
        return flow == .documentQueue && s.format.savesPDF(collectsPages: s.documentMultiPage)
    }

    /// The summary a collapsed header shows for `s`; "" for none (the task's section has none).
    public static func summary(_ section: String, for s: ScanSettings) -> String {
        switch section {
        case scanner: return scannerSummary(s)
        case output: return outputSummary(s, shownFormat: shownFormat(s))
        case adjustments: return adjustmentsSummary(s.adjustments)
        case pages: return pagesSummary(s.document)
        case split: return splitSummary(s.document)
        case archive: return archiveSummary(s.output)
        case more: return moreSummary(s.output, textShown: textApplies(s))
        default: return ""
        }
    }

    /// Something in the section differs from the default for `s` (the collapsed header's dot).
    public static func changed(_ section: String, for s: ScanSettings) -> Bool {
        switch section {
        case scanner: return scannerChanged(s)
        case output: return outputChanged(s, shownFormat: shownFormat(s))
        case split: return s.document.splitMode != SplitMode.none
        case archive: return s.output.protect || s.output.archival
        case task: return false
        default: return !summary(section, for: s).isEmpty
        }
    }

    /// The header's accessibility label for `s`: Pages counts its options, the others are `headerName`.
    public static func accessibleName(_ section: String, for s: ScanSettings) -> String {
        if section == pages { return pagesHeaderName(s.document) }
        return headerName(title(section, for: s), summary: summary(section, for: s))
    }
}
