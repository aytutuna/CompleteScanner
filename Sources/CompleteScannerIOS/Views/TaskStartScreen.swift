#if os(iOS)
import CompleteScannerKit
import SwiftUI

/// The start screen: what are you scanning? The user's presets first (when there are any, as on the
/// Mac), then one tile per task (`TaskCatalog.sections`) in its group: an icon, the title and the
/// one-line subtitle. A task that cannot be started (no feeder, or not in this version yet,
/// `IOSShell.availability`) is dimmed with one short line saying why. Picking a tile sets the task (or
/// the preset's settings) up and opens the scan screen (`onOpenScanner`); not while an import runs, whose
/// pages belong to the task set up. With a side of an ID card held, either kind of tile asks to discard the
/// card first (`IdCardDiscardQuestion`). Settings (Command-comma) where the sidebar does not offer it.
struct TaskStartScreen: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var importer: IOSImportSession

    /// Opens the scan screen (after a tile was set up, or for the Scanner button).
    let onOpenScanner: @MainActor () -> Void
    /// Opens Settings; nil when the sidebar has it (iPad).
    var onOpenSettings: (() -> Void)?
    @State private var askedToDiscard: Bool = false

    private let columns: [GridItem] = [GridItem(.adaptive(minimum: 150, maximum: 280), spacing: 12, alignment: .top)]

    var body: some View {
        let groups: [IOSTaskGroup] = IOSShell.groups(state.taskCards)
        let presets: [IOSPresetRow] = IOSPresetsModel.rows(state.presets)
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if !presets.isEmpty {
                    Text(IOSPresetText.groupTitle)
                        .font(.headline)
                        .padding(.top, 8)
                        .accessibilityAddTraits(.isHeader)
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                        ForEach(presets) { (row: IOSPresetRow) in
                            presetButton(row)
                        }
                    }
                }
                ForEach(groups) { (group: IOSTaskGroup) in
                    Text(group.title)
                        .font(.headline)
                        .padding(.top, 8)
                        .accessibilityAddTraits(.isHeader)
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                        ForEach(group.tiles) { (tile: IOSTaskTile) in
                            tileButton(tile)
                        }
                    }
                }
            }
            .padding(16)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("What are you scanning?")
        .modifier(IdCardDiscardQuestion(state: state, asked: $askedToDiscard))
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if let open = onOpenSettings {
                    Button {
                        open()
                    } label: {
                        Label(IOSSettingsText.title, systemImage: "gearshape")
                    }
                    .keyboardShortcut(IOSShortcuts.settings.keyboardShortcut)
                    .accessibilityIdentifier("open.settings")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    onOpenScanner()
                } label: {
                    Label("Scanner", systemImage: "scanner")
                }
                .accessibilityIdentifier("open.scanner")
            }
        }
    }

    private func tileButton(_ tile: IOSTaskTile) -> some View {
        let available: Bool = tile.availability.isAvailable
        let reason: String = tile.availability.reason ?? ""
        let hint: String = available ? "\(tile.subtitle) \(tile.summary)." : "\(tile.subtitle) Not available: \(reason)"
        return Button {
            pick(tile.task)
        } label: {
            TaskTileLabel(tile: tile)
        }
        .buttonStyle(TaskTileButtonStyle())
        .disabled(!available || state.isBusy || importer.isImporting)
        .accessibilityLabel(Text(tile.title))
        .accessibilityValue(Text(tile.accessibilityValue))
        .accessibilityHint(Text(hint))
        .accessibilityIdentifier("task.\(tile.task.rawValue)")
    }

    /// Picking a task ends the ID card task, so with a side of the card held it asks first, as a preset does.
    private func pick(_ task: ScanTask) {
        let appState: AppState = state
        let open: @MainActor () -> Void = onOpenScanner
        state.leaveIdCard {
            if appState.startTask(task) {
                open()
            }
        }
        if state.pendingIdCardLeave != nil {
            askedToDiscard = true
        }
    }

    /// A preset's tile: its task's icon and its name, the task and settings for VoiceOver.
    private func presetButton(_ row: IOSPresetRow) -> some View {
        let id: UUID = row.id
        return Button {
            applyPreset(id)
        } label: {
            PresetTileLabel(row: row)
        }
        .buttonStyle(TaskTileButtonStyle())
        .disabled(state.isBusy || importer.isImporting)
        .accessibilityLabel(Text(row.accessibilityLabel))
        .accessibilityHint(Text(row.accessibilityHint))
        .accessibilityIdentifier("start.preset.\(row.name)")
    }

    private func applyPreset(_ id: UUID) {
        let model: IOSPresetsModel = IOSPresetsModel(state: state, importer: importer)
        if model.apply(id, then: onOpenScanner) == IOSPresetApply.waitsForDiscard {
            askedToDiscard = true
        }
    }
}

/// The inside of a preset's tile: its task's icon, its name, and the task it brings back.
private struct PresetTileLabel: View {
    let row: IOSPresetRow

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: row.symbol)
                .font(.system(size: 22))
                .foregroundStyle(Color.accentColor)
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)
            Text(row.name)
                .font(.headline)
                .foregroundStyle(Color.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Text(row.taskTitle)
                .font(.caption)
                .foregroundStyle(Color.secondary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .multilineTextAlignment(.leading)
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 116, alignment: .topLeading)
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }
}

/// The inside of a tile: the icon (with "Current" for the task set up now), the title, the subtitle,
/// and for a task that cannot be started, why.
private struct TaskTileLabel: View {
    let tile: IOSTaskTile

    var body: some View {
        let available: Bool = tile.availability.isAvailable
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Image(systemName: tile.symbol)
                    .font(.system(size: 22))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 32, height: 32)
                    .opacity(available ? 1 : 0.4)
                    .accessibilityHidden(true)
                Spacer(minLength: 4)
                if tile.isCurrent {
                    Text("Current")
                        .font(.caption)
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.accentColor))
                }
            }
            Text(tile.title)
                .font(.headline)
                .foregroundStyle(available ? Color.primary : Color.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Text(available ? tile.subtitle : (tile.availability.reason ?? ""))
                .font(.caption)
                .foregroundStyle(Color.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .multilineTextAlignment(.leading)
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 116, alignment: .topLeading)
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }
}

/// A whole-tile button: card surface, hairline border, pressed feedback.
private struct TaskTileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(uiColor: .secondarySystemGroupedBackground)))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.secondary.opacity(configuration.isPressed ? 0.5 : 0.2), lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
    }
}
#endif
