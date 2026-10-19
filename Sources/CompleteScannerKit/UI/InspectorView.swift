import AppKit
import SwiftUI

/// Right column: the full control panel — every scan setting, presets, and the
/// Preview / Scan / Cancel actions pinned at the bottom.
struct InspectorView: View {
    @EnvironmentObject var state: AppState

    @State private var showNamingHelp = false
    @State private var showSavePresetAlert = false
    @State private var newPresetName = ""

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
            scanSection
            outputSection
            if state.settings.intent == .photo {
                photosSection
            }
            if state.settings.intent == .document {
                documentSection
            }
            adjustmentsSection
            presetsSection
        }
        .formStyle(.grouped)
        .disabled(state.isBusy)
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
        }
    }

    /// Why the mode and the source cannot be changed while a side of an ID card is held: changing
    /// them would end the task and drop the card. Leaving the task asks first.
    private static let idCardHeldHint =
        "The ID card task needs the flatbed in Document mode. Save or discard the card, or leave the task, to change this."

    /// What the paper size picker says: for a copy, Automatic on the glass is the printer's paper.
    private var paperSizeHint: String {
        state.isCopyFlow
            ? PrintText.copyPaperHint(state.settings.paperSize, source: state.settings.source)
            : PaperSizes.hint(state.settings.paperSize, source: state.settings.source)
    }

    // MARK: Copies

    /// The Copy task: where and how the copies print (AppState+Copy.swift). The print panel opens set
    /// to these, at 100 %.
    private var copySection: some View {
        Section("Copies") {
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
                Text(state.settings.taskOptions.copyFitToPage
                     ? "Made smaller to fit the paper, never larger. It is not at real size."
                     : "At real size, like a photocopier: 1 inch on the glass is 1 inch on paper.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let warning = state.copyMarginWarning {
                    Text(warning)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle("Also save a PDF", isOn: Binding(
                    get: { state.settings.taskOptions.copyAlsoSavePdf },
                    set: { state.setCopyAlsoSavePdf($0) }))
                    .help("Each copy is also saved as a PDF in the save folder")
                Button("Print Ruler Test Page\u{2026}") {
                    state.printRulerPage()
                }
                .help("Prints a 1-inch grid with centimetre ticks: measure it with a ruler to check that copies come out at real size")
            } else {
                Text("No printer is installed. Add one in System Settings \u{2192} Printers & Scanners, then look again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
        let pdf = state.settings.format.pageFormat == .pdf
        let dateHint: String
        if !options.receiptNameByDate {
            dateHint = "Each file is named by today's date."
        } else if Receipts.namesByDate(state.settings) {
            dateHint = "Each file is named by the date printed on the receipt ({docdate}), read from its text; today's date when none is found."
        } else {
            dateHint = "The file name has no {docdate}, so the date printed on the receipt is not used."
        }
        return Section("Receipts") {
            Toggle("Name by the receipt's date", isOn: Binding(
                get: { state.settings.taskOptions.receiptNameByDate },
                set: { state.setReceiptNameByDate($0) }))
            Text(dateHint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("One PDF for all receipts", isOn: Binding(
                get: { state.settings.taskOptions.receiptCombine },
                set: { state.setReceiptCombine($0) }))
                .disabled(!pdf)
            Text(!pdf
                 ? "Only for PDFs: each receipt is saved as an image of its own."
                 : options.receiptCombine
                 ? "All the receipts of a scan go into one PDF, a page each, named by the earliest date."
                 : "Each receipt is saved as a PDF of its own.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Scan

    private var scanSection: some View {
        Section("Scan") {
            Picker("Source", selection: $state.settings.source) {
                ForEach(availableSources) { source in
                    Text(source.label).tag(source)
                }
            }
            .disabled(state.hasIdCardCaptures)
            .help(state.hasIdCardCaptures ? Self.idCardHeldHint : "")
            if availableSources.contains(.documentFeeder) {
                sidesRows
            }
            paperSizeRow
            Picker("Resolution", selection: $state.settings.resolution) {
                ForEach(availableResolutions, id: \.self) { dpi in
                    Text("\(dpi) dpi").tag(dpi)
                }
            }
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
    /// caption says why a choice is left out. Twin of the Windows inspector's "Sides".
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

    private var sidesCaption: String {
        let s = state.settings
        guard feederSelected else { return DocumentSides.feederOnlyReason }
        if s.duplex == .manual, let reason = DocumentSides.manualUnavailableReason(s) { return reason }
        if s.duplex == .off, let reason = bothSidesReason { return "\(s.duplex.hint) \(reason)" }
        return s.duplex.hint
    }

    /// One side, both, or turned over by hand, for scanners with a feeder; usable while the
    /// feeder is the source. With both sides, along which edge the sheets turn.
    @ViewBuilder
    private var sidesRows: some View {
        Picker("Sides", selection: $state.settings.duplex) {
            ForEach(offeredSides) { mode in
                Text(mode.label).tag(mode)
            }
        }
        .disabled(!feederSelected)
        .help(sidesCaption)
        Text(sidesCaption)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        if feederSelected && state.settings.duplex != .off {
            Picker("Flip on", selection: $state.settings.backBinding) {
                ForEach(DuplexBinding.allCases) { binding in
                    Text(binding.label).tag(binding)
                }
            }
            .help("How the sheets turn: the backs of short-edge sheets are turned upright.")
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

    private var paperSizeRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Paper size", selection: $state.settings.paperSize) {
                ForEach(offeredPaperSizes) { size in
                    Text(size == .auto ? size.label : "\(size.label) (\(size.detail))").tag(size)
                }
            }
            .help(paperSizeHint)
            Text(paperSizeHint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if offeredPaperSizes.count < PaperSize.allCases.count {
                Text("Sizes larger than this scanner's \(feederSelected ? "feeder" : "glass") takes are left out.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Output

    private var outputSection: some View {
        Section("Output") {
            Picker("Format", selection: shownFormatBinding) {
                ForEach(availableFormats) { format in
                    Text(format.label).tag(format)
                }
            }
            if shownFormat == .jpeg {
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
            if shownFormat == .pdf {
                pdfSizeRow
            }
            afterSavePicker
            LabeledContent("Destination") {
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
            LabeledContent("Name") {
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
    }

    /// How small saved PDFs are made: one segment per size (largest first), the chosen size's
    /// hint, and the size of the PDF saved last. Twin of the Windows inspector's "PDF size".
    private var pdfSizeRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("PDF size")
            Picker("PDF size", selection: $state.settings.output.pdfSize) {
                ForEach(PDFSizePreset.displayOrder) { size in
                    Text(size.label).tag(size)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help(state.settings.output.pdfSize.hint)
            Text(state.settings.output.pdfSize.hint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let bytes = state.lastPDFByteCount {
                Text("Last PDF: \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
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

    // MARK: Photos

    private var photosSection: some View {
        Section("Photos") {
            Toggle("Auto-split multiple photos", isOn: $state.settings.photoAutoSplit)
            Toggle("Auto-straighten (deskew)", isOn: $state.settings.photoAutoDeskew)
            Stepper(value: $state.settings.photoMinSideInches, in: 0.5...4, step: 0.1) {
                LabeledContent("Min photo side",
                               value: String(format: "%.1f in", state.settings.photoMinSideInches))
            }
            Stepper(value: $state.settings.photoCropInsetPixels, in: 0...20) {
                LabeledContent("Edge trim", value: "\(state.settings.photoCropInsetPixels) px")
            }
        }
    }

    // MARK: Document / PDF

    private var documentSection: some View {
        Section("Document") {
            Toggle("Collect pages, then \(shownFormat.saveTitle)", isOn: $state.settings.documentMultiPage)
                .disabled(state.isReceiptFlow)
                .help(state.isReceiptFlow ? "Receipts are checked in a review, then saved: a file each, or one PDF." as String : "")
            Toggle("Searchable PDF (OCR)", isOn: $state.settings.pdfSearchable)
                .help("Text is recognized in any language automatically — nothing to configure.")
            alsoSaveTextRow
            blankPagesRow
            geometryRow
        }
    }

    /// The text of the pages in a .txt file beside each PDF; OCR reads each page once for both. Off,
    /// with the reason, when the save writes no PDF, and in the ID card and Copy tasks, whose PDFs
    /// are saved without it. Twin of the Windows inspector's "Also save text".
    private var alsoSaveTextRow: some View {
        let flow = TaskCatalog.flow(of: state.settings)
        let savesPDF = flow == .receiptSplit
            ? state.settings.format.pageFormat == .pdf
            : state.settings.format.savesPDF(collectsPages: state.settings.documentMultiPage)
        let hint: String
        switch flow {
        case .idCard:
            hint = "Not for ID cards: the card is saved as a picture, without its text."
        case .copy:
            hint = "Not for copies: the PDF of a copy is saved without its text."
        case .receiptSplit where savesPDF:
            hint = "Writes the text of each receipt beside its PDF, in a .txt file with the same name."
        default:
            hint = savesPDF
                ? "Writes the text of the pages beside each PDF, in a .txt file with the same name."
                : "Only for PDFs: Word and text files are the text already, and images have none."
        }
        return Toggle("Also save text (.txt)", isOn: $state.settings.output.alsoSaveText)
            .disabled(!savesPDF || (flow != .documentQueue && flow != .receiptSplit))
            .help(hint)
    }

    /// Crop and straighten: run on pages collected in the queue only, where a changed page shows a
    /// swap button; with each scan saved at once, and for copies, the switches are off and say why.
    /// Twin of the Windows inspector's "Crop to page" and "Straighten pages".
    private var geometryRow: some View {
        let isCopy = state.isCopyFlow
        let isReceipts = state.isReceiptFlow
        let collecting = state.settings.documentMultiPage && !isCopy && !isReceipts
        let document = state.settings.document
        let hint: String
        switch (collecting, document.autoCrop, document.autoStraighten) {
        case (false, _, _) where isCopy:
            hint = "Copies print every page as scanned: pages are not cropped or straightened."
        case (false, _, _) where isReceipts:
            hint = "Each receipt is cut out along its paper, or around its print, and turned straight on its own."
        case (false, _, _):
            hint = "Only for pages collected before saving: a scan saved at once is kept as scanned."
        case (true, true, true):
            hint = "Pages are cut out of the scanner background and turned straight when that is clear. Click the arrow on a page to see it as scanned."
        case (true, true, false):
            hint = "Pages are cut out of the scanner background when that is clear. Click the arrow on a page to see it as scanned."
        case (true, false, true):
            hint = "Pages that lie at a slant are turned straight when that is clear. Click the arrow on a page to see it as scanned."
        case (true, false, false):
            hint = "Cut each page out of the scanner background, and turn pages that lie at a slant."
        }
        return VStack(alignment: .leading, spacing: 6) {
            Toggle("Crop to page", isOn: $state.settings.document.autoCrop)
                .disabled(!collecting)
                .help(hint)
            Toggle("Straighten pages", isOn: $state.settings.document.autoStraighten)
                .disabled(!collecting)
                .help(hint)
            Text(hint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Blank pages: flagged in the page strip, left out when saving. The check runs on pages
    /// collected in the queue only, where flagged pages can be seen and kept; with each scan saved
    /// at once, and for copies, the switch is off and says why. Twin of the Windows inspector's "Skip
    /// blank pages".
    private var blankPagesRow: some View {
        let isCopy = state.isCopyFlow
        let isReceipts = state.isReceiptFlow
        let collecting = state.settings.documentMultiPage && !isCopy && !isReceipts
        let hint: String
        if isCopy {
            hint = "Copies print every page as scanned: blank pages are not left out."
        } else if isReceipts {
            hint = "Receipts are found on the glass and checked before saving: there are no blank pages to leave out."
        } else if collecting {
            hint = state.settings.document.removeBlankPages
                ? "Blank pages are marked in the page strip and left out when you save. Click Keep on a page to save it."
                : "Blank pages are marked in the page strip. Click Skip on a page to leave it out."
        } else {
            hint = "Only for pages collected before saving: a scan saved at once keeps every page."
        }
        return VStack(alignment: .leading, spacing: 6) {
            Toggle("Skip blank pages", isOn: $state.settings.document.removeBlankPages)
                .disabled(!collecting)
                .help(hint)
            Text(hint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
                Text(state.settings.document.blankSensitivity.hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Adjustments

    // All adjustment sliders use one -100...+100 scale: 0 is neutral and sits at the
    // center. The bindings below map that UI scale onto the underlying parameter ranges
    // (settings/presets keep their original semantics on disk).

    private var adjustmentsSection: some View {
        Section {
            DisclosureGroup("Adjustments") {
                Toggle("Auto-enhance", isOn: $state.settings.adjustments.autoEnhance)
                amountSlider("Brightness", value: brightnessAmount)
                amountSlider("Contrast", value: contrastAmount)
                amountSlider("Saturation", value: saturationAmount)
                amountSlider("Sharpness", value: sharpnessAmount)
                    .help("Positive sharpens, negative softens")
                Button {
                    resetAdjustmentSliders()
                } label: {
                    Label("Reset Sliders", systemImage: "arrow.counterclockwise")
                }
                .controlSize(.small)
                .disabled(slidersAreNeutral)
                Toggle("Descreen printed material", isOn: $state.settings.adjustments.descreen)
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
                            appState.leaveIdCard { appState.applyPreset(preset) }
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
                .help("Fast low-resolution preview of the whole flatbed")

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
        }
        .padding(12)
        .background(.bar)
    }

    private var previewUnavailable: Bool {
        state.capabilities?.supportsOverview == false || state.settings.source == .documentFeeder
    }
}
