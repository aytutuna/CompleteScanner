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
    public void HandlingSelect_TwoSidedFrontFirstThenWithoutThenOneSided()
    {
        Assert.Equal([0x002], WiaDocumentHandling.SelectValues(ScanSource.Flatbed, duplex: true));
        Assert.Equal([0x001], WiaDocumentHandling.SelectValues(ScanSource.DocumentFeeder, duplex: false));
        Assert.Equal([0x00D, 0x005, 0x001], WiaDocumentHandling.SelectValues(ScanSource.DocumentFeeder, duplex: true));
        Assert.Equal(0, WiaDocumentHandling.AllPages);
    }

    [Fact]
    public void SelectSource_TheFirstValueTheDriverTakes()
    {
        var offered = new List<int>();
        bool Takes(int value, params int[] accepted)
        {
            offered.Add(value);
            return accepted.Contains(value);
        }

        // A two-sided driver that takes FRONT_FIRST: two-sided.
        int? selected = WiaDocumentHandling.SelectSource(ScanSource.DocumentFeeder, duplex: true, v => Takes(v, 0x00D, 0x005, 0x001));
        Assert.Equal(0x00D, selected);
        Assert.True(WiaDocumentHandling.ScansBothSides(selected));
        Assert.Equal([0x00D], offered);

        // One that refuses FRONT_FIRST: still two-sided.
        offered.Clear();
        selected = WiaDocumentHandling.SelectSource(ScanSource.DocumentFeeder, duplex: true, v => Takes(v, 0x005, 0x001));
        Assert.Equal(0x005, selected);
        Assert.True(WiaDocumentHandling.ScansBothSides(selected));

        // A one-sided feeder refuses DUPLEX: the feeder alone, one side, never the flatbed.
        offered.Clear();
        selected = WiaDocumentHandling.SelectSource(ScanSource.DocumentFeeder, duplex: true, v => Takes(v, 0x001, 0x002));
        Assert.Equal(0x001, selected);
        Assert.False(WiaDocumentHandling.ScansBothSides(selected));
        Assert.Equal([0x00D, 0x005, 0x001], offered);

        // Nothing taken.
        selected = WiaDocumentHandling.SelectSource(ScanSource.DocumentFeeder, duplex: false, _ => false);
        Assert.Null(selected);
        Assert.False(WiaDocumentHandling.ScansBothSides(selected));
        Assert.Equal(0x002, WiaDocumentHandling.SelectSource(ScanSource.Flatbed, duplex: true, _ => true));
    }

    [Fact]
    public void FeederAlreadySelected_WhenTheDriverTakesNoValue()
    {
        // A feeder-only driver with a read-only FEEDER: rejects every write, but scans the feeder, one side.
        int? selected = WiaDocumentHandling.SelectSource(ScanSource.DocumentFeeder, duplex: true, _ => false)
                        ?? WiaDocumentHandling.FeederAlreadySelected(0x001);
        Assert.Equal(0x001, selected);
        Assert.False(WiaDocumentHandling.ScansBothSides(selected));

        // Read-only two-sided feeding: both sides.
        selected = WiaDocumentHandling.FeederAlreadySelected(0x005);
        Assert.Equal(0x005, selected);
        Assert.True(WiaDocumentHandling.ScansBothSides(selected));
        Assert.True(WiaDocumentHandling.ScansBothSides(WiaDocumentHandling.FeederAlreadySelected(0x00D)));

        // The flatbed selected (or nothing readable): the feeder is not, and the scan must not go ahead.
        Assert.Null(WiaDocumentHandling.FeederAlreadySelected(0x002));
        Assert.Null(WiaDocumentHandling.FeederAlreadySelected(0));
        Assert.Null(WiaDocumentHandling.FeederAlreadySelected(null));
    }

    [Fact]
    public void PageSizes_NamedOrCustom()
    {
        Assert.Null(WiaDocumentHandling.PageSize(PaperSize.Auto));
        Assert.Equal((1, 0, 0), WiaDocumentHandling.PageSize(PaperSize.Letter));
        Assert.Equal((3, 0, 0), WiaDocumentHandling.PageSize(PaperSize.Legal));
        Assert.Equal((0, 0, 0), WiaDocumentHandling.PageSize(PaperSize.A4));
        Assert.Equal((11, 0, 0), WiaDocumentHandling.PageSize(PaperSize.A5));
        Assert.Equal((12, 0, 0), WiaDocumentHandling.PageSize(PaperSize.A6));
        Assert.Equal((44, 0, 0), WiaDocumentHandling.PageSize(PaperSize.B5Jis));
        Assert.Equal((2, 7250, 10500), WiaDocumentHandling.PageSize(PaperSize.Executive));
        Assert.Equal((2, 2125, 3370), WiaDocumentHandling.PageSize(PaperSize.IdCard));
    }

    [Fact]
    public void FeederSizeComesFromThousandthsOfAnInch()
    {
        Assert.Equal(new SizeD(8.5, 14), WiaDocumentHandling.FeederSizeInches(8500, 14000));
        Assert.Null(WiaDocumentHandling.FeederSizeInches(8500, null));
        Assert.Null(WiaDocumentHandling.FeederSizeInches(0, 11000));
    }
}
