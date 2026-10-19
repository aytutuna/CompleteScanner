using CompleteScanner.Core;
using Xunit;

namespace CompleteScanner.Core.Tests;

// Mirrored by Tests/CompleteScannerTests/TroubleshootingTests.swift.

public class TroubleshootingTests
{
    [Fact]
    public void UnknownIsTheFirstMember()
    {
        Assert.Equal(ScannerProblem.Unknown, default(ScannerProblem));
    }

    [Fact]
    public void EveryProblemHasItsOwnText()
    {
        var texts = Enum.GetValues<ScannerProblem>().Select(ScannerProblems.Describe).ToList();
        Assert.All(texts, text => Assert.False(string.IsNullOrWhiteSpace(text)));
        Assert.Equal(texts.Count, texts.Distinct().Count());
    }

    [Fact]
    public void EmptyFeederAsksForPaper()
    {
        Assert.Equal("Load paper in the feeder, then scan again.", ScannerProblems.Describe(ScannerProblem.FeederEmpty));
    }

    [Fact]
    public void ForProblemCarriesTheProblemAndItsText()
    {
        var error = ScanException.ForProblem(ScannerProblem.FeederEmpty);
        Assert.Equal(ScannerProblem.FeederEmpty, error.Problem);
        Assert.Equal(ScanErrorKind.ScanFailed, error.Kind);
        Assert.Equal(ScannerProblems.Describe(ScannerProblem.FeederEmpty), error.Message);
    }

    [Fact]
    public void ForProblemAppendsTheDetail()
    {
        var error = ScanException.ForProblem(ScannerProblem.PaperJam, "WIA error 0x80210002");
        Assert.Equal($"{ScannerProblems.Describe(ScannerProblem.PaperJam)} (WIA error 0x80210002)", error.Message);
    }

    [Fact]
    public void AnOfflineScannerIsUnavailable()
    {
        Assert.Equal(ScanErrorKind.DeviceUnavailable, ScanException.ForProblem(ScannerProblem.Offline).Kind);
        Assert.Equal(ScanErrorKind.ScanFailed, ScanException.ForProblem(ScannerProblem.Busy).Kind);
    }

    [Fact]
    public void OtherErrorsHaveNoProblem()
    {
        Assert.Null(ScanException.ScanFailed("x").Problem);
        Assert.Null(ScanException.Cancelled().Problem);
    }

    [Fact]
    public void ScanStopSaysHowManyPagesWereKeptAndWhy()
    {
        var stop = ScanStop.From(ScanException.ForProblem(ScannerProblem.PaperJam));
        Assert.Equal(ScannerProblem.PaperJam, stop.Problem);
        Assert.Equal("Scanning stopped after 3 pages; they were kept. "
                     + "Paper is jammed in the scanner. Clear the jam, then scan again.", stop.Message(3));
        Assert.Equal("Scanning stopped after 1 page; it was kept. "
                     + "Paper is jammed in the scanner. Clear the jam, then scan again.", stop.Message(1));
    }

    [Fact]
    public void ScanStopWithoutAReasonStillSaysPagesWereKept()
    {
        var stop = new ScanStop("  ");
        Assert.Null(stop.Problem);
        Assert.Equal("Scanning stopped after 2 pages; they were kept.", stop.Message(2));
    }
}
