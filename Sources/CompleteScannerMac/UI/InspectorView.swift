#if os(macOS)
import AppKit
import CompleteScannerKit
import SwiftUI

/// Right column: the scan settings in sections (`InspectorSections`), presets, and the Preview / Scan /
/// Cancel actions pinned at the bottom. The task's own section (Photocopy or Receipts), Scanner and
/// Output start open; Adjustments, Pages, Split into documents, Archive & password and More options
/// start collapsed, and a
/// collapsed header shows what is on in it (with a dot when something differs from the default), so a
/// setting is never out of sight. What a control does is its help (tooltip and VoiceOver); a line under
/// a control stays only for why it is greyed out, for what cannot be undone, or for live state. Which
/// sections are open is remembered for the user (not in presets); starting a task opens the section it
/// needs without remembering it. Twin of the Windows inspector (MainWindow.xaml, MainWindow.Inspector.cs).
struct InspectorView: View {
    @EnvironmentObject var state: AppState

    @State private var showNamingHelp = false
    @State private var showSavePresetAlert = false
    @State private var newPresetName = ""
    @State private var showSplitSteps = false

    @AppStorage("inspector.section.task") private var taskOpen: Bool = InspectorSections.openByDefault(InspectorSections.task)
    @AppStorage("inspector.section.scanner") private var scannerOpen: Bool = InspectorSections.openByDefault(InspectorSections.scanner)
    @AppStorage("inspector.section.output") private var outputOpen: Bool = InspectorSections.openByDefault(InspectorSections.output)
    @AppStorage("inspector.section.adjustments") private var adjustmentsOpen: Bool = InspectorSections.openByDefault(InspectorSections.adjustments)
    @AppStorage("inspector.section.pages") private var pagesOpen: Bool = InspectorSections.openByDefault(InspectorSections.pages)
    @AppStorage("inspector.section.split") private var splitOpen: Bool = InspectorSections.openByDefault(InspectorSections.split)
    @AppStorage("inspector.section.archive") private var archiveOpen: Bool = InspectorSections.openByDefault(InspectorSections.archive)
    @AppStorage("inspector.section.more") private var moreOpen: Bool = InspectorSections.openByDefault(InspectorSections.more)

    var body: some View {
        // The action area is pinned as a bottom safe-area inset: the form scrolls
        // above it, so Preview/Scan can never be pushed off-window no matter how
        // small the window or how long the form gets.
        settingsForm
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    Divider()
                    actionArea
                }
            }
        .onChange(of: state.settings.intent) { _, newIntent in
            if newIntent == .photo && state.settings.format == .pdf {
                state.settings.format = .jpeg
            }
        }
        .alert("Save Preset", isPresented: $showSavePresetAlert) {
            TextField("Preset name", text: $newPresetName)
            Button("Save") { state.saveCurrentAsPreset(named: newPresetName) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The current scan settings will be saved as a reusable preset.")
        }
    }

    // MARK: Form

    private var settingsForm: some View {
        Form {
            modeSection
            if state.isCopyFlow {
                copySection
            }
            if state.isReceiptFlow {
                receiptsSection
            }
            scannerSection
            if state.settings.intent == .photo {
                photosSection
            } else {
                outputSection
            }
            adjustmentsSection
            if showsPageSections {
                pagesSection
                splitSection
            }
            if archiveShown {
                archiveSection
            }
            moreSection
            presetsSection
        }
        .formStyle(.grouped)
        .disabled(state.isBusy)
    }

    /// Pages and Split into documents apply to document pages, not to copies or receipts.
    private var showsPageSections: Bool {
        state.settings.intent == .document && !state.isCopyFlow && !state.isReceiptFlow
    }

    /// Pages are collected in the queue (not each scan saved at once), outside copies and receipts.
    private var collecting: Bool {
        state.settings.documentMultiPage && !state.isCopyFlow && !state.isReceiptFlow
    }

    // MARK: Sections

    /// Whether a section is open: as the user left it, or opened by a task (`AppState.sectionsOpenedByTask`,
    /// Restore old photos opens Adjustments) until the user closes it. A task opens a section without
    /// remembering it; applying a preset or changing a setting opens nothing.
    private func isOpen(_ id: String) -> Binding<Bool> {
        Binding(
            get: { storedOpen(id) || state.sectionsOpenedByTask.contains(id) },
            set: { (open: Bool) in
                state.sectionsOpenedByTask.remove(id)
                setStoredOpen(id, open)
            })
    }

    private func storedOpen(_ id: String) -> Bool {
        switch id {
        case InspectorSections.task: return taskOpen
        case InspectorSections.scanner: return scannerOpen
        case InspectorSections.output: return outputOpen
        case InspectorSections.adjustments: return adjustmentsOpen
        case InspectorSections.pages: return pagesOpen
        case InspectorSections.split: return splitOpen
        case InspectorSections.archive: return archiveOpen
        default: return moreOpen
        }
    }

    private func setStoredOpen(_ id: String, _ open: Bool) {
        switch id {
        case InspectorSections.task: taskOpen = open
        case InspectorSections.scanner: scannerOpen = open
        case InspectorSections.output: outputOpen = open
        case InspectorSections.adjustments: adjustmentsOpen = open
        case InspectorSections.pages: pagesOpen = open
        case InspectorSections.split: splitOpen = open
        case InspectorSections.archive: archiveOpen = open
        default: moreOpen = open
        }
    }

    /// A section of the column: a disclosure group whose header shows a summary while collapsed.
    private func section<Content: View>(_ id: String, title: String, summary: String, changed: Bool,
                                        locked: Bool = false, accessibilityName: String? = nil,
                                        @ViewBuilder content: () -> Content) -> some View {
        let open: Binding<Bool> = isOpen(id)
        let name: String = accessibilityName ?? InspectorSections.headerName(title, summary: summary)
        let inner: Content = content()
        return Section {
            DisclosureGroup(isExpanded: open) {
                inner
            } label: {
                InspectorSectionHeader(title: title, summary: summary, changed: changed, locked: locked,
                                       collapsed: !open.wrappedValue)
                    .accessibilityLabel(Text(name))
            }
        }
    }

    // MARK: Mode

    private var modeSection: some View {
        Section {
            Picker("Mode", selection: $state.settings.intent) {
                ForEach(ScanIntent.allCases) { intent in
                    Text(intent.label).tag(intent)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(state.hasIdCardCaptures)
            .help(state.hasIdCardCaptures ? Self.idCardHeldHint : "")
            .accessibilityHint(Text("Document: pages and text. Photos: finds each photo on the glass."))
        }
    }

    /// Why the mode and the source cannot be changed while a side of an ID card is held: changing
    /// them would end the task and drop the card. Leaving the task asks first.
    private static let idCardHeldHint =
        "The ID card task needs the flatbed in Document mode. Save or discard the card, or leave the task, to change this."

    /// A reason next to a greyed-out control, or a consequence that must not be missed: an icon and a
    /// few words, in secondary text.
    private func reasonLine(_ text: String, systemImage: String = "info.circle") -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Photocopy

    /// The Copy task: where and how the copies print (AppState+Copy.swift). The print panel opens set
    /// to these, at 100 %.
    private var copySection: some View {
        section(InspectorSections.task, title: "Photocopy", summary: "", changed: false) {
            if state.hasPrinter {
                Picker("Printer", selection: Binding(
                    get: { state.copyPrinterName ?? "" },
                    set: { state.setCopyPrinter($0) })) {
                    ForEach(state.printerNames, id: \.self) { name in
                        Text(name == state.printService.defaultPrinterName ? "\(name) (default)" : name).tag(name)
                    }
                }
                if !state.copyPaperText.isEmpty {
                    Text("Paper: \(state.copyPaperText)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Stepper(value: Binding(
                    get: { PrintCopies.clamp(state.settings.taskOptions.copyCount) },
                    set: { state.setCopyCount($0) }), in: 1...PrintCopies.maxCount) {
                    Text("Copies: \(PrintCopies.clamp(state.settings.taskOptions.copyCount))")
                }
                Toggle("Fit to page", isOn: Binding(
                    get: { state.settings.taskOptions.copyFitToPage },
                    set: { state.setCopyFitToPage($0) }))
                    .help("Off: real size. On: shrinks to fit the paper.")
                // Printer margins cut the edges of a copy at real size: stays visible.
                if let warning = state.copyMarginWarning {
                    reasonLine(warning, systemImage: "exclamationmark.triangle")
                }
                Toggle("Also save a PDF", isOn: Binding(
                    get: { state.settings.taskOptions.copyAlsoSavePdf },
                    set: { state.setCopyAlsoSavePdf($0) }))
                    .help("Keeps a PDF of each copy in your save folder")
                Button("Print Test Ruler\u{2026}") {
                    state.printRulerPage()
                }
                .help("Prints a ruler to check copies come out at real size")
            } else {
                reasonLine(PrintText.noPrinterReason)
                    .help("Add a printer in System Settings \u{2192} Printers & Scanners, then look again.")
                Button("Look Again") {
                    state.refreshPrinters()
                }
            }
        }
    }

    // MARK: Receipts

    /// The Receipts task: how the receipts found on the glass are named and saved (AppState+Receipts.swift).
    private var receiptsSection: some View {
        let options = state.settings.taskOptions
        let pdf: Bool = state.settings.format.pageFormat == .pdf
        let dateUsed: Bool = Receipts.namesByDate(state.settings)
        return section(InspectorSections.task, title: "Receipts", summary: "", changed: false) {
            Toggle("Name by receipt date", isOn: Binding(
                get: { state.settings.taskOptions.receiptNameByDate },
                set: { state.setReceiptNameByDate($0) }))
                .help("Uses the date printed on the receipt, or today")
            if options.receiptNameByDate && !dateUsed {
                reasonLine("Needs {docdate} in File name")
                    .help("The file name has no {docdate}, so the date printed on the receipt is not used.")
            }
            Toggle("One PDF for all", isOn: Binding(
                get: { state.settings.taskOptions.receiptCombine },
                set: { state.setReceiptCombine($0) }))
                .disabled(!pdf)
                .help(pdf ? "Off: a PDF for each receipt" : "Only for PDFs: each receipt is saved as an image of its own.")
            if !pdf {
                reasonLine("Only for PDFs")
            }
        }
    }

    // MARK: Scanner

    private var scannerSection: some View {
        section(InspectorSections.scanner, title: "Scanner",
                summary: InspectorSections.scannerSummary(state.settings),
                changed: InspectorSections.scannerChanged(state.settings)) {
            Picker("Source", selection: $state.settings.source) {
                ForEach(availableSources) { source in
                    Text(source.label).tag(source)
                }
            }
            .disabled(state.hasIdCardCaptures)
            .help(state.hasIdCardCaptures ? Self.idCardHeldHint : state.settings.source.hint)
            if availableSources.contains(.documentFeeder) {
                sidesRows
            }
            paperSizeRow
            Picker("Resolution", selection: $state.settings.resolution) {
                ForEach(availableResolutions, id: \.self) { dpi in
                    Text("\(dpi) dpi").tag(dpi)
                }
            }
            .help("Higher is sharper but slower and larger. 300 suits documents.")
            Picker("Color", selection: $state.settings.colorMode) {
                ForEach(ColorMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
        }
    }

    private var availableSources: [ScanSource] {
        state.capabilities?.sources ?? [.flatbed]
    }

    private var availableResolutions: [Int] {
        state.capabilities?.supportedResolutions ?? AppState.fallbackResolutions
    }

    // MARK: Sides and paper size

    private var feederSelected: Bool { state.settings.source == .documentFeeder }

    /// Why "Both sides" is left out: the feeder is known to scan one side at a time (one not asked
    /// yet is taken to scan both).
    private var bothSidesReason: String? {
        guard let caps = state.sidesCapabilities, !caps.supportsDuplex else { return nil }
        return DocumentSides.oneSidedFeederReason
    }

    /// The sides the scanner and the settings can do (the chosen one is always listed); the
    /// help says why a choice is left out. Twin of the Windows inspector's "Sides".
    private var offeredSides: [DuplexMode] {
        DuplexMode.allCases.filter { mode in
            switch mode {
            case .off: return true
            case .both: return bothSidesReason == nil || state.settings.duplex == .both
            case .manual:
                return DocumentSides.manualUnavailableReason(state.settings) == nil || state.settings.duplex == .manual
            }
        }
    }

    /// What the sides do, or why they can't be chosen: the picker's help.
    private var sidesHelp: String {
        let s = state.settings
        guard feederSelected else { return DocumentSides.feederOnlyReason }
        if s.duplex == .manual, let reason = DocumentSides.manualUnavailableReason(s) { return reason }
        if s.duplex == .off, let reason = bothSidesReason { return "\(s.duplex.hint). \(reason)" }
        return s.duplex.hint
    }

    /// One side, both, or turned over by hand, for scanners with a feeder; usable while the
    /// feeder is the source (greyed out with the reason on the flatbed). With both sides, along
    /// which edge the sheets turn.
    @ViewBuilder
    private var sidesRows: some View {
        Picker("Sides", selection: $state.settings.duplex) {
            ForEach(offeredSides) { mode in
                Text(mode.label).tag(mode)
            }
        }
        .disabled(!feederSelected)
        .help(sidesHelp)
        if !feederSelected {
            reasonLine(DocumentSides.needsFeederReason)
                .help(DocumentSides.feederOnlyReason)
        }
        if feederSelected && state.settings.duplex != .off {
            Picker("Flip on", selection: $state.settings.backBinding) {
                ForEach(DuplexBinding.allCases) { binding in
                    Text(binding.label).tag(binding)
                }
            }
            .help(DuplexBinding.pickerHint)
            .accessibilityHint(Text("How the sheets turn: the backs of short-edge sheets are turned upright."))
        }
    }

    /// The glass or the feeder, whichever is the source; nil when unknown.
    private var paperArea: CGSize? {
        guard let caps = state.capabilities else { return nil }
        return feederSelected ? caps.feederSizeInches : caps.flatbedSizeInches
    }

    /// Automatic, the usual size where the user lives, then the others; sizes larger than the
    /// glass or the feeder are left out (the chosen one is always listed).
    private var offeredPaperSizes: [PaperSize] {
        PaperSizes.displayOrder(region: Locale.current.region?.identifier).filter { size in
            PaperSizes.fits(size, in: paperArea) || size == state.settings.paperSize
        }
    }

    /// What the paper size does: for a copy, Automatic on the glass is the printer's paper.
    private var paperSizeHint: String {
        state.isCopyFlow
            ? PrintText.copyPaperHint(state.settings.paperSize, source: state.settings.source)
            : PaperSizes.hint(state.settings.paperSize, source: state.settings.source)
    }

    /// An area of the preview is selected: the scan takes it, whatever the paper size says.
    private var areaSelected: Bool {
        state.selectionRect != nil && state.overviewImage != nil && state.settings.source == .flatbed
    }

    private var paperSizeRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Paper size", selection: $state.settings.paperSize) {
                ForEach(offeredPaperSizes) { size in
                    Text(size == .auto ? size.label : "\(size.label) (\(size.detail))").tag(size)
                }
            }
            .help(paperSizeHint)
            if areaSelected {
                HStack(spacing: 4) {
                    reasonLine(PaperSizes.selectedAreaNote, systemImage: "selection.pin.in.out")
                    Button {
                        state.selectionRect = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .help("Clear the selected area")
                    .accessibilityLabel(Text("Clear the selected area"))
                }
            }
            if offeredPaperSizes.count < PaperSize.allCases.count {
                reasonLine("Larger sizes left out")
                    .help(PaperSizes.doesNotFitReason(source: state.settings.source))
            }
        }
    }

    // MARK: Archive & password

    /// Archive & password apply whenever the save writes a PDF (a queue of image pages too, and a copy
    /// also saved as a PDF), not only when PDF is the format shown. Twin of the Windows `WritesPdf`.
    private var archiveShown: Bool {
        let s: ScanSettings = state.settings
        guard s.intent == .document else { return false }
        if state.isCopyFlow { return s.taskOptions.copyAlsoSavePdf }
        if state.isReceiptFlow || state.isIdCardFlow { return s.format.pageFormat == .pdf }
        return s.format.savesPDF(collectsPages: s.documentMultiPage)
    }

    /// Archival PDF (PDF/A) and the password, which exclude each other: while one is on, the other is
    /// greyed out with why next to it (`PDFA.notWithPasswordReason`, `PDFProtection.notWithArchivalReason`).
    /// The password is asked for at each save and never stored. Twin of the Windows "Archive & password".
    private var archiveSection: some View {
        let output: OutputOptions = state.settings.output
        let protect: Bool = output.protect
        let archival: Bool = output.archival && !protect
        let archivalHelp: String = protect ? "\(PDFA.notWithPasswordReason). \(PDFA.cannotProtectNote)" : PDFA.optionHelp
        let protectHelp: String = archival
            ? "\(PDFProtection.notWithArchivalReason). \(PDFA.cannotProtectNote)"
            : PDFProtection.optionHelp
        return section(InspectorSections.archive, title: InspectorSections.title(InspectorSections.archive),
                       summary: InspectorSections.archiveSummary(output),
                       changed: output.protect || output.archival, locked: output.protect) {
            Toggle(PDFA.optionLabel, isOn: archivalBinding)
                .disabled(protect)
                .help(protect ? PDFA.cannotProtectNote : PDFA.optionHint)
                .accessibilityHint(Text(archivalHelp))
            if protect {
                reasonLine(PDFA.notWithPasswordReason, systemImage: "lock")
                    .help(PDFA.cannotProtectNote)
            }
            Toggle(PDFProtection.optionLabel, isOn: protectBinding)
                .disabled(archival)
                .help(archival ? PDFA.cannotProtectNote : PDFProtection.optionHint)
                .accessibilityHint(Text(protectHelp))
            if archival {
                reasonLine(PDFProtection.notWithArchivalReason, systemImage: "lock")
                    .help(PDFA.cannotProtectNote)
            }
        }
    }

    /// On while the archival option is (and the password is not: a settings file with both on gets
    /// the password).
    private var archivalBinding: Binding<Bool> {
        Binding(get: { state.settings.output.archival && !state.settings.output.protect },
                set: { (on: Bool) in state.settings.output.archival = on && !state.settings.output.protect })
    }

    /// Turning the password on turns archival PDF off. Archival keeps only what its switch showed
    /// (`archivalBinding`), as Windows writes `Archival = ArchivalBox.IsChecked && !Protect`: an
    /// archival setting hidden under the password (a settings file with both on) is cleared, so
    /// turning the password off later leaves archival off.
    private var protectBinding: Binding<Bool> {
        Binding(get: { state.settings.output.protect },
                set: { (on: Bool) in
                    let shownArchival = state.settings.output.archival && !state.settings.output.protect
                    state.settings.output.archival = shownArchival && !on
                    state.settings.output.protect = on
                })
    }

    // MARK: Output

    private var outputSection: some View {
        section(InspectorSections.output, title: "Output",
                summary: InspectorSections.outputSummary(state.settings, shownFormat: shownFormat),
                changed: InspectorSections.outputChanged(state.settings, shownFormat: shownFormat)) {
            formatPicker
            if shownFormat == .jpeg {
                jpegQualityRow
            }
            if shownFormat == .pdf {
                pdfSizeRow
            }
            if shownFormat == .word {
                wordPicturesRow
            }
            if searchableShown {
                Toggle("Searchable PDF", isOn: $state.settings.pdfSearchable)
                    .help("Lets you search and copy the text (OCR)")
            }
            if !state.isReceiptFlow && !state.isIdCardFlow {
                Toggle("Collect pages before saving", isOn: $state.settings.documentMultiPage)
                    .help("Off: each scan is saved right away")
                    .accessibilityHint(Text("On: pages are collected until you \(shownFormat.saveTitle). Off: each scan is saved right away."))
            }
            destinationRow
        }
    }

    /// Searchable PDF applies whenever the save writes a PDF that can carry text: not for Word, text or
    /// image files saved at once, nor for copies and ID cards (saved without their text).
    private var searchableShown: Bool {
        let writesPDF: Bool = state.settings.format.savesPDF(collectsPages: state.settings.documentMultiPage)
        return writesPDF && !state.isCopyFlow && !state.isIdCardFlow
    }

    private var formatPicker: some View {
        Picker("Format", selection: shownFormatBinding) {
            ForEach(availableFormats) { format in
                Text(format.label).tag(format)
            }
        }
    }

    private var jpegQualityRow: some View {
        LabeledContent("JPEG quality") {
            HStack(spacing: 8) {
                Slider(value: $state.settings.jpegQuality, in: 0.5...1)
                Text("\(Int((state.settings.jpegQuality * 100).rounded()))%")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 38, alignment: .trailing)
            }
        }
    }

    private var destinationRow: some View {
        LabeledContent("Save to") {
            HStack(spacing: 6) {
                Text(destinationURL.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(destinationURL.path)
                Spacer(minLength: 4)
                Button("Choose…") { chooseDestination() }
                Button {
                    state.revealInFinder(destinationURL)
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.borderless)
                .help("Show in Finder")
            }
        }
    }

    /// How small saved PDFs are made: one segment per size (largest first), what each is for as the
    /// help, and the size of the PDF saved last. Twin of the Windows inspector's "PDF size".
    private var pdfSizeRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("PDF size")
            pdfSizePicker("PDF size")
            if let bytes = state.lastPDFByteCount {
                Text("Last PDF: \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func pdfSizePicker(_ name: String) -> some View {
        let size: PDFSizePreset = state.settings.output.pdfSize
        return Picker(name, selection: $state.settings.output.pdfSize) {
            ForEach(PDFSizePreset.displayOrder) { preset in
                Text(preset.label).tag(preset)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .help(size.hint)
        .accessibilityHint(Text("\(size.hint). \(size.detail)"))
    }

    /// Word documents only: each page's picture before its text (`OutputOptions.wordPageImages`),
    /// stored at the size picked under the switch, which is the PDF size setting. Twin of the
    /// Windows inspector's "Include page images" and its "Page image size".
    private var wordPicturesRow: some View {
        let on: Bool = state.settings.output.wordPageImages
        return VStack(alignment: .leading, spacing: 6) {
            Toggle(DocxWriter.pageImagesLabel, isOn: $state.settings.output.wordPageImages)
                .help(DocxWriter.pageImagesHint(on: on))
            if on {
                Text("Page image size")
                pdfSizePicker("Page image size")
            }
        }
    }

    /// Every format for documents, the image formats for photos (`OutputFormat.offered(for:)`);
    /// receipts are saved as a PDF or an image (`pageFormat`), so Word and text are not offered there.
    private var availableFormats: [OutputFormat] {
        let offered = OutputFormat.offered(for: state.settings.intent)
        return state.isReceiptFlow ? offered.filter { $0.pageFormat == $0 } : offered
    }

    /// The format a save uses, as the picker shows it: photos are saved as an image, so a PDF or
    /// text format shows as JPEG there, and receipts as a PDF or an image, so Word or text shows as
    /// PDF there (the setting itself is kept for documents until another format is picked). Twin of
    /// the Windows inspector's format box.
    private var shownFormat: OutputFormat {
        if state.settings.intent == .photo { return state.settings.format.imageFormatOrJPEG }
        return state.isReceiptFlow ? state.settings.format.pageFormat : state.settings.format
    }

    private var shownFormatBinding: Binding<OutputFormat> {
        Binding(get: { shownFormat },
                set: { state.settings.format = $0 })
    }

    private var destinationURL: URL {
        URL(fileURLWithPath: (state.settings.destinationPath as NSString).expandingTildeInPath,
            isDirectory: true)
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = destinationURL
        panel.prompt = "Choose"
        panel.message = "Choose where scans are saved."
        if panel.runModal() == .OK, let url = panel.url {
            state.settings.destinationPath = url.path
        }
    }

    // MARK: Photos

    /// Photos mode: finding and straightening each photo, the image format and where it is saved.
    private var photosSection: some View {
        section(InspectorSections.output, title: "Photos",
                summary: InspectorSections.outputSummary(state.settings, shownFormat: shownFormat),
                changed: InspectorSections.outputChanged(state.settings, shownFormat: shownFormat)) {
            Toggle("Find each photo", isOn: $state.settings.photoAutoSplit)
                .help("Finds each photo on the glass and saves it on its own")
            Toggle("Straighten photos", isOn: $state.settings.photoAutoDeskew)
                .help("Turns each photo straight (deskew)")
            Stepper(value: $state.settings.photoMinSideInches, in: 0.5...4, step: 0.1) {
                LabeledContent("Min photo side",
                               value: String(format: "%.1f in", state.settings.photoMinSideInches))
            }
            Stepper(value: $state.settings.photoCropInsetPixels, in: 0...20) {
                LabeledContent("Edge trim", value: "\(state.settings.photoCropInsetPixels) px")
            }
            formatPicker
            if shownFormat == .jpeg {
                jpegQualityRow
            }
            destinationRow
        }
    }

    // MARK: Pages

    /// Skip blank pages, crop and straighten, turning pages upright and splitting facing pages: on
    /// pages collected in the queue only, where a changed page can be seen and undone.
    private var pagesSection: some View {
        let d = state.settings.document
        return section(InspectorSections.pages, title: "Pages",
                       summary: InspectorSections.pagesSummary(d),
                       changed: !InspectorSections.pagesSummary(d).isEmpty,
                       accessibilityName: InspectorSections.pagesHeaderName(d)) {
            if !collecting {
                reasonLine("Needs Collect pages")
                    .help("Only for pages collected before saving: a scan saved at once is kept as scanned.")
            }
            blankPagesRows
            geometryRows
            autoRotateRows
            bookRows
        }
    }

    /// Blank pages: flagged in the page strip, left out when saving. One-sided at blank sheets, every
    /// blank page is a separator, so the switch has no say. Twin of the Windows inspector's "Skip
    /// blank pages".
    @ViewBuilder
    private var blankPagesRows: some View {
        let separators: Bool = collecting
            && DocumentSplitter.blankPagesAreSeparators(state.settings.document, sides: state.effectiveDuplex)
        Toggle("Skip blank pages", isOn: $state.settings.document.removeBlankPages)
            .disabled(!collecting || separators)
            .help(separators ? DocumentSplitter.blankPagesAreSeparatorsHint
                  : "Blank pages are left out. Click Keep on a page to save it.")
            .accessibilityHint(Text(separators ? DocumentSplitter.blankPagesAreSeparatorsHint
                                    : "Blank pages are marked in the page strip and left out when you save. Click Keep on a page to save it."))
        if separators {
            reasonLine("Blank sheets split documents")
        }
        if collecting {
            Text("What counts as blank")
            Picker("What counts as blank", selection: $state.settings.document.blankSensitivity) {
                ForEach(BlankSensitivity.displayOrder) { level in
                    Text(level.label).tag(level)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help(state.settings.document.blankSensitivity.hint)
            // Pages with a few marks may be left out: stays visible.
            if state.settings.document.blankSensitivity == .high {
                reasonLine(BlankSensitivity.highWarning, systemImage: "exclamationmark.triangle")
            }
        }
    }

    /// Crop and straighten: what each does as its help. Twin of the Windows inspector's "Crop to page"
    /// and "Straighten pages".
    @ViewBuilder
    private var geometryRows: some View {
        Toggle("Crop to page", isOn: $state.settings.document.autoCrop)
            .disabled(!collecting)
            .help("Cut away the scanner background")
        Toggle("Straighten pages", isOn: $state.settings.document.autoStraighten)
            .disabled(!collecting)
            .help("Straighten slanted pages")
    }

    /// Rotate pages upright: needs text recognition; greyed out with the reason when there is none.
    /// Twin of the Windows inspector's "Rotate pages upright".
    @ViewBuilder
    private var autoRotateRows: some View {
        let available: Bool = state.canTurnPagesUpright
        let hint: String = PageTurns.hint(state.settings, available: available)
        Toggle("Rotate pages upright", isOn: $state.settings.document.autoRotate)
            .disabled(!collecting || !available)
            .help(hint)
        if collecting && !available {
            reasonLine(hint)
        }
    }

    /// Split facing pages: each scan of an open book becomes its two pages, scanned one side of each
    /// sheet. The reading order, the book's rotation and softening the spine's shadow show while
    /// spreads are split. Twin of the Windows inspector's "Split facing pages".
    @ViewBuilder
    private var bookRows: some View {
        let oneSide: Bool = BookPages.scansOneSide(state.settings)
        let twoSided: Bool = collecting && !oneSide
        Toggle("Split facing pages", isOn: $state.settings.document.splitFacingPages)
            .disabled(!collecting || !oneSide)
            .help(BookPages.hint(state.settings))
        if twoSided {
            reasonLine(BookPages.notWithTwoSidedReason)
                .help(BookPages.hint(state.settings))
        }
        if collecting && oneSide && state.settings.document.splitFacingPages {
            Toggle("Reads right to left", isOn: $state.settings.taskOptions.bookRightToLeft)
                .help("Arabic, Hebrew, manga: the right page of each spread comes first.")
                .padding(.leading, 12)
            Picker("Book rotation", selection: Binding(
                get: { BookSplitter.normalizedTurns(state.settings.taskOptions.bookRotationQuarterTurns) },
                set: { state.settings.taskOptions.bookRotationQuarterTurns = $0 })) {
                ForEach(BookPages.rotationChoices, id: \.self) { turns in
                    Text(BookPages.rotationLabel(turns)).tag(turns)
                }
            }
            .help("For a book lying sideways or upside down on the glass")
            .padding(.leading, 12)
            Toggle("Soften spine shadow", isOn: $state.settings.document.softenSpineShadow)
                .help(SpineShadow.hint(state.settings.document.softenSpineShadow))
                .padding(.leading, 12)
        }
    }

    // MARK: Split into documents

    /// Split the stack into documents: the page strip shows where before saving, and one click on the
    /// gap between two pages splits or joins there. One line under the choice says what happens to the
    /// sheets that split; the info button holds how it works, step by step. Separator sheets are saved
    /// or printed on the printer chosen for copies: Patch T, or at QR codes a QR code carrying the name
    /// typed above the buttons. Twin of the Windows inspector's "Split into documents".
    private var splitSection: some View {
        section(InspectorSections.split, title: "Split into documents",
                summary: InspectorSections.splitSummary(state.settings.document),
                changed: state.settings.document.splitMode != SplitMode.none) {
            splitRows
        }
    }

    /// How it works, step by step: the info button's text and the choice's VoiceOver help.
    private var splitSteps: String {
        collecting
            ? state.settings.document.splitMode.steps
            : "Only for pages collected before saving: a scan saved at once is one file."
    }

    @ViewBuilder
    private var splitRows: some View {
        let mode: SplitMode = state.settings.document.splitMode
        if !collecting {
            reasonLine("Needs Collect pages")
        }
        HStack(spacing: 4) {
            Picker("Split", selection: Binding(get: { state.settings.document.splitMode },
                                               set: { state.setSplitMode($0) })) {
                ForEach(SplitMode.displayOrder) { choice in
                    Text(choice.label).tag(choice)
                }
            }
            .disabled(!collecting || state.isBusy)
            .help(collecting ? mode.hint : splitSteps)
            .accessibilityHint(Text(splitSteps))
            Button {
                showSplitSteps.toggle()
            } label: {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.borderless)
            .help("More about Split into documents")
            .accessibilityLabel(Text("More about Split into documents"))
            .popover(isPresented: $showSplitSteps, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("How it works")
                        .font(.headline)
                    Text(splitSteps)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                .frame(width: 300, alignment: .leading)
            }
        }
        if collecting && !mode.caption.isEmpty {
            Text(mode.caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if collecting && mode == .sheetCount {
            Stepper(value: Binding(get: { DocumentSplitter.clampSheetCount(state.settings.document.splitSheetCount) },
                                   set: { state.setSplitSheetCount($0) }),
                    in: 1...DocumentSplitter.maxSheetCount) {
                LabeledContent("New document every",
                               value: "\(DocumentSplitter.clampSheetCount(state.settings.document.splitSheetCount)) sheets")
            }
        }
        if collecting && mode == .barcode {
            barcodeRows
        }
        separatorSheetButtons
    }

    /// At QR codes or barcodes: the codes are on separator sheets (left out) or on the documents' first
    /// pages (kept); then the name the QR separator sheet carries.
    @ViewBuilder
    private var barcodeRows: some View {
        let startsDocument: Bool = state.settings.document.barcodeStartsDocument
        let fullHint: String = BarcodeSeparators.startsDocumentHint(startsDocument,
                                                                    prefix: state.settings.document.splitBarcodePrefix)
        Picker("Codes are on", selection: Binding(get: { state.settings.document.barcodeStartsDocument },
                                                  set: { state.setBarcodeStartsDocument($0) })) {
            Text("Separator sheets").tag(false)
            Text("First pages").tag(true)
        }
        .pickerStyle(.segmented)
        .disabled(state.isBusy)
        .help(fullHint)
        .accessibilityHint(Text(fullHint))
        Text(BarcodeSeparators.startsDocumentCaption(startsDocument))
            .font(.caption)
            .foregroundStyle(.secondary)
            .help(fullHint)
        if !startsDocument {
            // The name the QR separator sheet carries; empty: a sheet that only splits.
            TextField("Name on sheet", text: $state.qrSheetName, prompt: Text("Optional"))
                .help("Names the document that follows the sheet")
                .accessibilityHint(Text("The QR code holds this name and the document after the sheet is named by it ({label}). Leave it empty for a sheet that only splits."))
        }
    }

    /// A PDF in the scans folder, to print on any printer; or printed at once on the printer chosen for copies.
    @ViewBuilder
    private var separatorSheetButtons: some View {
        let mode: SplitMode = state.settings.document.splitMode
        let qrSheets: Bool = collecting && mode == .barcode && !state.settings.document.barcodeStartsDocument
        if (collecting && mode == .separatorSheet) || qrSheets {
            let printer: String = state.copyPrinterName ?? "the default printer"
            HStack(spacing: 8) {
                Button {
                    state.saveSeparatorSheet()
                } label: {
                    Label("Save Sheet", systemImage: "square.and.arrow.down")
                }
                .disabled(state.isBusy)
                .help("Saves a PDF of the sheet; print it at 100%")
                .accessibilityLabel(Text(qrSheets ? "Save QR separator sheet as PDF" : "Save separator sheet as PDF"))
                Button {
                    state.printSeparatorSheet()
                } label: {
                    Label("Print Sheet", systemImage: "printer")
                }
                .disabled(!state.hasPrinter || state.isBusy)
                .help(state.hasPrinter ? "Prints one now on \(printer), at actual size" : PrintText.noPrinterReason)
                .accessibilityLabel(Text(qrSheets ? "Print QR separator sheet" : "Print separator sheet"))
            }
        }
    }

    // MARK: More options

    /// The text beside each PDF, what happens after a save, and the file name.
    private var moreSection: some View {
        section(InspectorSections.more, title: "More options",
                summary: InspectorSections.moreSummary(state.settings.output, textShown: alsoSaveTextShown),
                changed: !InspectorSections.moreSummary(state.settings.output, textShown: alsoSaveTextShown).isEmpty) {
            if alsoSaveTextShown {
                Toggle("Also save text (.txt)", isOn: $state.settings.output.alsoSaveText)
                    .help("Saves the text in a .txt file next to the PDF")
            }
            afterSavePicker
            fileNameRow
        }
    }

    /// The text of the pages in a .txt file beside each PDF; OCR reads each page once for both. Shown
    /// whenever a save of document pages (or receipts) writes a PDF; never for ID cards and copies,
    /// whose PDFs are saved without it. Twin of the Windows inspector's "Also save text".
    private var alsoSaveTextShown: Bool {
        guard state.settings.intent == .document else { return false }
        let flow = TaskCatalog.flow(of: state.settings)
        switch flow {
        case .receiptSplit:
            return state.settings.format.pageFormat == .pdf
        case .documentQueue:
            return state.settings.format.savesPDF(collectsPages: state.settings.documentMultiPage)
        case .idCard, .copy, .photoSplit:
            return false
        }
    }

    /// What happens on its own after a save. Twin of the Windows inspector's "After saving"; the
    /// photo review offers the same choice.
    private var afterSavePicker: some View {
        Picker("After saving", selection: $state.settings.output.afterSave) {
            ForEach(AfterSaveAction.allCases) { action in
                Text(action.label).tag(action)
            }
        }
        .help(state.settings.output.afterSave.hint)
    }

    private var fileNameRow: some View {
        LabeledContent("File name") {
            HStack(spacing: 4) {
                TextField("Naming template", text: $state.settings.namingTemplate)
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                Button {
                    showNamingHelp.toggle()
                } label: {
                    Image(systemName: "questionmark.circle")
                }
                .buttonStyle(.borderless)
                .help("Naming template tokens")
                .popover(isPresented: $showNamingHelp, arrowEdge: .bottom) {
                    namingHelpPopover
                }
            }
        }
    }

    private var namingHelpPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Naming Tokens")
                .font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                namingTokenRow("{date}", "Scan date, e.g. 2026-08-13")
                namingTokenRow("{time}", "Scan time, e.g. 14.05.32")
                namingTokenRow("{counter}", "Running number")
                namingTokenRow("{counter:3}", "Zero-padded number, e.g. 007")
                namingTokenRow("{intent}", "\u{201C}Document\u{201D} or \u{201C}Photos\u{201D}")
                namingTokenRow("{index}", "Photo number within a batch")
                namingTokenRow("{task}", "The task, e.g. \u{201C}Document\u{201D} or \u{201C}Photo\u{201D}")
                namingTokenRow("{label}", "The document\u{2019}s name, given in the page strip")
            }
        }
        .padding(14)
        .frame(width: 300, alignment: .leading)
    }

    private func namingTokenRow(_ token: String, _ meaning: String) -> some View {
        GridRow {
            Text(token)
                .font(.system(.caption, design: .monospaced).weight(.semibold))
            Text(meaning)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Adjustments

    // All adjustment sliders use one -100...+100 scale: 0 is neutral and sits at the
    // center. The bindings below map that UI scale onto the underlying parameter ranges
    // (settings/presets keep their original semantics on disk).

    private var adjustmentsSection: some View {
        let summary: String = InspectorSections.adjustmentsSummary(state.settings.adjustments)
        return section(InspectorSections.adjustments, title: "Adjustments", summary: summary, changed: !summary.isEmpty) {
            Toggle("Auto-enhance", isOn: $state.settings.adjustments.autoEnhance)
            amountSlider("Brightness", value: brightnessAmount)
            amountSlider("Contrast", value: contrastAmount)
            amountSlider("Saturation", value: saturationAmount)
            amountSlider("Sharpness", value: sharpnessAmount)
                .help("Positive sharpens, negative softens")
            Button {
                resetAdjustmentSliders()
            } label: {
                Label("Reset", systemImage: "arrow.counterclockwise")
            }
            .controlSize(.small)
            .disabled(slidersAreNeutral)
            .help("Put the four sliders back to neutral")
            Toggle("Remove print dots", isOn: $state.settings.adjustments.descreen)
                .help("Smooths the dot pattern of magazines and printed photos (descreen)")
            Toggle("Restore faded colors", isOn: $state.settings.adjustments.restoreFadedColors)
            if state.settings.colorMode == .blackWhite {
                LabeledContent("B&W threshold") {
                    HStack(spacing: 6) {
                        Slider(value: $state.settings.adjustments.blackWhiteThreshold, in: 0...1)
                        Text("\(Int((state.settings.adjustments.blackWhiteThreshold * 100).rounded()))")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 34, alignment: .trailing)
                    }
                }
            }
        }
    }

    private func amountSlider(_ title: LocalizedStringKey, value: Binding<Double>) -> some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                Slider(value: value, in: -100...100)
                Text(amountText(value.wrappedValue))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)
            }
        }
    }

    private func amountText(_ amount: Double) -> String {
        let rounded = Int(amount.rounded())
        return rounded == 0 ? "0" : String(format: "%+d", rounded)
    }

    /// Brightness -1...1 ↔ -100...100, linear.
    private var brightnessAmount: Binding<Double> {
        Binding(get: { state.settings.adjustments.brightness * 100 },
                set: { state.settings.adjustments.brightness = $0 / 100 })
    }

    /// Contrast 0.25...4 ↔ -100...100 exponentially, so 0 is exactly neutral (1.0).
    private var contrastAmount: Binding<Double> {
        Binding(get: { log(max(state.settings.adjustments.contrast, 0.25)) / log(4.0) * 100 },
                set: { state.settings.adjustments.contrast = pow(4.0, $0 / 100) })
    }

    /// Saturation 0...2 ↔ -100...100, linear around neutral 1.
    private var saturationAmount: Binding<Double> {
        Binding(get: { (state.settings.adjustments.saturation - 1) * 100 },
                set: { state.settings.adjustments.saturation = 1 + $0 / 100 })
    }

    /// Sharpness -2...2 ↔ -100...100; negative values soften (see ImagePipeline).
    private var sharpnessAmount: Binding<Double> {
        Binding(get: { state.settings.adjustments.sharpness * 50 },
                set: { state.settings.adjustments.sharpness = $0 / 50 })
    }

    private var slidersAreNeutral: Bool {
        let a = state.settings.adjustments
        return a.brightness == 0 && a.contrast == 1 && a.saturation == 1 && a.sharpness == 0
    }

    private func resetAdjustmentSliders() {
        state.settings.adjustments.brightness = 0
        state.settings.adjustments.contrast = 1
        state.settings.adjustments.saturation = 1
        state.settings.adjustments.sharpness = 0
    }

    // MARK: Presets

    private var presetsSection: some View {
        Section("Presets") {
            Menu {
                if state.presets.isEmpty {
                    Button("No Presets Saved") {}
                        .disabled(true)
                } else {
                    ForEach(state.presets) { preset in
                        Button(preset.name) {
                            let appState = state
                            appState.leaveIdCard {
                                appState.applyPreset(preset)
                                appState.clearAppendTarget()
                            }
                        }
                    }
                }
                Divider()
                Button("Save current as preset…") {
                    newPresetName = ""
                    showSavePresetAlert = true
                }
                if !state.presets.isEmpty {
                    Menu("Delete Preset") {
                        ForEach(state.presets) { preset in
                            Button(preset.name, role: .destructive) {
                                state.deletePreset(id: preset.id)
                            }
                        }
                    }
                }
            } label: {
                Label("Presets", systemImage: "slider.horizontal.3")
            }
            .contextMenu {
                ForEach(state.presets) { preset in
                    Button("Delete \u{201C}\(preset.name)\u{201D}", role: .destructive) {
                        state.deletePreset(id: preset.id)
                    }
                }
            }
        }
    }

    // MARK: Actions

    private var actionArea: some View {
        VStack(spacing: 10) {
            if state.isBusy {
                HStack(spacing: 10) {
                    ProgressView(value: state.progress?.fraction)
                        .progressViewStyle(.linear)
                    Button("Cancel") { state.cancelScan() }
                }
            }
            HStack(spacing: 10) {
                Button {
                    state.performOverview()
                } label: {
                    Label("Preview", systemImage: "viewfinder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(state.isBusy || previewUnavailable)
                .help("Quick look at the whole glass")

                Button {
                    state.performScan()
                } label: {
                    Label(state.primaryActionLabel, systemImage: "scanner")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(state.isBusy)
            }
            .controlSize(.large)
            // Photos of documents become pages of the queue too, with no scanner (AppState+Import.swift).
            if PhotoImport.isOffered(state.settings) {
                Button {
                    state.chooseAndImportPhotos()
                } label: {
                    Label(PhotoImport.buttonLabel, systemImage: "photo.on.rectangle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!state.canImportPhotos)
                .help(PhotoImport.buttonHint)
                .accessibilityHint(Text(PhotoImport.buttonHelp))
            }
        }
        .padding(12)
        .background(.bar)
    }

    private var previewUnavailable: Bool {
        state.capabilities?.supportsOverview == false || state.settings.source == .documentFeeder
    }
}

/// The header of a section of the settings column: its title, and while collapsed what is on in it
/// (a lock first for a password) with a dot when something differs from the default.
private struct InspectorSectionHeader: View {
    let title: String
    let summary: String
    let changed: Bool
    let locked: Bool
    let collapsed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.headline)
                if collapsed && changed {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                }
            }
            if collapsed && !summary.isEmpty {
                HStack(spacing: 3) {
                    if locked {
                        Image(systemName: "lock.fill")
                            .accessibilityHidden(true)
                    }
                    Text(summary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
}
#endif
