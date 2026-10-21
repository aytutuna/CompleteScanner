namespace CompleteScanner.Core;

// Port of Sources/CompleteScannerKit/Core/TaskCatalog.swift.

/// <summary>How the app handles a task's scans.</summary>
public enum TaskFlowKind
{
    /// <summary>Pages go to the queue and are saved together, or each scan is saved at once.</summary>
    DocumentQueue,
    /// <summary>Photos are found on the bed, cropped and straightened, then reviewed.</summary>
    PhotoSplit,
    /// <summary>The front and back of a card are found on the bed and laid out on one page (<see cref="IdCardComposer"/>).</summary>
    IdCard,
    /// <summary>The scan goes straight to the printer at real size (<see cref="PrintLayout"/>), like a photocopier.</summary>
    Copy,
    /// <summary>
    /// Receipts are found on the bed (<see cref="ReceiptDetector"/>), cut out, straightened and
    /// cleaned up (<see cref="ReceiptEnhancer"/>), then reviewed and saved, named by their date.
    /// </summary>
    ReceiptSplit,
}

/// <summary>A task card: what it is called, how it looks and how its scans are handled.</summary>
/// <param name="IconKey">
/// Names the card's icon; each platform maps it to its own symbol: "document", "feeder",
/// "photos", "restore", "quick", "email", "twoSided", "idCard", "copy", "word", "receipt", "batch", "book",
/// "archive".
/// </param>
/// <param name="Intent">The scan mode the task uses.</param>
/// <param name="RequiredSource">The source the task cannot work without; null when any source does.</param>
/// <param name="FileLabel">What the <c>{task}</c> naming token becomes ("Document", "Photo").</param>
/// <param name="Subtitle">What the task does, in one short line: the tile's tooltip, not shown on the tile.</param>
/// <param name="Group">The start screen's group the tile is in.</param>
public sealed record TaskDefinition(ScanTask Task, string Title, string Subtitle, string IconKey,
                                    TaskFlowKind Flow, ScanIntent Intent, ScanSource? RequiredSource,
                                    string FileLabel, IReadOnlyList<TaskStep> Steps, TaskGroup Group);

/// <summary>The start screen's groups of tasks, in the order it shows them.</summary>
public enum TaskGroup
{
    Documents,
    PhotosAndImages,
    Other,
}

/// <summary>A group of the start screen with its tasks, in the order they are shown.</summary>
public sealed record TaskGroupSection(TaskGroup Group, IReadOnlyList<TaskDefinition> Definitions);

public static class TaskGroups
{
    /// <summary>Every group, in start-screen order.</summary>
    public static IReadOnlyList<TaskGroup> All { get; } = Enum.GetValues<TaskGroup>();

    /// <summary>"Documents", "Photos &amp; images", "Other".</summary>
    public static string Title(this TaskGroup group) => group switch
    {
        TaskGroup.Documents => "Documents",
        TaskGroup.PhotosAndImages => "Photos & images",
        _ => "Other",
    };
}

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
            "Page by page into a searchable PDF.",
            "document", TaskFlowKind.DocumentQueue, ScanIntent.Document, null, "Document",
            [new TaskStep("scan", "Scan each page",
                          "Place each page face down and scan, then save.",
                          "Scan page", Repeats: true,
                          Help: "Scan the pages one by one. They are collected until you save the PDF.")],
            TaskGroup.Documents),
        new(ScanTask.Feeder, "Stack from feeder",
            "A stack through the feeder into one PDF.",
            "feeder", TaskFlowKind.DocumentQueue, ScanIntent.Document, ScanSource.DocumentFeeder, "Document",
            [new TaskStep("scan", "Scan the stack",
                          "Load the pages in the feeder and scan.",
                          "Scan stack", Repeats: true,
                          Help: "Add more stacks if you need to, then save the PDF.")],
            TaskGroup.Documents),
        new(ScanTask.Photos, "Photos",
            "Several photos at once, each cropped and straightened.",
            "photos", TaskFlowKind.PhotoSplit, ScanIntent.Photo, null, "Photo",
            [new TaskStep("scan", "Scan the photos",
                          "Lay the photos on the glass, apart, and scan.",
                          "Scan photos", Repeats: true,
                          Help: "Leave a little space between photos and close the lid. Check each photo before saving.")],
            TaskGroup.PhotosAndImages),
        new(ScanTask.PhotoRestore, "Restore old photos",
            "Brings back faded colors; saved as PNG.",
            "restore", TaskFlowKind.PhotoSplit, ScanIntent.Photo, null, "Restored photo",
            [new TaskStep("scan", "Scan the old photos",
                          "Lay the photos on the glass, apart, and scan.",
                          "Scan photos", Repeats: true,
                          Help: "Colors are restored automatically. Check each photo before saving.")],
            TaskGroup.PhotosAndImages),
        new(ScanTask.QuickScan, "Quick scan",
            "Save part of the glass as an image.",
            "quick", TaskFlowKind.DocumentQueue, ScanIntent.Document, ScanSource.Flatbed, "Scan",
            [new TaskStep("scan", "Scan an area",
                          "Preview, drag over the part you need, then scan.",
                          "Scan", Repeats: true,
                          Help: "Each scan is saved right away.")],
            TaskGroup.PhotosAndImages),
        new(ScanTask.Email, "Email a document",
            "A small PDF, ready to attach.",
            "email", TaskFlowKind.DocumentQueue, ScanIntent.Document, null, "Document",
            [new TaskStep("scan", "Scan each page",
                          "Scan each page, then save to email it.",
                          "Scan page", Repeats: true,
                          Help: "Saving opens the share window, so you can email the PDF.")],
            TaskGroup.Documents),
        new(ScanTask.TwoSided, "Two-sided document",
            "Both sides of every sheet, in page order.",
            "twoSided", TaskFlowKind.DocumentQueue, ScanIntent.Document, ScanSource.DocumentFeeder, "Document",
            [new TaskStep("scan", "Scan the stack",
                          "Load the pages in the feeder and scan.",
                          "Scan stack", Repeats: true,
                          Help: "Both sides of every sheet are scanned and put in order. Then save the PDF.")],
            TaskGroup.Documents),
        new(ScanTask.IdCard, "ID card",
            "Both sides on one page, at real size.",
            "idCard", TaskFlowKind.IdCard, ScanIntent.Document, ScanSource.Flatbed, "ID card",
            IdCardSteps.Steps,
            TaskGroup.Other),
        new(ScanTask.Copy, "Photocopy",
            "Prints at real size, like a photocopier.",
            "copy", TaskFlowKind.Copy, ScanIntent.Document, null, "Copy",
            [new TaskStep("scan", "Make a copy",
                          "Place the original face down, then copy.",
                          "Copy", Repeats: true,
                          Help: "Or load the feeder. Copies print at real size; choose the printer and number of copies on the right.")],
            TaskGroup.Other),
        new(ScanTask.Word, "Scan to Word",
            "Printed pages into an editable Word file.",
            "word", TaskFlowKind.DocumentQueue, ScanIntent.Document, null, "Document",
            [new TaskStep("scan", "Scan each page",
                          "Scan each page, then save as Word.",
                          "Scan page", Repeats: true,
                          Help: "The text is read from the pages into a Word document you can edit.")],
            TaskGroup.Documents),
        new(ScanTask.Receipt, "Receipts",
            "Several at once, small files named by date.",
            "receipt", TaskFlowKind.ReceiptSplit, ScanIntent.Document, null, "Receipt",
            [new TaskStep("scan", "Scan the receipts",
                          "Lay up to six receipts apart and scan.",
                          "Scan receipts", Repeats: true,
                          Help: "Each one is found, straightened and made easy to read. Check them before saving.")],
            TaskGroup.Other),
        new(ScanTask.Batch, "Separate documents",
            "One stack, a PDF for each document.",
            "batch", TaskFlowKind.DocumentQueue, ScanIntent.Document, ScanSource.DocumentFeeder, "Document",
            [new TaskStep("scan", "Scan the stack",
                          "Put a separator sheet before each document, then scan.",
                          "Scan stack", Repeats: true,
                          Help: "1. Print separator sheets (Split into documents, on the right). 2. Put one in front of each "
                                + "document after the first. 3. Load the stack and scan. 4. Check the splits in the page "
                                + "strip, then save.")],
            TaskGroup.Documents),
        new(ScanTask.Book, "Book or magazine",
            "Two pages per scan, split at the spine.",
            "book", TaskFlowKind.DocumentQueue, ScanIntent.Document, ScanSource.Flatbed, "Book",
            [new TaskStep("scan", "Scan each spread",
                          "Open the book face down, spine centered, and scan.",
                          "Scan spread", Repeats: true,
                          Help: "Press it gently flat. Turn the page and scan the next spread; each one becomes two pages.")],
            TaskGroup.Other),
        new(ScanTask.Archive, "Archive document",
            "A searchable PDF/A, made to be kept.",
            "archive", TaskFlowKind.DocumentQueue, ScanIntent.Document, null, "Document",
            [new TaskStep("scan", "Scan each page",
                          "Scan each page, then save as PDF/A.",
                          "Scan page", Repeats: true,
                          Help: "The PDF keeps its best quality, made to be kept for years.")],
            TaskGroup.Documents),
    ];

    /// <summary>
    /// The tasks in the order the start screen shows them, group by group: Documents (Document to
    /// PDF, Stack from feeder, Two-sided document, Separate documents, Scan to Word, Email a
    /// document, Archive document), Photos &amp; images (Photos, Restore old photos, Quick scan),
    /// Other (ID card, Photocopy, Receipts, Book or magazine).
    /// </summary>
    public static IReadOnlyList<ScanTask> StartOrder { get; } =
    [
        ScanTask.Document, ScanTask.Feeder, ScanTask.TwoSided, ScanTask.Batch, ScanTask.Word, ScanTask.Email,
        ScanTask.Archive, ScanTask.Photos, ScanTask.PhotoRestore, ScanTask.QuickScan, ScanTask.IdCard,
        ScanTask.Copy, ScanTask.Receipt, ScanTask.Book,
    ];

    /// <summary>The start screen's groups in order, each with its tasks in <see cref="StartOrder"/>; every task is in one group.</summary>
    public static IReadOnlyList<TaskGroupSection> Sections =>
        [.. TaskGroups.All.Select(group => new TaskGroupSection(
            group, [.. StartOrder.Select(Definition).Where(definition => definition.Group == group)]))];

    /// <summary>Every task, in the order of <see cref="ScanTask"/> (the start screen uses <see cref="StartOrder"/>).</summary>
    public static IReadOnlyList<TaskDefinition> All => Definitions;

    public static TaskDefinition Definition(ScanTask task) => Definitions.First(d => d.Task == task);

    /// <summary>
    /// <paramref name="current"/> with the task's settings laid over it: mode, source,
    /// resolution, color, format, JPEG quality, PDF size, the after-save action, the text beside a
    /// PDF (off: only the Scan to Word task saves text), archival PDF (only the Archive document
    /// task, at the Best size, which turns the password off), the photo and
    /// document switches, searchable PDF, adjustments, two-sided scanning, skipping blank pages,
    /// crop and straighten, turning pages upright, splitting facing pages, softening the spine's shadow,
    /// file name and the task itself. The password option, the page pictures of a Word document, the destination folder, the photo detection tuning, the
    /// legacy OCR languages, the paper size, the edge backs are turned on, how much counts as
    /// blank and the choices of each task (<see cref="ScanSettings.TaskOptions"/>) are kept: they
    /// describe the user's paper and how they want a task done, not the task. <paramref name="current"/> is
    /// not changed. The two-sided task asks for <see cref="DuplexMode.Both"/>, skips blank
    /// pages (the empty backs of one-sided sheets), straightens pages the feeder pulled in at a
    /// slant and turns upright the sheets put in the wrong way round; the Book or magazine task splits
    /// each spread into its facing pages, straightens each page, softens the shadow along the spine and
    /// turns upright a book lying sideways (its reading order and turn, in <see cref="ScanSettings.TaskOptions"/>, are kept); no
    /// task crops yet; <see cref="SettingsAdapter"/> turns
    /// <see cref="DuplexMode.Both"/> into turning over by hand on a feeder that scans one side.
    /// The ID card task makes no searchable PDF: the numbers on an ID are better not indexed; neither
    /// does the Copy task, whose PDF (when one is saved too) is a record of the paper copy. The
    /// Receipts task scans in grayscale (thermal print has no color) into Compact PDFs, named by
    /// the receipt's date. Only the Batch task splits the stack into documents (at separator
    /// sheets, skipping blank pages); the others save one document; no task splits at barcode or QR
    /// sheets. The sheets per document of <see cref="SplitMode.SheetCount"/>, whether a barcode starts a
    /// document (<see cref="DocumentOptions.BarcodeStartsDocument"/>) and the separator codes' prefix
    /// (<see cref="DocumentOptions.SplitBarcodePrefix"/>) are kept.
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
        s.PdfSearchable = task is not (ScanTask.IdCard or ScanTask.Copy);
        s.Adjustments = new AdjustmentSettings();
        s.Output.PdfSize = PdfSizePreset.Standard;
        s.Output.AfterSave = AfterSaveAction.None;
        s.Output.AlsoSaveText = false;
        s.Output.Archival = task == ScanTask.Archive;
        // The password is the user's choice for every task; a PDF/A file can't have one.
        if (task == ScanTask.Archive) s.Output.Protect = false;
        s.Duplex = DuplexMode.Off;
        s.Document.RemoveBlankPages = task is ScanTask.TwoSided or ScanTask.Batch;
        s.Document.AutoCrop = false;
        s.Document.AutoStraighten = task is ScanTask.TwoSided or ScanTask.Book;
        s.Document.AutoRotate = task is ScanTask.TwoSided or ScanTask.Book;
        s.Document.SplitMode = task == ScanTask.Batch ? SplitMode.SeparatorSheet : SplitMode.None;
        s.Document.SplitFacingPages = task == ScanTask.Book;
        s.Document.SoftenSpineShadow = task == ScanTask.Book;
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
                s.Output.AfterSave = AfterSaveAction.Share;
                s.NamingTemplate = "Scan {date} {counter}";
                break;
            case ScanTask.TwoSided:
                s.Intent = ScanIntent.Document;
                s.Source = ScanSource.DocumentFeeder;
                s.Resolution = 300;
                s.Format = OutputFormat.Pdf;
                s.Duplex = DuplexMode.Both;
                s.NamingTemplate = "Scan {date} {counter}";
                break;
            case ScanTask.IdCard:
                s.Intent = ScanIntent.Document;
                s.Resolution = 300;
                s.Format = OutputFormat.Pdf;
                s.NamingTemplate = "ID card {date}";
                break;
            case ScanTask.Copy:
                s.Intent = ScanIntent.Document;
                s.Resolution = 300;
                s.Format = OutputFormat.Pdf;
                s.NamingTemplate = "Copy {date} {counter}";
                break;
            case ScanTask.Word:
                s.Intent = ScanIntent.Document;
                s.Resolution = 300;
                s.Format = OutputFormat.Word;
                s.NamingTemplate = "Scan {date} {counter}";
                break;
            case ScanTask.Receipt:
                s.Intent = ScanIntent.Document;
                s.Resolution = 300;
                s.ColorMode = ColorMode.Grayscale;
                s.Format = OutputFormat.Pdf;
                s.Output.PdfSize = PdfSizePreset.Compact;
                s.NamingTemplate = "Receipt {docdate} {counter}";
                break;
            case ScanTask.Batch:
                s.Intent = ScanIntent.Document;
                s.Source = ScanSource.DocumentFeeder;
                s.Resolution = 300;
                s.Format = OutputFormat.Pdf;
                s.NamingTemplate = "Document {label} {date} {counter}";
                break;
            case ScanTask.Book:
                s.Intent = ScanIntent.Document;
                s.Resolution = 300;
                s.Format = OutputFormat.Pdf;
                s.NamingTemplate = "{task} {date} {counter}";
                break;
            case ScanTask.Archive:
                s.Intent = ScanIntent.Document;
                s.Resolution = 300;
                s.Format = OutputFormat.Pdf;
                s.Output.PdfSize = PdfSizePreset.Best;
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
        if (settings.Document.SplitMode != SplitMode.None && settings.DocumentMultiPage) return ScanTask.Batch;
        if (settings.Document.SplitFacingPages && settings.DocumentMultiPage) return ScanTask.Book;
        if (settings.Source == ScanSource.DocumentFeeder)
        {
            return settings.Duplex == DuplexMode.Off ? ScanTask.Feeder : ScanTask.TwoSided;
        }
        if (settings.Format == OutputFormat.Word) return ScanTask.Word;
        if (!settings.DocumentMultiPage && settings.Format.IsImageFormat()) return ScanTask.QuickScan;
        return ScanTask.Document;
    }

    /// <summary>Why a task that needs the document feeder cannot be started: the tile's one visible line.</summary>
    public const string NeedsFeederReason = "Needs a document feeder";

    /// <summary>Why a task that needs the flatbed cannot be started.</summary>
    public const string NeedsFlatbedReason = "Needs a flatbed";

    /// <summary>
    /// The error when a task that cannot be started is picked anyway: its title and the reason, as a
    /// sentence ("Stack from feeder needs a document feeder.").
    /// </summary>
    public static string UnavailableMessage(ScanTask task, string reason)
    {
        string text = reason.Trim().TrimEnd('.');
        if (text.Length > 0) text = char.ToLowerInvariant(text[0]) + text[1..];
        return $"{Definition(task).Title} {text}.";
    }

    /// <summary>
    /// Whether the task can be started with a scanner offering <paramref name="capabilities"/>
    /// (null: none connected yet, so nothing is ruled out).
    /// </summary>
    public static TaskAvailability Availability(ScanTask task, ScannerCapabilities? capabilities) =>
        Availability(task, capabilities, hasPrinter: true);

    /// <summary>
    /// Whether the task can be started with a scanner offering <paramref name="capabilities"/>
    /// (null: none connected yet, so nothing is ruled out) and, for the Copy task, a printer
    /// (<paramref name="hasPrinter"/>: false only when it is known that none is installed).
    /// </summary>
    public static TaskAvailability Availability(ScanTask task, ScannerCapabilities? capabilities, bool hasPrinter)
    {
        if (task == ScanTask.Copy && !hasPrinter) return new TaskAvailability(false, PrintText.NoPrinterReason);
        var definition = Definition(task);
        if (capabilities is null || definition.RequiredSource is not { } source
            || capabilities.Sources.Contains(source))
        {
            return TaskAvailability.Available;
        }
        return new TaskAvailability(false, source == ScanSource.DocumentFeeder
            ? NeedsFeederReason
            : NeedsFlatbedReason);
    }

    /// <summary>
    /// The settings still do what the task is for: the same scan mode, and the task's
    /// required source; for the two-sided task, both sides; for Scan to Word, a Word document; for
    /// the Batch task, a split; for the Book or magazine task, splitting facing pages; for the Archive
    /// document task, an archival PDF. Changing the mode by hand (or choosing one side, another
    /// format, no split or a plain PDF), or a scanner without that source, ends the task.
    /// </summary>
    public static bool Fits(ScanTask task, ScanSettings settings)
    {
        var definition = Definition(task);
        return settings.Intent == definition.Intent
               && (definition.RequiredSource is not { } source || settings.Source == source)
               && (task != ScanTask.TwoSided || settings.Duplex != DuplexMode.Off)
               && (task != ScanTask.Word || settings.Format == OutputFormat.Word)
               && (task != ScanTask.Batch || settings.Document.SplitMode != SplitMode.None)
               && (task != ScanTask.Book || settings.Document.SplitFacingPages)
               && (task != ScanTask.Archive || (settings.Output.Archival && settings.Format == OutputFormat.Pdf));
    }

    /// <summary>
    /// The steps the scan screen guides: turning the stack over by hand
    /// (<see cref="DocumentSides.ManualSteps"/>) whenever these settings scan both sides that
    /// way, otherwise the stored task's steps while it fits; null when there is nothing to guide.
    /// </summary>
    public static IReadOnlyList<TaskStep>? GuidedSteps(ScanSettings settings, ScannerCapabilities? capabilities)
    {
        if (DocumentSides.UsesManualSteps(settings, capabilities)) return DocumentSides.ManualSteps;
        return settings.Task is { } task && Fits(task, settings) ? Definition(task).Steps : null;
    }

    /// <summary>How a scan with these settings is handled: the stored task's flow while it fits, otherwise by mode.</summary>
    public static TaskFlowKind FlowOf(ScanSettings settings) =>
        settings.Task is { } task && Fits(task, settings)
            ? Definition(task).Flow
            : settings.Intent == ScanIntent.Photo ? TaskFlowKind.PhotoSplit : TaskFlowKind.DocumentQueue;

    /// <summary>
    /// One line describing the settings, e.g. "300 dpi · Color · PDF". A PDF size other than
    /// the default Standard is named ("300 dpi · Color · Compact PDF"), and so is two-sided
    /// feeder scanning ("… · Both sides", "… · Both sides, turned by hand"), splitting into
    /// documents ("… · Split at separator sheets") and facing pages ("… · Facing pages split",
    /// "… · Facing pages split, right to left"), so the line stays
    /// short enough for cards and the preset list. A copy says how it prints instead of a format:
    /// "300 dpi · Color · Actual size", "300 dpi · Grayscale · Fit to page · 3 copies".
    /// </summary>
    public static string Summary(ScanSettings settings)
    {
        if (FlowOf(settings) == TaskFlowKind.Copy)
        {
            // A copy is paper, not a file: its size and count matter, not the format.
            int copies = PrintCopies.Clamp(settings.TaskOptions.CopyCount);
            return $"{settings.Resolution} dpi · {settings.ColorMode.Label()} · {PrintText.ModeLabel(settings.TaskOptions.CopyFitToPage)}"
                   + (copies > 1 ? $" · {copies} copies" : "");
        }
        string format = settings.Format == OutputFormat.Pdf && settings.Output.PdfSize != PdfSizePreset.Standard
            ? $"{settings.Output.PdfSize.Label()} {settings.Format.Label()}"
            : settings.Format.Label();
        var sides = DocumentSides.Effective(settings, null);
        string twoSided = sides == DuplexMode.Off ? "" : $" · {sides.Label()}";
        string split = SplitSummary(settings) is { } text ? $" · {text}" : "";
        string book = BookSummary(settings) is { } pages ? $" · {pages}" : "";
        return $"{settings.Resolution} dpi · {settings.ColorMode.Label()} · {format}{twoSided}{split}{book}";
    }

    /// <summary>
    /// "Facing pages split" (", right to left") for collected document pages whose spreads are split
    /// (one side of each sheet, <see cref="BookPages.ScansOneSide"/>); null otherwise.
    /// </summary>
    private static string? BookSummary(ScanSettings settings)
    {
        if (settings.Intent != ScanIntent.Document || !settings.DocumentMultiPage || !settings.Document.SplitFacingPages
            || !BookPages.ScansOneSide(settings)) return null;
        return settings.TaskOptions.BookRightToLeft ? "Facing pages split, right to left" : "Facing pages split";
    }

    /// <summary>
    /// "Split at separator sheets", "Split at blank sheets", "Split every 3 sheets", "Split at barcode
    /// sheets" ("Split and named at barcodes" when a barcode starts its document) for collected
    /// document pages split into documents; null otherwise.
    /// </summary>
    private static string? SplitSummary(ScanSettings settings)
    {
        if (settings.Intent != ScanIntent.Document || !settings.DocumentMultiPage) return null;
        int sheets = DocumentSplitter.ClampSheetCount(settings.Document.SplitSheetCount);
        return settings.Document.SplitMode switch
        {
            SplitMode.SeparatorSheet => "Split at separator sheets",
            SplitMode.BlankSheet => "Split at blank sheets",
            SplitMode.SheetCount => sheets == 1 ? "Split every sheet" : $"Split every {sheets} sheets",
            SplitMode.Barcode => settings.Document.BarcodeStartsDocument ? "Split and named at barcodes" : "Split at barcode sheets",
            _ => null,
        };
    }
}
