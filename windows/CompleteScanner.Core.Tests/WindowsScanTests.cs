using CompleteScanner.Core;
using Xunit;

namespace CompleteScanner.Core.Tests;

// The Windows Scan connection (WinRT ImageScanner) is Windows only: no Swift twin.

public class WindowsScanTests
{
    private static ScannerInfo Wia(string name, string? model = null) =>
        new($"wia:{{6BDD1FC6-810F-11D0-BEC7-08002BE2092F}}\\0001#{name}", name, "WIA", Backend: "wia", Model: model);

    private static ScannerInfo WinRt(string name, string id = @"\\?\SWD#IMAGE#0001") => WindowsScanConnection.Info(id, name);

    private static ScannerInfo Twain(string name) => new($"twain:{name}", name, "USB", Backend: "twain");

    private static ScannerInfo Escl(string name) => new($"escl:{name}", name, "Network", Backend: "escl", Model: name);

    private static readonly WindowsScanSourceFacts Flatbed = new()
    {
        Source = ScanSource.Flatbed,
        MinDpi = 50,
        MaxDpi = 4800,
        OpticalDpi = 1200,
        MinScanAreaInches = new SizeD(0.5, 0.5),
        MaxScanAreaInches = new SizeD(8.5, 11.69),
        ColorModes = [WindowsScanColorMode.Color, WindowsScanColorMode.Grayscale, WindowsScanColorMode.Monochrome],
        Formats = [WindowsScanFormat.Jpeg, WindowsScanFormat.DeviceIndependentBitmap, WindowsScanFormat.Png],
        PreviewSupported = true,
    };

    private static readonly WindowsScanSourceFacts Feeder = new()
    {
        Source = ScanSource.DocumentFeeder,
        MinDpi = 100,
        MaxDpi = 600,
        OpticalDpi = 600,
        MaxScanAreaInches = new SizeD(8.5, 14),
        ColorModes = [WindowsScanColorMode.Color, WindowsScanColorMode.Grayscale],
        Formats = [WindowsScanFormat.Jpeg],
        CanScanDuplex = true,
        CanAutoDetectPageSize = true,
        PageSizes = [PaperSize.Letter, PaperSize.Legal, PaperSize.A4],
    };

    private static ScanSettings Settings(ScanSource source = ScanSource.Flatbed, int dpi = 300,
                                         ColorMode color = ColorMode.Color, DuplexMode duplex = DuplexMode.Off,
                                         PaperSize paper = PaperSize.Auto) =>
        new() { Source = source, Resolution = dpi, ColorMode = color, Duplex = duplex, PaperSize = paper };

    // MARK: - The connection in the device list

    [Fact]
    public void Info_IsAWindowsScanEntryWithItsOwnLabel()
    {
        var info = WinRt("  Canon LiDE 300  ");
        Assert.Equal(@"winrt:\\?\SWD#IMAGE#0001", info.Id);
        Assert.Equal("Canon LiDE 300", info.Name);
        Assert.Equal("winrt", info.Backend);
        Assert.Equal("Windows Scan (backup)", info.Transport);
        Assert.Null(info.Model);
        Assert.Null(info.HardwareId);
        Assert.False(info.IsDemo);
        Assert.Equal("Windows Scan (backup)", DeviceMerge.ConnectionLabel(info));
        Assert.Equal("winrt:Windows Scan (backup)", DeviceMerge.ConnectionId(info));
        Assert.Equal("Scanner", WindowsScanConnection.Info("x", "  ").Name);
        Assert.Equal("Scanner", WindowsScanConnection.Info("x", null).Name);
    }

    [Fact]
    public void DeviceId_ComesBackOnlyFromWindowsScanIds()
    {
        Assert.Equal(@"\\?\SWD#IMAGE#0001", WindowsScanConnection.DeviceId(WinRt("A").Id));
        Assert.Null(WindowsScanConnection.DeviceId("wia:{6BDD}\\0001"));
        Assert.Null(WindowsScanConnection.DeviceId("winrt:"));
        Assert.Null(WindowsScanConnection.DeviceId("WINRT:x"));
    }

    [Fact]
    public void WindowsRanking_DoesNotListWindowsScan()
    {
        // It ranks after every listed connection because no pattern matches it.
        Assert.DoesNotContain(DeviceMerge.WindowsRanking, pattern => pattern.StartsWith("winrt", StringComparison.OrdinalIgnoreCase)
                                                                    || pattern.StartsWith("*", StringComparison.Ordinal));
    }

    [Fact]
    public void Merge_JoinsTheWiaEntryAndKeepsWiaInUse()
    {
        var wia = Wia("Canon LiDE 300", model: "Canon Canon LiDE 300");
        var winrt = WinRt("Canon LiDE 300");
        foreach (var order in new[] { new[] { wia, winrt }, [winrt, wia] })
        {
            var group = Assert.Single(DeviceMerge.Group(order, DeviceMerge.WindowsRanking));
            Assert.Same(wia, group.Primary);
            Assert.Equal(2, group.Members.Count);
        }
    }

    [Fact]
    public void Merge_RanksWindowsScanAfterNetworkAndTwain()
    {
        var winrt = WinRt("HP LaserJet MFP M428fdw");
        Assert.Equal("escl", Assert.Single(DeviceMerge.Group([winrt, Escl("HP LaserJet MFP M428fdw")], DeviceMerge.WindowsRanking)).Primary.Backend);
        Assert.Equal("twain", Assert.Single(DeviceMerge.Group([winrt, Twain("HP LaserJet MFP M428fdw")], DeviceMerge.WindowsRanking)).Primary.Backend);
    }

    [Fact]
    public void Merge_UsesWindowsScanWhenItIsTheOnlyConnection()
    {
        var winrt = WinRt("Epson Perfection V39");
        var group = Assert.Single(DeviceMerge.Group([winrt], DeviceMerge.WindowsRanking));
        Assert.Same(winrt, group.Primary);
        Assert.Equal("model:epson perfection v39", group.Key);
    }

    [Fact]
    public void Merge_ComesBeforeThe32BitHelperListedAfterIt()
    {
        // Both rank last; the app lists Windows Scan's backend before the helper's.
        var winrt = WinRt("Fujitsu fi-7160");
        var helper = new ScannerInfo("twain32:Fujitsu fi-7160", "Fujitsu fi-7160 (32-bit driver)", "TWAIN (32-bit driver)",
                                     Backend: "twain32", Model: "Fujitsu fi-7160");
        Assert.Same(winrt, Assert.Single(DeviceMerge.Group([winrt, helper], DeviceMerge.WindowsRanking)).Primary);
    }

    [Fact]
    public void Merge_TheUsersChoiceTakesWindowsScan()
    {
        var wia = Wia("Canon LiDE 300");
        var winrt = WinRt("Canon LiDE 300");
        var key = Assert.Single(DeviceMerge.Group([wia, winrt], DeviceMerge.WindowsRanking)).Key;
        var chosen = new Dictionary<string, string> { [key] = DeviceMerge.ConnectionId(winrt) };
        Assert.Same(winrt, Assert.Single(DeviceMerge.Group([wia, winrt], DeviceMerge.WindowsRanking, chosen)).Primary);
        // The choice outlives the connection: without it, WIA again.
        Assert.Same(wia, Assert.Single(DeviceMerge.Group([wia], DeviceMerge.WindowsRanking, chosen)).Primary);
    }

    [Fact]
    public void Merge_TwoWindowsScanEntriesStayApart()
    {
        var groups = DeviceMerge.Group([WinRt("Canon LiDE 300", "a"), WinRt("Canon LiDE 300", "b")], DeviceMerge.WindowsRanking);
        Assert.Equal(2, groups.Count);
    }

    // MARK: - Capabilities

    [Fact]
    public void Capabilities_FlatbedAndTwoSidedFeeder()
    {
        var caps = WindowsScanCapabilities.Map(Flatbed, Feeder);
        Assert.Equal([ScanSource.Flatbed, ScanSource.DocumentFeeder], caps.Sources);
        Assert.True(caps.SupportsOverview);
        Assert.True(caps.SupportsDuplex);
        Assert.Equal(new SizeD(8.5, 11.69), caps.FlatbedSizeInches);
        Assert.Equal(new SizeD(8.5, 14), caps.FeederSizeInches);
        // The flatbed's: 50 to 4800 dpi, nothing above the optical 1200.
        Assert.Equal([50, 72, 75, 100, 150, 200, 240, 300, 400, 600, 800, 1200], caps.SupportedResolutions);
    }

    [Fact]
    public void Capabilities_FeederOnly()
    {
        var caps = WindowsScanCapabilities.Map(null, Feeder with { CanScanDuplex = false });
        Assert.Equal([ScanSource.DocumentFeeder], caps.Sources);
        Assert.False(caps.SupportsOverview);
        Assert.False(caps.SupportsDuplex);
        Assert.Equal([100, 150, 200, 240, 300, 400, 600], caps.SupportedResolutions);
        Assert.Equal(new SizeD(8.5, 14), caps.FeederSizeInches);
    }

    [Fact]
    public void Capabilities_DeviceThatConfiguresItself()
    {
        var caps = WindowsScanCapabilities.Map(null, null);
        Assert.Equal([ScanSource.Flatbed], caps.Sources);
        Assert.False(caps.SupportsOverview);
        Assert.False(caps.SupportsDuplex);
        Assert.Null(caps.FeederSizeInches);
        Assert.Equal(WindowsScanCapabilities.FallbackResolutions, caps.SupportedResolutions);
    }

    [Fact]
    public void Capabilities_AnUnreadableMaximumIsUnknownNotTheMinimum()
    {
        // The driver reported its minimum but refused its maximum (read as 0).
        var maxUnread = Flatbed with { MinDpi = 50, MaxDpi = 0, OpticalDpi = 0 };
        Assert.Equal(WindowsScanCapabilities.FallbackResolutions, WindowsScanCapabilities.Map(maxUnread, null).SupportedResolutions);
        Assert.Equal(300, WindowsScanRequest.Plan(Settings(dpi: 300), null, maxUnread).Dpi);
    }

    [Fact]
    public void Capabilities_UnknownSizesAndResolutionsKeepTheDefaults()
    {
        var unknown = new WindowsScanSourceFacts { Source = ScanSource.Flatbed };
        var caps = WindowsScanCapabilities.Map(unknown, Feeder with { MaxScanAreaInches = SizeD.Zero });
        Assert.Equal(new ScannerCapabilities().FlatbedSizeInches, caps.FlatbedSizeInches);
        Assert.Null(caps.FeederSizeInches);
        Assert.Equal(WindowsScanCapabilities.FallbackResolutions, caps.SupportedResolutions);
    }

    // MARK: - The scan request

    [Fact]
    public void Plan_FlatbedSelectionInInches()
    {
        var plan = WindowsScanRequest.Plan(Settings(), new RectD(0.5, 0.25, 0.5, 0.5), Flatbed);
        Assert.Equal(WindowsScanSource.Flatbed, plan.Source);
        Assert.Equal(300, plan.Dpi);
        Assert.Equal(WindowsScanColorMode.Color, plan.ColorMode);
        Assert.Equal(WindowsScanFormat.Png, plan.Format);
        Assert.Equal(new RectD(4.25, 11.69 * 0.25, 4.25, 11.69 * 0.5), plan.RegionInches);
        Assert.False(plan.Duplex);
        Assert.Null(plan.PageSize);
        Assert.Null(plan.AutoDetectPageSize);
    }

    [Fact]
    public void Plan_FlatbedWithoutSelectionScansTheWholeGlass()
    {
        var full = new RectD(0, 0, 8.5, 11.69);
        Assert.Equal(full, WindowsScanRequest.Plan(Settings(), null, Flatbed).RegionInches);
        // A selection with no area, or off the glass, is no selection.
        Assert.Equal(full, WindowsScanRequest.Plan(Settings(), new RectD(0.2, 0.2, 0, 0.5), Flatbed).RegionInches);
        Assert.Equal(full, WindowsScanRequest.Plan(Settings(), new RectD(2, 2, 0.5, 0.5), Flatbed).RegionInches);
        // An unknown glass leaves the device's area alone.
        Assert.Null(WindowsScanRequest.Plan(Settings(), new RectD(0, 0, 0.5, 0.5), Flatbed with { MaxScanAreaInches = SizeD.Zero }).RegionInches);
    }

    [Fact]
    public void Plan_SmallSelectionGrowsToTheSmallestAreaAndStaysOnTheGlass()
    {
        // 0.085 x 0.117 in at the far corner: grown to 0.5 x 0.5 in, moved back onto the glass.
        var plan = WindowsScanRequest.Plan(Settings(), new RectD(0.99, 0.99, 0.01, 0.01), Flatbed);
        var region = plan.RegionInches!.Value;
        Assert.Equal(0.5, region.Width, 9);
        Assert.Equal(0.5, region.Height, 9);
        Assert.Equal(8.0, region.X, 9);
        Assert.Equal(11.19, region.Y, 9);
        // A reversed rectangle is read the right way round.
        var reversed = WindowsScanRequest.Plan(Settings(), new RectD(1, 1, -0.5, -0.5), Flatbed).RegionInches!.Value;
        Assert.Equal(new RectD(4.25, 11.69 * 0.5, 4.25, 11.69 * 0.5), reversed);
    }

    [Theory]
    [InlineData(300, 300)]
    [InlineData(310, 300)]
    [InlineData(350, 300)] // a tie takes the lower
    [InlineData(1, 50)]
    [InlineData(2400, 1200)] // nothing above the optical resolution
    public void Plan_ResolutionIsTheNearestOffered(int wanted, int expected)
    {
        Assert.Equal(expected, WindowsScanRequest.Plan(Settings(dpi: wanted), null, Flatbed).Dpi);
    }

    [Fact]
    public void Plan_ResolutionAsAskedWhenTheDeviceReportsNone()
    {
        var unknown = Flatbed with { MinDpi = 0, MaxDpi = 0, OpticalDpi = 0 };
        Assert.Equal(333, WindowsScanRequest.Plan(Settings(dpi: 333), null, unknown).Dpi);
    }

    [Theory]
    [InlineData(ColorMode.Color, new[] { 0, 1, 2 }, 0)]
    [InlineData(ColorMode.Grayscale, new[] { 0, 1, 2 }, 1)]
    [InlineData(ColorMode.BlackWhite, new[] { 0, 1, 2 }, 2)]
    [InlineData(ColorMode.BlackWhite, new[] { 0, 1 }, 1)] // gray, which the app turns black and white
    [InlineData(ColorMode.BlackWhite, new[] { 3 }, 3)]
    [InlineData(ColorMode.Grayscale, new[] { 0 }, 0)]
    [InlineData(ColorMode.Color, new[] { 3, 1 }, 3)]
    [InlineData(ColorMode.Color, new[] { 1, 2 }, 1)]
    [InlineData(ColorMode.Color, new int[0], 0)] // nothing listed: as asked
    [InlineData(ColorMode.BlackWhite, new int[0], 2)]
    public void ColorMode_SameKindOrTheNearestListed(ColorMode wanted, int[] supported, int expected)
    {
        var list = supported.Select(value => (WindowsScanColorMode)value).ToList();
        Assert.Equal((WindowsScanColorMode)expected, WindowsScanRequest.ColorModeFor(wanted, list));
    }

    [Fact]
    public void Format_LosslessFirstThenJpegElseTheDevicesOwn()
    {
        Assert.Equal(WindowsScanFormat.Png, WindowsScanRequest.Format([WindowsScanFormat.Jpeg, WindowsScanFormat.Png, WindowsScanFormat.Tiff]));
        Assert.Equal(WindowsScanFormat.Tiff, WindowsScanRequest.Format([WindowsScanFormat.Jpeg, WindowsScanFormat.Tiff, WindowsScanFormat.DeviceIndependentBitmap]));
        Assert.Equal(WindowsScanFormat.DeviceIndependentBitmap, WindowsScanRequest.Format([WindowsScanFormat.Pdf, WindowsScanFormat.DeviceIndependentBitmap, WindowsScanFormat.Jpeg]));
        Assert.Equal(WindowsScanFormat.Jpeg, WindowsScanRequest.Format([WindowsScanFormat.Xps, WindowsScanFormat.Jpeg]));
        Assert.Null(WindowsScanRequest.Format([WindowsScanFormat.Pdf, WindowsScanFormat.Xps, WindowsScanFormat.OpenXps]));
        Assert.Null(WindowsScanRequest.Format([]));
    }

    [Fact]
    public void Plan_FeederAutomaticLetsItMeasureEachSheet()
    {
        var plan = WindowsScanRequest.Plan(Settings(ScanSource.DocumentFeeder, color: ColorMode.BlackWhite), new RectD(0, 0, 0.5, 0.5), Feeder);
        Assert.Equal(WindowsScanSource.Feeder, plan.Source);
        Assert.Equal(WindowsScanColorMode.Grayscale, plan.ColorMode);
        Assert.Equal(WindowsScanFormat.Jpeg, plan.Format);
        // The whole feeder, set first so it only clears an earlier scan's area.
        Assert.Equal(new RectD(0, 0, 8.5, 14), plan.RegionInches);
        Assert.True(plan.RegionFirst);
        Assert.Null(plan.PageSize);
        Assert.True(plan.AutoDetectPageSize);
        // A feeder that cannot scans its largest sheet.
        var fixedSize = WindowsScanRequest.Plan(Settings(ScanSource.DocumentFeeder), null, Feeder with { CanAutoDetectPageSize = false });
        Assert.Null(fixedSize.AutoDetectPageSize);
        Assert.Equal(new RectD(0, 0, 8.5, 14), fixedSize.RegionInches);
        Assert.Null(fixedSize.PageSize);
        // Of unknown size, there is nothing to state.
        Assert.Null(WindowsScanRequest.Plan(Settings(ScanSource.DocumentFeeder), null,
                                            Feeder with { CanAutoDetectPageSize = false, MaxScanAreaInches = SizeD.Zero }).RegionInches);
    }

    [Fact]
    public void Plan_FeederAlwaysStatesTheAreaSoAnEarlierScansDoesNotStay()
    {
        // One session: A5 as an area, then Automatic, then a size by name. Each plan says what
        // to scan, so the device keeps nothing of the scan before.
        var feeder = Feeder with { CanAutoDetectPageSize = false };
        var a5 = WindowsScanRequest.Plan(Settings(ScanSource.DocumentFeeder, paper: PaperSize.A5), null, feeder);
        var auto = WindowsScanRequest.Plan(Settings(ScanSource.DocumentFeeder), null, feeder);
        var letter = WindowsScanRequest.Plan(Settings(ScanSource.DocumentFeeder, paper: PaperSize.Letter), null, feeder);
        Assert.Equal(PaperSizes.FeederRegionInches(PaperSize.A5, new SizeD(8.5, 14)), a5.RegionInches);
        Assert.False(a5.RegionFirst);
        Assert.Equal(new RectD(0, 0, 8.5, 14), auto.RegionInches);
        Assert.Equal(new RectD(0, 0, 8.5, 14), letter.RegionInches);
        Assert.Equal(PaperSize.Letter, letter.PageSize);
        Assert.True(letter.RegionFirst);
        Assert.All(new[] { a5, auto, letter }, plan => Assert.NotNull(plan.RegionInches));
    }

    [Fact]
    public void Plan_FeederPaperSizeByNameWhenItTakesIt()
    {
        var plan = WindowsScanRequest.Plan(Settings(ScanSource.DocumentFeeder, paper: PaperSize.A4), null, Feeder);
        Assert.Equal(PaperSize.A4, plan.PageSize);
        Assert.False(plan.AutoDetectPageSize);
        // The whole feeder first, clearing an earlier scan's area, then the size by name.
        Assert.Equal(new RectD(0, 0, 8.5, 14), plan.RegionInches);
        Assert.True(plan.RegionFirst);
    }

    [Fact]
    public void Plan_FeederPaperSizeAsAnAreaWhenItDoesNotTakeItsName()
    {
        var plan = WindowsScanRequest.Plan(Settings(ScanSource.DocumentFeeder, paper: PaperSize.A5), null, Feeder);
        Assert.Null(plan.PageSize);
        Assert.False(plan.AutoDetectPageSize);
        Assert.Equal(PaperSizes.FeederRegionInches(PaperSize.A5, new SizeD(8.5, 14)), plan.RegionInches);
        // The paper's area is set last, after measuring is turned off.
        Assert.False(plan.RegionFirst);
        // Without the feeder's size there is no area to ask for either.
        var unknown = WindowsScanRequest.Plan(Settings(ScanSource.DocumentFeeder, paper: PaperSize.A5), null,
                                              Feeder with { MaxScanAreaInches = SizeD.Zero, CanAutoDetectPageSize = false });
        Assert.Null(unknown.RegionInches);
        Assert.Null(unknown.PageSize);
        Assert.Null(unknown.AutoDetectPageSize);
    }

    [Fact]
    public void Plan_FeederOfUnknownSizeSaysWhenItSetsNoArea()
    {
        // Of known size, every feeder plan sets the area.
        foreach (var known in new[] { Feeder, Feeder with { CanAutoDetectPageSize = false } })
        {
            foreach (var paper in new[] { PaperSize.Auto, PaperSize.Letter, PaperSize.A5 })
            {
                Assert.True(WindowsScanRequest.Plan(Settings(ScanSource.DocumentFeeder, paper: paper), null, known).SetsFeederArea);
            }
        }
        // Of unknown size, one session: Letter by name sets it; Automatic, and A5 (not taken by
        // name), set nothing, so the session puts back the feeder's own size and area rather
        // than keep Letter.
        var unknown = Feeder with { MaxScanAreaInches = SizeD.Zero, CanAutoDetectPageSize = false };
        var letter = WindowsScanRequest.Plan(Settings(ScanSource.DocumentFeeder, paper: PaperSize.Letter), null, unknown);
        Assert.Equal(PaperSize.Letter, letter.PageSize);
        Assert.True(letter.SetsFeederArea);
        var auto = WindowsScanRequest.Plan(Settings(ScanSource.DocumentFeeder), null, unknown);
        Assert.Equal(new WindowsScanPlan(WindowsScanSource.Feeder, 300, WindowsScanColorMode.Color, WindowsScanFormat.Jpeg, null), auto);
        Assert.False(auto.SetsFeederArea);
        Assert.False(WindowsScanRequest.Plan(Settings(ScanSource.DocumentFeeder, paper: PaperSize.A5), null, unknown).SetsFeederArea);
        // Measuring each sheet still puts them back first: measuring is set after them.
        var measured = WindowsScanRequest.Plan(Settings(ScanSource.DocumentFeeder), null, unknown with { CanAutoDetectPageSize = true });
        Assert.True(measured.AutoDetectPageSize);
        Assert.False(measured.SetsFeederArea);
        // The flatbed's area is the glass or the selection, never the feeder's.
        Assert.False(WindowsScanRequest.Plan(Settings(), null, Flatbed with { MaxScanAreaInches = SizeD.Zero }).SetsFeederArea);
    }

    [Theory]
    [InlineData(DuplexMode.Both, true, true)]
    [InlineData(DuplexMode.Both, false, false)]
    [InlineData(DuplexMode.Off, true, false)]
    [InlineData(DuplexMode.Manual, true, false)]
    public void Plan_TwoSidedOnlyWhenAskedAndTheFeederCan(DuplexMode duplex, bool canScanDuplex, bool expected)
    {
        var plan = WindowsScanRequest.Plan(Settings(ScanSource.DocumentFeeder, duplex: duplex), null, Feeder with { CanScanDuplex = canScanDuplex });
        Assert.Equal(expected, plan.Duplex);
        // The glass never scans two sides.
        Assert.False(WindowsScanRequest.Plan(Settings(duplex: duplex), null, Flatbed).Duplex);
    }

    [Fact]
    public void Plan_WithoutTheSourcesSettings()
    {
        var ex = Assert.Throws<ScanException>(() => WindowsScanRequest.Plan(Settings(ScanSource.DocumentFeeder), null, null));
        Assert.Equal(ScanErrorKind.Unsupported, ex.Kind);
        var auto = WindowsScanRequest.Plan(Settings(dpi: 200), new RectD(0, 0, 0.5, 0.5), null);
        Assert.Equal(new WindowsScanPlan(WindowsScanSource.AutoConfigured, 200, null, null, null), auto);
    }

    [Fact]
    public void Overview_WholeGlassInColorNearest150()
    {
        var plan = WindowsScanRequest.Overview(Flatbed with { ColorModes = [WindowsScanColorMode.Grayscale] });
        Assert.Equal(new WindowsScanPlan(WindowsScanSource.Flatbed, 150, WindowsScanColorMode.Grayscale, WindowsScanFormat.Png,
                                         new RectD(0, 0, 8.5, 11.69)), plan);
        Assert.Equal(200, WindowsScanRequest.Overview(Flatbed with { MinDpi = 200 }).Dpi);
    }

    [Fact]
    public void MediaSizeName_EverySizeButAutomatic()
    {
        Assert.Null(WindowsScanRequest.MediaSizeName(PaperSize.Auto));
        var names = PaperSizes.All.Where(size => size != PaperSize.Auto).Select(WindowsScanRequest.MediaSizeName).ToList();
        Assert.All(names, Assert.NotNull);
        Assert.Equal(names.Count, names.Distinct().Count());
        Assert.Equal("NorthAmericaLetter", WindowsScanRequest.MediaSizeName(PaperSize.Letter));
        Assert.Equal("IsoA4", WindowsScanRequest.MediaSizeName(PaperSize.A4));
        Assert.Equal("CreditCard", WindowsScanRequest.MediaSizeName(PaperSize.IdCard));
    }

    [Theory]
    [InlineData(299.6, 300)]
    [InlineData(0, 0)]
    [InlineData(-75, 0)]
    [InlineData(double.NaN, 0)]
    [InlineData(double.PositiveInfinity, 0)]
    public void Dpi_WholePositiveValues(double value, int expected)
    {
        Assert.Equal(expected, WindowsScanRequest.Dpi(value));
    }

    [Theory]
    [InlineData(300.0, 300)]
    [InlineData(199.6, 200)]
    [InlineData(96.0, 0)] // what a file without a resolution decodes as
    [InlineData(72.0, 0)]
    [InlineData(0.0, 0)]
    [InlineData(-200.0, 0)]
    [InlineData(double.NaN, 0)]
    [InlineData(1e9, 0)]
    public void FileDpi_OnlyAResolutionTheFileReallyRecords(double dpiX, int expected)
    {
        Assert.Equal(expected, WindowsScanRequest.FileDpi(dpiX));
    }

    [Theory]
    [InlineData(600, 200.0, 300, 600)] // what the driver reports comes first
    [InlineData(0, 200.0, 300, 200)] // a device that configures itself: what the file records
    [InlineData(0, 96.0, 300, 300)] // no resolution in the file either: as asked
    [InlineData(0, 0.0, 300, 300)]
    public void PageDpi_ReportedThenTheFileThenAsked(int reported, double fileDpiX, int asked, int expected)
    {
        Assert.Equal(expected, WindowsScanRequest.PageDpi(reported, fileDpiX, asked));
    }

    // MARK: - Failures

    [Fact]
    public void AfterFailure_LikeTheWiaConnection()
    {
        var empty = ScanException.ForProblem(ScannerProblem.FeederEmpty);
        var jam = ScanException.ForProblem(ScannerProblem.PaperJam);
        Assert.Equal(WindowsScanFailureOutcome.Finished, WindowsScanRequest.AfterFailure(empty, 3));
        Assert.Equal(WindowsScanFailureOutcome.Stopped, WindowsScanRequest.AfterFailure(jam, 2));
        Assert.Equal(WindowsScanFailureOutcome.Stopped, WindowsScanRequest.AfterFailure(ScanException.ScanFailed("x"), 1));
        Assert.Equal(WindowsScanFailureOutcome.Fail, WindowsScanRequest.AfterFailure(empty, 0));
        Assert.Equal(WindowsScanFailureOutcome.Fail, WindowsScanRequest.AfterFailure(jam, 0));
        Assert.Equal(WindowsScanFailureOutcome.Fail, WindowsScanRequest.AfterFailure(ScanException.Cancelled(), 4));
    }

    [Fact]
    public void FileOrder_IsScanOrder()
    {
        Assert.Equal(["Scan.png", "Scan (2).png", "Scan (3).png", "Scan (10).png"],
                     WindowsScanRequest.FileOrder(["Scan (10).png", "Scan (3).png", "Scan.png", "Scan (2).png"]));
        Assert.Equal(["page-2.jpg", "Page-09.jpg", "page-10.jpg", "page-10.tif"],
                     WindowsScanRequest.FileOrder(["page-10.tif", "page-10.jpg", "Page-09.jpg", "page-2.jpg"]));
        Assert.Empty(WindowsScanRequest.FileOrder([]));
    }

    public static TheoryData<uint, ScannerProblem> WiaProblems => new()
    {
        { 0x80210003, ScannerProblem.FeederEmpty },
        { 0x80210002, ScannerProblem.PaperJam },
        { 0x80210015, ScannerProblem.Offline },
        { 0x80210006, ScannerProblem.Busy },
        { 0x80210016, ScannerProblem.CoverOpen },
        { 0x80210020, ScannerProblem.MultiFeed },
        { 0x8007048F, ScannerProblem.Offline },
        { 0x80070490, ScannerProblem.Offline },
        { 0x800710DF, ScannerProblem.Offline },
        { 0x80070015, ScannerProblem.Offline },
        { 0x800706BA, ScannerProblem.CommunicationError },
        { 0x800706BE, ScannerProblem.CommunicationError },
        { 0x80010108, ScannerProblem.CommunicationError },
    };

    [Theory]
    [MemberData(nameof(WiaProblems))]
    public void Errors_ScannerProblems(uint hresult, ScannerProblem problem)
    {
        var error = WindowsScanErrors.ToScanException(unchecked((int)hresult), "Some text\r\nfrom Windows");
        Assert.Equal(problem, error.Problem);
        Assert.Equal(ScannerProblems.Kind(problem), error.Kind);
        Assert.StartsWith(ScannerProblems.Describe(problem), error.Message);
        Assert.EndsWith($"(Windows Scan error 0x{hresult:X8})", error.Message);
        Assert.False(WindowsScanErrors.UnavailableToThisApp(unchecked((int)hresult)));
    }

    [Theory]
    [InlineData(0x80004004u)]
    [InlineData(0x800704C7u)]
    public void Errors_CancelledCalls(uint hresult)
    {
        Assert.Equal(ScanErrorKind.Cancelled, WindowsScanErrors.ToScanException(unchecked((int)hresult), null).Kind);
    }

    [Theory]
    [InlineData(0x80004001u)]
    [InlineData(0x80070032u)]
    public void Errors_UnsupportedRequests(uint hresult)
    {
        var error = WindowsScanErrors.ToScanException(unchecked((int)hresult), "Not supported.");
        Assert.Equal(ScanErrorKind.Unsupported, error.Kind);
        Assert.Null(error.Problem);
        Assert.Contains($"0x{hresult:X8}: Not supported.", error.Message);
    }

    [Fact]
    public void Errors_AnythingElseIsAFailedScanWithTheCodeAndFirstLine()
    {
        var error = WindowsScanErrors.ToScanException(unchecked((int)0x80070057), "\r\n  The parameter is incorrect.  \r\n\r\nMore text");
        Assert.Equal(ScanErrorKind.ScanFailed, error.Kind);
        Assert.Null(error.Problem);
        Assert.Equal("Scan failed: Windows Scan error 0x80070057: The parameter is incorrect.", error.Message);
        Assert.Equal("Scan failed: Windows Scan error 0x80004005", WindowsScanErrors.ToScanException(unchecked((int)0x80004005), " ").Message);
    }

    [Theory]
    [InlineData(0x80073D54u, "Windows allows it only to apps installed as a package")]
    [InlineData(0x80070005u, "Windows refused this app access to it")]
    [InlineData(0x80040154u, "this edition of Windows does not have it")]
    [InlineData(0x80040111u, "this edition of Windows does not have it")]
    [InlineData(0x8000000Fu, "this edition of Windows does not have it")]
    public void Errors_TheApiRefusedToThisApp(uint hresult, string why)
    {
        int code = unchecked((int)hresult);
        Assert.True(WindowsScanErrors.UnavailableToThisApp(code));
        Assert.Equal($"{why} (0x{hresult:X8}: First line)", WindowsScanErrors.UnavailableNote(code, "First line\nsecond"));
        Assert.Equal($"{why} (0x{hresult:X8})", WindowsScanErrors.UnavailableNote(code, null));
        var error = WindowsScanErrors.ToScanException(code, "First line", opening: true);
        Assert.Equal(ScanErrorKind.SessionFailed, error.Kind);
        Assert.Equal($"Could not open a session with the scanner: Windows Scan is not available: {why} (0x{hresult:X8}: First line).", error.Message);
    }

    [Fact]
    public void Errors_AnAccessDenialOnceOpenIsAnOrdinaryFailure()
    {
        // E_ACCESSDENIED is also what a folder the app may not write gives (UnauthorizedAccessException).
        Assert.Equal(unchecked((int)WindowsScanErrors.AccessDenied), new UnauthorizedAccessException().HResult);
        var error = WindowsScanErrors.ToScanException(unchecked((int)0x80070005), "Access is denied.");
        Assert.Equal(ScanErrorKind.ScanFailed, error.Kind);
        Assert.Equal("Scan failed: Windows Scan error 0x80070005: Access is denied.", error.Message);
        Assert.Equal(ScanErrorKind.ScanFailed, WindowsScanErrors.ToScanException(unchecked((int)0x80073D54), null).Kind);
    }

    private const int AccessDenied = unchecked((int)0x80070005);

    [Fact]
    public void Access_OneScannerRefusingDoesNotHideTheOthers()
    {
        // Two scanners only Windows Scan reaches; the first one's driver refuses to open.
        var access = new WindowsScanAccess();
        string[] listed = ["a", "b"];
        Assert.False(access.HidesConnection("a", AccessDenied, listed));
        Assert.False(access.HidesConnection("a", AccessDenied, listed));
        // Every listed one refused: it is Windows refusing the API.
        Assert.True(access.HidesConnection("b", AccessDenied, listed));
        // A single scanner refusing is all there is.
        Assert.True(new WindowsScanAccess().HidesConnection("a", AccessDenied, ["a"]));
    }

    [Fact]
    public void Access_NothingHidesItOnceADeviceOpened()
    {
        var access = new WindowsScanAccess();
        Assert.False(access.HidesConnection("a", AccessDenied, ["a", "b"]));
        access.Opened();
        Assert.True(access.AnyOpened);
        Assert.False(access.HidesConnection("b", AccessDenied, ["a", "b"]));
        Assert.False(access.HidesConnection("a", AccessDenied, ["a"]));
        Assert.False(access.HidesConnection("a", unchecked((int)WindowsScanErrors.NoPackageIdentity), ["a"]));
    }

    [Theory]
    [InlineData(0x80073D54u)]
    [InlineData(0x80040154u)]
    [InlineData(0x80040111u)]
    [InlineData(0x8000000Fu)]
    public void Access_CodesOnlyTheApiGivesHideItAtOnce(uint hresult)
    {
        Assert.True(new WindowsScanAccess().HidesConnection("a", unchecked((int)hresult), ["a", "b"]));
    }

    [Fact]
    public void Access_OtherErrorsNeverHideIt()
    {
        var access = new WindowsScanAccess();
        Assert.False(access.HidesConnection("a", unchecked((int)0x80210015), ["a"]));
        Assert.False(access.HidesConnection("a", unchecked((int)WindowsScanErrors.NotFound), ["a"]));
        Assert.False(access.HidesConnection("a", unchecked((int)0x80004005), ["a"]));
    }

    [Fact]
    public void Access_DenialsAreForgottenWhenTheWatcherStartsAgain()
    {
        var access = new WindowsScanAccess();
        Assert.False(access.HidesConnection("a", AccessDenied, ["a", "b"]));
        access.Restart();
        Assert.False(access.HidesConnection("b", AccessDenied, ["a", "b"]));
        Assert.True(access.HidesConnection("a", AccessDenied, ["a", "b"]));
        // A scanner unplugged since it refused leaves only those still listed to ask.
        var unplugged = new WindowsScanAccess();
        Assert.False(unplugged.HidesConnection("a", AccessDenied, ["a", "b"]));
        Assert.True(unplugged.HidesConnection("b", AccessDenied, ["b"]));
    }

    // MARK: - Diagnostics

    [Fact]
    public void Describe_SaysWhatASourceReports()
    {
        Assert.Equal("flatbed: 50-4800 dpi (optical 1200), up to 8.50 x 11.69 in, colors Color Grayscale Monochrome, "
                     + "formats Jpeg DeviceIndependentBitmap Png, preview", Flatbed.Describe());
        Assert.Equal("feeder: 100-600 dpi (optical 600), up to 8.50 x 14.00 in, colors Color Grayscale, formats Jpeg, "
                     + "two-sided, detects page size, sizes Letter Legal A4", Feeder.Describe());
        Assert.Equal("feeder: 0-0 dpi (optical 0), up to 0.00 x 0.00 in, colors none listed, formats none listed, sizes none listed",
                     new WindowsScanSourceFacts { Source = ScanSource.DocumentFeeder }.Describe());
    }

    [Fact]
    public void Report_StatusDevicesAndWhatTheyReported()
    {
        var a = WinRt("Canon LiDE 300", "a");
        var b = WinRt("Epson ES-400", "b");
        var c = WinRt("Auto", "c");
        var facts = new Dictionary<string, IReadOnlyList<WindowsScanSourceFacts>>
        {
            [a.Id] = [Flatbed],
            [c.Id] = [],
        };
        Assert.Equal("Windows Scan (backup): watching, 3 scanner(s)\n"
                     + "  \"Canon LiDE 300\" id=\"winrt:a\"\n"
                     + "    " + Flatbed.Describe() + "\n"
                     + "  \"Epson ES-400\" id=\"winrt:b\"\n"
                     + "  \"Auto\" id=\"winrt:c\"\n"
                     + "    configures itself (no flatbed or feeder settings)\n",
                     WindowsScanDiagnostics.Report(WindowsScanStatus.Running, null, [a, b, c], facts));
        Assert.Equal("Windows Scan (backup): watching, 0 scanner(s)\n",
                     WindowsScanDiagnostics.Report(WindowsScanStatus.Running, " ", [], facts));
        Assert.Equal("Windows Scan (backup): searching\n", WindowsScanDiagnostics.Report(WindowsScanStatus.Searching, null, [], facts));
        Assert.Equal("Windows Scan (backup): off\n", WindowsScanDiagnostics.Report(WindowsScanStatus.Off, null, [], facts));
        Assert.Equal("Windows Scan (backup): unavailable, connection hidden - Windows allows it only to apps installed as a package (0x80073D54)\n",
                     WindowsScanDiagnostics.Report(WindowsScanStatus.Unavailable,
                                                   WindowsScanErrors.UnavailableNote(unchecked((int)0x80073D54), null), [], facts));
    }
}
