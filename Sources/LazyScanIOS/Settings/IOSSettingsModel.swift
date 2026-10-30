#if os(iOS)
import LazyScanKit
import Foundation

/// The settings screen's words that are the iPhone's own; the sections' titles and summaries are the
/// shared `InspectorSections`.
public enum IOSSettingsText {
    public static let title = "Settings"
    public static let doneLabel = "Done"
    public static let presetsLabel = "Presets"
    public static let historyLabel = "Scans"
    public static let savedLabel = "Saved files"
    /// The iPhone's saved files and scans together (`LibraryScreen`).
    public static let libraryLabel = "Library"
    /// The computer the phone is paired with (`CompanionScreen`, I20).
    public static let companionLabel = "My computer"
    public static let fileNameLabel = "File name"
    public static let saveToLabel = "Save to"
    /// Picks a save folder in Files (iCloud Drive, a USB drive); Use app folder goes back to the app's own.
    public static let chooseFolderLabel = "Choose\u{2026}"
    public static let appFolderLabel = "Use app folder"
    public static let troubleshootLabel = "Troubleshoot"
    public static let aboutLabel = "About"
    /// The ruler test page, to check that AirPrint copies come out at real size (I16).
    public static let rulerLabel = "Print test ruler"
    public static let rulerHint = "Prints a ruler to check copies come out at real size"
    public static let resetLabel = "Reset"
    public static let notCollectingReason = "Needs Collect pages"
    /// Why Collect pages is locked while the camera's Both sides is on: its fronts and backs are paired in
    /// the queue.
    public static let bothSidesCollectsReason = "Both sides pairs the pages in the stack"
    public static let docdateReason = "Needs {docdate} in File name"
    public static let onlyPDFReason = "Only for PDFs"
    public static let importingReason = "Can be changed once the import has finished"
    public static let busyReason = "Can be changed once the scan or save has finished"
    /// Why Source is locked while a side of an ID card is held (from the camera or the scanner alike).
    public static let idCardHeldReason =
        "Source is locked while a side of the ID card is held. Save or discard the card, or leave the task, to change it."
    /// In place of the Scanner section's rows while no scanner is selected: printer mode until the scanner
    /// picked is found (camera mode has no Scanner section).
    public static let noScannerReason = "No scanner is in use. Pick one in the Scanner row to change these."
    /// The About screen: what the app is built with (Apple's frameworks, and the page corner model with
    /// what runs it, whose licenses go with the app) and where scans stay.
    public static let aboutBuiltWith = "Built with Apple\u{2019}s frameworks. Pages are found with DocAligner by DocsaidLab "
        + "(Apache License 2.0) on ONNX Runtime by Microsoft (MIT License)."
    public static let aboutPrivacy = "Your scans stay on this device unless you share them."
    /// About's row to the licence texts that go with the app (`LicencesScreen`).
    public static let licencesLabel = "Licences"
    public static let licenceMissing = "Licence text missing"
    /// The camera's group, on this device only: the size its photos are taken at.
    public static let cameraTitle = "Camera"
    public static let cameraResolutionLabel = "Resolution"

    /// Why Collect pages is locked while a PDF picked in the task list takes the pages: turned off, each scan
    /// would be saved as a new file while Save still names this one.
    public static func addingToReason(_ fileName: String) -> String {
        "Adding to \(fileName)"
    }

    /// Why Source is locked under ID card, Book and Text, whose tasks need the flatbed.
    public static func needsFlatbedReason(_ kind: String) -> String {
        "\(kind) is scanned on the flatbed. Pick Document to use the feeder."
    }

    /// A photo size in the Resolution picker, "24 MP (default)" for the one taken until another is picked.
    public static func resolutionChoice(_ size: IOSPhotoSize, isDefault: Bool) -> String {
        isDefault ? "\(IOSCameraText.sizeLabel(size)) (default)" : IOSCameraText.sizeLabel(size)
    }

    /// "Version 0.1.0 (1)" from the app's Info.plist; "Version 0.1.0" without a build number.
    public static func version(_ info: [String: Any]?) -> String {
        let short: String = info?["CFBundleShortVersionString"] as? String ?? "?"
        guard let build = info?["CFBundleVersion"] as? String, !build.isEmpty else { return "Version \(short)" }
        return "Version \(short) (\(build))"
    }
}

/// A section of the settings screen: its header (title, the summary while it is collapsed, the dot when
/// something in it differs from the default, the lock while a password is on) and the name VoiceOver reads.
public struct IOSSettingsSection: Identifiable, Equatable {
    public let id: String
    public let title: String
    public let summary: String
    public let changed: Bool
    public let locked: Bool
    public let accessibilityLabel: String
}

/// The settings screen's sections: the shared `InspectorSections` (which are shown, in which order, their
/// titles, summaries and which start open), as the Mac's inspector and the Windows window lay them out.
/// The iPhone differs where it saves pictures: a queue saved as pictures (`IOSShell.savesImages`) and the
/// Text kind's held page (`AppState.saveQuickScan`) write no PDF, so Archive & password is hidden there and
/// the text beside a PDF does not count, and Output shows that page's picture format (`shownFormat`).
/// More options leaves out the action after a save, which the phone sets under Export's After saving
/// (`IOSAfterSave.thenTitle`). Camera mode has no Scanner section, the camera measuring its own pages, and
/// its Pages header counts only what runs on them (`cameraShown`). Which sections the user left open is kept
/// in the user's defaults (`storageKey`), not in presets, as on the desktop.
public enum IOSSettingsSections {
    public static let storageKey = "settings.openSections"

    /// The scan screen saves the queue as a picture a page, or the Text kind's screen its page as a picture,
    /// so no PDF is written.
    public static func savesPictures(_ s: ScanSettings) -> Bool {
        (IOSShell.collectsPages(s) && IOSShell.savesImages(s)) || (s.task == .quickScan && !s.documentMultiPage)
    }

    /// The format Output shows: the Text kind's held page (Collect pages off) is saved as a picture (JPEG
    /// unless an image format is chosen), the rest as `InspectorSections.shownFormat` says.
    public static func shownFormat(_ s: ScanSettings) -> OutputFormat {
        s.task == .quickScan && !s.documentMultiPage ? s.format.imageFormatOrJPEG : InspectorSections.shownFormat(s)
    }

    /// Archive & password and Searchable PDF apply: a save of `s` writes a PDF here.
    public static func writesPDF(_ s: ScanSettings) -> Bool {
        InspectorSections.writesPDF(s) && !savesPictures(s)
    }

    /// The Scanner section's rows are a selected scanner's; with none (printer mode's scanner not found yet)
    /// a line says where to pick one instead.
    public static func scannerRowsReason(selected: String?) -> String? {
        selected == nil ? IOSSettingsText.noScannerReason : nil
    }

    /// The sources the Source row offers: the scanner's (the flatbed until they are known), with the one
    /// chosen always listed, so the row never shows a blank value.
    public static func offeredSources(_ capabilities: ScannerCapabilities?, chosen: ScanSource) -> [ScanSource] {
        var sources: [ScanSource] = capabilities?.sources ?? [ScanSource.flatbed]
        if !sources.contains(chosen) {
            sources.append(chosen)
        }
        return sources
    }

    /// Why the Source row is locked, nil while it is free: a side of an ID card held, or a task that needs the
    /// flatbed (ID card, Book, Text) while the row offers the feeder, which would end the task under its chip.
    /// A scanner without a flatbed never has such a task (connecting to it ends the task), so the lock keeps
    /// nothing from it.
    public static func sourceLockReason(task: ScanTask?, cardHeld: Bool, sources: [ScanSource]) -> String? {
        if cardHeld { return IOSSettingsText.idCardHeldReason }
        guard let task, sources.contains(ScanSource.documentFeeder),
              TaskCatalog.definition(task).requiredSource == ScanSource.flatbed else { return nil }
        return IOSSettingsText.needsFlatbedReason(IOSShell.kind(of: task).title)
    }

    /// Also save text applies here.
    public static func textApplies(_ s: ScanSettings) -> Bool {
        InspectorSections.textApplies(s) && !savesPictures(s)
    }

    /// `s` with only the page options that run on camera mode's pages, which its Pages header counts: they
    /// are cut out of the photo along their corners already, so never cropped or straightened, and facing
    /// pages are split only from spreads taken whole (`PageProcessor.forCapture`).
    public static func cameraShown(_ s: ScanSettings) -> ScanSettings {
        var shown: ScanSettings = s
        shown.document.autoCrop = false
        shown.document.autoStraighten = false
        shown.document.splitFacingPages = PageProcessor.splitsCameraSpreads(s)
        return shown
    }

    public static func sections(_ s: ScanSettings, camera: Bool = false) -> [IOSSettingsSection] {
        let pages: ScanSettings = camera ? cameraShown(s) : s
        var result: [IOSSettingsSection] = []
        for id in InspectorSections.shown(s) {
            if id == InspectorSections.archive && !writesPDF(s) { continue }
            if id == InspectorSections.scanner && camera { continue }
            let title: String = InspectorSections.title(id, for: s)
            var summary: String = InspectorSections.summary(id, for: s)
            var changed: Bool = InspectorSections.changed(id, for: s)
            if id == InspectorSections.output {
                summary = InspectorSections.outputSummary(s, shownFormat: shownFormat(s))
                changed = InspectorSections.outputChanged(s, shownFormat: shownFormat(s))
            }
            if id == InspectorSections.pages {
                summary = InspectorSections.summary(id, for: pages)
                changed = InspectorSections.changed(id, for: pages)
            }
            if id == InspectorSections.more {
                var output: OutputOptions = s.output
                output.afterSave = AfterSaveAction.none
                summary = InspectorSections.moreSummary(output, textShown: textApplies(s))
                changed = !summary.isEmpty
            }
            let name: String = id == InspectorSections.pages
                ? InspectorSections.pagesHeaderName(pages.document)
                : InspectorSections.headerName(title, summary: summary)
            let locked: Bool = id == InspectorSections.archive && s.output.protect
            result.append(IOSSettingsSection(id: id, title: title, summary: summary, changed: changed, locked: locked,
                                             accessibilityLabel: name))
        }
        return result
    }

    /// The sections open at first: those `InspectorSections.openByDefault` names, as stored text.
    public static var defaultText: String {
        var open: Set<String> = []
        for id in InspectorSections.all where InspectorSections.openByDefault(id) {
            open.insert(id)
        }
        return text(open)
    }

    /// The open sections kept as text: their ids in the column's order, comma-separated ("" for none).
    public static func text(_ open: Set<String>) -> String {
        var ids: [String] = []
        for id in InspectorSections.all where open.contains(id) {
            ids.append(id)
        }
        return ids.joined(separator: ",")
    }

    /// The open sections read back; an id this version does not know is left out.
    public static func open(_ text: String) -> Set<String> {
        var open: Set<String> = []
        for part in text.split(separator: ",") {
            let id: String = String(part)
            if InspectorSections.all.contains(id) { open.insert(id) }
        }
        return open
    }

    /// A section is open as the user left it, or because the task started opened it (until the user closes it).
    public static func isOpen(_ id: String, stored: Set<String>, openedByTask: Set<String>) -> Bool {
        stored.contains(id) || openedByTask.contains(id)
    }
}

/// The four sliders of Adjustments on one -100...+100 scale (0 neutral), mapped onto the settings' own
/// ranges as on the Mac: brightness -1...1, contrast 0.25...4 (exponential, so 0 is exactly 1), saturation
/// 0...2, sharpness -2...2.
public enum IOSAdjustment: String, CaseIterable, Identifiable {
    case brightness
    case contrast
    case saturation
    case sharpness

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .brightness: return "Brightness"
        case .contrast: return "Contrast"
        case .saturation: return "Saturation"
        case .sharpness: return "Sharpness"
        }
    }

    public func amount(_ a: AdjustmentSettings) -> Double {
        switch self {
        case .brightness: return a.brightness * 100
        case .contrast: return log(max(a.contrast, 0.25)) / log(4.0) * 100
        case .saturation: return (a.saturation - 1) * 100
        case .sharpness: return a.sharpness * 50
        }
    }

    public func setting(_ amount: Double, in a: AdjustmentSettings) -> AdjustmentSettings {
        var changed: AdjustmentSettings = a
        switch self {
        case .brightness: changed.brightness = amount / 100
        case .contrast: changed.contrast = pow(4.0, amount / 100)
        case .saturation: changed.saturation = 1 + amount / 100
        case .sharpness: changed.sharpness = amount / 50
        }
        return changed
    }

    /// "0", "+12", "-5".
    public static func amountText(_ amount: Double) -> String {
        let rounded: Int = Int(amount.rounded())
        if rounded == 0 { return "0" }
        return rounded > 0 ? "+\(rounded)" : "\(rounded)"
    }

    /// The four sliders back to neutral; the switches stay as they are.
    public static func neutral(_ a: AdjustmentSettings) -> AdjustmentSettings {
        var changed: AdjustmentSettings = a
        changed.brightness = 0
        changed.contrast = 1
        changed.saturation = 1
        changed.sharpness = 0
        return changed
    }

    public static func isNeutral(_ a: AdjustmentSettings) -> Bool {
        a.brightness == 0 && a.contrast == 1 && a.saturation == 1 && a.sharpness == 0
    }
}

/// Export's After saving on the iPhone: what runs each time Save writes a document, checked in any
/// combination and kept in the user's defaults, not in the settings file. They run in the order of the
/// cases: Send to computer and Print take the queue, which the save empties, so they come before the file is
/// written (the save follows once the copy screen has closed); Email goes out with the saved file. Under the
/// checks, Then is the settings' own action after a save (`OutputOptions.afterSave`, kept in presets), the
/// phone's only control for it. A save that is emailed runs the email in its place (`AppState.runAfterSave`):
/// a preview, Files or the share sheet cannot show over Mail's composer.
public enum IOSAfterSave: String, CaseIterable, Identifiable {
    case send
    case print
    case email

    public var id: String { rawValue }

    /// The rows' order under After saving.
    public static let rows: [IOSAfterSave] = [.email, .print, .send]

    public static let title = "After saving"
    public static let footer = "Runs each time a document is saved. Change it any time."
    public static let thenTitle = "Then"
    /// Under Then while Email is checked.
    public static let emailInsteadReason = "Email is sent instead"

    /// The Kit's action after a save in the phone's words: Show in folder opens the Files app here.
    public static func thenLabel(_ action: AfterSaveAction) -> String {
        action == .reveal ? IOSSavedFiles.revealLabel : action.label
    }

    public static func thenHint(_ action: AfterSaveAction) -> String {
        switch action {
        case .open: return "Open the file (several: show them in Files)"
        case .reveal: return "Show the files in the Files app"
        default: return action.hint
        }
    }

    public var label: String {
        switch self {
        case .send: return IOSCompanionText.sendButton
        case .print: return "Print"
        case .email: return "Email"
        }
    }

    /// The user's defaults key the row's check is kept under.
    public var key: String { "afterSave.\(rawValue)" }

    /// The checked actions in the order they run; Send to computer only while a computer is paired.
    public static func steps(_ defaults: UserDefaults, paired: Bool) -> [IOSAfterSave] {
        var steps: [IOSAfterSave] = []
        for action in allCases where defaults.bool(forKey: action.key) {
            if action == .send && !paired { continue }
            steps.append(action)
        }
        return steps
    }

    /// Why Send to computer's pages have not gone when the send raised no alert of its own: the computer did not
    /// answer, or no longer knows this phone, and the document waits in the outbox (`waiting`), or in the cloud
    /// folder when every one waiting is there (`inFolder`). Nil when nothing waits or the computer answered.
    public static func notSentMessage(_ status: CompanionStatus, waiting: Int, inFolder: Int = 0) -> String? {
        guard waiting > 0 else { return nil }
        switch status {
        case .unreachable(let reason):
            if inFolder == waiting {
                return reason + " The document is in the cloud folder; the computer takes it from there."
            }
            return reason + " The pages wait on this phone and are sent once it answers."
        case .unpaired(let name):
            return CompanionText.unpairedMessage(name) + " The pages were not sent."
        case .notPaired, .checking, .reachable:
            return nil
        }
    }
}
#endif
