#if os(iOS)
import CompleteScannerKit
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
/// one cannot be started, the kind set up marked), the scanners, one of which picked is printer mode's
/// (`ScannerPickerSections`, with Add by address and Troubleshoot), and the library: Presets, Scans, Saved files and Settings
/// (Command-comma). A kind or a preset picked while a side of an ID card is held asks to discard the card
/// first (`IdCardDiscardQuestion`).
struct IOSSidebar: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var importer: IOSImportSession
    let picker: IOSScannerPickerModel
    /// The scan screen is the detail now.
    let scannerShown: Bool
    let detail: IOSDetail
    /// Starts a task, with the PDF its pages are added to when one was picked.
    let onTask: (ScanTask, URL?) -> Void
    let onPresetApplied: @MainActor () -> Void
    let onDetail: (IOSDetail) -> Void
    let onSettings: () -> Void
    @State private var showsAdd: Bool = false
    @State private var showsTroubleshooter: Bool = false
    @State private var askedToDiscard: Bool = false
    @State private var picksPDF: Bool = false

    var body: some View {
        let tiles: [IOSKindTile] = IOSShell.kindTiles(state.taskCards, current: IOSShell.shownKind(state.settings))
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
                                  header: IOSNetworkText.pickerTitle)
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
        .modifier(ScannerPickerSheets(picker: picker, showsAdd: $showsAdd, showsTroubleshooter: $showsTroubleshooter))
        .modifier(IdCardDiscardQuestion(state: state, asked: $askedToDiscard))
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
        let available: Bool = tile.availability.isAvailable
        let current: Bool = tile.isCurrent && scannerShown
        return Button {
            pick(kind.task)
        } label: {
            HStack(spacing: 10) {
                Label(kind.title, systemImage: kind.symbol)
                    .foregroundStyle(available ? Color.primary : Color.secondary)
                Spacer(minLength: 4)
                if current {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                }
            }
        }
        .disabled(!available || state.isBusy || importer.isImporting)
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
        .disabled(!available || state.isBusy || importer.isImporting)
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
        .disabled(state.isBusy || importer.isImporting)
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

    /// Picking a task ends the ID card task, so with a side of the card held it asks first, as a preset does.
    private func pick(_ task: ScanTask, target: URL? = nil) {
        let start: (ScanTask, URL?) -> Void = onTask
        state.leaveIdCard {
            start(task, target)
        }
        if state.pendingIdCardLeave != nil {
            askedToDiscard = true
        }
    }

    private func apply(_ id: UUID) {
        let model: IOSPresetsModel = IOSPresetsModel(state: state, importer: importer)
        if model.apply(id, then: onPresetApplied) == IOSPresetApply.waitsForDiscard {
            askedToDiscard = true
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
