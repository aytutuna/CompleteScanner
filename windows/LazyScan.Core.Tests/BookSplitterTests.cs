using LazyScan.Core;
using Xunit;

namespace LazyScan.Core.Tests;

// Twin of Tests/LazyScanTests/BookSplitterTests.swift: finding the gutter of an open book and
// cutting the spread into its pages, on the same synthetic spreads (TestPages, byte-identical,
// checked by checksum).

public class BookSplitterTests
{
    /// <summary>±0.05 in at the analysis resolution (100 dpi).</summary>
    private const double SpineTolerance = 5;

    // MARK: - The spreads are the same on both platforms

    [Fact]
    public void Spreads_AreTheSameBytesOnBothPlatforms()
    {
        Assert.Equal(0x4938C9B4u, TestPages.Checksum(TestPages.ShadowSpread()));
        Assert.Equal(0x7CCFEA71u, TestPages.Checksum(TestPages.MarginSpread()));
        Assert.Equal(0x01F76AFAu, TestPages.Checksum(TestPages.BlankFacingSpread()));
        Assert.Equal(0xD3D4D1E1u, TestPages.Checksum(TestPages.SinglePageAcross()));
        Assert.Equal(0xCBA411FEu, TestPages.Checksum(TestPages.TwoColumnPage()));
        Assert.Equal(0x978E0100u, TestPages.Checksum(TestPages.SectionGapPage()));
        Assert.Equal(0xCB7D0020u, TestPages.Checksum(TestPages.PageBesideEmptyGlass()));
    }

    // MARK: - Finding the gutter

    [Fact]
    public void ShadowSpread_FindsTheSpine_WithinAFiftiethOfAnInch()
    {
        var found = BookSplitter.FindGutter(TestPages.ShadowSpread());
        Assert.NotNull(found);
        Assert.Equal((GutterAxis.Vertical, GutterKind.Shadow), (found.Axis, found.Kind));
        Assert.InRange(found.Center, 572 - SpineTolerance, 572 + SpineTolerance);
        // The shadow is 25 % deep at its middle (less once smoothed, against the brightest paper).
        Assert.InRange(found.Confidence, 0.15, 0.3);
    }

    [Fact]
    public void ShadowSpread_ScannedAt300Dpi_IsCutAtTheSpine()
    {
        var scan = TestPages.Enlarged(TestPages.ShadowSpread(), 3);
        var gutter = BookSplitter.FindGutter(scan, 300);
        Assert.NotNull(gutter);
        Assert.Equal((GutterAxis.Vertical, GutterKind.Shadow), (gutter.Axis, gutter.Kind));
        Assert.InRange(gutter.Position, 3 * 572 - 15, 3 * 572 + 15);
        Assert.InRange(gutter.Fraction(scan.Width, scan.Height), 0.515, 0.525);
    }

    [Fact]
    public void MarginSpread_WithoutAShadow_FindsTheMarginCentre()
    {
        var found = BookSplitter.FindGutter(TestPages.MarginSpread());
        Assert.NotNull(found);
        Assert.Equal((GutterAxis.Vertical, GutterKind.Margin), (found.Axis, found.Kind));
        // Lines end unevenly on the left page, so the blank run's middle may lie a little left of the spine.
        Assert.InRange(found.Center, 550 - SpineTolerance, 550 + SpineTolerance);
        // The run is at least the two inner margins long (1.2 in of 11).
        Assert.InRange(found.Confidence, 0.1, 0.16);
    }

    [Fact]
    public void BlankFacingPage_TheShadowStillSplits()
    {
        var found = BookSplitter.FindGutter(TestPages.BlankFacingSpread());
        Assert.NotNull(found);
        Assert.Equal(GutterKind.Shadow, found.Kind);
        Assert.InRange(found.Center, 550 - SpineTolerance, 550 + SpineTolerance);
        // Without the shadow nothing tells where the blank page ends: the spread stays whole.
        Assert.Null(BookSplitter.FindGutter(TestPages.Spread(550, 40, 80, 0, 0, 0xB00C0003, blankLeft: true)));
    }

    [Fact]
    public void SinglePages_AreNotSplit()
    {
        Assert.Null(BookSplitter.FindGutter(TestPages.SinglePageAcross()));
        Assert.Null(BookSplitter.FindGutter(TestPages.TwoColumnPage()));
        Assert.Null(BookSplitter.FindGutter(TestPages.SectionGapPage()));
        Assert.Null(BookSplitter.FindGutter(TestPages.TextPage()));
        // Turned on its side, a single page is still a single page.
        Assert.Null(BookSplitter.FindGutter(TestPages.QuarterTurned(TestPages.SinglePageAcross())));
    }

    [Fact]
    public void ACreaseAcrossAFoldedLetter_IsNotSplit()
    {
        // The creases run along the lines of text: a fold, not a spine.
        Assert.Null(BookSplitter.FindGutter(TestPages.FoldedLetter()));
        Assert.Null(BookSplitter.FindGutter(TestPages.QuarterTurned(TestPages.FoldedLetter())));
    }

    [Fact]
    public void TheGuttersOwnDarkLine_DoesNotHideIt()
    {
        // The spine with the pages' edges meeting in it: a thin dark line along the cut.
        var c = new TestPages.Canvas(1100, 850, 245, 0xB00C0001);
        var spread = TestPages.ShadowSpread();
        Array.Copy(spread.Pixels, c.P, spread.Pixels.Length);
        c.FillRect(571, 0, 2, 850, 60);
        var found = BookSplitter.FindGutter(c.Gray());
        Assert.NotNull(found);
        Assert.Equal(GutterAxis.Vertical, found.Axis);
        Assert.InRange(found.Center, 572 - SpineTolerance, 572 + SpineTolerance);
        // Judged with the band around it blanked out, the text runs across the spine, along a section gap.
        Assert.False(BookSplitter.RunsAlongText(c.Gray(), found));
        Assert.True(BookSplitter.RunsAlongText(TestPages.SectionGapPage(),
                                               new GutterCandidate(GutterAxis.Horizontal, 550, 0.1, GutterKind.Margin)));
    }

    [Fact]
    public void ATitlePageFacingText_IsSplitOnlyByItsShadow()
    {
        // Without a shadow the blank run beside the centered title is not in the middle of the text: kept whole.
        Assert.Null(BookSplitter.FindGutter(TestPages.TitleFacingText(0)));
        var found = BookSplitter.FindGutter(TestPages.TitleFacingText(250));
        Assert.NotNull(found);
        Assert.Equal(GutterKind.Shadow, found.Kind);
        Assert.InRange(found.Center, 550 - SpineTolerance, 550 + SpineTolerance);
    }

    [Fact]
    public void APageBesideEmptyGlass_IsNotSplitAtItsEdge()
    {
        Assert.Null(BookSplitter.FindGutter(TestPages.PageBesideEmptyGlass()));
    }

    [Fact]
    public void NothingToRead_IsNotSplit()
    {
        Assert.Null(BookSplitter.FindGutter(TestPages.CleanBlank()));
        Assert.Null(BookSplitter.FindGutter(TestPages.Spread(550, 30, 80, 250, 17, 0xB00C000E, blankLeft: true, blankRight: true)));
    }

    [Fact]
    public void StackedSpread_FindsTheHorizontalAxis()
    {
        // The book lying sideways: turned a quarter clockwise, the left page is on top.
        var stacked = TestPages.QuarterTurned(TestPages.ShadowSpread());
        var found = BookSplitter.FindGutter(stacked);
        Assert.NotNull(found);
        Assert.Equal((GutterAxis.Horizontal, GutterKind.Shadow), (found.Axis, found.Kind));
        Assert.InRange(found.Center, 572 - SpineTolerance, 572 + SpineTolerance);
        var margins = BookSplitter.FindGutter(TestPages.QuarterTurned(TestPages.MarginSpread()));
        Assert.NotNull(margins);
        Assert.Equal((GutterAxis.Horizontal, GutterKind.Margin), (margins.Axis, margins.Kind));
        Assert.InRange(margins.Center, 550 - SpineTolerance, 550 + SpineTolerance);
    }

    [Fact]
    public void Candidates_SkipTheAxisAlongTheLinesOfText()
    {
        // The spread's lines run across, so only a vertical cut is looked for.
        Assert.All(BookSplitter.Candidates(TestPages.ShadowSpread()), c => Assert.Equal(GutterAxis.Vertical, c.Axis));
        Assert.All(BookSplitter.Candidates(TestPages.QuarterTurned(TestPages.ShadowSpread())),
                   c => Assert.Equal(GutterAxis.Horizontal, c.Axis));
    }

    [Fact]
    public void Profile_MeasuresBrightnessAndInkOverTheMiddleBand()
    {
        var profile = BookSplitter.Profile(TestPages.ShadowSpread(), GutterAxis.Vertical);
        Assert.Equal(1100, profile.Length);
        // Paper in the outer margin, darker under the spine's shadow; text on the pages, none in the shadow.
        Assert.InRange(profile.Brightness[40], 240, 250);
        Assert.InRange(profile.Brightness[572], 170, 200);
        Assert.True(profile.Ink[300] > 0.05, $"ink on the page {profile.Ink[300]}");
        Assert.Equal(0, profile.Ink[572]);
        Assert.Equal(5, BookSplitter.SmoothWidth(100));
        Assert.Equal(15, BookSplitter.SmoothWidth(300));
        Assert.Equal(3, BookSplitter.SmoothWidth(40));
    }

    // MARK: - Cutting

    /// <summary>A w × h image whose pixel (x, y) is (x, y, 7, 255), so every pixel can be told apart.</summary>
    private static RgbaImage Coordinates(int w, int h)
    {
        var p = new byte[w * h * 4];
        for (int y = 0; y < h; y++)
        {
            for (int x = 0; x < w; x++)
            {
                int i = (y * w + x) * 4;
                p[i] = (byte)x;
                p[i + 1] = (byte)y;
                p[i + 2] = 7;
                p[i + 3] = 255;
            }
        }
        return new RgbaImage(w, h, p);
    }

    [Fact]
    public void Halves_TogetherAreExactlyTheScan()
    {
        var image = Coordinates(101, 40);
        var (left, right) = BookSplitter.Halves(image, new GutterResult(GutterAxis.Vertical, 37, 0.2, GutterKind.Shadow));
        Assert.Equal((37, 40), (left.Width, left.Height));
        Assert.Equal((64, 40), (right.Width, right.Height));
        Assert.Equal(image.Width, left.Width + right.Width);
        for (int y = 0; y < 40; y++)
        {
            for (int x = 0; x < 101; x++)
            {
                var (half, hx) = x < 37 ? (left, x) : (right, x - 37);
                Assert.Equal(image.Pixels[(y * 101 + x) * 4], half.Pixels[(y * half.Width + hx) * 4]);
                Assert.Equal(image.Pixels[(y * 101 + x) * 4 + 1], half.Pixels[(y * half.Width + hx) * 4 + 1]);
            }
        }
        var (top, bottom) = BookSplitter.Halves(Coordinates(30, 90), new GutterResult(GutterAxis.Horizontal, 50, 0.2, GutterKind.Margin));
        Assert.Equal((30, 50, 30, 40), (top.Width, top.Height, bottom.Width, bottom.Height));
        Assert.Equal(50, bottom.Pixels[1]);
        // A cut at the edge still leaves a column on each side.
        var (edge, rest) = BookSplitter.Halves(image, new GutterResult(GutterAxis.Vertical, 0, 1, GutterKind.Manual));
        Assert.Equal((1, 100), (edge.Width, rest.Width));
    }

    /// <summary>The first pixel's red value of each page: which part of the scan it came from (its x).</summary>
    private static int[] Origins(IReadOnlyList<RgbaImage> pages) => pages.Select(p => (int)p.Pixels[0]).ToArray();

    [Fact]
    public void Split_LeftToRight_OrRightToLeft()
    {
        var image = Coordinates(200, 60);
        var cut = new GutterResult(GutterAxis.Vertical, 100, 0.3, GutterKind.Shadow);
        var pages = BookSplitter.Split(image, cut, 0, rightToLeft: false);
        Assert.Equal([0, 100], Origins(pages));
        Assert.All(pages, p => Assert.Equal((100, 60), (p.Width, p.Height)));
        Assert.Equal([100, 0], Origins(BookSplitter.Split(image, cut, 0, rightToLeft: true)));
    }

    [Fact]
    public void Split_TurnedBook_OrdersThePagesByWhereTheyLieOnceTurned()
    {
        // Stacked: the top page (y 0..59) and the bottom one (60..119); green tells them apart.
        var image = Coordinates(80, 120);
        var cut = new GutterResult(GutterAxis.Horizontal, 60, 0.3, GutterKind.Shadow);
        int[] Tops(IReadOnlyList<RgbaImage> pages, int turns) =>
            pages.Select(p => (int)p.RotatedQuarterTurns(4 - turns).Pixels[1]).ToArray();
        // Turned a quarter clockwise the top page lies on the right: it comes second, first right to left.
        var clockwise = BookSplitter.Split(image, cut, 1, rightToLeft: false);
        Assert.Equal([60, 0], Tops(clockwise, 1));
        Assert.All(clockwise, p => Assert.Equal((60, 80), (p.Width, p.Height)));
        Assert.Equal([0, 60], Tops(BookSplitter.Split(image, cut, 1, rightToLeft: true), 1));
        // Turned a quarter counterclockwise the top page lies on the left.
        Assert.Equal([0, 60], Tops(BookSplitter.Split(image, cut, 3, rightToLeft: false), 3));
        Assert.Equal([60, 0], Tops(BookSplitter.Split(image, cut, 3, rightToLeft: true), 3));
        // Not turned, top comes before bottom whichever way the book reads.
        Assert.Equal([0, 60], Tops(BookSplitter.Split(image, cut, 0, rightToLeft: true), 0));
        // Upside down, the bottom page is now on top.
        Assert.Equal([60, 0], Tops(BookSplitter.Split(image, cut, 2, rightToLeft: false), 2));
    }

    [Fact]
    public void Split_UpsideDownSpread_SwapsLeftAndRight()
    {
        var image = Coordinates(200, 60);
        var cut = new GutterResult(GutterAxis.Vertical, 100, 0.3, GutterKind.Shadow);
        var pages = BookSplitter.Split(image, cut, 2, rightToLeft: false);
        // Turned half way, each page's first pixel is its old last one: the right part (x 100..199) comes first.
        Assert.Equal([199, 99], Origins(pages));
    }

    [Fact]
    public void FirstPartLeads_Table()
    {
        // Vertical: the left part leads unturned (left to right) or turned half way (right to left).
        Assert.Equal([true, true, false, false], new[] { 0, 1, 2, 3 }.Select(t => BookSplitter.FirstPartLeads(GutterAxis.Vertical, t, false)));
        Assert.Equal([false, true, true, false], new[] { 0, 1, 2, 3 }.Select(t => BookSplitter.FirstPartLeads(GutterAxis.Vertical, t, true)));
        // Horizontal: the top part leads unturned, or turned counterclockwise (left to right), clockwise (right to left).
        Assert.Equal([true, false, false, true], new[] { 0, 1, 2, 3 }.Select(t => BookSplitter.FirstPartLeads(GutterAxis.Horizontal, t, false)));
        Assert.Equal([true, true, false, false], new[] { 0, 1, 2, 3 }.Select(t => BookSplitter.FirstPartLeads(GutterAxis.Horizontal, t, true)));
        // Turns beyond 0...3 count modulo 4.
        Assert.Equal(BookSplitter.FirstPartLeads(GutterAxis.Horizontal, 3, false), BookSplitter.FirstPartLeads(GutterAxis.Horizontal, -1, false));
        Assert.Equal(BookSplitter.FirstPartLeads(GutterAxis.Vertical, 2, false), BookSplitter.FirstPartLeads(GutterAxis.Vertical, 6, false));
    }

    [Fact]
    public void TotalTurns_AddWhatReadingTheTextAgreedOn()
    {
        var one = new UprightTurn(1);
        var three = new UprightTurn(3);
        Assert.Equal(0, BookSplitter.TotalTurns(0, null, null));
        Assert.Equal(1, BookSplitter.TotalTurns(0, one, one));
        // One page read and turned, the other unread (blank, a picture): the turn counts.
        Assert.Equal(1, BookSplitter.TotalTurns(0, one, null));
        Assert.Equal(3, BookSplitter.TotalTurns(0, null, three));
        // Pages turned different ways say nothing.
        Assert.Equal(2, BookSplitter.TotalTurns(2, one, three));
        // The book's own rotation adds up; a turn the user undid does not count.
        Assert.Equal(0, BookSplitter.TotalTurns(3, one, one));
        Assert.Equal(3, BookSplitter.TotalTurns(3, one with { Undone = true }, null));
        Assert.Equal(1, BookSplitter.NormalizedTurns(-3));
        Assert.Equal(2, BookSplitter.NormalizedTurns(6));
    }

    [Fact]
    public void Manual_PlacesTheCutAtAShareOfTheAxis_KeptOffTheEdges()
    {
        var cut = BookSplitter.Manual(GutterAxis.Vertical, 0.52, 1000, 700);
        Assert.Equal(new GutterResult(GutterAxis.Vertical, 520, 1, GutterKind.Manual), cut);
        Assert.Equal(0.52, cut.Fraction(1000, 700), 6);
        Assert.Equal(350, BookSplitter.Manual(GutterAxis.Horizontal, 0.5, 1000, 700).Position);
        Assert.Equal(1, BookSplitter.Manual(GutterAxis.Vertical, -0.5, 1000, 700).Position);
        Assert.Equal(999, BookSplitter.Manual(GutterAxis.Vertical, 1, 1000, 700).Position);
        Assert.Equal(500, BookSplitter.Manual(GutterAxis.Vertical, double.NaN, 1000, 700).Position);
    }

    [Fact]
    public void AtScale_MapsTheAnalysisCentreBackToTheScan()
    {
        var candidate = new GutterCandidate(GutterAxis.Vertical, 300.5, 0.2, GutterKind.Shadow);
        // An analysis image a third the size of the scan.
        Assert.Equal(902, BookSplitter.AtScale(candidate, 1800, 1200, 1.0 / 3).Position);
        Assert.Equal(1799, BookSplitter.AtScale(candidate with { Center = 700 }, 1800, 1200, 1.0 / 3).Position);
    }

    [Fact]
    public void Options_ComeFromTheSettings()
    {
        var s = new ScanSettings();
        Assert.Equal(new BookSplitOptions(0, false), BookSplitOptions.Of(s));
        s.TaskOptions.BookRotationQuarterTurns = 7;
        s.TaskOptions.BookRightToLeft = true;
        Assert.Equal(new BookSplitOptions(3, true), BookSplitOptions.Of(s));
    }

    // MARK: - The demo book

    [Fact]
    public void DemoBook_IsCutAtItsSpine()
    {
        foreach (int dpi in new[] { 100, 150 })
        {
            var spread = MockBedRenderer.RenderBookSpread(dpi, 0);
            var gutter = BookSplitter.FindGutter(spread, dpi);
            Assert.NotNull(gutter);
            Assert.Equal((GutterAxis.Vertical, GutterKind.Shadow), (gutter.Axis, gutter.Kind));
            double spine = MockBedRenderer.BookGutterFraction * spread.Width;
            Assert.InRange(gutter.Position, spine - 0.05 * dpi, spine + 0.05 * dpi);
        }
    }

    [Fact]
    public void DemoBook_PagesHaveTheSpineShadowSoftened()
    {
        var spread = MockBedRenderer.RenderBookSpread(150, 0);
        var pages = PageProcessor.ForScan(TaskCatalog.Apply(ScanTask.Book, new ScanSettings()))
            .Process([new ScannedPage(spread, 150, ColorMode.Color)]).Pages;
        Assert.Equal(new PageEdge?[] { PageEdge.Right, PageEdge.Left }, pages.Select(p => p.SpineShadow?.Edge));
        // The demo spine's shadow is 25 % deep at the fold; each page keeps the page as cut to show.
        Assert.All(pages, p => Assert.InRange(p.SpineShadow!.Depth, 0.1, 0.3));
        Assert.All(pages, p => Assert.True(p.CanSwapVersions));
    }

    // MARK: - What the strip and the status say

    private static ScannedPage Part(Guid spread, int? part) =>
        new(RgbaImage.Filled(4, 4, 255, 255, 255), 100, ColorMode.Color)
        {
            Spread = new SpreadPart(spread, part, part is null ? null : new GutterResult(GutterAxis.Vertical, 2, 0.2, GutterKind.Shadow)),
        };

    [Fact]
    public void Labels_NumberTheSpreadsAndTheirPages()
    {
        Guid a = Guid.NewGuid(), b = Guid.NewGuid();
        var loose = new ScannedPage(RgbaImage.Filled(4, 4, 255, 255, 255), 100, ColorMode.Color);
        var pages = new List<ScannedPage> { Part(a, 0), Part(a, 1), loose, Part(b, null) };
        Assert.Equal(["1 · left", "1 · right", null, "2 · not split"],
                     Enumerable.Range(0, pages.Count).Select(i => BookPages.Label(pages, i)));
        // Pages moved apart keep their spread's number, in queue order, and each keeps its own side.
        var moved = new List<ScannedPage> { pages[1], pages[3], pages[0] };
        Assert.Equal(["1 · right", "2 · not split", "1 · left"],
                     Enumerable.Range(0, moved.Count).Select(i => BookPages.Label(moved, i)));
        // The left page removed: the right page is still the right page.
        Assert.Equal("1 · right", BookPages.Label([pages[1]], 0));
        Assert.Equal("Spread 2, not split", BookPages.Help(pages, 3));
        Assert.Equal("Spread 1, right page", BookPages.Help(pages, 1));
        Assert.Null(BookPages.Help(pages, 2));
        Assert.Null(BookPages.Label(pages, 9));
        // The side recorded when the spread was cut wins over the part: a book scanned upside down.
        var upsideDown = new List<ScannedPage>
        {
            Part(a, 1).WithSpread(Part(a, 1).Spread! with { Left = true }),
            Part(a, 0).WithSpread(Part(a, 0).Spread! with { Left = false }),
        };
        Assert.Equal(["1 · left", "1 · right"], Enumerable.Range(0, 2).Select(i => BookPages.Label(upsideDown, i)));
        Assert.Equal(("Not split", "Not with two-sided"), (BookPages.NotSplitBadge, BookPages.NotWithTwoSidedReason));
    }

    [Fact]
    public void Labels_InOnePass_AreTheLabelAndHelpOfEveryPage()
    {
        Guid a = Guid.NewGuid(), b = Guid.NewGuid();
        var loose = new ScannedPage(RgbaImage.Filled(4, 4, 255, 255, 255), 100, ColorMode.Color);
        var pages = new List<ScannedPage> { Part(a, 1), loose, Part(b, null), Part(a, 0) };
        var labels = BookPages.Labels(pages);
        Assert.Equal(new BookPageLabel?[]
        {
            new("1 · right", "Spread 1, right page"),
            null,
            new("2 · not split", "Spread 2, not split"),
            new("1 · left", "Spread 1, left page"),
        }, labels);
        Assert.Equal(Enumerable.Range(0, pages.Count).Select(i => BookPages.Label(pages, i)), labels.Select(l => l?.Label));
        Assert.Equal(Enumerable.Range(0, pages.Count).Select(i => BookPages.Help(pages, i)), labels.Select(l => l?.Help));
        Assert.Empty(BookPages.Labels([]));
        // A long book: every spread numbered, each page with its side.
        var book = Enumerable.Range(0, 1000).SelectMany(_ => { var id = Guid.NewGuid(); return new[] { Part(id, 0), Part(id, 1) }; }).ToList();
        var bookLabels = BookPages.Labels(book);
        Assert.Equal(("1 · left", "1000 · right"), (bookLabels[0]!.Label, bookLabels[^1]!.Label));
    }

    [Fact]
    public void Labels_KeepTheSideEachPageWasCutWith()
    {
        // A left-to-right book: the left page leads.
        var spread = new ScannedPage(RgbaImage.Filled(20, 10, 255, 255, 255), 100, ColorMode.Color);
        var cut = BookSplitter.Manual(GutterAxis.Vertical, 0.5, spread.Image.Width, spread.Image.Height);
        var ltr = new PageProcessor([]).ProcessSpread(spread, cut, new BookSplitOptions());
        Assert.Equal(new int?[] { 0, 1 }, ltr.Select(p => p.Spread!.Part));
        Assert.Equal(["1 · left", "1 · right"], BookPages.Labels(ltr).Select(l => l!.Label));
        // A right-to-left book scanned next: the right page leads, and the pages of the first spread
        // keep their sides, as the setting applies to the spreads scanned from then on.
        var next = new ScannedPage(RgbaImage.Filled(20, 10, 255, 255, 255), 100, ColorMode.Color);
        var rtl = new PageProcessor([]).ProcessSpread(next, cut, new BookSplitOptions(0, true));
        Assert.Equal(new int?[] { 1, 0 }, rtl.Select(p => p.Spread!.Part));
        var queue = ltr.Concat(rtl).ToList();
        Assert.Equal(["1 · left", "1 · right", "2 · right", "2 · left"], BookPages.Labels(queue).Select(l => l!.Label));
        Assert.Equal("Spread 2, right page", BookPages.Help(queue, 2));
        // Upside down on the glass: the part before the cut lies on the right once turned.
        var turned = new PageProcessor([]).ProcessSpread(spread, cut, new BookSplitOptions(2));
        Assert.Equal(new int?[] { 1, 0 }, turned.Select(p => p.Spread!.Part));
        Assert.Equal(["1 · left", "1 · right"], BookPages.Labels(turned).Select(l => l!.Label));
        // A page moved in front of its partner, or left alone, keeps its side.
        Assert.Equal(["1 · right", "1 · left"], BookPages.Labels([ltr[1], ltr[0]]).Select(l => l!.Label));
        Assert.Equal(["1 · right"], BookPages.Labels([ltr[1]]).Select(l => l!.Label));
    }

    [Fact]
    public void ReplacementPages_KeepWhatTheUserDecided()
    {
        var id = Guid.NewGuid();
        // Split again: each new page takes the break, name and keep or skip of the queued page of its part.
        var left = Part(id, 0).WithInclusion(PageInclusion.Skip);
        var right = Part(id, 1).WithDocumentBreak(DocumentBreak.Split).WithDocumentLabel("Chapter 2");
        var fresh = new[] { Part(id, 0), Part(id, 1) };
        var both = BookPages.ReplacementPages([left, right], fresh);
        Assert.Equal(fresh.Select(p => p.Id), both.Select(p => p.Id));
        Assert.Equal((PageInclusion.Skip, DocumentBreak.Automatic, (string?)null), (both[0].Inclusion, both[0].DocumentBreak, both[0].DocumentLabel));
        Assert.Equal((PageInclusion.Automatic, DocumentBreak.Split, (string?)"Chapter 2"), (both[1].Inclusion, both[1].DocumentBreak, both[1].DocumentLabel));
        // In the new order (right to left, the right page first) each still takes its own part's.
        var reversed = BookPages.ReplacementPages([left, right], [fresh[1], fresh[0]]);
        Assert.Equal([fresh[1].Id, fresh[0].Id], reversed.Select(p => p.Id));
        Assert.Equal((DocumentBreak.Split, PageInclusion.Skip), (reversed[0].DocumentBreak, reversed[1].Inclusion));
        // A part the user removed from the queue stays out.
        var one = Assert.Single(BookPages.ReplacementPages([right], fresh));
        Assert.Equal((fresh[1].Id, DocumentBreak.Split, (string?)"Chapter 2"), (one.Id, one.DocumentBreak, one.DocumentLabel));
        // Joined: the first queued page's break, the first name among them, the keep or skip they share.
        var whole = Part(id, null);
        var joined = Assert.Single(BookPages.ReplacementPages([left.WithDocumentBreak(DocumentBreak.Split), right], [whole]));
        Assert.Equal((whole.Id, DocumentBreak.Split, (string?)"Chapter 2", PageInclusion.Automatic),
                     (joined.Id, joined.DocumentBreak, joined.DocumentLabel, joined.Inclusion));
        Assert.Equal(PageInclusion.Skip, Assert.Single(BookPages.ReplacementPages([left, right.WithInclusion(PageInclusion.Skip)], [whole])).Inclusion);
        // A whole spread split: the first page takes its break and name, both its keep or skip.
        var kept = whole.WithDocumentBreak(DocumentBreak.Split).WithDocumentLabel("Atlas").WithInclusion(PageInclusion.Keep);
        var split = BookPages.ReplacementPages([kept], fresh);
        Assert.Equal(fresh.Select(p => p.Id), split.Select(p => p.Id));
        Assert.Equal((DocumentBreak.Split, (string?)"Atlas", PageInclusion.Keep), (split[0].DocumentBreak, split[0].DocumentLabel, split[0].Inclusion));
        Assert.Equal((DocumentBreak.Automatic, (string?)null, PageInclusion.Keep), (split[1].DocumentBreak, split[1].DocumentLabel, split[1].Inclusion));
        // Nothing queued: the new pages as they are.
        Assert.Equal(fresh.Select(p => p.Id), BookPages.ReplacementPages([], fresh).Select(p => p.Id));
    }

    [Fact]
    public void Actions_SplitOrJoinASpread()
    {
        var id = Guid.NewGuid();
        Assert.Equal(("Change the split…", "Join the two pages"), (BookPages.SplitActionLabel(Part(id, 1)), BookPages.JoinActionLabel(Part(id, 1))));
        Assert.Equal("Split this spread…", BookPages.SplitActionLabel(Part(id, null)));
        Assert.Null(BookPages.JoinActionLabel(Part(id, null)));
        var loose = new ScannedPage(RgbaImage.Filled(4, 4, 255, 255, 255), 100, ColorMode.Color);
        Assert.Null(BookPages.SplitActionLabel(loose));
        Assert.Null(BookPages.JoinActionLabel(loose));
        Assert.Equal("Spread 3 is split into two pages.", BookPages.SplitNote(3, true));
        Assert.Equal("Spread 3 is one page again.", BookPages.SplitNote(3, false));
    }

    [Fact]
    public void ScanNote_CountsTheSpreadsSplitAndKeptWhole()
    {
        Guid a = Guid.NewGuid(), b = Guid.NewGuid(), c = Guid.NewGuid();
        Assert.Equal("", BookPages.ScanNote([new ScannedPage(RgbaImage.Filled(4, 4, 255, 255, 255), 100, ColorMode.Color)]));
        Assert.Equal(" 1 spread split into pages.", BookPages.ScanNote([Part(a, 0), Part(a, 1)]));
        Assert.Equal(" 2 spreads split into pages.", BookPages.ScanNote([Part(a, 0), Part(a, 1), Part(b, 1), Part(b, 0)]));
        Assert.Equal(" The spine of 1 spread was not found: it was added as one page (Split… on it splits it).",
                     BookPages.ScanNote([Part(c, null)]));
        Assert.Equal(" 1 spread split into pages. The spine of 2 spreads was not found: they were added as one page each (Split… on one splits it).",
                     BookPages.ScanNote([Part(a, 0), Part(a, 1), Part(b, null), Part(c, null)]));
    }

    [Fact]
    public void Rotation_And_Hint()
    {
        Assert.Equal(["As scanned", "90° clockwise", "180°", "90° counterclockwise"],
                     BookPages.RotationChoices.Select(BookPages.RotationLabel));
        Assert.Equal("90° clockwise", BookPages.RotationLabel(5));
        var book = TaskCatalog.Apply(ScanTask.Book, new ScanSettings());
        Assert.Equal("Each book scan becomes two pages, cut at the spine.", BookPages.Hint(book));
        book.Document.SplitFacingPages = false;
        Assert.Equal("Each book scan becomes two pages, cut at the spine.", BookPages.Hint(book));
        book.DocumentMultiPage = false;
        Assert.StartsWith("Only for pages collected", BookPages.Hint(book));
        Assert.StartsWith("Copies print", BookPages.Hint(TaskCatalog.Apply(ScanTask.Copy, new ScanSettings())));
        Assert.StartsWith("Receipts are", BookPages.Hint(TaskCatalog.Apply(ScanTask.Receipt, new ScanSettings())));
        // Two-sided scans keep their pages as scanned.
        var feeder = TaskCatalog.Apply(ScanTask.Book, new ScanSettings());
        feeder.Source = ScanSource.DocumentFeeder;
        feeder.Duplex = DuplexMode.Both;
        Assert.False(BookPages.ScansOneSide(feeder));
        Assert.Equal("Only for one side of each sheet: pages scanned on both sides are kept as scanned.", BookPages.Hint(feeder));
        feeder.Duplex = DuplexMode.Manual;
        Assert.StartsWith("Only for one side of each sheet", BookPages.Hint(feeder));
        feeder.Duplex = DuplexMode.Off;
        Assert.True(BookPages.ScansOneSide(feeder));
        Assert.StartsWith("Each book scan becomes two pages", BookPages.Hint(feeder));
    }
}
