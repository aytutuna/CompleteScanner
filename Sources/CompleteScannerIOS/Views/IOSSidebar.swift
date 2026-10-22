#if os(iOS)
import CompleteScannerKit
import SwiftUI

/// What the iPad's detail column shows beside the sidebar when the scan screen is not up.
enum IOSDetail: Hashable {
    case start
    case presets
    case history
    case saved
}

/// The iPad's sidebar (a regular width, `IOSLayout.usesSidebar`): the tasks in their groups (as the start
/// screen's tiles: dimmed with the reason when one cannot be started, the one set up marked), the user's
/// presets, the scanners to pick from (`ScannerPickerSections`, with Add by address and Troubleshoot), and
/// the library: Presets, Scans, Saved files and Settings (Command-comma). A task or a preset picked while a
/// side of an ID card is held asks to discard the card first (`IdCardDiscardQuestion`).
struct IOSSidebar: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var importer: IOSImportSession
    let picker: IOSScannerPickerModel
    /// The scan screen is the detail now.
    let scannerShown: Bool
    let detail: IOSDetail
    let onTask: (ScanTask) -> Void
    let onPresetApplied: @MainActor () -> Void
    let onDetail: (IOSDetail) -> Void
    let onSettings: () -> Void
    @State private var showsAdd: Bool = false
    @State private var showsTroubleshooter: Bool = false
    @State private var askedToDiscard: Bool = false

    var body: some View {
        let groups: [IOSTaskGroup] = IOSShell.groups(state.taskCards)
        let presets: [IOSPresetRow] = IOSPresetsModel.rows(state.presets)
        List {
            ForEach(groups) { (group: IOSTaskGroup) in
                Section(group.title) {
                    ForEach(group.tiles) { (tile: IOSTaskTile) in
                        taskRow(tile)
                    }
                }
            }
            if !presets.isEmpty {
                Section(IOSPresetText.groupTitle) {
                    ForEach(presets) { (row: IOSPresetRow) in
                        presetRow(row)
                    }
                }
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
    }

    private func taskRow(_ tile: IOSTaskTile) -> some View {
        let available: Bool = tile.availability.isAvailable
        let current: Bool = tile.isCurrent && scannerShown
        let task: ScanTask = tile.task
        return Button {
            pick(task)
        } label: {
            HStack(spacing: 10) {
                Label(tile.title, systemImage: tile.symbol)
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
        .accessibilityHint(Text(available ? tile.subtitle : "Not available: \(tile.availability.reason ?? "")"))
        .accessibilityAddTraits(current ? AccessibilityTraits.isSelected : [])
        .accessibilityIdentifier("sidebar.task.\(task.rawValue)")
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
    private func pick(_ task: ScanTask) {
        let start: (ScanTask) -> Void = onTask
        state.leaveIdCard {
            start(task)
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
