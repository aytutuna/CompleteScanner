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
    public void EveryProblem_HasATitleOfThreeWords_AndAdviceOfTen()
    {
        Assert.Equal(["Something went wrong", "Feeder empty", "Paper jam", "Paper problem", "Several sheets fed", "Cover open",
                      "Scanner offline", "Scanner busy", "Warming up", "Needs attention", "Connection lost"],
                     Enum.GetValues<ScannerProblem>().Select(ScannerProblems.Title));
        Assert.Equal("Turn it on and check the cable or network.", ScannerProblems.Advice(ScannerProblem.Offline));
        Assert.Equal("Clear the jam, then scan again.", ScannerProblems.Advice(ScannerProblem.PaperJam));
        foreach (var problem in Enum.GetValues<ScannerProblem>())
        {
            Assert.InRange(StatusLine.Words(ScannerProblems.Title(problem)), 1, 3);
            Assert.InRange(StatusLine.Words(ScannerProblems.Advice(problem)), 1, 10);
            Assert.Equal(problem, ScannerProblems.Find(ScannerProblems.Describe(problem)));
        }
        Assert.Equal("Something went wrong", ScannerProblems.GenericTitle);
    }

    [Fact]
    public void Notice_TitlesTheErrorByItsProblem_AndKeepsWhatToDo()
    {
        Assert.Equal(new ProblemNotice("Scanner offline", "Turn it on and check the cable or network."),
                     ScannerProblems.Notice(ScannerProblems.Describe(ScannerProblem.Offline)));
        // A connection's code after the text stays; the sentence before it is cut to what to do.
        Assert.Equal(new ProblemNotice("Paper jam", "Clear the jam, then scan again. (WIA error 0x80210002)"),
                     ScannerProblems.Notice(ScanException.ForProblem(ScannerProblem.PaperJam).Message + " (WIA error 0x80210002)"));
        // A feeder batch that stopped: what was kept, then what to do.
        string stopped = new ScanStop(ScannerProblems.Describe(ScannerProblem.MultiFeed), ScannerProblem.MultiFeed).Message(3);
        Assert.Equal(new ProblemNotice("Several sheets fed", "Scanning stopped after 3 pages; they were kept. Fan the stack, load it again, then scan again."),
                     ScannerProblems.Notice(stopped));
        // Any other error: the generic title and the message as it is.
        Assert.Equal(new ProblemNotice("Something went wrong", "Saving failed: the disk is full."),
                     ScannerProblems.Notice(" Saving failed: the disk is full. "));
        Assert.Null(ScannerProblems.Find("Saving failed: the disk is full."));
        Assert.Null(ScannerProblems.Find(null));
        Assert.Null(ScannerProblems.Find(""));
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
