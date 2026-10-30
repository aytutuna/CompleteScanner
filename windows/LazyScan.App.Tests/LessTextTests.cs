using LazyScan.Core;
using Xunit;

namespace LazyScan.App.Tests;

// The Windows layout's own short texts: the start screen's tile line, the Saved bar's line, what the
// inspector shows for the format and the split, and the last PDF's size. The short texts both apps
// show (the status line, the inspector's summaries, disabled reasons) are Core's, checked by
// StatusLineTests and InspectorSectionsTests in LazyScan.Core.Tests and their Swift twins.
public class LessTextTests
{
    // MARK: - Start screen

    [Fact]
    public void TaskTile_UnavailableReason_IsTheShortReason_TheTooltipKeepsWhatItSets()
    {
        var feeder = TaskCatalog.Definition(ScanTask.Feeder);
        var reason = TaskCatalog.Availability(ScanTask.Feeder, new ScannerCapabilities { Sources = [ScanSource.Flatbed] });
        var card = new TaskCardItem(feeder, reason, false, "300 dpi · Color · PDF");
        Assert.Equal("Needs a document feeder", card.ShortReason);
        Assert.Equal("300 dpi · Color · PDF", card.TipDetail);
        var copy = new TaskCardItem(TaskCatalog.Definition(ScanTask.Copy),
                                    TaskCatalog.Availability(ScanTask.Copy, null, hasPrinter: false), false, "300 dpi · Color · Actual size");
        Assert.Equal("Needs a printer", copy.ShortReason);
        var available = new TaskCardItem(feeder, TaskAvailability.Available, false, "300 dpi · Color · PDF");
        Assert.Null(available.ShortReason);
        Assert.Equal("300 dpi · Color · PDF", available.TipDetail);
    }

    // MARK: - Saved bar and sizes

    [Fact]
    public void SavedBarLine_NamesTheFile_OrCountsWhatWasSavedAndTheirFolder()
    {
        Assert.Equal("Scan 2026-10-20 1.pdf", MainWindow.SavedBarLine([@"C:\x\files\Scan 2026-10-20 1.pdf"], "photos"));
        Assert.Equal("3 photos · files", MainWindow.SavedBarLine([@"C:\x\files\a.jpg", @"C:\x\files\b.jpg", @"C:\x\files\c.png"], "photos"));
        // Receipts and document pages saved as images are not photos.
        Assert.Equal("3 receipts · files", MainWindow.SavedBarLine([@"C:\x\files\a.jpg", @"C:\x\files\b.jpg", @"C:\x\files\c.jpg"], "receipts"));
        Assert.Equal("3 files · files", MainWindow.SavedBarLine([@"C:\x\files\a.png", @"C:\x\files\b.png", @"C:\x\files\c.png"]));
        Assert.Equal("2 files · files", MainWindow.SavedBarLine([@"C:\x\files\a.pdf", @"C:\x\files\b.jpg"], "photos"));
    }

    // MARK: - What shows for the format and the split

    [Fact]
    public void WhatCountsAsBlank_ShowsWhileItDecidesSomething()
    {
        // Collected pages are checked for blanks whatever Skip blank is set to: the strip flags
        // "Looks blank" with Skip off, so what counts as blank shows then too.
        var s = new ScanSettings { Intent = ScanIntent.Document, DocumentMultiPage = true };
        s.Document.RemoveBlankPages = false;
        s.Document.SplitMode = SplitMode.None;
        Assert.True(MainWindow.BlankSensitivityApplies(s));
        s.Document.RemoveBlankPages = true;
        Assert.True(MainWindow.BlankSensitivityApplies(s));
        s.Document.RemoveBlankPages = false;
        foreach (var split in new[] { SplitMode.BlankSheet, SplitMode.SeparatorSheet, SplitMode.Barcode })
        {
            s.Document.SplitMode = split;
            Assert.True(MainWindow.BlankSensitivityApplies(s));
        }
        // Each scan saved at once is never checked; nor are copies, receipts, ID cards or photos.
        s.DocumentMultiPage = false;
        Assert.False(MainWindow.BlankSensitivityApplies(s));
        foreach (var task in new[] { ScanTask.Copy, ScanTask.Receipt, ScanTask.IdCard, ScanTask.Photos })
        {
            var other = TaskCatalog.Apply(task, new ScanSettings());
            other.DocumentMultiPage = true;
            other.Document.RemoveBlankPages = true;
            Assert.False(MainWindow.BlankSensitivityApplies(other), task.ToString());
        }
    }

    [Fact]
    public void WritesPdf_FollowsWhatTheSaveWrites_NotTheFormatShown()
    {
        // A queue of JPEG pages is saved as a PDF; each JPEG scan saved at once is not.
        var s = new ScanSettings { Intent = ScanIntent.Document, Format = OutputFormat.Jpeg, DocumentMultiPage = true };
        Assert.True(MainWindow.WritesPdf(s));
        s.DocumentMultiPage = false;
        Assert.False(MainWindow.WritesPdf(s));
        s.Format = OutputFormat.Pdf;
        Assert.True(MainWindow.WritesPdf(s));
        s.Format = OutputFormat.Word;
        s.DocumentMultiPage = true;
        Assert.False(MainWindow.WritesPdf(s));
        // Photos never save a PDF.
        var photos = new ScanSettings { Intent = ScanIntent.Photo, Format = OutputFormat.Pdf, DocumentMultiPage = true };
        Assert.False(MainWindow.WritesPdf(photos));
    }

    [Fact]
    public void WritesPdf_ForACopy_IsAlsoSaveAsPdf_WhateverTheFormat()
    {
        // A copy's PDF is written with the password and PDF/A, so Archive & password shows for it.
        var copy = TaskCatalog.Apply(ScanTask.Copy, new ScanSettings());
        Assert.Equal(TaskFlowKind.Copy, TaskCatalog.FlowOf(copy));
        foreach (var format in new[] { OutputFormat.Pdf, OutputFormat.Jpeg, OutputFormat.Word })
        {
            copy.Format = format;
            copy.TaskOptions.CopyAlsoSavePdf = false;
            Assert.False(MainWindow.WritesPdf(copy));
            copy.TaskOptions.CopyAlsoSavePdf = true;
            Assert.True(MainWindow.WritesPdf(copy));
        }
    }

    [Theory]
    [InlineData(497_700, "498 KB")]
    [InlineData(1_000, "1 KB")]
    [InlineData(999_600, "999.6 KB")]
    [InlineData(1_234_567, "1.2 MB")]
    [InlineData(512, "512 bytes")]
    public void LastPdfSize_IsRoundedToWholeKilobytes(long bytes, string expected)
    {
        Assert.Equal(expected, AppViewModel.RoundedSizeText(bytes));
    }
}
