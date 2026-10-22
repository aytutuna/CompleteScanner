#if os(iOS)
import CompleteScannerKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings: the presets, this session's scans and the saved files first, then the settings in the shared
/// sections (`IOSSettingsSections`, built on `InspectorSections`: which are shown, in which order, their
/// titles and the summaries their collapsed headers show; the task's own, Scanner and Output start open),
/// then Troubleshoot and About. My computer (since I20) pairs the phone with a computer and sends to it
/// (`CompanionScreen`). Which sections are open is kept for the user, not in presets; a task
/// started opens the section it needs (`AppState.sectionsOpenedByTask`) until it is closed. While an import
/// runs the settings cannot be changed: its pages belong to the task and format it started with.
struct SettingsScreen: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var importer: IOSImportSession
    /// Makes the troubleshooter's Add by address.
    let makeAddModel: () -> IOSAddScannerModel
    /// Runs once a preset's settings are in use (the scan screen opens).
    let onPresetApplied: @MainActor () -> Void
    /// Closes the sheet (Done); nil: no Done button.
    var onClose: (() -> Void)?
    /// The troubleshooter over Settings; the root view's, so the error alert in the sheet can open it too.
    @Binding var showsTroubleshooter: Bool
    /// Browses the computers on the network for My computer; nil when the app does not (`-demoScanner`).
    var companion: IOSCompanionBrowser?
    @AppStorage(IOSSettingsSections.storageKey) private var openText: String = IOSSettingsSections.defaultText

    var body: some View {
        let sections: [IOSSettingsSection] = IOSSettingsSections.sections(state.settings)
        Form {
            Section {
                NavigationLink {
                    PresetsScreen(onApplied: onPresetApplied)
                } label: {
                    Label(IOSSettingsText.presetsLabel, systemImage: "slider.horizontal.3")
                }
                .accessibilityIdentifier("settings.presets")
                NavigationLink {
                    HistoryScreen()
                } label: {
                    Label(IOSSettingsText.historyLabel, systemImage: "clock.arrow.circlepath")
                }
                .accessibilityIdentifier("settings.history")
                NavigationLink {
                    SavedFilesScreen()
                } label: {
                    Label(IOSSettingsText.savedLabel, systemImage: "tray")
                }
                .accessibilityIdentifier("settings.saved")
                NavigationLink {
                    CompanionScreen(state: state, browser: companion)
                } label: {
                    Label(IOSSettingsText.companionLabel, systemImage: "laptopcomputer.and.iphone")
                }
                .accessibilityIdentifier("settings.companion")
            }
            if importer.isImporting {
                Section {
                    ReasonLine(text: IOSSettingsText.importingReason)
                }
            }
            ForEach(sections) { (section: IOSSettingsSection) in
                Section {
                    DisclosureGroup(isExpanded: openBinding(section.id)) {
                        SettingsSectionRows(id: section.id)
                            .disabled(importer.isImporting)
                    } label: {
                        SettingsSectionHeader(section: section, collapsed: !isOpen(section.id))
                    }
                    .accessibilityIdentifier("settings.section.\(section.id)")
                }
            }
            Section {
                if state.hasPrinter {
                    Button {
                        state.printRulerPage()
                    } label: {
                        Label(IOSSettingsText.rulerLabel, systemImage: "ruler")
                    }
                    .accessibilityHint(Text(IOSSettingsText.rulerHint))
                    .accessibilityIdentifier("settings.ruler")
                }
                Button {
                    showsTroubleshooter = true
                } label: {
                    Label(IOSSettingsText.troubleshootLabel, systemImage: "questionmark.circle")
                }
                .accessibilityIdentifier("settings.troubleshoot")
                NavigationLink {
                    AboutScreen()
                } label: {
                    Label(IOSSettingsText.aboutLabel, systemImage: "info.circle")
                }
                .accessibilityIdentifier("settings.about")
            }
        }
        .disabled(state.isBusy)
        .navigationTitle(IOSSettingsText.title)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if let close = onClose {
                    Button(IOSSettingsText.doneLabel) {
                        close()
                    }
                    .accessibilityIdentifier("settings.done")
                }
            }
        }
        .sheet(isPresented: $showsTroubleshooter) {
            TroubleshooterScreen(makeAddModel: makeAddModel, onClose: closeTroubleshooter)
                .environmentObject(state)
        }
    }

    private func isOpen(_ id: String) -> Bool {
        IOSSettingsSections.isOpen(id, stored: IOSSettingsSections.open(openText),
                                   openedByTask: state.sectionsOpenedByTask)
    }

    /// Open as the user left it or as a task opened it; closing it forgets the task's opening, as on the Mac.
    private func openBinding(_ id: String) -> Binding<Bool> {
        let appState: AppState = state
        let stored: Binding<String> = $openText
        return Binding<Bool>(
            get: {
                IOSSettingsSections.isOpen(id, stored: IOSSettingsSections.open(stored.wrappedValue),
                                           openedByTask: appState.sectionsOpenedByTask)
            },
            set: { (open: Bool) in
                appState.sectionsOpenedByTask.remove(id)
                var current: Set<String> = IOSSettingsSections.open(stored.wrappedValue)
                if open {
                    current.insert(id)
                } else {
                    current.remove(id)
                }
                stored.wrappedValue = IOSSettingsSections.text(current)
            })
    }

    private func closeTroubleshooter() {
        showsTroubleshooter = false
    }
}

/// A section's header: its title, and while it is collapsed its summary (with a lock while a password is
/// on) and a dot when something in it differs from the default.
private struct SettingsSectionHeader: View {
    let section: IOSSettingsSection
    let collapsed: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(section.title)
                .foregroundStyle(Color.primary)
            Spacer(minLength: 8)
            if collapsed {
                if section.locked {
                    Image(systemName: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                }
                if !section.summary.isEmpty {
                    Text(section.summary)
                        .font(.subheadline)
                        .foregroundStyle(Color.secondary)
                        .lineLimit(1)
                }
                if section.changed {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 6, height: 6)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(section.accessibilityLabel))
    }
}

/// The settings of one section.
private struct SettingsSectionRows: View {
    let id: String

    var body: some View {
        switch id {
        case InspectorSections.task:
            TaskSettingsRows()
        case InspectorSections.scanner:
            ScannerSettingsRows()
        case InspectorSections.output:
            OutputSettingsRows()
        case InspectorSections.adjustments:
            AdjustmentSettingsRows()
        case InspectorSections.pages:
            PageSettingsRows()
        case InspectorSections.split:
            SplitSettingsRows()
        case InspectorSections.archive:
            ArchiveSettingsRows()
        default:
            MoreSettingsRows()
        }
    }
}

/// A reason beside a dimmed setting, or a consequence not to miss: an icon and a few words.
private struct ReasonLine: View {
    let text: String
    var systemImage: String = "info.circle"

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Receipts: named by the date printed on them, one PDF for all. The photocopy's choices are on its own
/// screen, once the page is in (`CopyScreen`).
private struct TaskSettingsRows: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        if state.isReceiptFlow {
            let options: TaskOptions = state.settings.taskOptions
            let pdf: Bool = state.settings.format.pageFormat == OutputFormat.pdf
            Toggle("Name by receipt date", isOn: nameByDate)
                .accessibilityHint(Text("Uses the date printed on the receipt, or today"))
            if options.receiptNameByDate && !Receipts.namesByDate(state.settings) {
                ReasonLine(text: IOSSettingsText.docdateReason)
            }
            Toggle("One PDF for all", isOn: combine)
                .disabled(!pdf)
                .accessibilityHint(Text(combineHint(pdf)))
            if !pdf {
                ReasonLine(text: IOSSettingsText.onlyPDFReason)
            }
        } else {
            ReasonLine(text: IOSCopyText.settingsNote)
        }
    }

    private func combineHint(_ pdf: Bool) -> String {
        pdf ? "Off: a PDF for each receipt" : "Only for PDFs: each receipt is saved as an image of its own."
    }

    private var nameByDate: Binding<Bool> {
        let appState: AppState = state
        return Binding<Bool>(
            get: { appState.settings.taskOptions.receiptNameByDate },
            set: { (on: Bool) in
                appState.setReceiptNameByDate(on)
            })
    }

    private var combine: Binding<Bool> {
        let appState: AppState = state
        return Binding<Bool>(
            get: { appState.settings.taskOptions.receiptCombine },
            set: { (on: Bool) in
                appState.setReceiptCombine(on)
            })
    }
}

/// The scanner's Source, Sides (with a feeder), Resolution and Color: for the scanner in use (a network
/// scanner, the demo scanner); the camera measures its own pages. Source is locked while a side of an ID
/// card is held, as on the Mac: another source would end the task and drop the card.
private struct ScannerSettingsRows: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        let sources: [ScanSource] = state.capabilities?.sources ?? [ScanSource.flatbed]
        let feeder: Bool = state.settings.source == ScanSource.documentFeeder
        let cardHeld: Bool = state.hasIdCardCaptures
        Picker("Source", selection: $state.settings.source) {
            ForEach(sources) { (source: ScanSource) in
                Text(source.label).tag(source)
            }
        }
        .disabled(cardHeld)
        .accessibilityHint(Text(cardHeld ? IOSSettingsText.idCardHeldReason : state.settings.source.hint))
        if cardHeld {
            ReasonLine(text: IOSSettingsText.idCardHeldReason)
        }
        if sources.contains(ScanSource.documentFeeder) {
            Picker("Sides", selection: $state.settings.duplex) {
                ForEach(offeredSides) { (mode: DuplexMode) in
                    Text(mode.label).tag(mode)
                }
            }
            .disabled(!feeder)
            .accessibilityHint(Text(state.settings.duplex.hint))
            if !feeder {
                ReasonLine(text: DocumentSides.needsFeederReason)
            }
        }
        Picker("Resolution", selection: $state.settings.resolution) {
            ForEach(resolutions, id: \.self) { (dpi: Int) in
                Text("\(dpi) dpi").tag(dpi)
            }
        }
        Picker("Color", selection: $state.settings.colorMode) {
            ForEach(ColorMode.allCases) { (mode: ColorMode) in
                Text(mode.label).tag(mode)
            }
        }
    }

    /// The scanner's resolutions, with the one chosen always listed.
    private var resolutions: [Int] {
        var list: [Int] = state.capabilities?.supportedResolutions ?? AppState.fallbackResolutions
        if !list.contains(state.settings.resolution) {
            list.append(state.settings.resolution)
            list.sort()
        }
        return list
    }

    /// One side, both (a feeder that scans both), turned over by hand (where it can be); the one chosen is
    /// always listed.
    private var offeredSides: [DuplexMode] {
        let s: ScanSettings = state.settings
        let duplex: Bool = state.capabilities?.supportsDuplex ?? false
        var modes: [DuplexMode] = []
        for mode in DuplexMode.allCases {
            switch mode {
            case .off:
                modes.append(mode)
            case .both:
                if duplex || s.duplex == .both { modes.append(mode) }
            case .manual:
                if DocumentSides.manualUnavailableReason(s) == nil || s.duplex == .manual { modes.append(mode) }
            }
        }
        return modes
    }
}

/// Output: the format (an image format for photos, a PDF or an image for receipts), the PDF's size,
/// Searchable PDF while a PDF is written, Collect pages, and where files are saved; Photos in Photos mode.
private struct OutputSettingsRows: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        let s: ScanSettings = state.settings
        let shown: OutputFormat = InspectorSections.shownFormat(s)
        let flow: TaskFlowKind = TaskCatalog.flow(of: s)
        Picker("Format", selection: format) {
            ForEach(formats) { (choice: OutputFormat) in
                Text(choice.label).tag(choice)
            }
        }
        .accessibilityIdentifier("settings.format")
        if shown == OutputFormat.pdf && s.intent == ScanIntent.document {
            Picker("PDF size", selection: $state.settings.output.pdfSize) {
                ForEach(PDFSizePreset.displayOrder, id: \.self) { (size: PDFSizePreset) in
                    Text(size.label).tag(size)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityHint(Text("\(s.output.pdfSize.hint). \(s.output.pdfSize.detail)"))
        }
        if IOSSettingsSections.writesPDF(s) && flow != TaskFlowKind.copy && flow != TaskFlowKind.idCard {
            Toggle("Searchable PDF", isOn: $state.settings.pdfSearchable)
                .accessibilityHint(Text("Lets you search and copy the text (OCR)"))
        }
        if s.intent == ScanIntent.document && flow != TaskFlowKind.receiptSplit && flow != TaskFlowKind.idCard {
            Toggle("Collect pages before saving", isOn: $state.settings.documentMultiPage)
                .accessibilityHint(Text("Off: each page is saved right away"))
        }
        SaveFolderRow()
    }

    /// Every format for documents, the image formats for photos; receipts are saved as a PDF or an image.
    private var formats: [OutputFormat] {
        let offered: [OutputFormat] = OutputFormat.offered(for: state.settings.intent)
        guard state.isReceiptFlow else { return offered }
        var list: [OutputFormat] = []
        for choice in offered where choice.pageFormat == choice {
            list.append(choice)
        }
        return list
    }

    private var format: Binding<OutputFormat> {
        let appState: AppState = state
        return Binding<OutputFormat>(
            get: { InspectorSections.shownFormat(appState.settings) },
            set: { (choice: OutputFormat) in
                appState.settings.format = choice
            })
    }
}

/// Where files are saved: the app's own folder in Files (On My iPhone › CompleteScanner) or one picked with
/// Choose… (iCloud Drive, a USB drive; `IOSSaveFolder`), with Show in Files. Use app folder goes back to
/// the app's own once another is picked.
private struct SaveFolderRow: View {
    @EnvironmentObject private var state: AppState
    @State private var choosing: Bool = false

    var body: some View {
        let folder: URL = IOSSavedFiles.shownFolder(state.settings)
        LabeledContent(IOSSettingsText.saveToLabel) {
            HStack(spacing: 8) {
                Text(folder.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button {
                    state.revealInFinder(folder)
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text(IOSSavedFiles.revealLabel))
            }
        }
        HStack {
            Button(IOSSettingsText.chooseFolderLabel) {
                choosing = true
            }
            .accessibilityIdentifier("settings.saveFolder.choose")
            if state.settings.destinationBookmark != nil {
                Spacer()
                Button(IOSSettingsText.appFolderLabel) {
                    state.settings = IOSSaveFolder.appFolder(state.settings)
                }
                .accessibilityIdentifier("settings.saveFolder.app")
            }
        }
        .buttonStyle(.borderless)
        .fileImporter(isPresented: $choosing, allowedContentTypes: [UTType.folder]) { (result: Result<URL, Error>) in
            switch result {
            case .success(let url):
                do {
                    state.settings = try IOSSaveFolder.choosing(url, in: state.settings)
                    state.openBookmarkedFolder()
                } catch {
                    state.errorMessage = error.localizedDescription
                }
            case .failure(let error):
                state.errorMessage = error.localizedDescription
            }
        }
    }
}

/// Auto-enhance, the four sliders on one -100…+100 scale with Reset, Remove print dots and Restore faded
/// colors.
private struct AdjustmentSettingsRows: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        Toggle("Auto-enhance", isOn: $state.settings.adjustments.autoEnhance)
        ForEach(IOSAdjustment.allCases) { (adjustment: IOSAdjustment) in
            slider(adjustment)
        }
        Button {
            state.settings.adjustments = IOSAdjustment.neutral(state.settings.adjustments)
        } label: {
            Label(IOSSettingsText.resetLabel, systemImage: "arrow.counterclockwise")
        }
        .disabled(IOSAdjustment.isNeutral(state.settings.adjustments))
        .accessibilityHint(Text("Puts the four sliders back to neutral"))
        Toggle("Remove print dots", isOn: $state.settings.adjustments.descreen)
            .accessibilityHint(Text("Smooths the dot pattern of magazines and printed photos (descreen)"))
        Toggle("Restore faded colors", isOn: $state.settings.adjustments.restoreFadedColors)
    }

    private func slider(_ adjustment: IOSAdjustment) -> some View {
        let value: Binding<Double> = amount(adjustment)
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(adjustment.label)
                Spacer(minLength: 8)
                Text(IOSAdjustment.amountText(value.wrappedValue))
                    .monospacedDigit()
                    .foregroundStyle(Color.secondary)
            }
            Slider(value: value, in: -100...100)
                .accessibilityLabel(Text(adjustment.label))
                .accessibilityValue(Text(IOSAdjustment.amountText(value.wrappedValue)))
        }
    }

    private func amount(_ adjustment: IOSAdjustment) -> Binding<Double> {
        let appState: AppState = state
        return Binding<Double>(
            get: { adjustment.amount(appState.settings.adjustments) },
            set: { (amount: Double) in
                appState.settings.adjustments = adjustment.setting(amount, in: appState.settings.adjustments)
            })
    }
}

/// Skip blank pages (with what counts as blank), crop and straighten, rotate upright, and split facing
/// pages with the book's choices: on pages collected before saving only.
private struct PageSettingsRows: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        let s: ScanSettings = state.settings
        let collecting: Bool = s.documentMultiPage && !state.isCopyFlow && !state.isReceiptFlow
        let separators: Bool = collecting && DocumentSplitter.blankPagesAreSeparators(s.document, sides: state.effectiveDuplex)
        let upright: Bool = state.canTurnPagesUpright
        let oneSide: Bool = BookPages.scansOneSide(s)
        if !collecting {
            ReasonLine(text: IOSSettingsText.notCollectingReason)
        }
        Toggle("Skip blank pages", isOn: $state.settings.document.removeBlankPages)
            .disabled(!collecting || separators)
            .accessibilityHint(Text(separators ? DocumentSplitter.blankPagesAreSeparatorsHint
                                    : "Blank pages are left out. Tap Keep on a page to save it."))
        if separators {
            ReasonLine(text: "Blank sheets split documents")
        }
        if collecting && s.document.removeBlankPages {
            Picker("What counts as blank", selection: $state.settings.document.blankSensitivity) {
                ForEach(BlankSensitivity.displayOrder, id: \.self) { (level: BlankSensitivity) in
                    Text(level.label).tag(level)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityHint(Text(s.document.blankSensitivity.hint))
            if s.document.blankSensitivity == BlankSensitivity.high {
                ReasonLine(text: BlankSensitivity.highWarning, systemImage: "exclamationmark.triangle")
            }
        }
        Toggle("Crop to page", isOn: $state.settings.document.autoCrop)
            .disabled(!collecting)
            .accessibilityHint(Text("Cut away the scanner background"))
        Toggle("Straighten pages", isOn: $state.settings.document.autoStraighten)
            .disabled(!collecting)
            .accessibilityHint(Text("Straighten slanted pages"))
        Toggle("Rotate pages upright", isOn: $state.settings.document.autoRotate)
            .disabled(!collecting || !upright)
            .accessibilityHint(Text(PageTurns.hint(s, available: upright)))
        if collecting && !upright {
            ReasonLine(text: PageTurns.hint(s, available: upright))
        }
        Toggle("Split facing pages", isOn: $state.settings.document.splitFacingPages)
            .disabled(!collecting || !oneSide)
        if collecting && !oneSide {
            ReasonLine(text: BookPages.notWithTwoSidedReason)
        }
        if collecting && oneSide && s.document.splitFacingPages {
            Toggle("Reads right to left", isOn: $state.settings.taskOptions.bookRightToLeft)
                .accessibilityHint(Text("Arabic, Hebrew, manga: the right page of each spread comes first."))
            Picker("Book rotation", selection: bookTurns) {
                ForEach(BookPages.rotationChoices, id: \.self) { (turns: Int) in
                    Text(BookPages.rotationLabel(turns)).tag(turns)
                }
            }
            Toggle("Soften spine shadow", isOn: $state.settings.document.softenSpineShadow)
                .accessibilityHint(Text(SpineShadow.hint(s.document.softenSpineShadow)))
        }
    }

    private var bookTurns: Binding<Int> {
        let appState: AppState = state
        return Binding<Int>(
            get: { BookSplitter.normalizedTurns(appState.settings.taskOptions.bookRotationQuarterTurns) },
            set: { (turns: Int) in
                appState.settings.taskOptions.bookRotationQuarterTurns = turns
            })
    }
}

/// Split into documents: the choice (through `AppState.setSplitMode`), its one line, the sheet count, and at
/// QR codes where the codes are; Save sheet makes the separator sheet to print.
private struct SplitSettingsRows: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        let s: ScanSettings = state.settings
        let collecting: Bool = s.documentMultiPage
        let mode: SplitMode = s.document.splitMode
        if !collecting {
            ReasonLine(text: IOSSettingsText.notCollectingReason)
        }
        Picker("Split", selection: splitMode) {
            ForEach(SplitMode.displayOrder, id: \.self) { (choice: SplitMode) in
                Text(choice.label).tag(choice)
            }
        }
        .disabled(!collecting)
        .accessibilityHint(Text(collecting ? mode.steps : mode.hint))
        if collecting && !mode.caption.isEmpty {
            Text(mode.caption)
                .font(.caption)
                .foregroundStyle(Color.secondary)
        }
        if collecting && mode == SplitMode.sheetCount {
            Stepper(value: sheetCount, in: 1...DocumentSplitter.maxSheetCount) {
                Text("New document every \(DocumentSplitter.clampSheetCount(s.document.splitSheetCount)) sheets")
            }
        }
        if collecting && mode == SplitMode.barcode {
            Picker("Codes are on", selection: startsDocument) {
                Text("Separator sheets").tag(false)
                Text("First pages").tag(true)
            }
            .pickerStyle(.segmented)
            Text(BarcodeSeparators.startsDocumentCaption(s.document.barcodeStartsDocument))
                .font(.caption)
                .foregroundStyle(Color.secondary)
        }
        if collecting && (mode == SplitMode.separatorSheet || (mode == SplitMode.barcode && !s.document.barcodeStartsDocument)) {
            if mode == SplitMode.barcode {
                TextField("Name on sheet", text: $state.qrSheetName, prompt: Text("Optional"))
            }
            Button {
                state.saveSeparatorSheet()
            } label: {
                Label("Save sheet", systemImage: "square.and.arrow.down")
            }
            .accessibilityHint(Text("Saves a PDF of the sheet; print it at 100%"))
        }
    }

    private var splitMode: Binding<SplitMode> {
        let appState: AppState = state
        return Binding<SplitMode>(
            get: { appState.settings.document.splitMode },
            set: { (mode: SplitMode) in
                appState.setSplitMode(mode)
            })
    }

    private var sheetCount: Binding<Int> {
        let appState: AppState = state
        return Binding<Int>(
            get: { DocumentSplitter.clampSheetCount(appState.settings.document.splitSheetCount) },
            set: { (count: Int) in
                appState.setSplitSheetCount(count)
            })
    }

    private var startsDocument: Binding<Bool> {
        let appState: AppState = state
        return Binding<Bool>(
            get: { appState.settings.document.barcodeStartsDocument },
            set: { (on: Bool) in
                appState.setBarcodeStartsDocument(on)
            })
    }
}

/// Archival PDF (PDF/A) and Require a password, which exclude each other (`IOSPDFOptions`, as on the scan
/// screen); the password is asked for when saving and never kept.
private struct ArchiveSettingsRows: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        let output: OutputOptions = state.settings.output
        Toggle(PDFA.optionLabel, isOn: archival)
            .disabled(output.protect)
            .accessibilityHint(Text(output.protect ? PDFA.cannotProtectNote : PDFA.optionHint))
        if let reason = IOSPDFOptions.archivalReason(output) {
            ReasonLine(text: reason, systemImage: "lock")
        }
        Toggle(PDFProtection.optionLabel, isOn: protect)
            .disabled(IOSPDFOptions.archivalShown(output))
            .accessibilityHint(Text(IOSPDFOptions.archivalShown(output) ? PDFA.cannotProtectNote : PDFProtection.optionHint))
        if let reason = IOSPDFOptions.protectReason(output) {
            ReasonLine(text: reason, systemImage: "lock")
        }
    }

    private var archival: Binding<Bool> {
        let appState: AppState = state
        return Binding<Bool>(
            get: { IOSPDFOptions.archivalShown(appState.settings.output) },
            set: { (on: Bool) in
                appState.settings.output = IOSPDFOptions.settingArchival(on, in: appState.settings.output)
            })
    }

    private var protect: Binding<Bool> {
        let appState: AppState = state
        return Binding<Bool>(
            get: { appState.settings.output.protect },
            set: { (on: Bool) in
                appState.settings.output = IOSPDFOptions.settingProtect(on, in: appState.settings.output)
            })
    }
}

/// The text beside each PDF, what happens after a save, and the file name.
private struct MoreSettingsRows: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        if IOSSettingsSections.textApplies(state.settings) {
            Toggle(IOSPDFOptions.alsoSaveTextLabel, isOn: $state.settings.output.alsoSaveText)
                .accessibilityHint(Text(IOSPDFOptions.alsoSaveTextHint))
        }
        Picker("After saving", selection: $state.settings.output.afterSave) {
            ForEach(AfterSaveAction.allCases) { (action: AfterSaveAction) in
                Text(action.label).tag(action)
            }
        }
        .accessibilityHint(Text(state.settings.output.afterSave.hint))
        NavigationLink {
            NamingEditorScreen(model: IOSNamingModel(state: state))
        } label: {
            LabeledContent(IOSSettingsText.fileNameLabel) {
                Text(state.settings.namingTemplate)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .accessibilityIdentifier("settings.fileName")
    }
}

/// About: the app's name and version, what it is built with, and where scans stay.
struct AboutScreen: View {
    var body: some View {
        let info: [String: Any]? = Bundle.main.infoDictionary
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("CompleteScanner")
                        .font(.headline)
                    Text(IOSSettingsText.version(info))
                        .font(.subheadline)
                        .foregroundStyle(Color.secondary)
                        .accessibilityIdentifier("about.version")
                }
                .accessibilityElement(children: .combine)
            }
            Section {
                Text(IOSSettingsText.aboutBuiltWith)
                Text(IOSSettingsText.aboutPrivacy)
            }
        }
        .navigationTitle(IOSSettingsText.aboutLabel)
    }
}
#endif
