using CompleteScanner.Core;
using Xunit;

namespace CompleteScanner.Core.Tests;

// Twin of Tests/CompleteScannerTests/PageProcessorTests.swift: the clean-up stage, which pages
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
            Assert.Equal(["blank"], processor.Steps.Select(step => step.Name));
            Assert.Equal(BlankSensitivity.High, ((BlankDetectionStep)processor.Steps[0]).Options.Sensitivity);
        }
    }

    [Fact]
    public void ForScan_AdjustmentsComeAfterTheBlankCheck_OnlyWhenTheyChangeSomething()
    {
        var s = new ScanSettings();
        s.Adjustments.Brightness = 0.25;
        Assert.Equal(["blank", "adjust"], PageProcessor.ForScan(s).Steps.Select(step => step.Name));
        var gray = new ScanSettings { ColorMode = ColorMode.Grayscale };
        Assert.Equal(["blank", "adjust"], PageProcessor.ForScan(gray).Steps.Select(step => step.Name));
        var adjust = (AdjustmentStep)PageProcessor.ForScan(gray).Steps[1];
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
        Assert.Equal(["blank", "geometry", "adjust"], processor.Steps.Select(step => step.Name));
        var step = (GeometryStep)processor.Steps[1];
        Assert.Equal((false, true), (step.Crop, step.Straighten));
        s.Document.AutoCrop = true;
        s.Document.AutoStraighten = false;
        Assert.Equal((true, false), (((GeometryStep)PageProcessor.ForScan(s).Steps[1]).Crop, ((GeometryStep)PageProcessor.ForScan(s).Steps[1]).Straighten));
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
        // The result is that of the page as scanned, not of the adjusted pixels.
        var s = new ScanSettings { ColorMode = ColorMode.BlackWhite };
        s.Adjustments.Brightness = -0.5;
        s.Adjustments.Contrast = 3;
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
        Assert.Equal("1 page in queue", PageFilter.QueueSummary([Checked(false)], on));
        Assert.Equal("3 pages in queue, 2 blank skipped", PageFilter.QueueSummary([Checked(false), Checked(true), Checked(true)], on));
        Assert.Equal("2 pages in queue, 1 skipped",
                     PageFilter.QueueSummary([Checked(false), Checked(false, PageInclusion.Skip)], on));
        Assert.Equal("2 pages in queue", PageFilter.QueueSummary([Checked(true), Checked(false)], Options(false)));
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
}
