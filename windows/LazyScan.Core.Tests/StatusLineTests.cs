using LazyScan.Core;
using Xunit;

namespace LazyScan.Core.Tests;

// Twin of Tests/LazyScanTests/StatusLineTests.swift: the status line's six words.
public class StatusLineTests
{
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
    [InlineData("9 pages · 3 documents.", "9 pages · 3 documents")]
    [InlineData("9 pages · 3 documents · 2 separator pages skipped.", "9 pages · 3 documents")]
    [InlineData("12 pages · 4 documents · 2 separator pages and 1 blank skipped.", "12 pages · 4 documents")]
    [InlineData("24 pages · 5 blank skipped.", "24 pages · 5 blank skipped")]
    public void Short_IsShortAndFactual(string message, string expected)
    {
        Assert.Equal(expected, StatusLine.Short(message));
    }

    [Fact]
    public void Short_ReadyForATask_NamesTheScannerInstead()
    {
        Assert.Equal("Ready — Demo Scanner", StatusLine.Short("Ready for “Document to PDF”.", "Demo Scanner"));
        Assert.Equal("Ready", StatusLine.Short("Ready for “Document to PDF”."));
        Assert.Equal("", StatusLine.Short("   "));
    }

    [Theory]
    [InlineData("Could not connect to the Epson Perfection V600 Photo scanner over the network.")]
    [InlineData("Scanned 3 front sides before the feeder stopped. Load the rest of the stack and scan, or turn it over.")]
    [InlineData("The ID card task ended during the scan. Nothing of the card was kept.")]
    [InlineData("A very long message without any punctuation that goes on and on about nothing in particular")]
    public void Short_NeverShowsMoreThanSixWords(string message)
    {
        string shown = StatusLine.Short(message);
        Assert.InRange(StatusLine.Words(shown), 1, StatusLine.MaxWords);
    }

    [Fact]
    public void Short_OfALongSentence_EndsWithAnEllipsis()
    {
        Assert.Equal("A very long message without any…",
                     StatusLine.Short("A very long message without any punctuation that goes on and on about nothing in particular"));
        Assert.Equal("Could not connect to the Epson…",
                     StatusLine.Short("Could not connect to the Epson Perfection V600 Photo scanner over the network."));
        Assert.Equal("Scanned 3 front sides before the…",
                     StatusLine.Short("Scanned 3 front sides before the feeder stopped. Load the rest of the stack and scan, or turn it over."));
    }

    /// <summary>The status after settings met a scanner, as the apps build it: the message, then each note.</summary>
    private static string WithNotes(string message, ScanSettings settings, ScannerCapabilities capabilities)
    {
        var notes = SettingsAdapter.Adapt(settings, capabilities).Notes;
        Assert.NotEmpty(notes);
        return $"{message} {string.Join(" ", notes.Select(n => n.Message))}";
    }

    [Fact]
    public void Short_KeepsASettingChangedForTheScanner_AsAShortWarning()
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
    public void Short_ATwoSidedScanThatCameBackOneSided_SaysSo()
    {
        Assert.Equal("3 pages added · one side only", StatusLine.Short(
            "Added 3 pages, one side of each sheet: the scanner did not scan both sides — 3 in queue. Scan more or Save PDF."));
        Assert.Equal("Page 4 added · one side only", StatusLine.Short(
            "Added 1 page, one side of each sheet: the scanner did not scan both sides — 4 in queue. Scan more or Save PDF."));
    }

    [Fact]
    public void Words_CountsTokensWithALetterOrDigit()
    {
        Assert.Equal(3, StatusLine.Words("Ready — Demo Scanner"));
        Assert.Equal(5, StatusLine.Words("6 pages added · 1 blank"));
        Assert.Equal(0, StatusLine.Words(" — · "));
    }

    [Fact]
    public void Saved_WithASettingChangedForTheScanner_KeepsTheWarning()
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
    public void Shown_IsEmptyUnderAReview_AndSavedWhileTheSavedFilesShow()
    {
        Assert.Equal("", StatusLine.Shown("Found 3 photos on the bed.", "Demo Scanner", reviewShown: true, savedShown: false));
        Assert.Equal("", StatusLine.Shown("Back scanned. Check the sides, then save.", "Demo Scanner", reviewShown: true, savedShown: false));
        Assert.Equal("Saved", StatusLine.Shown("Saved 3-page PDF: Scan 2026-10-20 1.pdf (497.7 KB)", null, reviewShown: false, savedShown: true));
        Assert.Equal("Saved", StatusLine.Shown("Saved 3 photos to C:\\x\\files", null, reviewShown: false, savedShown: true));
        // Not about a save: the short line, whatever the bar.
        Assert.Equal("Page 3 added", StatusLine.Shown("Added 1 page — 3 in queue. Scan more or Save PDF.", null, reviewShown: false, savedShown: true));
        Assert.Equal("Ready — Demo Scanner", StatusLine.Shown("Ready for “Photos”.", "Demo Scanner", reviewShown: false, savedShown: false));
    }
}
