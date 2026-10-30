namespace LazyScan.Core;

// Port of Sources/CompleteScannerKit/Core/TaskFlow.swift.

/// <summary>One step of a guided task, as the banner on the scan screen shows it.</summary>
/// <param name="Id">Stable within its task, for example "scan", "front" or "back".</param>
/// <param name="Title">Short name of the step ("Scan each page").</param>
/// <param name="Prompt">What to do, in one short line (ten words at most): the banner shows it.</param>
/// <param name="PrimaryActionLabel">Caption of the button that performs the step ("Scan page").</param>
/// <param name="Skippable">The step may be left out (the back of a one-sided card).</param>
/// <param name="Repeats">The step takes any number of captures (pages of a document) instead of one.</param>
/// <param name="RequiresCapture">The task cannot be finished before this step has a capture.</param>
/// <param name="Help">
/// The fuller guidance behind the banner's ⓘ, read out with the prompt by screen readers; empty
/// when the prompt says it all.
/// </param>
public sealed record TaskStep(string Id, string Title, string Prompt, string PrimaryActionLabel,
                              bool Skippable = false, bool Repeats = false, bool RequiresCapture = true,
                              string Help = "")
{
    /// <summary>
    /// The step in one word, for a step indicator ("Front · Back · Check"): the title's first word
    /// after a leading "Scan the" or "Scan", capitalized ("Scan the front sides" is "Front").
    /// </summary>
    public string Word
    {
        get
        {
            string t = Title.Trim();
            foreach (string lead in new[] { "Scan the ", "Scan " })
            {
                if (t.StartsWith(lead, StringComparison.Ordinal) && t.Length > lead.Length)
                {
                    t = t[lead.Length..];
                    break;
                }
            }
            string word = t.Split(' ', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault() ?? t;
            return word.Length == 0 ? word : char.ToUpperInvariant(word[0]) + word[1..];
        }
    }

    /// <summary>The prompt and the help as one text, for screen readers.</summary>
    public string FullPrompt => Help.Length == 0 ? Prompt : $"{Prompt} {Help}";
}

/// <summary>
/// Where the user is in a guided task: the current step, what each step has captured, and
/// which steps were skipped. A pure state machine; the app records captures (page or photo
/// ids) and asks it what to show. Unknown step ids are ignored.
/// </summary>
public sealed class TaskFlow
{
    private readonly List<TaskStep> _steps;
    private readonly Dictionary<string, List<Guid>> _captures = new(StringComparer.Ordinal);
    private readonly HashSet<string> _skipped = new(StringComparer.Ordinal);

    public TaskFlow(IEnumerable<TaskStep> steps)
    {
        _steps = [.. steps];
    }

    public IReadOnlyList<TaskStep> Steps => _steps;

    /// <summary>Index of <see cref="Current"/>; equals <see cref="StepCount"/> once every step is done.</summary>
    public int StepIndex { get; private set; }

    public int StepCount => _steps.Count;

    /// <summary>The step to show; null once the flow is complete.</summary>
    public TaskStep? Current => StepIndex < _steps.Count ? _steps[StepIndex] : null;

    /// <summary>Every step was advanced past or skipped.</summary>
    public bool IsComplete => StepIndex >= _steps.Count;

    /// <summary>Every step that requires a capture has one, so the result can be saved.</summary>
    public bool CanFinish => _steps.All(step => !step.RequiresCapture || Captures(step.Id).Count > 0);

    /// <summary>The captures of a step, oldest first (empty for an unknown step).</summary>
    public IReadOnlyList<Guid> Captures(string stepId) =>
        _captures.TryGetValue(stepId, out var list) ? [.. list] : [];

    public bool IsSkipped(string stepId) => _skipped.Contains(stepId);

    /// <summary>
    /// Records a capture for a step. A repeating step keeps every capture; any other step keeps
    /// only the newest. Returns the captures it replaced, for the caller to discard. A skipped
    /// step counts as not skipped again. The current step does not change.
    /// </summary>
    public IReadOnlyList<Guid> Record(string stepId, Guid captureId)
    {
        if (IndexOf(stepId) is not { } index) return [];
        var step = _steps[index];
        if (!_captures.TryGetValue(stepId, out var list))
        {
            list = [];
            _captures[stepId] = list;
        }
        List<Guid> replaced = step.Repeats ? [] : [.. list];
        if (!step.Repeats) list.Clear();
        list.Add(captureId);
        _skipped.Remove(stepId);
        return replaced;
    }

    /// <summary>
    /// Moves to the next step. Refused (false) when the flow is complete, or when the current
    /// step requires a capture and has none.
    /// </summary>
    public bool Advance()
    {
        if (Current is not { } step) return false;
        if (step.RequiresCapture && Captures(step.Id).Count == 0) return false;
        StepIndex += 1;
        return true;
    }

    /// <summary>
    /// Leaves out the current step: its captures are dropped and the flow moves on. Refused
    /// (false) when the flow is complete or the current step is not skippable.
    /// </summary>
    public bool Skip()
    {
        if (Current is not { Skippable: true } step) return false;
        _captures.Remove(step.Id);
        _skipped.Add(step.Id);
        StepIndex += 1;
        return true;
    }

    /// <summary>
    /// Goes back to a step to capture it again: its captures are dropped (and returned, for
    /// the caller to discard) and it becomes the current step. Later steps keep theirs.
    /// </summary>
    public IReadOnlyList<Guid> Retake(string stepId)
    {
        if (IndexOf(stepId) is not { } index) return [];
        var removed = Captures(stepId);
        _captures.Remove(stepId);
        _skipped.Remove(stepId);
        StepIndex = index;
        return removed;
    }

    /// <summary>Back to the first step with nothing captured (after the result was saved or discarded).</summary>
    public void Reset()
    {
        _captures.Clear();
        _skipped.Clear();
        StepIndex = 0;
    }

    private int? IndexOf(string stepId)
    {
        int index = _steps.FindIndex(step => string.Equals(step.Id, stepId, StringComparison.Ordinal));
        return index < 0 ? null : index;
    }
}
