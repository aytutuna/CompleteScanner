#if os(iOS)
import LazyScanKit
import SwiftUI
import UniformTypeIdentifiers

/// What the iPad's detail column shows beside the sidebar when the scan screen is not up.
enum IOSDetail: Hashable {
    case start
    case presets
    case history
    case saved
}

/// The iPad's sidebar (a regular width, `IOSLayout.usesSidebar`): the user's presets, the kinds and "Add
/// pages to a PDF" as the task list has them (`IOSShell.kindTiles`: dimmed with the reason when
/// one cannot be started, the kind set up marked; in camera mode only camera mode's, `IOSShell.cameraKinds`,
/// named as the camera row names them), the scanners, one of which picked is printer mode's
/// (`ScannerPickerSections`, with Add by address and Troubleshoot), and the library: Presets, Scans, Saved files and Settings
/// (Command-comma). A kind picked goes to the root view (`onTask`), which asks about the pages and an ID card
/// held; a preset picked while a side of an ID card is held asks to discard the card first
/// (`IdCardDiscardQuestion`), and one that would leave the queued pages without a Save asks about them
/// (`KeepPagesQuestion`). The rows do nothing while an import runs or while a share or a send reads the
/// queue (`AppState.readsQueue`), when a pick would only be refused.
struct IOSSidebar: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var importer: IOSImportSession
    let picker: IOSScannerPickerModel
    /// The scan screen is the detail now.
    let scannerShown: Bool
    let detail: IOSDetail
    /// Starts a task, with the PDF its pages are added to when one was picked.
    let onTask: @MainActor (ScanTask, URL?) -> Void
    /// Brings the scan screen back: a preset applied, or a scanner picked or added.
    let onPresetApplied: @MainActor () -> Void
    let onDetail: (IOSDetail) -> Void
    let onSettings: () -> Void
    @State private var showsAdd: Bool = false
    @State private var showsTroubleshooter: Bool = false
    @State private var askedToDiscard: Bool = false
    /// A preset that would leave the queued pages without a Save, while the question about them is up.
    @State private var leavingPages: PagesLeave?
    @State private var picksPDF: Bool = false
    @AppStorage(IOSShell.scanModeKey) private var mode: IOSScanMode = .camera

    var body: some View {
        let kinds: [IOSScanKind] = mode == .camera ? IOSShell.cameraKinds : IOSScanKind.allCases
        let tiles: [IOSKindTile] = IOSShell.kindTiles(state.taskCards, current: IOSShell.shownKind(state.settings),
                                                      order: kinds)
        let presets: [IOSPresetRow] = IOSPresetsModel.rows(state.presets)
        List {
            if !presets.isEmpty {
                Section(IOSPresetText.groupTitle) {
                    ForEach(presets) { (row: IOSPresetRow) in
                        presetRow(row)
                    }
                }
            }
            Section("Scan") {
                ForEach(tiles) { (tile: IOSKindTile) in
                    kindRow(tile)
                }
                appendRow(IOSAppendTile.availability(state.taskCards))
            }
            ScannerPickerSections(picker: picker, onAdd: openAdd, onTroubleshoot: openTroubleshooter,
                                  asksAboutCard: $askedToDiscard, header: IOSNetworkText.pickerTitle,
                                  onPicked: onPresetApplied)
            Section {
                libraryRow(IOSSettingsText.presetsLabel, symbol: "slider.horizontal.3", target: IOSDetail.presets,
                           identifier: "sidebar.presets")
                libraryRow(IOSSettingsText.historyLabel, symbol: "clock.arrow.circlepath", target: IOSDetail.history,
                           identifier: "sidebar.history")
                libraryRow(IOSSettingsText.savedLabel, symbol: "tray", target: IOSDetail.saved,
                           identifier: "sidebar.saved")
                Button {
                    onSettings()
                } label: {
                    Label(IOSSettingsText.title, systemImage: "gearshape")
                }
                .keyboardShortcut(IOSShortcuts.settings.keyboardShortcut)
                .accessibilityIdentifier("open.settings")
            }
        }
        .listStyle(.sidebar)
        .accessibilityIdentifier("scanners.sidebar")
        .modifier(ScannerPickerSheets(picker: picker, showsAdd: $showsAdd, showsTroubleshooter: $showsTroubleshooter,
                                      asksAboutCard: $askedToDiscard, onPicked: onPresetApplied))
        .modifier(IdCardDiscardQuestion(state: state, asked: $askedToDiscard))
        .modifier(KeepPagesQuestion(state: state, leave: $leavingPages, blocked: importer.isImporting))
        .fileImporter(isPresented: $picksPDF, allowedContentTypes: [UTType.pdf]) { (result: Result<URL, Error>) in
            switch result {
            case .success(let url):
                pick(.document, target: url)
            case .failure(let error):
                state.errorMessage = error.localizedDescription
            }
        }
    }

    private func kindRow(_ tile: IOSKindTile) -> some View {
        let kind: IOSScanKind = tile.kind
        let title: String = mode == .camera ? kind.cameraTitle : kind.title
        let available: Bool = tile.availability.isAvailable
        let current: Bool = tile.isCurrent && scannerShown
        return Button {
            pick(kind.task)
        } label: {
            HStack(spacing: 10) {
                Label(title, systemImage: kind.symbol)
                    .foregroundStyle(available ? Color.primary : Color.secondary)
                Spacer(minLength: 4)
                if current {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                }
            }
        }
        .disabled(!available || state.isBusy || importer.isImporting || state.readsQueue)
        .accessibilityValue(Text(tile.accessibilityValue))
        .accessibilityHint(Text(available ? kind.subtitle : "Not available: \(tile.availability.reason ?? "")"))
        .accessibilityAddTraits(current ? AccessibilityTraits.isSelected : [])
        .accessibilityIdentifier("sidebar.task.\(kind.rawValue)")
    }

    private func appendRow(_ availability: TaskAvailability) -> some View {
        let available: Bool = availability.isAvailable
        return Button {
            picksPDF = true
        } label: {
            Label(IOSAppendTile.title, systemImage: IOSAppendTile.symbol)
                .foregroundStyle(available ? Color.primary : Color.secondary)
        }
        .disabled(!available || state.isBusy || importer.isImporting || state.readsQueue)
        .accessibilityHint(Text(available ? IOSAppendTile.subtitle : "Not available: \(availability.reason ?? "")"))
        .accessibilityIdentifier("sidebar.task.appendToPDF")
    }

    private func presetRow(_ row: IOSPresetRow) -> some View {
        let id: UUID = row.id
        return Button {
            apply(id)
        } label: {
            Label(row.name, systemImage: row.symbol)
                .foregroundStyle(Color.primary)
        }
        .disabled(state.isBusy || importer.isImporting || state.readsQueue)
        .accessibilityLabel(Text(row.accessibilityLabel))
        .accessibilityHint(Text(row.accessibilityHint))
    }

    private func libraryRow(_ title: String, symbol: String, target: IOSDetail, identifier: String) -> some View {
        let selected: Bool = !scannerShown && detail == target
        return Button {
            onDetail(target)
        } label: {
            HStack {
                Label(title, systemImage: symbol)
                    .foregroundStyle(Color.primary)
                Spacer(minLength: 4)
                if selected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                }
            }
        }
        .accessibilityAddTraits(selected ? AccessibilityTraits.isSelected : [])
        .accessibilityIdentifier(identifier)
    }

    private func pick(_ task: ScanTask, target: URL? = nil) {
        onTask(task, target)
    }

    private func apply(_ id: UUID, discardingPages: Bool = false) {
        let model: IOSPresetsModel = IOSPresetsModel(state: state, importer: importer)
        switch model.apply(id, discardingPages: discardingPages, then: onPresetApplied) {
        case .waitsForDiscard:
            askedToDiscard = true
        case .waitsForPages(let name):
            leavingPages = PagesLeave(reason: IOSShell.keepPagesReason(preset: name)) { (discarding: Bool) in
                apply(id, discardingPages: discarding)
            }
        case .applied, .refused:
            break
        }
    }

    private func openAdd() {
        showsAdd = true
    }

    private func openTroubleshooter() {
        showsTroubleshooter = true
    }
}
#endif
