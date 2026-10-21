using CompleteScanner.Core;
using Xunit;

namespace CompleteScanner.Core.Tests;

// Twin of Tests/CompleteScannerTests/BarcodeTests.swift: the same cases, with a stand-in reader.
// The real readers are checked on synthetic scans by the app's tests (ZXing.Net here,
// CompleteScanner.App.Tests/BarcodeReaderTests.cs; Vision on the Mac, VisionBarcodeTests.swift).

public class BarcodeTests
{
    /// <summary>A reader that returns what it was given and records the images it was asked to read.</summary>
    private sealed class FakeReader(params BarcodeReading[] readings) : IBarcodeReader
    {
        public List<GrayImage> Seen { get; } = [];
        public bool IsAvailable { get; init; } = true;
        public Exception? Failure { get; init; }

        public IReadOnlyList<BarcodeReading> Read(GrayImage image, CancellationToken token)
        {
            Seen.Add(image);
            if (Failure is not null) throw Failure;
            return readings;
        }
    }

    private static BarcodeReading Qr(string text, double x = 10, double y = 10) =>
        new(BarcodeSymbology.QrCode, text, new RectD(x, y, 20, 20));

    private static readonly PageFacts Page = new();

    /// <summary>The code of a QR separator sheet naming <paramref name="name"/>: "CS-SEP Lease"; "CS-SEP" for none.</summary>
    private static string Sheet(string? name) => QrSeparatorSheet.Text(name);

    /// <summary>A side of a separator sheet naming <paramref name="name"/>.</summary>
    private static PageFacts Coded(string? name) => new(Barcode: Qr(Sheet(name)));

    /// <summary>A page carrying a code of its own (an invoice's number, a payment QR code): no separator code.</summary>
    private static PageFacts Own(string text) => new(Barcode: Qr(text));

    private static PageFacts Front(int sheet, string? code = null, bool blank = false) =>
        new(sheet, PageSide.Front, blank, Barcode: code is null ? null : Qr(code));

    private static PageFacts Back(int sheet, string? code = null, bool blank = false) =>
        new(sheet, PageSide.Back, blank, Barcode: code is null ? null : Qr(code));

    private static DocumentOptions Options(bool startsDocument = false, bool removeBlankPages = false,
                                           SplitMode mode = SplitMode.Barcode) =>
        new() { SplitMode = mode, BarcodeStartsDocument = startsDocument, RemoveBlankPages = removeBlankPages };

    private static int[][] Documents(SplitPlan plan) => plan.Documents.Select(d => d.Pages.ToArray()).ToArray();

    private static string Roles(SplitPlan plan) => string.Concat(plan.Pages.Select(p => p.Role switch
    {
        PageRole.Content => 'c',
        PageRole.Skipped => 's',
        _ => 'x',
    }));

    private static ScannedPage PageOf(int width = 30, int height = 40, int dpi = 300) =>
        new(RgbaImage.Filled(width, height, 255, 255, 255), dpi, ColorMode.Color);

    // MARK: - Kinds and readings

    [Fact]
    public void Symbologies_TheFourKindsRead()
    {
        Assert.Equal([BarcodeSymbology.QrCode, BarcodeSymbology.Code128, BarcodeSymbology.Code39, BarcodeSymbology.DataMatrix],
                     BarcodeSymbologies.All);
        Assert.Equal(["QR code", "Code 128", "Code 39", "Data Matrix"], BarcodeSymbologies.All.Select(s => s.Label()));
    }

    [Fact]
    public void InReadingOrder_TopToBottomThenLeftToRight_WithoutEmptyOrRepeatedCodes()
    {
        var lower = Qr("lower", 5, 50);
        var right = Qr("right", 40, 10);
        var left = new BarcodeReading(BarcodeSymbology.Code128, "left", new RectD(5, 10, 30, 0));
        var empty = Qr("", 0, 0);
        var again = Qr("right", 60, 70);
        var sameTextOtherKind = new BarcodeReading(BarcodeSymbology.DataMatrix, "right", new RectD(0, 80, 5, 5));
        var ordered = BarcodeSeparators.InReadingOrder([lower, right, empty, left, again, sameTextOtherKind]);
        Assert.Equal([left, right, lower, sameTextOtherKind], ordered);
        // The same corner: by kind, then as read.
        var a = Qr("a", 1, 1);
        var b = new BarcodeReading(BarcodeSymbology.Code39, "b", new RectD(1, 1, 3, 3));
        var c = Qr("c", 1, 1);
        Assert.Equal([a, c, b], BarcodeSeparators.InReadingOrder([b, a, c]));
        Assert.Equal(left, BarcodeSeparators.First(ordered));
        Assert.Null(BarcodeSeparators.First([]));
        Assert.Null(BarcodeSeparators.First(null));
    }

    [Fact]
    public void Read_HandsTheReaderTheGrayCopyAtTheReadingResolution_AndGivesBoundsInThePagesPixels()
    {
        var reader = new FakeReader(Qr("Lease", 20, 40), Qr("Index", 2, 4));
        var image = RgbaImage.Filled(600, 900, 250, 250, 250);
        var found = BarcodeSeparators.Read(image, 300, reader, CancellationToken.None);
        var seen = Assert.Single(reader.Seen);
        Assert.Equal((400, 600, 200.0), (seen.Width, seen.Height, seen.Dpi));
        Assert.Equal(["Index", "Lease"], found.Select(r => r.Text));
        Assert.Equal(new RectD(30, 60, 30, 30), found[1].Bounds);
        // A scan no finer than the reading resolution is read as it is.
        var coarse = new FakeReader(Qr("Lease", 20, 40));
        var same = BarcodeSeparators.Read(RgbaImage.Filled(150, 200, 250, 250, 250), 150, coarse, CancellationToken.None);
        Assert.Equal((150, 200), (coarse.Seen[0].Width, coarse.Seen[0].Height));
        Assert.Equal(new RectD(20, 40, 20, 20), same[0].Bounds);
        using var cancelled = new CancellationTokenSource();
        cancelled.Cancel();
        Assert.ThrowsAny<OperationCanceledException>(() => BarcodeSeparators.Read(image, 300, reader, cancelled.Token));
    }

    [Fact]
    public void ReadPage_ReadsASpooledPagesPreview_AtTheResolutionItHas_BoundsInFullSizePixels()
    {
        // A 2400 × 3000 page at 300 dpi whose preview is 800 × 1000: 100 dpi.
        var preview = new ScannedPage(RgbaImage.Filled(800, 1000, 255, 255, 255), 300, ColorMode.Color,
                                      filePath: "spool.tiff", fullPixelSize: new SizeD(2400, 3000));
        var reader = new FakeReader(Qr("Lease", 20, 40));
        var found = BarcodeSeparators.ReadPage(preview, reader, CancellationToken.None);
        Assert.Equal((800, 1000, 100.0), (reader.Seen[0].Width, reader.Seen[0].Height, reader.Seen[0].Dpi));
        Assert.Equal(new RectD(60, 120, 60, 60), Assert.Single(found).Bounds);
        // Turned a quarter: the longer sides still match.
        var turned = new ScannedPage(RgbaImage.Filled(1000, 800, 255, 255, 255), 300, ColorMode.Color,
                                     filePath: "spool.tiff", fullPixelSize: new SizeD(2400, 3000));
        Assert.Equal(new RectD(60, 120, 60, 60), BarcodeSeparators.ReadPage(turned, reader, CancellationToken.None)[0].Bounds);
        // A page not spooled: its own pixels at its own resolution.
        var whole = new FakeReader(Qr("Lease", 20, 40));
        BarcodeSeparators.ReadPage(PageOf(300, 400, 300), whole, CancellationToken.None);
        Assert.Equal((200, 267, 200.0), (whole.Seen[0].Width, whole.Seen[0].Height, whole.Seen[0].Dpi));
    }

    [Fact]
    public void ReadQueuedPage_ReadsTheSpoolFileTurnedLikeThePage_AndAPreviewShowingNoCodeStaysUnread()
    {
        // A 2400 × 3000 page at 300 dpi whose preview is 800 × 1000; its spool file has every pixel.
        var preview = new ScannedPage(RgbaImage.Filled(800, 1000, 255, 255, 255), 300, ColorMode.Color,
                                      filePath: "spool.png", fullPixelSize: new SizeD(2400, 3000));
        var full = RgbaImage.Filled(2400, 3000, 255, 255, 255);
        var reader = new FakeReader(Qr("Lease", 20, 40));
        var found = BarcodeSeparators.ReadQueuedPage(preview, full, reader, CancellationToken.None);
        Assert.Equal((1600, 2000, 200.0), (reader.Seen[0].Width, reader.Seen[0].Height, reader.Seen[0].Dpi));
        Assert.Equal(new RectD(30, 60, 30, 30), Assert.Single(found!).Bounds);
        // Nothing found on the spool file: read, with no code.
        Assert.Empty(BarcodeSeparators.ReadQueuedPage(preview, full, new FakeReader(), CancellationToken.None)!);
        // Turned a quarter by the user: the spool file, as scanned, is turned like the page.
        var turned = new ScannedPage(RgbaImage.Filled(1000, 800, 255, 255, 255), 300, ColorMode.Color,
                                     filePath: "spool.png", fullPixelSize: new SizeD(2400, 3000)) { RotationQuarterTurns = 1 };
        var turnedReader = new FakeReader();
        BarcodeSeparators.ReadQueuedPage(turned, full, turnedReader, CancellationToken.None);
        Assert.Equal((2000, 1600), (turnedReader.Seen[0].Width, turnedReader.Seen[0].Height));
        // No spool file to read: the preview. Nothing found there leaves the page unread, as a code too
        // fine for the preview may be there; a code found is kept.
        var none = new FakeReader();
        Assert.Null(BarcodeSeparators.ReadQueuedPage(preview, null, none, CancellationToken.None));
        Assert.Equal((800, 1000), (none.Seen[0].Width, none.Seen[0].Height));
        Assert.Equal(new RectD(60, 120, 60, 60),
                     Assert.Single(BarcodeSeparators.ReadQueuedPage(preview, null, new FakeReader(Qr("Lease", 20, 40)), CancellationToken.None)!).Bounds);
        // A page never spooled holds every pixel: nothing found is no code.
        Assert.Empty(BarcodeSeparators.ReadQueuedPage(PageOf(300, 400, 300), null, new FakeReader(), CancellationToken.None)!);
        using var cancelled = new CancellationTokenSource();
        cancelled.Cancel();
        Assert.ThrowsAny<OperationCanceledException>(() => BarcodeSeparators.ReadQueuedPage(preview, full, reader, cancelled.Token));
    }

    // MARK: - Names from codes

    [Fact]
    public void Label_ACodesTextAsADocumentName()
    {
        Assert.Equal("Lease 2026", BarcodeSeparators.Label("  Lease\t2026 \r\n"));
        Assert.Equal("Invoice 42 - March", BarcodeSeparators.Label("Invoice\u000042\u0007 -   March"));
        Assert.Equal("https---example.com-inv-42", BarcodeSeparators.Label("https://example.com/inv/42"));
        Assert.Equal("a-b-c-d-e-f-g-h-i", BarcodeSeparators.Label("a\\b:c*d?e\"f<g>h|i"));
        Assert.Equal("Fatura Şubat №5 東京", BarcodeSeparators.Label("Fatura Şubat №5 東京"));
        Assert.Null(BarcodeSeparators.Label(null));
        Assert.Null(BarcodeSeparators.Label(""));
        Assert.Null(BarcodeSeparators.Label(" \n\t"));
        // The sheet that only splits.
        Assert.Null(BarcodeSeparators.Label("SEPARATOR"));
        Assert.Null(BarcodeSeparators.Label(" separator "));
        Assert.Equal("SEPARATORS", BarcodeSeparators.Label("SEPARATORS"));
        // Invisible format characters are dropped: a byte-order mark, zero-width spaces and joiners,
        // bidi overrides and isolates, which would hide or reorder a file name.
        Assert.Null(BarcodeSeparators.Label("\uFEFFSEPARATOR"));
        Assert.Equal("Invoice 7", BarcodeSeparators.Label("\uFEFFInv\u200Boice\u00A07"));
        Assert.Equal("Invoicetxt.exe", BarcodeSeparators.Label("Invoice\u202Etxt.exe\u202C"));
        Assert.Equal("Lease", BarcodeSeparators.Label("\u2066Lease\u2069\u200D"));
        Assert.Null(BarcodeSeparators.Label("\u200B\uFEFF\u202E"));
        // Cut like a name typed in the page strip.
        string longText = string.Concat(Enumerable.Repeat("0123456789", 12));
        Assert.Equal(longText[..DocumentSplitter.MaxLabelLength], BarcodeSeparators.Label(longText));
    }

    [Fact]
    public void Describe_TheKindAndTheText_CutWhenLong()
    {
        Assert.Equal("QR code “Lease”", BarcodeSeparators.Describe(Qr("Lease")));
        string longText = string.Concat(Enumerable.Repeat("abcdefghij", 5));
        Assert.Equal($"Code 39 “{longText[..39]}…”",
                     BarcodeSeparators.Describe(new BarcodeReading(BarcodeSymbology.Code39, longText, new RectD(0, 0, 1, 1))));
        Assert.Contains("invoices", BarcodeSeparators.StartsDocumentHint(true));
        Assert.Contains("left out", BarcodeSeparators.StartsDocumentHint(false));
        Assert.Contains("starts with “CS-SEP”", BarcodeSeparators.StartsDocumentHint(false));
        Assert.Contains("starts with “DOC”", BarcodeSeparators.StartsDocumentHint(false, " DOC "));
        Assert.DoesNotContain("starts with", BarcodeSeparators.StartsDocumentHint(false, ""));
    }

    // MARK: - The clean-up stage

    [Fact]
    public void BarcodeStep_RecordsTheCodes_AndAPageTheReaderFailsOnStaysUnread()
    {
        var page = PageOf(300, 400, 300);
        Assert.Null(page.Barcodes);
        var read = new BarcodeStep(new FakeReader(Qr("Lease", 20, 40))).Apply(page);
        Assert.Equal("barcode", new BarcodeStep(new FakeReader()).Name);
        Assert.Equal(new RectD(30, 60, 30, 30), Assert.Single(read.Barcodes!).Bounds);
        Assert.Same(page.Image, read.Image);
        var none = new BarcodeStep(new FakeReader()).Apply(page);
        Assert.NotNull(none.Barcodes);
        Assert.Empty(none.Barcodes!);
        var failed = new BarcodeStep(new FakeReader { Failure = new InvalidOperationException("no") }).Apply(page);
        Assert.Null(failed.Barcodes);
        using var cancelled = new CancellationTokenSource();
        cancelled.Cancel();
        Assert.ThrowsAny<OperationCanceledException>(() => new BarcodeStep(new FakeReader()).Apply(page, cancelled.Token));
        Assert.ThrowsAny<OperationCanceledException>(
            () => new BarcodeStep(new FakeReader { Failure = new OperationCanceledException() }).Apply(page, CancellationToken.None));
    }

    [Fact]
    public void ForScan_ReadsBarcodes_OnlyWhenTheStackIsSplitAtBarcodes_AndTheReaderCanRead()
    {
        var reader = new FakeReader();
        var s = new ScanSettings();
        s.Adjustments.Brightness = 0.25;
        foreach (var mode in SplitModes.DisplayOrder.Where(m => m != SplitMode.Barcode))
        {
            s.Document.SplitMode = mode;
            Assert.False(PageProcessor.ReadsBarcodes(s));
            Assert.Equal(["blank", "separator", "adjust"], PageProcessor.ForScan(s, barcodes: reader).Steps.Select(step => step.Name));
        }
        s.Document.SplitMode = SplitMode.Barcode;
        Assert.True(PageProcessor.ReadsBarcodes(s));
        var processor = PageProcessor.ForScan(s, barcodes: reader);
        Assert.Equal(["blank", "separator", "barcode", "adjust"], processor.Steps.Select(step => step.Name));
        Assert.Same(reader, ((BarcodeStep)processor.Steps[2]).Reader);
        Assert.Equal(["blank", "separator", "adjust"], PageProcessor.ForScan(s).Steps.Select(step => step.Name));
        Assert.Equal(["blank", "separator", "adjust"],
                     PageProcessor.ForScan(s, barcodes: new FakeReader { IsAvailable = false }).Steps.Select(step => step.Name));
        // Before turning pages upright.
        s.Document.AutoRotate = true;
        Assert.Equal(["blank", "separator", "barcode", "orientation", "adjust"],
                     PageProcessor.ForScan(s, scorer: new UprightScorer(), barcodes: reader).Steps.Select(step => step.Name));
        // Pages saved at once and photos are never read.
        var atOnce = s.Clone();
        atOnce.DocumentMultiPage = false;
        Assert.False(PageProcessor.ReadsBarcodes(atOnce));
        var photos = s.Clone();
        photos.Intent = ScanIntent.Photo;
        Assert.False(PageProcessor.ReadsBarcodes(photos));
    }

    private sealed class UprightScorer : IOrientationScorer
    {
        public bool IsAvailable => true;
        public OrientationScore Score(RgbaImage image, CancellationToken token) => OrientationScore.Of([]);
    }

    [Fact]
    public void Process_ReadsEveryPage()
    {
        var s = new ScanSettings();
        s.Document.SplitMode = SplitMode.Barcode;
        var reader = new FakeReader(Qr("Lease"));
        var result = PageProcessor.ForScan(s, barcodes: reader).Process([PageOf(), PageOf()]);
        Assert.All(result.Pages, p => Assert.Equal("Lease", Assert.Single(p.Barcodes!).Text));
        Assert.Equal(2, reader.Seen.Count);
    }

    [Fact]
    public void Barcodes_SurviveRebuildingThePage()
    {
        IReadOnlyList<BarcodeReading> codes = [Qr(Sheet("Lease"))];
        var page = PageOf().WithBarcodes(codes);
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
                     page.WithSpineShadow(RgbaImage.Filled(3, 3, 0, 0, 0), new SpineShadowResult(PageEdge.Left, 0.2, 0.5, 1.3, 0)),
                     PageOf().CopyMeta(page),
                 })
        {
            Assert.Same(codes, rebuilt.Barcodes);
        }
        var corrected = page.WithGeometry(RgbaImage.Filled(3, 3, 0, 0, 0), new PageGeometry(false, 1.5, GeometryBasis.TextLines));
        Assert.Same(codes, corrected.WithVersionsSwapped(PageOf().Image).Barcodes);
        Assert.Null(page.WithBarcodes(null).Barcodes);
        Assert.Equal("CS-SEP Lease", PageFacts.Of(page, Options()).Barcode!.Text);
        Assert.Null(PageFacts.Of(PageOf(), Options()).Barcode);
    }

    // MARK: - Splitting at barcode or QR sheets

    [Fact]
    public void BarcodeSheets_OneSided_AreLeftOut_AndNameTheDocumentAfterThem()
    {
        var plan = DocumentSplitter.Plan([Page, Page, Coded("Lease"), Page, Coded("Invoice 42"), Page, Page], Options());
        Assert.Equal([[0, 1], [3], [5, 6]], Documents(plan));
        Assert.Equal("ccxcxcc", Roles(plan));
        Assert.Equal([null, "Lease", "Invoice 42"], plan.Documents.Select(d => d.Label));
        Assert.Equal((2, 0, 5), (plan.SeparatorCount, plan.SkippedCount, plan.PageCount));
        // A sheet in front of the first document names it too; one with no name names nothing.
        var first = DocumentSplitter.Plan([Coded("Lease"), Page, Coded(null), Page], Options());
        Assert.Equal([[1], [3]], Documents(first));
        Assert.Equal(["Lease", null], first.Documents.Select(d => d.Label));
        Assert.Equal("Document 1 · Lease", DocumentSplitter.DividerTitle(first, 1));
    }

    [Fact]
    public void BarcodeSheets_InARow_SplitOnce_TheLastOneNames()
    {
        var plan = DocumentSplitter.Plan([Page, Coded("Old"), Coded("New"), Page, Coded("Named"), Coded(null), Page, Coded("Last")],
                                         Options());
        Assert.Equal([[0], [3], [6]], Documents(plan));
        Assert.Equal([null, "New", null], plan.Documents.Select(d => d.Label));
        Assert.Equal("cxxcxxcx", Roles(plan));
    }

    [Fact]
    public void BarcodeSheets_TwoSided_ACodeOnEitherSide_TheWholeSheetIsLeftOut()
    {
        var facts = new[]
        {
            Front(0), Back(0, blank: true),
            Front(1, blank: true), Back(1, Sheet("Lease")),
            Front(2), Back(2, "PAY 42"),
            Front(3, Sheet("Invoice 7")), Back(3, Sheet("Ignored"), blank: true),
            Front(4), Back(4, blank: true),
        };
        var plan = DocumentSplitter.Plan(facts, Options(removeBlankPages: true));
        Assert.Equal([[0], [4, 5], [8]], Documents(plan));
        Assert.Equal("csxxccxxcs", Roles(plan));
        Assert.Equal([null, "Lease", "Invoice 7"], plan.Documents.Select(d => d.Label));
    }

    [Fact]
    public void OnlyCodesStartingWithThePrefix_MakeSeparatorSheets_OthersAreIgnored()
    {
        // An invoice carrying a payment QR code and an order number, between two separator sheets.
        var facts = new[] { Page, Coded("Lease"), Own("SPC 0200 1 CH4431999123000889012"), Page, Own("ORDER-4711"), Coded(null), Page };
        var plan = DocumentSplitter.Plan(facts, Options());
        Assert.Equal([[0], [2, 3, 4], [6]], Documents(plan));
        Assert.Equal("cxcccxc", Roles(plan));
        Assert.Equal([null, "Lease", null], plan.Documents.Select(d => d.Label));
        // Compared with a–z matching A–Z, after spaces and invisible characters (a byte-order mark).
        Assert.Equal("CS-SEP", BarcodeSeparators.DefaultPrefix);
        Assert.Equal("CS-SEP", new DocumentOptions().SplitBarcodePrefix);
        Assert.True(BarcodeSeparators.StartsWithPrefix("cs-sep Lease", "CS-SEP"));
        Assert.True(BarcodeSeparators.StartsWithPrefix("\uFEFF CS-SEP", " CS-SEP "));
        Assert.False(BarcodeSeparators.StartsWithPrefix("CS-SE", "CS-SEP"));
        Assert.False(BarcodeSeparators.StartsWithPrefix("INVOICE CS-SEP", "CS-SEP"));
        Assert.Equal("Lease", BarcodeSeparators.CodeLabel("cs-sep Lease", Options()));
        Assert.Equal("Lease", BarcodeSeparators.CodeLabel("\uFEFFCS-SEP Lease", Options()));
        Assert.Equal("ORDER-4711", BarcodeSeparators.CodeLabel("ORDER-4711", Options()));
        Assert.Null(BarcodeSeparators.CodeLabel("CS-SEP", Options()));
        Assert.Null(BarcodeSeparators.CodeLabel("CS-SEP \u200B ", Options()));
        Assert.Null(BarcodeSeparators.CodeLabel(null, Options()));
        // On a page with several codes, the first separator code counts, wherever it is; a barcode
        // starting a document takes the first code.
        var page = PageOf().WithBarcodes([Qr("PAY 42", 10, 10), Qr(Sheet("Invoice 7"), 10, 300)]);
        Assert.Equal(Sheet("Invoice 7"), PageFacts.Of(page, Options()).Barcode!.Text);
        Assert.Equal("PAY 42", PageFacts.Of(page, Options(startsDocument: true)).Barcode!.Text);
        Assert.Null(PageFacts.Of(PageOf().WithBarcodes([Qr("PAY 42")]), Options()).Barcode);
        // Another prefix, spaces around it ignored.
        var mine = Options();
        mine.SplitBarcodePrefix = "  DOC: ";
        var custom = DocumentSplitter.Plan([Page, Own("doc: Lease"), Page, Coded("Invoice"), Page], mine);
        Assert.Equal([[0], [2, 3, 4]], Documents(custom));
        Assert.Equal([null, "Lease"], custom.Documents.Select(d => d.Label));
        Assert.Equal("DOC: Lease", QrSeparatorSheet.Text("Lease", mine.SplitBarcodePrefix));
        Assert.Equal("DOC:", QrSeparatorSheet.Text(null, mine.SplitBarcodePrefix));
        // An empty prefix: every code makes a separator sheet, and "SEPARATOR" names nothing.
        var anyCode = Options();
        anyCode.SplitBarcodePrefix = " ";
        var all = DocumentSplitter.Plan([Page, Own("Lease"), Page, Own("separator"), Page], anyCode);
        Assert.Equal([[0], [2], [4]], Documents(all));
        Assert.Equal([null, "Lease", null], all.Documents.Select(d => d.Label));
        Assert.Equal("Lease", QrSeparatorSheet.Text("Lease", ""));
        Assert.Equal("SEPARATOR", QrSeparatorSheet.Text(null, " "));
    }

    [Fact]
    public void BarcodeSheets_KeptByTheUser_AreSavedAndSplitNothing()
    {
        var facts = new[] { Page, Coded("Lease") with { Inclusion = PageInclusion.Keep }, Page };
        var plan = DocumentSplitter.Plan(facts, Options());
        Assert.Equal([[0, 1, 2]], Documents(plan));
        Assert.Equal([null], plan.Documents.Select(d => d.Label));
        Assert.Equal(PageInclusion.Keep, DocumentSplitter.ToggledInclusion([Page, Coded("Lease"), Page], 1, Options()));
    }

    [Fact]
    public void ABarcodeStartsADocument_ThePageIsKept_AndNamesIt()
    {
        var options = Options(startsDocument: true);
        var plan = DocumentSplitter.Plan([Page, Own("Invoice 41"), Page, Page, Own("Invoice 42"), Own("Invoice 43")], options);
        Assert.Equal([[0], [1, 2, 3], [4], [5]], Documents(plan));
        Assert.Equal("cccccc", Roles(plan));
        Assert.Equal([null, "Invoice 41", "Invoice 42", "Invoice 43"], plan.Documents.Select(d => d.Label));
        // The first page with a code: one document, named.
        var first = DocumentSplitter.Plan([Own("Lease"), Page], options);
        Assert.Equal([[0, 1]], Documents(first));
        Assert.Equal("Lease", first.Documents[0].Label);
        // A separator sheet's code does the same, named without its prefix.
        var fromSheets = DocumentSplitter.Plan([Page, Coded("Lease"), Page, Coded(null)], options);
        Assert.Equal([[0], [1, 2], [3]], Documents(fromSheets));
        Assert.Equal([null, "Lease", null], fromSheets.Documents.Select(d => d.Label));
        // Two-sided: a code on the back starts the document at the front.
        var sheets = DocumentSplitter.Plan([Front(0), Back(0), Front(1), Back(1, "Lease"), Front(2), Back(2)], options);
        Assert.Equal([[0, 1], [2, 3, 4, 5]], Documents(sheets));
        Assert.Equal([null, "Lease"], sheets.Documents.Select(d => d.Label));
        // A page with a code that is skipped still starts the document at the next page saved.
        var skipped = DocumentSplitter.Plan([Page, Own("Lease") with { Inclusion = PageInclusion.Skip }, Page], options);
        Assert.Equal([[0], [2]], Documents(skipped));
        Assert.Equal([null, "Lease"], skipped.Documents.Select(d => d.Label));
    }

    [Fact]
    public void TheUsersNamesAndJoinsWin_OverTheCodes()
    {
        var facts = new[] { Page, Coded("Lease"), Page with { Label = "Mine" }, Page, Coded("Invoice"), Page with { Break = DocumentBreak.Join } };
        var plan = DocumentSplitter.Plan(facts, Options());
        Assert.Equal([[0], [2, 3, 5]], Documents(plan));
        Assert.Equal([null, "Mine"], plan.Documents.Select(d => d.Label));
        // A split by hand after a separator does not take its name.
        var split = DocumentSplitter.Plan([Coded("Lease"), Page, Page with { Break = DocumentBreak.Split }], Options());
        Assert.Equal(["Lease", null], split.Documents.Select(d => d.Label));
        // Joined to the document before: the code's name is gone with its document.
        var joined = DocumentSplitter.Plan([Page, Coded("Lease") with { Break = DocumentBreak.Join }, Page], Options(startsDocument: true));
        Assert.Equal([[0, 1, 2]], Documents(joined));
        Assert.Equal([null], joined.Documents.Select(d => d.Label));
    }

    [Fact]
    public void OtherSplits_IgnoreBarcodes()
    {
        var facts = new[] { Page, Coded("Lease"), Page };
        foreach (var mode in new[] { SplitMode.None, SplitMode.SeparatorSheet, SplitMode.BlankSheet, SplitMode.SheetCount })
        {
            var plan = DocumentSplitter.Plan(facts, Options(mode: mode));
            Assert.All(plan.Documents, d => Assert.Null(d.Label));
            Assert.Equal(0, plan.SeparatorCount);
        }
    }

    [Fact]
    public void CarriedLabels_LeaveNamesFromCodesToTheCodes()
    {
        // Skipping the first page of a document named by its separator sheet: no name is written on the pages.
        var before = new[] { Page, Coded("Lease"), Page, Page };
        var after = new[] { Page, Coded("Lease"), Page with { Inclusion = PageInclusion.Skip }, Page };
        Assert.Equal([null, null, null, null], DocumentSplitter.CarriedLabels(before, after, Options()));
        Assert.Equal("Lease", DocumentSplitter.Plan(after, Options()).Documents[1].Label);
        // A name the user gave still moves with its document.
        var named = new[] { Page, Coded("Lease"), Page with { Label = "Mine" }, Page };
        var namedAfter = new[] { Page, Coded("Lease"), Page with { Label = "Mine", Inclusion = PageInclusion.Skip }, Page };
        Assert.Equal([null, null, null, "Mine"], DocumentSplitter.CarriedLabels(named, namedAfter, Options()));
    }

    [Fact]
    public void Texts_ForTheStripAndTheTaskSummary()
    {
        var pages = new List<ScannedPage>
        {
            PageOf(), PageOf().WithBarcodes([Qr(Sheet("Lease"))]), PageOf(), PageOf().WithBarcodes([Qr(Sheet(null))]), PageOf(),
        };
        var options = Options();
        var plan = DocumentSplitter.Plan(pages, options);
        Assert.Equal([[0], [2], [4]], Documents(plan));
        Assert.Equal("Separator", DocumentSplitter.Badge(plan, 1, pages[1], options));
        Assert.Equal("Separator sheet (QR code “CS-SEP Lease”): a new document named “Lease” starts after it. It is not saved.",
                     DocumentSplitter.SeparatorNote(plan, 1, pages[1]));
        Assert.Equal("Separator sheet (QR code “CS-SEP”): a new document starts after it. It is not saved.",
                     DocumentSplitter.SeparatorNote(plan, 3, pages[3]));
        Assert.Null(DocumentSplitter.SeparatorNote(plan, 2, pages[2]));
        Assert.Equal("Document 2 · Lease", DocumentSplitter.DividerTitle(plan, 2));
        Assert.Equal("5 pages · 3 documents · 2 separator pages skipped", DocumentSplitter.QueueSummary(pages, options));
        Assert.Equal(" Found 2 separator pages: 3 documents to save.", DocumentSplitter.ScanNote(plan, 2));
        // The save names the files after the codes.
        var save = SavePlan.Make(pages, options);
        Assert.Equal([null, "Lease", null], save.Documents.Select(d => d.Label));

        var s = TaskCatalog.Apply(ScanTask.Batch, new ScanSettings());
        s.Document.SplitMode = SplitMode.Barcode;
        Assert.Contains("Split at barcode sheets", TaskCatalog.Summary(s));
        s.Document.BarcodeStartsDocument = true;
        Assert.Contains("Split and named at barcodes", TaskCatalog.Summary(s));
    }

    [Fact]
    public void SeparatorNote_NamesTheDocumentThePlanStartsAfterTheSheet()
    {
        // Two code sheets in a row: the last names the document, and both notes say so.
        var pages = new List<ScannedPage>
        {
            PageOf(), PageOf().WithBarcodes([Qr(Sheet("Lease"))]), PageOf().WithBarcodes([Qr(Sheet("Invoice 7"))]), PageOf(),
        };
        var plan = DocumentSplitter.Plan(pages, Options());
        Assert.Equal("Separator sheet (QR code “CS-SEP Lease”): a new document named “Invoice 7” starts after it. It is not saved.",
                     DocumentSplitter.SeparatorNote(plan, 1, pages[1]));
        Assert.Equal("Separator sheet (QR code “CS-SEP Invoice 7”): a new document named “Invoice 7” starts after it. It is not saved.",
                     DocumentSplitter.SeparatorNote(plan, 2, pages[2]));
        // A name the user gives wins.
        pages[3] = pages[3].WithDocumentLabel("Mine");
        var named = DocumentSplitter.Plan(pages, Options());
        Assert.Equal("Separator sheet (QR code “CS-SEP Invoice 7”): a new document named “Mine” starts after it. It is not saved.",
                     DocumentSplitter.SeparatorNote(named, 2, pages[2]));
        // Two-sided, the code on the back only: the front gives the sheet's code too.
        var sheets = new List<ScannedPage>
        {
            PageOf().WithSide(PageSide.Front, 0), PageOf().WithSide(PageSide.Back, 0),
            PageOf().WithSide(PageSide.Front, 1), PageOf().WithSide(PageSide.Back, 1).WithBarcodes([Qr(Sheet("Lease"))]),
            PageOf().WithSide(PageSide.Front, 2), PageOf().WithSide(PageSide.Back, 2),
        };
        var twoSided = DocumentSplitter.Plan(sheets, Options());
        Assert.Equal(Sheet("Lease"), twoSided.Pages[2].Code!.Text);
        Assert.Equal("Separator sheet (QR code “CS-SEP Lease”): a new document named “Lease” starts after it. It is not saved.",
                     DocumentSplitter.SeparatorNote(twoSided, 2, sheets[2]));
        Assert.Equal(DocumentSplitter.SeparatorNote(twoSided, 2, sheets[2]), DocumentSplitter.SeparatorNote(twoSided, 3, sheets[3]));
        // A sheet with nothing after it.
        var last = DocumentSplitter.Plan([PageOf(), PageOf().WithBarcodes([Qr(Sheet("Lease"))])], Options());
        Assert.Equal("Separator sheet (QR code “CS-SEP Lease”): a new document starts after it. It is not saved.",
                     DocumentSplitter.SeparatorNote(last, 1, PageOf().WithBarcodes([Qr(Sheet("Lease"))])));
        // Joined across the sheet: no document starts after it, so none is named.
        var joinedPages = new List<ScannedPage>
        {
            PageOf().WithDocumentLabel("Alpha"), PageOf().WithBarcodes([Qr(Sheet("Lease"))]), PageOf().WithDocumentBreak(DocumentBreak.Join),
        };
        var joined = DocumentSplitter.Plan(joinedPages, Options());
        Assert.Equal([[0, 2]], Documents(joined));
        Assert.Equal("Alpha", joined.Documents[0].Label);
        Assert.Equal("Separator sheet (QR code “CS-SEP Lease”): the pages after it are joined to the document before. It is not saved.",
                     DocumentSplitter.SeparatorNote(joined, 1, joinedPages[1]));
        // Patch codes and other splits carry no code.
        Assert.All(DocumentSplitter.Plan(pages, Options(mode: SplitMode.SeparatorSheet)).Pages, p => Assert.Null(p.Code));
    }

    // MARK: - The QR separator sheet

    /// <summary>A made-up 25 × 25 module pattern, the same on both platforms (not a readable code).</summary>
    private static QrModules Pattern()
    {
        const int size = 25;
        var dark = new bool[size * size];
        for (int y = 0; y < size; y++)
        {
            for (int x = 0; x < size; x++) dark[y * size + x] = (x * 3 + y * 5 + x * y) % 7 < 3;
        }
        return new QrModules(size, dark);
    }

    [Fact]
    public void QrModules_RowByRow()
    {
        var modules = new QrModules(2, [true, false, false, true]);
        Assert.Equal((true, false, false, true), (modules[0, 0], modules[1, 0], modules[0, 1], modules[1, 1]));
        Assert.Throws<ArgumentException>(() => new QrModules(2, [true]));
        Assert.Throws<ArgumentOutOfRangeException>(() => new QrModules(0, []));
    }

    [Fact]
    public void QrSheet_TextAndCaption()
    {
        Assert.Equal("CS-SEP Lease 2026", QrSeparatorSheet.Text(" Lease  2026 "));
        Assert.Equal("CS-SEP", QrSeparatorSheet.Text(null));
        Assert.Equal("CS-SEP", QrSeparatorSheet.Text("  "));
        Assert.Equal("CS-SEP", QrSeparatorSheet.Text("separator"));
        Assert.Equal("Lease 2026", BarcodeSeparators.CodeLabel(QrSeparatorSheet.Text(" Lease  2026 "), new DocumentOptions()));
        Assert.Equal("LEASE 2026", QrSeparatorSheet.Caption("Lease 2026"));
        Assert.Equal("FATURA SUBAT ?5 ??", QrSeparatorSheet.Caption("Fatura Şubat №5 東京"));
        Assert.Equal("CAFE CREME, A-B_C #1+2 & 'X'!", QrSeparatorSheet.Caption("Café crème, a-b_c #1+2 & 'x'!"));
        Assert.Equal("??", QrSeparatorSheet.Caption("😀@"));
    }

    [Fact]
    public void QrSheet_DrawsTheCodeWithItsQuietZone_TheNameAndHowToUseIt()
    {
        var code = Pattern();
        var sheet = QrSeparatorSheet.Render(code, "Lease 2026", 8.5, 11, 100);
        Assert.Equal((850, 1100, 100.0), (sheet.Width, sheet.Height, sheet.Dpi));
        // 2.5 in for 25 modules and 8 of quiet zone: 7 pixels a module, the code 175 pixels wide, centred.
        int module = 250 / (25 + 8);
        Assert.Equal(7, module);
        int x0 = (850 - 25 * module) / 2, y0 = 180 + 4 * module;
        for (int y = 0; y < 25; y++)
        {
            for (int x = 0; x < 25; x++)
            {
                Assert.Equal(code[x, y] ? 0 : 255, sheet[x0 + x * module + 3, y0 + y * module + 3]);
            }
        }
        // The quiet zone is white.
        for (int k = -4 * module; k < 25 * module + 4 * module; k++)
        {
            Assert.Equal(255, sheet[x0 + k, y0 - 4 * module]);
            Assert.Equal(255, sheet[x0 + k, y0 + 25 * module + 4 * module - 1]);
        }
        Assert.Equal(968354098u, TestPages.Checksum(sheet));
        Assert.Equal(501687770u, TestPages.Checksum(QrSeparatorSheet.Render(code, null, 8.5, 11, 100)));
        Assert.Equal(1710040988u, TestPages.Checksum(QrSeparatorSheet.Render(code, "Lease 2026", 210 / 25.4, 297 / 25.4, 150)));
        // A name too long for the line at the smallest type is cut with "...".
        string longName = string.Concat(Enumerable.Repeat("W", 100));
        var cut = QrSeparatorSheet.Render(code, longName, 8.5, 11, 100);
        Assert.NotEqual(TestPages.Checksum(sheet), TestPages.Checksum(cut));
        Assert.Equal(2, QrSeparatorSheet.DrawCaption(new byte[850 * 50], 850, 50, QrSeparatorSheet.Caption(longName), 0, 100));
        Assert.Equal(4, QrSeparatorSheet.DrawCaption(new byte[850 * 50], 850, 50, "LEASE", 0, 100));
        Assert.Equal(3, QrSeparatorSheet.DrawCaption(new byte[850 * 50], 850, 50, new string('W', 40), 0, 100));
    }

    [Fact]
    public void QrSheet_FileNamesAndMessages()
    {
        Assert.Equal("Separator sheet (QR code, Lease 2026, Letter)", QrSeparatorSheet.FileBaseName(" Lease 2026", PaperSize.Letter));
        Assert.Equal("Separator sheet (QR code, A4)", QrSeparatorSheet.FileBaseName(null, PaperSize.A4));
        Assert.Equal("Separator sheet (QR code, a-b, A4)", QrSeparatorSheet.FileBaseName("a/b", PaperSize.A4));
        Assert.Equal("Saved the QR separator sheet for “Lease”: S.pdf. Print it and put it in front of that document; the document is named “Lease”.",
                     QrSeparatorSheet.SavedMessage("S.pdf", "Lease"));
        Assert.Equal("Saved the QR separator sheet: S.pdf. Print as many as you need and put one in front of each document.",
                     QrSeparatorSheet.SavedMessage("S.pdf", ""));
        Assert.Equal("Sent the QR separator sheet for “Lease” to P. Put it in front of that document; the document is named “Lease”.",
                     QrSeparatorSheet.PrintedMessage("P", "Lease"));
        Assert.Equal("Sent the QR separator sheet to P. Put one in front of each document; print more copies as you need them.",
                     QrSeparatorSheet.PrintedMessage("P", null));
        Assert.Equal(300, QrSeparatorSheet.Dpi);
    }

    // MARK: - Code 39

    [Fact]
    public void Code39_ModulesFramedByStars()
    {
        Assert.True(Code39.CanEncode("INVOICE 1002"));
        Assert.True(Code39.CanEncode("A-B.C $/+%"));
        Assert.False(Code39.CanEncode(""));
        Assert.False(Code39.CanEncode("lower"));
        Assert.False(Code39.CanEncode("A*B"));
        Assert.Empty(Code39.Modules("lower"));
        // A character is 6 narrow and 3 wide elements (15 modules); a narrow space between characters.
        var a = Code39.Modules("A");
        Assert.Equal(3 * 15 + 2, a.Count);
        string bits = string.Concat(a.Select(m => m ? '1' : '0'));
        // '*' = 010010100: bar, wide space, bar, space, wide bar, space, wide bar, space, bar.
        Assert.Equal("100010111011101" + "0" + "111010100010111" + "0" + "100010111011101", bits);
    }

    [Fact]
    public void Code39_TheDemoSheet()
    {
        var sheet = Code39.RenderSheet("INVOICE 1002", 8.5, 11, 100);
        Assert.Equal((850, 1100), (sheet.Width, sheet.Height));
        // The bars, 0.02 in a module, 0.8 in tall, 1.8 in from the top, centred.
        int count = Code39.Modules("INVOICE 1002").Count;
        int x0 = (850 - 2 * count) / 2;
        var modules = Code39.Modules("INVOICE 1002");
        for (int i = 0; i < count; i++)
        {
            Assert.Equal(modules[i] ? 0 : 255, sheet[x0 + 2 * i, 180]);
            Assert.Equal(modules[i] ? 0 : 255, sheet[x0 + 2 * i + 1, 259]);
        }
        Assert.Equal(255, sheet[x0 + 1, 260]);
        Assert.Equal(28674273u, TestPages.Checksum(sheet));
        // Text that can't be drawn: the sheet without a code.
        Assert.Equal(255, Code39.RenderSheet("lower", 8.5, 11, 100)[425, 200]);
    }
}
