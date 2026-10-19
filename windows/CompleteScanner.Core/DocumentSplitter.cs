using System.Globalization;

namespace CompleteScanner.Core;

// Twin of Sources/CompleteScannerKit/Core/DocumentSplitter.swift.

/// <summary>What saving does with a queued page (<see cref="DocumentSplitter.Plan(IReadOnlyList{PageFacts}, DocumentOptions)"/>).</summary>
public enum PageRole
{
    /// <summary>Saved, in its document.</summary>
    Content,
    /// <summary>Left out: blank with Skip blank pages on, or skipped by the user (<see cref="PageFilter"/>).</summary>
    Skipped,
    /// <summary>Left out: a side of a separator sheet; the next page starts a new document.</summary>
    Separator,
}

/// <summary>
/// What the split looks at on a queued page: its sheet and side (two-sided scans), whether it
/// looks blank at the chosen sensitivity, the patch code found on it, and the user's keep or skip,
/// document break and document name.
/// </summary>
public sealed record PageFacts(int? SheetIndex = null, PageSide? Side = null, bool LooksBlank = false,
                               PatchCode? Patch = null, PageInclusion Inclusion = PageInclusion.Automatic,
                               DocumentBreak Break = DocumentBreak.Automatic, string? Label = null)
{
    /// <summary>The facts of <paramref name="page"/> under <paramref name="options"/> (its blank-page sensitivity).</summary>
    public static PageFacts Of(ScannedPage page, DocumentOptions options) =>
        new(page.SheetIndex, page.Side, PageFilter.LooksBlank(page, options.BlankSensitivity), page.Patch,
            page.Inclusion, page.DocumentBreak, page.DocumentLabel);
}

/// <summary>
/// A queued page in the plan: what saving does with it, the sheet it is on (0 = the queue's first),
/// its document (numbered from 1; null for a page left out) and whether it is that document's first page.
/// </summary>
public sealed record PlannedPage(PageRole Role, int Sheet, int? Document, bool StartsDocument);

/// <summary>A document saving writes: its number (from 1), its pages (queue indices, in order) and its name, if any.</summary>
public sealed record PlannedDocument(int Number, IReadOnlyList<int> Pages, string? Label);

/// <summary>The documents the queue is saved as, and what happens to each queued page.</summary>
public sealed record SplitPlan(IReadOnlyList<PlannedPage> Pages, IReadOnlyList<PlannedDocument> Documents)
{
    /// <summary>Pages left out as sides of separator sheets.</summary>
    public int SeparatorCount => Pages.Count(p => p.Role == PageRole.Separator);

    /// <summary>Pages left out as blank or skipped by the user.</summary>
    public int SkippedCount => Pages.Count(p => p.Role == PageRole.Skipped);

    /// <summary>Pages saving writes.</summary>
    public int PageCount => Documents.Sum(d => d.Pages.Count);

    /// <summary>The queue is saved as more than one document.</summary>
    public bool IsSplit => Documents.Count > 1;
}

/// <summary>
/// Splits the collected pages into separate documents (<see cref="DocumentOptions.SplitMode"/>)
/// and lets the user adjust where. Nothing is removed from the queue: the page strip shows the
/// plan (separator pages flagged and dimmed, a divider where each document starts), one click on a
/// page keeps a separator page as content or skips a page, one click on the gap before a page
/// starts a new document there or joins it to the one before, and only saving acts on the plan.
///
/// The rules, over the queue in order. A sheet is a front with its back right after it (two-sided
/// scans, the same sheet index), otherwise a page on its own. At separator sheets: a sheet with a
/// patch code on either side is a separator; both its sides are left out and the next page saved
/// starts a new document. At blank sheets: a sheet blank on every side is a separator (one-sided:
/// each blank page; two-sided: only a sheet blank on both sides, so the blank back of a printed
/// sheet is no separator and follows Skip blank pages). Separators in a row count once, and
/// documents left with no page are dropped. Every N sheets: a new document starts at every Nth
/// sheet, counting every sheet, blank ones too. A page the user keeps makes its sheet no
/// separator; the user's split or join at a page wins over the setting.
/// </summary>
public static class DocumentSplitter
{
    /// <summary>The most sheets per document for <see cref="SplitMode.SheetCount"/>.</summary>
    public const int MaxSheetCount = 999;

    /// <summary>The sheet count as used: 1 to <see cref="MaxSheetCount"/>.</summary>
    public static int ClampSheetCount(int count) => Math.Clamp(count, 1, MaxSheetCount);

    /// <summary>
    /// The sheet each page is on, counted from 0: a front followed by its back (the same sheet
    /// index) share a sheet; every other page is a sheet of its own.
    /// </summary>
    public static IReadOnlyList<int> Sheets(IReadOnlyList<PageFacts> facts)
    {
        var sheets = new int[facts.Count];
        int sheet = -1;
        for (int i = 0; i < facts.Count; i++)
        {
            bool backOfPrevious = i > 0 && facts[i].Side == PageSide.Back && facts[i - 1].Side == PageSide.Front
                                  && facts[i].SheetIndex is { } index && facts[i - 1].SheetIndex == index;
            if (!backOfPrevious) sheet += 1;
            sheets[i] = sheet;
        }
        return sheets;
    }

    /// <summary>The plan of <paramref name="pages"/> under <paramref name="options"/>.</summary>
    public static SplitPlan Plan(IReadOnlyList<ScannedPage> pages, DocumentOptions options) =>
        Plan(pages.Select(p => PageFacts.Of(p, options)).ToList(), options);

    /// <summary>The documents saving writes and what it does with each page (see the class remarks for the rules).</summary>
    public static SplitPlan Plan(IReadOnlyList<PageFacts> facts, DocumentOptions options)
    {
        var sheets = Sheets(facts);
        var mode = options.SplitMode;
        int perDocument = ClampSheetCount(options.SplitSheetCount);

        // Which sheets are separators.
        int sheetCount = facts.Count == 0 ? 0 : sheets[^1] + 1;
        var separator = new bool[sheetCount];
        if (mode is SplitMode.SeparatorSheet or SplitMode.BlankSheet)
        {
            var kept = new bool[sheetCount];
            var patch = new bool[sheetCount];
            var allBlank = Enumerable.Repeat(true, sheetCount).ToArray();
            for (int i = 0; i < facts.Count; i++)
            {
                int s = sheets[i];
                if (facts[i].Inclusion == PageInclusion.Keep) kept[s] = true;
                if (facts[i].Patch is not null) patch[s] = true;
                if (!facts[i].LooksBlank) allBlank[s] = false;
            }
            for (int s = 0; s < sheetCount; s++)
            {
                separator[s] = !kept[s] && (mode == SplitMode.SeparatorSheet ? patch[s] : allBlank[s]);
            }
        }

        var pages = new PlannedPage[facts.Count];
        var documents = new List<(List<int> Pages, string? Label)>();
        bool pending = false;
        int ordinal = 0;
        for (int i = 0; i < facts.Count; i++)
        {
            var fact = facts[i];
            int sheet = sheets[i];
            bool firstOfSheet = i == 0 || sheets[i - 1] != sheet;
            if (separator[sheet])
            {
                pages[i] = new PlannedPage(PageRole.Separator, sheet, null, false);
                pending = true;
                continue;
            }
            if (mode == SplitMode.SheetCount && firstOfSheet)
            {
                if (ordinal > 0 && ordinal % perDocument == 0) pending = true;
                ordinal += 1;
            }
            bool skipped = fact.Inclusion switch
            {
                PageInclusion.Keep => false,
                PageInclusion.Skip => true,
                _ => options.RemoveBlankPages && fact.LooksBlank,
            };
            if (skipped)
            {
                pages[i] = new PlannedPage(PageRole.Skipped, sheet, null, false);
                continue;
            }
            bool starts = documents.Count == 0
                          || fact.Break == DocumentBreak.Split
                          || (pending && fact.Break != DocumentBreak.Join);
            if (starts) documents.Add(([], null));
            var current = documents[^1];
            current.Pages.Add(i);
            if (current.Label is null && Cleaned(fact.Label) is { } label) documents[^1] = (current.Pages, label);
            pages[i] = new PlannedPage(PageRole.Content, sheet, documents.Count, starts);
            pending = false;
        }
        var planned = documents.Select((d, n) => new PlannedDocument(n + 1, d.Pages, d.Label)).ToList();
        return new SplitPlan(pages, planned);
    }

    /// <summary>The longest document name, in characters: a longer one is cut (<see cref="Cleaned"/>).</summary>
    public const int MaxLabelLength = 100;

    /// <summary>
    /// A document name as used: trimmed, and cut to <see cref="MaxLabelLength"/> characters (never
    /// inside one); null when nothing is left.
    /// </summary>
    public static string? Cleaned(string? label)
    {
        string trimmed = label?.Trim() ?? "";
        var text = new StringInfo(trimmed);
        if (text.LengthInTextElements > MaxLabelLength) trimmed = text.SubstringByTextElements(0, MaxLabelLength).TrimEnd();
        return trimmed.Length == 0 ? null : trimmed;
    }

    /// <summary>
    /// The pages' document names after a change from <paramref name="before"/> to
    /// <paramref name="after"/> (one page's inclusion or document break): a document whose first
    /// saved page changed, because that page is now left out or a page before it is now saved,
    /// keeps the name it showed, now held on its new first page, and the old first page's name is
    /// cleared. Otherwise a page keeps its name, also while it is left out, so a document that is
    /// gone comes back with its name, and a document split off another has the name its own first
    /// page holds. Returns the labels of <paramref name="after"/>, changed where needed; both lists
    /// hold the same pages in the same order.
    /// </summary>
    public static IReadOnlyList<string?> CarriedLabels(IReadOnlyList<PageFacts> before, IReadOnlyList<PageFacts> after,
                                                       DocumentOptions options) =>
        CarriedLabels(before, options, after, options);

    /// <summary>
    /// The same after a change of the settings too (Skip blank pages, what counts as blank, the
    /// split): <paramref name="before"/> is planned under <paramref name="beforeOptions"/>,
    /// <paramref name="after"/> under <paramref name="options"/>. A name goes to one document only:
    /// the first that holds a page of the document it named.
    /// </summary>
    public static IReadOnlyList<string?> CarriedLabels(IReadOnlyList<PageFacts> before, DocumentOptions beforeOptions,
                                                       IReadOnlyList<PageFacts> after, DocumentOptions options)
    {
        var labels = after.Select(f => f.Label).ToArray();
        if (before.Count != after.Count) return labels;
        var old = Plan(before, beforeOptions);
        var now = Plan(after, options);
        var carried = new HashSet<int>();
        foreach (var document in now.Documents)
        {
            int first = document.Pages[0];
            if (old.Pages[first].StartsDocument) continue;
            // The document as it was: the one its first page that was saved before was in.
            int kept = -1;
            foreach (int page in document.Pages)
            {
                if (old.Pages[page].Role == PageRole.Content)
                {
                    kept = page;
                    break;
                }
            }
            if (kept < 0 || old.Pages[kept].Document is not { } number) continue;
            var was = old.Documents[number - 1];
            int oldFirst = was.Pages[0];
            // That document still starts where it did: this one is split off it.
            if (now.Pages[oldFirst].StartsDocument) continue;
            // A split chosen since can leave its pages in several documents: the first takes the name.
            if (!carried.Add(number)) continue;
            labels[first] = was.Label;
            labels[oldFirst] = null;
        }
        return labels;
    }

    /// <summary>
    /// Skip blank pages has no say: one-sided (<paramref name="sides"/> is <see cref="DuplexMode.Off"/>)
    /// at blank sheets, every blank page is a separator, which splits the stack and is left out.
    /// </summary>
    public static bool BlankPagesAreSeparators(DocumentOptions options, DuplexMode sides) =>
        options.SplitMode == SplitMode.BlankSheet && sides == DuplexMode.Off;

    /// <summary>Why Skip blank pages is off while <see cref="BlankPagesAreSeparators"/> holds.</summary>
    public const string BlankPagesAreSeparatorsHint =
        "Each blank page splits the stack into documents and is left out: Split into documents is At blank sheets.";

    /// <summary>
    /// Whether a click on the gap before page <paramref name="index"/> can split or join there: a
    /// page saved, other than the first page saved.
    /// </summary>
    public static bool CanToggleBreak(SplitPlan plan, int index) =>
        index >= 0 && index < plan.Pages.Count && plan.Pages[index] is { Role: PageRole.Content } page
        && !(page.Document == 1 && page.StartsDocument);

    /// <summary>
    /// The document break after one click on the gap before page <paramref name="index"/>: a new
    /// document starts there, or no longer does. A click that agrees with the setting goes back to
    /// <see cref="DocumentBreak.Automatic"/>, so two clicks undo one. Unchanged where
    /// <see cref="CanToggleBreak"/> says no.
    /// </summary>
    public static DocumentBreak ToggledBreak(IReadOnlyList<PageFacts> facts, int index, DocumentOptions options)
    {
        var plan = Plan(facts, options);
        if (!CanToggleBreak(plan, index)) return facts[index].Break;
        bool want = !plan.Pages[index].StartsDocument;
        var automatic = facts.ToList();
        automatic[index] = facts[index] with { Break = DocumentBreak.Automatic };
        var page = Plan(automatic, options).Pages[index];
        bool automaticStarts = page.StartsDocument && page.Document != 1;
        if (want == automaticStarts) return DocumentBreak.Automatic;
        return want ? DocumentBreak.Split : DocumentBreak.Join;
    }

    /// <summary>
    /// The inclusion after one click on page <paramref name="index"/>: the opposite of what saving
    /// would do now (a separator page kept is saved, and its sheet no longer splits). A click that
    /// agrees with the settings goes back to <see cref="PageInclusion.Automatic"/>, so two clicks
    /// undo one. Like <see cref="PageFilter.Toggled"/>, with separator sheets.
    /// </summary>
    public static PageInclusion ToggledInclusion(IReadOnlyList<PageFacts> facts, int index, DocumentOptions options)
    {
        bool excludedNow = Plan(facts, options).Pages[index].Role != PageRole.Content;
        var automatic = facts.ToList();
        automatic[index] = facts[index] with { Inclusion = PageInclusion.Automatic };
        bool automaticExcluded = Plan(automatic, options).Pages[index].Role != PageRole.Content;
        bool excludeNow = !excludedNow;
        if (excludeNow == automaticExcluded) return PageInclusion.Automatic;
        return excludeNow ? PageInclusion.Skip : PageInclusion.Keep;
    }

    /// <summary>The page strip shows where documents start: a split mode is chosen, or the user split the queue.</summary>
    public static bool ShowsBreaks(SplitPlan plan, DocumentOptions options) =>
        options.SplitMode != SplitMode.None || plan.IsSplit;

    /// <summary>"Document 2", or "Document 2 · Invoice 0042" when it has a name.</summary>
    public static string DocumentTitle(PlannedDocument document) =>
        document.Label is { } label ? $"Document {document.Number} · {label}" : $"Document {document.Number}";

    /// <summary>
    /// The title over page <paramref name="index"/> when it starts a document and the queue is
    /// saved as several (<see cref="DocumentTitle"/>); null otherwise.
    /// </summary>
    public static string? DividerTitle(SplitPlan plan, int index) =>
        plan.IsSplit && plan.Pages[index] is { StartsDocument: true, Document: { } number }
            ? DocumentTitle(plan.Documents[number - 1])
            : null;

    /// <summary>
    /// What a click on the gap before page <paramref name="index"/> does: "Join with document 1" where
    /// a document starts, "Start a new document here" elsewhere; null where it does nothing.
    /// </summary>
    public static string? BreakLabel(SplitPlan plan, int index)
    {
        if (!CanToggleBreak(plan, index)) return null;
        var page = plan.Pages[index];
        return page.StartsDocument ? $"Join with document {page.Document - 1}" : "Start a new document here";
    }

    /// <summary>
    /// The page strip's note on page <paramref name="index"/>: "Separator" for a side of a
    /// separator sheet, otherwise <see cref="PageFilter.Badge"/>.
    /// </summary>
    public static string? Badge(SplitPlan plan, int index, ScannedPage page, DocumentOptions options) =>
        plan.Pages[index].Role == PageRole.Separator ? "Separator" : PageFilter.Badge(page, options);

    /// <summary>
    /// What one click on page <paramref name="index"/> does: "Keep this page" for a separator page,
    /// otherwise <see cref="PageFilter.ToggleLabel"/>.
    /// </summary>
    public static string? ToggleLabel(SplitPlan plan, int index, ScannedPage page, DocumentOptions options) =>
        plan.Pages[index].Role == PageRole.Separator ? "Keep this page" : PageFilter.ToggleLabel(page, options);

    /// <summary>
    /// What a separator page is, for its tooltip and screen readers: "Separator sheet (Patch T): a new
    /// document starts after it. It is not saved." (the code when one was found); null for other pages.
    /// </summary>
    public static string? SeparatorNote(SplitPlan plan, int index, ScannedPage page)
    {
        if (plan.Pages[index].Role != PageRole.Separator) return null;
        string what = page.Patch is { } code ? $"Separator sheet ({code.Label()})" : "Blank separator sheet";
        return $"{what}: a new document starts after it. It is not saved.";
    }

    /// <summary>
    /// "9 pages in queue", "9 pages in queue, 3 documents, 2 separator pages skipped", "24 pages in
    /// queue, 5 blank skipped": <see cref="PageFilter.QueueSummary"/> with documents and separators.
    /// </summary>
    public static string QueueSummary(IReadOnlyList<ScannedPage> pages, DocumentOptions options)
    {
        var plan = Plan(pages, options);
        int total = pages.Count;
        string text = $"{total} page{(total == 1 ? "" : "s")} in queue";
        if (plan.IsSplit) text += $", {plan.Documents.Count} documents";
        int separators = plan.SeparatorCount;
        var skipped = Enumerable.Range(0, pages.Count).Where(i => plan.Pages[i].Role == PageRole.Skipped).ToList();
        bool allBlank = skipped.All(i => PageFilter.LooksBlank(pages[i], options.BlankSensitivity));
        string skippedText = $"{skipped.Count}{(allBlank ? " blank" : "")}";
        string separatorText = $"{separators} separator page{(separators == 1 ? "" : "s")}";
        if (separators > 0 && skipped.Count > 0) return $"{text}, {separatorText} and {skippedText} skipped";
        if (separators > 0) return $"{text}, {separatorText} skipped";
        if (skipped.Count > 0) return $"{text}, {skippedText} skipped";
        return text;
    }

    /// <summary>
    /// The status after a scan's pages were queued: " Found 2 separator pages: 3 documents to
    /// save." when the scan brought separator pages, " 3 documents to save." when the queue is split
    /// otherwise (leading space); empty when it is one document.
    /// </summary>
    public static string ScanNote(SplitPlan plan, int separatorsAdded)
    {
        int documents = plan.Documents.Count;
        string toSave = $"{documents} document{(documents == 1 ? "" : "s")} to save.";
        if (separatorsAdded > 0) return $" Found {separatorsAdded} separator page{(separatorsAdded == 1 ? "" : "s")}: {toSave}";
        return plan.IsSplit ? $" {toSave}" : "";
    }
}
