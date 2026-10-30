using LazyScan.Core;
using Xunit;

namespace LazyScan.Core.Tests;

// Mirrored by Tests/CompleteScannerTests/PrintLayoutTests.swift: the same cases.

public class PrintLayoutTests
{
    private static readonly SizeD Letter = PaperSizes.Inches(PaperSize.Letter)!.Value;
    private static readonly SizeD A4 = PaperSizes.Inches(PaperSize.A4)!.Value;

    private static RectD Whole(SizeD paper) => new(0, 0, paper.Width, paper.Height);

    private static void AssertRect(double x, double y, double width, double height, RectD actual, double tolerance = 0.0001)
    {
        Assert.Equal(x, actual.X, tolerance);
        Assert.Equal(y, actual.Y, tolerance);
        Assert.Equal(width, actual.Width, tolerance);
        Assert.Equal(height, actual.Height, tolerance);
    }

    // MARK: - Actual size

    [Fact]
    public void ActualSize_A4PageAt300Dpi_PrintsAtItsRealSize()
    {
        var placement = PrintLayout.Place(2480, 3508, 300, A4, Whole(A4), PrintMode.ActualSize, PrintAlign.PaperOrigin);
        AssertRect(0, 0, 8.2667, 11.6933, placement.Rect);
        Assert.Equal(1, placement.Scale);
        Assert.Equal(0, placement.QuarterTurns);
        // 2480 × 3508 is A4 rounded to whole pixels: 0.0004 in too tall is nothing to warn about.
        Assert.True(placement.ClippedInches < 0.001);
        Assert.False(placement.IsClipped);
        Assert.Null(PrintLayout.ClipWarning(placement, A4));
    }

    [Fact]
    public void ActualSize_FullGlassOnA4_IsCutOffBeyondThePaper()
    {
        // A whole 8.5 × 11.7 in glass at 300 dpi.
        var placement = PrintLayout.Place(2550, 3510, 300, A4, Whole(A4), PrintMode.ActualSize, PrintAlign.PaperOrigin);
        AssertRect(0, 0, 8.5, 11.7, placement.Rect);
        Assert.Equal(0, placement.QuarterTurns);
        Assert.Equal(0.2323, placement.ClippedInches, 0.0001);
        Assert.True(placement.IsClipped);
        Assert.Equal("Larger than the paper: up to 6 mm is cut off. Turn on Fit to page to print all of it.",
                     PrintLayout.ClipWarning(placement, A4));
    }

    [Fact]
    public void ActualSize_AgainstTheCorner_PrinterMarginsCutTheEdges()
    {
        var printable = new RectD(0.25, 0.25, 8.0, 10.5);
        var placement = PrintLayout.Place(2550, 3300, 300, Letter, printable, PrintMode.ActualSize, PrintAlign.PaperOrigin);
        AssertRect(0, 0, 8.5, 11, placement.Rect);
        Assert.Equal(0.25, placement.ClippedInches, 1e-9);
        Assert.Equal("Edges may be cut by up to 7 mm (printer margins).", PrintLayout.ClipWarning(placement, Letter));
        // The same page on the printer's paper record.
        var onPrinter = PrintLayout.Place(2550, 3300, 300, PrinterPaper.Make(Letter, printable), PrintMode.ActualSize, PrintAlign.PaperOrigin);
        Assert.Equal(placement, onPrinter);
    }

    [Fact]
    public void ActualSize_ASelectionIsCentredOnThePaper()
    {
        var placement = PrintLayout.Place(900, 600, 300, Letter, Whole(Letter), PrintMode.ActualSize, PrintAlign.Center);
        AssertRect(2.75, 4.5, 3, 2, placement.Rect);
        Assert.Equal(0, placement.ClippedInches);
        Assert.Equal(PrintAlign.Center, PrintLayout.AlignFor(hasSelection: true));
        Assert.Equal(PrintAlign.PaperOrigin, PrintLayout.AlignFor(hasSelection: false));
    }

    [Fact]
    public void ActualSize_TurnsOnlyWhenThatCutsOffLess()
    {
        // 10 × 7 in across does not fit Letter upright but does turned.
        var turned = PrintLayout.Place(3000, 2100, 300, Letter, Whole(Letter), PrintMode.ActualSize, PrintAlign.PaperOrigin);
        Assert.Equal(1, turned.QuarterTurns);
        AssertRect(0, 0, 7, 10, turned.Rect);
        Assert.Equal(0, turned.ClippedInches);
        // 4 × 3 in fits either way: left as it is.
        var upright = PrintLayout.Place(1200, 900, 300, Letter, Whole(Letter), PrintMode.ActualSize, PrintAlign.PaperOrigin);
        Assert.Equal(0, upright.QuarterTurns);
        AssertRect(0, 0, 4, 3, upright.Rect);
        // At another resolution the inches count, not the pixels: 600 dpi halves the size.
        var fine = PrintLayout.Place(3000, 2100, 600, Letter, Whole(Letter), PrintMode.ActualSize, PrintAlign.PaperOrigin);
        Assert.Equal(0, fine.QuarterTurns);
        AssertRect(0, 0, 10 / 2.0, 7 / 2.0, fine.Rect);
    }

    // MARK: - Fit to page

    [Fact]
    public void Fit_TurnsWhenThatGivesALargerScale()
    {
        var printable = new RectD(0.25, 0.25, 8.0, 10.5);
        // A landscape Letter page: upright it would be 0.727 of its size, turned 0.941.
        var placement = PrintLayout.Place(3300, 2550, 300, Letter, printable, PrintMode.FitToPrintable, PrintAlign.PaperOrigin);
        Assert.Equal(1, placement.QuarterTurns);
        Assert.Equal(8.0 / 8.5, placement.Scale, 1e-9);
        AssertRect(0.25, 0.25 + (10.5 - 11 * 8.0 / 8.5) / 2, 8.0, 11 * 8.0 / 8.5, placement.Rect);
        Assert.Equal(0, placement.ClippedInches);
        Assert.Null(PrintLayout.ClipWarning(placement, Letter));
    }

    [Fact]
    public void Fit_NeverEnlarges_AndCentresInThePrintableArea()
    {
        var printable = new RectD(0.25, 0.5, 8.0, 10.0);
        var placement = PrintLayout.Place(600, 300, 300, Letter, printable, PrintMode.FitToPrintable, PrintAlign.PaperOrigin);
        Assert.Equal(1, placement.Scale);
        Assert.Equal(0, placement.QuarterTurns);
        AssertRect(0.25 + 3, 0.5 + 4.5, 2, 1, placement.Rect);
    }

    [Fact]
    public void Fit_FullGlassOnA4_ShrinksToTheMargins()
    {
        var printable = new RectD(0.17, 0.17, A4.Width - 0.34, A4.Height - 0.34);
        var placement = PrintLayout.Place(2550, 3510, 300, A4, printable, PrintMode.FitToPrintable, PrintAlign.PaperOrigin);
        Assert.Equal(0, placement.QuarterTurns);
        double scale = Math.Min((A4.Width - 0.34) / 8.5, (A4.Height - 0.34) / 11.7);
        Assert.Equal(scale, placement.Scale, 1e-9);
        Assert.Equal(A4.Width - 0.34, placement.Rect.Width, 1e-9);
        Assert.Equal(0, placement.ClippedInches);
    }

    // MARK: - Units, paper, copies

    [Fact]
    public void ToUnits_DevicePixelsAndPoints()
    {
        var rect = new RectD(1, 2, 8.5, 11);
        AssertRect(96, 192, 816, 1056, PrintLayout.ToUnits(rect, 96));
        AssertRect(72, 144, 612, 792, PrintLayout.ToUnits(rect, 72));
        Assert.Equal(new SizeD(816, 1056), PrintLayout.ToUnits(Letter, 96));
        Assert.Equal(new SizeD(612, 792), PrintLayout.ToUnits(Letter, 72));
    }

    [Fact]
    public void PrinterPaper_ClampsThePrintableArea_AndNamesTheSize()
    {
        Assert.Equal(Whole(Letter), PrinterPaper.Make(Letter, null).Printable);
        Assert.Equal(Whole(Letter), PrinterPaper.Make(Letter, new RectD(-1, -1, 20, 20)).Printable);
        Assert.Equal(Whole(Letter), PrinterPaper.Make(Letter, new RectD(9, 12, 1, 1)).Printable);
        var a4 = PrinterPaper.Make(A4, new RectD(0.17, 0.2, A4.Width - 0.34, A4.Height - 0.5));
        Assert.Equal(PaperSize.A4, a4.Size);
        Assert.Equal(0.3, a4.LargestMargin, 1e-9);
        Assert.Equal("A4 (210 × 297 mm)", a4.Description);
        Assert.Equal("Letter (8.5 × 11 in)", PrinterPaper.Make(Letter, null).Description);
        var photo = PrinterPaper.Make(new SizeD(5, 7), null);
        Assert.Null(photo.Size);
        Assert.Equal("5 × 7 in", photo.Description);
        Assert.Equal(0, photo.LargestMargin);
    }

    [Fact]
    public void ClippedInches_WorstSide()
    {
        var printable = new RectD(0.25, 0.25, 8.0, 10.5);
        Assert.Equal(0, PrintLayout.ClippedInches(new RectD(1, 1, 2, 2), printable));
        Assert.Equal(0.25, PrintLayout.ClippedInches(new RectD(0, 1, 2, 2), printable), 1e-9);
        Assert.Equal(0.5, PrintLayout.ClippedInches(new RectD(7, 1, 1.75, 2), printable), 1e-9);
        Assert.Equal(1, PrintLayout.ClippedInches(new RectD(1, 9, 2, 2.75), printable), 1e-9);
        Assert.Equal(1, PrintLayout.Millimetres(0.01));
        Assert.Equal(7, PrintLayout.Millimetres(0.25));
        Assert.Equal(25, PrintLayout.Millimetres(25 / 25.4));
    }

    [Fact]
    public void Copies_ThePrinterMakesThemWhenItSaysItCan()
    {
        Assert.Equal(new PrintCopiesPlan(1, 1), PrintCopies.Plan(1, null));
        Assert.Equal(new PrintCopiesPlan(3, 1), PrintCopies.Plan(3, 99));
        Assert.Equal(new PrintCopiesPlan(3, 1), PrintCopies.Plan(3, 3));
        Assert.Equal(new PrintCopiesPlan(1, 3), PrintCopies.Plan(3, 2));
        Assert.Equal(new PrintCopiesPlan(1, 3), PrintCopies.Plan(3, null));
        Assert.Equal(new PrintCopiesPlan(99, 1), PrintCopies.Plan(150, 999));
        Assert.Equal(new PrintCopiesPlan(1, 1), PrintCopies.Plan(0, null));
        Assert.Equal(1, PrintCopies.Clamp(-5));
        Assert.Equal(99, PrintCopies.Clamp(99));
        Assert.Equal(99, PrintCopies.MaxCount);
    }

    [Fact]
    public void Copies_SeveralPages_ThePrinterMakesThemOnlyWhenItCollates()
    {
        // Pages in order in every copy (1, 2, 3, 1, 2, 3): a printer that does not collate would
        // give 1, 1, 2, 2, 3, 3, so the pages are repeated in the job instead.
        Assert.Equal(new PrintCopiesPlan(3, 1), PrintCopies.Plan(3, 99, pageCount: 3, canCollate: true));
        Assert.Equal(new PrintCopiesPlan(1, 3), PrintCopies.Plan(3, 99, pageCount: 3, canCollate: false));
        // One page needs no collating.
        Assert.Equal(new PrintCopiesPlan(3, 1), PrintCopies.Plan(3, 99, pageCount: 1, canCollate: false));
        Assert.Equal(new PrintCopiesPlan(1, 3), PrintCopies.Plan(3, 2, pageCount: 3, canCollate: true));
        Assert.Equal(new PrintCopiesPlan(1, 1), PrintCopies.Plan(1, 99, pageCount: 3, canCollate: false));
    }

    [Fact]
    public void Text()
    {
        Assert.Equal("Sent 1 page to Office Printer.", PrintText.Sent(1, 1, "Office Printer"));
        Assert.Equal("Sent 2 pages to Office Printer, 3 copies.", PrintText.Sent(2, 3, "Office Printer"));
        Assert.Equal("Actual size", PrintText.ModeLabel(false));
        Assert.Equal("Fit to page", PrintText.ModeLabel(true));
        Assert.Equal("Needs a printer", PrintText.NoPrinterReason);
        Assert.Equal("The printer's paper size, from the glass corner",
                     PrintText.CopyPaperHint(PaperSize.Auto, ScanSource.Flatbed));
        Assert.Equal(PaperSizes.Hint(PaperSize.Auto, ScanSource.DocumentFeeder), PrintText.CopyPaperHint(PaperSize.Auto, ScanSource.DocumentFeeder));
        Assert.Equal(PaperSizes.Hint(PaperSize.A4, ScanSource.Flatbed), PrintText.CopyPaperHint(PaperSize.A4, ScanSource.Flatbed));
    }

    // MARK: - Ruler test page

    private static int Gray(RgbaImage image, int x, int y) => image.Pixels[(y * image.Width + x) * 4];

    [Fact]
    public void RulerPage_InchGridAndCentimetreTicks()
    {
        var page = PrintCalibration.MakeRulerPage(Letter, 300);
        Assert.Equal((2550, 3300), (page.Width, page.Height));
        Assert.Equal(2, PrintCalibration.LineWidth(300));
        Assert.Equal(1, PrintCalibration.LineWidth(72));
        Assert.Equal(4, PrintCalibration.LineWidth(600));
        Assert.Equal(255, Gray(page, 0, 0));
        Assert.Equal(255, Gray(page, 150, 150));
        // Grid lines every inch, two pixels wide at 300 dpi, centred on the inch.
        Assert.Equal(128, Gray(page, 299, 1450));
        Assert.Equal(128, Gray(page, 300, 1450));
        Assert.Equal(255, Gray(page, 301, 1450));
        Assert.Equal(255, Gray(page, 298, 1450));
        Assert.Equal(128, Gray(page, 1500, 600));
        Assert.Equal(128, Gray(page, 2400, 3000));
        // Centimetre ticks from the first inch line: 0.15 in, 0.3 in every 5 cm.
        Assert.Equal(418, PrintCalibration.TickPosition(1, 300));
        Assert.Equal(891, PrintCalibration.TickPosition(5, 300));
        Assert.Equal(0, Gray(page, 418, 340));
        Assert.Equal(255, Gray(page, 418, 380));
        Assert.Equal(0, Gray(page, 891, 380));
        Assert.Equal(255, Gray(page, 891, 400));
        Assert.Equal(0, Gray(page, 340, 418));
        Assert.Equal(0, Gray(page, 380, 891));
        Assert.Equal(255, Gray(page, 380, 418));
        Assert.Equal(255, page.Pixels[(1450 * page.Width + 299) * 4 + 3]);
        // Ten centimetres from the first inch line is 3.937 in, 1181 pixels further on.
        Assert.Equal(300 + 1181, PrintCalibration.TickPosition(10, 300));
    }

    [Fact]
    public void RulerPage_SizeFollowsThePaperAndResolution()
    {
        var a4 = PrintCalibration.MakeRulerPage(A4, 200);
        Assert.Equal((1654, 2339), (a4.Width, a4.Height));
        var small = PrintCalibration.MakeRulerPage(new SizeD(2, 1.5), 72);
        Assert.Equal((144, 108), (small.Width, small.Height));
        Assert.Equal(128, Gray(small, 72, 10));
        Assert.Equal(0, Gray(small, 100, 80));
    }

    // MARK: - Real size or fit to page

    [Fact]
    public void CopyFitsToPage_RealSizePages_FollowsTheUsersChoice()
    {
        Assert.False(PrintLayout.CopyFitsToPage(chosenFit: false, allPagesRealSize: true));
        Assert.True(PrintLayout.CopyFitsToPage(chosenFit: true, allPagesRealSize: true));
    }

    [Fact]
    public void CopyFitsToPage_AGuessedSize_IsForcedToFit()
    {
        Assert.True(PrintLayout.CopyFitsToPage(chosenFit: false, allPagesRealSize: false));
        Assert.True(PrintLayout.CopyFitsToPage(chosenFit: true, allPagesRealSize: false));
    }

    [Fact]
    public void PrintsAtRealSize_ScannerAndImportedPages_AreRealSize()
    {
        var scan = new ScannedPage(RgbaImage.Filled(10, 10, 255, 255, 255), 300, ColorMode.Color);
        Assert.True(scan.PrintsAtRealSize);
    }

    [Fact]
    public void PrintsAtRealSize_CameraPageSnappedToAKnownSize_IsRealSize()
    {
        var page = CameraPage(new CaptureScaleResult(CaptureScaleBasis.Paper, "a4", 300, 2480, 3508, 8.2667, 11.6933));
        Assert.True(page.PrintsAtRealSize);
    }

    [Fact]
    public void PrintsAtRealSize_CameraPageWithAGuessedSize_IsNotRealSize()
    {
        var nominal = new CaptureScaleResult(CaptureScaleBasis.Nominal, null, 200, 2000, 1500, 10, 7.5);
        Assert.False(CameraPage(nominal).PrintsAtRealSize);
        // Not yet cut out (no scale): treated as not real size, so a copy is fitted to the page.
        Assert.False(CameraPage(null).PrintsAtRealSize);
    }

    private static ScannedPage CameraPage(CaptureScaleResult? scale)
    {
        var quad = new Quad(new PointD(0, 0), new PointD(100, 0), new PointD(100, 100), new PointD(0, 100));
        var facts = new CaptureFacts(quad, 100, 100) { Scale = scale };
        return new ScannedPage(RgbaImage.Filled(10, 10, 255, 255, 255), 300, ColorMode.Color).WithCapture(facts);
    }
}
