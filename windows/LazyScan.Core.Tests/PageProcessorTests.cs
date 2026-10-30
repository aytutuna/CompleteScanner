using LazyScan.Core;
using Xunit;

namespace LazyScan.Core.Tests;

// Twin of Tests/LazyScanTests/PageProcessorTests.swift: the clean-up stage, which pages
// are saved, and the page facts every rebuild keeps.

public class PageProcessorTests
{
    private static readonly RgbaImage BlankImage = TestPages.Enlarged(TestPages.NoisyBlank(), 1);
    private static readonly RgbaImage TextImage = TestPages.Enlarged(TestPages.OneTextLine(), 1);
    /// <summary>A 6 × 8 in sheet lying at -4° on a dark backdrop, scanned at 100 dpi.</summary>
    private static readonly RgbaImage SheetImage =
        TestPages.SheetOnBackdrop(TestPages.Minus4, 30, 240, 0, 0x5EE70002).ToRgba();

    private static ScannedPage Page(RgbaImage image) => new(image, 100, ColorMode.Color);

    private static ScannedPage Checked(bool blank, PageInclusion inclusion = PageInclusion.Automatic) =>
        Page(BlankImage).WithBlank(new BlankPageResult(blank ? 0.00005 : 0.002, blank ? 1 : 40, false, blank))
                        .WithInclusion(inclusion);

    private static DocumentOptions Options(bool remove, BlankSensitivity sensitivity = BlankSensitivity.Medium) =>
        new() { RemoveBlankPages = remove, BlankSensitivity = sensitivity };

    /// <summary>A step that records the pages it saw and marks each by turning it.</summary>
    private sealed class RecordingStep(string name, List<string> log) : IPageStep
    {
        public string Name => name;
        public ScannedPage Apply(ScannedPage page)
        {
            log.Add($"{name}:{page.Id}");
            return page.WithImage(page.Image.RotatedQuarterTurns(1));
        }
    }

    // MARK: - The steps a scan gets

    [Fact]
    public void ForScan_DocumentQueue_ChecksBlankPagesWhetherOrNotTheyAreSkipped()
    {
        foreach (bool remove in new[] { false, true })
        {
            var s = new ScanSettings();
            s.Document.RemoveBlankPages = remove;
            s.Document.BlankSensitivity = BlankSensitivity.High;
            var processor = PageProcessor.ForScan(s);
            Assert.Equal(["blank", "separator"], processor.Steps.Select(step => step.Name));
            Assert.Equal(BlankSensitivity.High, ((BlankDetectionStep)processor.Steps[0]).Options.Sensitivity);
        }
    }

    [Fact]
    public void ForScan_AdjustmentsComeAfterTheBlankCheck_OnlyWhenTheyChangeSomething()
    {
        var s = new ScanSettings();
        s.Adjustments.Brightness = 0.25;
        Assert.Equal(["blank", "separator", "adjust"], PageProcessor.ForScan(s).Steps.Select(step => step.Name));
        var gray = new ScanSettings { ColorMode = ColorMode.Grayscale };
        Assert.Equal(["blank", "separator", "adjust"], PageProcessor.ForScan(gray).Steps.Select(step => step.Name));
        var adjust = (AdjustmentStep)PageProcessor.ForScan(gray).Steps[2];
        Assert.Equal(ColorMode.Grayscale, adjust.ColorMode);
    }

    [Fact]
    public void ForScan_PhotosAndPagesSavedAtOnce_AreNotChecked()
    {
        var photos = new ScanSettings { Intent = ScanIntent.Photo };
        Assert.Empty(PageProcessor.ForScan(photos).Steps);
        Assert.False(PageProcessor.ChecksBlankPages(photos));
        var atOnce = new ScanSettings { DocumentMultiPage = false };
        atOnce.Document.RemoveBlankPages = true;
        Assert.Empty(PageProcessor.ForScan(atOnce).Steps);
        Assert.False(PageProcessor.ChecksBlankPages(atOnce));
        Assert.True(PageProcessor.ChecksBlankPages(new ScanSettings()));
        // Quick scan saves every scan at once.
        var quick = TaskCatalog.Apply(ScanTask.QuickScan, new ScanSettings());
        Assert.False(PageProcessor.ChecksBlankPages(quick));
    }

    [Fact]
    public void ForScan_CropAndStraighten_ComeBetweenTheBlankCheckAndTheAdjustments()
    {
        var s = new ScanSettings();
        Assert.False(PageProcessor.CorrectsGeometry(s));
        s.Document.AutoStraighten = true;
        s.Adjustments.Brightness = 0.25;
        Assert.True(PageProcessor.CorrectsGeometry(s));
        var processor = PageProcessor.ForScan(s);
        Assert.Equal(["blank", "geometry", "separator", "adjust"], processor.Steps.Select(step => step.Name));
        var step = (GeometryStep)processor.Steps[1];
        Assert.Equal((false, true), (step.Crop, step.Straighten));
        s.Document.AutoCrop = true;
        s.Document.AutoStraighten = false;
        Assert.Equal((true, false), (((GeometryStep)PageProcessor.ForScan(s).Steps[1]).Crop, ((GeometryStep)PageProcessor.ForScan(s).Steps[1]).Straighten));
    }

    /// <summary>Text recognition that can or cannot run, reading nothing.</summary>
    private sealed class StubScorer(bool available) : IOrientationScorer
    {
        public bool IsAvailable => available;
        public OrientationScore Score(RgbaImage image, CancellationToken token) => OrientationScore.None;
    }

    [Fact]
    public void ForScan_RotatePagesUpright_ReadsAfterTheSeparatorCheck_WhenTextCanBeRead()
    {
        var s = new ScanSettings();
        var scorer = new StubScorer(true);
        Assert.False(PageProcessor.TurnsPagesUpright(s));
        Assert.Equal(["blank", "separator"], PageProcessor.ForScan(s, scorer: scorer).Steps.Select(step => step.Name));
        s.Document.AutoRotate = true;
        Assert.True(PageProcessor.TurnsPagesUpright(s));
        var processor = PageProcessor.ForScan(s, scorer: scorer);
        Assert.Equal(["blank", "separator", "orientation"], processor.Steps.Select(step => step.Name));
        Assert.Same(scorer, ((OrientationStep)processor.Steps[2]).Scorer);
        Assert.Equal(OrientationDecision.MaxSecondsPerPage, ((OrientationStep)processor.Steps[2]).MaxSeconds);
        // It knows the split, so barcode or QR separator sheets are not read (BarcodeSeparators.IsSeparatorPage).
        Assert.Equal(s.Document, ((OrientationStep)processor.Steps[2]).Split);
        s.Document.AutoStraighten = true;
        s.Adjustments.Brightness = 0.25;
        Assert.Equal(["blank", "geometry", "separator", "orientation", "adjust"],
                     PageProcessor.ForScan(s, scorer: scorer).Steps.Select(step => step.Name));
        // No text recognition: the pages are not turned.
        Assert.DoesNotContain("orientation", PageProcessor.ForScan(s).Steps.Select(step => step.Name));
        Assert.DoesNotContain("orientation", PageProcessor.ForScan(s, scorer: new StubScorer(false)).Steps.Select(step => step.Name));
        // Pages saved at once, and photos, are never turned unseen.
        foreach (var other in new[] { new ScanSettings { Intent = ScanIntent.Photo }, new ScanSettings { DocumentMultiPage = false } })
        {
            other.Document.AutoRotate = true;
            Assert.False(PageProcessor.TurnsPagesUpright(other));
            Assert.DoesNotContain("orientation", PageProcessor.ForScan(other, scorer: scorer).Steps.Select(step => step.Name));
        }
    }

    /// <summary>A step that records the token it was handed.</summary>
    private sealed class TokenStep : ICancellablePageStep
    {
        public List<CancellationToken> Tokens { get; } = [];
        public string Name => "token";
        public ScannedPage Apply(ScannedPage page) => throw new InvalidOperationException("Process hands the token on.");
        public ScannedPage Apply(ScannedPage page, CancellationToken token)
        {
            Tokens.Add(token);
            return page;
        }
    }

    [Fact]
    public void Process_HandsTheTokenToStepsThatCanStopPartWay()
    {
        using var source = new CancellationTokenSource();
        var step = new TokenStep();
        new PageProcessor([step]).Process([Page(BlankImage), Page(TextImage)], source.Token);
        Assert.Equal([source.Token, source.Token], step.Tokens);
    }

    [Fact]
    public void ForScan_SeparatorSheets_AreLookedForOnCollectedDocumentPages_WhetherOrNotTheStackIsSplit()
    {
        foreach (var mode in SplitModes.DisplayOrder)
        {
            var s = new ScanSettings();
            s.Document.SplitMode = mode;
            Assert.Contains("separator", PageProcessor.ForScan(s).Steps.Select(step => step.Name));
        }
        foreach (var s in new[] { new ScanSettings { Intent = ScanIntent.Photo }, new ScanSettings { DocumentMultiPage = false } })
        {
            s.Document.SplitMode = SplitMode.SeparatorSheet;
            Assert.DoesNotContain("separator", PageProcessor.ForScan(s).Steps.Select(step => step.Name));
        }
        // The check records the code and keeps every other fact of the page.
        var page = new ScannedPage(PatchCodeDetector.RenderSheet(PatchCode.Patch2, 8.5, 11, 150).ToRgba(), 150, ColorMode.Color)
            .WithSide(PageSide.Front, 3).WithInclusion(PageInclusion.Keep);
        var processed = PageProcessor.ForScan(new ScanSettings()).Process([page]).Pages[0];
        Assert.Equal(PatchCode.Patch2, processed.Patch);
        Assert.Equal((PageSide.Front, 3, PageInclusion.Keep), (processed.Side, processed.SheetIndex, processed.Inclusion));
        Assert.False(processed.Blank!.IsBlank);
    }

    [Fact]
    public void ForScan_PhotosAndPagesSavedAtOnce_AreNeverCroppedOrStraightened()
    {
        foreach (var s in new[] { new ScanSettings { Intent = ScanIntent.Photo }, new ScanSettings { DocumentMultiPage = false } })
        {
            s.Document.AutoCrop = true;
            s.Document.AutoStraighten = true;
            Assert.False(PageProcessor.CorrectsGeometry(s));
            Assert.DoesNotContain("geometry", PageProcessor.ForScan(s).Steps.Select(step => step.Name));
        }
    }

    [Fact]
    public void ForScan_TakesTheBackBindingAndArrangement()
    {
        var s = new ScanSettings { BackBinding = DuplexBinding.ShortEdge };
        var processor = PageProcessor.ForScan(s, ScanArrangement.TurnedOverBacks);
        Assert.Equal((ScanArrangement.TurnedOverBacks, DuplexBinding.ShortEdge), (processor.Arrangement, processor.Binding));
        Assert.Equal(ScanArrangement.AsScanned, PageProcessor.ForScan(s).Arrangement);
    }

    // MARK: - Processing

    [Fact]
    public void Process_RecordsWhichPagesLookBlank_PixelsUnchanged()
    {
        var pages = new[] { Page(TextImage), Page(BlankImage) };
        var result = PageProcessor.ForScan(new ScanSettings()).Process(pages);
        Assert.Equal(pages.Select(p => p.Id), result.Pages.Select(p => p.Id));
        Assert.Equal([false, true], result.Pages.Select(p => p.Blank!.IsBlank));
        Assert.Same(pages[1].Image, result.Pages[1].Image);
        Assert.Equal(1, result.BlankCount);
        // The arranged pages are the pages as scanned, before any step.
        Assert.Same(pages[0], result.Arranged[0]);
        Assert.Null(result.Arranged[1].Blank);
    }

    [Fact]
    public void Process_ChecksThePageAsScanned_BeforeTheAdjustments()
    {
        // The result is that of the page as scanned, not of the adjusted pixels. The adjustments
        // turn the paper black on both platforms (Core Image adjusts in linear light, this pipeline
        // in sRGB values, so milder ones can leave a thresholded text page looking the same).
        var s = new ScanSettings { ColorMode = ColorMode.BlackWhite };
        s.Adjustments.Brightness = -1;
        s.Adjustments.BlackWhiteThreshold = 0.7;
        var scanned = Page(TextImage);
        var result = PageProcessor.ForScan(s).Process([scanned]);
        Assert.Equal(BlankPageDetector.Analyze(TextImage, 100), result.Pages[0].Blank);
        Assert.NotEqual(TextImage.Pixels, result.Pages[0].Image.Pixels);
        Assert.NotEqual(BlankPageDetector.Analyze(result.Pages[0].Image, 100), result.Pages[0].Blank);
        Assert.Equal(ColorMode.BlackWhite, result.Pages[0].ColorMode);
    }

    [Fact]
    public void Process_AStepAfterTheCheck_DoesNotChangeItsResult()
    {
        // A step that prints a bar over a blank page: the check before it still saw a blank page.
        var bar = new BarStep();
        var processor = new PageProcessor([new BlankDetectionStep(new BlankPageOptions()), bar]);
        var result = processor.Process([Page(BlankImage)]);
        Assert.True(result.Pages[0].Blank!.IsBlank);
        Assert.False(BlankPageDetector.Analyze(result.Pages[0].Image, 100).IsBlank);
    }

    private sealed class BarStep : IPageStep
    {
        public string Name => "bar";
        public ScannedPage Apply(ScannedPage page)
        {
            var image = page.Image.Clone();
            for (int y = 500; y < 520; y++)
            {
                for (int x = 100; x < 700; x++)
                {
                    int i = (y * image.Width + x) * 4;
                    image.Pixels[i] = 0;
                    image.Pixels[i + 1] = 0;
                    image.Pixels[i + 2] = 0;
                }
            }
            return page.WithImage(image);
        }
    }

    [Fact]
    public void Process_TwoSided_ArrangesLikeDocumentSides_ThenRunsTheSteps()
    {
        var scanned = Enumerable.Range(0, 4).Select(_ => Page(RgbaImage.Filled(4, 6, 255, 255, 255))).ToList();
        var processor = PageProcessor.ForScan(new ScanSettings { BackBinding = DuplexBinding.ShortEdge }, ScanArrangement.TwoSided);
        var result = processor.Process(scanned);
        var expected = DocumentSides.ArrangeTwoSided(scanned, DuplexBinding.ShortEdge);
        Assert.Equal(expected.Select(p => (p.Id, p.Side, p.SheetIndex, p.RotationQuarterTurns)),
                     result.Arranged.Select(p => (p.Id, p.Side, p.SheetIndex, p.RotationQuarterTurns)));
        Assert.Equal(expected.Select(p => (p.Id, p.Side, p.SheetIndex)),
                     result.Pages.Select(p => (p.Id, p.Side, p.SheetIndex)));
        Assert.All(result.Pages, p => Assert.NotNull(p.Blank));
    }

    [Fact]
    public void Process_TurnedOver_MarksTheSide()
    {
        var scanned = new[] { Page(BlankImage), Page(TextImage) };
        var fronts = new PageProcessor([], ScanArrangement.TurnedOverFronts).Process(scanned);
        Assert.Equal(DocumentSides.MarkManual(scanned, PageSide.Front, DuplexBinding.LongEdge).Select(p => (p.Side, p.SheetIndex)),
                     fronts.Pages.Select(p => (p.Side, p.SheetIndex)));
        var backs = new PageProcessor([], ScanArrangement.TurnedOverBacks).Process(scanned);
        Assert.All(backs.Pages, p => Assert.Equal(PageSide.Back, p.Side));
    }

    [Fact]
    public void Process_Camera_MarksTheSide_WithoutTurningForTheBinding()
    {
        var left = TwoTone(6, 4);
        var scanned = new[] { Page(left), Page(left).WithSide(null, 2) };
        foreach (var binding in new[] { DuplexBinding.LongEdge, DuplexBinding.ShortEdge })
        {
            var backs = new PageProcessor([], ScanArrangement.CameraBack, binding).Process(scanned);
            Assert.Equal([(PageSide.Back, (int?)null), (PageSide.Back, 2)], backs.Pages.Select(p => (p.Side!.Value, p.SheetIndex)));
            // As taken: red still on the left, no turn waiting for the save.
            Assert.All(backs.Arranged, p => Assert.Equal((left.Pixels, 0), (p.Image.Pixels, p.RotationQuarterTurns)));
            var fronts = new PageProcessor([], ScanArrangement.CameraFront, binding).Process(scanned);
            Assert.All(fronts.Pages, p => Assert.Equal(PageSide.Front, p.Side));
        }
        // A stack turned over by hand, by contrast, has its short-edge backs turned.
        var turned = new PageProcessor([], ScanArrangement.TurnedOverBacks, DuplexBinding.ShortEdge).Process(scanned);
        Assert.All(turned.Arranged, p => Assert.NotEqual(left.Pixels, p.Image.Pixels));
        Assert.Equal(ScanArrangement.CameraBack, PageProcessor.ForCapture(new ScanSettings(), arrangement: ScanArrangement.CameraBack).Arrangement);
        Assert.Equal(ScanArrangement.AsScanned, PageProcessor.ForCapture(new ScanSettings()).Arrangement);
    }

    [Fact]
    public void Process_RunsEveryStepOnEveryPage_InOrder()
    {
        var log = new List<string>();
        var pages = new[] { Page(RgbaImage.Filled(2, 3, 0, 0, 0)), Page(RgbaImage.Filled(2, 3, 0, 0, 0)) };
        var processor = new PageProcessor([new RecordingStep("one", log), new RecordingStep("two", log)]);
        var result = processor.Process(pages);
        Assert.Equal([$"one:{pages[0].Id}", $"two:{pages[0].Id}", $"one:{pages[1].Id}", $"two:{pages[1].Id}"], log);
        // Two quarter turns: the steps' results were passed on.
        Assert.All(result.Pages, p => Assert.Equal((2, 3), (p.Image.Width, p.Image.Height)));
        Assert.Empty(new PageProcessor([]).Process([]).Pages);
    }

    [Fact]
    public void Process_StopsWhenCancelled()
    {
        using var cancelled = new CancellationTokenSource();
        cancelled.Cancel();
        Assert.ThrowsAny<OperationCanceledException>(
            () => PageProcessor.ForScan(new ScanSettings()).Process([Page(BlankImage)], cancelled.Token));
    }

    [Fact]
    public void Process_CropsAndStraightens_KeepingThePageAsScanned()
    {
        var s = new ScanSettings();
        s.Document.AutoCrop = true;
        s.Document.AutoStraighten = true;
        var scanned = Page(SheetImage);
        var result = PageProcessor.ForScan(s).Process([scanned]);
        var page = result.Pages[0];
        Assert.Equal(scanned.Id, page.Id);
        Assert.NotNull(page.Geometry);
        Assert.True(page.Geometry.Cropped);
        Assert.InRange(page.Geometry.AngleDegrees, TestPages.Minus4.Degrees - 0.3, TestPages.Minus4.Degrees + 0.3);
        Assert.False(page.ShowsOriginal);
        Assert.True(page.CanSwapVersions);
        Assert.Same(SheetImage, page.Alternate!.Image);
        Assert.InRange(page.Image.Width, TestPages.SheetWidth - 4, TestPages.SheetWidth + 2);
        // The blank check ran on the page as scanned.
        Assert.False(page.Blank!.IsBlank);
        Assert.Equal(" 1 cropped and straightened.", PageCorrections.ScanNote(result.Pages));
    }

    [Fact]
    public void Process_PageItIsNotSureAbout_StaysAsScanned()
    {
        var s = new ScanSettings();
        s.Document.AutoCrop = true;
        s.Document.AutoStraighten = true;
        var scanned = Page(BlankImage);
        var page = PageProcessor.ForScan(s).Process([scanned]).Pages[0];
        Assert.Same(scanned.Image, page.Image);
        Assert.Null(page.Geometry);
        Assert.Null(page.Alternate);
        Assert.False(page.CanSwapVersions);
        Assert.Equal("", PageCorrections.ScanNote([page]));
    }

    [Fact]
    public void AdjustmentStep_AdjustsBothVersions()
    {
        var s = new ScanSettings { ColorMode = ColorMode.Grayscale };
        s.Document.AutoCrop = true;
        s.Document.AutoStraighten = true;
        var page = PageProcessor.ForScan(s).Process([Page(SheetImage)]).Pages[0];
        Assert.Equal(ColorMode.Grayscale, page.ColorMode);
        Assert.Equal(ImagePipeline.Apply(s.Adjustments, SheetImage, ColorMode.Grayscale).Pixels, page.Alternate!.Image!.Pixels);
        Assert.NotNull(page.Geometry);
    }

    // MARK: - Showing a page as scanned

    private static ScannedPage Corrected() =>
        Page(SheetImage).WithSide(PageSide.Front, 1).WithBlank(new BlankPageResult(0.01, 50, false, false))
                        .WithGeometry(RgbaImage.Filled(60, 80, 200, 200, 200), new PageGeometry(true, -4, GeometryBasis.PageEdges));

    [Fact]
    public void WithVersionsSwapped_ShowsThePageAsScanned_AndBackAgain()
    {
        var page = Corrected();
        var original = page.WithVersionsSwapped(page.Alternate!.Image!);
        Assert.True(original.ShowsOriginal);
        Assert.Same(SheetImage, original.Image);
        Assert.Equal(page.Id, original.Id);
        Assert.Equal(page.Geometry, original.Geometry);
        Assert.Equal((PageSide.Front, 1), (original.Side, original.SheetIndex));
        Assert.Equal(page.Blank, original.Blank);
        Assert.Same(page.Image, original.Alternate!.Image);
        var back = original.WithVersionsSwapped(original.Alternate.Image!);
        Assert.False(back.ShowsOriginal);
        Assert.Same(page.Image, back.Image);
        Assert.Same(SheetImage, back.Alternate!.Image);
        // A page with no other version stays as it is.
        var plain = Page(BlankImage);
        Assert.Same(plain, plain.WithVersionsSwapped(TextImage));
    }

    [Fact]
    public void WithVersionsSwapped_SpooledVersions_SwapFilesAndDropThePixelsOfTheHiddenOne()
    {
        var corrected = Corrected().WithImage(RgbaImage.Filled(6, 8, 1, 1, 1), filePath: "corrected.png", fullPixelSize: new SizeD(60, 80))
                                   .WithAlternate(new PageVersion(null, "original.png", new SizeD(850, 1100)));
        var preview = RgbaImage.Filled(85, 110, 2, 2, 2);
        var original = corrected.WithVersionsSwapped(preview);
        Assert.Equal(("original.png", new SizeD(850, 1100)), (original.FilePath, original.FullPixelSize));
        Assert.Same(preview, original.Image);
        Assert.Equal(new PageVersion(null, "corrected.png", new SizeD(60, 80)), original.Alternate);
    }

    [Fact]
    public void RotatedClockwise_TurnsTheOtherVersionToo()
    {
        var page = Corrected();
        var turned = page.RotatedClockwise();
        Assert.Equal(1, turned.RotationQuarterTurns);
        Assert.Equal((SheetImage.Height, SheetImage.Width), (turned.Alternate!.Image!.Width, turned.Alternate.Image.Height));
        Assert.Equal(SheetImage.RotatedQuarterTurns(1).Pixels, turned.Alternate.Image.Pixels);
        Assert.Equal(page.Geometry, turned.Geometry);
        // A spooled other version has no pixels to turn: its file is turned when it is saved.
        var spooled = page.WithAlternate(new PageVersion(null, "original.png", new SizeD(850, 1100)));
        Assert.Equal(spooled.Alternate, spooled.RotatedClockwise().Alternate);
    }

    [Fact]
    public void Geometry_SurvivesRebuildingThePage_TheOtherVersionStaysWithItsPixels()
    {
        var page = Corrected().WithVersionsSwapped(SheetImage);
        foreach (var rebuilt in new[]
                 {
                     page.WithImage(RgbaImage.Filled(3, 3, 0, 0, 0)),
                     page.WithSide(PageSide.Back, 0),
                     page.WithBlank(null),
                     page.WithInclusion(PageInclusion.Skip),
                 })
        {
            Assert.Equal(page.Geometry, rebuilt.Geometry);
            Assert.True(rebuilt.ShowsOriginal);
            Assert.Same(page.Alternate, rebuilt.Alternate);
        }
        // CopyMeta takes the source's facts and keeps this page's other version.
        var other = Page(TextImage).CopyMeta(page);
        Assert.Equal((page.Geometry, true), (other.Geometry, other.ShowsOriginal));
        Assert.Null(other.Alternate);
        Assert.Null(Page(TextImage).Geometry);
    }

    [Fact]
    public void PageCorrections_SayWhatWasDone_AndWhatOneClickDoes()
    {
        var page = Corrected();
        Assert.Equal("Cropped and straightened 4.0°", PageCorrections.Caption(page));
        Assert.Equal("Show as scanned", PageCorrections.ToggleLabel(page));
        Assert.Equal("Page 2 is cropped and straightened again.", PageCorrections.SwapNote(page, 2));
        var original = page.WithVersionsSwapped(SheetImage);
        Assert.Equal("As scanned", PageCorrections.Caption(original));
        Assert.Equal("Show cropped and straightened", PageCorrections.ToggleLabel(original));
        Assert.Equal("Page 2 is shown as scanned. It is saved that way.", PageCorrections.SwapNote(original, 2));
        var straightened = Page(SheetImage).WithGeometry(SheetImage, new PageGeometry(false, 1.25, GeometryBasis.TextLines));
        Assert.Equal("Straightened 1.3°", PageCorrections.Caption(straightened));
        Assert.Equal("Show straightened", PageCorrections.ToggleLabel(straightened.WithVersionsSwapped(SheetImage)));
        var cropped = Page(SheetImage).WithGeometry(SheetImage, new PageGeometry(true, 0, GeometryBasis.PageEdges));
        Assert.Equal("Cropped", PageCorrections.Caption(cropped));
        Assert.Null(PageCorrections.Caption(Page(BlankImage)));
        Assert.Null(PageCorrections.ToggleLabel(Page(BlankImage)));
        Assert.Null(PageCorrections.ToggleLabel(cropped.WithAlternate(null)));
        Assert.Equal(" 2 straightened.", PageCorrections.ScanNote([straightened, straightened, Page(BlankImage)]));
        Assert.Equal(" 2 cropped or straightened.", PageCorrections.ScanNote([straightened, cropped]));
        Assert.Equal("", PageCorrections.ScanNote([original]));
    }

    // MARK: - Which pages are saved

    [Fact]
    public void IsExcluded_FollowsTheSetting_UnlessTheUserDecided()
    {
        var on = Options(true);
        var off = Options(false);
        Assert.True(PageFilter.IsExcluded(Checked(true), on));
        Assert.False(PageFilter.IsExcluded(Checked(true), off));
        Assert.False(PageFilter.IsExcluded(Checked(false), on));
        Assert.False(PageFilter.IsExcluded(Page(BlankImage), on));            // never checked
        Assert.False(PageFilter.IsExcluded(Checked(true, PageInclusion.Keep), on));
        Assert.True(PageFilter.IsExcluded(Checked(false, PageInclusion.Skip), off));
        Assert.True(PageFilter.IsExcluded(Checked(true, PageInclusion.Skip), off));
    }

    [Fact]
    public void LooksBlank_UsesTheSensitivityOfNow()
    {
        // 0.02 % ink: blank at Medium and High, not at Low.
        var page = Page(BlankImage).WithBlank(new BlankPageResult(0.0002, 2, false, true));
        Assert.True(PageFilter.LooksBlank(page, BlankSensitivity.Medium));
        Assert.False(PageFilter.LooksBlank(page, BlankSensitivity.Low));
        Assert.False(PageFilter.IsExcluded(page, Options(true, BlankSensitivity.Low)));
        var dark = Page(BlankImage).WithBlank(new BlankPageResult(0, 0, true, false));
        Assert.False(PageFilter.LooksBlank(dark, BlankSensitivity.High));
    }

    [Fact]
    public void Toggled_FlipsWhatSavingDoes_AndTwoClicksUndoOne()
    {
        foreach (bool remove in new[] { false, true })
        {
            var options = Options(remove);
            foreach (var start in new[] { Checked(true), Checked(false) })
            {
                bool before = PageFilter.IsExcluded(start, options);
                var once = start.WithInclusion(PageFilter.Toggled(start, options));
                Assert.Equal(!before, PageFilter.IsExcluded(once, options));
                var twice = once.WithInclusion(PageFilter.Toggled(once, options));
                Assert.Equal(before, PageFilter.IsExcluded(twice, options));
                Assert.Equal(PageInclusion.Automatic, twice.Inclusion);
            }
        }
        Assert.Equal(PageInclusion.Keep, PageFilter.Toggled(Checked(true), Options(true)));
        Assert.Equal(PageInclusion.Skip, PageFilter.Toggled(Checked(true), Options(false)));
    }

    [Fact]
    public void PagesToSave_LeavesOutExcludedPages_InQueueOrder()
    {
        var pages = new[] { Checked(false), Checked(true), Checked(true, PageInclusion.Keep), Checked(false, PageInclusion.Skip) };
        Assert.Equal([pages[0].Id, pages[2].Id], PageFilter.PagesToSave(pages, Options(true)).Select(p => p.Id));
        Assert.Equal([pages[0].Id, pages[1].Id, pages[2].Id], PageFilter.PagesToSave(pages, Options(false)).Select(p => p.Id));
    }

    [Fact]
    public void Badge_AndToggleLabel_SayWhatHappensToThePage()
    {
        var on = Options(true);
        var off = Options(false);
        Assert.Equal(("Blank, skipped", "Keep this page"), (PageFilter.Badge(Checked(true), on), PageFilter.ToggleLabel(Checked(true), on)));
        Assert.Equal(("Looks blank", "Skip this page"), (PageFilter.Badge(Checked(true), off), PageFilter.ToggleLabel(Checked(true), off)));
        Assert.Equal(("Looks blank", "Skip this page"),
                     (PageFilter.Badge(Checked(true, PageInclusion.Keep), on), PageFilter.ToggleLabel(Checked(true, PageInclusion.Keep), on)));
        Assert.Equal(("Skipped", "Keep this page"),
                     (PageFilter.Badge(Checked(false, PageInclusion.Skip), off), PageFilter.ToggleLabel(Checked(false, PageInclusion.Skip), off)));
        Assert.Null(PageFilter.Badge(Checked(false), on));
        Assert.Null(PageFilter.ToggleLabel(Checked(false), on));
        Assert.Null(PageFilter.Badge(Page(BlankImage), on));
    }

    [Fact]
    public void QueueSummary_AndScanNote_CountTheSkippedPages()
    {
        var on = Options(true);
        Assert.Equal("1 page", PageFilter.QueueSummary([Checked(false)], on));
        Assert.Equal("3 pages · 2 blank skipped", PageFilter.QueueSummary([Checked(false), Checked(true), Checked(true)], on));
        Assert.Equal("2 pages · 1 skipped",
                     PageFilter.QueueSummary([Checked(false), Checked(false, PageInclusion.Skip)], on));
        Assert.Equal("2 pages", PageFilter.QueueSummary([Checked(true), Checked(false)], Options(false)));
        Assert.Equal(" 2 look blank and will be skipped.", PageFilter.ScanNote([Checked(true), Checked(true), Checked(false)], on));
        Assert.Equal(" 1 looks blank.", PageFilter.ScanNote([Checked(true)], Options(false)));
        Assert.Equal("", PageFilter.ScanNote([Checked(false), Page(BlankImage)], on));
    }

    // MARK: - Page facts survive every rebuild

    [Fact]
    public void BlankResultAndInclusion_SurviveRebuildingThePage()
    {
        var result = new BlankPageResult(0.00001, 1, false, true);
        var page = Page(BlankImage).WithSide(PageSide.Back, 2).WithBlank(result).WithInclusion(PageInclusion.Keep);
        foreach (var rebuilt in new[]
                 {
                     page.WithImage(RgbaImage.Filled(3, 3, 0, 0, 0)),
                     page.RotatedClockwise(),
                     page.WithSide(PageSide.Front, 0),
                     Page(TextImage).CopyMeta(page),
                     page.WithInclusion(PageInclusion.Keep).WithBlank(result),
                 })
        {
            Assert.Equal(result, rebuilt.Blank);
            Assert.Equal(PageInclusion.Keep, rebuilt.Inclusion);
        }
        Assert.Equal((PageSide.Back, 2), (page.Side, page.SheetIndex));
        Assert.Equal(PageInclusion.Automatic, Page(BlankImage).Inclusion);
        Assert.Null(Page(BlankImage).Blank);
    }

    // MARK: - Facing pages

    /// <summary>The spread of TestPages.ShadowSpread as a 100 dpi scan: its spine at x = 572 of 1100.</summary>
    private static readonly RgbaImage SpreadImage = TestPages.ShadowSpread().ToRgba();

    /// <summary>A w × h scan whose left part (x below w / 2) is red and right part blue, top half bright and bottom dim.</summary>
    private static RgbaImage TwoTone(int w, int h)
    {
        var p = new byte[w * h * 4];
        for (int y = 0; y < h; y++)
        {
            for (int x = 0; x < w; x++)
            {
                int i = (y * w + x) * 4;
                byte level = (byte)(y < h / 2 ? 250 : 120);
                p[i] = x < w / 2 ? level : (byte)0;
                p[i + 2] = x < w / 2 ? (byte)0 : level;
                p[i + 3] = 255;
            }
        }
        return new RgbaImage(w, h, p);
    }

    [Fact]
    public void ForScan_SplitsFacingPages_OnlyOnCollectedDocumentPages()
    {
        var s = new ScanSettings();
        Assert.False(PageProcessor.SplitsFacingPages(s));
        Assert.Null(PageProcessor.ForScan(s).Book);
        s.Document.SplitFacingPages = true;
        s.TaskOptions.BookRightToLeft = true;
        s.TaskOptions.BookRotationQuarterTurns = -1;
        Assert.True(PageProcessor.SplitsFacingPages(s));
        Assert.Equal(new BookSplitOptions(3, true), PageProcessor.ForScan(s).Book);
        // The steps are the usual ones: the split comes before them.
        Assert.Equal(["blank", "separator"], PageProcessor.ForScan(s).Steps.Select(step => step.Name));
        Assert.NotNull(PageProcessor.ForScan(TaskCatalog.Apply(ScanTask.Book, new ScanSettings())).Book);
        // Pages saved at once, photos, copies and receipts are never cut unseen.
        foreach (var other in new[]
                 {
                     new ScanSettings { DocumentMultiPage = false },
                     new ScanSettings { Intent = ScanIntent.Photo },
                     TaskCatalog.Apply(ScanTask.Copy, new ScanSettings()),
                     TaskCatalog.Apply(ScanTask.Receipt, new ScanSettings()),
                 })
        {
            other.Document.SplitFacingPages = true;
            Assert.False(PageProcessor.SplitsFacingPages(other));
            Assert.Null(PageProcessor.ForScan(other).Book);
        }
        // Pages scanned on both sides keep their sheet and side: by a feeder that scans both, or turned by hand.
        foreach (var duplex in new[] { DuplexMode.Both, DuplexMode.Manual })
        {
            var twoSided = new ScanSettings { Source = ScanSource.DocumentFeeder, Duplex = duplex };
            twoSided.Document.SplitFacingPages = true;
            Assert.False(PageProcessor.SplitsFacingPages(twoSided));
            Assert.Null(PageProcessor.ForScan(twoSided).Book);
        }
        // One side of each sheet from the feeder is split.
        var oneSided = new ScanSettings { Source = ScanSource.DocumentFeeder, Duplex = DuplexMode.Off };
        oneSided.Document.SplitFacingPages = true;
        Assert.True(PageProcessor.SplitsFacingPages(oneSided));
        // The flatbed scans one side, whatever the feeder's choice.
        var flatbed = new ScanSettings { Source = ScanSource.Flatbed, Duplex = DuplexMode.Both };
        flatbed.Document.SplitFacingPages = true;
        Assert.True(PageProcessor.SplitsFacingPages(flatbed));
    }

    [Fact]
    public void Process_SpreadsGivenASide_KeepTheirSheetAndSide()
    {
        // A front and its back, each a spread: every page cut from them keeps the side and sheet arranging gave it.
        var book = new BookSplitOptions();
        var result = new PageProcessor([], ScanArrangement.TwoSided, book: book).Process([Page(SpreadImage), Page(SpreadImage)]);
        Assert.Equal(4, result.Pages.Count);
        Assert.All(result.Pages, p => Assert.False(p.Spread!.IsWhole));
        Assert.Equal(new[] { (PageSide.Front, 0), (PageSide.Front, 0), (PageSide.Back, 0), (PageSide.Back, 0) },
                     result.Pages.Select(p => (p.Side!.Value, p.SheetIndex!.Value)));
        // A spread kept whole too.
        var single = TestPages.SinglePageAcross().ToRgba();
        var whole = new PageProcessor([], ScanArrangement.TwoSided, book: book).Process([Page(single), Page(single)]).Pages;
        Assert.All(whole, p => Assert.True(p.Spread!.IsWhole));
        Assert.Equal(new[] { (PageSide.Front, 0), (PageSide.Back, 0) }, whole.Select(p => (p.Side!.Value, p.SheetIndex!.Value)));
        // Turned over by hand, and a spread split again by hand.
        var backs = new PageProcessor([], ScanArrangement.TurnedOverBacks, book: book).Process([Page(SpreadImage)]).Pages;
        Assert.All(backs, p => Assert.Equal(PageSide.Back, p.Side));
        var cut = BookSplitter.Manual(GutterAxis.Vertical, 0.3, 200, 100);
        var again = new PageProcessor([]).ProcessSpread(Page(TwoTone(200, 100)).WithSide(PageSide.Back, 3), cut, book);
        Assert.Equal(2, again.Count);
        Assert.All(again, p => Assert.Equal((PageSide.Back, 3), (p.Side!.Value, p.SheetIndex!.Value)));
        // A spread scanned one side has none.
        Assert.All(new PageProcessor([], book: book).Process([Page(SpreadImage)]).Pages,
                   p => Assert.Equal(((PageSide?)null, (int?)null), (p.Side, p.SheetIndex)));
    }

    [Fact]
    public void Process_ASpread_BecomesItsTwoPages_InReadingOrder()
    {
        var spread = Page(SpreadImage);
        var result = new PageProcessor([], book: new BookSplitOptions()).Process([spread]);
        Assert.Equal([spread.Id], result.Arranged.Select(p => p.Id));
        Assert.Equal([spread.Id], result.Spreads.Select(p => p.Id));
        Assert.Equal(2, result.Pages.Count);
        var (left, right) = (result.Pages[0], result.Pages[1]);
        // Cut at the spine, together exactly the spread, each at the scan's resolution.
        Assert.InRange(left.Image.Width, 567, 577);
        Assert.Equal(1100, left.Image.Width + right.Image.Width);
        Assert.All(result.Pages, p => Assert.Equal((850, 100, ColorMode.Color), (p.Image.Height, p.Dpi, p.ColorMode)));
        Assert.Equal(spread.CreatedAt, left.CreatedAt);
        // Each page records its spread and part, and has an id of its own.
        Assert.Equal((spread.Id, 0, GutterKind.Shadow), (left.SpreadId, left.Spread!.Part, left.Spread.Gutter!.Kind));
        Assert.Equal((spread.Id, 1), (right.SpreadId, right.Spread!.Part));
        Assert.Equal(left.Spread.Gutter, right.Spread.Gutter);
        Assert.Equal(3, new[] { spread.Id, left.Id, right.Id }.Distinct().Count());
        // Right to left, the right page comes first.
        var rtl = new PageProcessor([], book: new BookSplitOptions(0, RightToLeft: true)).Process([spread]).Pages;
        Assert.Equal([1, 0], rtl.Select(p => p.Spread!.Part!.Value));
    }

    [Fact]
    public void Process_ASpreadWithoutAClearSpine_StaysWhole()
    {
        var single = Page(TestPages.SinglePageAcross().ToRgba());
        var result = new PageProcessor([], book: new BookSplitOptions()).Process([single]);
        var page = Assert.Single(result.Pages);
        Assert.True(page.Spread!.IsWhole);
        Assert.Equal((single.Id, (GutterResult?)null), (page.SpreadId, page.Spread.Gutter));
        Assert.NotEqual(single.Id, page.Id);
        Assert.Equal((850, 1100), (page.Image.Width, page.Image.Height));
        Assert.Equal([single.Id], result.Spreads.Select(p => p.Id));
        // Without the split, the page goes through as it is.
        var plain = new PageProcessor([]).Process([single]);
        Assert.Equal(single.Id, Assert.Single(plain.Pages).Id);
        Assert.Null(plain.Pages[0].Spread);
        Assert.Empty(plain.Spreads);
    }

    [Fact]
    public void Process_TheStepsRunOnEachPage_OfEverySpread()
    {
        var log = new List<string>();
        var spreads = new[] { Page(SpreadImage), Page(SpreadImage) };
        var result = new PageProcessor([new RecordingStep("one", log)], book: new BookSplitOptions()).Process(spreads);
        Assert.Equal(4, result.Pages.Count);
        Assert.Equal(result.Pages.Select(p => $"one:{p.Id}"), log);
        Assert.Equal([spreads[0].Id, spreads[0].Id, spreads[1].Id, spreads[1].Id], result.Pages.Select(p => p.SpreadId!.Value));
        // A blank facing page is flagged like any blank page.
        var blankFacing = PageProcessor.ForScan(TaskCatalog.Apply(ScanTask.Book, new ScanSettings()))
            .Process([Page(TestPages.BlankFacingSpread().ToRgba())]).Pages;
        Assert.Equal([true, false], blankFacing.Select(p => p.Blank?.IsBlank == true));
    }

    [Fact]
    public void ProcessSpread_CutsWhereAsked_OrKeepsTheSpreadWhole()
    {
        var spread = Page(TwoTone(200, 100));
        var processor = new PageProcessor([], book: new BookSplitOptions());
        var cut = BookSplitter.Manual(GutterAxis.Vertical, 0.3, 200, 100);
        var pages = processor.ProcessSpread(spread, cut, new BookSplitOptions());
        Assert.Equal([60, 140], pages.Select(p => p.Image.Width));
        Assert.All(pages, p => Assert.Equal(GutterKind.Manual, p.Spread!.Gutter!.Kind));
        var whole = Assert.Single(processor.ProcessSpread(spread, null, new BookSplitOptions()));
        Assert.True(whole.Spread!.IsWhole);
        Assert.Equal((200, 100), (whole.Image.Width, whole.Image.Height));
        // The book's rotation turns the whole spread too.
        var turned = Assert.Single(processor.ProcessSpread(spread, null, new BookSplitOptions(1)));
        Assert.Equal((100, 200), (turned.Image.Width, turned.Image.Height));
    }

    /// <summary>A step that turns every page upright by a quarter clockwise, as reading its text would.</summary>
    private sealed class TurnStep(int quarterTurns) : IPageStep
    {
        public string Name => "orientation";
        public ScannedPage Apply(ScannedPage page) => page.TurnedUpright(quarterTurns);
    }

    [Fact]
    public void ProcessSpread_PagesTurnedByReadingTheirText_AreOrderedAsTheyLieTurned()
    {
        // A book lying sideways: its pages one above the other, red on top, blue below.
        var stacked = Page(TwoTone(200, 100).RotatedQuarterTurns(1));
        var cut = BookSplitter.Manual(GutterAxis.Horizontal, 0.5, 100, 200);
        // Reading turns each page a quarter counterclockwise: the top page lies on the left, and leads.
        var counter = new PageProcessor([new TurnStep(3)]).ProcessSpread(stacked, cut, new BookSplitOptions());
        Assert.Equal([0, 1], counter.Select(p => p.Spread!.Part!.Value));
        Assert.All(counter, p => Assert.Equal(new UprightTurn(3), p.Upright));
        // Clockwise, the top page lies on the right: the bottom one leads, unless the book reads right to left.
        var clockwise = new PageProcessor([new TurnStep(1)]).ProcessSpread(stacked, cut, new BookSplitOptions());
        Assert.Equal([1, 0], clockwise.Select(p => p.Spread!.Part!.Value));
        Assert.Equal([0, 1], new PageProcessor([new TurnStep(1)]).ProcessSpread(stacked, cut, new BookSplitOptions(0, true))
                                 .Select(p => p.Spread!.Part!.Value));
        // The book's rotation counts the same way: turned clockwise by setting, then not read.
        var bySetting = new PageProcessor([]).ProcessSpread(stacked, cut, new BookSplitOptions(1));
        Assert.Equal([1, 0], bySetting.Select(p => p.Spread!.Part!.Value));
        Assert.All(bySetting, p => Assert.Equal((100, 100), (p.Image.Width, p.Image.Height)));
    }

    [Fact]
    public void Spread_SurvivesRebuildingThePage()
    {
        var part = new SpreadPart(Guid.NewGuid(), 1, BookSplitter.Manual(GutterAxis.Vertical, 0.5, 10, 10));
        var page = Page(BlankImage).WithSpread(part);
        foreach (var rebuilt in new[]
                 {
                     page.WithImage(RgbaImage.Filled(3, 3, 0, 0, 0)),
                     page.RotatedClockwise(),
                     page.WithSide(PageSide.Front, 0),
                     page.WithBlank(null),
                     page.WithInclusion(PageInclusion.Skip),
                     page.WithPatch(null),
                     page.WithDocumentBreak(DocumentBreak.Split),
                     page.WithDocumentLabel("Chapter 1"),
                     page.WithUpright(new UprightTurn(2)),
                     page.TurnedUpright(2),
                     page.WithAlternate(null),
                     page.WithGeometry(RgbaImage.Filled(3, 3, 0, 0, 0), new PageGeometry(false, 1.5, GeometryBasis.TextLines)),
                     page.WithSpineShadow(RgbaImage.Filled(3, 3, 0, 0, 0), new SpineShadowResult(PageEdge.Left, 0.2, 0.5, 1.3, 0)),
                     Page(TextImage).CopyMeta(page),
                 })
        {
            Assert.Equal(part, rebuilt.Spread);
            Assert.Equal(part.SpreadId, rebuilt.SpreadId);
        }
        var corrected = page.WithGeometry(RgbaImage.Filled(3, 3, 0, 0, 0), new PageGeometry(false, 1.5, GeometryBasis.TextLines));
        Assert.Equal(part, corrected.WithVersionsSwapped(BlankImage).Spread);
        Assert.Null(page.WithSpread(null).Spread);
        Assert.Null(Page(BlankImage).SpreadId);
    }

    // MARK: - Softening the spine's shadow

    [Fact]
    public void ForScan_SoftensTheSpineShadow_OnlyOnSplitSpreads()
    {
        var s = new ScanSettings();
        s.Document.SoftenSpineShadow = true;
        // Facing pages are not split: there is no spine.
        Assert.False(PageProcessor.SoftensSpineShadow(s));
        Assert.DoesNotContain("spineShadow", PageProcessor.ForScan(s).Steps.Select(step => step.Name));
        s.Document.SplitFacingPages = true;
        s.TaskOptions.BookRotationQuarterTurns = 5;
        Assert.True(PageProcessor.SoftensSpineShadow(s));
        var steps = PageProcessor.ForScan(s).Steps;
        Assert.Equal(["blank", "spineShadow", "separator"], steps.Select(step => step.Name));
        // The step knows how the book's pages were turned before the steps.
        Assert.Equal(1, Assert.IsType<SpineShadowStep>(steps[1]).RotationQuarterTurns);
        // The Book or magazine task softens it, after straightening each page.
        var book = TaskCatalog.Apply(ScanTask.Book, new ScanSettings());
        Assert.Equal(["blank", "geometry", "spineShadow", "separator"], PageProcessor.ForScan(book).Steps.Select(step => step.Name));
        Assert.Equal(["blank", "geometry", "spineShadow", "separator", "orientation"],
                     PageProcessor.ForScan(book, scorer: new StubScorer(true)).Steps.Select(step => step.Name));
        // Off, or with spreads kept as scanned (two-sided, saved at once, photos), there is no step.
        book.Document.SoftenSpineShadow = false;
        Assert.DoesNotContain("spineShadow", PageProcessor.ForScan(book).Steps.Select(step => step.Name));
        foreach (var other in new[]
                 {
                     new ScanSettings { Source = ScanSource.DocumentFeeder, Duplex = DuplexMode.Both },
                     new ScanSettings { DocumentMultiPage = false },
                     new ScanSettings { Intent = ScanIntent.Photo },
                 })
        {
            other.Document.SplitFacingPages = true;
            other.Document.SoftenSpineShadow = true;
            Assert.False(PageProcessor.SoftensSpineShadow(other));
            Assert.DoesNotContain("spineShadow", PageProcessor.ForScan(other).Steps.Select(step => step.Name));
        }
    }

    [Fact]
    public void Process_ASpreadWithTheSpinesShadow_SoftensBothPages_KeepingThemAsScanned()
    {
        var s = new ScanSettings();
        s.Document.SplitFacingPages = true;
        s.Document.SoftenSpineShadow = true;
        var spread = Page(TestPages.ShadowedBookSpread().ToRgba());
        var result = PageProcessor.ForScan(s).Process([spread]);
        Assert.Equal(2, result.Pages.Count);
        var (left, right) = (result.Pages[0], result.Pages[1]);
        Assert.Equal((0, 1), (left.Spread!.Part!.Value, right.Spread!.Part!.Value));
        Assert.Equal((PageEdge.Right, PageEdge.Left), (left.SpineShadow!.Edge, right.SpineShadow!.Edge));
        foreach (var page in result.Pages)
        {
            Assert.True(page.CanSwapVersions);
            Assert.False(page.ShowsOriginal);
            Assert.Null(page.Geometry);
            Assert.Equal("Spine shadow softened", PageCorrections.Caption(page));
            Assert.Equal("Show as scanned", PageCorrections.ToggleLabel(page));
        }
        // The page as cut is the other version: the paper at the spine (between two lines) is brighter on the page shown.
        static int Paper(RgbaImage image, bool atRight) => image.Pixels[(430 * image.Width + (atRight ? image.Width - 3 : 2)) * 4];
        Assert.True(Paper(left.Image, true) > Paper(left.Alternate!.Image!, true) + 40);
        Assert.True(Paper(right.Image, false) > Paper(right.Alternate!.Image!, false) + 40);
        Assert.Equal(" Spine shadow softened on 2 pages.", PageCorrections.ScanNote(result.Pages));
        // One click shows the page as cut from the scan.
        var asScanned = left.WithVersionsSwapped(left.Alternate!.Image!);
        Assert.Equal("As scanned", PageCorrections.Caption(asScanned));
        Assert.Equal("Show with the spine shadow softened", PageCorrections.ToggleLabel(asScanned));
        Assert.Equal("Page 1 is shown as scanned. It is saved that way.", PageCorrections.SwapNote(asScanned, 1));
        Assert.Equal("Page 1 is shown with the spine shadow softened again.",
                     PageCorrections.SwapNote(asScanned.WithVersionsSwapped(left.Image), 1));
        Assert.Equal("", PageCorrections.ScanNote([asScanned]));
        // Turned off, the pages are cut and nothing else.
        s.Document.SoftenSpineShadow = false;
        Assert.All(PageProcessor.ForScan(s).Process([spread]).Pages, p => Assert.Null(p.SpineShadow));
    }

    [Fact]
    public void SpineShadowStep_TakesTheEdgeOfTheCut_TurnedByTheBook()
    {
        var page = TestPages.ShadowedBookPage().ToRgba();   // the spine's shadow on its right
        var cut = BookSplitter.Manual(GutterAxis.Vertical, 0.5, 1100, 850);
        var leftPart = Page(page).WithSpread(new SpreadPart(Guid.NewGuid(), 0, cut));
        Assert.Equal(PageEdge.Right, new SpineShadowStep(0).Apply(leftPart).SpineShadow?.Edge);
        // The same pixels as the right part of a spread are looked at along their left edge: no shadow there.
        var rightPart = Page(page).WithSpread(new SpreadPart(Guid.NewGuid(), 1, cut));
        Assert.Same(rightPart, new SpineShadowStep(0).Apply(rightPart));
        // A book upside down on the glass: the left part, turned half round, has the spine on its left.
        var turned = Page(page.RotatedQuarterTurns(2)).WithSpread(new SpreadPart(Guid.NewGuid(), 0, cut));
        Assert.Equal(PageEdge.Left, new SpineShadowStep(2).Apply(turned).SpineShadow?.Edge);
        Assert.Same(turned, new SpineShadowStep(0).Apply(turned));
        // Pages not cut from a spread, and whole spreads, are left alone.
        var plain = Page(page);
        Assert.Same(plain, new SpineShadowStep(0).Apply(plain));
        var whole = Page(page).WithSpread(new SpreadPart(Guid.NewGuid(), null, null));
        Assert.Same(whole, new SpineShadowStep(0).Apply(whole));
        Assert.Equal("spineShadow", new SpineShadowStep(0).Name);
        Assert.Equal(3, new SpineShadowStep(-1).RotationQuarterTurns);
    }

    [Fact]
    public void WithSpineShadow_KeepsThePageAsScanned_AsTheOtherVersion()
    {
        var softened = RgbaImage.Filled(6, 8, 250, 250, 250);
        var result = new SpineShadowResult(PageEdge.Right, 0.3, 0.6, 1.7, 0);
        // Not cropped or straightened: the page as it was becomes the other version.
        var page = Page(TextImage).WithSide(PageSide.Front, 2).WithBlank(new BlankPageResult(0.01, 50, false, false));
        var soft = page.WithSpineShadow(softened, result);
        Assert.Same(softened, soft.Image);
        Assert.Same(TextImage, soft.Alternate!.Image);
        Assert.Equal((page.Id, result, PageSide.Front, 2), (soft.Id, soft.SpineShadow, soft.Side!.Value, soft.SheetIndex!.Value));
        Assert.Equal(page.Blank, soft.Blank);
        Assert.True(soft.CanSwapVersions);
        Assert.False(soft.WithAlternate(null).CanSwapVersions);
        // Straightened first: the other version stays the page as scanned, not the straightened one.
        var straightened = Page(SheetImage).WithGeometry(TextImage, new PageGeometry(false, 1.5, GeometryBasis.TextLines));
        var both = straightened.WithSpineShadow(softened, result);
        Assert.Same(SheetImage, both.Alternate!.Image);
        Assert.Equal(straightened.Geometry, both.Geometry);
        Assert.Equal("Straightened 1.5°, spine shadow softened", PageCorrections.Caption(both));
        Assert.Equal("Show as scanned", PageCorrections.ToggleLabel(both));
        Assert.Equal("Page 4 is straightened again, with the spine shadow softened.", PageCorrections.SwapNote(both, 4));
        var original = both.WithVersionsSwapped(SheetImage);
        Assert.Equal("As scanned", PageCorrections.Caption(original));
        Assert.Equal("Show straightened, with the spine shadow softened", PageCorrections.ToggleLabel(original));
        Assert.Equal(result, original.SpineShadow);
        Assert.Equal(" 1 straightened. Spine shadow softened on 1 page.", PageCorrections.ScanNote([both, original]));
        // The adjustments reach both versions.
        var gray = new AdjustmentStep(new AdjustmentSettings(), ColorMode.Grayscale).Apply(both);
        Assert.Equal(ImagePipeline.Apply(new AdjustmentSettings(), SheetImage, ColorMode.Grayscale).Pixels, gray.Alternate!.Image!.Pixels);
        Assert.Equal(result, gray.SpineShadow);
    }

    [Fact]
    public void SpineShadow_SurvivesRebuildingThePage()
    {
        var result = new SpineShadowResult(PageEdge.Left, 0.2, 0.5, 1.4, 0.1);
        var page = Page(TextImage).WithSpineShadow(BlankImage, result);
        foreach (var rebuilt in new[]
                 {
                     page.WithImage(RgbaImage.Filled(3, 3, 0, 0, 0)),
                     page.RotatedClockwise(),
                     page.WithSide(PageSide.Front, 0),
                     page.WithBlank(null),
                     page.WithInclusion(PageInclusion.Skip),
                     page.WithPatch(null),
                     page.WithDocumentBreak(DocumentBreak.Split),
                     page.WithDocumentLabel("Chapter 1"),
                     page.WithUpright(new UprightTurn(2)),
                     page.TurnedUpright(1),
                     page.WithAlternate(null),
                     page.WithSpread(null),
                     page.WithGeometry(RgbaImage.Filled(3, 3, 0, 0, 0), new PageGeometry(false, 1.5, GeometryBasis.TextLines)),
                     page.WithVersionsSwapped(TextImage),
                     Page(SheetImage).CopyMeta(page),
                 })
        {
            Assert.Equal(result, rebuilt.SpineShadow);
        }
        Assert.Null(Page(TextImage).SpineShadow);
    }
}
