using CompleteScanner.Core;
using Xunit;

namespace CompleteScanner.Core.Tests;

// Twin of Tests/CompleteScannerTests/PhotoImportTests.swift: the same cases on the same synthetic
// photos (PhotoScenes).

public class PhotoImportTests
{
    /// <summary>A small photo whose every pixel is different, to follow where each one goes.</summary>
    private static RgbaImage Numbered(int width, int height)
    {
        var pixels = new byte[width * height * 4];
        for (int i = 0; i < width * height; i++)
        {
            pixels[i * 4] = (byte)(10 + i);
            pixels[i * 4 + 1] = (byte)(100 + i);
            pixels[i * 4 + 2] = (byte)(200 - i);
            pixels[i * 4 + 3] = 255;
        }
        return new RgbaImage(width, height, pixels);
    }

    private static byte[] PixelAt(RgbaImage image, int x, int y) => image.Pixels.AsSpan((y * image.Width + x) * 4, 4).ToArray();

    /// <summary>Text recognition that can or cannot run, reading nothing.</summary>
    private sealed class StubScorer(bool available) : IOrientationScorer
    {
        public bool IsAvailable => available;
        public OrientationScore Score(RgbaImage image, CancellationToken token) => OrientationScore.None;
    }

    /// <summary>A barcode reader that can run and finds nothing.</summary>
    private sealed class EmptyReader : IBarcodeReader
    {
        public bool IsAvailable => true;
        public IReadOnlyList<BarcodeReading> Read(GrayImage image, CancellationToken token) => [];
    }

    [Fact]
    public void EveryOrientationTagHasItsTurn()
    {
        Assert.Equal(new PhotoOrientation(0, false), PhotoOrientation.FromExif(1));
        Assert.Equal(new PhotoOrientation(0, true), PhotoOrientation.FromExif(2));
        Assert.Equal(new PhotoOrientation(2, false), PhotoOrientation.FromExif(3));
        Assert.Equal(new PhotoOrientation(2, true), PhotoOrientation.FromExif(4));
        Assert.Equal(new PhotoOrientation(3, true), PhotoOrientation.FromExif(5));
        Assert.Equal(new PhotoOrientation(1, false), PhotoOrientation.FromExif(6));
        Assert.Equal(new PhotoOrientation(1, true), PhotoOrientation.FromExif(7));
        Assert.Equal(new PhotoOrientation(3, false), PhotoOrientation.FromExif(8));
        foreach (int unknown in new[] { 0, 9, -1, 274 })
        {
            Assert.True(PhotoOrientation.FromExif(unknown).IsUpright);
        }
        Assert.True(PhotoOrientation.Upright.IsUpright);
        Assert.False(PhotoOrientation.FromExif(6).IsUpright);
    }

    [Fact]
    public void EveryOrientationTagShowsThePhotoAsTheCameraSawIt()
    {
        // Where each stored pixel (x, y) of a W × H photo is shown, by the tag's definition: the
        // stored first row is shown as the top (1–4) or as a side (5–8) of the picture.
        const int w = 3, h = 2;
        var stored = Numbered(w, h);
        var placed = new Dictionary<int, Func<int, int, (int X, int Y)>>
        {
            [1] = (x, y) => (x, y),
            [2] = (x, y) => (w - 1 - x, y),
            [3] = (x, y) => (w - 1 - x, h - 1 - y),
            [4] = (x, y) => (x, h - 1 - y),
            [5] = (x, y) => (y, x),
            [6] = (x, y) => (h - 1 - y, x),
            [7] = (x, y) => (h - 1 - y, w - 1 - x),
            [8] = (x, y) => (y, w - 1 - x),
        };
        foreach (var (tag, place) in placed)
        {
            var shown = PhotoImport.Oriented(stored, PhotoOrientation.FromExif(tag));
            bool sideways = tag >= 5;
            Assert.Equal(sideways ? h : w, shown.Width);
            Assert.Equal(sideways ? w : h, shown.Height);
            for (int y = 0; y < h; y++)
            {
                for (int x = 0; x < w; x++)
                {
                    var (sx, sy) = place(x, y);
                    Assert.True(PixelAt(stored, x, y).SequenceEqual(PixelAt(shown, sx, sy)), $"tag {tag}: pixel ({x}, {y})");
                }
            }
        }
        Assert.Same(stored, PhotoImport.Oriented(stored, PhotoOrientation.Upright));
    }

    [Fact]
    public void APageFoundClearlyIsCorrectedWithoutAsking()
    {
        var photo = PhotoScenes.WoodScene();
        var detection = PhotoDocumentDetector.Detect(photo);
        Assert.True(detection.Confidence >= PhotoImport.SureConfidence, $"confidence {detection.Confidence:0.000}");
        var plan = PhotoImport.Plan(photo);
        Assert.Equal(PhotoImportAction.Correct, plan.Action);
        Assert.Equal(PhotoReviewReason.None, plan.Reason);
        // The page found, moved onto the photo's edges.
        Assert.Equal(QuadRefiner.Refine(photo, detection.Quad!.Value).Quad, plan.Corners);
        Assert.True(plan.Corners.MaxCornerDistance(detection.Quad!.Value) < 1, plan.Corners.ToString());
        Assert.Equal("", PhotoImport.ReasonText(plan.Reason));
    }

    [Fact]
    public void AnUnsurePageGoesToTheCornerEditorWithItsCorners()
    {
        var quad = new Quad(new PointD(40, 30), new PointD(300, 50), new PointD(290, 420), new PointD(30, 400));
        var unsure = new PhotoDocumentDetection(quad, PhotoImport.SureConfidence - 0.01, PhotoDocumentRejection.None, null, null, null);
        var plan = PhotoImport.Plan(unsure, 360, 480);
        Assert.Equal(PhotoImportAction.Review, plan.Action);
        Assert.Equal(PhotoReviewReason.Unsure, plan.Reason);
        Assert.Equal(quad, plan.Corners);
        var sure = unsure with { Confidence = PhotoImport.SureConfidence };
        Assert.Equal(PhotoImportAction.Correct, PhotoImport.Plan(sure, 360, 480).Action);
        // An outline seen but not taken is the editor's start too.
        var low = new PhotoDocumentDetection(null, 0, PhotoDocumentRejection.LowConfidence, quad, null, null);
        var lowPlan = PhotoImport.Plan(low, 360, 480);
        Assert.Equal((PhotoImportAction.Review, PhotoReviewReason.Unsure, quad), (lowPlan.Action, lowPlan.Reason, lowPlan.Corners));
    }

    [Fact]
    public void APageCutOffByTheFrameStartsFromWhatIsSeenWithinThePhoto()
    {
        var photo = PhotoScenes.CutOffScene();
        var plan = PhotoImport.Plan(photo);
        Assert.Equal(PhotoImportAction.Review, plan.Action);
        Assert.Equal(PhotoReviewReason.CutOff, plan.Reason);
        Assert.True(plan.Corners.IsInside(photo.Width, photo.Height), plan.Corners.ToString());
        Assert.True(PhotoImport.CanUseCorners(plan.Corners));
        Assert.NotEqual(PhotoImport.StartCorners(photo.Width, photo.Height), plan.Corners);
        Assert.NotEmpty(PhotoImport.ReasonText(plan.Reason));
    }

    [Fact]
    public void NoPageOrTwoPagesAskTheUser()
    {
        var plan = PhotoImport.Plan(PhotoDocumentDetection.Nothing, 360, 480);
        Assert.Equal((PhotoImportAction.Review, PhotoReviewReason.NothingFound), (plan.Action, plan.Reason));
        Assert.Equal(PhotoImport.StartCorners(360, 480), plan.Corners);
        Assert.Equal(new Quad(new PointD(36, 48), new PointD(324, 48), new PointD(324, 432), new PointD(36, 432)), plan.Corners);
        // A table with no page on it: nothing found, or nothing clear enough (the detector may answer either).
        foreach (var scene in new[] { PhotoScenes.NoPageScene(), PhotoScenes.PlainScene() })
        {
            var asked = PhotoImport.Plan(scene);
            Assert.Equal(PhotoImportAction.Review, asked.Action);
            Assert.Contains(asked.Reason, new[] { PhotoReviewReason.NothingFound, PhotoReviewReason.Unsure });
            Assert.True(PhotoImport.CanUseCorners(asked.Corners) && asked.Corners.IsInside(scene.Width, scene.Height));
        }
        var two = PhotoImport.Plan(PhotoScenes.TwoPagesScene());
        Assert.Equal((PhotoImportAction.Review, PhotoReviewReason.TwoPages), (two.Action, two.Reason));
        Assert.True(PhotoImport.CanUseCorners(two.Corners));
        foreach (var reason in new[] { PhotoReviewReason.Unsure, PhotoReviewReason.CutOff, PhotoReviewReason.TwoPages, PhotoReviewReason.NothingFound })
        {
            Assert.NotEmpty(PhotoImport.ReasonText(reason));
        }
    }

    [Fact]
    public void TheResolutionComesFromThePaperSizeElseItIsNominal()
    {
        Assert.Equal(282, PhotoImport.PageDpi(282.4));
        Assert.Equal(283, PhotoImport.PageDpi(282.5));
        Assert.Equal(200, PhotoImport.PageDpi(null));
        Assert.Equal(200, PhotoImport.PageDpi(double.NaN));
        Assert.Equal(200, PhotoImport.PageDpi(0));
        Assert.Equal(PhotoImport.MinDpi, PhotoImport.PageDpi(12));
        Assert.Equal(PhotoImport.MaxDpi, PhotoImport.PageDpi(5000));
        // A whole photo of A4's shape takes A4's resolution; a 4:3 photo is no known size.
        var a4 = PaperSizes.Inches(PaperSize.A4)!.Value;
        int longSide = 3508, shortSide = (int)Math.Floor(3508 * a4.Width / a4.Height + 0.5);
        Assert.Equal((int)Math.Floor(3508 / a4.Height + 0.5), PhotoImport.WholePhotoDpi(shortSide, longSide));
        Assert.Equal(PhotoImport.WholePhotoDpi(shortSide, longSide), PhotoImport.WholePhotoDpi(longSide, shortSide));
        Assert.Equal(200, PhotoImport.WholePhotoDpi(4032, 3024));
        Assert.Equal(200, PhotoImport.WholePhotoDpi(0, 10));
        // A corrected page takes the resolution of the paper size its shape matched.
        var photo = PhotoScenes.WoodScene();
        var plan = PhotoImport.Plan(photo);
        var correction = PerspectiveCorrector.Correct(photo, Quad.FromCorners(plan.Corners.Corners))!;
        Assert.Equal(PaperSize.A4, correction.Plan.Paper!.Size);
        var page = PhotoImport.CorrectedPage(photo, plan.Corners)!;
        Assert.Equal(PhotoImport.PageDpi(correction.Plan.Dpi), page.Dpi);
    }

    [Fact]
    public void APageFromAPhotoKeepsThePhotoAsItsOtherVersion()
    {
        var photo = PhotoScenes.WoodScene();
        var plan = PhotoImport.Plan(photo);
        var page = PhotoImport.CorrectedPage(photo, plan.Corners)!;
        var expected = PerspectiveCorrector.Correct(photo, Quad.FromCorners(plan.Corners.Corners))!.Image;
        Assert.Equal(PhotoScenes.Checksum(expected), PhotoScenes.Checksum(page.Image));
        Assert.Equal(PageSource.Photo, page.Source);
        Assert.Equal(ColorMode.Color, page.ColorMode);
        Assert.Equal(new PageGeometry(true, 0, GeometryBasis.Perspective) { Quad = Quad.FromCorners(plan.Corners.Corners) }, page.Geometry);
        Assert.Same(photo, page.Alternate!.Image);
        Assert.Null(page.Alternate.FilePath);
        Assert.True(page.CanSwapVersions);
        Assert.Equal("Photo", PhotoImport.SourceLabel(page));
        Assert.Equal("Corrected from photo", PageCorrections.Caption(page));
        Assert.Equal("Show as photographed", PageCorrections.ToggleLabel(page));

        var original = page.WithVersionsSwapped(photo);
        Assert.True(original.ShowsOriginal);
        Assert.Equal(PageSource.Photo, original.Source);
        Assert.Equal("As photographed", PageCorrections.Caption(original));
        Assert.Equal("Show corrected", PageCorrections.ToggleLabel(original));
        Assert.Equal("Page 2 is shown as photographed. It is saved that way.", PageCorrections.SwapNote(original, 2));
        var back = original.WithVersionsSwapped(page.Image);
        Assert.Equal("Page 2 is corrected again.", PageCorrections.SwapNote(back, 2));
        // The page's facts follow it through every change.
        Assert.Equal(PageSource.Photo, page.RotatedClockwise().Source);
        Assert.Equal(PageSource.Photo, page.WithInclusion(PageInclusion.Skip).Source);
        Assert.Equal(PageSource.Photo, page.TurnedUpright(2).Source);
        Assert.Equal(PageSource.Photo, new ScannedPage(page.Image, 300, ColorMode.Color).CopyMeta(page).Source);
    }

    [Fact]
    public void AWholePhotoIsLabelledAndHasNothingToSwap()
    {
        var photo = PhotoScenes.NoPageScene();
        var page = PhotoImport.WholePhotoPage(photo);
        Assert.Same(photo, page.Image);
        Assert.Equal(PageSource.Photo, page.Source);
        Assert.Equal(PhotoImport.WholePhotoDpi(photo.Width, photo.Height), page.Dpi);
        Assert.Null(page.Geometry);
        Assert.Null(page.Alternate);
        Assert.False(page.CanSwapVersions);
        Assert.Equal("Photo", PhotoImport.SourceLabel(page));
        Assert.Null(PageCorrections.Caption(page));
        Assert.Null(PhotoImport.SourceLabel(new ScannedPage(photo, 300, ColorMode.Color)));
        Assert.Equal(PageSource.Scanner, new ScannedPage(photo, 300, ColorMode.Color).Source);
    }

    [Fact]
    public void APageFromAPhoneIsLabelledAsSuch()
    {
        var page = new ScannedPage(PhotoScenes.NoPageScene(), 300, ColorMode.Color) { Source = PageSource.Phone };
        Assert.Equal("From phone", PhotoImport.SourceLabel(page));
        Assert.Equal("Sent from a paired phone", PhotoImport.SourceHelp(page));
        Assert.Equal("Imported from a photo", PhotoImport.SourceHelp(PhotoImport.WholePhotoPage(PhotoScenes.NoPageScene())));
        Assert.Null(PhotoImport.SourceHelp(new ScannedPage(page.Image, 300, ColorMode.Color)));
        // The page's source follows it through every change.
        Assert.Equal(PageSource.Phone, page.RotatedClockwise().Source);
        Assert.Equal(PageSource.Phone, page.WithInclusion(PageInclusion.Skip).Source);
        Assert.Equal(PageSource.Phone, new ScannedPage(page.Image, 300, ColorMode.Color).CopyMeta(page).Source);
    }

    [Fact]
    public void ThePhotosCornersAreNamedAgainBeforeThePageIsCutOut()
    {
        // Corners dragged around the outline, starting anywhere and either way round, cut out the same page.
        var photo = PhotoScenes.WoodScene();
        var quad = PhotoImport.Plan(photo).Corners;
        var expected = PhotoScenes.Checksum(PhotoImport.CorrectedPage(photo, quad)!.Image);
        var shifted = new Quad(quad.BottomRight, quad.BottomLeft, quad.TopLeft, quad.TopRight);
        Assert.Equal(expected, PhotoScenes.Checksum(PhotoImport.CorrectedPage(photo, shifted)!.Image));
        var reversed = new Quad(quad.TopLeft, quad.BottomLeft, quad.BottomRight, quad.TopRight);
        Assert.Equal(expected, PhotoScenes.Checksum(PhotoImport.CorrectedPage(photo, reversed)!.Image));
        var line = new Quad(new PointD(0, 0), new PointD(10, 0), new PointD(20, 0), new PointD(30, 0));
        Assert.Null(PhotoImport.CorrectedPage(photo, line));
    }

    [Fact]
    public void TheCornerEditorKeepsAnOutlineThePageCanBeCutOutAlong()
    {
        var quad = new Quad(new PointD(50, 50), new PointD(300, 60), new PointD(290, 400), new PointD(40, 380));
        var moved = PhotoImport.MovedCorner(quad, 1, new PointD(310, 40), 360, 480);
        Assert.Equal(new PointD(310, 40), moved.TopRight);
        Assert.Equal(quad.TopLeft, moved.TopLeft);
        // Dragged off the photo: kept on its edge.
        var outside = PhotoImport.MovedCorner(quad, 2, new PointD(500, 600), 360, 480);
        Assert.Equal(new PointD(360, 480), outside.BottomRight);
        // Across the outline (a bow tie) or onto another corner: refused.
        Assert.Equal(quad, PhotoImport.MovedCorner(quad, 0, new PointD(320, 420), 360, 480));
        Assert.Equal(quad, PhotoImport.MovedCorner(quad, 0, new PointD(295, 62), 360, 480));
        Assert.Equal(quad, PhotoImport.MovedCorner(quad, 0, new PointD(170, 380), 360, 480));
        // The index wraps like the quad's.
        Assert.Equal(new PointD(45, 385), PhotoImport.MovedCorner(quad, 7, new PointD(45, 385), 360, 480).BottomLeft);

        Assert.True(PhotoImport.CanUseCorners(quad));
        Assert.True(PhotoImport.CanUseCorners(PhotoImport.WholePhoto(360, 480)));
        Assert.False(PhotoImport.CanUseCorners(new Quad(new PointD(0, 0), new PointD(10, 0), new PointD(10, 10), new PointD(0, 10))));
        Assert.False(PhotoImport.CanUseCorners(new Quad(quad.TopLeft, quad.BottomLeft, quad.BottomRight, quad.TopRight)));
        // A guess partly off the photo is brought onto it.
        var off = new Quad(new PointD(-30, 20), new PointD(330, -10), new PointD(400, 500), new PointD(20, 470));
        Assert.Equal(new Quad(new PointD(0, 20), new PointD(330, 0), new PointD(360, 480), new PointD(20, 470)),
                     PhotoImport.ClampedToPhoto(off, 360, 480));
        var flat = new Quad(new PointD(-30, -20), new PointD(-10, -20), new PointD(-10, -5), new PointD(-30, -5));
        Assert.Equal(PhotoImport.StartCorners(360, 480), PhotoImport.ClampedToPhoto(flat, 360, 480));
    }

    [Fact]
    public void PhotoFilesAreTakenByTheirType()
    {
        Assert.True(PhotoImport.IsPhotoFile(@"C:\Photos\IMG_0042.JPG"));
        Assert.True(PhotoImport.IsPhotoFile("/Users/me/Desktop/scan.jpeg"));
        Assert.True(PhotoImport.IsPhotoFile("letter.HEIC"));
        Assert.True(PhotoImport.IsPhotoFile("page.png"));
        Assert.False(PhotoImport.IsPhotoFile("notes.txt"));
        Assert.False(PhotoImport.IsPhotoFile("report.pdf"));
        Assert.False(PhotoImport.IsPhotoFile("README"));
        Assert.False(PhotoImport.IsPhotoFile(@"C:\photos.jpg\README"));
        Assert.False(PhotoImport.IsPhotoFile("trailing."));
        Assert.True(PhotoImport.IsHeif("IMG_1.heic"));
        Assert.True(PhotoImport.IsHeif("IMG_1.HEIF"));
        Assert.False(PhotoImport.IsHeif("IMG_1.jpg"));
        Assert.Equal(["b.jpg", "a.PNG", "c.heic"],
                     PhotoImport.PhotoFiles(["b.jpg", "notes.txt", "a.PNG", "B.JPG", "c.heic", "a.png"]));
    }

    [Fact]
    public void PhotosAreImportedWhereTheQueueCollectsPages()
    {
        var document = new ScanSettings();
        Assert.True(PhotoImport.IsOffered(document));
        document.DocumentMultiPage = false;
        Assert.True(PhotoImport.IsOffered(document));
        Assert.False(PhotoImport.IsOffered(new ScanSettings { Intent = ScanIntent.Photo }));
        Assert.False(PhotoImport.IsOffered(TaskCatalog.Apply(ScanTask.IdCard, new ScanSettings())));
        Assert.False(PhotoImport.IsOffered(TaskCatalog.Apply(ScanTask.Receipt, new ScanSettings())));
        Assert.True(PhotoImport.IsOffered(TaskCatalog.Apply(ScanTask.Document, new ScanSettings())));
    }

    [Fact]
    public void PagesFromPhotosGoThroughTheCleanUpStageButAreNotCroppedAgain()
    {
        var s = new ScanSettings();
        s.Document.AutoCrop = true;
        s.Document.AutoStraighten = true;
        s.Document.SplitFacingPages = true;
        s.Document.SoftenSpineShadow = true;
        Assert.Equal(["blank", "separator"], PageProcessor.ForPhotoImport(s).Steps.Select(step => step.Name));
        s.Document.AutoRotate = true;
        s.Document.SplitMode = SplitMode.Barcode;
        s.Adjustments.Brightness = 0.2;
        s.ColorMode = ColorMode.Grayscale;
        var all = PageProcessor.ForPhotoImport(s, new StubScorer(true), new EmptyReader());
        Assert.Equal(["blank", "separator", "barcode", "orientation", "adjust"], all.Steps.Select(step => step.Name));
        Assert.Null(all.Book);
        Assert.Equal(["blank", "separator", "adjust"],
                     PageProcessor.ForPhotoImport(s, new StubScorer(false)).Steps.Select(step => step.Name));

        var photo = PhotoScenes.WoodScene();
        var page = PhotoImport.CorrectedPage(photo, PhotoImport.Plan(photo).Corners)!;
        var processed = PageProcessor.ForPhotoImport(s).Process([page]).Pages.Single();
        Assert.Equal(page.Id, processed.Id);
        Assert.NotNull(processed.Blank);
        Assert.Equal(ColorMode.Grayscale, processed.ColorMode);
        Assert.Equal(GeometryBasis.Perspective, processed.Geometry!.Basis);
        Assert.Equal(PageSource.Photo, processed.Source);
        // The photo as it was is adjusted too, so either version can be shown.
        Assert.Equal(photo.Width, processed.Alternate!.Image!.Width);
        Assert.NotSame(photo, processed.Alternate.Image);
    }

    [Fact]
    public void TheStatusTellsWhatTheImportDid()
    {
        Assert.Equal("Added 3 pages from photos — 5 in queue. Scan more or save PDF.",
                     PhotoImport.AddedMessage(3, 0, 0, 5, "save PDF"));
        Assert.Equal("Added 1 page from photos — 1 in queue. Scan more or save PDF. 1 photo was skipped. 2 photos could not be opened.",
                     PhotoImport.AddedMessage(1, 1, 2, 1, "save PDF"));
        Assert.Equal("No pages were added. 2 photos were skipped. 1 photo could not be opened.",
                     PhotoImport.AddedMessage(0, 2, 1, 0, "save PDF"));
        Assert.Equal("Cancelled.", PhotoImport.CancelledMessage(0, 3));
        Assert.Equal("Cancelled after adding 2 pages from photos — 4 in queue.", PhotoImport.CancelledMessage(2, 4));
        Assert.Equal("Photo 2 of 5", PhotoImport.Counter(2, 5, "IMG_0042.jpg"));
        Assert.Equal("Photo 2 of 5: IMG_0042.jpg", PhotoImport.CounterName(2, 5, "IMG_0042.jpg"));
        Assert.Equal("IMG_0042.jpg", PhotoImport.Counter(1, 1, "IMG_0042.jpg"));
        Assert.Equal("IMG_0042.jpg", PhotoImport.CounterName(1, 1, "IMG_0042.jpg"));
        Assert.Equal("Importing photo 2 of 5…", PhotoImport.ProgressMessage(2, 5));
        Assert.Equal("Importing photo…", PhotoImport.ProgressMessage(1, 1));
        // A TIFF of several pages: each page is imported, and named, in turn.
        Assert.Equal("Importing photo 2 of 5, page 3 of 7…", PhotoImport.ProgressMessage(2, 5, 3, 7));
        Assert.Equal("Importing page 3 of 7…", PhotoImport.ProgressMessage(1, 1, 3, 7));
        Assert.Equal("Importing photo 2 of 5…", PhotoImport.ProgressMessage(2, 5, 1, 1));
        Assert.Equal("fax.tif, page 2 of 5", PhotoImport.PageName("fax.tif", 2, 5));
        Assert.Equal("IMG_0042.jpg", PhotoImport.PageName("IMG_0042.jpg", 1, 1));
        Assert.Equal("Photo 2 of 3: fax.tif, page 2 of 5", PhotoImport.CounterName(2, 3, PhotoImport.PageName("fax.tif", 2, 5)));
        Assert.Equal("a.jpg could not be opened: it is damaged.", PhotoImport.UnreadableMessage("a.jpg", "it is damaged."));
        Assert.StartsWith("IMG_1.heic could not be opened: HEIC photos need the free “HEIF Image Extensions”", PhotoImport.HeifUnavailableMessage("IMG_1.heic"));
    }

    [Fact]
    public void TheImportAndTheCornerEditor_SayLittle()
    {
        Assert.Equal("Import photos of documents…", PhotoImport.ButtonLabel);
        Assert.Equal("Add phone photos of documents as pages", PhotoImport.ButtonHint);
        Assert.Equal("Each page is found in the photo and straightened. Your photo files are not changed.", PhotoImport.ButtonHelp);
        Assert.Equal(("or drop them here", "Drop to add as pages"), (PhotoImport.DropHint, PhotoImport.DropOverlay));
        Assert.Equal("Check the corners", PhotoImport.EditorTitle);
        Assert.Equal("Drag each corner onto a corner of the page.", PhotoImport.EditorHelp);
        Assert.Equal("Keys 1–4 select a corner. Arrow keys move it; Shift takes bigger steps.", PhotoImport.EditorKeys);
        Assert.Equal(("Use corners", "Use whole photo", "Skip photo"),
                     (PhotoImport.UseCornersLabel, PhotoImport.WholePhotoLabel, PhotoImport.SkipLabel));
        Assert.Equal("The page edges are unclear.", PhotoImport.ReasonText(PhotoReviewReason.Unsure));
        Assert.Equal("No page found in this photo.", PhotoImport.ReasonText(PhotoReviewReason.NothingFound));
        Assert.Equal("The page runs off the photo.", PhotoImport.ReasonText(PhotoReviewReason.CutOff));
        Assert.Equal("Two pages found: pick one.", PhotoImport.ReasonText(PhotoReviewReason.TwoPages));
        Assert.Equal("", PhotoImport.ReasonText(PhotoReviewReason.None));
        foreach (var reason in Enum.GetValues<PhotoReviewReason>())
        {
            Assert.InRange(StatusLine.Words(PhotoImport.ReasonText(reason)), 0, 6);
        }
    }

    [Fact]
    public void TheCornerEditor_NamesWhatIsCutOut()
    {
        Assert.Equal(PhotoImport.EditorHelp, PhotoImport.CornersHelp(CaptureKind.Document));
        Assert.Equal("Drag each corner onto a corner of the receipt.", PhotoImport.CornersHelp(CaptureKind.Receipt));
        Assert.Equal("Drag each corner onto a corner of the photo.", PhotoImport.CornersHelp(CaptureKind.Photo));
        Assert.Equal("Drag each corner onto a corner of the card.", PhotoImport.CornersHelp(CaptureKind.IdCard));
        Assert.Equal("Page corners", PhotoImport.CornersName(CaptureKind.Document));
        Assert.Equal("Receipt corners", PhotoImport.CornersName(CaptureKind.Receipt));
        Assert.Equal("Photo corners", PhotoImport.CornersName(CaptureKind.Photo));
        Assert.Equal("Card corners", PhotoImport.CornersName(CaptureKind.IdCard));
        // A card that did not measure as ID-1 is unsure: its note speaks of the outline, not of the page's edges.
        Assert.Equal("The card's outline is not certain.", PhotoImport.ReasonText(PhotoReviewReason.Unsure, CaptureKind.IdCard));
        Assert.Equal("The card runs off the photo.", PhotoImport.ReasonText(PhotoReviewReason.CutOff, CaptureKind.IdCard));
        Assert.Equal("No card found in this photo.", PhotoImport.ReasonText(PhotoReviewReason.NothingFound, CaptureKind.IdCard));
        Assert.Equal("The photo's edges are unclear.", PhotoImport.ReasonText(PhotoReviewReason.Unsure, CaptureKind.Photo));
        Assert.Equal("No photo found in this shot.", PhotoImport.ReasonText(PhotoReviewReason.NothingFound, CaptureKind.Photo));
        Assert.Equal("The receipt's edges are unclear.", PhotoImport.ReasonText(PhotoReviewReason.Unsure, CaptureKind.Receipt));
        Assert.Equal("No receipt found in this shot.", PhotoImport.ReasonText(PhotoReviewReason.NothingFound, CaptureKind.Receipt));
        foreach (var reason in Enum.GetValues<PhotoReviewReason>())
        {
            Assert.Equal(PhotoImport.ReasonText(reason), PhotoImport.ReasonText(reason, CaptureKind.Document));
            foreach (var kind in Enum.GetValues<CaptureKind>())
            {
                Assert.InRange(StatusLine.Words(PhotoImport.ReasonText(reason, kind)), 0, 6);
            }
        }
        // Fix crop gives no reason, whatever it cuts out.
        foreach (var kind in Enum.GetValues<CaptureKind>())
        {
            Assert.Equal("", PhotoImport.ReasonText(PhotoReviewReason.None, kind));
        }
    }

    [Fact]
    public void TheStatusAfterAScanLeavesPagesFromPhotosToTheImport()
    {
        var photo = PhotoScenes.WoodScene();
        var fromPhoto = PhotoImport.CorrectedPage(photo, PhotoImport.Plan(photo).Corners)!;
        var scanned = new ScannedPage(photo, 300, ColorMode.Color).WithGeometry(photo, new PageGeometry(true, 2.4, GeometryBasis.PageEdges));
        Assert.Equal("", PageCorrections.ScanNote([fromPhoto]));
        Assert.Equal(" 1 cropped and straightened.", PageCorrections.ScanNote([fromPhoto, scanned]));
        Assert.Equal("Corrected from photo", new PageGeometry(true, 0, GeometryBasis.Perspective).Caption);
        Assert.Equal("As scanned", PageCorrections.Caption(scanned.WithVersionsSwapped(photo)));
    }
}
