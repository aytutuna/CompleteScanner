using CompleteScanner.Core;
using Xunit;

namespace CompleteScanner.Core.Tests;

// Mirrored by Tests/CompleteScannerTests/DocumentSidesTests.swift: the same cases.

public class DocumentSidesTests
{
    private static (int, int, PageSide)[] Rows(IEnumerable<SidedTransfer> transfers) =>
        [.. transfers.Select(t => (t.TransferIndex, t.SheetIndex, t.Side))];

    private static (PageSide, int, int)[] Rows(ManualInterleave interleave) =>
        [.. interleave.Order.Select(p => (p.Batch, p.Index, p.SheetIndex))];

    // MARK: - Sides of a feeder scan

    [Fact]
    public void AssignSides_OneSided_EveryTransferIsTheFrontOfItsSheet()
    {
        Assert.Equal([(0, 0, PageSide.Front), (1, 1, PageSide.Front), (2, 2, PageSide.Front)],
                     Rows(DocumentSides.AssignSides(3, duplex: false)));
    }

    [Fact]
    public void AssignSides_TwoSided_SixTransfersAreThreeSheets()
    {
        Assert.Equal(
            [
                (0, 0, PageSide.Front), (1, 0, PageSide.Back),
                (2, 1, PageSide.Front), (3, 1, PageSide.Back),
                (4, 2, PageSide.Front), (5, 2, PageSide.Back),
            ],
            Rows(DocumentSides.AssignSides(6, duplex: true)));
    }

    [Fact]
    public void AssignSides_TwoSided_OddCountEndsWithAFrontOnly()
    {
        var sides = DocumentSides.AssignSides(5, duplex: true);
        Assert.Equal(5, sides.Count);
        Assert.Equal((4, 2, PageSide.Front), Rows(sides)[^1]);
        Assert.Equal(3, sides.Select(t => t.SheetIndex).Distinct().Count());
    }

    [Fact]
    public void AssignSides_ReverseOrder_NumbersTheSheetsFromTheEnd()
    {
        Assert.Equal(
            [(2, 0, PageSide.Front), (3, 0, PageSide.Back), (0, 1, PageSide.Front), (1, 1, PageSide.Back)],
            Rows(DocumentSides.AssignSides(4, duplex: true, reverseOrder: true)));
        Assert.Equal([(2, 0, PageSide.Front), (1, 1, PageSide.Front), (0, 2, PageSide.Front)],
                     Rows(DocumentSides.AssignSides(3, duplex: false, reverseOrder: true)));
    }

    [Fact]
    public void AssignSides_NothingScanned()
    {
        Assert.Empty(DocumentSides.AssignSides(0, duplex: true));
        Assert.Empty(DocumentSides.AssignSides(-2, duplex: false));
    }

    // MARK: - Turning the stack over by hand

    [Fact]
    public void InterleaveManual_ThreeAndThree_TheBacksComeLastSheetFirst()
    {
        var result = DocumentSides.InterleaveManual(3, 3);
        Assert.Equal(
            [
                (PageSide.Front, 0, 0), (PageSide.Back, 2, 0),
                (PageSide.Front, 1, 1), (PageSide.Back, 1, 1),
                (PageSide.Front, 2, 2), (PageSide.Back, 0, 2),
            ],
            Rows(result));
        Assert.False(result.Mismatch);
        Assert.Null(result.MismatchMessage);
    }

    [Fact]
    public void InterleaveManual_BacksInScanOrder()
    {
        Assert.Equal(
            [(PageSide.Front, 0, 0), (PageSide.Back, 0, 0), (PageSide.Front, 1, 1), (PageSide.Back, 1, 1)],
            Rows(DocumentSides.InterleaveManual(2, 2, backsReversed: false)));
    }

    [Fact]
    public void InterleaveManual_ThreeFrontsTwoBacks_PairsWhatItCanAndSaysSo()
    {
        var result = DocumentSides.InterleaveManual(3, 2);
        Assert.Equal(
            [
                (PageSide.Front, 0, 0), (PageSide.Back, 1, 0),
                (PageSide.Front, 1, 1), (PageSide.Back, 0, 1),
                (PageSide.Front, 2, 2),
            ],
            Rows(result));
        Assert.True(result.Mismatch);
        Assert.Equal("3 fronts but 2 backs", result.MismatchMessage);
    }

    [Fact]
    public void InterleaveManual_MoreBacksThanFronts_TheExtraBacksComeLast()
    {
        var result = DocumentSides.InterleaveManual(2, 3);
        Assert.Equal(
            [
                (PageSide.Front, 0, 0), (PageSide.Back, 2, 0),
                (PageSide.Front, 1, 1), (PageSide.Back, 1, 1),
                (PageSide.Back, 0, 2),
            ],
            Rows(result));
        Assert.Equal("2 fronts but 3 backs", result.MismatchMessage);
    }

    [Fact]
    public void InterleaveManual_NoBacks()
    {
        var result = DocumentSides.InterleaveManual(2, 0);
        Assert.Equal([(PageSide.Front, 0, 0), (PageSide.Front, 1, 1)], Rows(result));
        Assert.Equal("2 fronts but 0 backs", result.MismatchMessage);
    }

    [Fact]
    public void CountMessage_SingularAndPlural()
    {
        Assert.Equal("12 fronts but 11 backs", DocumentSides.CountMessage(12, 11));
        Assert.Equal("1 front but 2 backs", DocumentSides.CountMessage(1, 2));
        Assert.Equal("2 fronts but 1 back", DocumentSides.CountMessage(2, 1));
    }

    [Fact]
    public void SideLabel()
    {
        Assert.Equal("Sheet 2 · back", DocumentSides.SideLabel(PageSide.Back, 1));
        Assert.Equal("Sheet 1 · front", DocumentSides.SideLabel(PageSide.Front, 0));
        Assert.Equal("Front", DocumentSides.SideLabel(PageSide.Front, null));
        Assert.Equal("Back", DocumentSides.SideLabel(PageSide.Back, null));
        Assert.Null(DocumentSides.SideLabel(null, 3));
    }

    [Fact]
    public void BackQuarterTurns_ShortEdgeBacksAreUpsideDown()
    {
        Assert.Equal(0, DocumentSides.BackQuarterTurns(DuplexBinding.LongEdge));
        Assert.Equal(2, DocumentSides.BackQuarterTurns(DuplexBinding.ShortEdge));
    }

    [Fact]
    public void ManualSteps_FrontsThenBacks()
    {
        var steps = DocumentSides.ManualSteps;
        Assert.Equal([DocumentSides.FrontsStepId, DocumentSides.BacksStepId], steps.Select(s => s.Id));
        Assert.Equal(["fronts", "backs"], steps.Select(s => s.Id));
        Assert.Equal(["Scan fronts", "Scan backs"], steps.Select(s => s.PrimaryActionLabel));
        Assert.All(steps, step => Assert.True(step.Repeats));
        Assert.True(steps[0].RequiresCapture);
        Assert.False(steps[0].Skippable);
        Assert.False(steps[1].RequiresCapture);
        Assert.True(steps[1].Skippable);
        Assert.Contains("turn it over", steps[1].Prompt);
    }

    // MARK: - What a scan does with the settings

    private static ScanSettings Feeder(DuplexMode duplex) =>
        new() { Source = ScanSource.DocumentFeeder, Duplex = duplex };

    [Fact]
    public void Effective_OnlyTheFeederScansTwoSided()
    {
        Assert.Equal(DuplexMode.Off, DocumentSides.Effective(new ScanSettings { Duplex = DuplexMode.Both }, null));
        Assert.Equal(DuplexMode.Off, DocumentSides.Effective(new ScanSettings { Duplex = DuplexMode.Manual }, null));
        Assert.Equal(DuplexMode.Off, DocumentSides.Effective(Feeder(DuplexMode.Off), null));
    }

    [Fact]
    public void Effective_AOneSidedFeederTurnsTheStackOverByHand()
    {
        var oneSided = new ScannerCapabilities { Sources = [ScanSource.DocumentFeeder], SupportsDuplex = false };
        var twoSided = new ScannerCapabilities { Sources = [ScanSource.DocumentFeeder], SupportsDuplex = true };
        Assert.Equal(DuplexMode.Both, DocumentSides.Effective(Feeder(DuplexMode.Both), null));
        Assert.Equal(DuplexMode.Both, DocumentSides.Effective(Feeder(DuplexMode.Both), twoSided));
        Assert.Equal(DuplexMode.Manual, DocumentSides.Effective(Feeder(DuplexMode.Both), oneSided));
        Assert.Equal(DuplexMode.Manual, DocumentSides.Effective(Feeder(DuplexMode.Manual), twoSided));
    }

    [Fact]
    public void CapabilitiesForSides_AFeederNotYetAskedIsTakenToScanBothSides()
    {
        var unknown = new ScannerCapabilities
        {
            Sources = [ScanSource.Flatbed, ScanSource.DocumentFeeder],
            SupportedResolutions = [150, 300],
            FeederSizeInches = new SizeD(8.5, 14),
            SupportsDuplex = false,
        };
        var assumed = DocumentSides.CapabilitiesForSides(unknown, duplexKnown: false);
        Assert.NotNull(assumed);
        Assert.True(assumed!.SupportsDuplex);
        Assert.False(unknown.SupportsDuplex);
        Assert.Equal(unknown.Sources, assumed.Sources);
        Assert.Equal(unknown.SupportedResolutions, assumed.SupportedResolutions);
        Assert.Equal(unknown.FeederSizeInches, assumed.FeederSizeInches);
        Assert.Equal(DuplexMode.Both, DocumentSides.Effective(Feeder(DuplexMode.Both), assumed));
        Assert.False(DocumentSides.UsesManualSteps(Feeder(DuplexMode.Both), assumed));

        // Known: as reported.
        Assert.Same(unknown, DocumentSides.CapabilitiesForSides(unknown, duplexKnown: true));
        Assert.Equal(DuplexMode.Manual,
                     DocumentSides.Effective(Feeder(DuplexMode.Both), DocumentSides.CapabilitiesForSides(unknown, duplexKnown: true)));
        // Nothing to assume without a feeder or capabilities.
        var flatbed = new ScannerCapabilities { Sources = [ScanSource.Flatbed] };
        Assert.Same(flatbed, DocumentSides.CapabilitiesForSides(flatbed, duplexKnown: false));
        Assert.Null(DocumentSides.CapabilitiesForSides(null, duplexKnown: false));
    }

    [Fact]
    public void UsesManualSteps_DocumentsCollectedIntoOnePdf()
    {
        var oneSided = new ScannerCapabilities { Sources = [ScanSource.DocumentFeeder] };
        Assert.True(DocumentSides.UsesManualSteps(Feeder(DuplexMode.Manual), null));
        Assert.True(DocumentSides.UsesManualSteps(Feeder(DuplexMode.Both), oneSided));
        Assert.False(DocumentSides.UsesManualSteps(Feeder(DuplexMode.Both), null));
        Assert.False(DocumentSides.UsesManualSteps(new ScanSettings { Duplex = DuplexMode.Manual }, null));

        var photos = Feeder(DuplexMode.Manual);
        photos.Intent = ScanIntent.Photo;
        Assert.False(DocumentSides.UsesManualSteps(photos, null));
        Assert.Equal("Turning the stack over by hand works for documents, not photos.",
                     DocumentSides.ManualUnavailableReason(photos));

        var eachSaved = Feeder(DuplexMode.Manual);
        eachSaved.DocumentMultiPage = false;
        Assert.False(DocumentSides.UsesManualSteps(eachSaved, null));
        Assert.Equal("Turning the stack over by hand needs “Collect pages, then Save PDF”.",
                     DocumentSides.ManualUnavailableReason(eachSaved));
        Assert.Null(DocumentSides.ManualUnavailableReason(Feeder(DuplexMode.Manual)));

        // The Copy task is in Document mode, yet copies are made from one side of each sheet.
        var copy = TaskCatalog.Apply(ScanTask.Copy, new ScanSettings());
        copy.Source = ScanSource.DocumentFeeder;
        copy.Duplex = DuplexMode.Manual;
        Assert.Equal(TaskFlowKind.Copy, TaskCatalog.FlowOf(copy));
        Assert.False(DocumentSides.UsesManualSteps(copy, null));
        Assert.Equal("Copies are made from one side of each sheet; turn the stack over and copy again.",
                     DocumentSides.ManualUnavailableReason(copy));
    }

    // MARK: - Pages

    /// <summary>A 2 × 1 page: red on the left, blue on the right, so a half turn shows.</summary>
    private static ScannedPage TwoPixelPage(string? filePath = null)
    {
        var image = new RgbaImage(2, 1, [255, 0, 0, 255, 0, 0, 255, 255]);
        return new ScannedPage(image, 100, ColorMode.Color, filePath: filePath,
                               fullPixelSize: filePath is null ? null : new SizeD(2, 1));
    }

    private static bool RedOnTheLeft(ScannedPage page) => page.Image.Pixels[0] == 255 && page.Image.Pixels[2] == 0;

    [Fact]
    public void ArrangeTwoSided_MarksSidesAndTurnsShortEdgeBacksUpright()
    {
        var pages = Enumerable.Range(0, 4).Select(_ => TwoPixelPage()).ToList();
        var arranged = DocumentSides.ArrangeTwoSided(pages, DuplexBinding.ShortEdge);
        Assert.Equal(pages.Select(p => p.Id), arranged.Select(p => p.Id));
        Assert.Equal([PageSide.Front, PageSide.Back, PageSide.Front, PageSide.Back], arranged.Select(p => p.Side!.Value));
        Assert.Equal([0, 0, 1, 1], arranged.Select(p => p.SheetIndex!.Value));
        Assert.Equal([true, false, true, false], arranged.Select(RedOnTheLeft));
        Assert.All(arranged, page => Assert.Equal(0, page.RotationQuarterTurns));
        // The input is not changed.
        Assert.All(pages, page => Assert.True(page.Side is null && RedOnTheLeft(page)));

        var longEdge = DocumentSides.ArrangeTwoSided(pages, DuplexBinding.LongEdge);
        Assert.All(longEdge, page => Assert.True(RedOnTheLeft(page)));
    }

    [Fact]
    public void ArrangeTwoSided_ReverseOrder()
    {
        var pages = Enumerable.Range(0, 4).Select(_ => TwoPixelPage()).ToList();
        var arranged = DocumentSides.ArrangeTwoSided(pages, DuplexBinding.LongEdge, reverseOrder: true);
        Assert.Equal([pages[2].Id, pages[3].Id, pages[0].Id, pages[1].Id], arranged.Select(p => p.Id));
        Assert.Equal([0, 0, 1, 1], arranged.Select(p => p.SheetIndex!.Value));
    }

    [Fact]
    public void MarkManual_BacksAreTurnedUpright_TheirSheetsComeLater()
    {
        var pages = new[] { TwoPixelPage(), TwoPixelPage() };
        var backs = DocumentSides.MarkManual(pages, PageSide.Back, DuplexBinding.ShortEdge);
        Assert.All(backs, page => Assert.True(page.Side == PageSide.Back && page.SheetIndex is null && !RedOnTheLeft(page)));
        var fronts = DocumentSides.MarkManual(pages, PageSide.Front, DuplexBinding.ShortEdge);
        Assert.All(fronts, page => Assert.True(page.Side == PageSide.Front && RedOnTheLeft(page)));
        var longEdge = DocumentSides.MarkManual(pages, PageSide.Back, DuplexBinding.LongEdge);
        Assert.All(longEdge, page => Assert.True(RedOnTheLeft(page)));
    }

    [Fact]
    public void MarkManual_ASpooledBackTurnsItsPreviewNowAndItsFileWhenSaved()
    {
        var spooled = TwoPixelPage("page.png");
        var back = Assert.Single(DocumentSides.MarkManual([spooled], PageSide.Back, DuplexBinding.ShortEdge));
        Assert.False(RedOnTheLeft(back));
        Assert.Equal(2, back.RotationQuarterTurns);
        Assert.Equal("page.png", back.FilePath);
        Assert.Equal(new SizeD(2, 1), back.FullPixelSize);
    }

    [Fact]
    public void CollateQueue_TheStackTakesThePlaceOfItsFirstPage()
    {
        var ids = Enumerable.Range(0, 8).Select(_ => Guid.NewGuid()).ToArray();
        Guid x = ids[0], f0 = ids[1], f1 = ids[2], f2 = ids[3], y = ids[4], b0 = ids[5], b1 = ids[6], b2 = ids[7];
        var collation = DocumentSides.CollateQueue([x, f0, f1, f2, y, b0, b1, b2], [f0, f1, f2], [b0, b1, b2]);
        Assert.Equal([x, f0, b2, f1, b1, f2, b0, y], collation.Order);
        Assert.Equal(new SheetPosition(0, PageSide.Front), collation.Positions[f0]);
        Assert.Equal(new SheetPosition(0, PageSide.Back), collation.Positions[b2]);
        Assert.Equal(new SheetPosition(2, PageSide.Back), collation.Positions[b0]);
        Assert.False(collation.Positions.ContainsKey(x));
        Assert.False(collation.Interleave.Mismatch);
    }

    [Fact]
    public void CollateQueue_PagesNoLongerQueuedAreLeftOut_AndAMismatchIsReported()
    {
        Guid f0 = Guid.NewGuid(), f1 = Guid.NewGuid(), gone = Guid.NewGuid(), b0 = Guid.NewGuid();
        var collation = DocumentSides.CollateQueue([f0, f1, b0], [f0, f1, gone], [b0]);
        Assert.Equal([f0, b0, f1], collation.Order);
        Assert.True(collation.Interleave.Mismatch);
        Assert.Equal("2 fronts but 1 back", collation.Interleave.MismatchMessage);
        Assert.Equal(new SheetPosition(1, PageSide.Front), collation.Positions[f1]);
    }

    // MARK: - Page facts survive rebuilding the page

    [Fact]
    public void WithImage_KeepsTheIdentityAndWhatTheScanRecorded()
    {
        var page = TwoPixelPage().WithSide(PageSide.Back, 4);
        page.RotationQuarterTurns = 3;
        var other = new RgbaImage(1, 1, [0, 0, 0, 255]);
        var rebuilt = page.WithImage(other, ColorMode.Grayscale, "spool.png", new SizeD(10, 20));
        Assert.Equal((page.Id, page.Dpi, page.CreatedAt, 3), (rebuilt.Id, rebuilt.Dpi, rebuilt.CreatedAt, rebuilt.RotationQuarterTurns));
        Assert.Equal((PageSide.Back, 4), (rebuilt.Side!.Value, rebuilt.SheetIndex!.Value));
        Assert.Same(other, rebuilt.Image);
        Assert.Equal(ColorMode.Grayscale, rebuilt.ColorMode);
        Assert.Equal(("spool.png", new SizeD(10, 20)), (rebuilt.FilePath, rebuilt.FullPixelSize!.Value));
        // Without a color mode or file: the page's color mode, no file.
        var plain = page.WithImage(other);
        Assert.Equal((ColorMode.Color, (string?)null, (SizeD?)null), (plain.ColorMode, plain.FilePath, plain.FullPixelSize));
    }

    [Fact]
    public void CopyMeta_AndRotating_KeepTheSides()
    {
        var source = TwoPixelPage().WithSide(PageSide.Front, 2);
        var copy = TwoPixelPage().CopyMeta(source);
        Assert.Equal((PageSide.Front, 2), (copy.Side!.Value, copy.SheetIndex!.Value));
        var rotated = source.RotatedClockwise();
        Assert.Equal((PageSide.Front, 2, 1), (rotated.Side!.Value, rotated.SheetIndex!.Value, rotated.RotationQuarterTurns));
        Assert.Null(TwoPixelPage().Side);
        Assert.Null(source.WithSide(null, null).SheetIndex);
    }
}
