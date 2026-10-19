using CompleteScanner.Core;
using Xunit;

namespace CompleteScanner.Core.Tests;

// WIA is Windows-only: no Swift counterpart.

public class WiaErrorsTests
{
    public static TheoryData<uint, ScannerProblem> Mapped => new()
    {
        { 0x80210002, ScannerProblem.PaperJam },
        { 0x80210003, ScannerProblem.FeederEmpty },
        { 0x80210004, ScannerProblem.PaperProblem },
        { 0x80210005, ScannerProblem.Offline },
        { 0x80210006, ScannerProblem.Busy },
        { 0x80210007, ScannerProblem.WarmingUp },
        { 0x80210008, ScannerProblem.NeedsAttention },
        { 0x80210009, ScannerProblem.Offline },
        { 0x8021000A, ScannerProblem.CommunicationError },
        { 0x8021000D, ScannerProblem.Busy },
        { 0x80210015, ScannerProblem.Offline },
        { 0x80210016, ScannerProblem.CoverOpen },
        { 0x80210017, ScannerProblem.NeedsAttention },
        { 0x80210020, ScannerProblem.MultiFeed },
    };

    [Theory]
    [MemberData(nameof(Mapped))]
    public void HResultMapsToProblem(uint hresult, ScannerProblem expected)
    {
        Assert.Equal(expected, WiaErrors.ProblemFor(unchecked((int)hresult)));
    }

    [Theory]
    [InlineData(0x80210001u)] // general error
    [InlineData(0x8021000Bu)] // invalid command
    [InlineData(0x8021000Eu)] // exception in driver
    [InlineData(0x80004005u)] // E_FAIL
    [InlineData(0u)]
    public void OtherHResultsHaveNoProblem(uint hresult)
    {
        Assert.Null(WiaErrors.ProblemFor(unchecked((int)hresult)));
    }

    [Fact]
    public void EmptyFeederBecomesLoadPaper()
    {
        var error = WiaErrors.ToScanException(unchecked((int)WiaErrors.PaperEmpty), "driver text");
        Assert.Equal(ScannerProblem.FeederEmpty, error.Problem);
        Assert.Equal("Load paper in the feeder, then scan again. (WIA error 0x80210003)", error.Message);
    }

    [Fact]
    public void UnmappedHResultKeepsCodeAndDriverMessage()
    {
        var error = WiaErrors.ToScanException(unchecked((int)0x8021000Eu), "Driver crashed");
        Assert.Null(error.Problem);
        Assert.Equal(ScanErrorKind.ScanFailed, error.Kind);
        Assert.Equal("Scan failed: WIA error 0x8021000E: Driver crashed", error.Message);
    }

    [Fact]
    public void FeederOnlyScannerHasNoFlatbed()
    {
        Assert.Equal([ScanSource.DocumentFeeder], WiaDocumentHandling.Sources(WiaDocumentHandling.Feed));
        Assert.Equal([ScanSource.DocumentFeeder],
                     WiaDocumentHandling.Sources(WiaDocumentHandling.Feed | WiaDocumentHandling.Duplex));
    }

    [Fact]
    public void FlatbedAndFeederAreBothListedFlatbedFirst()
    {
        Assert.Equal([ScanSource.Flatbed, ScanSource.DocumentFeeder],
                     WiaDocumentHandling.Sources(WiaDocumentHandling.Feed | WiaDocumentHandling.Flat | 0x20));
    }

    [Fact]
    public void FlatbedOnlyScanner()
    {
        Assert.Equal([ScanSource.Flatbed], WiaDocumentHandling.Sources(WiaDocumentHandling.Flat));
    }

    [Theory]
    [InlineData(null)]
    [InlineData(0)]
    [InlineData(0x08)] // detection flags only
    public void UnknownCapabilitiesMeanFlatbedOnly(int? flags)
    {
        Assert.Equal([ScanSource.Flatbed], WiaDocumentHandling.Sources(flags));
    }

    [Fact]
    public void DuplexNeedsAFeeder()
    {
        Assert.True(WiaDocumentHandling.SupportsDuplex(WiaDocumentHandling.Feed | WiaDocumentHandling.Duplex));
        Assert.False(WiaDocumentHandling.SupportsDuplex(WiaDocumentHandling.Feed));
        Assert.False(WiaDocumentHandling.SupportsDuplex(WiaDocumentHandling.Flat | WiaDocumentHandling.Duplex));
        Assert.False(WiaDocumentHandling.SupportsDuplex(null));
    }

    [Fact]
    public void FeederSizeComesFromThousandthsOfAnInch()
    {
        Assert.Equal(new SizeD(8.5, 14), WiaDocumentHandling.FeederSizeInches(8500, 14000));
        Assert.Null(WiaDocumentHandling.FeederSizeInches(8500, null));
        Assert.Null(WiaDocumentHandling.FeederSizeInches(0, 11000));
    }
}
