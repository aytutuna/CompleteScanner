using CompleteScanner.Core;
using Xunit;

namespace CompleteScanner.Core.Tests;

// Twin of Tests/CompleteScannerTests/CapturePageTests.swift: camera pages in the clean-up stage, their
// capture facts kept by every rebuild, and the geometry of perspective pages.

public class CapturePageTests
{
    /// <summary>A sheet photographed square on: an A4-shaped outline (280 × 396 px) in a 640 × 480 photo.</summary>
    private static readonly Quad SheetQuad =
        new(new PointD(100, 40), new PointD(380, 40), new PointD(380, 436), new PointD(100, 436));

    private static RgbaImage Photo(int w, int h) => PerspectiveWarpTests.Fixture(w, h);

    private static ScannedPage Captured(RgbaImage photo, CaptureFacts capture) =>
        new ScannedPage(photo, 72, ColorMode.Color).WithCapture(capture);

    private static CaptureFacts Facts => new(SheetQuad, 640, 480) { Kind = CaptureKind.Document, FocalLength = 500 };

    [Fact]
    public void PerspectiveStepCutsTheSheetOutAtItsRealSize()
    {
        var photo = Photo(640, 480);
        var page = Captured(photo, Facts).WithSide(PageSide.Front, 0);
        var step = new PerspectiveStep();
        Assert.Equal("perspective", step.Name);
        var cut = step.Apply(page);

        var scale = cut.Capture!.Scale!;
        Assert.Equal(CaptureScaleBasis.Paper, scale.Basis);
        Assert.Equal("a4", scale.Size);
        Assert.Equal(33, scale.Dpi); // 396 px over 11.6929 in
        Assert.Equal(33, cut.Dpi);
        Assert.Equal((273, 386), (cut.Image.Width, cut.Image.Height));
        Assert.Equal((scale.PixelWidth, scale.PixelHeight), (cut.Image.Width, cut.Image.Height));
        Assert.Equal(PerspectiveWarp.Warp(photo, SheetQuad, 273, 386)!.Pixels, cut.Image.Pixels);
        Assert.Equal(new PageGeometry(true, 0, GeometryBasis.Perspective) { Quad = SheetQuad }, cut.Geometry);
        Assert.Same(photo, cut.Alternate!.Image);
        Assert.True(cut.CanSwapVersions);
        Assert.Equal((page.Id, PageSide.Front, 0), (cut.Id, cut.Side, cut.SheetIndex));
        Assert.Equal(Facts with { Scale = scale }, cut.Capture);
        Assert.Equal("Corrected from photo", PageCorrections.Caption(cut));
        Assert.Equal("Show as photographed", PageCorrections.ToggleLabel(cut));

        // Done once: a page cut out already, or with a geometry, stays as it is.
        Assert.Same(cut, step.Apply(cut));
        var straightened = Captured(photo, Facts).WithGeometry(photo, new PageGeometry(false, 1, GeometryBasis.TextLines));
        Assert.Same(straightened, step.Apply(straightened));
        var scanned = new ScannedPage(photo, 300, ColorMode.Color);
        Assert.Same(scanned, step.Apply(scanned));
        var bowTie = Captured(photo, Facts with { Quad = new Quad(new PointD(100, 40), new PointD(380, 436), new PointD(380, 40), new PointD(100, 436)) });
        Assert.Same(bowTie, step.Apply(bowTie));
    }

    [Fact]
    public void PerspectiveStepScalesTheCornersToASmallerPhotoInMemory()
    {
        var half = Photo(320, 240);
        var cut = new PerspectiveStep().Apply(Captured(half, Facts));
        var quad = SheetQuad.Scaled(0.5, 0.5);
        Assert.Equal(quad, cut.Geometry!.Quad);
        Assert.Equal(16, cut.Dpi); // 198 px over 11.6929 in
        Assert.Equal(PerspectiveWarp.Warp(half, quad, cut.Image.Width, cut.Image.Height)!.Pixels, cut.Image.Pixels);
        // The facts follow the photo kept as the other version: its corners, its size, its focal length.
        Assert.Same(half, cut.Alternate!.Image);
        var kept = cut.Capture!;
        Assert.Equal(quad, kept.Quad);
        Assert.Equal((320, 240), (kept.SourceWidth, kept.SourceHeight));
        Assert.Equal(250, kept.FocalLength);
        Assert.Equal(cut.Geometry!.Quad, kept.Quad);
        Assert.Equal(16, kept.Scale!.Dpi);
    }

    [Fact]
    public void PerspectiveStepLeavesAPhotoTurnedWithoutItsFactsAlone()
    {
        var turned = PhotoImport.Oriented(Photo(640, 480), new PhotoOrientation(1, false));
        Assert.Equal((480, 640), (turned.Width, turned.Height));
        var page = Captured(turned, Facts);
        Assert.Same(page, new PerspectiveStep().Apply(page));
    }

    [Fact]
    public void PerspectiveStepCutsAPhotoTurnedWithItsFacts()
    {
        var quarter = new PhotoOrientation(1, false);
        var turned = PhotoImport.Oriented(Photo(640, 480), quarter);
        var facts = Facts.Oriented(quarter);
        var cut = new PerspectiveStep().Apply(Captured(turned, facts));
        var scale = cut.Capture!.Scale!;
        Assert.Equal("a4", scale.Size);
        Assert.Equal(33, cut.Dpi);
        // The sheet lies on its side in the turned photo: the same page, turned.
        Assert.Equal((386, 273), (cut.Image.Width, cut.Image.Height));
        Assert.Equal(facts with { Scale = scale }, cut.Capture);
        Assert.Equal(facts.Quad, cut.Geometry!.Quad);
    }

    [Fact]
    public void CaptureFactsTurnWithThePhoto()
    {
        // Four marked pixels at the corners of an outline in a 64 × 48 photo: for every orientation tag,
        // the turned facts' corners land on the same marks in the photo turned the same way.
        const int w = 64, h = 48;
        var photo = RgbaImage.Filled(w, h, 0, 0, 0);
        var marks = new (int X, int Y, byte Value)[] { (10, 5, 50), (49, 8, 100), (52, 40, 150), (7, 37, 200) };
        foreach (var (x, y, value) in marks) photo.Pixels[(y * w + x) * 4] = value;
        var quad = new Quad(new PointD(10.5, 5.5), new PointD(49.5, 8.5), new PointD(52.5, 40.5), new PointD(7.5, 37.5));
        var facts = new CaptureFacts(quad, w, h) { Kind = CaptureKind.Receipt, FocalLength = 70 };
        for (int tag = 1; tag <= 8; tag++)
        {
            var orientation = PhotoOrientation.FromExif(tag);
            var turnedPhoto = PhotoImport.Oriented(photo, orientation);
            var turned = facts.Oriented(orientation);
            Assert.Equal((turnedPhoto.Width, turnedPhoto.Height), (turned.SourceWidth, turned.SourceHeight));
            Assert.True(turned.Quad.IsConvex, $"tag {tag}");
            Assert.Equal(CaptureKind.Receipt, turned.Kind);
            Assert.Equal(70, turned.FocalLength);
            Assert.Null(turned.Scale);
            var found = new List<byte>();
            foreach (var corner in turned.Quad.Corners)
            {
                int px = (int)Math.Floor(corner.X), py = (int)Math.Floor(corner.Y);
                found.Add(turnedPhoto.Pixels[(py * turnedPhoto.Width + px) * 4]);
            }
            found.Sort();
            Assert.Equal([50, 100, 150, 200], found);
        }
        // A quarter turn clockwise: (x, y) to (48 − y, x), named again from the top edge.
        Assert.Equal(new Quad(new PointD(10.5, 7.5), new PointD(42.5, 10.5), new PointD(39.5, 49.5), new PointD(7.5, 52.5)),
                     facts.Oriented(new PhotoOrientation(1, false)).Quad);
        // Turned all the way round, and upright, the facts are as they were.
        Assert.Equal(facts, facts.Oriented(new PhotoOrientation(1, false)).Oriented(new PhotoOrientation(3, false)));
        Assert.Equal(facts, facts.Oriented(new PhotoOrientation(2, true)).Oriented(new PhotoOrientation(2, true)));
        Assert.Same(facts, facts.Oriented(PhotoOrientation.Upright));
    }

    [Fact]
    public void CaptureFactsScaleWithThePhoto()
    {
        var facts = Facts;
        var half = facts.ScaledTo(320, 240);
        Assert.Equal(SheetQuad.Scaled(0.5, 0.5), half.Quad);
        Assert.Equal((320, 240), (half.SourceWidth, half.SourceHeight));
        Assert.Equal(250, half.FocalLength);
        Assert.Equal(facts.Kind, half.Kind);
        // Another shape: each way by its own scale, the focal length by their geometric mean.
        var wide = facts.ScaledTo(1280, 240);
        Assert.Equal(SheetQuad.Scaled(2, 0.5), wide.Quad);
        Assert.Equal(500, wide.FocalLength);
        // No focal length is made up; the same size and no size change nothing.
        Assert.Null((facts with { FocalLength = null }).ScaledTo(320, 240).FocalLength);
        Assert.Same(facts, facts.ScaledTo(640, 480));
        Assert.Same(facts, facts.ScaledTo(0, 480));
        // The photos the facts describe: the same shape, to within a resize's rounding.
        Assert.True(facts.DescribesPhoto(640, 480));
        Assert.True(facts.DescribesPhoto(320, 240));
        Assert.True(facts.DescribesPhoto(321, 240));
        Assert.True(facts.DescribesPhoto(4000, 3000));
        Assert.False(facts.DescribesPhoto(480, 640));
        Assert.False(facts.DescribesPhoto(640, 400));
        Assert.False(facts.DescribesPhoto(0, 0));
        Assert.False(new CaptureFacts(SheetQuad, 0, 480).DescribesPhoto(640, 480));
        // A nearly square photo turned a quarter is not taken for the same photo either.
        Assert.False(new CaptureFacts(SheetQuad, 1000, 999).DescribesPhoto(999, 1000));
    }

    [Fact]
    public void GeometryStepLeavesCameraAndPhotoPagesAlone()
    {
        var photo = Photo(640, 480);
        var step = new GeometryStep(true, true);
        var captured = Captured(photo, Facts);
        Assert.Same(captured, step.Apply(captured));
        var cut = new PerspectiveStep().Apply(captured);
        Assert.Same(cut, step.Apply(cut));
        var imported = PhotoImport.CorrectedPage(PhotoScenes.WoodScene(), PhotoScenes.WoodMap.Corners(PhotoScenes.PageWidth, PhotoScenes.PageHeight))!;
        Assert.Same(imported, step.Apply(imported));
    }

    [Fact]
    public void ForCaptureCutsThePageOutFirst()
    {
        var s = new ScanSettings();
        s.Document.AutoCrop = true;
        Assert.Equal(["perspective", "enhance"], PageProcessor.ForCapture(s).Prepare.Select(step => step.Name));
        Assert.Equal(["blank", "separator"], PageProcessor.ForCapture(s).Steps.Select(step => step.Name));
        s.ColorMode = ColorMode.Grayscale;
        var processor = PageProcessor.ForCapture(s);
        Assert.Equal(["blank", "separator", "adjust"], processor.Steps.Select(step => step.Name));
        Assert.Equal(DocumentEnhanceMode.Gray, Assert.IsType<EnhanceStep>(processor.Prepare[1]).Mode);
        var result = processor.Process([Captured(Photo(640, 480), Facts)]);
        var processed = result.Pages.Single();
        // The preview and the history show the page cut out, not the photo around it.
        var shown = result.Arranged.Single();
        Assert.Equal(GeometryBasis.Perspective, shown.Geometry!.Basis);
        Assert.Equal(processed.Image.Width, shown.Image.Width);
        Assert.Equal(processed.Image.Height, shown.Image.Height);
        Assert.Equal(GeometryBasis.Perspective, processed.Geometry!.Basis);
        Assert.Equal(33, processed.Dpi);
        Assert.NotNull(processed.Blank);
        Assert.Equal(ColorMode.Grayscale, processed.ColorMode);
        Assert.NotNull(processed.Capture!.Scale);
        Assert.Equal(DocumentEnhanceMode.Gray, processed.Capture.Enhancement);
    }

    /// <summary>
    /// <paramref name="sheet"/> photographed square on, on a dark table with <paramref name="margin"/> px of
    /// table round it, and its outline in the photo.
    /// </summary>
    internal static (RgbaImage Photo, Quad Sheet) SquareOnATable(RgbaImage sheet, int margin = 60)
    {
        int w = sheet.Width + 2 * margin, h = sheet.Height + 2 * margin;
        var pixels = new byte[w * h * 4];
        for (int y = 0; y < h; y++)
        {
            for (int x = 0; x < w; x++)
            {
                int i = (y * w + x) * 4;
                int sx = x - margin, sy = y - margin;
                if (sx >= 0 && sx < sheet.Width && sy >= 0 && sy < sheet.Height)
                {
                    int j = (sy * sheet.Width + sx) * 4;
                    pixels[i] = sheet.Pixels[j];
                    pixels[i + 1] = sheet.Pixels[j + 1];
                    pixels[i + 2] = sheet.Pixels[j + 2];
                }
                else
                {
                    pixels[i] = 52;
                    pixels[i + 1] = 40;
                    pixels[i + 2] = 34;
                }
                pixels[i + 3] = 255;
            }
        }
        var quad = new Quad(new PointD(margin, margin), new PointD(margin + sheet.Width, margin),
                            new PointD(margin + sheet.Width, margin + sheet.Height), new PointD(margin, margin + sheet.Height));
        return (new RgbaImage(w, h, pixels), quad);
    }

    [Fact]
    public void ForCapture_AWholeSpreadIsCutOutOfItsPhoto_ThenSplitAtItsSpine()
    {
        var s = TaskCatalog.Apply(ScanTask.Book, new ScanSettings());
        // Page by page, the phone's default: each shot is one page, as any camera page.
        Assert.False(PageProcessor.SplitsCameraSpreads(s));
        var single = PageProcessor.ForCapture(s);
        Assert.Null(single.Book);
        Assert.Equal(["perspective", "enhance"], single.Prepare.Select(step => step.Name));
        Assert.Equal(["blank", "separator"], single.Steps.Select(step => step.Name));

        s.TaskOptions.CameraSpreads = true;
        Assert.True(PageProcessor.SplitsCameraSpreads(s));
        var processor = PageProcessor.ForCapture(s);
        Assert.Equal(["perspective", "enhance"], processor.Prepare.Select(step => step.Name));
        Assert.True(Assert.IsType<PerspectiveStep>(processor.Prepare[0]).Spread);
        Assert.False(Assert.IsType<PerspectiveStep>(single.Prepare[0]).Spread);
        Assert.Equal(["blank", "spineShadow", "separator"], processor.Steps.Select(step => step.Name));
        Assert.Equal(BookSplitOptions.Of(s), processor.Book);
        // Not for another task, nor for a scan.
        var document = TaskCatalog.Apply(ScanTask.Document, new ScanSettings());
        document.TaskOptions.CameraSpreads = true;
        Assert.False(PageProcessor.SplitsCameraSpreads(document));
        Assert.Empty(PageProcessor.ForScan(s).Prepare);

        // The open book as the camera takes it: TestPages.ShadowSpread (1100 × 850, its spine at x = 572).
        var (photo, quad) = SquareOnATable(TestPages.ShadowSpread().ToRgba());
        var page = new ScannedPage(photo, 72, ColorMode.Color) { Source = PageSource.Photo }
            .WithCapture(new CaptureFacts(quad, photo.Width, photo.Height));
        var result = processor.Process([page]);
        // The spread as cut out of the photo is what is kept to split it again by hand: at its own pixels,
        // matched against no sheet.
        var spread = Assert.Single(result.Spreads);
        Assert.Equal(page.Id, spread.Id);
        Assert.Equal(GeometryBasis.Perspective, spread.Geometry!.Basis);
        Assert.Equal(CaptureScaleBasis.Nominal, spread.Capture!.Scale!.Basis);
        Assert.Equal((1100, 850, CaptureScale.NominalDpi), (spread.Image.Width, spread.Image.Height, spread.Dpi));
        Assert.Equal(2, result.Pages.Count);
        Assert.All(result.Pages, p => Assert.Equal(page.Id, p.SpreadId));
        Assert.Equal([true, false], result.Pages.Select(p => p.Spread!.IsLeft));
        // Cut at the spine: the left page ends near x = 572.
        var gutter = result.Pages[0].Spread!.Gutter!;
        Assert.Equal(GutterAxis.Vertical, gutter.Axis);
        Assert.InRange(result.Pages[0].Image.Width, 540, 600);
        Assert.All(result.Pages, p => Assert.Equal(CaptureScale.NominalDpi, p.Dpi));
        // Each page keeps where it came from and what the camera recorded.
        Assert.All(result.Pages, p => Assert.Equal(PageSource.Photo, p.Source));
        Assert.All(result.Pages, p => Assert.Equal(spread.Capture, p.Capture));

        // A book read from right to left: its right page comes first.
        s.TaskOptions.BookRightToLeft = true;
        var rtl = PageProcessor.ForCapture(s).Process([page]).Pages;
        Assert.Equal([false, true], rtl.Select(p => p.Spread!.IsLeft));
    }

    [Theory]
    [InlineData(1700, 1100, PaperSize.IdCard)] // a Letter book's 17 × 11 in spread has nearly an ID card's shape
    [InlineData(1414, 1000, PaperSize.A4)] // an A4 book's spread is A3, A4's shape
    public void ForCapture_AWholeSpreadKeepsItsPixels_NotASingleSheetsSize(int width, int height, PaperSize lookalike)
    {
        var s = TaskCatalog.Apply(ScanTask.Book, new ScanSettings());
        s.TaskOptions.CameraSpreads = true;
        var (photo, quad) = SquareOnATable(TestPages.Spread(width / 2, 20, 80, 250, 17, 0xB00C0011, width, height).ToRgba());
        // As one page, the spread would snap to a sheet it only looks like.
        Assert.Equal(lookalike, CaptureScale.Match((double)width / height, CaptureScale.Papers)!.Paper);

        var result = PageProcessor.ForCapture(s).Process([Captured(photo, new CaptureFacts(quad, photo.Width, photo.Height))]);
        var spread = Assert.Single(result.Spreads);
        Assert.Equal(CaptureScaleBasis.Nominal, spread.Capture!.Scale!.Basis);
        Assert.Equal((width, height, CaptureScale.NominalDpi), (spread.Image.Width, spread.Image.Height, spread.Dpi));
        Assert.Equal(2, result.Pages.Count);
        Assert.All(result.Pages, p =>
        {
            Assert.Equal(height, p.Image.Height);
            Assert.InRange(p.Image.Width, width / 2 - 60, width / 2 + 60);
            Assert.Equal(CaptureScale.NominalDpi, p.Dpi);
        });
    }

    [Fact]
    public void ForCapture_ThePagesOfASpreadMadeGrayStayGrayInAColorTask()
    {
        var s = TaskCatalog.Apply(ScanTask.Book, new ScanSettings());
        s.TaskOptions.CameraSpreads = true;
        s.ColorMode = ColorMode.Color;
        s.Adjustments.Brightness = 0.1;
        var processor = PageProcessor.ForCapture(s);
        Assert.Equal("adjust", processor.Steps[^1].Name);
        var (photo, quad) = SquareOnATable(TestPages.ShadowSpread().ToRgba());
        var result = processor.Process([Captured(photo, new CaptureFacts(quad, photo.Width, photo.Height))]);
        Assert.Equal(DocumentEnhanceMode.Gray, Assert.Single(result.Spreads).Capture!.Enhancement);
        Assert.Equal(2, result.Pages.Count);
        Assert.All(result.Pages, p =>
        {
            Assert.Equal(DocumentEnhanceMode.Gray, p.Capture!.Enhancement);
            Assert.Equal(ColorMode.Grayscale, p.ColorMode);
        });
    }

    [Fact]
    public void AdjustmentsKeepACameraPageWithoutColorGrayInAColorTask()
    {
        var s = new ScanSettings();
        s.Adjustments.Brightness = 0.1;
        var processor = PageProcessor.ForCapture(s);
        Assert.Equal(["blank", "separator", "adjust"], processor.Steps.Select(step => step.Name));
        static ScannedPage Shot(RgbaImage sheet)
        {
            var photo = EnhancerPages.OnATable(sheet);
            return new ScannedPage(photo, CaptureScale.NominalDpi, ColorMode.Color) { Source = PageSource.Photo }
                .WithCapture(new CaptureFacts(EnhancerPages.TableQuad, photo.Width, photo.Height));
        }
        // Black print on white paper: made gray by the clean-up, and still gray after the brightness.
        var plain = processor.Process([Shot(EnhancerPages.Shadowed(stamp: false))]).Pages.Single();
        Assert.Equal(DocumentEnhanceMode.Gray, plain.Capture!.Enhancement);
        Assert.Equal(ColorMode.Grayscale, plain.ColorMode);
        Assert.True(ColorAnalysis.IsEffectivelyGray(plain.Image));
        // The photo kept as the other version is adjusted in the task's color mode: its warm paper stays warm.
        var alternate = plain.Alternate!.Image!.Pixels;
        Assert.Contains(Enumerable.Range(0, alternate.Length / 4), p => alternate[p * 4] != alternate[p * 4 + 2]);
        // With the red stamp: color.
        var stamped = processor.Process([Shot(EnhancerPages.Shadowed())]).Pages.Single();
        Assert.Equal(DocumentEnhanceMode.Color, stamped.Capture!.Enhancement);
        Assert.Equal(ColorMode.Color, stamped.ColorMode);
        // The mode the step adjusts a page in.
        var image = RgbaImage.Filled(8, 8, 200, 200, 200);
        var grayPage = new ScannedPage(image, 72, ColorMode.Grayscale).WithCapture(Facts with { Enhancement = DocumentEnhanceMode.Gray });
        var bwPage = new ScannedPage(image, 72, ColorMode.BlackWhite).WithCapture(Facts with { Enhancement = DocumentEnhanceMode.BlackAndWhite });
        var colorPage = new ScannedPage(image, 72, ColorMode.Color).WithCapture(Facts with { Enhancement = DocumentEnhanceMode.Color });
        var scanned = new ScannedPage(image, 72, ColorMode.Grayscale);
        var colorStep = new AdjustmentStep(s.Adjustments, ColorMode.Color);
        Assert.Equal(ColorMode.Grayscale, colorStep.ModeFor(grayPage));
        Assert.Equal(ColorMode.BlackWhite, colorStep.ModeFor(bwPage));
        Assert.Equal(ColorMode.Color, colorStep.ModeFor(colorPage));
        Assert.Equal(ColorMode.Color, colorStep.ModeFor(scanned));
        Assert.Equal(ColorMode.Grayscale, colorStep.Apply(grayPage).ColorMode);
        Assert.Equal(ColorMode.BlackWhite, new AdjustmentStep(s.Adjustments, ColorMode.BlackWhite).ModeFor(grayPage));
    }

    [Fact]
    public void CaptureFactsSurviveEveryRebuildOfThePage()
    {
        var capture = Facts with { Kind = CaptureKind.Receipt, Scale = new CaptureScaleResult(CaptureScaleBasis.ReceiptWidth, "receipt80mm", 101, 318, 1591, 3.15, 15.75) };
        var photo = Photo(64, 48);
        var page = new ScannedPage(photo, 101, ColorMode.Color).WithCapture(capture);
        var other = RgbaImage.Filled(3, 3, 0, 0, 0);
        foreach (var rebuilt in new[]
                 {
                     page.WithImage(other),
                     page.RotatedClockwise(),
                     page.WithSide(PageSide.Front, 0),
                     page.WithBlank(null),
                     page.WithInclusion(PageInclusion.Skip),
                     page.WithPatch(null),
                     page.WithBarcodes([]),
                     page.WithDocumentBreak(DocumentBreak.Split),
                     page.WithDocumentLabel("Receipts"),
                     page.WithUpright(new UprightTurn(2)),
                     page.TurnedUpright(1),
                     page.TurnedUpright(1).WithUprightToggled(),
                     page.WithAlternate(null),
                     page.WithSpread(null),
                     page.WithSpineShadow(other, new SpineShadowResult(PageEdge.Left, 0.2, 0.5, 1.4, 0.1)),
                     page.WithGeometry(other, new PageGeometry(true, 0, GeometryBasis.Perspective) { Quad = SheetQuad }),
                     page.WithGeometry(other, new PageGeometry(true, 0, GeometryBasis.Perspective)).WithVersionsSwapped(photo),
                     new ScannedPage(other, 300, ColorMode.Color).CopyMeta(page),
                 })
        {
            Assert.Equal(capture, rebuilt.Capture);
        }
        Assert.Null(new ScannedPage(photo, 300, ColorMode.Color).Capture);
        Assert.Null(page.WithCapture(null).Capture);
    }

    [Fact]
    public void ACutPageSwapsToThePhotoAndBackWithItsFacts()
    {
        var photo = Photo(640, 480);
        var cut = new PerspectiveStep().Apply(Captured(photo, Facts));
        var shown = cut.WithVersionsSwapped(cut.Alternate!.Image!);
        Assert.True(shown.ShowsOriginal);
        Assert.Same(photo, shown.Image);
        Assert.Equal(cut.Capture, shown.Capture);
        Assert.Equal(cut.Geometry, shown.Geometry);
        Assert.Equal("As photographed", PageCorrections.Caption(shown));
        Assert.Equal("Show corrected", PageCorrections.ToggleLabel(shown));
        var back = shown.WithVersionsSwapped(shown.Alternate!.Image!);
        Assert.False(back.ShowsOriginal);
        Assert.Equal(cut.Image.Pixels, back.Image.Pixels);
        Assert.Equal(cut.Capture, back.Capture);
        Assert.Equal(cut.Dpi, back.Dpi);
    }

    [Fact]
    public void EveryGeometryBasisHasItsWords()
    {
        // Each basis, as a switch over all of them would: a caption, a swap label, a note.
        foreach (var basis in Enum.GetValues<GeometryBasis>())
        {
            var geometry = new PageGeometry(true, basis == GeometryBasis.Perspective ? 0 : 2.4, basis);
            var page = new ScannedPage(Photo(8, 8), 100, ColorMode.Color).WithGeometry(Photo(6, 6), geometry);
            Assert.False(string.IsNullOrEmpty(geometry.Caption), basis.ToString());
            Assert.False(string.IsNullOrEmpty(PageCorrections.ToggleLabel(page)), basis.ToString());
            Assert.False(string.IsNullOrEmpty(PageCorrections.SwapNote(page, 1)), basis.ToString());
            Assert.Equal(basis == GeometryBasis.Perspective, PageCorrections.Caption(page) == PhotoImport.CorrectedCaption);
        }
        Assert.Equal(3, Enum.GetValues<GeometryBasis>().Length);
        // The quad is part of what a geometry is.
        Assert.NotEqual(new PageGeometry(true, 0, GeometryBasis.Perspective) { Quad = SheetQuad },
                        new PageGeometry(true, 0, GeometryBasis.Perspective));
        Assert.Null(new PageGeometry(true, 2, GeometryBasis.PageEdges).Quad);
    }
}
