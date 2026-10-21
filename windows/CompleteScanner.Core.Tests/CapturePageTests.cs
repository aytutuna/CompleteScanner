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
        Assert.Equal(["perspective", "blank", "separator"], PageProcessor.ForCapture(s).Steps.Select(step => step.Name));
        s.ColorMode = ColorMode.Grayscale;
        var processor = PageProcessor.ForCapture(s);
        Assert.Equal(["perspective", "blank", "separator", "adjust"], processor.Steps.Select(step => step.Name));
        var processed = processor.Process([Captured(Photo(640, 480), Facts)]).Pages.Single();
        Assert.Equal(GeometryBasis.Perspective, processed.Geometry!.Basis);
        Assert.Equal(33, processed.Dpi);
        Assert.NotNull(processed.Blank);
        Assert.Equal(ColorMode.Grayscale, processed.ColorMode);
        Assert.NotNull(processed.Capture!.Scale);
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
