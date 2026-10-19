namespace CompleteScanner.Core;

// Port of Sources/CompleteScannerKit/Core/TaskCatalog.swift.

/// <summary>How the app handles a task's scans.</summary>
public enum TaskFlowKind
{
    /// <summary>Pages go to the queue and are saved together, or each scan is saved at once.</summary>
    DocumentQueue,
    /// <summary>Photos are found on the bed, cropped and straightened, then reviewed.</summary>
    PhotoSplit,
}

/// <summary>A task card: what it is called, how it looks and how its scans are handled.</summary>
/// <param name="IconKey">
/// Names the card's icon; each platform maps it to its own symbol: "document", "feeder",
/// "photos", "restore", "quick", "email".
/// </param>
/// <param name="Intent">The scan mode the task uses.</param>
/// <param name="RequiredSource">The source the task cannot work without; null when any source does.</param>
/// <param name="FileLabel">What the <c>{task}</c> naming token becomes ("Document", "Photo").</param>
public sealed record TaskDefinition(ScanTask Task, string Title, string Subtitle, string IconKey,
                                    TaskFlowKind Flow, ScanIntent Intent, ScanSource? RequiredSource,
                                    string FileLabel, IReadOnlyList<TaskStep> Steps);

/// <summary>Whether a task can be started with the connected scanner, and if not, why.</summary>
public sealed record TaskAvailability(bool IsAvailable, string? Reason = null)
{
    public static readonly TaskAvailability Available = new(true);
}

/// <summary>
/// The tasks of the start screen, in code rather than in a settings file. Picking a task lays
/// its settings over the current ones (<see cref="Apply"/>); a preset without a stored task
/// is shown with the task its settings look like (<see cref="Infer"/>).
/// </summary>
public static class TaskCatalog
{
    private static readonly TaskDefinition[] Definitions =
    [
        new(ScanTask.Document, "Document to PDF",
            "Scan pages one at a time into a searchable PDF.",
            "document", TaskFlowKind.DocumentQueue, ScanIntent.Document, null, "Document",
            [new TaskStep("scan", "Scan each page",
                          "Place a page face down on the glass and scan it. Repeat for every page, then save the PDF.",
                          "Scan page", Repeats: true)]),
        new(ScanTask.Feeder, "Multi-page from feeder",
            "Scan a stack of pages through the document feeder into one PDF.",
            "feeder", TaskFlowKind.DocumentQueue, ScanIntent.Document, ScanSource.DocumentFeeder, "Document",
            [new TaskStep("scan", "Scan the stack",
                          "Load the pages in the document feeder and scan. Add more stacks if you need to, then save the PDF.",
                          "Scan stack", Repeats: true)]),
        new(ScanTask.Photos, "Photos",
            "Scan several photos at once. Each one is found, cropped and straightened.",
            "photos", TaskFlowKind.PhotoSplit, ScanIntent.Photo, null, "Photo",
            [new TaskStep("scan", "Scan the photos",
                          "Lay the photos on the glass with a little space between them, close the lid and scan. Check each photo before saving.",
                          "Scan photos", Repeats: true)]),
        new(ScanTask.PhotoRestore, "Old photo restoration",
            "Bring back the faded colors of old prints, saved as lossless PNG.",
            "restore", TaskFlowKind.PhotoSplit, ScanIntent.Photo, null, "Restored photo",
            [new TaskStep("scan", "Scan the old photos",
                          "Lay the photos on the glass with a little space between them and scan. Colors are restored automatically; check each photo before saving.",
                          "Scan photos", Repeats: true)]),
        new(ScanTask.QuickScan, "Quick scan",
            "Preview the glass, drag over the part you need and save it as an image.",
            "quick", TaskFlowKind.DocumentQueue, ScanIntent.Document, ScanSource.Flatbed, "Scan",
            [new TaskStep("scan", "Scan an area",
                          "Preview the glass, drag over the part you need, then scan. Each scan is saved right away.",
                          "Scan", Repeats: true)]),
        new(ScanTask.Email, "Email a document",
            "Scan pages into a small PDF that is easy to attach to an email.",
            "email", TaskFlowKind.DocumentQueue, ScanIntent.Document, null, "Document",
            [new TaskStep("scan", "Scan each page",
                          "Place a page face down on the glass and scan it. Repeat for every page, then save the PDF and attach it to your email.",
                          "Scan page", Repeats: true)]),
    ];

    /// <summary>Every task, in start-screen order.</summary>
    public static IReadOnlyList<TaskDefinition> All => Definitions;

    public static TaskDefinition Definition(ScanTask task) => Definitions.First(d => d.Task == task);

    /// <summary>
    /// <paramref name="current"/> with the task's settings laid over it: mode, source,
    /// resolution, color, format, JPEG quality, PDF size, the photo and document switches,
    /// searchable PDF, adjustments, file name and the task itself. The destination folder, the photo
    /// detection tuning and the legacy OCR languages are kept. <paramref name="current"/> is
    /// not changed.
    /// </summary>
    public static ScanSettings Apply(ScanTask task, ScanSettings current)
    {
        var s = current.Clone();
        s.Source = ScanSource.Flatbed;
        s.ColorMode = ColorMode.Color;
        s.JpegQuality = 0.9;
        s.PhotoAutoSplit = true;
        s.PhotoAutoDeskew = true;
        s.DocumentMultiPage = true;
        s.PdfSearchable = true;
        s.Adjustments = new AdjustmentSettings();
        s.Output.PdfSize = PdfSizePreset.Standard;
        switch (task)
        {
            case ScanTask.Document:
                s.Intent = ScanIntent.Document;
                s.Resolution = 300;
                s.Format = OutputFormat.Pdf;
                s.NamingTemplate = "Scan {date} {counter}";
                break;
            case ScanTask.Feeder:
                s.Intent = ScanIntent.Document;
                s.Source = ScanSource.DocumentFeeder;
                s.Resolution = 300;
                s.Format = OutputFormat.Pdf;
                s.NamingTemplate = "Scan {date} {counter}";
                break;
            case ScanTask.Photos:
                s.Intent = ScanIntent.Photo;
                s.Resolution = 600;
                s.Format = OutputFormat.Jpeg;
                s.NamingTemplate = "Photo {date} {counter}";
                break;
            case ScanTask.PhotoRestore:
                s.Intent = ScanIntent.Photo;
                s.Resolution = 600;
                s.Format = OutputFormat.Png;
                s.Adjustments.RestoreFadedColors = true;
                s.Adjustments.AutoEnhance = true;
                s.NamingTemplate = "Photo {date} {counter}";
                break;
            case ScanTask.QuickScan:
                s.Intent = ScanIntent.Document;
                s.Resolution = 150;
                s.Format = OutputFormat.Jpeg;
                s.DocumentMultiPage = false;
                s.NamingTemplate = "Scan {date} {counter}";
                break;
            case ScanTask.Email:
                s.Intent = ScanIntent.Document;
                s.Resolution = 300;
                s.Format = OutputFormat.Pdf;
                s.Output.PdfSize = PdfSizePreset.Compact;
                s.NamingTemplate = "Scan {date} {counter}";
                break;
        }
        s.TaskId = task.RawValue();
        return s;
    }

    /// <summary>
    /// The task the settings belong to: the stored one when it is known, otherwise the one they
    /// look like. Used for display and file names only; never written back.
    /// </summary>
    public static ScanTask Infer(ScanSettings settings)
    {
        if (settings.Task is { } stored) return stored;
        if (settings.Intent == ScanIntent.Photo)
        {
            return settings.Adjustments.RestoreFadedColors ? ScanTask.PhotoRestore : ScanTask.Photos;
        }
        if (settings.Source == ScanSource.DocumentFeeder) return ScanTask.Feeder;
        if (!settings.DocumentMultiPage && settings.Format != OutputFormat.Pdf) return ScanTask.QuickScan;
        return ScanTask.Document;
    }

    /// <summary>
    /// Whether the task can be started with a scanner offering <paramref name="capabilities"/>
    /// (null: none connected yet, so nothing is ruled out).
    /// </summary>
    public static TaskAvailability Availability(ScanTask task, ScannerCapabilities? capabilities)
    {
        var definition = Definition(task);
        if (capabilities is null || definition.RequiredSource is not { } source
            || capabilities.Sources.Contains(source))
        {
            return TaskAvailability.Available;
        }
        return new TaskAvailability(false, source == ScanSource.DocumentFeeder
            ? "This scanner has no document feeder."
            : "This scanner has no flatbed.");
    }

    /// <summary>
    /// The settings still do what the task is for: the same scan mode, and the task's
    /// required source. Changing the mode by hand, or a scanner without that source, ends the
    /// task.
    /// </summary>
    public static bool Fits(ScanTask task, ScanSettings settings)
    {
        var definition = Definition(task);
        return settings.Intent == definition.Intent
               && (definition.RequiredSource is not { } source || settings.Source == source);
    }

    /// <summary>How a scan with these settings is handled: the stored task's flow while it fits, otherwise by mode.</summary>
    public static TaskFlowKind FlowOf(ScanSettings settings) =>
        settings.Task is { } task && Fits(task, settings)
            ? Definition(task).Flow
            : settings.Intent == ScanIntent.Photo ? TaskFlowKind.PhotoSplit : TaskFlowKind.DocumentQueue;

    /// <summary>
    /// One line describing the settings, e.g. "300 dpi · Color · PDF". A PDF size other than
    /// the default Standard is named ("300 dpi · Color · Compact PDF"), so the line stays short
    /// enough for cards and the preset list.
    /// </summary>
    public static string Summary(ScanSettings settings)
    {
        string format = settings.Format == OutputFormat.Pdf && settings.Output.PdfSize != PdfSizePreset.Standard
            ? $"{settings.Output.PdfSize.Label()} {settings.Format.Label()}"
            : settings.Format.Label();
        return $"{settings.Resolution} dpi · {settings.ColorMode.Label()} · {format}";
    }
}
