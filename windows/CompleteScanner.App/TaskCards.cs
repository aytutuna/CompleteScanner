using CompleteScanner.Core;

namespace CompleteScanner.App;

/// <summary>Segoe Fluent Icons glyphs for the task icons (<see cref="TaskDefinition.IconKey"/>).</summary>
public static class TaskIcons
{
    public static string Glyph(string iconKey) => iconKey switch
    {
        "document" => "",
        "feeder" => "",
        "photos" => "",
        "restore" => "",
        "quick" => "",
        "email" => "",
        _ => "",
    };

    public static string Glyph(ScanTask task) => Glyph(TaskCatalog.Definition(task).IconKey);
}

/// <summary>A task card on the start screen: the task, whether the connected scanner can do it, and what it sets.</summary>
public sealed class TaskCardItem(TaskDefinition definition, TaskAvailability availability, bool isCurrent,
                                 string summary)
{
    public TaskDefinition Definition { get; } = definition;
    public ScanTask Task => Definition.Task;
    public string Title => Definition.Title;
    public string Subtitle => Definition.Subtitle;
    public string Glyph => TaskIcons.Glyph(Definition.IconKey);
    /// <summary>What the task sets on the connected scanner, e.g. "300 dpi · Color · PDF".</summary>
    public string Summary { get; } = summary;
    public bool IsAvailable => availability.IsAvailable;
    /// <summary>Why the task cannot be started; null while it can.</summary>
    public string? Reason => availability.Reason;
    /// <summary>The task the current settings are set up for.</summary>
    public bool IsCurrent { get; } = isCurrent;

    public string HelpText =>
        IsAvailable
            ? $"{Subtitle} {Summary}.{(IsCurrent ? " Current task." : "")}"
            : $"{Subtitle} Not available: {Reason}";

    /// <summary>Equal for cards that look and behave the same, so an unchanged grid is not rebuilt (and keeps focus).</summary>
    internal string Signature => string.Join('\u001f', Task, IsAvailable, Reason ?? "", IsCurrent, Summary);
}

/// <summary>A saved preset on the start screen, badged with the task it was saved for or looks like.</summary>
public sealed class PresetCardItem(Preset preset)
{
    public Preset Preset { get; } = preset;
    public string Name => Preset.Name;
    public ScanTask Task { get; } = TaskCatalog.Infer(preset.Settings);
    public string TaskTitle => TaskCatalog.Definition(Task).Title;
    public string Glyph => TaskIcons.Glyph(Task);
    public string Summary => TaskCatalog.Summary(Preset.Settings);
    public string HelpText => $"Preset for {TaskTitle}. {Summary}.";

    internal string Signature => string.Join('\u001f', Preset.Id, Name, Task, Summary);
}
