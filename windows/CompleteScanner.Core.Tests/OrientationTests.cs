using CompleteScanner.Core;
using Xunit;

namespace CompleteScanner.Core.Tests;

// Twin of Tests/CompleteScannerTests/OrientationTests.swift: rotate pages upright — what a reading
// scores, which ways up are read, when a page is turned, and what the page strip says about it.

public class OrientationTests
{
    /// <summary>
    /// The page of text lines (<see cref="TestPages.TextPage"/>) as an RGBA scan at 100 dpi, upright,
    /// with a dark square in its top left corner that tells the stand-in OCR which way up it is.
    /// </summary>
    private static readonly RgbaImage TextImage = Marked(TestPages.Enlarged(TestPages.TextPage(), 1));
    private static readonly RgbaImage BlankImage = TestPages.Enlarged(TestPages.CleanBlank(), 1);

    private static readonly OrientationScore ReadsWell = new(400, 380);
    private static readonly OrientationScore UpsideDown = new(200, 90);
    private static readonly OrientationScore Sideways = new(5, 0);

    private static ScannedPage Page(RgbaImage image) => new(image, 100, ColorMode.Color);

    /// <summary><paramref name="page"/> with a black 20 × 20 px square 10 px in from its top left corner.</summary>
    private static RgbaImage Marked(RgbaImage page)
    {
        for (int y = 10; y < 30; y++)
        {
            for (int x = 10; x < 30; x++)
            {
                int i = (y * page.Width + x) * 4;
                page.Pixels[i] = 0;
                page.Pixels[i + 1] = 0;
                page.Pixels[i + 2] = 0;
            }
        }
        return page;
    }

    /// <summary>
    /// How far a picture of <see cref="TextImage"/> is turned from upright, in quarter turns
    /// clockwise, by the corner its square is in; null when no corner is dark.
    /// </summary>
    private static int? TurnsFromUpright(RgbaImage image)
    {
        const int side = 40;
        int w = image.Width, h = image.Height;
        double Mean(int x0, int y0)
        {
            long sum = 0;
            for (int y = y0; y < y0 + side; y++)
            {
                for (int x = x0; x < x0 + side; x++) sum += image.Pixels[(y * w + x) * 4];
            }
            return sum / (double)(side * side);
        }
        // Turning clockwise takes the top left corner to the top right, the bottom right, the bottom left.
        double[] corners = [Mean(0, 0), Mean(w - side, 0), Mean(w - side, h - side), Mean(0, h - side)];
        int darkest = 0;
        for (int i = 1; i < 4; i++)
        {
            if (corners[i] < corners[darkest]) darkest = i;
        }
        return corners[darkest] < 200 ? darkest : null;
    }

    /// <summary>
    /// A stand-in for text recognition that reads <see cref="TextImage"/> as real OCR reads a letter:
    /// well upright, words that are not words upside down, next to nothing sideways. It records how
    /// far from upright each picture it was given was turned (clockwise quarter turns).
    /// </summary>
    private sealed class FakeScorer(OrientationScore upright, OrientationScore upsideDown, OrientationScore sideways)
        : IOrientationScorer
    {
        public bool IsAvailable { get; init; } = true;
        public bool Fails { get; init; }
        public Action? OnScore { get; init; }
        public List<int> Seen { get; } = [];

        public OrientationScore Score(RgbaImage image, CancellationToken token)
        {
            OnScore?.Invoke();
            if (Fails) throw ScanException.ScanFailed("OCR failed: the recognizer stopped.");
            if (TurnsFromUpright(image) is not { } turns) return OrientationScore.None;
            Seen.Add(turns);
            return turns == 0 ? upright : turns == 2 ? upsideDown : sideways;
        }
    }

    private static FakeScorer LikeALetter() => new(ReadsWell, UpsideDown, Sideways);

    // MARK: - Scores

    [Fact]
    public void Score_CountsLetters_AndTheLettersOfWordsThatLookLikeWords()
    {
        var score = OrientationScore.Of(
        [
            "THE AMERICAN NATIONAL RED CROSS.",
            "August 21, 1903.",
            "sanof RTtnJqoedsea a.10Jaq suo!umqxa",
            "o O 0",
            "Jean-Pierre l'eau don’t McKinley",
            "東京都 2nd",
        ]);
        Assert.Equal(new OrientationScore(105, 65), score);
        Assert.Equal(OrientationScore.None, OrientationScore.Of([]));
        Assert.Equal(OrientationScore.None, OrientationScore.Of(["", "   "]));
    }

    [Fact]
    public void WordScore_TakesWordsInOneCase_AndNumbers()
    {
        foreach (var (word, letters) in new (string, int)[]
                 {
                     ("Lieutenant,", 10), ("1903.", 4), ("Jean-Pierre", 10), ("(HARRY)", 5), ("SVNVNVEI", 8),
                     ("a-b", 2), ("a.10Jaq", 0), ("RTtnJqoed", 0), ("o", 0), ("--", 0), ("x-", 0), ("2nd", 0), ("", 0),
                 })
        {
            Assert.True(OrientationScore.WordScore(word) == letters, $"{word}: {OrientationScore.WordScore(word)}");
        }
    }

    [Fact]
    public void ReadsClearly_NeedsEnoughWords_AndFewLettersOutsideThem()
    {
        Assert.True(ReadsWell.ReadsClearly);
        Assert.True(new OrientationScore(150, 150).ReadsClearly);
        Assert.False(new OrientationScore(400, 300).ReadsClearly);
        Assert.False(new OrientationScore(160, 149).ReadsClearly);
        Assert.False(UpsideDown.ReadsClearly);
        Assert.False(OrientationScore.None.ReadsClearly);
    }

    // MARK: - Which ways up are read

    [Fact]
    public void Candidates_FollowTheLinesOfText()
    {
        Assert.Equal([0, 2], OrientationDecision.Candidates(new TextLayout(TextAxis.Horizontal, 0.5, 0.6, 5000)));
        Assert.Equal([1, 3], OrientationDecision.Candidates(new TextLayout(TextAxis.Vertical, -1, 0.6, 5000)));
        Assert.Equal([0, 2, 1, 3], OrientationDecision.Candidates(new TextLayout(TextAxis.Unknown, 0, 0.6, 5000)));
        // Lines too faint to trust: every way up.
        Assert.Equal([0, 2, 1, 3], OrientationDecision.Candidates(new TextLayout(TextAxis.Horizontal, 0, 0.1, 5000)));
        // Too little ink to hold text: nothing is read.
        Assert.Empty(OrientationDecision.Candidates(new TextLayout(TextAxis.Horizontal, 0, 0.6, DocumentGeometry.MinInkPoints - 1)));
        Assert.Empty(OrientationDecision.Candidates(TextLayout.Nothing));
    }

    [Fact]
    public void Choose_NeedsEnoughWords_AndAClearMargin()
    {
        static CandidateScore C(int turns, int words) => new(turns, new OrientationScore(words + 10, words));
        Assert.Equal(0, OrientationDecision.Choose([C(0, 100), C(2, 50)]));
        Assert.Equal(2, OrientationDecision.Choose([C(0, 49), C(2, 100)]));
        Assert.Equal(3, OrientationDecision.Choose([C(1, 0), C(3, 250)]));
        Assert.Equal(1, OrientationDecision.Choose([C(0, 3), C(2, 4), C(1, 20), C(3, 10)]));
        Assert.Equal(0, OrientationDecision.Choose([C(0, 20)]));
        Assert.Null(OrientationDecision.Choose([C(0, 100), C(2, 51)]));    // not twice as many
        Assert.Null(OrientationDecision.Choose([C(0, 19), C(2, 0)]));      // too few
        Assert.Null(OrientationDecision.Choose([C(0, 80), C(2, 80)]));     // a tie
        Assert.Null(OrientationDecision.Choose([C(0, 0), C(2, 0), C(1, 0), C(3, 0)]));
        Assert.Null(OrientationDecision.Choose([]));
    }

    [Fact]
    public void AnalysisImage_IsAtMost1600PixelsLong()
    {
        Assert.Equal((850, 1100), OrientationDecision.AnalysisSize(850, 1100));
        Assert.Equal((1600, 1600), OrientationDecision.AnalysisSize(1600, 1600));
        Assert.Equal((1236, 1600), OrientationDecision.AnalysisSize(2550, 3300));
        Assert.Equal((1600, 1236), OrientationDecision.AnalysisSize(3300, 2550));
        Assert.Equal((1600, 1), OrientationDecision.AnalysisSize(9000, 2));
        Assert.Same(TextImage, OrientationDecision.AnalysisImage(TextImage));
        var wide = OrientationDecision.AnalysisImage(RgbaImage.Filled(2000, 100, 9, 9, 9));
        Assert.Equal((1600, 80), (wide.Width, wide.Height));
    }

    // MARK: - Reading a page

    [Fact]
    public void Check_UprightPage_IsLeftAsIs_AfterOneReading()
    {
        var scorer = LikeALetter();
        var check = OrientationDecision.Check(TextImage, 100, scorer);
        Assert.Equal((OrientationVerdict.Upright, 0), (check.Verdict, check.QuarterTurns));
        Assert.Equal(TextAxis.Horizontal, check.Layout.Axis);
        Assert.Equal([0], scorer.Seen);
        Assert.Equal(1, check.Passes);
        Assert.Equal([new CandidateScore(0, ReadsWell)], check.Scores);
    }

    [Fact]
    public void Check_PageTurnedAnyWay_IsTurnedUpright()
    {
        // (the page's turn from upright, the turn that makes it upright, what was read: turns from upright)
        // A sideways page that reads clearly at the first quarter turn is read the other way too.
        foreach (var (turned, expected, seen) in new (int, int, int[])[]
                 {
                     (2, 2, [2, 0]),
                     (1, 3, [2, 0]),
                     (3, 1, [0, 2]),
                 })
        {
            var scorer = LikeALetter();
            var check = OrientationDecision.Check(TextImage.RotatedQuarterTurns(turned), 100, scorer);
            Assert.Equal((OrientationVerdict.Turned, expected), (check.Verdict, check.QuarterTurns));
            Assert.Equal(turned % 2 == 0 ? TextAxis.Horizontal : TextAxis.Vertical, check.Layout.Axis);
            Assert.Equal(seen, scorer.Seen);
        }
    }

    [Fact]
    public void Check_NoReadingClear_TheBestWithAMarginWins()
    {
        // Upright reads 90 letters in words, upside down 40: not clear, but more than twice as many.
        var scorer = new FakeScorer(new OrientationScore(100, 90), new OrientationScore(60, 40), Sideways);
        var check = OrientationDecision.Check(TextImage.RotatedQuarterTurns(2), 100, scorer);
        Assert.Equal((OrientationVerdict.Turned, 2), (check.Verdict, check.QuarterTurns));
        Assert.Equal([2, 0], scorer.Seen);
        var upright = OrientationDecision.Check(TextImage, 100, new FakeScorer(new OrientationScore(100, 90), new OrientationScore(60, 40), Sideways));
        Assert.Equal((OrientationVerdict.Upright, 0, 2), (upright.Verdict, upright.QuarterTurns, upright.Passes));
    }

    [Fact]
    public void Check_ClearReadingTurned_NeedsAMarginOverTheReadingsBefore()
    {
        // As it is: many words but not clear (prices, dates); upside down: clear, but not twice as many.
        var scorer = new FakeScorer(new OrientationScore(200, 140), new OrientationScore(170, 160), Sideways);
        var check = OrientationDecision.Check(TextImage, 100, scorer);
        Assert.Equal((OrientationVerdict.Unsure, 0, 2), (check.Verdict, check.QuarterTurns, check.Passes));
        Assert.Equal([0, 2], scorer.Seen);
        // Twice as many as the reading before: taken.
        var twice = OrientationDecision.Check(TextImage.RotatedQuarterTurns(2), 100,
                                              new FakeScorer(new OrientationScore(300, 280), new OrientationScore(200, 140), Sideways));
        Assert.Equal((OrientationVerdict.Turned, 2, 2), (twice.Verdict, twice.QuarterTurns, twice.Passes));
        // Just under twice as many: left as it is.
        var under = OrientationDecision.Check(TextImage.RotatedQuarterTurns(2), 100,
                                              new FakeScorer(new OrientationScore(300, 280), new OrientationScore(200, 141), Sideways));
        Assert.Equal((OrientationVerdict.Unsure, 0, 2), (under.Verdict, under.QuarterTurns, under.Passes));
    }

    [Fact]
    public void Check_ClearReadingSideways_IsNotTakenBeforeTheOppositeWayIsRead()
    {
        // Lines down the page, upright at turn 3: turn 1 shows it upside down and reads clear (like
        // upside-down text read as words), turn 3 reads twice as many words. Both are read; turn 3 wins.
        var page = TextImage.RotatedQuarterTurns(1);
        var scorer = new FakeScorer(ReadsWell, new OrientationScore(170, 160), Sideways);
        var check = OrientationDecision.Check(page, 100, scorer);
        Assert.Equal(TextAxis.Vertical, check.Layout.Axis);
        Assert.Equal((OrientationVerdict.Turned, 3, 2), (check.Verdict, check.QuarterTurns, check.Passes));
        Assert.Equal([2, 0], scorer.Seen);
        Assert.Equal([1, 3], check.Scores.Select(s => s.QuarterTurns));
        // Turn 3 clear too but not twice as many: neither is taken.
        var close = OrientationDecision.Check(page, 100, new FakeScorer(new OrientationScore(300, 280), new OrientationScore(170, 160), Sideways));
        Assert.Equal((OrientationVerdict.Unsure, 0, 2), (close.Verdict, close.QuarterTurns, close.Passes));
    }

    [Fact]
    public void Check_UnclearText_IsLeftAsIs()
    {
        var scorer = new FakeScorer(new OrientationScore(70, 50), new OrientationScore(50, 30), Sideways);
        var check = OrientationDecision.Check(TextImage.RotatedQuarterTurns(2), 100, scorer);
        Assert.Equal((OrientationVerdict.Unsure, 0), (check.Verdict, check.QuarterTurns));
        Assert.Equal(2, check.Passes);
        var page = Page(TextImage.RotatedQuarterTurns(2));
        Assert.Same(page, new OrientationStep(scorer).Apply(page));
    }

    [Fact]
    public void Check_PageWithoutText_IsNotRead()
    {
        var scorer = LikeALetter();
        var check = OrientationDecision.Check(BlankImage, 100, scorer);
        Assert.Equal((OrientationVerdict.NoText, 0, 0), (check.Verdict, check.QuarterTurns, check.Passes));
        Assert.Empty(scorer.Seen);
    }

    [Fact]
    public void Check_StopsReadingWhenThePageTakesTooLong()
    {
        double now = 0;
        var scorer = new FakeScorer(new OrientationScore(70, 50), new OrientationScore(50, 30), Sideways) { OnScore = () => now += 4 };
        var check = OrientationDecision.Check(TextImage.RotatedQuarterTurns(2), 100, scorer, maxSeconds: 3, clock: () => now);
        Assert.Equal((OrientationVerdict.OutOfTime, 0, 1), (check.Verdict, check.QuarterTurns, check.Passes));
        Assert.Equal(4, check.Seconds);
        // Within the time, both ways are read.
        now = 0;
        var slow = new FakeScorer(new OrientationScore(70, 50), new OrientationScore(50, 30), Sideways) { OnScore = () => now += 1 };
        Assert.Equal(2, OrientationDecision.Check(TextImage, 100, slow, maxSeconds: 3, clock: () => now).Passes);
    }

    [Fact]
    public void Check_RecognitionFailing_LeavesThePage()
    {
        var scorer = new FakeScorer(ReadsWell, UpsideDown, Sideways) { Fails = true };
        var check = OrientationDecision.Check(TextImage.RotatedQuarterTurns(2), 100, scorer);
        Assert.Equal((OrientationVerdict.Unsure, 0, 0), (check.Verdict, check.QuarterTurns, check.Passes));
    }

    [Fact]
    public void Check_StopsWhenCancelled()
    {
        using var cancelled = new CancellationTokenSource();
        cancelled.Cancel();
        Assert.ThrowsAny<OperationCanceledException>(() => OrientationDecision.Check(TextImage, 100, LikeALetter(), cancelled.Token));
        // Cancelled during the first reading: the second is not started.
        using var during = new CancellationTokenSource();
        var scorer = new FakeScorer(new OrientationScore(70, 50), UpsideDown, Sideways) { OnScore = during.Cancel };
        Assert.ThrowsAny<OperationCanceledException>(() => OrientationDecision.Check(TextImage, 100, scorer, during.Token));
        Assert.Single(scorer.Seen);
    }

    // MARK: - The step

    [Fact]
    public void Step_TurnsThePageAndItsOtherVersion_KeepingItsFacts()
    {
        var scanned = TextImage.RotatedQuarterTurns(2);
        var page = Page(scanned).WithSide(PageSide.Back, 1)
                                .WithBlank(new BlankPageResult(0.02, 300, false, false))
                                .WithGeometry(scanned, new PageGeometry(false, 1.5, GeometryBasis.TextLines));
        var turned = new OrientationStep(LikeALetter()).Apply(page);
        Assert.Equal("orientation", new OrientationStep(LikeALetter()).Name);
        Assert.Equal(page.Id, turned.Id);
        Assert.Equal(new UprightTurn(2), turned.Upright);
        Assert.Equal(TextImage.Pixels, turned.Image.Pixels);
        Assert.Equal(TextImage.Pixels, turned.Alternate!.Image!.Pixels);
        Assert.Equal(0, turned.RotationQuarterTurns);
        Assert.Equal((PageSide.Back, 1), (turned.Side, turned.SheetIndex));
        Assert.Equal(page.Blank, turned.Blank);
        Assert.Equal(page.Geometry, turned.Geometry);
        // Upright already: unchanged, nothing recorded.
        var upright = Page(TextImage);
        Assert.Same(upright, new OrientationStep(LikeALetter()).Apply(upright));
    }

    [Fact]
    public void Step_DoesNotReadBlankPagesOrSeparatorSheets()
    {
        var scorer = LikeALetter();
        var step = new OrientationStep(scorer);
        var blank = Page(TextImage.RotatedQuarterTurns(2)).WithBlank(new BlankPageResult(0.00001, 1, false, true));
        var separator = Page(TextImage.RotatedQuarterTurns(2)).WithPatch(PatchCode.PatchT);
        Assert.Same(blank, step.Apply(blank));
        Assert.Same(separator, step.Apply(separator));
        Assert.Empty(scorer.Seen);
        // A page checked and found not blank is read.
        var printed = Page(TextImage.RotatedQuarterTurns(2)).WithBlank(new BlankPageResult(0.02, 300, false, false));
        Assert.Equal(new UprightTurn(2), step.Apply(printed).Upright);
    }

    [Fact]
    public void Step_DoesNotReadBarcodeSeparatorSheets_ButTurnsPagesACodeStartsADocumentWith()
    {
        var scorer = LikeALetter();
        var split = new DocumentOptions { SplitMode = SplitMode.Barcode };
        var sheet = Page(TextImage.RotatedQuarterTurns(2))
            .WithBarcodes([new BarcodeReading(BarcodeSymbology.QrCode, "CS-SEP Lease", new RectD(10, 10, 20, 20))]);
        Assert.Same(sheet, new OrientationStep(scorer, split: split).Apply(sheet));
        Assert.Empty(scorer.Seen);
        // Without the split's options, or under another split, the page is read.
        Assert.Equal(new UprightTurn(2), new OrientationStep(LikeALetter()).Apply(sheet).Upright);
        var patchSplit = new DocumentOptions { SplitMode = SplitMode.SeparatorSheet };
        Assert.Equal(new UprightTurn(2), new OrientationStep(LikeALetter(), split: patchSplit).Apply(sheet).Upright);
        // A code of the page's own (no separator code) is read.
        var invoice = Page(TextImage.RotatedQuarterTurns(2))
            .WithBarcodes([new BarcodeReading(BarcodeSymbology.Code128, "ORDER-4711", new RectD(10, 10, 20, 2))]);
        Assert.Equal(new UprightTurn(2), new OrientationStep(LikeALetter(), split: split).Apply(invoice).Upright);
        // A barcode starting a document keeps the page: it is turned upright.
        var starts = new DocumentOptions { SplitMode = SplitMode.Barcode, BarcodeStartsDocument = true };
        Assert.Equal(new UprightTurn(2), new OrientationStep(LikeALetter(), split: starts).Apply(sheet).Upright);
        // The step keeps its own copy of the options.
        var step = new OrientationStep(LikeALetter(), split: split);
        split.BarcodeStartsDocument = true;
        Assert.False(step.Split!.BarcodeStartsDocument);
    }

    [Fact]
    public void Step_PassesTheTokenOn()
    {
        using var cancelled = new CancellationTokenSource();
        cancelled.Cancel();
        var step = new OrientationStep(LikeALetter());
        Assert.ThrowsAny<OperationCanceledException>(() => step.Apply(Page(TextImage), cancelled.Token));
        var s = new ScanSettings();
        s.Document.AutoRotate = true;
        var processor = PageProcessor.ForScan(s, scorer: LikeALetter());
        Assert.ThrowsAny<OperationCanceledException>(() => processor.Process([Page(TextImage)], cancelled.Token));
    }

    [Fact]
    public void Process_TurnsAPageScannedUpsideDown_Upright()
    {
        var s = new ScanSettings();
        s.Document.AutoRotate = true;
        var result = PageProcessor.ForScan(s, scorer: LikeALetter())
            .Process([Page(TextImage), Page(TextImage.RotatedQuarterTurns(2)), Page(BlankImage)]);
        Assert.Equal([null, new UprightTurn(2), null], result.Pages.Select(p => p.Upright));
        Assert.All(result.Pages.Take(2), p => Assert.Equal(TextImage.Pixels, p.Image.Pixels));
        Assert.Equal(" 1 turned upright.", PageTurns.ScanNote(result.Pages));
        // The preview and the history keep the page as scanned.
        Assert.Equal(TextImage.RotatedQuarterTurns(2).Pixels, result.Arranged[1].Image.Pixels);
    }

    // MARK: - Undoing a turn

    [Fact]
    public void TurnedUpright_TurnsThePixels_AndToggledTurnsThemBack()
    {
        var scanned = TextImage.RotatedQuarterTurns(1);
        var page = Page(scanned).TurnedUpright(3);
        Assert.Equal(new UprightTurn(3), page.Upright);
        Assert.Equal(TextImage.Pixels, page.Image.Pixels);
        Assert.Equal(0, page.RotationQuarterTurns);
        var undone = page.WithUprightToggled();
        Assert.Equal(new UprightTurn(3, Undone: true), undone.Upright);
        Assert.Equal(scanned.Pixels, undone.Image.Pixels);
        Assert.Equal(0, undone.RotationQuarterTurns);
        var again = undone.WithUprightToggled();
        Assert.Equal(new UprightTurn(3), again.Upright);
        Assert.Equal(TextImage.Pixels, again.Image.Pixels);
        Assert.Equal(page.Id, again.Id);
        // No turn, nothing recorded; a page not turned has nothing to undo.
        var plain = Page(TextImage);
        Assert.Same(plain, plain.TurnedUpright(0));
        Assert.Same(plain, plain.TurnedUpright(4));
        Assert.Same(plain, plain.WithUprightToggled());
    }

    [Fact]
    public void WithUprightToggled_SpooledPage_TurnsThroughTheRotation_LikeATurnByHand()
    {
        var preview = TextImage.RotatedQuarterTurns(1).Resized(85, 110);
        var page = Page(TextImage).WithImage(preview, filePath: "page.png", fullPixelSize: new SizeD(850, 1100))
                                  .WithAlternate(new PageVersion(null, "page-other.png", new SizeD(900, 1200)))
                                  .WithUpright(new UprightTurn(1));
        var undone = page.WithUprightToggled();
        Assert.Equal(3, undone.RotationQuarterTurns);
        Assert.Equal(preview.RotatedQuarterTurns(3).Pixels, undone.Image.Pixels);
        Assert.Equal(("page.png", new SizeD(850, 1100)), (undone.FilePath, undone.FullPixelSize));
        Assert.Equal(page.Alternate, undone.Alternate);
        Assert.True(undone.Upright!.Undone);
        var again = undone.WithUprightToggled();
        Assert.Equal(0, again.RotationQuarterTurns);
        Assert.Equal(preview.Pixels, again.Image.Pixels);
        // Turned by the step after spooling (not how the app does it): through the rotation too.
        Assert.Equal(2, Page(TextImage).WithImage(preview, filePath: "page.png").TurnedUpright(2).RotationQuarterTurns);
    }

    [Fact]
    public void WithUprightToggled_PageInMemory_OtherVersionSpooled_TurnsTheFileThroughTheRotation()
    {
        // Shown: the page as scanned, kept in memory (its spool file failed), turned upright by a
        // quarter turn; the other version (cropped and straightened, upright) has a spool file.
        var scanned = TextImage.RotatedQuarterTurns(3);
        var page = Page(TextImage).WithAlternate(new PageVersion(null, "page.png", new SizeD(100, 130)))
                                  .WithUpright(new UprightTurn(1));
        var undone = page.WithUprightToggled();
        Assert.Equal(3, undone.RotationQuarterTurns);
        Assert.Equal(scanned.Pixels, undone.Image.Pixels);
        Assert.Null(undone.FilePath);
        Assert.Equal(page.Alternate, undone.Alternate);
        // Saved from memory, the rotation is not applied again: as scanned.
        Assert.Equal(scanned.Pixels, PdfBuilder.PreparePage(undone, null).Image.Pixels);
        // The other version, read from its file and turned like the page: as scanned too, shown and saved.
        var swapped = undone.WithVersionsSwapped(TextImage.RotatedQuarterTurns(undone.RotationQuarterTurns));
        Assert.Equal(scanned.Pixels, swapped.Image.Pixels);
        Assert.Equal(scanned.Pixels, PdfBuilder.PreparePage(swapped, TextImage).Image.Pixels);
        // Turned upright again: both back upright.
        var again = undone.WithUprightToggled();
        Assert.Equal(0, again.RotationQuarterTurns);
        Assert.Equal(TextImage.Pixels, again.Image.Pixels);
    }

    [Fact]
    public void Upright_SurvivesRebuildingThePage()
    {
        var page = Page(TextImage).TurnedUpright(2)
                                  .WithGeometry(TextImage, new PageGeometry(true, 0, GeometryBasis.PageEdges));
        var turn = new UprightTurn(2);
        foreach (var rebuilt in new[]
                 {
                     page.WithImage(RgbaImage.Filled(3, 3, 0, 0, 0)),
                     page.RotatedClockwise(),
                     page.WithSide(PageSide.Front, 0),
                     page.WithBlank(null),
                     page.WithInclusion(PageInclusion.Skip),
                     page.WithPatch(null),
                     page.WithDocumentBreak(DocumentBreak.Split),
                     page.WithDocumentLabel("Lease"),
                     page.WithAlternate(null),
                     page.WithVersionsSwapped(TextImage),
                     page.WithGeometry(TextImage, new PageGeometry(false, 2, GeometryBasis.TextLines)),
                     Page(BlankImage).CopyMeta(page),
                 })
        {
            Assert.Equal(turn, rebuilt.Upright);
        }
        Assert.Null(Page(TextImage).Upright);
        Assert.Null(page.WithUpright(null).Upright);
    }

    // MARK: - What the strip and the status say

    [Fact]
    public void PageTurns_SayWhatWasDone_AndWhatOneClickDoes()
    {
        var half = Page(TextImage).TurnedUpright(2);
        Assert.Equal("Turned upright 180°", PageTurns.Caption(half));
        Assert.Equal("Turned upright 90° clockwise", PageTurns.Caption(Page(TextImage).TurnedUpright(1)));
        Assert.Equal("Turned upright 90° counterclockwise", PageTurns.Caption(Page(TextImage).TurnedUpright(3)));
        Assert.Equal("Undo turn", PageTurns.ToggleLabel(half));
        Assert.Equal("Page 2 is turned upright again.", PageTurns.ToggleNote(half, 2));
        var undone = half.WithUprightToggled();
        Assert.Equal("Turned back as scanned", PageTurns.Caption(undone));
        Assert.Equal("Turn upright again", PageTurns.ToggleLabel(undone));
        Assert.Equal("Page 2 is turned back as scanned. It is saved that way.", PageTurns.ToggleNote(undone, 2));
        Assert.Null(PageTurns.Caption(Page(TextImage)));
        Assert.Null(PageTurns.ToggleLabel(Page(TextImage)));
        Assert.Equal(" 2 turned upright.", PageTurns.ScanNote([half, Page(TextImage).TurnedUpright(1), undone, Page(TextImage)]));
        Assert.Equal(" 1 turned upright.", PageTurns.ScanNote([half]));
        Assert.Equal("", PageTurns.ScanNote([undone, Page(TextImage)]));
    }

    [Fact]
    public void PageTurns_Hint_SaysWhyTheSwitchIsOff_OrWhatItDoes()
    {
        var s = new ScanSettings();
        Assert.Equal("Turn pages that are upside down or sideways, by reading their text.", PageTurns.Hint(s, true));
        s.Document.AutoRotate = true;
        Assert.Equal("Pages upside down or sideways are turned when their text makes it clear. Click the turn button on a page to undo it.",
                     PageTurns.Hint(s, true));
        Assert.Equal("Needs a text recognition language, and none is installed.", PageTurns.Hint(s, false));
        Assert.Equal("Only for pages collected before saving: a scan saved at once is kept as scanned.",
                     PageTurns.Hint(new ScanSettings { DocumentMultiPage = false }, true));
        Assert.Equal("Copies print every page as scanned: pages are not turned.",
                     PageTurns.Hint(TaskCatalog.Apply(ScanTask.Copy, new ScanSettings()), true));
        Assert.Equal("Receipts are kept the way they lie on the glass.",
                     PageTurns.Hint(TaskCatalog.Apply(ScanTask.Receipt, new ScanSettings()), true));
        Assert.StartsWith(" Pages were not turned upright", PageTurns.UnavailableNote, StringComparison.Ordinal);
    }
}
