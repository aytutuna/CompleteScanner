using System.Text.RegularExpressions;
using CompleteScanner.Core;

namespace CompleteScanner.App;

/// <summary>
/// The short visible texts of the Windows layout that have no home in Core yet: disabled reasons,
/// consequence lines and state chips. Their wording follows the text spec; the ones shared with the
/// Mac move into Core (with Swift twins) when the shared strings are shortened.
/// </summary>
internal static class ShortText
{
    /// <summary>Sides on the flatbed of a scanner that has a feeder.</summary>
    public const string NeedsFeeder = "Needs the feeder";
    /// <summary>Split facing pages while both sides of each sheet are scanned.</summary>
    public const string NotWithTwoSided = "Not with two-sided";
    /// <summary>Page clean-up and splitting while each scan is saved at once.</summary>
    public const string NeedsCollectPages = "Needs Collect pages";
    /// <summary>Under What counts as blank, at High.</summary>
    public const string CheckFlaggedPages = "Check flagged pages before saving";
    /// <summary>Under Paper size, while an area of the preview is selected.</summary>
    public const string UsingSelectedArea = "Using the selected area";
    /// <summary>The overlay while photo files are dragged over the window.</summary>
    public const string DropToAddPages = "Drop to add as pages";
    /// <summary>The chip on a preview until an area is selected.</summary>
    public const string DragToSelect = "Drag to select an area";
    /// <summary>The empty stage's line without a task.</summary>
    public const string PlaceOriginal = "Place the original face down, then select Scan.";
    /// <summary>The one-line consequences of each way of splitting a stack.</summary>
    public const string SeparatorSheetsLeftOut = "Separator sheets are left out";
    public const string BlankSheetsLeftOut = "Blank sheets are left out";
    public const string CodeSheetsLeftOut = "Sheets are left out";
    public const string CodePagesKept = "Pages are kept";
    /// <summary>The ID card review's privacy line.</summary>
    public const string NotKeptInHistory = "Not kept in Scans history";
    /// <summary>The page strip's badge on a spread kept whole.</summary>
    public const string NotSplit = "Not split";
    /// <summary>A start-screen tile whose task needs a scanner with a feeder, or a printer.</summary>
    public const string NeedsDocumentFeeder = "Needs a document feeder";
    public const string NeedsPrinter = "Needs a printer";
    /// <summary>Skip blank pages while blank sheets split the stack into documents.</summary>
    public const string BlankSheetsSplit = "Blank sheets split documents";
    /// <summary>Receipts in one PDF, while they are saved as images.</summary>
    public const string OnlyForPdfs = "Only for PDFs";
    /// <summary>Name by receipt date while the file name has no {docdate}: the receipt's date is not used.</summary>
    public const string NeedsDocDate = "Needs {docdate} in File name";
}

/// <summary>Splits a sentence or two into the line shown and the rest, which goes behind an ⓘ or into a tooltip.</summary>
internal static class TextSplit
{
    /// <summary>
    /// The first sentence (or the clause before a colon or semicolon) of <paramref name="text"/>,
    /// ending with its full stop or question mark, and the rest (More) with its first letter capitalized
    /// ("" when there is none). A full stop counts only before a capital letter or a digit, and not at the end of an abbreviation, so
    /// "e.g. 192.168.1.50" is not cut.
    /// </summary>
    public static (string Lead, string More) Lead(string text)
    {
        text = text.Trim();
        for (int i = 0; i < text.Length - 2; i++)
        {
            char c = text[i];
            if (text[i + 1] != ' ') continue;
            char next = text[i + 2];
            // "e.g. 192…": a full stop two characters after another one ends an abbreviation, not a sentence.
            bool abbreviation = c == '.' && i >= 2 && text[i - 2] == '.';
            bool sentenceEnd = (c is '.' or '?' or '!') && !abbreviation && (char.IsUpper(next) || char.IsDigit(next));
            bool clauseEnd = c is ':' or ';';
            if (!sentenceEnd && !clauseEnd) continue;
            string lead = clauseEnd ? text[..i] + "." : text[..(i + 1)];
            string rest = text[(i + 2)..].Trim();
            return (lead, Capitalize(rest));
        }
        return (text, "");
    }

    private static string Capitalize(string text) =>
        text.Length == 0 ? text : char.ToUpperInvariant(text[0]) + text[1..];
}

/// <summary>
/// The status bar's visible text: at most <see cref="MaxWords"/> words, facts only. The full
/// sentence stays the status bar's accessible name, so screen readers hear all of it.
/// </summary>
internal static class StatusLine
{
    public const int MaxWords = 6;

    private static readonly Regex WordToken = new(@"[\p{L}\p{N}]", RegexOptions.Compiled);

    /// <summary>Words as the text spec counts them: whitespace-separated tokens with a letter or digit.</summary>
    public static int Words(string text) =>
        text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Count(t => WordToken.IsMatch(t));

    /// <summary>
    /// The sentences <see cref="SettingsAdapter"/> adds when a setting had to change for the scanner,
    /// each with its short form: a warning stays visible, not only in the accessible name.
    /// </summary>
    private static readonly (Regex Note, string Short)[] SettingsNotes =
    [
        (new(@"This scanner has no flatbed, so the document feeder is used\."), "Feeder used"),
        (new(@"This scanner has no document feeder, so the flatbed is used\."), "Flatbed used"),
        (new(@"This scanner's feeder scans one side at a time, so you'll turn the stack over by hand\."), "Two-sided by hand"),
        (new($@"(?:{string.Join("|", Enum.GetValues<PaperSize>().Select(p => Regex.Escape(p.Label())))}) paper does not fit this scanner's (?:feeder|glass), so the paper size is Automatic\."),
         "Paper size Automatic"),
        (new(@"This scanner does not offer \d+ dpi, so (\d+) dpi is used\."), "$1 dpi used"),
    ];

    /// <summary>A two-sided scan came back with one side of each sheet.</summary>
    private const string OneSidedMark = "the scanner did not scan both sides";
    private const string OneSidedShort = "One side only";

    /// <param name="message">The view model's status sentence.</param>
    /// <param name="deviceName">The connected scanner, for "Ready — Demo Scanner" after a task is picked.</param>
    /// <remarks>
    /// A setting changed for the scanner, or a two-sided scan that came back one-sided, keeps a short
    /// warning on the line ("Ready — Demo · feeder used", "3 pages added · one side only"); when the
    /// line can't hold both, the warnings win.
    /// </remarks>
    public static string Short(string message, string? deviceName = null)
    {
        string text = message.Trim();
        if (text.Length == 0) return "";
        var (shorts, notesAt) = FindWarnings(text);
        string head = notesAt > 0 ? Head(text[..notesAt].Trim(), deviceName) : "";
        return Compose(head, shorts);
    }

    /// <summary>
    /// <paramref name="head"/> with the short warnings found in <paramref name="message"/>, the same
    /// way <see cref="Short"/> adds them: "Saved · 600 dpi used", or the warnings alone when the line
    /// can't hold both; just <paramref name="head"/> when there are none.
    /// </summary>
    public static string WithWarnings(string head, string message) => Compose(head, Warnings(message));

    /// <summary>
    /// The short warnings in <paramref name="message"/>, in the order they come: a setting changed for
    /// the scanner ("600 dpi used"), a two-sided scan that came back one-sided ("One side only").
    /// </summary>
    public static IReadOnlyList<string> Warnings(string message) => FindWarnings(message.Trim()).Shorts;

    /// <summary>The warnings in <paramref name="text"/>, and where the first settings note starts (the text's length when none does).</summary>
    private static (List<string> Shorts, int NotesAt) FindWarnings(string text)
    {
        // The notes are appended after the message: the message is what comes before the first one.
        var warnings = new List<(int At, string Short)>();
        int notesAt = text.Length;
        foreach (var (note, shortForm) in SettingsNotes)
        {
            foreach (Match m in note.Matches(text))
            {
                warnings.Add((m.Index, m.Result(shortForm)));
                notesAt = Math.Min(notesAt, m.Index);
            }
        }
        int oneSided = text.IndexOf(OneSidedMark, StringComparison.Ordinal);
        if (oneSided >= 0) warnings.Add((oneSided, OneSidedShort));
        return (warnings.OrderBy(w => w.At).Select(w => w.Short).ToList(), notesAt);
    }

    /// <summary>The head, then the warnings while they fit; when the line can't hold both, the warnings win.</summary>
    private static string Compose(string head, IReadOnlyList<string> shorts)
    {
        if (shorts.Count == 0) return head;
        if (head.Length > 0)
        {
            string all = string.Join(" · ", shorts.Select(LowerFirst).Prepend(head));
            if (Words(all) <= MaxWords) return all;
        }
        // Not room for the message too: the warnings alone, as many as fit, then how many more.
        string shown = shorts[0];
        int i = 1;
        while (i < shorts.Count)
        {
            string next = $"{shown} · {LowerFirst(shorts[i])}";
            // While more would follow, keep a word free for "+N".
            if (Words(next) > MaxWords - (i < shorts.Count - 1 ? 1 : 0)) break;
            shown = next;
            i++;
        }
        return i < shorts.Count ? $"{shown} +{shorts.Count - i}" : shown;
    }

    /// <summary>"Feeder used" after a message reads "… · feeder used"; "300 dpi used" stays as it is.</summary>
    private static string LowerFirst(string text) =>
        text.Length > 0 && char.IsUpper(text[0]) ? char.ToLowerInvariant(text[0]) + text[1..] : text;

    /// <summary>The short form of the message itself (without the notes after it).</summary>
    private static string Head(string text, string? deviceName)
    {
        if (text.Length == 0) return "";
        if (text.StartsWith("Ready for “", StringComparison.Ordinal))
        {
            return deviceName is { Length: > 0 } name ? $"Ready — {name}" : "Ready";
        }
        if (Regex.Match(text, @"^Added (\d+) (?:page|pages)\b") is { Success: true } added)
        {
            int count = int.Parse(added.Groups[1].Value);
            string head = count == 1 && Regex.Match(text, @"— (\d+) in queue") is { Success: true } queue
                ? $"Page {queue.Groups[1].Value} added"
                : $"{count} {(count == 1 ? "page" : "pages")} added";
            if (Regex.Match(text, @"(\d+) looks? blank") is { Success: true } blank)
            {
                head = Append(head, $"{blank.Groups[1].Value} blank");
            }
            if (Regex.Match(text, @"(\d+) (spreads?) split into pages") is { Success: true } spreads)
            {
                head = Append(head, $"{spreads.Groups[1].Value} {spreads.Groups[2].Value} split");
            }
            return head;
        }
        if (Regex.Match(text, @"^(?:Cancelled — )?Saved (\d+) (photos?|receipts?|documents?|files?|PDFs?|copies)\b",
                        RegexOptions.IgnoreCase) is { Success: true } savedMany)
        {
            return $"Saved {savedMany.Groups[1].Value} {savedMany.Groups[2].Value}";
        }
        if (text.StartsWith("Saved ", StringComparison.Ordinal)) return "Saved";
        if (Regex.Match(text, @"^Found (\d+) (photos?|receipts?)\b") is { Success: true } found)
        {
            return $"Found {found.Groups[1].Value} {found.Groups[2].Value}";
        }
        if (text.StartsWith("Page queue cleared", StringComparison.Ordinal)) return "Queue cleared";
        if (Regex.Match(text, @"^Reading the text of page (\d+)( of \d+)?…") is { Success: true } reading)
        {
            return $"Reading page {reading.Groups[1].Value}{reading.Groups[2].Value}…";
        }
        if (Regex.Match(text, @"^Adding (\d+) (pages?) to .+…$") is { Success: true } adding)
        {
            return $"Adding {adding.Groups[1].Value} {adding.Groups[2].Value}…";
        }
        if (text.StartsWith("Sent ", StringComparison.Ordinal)) return "Sent to the printer";

        // Anything else: its first sentence, then what comes before a dash or a colon.
        string first = FirstSentence(text);
        if (Words(first) <= MaxWords) return first;
        foreach (string mark in new[] { " — ", ": ", ", " })
        {
            int at = first.IndexOf(mark, StringComparison.Ordinal);
            if (at > 0 && Words(first[..at]) <= MaxWords) return first[..at];
        }
        var tokens = first.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        var kept = new List<string>();
        int words = 0;
        foreach (var token in tokens)
        {
            if (WordToken.IsMatch(token) && ++words > MaxWords) break;
            kept.Add(token);
        }
        return string.Join(' ', kept).TrimEnd(',', ':', ';', '.', ' ') + "…";
    }

    /// <summary>"6 pages added · 1 blank", while the words stay within the limit.</summary>
    private static string Append(string head, string part)
    {
        string joined = $"{head} · {part}";
        return Words(joined) <= MaxWords ? joined : head;
    }

    /// <summary>The first sentence without its full stop ("…" is kept: it says work is under way).</summary>
    private static string FirstSentence(string text)
    {
        for (int i = 0; i < text.Length - 2; i++)
        {
            if (text[i] is '.' or '!' or '?' && text[i + 1] == ' ' && (char.IsUpper(text[i + 2]) || char.IsDigit(text[i + 2])))
            {
                return text[..i];
            }
        }
        return text.EndsWith('.') && !text.EndsWith("…", StringComparison.Ordinal) ? text[..^1] : text;
    }
}

/// <summary>A step of a task in one word, for the banner's step indicator: "Front side" and "Scan the front sides" are "Front".</summary>
internal static class StepWords
{
    public static string Of(string title)
    {
        string t = title.Trim();
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

/// <summary>The page strip's side badge of a page of a two-sided stack: "1 · front", named "Sheet 1, front".</summary>
internal static class SideBadge
{
    public static string? Text(PageSide? side, int? sheetIndex) => side switch
    {
        null => null,
        { } s when sheetIndex is { } sheet => $"{sheet + 1} · {SideWord(s)}",
        PageSide.Front => "Front",
        _ => "Back",
    };

    public static string? Name(PageSide? side, int? sheetIndex) => side switch
    {
        null => null,
        { } s when sheetIndex is { } sheet => $"Sheet {sheet + 1}, {SideWord(s)}",
        PageSide.Front => "Front",
        _ => "Back",
    };

    private static string SideWord(PageSide side) => side == PageSide.Front ? "front" : "back";
}

/// <summary>The start screen's groups of tasks, in order. Every task is in exactly one group.</summary>
internal static class TaskGroups
{
    public sealed record Group(string Title, IReadOnlyList<ScanTask> Tasks);

    public static IReadOnlyList<Group> All { get; } =
    [
        new("Documents", [ScanTask.Document, ScanTask.Feeder, ScanTask.TwoSided, ScanTask.Batch, ScanTask.Word,
                          ScanTask.Email, ScanTask.Archive]),
        new("Photos & images", [ScanTask.Photos, ScanTask.PhotoRestore, ScanTask.QuickScan]),
        new("Other", [ScanTask.IdCard, ScanTask.Copy, ScanTask.Receipt, ScanTask.Book]),
    ];

    public static string TitleOf(ScanTask task) => All.First(g => g.Tasks.Contains(task)).Title;
}

/// <summary>The inspector's sections, their default open state and the summary a collapsed header shows.</summary>
internal static class InspectorSummary
{
    public const string Task = "task";
    public const string Scanner = "scanner";
    public const string Output = "output";
    public const string Adjustments = "adjustments";
    public const string Pages = "pages";
    public const string Split = "split";
    public const string Archive = "archive";
    public const string More = "more";

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

    public static bool ScannerChanged(ScanSettings s) =>
        s.Source != Defaults.Source || s.Duplex != Defaults.Duplex || s.PaperSize != Defaults.PaperSize
        || s.Resolution != Defaults.Resolution || s.ColorMode != Defaults.ColorMode;

    /// <summary>"PDF · Standard", "Word", "JPEG": the format the save uses, and a PDF's size.</summary>
    /// <param name="shownFormat">The format the inspector shows (photos save an image, receipts a PDF or an image).</param>
    public static string OutputSummary(ScanSettings s, OutputFormat shownFormat)
    {
        string format = shownFormat switch { OutputFormat.Word => "Word", OutputFormat.Text => "Text", var f => f.Label() };
        return shownFormat == OutputFormat.Pdf && s.Intent == ScanIntent.Document ? $"{format} · {s.Output.PdfSize.Label()}" : format;
    }

    public static bool OutputChanged(ScanSettings s, OutputFormat shownFormat) =>
        shownFormat != Defaults.Format || s.Output.PdfSize != Defaults.Output.PdfSize;

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
    public static string SplitSummary(DocumentOptions d) => d.SplitMode switch
    {
        SplitMode.SeparatorSheet => "Separator sheets",
        SplitMode.BlankSheet => "Blank sheets",
        SplitMode.SheetCount => $"Every {DocumentSplitter.ClampSheetCount(d.SplitSheetCount)} sheet{(DocumentSplitter.ClampSheetCount(d.SplitSheetCount) == 1 ? "" : "s")}",
        SplitMode.Barcode => "QR codes",
        _ => "Off",
    };

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
}
