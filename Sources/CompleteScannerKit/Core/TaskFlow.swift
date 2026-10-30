import Foundation

/// One step of a guided task, as the banner on the scan screen shows it. Twin of C# `TaskStep`
/// (`windows/LazyScan.Core/TaskFlow.cs`).
public struct TaskStep: Equatable, Sendable {
    /// Stable within its task, for example "scan", "front" or "back".
    public let id: String
    /// Short name of the step ("Scan each page").
    public let title: String
    /// What to do, in one short line (ten words at most): the banner shows it.
    public let prompt: String
    /// Caption of the button that performs the step ("Scan page").
    public let primaryActionLabel: String
    /// The step may be left out (the back of a one-sided card).
    public let skippable: Bool
    /// The step takes any number of captures (pages of a document) instead of one.
    public let repeats: Bool
    /// The task cannot be finished before this step has a capture.
    public let requiresCapture: Bool
    /// The fuller guidance behind the banner's info button, read out with the prompt by VoiceOver;
    /// empty when the prompt says it all.
    public let help: String

    public init(id: String, title: String, prompt: String, primaryActionLabel: String,
                skippable: Bool = false, repeats: Bool = false, requiresCapture: Bool = true,
                help: String = "") {
        self.id = id
        self.title = title
        self.prompt = prompt
        self.primaryActionLabel = primaryActionLabel
        self.skippable = skippable
        self.repeats = repeats
        self.requiresCapture = requiresCapture
        self.help = help
    }

    /// The step in one word, for a step indicator ("Front · Back · Check"): the title's first word
    /// after a leading "Scan the" or "Scan", capitalized ("Scan the front sides" is "Front").
    public var word: String {
        var text: String = title.trimmingCharacters(in: .whitespaces)
        for lead in ["Scan the ", "Scan "] {
            if text.hasPrefix(lead) && text.count > lead.count {
                text = String(text.dropFirst(lead.count))
                break
            }
        }
        let parts: [Substring] = text.split(separator: " ", omittingEmptySubsequences: true)
        let first: String = parts.first.map { String($0) } ?? text
        guard let initial: Character = first.first else { return first }
        return String(initial).uppercased() + String(first.dropFirst())
    }

    /// The prompt and the help as one text, for VoiceOver.
    public var fullPrompt: String {
        help.isEmpty ? prompt : prompt + " " + help
    }
}

/// Where the user is in a guided task: the current step, what each step has captured, and
/// which steps were skipped. A pure state machine; the app records captures (page or photo
/// ids) and asks it what to show. Unknown step ids are ignored. Twin of C# `TaskFlow`.
public struct TaskFlow: Equatable, Sendable {
    public let steps: [TaskStep]
    /// Index of `current`; equals `stepCount` once every step is done.
    public private(set) var stepIndex: Int = 0
    private var capturesByStep: [String: [UUID]] = [:]
    private var skippedSteps: Set<String> = []

    public init(steps: [TaskStep]) {
        self.steps = steps
    }

    public var stepCount: Int { steps.count }

    /// The step to show; nil once the flow is complete.
    public var current: TaskStep? { stepIndex < steps.count ? steps[stepIndex] : nil }

    /// Every step was advanced past or skipped.
    public var isComplete: Bool { stepIndex >= steps.count }

    /// Every step that requires a capture has one, so the result can be saved.
    public var canFinish: Bool {
        steps.allSatisfy { step in !step.requiresCapture || !captures(for: step.id).isEmpty }
    }

    /// The captures of a step, oldest first (empty for an unknown step).
    public func captures(for stepID: String) -> [UUID] {
        capturesByStep[stepID] ?? []
    }

    public func isSkipped(_ stepID: String) -> Bool {
        skippedSteps.contains(stepID)
    }

    /// Records a capture for a step. A repeating step keeps every capture; any other step keeps
    /// only the newest. Returns the captures it replaced, for the caller to discard. A skipped
    /// step counts as not skipped again. The current step does not change.
    @discardableResult
    public mutating func record(stepID: String, captureID: UUID) -> [UUID] {
        guard let index = indexOf(stepID) else { return [] }
        let step = steps[index]
        var list = capturesByStep[stepID] ?? []
        let replaced: [UUID] = step.repeats ? [] : list
        if !step.repeats { list.removeAll() }
        list.append(captureID)
        capturesByStep[stepID] = list
        skippedSteps.remove(stepID)
        return replaced
    }

    /// Moves to the next step. Refused (false) when the flow is complete, or when the current
    /// step requires a capture and has none.
    @discardableResult
    public mutating func advance() -> Bool {
        guard let step = current else { return false }
        if step.requiresCapture && captures(for: step.id).isEmpty { return false }
        stepIndex += 1
        return true
    }

    /// Leaves out the current step: its captures are dropped and the flow moves on. Refused
    /// (false) when the flow is complete or the current step is not skippable.
    @discardableResult
    public mutating func skip() -> Bool {
        guard let step = current, step.skippable else { return false }
        capturesByStep[step.id] = nil
        skippedSteps.insert(step.id)
        stepIndex += 1
        return true
    }

    /// Goes back to a step to capture it again: its captures are dropped (and returned, for
    /// the caller to discard) and it becomes the current step. Later steps keep theirs.
    @discardableResult
    public mutating func retake(stepID: String) -> [UUID] {
        guard let index = indexOf(stepID) else { return [] }
        let removed = captures(for: stepID)
        capturesByStep[stepID] = nil
        skippedSteps.remove(stepID)
        stepIndex = index
        return removed
    }

    /// Back to the first step with nothing captured (after the result was saved or discarded).
    public mutating func reset() {
        capturesByStep = [:]
        skippedSteps = []
        stepIndex = 0
    }

    private func indexOf(_ stepID: String) -> Int? {
        steps.firstIndex(where: { $0.id == stepID })
    }
}
