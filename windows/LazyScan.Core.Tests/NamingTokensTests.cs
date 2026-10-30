using LazyScan.Core;
using Xunit;

namespace LazyScan.Core.Tests;

// Twin of Tests/LazyScanTests/NamingTokensTests.swift: the file name field's parts, putting one
// in, what is wrong with a template, and the name the next file gets.
public class NamingTokensTests
{
    /// <summary>2026-10-20 14:05:32.</summary>
    private static DateTime FixedDate() => new(2026, 10, 20, 14, 5, 32);

    [Fact]
    public void TheInsertMenu_OffersSevenParts_EachKnownAndShort()
    {
        Assert.Equal(["Date", "Time", "Number", "Mode", "Task", "Document name", "Receipt date"],
                     NamingTokens.All.Select(t => t.Label));
        Assert.Equal(["{date}", "{time}", "{counter}", "{intent}", "{task}", "{label}", "{docdate}"],
                     NamingTokens.All.Select(t => t.Token));
        Assert.All(NamingTokens.All, t =>
        {
            Assert.True(NamingTokens.IsKnown(t.Token), t.Token);
            Assert.InRange(StatusLine.Words(t.Label), 1, 3);
            Assert.InRange(StatusLine.Words(t.Help), 1, 15);
        });
    }

    [Fact]
    public void Insert_PutsASpaceBefore_UnlessAfterASpaceOrAtTheStart_AndMovesTheCaretPastIt()
    {
        Assert.Equal(new NamingInsertion("Scan {date}", 11), NamingTokens.Insert("{date}", "Scan", 4));
        Assert.Equal(new NamingInsertion("Scan {date}", 11), NamingTokens.Insert("{date}", "Scan ", 5));
        Assert.Equal(new NamingInsertion("{counter}", 9), NamingTokens.Insert("{counter}", "", 0));
        Assert.Equal(new NamingInsertion("A {date}B", 8), NamingTokens.Insert("{date}", "AB", 1));
        Assert.Equal(new NamingInsertion("{date}Scan", 6), NamingTokens.Insert("{date}", "Scan", -3));
        Assert.Equal(new NamingInsertion("A {time}", 8), NamingTokens.Insert("{time}", "A", 99));
    }

    [Fact]
    public void Problem_NamesABlankTemplate_AndTheFirstUnknownPart()
    {
        Assert.Equal(NamingTokens.EmptyProblem, NamingTokens.Problem(""));
        Assert.Equal("Needs a file name", NamingTokens.Problem("   "));
        Assert.Null(NamingTokens.Problem("Scan {date} {counter}"));
        Assert.Null(NamingTokens.Problem("Scan {counter:3} {year}-{month}-{day} {time} {intent} {index}"));
        Assert.Null(NamingTokens.Problem("{task} {label} {docdate}"));
        Assert.Equal("Unknown part {foo}", NamingTokens.Problem("Scan {foo} {bar}"));
        Assert.Equal("Unknown part {counter:}", NamingTokens.Problem("Scan {counter:}"));
        Assert.Equal("Unknown part {counter:x}", NamingTokens.Problem("Scan {counter:x}"));
        Assert.Equal("Unknown part {Date}", NamingTokens.Problem("{Date}"));
        // An unclosed brace is text; a brace inside braces starts the part again.
        Assert.Null(NamingTokens.Problem("Scan {date"));
        Assert.Null(NamingTokens.Problem("{{date}}"));
        Assert.Equal(["{a}", "{b}"], NamingTokens.Braced("x{a}y{b}"));
    }

    [Fact]
    public void SavedFormat_IsWhatTheSaveWrites()
    {
        var s = new ScanSettings();
        Assert.Equal(OutputFormat.Pdf, NamingTokens.SavedFormat(s));
        s.Format = OutputFormat.Png;
        Assert.Equal(OutputFormat.Pdf, NamingTokens.SavedFormat(s));
        s.DocumentMultiPage = false;
        Assert.Equal(OutputFormat.Png, NamingTokens.SavedFormat(s));
        s.Format = OutputFormat.Word;
        s.DocumentMultiPage = true;
        Assert.Equal(OutputFormat.Word, NamingTokens.SavedFormat(s));

        var photos = new ScanSettings { Intent = ScanIntent.Photo, Format = OutputFormat.Pdf };
        Assert.Equal(OutputFormat.Jpeg, NamingTokens.SavedFormat(photos));

        var receipts = TaskCatalog.Apply(ScanTask.Receipt, new ScanSettings());
        receipts.Format = OutputFormat.Word;
        Assert.Equal(OutputFormat.Pdf, NamingTokens.SavedFormat(receipts));
        receipts.Format = OutputFormat.Jpeg;
        Assert.Equal(OutputFormat.Jpeg, NamingTokens.SavedFormat(receipts));
    }

    [Fact]
    public void Example_IsTheNextFilesName()
    {
        var s = new ScanSettings();
        Assert.Equal("Scan 2026-10-20 007.pdf",
                     NamingTokens.Example("Scan {date} {counter:3}", s, OutputFormat.Pdf, 7, FixedDate()));
        Assert.Equal("Scan.pdf", NamingTokens.Example("   ", s, OutputFormat.Pdf, 1, FixedDate()));
        Assert.Equal("Scan 14.05.32 4.jpg", NamingTokens.Example("Scan {time} {counter}", s, OutputFormat.Jpeg, 4, FixedDate()));

        var receipts = TaskCatalog.Apply(ScanTask.Receipt, new ScanSettings());
        string label = TaskCatalog.Definition(ScanTask.Receipt).FileLabel;
        Assert.Equal($"{label} 2026-10-20.pdf",
                     NamingTokens.Example("{task} {docdate}", receipts, OutputFormat.Pdf, 1, FixedDate()));
    }
}
