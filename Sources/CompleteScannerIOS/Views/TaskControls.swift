#if os(iOS)
import CompleteScannerKit
import SwiftUI

/// The PDF's Archive and Password choices as the scan screen shows them: the two exclude each other (a
/// PDF/A file can't have a password), so while one is on the other is off, dimmed, with its short reason;
/// a settings file with both on shows the password (`PDFWriteOptions.forOutput` writes it). The same rule
/// as the Mac's inspector and the Windows window.
enum IOSPDFOptions {
    /// The Archive switch is on: archival, and no password.
    static func archivalShown(_ output: OutputOptions) -> Bool {
        output.archival && !output.protect
    }

    /// The Archive switch turned on or off; it can't be turned on while the password is.
    static func settingArchival(_ on: Bool, in output: OutputOptions) -> OutputOptions {
        var changed: OutputOptions = output
        changed.archival = on && !output.protect
        return changed
    }

    /// The Password switch turned on or off: on turns archival PDF off; archival keeps only what its switch
    /// showed, so turning the password off later leaves it off.
    static func settingProtect(_ on: Bool, in output: OutputOptions) -> OutputOptions {
        var changed: OutputOptions = output
        let shown: Bool = archivalShown(output)
        changed.archival = shown && !on
        changed.protect = on
        return changed
    }

    /// The short reason beside a dimmed switch: the Archive switch's while the password is on, the
    /// Password switch's while archival is; nil when neither is dimmed.
    static func archivalReason(_ output: OutputOptions) -> String? {
        output.protect ? PDFA.notWithPasswordReason : nil
    }

    static func protectReason(_ output: OutputOptions) -> String? {
        archivalShown(output) ? PDFProtection.notWithArchivalReason : nil
    }

    /// The pages' text in a .txt file beside the PDF, as the Mac's "Also save text".
    static let alsoSaveTextLabel = "Also save text (.txt)"
    static let alsoSaveTextHint = "Saves the text in a .txt file next to the PDF"
}

/// The camera's buttons between shots for the task set up: No back (flip & capture, while a back is
/// due), Now the backs and Put in order or Combine anyway (fronts first), and New document (Separate
/// documents, the main button there; Command-N). Nothing for the other tasks. `onDark` draws them for the
/// camera's black screen: the bordered ones white, the prominent ones in the accent color, as the camera's
/// own buttons are (a white fill would hide their white labels).
struct CameraTaskButtons: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var importer: IOSImportSession
    var onDark: Bool = false

    var body: some View {
        let busy: Bool = state.isBusy || importer.isImporting
        HStack(spacing: 10) {
            if let sides = state.cameraSides {
                if sides.canSkipBack {
                    Button(CameraTaskCatalog.noBackLabel) {
                        state.skipCameraBack()
                    }
                    .buttonStyle(.bordered)
                    .tint(borderedTint)
                    .disabled(busy)
                    .accessibilityIdentifier("task.noBack")
                }
                if sides.canStartBacks {
                    Button(CameraTaskCatalog.startBacksLabel) {
                        state.startCameraBacks()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy)
                    .accessibilityIdentifier("task.startBacks")
                }
                if sides.canPutInOrder {
                    Button(state.sidesMismatch == nil ? CameraTaskCatalog.putInOrderLabel : CameraTaskCatalog.combineLabel) {
                        state.putCameraSidesInOrder()
                    }
                    .buttonStyle(.bordered)
                    .tint(borderedTint)
                    .disabled(busy)
                    .accessibilityIdentifier("task.putInOrder")
                }
            }
            if state.offersNewDocument {
                Button {
                    state.startNewDocument()
                } label: {
                    Label(CameraTaskCatalog.newDocumentLabel, systemImage: "doc.badge.plus")
                }
                .buttonStyle(.borderedProminent)
                .disabled(busy || !state.canStartNewDocument)
                .keyboardShortcut(IOSShortcuts.newDocument.keyboardShortcut)
                .accessibilityHint(Text(CameraTaskCatalog.newDocumentPrompt))
                .accessibilityIdentifier("task.newDocument")
            }
        }
    }

    private var borderedTint: Color {
        onDark ? Color.white : Color.accentColor
    }
}

/// How the camera takes the task set up: Flip & capture or Fronts, then backs for the two-sided task;
/// Page by page or Whole spread for a book (`TaskOptions.cameraFrontsFirst`, `cameraSpreads`), and while
/// spreads are cut (whole spreads, or a network scanner's scans) whether the book reads right to left
/// (`bookRightToLeft`, as the Mac's inspector has it; `IOSShell.showsRightToLeft`).
/// Nothing for the other tasks. Kept in the settings, as the task's other choices are.
struct TaskWayPicker: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var importer: IOSImportSession

    var body: some View {
        if state.activeTask == .twoSided {
            Picker("Sides", selection: frontsFirst) {
                Text(CameraTaskCatalog.flipLabel).tag(false)
                Text(CameraTaskCatalog.frontsFirstLabel).tag(true)
            }
            .pickerStyle(.segmented)
            .disabled(state.isBusy || importer.isImporting)
            .accessibilityIdentifier("task.sidesWay")
        } else if state.activeTask == .book {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Book", selection: spreads) {
                    Text(CameraTaskCatalog.pageByPageLabel).tag(false)
                    Text(CameraTaskCatalog.wholeSpreadLabel).tag(true)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("task.bookWay")
                if IOSShell.showsRightToLeft(state.settings, device: selectedDevice) {
                    Toggle(CameraTaskCatalog.rightToLeftLabel, isOn: rightToLeft)
                        .accessibilityHint(Text(CameraTaskCatalog.rightToLeftHint))
                        .accessibilityIdentifier("task.rightToLeft")
                }
            }
            .disabled(state.isBusy || importer.isImporting)
        }
    }

    private var selectedDevice: ScannerInfo? {
        let selected: String? = state.selectedDeviceID
        return state.devices.first(where: { (info: ScannerInfo) -> Bool in info.id == selected })
    }

    private var frontsFirst: Binding<Bool> {
        let appState: AppState = state
        return Binding<Bool>(
            get: { appState.settings.taskOptions.cameraFrontsFirst },
            set: { (on: Bool) in
                appState.settings.taskOptions.cameraFrontsFirst = on
            })
    }

    private var spreads: Binding<Bool> {
        let appState: AppState = state
        return Binding<Bool>(
            get: { appState.settings.taskOptions.cameraSpreads },
            set: { (on: Bool) in
                appState.settings.taskOptions.cameraSpreads = on
            })
    }

    private var rightToLeft: Binding<Bool> {
        let appState: AppState = state
        return Binding<Bool>(
            get: { appState.settings.taskOptions.bookRightToLeft },
            set: { (on: Bool) in
                appState.settings.taskOptions.bookRightToLeft = on
            })
    }
}

/// Separate documents' separator sheets: Patch code or QR code (with the name the QR sheet carries), and
/// Separator sheet, which saves the sheet as a PDF to print here or elsewhere (Share). A photographed
/// sheet's patch code is read once the page matches a paper size, so its bars are measured in inches.
struct SeparatorSheetRow: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        if state.activeTask == .batch {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Separators", selection: qrSheets) {
                    Text(CameraTaskCatalog.patchCodeLabel).tag(false)
                    Text(CameraTaskCatalog.qrCodeLabel).tag(true)
                }
                .pickerStyle(.segmented)
                .disabled(state.isBusy)
                .accessibilityIdentifier("separator.kind")
                HStack(spacing: 10) {
                    if state.settings.document.splitMode == .barcode {
                        TextField("Name (optional)", text: $state.qrSheetName)
                            .textFieldStyle(.roundedBorder)
                            .disabled(state.isBusy)
                            .accessibilityIdentifier("separator.name")
                    }
                    Button {
                        state.saveSeparatorSheet()
                    } label: {
                        Label(CameraTaskCatalog.separatorSheetLabel, systemImage: "doc.text")
                    }
                    .buttonStyle(.bordered)
                    .disabled(state.isBusy)
                    .accessibilityHint(Text("Saves the sheet as a PDF to print"))
                    .accessibilityIdentifier("separator.save")
                }
                Label(CameraTaskCatalog.separatorHint, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
            }
        }
    }

    /// QR code sheets: split at barcode or QR sheets; Patch code: at separator sheets.
    private var qrSheets: Binding<Bool> {
        let appState: AppState = state
        return Binding<Bool>(
            get: { appState.settings.document.splitMode == .barcode },
            set: { (on: Bool) in
                appState.setSplitMode(on ? SplitMode.barcode : SplitMode.separatorSheet)
            })
    }
}

/// Options' Both sides for the camera: the two-sided task under the hood (`IOSShell.settingBothSides`), so
/// the camera takes each sheet's front and back; how it does is `TaskWayPicker`'s. Dimmed with its reason
/// while the scanner set up has no feeder, as the two-sided task's tile was.
struct BothSidesToggle: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var importer: IOSImportSession

    var body: some View {
        let on: Bool = state.activeTask == .twoSided
        let availability: TaskAvailability = TaskCatalog.availability(of: .twoSided, capabilities: state.capabilities)
        Toggle("Both sides", isOn: bothSides)
            .disabled(state.isBusy || importer.isImporting || (!on && !availability.isAvailable))
            .accessibilityHint(Text("Takes the front and back of each sheet"))
            .accessibilityIdentifier("options.bothSides")
        if !on, let reason = availability.reason {
            OptionReason(text: reason)
        }
    }

    private var bothSides: Binding<Bool> {
        let appState: AppState = state
        return Binding<Bool>(
            get: { appState.activeTask == .twoSided },
            set: { (on: Bool) in
                // Off goes back to the flatbed, unless the scanner has none.
                let s: ScanSettings = IOSShell.settingBothSides(on, in: appState.settings)
                appState.settings = SettingsAdapter.adapt(s, to: appState.capabilities).settings
            })
    }
}

/// Options' Restore faded colours for Photos: Restore old photos under the hood (`IOSShell.settingRestore`).
struct RestoreToggle: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var importer: IOSImportSession

    var body: some View {
        Toggle("Restore faded colours", isOn: restore)
            .disabled(state.isBusy || importer.isImporting)
            .accessibilityHint(Text("Brings back the colours of old prints"))
            .accessibilityIdentifier("options.restore")
    }

    private var restore: Binding<Bool> {
        let appState: AppState = state
        return Binding<Bool>(
            get: { appState.settings.adjustments.restoreFadedColors },
            set: { (on: Bool) in
                appState.settings = IOSShell.settingRestore(on, in: appState.settings)
            })
    }
}

/// Options' Export, while the scan screen collects pages: the format (a PDF, a JPEG a page, Word or text),
/// for a document Separate documents (the Separate documents task, with its separator sheets; dimmed
/// without a feeder as its tile was), One PDF per page for a PDF that is not split otherwise, and the PDF's
/// choices while Save writes one.
struct ExportOptions: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var importer: IOSImportSession

    var body: some View {
        let s: ScanSettings = state.settings
        let busy: Bool = state.isBusy || importer.isImporting
        let separates: Bool = IOSShell.separatesDocuments(s)
        let availability: TaskAvailability = TaskCatalog.availability(of: .batch, capabilities: state.capabilities)
        VStack(alignment: .leading, spacing: 12) {
            Picker("Format", selection: format) {
                ForEach(IOSShell.exportFormats) { (choice: OutputFormat) in
                    Text(Self.label(choice)).tag(choice)
                }
            }
            .pickerStyle(.segmented)
            .disabled(busy)
            .accessibilityIdentifier("options.format")
            // A book stays a book: its spreads are split, not its stack.
            if IOSShell.shownKind(s) == .document {
                Toggle("Separate documents", isOn: separate)
                    .disabled(busy || (!separates && !availability.isAvailable))
                    .accessibilityHint(Text("Splits the pages into documents at separator sheets"))
                    .accessibilityIdentifier("options.separate")
                if !separates, let reason = availability.reason {
                    OptionReason(text: reason)
                }
                SeparatorSheetRow()
            }
            if !separates && IOSShell.exportFormat(s) == .pdf {
                // A sheet's front and back stay together.
                Toggle(s.source == .documentFeeder && s.duplex != .off ? "One PDF per sheet" : "One PDF per page",
                       isOn: eachPage)
                    .disabled(busy)
                    .accessibilityIdentifier("options.eachPage")
            }
            if IOSShell.offersPDFOptions(s) {
                PDFOptionsSection()
            }
        }
    }

    /// The segment's short name: "PDF", "JPEG", "Word", "Text".
    static func label(_ format: OutputFormat) -> String {
        switch format {
        case .word: return "Word"
        case .text: return "Text"
        default: return format.label
        }
    }

    private var format: Binding<OutputFormat> {
        let appState: AppState = state
        return Binding<OutputFormat>(
            get: { IOSShell.exportFormat(appState.settings) },
            set: { (choice: OutputFormat) in
                var s: ScanSettings = appState.settings
                s.format = choice
                appState.settings = IOSShell.keepingKind(s)
            })
    }

    private var separate: Binding<Bool> {
        let appState: AppState = state
        return Binding<Bool>(
            get: { IOSShell.separatesDocuments(appState.settings) },
            set: { (on: Bool) in
                let s: ScanSettings = IOSShell.settingSeparate(on, in: appState.settings)
                appState.settings = SettingsAdapter.adapt(s, to: appState.capabilities).settings
            })
    }

    private var eachPage: Binding<Bool> {
        let appState: AppState = state
        return Binding<Bool>(
            get: { IOSShell.savesEachPage(appState.settings) },
            set: { (on: Bool) in
                appState.settings = IOSShell.settingEachPage(on, in: appState.settings)
            })
    }
}

/// Why an option is dimmed, in one short line under it.
private struct OptionReason: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "info.circle")
            .font(.caption)
            .foregroundStyle(Color.secondary)
    }
}

/// The PDF's choices while Save writes one: its size (Best, Standard, Compact, Smallest), then Archive
/// (PDF/A) and Password, which exclude each other (`IOSPDFOptions`), and the pages' text in a .txt file
/// beside the PDF (`OutputOptions.alsoSaveText`, as on the Mac). The password itself is asked for when
/// saving (`IOSPasswordPrompt`) and never kept.
struct PDFOptionsSection: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        let output: OutputOptions = state.settings.output
        VStack(alignment: .leading, spacing: 8) {
            Picker("PDF size", selection: pdfSize) {
                ForEach(PDFSizePreset.displayOrder, id: \.self) { (size: PDFSizePreset) in
                    Text(size.label).tag(size)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("pdf.size")
            Toggle(PDFA.optionLabel, isOn: archival)
                .disabled(output.protect)
                .accessibilityHint(Text(output.protect ? PDFA.cannotProtectNote : PDFA.optionHint))
                .accessibilityIdentifier("pdf.archival")
            if let reason = IOSPDFOptions.archivalReason(output) {
                reasonLine(reason)
            }
            Toggle(PDFProtection.optionLabel, isOn: protect)
                .disabled(IOSPDFOptions.archivalShown(output))
                .accessibilityHint(Text(IOSPDFOptions.archivalShown(output) ? PDFA.cannotProtectNote : PDFProtection.optionHint))
                .accessibilityIdentifier("pdf.protect")
            if let reason = IOSPDFOptions.protectReason(output) {
                reasonLine(reason)
            }
            Toggle(IOSPDFOptions.alsoSaveTextLabel, isOn: alsoSaveText)
                .accessibilityHint(Text(IOSPDFOptions.alsoSaveTextHint))
                .accessibilityIdentifier("pdf.alsoSaveText")
        }
        .disabled(state.isBusy)
    }

    private func reasonLine(_ reason: String) -> some View {
        Label(reason, systemImage: "lock")
            .font(.caption)
            .foregroundStyle(Color.secondary)
    }

    private var pdfSize: Binding<PDFSizePreset> {
        let appState: AppState = state
        return Binding<PDFSizePreset>(
            get: { appState.settings.output.pdfSize },
            set: { (size: PDFSizePreset) in
                appState.settings.output.pdfSize = size
            })
    }

    private var archival: Binding<Bool> {
        let appState: AppState = state
        return Binding<Bool>(
            get: { IOSPDFOptions.archivalShown(appState.settings.output) },
            set: { (on: Bool) in
                var s: ScanSettings = appState.settings
                s.output = IOSPDFOptions.settingArchival(on, in: s.output)
                appState.settings = IOSShell.keepingKind(s)
            })
    }

    private var alsoSaveText: Binding<Bool> {
        let appState: AppState = state
        return Binding<Bool>(
            get: { appState.settings.output.alsoSaveText },
            set: { (on: Bool) in
                appState.settings.output.alsoSaveText = on
            })
    }

    private var protect: Binding<Bool> {
        let appState: AppState = state
        return Binding<Bool>(
            get: { appState.settings.output.protect },
            set: { (on: Bool) in
                var s: ScanSettings = appState.settings
                s.output = IOSPDFOptions.settingProtect(on, in: s.output)
                appState.settings = IOSShell.keepingKind(s)
            })
    }
}
#endif
