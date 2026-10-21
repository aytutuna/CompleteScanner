using CompleteScanner.Core;
using Xunit;

namespace CompleteScanner.App.Tests;

// The Windows layout's short texts: the status line, the first-sentence split behind the ⓘ, the side
// badges, the start screen's groups and the inspector's section summaries. Windows only: the Mac lays
// out its own views (the shared strings these shorten stay in Core, unchanged).
public class LessTextTests
{
    // MARK: - Status line

    [Theory]
    [InlineData("Added 1 page — 3 in queue. Scan more or Save PDF.", "Page 3 added")]
    [InlineData("Added 6 pages from 3 sheets, both sides — 6 in queue. Scan more or Save PDF. 1 looks blank and will be skipped.", "6 pages added · 1 blank")]
    [InlineData("Added 2 pages — 4 in queue. Scan more or Save PDF. 1 spread split into pages. Spine shadow softened on 2 pages.", "2 pages added · 1 spread split")]
    [InlineData("Saved 3-page PDF: Scan 2026-10-20 1.pdf (497.7 KB)", "Saved")]
    [InlineData(@"Saved 3 photos to C:\Users\me\files", "Saved 3 photos")]
    [InlineData("Found 3 photos on the bed.", "Found 3 photos")]
    [InlineData("Front scanned. Turn the card over where it lies and scan the back, or skip it.", "Front scanned")]
    [InlineData("Back scanned. Check the sides, then save.", "Back scanned")]
    [InlineData("Page queue cleared.", "Queue cleared")]
    [InlineData("Ready — Demo Scanner", "Ready — Demo Scanner")]
    [InlineData("Overview ready — drag on the preview to select an area, then Scan.", "Overview ready")]
    [InlineData("Scanning…", "Scanning…")]
    [InlineData("Reading the text of page 3 of 12…", "Reading page 3 of 12…")]
    [InlineData("Adding 3 pages to Scan 2026-10-20 1.pdf…", "Adding 3 pages…")]
    [InlineData("Sent the ruler test page to Office Laser. At real size each square measures 1 inch.", "Sent to the printer")]
    public void StatusLine_IsShortAndFactual(string message, string expected)
    {
        Assert.Equal(expected, StatusLine.Short(message));
    }

    [Fact]
    public void StatusLine_ReadyForATask_NamesTheScannerInstead()
    {
        Assert.Equal("Ready — Demo Scanner", StatusLine.Short("Ready for “Document to PDF”.", "Demo Scanner"));
        Assert.Equal("Ready", StatusLine.Short("Ready for “Document to PDF”."));
    }

    [Theory]
    [InlineData("Could not connect to the Epson Perfection V600 Photo scanner over the network.")]
    [InlineData("Scanned 3 front sides before the feeder stopped. Load the rest of the stack and scan, or turn it over.")]
    [InlineData("The ID card task ended during the scan. Nothing of the card was kept.")]
    [InlineData("A very long message without any punctuation that goes on and on about nothing in particular")]
    public void StatusLine_NeverShowsMoreThanSixWords(string message)
    {
        string shown = StatusLine.Short(message);
        Assert.InRange(StatusLine.Words(shown), 1, StatusLine.MaxWords);
    }

    /// <summary>The status after settings met a scanner, as the view model builds it: the message, then each note.</summary>
    private static string WithNotes(string message, ScanSettings settings, ScannerCapabilities capabilities)
    {
        var notes = SettingsAdapter.Adapt(settings, capabilities).Notes;
        Assert.NotEmpty(notes);
        return $"{message} {string.Join(" ", notes.Select(n => n.Message))}";
    }

    [Fact]
    public void StatusLine_KeepsASettingChangedForTheScanner_AsAShortWarning()
    {
        // A preset at 600 dpi on a scanner that tops out at 300.
        var resolution = WithNotes("Applied preset “Invoices”.", new ScanSettings { Resolution = 600 },
                                   new ScannerCapabilities { SupportedResolutions = [150, 300] });
        Assert.Equal("Applied preset “Invoices” · 300 dpi used", StatusLine.Short(resolution));
        // A longer preset name leaves no room: the warning wins.
        var longName = WithNotes("Applied preset “Monthly office invoices”.", new ScanSettings { Resolution = 600 },
                                 new ScannerCapabilities { SupportedResolutions = [150, 300] });
        Assert.Equal("300 dpi used", StatusLine.Short(longName));
        // A scanner without a flatbed connects: no full stop before the note, and the name stays.
        var feeder = WithNotes("Ready — Demo Scanner", new ScanSettings { Source = ScanSource.Flatbed },
                               new ScannerCapabilities { Sources = [ScanSource.DocumentFeeder], FeederSizeInches = new(8.5, 14) });
        Assert.Equal("Ready — Demo Scanner · feeder used", StatusLine.Short(feeder));
        // A task is picked: "Ready — device" and the note.
        string picked = feeder.Replace("Ready — Demo Scanner", "Ready for “Document to PDF”.", StringComparison.Ordinal);
        Assert.Equal("Ready — Demo Scanner · feeder used", StatusLine.Short(picked, "Demo Scanner"));
        var flatbed = WithNotes("Ready — Demo Scanner", new ScanSettings { Source = ScanSource.DocumentFeeder },
                                new ScannerCapabilities { Sources = [ScanSource.Flatbed] });
        Assert.Equal("Ready — Demo Scanner · flatbed used", StatusLine.Short(flatbed));
        var paper = WithNotes("Ready — Demo Scanner", new ScanSettings { PaperSize = PaperSize.Legal },
                              new ScannerCapabilities());
        Assert.Equal("Ready — Demo Scanner · paper size Automatic", StatusLine.Short(paper));
        var sides = WithNotes("Ready — Demo Scanner", new ScanSettings { Source = ScanSource.DocumentFeeder, Duplex = DuplexMode.Both },
                              new ScannerCapabilities { Sources = [ScanSource.DocumentFeeder], FeederSizeInches = new(8.5, 14) });
        Assert.Equal("Ready — Demo Scanner · two-sided by hand", StatusLine.Short(sides));
        // Every note at once: as many as fit, then how many more.
        var all = WithNotes("Ready — Demo Scanner",
                            new ScanSettings { Source = ScanSource.Flatbed, Duplex = DuplexMode.Both, PaperSize = PaperSize.Legal, Resolution = 600 },
                            new ScannerCapabilities { Sources = [ScanSource.DocumentFeeder], FeederSizeInches = new(8.5, 11), SupportedResolutions = [300] });
        Assert.Equal("Feeder used · two-sided by hand +2", StatusLine.Short(all));
        foreach (var message in new[] { resolution, longName, feeder, picked, flatbed, paper, sides, all })
        {
            Assert.InRange(StatusLine.Words(StatusLine.Short(message, "Demo Scanner")), 1, StatusLine.MaxWords);
        }
    }

    [Fact]
    public void StatusLine_ATwoSidedScanThatCameBackOneSided_SaysSo()
    {
        Assert.Equal("3 pages added · one side only", StatusLine.Short(
            "Added 3 pages, one side of each sheet: the scanner did not scan both sides — 3 in queue. Scan more or Save PDF."));
        Assert.Equal("Page 4 added · one side only", StatusLine.Short(
            "Added 1 page, one side of each sheet: the scanner did not scan both sides — 4 in queue. Scan more or Save PDF."));
    }

    [Fact]
    public void StatusLine_Words_CountsTokensWithALetterOrDigit()
    {
        Assert.Equal(3, StatusLine.Words("Ready — Demo Scanner"));
        Assert.Equal(5, StatusLine.Words("6 pages added · 1 blank"));
    }

    // MARK: - First sentence and the rest

    [Fact]
    public void TextSplit_KeepsTheFirstSentence_AndCapitalizesTheRest()
    {
        var (lead, more) = TextSplit.Lead("Place a page face down on the glass and scan it. Repeat for every page, then save the PDF.");
        Assert.Equal("Place a page face down on the glass and scan it.", lead);
        Assert.Equal("Repeat for every page, then save the PDF.", more);
    }

    [Fact]
    public void TextSplit_CutsAtAColon_AndEndsTheLineWithAFullStop()
    {
        var (lead, more) = TextSplit.Lead("Load the pages in the document feeder and scan: both sides of every sheet are scanned and put in order. Then save the PDF.");
        Assert.Equal("Load the pages in the document feeder and scan.", lead);
        Assert.Equal("Both sides of every sheet are scanned and put in order. Then save the PDF.", more);
    }

    [Fact]
    public void TextSplit_OneSentence_HasNoRest_AndAbbreviationsAreNotCut()
    {
        Assert.Equal(("Check both sides, then save them on one page at their real size.", ""),
                     TextSplit.Lead("Check both sides, then save them on one page at their real size."));
        Assert.Equal(("Enter it, e.g. 192.168.1.50 or scanner.local.", ""),
                     TextSplit.Lead("Enter it, e.g. 192.168.1.50 or scanner.local."));
    }

    [Fact]
    public void TextSplit_EveryTaskPrompt_LeadsWithItsFirstSentence()
    {
        foreach (var task in TaskCatalog.All)
        {
            foreach (var step in task.Steps)
            {
                var (lead, more) = TextSplit.Lead(step.Prompt);
                Assert.StartsWith(lead.TrimEnd('.'), step.Prompt);
                Assert.True(lead.Length < step.Prompt.Length || more.Length == 0, task.Title);
                Assert.True(more.Length == 0 || char.IsUpper(more[0]), $"{task.Title}: {more}");
            }
        }
    }

    // MARK: - Side badges

    [Fact]
    public void SideBadge_IsShort_AndItsNameSpellsTheSheetOut()
    {
        Assert.Equal("1 · front", SideBadge.Text(PageSide.Front, 0));
        Assert.Equal("2 · back", SideBadge.Text(PageSide.Back, 1));
        Assert.Equal("Sheet 2, back", SideBadge.Name(PageSide.Back, 1));
        Assert.Equal("Front", SideBadge.Text(PageSide.Front, null));
        Assert.Null(SideBadge.Text(null, 3));
        Assert.Null(SideBadge.Name(null, 3));
    }

    // MARK: - Step indicator

    [Theory]
    [InlineData("Front side", "Front")]
    [InlineData("Back side", "Back")]
    [InlineData("Check and save", "Check")]
    [InlineData("Scan the front sides", "Front")]
    [InlineData("Scan the back sides", "Back")]
    public void StepWord_IsTheStepInOneWord(string title, string expected)
    {
        Assert.Equal(expected, StepWords.Of(title));
    }

    [Fact]
    public void StepWords_OfEveryTaskWithSteps_AreDistinct()
    {
        foreach (var task in TaskCatalog.All.Where(t => t.Steps.Count > 1))
        {
            var words = task.Steps.Select(s => StepWords.Of(s.Title)).ToList();
            Assert.Equal(words.Count, words.Distinct().Count());
        }
    }

    // MARK: - Start screen

    [Fact]
    public void TaskGroups_HoldEveryTaskOnce_InThreeGroups()
    {
        var all = TaskGroups.All.SelectMany(g => g.Tasks).ToList();
        Assert.Equal(Enum.GetValues<ScanTask>().Length, all.Count);
        Assert.Equal(Enum.GetValues<ScanTask>().Order(), all.Order());
        Assert.Equal(["Documents", "Photos & images", "Other"], TaskGroups.All.Select(g => g.Title));
        Assert.Equal("Other", TaskGroups.TitleOf(ScanTask.IdCard));
        Assert.Equal("Photos & images", TaskGroups.TitleOf(ScanTask.QuickScan));
    }

    [Fact]
    public void TaskTile_UnavailableReason_IsShort_TheFullReasonStaysTheTooltip()
    {
        var feeder = TaskCatalog.Definition(ScanTask.Feeder);
        Assert.Equal("Needs a document feeder", TaskCardItem.ShortReasonFor(feeder, "This scanner has no document feeder."));
        Assert.Equal("Needs a printer", TaskCardItem.ShortReasonFor(TaskCatalog.Definition(ScanTask.Copy), "No printer is installed."));
        var card = new TaskCardItem(feeder, new TaskAvailability(false, "This scanner has no document feeder."), false, "300 dpi · Color · PDF");
        Assert.Equal("Needs a document feeder", card.ShortReason);
        Assert.Equal("This scanner has no document feeder.", card.TipDetail);
        var available = new TaskCardItem(feeder, TaskAvailability.Available, false, "300 dpi · Color · PDF");
        Assert.Null(available.ShortReason);
        Assert.Equal("300 dpi · Color · PDF", available.TipDetail);
    }

    // MARK: - Inspector summaries

    [Fact]
    public void Sections_OnlyTheTaskScannerAndOutput_StartOpen()
    {
        Assert.True(InspectorSummary.OpenByDefault(InspectorSummary.Task));
        Assert.True(InspectorSummary.OpenByDefault(InspectorSummary.Scanner));
        Assert.True(InspectorSummary.OpenByDefault(InspectorSummary.Output));
        foreach (var id in new[] { InspectorSummary.Adjustments, InspectorSummary.Pages, InspectorSummary.Split,
                                   InspectorSummary.Archive, InspectorSummary.More })
        {
            Assert.False(InspectorSummary.OpenByDefault(id));
        }
        Assert.Equal(InspectorSummary.Adjustments, InspectorSummary.OpenedBy(ScanTask.PhotoRestore));
        Assert.Equal(InspectorSummary.Pages, InspectorSummary.OpenedBy(ScanTask.Book));
        Assert.Equal(InspectorSummary.Split, InspectorSummary.OpenedBy(ScanTask.Batch));
        Assert.Equal(InspectorSummary.Archive, InspectorSummary.OpenedBy(ScanTask.Archive));
        Assert.Null(InspectorSummary.OpenedBy(ScanTask.Document));
    }

    [Fact]
    public void Summaries_OfTheDefaults_SayLittle_AndShowNoChange()
    {
        var s = new ScanSettings();
        Assert.Equal("Flatbed · 300 dpi · Color", InspectorSummary.ScannerSummary(s));
        Assert.False(InspectorSummary.ScannerChanged(s));
        Assert.Equal("PDF · Standard", InspectorSummary.OutputSummary(s, OutputFormat.Pdf));
        Assert.False(InspectorSummary.OutputChanged(s, OutputFormat.Pdf));
        Assert.Equal("", InspectorSummary.AdjustmentsSummary(s.Adjustments));
        Assert.Equal("", InspectorSummary.PagesSummary(s.Document));
        Assert.Equal("Off", InspectorSummary.SplitSummary(s.Document));
        Assert.Equal("Off", InspectorSummary.ArchiveSummary(s.Output));
        Assert.Equal("", InspectorSummary.MoreSummary(s.Output, textShown: true));
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
        Assert.Equal("Feeder · both sides · 200 dpi · Gray", InspectorSummary.ScannerSummary(s));
        Assert.True(InspectorSummary.ScannerChanged(s));
        Assert.Equal("Word", InspectorSummary.OutputSummary(s, OutputFormat.Word));
        Assert.True(InspectorSummary.OutputChanged(s, OutputFormat.Word));

        s.Adjustments.AutoEnhance = true;
        Assert.Equal("Auto", InspectorSummary.AdjustmentsSummary(s.Adjustments));
        s.Adjustments.Brightness = 0.2;
        Assert.Equal("Edited", InspectorSummary.AdjustmentsSummary(s.Adjustments));

        s.Document.RemoveBlankPages = true;
        s.Document.AutoRotate = true;
        Assert.Equal("Skip blank · Upright", InspectorSummary.PagesSummary(s.Document));
        s.Document.SplitFacingPages = true;
        Assert.Equal("Skip blank · Upright +1", InspectorSummary.PagesSummary(s.Document));
        Assert.Equal(3, InspectorSummary.PagesOn(s.Document));

        s.Document.SplitMode = SplitMode.SheetCount;
        s.Document.SplitSheetCount = 3;
        Assert.Equal("Every 3 sheets", InspectorSummary.SplitSummary(s.Document));
        s.Document.SplitMode = SplitMode.Barcode;
        Assert.Equal("QR codes", InspectorSummary.SplitSummary(s.Document));

        s.Output.Archival = true;
        Assert.Equal("PDF/A", InspectorSummary.ArchiveSummary(s.Output));
        s.Output.Protect = true;
        Assert.Equal("Password on", InspectorSummary.ArchiveSummary(s.Output));

        s.Output.AfterSave = AfterSaveAction.Open;
        s.Output.AlsoSaveText = true;
        Assert.Equal("Open after saving · .txt", InspectorSummary.MoreSummary(s.Output, textShown: true));
        Assert.Equal("Open after saving", InspectorSummary.MoreSummary(s.Output, textShown: false));
        s.Output.AfterSave = AfterSaveAction.Share;
        Assert.Equal("Share after saving · .txt", InspectorSummary.MoreSummary(s.Output, textShown: true));
    }

    // MARK: - Saved bar, troubleshooter headline, sizes

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

    [Fact]
    public void StatusLine_SavedWithASettingChangedForTheScanner_KeepsTheWarning()
    {
        // Capabilities read after a scan saved at once add their note to "Saved …".
        var notes = SettingsAdapter.Adapt(new ScanSettings { Resolution = 1200 },
                                          new ScannerCapabilities { SupportedResolutions = [300, 600] }).Notes;
        string message = $"Saved Scan 2026-10-20 1.pdf (412 KB) {string.Join(" ", notes.Select(n => n.Message))}";
        Assert.Equal(["600 dpi used"], StatusLine.Warnings(message));
        Assert.Equal("Saved · 600 dpi used", StatusLine.WithWarnings("Saved", message));
        Assert.Equal("Saved · 600 dpi used", StatusLine.Short(message));
        // Without a note, just the head.
        Assert.Empty(StatusLine.Warnings("Saved Scan 2026-10-20 1.pdf (412 KB)"));
        Assert.Equal("Saved", StatusLine.WithWarnings("Saved", "Saved Scan 2026-10-20 1.pdf (412 KB)"));
        // Too many to fit with the head: the warnings win, as on any other line.
        var all = SettingsAdapter.Adapt(
            new ScanSettings { Source = ScanSource.Flatbed, Duplex = DuplexMode.Both, PaperSize = PaperSize.Legal, Resolution = 600 },
            new ScannerCapabilities { Sources = [ScanSource.DocumentFeeder], FeederSizeInches = new(8.5, 11), SupportedResolutions = [300] }).Notes;
        string many = $"Saved Scan 2026-10-20 1.pdf (412 KB) {string.Join(" ", all.Select(n => n.Message))}";
        string shown = StatusLine.WithWarnings("Saved", many);
        Assert.Equal(StatusLine.Short(many), shown);
        Assert.InRange(StatusLine.Words(shown), 1, StatusLine.MaxWords);
    }

    [Fact]
    public void TroubleshooterHeadline_IsOneLine()
    {
        Assert.Equal("No scanner found yet · 1 warning found", TroubleshooterWindow.HeadlineLine("No scanner found yet", "1 warning found."));
        Assert.Equal("2 scanners found", TroubleshooterWindow.HeadlineLine("2 scanners found", ""));
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
