namespace CompleteScanner.Core;

// Port of Sources/CompleteScannerKit/Core/ScanTask.swift.

/// <summary>
/// What the user is scanning, as picked on the start screen. Settings files store it as its
/// raw string (<see cref="ScanSettings.TaskId"/>), never as this enum, so a task added by a
/// newer version survives a round trip through an older one. Only tasks whose features exist
/// get a member; later features add theirs after the existing ones.
/// </summary>
public enum ScanTask
{
    Document,
    Feeder,
    Photos,
    PhotoRestore,
    QuickScan,
    Email,
    TwoSided,
    IdCard,
    Copy,
}

public static class ScanTasks
{
    /// <summary>Every task, in start-screen order.</summary>
    public static IReadOnlyList<ScanTask> All { get; } = Enum.GetValues<ScanTask>();

    /// <summary>The stored form: "document", "feeder", "photos", "photoRestore", "quickScan", "email", "twoSided", "idCard", "copy" (the Swift raw values).</summary>
    public static string RawValue(this ScanTask task) => task switch
    {
        ScanTask.Document => "document",
        ScanTask.Feeder => "feeder",
        ScanTask.Photos => "photos",
        ScanTask.PhotoRestore => "photoRestore",
        ScanTask.QuickScan => "quickScan",
        ScanTask.Email => "email",
        ScanTask.TwoSided => "twoSided",
        ScanTask.IdCard => "idCard",
        ScanTask.Copy => "copy",
        _ => throw new ArgumentOutOfRangeException(nameof(task), task, null),
    };

    /// <summary>
    /// The task stored as <paramref name="rawValue"/>; null for null and for any other text
    /// (compared exactly, like a Swift raw value), such as a task of a newer version.
    /// </summary>
    public static ScanTask? TryParse(string? rawValue)
    {
        if (rawValue is null) return null;
        foreach (var task in All)
        {
            if (string.Equals(task.RawValue(), rawValue, StringComparison.Ordinal)) return task;
        }
        return null;
    }
}
