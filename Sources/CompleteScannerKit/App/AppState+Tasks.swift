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

    /// The steps guide turning a stack over by hand: fronts, then backs.
    public var isTurningOverByHand: Bool { taskFlow != nil && flowIsManual }

    /// Turning over by hand, the backs are next (or were scanned and did not pair up).
    public var awaitingBacks: Bool { isTurningOverByHand && taskFlow?.current?.id == DocumentSides.backsStepID }

    /// Turning over by hand, fronts are in the queue but the stack was not turned over yet (the
    /// feeder stopped early, or more fronts were asked for): `finishFronts()` moves on to the backs.
    public var canFinishFronts: Bool {
        isTurningOverByHand && taskFlow?.current?.id == DocumentSides.frontsStepID
            && queuedCaptures(DocumentSides.frontsStepID) > 0
    }

    /// The backs are due but none was scanned yet: `scanMoreFronts()` goes back to the fronts, for
    /// a stack larger than the feeder holds.
    public var canScanMoreFronts: Bool { awaitingBacks && queuedCaptures(DocumentSides.backsStepID) == 0 }

    /// How the next scan captures the sheets (one side, both, or turned over by hand).
    public var effectiveDuplex: DuplexMode { DocumentSides.effective(settings, capabilities: sidesCapabilities) }

    /// The start screen's task cards, with what the connected scanner (and, for Copy, the printers) can do.
    public var taskCards: [TaskCard] {
        TaskCatalog.all.map { definition in
            let settings = SettingsAdapter.adapt(TaskCatalog.apply(definition.task, to: ScanSettings()),
                                                 to: sidesCapabilities).settings
            return TaskCard(definition: definition,
                            availability: TaskCatalog.availability(of: definition.task, capabilities: capabilities,
                                                                   hasPrinter: hasPrinter),
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
        // Printers come and go: the Copy task reads them again.
        if task == .copy { refreshPrinters() }
        let availability = TaskCatalog.availability(of: task, capabilities: capabilities, hasPrinter: hasPrinter)
        guard availability.isAvailable else {
            errorMessage = TaskCatalog.unavailableMessage(task, reason: availability.reason ?? "")
            return false
        }
        // A feeder not asked yet whether it scans both sides is taken to (`sidesCapabilities`); the
        // check that follows the change of source switches to turning over by hand if it does not.
        let adapted = SettingsAdapter.adapt(TaskCatalog.apply(task, to: settings), to: sidesCapabilities)
        // Fresh steps, even when the same task is picked again: nothing of an ID card is kept, on
        // the stage either.
        if isIdCardFlow || hasIdCardCaptures || showIdCardReview { clearIdCard(clearCanvas: true) }
        taskFlow = nil
        flowTask = nil
        flowIsManual = false
        if newDocumentPending { newDocumentPending = false }
        settings = adapted.settings
        if let section = InspectorSections.openedBy(task) { sectionsOpenedByTask.insert(section) }
        statusMessage = Self.withNotes("Ready for \u{201C}\(TaskCatalog.definition(task).title)\u{201D}.",
                                       adapted.notes)
        return true
    }

    /// Leaves the active task: the settings stay as they are, without the task's banner, so the
    /// scan screen is back to plain settings. Refused while an operation runs: a scan under way
    /// belongs to the task's steps.
    public func exitTask() {
        guard !isBusy, settings.taskId != nil else { return }
        settings.taskId = nil
    }

    /// Keeps the guided steps in line with the settings: turning stacks over by hand gets its
    /// own steps (`TaskCatalog.guidedSteps`), whatever the task; an active task gets its steps;
    /// steps go when there is nothing to guide. A task id this version does not know stays
    /// stored, without steps. Steps already under way are kept while they still apply.
    func syncTaskFlow() {
        let wasIdCard = isIdCardFlow
        let caps = sidesCapabilities
        let manual = DocumentSides.usesManualSteps(settings, capabilities: caps)
        let task: ScanTask? = manual ? nil : settings.task
        guard let steps = TaskCatalog.guidedSteps(settings, capabilities: caps) else {
            if taskFlow != nil { taskFlow = nil }
            flowTask = nil
            flowIsManual = false
            if sidesMismatch != nil { sidesMismatch = nil }
            // No steps: the sides of an ID card scanned before go, and the stage no longer shows the
            // card (also a scan whose card was not found, or a preview of the glass).
            if wasIdCard || hasIdCardCaptures || showIdCardReview { clearIdCard(clearCanvas: true) }
            return
        }
        if taskFlow == nil || flowTask != task || flowIsManual != manual {
            taskFlow = TaskFlow(steps: steps)
            flowTask = task
            flowIsManual = manual
            if sidesMismatch != nil { sidesMismatch = nil }
            // Steps started afresh: the same.
            if wasIdCard || hasIdCardCaptures || showIdCardReview { clearIdCard(clearCanvas: true) }
        }
    }

    /// The banner's skip button is offered: the back of an ID card (`IdCardSteps.offersSkip`).
    public var canSkipStep: Bool { isIdCardFlow && IdCardSteps.offersSkip(taskFlow?.current) }

    /// Leaves out the back of an ID card with nothing on it (`canSkipStep`), after which the card's
    /// review opens. The backs of a stack turned over by hand are not skipped here: Keep Fronts Only
    /// (`keepFrontsOnly`) leaves them out. Twin of the Windows `AppViewModel.SkipStep`.
    public func skipStep() {
        guard !isBusy, canSkipStep else { return }
        taskFlow?.skip()
        setIdCardSide(.back, photo: nil, note: nil)
        statusMessage = "No back side. Check the front, then save."
        openIdCardReview()
    }

    /// Back to the first step with nothing captured; a stack's count mismatch goes with it, and so do the
    /// camera's two-sided steps and a pending New document.
    func resetFlow() {
        taskFlow?.reset()
        if sidesMismatch != nil { sidesMismatch = nil }
        if var sides = cameraSides {
            sides.reset()
            cameraSides = sides
        }
        if newDocumentPending { newDocumentPending = false }
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
