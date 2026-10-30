namespace LazyScan.Core;

// Port of Sources/CompleteScannerKit/Core/InspectorSections.swift: the settings column's sections,
// which of them start open, which a task opens, and the summary a collapsed section's header shows.
// Both apps lay their settings out in these sections.

/// <summary>
/// The settings column's sections, in order: the task's own section (Photocopy or Receipts), Scanner,
/// Output, Adjustments, Pages, Split into documents, Archive &amp; password and More options. The
/// task's section, Scanner and Output start open; a collapsed header shows what is on in it, so a
/// setting other than the default is never out of sight.
/// </summary>
public static class InspectorSections
{
    public const string Task = "task";
    public const string Scanner = "scanner";
    public const string Output = "output";
    public const string Adjustments = "adjustments";
    public const string Pages = "pages";
    public const string Split = "split";
    public const string Archive = "archive";
    public const string More = "more";

    /// <summary>Every section, in the order the column shows them.</summary>
    public static IReadOnlyList<string> All { get; } = [Task, Scanner, Output, Adjustments, Pages, Split, Archive, More];

    /// <summary>The section's header: "Scanner", "Split into documents"; the task's section is named by its task.</summary>
    public static string Title(string section) => section switch
    {
        Task => "Task",
        Scanner => "Scanner",
        Output => "Output",
        Adjustments => "Adjustments",
        Pages => "Pages",
        Split => "Split into documents",
        Archive => "Archive & password",
        More => "More options",
        _ => section,
    };

    /// <summary>The task section, Scanner and Output start open; the rest start collapsed.</summary>
    public static bool OpenByDefault(string section) => section is Task or Scanner or Output;

    /// <summary>The section a task opens when it is started, if any.</summary>
    public static string? OpenedBy(ScanTask task) => task switch
    {
        ScanTask.PhotoRestore => Adjustments,
        ScanTask.Book => Pages,
        ScanTask.Batch => Split,
        ScanTask.Archive => Archive,
        _ => null,
    };

    private static readonly ScanSettings Defaults = new();

    /// <summary>"Flatbed · 300 dpi · Color", "Feeder · both sides · 300 dpi · Gray".</summary>
    public static string ScannerSummary(ScanSettings s)
    {
        var parts = new List<string> { s.Source == ScanSource.DocumentFeeder ? "Feeder" : "Flatbed" };
        if (s.Source == ScanSource.DocumentFeeder && s.Duplex != DuplexMode.Off) parts.Add("both sides");
        parts.Add($"{s.Resolution} dpi");
        parts.Add(s.ColorMode switch { ColorMode.Grayscale => "Gray", ColorMode.BlackWhite => "B&W", _ => "Color" });
        return string.Join(" · ", parts);
    }

    /// <summary>A scanner setting differs from a fresh install's.</summary>
    public static bool ScannerChanged(ScanSettings s) =>
        s.Source != Defaults.Source || s.Duplex != Defaults.Duplex || s.PaperSize != Defaults.PaperSize
        || s.Resolution != Defaults.Resolution || s.ColorMode != Defaults.ColorMode;

    /// <summary>"PDF · Standard", "Word", "JPEG": the format the save uses, and a PDF's size.</summary>
    /// <param name="shownFormat">The format the column shows (photos save an image, receipts and the ID card a PDF or an image).</param>
    public static string OutputSummary(ScanSettings s, OutputFormat shownFormat)
    {
        string format = shownFormat switch { OutputFormat.Word => "Word", OutputFormat.Text => "Text", var f => f.Label() };
        return shownFormat == OutputFormat.Pdf && s.Intent == ScanIntent.Document ? $"{format} · {s.Output.PdfSize.Label()}" : format;
    }

    /// <summary>
    /// The format differs from a fresh install's for the mode (JPEG for photos, PDF otherwise), or a PDF
    /// shown has a size other than a fresh install's.
    /// </summary>
    public static bool OutputChanged(ScanSettings s, OutputFormat shownFormat)
    {
        var defaultFormat = s.Intent == ScanIntent.Photo ? OutputFormat.Jpeg : Defaults.Format;
        return shownFormat != defaultFormat
               || (shownFormat == OutputFormat.Pdf && s.Output.PdfSize != Defaults.Output.PdfSize);
    }

    /// <summary>"Edited" when a slider or a switch other than Auto enhance is changed, "Auto" for Auto enhance alone, else "".</summary>
    public static string AdjustmentsSummary(AdjustmentSettings a)
    {
        bool edited = a.Brightness != 0 || a.Contrast != 1 || a.Saturation != 1 || a.Sharpness != 0
                      || a.Descreen || a.RestoreFadedColors;
        return edited ? "Edited" : a.AutoEnhance ? "Auto" : "";
    }

    /// <summary>The page options that are on, at most two then "+N": "Skip blank · Upright +1"; "" when none is.</summary>
    public static string PagesSummary(DocumentOptions d)
    {
        var on = new List<string>();
        if (d.RemoveBlankPages) on.Add("Skip blank");
        if (d.AutoCrop) on.Add("Crop");
        if (d.AutoStraighten) on.Add("Straighten");
        if (d.AutoRotate) on.Add("Upright");
        if (d.SplitFacingPages) on.Add("Facing pages");
        if (on.Count <= 2) return string.Join(" · ", on);
        return $"{on[0]} · {on[1]} +{on.Count - 2}";
    }

    /// <summary>How many page options are on (the header's accessible name: "Pages, 2 options on").</summary>
    public static int PagesOn(DocumentOptions d) =>
        new[] { d.RemoveBlankPages, d.AutoCrop, d.AutoStraighten, d.AutoRotate, d.SplitFacingPages }.Count(on => on);

    /// <summary>"Off", "Separator sheets", "Blank sheets", "Every 3 sheets", "QR codes".</summary>
    public static string SplitSummary(DocumentOptions d)
    {
        int sheets = DocumentSplitter.ClampSheetCount(d.SplitSheetCount);
        return d.SplitMode switch
        {
            SplitMode.SeparatorSheet => "Separator sheets",
            SplitMode.BlankSheet => "Blank sheets",
            SplitMode.SheetCount => sheets == 1 ? "Every sheet" : $"Every {sheets} sheets",
            SplitMode.Barcode => "QR codes",
            _ => "Off",
        };
    }

    /// <summary>"Off", "PDF/A" or "Password on" (the password wins: the two can't be on together).</summary>
    public static string ArchiveSummary(OutputOptions o) => o.Protect ? "Password on" : o.Archival ? "PDF/A" : "Off";

    /// <summary>"Open after saving", ".txt", both, or "".</summary>
    /// <param name="textShown">Also save text applies (a PDF is saved), so it counts.</param>
    public static string MoreSummary(OutputOptions o, bool textShown)
    {
        var parts = new List<string>();
        if (o.AfterSave != AfterSaveAction.None) parts.Add($"{o.AfterSave.Label().TrimEnd('…')} after saving");
        if (textShown && o.AlsoSaveText) parts.Add(".txt");
        return string.Join(" · ", parts);
    }

    /// <summary>
    /// The header's accessible name: the title, then the summary when there is one ("Scanner, Flatbed ·
    /// 300 dpi · Color").
    /// </summary>
    public static string HeaderName(string title, string summary) =>
        summary.Length == 0 ? title : $"{title}, {summary}";

    /// <summary>The Pages header's accessible name: how many options are on ("Pages, 2 options on"), or just "Pages".</summary>
    public static string PagesHeaderName(DocumentOptions d)
    {
        int on = PagesOn(d);
        string title = Title(Pages);
        return on == 0 ? title : $"{title}, {on} option{(on == 1 ? "" : "s")} on";
    }

    // MARK: - The sections for a setting

    /// <summary>
    /// The sections shown for <paramref name="s"/>, in order (hide what can't apply): the task's own for
    /// Photocopy and Receipts; Scanner, Output and Adjustments always; Pages and Split into documents for
    /// document pages collected in the queue; Archive &amp; password while a save writes a PDF
    /// (<see cref="WritesPdf"/>); More options always.
    /// </summary>
    public static IReadOnlyList<string> Shown(ScanSettings s)
    {
        var flow = TaskCatalog.FlowOf(s);
        bool pageSections = s.Intent == ScanIntent.Document && flow == TaskFlowKind.DocumentQueue;
        var result = new List<string>();
        foreach (string section in All)
        {
            bool shown = section switch
            {
                Task => TaskTitle(s) is not null,
                Pages or Split => pageSections,
                Archive => WritesPdf(s),
                _ => true,
            };
            if (shown) result.Add(section);
        }
        return result;
    }

    /// <summary>The task's own section's header: "Photocopy" or "Receipts"; null for a task without one.</summary>
    public static string? TaskTitle(ScanSettings s) => TaskCatalog.FlowOf(s) switch
    {
        TaskFlowKind.Copy => "Photocopy",
        TaskFlowKind.ReceiptSplit => "Receipts",
        _ => null,
    };

    /// <summary>
    /// A section's header for <paramref name="s"/>: the task's own named by its task, Output named "Photos"
    /// in Photos mode, the others by <see cref="Title(string)"/>.
    /// </summary>
    public static string Title(string section, ScanSettings s)
    {
        if (section == Task) return TaskTitle(s) ?? Title(Task);
        if (section == Output && s.Intent == ScanIntent.Photo) return "Photos";
        return Title(section);
    }

    /// <summary>
    /// Receipts and the ID card are saved from their reviews as a PDF or an image
    /// (<see cref="OutputFormats.PageFormat"/>), so Word and text are not offered for them.
    /// </summary>
    public static bool SavesPageFormat(ScanSettings s) => TaskCatalog.FlowOf(s) is TaskFlowKind.ReceiptSplit or TaskFlowKind.IdCard;

    /// <summary>The format the column shows: receipts and the ID card save a PDF or an image, photos an image, else the format.</summary>
    public static OutputFormat ShownFormat(ScanSettings s) =>
        SavesPageFormat(s) ? OutputFormats.PageFormat(s.Format)
        : s.Intent == ScanIntent.Photo ? OutputFormats.ImageFormatOrJpeg(s.Format)
        : s.Format;

    /// <summary>
    /// A save of <paramref name="s"/> writes a PDF, so Archive &amp; password apply: a queue of image pages
    /// too, receipts and the ID card saved as a PDF, and a copy also saved as a PDF; never photos.
    /// </summary>
    public static bool WritesPdf(ScanSettings s)
    {
        if (s.Intent != ScanIntent.Document) return false;
        return TaskCatalog.FlowOf(s) switch
        {
            TaskFlowKind.Copy => s.TaskOptions.CopyAlsoSavePdf,
            TaskFlowKind.ReceiptSplit or TaskFlowKind.IdCard => OutputFormats.PageFormat(s.Format) == OutputFormat.Pdf,
            _ => OutputFormats.SavesPdf(s.Format, s.DocumentMultiPage),
        };
    }

    /// <summary>Also save text applies: document pages collected or saved as a PDF, and receipts saved as PDFs.</summary>
    public static bool TextApplies(ScanSettings s)
    {
        if (s.Intent != ScanIntent.Document) return false;
        var flow = TaskCatalog.FlowOf(s);
        if (flow == TaskFlowKind.ReceiptSplit) return OutputFormats.PageFormat(s.Format) == OutputFormat.Pdf;
        return flow == TaskFlowKind.DocumentQueue && OutputFormats.SavesPdf(s.Format, s.DocumentMultiPage);
    }

    /// <summary>The summary a collapsed header shows for <paramref name="s"/>; "" for none (the task's section has none).</summary>
    public static string Summary(string section, ScanSettings s) => section switch
    {
        Scanner => ScannerSummary(s),
        Output => OutputSummary(s, ShownFormat(s)),
        Adjustments => AdjustmentsSummary(s.Adjustments),
        Pages => PagesSummary(s.Document),
        Split => SplitSummary(s.Document),
        Archive => ArchiveSummary(s.Output),
        More => MoreSummary(s.Output, TextApplies(s)),
        _ => "",
    };

    /// <summary>Something in the section differs from the default for <paramref name="s"/> (the collapsed header's dot).</summary>
    public static bool Changed(string section, ScanSettings s) => section switch
    {
        Scanner => ScannerChanged(s),
        Output => OutputChanged(s, ShownFormat(s)),
        Split => s.Document.SplitMode != SplitMode.None,
        Archive => s.Output.Protect || s.Output.Archival,
        Task => false,
        _ => Summary(section, s).Length > 0,
    };

    /// <summary>The header's accessible name for <paramref name="s"/>: Pages counts its options, the others are <see cref="HeaderName"/>.</summary>
    public static string AccessibleName(string section, ScanSettings s) =>
        section == Pages ? PagesHeaderName(s.Document) : HeaderName(Title(section, s), Summary(section, s));
}
