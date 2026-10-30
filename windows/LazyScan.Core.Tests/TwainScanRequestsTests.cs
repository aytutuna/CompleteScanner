using LazyScan.Core;
using Xunit;

namespace LazyScan.Core.Tests;

// TWAIN is Windows-only: no Swift counterpart.

public class TwainScanRequestsTests
{
    private static TwainDeviceCaps FlatbedAndFeeder(bool uiControllable = true, bool memory = true) => new()
    {
        HasFlatbed = true,
        HasFeeder = true,
        UIControllable = uiControllable,
        DuplexKind = TwainDuplexKinds.OnePass,
        Resolutions = [75, 100, 150, 200, 300, 600, 1200, 2400],
        NativeResolution = 1200,
        PixelTypes = [TwainPixelTypes.BlackWhite, TwainPixelTypes.Gray, TwainPixelTypes.Rgb],
        FlatbedSizeInches = new SizeD(8.5, 11.69),
        FeederSizeInches = new SizeD(8.5, 100),
        MemoryTransfer = memory,
    };

    private static ScanSettings Settings(ScanSource source = ScanSource.Flatbed, ColorMode mode = ColorMode.Color,
                                         int dpi = 300) =>
        new() { Source = source, ColorMode = mode, Resolution = dpi };

    // MARK: - Capabilities

    [Fact]
    public void Capabilities_ReportTheRealSourcesSizesAndResolutions()
    {
        var caps = TwainScanRequests.Capabilities(FlatbedAndFeeder());
        Assert.Equal([ScanSource.Flatbed, ScanSource.DocumentFeeder], caps.Sources);
        Assert.True(caps.SupportsOverview);
        Assert.True(caps.SupportsDuplex);
        Assert.Equal(new SizeD(8.5, 11.69), caps.FlatbedSizeInches);
        Assert.Equal(new SizeD(8.5, 100), caps.FeederSizeInches);
        // Interpolated resolutions above the optical one are not offered.
        Assert.Equal([75, 100, 150, 200, 300, 600, 1200], caps.SupportedResolutions);
    }

    [Fact]
    public void Capabilities_FeederOnlyScannerHasNoPreview_AndItsSizeComesFromItsSizesList()
    {
        var caps = TwainScanRequests.Capabilities(new TwainDeviceCaps
        {
            HasFlatbed = false,
            HasFeeder = true,
            SupportedSizes = [TwainSizes.A4, TwainSizes.UsLegal],
        });
        Assert.Equal([ScanSource.DocumentFeeder], caps.Sources);
        Assert.False(caps.SupportsOverview);
        Assert.False(caps.SupportsDuplex);
        Assert.Equal(8.5, caps.FeederSizeInches!.Value.Width, 3);
        Assert.Equal(14, caps.FeederSizeInches!.Value.Height, 3);
        // A source that lists no resolutions gets the common ones.
        Assert.Equal(TwainScanRequests.FallbackResolutions, caps.SupportedResolutions);
    }

    [Fact]
    public void Capabilities_FlatbedOnlyScannerHasNoFeederSize()
    {
        var caps = TwainScanRequests.Capabilities(new TwainDeviceCaps { DuplexKind = TwainDuplexKinds.TwoPass });
        Assert.Equal([ScanSource.Flatbed], caps.Sources);
        Assert.Null(caps.FeederSizeInches);
        Assert.False(caps.SupportsDuplex);
        Assert.Equal(TwainScanRequests.DefaultBedInches, caps.FlatbedSizeInches);
    }

    [Fact]
    public void Capabilities_NoPreviewWhenTheDriverAlwaysShowsItsWindow()
    {
        var caps = TwainScanRequests.Capabilities(FlatbedAndFeeder(uiControllable: false));
        Assert.Contains(ScanSource.Flatbed, caps.Sources);
        Assert.False(caps.SupportsOverview);
    }

    // MARK: - Scan requests

    [Fact]
    public void ForScan_TwoSidedOnlyFromATwoSidedFeeder()
    {
        var caps = FlatbedAndFeeder();
        var feeder = Settings(ScanSource.DocumentFeeder);
        Assert.False(TwainScanRequests.ForScan(feeder, null, caps).Duplex);
        feeder.Duplex = DuplexMode.Both;
        Assert.True(TwainScanRequests.ForScan(feeder, null, caps).Duplex);
        // Turning over by hand scans one side at a time.
        feeder.Duplex = DuplexMode.Manual;
        Assert.False(TwainScanRequests.ForScan(feeder, null, caps).Duplex);
        var flatbed = Settings();
        flatbed.Duplex = DuplexMode.Both;
        Assert.False(TwainScanRequests.ForScan(flatbed, null, caps).Duplex);
        feeder.Duplex = DuplexMode.Both;
        var oneSided = new TwainDeviceCaps { HasFlatbed = true, HasFeeder = true, DuplexKind = TwainDuplexKinds.None };
        Assert.False(TwainScanRequests.ForScan(feeder, null, oneSided).Duplex);
    }

    [Fact]
    public void ForScan_FeederPaperSize_ListedSizeOrFrame()
    {
        var settings = Settings(ScanSource.DocumentFeeder);
        settings.PaperSize = PaperSize.A4;
        var unlisted = TwainScanRequests.ForScan(settings, null, FlatbedAndFeeder());
        Assert.Equal(TwainSizes.None, unlisted.SupportedSize);
        Assert.Equal(8.2677, unlisted.FrameInches!.Value.Width, 4);
        Assert.Equal(11.6929, unlisted.FrameInches!.Value.Height, 4);

        var listing = new TwainDeviceCaps
        {
            HasFlatbed = false,
            HasFeeder = true,
            SupportedSizes = [TwainSizes.A4, TwainSizes.UsLetter, TwainSizes.UsLegal],
        };
        Assert.Equal(TwainSizes.A4, TwainScanRequests.ForScan(settings, null, listing).SupportedSize);
        // Larger than the feeder: clamped to its largest sheet.
        settings.PaperSize = PaperSize.Legal;
        var small = new TwainDeviceCaps { HasFlatbed = false, HasFeeder = true, FeederSizeInches = new SizeD(8.5, 11) };
        Assert.Equal(new RectD(0, 0, 8.5, 11), TwainScanRequests.ForScan(settings, null, small).FrameInches);
        // The flatbed takes the paper size as a selection (the app's job).
        var flatbed = Settings();
        flatbed.PaperSize = PaperSize.A5;
        Assert.Equal(TwainSizes.None, TwainScanRequests.ForScan(flatbed, null, FlatbedAndFeeder()).SupportedSize);
    }

    [Fact]
    public void TwainSizes_FromPaperSize()
    {
        Assert.Equal(
            [TwainSizes.None, TwainSizes.UsLetter, TwainSizes.UsLegal, TwainSizes.UsExecutive, TwainSizes.A4,
             TwainSizes.A5, TwainSizes.A6, TwainSizes.JisB5, TwainSizes.None],
            PaperSizes.All.Select(TwainSizes.FromPaperSize));
        foreach (var size in PaperSizes.All.Where(s => TwainSizes.FromPaperSize(s) != TwainSizes.None))
        {
            var twain = TwainSizes.Inches(TwainSizes.FromPaperSize(size))!.Value;
            var app = PaperSizes.Inches(size)!.Value;
            Assert.Equal(app.Width, twain.Width, 2);
            Assert.Equal(app.Height, twain.Height, 2);
        }
    }

    [Theory]
    [InlineData(ColorMode.Color, TwainPixelTypes.Rgb, 8)]
    [InlineData(ColorMode.Grayscale, TwainPixelTypes.Gray, 8)]
    [InlineData(ColorMode.BlackWhite, TwainPixelTypes.BlackWhite, 1)]
    public void ForScan_PicksThePixelTypeAndDepth(ColorMode mode, int pixelType, int bitDepth)
    {
        var request = TwainScanRequests.ForScan(Settings(mode: mode), null, FlatbedAndFeeder());
        Assert.Equal(pixelType, request.PixelType);
        Assert.Equal(bitDepth, request.BitDepth);
        Assert.Equal(mode, request.ColorMode);
    }

    [Fact]
    public void ForScan_FallsBackToARicherPixelTypeTheSourceOffers()
    {
        var colorOnly = new TwainDeviceCaps { PixelTypes = [TwainPixelTypes.Rgb] };
        Assert.Equal(TwainPixelTypes.Rgb, TwainScanRequests.ForScan(Settings(mode: ColorMode.BlackWhite), null, colorOnly).PixelType);
        var grayOnly = new TwainDeviceCaps { PixelTypes = [TwainPixelTypes.Gray, TwainPixelTypes.BlackWhite] };
        Assert.Equal(TwainPixelTypes.Gray, TwainScanRequests.ForScan(Settings(mode: ColorMode.Color), null, grayOnly).PixelType);
    }

    [Fact]
    public void ForScan_Flatbed_UsesTheSelectionOfTheBedAndTheNearestResolution()
    {
        var request = TwainScanRequests.ForScan(Settings(dpi: 250), new RectD(0.5, 0.25, 0.5, 0.5), FlatbedAndFeeder());
        Assert.False(request.Feeder);
        Assert.Equal(1, request.TransferCount);
        Assert.Equal(200, request.Resolution); // 200 and 300 are equally near; the lower wins
        var frame = request.FrameInches!.Value;
        Assert.Equal(4.25, frame.X, 6);
        Assert.Equal(11.69 * 0.25, frame.Y, 6);
        Assert.Equal(4.25, frame.Width, 6);
        Assert.Equal(11.69 * 0.5, frame.Height, 6);

        var whole = TwainScanRequests.ForScan(Settings(), null, FlatbedAndFeeder());
        Assert.Equal(new RectD(0, 0, 8.5, 11.69), whole.FrameInches);
    }

    [Fact]
    public void ForScan_Feeder_ScansEverySheetAtTheFeedersSize_CappedLikeTheOtherBackends()
    {
        var request = TwainScanRequests.ForScan(Settings(ScanSource.DocumentFeeder), new RectD(0, 0, 0.5, 0.5), FlatbedAndFeeder());
        Assert.True(request.Feeder);
        Assert.Equal(-1, request.TransferCount);
        Assert.Equal(new RectD(0, 0, 8.5, EsclScanRequest.MaxFeederHeightInches), request.FrameInches);
    }

    [Fact]
    public void ForScan_FeederOnlyScanner_UsesTheFeederWhateverTheSetting()
    {
        var caps = new TwainDeviceCaps { HasFlatbed = false, HasFeeder = true };
        var request = TwainScanRequests.ForScan(Settings(ScanSource.Flatbed), null, caps);
        Assert.True(request.Feeder);
        Assert.Null(request.FrameInches); // no size reported: the driver's own
    }

    [Fact]
    public void ForScan_DriverWindow_WhenAskedOrWhenTheSourceNeedsIt()
    {
        Assert.False(TwainScanRequests.ForScan(Settings(), null, FlatbedAndFeeder()).ShowDriverWindow);
        Assert.True(TwainScanRequests.ForScan(Settings(), null, FlatbedAndFeeder(), showDriverWindow: true).ShowDriverWindow);
        Assert.True(TwainScanRequests.ForScan(Settings(), null, FlatbedAndFeeder(uiControllable: false)).ShowDriverWindow);
    }

    [Fact]
    public void ForScan_DriverWindow_AcceptsAsManyImagesAsTheWindowSends()
    {
        // The app's source is only the window's starting point: the user may pick the feeder there.
        var asked = TwainScanRequests.ForScan(Settings(ScanSource.Flatbed), null, FlatbedAndFeeder(), showDriverWindow: true);
        Assert.False(asked.Feeder);
        Assert.Equal(-1, asked.TransferCount);
        var needed = TwainScanRequests.ForScan(Settings(ScanSource.Flatbed), null, FlatbedAndFeeder(uiControllable: false));
        Assert.Equal(-1, needed.TransferCount);
        Assert.Equal(1, TwainScanRequests.ForScan(Settings(ScanSource.Flatbed), null, FlatbedAndFeeder()).TransferCount);
    }

    [Fact]
    public void ForScan_PrefersMemoryTransfersUnlessTold()
    {
        Assert.True(TwainScanRequests.ForScan(Settings(), null, FlatbedAndFeeder()).PreferMemory);
        Assert.False(TwainScanRequests.ForScan(Settings(), null, FlatbedAndFeeder(), preferNative: true).PreferMemory);
        Assert.False(TwainScanRequests.ForScan(Settings(), null, FlatbedAndFeeder(memory: false)).PreferMemory);
    }

    [Fact]
    public void ForOverview_ScansTheWholeBedInColorAtPreviewResolution()
    {
        var request = TwainScanRequests.ForOverview(FlatbedAndFeeder(uiControllable: false));
        Assert.False(request.Feeder);
        Assert.False(request.ShowDriverWindow);
        Assert.Equal(TwainPixelTypes.Rgb, request.PixelType);
        Assert.Equal(100, request.Resolution);
        Assert.Equal(new RectD(0, 0, 8.5, 11.69), request.FrameInches);
    }

    [Theory]
    [InlineData(new[] { 75, 150, 300 }, 75)]
    [InlineData(new[] { 150, 300 }, 150)]
    [InlineData(new[] { 200, 300, 600 }, 200)]
    [InlineData(new[] { 50, 60 }, 60)]
    [InlineData(new int[0], 100)]
    public void OverviewResolution_PrefersAbout100Dpi(int[] listed, int expected)
    {
        Assert.Equal(expected, TwainScanRequests.OverviewResolution(listed));
    }

    [Theory]
    [InlineData(true, true, TwainPixelTypes.Rgb, 8, TwainTransferMechanisms.Memory)]
    [InlineData(true, true, TwainPixelTypes.BlackWhite, 1, TwainTransferMechanisms.Memory)]
    [InlineData(true, true, TwainPixelTypes.Gray, 16, TwainTransferMechanisms.Native)]
    [InlineData(false, true, TwainPixelTypes.Rgb, 8, TwainTransferMechanisms.Native)]
    [InlineData(true, false, TwainPixelTypes.Rgb, 8, TwainTransferMechanisms.Native)]
    public void TransferMechanism_IsMemoryOnlyWhenTheAppCanReadTheStrips(bool offered, bool preferred, int pixelType,
                                                                         int bitDepth, int expected)
    {
        Assert.Equal(expected, TwainScanRequests.TransferMechanism(offered, preferred, pixelType, bitDepth));
    }

    // MARK: - Paper sizes (TWSS values from twain.h 2.3)

    [Theory]
    [InlineData(TwainSizes.None, 0)]
    [InlineData(TwainSizes.A4, 1)]
    [InlineData(TwainSizes.JisB5, 2)]
    [InlineData(TwainSizes.UsLetter, 3)]
    [InlineData(TwainSizes.UsLegal, 4)]
    [InlineData(TwainSizes.A5, 5)]
    [InlineData(TwainSizes.IsoB4, 6)]
    [InlineData(TwainSizes.IsoB6, 7)]
    [InlineData(TwainSizes.UsLedger, 9)]
    [InlineData(TwainSizes.UsExecutive, 10)]
    [InlineData(TwainSizes.A3, 11)]
    [InlineData(TwainSizes.IsoB3, 12)]
    [InlineData(TwainSizes.A6, 13)]
    [InlineData(TwainSizes.C4, 14)]
    [InlineData(TwainSizes.C5, 15)]
    [InlineData(TwainSizes.C6, 16)]
    [InlineData(TwainSizes.FourA0, 17)]
    [InlineData(TwainSizes.TwoA0, 18)]
    [InlineData(TwainSizes.A0, 19)]
    [InlineData(TwainSizes.A10, 25)]
    [InlineData(TwainSizes.IsoB0, 26)]
    [InlineData(TwainSizes.IsoB5, 29)]
    [InlineData(TwainSizes.IsoB10, 33)]
    [InlineData(TwainSizes.JisB0, 34)]
    [InlineData(TwainSizes.JisB4, 38)]
    [InlineData(TwainSizes.JisB6, 39)]
    [InlineData(TwainSizes.JisB10, 43)]
    [InlineData(TwainSizes.C0, 44)]
    [InlineData(TwainSizes.C3, 47)]
    [InlineData(TwainSizes.C7, 48)]
    [InlineData(TwainSizes.C10, 51)]
    [InlineData(TwainSizes.UsStatement, 52)]
    [InlineData(TwainSizes.BusinessCard, 53)]
    [InlineData(TwainSizes.MaxSize, 54)]
    public void SizeValues_MatchTwainH(int constant, int twainH)
    {
        Assert.Equal(twainH, constant);
    }

    [Theory]
    [InlineData(TwainSizes.UsLetter, 8.5, 11)]
    [InlineData(TwainSizes.UsLegal, 8.5, 14)]
    [InlineData(TwainSizes.UsLedger, 11, 17)]
    [InlineData(TwainSizes.A4, 210 / 25.4, 297 / 25.4)]
    [InlineData(TwainSizes.A5, 148 / 25.4, 210 / 25.4)]
    [InlineData(TwainSizes.JisB5, 182 / 25.4, 257 / 25.4)]
    [InlineData(TwainSizes.IsoB5, 176 / 25.4, 250 / 25.4)]
    [InlineData(TwainSizes.BusinessCard, 55 / 25.4, 90 / 25.4)]
    public void Sizes_HaveTheirDimensionsInInches(int size, double width, double height)
    {
        var inches = TwainSizes.Inches(size)!.Value;
        Assert.Equal(width, inches.Width, 6);
        Assert.Equal(height, inches.Height, 6);
    }

    [Fact]
    public void EveryNamedSizeHasDimensions_ExceptNoneAndMaxSize()
    {
        for (int size = 1; size < TwainSizes.MaxSize; size++)
        {
            if (size == 8) continue; // withdrawn TWSS_B
            Assert.NotNull(TwainSizes.Inches(size));
        }
        Assert.Null(TwainSizes.Inches(TwainSizes.None));
        Assert.Null(TwainSizes.Inches(TwainSizes.MaxSize));
        Assert.Null(TwainSizes.Inches(8));
        Assert.Null(TwainSizes.Inches(999));
    }

    [Fact]
    public void Largest_IsTheAreaEveryListedSizeFitsIn()
    {
        var largest = TwainSizes.Largest([TwainSizes.A3, TwainSizes.UsLedger, TwainSizes.MaxSize])!.Value;
        Assert.Equal(297 / 25.4, largest.Width, 6);
        Assert.Equal(17, largest.Height, 6);
        Assert.Null(TwainSizes.Largest([TwainSizes.None, TwainSizes.MaxSize]));
        Assert.Null(TwainSizes.Largest([]));
    }

    // MARK: - Errors

    public static TheoryData<int, int, ScannerProblem> Problems => new()
    {
        { TwainReturnCodes.Failure, TwainConditionCodes.PaperJam, ScannerProblem.PaperJam },
        { TwainReturnCodes.Failure, TwainConditionCodes.PaperDoubleFeed, ScannerProblem.MultiFeed },
        { TwainReturnCodes.Failure, TwainConditionCodes.CheckDeviceOnline, ScannerProblem.Offline },
        { TwainReturnCodes.Failure, TwainConditionCodes.Interlock, ScannerProblem.CoverOpen },
        { TwainReturnCodes.Failure, TwainConditionCodes.DamagedCorner, ScannerProblem.PaperProblem },
        { TwainReturnCodes.Failure, TwainConditionCodes.NoMedia, ScannerProblem.FeederEmpty },
        { TwainReturnCodes.Failure, TwainConditionCodes.MaxConnections, ScannerProblem.Busy },
        { TwainReturnCodes.Busy, TwainConditionCodes.Success, ScannerProblem.Busy },
        { TwainReturnCodes.ScannerLocked, TwainConditionCodes.Bummer, ScannerProblem.Busy },
    };

    [Theory]
    [MemberData(nameof(Problems))]
    public void ConditionCodesMapToProblems(int returnCode, int conditionCode, ScannerProblem expected)
    {
        Assert.Equal(expected, TwainErrors.ProblemFor(returnCode, conditionCode));
    }

    [Theory]
    [InlineData(TwainConditionCodes.Bummer)]
    [InlineData(TwainConditionCodes.LowMemory)]
    [InlineData(TwainConditionCodes.BadValue)]
    [InlineData(TwainConditionCodes.SequenceError)]
    [InlineData(TwainConditionCodes.DocumentTooDark)]
    public void OtherConditionsAreNotProblems(int conditionCode)
    {
        Assert.Null(TwainErrors.ProblemFor(TwainReturnCodes.Failure, conditionCode));
    }

    [Fact]
    public void TwainCodeValues_MatchTwainH()
    {
        Assert.Equal(20, TwainConditionCodes.PaperJam);
        Assert.Equal(21, TwainConditionCodes.PaperDoubleFeed);
        Assert.Equal(23, TwainConditionCodes.CheckDeviceOnline);
        Assert.Equal(24, TwainConditionCodes.Interlock);
        Assert.Equal(25, TwainConditionCodes.DamagedCorner);
        Assert.Equal(29, TwainConditionCodes.NoMedia);
        Assert.Equal(3, TwainReturnCodes.Cancel);
        Assert.Equal(10, TwainReturnCodes.Busy);
        Assert.Equal(11, TwainReturnCodes.ScannerLocked);
        Assert.Equal(2, TwainPixelTypes.Rgb);
        Assert.Equal(1, TwainPixelFlavors.Vanilla);
        Assert.Equal(2, TwainTransferMechanisms.Memory);
        Assert.Equal(2, TwainDuplexKinds.TwoPass);
    }

    [Fact]
    public void ScanExceptions_ReadAsUserText()
    {
        var jam = TwainErrors.ToScanException(TwainReturnCodes.Failure, TwainConditionCodes.PaperJam);
        Assert.Equal("Paper is jammed in the scanner. Clear the jam, then scan again. (TWAIN TWCC_PAPERJAM)", jam.Message);

        Assert.Equal(ScanErrorKind.Cancelled, TwainErrors.ToScanException(TwainReturnCodes.Cancel, 0).Kind);

        var memory = TwainErrors.ToScanException(TwainReturnCodes.Failure, TwainConditionCodes.LowMemory);
        Assert.Equal("Scan failed: The scanner driver ran out of memory. Try a lower resolution. (TWAIN TWCC_LOWMEMORY)", memory.Message);

        var other = TwainErrors.ToScanException(TwainReturnCodes.Failure, TwainConditionCodes.OperationError, "Lamp failure");
        Assert.Null(other.Problem);
        Assert.Equal("Scan failed: The scanner driver reported an error: Lamp failure (TWAIN TWCC_OPERATIONERROR)", other.Message);

        Assert.Equal("condition code 4242", TwainErrors.ConditionName(4242));
        var offline = TwainErrors.ToScanException(new TwainException("Starting the scan", 1, TwainConditionCodes.CheckDeviceOnline));
        Assert.Equal(ScanErrorKind.DeviceUnavailable, offline.Kind);
    }

    // MARK: - Diagnostics

    [Fact]
    public void ThirtyTwoBitOnlySources_AreThoseWithoutA64BitCounterpart()
    {
        string[] twain32 =
        [
            "wiatwain.ds",
            @"Canon\DR-C225.ds",
            @"Fujitsu\fjtwain32.ds",
            @"OldVendor\Scanner.ds",
            @"OldVendor\readme.txt",
            "Visioneer/VisioneerOne.DS",
        ];
        string[] twain64 = [@"Canon\DR-C225.ds", @"Fujitsu\fjtwain64.ds"];
        Assert.Equal([@"OldVendor\Scanner.ds", "Visioneer/VisioneerOne.DS"],
                     TwainDiagnostics.ThirtyTwoBitOnlySources(twain32, twain64));
        Assert.Empty(TwainDiagnostics.ThirtyTwoBitOnlySources([], twain64));
    }

    [Fact]
    public void Report_SaysWhetherTwainWorksAndListsTheDrivers()
    {
        Assert.Equal(
            "TWAIN: not installed (no TWAINDSM.dll)\n  32-bit only (needs the 32-bit helper) \"Old\\Scanner.ds\"\n",
            TwainDiagnostics.Report(TwainAvailability.NoDataSourceManager, [], [@"Old\Scanner.ds"]));
        Assert.Equal("TWAIN: available\n  source \"Canon DR-C225\"\n",
                     TwainDiagnostics.Report(TwainAvailability.Available, ["Canon DR-C225"], []));
        Assert.Contains("TWAINDSM.dll", TwainDiagnostics.NoDataSourceManagerMessage);
    }
}
