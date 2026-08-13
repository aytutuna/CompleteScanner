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
        VStack(spacing: 0) {
            settingsForm
            Divider()
            actionArea
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

    // MARK: Output

    private var outputSection: some View {
        Section("Output") {
            Picker("Format", selection: $state.settings.format) {
                ForEach(availableFormats) { format in
                    Text(format.label).tag(format)
                }
            }
            if state.settings.format == .jpeg {
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

    private var availableFormats: [OutputFormat] {
        state.settings.intent == .document ? [.pdf, .jpeg, .png, .tiff] : [.jpeg, .png, .tiff]
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
            Toggle("Collect pages, save one PDF", isOn: $state.settings.documentMultiPage)
            Toggle("Searchable PDF (OCR)", isOn: $state.settings.pdfSearchable)
                .help("Text is recognized in any language automatically — nothing to configure.")
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
                        Button(preset.name) { state.applyPreset(preset) }
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
                    Label("Scan", systemImage: "scanner")
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
