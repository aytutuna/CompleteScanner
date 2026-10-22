using CompleteScanner.Core;
using Xunit;

namespace CompleteScanner.Core.Tests;

// Twin of Tests/CompleteScannerTests/CaptureObjectsTests.swift: the same shots, pages and answers.

/// <summary>
/// Made-up camera shots for the objects of one photo, drawn the same way on both platforms: two prints
/// on a dark table, and an ID card photographed turned and tilted.
/// </summary>
internal static class ObjectShots
{
    /// <summary>The dark table the objects lie on.</summary>
    public static readonly (byte R, byte G, byte B) Table = (34, 30, 28);

    /// <summary>Two 6 × 4 in prints square on in a 900 × 600 photo: 300 × 200 and 360 × 240 pixels.</summary>
    public static readonly Quad PrintA = Rect(60, 80, 360, 280);
    public static readonly Quad PrintB = Rect(480, 300, 840, 540);

    public static Quad Rect(double x0, double y0, double x1, double y1) =>
        new(new PointD(x0, y0), new PointD(x1, y0), new PointD(x1, y1), new PointD(x0, y1));

    /// <summary>The two prints on the table: each a soft gradient (no picture of anything).</summary>
    public static RgbaImage TwoPrints()
    {
        const int w = 900, h = 600;
        var pixels = new byte[w * h * 4];
        for (int y = 0; y < h; y++)
        {
            for (int x = 0; x < w; x++)
            {
                (int r, int g, int b) = (Table.R, Table.G, Table.B);
                if (x >= 60 && x < 360 && y >= 80 && y < 280)
                    (r, g, b) = (90 + (x - 60) * 100 / 300, 120 + (y - 80) * 60 / 200, 170);
                else if (x >= 480 && x < 840 && y >= 300 && y < 540)
                    (r, g, b) = (200, 150 - (y - 300) * 80 / 240, 80 + (x - 480) * 90 / 360);
                int p = (y * w + x) * 4;
                pixels[p] = (byte)r;
                pixels[p + 1] = (byte)g;
                pixels[p + 2] = (byte)b;
                pixels[p + 3] = 255;
            }
        }
        return new RgbaImage(w, h, pixels);
    }

    /// <summary>
    /// Two prints with white borders on a plain dark table, as the photos UI test's fixture lays them out
    /// (scripts/make_ios_ui_fixture.py): a 1200 × 900 shot, a 450 × 300 print at (120, 150) and a 420 × 280
    /// print at (650, 420), each with an 18 px border around a soft gradient.
    /// </summary>
    public static readonly Quad BorderedA = Rect(120, 150, 570, 450);
    public static readonly Quad BorderedB = Rect(650, 420, 1070, 700);

    public static RgbaImage PrintsOnTable()
    {
        const int w = 1200, h = 900, border = 18;
        var pixels = new byte[w * h * 4];
        for (int y = 0; y < h; y++)
        {
            for (int x = 0; x < w; x++)
            {
                (int r, int g, int b) = (40, 36, 34);
                if (x >= 120 && x < 570 && y >= 150 && y < 450)
                {
                    bool inner = x >= 120 + border && x < 570 - border && y >= 150 + border && y < 450 - border;
                    (r, g, b) = inner ? (70 + (x - 120) * 120 / 450, 110 + (y - 150) * 90 / 300, 180) : (245, 244, 238);
                }
                else if (x >= 650 && x < 1070 && y >= 420 && y < 700)
                {
                    bool inner = x >= 650 + border && x < 1070 - border && y >= 420 + border && y < 700 - border;
                    (r, g, b) = inner ? (190, 140 - (y - 420) * 70 / 280, 60 + (x - 650) * 100 / 420) : (245, 244, 238);
                }
                int p = (y * w + x) * 4;
                pixels[p] = (byte)r;
                pixels[p + 1] = (byte)g;
                pixels[p + 2] = (byte)b;
                pixels[p + 3] = 255;
            }
        }
        return new RgbaImage(w, h, pixels);
    }

    /// <summary>The camera of the card shot: a 1200 × 900 photo, focal length 1000 px, centered.</summary>
    public const int CardPhotoWidth = 1200, CardPhotoHeight = 900;
    public const double CardFocal = 1000;
    private const double Cos25 = 0.9063077870366499, Sin25 = 0.42261826174069944;
    private const double Cos35 = 0.8191520442889918, Sin35 = 0.573576436351046;

    /// <summary>
    /// An ID-1 card (85.6 × 53.98 mm) turned 25° in its plane and tilted back 35°, its center 10 mm
    /// right of and 5 mm above the camera's axis at 180 mm: its corners in the photo.
    /// </summary>
    public static Quad CardQuad()
    {
        double[] us = [-42.8, 42.8, 42.8, -42.8];
        double[] vs = [-26.99, -26.99, 26.99, 26.99];
        var corners = new PointD[4];
        for (int i = 0; i < 4; i++)
        {
            double u = us[i] * Cos25 - vs[i] * Sin25;
            double v = us[i] * Sin25 + vs[i] * Cos25;
            double x = u + 10;
            double y = v * Cos35 - 5;
            double z = 180 + v * Sin35;
            corners[i] = new PointD(CardPhotoWidth / 2.0 + CardFocal * x / z, CardPhotoHeight / 2.0 + CardFocal * y / z);
        }
        return Quad.FromCorners(corners);
    }

    /// <summary>
    /// The card shot: each pixel's center mapped onto the card (856 × 540 units), blue with a yellow band
    /// and a grey photo box, on the table elsewhere.
    /// </summary>
    public static RgbaImage CardPhoto()
    {
        var toCard = Homography.RectToQuad(856, 540, CardQuad())!.Value.Inverse()!.Value;
        const int w = CardPhotoWidth, h = CardPhotoHeight;
        var pixels = new byte[w * h * 4];
        for (int y = 0; y < h; y++)
        {
            for (int x = 0; x < w; x++)
            {
                var c = toCard.Map(new PointD(x + 0.5, y + 0.5));
                (int r, int g, int b) = (Table.R, Table.G, Table.B);
                if (c.X >= 0 && c.X < 856 && c.Y >= 0 && c.Y < 540)
                {
                    (r, g, b) = (40, 90, 160);
                    if (c.Y >= 60 && c.Y < 140) (r, g, b) = (200, 170, 60);
                    else if (c.X >= 60 && c.X < 260 && c.Y >= 200 && c.Y < 460) (r, g, b) = (120, 100, 90);
                }
                int p = (y * w + x) * 4;
                pixels[p] = (byte)r;
                pixels[p + 1] = (byte)g;
                pixels[p + 2] = (byte)b;
                pixels[p + 3] = 255;
            }
        }
        return new RgbaImage(w, h, pixels);
    }

    /// <summary>The smallest rectangle holding every pixel of <paramref name="page"/> that is not white (a channel below 250).</summary>
    public static (int X0, int Y0, int X1, int Y1)? Printed(RgbaImage page)
    {
        int x0 = int.MaxValue, y0 = int.MaxValue, x1 = -1, y1 = -1;
        for (int y = 0; y < page.Height; y++)
        {
            for (int x = 0; x < page.Width; x++)
            {
                int p = (y * page.Width + x) * 4;
                if (page.Pixels[p] >= 250 && page.Pixels[p + 1] >= 250 && page.Pixels[p + 2] >= 250) continue;
                x0 = Math.Min(x0, x);
                y0 = Math.Min(y0, y);
                x1 = Math.Max(x1, x + 1);
                y1 = Math.Max(y1, y + 1);
            }
        }
        return x1 < 0 ? null : (x0, y0, x1, y1);
    }
}

public class CaptureObjectsTests
{
    private static ScanSettings Task(ScanTask task) => TaskCatalog.Apply(task, new ScanSettings());

    /// <summary>Text recognition that can run, reading nothing.</summary>
    private sealed class ReadingScorer : IOrientationScorer
    {
        public bool IsAvailable => true;
        public OrientationScore Score(RgbaImage image, CancellationToken token) => OrientationScore.None;
    }

    [Fact]
    public void TheTaskDecidesWhatIsPhotographed()
    {
        Assert.Equal(CaptureKind.Photo, CaptureObjects.KindFor(Task(ScanTask.Photos)));
        Assert.Equal(CaptureKind.Photo, CaptureObjects.KindFor(Task(ScanTask.PhotoRestore)));
        Assert.Equal(CaptureKind.Receipt, CaptureObjects.KindFor(Task(ScanTask.Receipt)));
        Assert.Equal(CaptureKind.IdCard, CaptureObjects.KindFor(Task(ScanTask.IdCard)));
        foreach (var task in new[] { ScanTask.Document, ScanTask.Feeder, ScanTask.Email, ScanTask.Word, ScanTask.Book })
        {
            Assert.Equal(CaptureKind.Document, CaptureObjects.KindFor(Task(task)));
        }
        // Without a task: photos in photo mode, else pages.
        Assert.Equal(CaptureKind.Photo, CaptureObjects.KindFor(new ScanSettings { Intent = ScanIntent.Photo }));
        Assert.Equal(CaptureKind.Document, CaptureObjects.KindFor(new ScanSettings()));
        Assert.True(CaptureObjects.FindsSeveral(CaptureKind.Receipt));
        Assert.True(CaptureObjects.FindsSeveral(CaptureKind.Photo));
        Assert.False(CaptureObjects.FindsSeveral(CaptureKind.IdCard));
        Assert.False(CaptureObjects.FindsSeveral(CaptureKind.Document));
        Assert.Equal(200, CaptureObjects.FallbackDpi);
    }

    [Fact]
    public void EachObjectOfAShotIsAPageOfThePhoto()
    {
        var photo = ObjectShots.TwoPrints();
        var when = new DateTime(2026, 10, 21, 12, 0, 0);
        // The second outline given the other way round, from its bottom left: named again.
        var reversed = new Quad(ObjectShots.PrintB.BottomLeft, ObjectShots.PrintB.BottomRight, ObjectShots.PrintB.TopRight,
                                ObjectShots.PrintB.TopLeft);
        var pages = CaptureObjects.Pages(photo, [ObjectShots.PrintA, reversed], CaptureKind.Photo, 750, when);
        Assert.Equal(2, pages.Count);
        Assert.NotEqual(pages[0].Id, pages[1].Id);
        foreach (var page in pages)
        {
            Assert.Same(photo, page.Image);
            Assert.Equal(CaptureScale.NominalDpi, page.Dpi);
            Assert.Equal(ColorMode.Color, page.ColorMode);
            Assert.Equal(PageSource.Photo, page.Source);
            Assert.Equal(when, page.CreatedAt);
            Assert.Equal((900, 600), (page.Capture!.SourceWidth, page.Capture.SourceHeight));
            Assert.Equal(CaptureKind.Photo, page.Capture.Kind);
            Assert.Equal(750, page.Capture.FocalLength);
            Assert.Null(page.Capture.Scale);
            Assert.Null(page.Geometry);
            Assert.False(CaptureObjects.IsCutOut(page));
        }
        Assert.Equal(ObjectShots.PrintA, pages[0].Capture!.Quad);
        Assert.Equal(ObjectShots.PrintB, pages[1].Capture!.Quad);
        Assert.Empty(CaptureObjects.Pages(photo, [], CaptureKind.Receipt));
    }

    [Fact]
    public void AShotWithNothingFoundComesInWhole()
    {
        var photo = ObjectShots.TwoPrints();
        var page = CaptureObjects.FallbackPage(photo);
        Assert.Same(photo, page.Image);
        Assert.Equal(CaptureObjects.FallbackDpi, page.Dpi);
        Assert.Equal(PageSource.Photo, page.Source);
        Assert.Null(page.Capture);
        Assert.False(CaptureObjects.IsCutOut(page));
        // Nothing cuts it: the clean-up leaves its pixels as they are.
        var processed = PageProcessor.ForCapture(Task(ScanTask.Photos)).Process([page]).Pages.Single();
        Assert.Same(photo, processed.Image);
        Assert.Null(processed.Geometry);
    }

    [Fact]
    public void TheRegionAroundAnOutlineIsItsBoundingBox()
    {
        var quad = new Quad(new PointD(10, 30), new PointD(110, 20), new PointD(130, 90), new PointD(5, 80));
        var region = CaptureObjects.RegionAround(quad);
        Assert.Equal(new PointD(67.5, 55), region.Center);
        Assert.Equal(new SizeD(125, 70), region.Size);
        Assert.Equal(0, region.AngleDegrees);
    }

    [Fact]
    public void ACardsNoteSaysWhenItIsNotAtRealSizeThenTheGlare()
    {
        Assert.Null(CaptureObjects.CardNote(realSize: true, glare: false));
        Assert.Equal("Tilt to avoid glare", CaptureObjects.CardNote(realSize: true, glare: true));
        Assert.Equal("This does not look like the shape of an ID card, so it is not at real size. Fix the crop, or take it again.",
                     CaptureObjects.CardNote(realSize: false, glare: false));
        Assert.Equal(CaptureObjects.CardNotRealSizeNote + " " + GlareDetector.Hint,
                     CaptureObjects.CardNote(realSize: false, glare: true));
    }

    [Fact]
    public void ForCaptureReadsNothingOnObjectsOutsideTheQueue()
    {
        var scorer = new ReadingScorer();
        // Pages for the queue, as before: the photo import's steps, with the text read to turn them upright.
        var document = Task(ScanTask.Document);
        document.Document.AutoRotate = true;
        Assert.Equal(["perspective", "enhance", "blank", "separator", "orientation"],
                     PageProcessor.ForCapture(document, scorer).Steps.Select(step => step.Name));
        // Photos, receipts and the ID card: cut out and cleaned up, then only their adjustments.
        foreach (var task in new[] { ScanTask.Photos, ScanTask.IdCard })
        {
            var s = Task(task);
            s.Document.AutoRotate = true;
            Assert.Equal(["perspective", "enhance"], PageProcessor.ForCapture(s, scorer).Steps.Select(step => step.Name));
        }
        Assert.Equal(["perspective", "enhance", "adjust"],
                     PageProcessor.ForCapture(Task(ScanTask.PhotoRestore), scorer).Steps.Select(step => step.Name));
        Assert.Equal(["perspective", "enhance", "adjust"],
                     PageProcessor.ForCapture(Task(ScanTask.Receipt), scorer).Steps.Select(step => step.Name));
        Assert.Equal(DocumentEnhanceMode.Photo, ((EnhanceStep)PageProcessor.ForCapture(Task(ScanTask.Photos)).Steps[1]).Mode);
        Assert.Equal(DocumentEnhanceMode.Gray, ((EnhanceStep)PageProcessor.ForCapture(Task(ScanTask.Receipt)).Steps[1]).Mode);
    }

    [Fact]
    public void TwoPrintsInOneShotAreCutOutAtTheirSize()
    {
        var photo = ObjectShots.TwoPrints();
        var pages = CaptureObjects.Pages(photo, [ObjectShots.PrintA, ObjectShots.PrintB], CaptureKind.Photo);
        var cut = PageProcessor.ForCapture(Task(ScanTask.Photos)).Process(pages).Pages;
        Assert.Equal(2, cut.Count);
        foreach (var page in cut)
        {
            Assert.True(CaptureObjects.IsCutOut(page));
            Assert.Equal(CaptureScaleBasis.PhotoSize, page.Capture!.Scale!.Basis);
            Assert.Equal("photo4x6in", page.Capture.Scale.Size);
            // A photo is cleaned up as a photo, never evened out, and stays in color.
            Assert.Equal(DocumentEnhanceMode.Photo, page.Capture.Enhancement);
            Assert.Equal(ColorMode.Color, page.ColorMode);
            Assert.Same(photo, page.Alternate!.Image);
        }
        // 300 px across 6 in: 50 dpi; 360 px: 60 dpi; each the print's own pixels.
        Assert.Equal((50, 300, 200), (cut[0].Dpi, cut[0].Image.Width, cut[0].Image.Height));
        Assert.Equal((60, 360, 240), (cut[1].Dpi, cut[1].Image.Width, cut[1].Image.Height));
        Assert.Equal(ObjectShots.PrintA, cut[0].Capture!.Quad);
    }

    [Fact]
    public void AdjustedObjectsShareTheShotAsTaken()
    {
        var photo = ObjectShots.TwoPrints();
        var receipts = PageProcessor.ForCapture(Task(ScanTask.Receipt));
        Assert.False(receipts.Steps.OfType<AdjustmentStep>().Single().AdjustsAlternate);
        // Receipts are made gray; the shot they were cut from stays one, as taken.
        var pages = CaptureObjects.Pages(photo, [ObjectShots.PrintA, ObjectShots.PrintB], CaptureKind.Receipt);
        var cut = receipts.Process(pages).Pages;
        Assert.Equal(2, cut.Count);
        foreach (var page in cut)
        {
            Assert.True(CaptureObjects.IsCutOut(page));
            Assert.Equal(ColorMode.Grayscale, page.ColorMode);
            Assert.Same(photo, page.Alternate!.Image);
        }
        // A page for the queue has its photo adjusted with it, so either can be shown.
        var document = Task(ScanTask.Document);
        document.ColorMode = ColorMode.Grayscale;
        Assert.True(PageProcessor.ForCapture(document).Steps.OfType<AdjustmentStep>().Single().AdjustsAlternate);
    }

    [Fact]
    public void TheCameraIdCardComesOutAtItsRealSizeOnThePage()
    {
        var photo = ObjectShots.CardPhoto();
        var quad = ObjectShots.CardQuad();
        var settings = Task(ScanTask.IdCard);
        var page = CaptureObjects.Pages(photo, [quad], CaptureKind.IdCard, ObjectShots.CardFocal).Single();
        var cut = PageProcessor.ForCapture(settings).Process([page]).Pages.Single();
        Assert.True(CaptureObjects.IsCutOut(cut));
        var scale = cut.Capture!.Scale!;
        Assert.Equal("idCard", scale.Size);
        Assert.True(scale.IsRealSize);
        Assert.Equal(DocumentEnhanceMode.Photo, cut.Capture.Enhancement);
        Assert.Equal((scale.PixelWidth, scale.PixelHeight), (cut.Image.Width, cut.Image.Height));

        // Composed on A4 at the side's resolution, as the review saves it: 85.60 × 53.98 mm within 0.5 mm.
        var paper = PaperSizes.Inches(PaperSize.A4)!.Value;
        int pageDpi = IdCardComposer.PageDpi(cut.Dpi);
        var side = new IdCardSide(cut.Image, cut.Dpi);
        Assert.False(IdCardLayout.Place(side.Inches, null, paper).ScaledToFit);
        var composed = IdCardComposer.Compose(side, null, pageDpi, paper);
        var printed = ObjectShots.Printed(composed)!.Value;
        double widthMm = (printed.X1 - printed.X0) * 25.4 / pageDpi;
        double heightMm = (printed.Y1 - printed.Y0) * 25.4 / pageDpi;
        Assert.InRange(Math.Max(widthMm, heightMm), 85.10, 86.10);
        Assert.InRange(Math.Min(widthMm, heightMm), 53.48, 54.48);
        // No glare on this card.
        Assert.False(GlareDetector.HasGlare(photo, quad));
    }

    [Fact]
    public void ReceiptsOnAWhiteTableAreFoundInTheWholeShotWhenNoOutlineWas()
    {
        // Thermal paper three levels darker than the white table: the shot at 200 dpi (the bed doubled).
        var left = new TestPages.Placed(TestPages.Receipt(300, 800, 237, 153, 40, 0xC0FFEE01), 220, 585, TestPages.Plus3);
        var right = new TestPages.Placed(TestPages.Receipt(300, 800, 237, 153, 40, 0xC0FFEE02), 630, 585, TestPages.Minus3);
        var photo = TestPages.Enlarged(TestPages.ReceiptBed(245, 0xBED00001, left, right), 2);
        var page = CaptureObjects.FallbackPage(photo);
        var processed = PageProcessor.ForCapture(Task(ScanTask.Receipt)).Process([page]).Pages.Single();
        Assert.Equal(ColorMode.Grayscale, processed.ColorMode);
        var regions = ReceiptDetector.DetectRegions(processed.Image, processed.Dpi);
        Assert.Equal(2, regions.Count);
        Assert.InRange(regions[0].Center.X, 440 - 20, 440 + 20);
        Assert.InRange(regions[1].Center.X, 1260 - 20, 1260 + 20);
        foreach (var region in regions)
        {
            Assert.InRange(region.Center.Y, 1170 - 20, 1170 + 20);
            Assert.InRange(Math.Min(region.Size.Width, region.Size.Height), 560, 640);
        }
    }

    [Fact]
    public void PhotosOnAPlainTableAreFoundInTheWholeShotWhenNoOutlineWas()
    {
        // The photos UI test's fixture (scripts/make_ios_ui_fixture.py photos) has these very pixels.
        Assert.Equal(0xE0C900E1u, GlareCards.Checksum(ObjectShots.PrintsOnTable()));
        // The flatbed's search of the whole shot at the fallback resolution, as the Photos task runs it.
        var page = CaptureObjects.FallbackPage(ObjectShots.PrintsOnTable());
        var processed = PageProcessor.ForCapture(Task(ScanTask.Photos)).Process([page]).Pages.Single();
        var options = new PhotoDetectorOptions { MinPhotoSideInches = new ScanSettings().PhotoMinSideInches };
        var regions = PhotoDetector.DetectRegions(processed.Image, processed.Dpi, options);
        Assert.Equal(2, regions.Count);
        Assert.InRange(regions[0].Center.X, 345 - 6, 345 + 6);
        Assert.InRange(regions[0].Center.Y, 300 - 6, 300 + 6);
        Assert.InRange(regions[1].Center.X, 860 - 6, 860 + 6);
        Assert.InRange(regions[1].Center.Y, 560 - 6, 560 + 6);
        Assert.InRange(Math.Max(regions[0].Size.Width, regions[0].Size.Height), 440, 456);
        Assert.InRange(Math.Max(regions[1].Size.Width, regions[1].Size.Height), 410, 426);
    }

    [Fact]
    public void ThePhotoReviewSaysWhatItFoundAndSaves()
    {
        Assert.Equal("Found 3 photos", PhotoReview.Title(3));
        Assert.Equal("Found 1 photo", PhotoReview.Title(1));
        Assert.Equal("Save 2 photos", PhotoReview.SaveTitle(2));
        Assert.Equal("Save 1 photo", PhotoReview.SaveTitle(1));
    }
}
