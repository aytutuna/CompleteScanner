#if os(iOS)
import CompleteScannerKit
import SwiftUI

/// Camera mode's kinds as the Camera app has its modes: a row under the viewfinder (`IOSShell.cameraKinds`)
/// that snaps one kind into its middle, the one there in the accent colour, the others grey. Swiping the
/// row or tapping a kind picks it (`onKind`, as the printer screen's chips do); a pick that does not happen
/// (the ID card's or the pages' question answered Cancel, a kind that cannot be started) brings the row back
/// to the kind set up. Still while a scan or an import runs. Every kind is as wide as its word and the same
/// space either side of it, so the gaps between the words are all alike; the text is one size throughout,
/// capped by the camera screen at the first accessibility size, and a row too long for the screen scrolls.
struct KindsRow: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var importer: IOSImportSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion: Bool
    let onKind: (IOSScanKind) -> Void
    /// The kind in the row's middle: followed while the row is swiped, set when it is moved to a kind.
    @State private var middle: IOSScanKind?
    @State private var position: ScrollPosition = ScrollPosition(idType: IOSScanKind.self)
    /// The person is moving the row, rather than the row moving itself to a kind.
    @State private var swiping: Bool = false
    /// Each kind's width as laid out, for snapping its middle to the row's.
    @State private var widths: [IOSScanKind: CGFloat] = [:]
    /// Half the row's width.
    @State private var inset: CGFloat = 0

    /// Half the gap between two kinds.
    @ScaledMetric(relativeTo: .footnote) private var gap: CGFloat = 12

    var body: some View {
        let current: IOSScanKind = IOSShell.shownKind(state.settings)
        let busy: Bool = state.isBusy || importer.isImporting
        let tiles: [IOSKindTile] = IOSShell.kindTiles(state.taskCards, current: current, order: IOSShell.cameraKinds)
        let middles: [CGFloat] = centres(tiles)
        row(tiles, middles: middles, busy: busy, current: current)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .onGeometryChange(for: CGFloat.self) { (proxy: GeometryProxy) -> CGFloat in
                proxy.size.width / 2
            } action: { (half: CGFloat) in
                inset = half
            }
            .modifier(EdgeFade(leading: 28, trailing: 28))
            .onAppear {
                middle = current
                scroll(to: current, in: tiles, middles: middles)
            }
            .onChange(of: current) { (_: IOSScanKind, kind: IOSScanKind) in
                centre(kind)
            }
            // The kinds are measured after the row first appears, and again when the text size or the row's
            // width changes: the row is put back on its kind then, as it cannot be before.
            .onChange(of: middles) { (_: [CGFloat], new: [CGFloat]) in
                if !swiping {
                    scroll(to: middle ?? current, in: tiles, middles: new)
                }
            }
        .sensoryFeedback(SensoryFeedback.selection, trigger: middle) { (old: IOSScanKind?, new: IOSScanKind?) -> Bool in
            old != nil && new != nil && old != new
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("kinds.row")
    }

    private func row(_ tiles: [IOSKindTile], middles: [CGFloat], busy: Bool, current: IOSScanKind) -> some View {
        let shown: IOSScanKind = middle ?? current
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(tiles) { (tile: IOSKindTile) in
                    item(tile, highlighted: tile.kind == shown, busy: busy)
                }
            }
            .scrollTargetLayout()
            // Padding in the content rather than safe-area padding, so the snap's offsets are plain content
            // coordinates; half the row either side lets the first and last kinds reach the middle.
            .padding(.horizontal, inset)
        }
        .scrollTargetBehavior(CentreSnap(middles: middles))
        .scrollPosition($position)
        .scrollDisabled(busy)
        // Worked out here rather than read from the position's id, which SwiftUI may report by the leading
        // visible kind; a kind's own move to the middle passes others on the way, so only a swipe counts.
        .onScrollGeometryChange(for: CGFloat.self) { (geometry: ScrollGeometry) -> CGFloat in
            geometry.visibleRect.midX
        } action: { (_: CGFloat, mid: CGFloat) in
            if swiping, let index = CentreSnap.nearest(to: mid, in: middles) {
                middle = tiles[index].kind
            }
        }
        .onScrollPhaseChange { (_: ScrollPhase, phase: ScrollPhase) in
            swiping = phase == .interacting || phase == .decelerating
            if !phase.isScrolling {
                settle()
            }
        }
    }

    /// The kinds' middles in the row's content, in its order; empty until the row and every kind are laid out.
    private func centres(_ tiles: [IOSKindTile]) -> [CGFloat] {
        guard inset > 0 else { return [] }
        var leading: CGFloat = inset
        var middles: [CGFloat] = []
        for tile in tiles {
            guard let width = widths[tile.kind] else { return [] }
            middles.append(leading + width / 2)
            leading += width
        }
        return middles
    }

    private func item(_ tile: IOSKindTile, highlighted: Bool, busy: Bool) -> some View {
        let kind: IOSScanKind = tile.kind
        let available: Bool = tile.availability.isAvailable
        let hint: String = available ? kind.subtitle : "\(kind.subtitle). Not available: \(tile.availability.reason ?? "")"
        return Button {
            onKind(kind)
        } label: {
            Text(kind.title)
                .textCase(.uppercase)
                .font(.footnote.weight(.semibold))
                .tracking(0.8)
                .foregroundStyle(highlighted ? Color.accentColor : Color.secondary)
                .lineLimit(1)
                .padding(.horizontal, gap)
                .frame(height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onGeometryChange(for: CGFloat.self) { (proxy: GeometryProxy) -> CGFloat in
            proxy.size.width
        } action: { (width: CGFloat) in
            widths[kind] = width
        }
        .disabled(!available || busy)
        .opacity(available ? 1 : 0.5)
        .accessibilityLabel(Text(kind.title))
        .accessibilityAddTraits(tile.isCurrent ? AccessibilityTraits.isSelected : [])
        .accessibilityHint(Text(hint))
        .accessibilityIdentifier("kinds.\(kind.rawValue)")
    }

    /// The row came to rest: the kind in its middle is picked; if it was not, the row goes back.
    private func settle() {
        let appState: AppState = state
        guard let kind = middle, kind != IOSShell.shownKind(appState.settings) else { return }
        onKind(kind)
        Task { @MainActor in
            let now: IOSScanKind = IOSShell.shownKind(appState.settings)
            if middle != now {
                centre(now)
            }
        }
    }

    /// Moves the row so `kind` is in its middle.
    private func centre(_ kind: IOSScanKind) {
        let tiles: [IOSKindTile] = IOSShell.kindTiles(state.taskCards, current: kind, order: IOSShell.cameraKinds)
        withAnimation(animation) {
            middle = kind
            scroll(to: kind, in: tiles, middles: centres(tiles))
        }
    }

    /// Scrolls so `kind`'s middle is the row's, by offset: the kinds' own ids would centre them by SwiftUI's
    /// reckoning, which the snap does not share. Nothing to do until the kinds are measured.
    private func scroll(to kind: IOSScanKind, in tiles: [IOSKindTile], middles: [CGFloat]) {
        guard let index = tiles.firstIndex(where: { (tile: IOSKindTile) -> Bool in tile.kind == kind }),
              index < middles.count else { return }
        position.scrollTo(x: middles[index] - inset)
    }

    private var animation: Animation {
        reduceMotion ? Animation.easeInOut(duration: 0.2) : Animation.spring(duration: 0.35, bounce: 0.15)
    }
}

/// Where a swipe would come to rest, moved so the kind nearest the row's middle lands with its middle there:
/// `.viewAligned` lines up leading edges, which centres a kind only while all are as wide.
private struct CentreSnap: ScrollTargetBehavior {
    /// The kinds' middles in the row's content; empty until they are laid out, when a swipe rests where it ends.
    let middles: [CGFloat]

    func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
        guard let index = CentreSnap.nearest(to: target.rect.midX, in: middles) else { return }
        target.rect.origin.x = middles[index] - target.rect.width / 2
    }

    static func nearest(to x: CGFloat, in middles: [CGFloat]) -> Int? {
        middles.indices.min { (a: Int, b: Int) -> Bool in
            abs(middles[a] - x) < abs(middles[b] - x)
        }
    }
}

/// A scrolling row that fades out at its edges instead of cutting a word off there.
struct EdgeFade: ViewModifier {
    let leading: CGFloat
    let trailing: CGFloat

    func body(content: Content) -> some View {
        content
            .mask {
                HStack(spacing: 0) {
                    LinearGradient(colors: [Color.clear, Color.black], startPoint: .leading, endPoint: .trailing)
                        .frame(width: leading)
                    Color.black
                    LinearGradient(colors: [Color.black, Color.clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: trailing)
                }
            }
    }
}

/// A group of camera mode's options drawer, an icon each in its row.
enum CameraDrawerGroup: String, Identifiable, CaseIterable {
    case export
    case colour
    case quality
    case flash
    case camera

    var id: String { rawValue }

    var title: String {
        switch self {
        case .export: return "Export"
        case .colour: return "Colour"
        case .quality: return "Quality"
        case .flash: return IOSCameraText.flashLabel
        case .camera: return IOSImportText.cameraLabel
        }
    }

    var symbol: String {
        switch self {
        case .export: return "doc.text"
        case .colour: return "circle.lefthalf.filled"
        case .quality: return "slider.horizontal.3"
        case .flash: return "bolt"
        case .camera: return "camera"
        }
    }

    /// The groups that apply to the settings and the `pageCount` pages queued: Export while the pages are
    /// saved here (`IOSShell.offersSave`), Quality while Save writes a PDF (its size), Flash where the camera
    /// has a light (`torch`), Colour and Camera always.
    static func shown(_ settings: ScanSettings, pageCount: Int, torch: Bool) -> [CameraDrawerGroup] {
        var groups: [CameraDrawerGroup] = []
        if IOSShell.offersSave(settings, pageCount: pageCount) {
            groups.append(.export)
        }
        groups.append(.colour)
        if IOSShell.offersPDFOptions(settings) {
            groups.append(.quality)
        }
        if torch {
            groups.append(.flash)
        }
        groups.append(.camera)
        return groups
    }
}

/// Camera mode's options, in place of the kinds when the chevron is up, so they never cover the picture:
/// a row of icons, one per group that applies (`CameraDrawerGroup.shown`), and the chosen group's controls
/// under it. Export: the format, then chips for Separate documents, One PDF per page, PDF/A, Password and
/// Also .txt where they apply, and More… for the whole Export sheet (separator sheets, After saving).
/// Colour: the filter new pages get, or the colour mode for the kinds that collect no pages (and Restore
/// faded colours for Photos). Quality: the PDF's size. Flash: the camera's light (its torch), where it has
/// one. Camera: the automatic shutter, Both sides and how the sides or a book's pages are taken, and Use
/// Apple's scanner where the task offers it.
struct CameraDrawer: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var importer: IOSImportSession
    @ObservedObject var model: IOSCameraModel
    @Binding var group: CameraDrawerGroup
    let scanner: IOSCameraAvailability
    let onExportSheet: () -> Void
    let onAppleScanner: () -> Void

    var body: some View {
        let groups: [CameraDrawerGroup] = CameraDrawerGroup.shown(state.settings, pageCount: state.scannedPages.count,
                                                                  torch: model.hasTorch)
        let shown: CameraDrawerGroup = groups.contains(group) ? group : (groups.first ?? CameraDrawerGroup.camera)
        VStack(spacing: 10) {
            HStack(spacing: 14) {
                ForEach(groups) { (item: CameraDrawerGroup) in
                    groupButton(item, selected: item == shown)
                }
            }
            .frame(height: 56)
            // The icons sit in fixed circles.
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            controls(shown)
                .padding(.horizontal, 16)
                .disabled(state.isBusy || importer.isImporting)
        }
        .padding(.bottom, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("drawer")
    }

    private func groupButton(_ item: CameraDrawerGroup, selected: Bool) -> some View {
        Button {
            group = item
        } label: {
            Image(systemName: item.symbol)
                .font(.body.weight(.medium))
                .foregroundStyle(selected ? Color.white : Color.primary)
                .frame(width: 44, height: 44)
                .background(Circle().fill(selected ? Color.accentColor : Color(uiColor: .tertiarySystemFill)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(item.title))
        .accessibilityAddTraits(selected ? AccessibilityTraits.isSelected : [])
        .accessibilityIdentifier("drawer.\(item.rawValue)")
    }

    @ViewBuilder
    private func controls(_ shown: CameraDrawerGroup) -> some View {
        switch shown {
        case .export:
            ExportDrawer(onMore: onExportSheet)
        case .colour:
            ColourDrawer()
        case .quality:
            Picker("PDF size", selection: pdfSize) {
                ForEach(PDFSizePreset.displayOrder, id: \.self) { (size: PDFSizePreset) in
                    Text(size.label).tag(size)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("drawer.pdfSize")
        case .flash:
            Picker(IOSCameraText.flashLabel, selection: torch) {
                Text(IOSCameraText.offValue).tag(false)
                Text(IOSCameraText.onValue).tag(true)
            }
            .pickerStyle(.segmented)
            .disabled(!model.lifecycle.isLive)
            .accessibilityIdentifier("camera.torch")
        case .camera:
            cameraControls
        }
    }

    private var cameraControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(IOSCameraText.autoShutterLabel, isOn: autoShutter)
                .accessibilityHint(Text(IOSCameraText.autoHint))
                .accessibilityIdentifier("camera.auto")
            if IOSShell.shownKind(state.settings) == .document {
                BothSidesToggle()
            }
            TaskWayPicker()
            if IOSShell.offersCamera(state.activeTask) {
                AppleScannerRow(scanner: scanner, onScanner: onAppleScanner)
            }
        }
    }

    private var pdfSize: Binding<PDFSizePreset> {
        let appState: AppState = state
        return Binding<PDFSizePreset>(
            get: { appState.settings.output.pdfSize },
            set: { (size: PDFSizePreset) in
                appState.settings.output.pdfSize = size
            })
    }

    private var torch: Binding<Bool> {
        let shown: IOSCameraModel = model
        return Binding<Bool>(
            get: { shown.torchOn },
            set: { (on: Bool) in
                guard on != shown.torchOn else { return }
                Task { @MainActor in
                    await shown.toggleTorch()
                }
            })
    }

    private var autoShutter: Binding<Bool> {
        let shown: IOSCameraModel = model
        return Binding<Bool>(
            get: { shown.autoShutter },
            set: { (on: Bool) in
                shown.setAutoShutter(on)
            })
    }
}

/// The drawer's Export group: the format, then a chip for each choice that applies to it.
private struct ExportDrawer: View {
    @EnvironmentObject private var state: AppState
    let onMore: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Format", selection: format) {
                ForEach(IOSShell.exportFormats(state.settings)) { (choice: OutputFormat) in
                    Text(ExportOptions.label(choice)).tag(choice)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("drawer.format")
            ScrollView(.horizontal, showsIndicators: false) {
                chips
            }
        }
    }

    private var chips: some View {
        let s: ScanSettings = state.settings
        let separates: Bool = IOSShell.separatesDocuments(s)
        let batch: TaskAvailability = TaskCatalog.availability(of: .batch, capabilities: state.capabilities)
        let output: OutputOptions = s.output
        return HStack(spacing: 6) {
            if IOSShell.shownKind(s) == .document {
                DrawerChip(title: "Separate documents", isOn: separates, action: toggleSeparate)
                    .disabled(!separates && !batch.isAvailable)
                    .accessibilityIdentifier("chip.separate")
            }
            if !separates && IOSShell.exportFormat(s) == .pdf {
                DrawerChip(title: IOSShell.eachPageTitle(s), isOn: IOSShell.savesEachPage(s), action: toggleEachPage)
                    .accessibilityIdentifier("chip.eachPage")
            }
            if IOSShell.offersPDFOptions(s) {
                DrawerChip(title: "PDF/A", isOn: IOSPDFOptions.archivalShown(output), action: toggleArchival)
                    .disabled(output.protect)
                    .accessibilityHint(Text(output.protect ? PDFA.cannotProtectNote : PDFA.optionHint))
                    .accessibilityIdentifier("chip.archival")
                DrawerChip(title: "Password", isOn: output.protect, action: toggleProtect)
                    .disabled(IOSPDFOptions.archivalShown(output))
                    .accessibilityHint(Text(PDFProtection.optionHint))
                    .accessibilityIdentifier("chip.protect")
                DrawerChip(title: "Also .txt", isOn: output.alsoSaveText, action: toggleAlsoSaveText)
                    .accessibilityHint(Text(IOSPDFOptions.alsoSaveTextHint))
                    .accessibilityIdentifier("chip.alsoSaveText")
            }
            DrawerChip(title: "More\u{2026}", isOn: nil, action: onMore)
                .accessibilityHint(Text("Opens all the Export options"))
                .accessibilityIdentifier("chip.more")
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

    private func toggleSeparate() {
        let on: Bool = !IOSShell.separatesDocuments(state.settings)
        let s: ScanSettings = IOSShell.settingSeparate(on, in: state.settings)
        state.settings = SettingsAdapter.adapt(s, to: state.capabilities).settings
    }

    private func toggleEachPage() {
        state.settings = IOSShell.settingEachPage(!IOSShell.savesEachPage(state.settings), in: state.settings)
    }

    private func toggleArchival() {
        var s: ScanSettings = state.settings
        s.output = IOSPDFOptions.settingArchival(!IOSPDFOptions.archivalShown(s.output), in: s.output)
        state.settings = IOSShell.keepingKind(s)
    }

    private func toggleProtect() {
        var s: ScanSettings = state.settings
        s.output = IOSPDFOptions.settingProtect(!s.output.protect, in: s.output)
        state.settings = IOSShell.keepingKind(s)
    }

    private func toggleAlsoSaveText() {
        state.settings.output.alsoSaveText.toggle()
    }
}

/// The drawer's Colour group: the filter new pages get (Original, Enhanced, Grayscale, B&W) for the kinds that
/// collect pages, else the colour mode, and for Photos whether faded colours are restored.
private struct ColourDrawer: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if IOSShell.shownKind(state.settings) == .photos {
                Picker("Photos", selection: restore) {
                    Text("As taken").tag(false)
                    Text("Restored").tag(true)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("drawer.restore")
            }
            if IOSShell.offersFilters(state.settings) {
                Picker("Colour", selection: filter) {
                    ForEach(CaptureFilter.displayOrder, id: \.self) { (choice: CaptureFilter) in
                        Text(choice.label).tag(choice)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("drawer.colourMode")
            } else {
                Picker("Colour", selection: $state.settings.colorMode) {
                    ForEach(ColorMode.allCases) { (mode: ColorMode) in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("drawer.colourMode")
            }
        }
    }

    /// The filter new pages get (`IOSShell.drawerFilter`, `settingDrawerFilter`).
    private var filter: Binding<CaptureFilter> {
        let appState: AppState = state
        return Binding<CaptureFilter>(
            get: { IOSShell.drawerFilter(appState.settings) },
            set: { (choice: CaptureFilter) in
                appState.settings = IOSShell.settingDrawerFilter(choice, in: appState.settings)
            })
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

/// A capsule in the drawer: on in the accent colour, off grey; `isOn` nil for one that only opens
/// something.
private struct DrawerChip: View {
    @Environment(\.isEnabled) private var isEnabled: Bool
    let title: String
    let isOn: Bool?
    let action: () -> Void

    var body: some View {
        let on: Bool = isOn ?? false
        let value: String = isOn == nil ? "" : (on ? IOSCameraText.onValue : IOSCameraText.offValue)
        Button(action: action) {
            Text(title)
                .font(.footnote.weight(on ? .semibold : .medium))
                .foregroundStyle(on ? Color.white : Color.primary)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(minHeight: 30)
                .background(Capsule().fill(on ? Color.accentColor : Color(uiColor: .tertiarySystemFill)))
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityValue(Text(value))
        .accessibilityAddTraits(on ? AccessibilityTraits.isSelected : [])
    }
}
#endif
