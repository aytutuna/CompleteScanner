import Foundation

/// A task card on the start screen: the task, whether the connected scanner can do it, and
/// what it sets. Twin of the Windows `TaskCardItem`.
public struct TaskCard: Identifiable, Equatable {
    public let definition: TaskDefinition
    public let availability: TaskAvailability
    /// The task the current settings are set up for.
    public let isCurrent: Bool
    /// What the task sets on the connected scanner, e.g. "300 dpi · Color · PDF".
    public let summary: String

    public var id: ScanTask { definition.task }
}

/// Tasks picked on the start screen (`UI/TaskStartView.swift`) and their guided steps (the
/// banner, `UI/TaskBannerView.swift`). The task itself is `settings.taskId`, so it is saved
/// with the settings and comes back after a restart; `settings`' didSet ends a task the
/// settings no longer fit. Port of the task members of the Windows `AppViewModel`.
extension AppState {
    /// The task the settings are set up for; nil for settings chosen by hand.
    public var activeTask: ScanTask? { settings.task }

    public var activeTaskDefinition: TaskDefinition? { activeTask.map { TaskCatalog.definition($0) } }

    /// Caption of the Scan button: the current step's action ("Scan page"), or "Scan".
    public var primaryActionLabel: String { taskFlow?.current?.primaryActionLabel ?? "Scan" }

    /// The start screen's task cards, with what the connected scanner can do.
    public var taskCards: [TaskCard] {
        TaskCatalog.all.map { definition in
            let settings = SettingsAdapter.adapt(TaskCatalog.apply(definition.task, to: ScanSettings()),
                                                 to: capabilities).settings
            return TaskCard(definition: definition,
                            availability: TaskCatalog.availability(of: definition.task, capabilities: capabilities),
                            isCurrent: activeTask == definition.task,
                            summary: TaskCatalog.summary(settings))
        }
    }

    /// Sets everything up for a task picked on the start screen: its settings are laid over the
    /// current ones (the destination folder is kept) and fitted to the connected scanner, and
    /// its guided steps start. Refused (false) while an operation runs, or when the connected
    /// scanner cannot do the task (the reason is shown).
    @discardableResult
    public func startTask(_ task: ScanTask) -> Bool {
        guard !isBusy else { return false }
        let availability = TaskCatalog.availability(of: task, capabilities: capabilities)
        guard availability.isAvailable else {
            errorMessage = availability.reason
            return false
        }
        let adapted = SettingsAdapter.adapt(TaskCatalog.apply(task, to: settings), to: capabilities)
        // Fresh steps, even when the same task is picked again.
        taskFlow = nil
        flowTask = nil
        settings = adapted.settings
        statusMessage = Self.withNotes("Ready for \u{201C}\(TaskCatalog.definition(task).title)\u{201D}.",
                                       adapted.notes)
        return true
    }

    /// Leaves the active task: the settings stay as they are, without the task's banner, so the
    /// scan screen is back to plain settings.
    public func exitTask() {
        guard settings.taskId != nil else { return }
        settings.taskId = nil
    }

    /// Keeps the steps in line with the task: an active task without steps gets them, and steps
    /// go when the task does. A task id this version does not know stays stored, without steps.
    func syncTaskFlow() {
        guard let active = settings.task else {
            if taskFlow != nil { taskFlow = nil }
            flowTask = nil
            return
        }
        if taskFlow == nil || flowTask != active {
            taskFlow = TaskFlow(steps: TaskCatalog.definition(active).steps)
            flowTask = active
        }
    }

    /// Notes the current step of the active task what a scan produced (page or photo ids).
    func recordCaptures(_ ids: [UUID]) {
        guard let step = taskFlow?.current else { return }
        for id in ids {
            taskFlow?.record(stepID: step.id, captureID: id)
        }
    }

    static func withNotes(_ message: String, _ notes: [SettingsNote]) -> String {
        notes.isEmpty ? message : ([message] + notes.map(\.message)).joined(separator: " ")
    }
}
