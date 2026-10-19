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

    private static ScanSettings FeederSettings(ScanIntent intent = ScanIntent.Document) => new()
    {
        Source = ScanSource.DocumentFeeder,
        Resolution = Dpi,
        Intent = intent,
    };

    /// <summary>Dark runs along the row through the middle of the sheet marks (0.8 in above the bottom edge).</summary>
    private static int SheetMarks(RgbaImage image)
    {
        int y = (int)((11 - 0.8) * Dpi);
        int runs = 0;
        bool dark = false;
        for (int x = 0; x < image.Width; x++)
        {
            bool isDark = image.Pixels[(y * image.Width + x) * 4] < 128;
            if (isDark && !dark) runs++;
            dark = isDark;
        }
        return runs;
    }

    [Fact]
    public async Task DemoScannerHasAFeeder()
    {
        var (_, session) = await Open();
        var caps = await session.GetCapabilitiesAsync();
        Assert.Equal([ScanSource.Flatbed, ScanSource.DocumentFeeder], caps.Sources);
        Assert.Equal(new SizeD(8.5, 11), caps.FeederSizeInches);
        Assert.False(caps.SupportsDuplex);
        Assert.True(caps.SupportsOverview);
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
}
