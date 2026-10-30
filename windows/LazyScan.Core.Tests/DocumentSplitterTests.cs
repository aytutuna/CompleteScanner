using LazyScan.Core;
using Xunit;

namespace LazyScan.Core.Tests;

// Twin of Tests/CompleteScannerTests/DocumentSplitterTests.swift: the same cases.

public class DocumentSplitterTests
{
    private static readonly PageFacts Page = new();
    private static readonly PageFacts Blank = new(LooksBlank: true);
    private static readonly PageFacts Patch = new(Patch: PatchCode.PatchT);

    private static PageFacts Front(int sheet, bool blank = false, PatchCode? patch = null) =>
        new(sheet, PageSide.Front, blank, patch);

    private static PageFacts Back(int sheet, bool blank = false, PatchCode? patch = null) =>
        new(sheet, PageSide.Back, blank, patch);

    private static DocumentOptions Options(SplitMode mode, bool removeBlankPages = false, int sheets = 1) =>
        new() { SplitMode = mode, RemoveBlankPages = removeBlankPages, SplitSheetCount = sheets };

    private static int[][] Documents(SplitPlan plan) => plan.Documents.Select(d => d.Pages.ToArray()).ToArray();

    private static string Roles(SplitPlan plan) => string.Concat(plan.Pages.Select(p => p.Role switch
    {
        PageRole.Content => 'c',
        PageRole.Skipped => 's',
        _ => 'x',
    }));

    [Fact]
    public void Sheets_AFrontAndItsBackShareASheet()
    {
        Assert.Equal([0, 1, 2], DocumentSplitter.Sheets([Page, Page, Page]));
        Assert.Equal([0, 0, 1, 1, 2], DocumentSplitter.Sheets([Front(0), Back(0), Front(1), Back(1), Front(2)]));
        // A back without its front, or of another sheet, is a sheet of its own.
        Assert.Equal([0, 1, 2, 3], DocumentSplitter.Sheets([Back(0), Front(1), Back(2), Page]));
        Assert.Equal([0, 0, 1, 2], DocumentSplitter.Sheets([Front(0), Back(0), Back(0), Front(0)]));
        Assert.Empty(DocumentSplitter.Sheets([]));
    }

    [Fact]
    public void Off_OneDocument_SkippedPagesAsTheBlankPageSettingSays()
    {
        var facts = new[] { Page, Patch, Blank, Page };
        var plan = DocumentSplitter.Plan(facts, Options(SplitMode.None));
        Assert.Equal([[0, 1, 2, 3]], Documents(plan));
        Assert.Equal("cccc", Roles(plan));
        Assert.False(plan.IsSplit);
        var skipping = DocumentSplitter.Plan(facts, Options(SplitMode.None, removeBlankPages: true));
        Assert.Equal([[0, 1, 3]], Documents(skipping));
        Assert.Equal("ccsc", Roles(skipping));
        Assert.Equal((0, 1, 3), (skipping.SeparatorCount, skipping.SkippedCount, skipping.PageCount));
        Assert.Empty(DocumentSplitter.Plan(new List<PageFacts>(), Options(SplitMode.SeparatorSheet)).Documents);
    }

    [Fact]
    public void SeparatorSheets_OneSided_StartANewDocumentAndAreLeftOut()
    {
        var plan = DocumentSplitter.Plan([Page, Page, Patch, Page, Patch, Page, Page], Options(SplitMode.SeparatorSheet));
        Assert.Equal([[0, 1], [3], [5, 6]], Documents(plan));
        Assert.Equal("ccxcxcc", Roles(plan));
        Assert.Equal([1, 2, 3], plan.Documents.Select(d => d.Number));
        Assert.Equal((2, 0, 5), (plan.SeparatorCount, plan.SkippedCount, plan.PageCount));
        Assert.Equal([true, false, false, true, false, true, false], plan.Pages.Select(p => p.StartsDocument));
        Assert.Equal([1, 1, null, 2, null, 3, 3], plan.Pages.Select(p => p.Document));
        Assert.True(plan.IsSplit);
    }

    [Fact]
    public void SeparatorSheets_TwoSided_TheWholeSheetIsLeftOut_BlankBacksFollowTheSetting()
    {
        // A printed sheet with a blank back, the separator (blank back), a printed sheet both sides.
        var facts = new[] { Front(0), Back(0, blank: true), Front(1, patch: PatchCode.PatchT), Back(1, blank: true), Front(2), Back(2) };
        var plan = DocumentSplitter.Plan(facts, Options(SplitMode.SeparatorSheet, removeBlankPages: true));
        Assert.Equal([[0], [4, 5]], Documents(plan));
        Assert.Equal("csxxcc", Roles(plan));
        Assert.Equal([0, 0, 1, 1, 2, 2], plan.Pages.Select(p => p.Sheet));
        var keepingBlanks = DocumentSplitter.Plan(facts, Options(SplitMode.SeparatorSheet));
        Assert.Equal([[0, 1], [4, 5]], Documents(keepingBlanks));
        // A sheet fed the other way round has its code on the back.
        var turned = new[] { Front(0), Back(0), Front(1, blank: true), Back(1, patch: PatchCode.Patch3), Front(2), Back(2) };
        Assert.Equal([[0, 1], [4, 5]], Documents(DocumentSplitter.Plan(turned, Options(SplitMode.SeparatorSheet))));
    }

    [Fact]
    public void Separators_InARowCountOnce_AndEmptyDocumentsAreDropped()
    {
        var mode = Options(SplitMode.SeparatorSheet);
        Assert.Equal([[2], [5]], Documents(DocumentSplitter.Plan([Patch, Patch, Page, Patch, Patch, Page, Patch], mode)));
        Assert.Equal([[0]], Documents(DocumentSplitter.Plan([Page, Patch], mode)));
        Assert.Empty(DocumentSplitter.Plan([Patch, Patch], mode).Documents);
        // A document of blank pages only, all skipped, is no document.
        Assert.Equal([[0], [4]],
                     Documents(DocumentSplitter.Plan([Page, Patch, Blank, Patch, Page], Options(SplitMode.SeparatorSheet, removeBlankPages: true))));
    }

    [Fact]
    public void BlankSheets_OneSided_EveryBlankPageSplits()
    {
        var facts = new[] { Page, Blank, Page, Blank, Blank, Page };
        foreach (bool remove in new[] { false, true })
        {
            var plan = DocumentSplitter.Plan(facts, Options(SplitMode.BlankSheet, removeBlankPages: remove));
            Assert.Equal([[0], [2], [5]], Documents(plan));
            Assert.Equal("cxcxxc", Roles(plan));
        }
        // A patch code is no separator here.
        Assert.Equal([[0, 1, 2]], Documents(DocumentSplitter.Plan([Page, Patch, Page], Options(SplitMode.BlankSheet))));
    }

    [Fact]
    public void BlankSheets_TwoSided_OnlyASheetBlankOnBothSidesSplits()
    {
        var facts = new[]
        {
            Front(0), Back(0, blank: true),
            Front(1, blank: true), Back(1, blank: true),
            Front(2), Back(2),
            Front(3), Back(3, blank: true),
        };
        var plan = DocumentSplitter.Plan(facts, Options(SplitMode.BlankSheet));
        Assert.Equal([[0, 1], [4, 5, 6, 7]], Documents(plan));
        Assert.Equal("ccxxcccc", Roles(plan));
        var skipping = DocumentSplitter.Plan(facts, Options(SplitMode.BlankSheet, removeBlankPages: true));
        Assert.Equal([[0], [4, 5, 6]], Documents(skipping));
        Assert.Equal("csxxcccs", Roles(skipping));
        // An odd last front that is blank is a sheet blank on every side.
        Assert.Equal([[0, 1]], Documents(DocumentSplitter.Plan([Front(0), Back(0), Front(1, blank: true)], Options(SplitMode.BlankSheet))));
    }

    [Fact]
    public void EveryNSheets_CountsEverySheet_BlankOnesToo()
    {
        Assert.Equal([[0, 1], [2, 3], [4]],
                     Documents(DocumentSplitter.Plan([Page, Page, Page, Page, Page], Options(SplitMode.SheetCount, sheets: 2))));
        Assert.Equal([[0], [1], [2]],
                     Documents(DocumentSplitter.Plan([Page, Page, Page], Options(SplitMode.SheetCount, sheets: 1))));
        // Two-sided: sheets, not pages, are counted; an odd last sheet makes a short document.
        Assert.Equal([[0, 1], [2, 3], [4]],
                     Documents(DocumentSplitter.Plan([Front(0), Back(0), Front(1), Back(1), Front(2)], Options(SplitMode.SheetCount))));
        // A skipped blank page still counts as a sheet; a document whose first sheet is skipped starts at its next page.
        var remove = Options(SplitMode.SheetCount, removeBlankPages: true, sheets: 2);
        Assert.Equal([[0], [2, 3], [4]], Documents(DocumentSplitter.Plan([Page, Blank, Page, Page, Page], remove)));
        Assert.Equal([[0, 1], [3]], Documents(DocumentSplitter.Plan([Page, Page, Blank, Page], remove)));
        // A patch code or a blank sheet is no separator here.
        Assert.Equal([[0, 1], [2]], Documents(DocumentSplitter.Plan([Patch, Blank, Page], Options(SplitMode.SheetCount, sheets: 2))));
        Assert.Equal((1, 999, 1, 999), (DocumentSplitter.ClampSheetCount(0), DocumentSplitter.ClampSheetCount(5000),
                                        DocumentSplitter.ClampSheetCount(-3), DocumentSplitter.ClampSheetCount(999)));
        Assert.Equal([[0], [1], [2]], Documents(DocumentSplitter.Plan([Page, Page, Page], Options(SplitMode.SheetCount, sheets: 0))));
    }

    [Fact]
    public void TheUsersSplitsAndJoinsWin()
    {
        var split = Page with { Break = DocumentBreak.Split };
        var join = Page with { Break = DocumentBreak.Join };
        // A split by hand, with no split chosen.
        Assert.Equal([[0, 1], [2, 3]], Documents(DocumentSplitter.Plan([Page, Page, split, Page], Options(SplitMode.None))));
        // A join where a separator would start a document.
        Assert.Equal([[0, 2, 3]], Documents(DocumentSplitter.Plan([Page, Patch, join, Page], Options(SplitMode.SeparatorSheet))));
        // A split on the first page saved changes nothing.
        Assert.Equal([[0, 1]], Documents(DocumentSplitter.Plan([split, Page], Options(SplitMode.None))));
        // A split on a page left out does not carry over.
        Assert.Equal([[0, 2]], Documents(DocumentSplitter.Plan([Page, Blank with { Break = DocumentBreak.Split }, Page],
                                                               Options(SplitMode.None, removeBlankPages: true))));
        // Every N sheets goes on counting after a join.
        Assert.Equal([[0, 1, 2, 3], [4, 5]],
                     Documents(DocumentSplitter.Plan([Page, Page, join, Page, Page, Page], Options(SplitMode.SheetCount, sheets: 2))));
    }

    [Fact]
    public void ToggledBreak_TwoClicksUndoOne()
    {
        var options = Options(SplitMode.SeparatorSheet);
        var facts = new List<PageFacts> { Page, Page, Patch, Page, Page };
        // The gap before page 1: a split by hand.
        Assert.True(DocumentSplitter.CanToggleBreak(DocumentSplitter.Plan(facts, options), 1));
        Assert.Equal(DocumentBreak.Split, DocumentSplitter.ToggledBreak(facts, 1, options));
        facts[1] = facts[1] with { Break = DocumentBreak.Split };
        Assert.Equal([[0], [1], [3, 4]], Documents(DocumentSplitter.Plan(facts, options)));
        Assert.Equal(DocumentBreak.Automatic, DocumentSplitter.ToggledBreak(facts, 1, options));
        // The page after the separator starts a document: a click joins it.
        Assert.Equal(DocumentBreak.Join, DocumentSplitter.ToggledBreak(facts, 3, options));
        facts[3] = facts[3] with { Break = DocumentBreak.Join };
        Assert.Equal([[0], [1, 3, 4]], Documents(DocumentSplitter.Plan(facts, options)));
        Assert.Equal(DocumentBreak.Automatic, DocumentSplitter.ToggledBreak(facts, 3, options));
        // The first page saved and a separator page have no gap to click.
        var plan = DocumentSplitter.Plan(facts, options);
        Assert.False(DocumentSplitter.CanToggleBreak(plan, 0));
        Assert.False(DocumentSplitter.CanToggleBreak(plan, 2));
        Assert.False(DocumentSplitter.CanToggleBreak(plan, 7));
        Assert.Equal(DocumentBreak.Automatic, DocumentSplitter.ToggledBreak(facts, 0, options));
        Assert.Equal(DocumentBreak.Automatic, DocumentSplitter.ToggledBreak(facts, 2, options));
    }

    [Fact]
    public void ToggledInclusion_KeepsASeparatorPage_AndTwoClicksUndoOne()
    {
        var options = Options(SplitMode.SeparatorSheet, removeBlankPages: true);
        var facts = new List<PageFacts> { Page, Front(0, patch: PatchCode.PatchT), Back(0, blank: true), Page };
        Assert.Equal(PageInclusion.Keep, DocumentSplitter.ToggledInclusion(facts, 1, options));
        facts[1] = facts[1] with { Inclusion = PageInclusion.Keep };
        // Kept, the sheet no longer splits; its blank back is still skipped.
        var plan = DocumentSplitter.Plan(facts, options);
        Assert.Equal([[0, 1, 3]], Documents(plan));
        Assert.Equal("ccsc", Roles(plan));
        Assert.Equal(PageInclusion.Automatic, DocumentSplitter.ToggledInclusion(facts, 1, options));
        // A page saved: a click skips it, a second click follows the settings again.
        Assert.Equal(PageInclusion.Skip, DocumentSplitter.ToggledInclusion(facts, 0, options));
        // A blank page skipped by the setting: kept, like PageFilter.Toggled.
        Assert.Equal(PageInclusion.Keep, DocumentSplitter.ToggledInclusion(facts, 2, options));
    }

    [Fact]
    public void Names_TheFirstNameAmongADocumentsPagesSaved()
    {
        var facts = new[]
        {
            Page with { Label = "  " }, Page with { Label = " Lease " }, Page with { Label = "Other" },
            Patch with { Label = "Separator" }, Blank with { Label = "Skipped" }, Page,
        };
        var plan = DocumentSplitter.Plan(facts, Options(SplitMode.SeparatorSheet, removeBlankPages: true));
        Assert.Equal(["Lease", null], plan.Documents.Select(d => d.Label));
        Assert.Equal("Document 1 · Lease", DocumentSplitter.DocumentTitle(plan.Documents[0]));
        Assert.Equal("Document 2", DocumentSplitter.DocumentTitle(plan.Documents[1]));
        Assert.Null(DocumentSplitter.Cleaned("  "));
        Assert.Equal("A b", DocumentSplitter.Cleaned(" A b "));
        // A long name is cut to 100 characters, never inside one.
        Assert.Equal(new string('a', 100), DocumentSplitter.Cleaned(new string('a', 300)));
        Assert.Equal(new string('a', 99), DocumentSplitter.Cleaned(new string('a', 99) + " and more"));
        Assert.Equal(string.Concat(Enumerable.Repeat("😀", 100)), DocumentSplitter.Cleaned(string.Concat(Enumerable.Repeat("😀", 101))));
    }

    private static List<PageFacts> Toggled(List<PageFacts> facts, int index, PageInclusion? inclusion = null,
                                           DocumentBreak? documentBreak = null)
    {
        var after = facts.ToList();
        after[index] = after[index] with
        {
            Inclusion = inclusion ?? after[index].Inclusion,
            Break = documentBreak ?? after[index].Break,
        };
        var labels = DocumentSplitter.CarriedLabels(facts, after, Options(SplitMode.SeparatorSheet));
        return after.Select((f, i) => f with { Label = labels[i] }).ToList();
    }

    private static void AssertLabels(IEnumerable<string?> expected, IEnumerable<string?> actual) =>
        Assert.Equal(expected, actual);

    private static string?[] Names(List<PageFacts> facts) =>
        DocumentSplitter.Plan(facts, Options(SplitMode.SeparatorSheet)).Documents.Select(d => d.Label).ToArray();

    [Fact]
    public void CarriedLabels_SkippingANamedFirstPage_MovesTheNameToTheNextPage_AndKeepingItMovesItBack()
    {
        // Document 2 is pages 3 and 4, named on page 3.
        var facts = new List<PageFacts> { Page, Page, Patch, Page with { Label = "Lease" }, Page };
        var skipped = Toggled(facts, 3, inclusion: PageInclusion.Skip);
        AssertLabels([null, "Lease"], Names(skipped));
        Assert.Equal([null, null, null, null, "Lease"], skipped.Select(f => f.Label));
        var kept = Toggled(skipped, 3, inclusion: PageInclusion.Automatic);
        AssertLabels([null, "Lease"], Names(kept));
        Assert.Equal([null, null, null, "Lease", null], kept.Select(f => f.Label));
    }

    [Fact]
    public void CarriedLabels_APageSavedAgainBeforeANamedDocument_TakesItsLatestName_NotAnOldOne()
    {
        // Page 3 is skipped and still holds an old name; the document starting at page 4 is named "New".
        var facts = new List<PageFacts>
        {
            Page, Patch, Page with { Inclusion = PageInclusion.Skip, Label = "Old" }, Page with { Label = "New" }, Page,
        };
        AssertLabels([null, "New"], Names(facts));
        var kept = Toggled(facts, 2, inclusion: PageInclusion.Automatic);
        AssertLabels([null, "New"], Names(kept));
        Assert.Equal([null, null, "New", null, null], kept.Select(f => f.Label));
        // A document with no name stays without one: the old name is cleared.
        var unnamed = facts.ToList();
        unnamed[3] = unnamed[3] with { Label = null };
        var keptUnnamed = Toggled(unnamed, 2, inclusion: PageInclusion.Automatic);
        AssertLabels([null, null], Names(keptUnnamed));
    }

    [Fact]
    public void CarriedLabels_ADocumentThatIsGone_ComesBackWithItsName_AndSplitsAndJoinsKeepNames()
    {
        // Document 2 is page 3 alone: skipped, it is gone; kept again, it has its name back.
        var facts = new List<PageFacts> { Page, Patch, Page with { Label = "Cover" }, Patch, Page with { Label = "Body" } };
        var gone = Toggled(facts, 2, inclusion: PageInclusion.Skip);
        AssertLabels([null, "Body"], Names(gone));
        Assert.Equal("Cover", gone[2].Label);
        AssertLabels([null, "Cover", "Body"], Names(Toggled(gone, 2, inclusion: PageInclusion.Automatic)));
        // Joined to the document before and split off again: the second document keeps its name.
        var two = new List<PageFacts> { Page with { Label = "A" }, Patch, Page with { Label = "B" }, Page };
        var joined = Toggled(two, 2, documentBreak: DocumentBreak.Join);
        AssertLabels(["A"], Names(joined));
        AssertLabels(["A", "B"], Names(Toggled(joined, 2, documentBreak: DocumentBreak.Automatic)));
        // Split by hand inside a named document: the new document has no name, the first keeps its.
        var split = Toggled(two, 3, documentBreak: DocumentBreak.Split);
        AssertLabels(["A", "B", null], Names(split));
        // Nothing changed: the names stay as they are.
        Assert.Equal(two.Select(f => f.Label), DocumentSplitter.CarriedLabels(two, two, Options(SplitMode.SeparatorSheet)));
    }

    private static List<PageFacts> Carried(List<PageFacts> before, DocumentOptions beforeOptions, List<PageFacts> after,
                                           DocumentOptions options)
    {
        var labels = DocumentSplitter.CarriedLabels(before, beforeOptions, after, options);
        return after.Select((f, i) => f with { Label = labels[i] }).ToList();
    }

    [Fact]
    public void CarriedLabels_ASettingThatLeavesOutANamedFirstPage_MovesTheName_AndChangingItBackMovesItBack()
    {
        // Document 2 starts with a nearly empty cover named "Lease": blank only at High.
        var medium = Options(SplitMode.SeparatorSheet, removeBlankPages: true);
        var high = Options(SplitMode.SeparatorSheet, removeBlankPages: true);
        high.BlankSensitivity = BlankSensitivity.High;
        var facts = new List<PageFacts> { Page, Patch, Page with { Label = "Lease" }, Page };
        var blankAtHigh = facts.Select((f, i) => i == 2 ? f with { LooksBlank = true } : f).ToList();
        var sensitive = Carried(facts, medium, blankAtHigh, high);
        Assert.Equal([null, "Lease"], DocumentSplitter.Plan(sensitive, high).Documents.Select(d => d.Label));
        Assert.Equal([null, null, null, "Lease"], sensitive.Select(f => f.Label));
        var back = Carried(sensitive, high, sensitive.Select(f => f with { LooksBlank = false }).ToList(), medium);
        Assert.Equal([null, null, "Lease", null], back.Select(f => f.Label));
        // Skip blank pages turned on, and off again.
        var off = Options(SplitMode.SeparatorSheet);
        var skipping = Carried(blankAtHigh, off, blankAtHigh, medium);
        Assert.Equal([null, null, null, "Lease"], skipping.Select(f => f.Label));
        Assert.Equal([null, null, "Lease", null], Carried(skipping, medium, skipping, off).Select(f => f.Label));
    }

    [Fact]
    public void CarriedLabels_ASplitChosenLater_GivesTheNameToOneDocument()
    {
        // Named while not split, on a separator sheet first in the stack: at separator sheets the
        // first document takes the name, the next has none; not split again, the name is back.
        var facts = new List<PageFacts> { Patch with { Label = "Lease" }, Page, Patch, Page };
        var none = Options(SplitMode.None);
        var separators = Options(SplitMode.SeparatorSheet);
        var split = Carried(facts, none, facts, separators);
        Assert.Equal(["Lease", null], DocumentSplitter.Plan(split, separators).Documents.Select(d => d.Label));
        Assert.Equal([null, "Lease", null, null], split.Select(f => f.Label));
        Assert.Equal(["Lease", null, null, null], Carried(split, separators, split, none).Select(f => f.Label));
        // Every 2 sheets: the first document keeps the name where it is.
        var named = new List<PageFacts> { Page with { Label = "L" }, Page, Page, Page };
        var everyTwo = Carried(named, none, named, Options(SplitMode.SheetCount, sheets: 2));
        Assert.Equal(["L", null, null, null], everyTwo.Select(f => f.Label));
    }

    [Fact]
    public void BlankPagesAreSeparators_OnlyOneSidedAtBlankSheets()
    {
        Assert.True(DocumentSplitter.BlankPagesAreSeparators(Options(SplitMode.BlankSheet), DuplexMode.Off));
        Assert.False(DocumentSplitter.BlankPagesAreSeparators(Options(SplitMode.BlankSheet), DuplexMode.Both));
        Assert.False(DocumentSplitter.BlankPagesAreSeparators(Options(SplitMode.BlankSheet), DuplexMode.Manual));
        Assert.False(DocumentSplitter.BlankPagesAreSeparators(Options(SplitMode.SeparatorSheet), DuplexMode.Off));
        Assert.False(DocumentSplitter.BlankPagesAreSeparators(Options(SplitMode.None), DuplexMode.Off));
        // There, the setting makes no difference to the plan.
        var facts = new[] { Page, Blank, Page, Blank with { Inclusion = PageInclusion.Keep }, Page };
        Assert.Equal(Roles(DocumentSplitter.Plan(facts, Options(SplitMode.BlankSheet, removeBlankPages: false))),
                     Roles(DocumentSplitter.Plan(facts, Options(SplitMode.BlankSheet, removeBlankPages: true))));
    }

    [Fact]
    public void Texts_ForThePageStrip()
    {
        var options = Options(SplitMode.SeparatorSheet);
        var facts = new[] { Page, Patch, Page, Page };
        var plan = DocumentSplitter.Plan(facts, options);
        Assert.Equal(["Document 1", null, "Document 2", null], Enumerable.Range(0, 4).Select(i => DocumentSplitter.DividerTitle(plan, i)));
        Assert.Equal([null, null, "Join with document 1", "Start a new document here"],
                     Enumerable.Range(0, 4).Select(i => DocumentSplitter.BreakLabel(plan, i)));
        Assert.True(DocumentSplitter.ShowsBreaks(plan, options));
        // One document: no titles; the dividers show only while a split is chosen.
        var single = DocumentSplitter.Plan([Page, Page], Options(SplitMode.None));
        Assert.Null(DocumentSplitter.DividerTitle(single, 0));
        Assert.False(DocumentSplitter.ShowsBreaks(single, Options(SplitMode.None)));
        Assert.True(DocumentSplitter.ShowsBreaks(single, Options(SplitMode.BlankSheet)));
        Assert.True(DocumentSplitter.ShowsBreaks(DocumentSplitter.Plan([Page, Page with { Break = DocumentBreak.Split }], Options(SplitMode.None)),
                                                 Options(SplitMode.None)));
        Assert.Equal(" Found 1 separator page: 2 documents to save.", DocumentSplitter.ScanNote(plan, 1));
        Assert.Equal(" 2 documents to save.", DocumentSplitter.ScanNote(plan, 0));
        Assert.Equal("", DocumentSplitter.ScanNote(single, 0));
        Assert.Equal(" Found 2 separator pages: 1 document to save.", DocumentSplitter.ScanNote(single, 2));
    }

    private static ScannedPage MakePage(BlankPageResult? blank = null, PatchCode? patch = null) =>
        new ScannedPage(RgbaImage.Filled(4, 4, 255, 255, 255), 300, ColorMode.Color).WithBlank(blank).WithPatch(patch);

    private static readonly BlankPageResult LooksBlank = new(0, 0, false, true);

    [Fact]
    public void ThePlanOfQueuedPages_UsesWhatTheirChecksFound()
    {
        var pages = new List<ScannedPage>
        {
            MakePage(), MakePage(patch: PatchCode.Patch2).WithDocumentLabel("ignored"), MakePage(blank: LooksBlank),
            MakePage().WithDocumentLabel("Lease"), MakePage().WithDocumentBreak(DocumentBreak.Split),
        };
        var options = Options(SplitMode.SeparatorSheet, removeBlankPages: true);
        Assert.Equal(PatchCode.Patch2, PageFacts.Of(pages[1], options).Patch);
        Assert.True(PageFacts.Of(pages[2], options).LooksBlank);
        Assert.Equal(DocumentBreak.Split, PageFacts.Of(pages[4], options).Break);
        var plan = DocumentSplitter.Plan(pages, options);
        Assert.Equal([[0], [3], [4]], Documents(plan));
        Assert.Equal([null, "Lease", null], plan.Documents.Select(d => d.Label));
        // The strip's notes.
        Assert.Equal("Separator", DocumentSplitter.Badge(plan, 1, pages[1], options));
        Assert.Equal("Blank, skipped", DocumentSplitter.Badge(plan, 2, pages[2], options));
        Assert.Null(DocumentSplitter.Badge(plan, 0, pages[0], options));
        Assert.Equal("Keep this page", DocumentSplitter.ToggleLabel(plan, 1, pages[1], options));
        Assert.Equal("Keep this page", DocumentSplitter.ToggleLabel(plan, 2, pages[2], options));
        Assert.Null(DocumentSplitter.ToggleLabel(plan, 0, pages[0], options));
        Assert.Equal("Separator sheet (Patch 2): a new document starts after it. It is not saved.",
                     DocumentSplitter.SeparatorNote(plan, 1, pages[1]));
        Assert.Null(DocumentSplitter.SeparatorNote(plan, 0, pages[0]));
        var blankSheets = DocumentSplitter.Plan(pages, Options(SplitMode.BlankSheet));
        Assert.Equal("Blank separator sheet: a new document starts after it. It is not saved.",
                     DocumentSplitter.SeparatorNote(blankSheets, 2, pages[2]));
        // Joined across the sheet: no document starts after it.
        var joined = new List<ScannedPage>(pages);
        joined[3] = pages[3].WithDocumentBreak(DocumentBreak.Join);
        var joinedPlan = DocumentSplitter.Plan(joined, options);
        Assert.Equal([[0, 3], [4]], Documents(joinedPlan));
        Assert.Equal("Separator sheet (Patch 2): the pages after it are joined to the document before. It is not saved.",
                     DocumentSplitter.SeparatorNote(joinedPlan, 1, joined[1]));
        // The strip's label.
        Assert.Equal("5 pages · 3 documents · 1 separator page and 1 blank skipped", DocumentSplitter.QueueSummary(pages, options));
        Assert.Equal("5 pages · 2 documents · 1 blank skipped",
                     DocumentSplitter.QueueSummary(pages, Options(SplitMode.None, removeBlankPages: true)));
    }

    [Fact]
    public void QueueSummary_WithoutASplit_IsThePageFiltersSummary()
    {
        var pages = new List<ScannedPage> { MakePage(), MakePage(blank: LooksBlank), MakePage().WithInclusion(PageInclusion.Skip), MakePage(patch: PatchCode.PatchT) };
        foreach (bool remove in new[] { false, true })
        {
            var options = Options(SplitMode.None, removeBlankPages: remove);
            Assert.Equal(PageFilter.QueueSummary(pages, options), DocumentSplitter.QueueSummary(pages, options));
            Assert.Equal(PageFilter.QueueSummary(pages[..2], options), DocumentSplitter.QueueSummary(pages[..2], options));
        }
        Assert.Equal("1 page", DocumentSplitter.QueueSummary([MakePage()], new DocumentOptions()));
    }
}
