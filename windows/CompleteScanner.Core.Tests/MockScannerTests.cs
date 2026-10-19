using CompleteScanner.Core;
using Xunit;

namespace CompleteScanner.Core.Tests;

// The demo scanner's feeder. Mirrored by Tests/CompleteScannerTests/MockScannerTests.swift.

public class MockScannerTests
{
    private const int Dpi = 75;

    private static async Task<(MockScannerBackend Backend, IScannerSession Session)> Open()
    {
        var backend = new MockScannerBackend();
        backend.StartBrowsing();
        var session = await backend.OpenSessionAsync("mock:demo");
        return (backend, session);
    }

    private static ScanSettings FeederSettings(ScanIntent intent = ScanIntent.Document,
                                               DuplexMode duplex = DuplexMode.Off) => new()
    {
        Source = ScanSource.DocumentFeeder,
        Resolution = Dpi,
        Intent = intent,
        Duplex = duplex,
    };

    /// <summary>Dark runs along the row through the middle of the sheet marks (0.8 in above the bottom edge).</summary>
    private static int SheetMarks(RgbaImage image) => DarkRuns(image, (int)(image.Height - 0.8 * Dpi)).Count;

    /// <summary>The sheet marks sit on the left half of the page (a front) rather than the right (a back).</summary>
    private static bool MarksOnTheLeft(RgbaImage image) =>
        DarkRuns(image, (int)(image.Height - 0.8 * Dpi)) is { Count: > 0 } runs && runs[0] < image.Width / 2;

    /// <summary>Where each dark run along row <paramref name="y"/> starts.</summary>
    private static List<int> DarkRuns(RgbaImage image, int y)
    {
        var starts = new List<int>();
        bool dark = false;
        for (int x = 0; x < image.Width; x++)
        {
            bool isDark = image.Pixels[(y * image.Width + x) * 4] < 128;
            if (isDark && !dark) starts.Add(x);
            dark = isDark;
        }
        return starts;
    }

    [Fact]
    public async Task DemoScannerHasAFeeder()
    {
        var (_, session) = await Open();
        var caps = await session.GetCapabilitiesAsync();
        Assert.Equal([ScanSource.Flatbed, ScanSource.DocumentFeeder], caps.Sources);
        Assert.Equal(new SizeD(8.5, 14), caps.FeederSizeInches);
        Assert.True(caps.SupportsDuplex);
        Assert.True(caps.SupportsOverview);
    }

    [Fact]
    public async Task DemoFeederCanScanOneSideOnly()
    {
        var (backend, session) = await Open();
        backend.FeederDuplex = false;
        Assert.False((await session.GetCapabilitiesAsync()).SupportsDuplex);
        // Asked for both sides anyway: the fronts, and the session says it scanned one side.
        var pages = await session.PerformScanAsync(FeederSettings(duplex: DuplexMode.Both), selection: null);
        Assert.Equal(3, pages.Count);
        Assert.All(pages, page => Assert.True(MarksOnTheLeft(page.Image)));
        Assert.False(session.LastScanDuplex);
    }

    [Fact]
    public async Task TheSessionSaysWhetherItScannedBothSides()
    {
        var (_, session) = await Open();
        await session.PerformScanAsync(FeederSettings(duplex: DuplexMode.Both), selection: null);
        Assert.True(session.LastScanDuplex);
        // Not asked for: nothing to say.
        await session.PerformScanAsync(FeederSettings(duplex: DuplexMode.Manual), selection: null);
        Assert.Null(session.LastScanDuplex);
        await session.PerformScanAsync(FeederSettings(), selection: null);
        Assert.Null(session.LastScanDuplex);
    }

    [Fact]
    public async Task TwoSidedFeederDeliversFrontBackPairs()
    {
        var (_, session) = await Open();
        var pages = await session.PerformScanAsync(FeederSettings(duplex: DuplexMode.Both), selection: null);
        Assert.Equal(6, pages.Count);
        for (int i = 0; i < pages.Count; i++)
        {
            Assert.Equal(i / 2 + 1, SheetMarks(pages[i].Image));
            // Fronts carry their marks on the left, backs on the right; both upright.
            Assert.Equal(i % 2 == 0, MarksOnTheLeft(pages[i].Image));
            Assert.Equal(11 * Dpi, pages[i].Image.Height);
        }
        Assert.Equal(6, pages.Select(p => p.Id).Distinct().Count());
    }

    [Fact]
    public async Task BlankBacks_LookBlank_TheOtherSidesDoNot()
    {
        var (backend, session) = await Open();
        Assert.Empty(backend.FeederBlankBackSheets);
        backend.FeederBlankBackSheets = [1];
        var pages = await session.PerformScanAsync(FeederSettings(duplex: DuplexMode.Both), selection: null);
        Assert.Equal(6, pages.Count);
        var blank = pages.Select(p => BlankPageDetector.Analyze(p.Image, p.Dpi).IsBlank).ToList();
        Assert.Equal([false, false, false, true, false, false], blank);
        // The blank back is paper, not white: noise and the front showing through.
        var back = pages[3].Image;
        Assert.Equal(0, SheetMarks(back));
        Assert.InRange(back.Pixels.Where((_, i) => i % 4 == 0).Average(b => b), 225, 250);
        Assert.Contains(back.Pixels.Where((_, i) => i % 4 == 0), b => b < 236);
        // Deterministic: the same sheet looks the same every time.
        var again = await session.PerformScanAsync(FeederSettings(duplex: DuplexMode.Both), selection: null);
        Assert.Equal(back.Pixels, again[3].Image.Pixels);
        Assert.Equal(pages[2].Image.Pixels, again[2].Image.Pixels);
    }

    [Fact]
    public async Task BlankBacks_TurnedOverByHand_ComeInTheBacksScan()
    {
        var (backend, session) = await Open();
        backend.FeederBlankBackSheets = [0, 2];
        var fronts = await session.PerformScanAsync(FeederSettings(duplex: DuplexMode.Manual), selection: null);
        Assert.All(fronts, p => Assert.False(BlankPageDetector.Analyze(p.Image, p.Dpi).IsBlank));
        var backs = await session.PerformScanAsync(FeederSettings(duplex: DuplexMode.Manual), selection: null);
        // Last sheet first: sheets 2, 1, 0.
        Assert.Equal([true, false, true], backs.Select(p => BlankPageDetector.Analyze(p.Image, p.Dpi).IsBlank));
        Assert.Equal(2, SheetMarks(backs[1].Image));
    }

    [Fact]
    public async Task TwoSidedJamKeepsTheSheetsBeforeIt()
    {
        var (backend, session) = await Open();
        backend.FeederJamsAfter = 1;
        var pages = await session.PerformScanAsync(FeederSettings(duplex: DuplexMode.Both), selection: null);
        Assert.Equal(2, pages.Count);
        Assert.Equal(ScannerProblem.PaperJam, session.LastScanStop?.Problem);
    }

    [Fact]
    public async Task TurningOverByHand_TheSecondScanDeliversTheBacksLastSheetFirst()
    {
        var (backend, session) = await Open();
        var fronts = await session.PerformScanAsync(FeederSettings(duplex: DuplexMode.Manual), selection: null);
        Assert.Equal([1, 2, 3], fronts.Select(p => SheetMarks(p.Image)));
        Assert.All(fronts, page => Assert.True(MarksOnTheLeft(page.Image)));
        Assert.True(backend.FeederStackTurnedOver);

        var backs = await session.PerformScanAsync(FeederSettings(duplex: DuplexMode.Manual), selection: null);
        Assert.Equal([3, 2, 1], backs.Select(p => SheetMarks(p.Image)));
        Assert.All(backs, page => Assert.False(MarksOnTheLeft(page.Image)));
        Assert.False(backend.FeederStackTurnedOver);
    }

    [Fact]
    public async Task TurningOverByHand_AJamLeavesTheStackAsItIs()
    {
        var (backend, session) = await Open();
        backend.FeederJamsAfter = 2;
        var fronts = await session.PerformScanAsync(FeederSettings(duplex: DuplexMode.Manual), selection: null);
        Assert.Equal([1, 2], fronts.Select(p => SheetMarks(p.Image)));
        Assert.NotNull(session.LastScanStop);
        // The rest of the fronts comes next, not the backs.
        Assert.False(backend.FeederStackTurnedOver);
        backend.FeederJamsAfter = null;
        var more = await session.PerformScanAsync(FeederSettings(duplex: DuplexMode.Manual), selection: null);
        Assert.All(more, page => Assert.True(MarksOnTheLeft(page.Image)));
        Assert.True(backend.FeederStackTurnedOver);
    }

    [Fact]
    public async Task OtherScansLoadTheStackTheRightWayUp()
    {
        var (backend, session) = await Open();
        backend.FeederStackTurnedOver = true;
        var backs = await session.PerformScanAsync(FeederSettings(), selection: null);
        Assert.All(backs, page => Assert.False(MarksOnTheLeft(page.Image)));
        Assert.False(backend.FeederStackTurnedOver);
        var fronts = await session.PerformScanAsync(FeederSettings(), selection: null);
        Assert.All(fronts, page => Assert.True(MarksOnTheLeft(page.Image)));
    }

    [Fact]
    public async Task FeederScansThePaperSize()
    {
        var (_, session) = await Open();
        var settings = FeederSettings();
        settings.PaperSize = PaperSize.A4;
        var a4 = await session.PerformScanAsync(settings, selection: null);
        Assert.All(a4, page => Assert.Equal(((int)(8.2677 * Dpi), (int)(11.6929 * Dpi)), (page.Image.Width, page.Image.Height)));
        Assert.Equal(1, SheetMarks(a4[0].Image));
        settings.PaperSize = PaperSize.Legal;
        var legal = await session.PerformScanAsync(settings, selection: null);
        Assert.All(legal, page => Assert.Equal(14 * Dpi, page.Image.Height));
    }

    [Fact]
    public async Task FeederScanDeliversThreeNumberedSheets()
    {
        var (_, session) = await Open();
        var pages = await session.PerformScanAsync(FeederSettings(), selection: null);
        Assert.Equal(MockScannerBackend.DefaultFeederSheetCount, pages.Count);
        Assert.Equal(3, pages.Count);
        for (int i = 0; i < pages.Count; i++)
        {
            Assert.Equal(Dpi, pages[i].Dpi);
            Assert.Equal((int)(8.5 * Dpi), pages[i].Image.Width);
            Assert.Equal(11 * Dpi, pages[i].Image.Height);
            Assert.Equal(i + 1, SheetMarks(pages[i].Image));
        }
        Assert.Equal(3, pages.Select(p => p.Id).Distinct().Count());
    }

    [Fact]
    public async Task FeederIgnoresTheSelection()
    {
        var (_, session) = await Open();
        var pages = await session.PerformScanAsync(FeederSettings(), new RectD(0.1, 0.1, 0.3, 0.3));
        Assert.All(pages, page => Assert.Equal(11 * Dpi, page.Image.Height));
    }

    [Fact]
    public async Task FeederPhotoSheetsHoldOnePhotoEach()
    {
        var (_, session) = await Open();
        var pages = await session.PerformScanAsync(FeederSettings(ScanIntent.Photo), selection: null);
        Assert.Equal(3, pages.Count);
        Assert.All(pages, page => Assert.Single(PhotoDetector.DetectRegions(page.Image, page.Dpi)));
    }

    [Fact]
    public async Task SheetCountIsReadWhenTheScanStarts()
    {
        var (backend, session) = await Open();
        backend.FeederSheetCount = 1;
        Assert.Single(await session.PerformScanAsync(FeederSettings(), selection: null));
    }

    [Fact]
    public async Task EmptyFeederAsksForPaper()
    {
        var (backend, session) = await Open();
        backend.FeederSheetCount = 0;
        var error = await Assert.ThrowsAsync<ScanException>(() => session.PerformScanAsync(FeederSettings(), null));
        Assert.Equal(ScannerProblem.FeederEmpty, error.Problem);
        Assert.Equal(ScannerProblems.Describe(ScannerProblem.FeederEmpty), error.Message);
    }

    [Fact]
    public async Task AFullBatchHasNoStop()
    {
        var (_, session) = await Open();
        await session.PerformScanAsync(FeederSettings(), selection: null);
        Assert.Null(session.LastScanStop);
    }

    [Fact]
    public async Task AJamPartwayKeepsTheSheetsAndSaysWhy()
    {
        var (backend, session) = await Open();
        backend.FeederJamsAfter = 2;
        var pages = await session.PerformScanAsync(FeederSettings(), selection: null);
        Assert.Equal(2, pages.Count);
        Assert.Equal(1, SheetMarks(pages[0].Image));
        Assert.Equal(2, SheetMarks(pages[1].Image));
        var stop = Assert.IsType<ScanStop>(session.LastScanStop);
        Assert.Equal(ScannerProblem.PaperJam, stop.Problem);
        Assert.Equal(ScannerProblems.Describe(ScannerProblem.PaperJam), stop.Reason);
    }

    [Fact]
    public async Task AJamOnTheFirstSheetFailsTheScan()
    {
        var (backend, session) = await Open();
        backend.FeederJamsAfter = 0;
        var error = await Assert.ThrowsAsync<ScanException>(() => session.PerformScanAsync(FeederSettings(), null));
        Assert.Equal(ScannerProblem.PaperJam, error.Problem);
        Assert.Null(session.LastScanStop);
    }

    [Fact]
    public async Task TheNextScanClearsTheStop()
    {
        var (backend, session) = await Open();
        backend.FeederJamsAfter = 1;
        Assert.Single(await session.PerformScanAsync(FeederSettings(), selection: null));
        Assert.NotNull(session.LastScanStop);
        backend.FeederJamsAfter = null;
        Assert.Equal(3, (await session.PerformScanAsync(FeederSettings(), selection: null)).Count);
        Assert.Null(session.LastScanStop);
    }

    [Fact]
    public async Task FlatbedStillScansOneBed()
    {
        var (_, session) = await Open();
        var pages = await session.PerformScanAsync(new ScanSettings { Resolution = Dpi }, selection: null);
        var page = Assert.Single(pages);
        Assert.Equal((int)(11.7 * Dpi), page.Image.Height);
    }

    // MARK: - ID card

    private static ScanSettings IdCardSettings(int dpi)
    {
        var settings = TaskCatalog.Apply(ScanTask.IdCard, new ScanSettings());
        settings.Resolution = dpi;
        return settings;
    }

    [Fact]
    public async Task IdCardScansTurnTheSampleCardOver()
    {
        var (backend, session) = await Open();
        Assert.False(backend.IdCardTurnedOver);
        // A preview shows the side facing the glass without turning the card.
        var preview = await session.PerformOverviewScanAsync(IdCardSettings(Dpi));
        Assert.False(backend.IdCardTurnedOver);
        var front = Assert.Single(await session.PerformScanAsync(IdCardSettings(Dpi), selection: null)).Image;
        Assert.True(backend.IdCardTurnedOver);
        var back = Assert.Single(await session.PerformScanAsync(IdCardSettings(Dpi), selection: null)).Image;
        Assert.False(backend.IdCardTurnedOver);
        var frontAgain = Assert.Single(await session.PerformScanAsync(IdCardSettings(Dpi), selection: null)).Image;
        Assert.Equal((front.Width, front.Height), (back.Width, back.Height));
        Assert.Equal((int)(11.7 * Dpi), front.Height);
        Assert.NotEqual(front.Pixels, back.Pixels);
        Assert.Equal(front.Pixels, frontAgain.Pixels);
        Assert.Equal((int)(11.7 * 100), preview.Height);
        // Other scans do not touch the card.
        await session.PerformScanAsync(new ScanSettings { Resolution = Dpi }, selection: null);
        Assert.True(backend.IdCardTurnedOver);
    }

    [Fact]
    public async Task TheSampleCardIsFoundAtIdOneSize()
    {
        var (_, session) = await Open();
        foreach (double angle in new[] { 4.0, -4.0 })
        {
            var scan = Assert.Single(await session.PerformScanAsync(IdCardSettings(150), selection: null));
            var pick = IdCardDetector.Detect(scan.Image, 150);
            Assert.Equal(IdCardPickKind.Card, pick.Kind);
            double longSide = Math.Max(pick.Region.Size.Width, pick.Region.Size.Height) / 150;
            double shortSide = Math.Min(pick.Region.Size.Width, pick.Region.Size.Height) / 150;
            Assert.InRange(longSide, 3.370 - 0.05, 3.370 + 0.05);
            Assert.InRange(shortSide, 2.125 - 0.05, 2.125 + 0.05);
            Assert.InRange(pick.Region.AngleDegrees, angle - 0.5, angle + 0.5);
            Assert.InRange(pick.Region.Center.X / 150, 2.30, 2.40);
            Assert.InRange(pick.Region.Center.Y / 150, 1.70, 1.80);
        }
    }

    // MARK: - Receipts

    [Fact]
    public async Task TheDemoReceiptsAreFoundApart_AlongTheirPaper()
    {
        var (_, session) = await Open();
        var settings = TaskCatalog.Apply(ScanTask.Receipt, new ScanSettings());
        settings.Resolution = 150;
        var preview = await session.PerformOverviewScanAsync(settings);
        Assert.Equal((int)(11.7 * 100), preview.Height);
        var scan = Assert.Single(await session.PerformScanAsync(settings, selection: null));
        var found = ReceiptDetector.Find(scan.Image, 150);
        var places = MockBedRenderer.ReceiptPlaces;
        Assert.Equal(places.Count, found.Count);
        for (int i = 0; i < found.Count; i++)
        {
            var region = found[i].Region;
            var place = places[i];
            Assert.Equal(ReceiptBasis.Paper, found[i].Basis);
            Assert.InRange(region.Center.X / 150, place.CenterInches.X - 0.05, place.CenterInches.X + 0.05);
            Assert.InRange(region.Center.Y / 150, place.CenterInches.Y - 0.05, place.CenterInches.Y + 0.05);
            Assert.InRange(region.Size.Width / 150, place.SizeInches.Width - 0.08, place.SizeInches.Width + 0.08);
            Assert.InRange(region.Size.Height / 150, place.SizeInches.Height - 0.08, place.SizeInches.Height + 0.08);
            Assert.InRange(region.AngleDegrees, place.AngleDegrees - 0.5, place.AngleDegrees + 0.5);
        }
        // Other tasks keep the usual bed.
        var document = Assert.Single(await session.PerformScanAsync(new ScanSettings { Resolution = 150 }, selection: null));
        Assert.NotEqual(scan.Image.Pixels, document.Image.Pixels);
    }
}
