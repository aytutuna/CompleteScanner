using System.Text;
using CompleteScanner.Core;
using Xunit;

namespace CompleteScanner.Core.Tests;

// The ID card task: paper, steps, layout, composer and detector. Mirrored by
// Tests/CompleteScannerTests/IdCardTests.swift: the same cases, on the same synthetic beds.

public class IdCardTests
{
    private static readonly SizeD Card = new(IdCardDetector.CardLongSideInches, IdCardDetector.CardShortSideInches);
    private static readonly SizeD Letter = PaperSizes.Inches(PaperSize.Letter)!.Value;
    private static readonly SizeD A4 = PaperSizes.Inches(PaperSize.A4)!.Value;

    /// <summary>One flat-colored rectangle on a synthetic bed, in inches, turned clockwise by <paramref name="AngleDegrees"/>.</summary>
    private sealed record BedItem(PointD Center, SizeD Size, double AngleDegrees, byte R, byte G, byte B);

    /// <summary>A flatbed scan: light gray glass (245) with flat rectangles on it. Pixels whose centre lies inside a rectangle take its color.</summary>
    private static RgbaImage Bed(int dpi, double widthInches, double heightInches, params BedItem[] items)
    {
        int width = (int)Math.Round(widthInches * dpi), height = (int)Math.Round(heightInches * dpi);
        var image = RgbaImage.Filled(width, height, 245, 245, 245);
        foreach (var item in items)
        {
            double a = item.AngleDegrees * Math.PI / 180, cos = Math.Cos(a), sin = Math.Sin(a);
            double cx = item.Center.X * dpi, cy = item.Center.Y * dpi;
            double hw = item.Size.Width * dpi / 2, hh = item.Size.Height * dpi / 2;
            double reach = Math.Sqrt(hw * hw + hh * hh) + 2;
            int minX = Math.Max(0, (int)(cx - reach)), maxX = Math.Min(width - 1, (int)(cx + reach));
            int minY = Math.Max(0, (int)(cy - reach)), maxY = Math.Min(height - 1, (int)(cy + reach));
            for (int y = minY; y <= maxY; y++)
            {
                for (int x = minX; x <= maxX; x++)
                {
                    double dx = x + 0.5 - cx, dy = y + 0.5 - cy;
                    double lx = dx * cos + dy * sin, ly = -dx * sin + dy * cos;
                    if (Math.Abs(lx) > hw || Math.Abs(ly) > hh) continue;
                    int i = (y * width + x) * 4;
                    image.Pixels[i] = item.R;
                    image.Pixels[i + 1] = item.G;
                    image.Pixels[i + 2] = item.B;
                }
            }
        }
        return image;
    }

    private static (byte R, byte G, byte B) Pixel(RgbaImage image, int x, int y)
    {
        int i = (y * image.Width + x) * 4;
        return (image.Pixels[i], image.Pixels[i + 1], image.Pixels[i + 2]);
    }

    private static void AssertRect(RectD expected, RectD? actual)
    {
        Assert.NotNull(actual);
        var r = actual!.Value;
        Assert.Equal(expected.X, r.X, 0.001);
        Assert.Equal(expected.Y, r.Y, 0.001);
        Assert.Equal(expected.Width, r.Width, 0.001);
        Assert.Equal(expected.Height, r.Height, 0.001);
    }

    // MARK: - Paper

    [Fact]
    public void Paper_AutomaticIsTheFirstChoice_StoredNames()
    {
        Assert.Equal([IdCardPaper.Auto, IdCardPaper.A4, IdCardPaper.Letter], IdCardPapers.All);
        Assert.Equal(["auto", "a4", "letter"], IdCardPapers.All.Select(p => p.RawValue()));
        Assert.Equal(["Automatic", "A4", "Letter"], IdCardPapers.All.Select(p => p.Label()));
        Assert.Equal(IdCardPaper.Auto, new TaskOptions().IdCardPaper);
        Assert.False(new TaskOptions().IdCardSaveSidesAsImages);
    }

    [Fact]
    public void Paper_AutomaticFollowsTheRegion()
    {
        Assert.Equal(PaperSize.Letter, IdCardPapers.Resolve(IdCardPaper.Auto, "US"));
        Assert.Equal(PaperSize.Letter, IdCardPapers.Resolve(IdCardPaper.Auto, "ca"));
        Assert.Equal(PaperSize.A4, IdCardPapers.Resolve(IdCardPaper.Auto, "TR"));
        Assert.Equal(PaperSize.A4, IdCardPapers.Resolve(IdCardPaper.Auto, "DE"));
        Assert.Equal(PaperSize.A4, IdCardPapers.Resolve(IdCardPaper.Auto, null));
        Assert.Equal(PaperSize.A4, IdCardPapers.Resolve(IdCardPaper.A4, "US"));
        Assert.Equal(PaperSize.Letter, IdCardPapers.Resolve(IdCardPaper.Letter, "TR"));
        Assert.Equal("Automatic (Letter)", IdCardPapers.ChoiceLabel(IdCardPaper.Auto, "US"));
        Assert.Equal("Automatic (A4)", IdCardPapers.ChoiceLabel(IdCardPaper.Auto, "TR"));
        Assert.Equal("A4", IdCardPapers.ChoiceLabel(IdCardPaper.A4, "US"));
    }

    [Fact]
    public void Paper_AutomaticIsTheDefaultPrintersPaper_WhenItIsA4OrLetter()
    {
        Assert.Equal(PaperSize.Letter, IdCardPapers.Resolve(IdCardPaper.Auto, "TR", PaperSize.Letter));
        Assert.Equal(PaperSize.A4, IdCardPapers.Resolve(IdCardPaper.Auto, "US", PaperSize.A4));
        // Other paper in the printer, or none known: the region's.
        Assert.Equal(PaperSize.A4, IdCardPapers.Resolve(IdCardPaper.Auto, "TR", PaperSize.Legal));
        Assert.Equal(PaperSize.Letter, IdCardPapers.Resolve(IdCardPaper.Auto, "US", PaperSize.A5));
        Assert.Equal(PaperSize.Letter, IdCardPapers.Resolve(IdCardPaper.Auto, "US", null));
        // A choice made by hand stands.
        Assert.Equal(PaperSize.A4, IdCardPapers.Resolve(IdCardPaper.A4, "US", PaperSize.Letter));
        Assert.Equal(PaperSize.Letter, IdCardPapers.Resolve(IdCardPaper.Letter, "TR", PaperSize.A4));
        Assert.Equal("Automatic (Letter)", IdCardPapers.ChoiceLabel(IdCardPaper.Auto, "TR", PaperSize.Letter));
        Assert.Equal("Automatic (A4)", IdCardPapers.ChoiceLabel(IdCardPaper.Auto, "TR", PaperSize.Legal));
        Assert.Equal("Letter", IdCardPapers.ChoiceLabel(IdCardPaper.Letter, "TR", PaperSize.A4));
    }

    // MARK: - Steps

    [Fact]
    public void Steps_FrontThenBackThenReview()
    {
        var steps = IdCardSteps.Steps;
        Assert.Equal(["front", "back", "review"], steps.Select(s => s.Id));
        Assert.Equal(["Scan front", "Scan back", "Review"], steps.Select(s => s.PrimaryActionLabel));
        Assert.Equal([true, false, false], steps.Select(s => s.RequiresCapture));
        Assert.Equal([false, true, false], steps.Select(s => s.Skippable));
        Assert.All(steps, s => Assert.False(s.Repeats));
        Assert.All(steps, s => Assert.False(string.IsNullOrWhiteSpace(s.Prompt)));
        Assert.Equal(PageSide.Front, IdCardSteps.SideOf("front"));
        Assert.Equal(PageSide.Back, IdCardSteps.SideOf("back"));
        Assert.Null(IdCardSteps.SideOf("review"));
        Assert.Null(IdCardSteps.SideOf(null));
        Assert.Equal("front", IdCardSteps.StepId(PageSide.Front));
        Assert.Equal("back", IdCardSteps.StepId(PageSide.Back));
    }

    [Fact]
    public void OffersSkip_OnlyTheBackOfTheCard_NeverTheBacksOfAStackTurnedOver()
    {
        Assert.Equal([false, true, false], IdCardSteps.Steps.Select(IdCardSteps.OffersSkip));
        Assert.False(IdCardSteps.OffersSkip(null));
        // The backs of a stack turned over by hand are skippable in the steps, but are left out with
        // Keep fronts only: no Skip button for them.
        Assert.Contains(DocumentSides.ManualSteps, s => s.Skippable);
        Assert.All(DocumentSides.ManualSteps, s => Assert.False(IdCardSteps.OffersSkip(s)));
        // Nor for the steps of any other task.
        foreach (var definition in TaskCatalog.All.Where(d => d.Task != ScanTask.IdCard))
        {
            Assert.All(definition.Steps, s => Assert.False(IdCardSteps.OffersSkip(s)));
        }
    }

    [Fact]
    public void Flow_SkipTheBack_RetakeTheFront_FinishOnlyWithAFront()
    {
        var flow = new TaskFlow(IdCardSteps.Steps);
        Assert.False(flow.CanFinish);
        Assert.False(flow.Advance());
        Assert.False(flow.Skip());
        var front = Guid.NewGuid();
        flow.Record("front", front);
        Assert.True(flow.CanFinish);
        Assert.True(flow.Advance());
        Assert.Equal("back", flow.Current?.Id);
        // A card with nothing on its back: skipped, on to the review.
        Assert.True(flow.Skip());
        Assert.True(flow.IsSkipped("back"));
        Assert.Equal("review", flow.Current?.Id);
        Assert.True(flow.CanFinish);
        // The front again: its capture goes, the back stays skipped.
        Assert.Equal([front], flow.Retake("front"));
        Assert.Equal("front", flow.Current?.Id);
        Assert.False(flow.CanFinish);
        Assert.True(flow.IsSkipped("back"));
        flow.Record("front", Guid.NewGuid());
        Assert.True(flow.CanFinish);
        // A second front replaces the first.
        var third = Guid.NewGuid();
        Assert.Single(flow.Record("front", third));
        Assert.Equal([third], flow.Captures("front"));
        // The review neither needs nor skips anything; done once advanced past.
        Assert.True(flow.Advance());
        Assert.True(flow.Advance());
        Assert.Equal("review", flow.Current?.Id);
        Assert.False(flow.Skip());
        Assert.True(flow.Advance());
        Assert.True(flow.IsComplete);
    }

    // MARK: - Layout

    [Fact]
    public void Layout_Letter_BothSidesAtRealSize()
    {
        var layout = IdCardLayout.Place(Card, Card, Letter);
        Assert.False(layout.ScaledToFit);
        Assert.Equal(1, layout.Scale);
        AssertRect(new RectD(2.565, 1.0, 3.370, 2.125), layout.Front);
        AssertRect(new RectD(2.565, 3.625, 3.370, 2.125), layout.Back);
    }

    [Fact]
    public void Layout_A4_BothSidesAtRealSize()
    {
        var layout = IdCardLayout.Place(Card, Card, A4);
        Assert.False(layout.ScaledToFit);
        AssertRect(new RectD((8.2677 - 3.370) / 2, 1.0, 3.370, 2.125), layout.Front);
        AssertRect(new RectD((8.2677 - 3.370) / 2, 3.625, 3.370, 2.125), layout.Back);
    }

    [Fact]
    public void Layout_FrontOnly()
    {
        var layout = IdCardLayout.Place(Card, null, Letter);
        Assert.Null(layout.Back);
        AssertRect(new RectD(2.565, 1.0, 3.370, 2.125), layout.Front);
        // A card lying the other way round (a portrait licence) keeps its own shape.
        var portrait = IdCardLayout.Place(new SizeD(2.125, 3.370), null, Letter);
        AssertRect(new RectD((8.5 - 2.125) / 2, 1.0, 2.125, 3.370), portrait.Front);
    }

    [Fact]
    public void Layout_TooLarge_IsScaledToFit()
    {
        var large = new SizeD(7, 5);
        // Front only: 1 + 5 in fits in 11 − 0.25 in.
        Assert.False(IdCardLayout.Place(large, null, Letter).ScaledToFit);
        // Both: 1 + 5 + 0.5 + 5 = 11.5 in does not; 9.25 / 10.
        var both = IdCardLayout.Place(large, large, Letter);
        Assert.True(both.ScaledToFit);
        Assert.Equal(0.925, both.Scale, 6);
        AssertRect(new RectD((8.5 - 6.475) / 2, 1.0, 6.475, 4.625), both.Front);
        AssertRect(new RectD((8.5 - 6.475) / 2, 6.125, 6.475, 4.625), both.Back);
        Assert.True(both.Back!.Value.MaxY <= 11 - IdCardLayout.EdgeMarginInches + 1e-9);
        // Too wide: 9 in on 8.5 in paper.
        var wide = IdCardLayout.Place(new SizeD(9, 2), null, Letter);
        Assert.True(wide.ScaledToFit);
        Assert.Equal(8.0 / 9, wide.Scale, 6);
        Assert.Equal(0.25, wide.Front.X, 6);
        Assert.Equal(8.0, wide.Front.Width, 6);
    }

    [Fact]
    public void Layout_Caption()
    {
        Assert.Equal("Front and back on one A4 page, at real size.", IdCardLayout.Caption(PaperSize.A4, hasBack: true, scaledToFit: false));
        Assert.Equal("Front only on one Letter page, made smaller to fit.", IdCardLayout.Caption(PaperSize.Letter, hasBack: false, scaledToFit: true));
    }

    // MARK: - Composer

    private static IdCardSide SolidSide(SizeD inches, int dpi, byte r, byte g, byte b) =>
        new(RgbaImage.Filled((int)Math.Round(inches.Width * dpi, MidpointRounding.AwayFromZero),
                             (int)Math.Round(inches.Height * dpi, MidpointRounding.AwayFromZero), r, g, b), dpi);

    [Fact]
    public void Composer_LetterAt300Dpi()
    {
        var front = SolidSide(Card, 300, 200, 40, 40);
        var back = SolidSide(Card, 300, 40, 90, 200);
        Assert.Equal((1011, 638), (front.Image.Width, front.Image.Height));
        var page = IdCardComposer.Compose(front, back, 300, Letter);
        Assert.Equal((2550, 3300), (page.Width, page.Height));
        Assert.Equal((2550, 3300), IdCardComposer.CanvasSize(Letter, 300));
        // The centre of each side is its color.
        Assert.Equal(((byte)200, (byte)40, (byte)40), Pixel(page, 1275, 300 + 319));
        Assert.Equal(((byte)40, (byte)90, (byte)200), Pixel(page, 1275, 1088 + 319));
        // The margins, and the gap between the sides, are white.
        foreach (var (x, y) in new[] { (0, 0), (2549, 3299), (1275, 150), (100, 619), (2450, 619), (1275, 1000), (1275, 3000) })
        {
            Assert.Equal(((byte)255, (byte)255, (byte)255), Pixel(page, x, y));
        }
    }

    [Fact]
    public void Composer_A4At300Dpi_FrontOnly()
    {
        var page = IdCardComposer.Compose(SolidSide(Card, 300, 200, 40, 40), null, 300, A4);
        Assert.Equal((2480, 3508), (page.Width, page.Height));
        Assert.Equal(((byte)200, (byte)40, (byte)40), Pixel(page, 1240, 619));
        // No back: white where it would be.
        Assert.Equal(((byte)255, (byte)255, (byte)255), Pixel(page, 1240, 1407));
    }

    [Fact]
    public void Composer_ResamplesASideScannedAtAnotherResolution()
    {
        // Scanned at 150 dpi, composed at 300: the side covers its real size.
        var front = SolidSide(Card, 150, 10, 120, 60);
        Assert.Equal((506, 319), (front.Image.Width, front.Image.Height));
        var page = IdCardComposer.Compose(front, null, 300, Letter);
        Assert.Equal(((byte)10, (byte)120, (byte)60), Pixel(page, 1275, 619));
        // Its edges are where a 300 dpi side's would be (within a pixel).
        Assert.Equal(((byte)10, (byte)120, (byte)60), Pixel(page, 771, 302));
        Assert.Equal(((byte)10, (byte)120, (byte)60), Pixel(page, 1778, 934));
        Assert.Equal(((byte)255, (byte)255, (byte)255), Pixel(page, 767, 619));
        Assert.Equal(((byte)255, (byte)255, (byte)255), Pixel(page, 1783, 619));
    }

    [Fact]
    public void Composer_PageIsTheWholePaperInThePdf()
    {
        var front = SolidSide(Card, 100, 200, 40, 40);
        var back = SolidSide(Card, 100, 40, 90, 200);
        var composed = IdCardComposer.Compose(front, back, 100, Letter);
        Assert.Equal((850, 1100), (composed.Width, composed.Height));
        var prepared = PdfBuilder.PreparePage(new ScannedPage(composed, 100, ColorMode.Color), null);
        // The page size comes from the page's pixels and resolution, whatever the JPEG holds.
        var input = new PdfPageInput([0xFF, 0xD8, 0xFF, 0xD9], prepared.PixelWidth, prepared.PixelHeight, 100, null);
        string text = Encoding.Latin1.GetString(PdfBuilder.Make([input]));
        int start = text.IndexOf("/MediaBox [", StringComparison.Ordinal);
        var box = text[(start + "/MediaBox [".Length)..text.IndexOf(']', start)].Split(' ').Select(v => double.Parse(v, System.Globalization.CultureInfo.InvariantCulture)).ToArray();
        Assert.Equal(612, box[2], 0.5);
        Assert.Equal(792, box[3], 0.5);
        // A4 at 300 dpi: 595.3 × 841.9 pt.
        var a4 = IdCardComposer.CanvasSize(A4, 300);
        Assert.Equal(595.3, a4.Width / 300.0 * 72, 0.5);
        Assert.Equal(841.9, a4.Height / 300.0 * 72, 0.5);
    }

    [Fact]
    public void Composer_SideFileNames()
    {
        Assert.Equal("ID card 2026-10-19 front", IdCardComposer.SideFileBase("ID card 2026-10-19", PageSide.Front));
        Assert.Equal("ID card 2026-10-19 back", IdCardComposer.SideFileBase("ID card 2026-10-19", PageSide.Back));
    }

    // MARK: - Detector

    private static DetectedPhotoRegion Region(double x, double y, double widthInches, double heightInches, int dpi = 300,
                                              double angle = 0) =>
        new(new PointD(x * dpi, y * dpi), new SizeD(widthInches * dpi, heightInches * dpi), angle);

    [Fact]
    public void Score_ZeroForACard_GrowsWithShapeAndSize()
    {
        Assert.Equal(0, IdCardDetector.Score(Region(2, 2, 3.370, 2.125), 300), 9);
        // Either way round.
        Assert.Equal(0, IdCardDetector.Score(Region(2, 2, 2.125, 3.370), 300), 9);
        double square = IdCardDetector.Score(Region(2, 2, 2.6, 2.6), 300);
        double photo = IdCardDetector.Score(Region(2, 2, 6, 4), 300);
        Assert.Equal(Math.Abs(1 - IdCardDetector.CardAspect) / IdCardDetector.CardAspect + (3.370 - 2.6) / 3.370, square, 9);
        Assert.True(square > 0.5 && photo > 0.5);
        Assert.True(IdCardDetector.Score(Region(2, 2, 3.4, 2.1), 300) < 0.05);
        Assert.Equal(double.MaxValue, IdCardDetector.Score(Region(2, 2, 3, 0), 300));
    }

    [Fact]
    public void PickCard_TakesTheRegionClosestToACard()
    {
        var square = Region(5, 5, 2.6, 2.6);
        var card = Region(2, 2, 3.36, 2.13, angle: 7);
        var passport = Region(5, 2, 4.92, 3.46);
        var photo = Region(4, 8, 6, 4);
        var pick = IdCardDetector.PickCard([square, photo, card, passport], 300, new SizeD(2550, 3510));
        Assert.Same(card, pick.Region);
        Assert.Equal(IdCardPickKind.Card, pick.Kind);
        Assert.False(pick.NeedsManualCrop);
        Assert.Null(pick.Note);
        // A passport page qualifies on its own.
        Assert.Same(passport, IdCardDetector.PickCard([square, passport], 300, new SizeD(2550, 3510)).Region);
        // Equals: the first.
        var twin = Region(6, 6, 3.36, 2.13, angle: 7);
        Assert.Same(card, IdCardDetector.PickCard([card, twin], 300, new SizeD(2550, 3510)).Region);
    }

    [Fact]
    public void PickCard_NothingCardSized_TakesTheLargest()
    {
        var small = Region(2, 2, 2.0, 1.6);
        var huge = Region(4, 5, 7, 9);
        var pick = IdCardDetector.PickCard([small, huge], 300, new SizeD(2550, 3510));
        Assert.Same(huge, pick.Region);
        Assert.Equal(IdCardPickKind.LargestRegion, pick.Kind);
        Assert.False(pick.NeedsManualCrop);
        Assert.Equal("This does not look like the size of an ID card. Check the crop.", pick.Note);
    }

    [Fact]
    public void PickCard_NothingFound_TakesTheWholeScan()
    {
        var pick = IdCardDetector.PickCard([], 300, new SizeD(2550, 3510));
        Assert.Equal(IdCardPickKind.WholeScan, pick.Kind);
        Assert.True(pick.NeedsManualCrop);
        Assert.Equal(new PointD(1275, 1755), pick.Region.Center);
        Assert.Equal(new SizeD(2550, 3510), pick.Region.Size);
        Assert.Equal(0, pick.Region.AngleDegrees);
        Assert.StartsWith("No card was found", pick.Note);
    }

    [Fact]
    public void PickCard_TheBackFallsBackOnTheFrontsPlace()
    {
        var front = Region(2, 2, 3.37, 2.125, angle: 4);
        var flipped = IdCardDetector.FlippedInPlace(front);
        Assert.Equal(front.Center, flipped.Center);
        Assert.Equal(front.Size, flipped.Size);
        Assert.Equal(-4, flipped.AngleDegrees);
        Assert.Equal(0, IdCardDetector.FlippedInPlace(Region(2, 2, 3, 2)).AngleDegrees);
        var pick = IdCardDetector.PickCard([Region(6, 8, 1.6, 1.6)], 300, new SizeD(2550, 3510), flipped);
        Assert.Same(flipped, pick.Region);
        Assert.Equal(IdCardPickKind.FrontPlace, pick.Kind);
        Assert.StartsWith("The card did not stand out", pick.Note);
        // A card on the back's scan wins over the front's place.
        var card = Region(3, 3, 3.37, 2.125);
        Assert.Same(card, IdCardDetector.PickCard([card], 300, new SizeD(2550, 3510), flipped).Region);
    }

    [Fact]
    public void FrontPlaceOnBack_SameScan_IsTheFrontFlipped()
    {
        var front = Region(2, 2, 3.37, 2.125, angle: 4);
        var area = new IdCardScanArea(300, new SizeD(2550, 3510), null);
        var place = IdCardDetector.FrontPlaceOnBack(front, area, area);
        Assert.NotNull(place);
        Assert.Equal(front.Center, place.Center);
        Assert.Equal(front.Size, place.Size);
        Assert.Equal(-4, place.AngleDegrees);
        // A pixel of rounding in the scan's size does not matter.
        Assert.NotNull(IdCardDetector.FrontPlaceOnBack(front, area, area with { PixelSize = new SizeD(2551, 3509) }));
    }

    [Fact]
    public void FrontPlaceOnBack_AnotherResolution_IsScaled()
    {
        // The front at 300 dpi, the back at 600 dpi: the place is where the card is on the 600 dpi scan.
        var front = Region(2, 2, 3.37, 2.125, angle: 4);
        var place = IdCardDetector.FrontPlaceOnBack(front, new IdCardScanArea(300, new SizeD(2550, 3510), null),
                                                    new IdCardScanArea(600, new SizeD(5100, 7020), null));
        Assert.NotNull(place);
        Assert.Equal(1200, place.Center.X, 6);
        Assert.Equal(1200, place.Center.Y, 6);
        Assert.Equal(3.37 * 600, place.Size.Width, 6);
        Assert.Equal(2.125 * 600, place.Size.Height, 6);
        Assert.Equal(-4, place.AngleDegrees);
        // 300 → 150 dpi halves it.
        var half = IdCardDetector.FrontPlaceOnBack(front, new IdCardScanArea(300, new SizeD(2550, 3510), null),
                                                   new IdCardScanArea(150, new SizeD(1275, 1755), null));
        Assert.Equal(300, half!.Center.X, 6);
        Assert.Equal(3.37 * 150, half.Size.Width, 6);
    }

    [Fact]
    public void FrontPlaceOnBack_AnotherPartOfTheGlass_IsNone()
    {
        var front = Region(2, 2, 3.37, 2.125);
        var whole = new IdCardScanArea(300, new SizeD(2550, 3510), null);
        var selected = new IdCardScanArea(300, new SizeD(1275, 1755), new RectD(0, 0, 0.5, 0.5));
        // Another selection.
        Assert.Null(IdCardDetector.FrontPlaceOnBack(front, whole, selected));
        Assert.Null(IdCardDetector.FrontPlaceOnBack(front, selected, whole));
        Assert.Null(IdCardDetector.FrontPlaceOnBack(front, selected, selected with { Selection = new RectD(0.5, 0, 0.5, 0.5) }));
        // The same selection.
        Assert.NotNull(IdCardDetector.FrontPlaceOnBack(front, selected, selected));
        // A scan of another size for its resolution (the scanner cut it differently).
        Assert.Null(IdCardDetector.FrontPlaceOnBack(front, whole, new IdCardScanArea(600, new SizeD(5100, 6600), null)));
        Assert.Null(IdCardDetector.FrontPlaceOnBack(front, whole, whole with { PixelSize = new SizeD(2400, 3510) }));
        // No resolution known.
        Assert.Null(IdCardDetector.FrontPlaceOnBack(front, whole with { Dpi = 0 }, whole));
    }

    [Fact]
    public void Composer_PageResolution_IsTheScansAtMost600Dpi()
    {
        Assert.Equal(600, IdCardComposer.MaxPageDpi);
        Assert.Equal(300, IdCardComposer.PageDpi(300));
        Assert.Equal(600, IdCardComposer.PageDpi(600));
        Assert.Equal(600, IdCardComposer.PageDpi(1200));
        Assert.Equal(600, IdCardComposer.PageDpi(2400));
        Assert.Equal(75, IdCardComposer.PageDpi(75));
        Assert.Equal(1, IdCardComposer.PageDpi(0));
        // A side scanned at 2400 dpi goes on an A4 page at 600 dpi: at real size, and the page fits
        // in one image (at 2400 dpi it would be 19843 × 28063 pixels, too large for one).
        var side = SolidSide(new SizeD(1, 0.5), 2400, 200, 40, 40);
        int dpi = IdCardComposer.PageDpi(side.Dpi);
        var page = IdCardComposer.Compose(side, null, dpi, A4);
        Assert.Equal(IdCardComposer.CanvasSize(A4, 600), (page.Width, page.Height));
        Assert.Equal(((byte)200, (byte)40, (byte)40), Pixel(page, page.Width / 2, 600 + 150));
        Assert.Equal(((byte)255, (byte)255, (byte)255), Pixel(page, page.Width / 2 - 320, 600 + 150));
    }

    [Fact]
    public void Composer_PageColorMode_IsWhatTheSidesWereScannedIn()
    {
        foreach (var mode in Enum.GetValues<ColorMode>())
        {
            Assert.Equal(mode, IdCardComposer.PageColorMode(mode, null));
            Assert.Equal(mode, IdCardComposer.PageColorMode(mode, mode));
        }
        Assert.Equal(ColorMode.Color, IdCardComposer.PageColorMode(ColorMode.Color, ColorMode.BlackWhite));
        Assert.Equal(ColorMode.Color, IdCardComposer.PageColorMode(ColorMode.Grayscale, ColorMode.Color));
        Assert.Equal(ColorMode.Grayscale, IdCardComposer.PageColorMode(ColorMode.BlackWhite, ColorMode.Grayscale));
        Assert.Equal(ColorMode.Grayscale, IdCardComposer.PageColorMode(ColorMode.Grayscale, ColorMode.BlackWhite));
    }

    [Fact]
    public void DetectedPhoto_KeepsItsColorMode_WhenRecropped()
    {
        var image = RgbaImage.Filled(4, 4, 255, 255, 255);
        var region = new DetectedPhotoRegion(new PointD(2, 2), new SizeD(4, 4), 0);
        Assert.Equal(ColorMode.Color, new DetectedPhoto(region, image, 300).ColorMode);
        var photo = new DetectedPhoto(region, image, 300, sourcePageId: Guid.NewGuid(), colorMode: ColorMode.BlackWhite)
        {
            RotationQuarterTurns = 1,
        };
        var recropped = photo.Recropped(new DetectedPhotoRegion(new PointD(1, 1), new SizeD(2, 2), 0), RgbaImage.Filled(2, 2, 0, 0, 0));
        Assert.Equal(ColorMode.BlackWhite, recropped.ColorMode);
        Assert.Equal(photo.SourcePageId, recropped.SourcePageId);
        Assert.Equal(1, recropped.RotationQuarterTurns);
    }

    [Fact]
    public void Detect_FindsTheCardOnABed_AtItsRealSize()
    {
        // 300 dpi, 6.5 × 6.5 in of glass: a blue card turned 7°, a 1 in square and a 2.6 in square.
        var bed = Bed(300, 6.5, 6.5,
                      new BedItem(new PointD(2.3, 1.7), Card, 7, 40, 90, 160),
                      new BedItem(new PointD(1.2, 5.2), new SizeD(1, 1), 0, 60, 60, 60),
                      new BedItem(new PointD(4.6, 4.8), new SizeD(2.6, 2.6), -3, 170, 60, 40));
        var pick = IdCardDetector.Detect(bed, 300);
        Assert.Equal(IdCardPickKind.Card, pick.Kind);
        var region = pick.Region;
        double longSide = Math.Max(region.Size.Width, region.Size.Height) / 300;
        double shortSide = Math.Min(region.Size.Width, region.Size.Height) / 300;
        Assert.InRange(longSide, 3.370 - 0.04, 3.370 + 0.04);
        Assert.InRange(shortSide, 2.125 - 0.04, 2.125 + 0.04);
        Assert.InRange(region.AngleDegrees, 6.5, 7.5);
        Assert.InRange(region.Center.X / 300, 2.25, 2.35);
        Assert.InRange(region.Center.Y / 300, 1.65, 1.75);
        // Cut out straight: the card's own size, its color in the middle.
        var side = IdCardDetector.Extract(bed, pick);
        Assert.InRange(side.Width, 1011 - 12, 1011 + 12);
        Assert.InRange(side.Height, 638 - 12, 638 + 12);
        var middle = Pixel(side, side.Width / 2, side.Height / 2);
        Assert.InRange(middle.R, 38, 42);
        Assert.InRange(middle.G, 88, 92);
        Assert.InRange(middle.B, 158, 162);
    }

    [Fact]
    public void Detect_EmptyGlass_TakesTheWholeScan()
    {
        var bed = Bed(100, 6, 5);
        var pick = IdCardDetector.Detect(bed, 100);
        Assert.Equal(IdCardPickKind.WholeScan, pick.Kind);
        var whole = IdCardDetector.Extract(bed, pick);
        Assert.Equal((600, 500), (whole.Width, whole.Height));
    }
}
