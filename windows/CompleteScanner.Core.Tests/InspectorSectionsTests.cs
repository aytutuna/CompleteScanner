using CompleteScanner.Core;
using Xunit;

namespace CompleteScanner.Core.Tests;

// Twin of Tests/CompleteScannerTests/InspectorSectionsTests.swift: the settings column's sections and
// the summaries their collapsed headers show.
public class InspectorSectionsTests
{
    [Fact]
    public void OnlyTheTaskScannerAndOutput_StartOpen()
    {
        Assert.Equal(["task", "scanner", "output", "adjustments", "pages", "split", "archive", "more"], InspectorSections.All);
        Assert.True(InspectorSections.OpenByDefault(InspectorSections.Task));
        Assert.True(InspectorSections.OpenByDefault(InspectorSections.Scanner));
        Assert.True(InspectorSections.OpenByDefault(InspectorSections.Output));
        foreach (var id in new[] { InspectorSections.Adjustments, InspectorSections.Pages, InspectorSections.Split,
                                   InspectorSections.Archive, InspectorSections.More })
        {
            Assert.False(InspectorSections.OpenByDefault(id));
        }
        Assert.Equal(InspectorSections.Adjustments, InspectorSections.OpenedBy(ScanTask.PhotoRestore));
        Assert.Equal(InspectorSections.Pages, InspectorSections.OpenedBy(ScanTask.Book));
        Assert.Equal(InspectorSections.Split, InspectorSections.OpenedBy(ScanTask.Batch));
        Assert.Equal(InspectorSections.Archive, InspectorSections.OpenedBy(ScanTask.Archive));
        Assert.Null(InspectorSections.OpenedBy(ScanTask.Document));
    }

    [Fact]
    public void Titles_AreShort()
    {
        Assert.Equal(["Task", "Scanner", "Output", "Adjustments", "Pages", "Split into documents", "Archive & password", "More options"],
                     InspectorSections.All.Select(InspectorSections.Title));
        Assert.All(InspectorSections.All, id => Assert.InRange(StatusLine.Words(InspectorSections.Title(id)), 1, 3));
    }

    [Fact]
    public void Summaries_OfTheDefaults_SayLittle_AndShowNoChange()
    {
        var s = new ScanSettings();
        Assert.Equal("Flatbed · 300 dpi · Color", InspectorSections.ScannerSummary(s));
        Assert.False(InspectorSections.ScannerChanged(s));
        Assert.Equal("PDF · Standard", InspectorSections.OutputSummary(s, OutputFormat.Pdf));
        Assert.False(InspectorSections.OutputChanged(s, OutputFormat.Pdf));
        Assert.Equal("", InspectorSections.AdjustmentsSummary(s.Adjustments));
        Assert.Equal("", InspectorSections.PagesSummary(s.Document));
        Assert.Equal("Off", InspectorSections.SplitSummary(s.Document));
        Assert.Equal("Off", InspectorSections.ArchiveSummary(s.Output));
        Assert.Equal("", InspectorSections.MoreSummary(s.Output, textShown: true));
        Assert.Equal("Pages", InspectorSections.PagesHeaderName(s.Document));
        Assert.Equal("Scanner, Flatbed · 300 dpi · Color", InspectorSections.HeaderName("Scanner", InspectorSections.ScannerSummary(s)));
        Assert.Equal("More options", InspectorSections.HeaderName("More options", ""));
    }

    [Fact]
    public void Summaries_SayWhatIsOn()
    {
        var s = new ScanSettings
        {
            Source = ScanSource.DocumentFeeder,
            Duplex = DuplexMode.Both,
            ColorMode = ColorMode.Grayscale,
            Resolution = 200,
            Format = OutputFormat.Word,
        };
        Assert.Equal("Feeder · both sides · 200 dpi · Gray", InspectorSections.ScannerSummary(s));
        Assert.True(InspectorSections.ScannerChanged(s));
        Assert.Equal("Word", InspectorSections.OutputSummary(s, OutputFormat.Word));
        Assert.True(InspectorSections.OutputChanged(s, OutputFormat.Word));
        Assert.Equal("JPEG", InspectorSections.OutputSummary(new ScanSettings { Intent = ScanIntent.Photo }, OutputFormat.Jpeg));
        // Photos at their defaults save JPEG: nothing changed; another image format is a change.
        Assert.False(InspectorSections.OutputChanged(new ScanSettings { Intent = ScanIntent.Photo }, OutputFormat.Jpeg));
        Assert.True(InspectorSections.OutputChanged(new ScanSettings { Intent = ScanIntent.Photo }, OutputFormat.Png));
        // A PDF size other than the default is a change only while a PDF is shown.
        var compact = new ScanSettings();
        compact.Output.PdfSize = PdfSizePreset.Compact;
        Assert.True(InspectorSections.OutputChanged(compact, OutputFormat.Pdf));
        compact.Intent = ScanIntent.Photo;
        Assert.False(InspectorSections.OutputChanged(compact, OutputFormat.Jpeg));
        Assert.Equal("Text", InspectorSections.OutputSummary(s, OutputFormat.Text));

        s.Adjustments.AutoEnhance = true;
        Assert.Equal("Auto", InspectorSections.AdjustmentsSummary(s.Adjustments));
        s.Adjustments.Brightness = 0.2;
        Assert.Equal("Edited", InspectorSections.AdjustmentsSummary(s.Adjustments));

        s.Document.RemoveBlankPages = true;
        s.Document.AutoRotate = true;
        Assert.Equal("Skip blank · Upright", InspectorSections.PagesSummary(s.Document));
        s.Document.SplitFacingPages = true;
        Assert.Equal("Skip blank · Upright +1", InspectorSections.PagesSummary(s.Document));
        Assert.Equal(3, InspectorSections.PagesOn(s.Document));
        Assert.Equal("Pages, 3 options on", InspectorSections.PagesHeaderName(s.Document));
        s.Document.RemoveBlankPages = false;
        s.Document.SplitFacingPages = false;
        Assert.Equal("Pages, 1 option on", InspectorSections.PagesHeaderName(s.Document));

        s.Document.SplitMode = SplitMode.SheetCount;
        s.Document.SplitSheetCount = 3;
        Assert.Equal("Every 3 sheets", InspectorSections.SplitSummary(s.Document));
        s.Document.SplitSheetCount = 1;
        Assert.Equal("Every sheet", InspectorSections.SplitSummary(s.Document));
        s.Document.SplitMode = SplitMode.Barcode;
        Assert.Equal("QR codes", InspectorSections.SplitSummary(s.Document));
        s.Document.SplitMode = SplitMode.SeparatorSheet;
        Assert.Equal("Separator sheets", InspectorSections.SplitSummary(s.Document));

        s.Output.Archival = true;
        Assert.Equal("PDF/A", InspectorSections.ArchiveSummary(s.Output));
        s.Output.Protect = true;
        Assert.Equal("Password on", InspectorSections.ArchiveSummary(s.Output));

        s.Output.AfterSave = AfterSaveAction.Open;
        s.Output.AlsoSaveText = true;
        Assert.Equal("Open after saving · .txt", InspectorSections.MoreSummary(s.Output, textShown: true));
        Assert.Equal("Open after saving", InspectorSections.MoreSummary(s.Output, textShown: false));
        s.Output.AfterSave = AfterSaveAction.Share;
        Assert.Equal("Share after saving · .txt", InspectorSections.MoreSummary(s.Output, textShown: true));
    }

    [Fact]
    public void Shown_HidesWhatCannotApply_EachSectionOnce()
    {
        var s = new ScanSettings();
        Assert.Equal(["scanner", "output", "adjustments", "pages", "split", "archive", "more"], InspectorSections.Shown(s));
        Assert.Equal("Output", InspectorSections.Title(InspectorSections.Output, s));
        Assert.True(InspectorSections.TextApplies(s));

        s.Format = OutputFormat.Word;
        Assert.Equal(["scanner", "output", "adjustments", "pages", "split", "more"], InspectorSections.Shown(s));
        Assert.False(InspectorSections.WritesPdf(s));
        Assert.False(InspectorSections.TextApplies(s));

        // A queue of image pages is saved as a PDF.
        s.Format = OutputFormat.Jpeg;
        Assert.True(InspectorSections.WritesPdf(s));
        s.DocumentMultiPage = false;
        Assert.False(InspectorSections.WritesPdf(s));

        var photos = new ScanSettings { Intent = ScanIntent.Photo };
        Assert.Equal(["scanner", "output", "adjustments", "more"], InspectorSections.Shown(photos));
        Assert.Equal("Photos", InspectorSections.Title(InspectorSections.Output, photos));
        Assert.Equal(OutputFormat.Jpeg, InspectorSections.ShownFormat(photos));

        var receipts = TaskCatalog.Apply(ScanTask.Receipt, new ScanSettings());
        receipts.Format = OutputFormat.Word;
        Assert.Equal(["task", "scanner", "output", "adjustments", "archive", "more"], InspectorSections.Shown(receipts));
        Assert.Equal("Receipts", InspectorSections.Title(InspectorSections.Task, receipts));
        Assert.Equal(OutputFormat.Pdf, InspectorSections.ShownFormat(receipts));
        Assert.True(InspectorSections.TextApplies(receipts));
        receipts.Format = OutputFormat.Png;
        Assert.DoesNotContain(InspectorSections.Archive, InspectorSections.Shown(receipts));

        var copy = TaskCatalog.Apply(ScanTask.Copy, new ScanSettings());
        copy.TaskOptions.CopyAlsoSavePdf = false;
        Assert.Equal(["task", "scanner", "output", "adjustments", "more"], InspectorSections.Shown(copy));
        Assert.Equal("Photocopy", InspectorSections.Title(InspectorSections.Task, copy));
        copy.TaskOptions.CopyAlsoSavePdf = true;
        Assert.Contains(InspectorSections.Archive, InspectorSections.Shown(copy));
        Assert.False(InspectorSections.TextApplies(copy));

        // The ID card never goes through the queue and is saved from its review as a PDF or an image.
        var idCard = TaskCatalog.Apply(ScanTask.IdCard, new ScanSettings());
        idCard.Format = OutputFormat.Word;
        Assert.Equal(["scanner", "output", "adjustments", "archive", "more"], InspectorSections.Shown(idCard));
        Assert.Equal(OutputFormat.Pdf, InspectorSections.ShownFormat(idCard));
        Assert.True(InspectorSections.SavesPageFormat(idCard));
        Assert.True(InspectorSections.SavesPageFormat(receipts));
        Assert.False(InspectorSections.SavesPageFormat(new ScanSettings()));
        Assert.False(InspectorSections.TextApplies(idCard));
        idCard.Format = OutputFormat.Png;
        Assert.DoesNotContain(InspectorSections.Archive, InspectorSections.Shown(idCard));

        Assert.Null(InspectorSections.TaskTitle(new ScanSettings()));
        Assert.Equal("Task", InspectorSections.Title(InspectorSections.Task, new ScanSettings()));
        foreach (var settings in new[] { s, photos, receipts, copy, idCard })
        {
            var shown = InspectorSections.Shown(settings);
            Assert.Equal(shown.Count, shown.Distinct().Count());
            Assert.Equal(InspectorSections.All.Where(shown.Contains), shown);
        }
    }

    [Fact]
    public void Headers_ForASetting_HaveTheirSummaryDotAndName()
    {
        var s = new ScanSettings();
        Assert.Equal("Flatbed · 300 dpi · Color", InspectorSections.Summary(InspectorSections.Scanner, s));
        Assert.False(InspectorSections.Changed(InspectorSections.Scanner, s));
        Assert.Equal("Scanner, Flatbed · 300 dpi · Color", InspectorSections.AccessibleName(InspectorSections.Scanner, s));
        Assert.Equal("PDF · Standard", InspectorSections.Summary(InspectorSections.Output, s));
        Assert.False(InspectorSections.Changed(InspectorSections.Output, s));
        Assert.Equal("", InspectorSections.Summary(InspectorSections.Pages, s));
        Assert.False(InspectorSections.Changed(InspectorSections.Pages, s));
        Assert.Equal("Pages", InspectorSections.AccessibleName(InspectorSections.Pages, s));
        Assert.Equal("Off", InspectorSections.Summary(InspectorSections.Split, s));
        Assert.False(InspectorSections.Changed(InspectorSections.Split, s));
        Assert.Equal("Off", InspectorSections.Summary(InspectorSections.Archive, s));
        Assert.False(InspectorSections.Changed(InspectorSections.Archive, s));
        Assert.Equal("", InspectorSections.Summary(InspectorSections.More, s));
        Assert.False(InspectorSections.Changed(InspectorSections.More, s));
        Assert.Equal("More options", InspectorSections.AccessibleName(InspectorSections.More, s));
        Assert.Equal("", InspectorSections.Summary(InspectorSections.Task, s));
        Assert.False(InspectorSections.Changed(InspectorSections.Task, s));

        s.Resolution = 600;
        s.Output.AlsoSaveText = true;
        s.Output.Protect = true;
        s.Document.SplitMode = SplitMode.BlankSheet;
        s.Document.AutoCrop = true;
        s.Document.AutoRotate = true;
        Assert.Equal("Crop · Upright", InspectorSections.Summary(InspectorSections.Pages, s));
        Assert.True(InspectorSections.Changed(InspectorSections.Pages, s));
        Assert.Equal("Pages, 2 options on", InspectorSections.AccessibleName(InspectorSections.Pages, s));
        Assert.True(InspectorSections.Changed(InspectorSections.Scanner, s));
        Assert.Equal(".txt", InspectorSections.Summary(InspectorSections.More, s));
        Assert.True(InspectorSections.Changed(InspectorSections.More, s));
        Assert.Equal("Archive & password, Password on", InspectorSections.AccessibleName(InspectorSections.Archive, s));
        Assert.True(InspectorSections.Changed(InspectorSections.Split, s));
        s.Format = OutputFormat.Word;
        Assert.Equal("", InspectorSections.Summary(InspectorSections.More, s));
        Assert.Equal("Word", InspectorSections.Summary(InspectorSections.Output, s));
        Assert.True(InspectorSections.Changed(InspectorSections.Output, s));

        var photos = new ScanSettings { Intent = ScanIntent.Photo };
        Assert.Equal("Photos, JPEG", InspectorSections.AccessibleName(InspectorSections.Output, photos));
    }
}
