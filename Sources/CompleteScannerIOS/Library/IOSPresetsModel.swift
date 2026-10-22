#if os(iOS)
import CompleteScannerKit
import Foundation

/// The presets screen's words.
public enum IOSPresetText {
    public static let title = "Presets"
    public static let groupTitle = "My presets"
    public static let saveLabel = "Save preset"
    public static let saveTitle = "Save preset"
    public static let saveLine = "Saves the current settings to use again."
    public static let namePlaceholder = "Preset name"
    public static let renameLabel = "Rename"
    public static let renameTitle = "Rename preset"
    public static let deleteLabel = "Delete"
    public static let emptyTitle = "No presets"
    public static let emptyLine = "Save your settings to use them again."
    public static let discardTitle = "Discard the ID card?"
    public static let discardLine = "The ID card has not been saved. Its sides will be discarded."
    public static let discardLabel = "Discard"
}

/// A preset as the list shows it: its name, the task it brings back with that task's icon, and the
/// settings' one-line summary (`TaskCatalog.summary`), as the Mac's preset tiles show them.
public struct IOSPresetRow: Identifiable, Equatable {
    public let id: UUID
    public let name: String
    public let taskTitle: String
    public let summary: String
    public let symbol: String

    public init(preset: Preset) {
        let task: ScanTask = TaskCatalog.infer(preset.settings)
        let definition: TaskDefinition = TaskCatalog.definition(task)
        self.id = preset.id
        self.name = preset.name
        self.taskTitle = definition.title
        self.summary = TaskCatalog.summary(preset.settings)
        self.symbol = IOSShell.systemImage(definition.iconKey)
    }

    /// "Invoices preset", as VoiceOver reads the row.
    public var accessibilityLabel: String { "\(name) preset" }
    /// "Preset for Document to PDF. 300 dpi · Color · PDF."
    public var accessibilityHint: String { "Preset for \(taskTitle). \(summary)." }
}

/// What applying a preset came to.
public enum IOSPresetApply: Equatable, Sendable {
    /// The preset's settings are in use.
    case applied
    /// An ID card side is held and not saved: the preset waits until the user discards it
    /// (`AppState.pendingIdCardLeave`).
    case waitsForDiscard
    /// Nothing happened: an operation or an import runs, or the preset is gone.
    case refused
}

/// The presets screen without a screen: the presets as rows, saving the current settings as one,
/// renaming, deleting and applying one, all through `AppState` and its `PresetStore` (presets.json).
/// There are no built-in presets: a first run starts with none.
@MainActor
public final class IOSPresetsModel {
    private let state: AppState
    private let importer: IOSImportSession

    /// `importer`: while it imports, no preset is applied (its pages belong to the task it started in).
    public init(state: AppState, importer: IOSImportSession) {
        self.state = state
        self.importer = importer
    }

    public var rows: [IOSPresetRow] { IOSPresetsModel.rows(state.presets) }

    public static func rows(_ presets: [Preset]) -> [IOSPresetRow] {
        var rows: [IOSPresetRow] = []
        for preset in presets {
            rows.append(IOSPresetRow(preset: preset))
        }
        return rows
    }

    /// A name a preset can be saved or renamed with: anything but blank.
    public static func isValidName(_ name: String) -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The current settings saved as a preset named `name` (trimmed); false for a blank name.
    @discardableResult
    public func save(named name: String) -> Bool {
        guard IOSPresetsModel.isValidName(name) else { return false }
        state.saveCurrentAsPreset(named: name)
        return true
    }

    @discardableResult
    public func rename(_ id: UUID, to name: String) -> Bool {
        state.renamePreset(id: id, to: name)
    }

    public func delete(_ id: UUID) {
        state.deletePreset(id: id)
    }

    /// The preset's settings put in use, fitted to the scanner (`AppState.applyPreset`), and a PDF picked
    /// to add the pages to forgotten, then `done` runs; with an ID card side held, both wait until the user discards the card. Refused while an
    /// operation or an import runs.
    @discardableResult
    public func apply(_ id: UUID, then done: @escaping @MainActor () -> Void) -> IOSPresetApply {
        guard !state.isBusy, !importer.isImporting else { return .refused }
        guard let preset = state.presets.first(where: { (item: Preset) -> Bool in item.id == id }) else {
            return .refused
        }
        let held: Bool = state.hasIdCardCaptures
        let appState: AppState = state
        state.leaveIdCard {
            appState.applyPreset(preset)
            appState.clearAppendTarget()
            done()
        }
        return held ? .waitsForDiscard : .applied
    }
}
#endif
