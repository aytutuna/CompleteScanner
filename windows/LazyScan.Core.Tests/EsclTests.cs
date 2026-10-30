using LazyScan.Core;
using Xunit;

namespace LazyScan.Core.Tests;

// Mirrored by Tests/LazyScanTests/EsclTests.swift (same cases). The fixtures, which the Swift
// suite reads too (Tests/Fixtures/Escl, see EsclFixtures), are hand-written in the shape real devices
// send (namespace prefixes vary between devices).

public class EsclTests
{
    // MARK: - Fixtures (Tests/Fixtures/Escl)

    internal static string PlatenAndDuplexAdf => EsclFixtures.PlatenAndDuplexAdf;
    internal static string FeederOnly => EsclFixtures.FeederOnly;
    internal static string BarePlaten => EsclFixtures.BarePlaten;
    internal static string DuplexOption => EsclFixtures.DuplexOption;

    private static void AssertSize(SizeD expected, SizeD? actual)
    {
        Assert.NotNull(actual);
        Assert.Equal(expected.Width, actual.Value.Width, 4);
        Assert.Equal(expected.Height, actual.Value.Height, 4);
    }

    // MARK: - Capabilities

    [Fact]
    public void ParsesPlatenAndFeeder()
    {
        var caps = EsclCapabilitiesParser.Parse(PlatenAndDuplexAdf);
        Assert.Equal("2.63", caps.Version);
        Assert.Equal("HP Color LaserJet MFP M479fdw", caps.MakeAndModel);
        Assert.Equal("564e4333-4230-3538-3930-a0b3cce51a2b", caps.Uuid);

        Assert.NotNull(caps.Platen);
        AssertSize(new SizeD(8.5, 3508 / 300.0), caps.Platen.MaxSizeInches);
        AssertSize(new SizeD(8 / 300.0, 8 / 300.0), caps.Platen.MinSizeInches);
        // 1200 × 600 is not square, so it is not offered.
        Assert.Equal([75, 100, 200, 300, 600], caps.Platen.Resolutions);
        Assert.Equal(["BlackAndWhite1", "Grayscale8", "RGB24"], caps.Platen.ColorModes);
        Assert.Equal(["application/pdf", "image/jpeg"], caps.Platen.DocumentFormats);

        Assert.NotNull(caps.AdfSimplex);
        Assert.NotNull(caps.AdfDuplex);
        AssertSize(new SizeD(8.5, 14), caps.AdfSimplex.MaxSizeInches);
        Assert.Equal([200, 300], caps.AdfSimplex.Resolutions);
        Assert.True(caps.SupportsDuplex);
        Assert.Same(caps.AdfSimplex, caps.Feeder);
    }

    [Fact]
    public void PlatenAndFeederCapabilities()
    {
        var caps = EsclCapabilitiesParser.Parse(PlatenAndDuplexAdf).ToScannerCapabilities();
        Assert.Equal([ScanSource.Flatbed, ScanSource.DocumentFeeder], caps.Sources);
        Assert.True(caps.SupportsOverview);
        Assert.True(caps.SupportsDuplex);
        Assert.Equal([75, 100, 200, 300, 600], caps.SupportedResolutions);
        Assert.Equal(8.5, caps.FlatbedSizeInches.Width, 4);
        AssertSize(new SizeD(8.5, 14), caps.FeederSizeInches);
    }

    [Fact]
    public void FeederOnlyScannerHasNoFlatbedAndNoOverview()
    {
        var parsed = EsclCapabilitiesParser.Parse(FeederOnly);
        Assert.Null(parsed.Platen);
        Assert.Equal("Brother ADS-1700W", parsed.MakeAndModel);
        Assert.Equal("e3248000-80ce-11db-8000-30055c773bcf", parsed.Uuid);
        Assert.False(parsed.SupportsDuplex);

        var caps = parsed.ToScannerCapabilities();
        Assert.Equal([ScanSource.DocumentFeeder], caps.Sources);
        Assert.False(caps.SupportsOverview);
        // The range expands to its steps; the list is the feeder's.
        Assert.Equal([100, 200, 300, 400, 500, 600], caps.SupportedResolutions);
        AssertSize(new SizeD(8.6, 118), caps.FeederSizeInches);
    }

    [Fact]
    public void BarePlatenGetsDefaults()
    {
        var caps = EsclCapabilitiesParser.Parse(BarePlaten).ToScannerCapabilities();
        Assert.Equal([ScanSource.Flatbed], caps.Sources);
        Assert.True(caps.SupportsOverview);
        Assert.Equal([75, 150, 200, 300, 600], caps.SupportedResolutions);
        Assert.Equal(EsclCapabilities.DefaultAreaInches, caps.FlatbedSizeInches);
        Assert.Null(caps.FeederSizeInches);
        Assert.False(caps.SupportsDuplex);
    }

    [Fact]
    public void DuplexCanBeAnnouncedAsAnAdfOption()
    {
        var caps = EsclCapabilitiesParser.Parse(DuplexOption);
        Assert.True(caps.SupportsDuplex);
        Assert.Null(caps.AdfDuplex);
        Assert.Equal([ScanSource.DocumentFeeder], caps.ToScannerCapabilities().Sources);
    }

    [Fact]
    public void DeviceListingNoInputIsTreatedAsAFlatbed()
    {
        var caps = EsclCapabilitiesParser.Parse("<ScannerCapabilities><MakeAndModel>X</MakeAndModel></ScannerCapabilities>")
            .ToScannerCapabilities();
        Assert.Equal([ScanSource.Flatbed], caps.Sources);
        Assert.True(caps.SupportsOverview);
    }

    [Fact]
    public void InvalidXmlIsAFormatException()
    {
        Assert.Throws<FormatException>(() => EsclCapabilitiesParser.Parse("<html><body>Login</body>"));
        Assert.Throws<FormatException>(() => EsclCapabilitiesParser.Parse(""));
    }

    // MARK: - Scan requests

    [Fact]
    public void FullPlatenColorRequestSnapshot()
    {
        var caps = EsclCapabilitiesParser.Parse(PlatenAndDuplexAdf);
        var request = EsclScanRequest.Create(caps, ScanSource.Flatbed, ColorMode.Color, 300, selection: null);
        string expected = EsclFixtures.Text(EsclFixtures.PlatenColorRequestFile);
        Assert.Equal(expected, request.ToXml());
    }

    [Fact]
    public void FeederRequestUsesTheFeederSizeAndIgnoresTheSelection()
    {
        var caps = EsclCapabilitiesParser.Parse(PlatenAndDuplexAdf);
        var request = EsclScanRequest.Create(caps, ScanSource.DocumentFeeder, ColorMode.Grayscale, 300,
                                             selection: new RectD(0.1, 0.1, 0.2, 0.2));
        Assert.Equal("Feeder", request.InputSource);
        Assert.Equal(new EsclRegion(0, 0, 2550, 4200), request.Region);
        Assert.Equal("Grayscale8", request.ColorMode);
        string xml = request.ToXml();
        Assert.Contains("  <pwg:InputSource>Feeder</pwg:InputSource>\n", xml);
        Assert.Contains("      <pwg:Height>4200</pwg:Height>\n", xml);
    }

    [Fact]
    public void TwoSidedFeederRequestSnapshot()
    {
        var caps = EsclCapabilitiesParser.Parse(PlatenAndDuplexAdf);
        var request = EsclScanRequest.Create(caps, ScanSource.DocumentFeeder, ColorMode.Color, 300, selection: null,
                                             duplex: true);
        Assert.True(request.Duplex);
        string expected = EsclFixtures.Text(EsclFixtures.FeederTwoSidedRequestFile);
        Assert.Equal(expected, request.ToXml());
    }

    [Fact]
    public void TwoSidedIsAskedForOnlyFromATwoSidedFeeder()
    {
        var duplexAdf = EsclCapabilitiesParser.Parse(PlatenAndDuplexAdf);
        var flatbed = EsclScanRequest.Create(duplexAdf, ScanSource.Flatbed, ColorMode.Color, 300, null, duplex: true);
        Assert.False(flatbed.Duplex);
        Assert.DoesNotContain("Duplex", flatbed.ToXml());
        var oneSided = EsclScanRequest.Create(duplexAdf, ScanSource.DocumentFeeder, ColorMode.Color, 300, null);
        Assert.False(oneSided.Duplex);
        Assert.DoesNotContain("Duplex", oneSided.ToXml());

        var simplexOnly = EsclCapabilitiesParser.Parse(FeederOnly);
        var request = EsclScanRequest.Create(simplexOnly, ScanSource.DocumentFeeder, ColorMode.Color, 300, null, duplex: true);
        Assert.False(request.Duplex);
        Assert.DoesNotContain("Duplex", request.ToXml());

        // Two-sided announced only as an AdfOption: the feeder's own capabilities are used.
        var optionOnly = EsclCapabilitiesParser.Parse(DuplexOption);
        Assert.Null(optionOnly.AdfDuplex);
        Assert.True(EsclScanRequest.Create(optionOnly, ScanSource.DocumentFeeder, ColorMode.Color, 300, null, duplex: true).Duplex);
    }

    [Fact]
    public void FeederRequestUsesThePaperSize()
    {
        var caps = EsclCapabilitiesParser.Parse(PlatenAndDuplexAdf);
        EsclRegion Region(PaperSize size) =>
            EsclScanRequest.Create(caps, ScanSource.DocumentFeeder, ColorMode.Color, 300, null, paperSize: size).Region;
        Assert.Equal(new EsclRegion(0, 0, 2480, 3508), Region(PaperSize.A4));
        Assert.Equal(new EsclRegion(0, 0, 2550, 3300), Region(PaperSize.Letter));
        Assert.Equal(new EsclRegion(0, 0, 2550, 4200), Region(PaperSize.Legal));
        Assert.Equal(new EsclRegion(0, 0, 2550, 4200), Region(PaperSize.Auto));
        // A long-paper feeder: Automatic is capped, a paper size is not needed to be.
        var longPaper = EsclCapabilitiesParser.Parse(FeederOnly);
        Assert.Equal(new EsclRegion(0, 0, 2550, 3300),
                     EsclScanRequest.Create(longPaper, ScanSource.DocumentFeeder, ColorMode.Color, 300, null,
                                            paperSize: PaperSize.Letter).Region);
        // The flatbed takes the paper size as a selection (the app's job), not here.
        Assert.Equal(new EsclRegion(0, 0, 2550, 3508),
                     EsclScanRequest.Create(caps, ScanSource.Flatbed, ColorMode.Color, 300, null, paperSize: PaperSize.A5).Region);
    }

    [Fact]
    public void BlackAndWhiteIsRequestedAsGrayscale()
    {
        // The device offers BlackAndWhite1, but not as PNG/TIFF: 1-bit JPEG is what devices reject.
        var caps = EsclCapabilitiesParser.Parse(PlatenAndDuplexAdf);
        var request = EsclScanRequest.Create(caps, ScanSource.Flatbed, ColorMode.BlackWhite, 300, null);
        Assert.Equal("Grayscale8", request.ColorMode);
        Assert.Equal("image/jpeg", request.DocumentFormat);
        Assert.DoesNotContain("BlackAndWhite1", request.ToXml());
    }

    [Fact]
    public void GrayFallsBackToColorWhenTheInputHasNoGrayscale()
    {
        var caps = EsclCapabilitiesParser.Parse(FeederOnly);
        Assert.Equal("RGB24", EsclScanRequest.Create(caps, ScanSource.DocumentFeeder, ColorMode.Grayscale, 300, null).ColorMode);
        Assert.Equal("RGB24", EsclScanRequest.Create(caps, ScanSource.DocumentFeeder, ColorMode.BlackWhite, 300, null).ColorMode);
    }

    [Fact]
    public void FormatFallsBackToPngWhenJpegIsNotOffered()
    {
        var caps = EsclCapabilitiesParser.Parse(FeederOnly);
        Assert.Equal("image/png", EsclScanRequest.Create(caps, ScanSource.DocumentFeeder, ColorMode.Color, 300, null).DocumentFormat);
    }

    [Fact]
    public void NothingListedMeansColorJpeg()
    {
        var caps = EsclCapabilitiesParser.Parse(BarePlaten);
        var request = EsclScanRequest.Create(caps, ScanSource.Flatbed, ColorMode.Grayscale, 250, null);
        Assert.Equal("Grayscale8", request.ColorMode);
        Assert.Equal("image/jpeg", request.DocumentFormat);
        Assert.Equal(250, request.Resolution); // nothing to snap to
        Assert.Equal(new EsclRegion(0, 0, 2550, 3510), request.Region); // the default 8.5 × 11.7 in area
    }

    [Fact]
    public void LongPaperFeederHeightIsCapped()
    {
        var caps = EsclCapabilitiesParser.Parse(FeederOnly);
        var request = EsclScanRequest.Create(caps, ScanSource.DocumentFeeder, ColorMode.Color, 300, null);
        Assert.Equal(new EsclRegion(0, 0, 2580, 5100), request.Region);
    }

    [Fact]
    public void ResolutionSnapsToTheInputsOwnList()
    {
        var caps = EsclCapabilitiesParser.Parse(PlatenAndDuplexAdf);
        // The feeder offers 200 and 300 only; the platen goes up to 600.
        Assert.Equal(300, EsclScanRequest.Create(caps, ScanSource.DocumentFeeder, ColorMode.Color, 600, null).Resolution);
        Assert.Equal(200, EsclScanRequest.Create(caps, ScanSource.DocumentFeeder, ColorMode.Color, 150, null).Resolution);
        Assert.Equal(600, EsclScanRequest.Create(caps, ScanSource.Flatbed, ColorMode.Color, 600, null).Resolution);
        Assert.Equal(100, EsclScanRequest.Create(caps, ScanSource.Flatbed, ColorMode.Color, 120, null).Resolution);
    }

    [Fact]
    public void SelectionBecomesARegionOfThePlaten()
    {
        var caps = EsclCapabilitiesParser.Parse(PlatenAndDuplexAdf);
        var request = EsclScanRequest.Create(caps, ScanSource.Flatbed, ColorMode.Color, 300,
                                             new RectD(0.25, 0.5, 0.5, 0.25));
        Assert.Equal(new EsclRegion(638, 1754, 1275, 877), request.Region);
    }

    [Fact]
    public void SelectionNeverPassesThePlatenEdge()
    {
        var caps = EsclCapabilitiesParser.Parse(PlatenAndDuplexAdf);
        // A selection reaching the right and bottom edges stays inside the platen after rounding.
        var request = EsclScanRequest.Create(caps, ScanSource.Flatbed, ColorMode.Color, 300,
                                             new RectD(0.3333, 0, 0.6667, 1));
        Assert.True(request.Region.XOffset + request.Region.Width <= 2550);
        Assert.True(request.Region.YOffset + request.Region.Height <= 3508);
        Assert.Equal(850, request.Region.XOffset);
        Assert.Equal(1700, request.Region.Width);
    }

    [Fact]
    public void TinySelectionGrowsToTheMinimumSize()
    {
        var caps = EsclCapabilitiesParser.Parse(FeederOnly.Replace("<Adf>", "<Platen><PlatenInputCaps><MinWidth>300</MinWidth><MinHeight>300</MinHeight><MaxWidth>2550</MaxWidth><MaxHeight>3300</MaxHeight></PlatenInputCaps></Platen><Adf>"));
        var request = EsclScanRequest.Create(caps, ScanSource.Flatbed, ColorMode.Color, 300,
                                             new RectD(0.995, 0.995, 0.004, 0.004));
        Assert.Equal(new EsclRegion(2250, 3000, 300, 300), request.Region);
    }

    [Fact]
    public void SelectionOutsideThePlatenScansTheWholePlaten()
    {
        var caps = EsclCapabilitiesParser.Parse(PlatenAndDuplexAdf);
        var request = EsclScanRequest.Create(caps, ScanSource.Flatbed, ColorMode.Color, 300, new RectD(1.5, 1.5, 0.2, 0.2));
        Assert.Equal(new EsclRegion(0, 0, 2550, 3508), request.Region);
    }

    // MARK: - Job location

    private static readonly Uri ScanJobs = new("http://192.168.1.50:8080/eSCL/ScanJobs");

    [Theory]
    [InlineData("http://192.168.1.50:8080/eSCL/ScanJobs/42", "http://192.168.1.50:8080/eSCL/ScanJobs/42")]
    [InlineData("/eSCL/ScanJobs/42", "http://192.168.1.50:8080/eSCL/ScanJobs/42")]
    [InlineData("/eSCL/ScanJobs/42/", "http://192.168.1.50:8080/eSCL/ScanJobs/42")]
    [InlineData("ScanJobs/42", "http://192.168.1.50:8080/eSCL/ScanJobs/42")]
    [InlineData("  /eSCL/ScanJobs/urn:uuid:4509a320-00a0-008f-00b6-002507510eca  ",
                "http://192.168.1.50:8080/eSCL/ScanJobs/urn:uuid:4509a320-00a0-008f-00b6-002507510eca")]
    [InlineData("https://scanner.local/eSCL/ScanJobs/7", "https://scanner.local/eSCL/ScanJobs/7")]
    public void ResolvesTheJobLocation(string location, string expected)
    {
        Assert.Equal(expected, EsclJob.ResolveLocation(ScanJobs, location)?.AbsoluteUri);
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("   ")]
    public void MissingLocationIsNull(string? location)
    {
        Assert.Null(EsclJob.ResolveLocation(ScanJobs, location));
    }

    [Fact]
    public void NextDocumentIsBelowTheJob()
    {
        Assert.Equal("http://h/eSCL/ScanJobs/42/NextDocument",
                     EsclJob.NextDocument(new Uri("http://h/eSCL/ScanJobs/42")).AbsoluteUri);
        Assert.Equal("http://h/eSCL/ScanJobs/42/NextDocument",
                     EsclJob.NextDocument(new Uri("http://h/eSCL/ScanJobs/42/")).AbsoluteUri);
    }

    // MARK: - Scanner status

    private static string Status(string state, string? adfState) => $"""
        <?xml version="1.0" encoding="UTF-8"?>
        <scan:ScannerStatus xmlns:scan="http://schemas.hp.com/imaging/escl/2011/05/03" xmlns:pwg="http://www.pwg.org/schemas/2010/12/sm">
          <pwg:Version>2.6</pwg:Version>
          <pwg:State>{state}</pwg:State>
          {(adfState is null ? "" : $"<scan:AdfState>{adfState}</scan:AdfState>")}
          <scan:Jobs>
            <scan:JobInfo><pwg:JobState>Completed</pwg:JobState></scan:JobInfo>
          </scan:Jobs>
        </scan:ScannerStatus>
        """;

    [Fact]
    public void ParsesTheStatus()
    {
        var status = EsclScannerStatus.Parse(Status("Idle", "ScannerAdfEmpty"));
        Assert.NotNull(status);
        Assert.Equal("Idle", status.State);
        Assert.Equal("ScannerAdfEmpty", status.AdfState);
        Assert.Null(EsclScannerStatus.Parse("not xml"));
    }

    [Theory]
    [InlineData("Idle", "ScannerAdfEmpty", ScannerProblem.FeederEmpty)]
    [InlineData("Idle", "ScannerAdfJam", ScannerProblem.PaperJam)]
    [InlineData("Stopped", "ScannerAdfHatchOpen", ScannerProblem.CoverOpen)]
    [InlineData("Idle", "ScannerAdfMultipickDetected", ScannerProblem.MultiFeed)]
    [InlineData("Idle", "ScannerAdfMispick", ScannerProblem.PaperProblem)]
    [InlineData("Down", "ScannerAdfLoaded", ScannerProblem.Offline)]
    [InlineData("Processing", "ScannerAdfProcessing", ScannerProblem.Busy)]
    [InlineData("Testing", null, ScannerProblem.WarmingUp)]
    [InlineData("Stopped", null, ScannerProblem.NeedsAttention)]
    public void FeederJobProblems(string state, string? adfState, ScannerProblem expected)
    {
        Assert.Equal(expected, EsclScannerStatus.Parse(Status(state, adfState))!.Problem(ScanSource.DocumentFeeder));
    }

    [Fact]
    public void PlatenJobsIgnoreTheFeederState()
    {
        var status = EsclScannerStatus.Parse(Status("Idle", "ScannerAdfEmpty"))!;
        Assert.Null(status.Problem(ScanSource.Flatbed));
        Assert.Null(EsclScannerStatus.Parse(Status("Idle", "ScannerAdfLoaded"))!.Problem(ScanSource.DocumentFeeder));
    }
}
