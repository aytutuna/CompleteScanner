using System.Diagnostics;
using LazyScan.App.Services;
using LazyScan.Core;
using Xunit;
using Xunit.Abstractions;
using ZXing;
using ZXing.Common;

namespace LazyScan.App.Tests;

// The Windows app's barcode reading (ZXingBarcodeReader) and QR sheets (ZXingQrEncoder) on synthetic
// scans: codes drawn at their printed size on a page, "scanned" at common resolutions (each scan
// pixel the mean of the printed ones it covers), with the scanner's noise and a slant. The logic
// around them is in Core's BarcodeTests (a stand-in reader, the same cases as the Mac); the Mac reads
// with Vision (VisionBarcodeTests.swift).
public class BarcodeReaderTests(ITestOutputHelper output)
{
    /// <summary>The printed page, at this resolution before it is scanned.</summary>
    private const int PrintDpi = 600;
    private const byte Paper = 242, Toner = 30;

    private static readonly ZXingBarcodeReader Reader = new();

    /// <summary>A printed page: paper with <paramref name="draw"/>'s marks on it.</summary>
    private static GrayImage Printed(double widthInches, double heightInches, Action<byte[], int, int> draw)
    {
        int w = (int)Math.Round(widthInches * PrintDpi), h = (int)Math.Round(heightInches * PrintDpi);
        var pixels = new byte[w * h];
        Array.Fill(pixels, Paper);
        draw(pixels, w, h);
        return new GrayImage(w, h, pixels, PrintDpi);
    }

    /// <summary>
    /// The code ZXing writes for <paramref name="text"/>, drawn with its top-left corner at
    /// (<paramref name="xInches"/>, <paramref name="yInches"/>), each module
    /// <paramref name="moduleInches"/> wide (and tall for 2D codes; bars <paramref name="barInches"/> tall).
    /// </summary>
    private static Action<byte[], int, int> Code(BarcodeFormat format, string text, double xInches, double yInches,
                                                 double moduleInches, double barInches = 0.5) => (pixels, w, h) =>
    {
        var hints = new Dictionary<EncodeHintType, object> { [EncodeHintType.MARGIN] = 0, [EncodeHintType.CHARACTER_SET] = "UTF-8" };
        // Square Data Matrix codes, the usual shape (ZXing would choose a long one for short texts).
        if (format == BarcodeFormat.DATA_MATRIX) hints[EncodeHintType.DATA_MATRIX_SHAPE] = ZXing.Datamatrix.Encoder.SymbolShapeHint.FORCE_SQUARE;
        var matrix = new MultiFormatWriter().encode(text, format, 0, 0, hints);
        bool oneD = matrix.Height == 1;
        int module = (int)Math.Round(moduleInches * PrintDpi);
        int x0 = (int)Math.Round(xInches * PrintDpi), y0 = (int)Math.Round(yInches * PrintDpi);
        int height = oneD ? (int)Math.Round(barInches * PrintDpi) : matrix.Height * module;
        for (int y = 0; y < height; y++)
        {
            for (int x = 0; x < matrix.Width * module; x++)
            {
                if (matrix[x / module, oneD ? 0 : y / module]) pixels[(y0 + y) * w + x0 + x] = Toner;
            }
        }
    };

    /// <summary>Lines of word-shaped blocks, like printed text (no code in them).</summary>
    private static readonly Action<byte[], int, int> TextLines = (pixels, w, h) =>
    {
        var random = new Random(7);
        int lineHeight = PrintDpi / 6, x = PrintDpi, y = PrintDpi;
        while (y + lineHeight < h - PrintDpi)
        {
            int word = random.Next(PrintDpi / 10, PrintDpi / 2);
            if (x + word > w - PrintDpi)
            {
                x = PrintDpi;
                y += lineHeight;
                continue;
            }
            for (int py = y; py < y + lineHeight / 2; py++)
            {
                for (int px = x; px < x + word; px++)
                {
                    if ((px / 9 + py / 13) % 3 != 0) pixels[py * w + px] = Toner;
                }
            }
            x += word + PrintDpi / 12;
        }
    };

    /// <summary>
    /// <paramref name="page"/> as a scanner delivers it at <paramref name="dpi"/>: averaged down,
    /// turned <paramref name="degrees"/> clockwise about its middle (bilinear, paper beyond the
    /// edges), with Gaussian noise of <paramref name="noise"/> levels.
    /// </summary>
    private static GrayImage Scanned(GrayImage page, int dpi, double degrees = 0, double noise = 6, int seed = 1)
    {
        var scan = page.AtResolution(dpi);
        int w = scan.Width, h = scan.Height;
        var turned = new byte[w * h];
        double radians = degrees * Math.PI / 180, cos = Math.Cos(radians), sin = Math.Sin(radians);
        double cx = w / 2.0, cy = h / 2.0;
        var random = new Random(seed);
        for (int y = 0; y < h; y++)
        {
            for (int x = 0; x < w; x++)
            {
                // The source of this pixel: turned back.
                double dx = x - cx, dy = y - cy;
                double sx = cx + dx * cos + dy * sin, sy = cy - dx * sin + dy * cos;
                double value = Paper;
                int ix = (int)Math.Floor(sx), iy = (int)Math.Floor(sy);
                if (ix >= 0 && iy >= 0 && ix + 1 < w && iy + 1 < h)
                {
                    double fx = sx - ix, fy = sy - iy;
                    value = scan.Pixels[iy * w + ix] * (1 - fx) * (1 - fy) + scan.Pixels[iy * w + ix + 1] * fx * (1 - fy)
                            + scan.Pixels[(iy + 1) * w + ix] * (1 - fx) * fy + scan.Pixels[(iy + 1) * w + ix + 1] * fx * fy;
                }
                double u1 = 1 - random.NextDouble(), u2 = random.NextDouble();
                value += noise * Math.Sqrt(-2 * Math.Log(u1)) * Math.Cos(2 * Math.PI * u2);
                turned[y * w + x] = (byte)Math.Clamp(Math.Round(value), 0, 255);
            }
        }
        return new GrayImage(w, h, turned, dpi);
    }

    /// <summary>The codes on a scanned page, read the way the clean-up stage reads them.</summary>
    private IReadOnlyList<BarcodeReading> Read(GrayImage scan, string what)
    {
        var watch = Stopwatch.StartNew();
        var found = BarcodeSeparators.Read(scan.ToRgba(), (int)scan.Dpi, Reader, CancellationToken.None);
        output.WriteLine($"{what}: {string.Join(", ", found.Select(BarcodeSeparators.Describe))} in {watch.ElapsedMilliseconds} ms");
        return found;
    }

    public static TheoryData<BarcodeFormat, BarcodeSymbology, string, double> Kinds => new()
    {
        { BarcodeFormat.QR_CODE, BarcodeSymbology.QrCode, "Invoice 0042 · März", 0.03 },
        { BarcodeFormat.CODE_128, BarcodeSymbology.Code128, "INV-0042/b", 0.013 },
        { BarcodeFormat.CODE_39, BarcodeSymbology.Code39, "INV-0042", 0.012 },
        { BarcodeFormat.DATA_MATRIX, BarcodeSymbology.DataMatrix, "Lease 2026", 0.03 },
    };

    [Theory]
    [MemberData(nameof(Kinds))]
    public void EachKind_IsRead_AtCommonResolutions_WithNoiseAndASlant(BarcodeFormat format, BarcodeSymbology kind, string text,
                                                                         double moduleInches)
    {
        // Half a letter page, the code away from the middle, some text beside it.
        var page = Printed(8.5, 5.5, (pixels, w, h) =>
        {
            Code(format, text, 1.0, 0.8, moduleInches)(pixels, w, h);
            for (int y = (int)(3.2 * PrintDpi); y < (int)(3.5 * PrintDpi); y++)
            {
                for (int x = PrintDpi; x < (int)(7.5 * PrintDpi); x++)
                {
                    if ((x / 20) % 3 != 0) pixels[y * w + x] = Toner;
                }
            }
        });
        foreach (int dpi in new[] { 150, 200, 300 })
        {
            foreach (double degrees in new[] { 0.0, 2.5, -3 })
            {
                var found = Read(Scanned(page, dpi, degrees, seed: dpi), $"{kind} at {dpi} dpi, {degrees}°");
                var reading = Assert.Single(found);
                Assert.Equal((kind, text), (reading.Symbology, reading.Text));
                // Where it is, in the scan's pixels: near where it was drawn.
                Assert.InRange(reading.Bounds.X, 0.7 * dpi, 1.6 * dpi);
                Assert.InRange(reading.Bounds.Y, 0.5 * dpi, 1.9 * dpi);
            }
        }
    }

    [Fact]
    public void DataMatrix_IsFoundAnywhereOnThePage()
    {
        foreach (var (x, y) in new[] { (0.6, 0.6), (6.8, 0.6), (3.9, 4.8), (0.6, 9.6), (6.8, 9.6) })
        {
            var page = Printed(8.5, 11, Code(BarcodeFormat.DATA_MATRIX, $"DM {x} {y}", x, y, 0.025));
            var reading = Assert.Single(Read(Scanned(page, 200, 1.5), $"Data Matrix at ({x}, {y}) in"));
            Assert.Equal((BarcodeSymbology.DataMatrix, $"DM {x} {y}"), (reading.Symbology, reading.Text));
        }
    }

    [Fact]
    public void SeveralCodes_AreAllRead_InReadingOrder()
    {
        var page = Printed(8.5, 11, (pixels, w, h) =>
        {
            Code(BarcodeFormat.CODE_128, "SECOND", 1, 4, 0.015)(pixels, w, h);
            Code(BarcodeFormat.QR_CODE, "FIRST", 5.5, 1, 0.03)(pixels, w, h);
            Code(BarcodeFormat.CODE_39, "THIRD", 1, 8, 0.015)(pixels, w, h);
        });
        var found = Read(Scanned(page, 200), "three codes");
        Assert.Equal(["FIRST", "SECOND", "THIRD"], found.Select(r => r.Text));
    }

    [Fact]
    public void PagesWithoutCodes_ReadNothing()
    {
        Assert.Empty(Read(Scanned(Printed(8.5, 11, (_, _, _) => { }), 200, noise: 8), "a blank page"));
        Assert.Empty(Read(Scanned(Printed(8.5, 11, TextLines), 200, 1), "a page of text"));
        Assert.Empty(Read(Scanned(Printed(8.5, 11, TextLines), 300, -2), "a page of text at 300 dpi"));
        var patch = PatchCodeDetector.RenderSheet(PatchCode.PatchT, 8.5, 11, 300);
        Assert.Empty(Read(Scanned(patch, 200), "the patch-code sheet"));
    }

    [Theory]
    [InlineData("Lease 2026", 150, 0.0)]
    [InlineData("Fatura Şubat 2026 — №5", 200, 2.0)]
    [InlineData("東京の請求書 0042", 200, -2.0)]
    [InlineData("Αρχείο Ιανουάριος", 300, 1.0)]
    [InlineData(null, 150, -1.5)]
    public void TheQrSeparatorSheet_ReadsBackItsName(string? name, int dpi, double degrees)
    {
        var code = new ZXingQrEncoder().Encode(QrSeparatorSheet.Text(name));
        Assert.NotNull(code);
        var sheet = QrSeparatorSheet.Render(code, name, 8.5, 11, QrSeparatorSheet.Dpi);
        var reading = Assert.Single(Read(Scanned(sheet, dpi, degrees, noise: 8), $"QR sheet “{name}” at {dpi} dpi, {degrees}°"));
        Assert.Equal(BarcodeSymbology.QrCode, reading.Symbology);
        Assert.Equal(QrSeparatorSheet.Text(name), reading.Text);
        Assert.True(BarcodeSeparators.StartsWithPrefix(reading.Text, BarcodeSeparators.DefaultPrefix));
        Assert.Equal(BarcodeSeparators.Label(name), BarcodeSeparators.CodeLabel(reading.Text, new DocumentOptions()));
    }

    [Fact]
    public void TheQrSeparatorSheet_ReadsFromAQueuedPagesPreview()
    {
        // A queued page keeps a preview at most 1600 pixels long: about 145 dpi for a letter page.
        var code = new ZXingQrEncoder().Encode("Lease 2026")!;
        var sheet = Scanned(QrSeparatorSheet.Render(code, "Lease 2026", 8.5, 11, 300), 300, 1);
        var preview = sheet.Downsampled(1236, 1600).ToRgba();
        var page = new ScannedPage(preview, 300, ColorMode.Grayscale, filePath: "spool.tiff", fullPixelSize: new SizeD(2550, 3300));
        var reading = Assert.Single(BarcodeSeparators.ReadPage(page, Reader, CancellationToken.None));
        Assert.Equal("Lease 2026", reading.Text);
        // Bounds in the full page's pixels: the code (21 modules of 0.083 in) is centred, from 2.1 in down.
        Assert.InRange(reading.Bounds.X, 3.2 * 300, 4.0 * 300);
        Assert.InRange(reading.Bounds.Y, 2.1 * 300, 2.8 * 300);
    }

    public static TheoryData<BarcodeFormat, BarcodeSymbology, double, double> SmallCodes => new()
    {
        // Letter: a preview 1600 pixels long is about 145 dpi; legal: about 114 dpi.
        { BarcodeFormat.CODE_39, BarcodeSymbology.Code39, 0.010, 11 },
        { BarcodeFormat.CODE_128, BarcodeSymbology.Code128, 0.010, 14 },
        { BarcodeFormat.CODE_39, BarcodeSymbology.Code39, 0.012, 14 },
    };

    [Theory]
    [MemberData(nameof(SmallCodes))]
    public void AQueuedPage_IsReadOnItsSpoolFile_WhereSmallCodesItsPreviewLosesAreFound(BarcodeFormat format, BarcodeSymbology kind,
                                                                                         double moduleInches, double heightInches)
    {
        const string text = "LS-SEP INV-42";
        var scan = Scanned(Printed(8.5, heightInches, Code(format, text, 1.0, 1.0, moduleInches)), 300, seed: 3);
        var full = scan.ToRgba();
        // Read during the scan: found.
        Assert.Equal(text, Assert.Single(Read(scan, $"{kind} {moduleInches} in, 8.5 × {heightInches} in, as scanned")).Text);
        // Queued: the page keeps a preview at most 1600 pixels long; its spool file has every pixel.
        var preview = ScanHistory.MakePreview(full, 1600);
        var queued = new ScannedPage(preview, 300, ColorMode.Grayscale, filePath: "spool.png", fullPixelSize: new SizeD(full.Width, full.Height));
        Assert.Empty(BarcodeSeparators.ReadPage(queued, Reader, CancellationToken.None));
        // Read on the preview alone, a page showing no code is not taken as one without: it stays unread.
        Assert.Null(BarcodeSeparators.ReadQueuedPage(queued, null, Reader, CancellationToken.None));
        var watch = Stopwatch.StartNew();
        var reading = Assert.Single(BarcodeSeparators.ReadQueuedPage(queued, full, Reader, CancellationToken.None)!);
        output.WriteLine($"queued {kind} {moduleInches} in on its spool file: {BarcodeSeparators.Describe(reading)} in {watch.ElapsedMilliseconds} ms");
        Assert.Equal((kind, text), (reading.Symbology, reading.Text));
        Assert.InRange(reading.Bounds.X, 0.8 * 300, 1.3 * 300);
        Assert.InRange(reading.Bounds.Y, 0.8 * 300, 1.6 * 300);
    }

    [Fact]
    public void TheDemoScannersCode39Sheet_ReadsAsItsText()
    {
        // The demo's sheets carry the separator prefix and a name (MockBedRenderer.BatchBarcodeText).
        foreach (int dpi in new[] { 100, 150, 300 })
        {
            var sheet = Code39.RenderSheet("LS-SEP INVOICE 1002", 8.5, 11, dpi);
            var reading = Assert.Single(Read(Scanned(sheet, dpi, noise: 4), $"the demo sheet at {dpi} dpi"));
            Assert.Equal((BarcodeSymbology.Code39, "LS-SEP INVOICE 1002"), (reading.Symbology, reading.Text));
            Assert.Equal("INVOICE 1002", BarcodeSeparators.CodeLabel(reading.Text, new DocumentOptions()));
        }
        // Every character Code 39 has, as ZXing writes it (its wide elements are two narrow ones, ours three).
        const string all = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ-. $/+%";
        var theirs = new ZXing.OneD.Code39Writer().encode(all, BarcodeFormat.CODE_39, 0, 0,
                                                         new Dictionary<EncodeHintType, object> { [EncodeHintType.MARGIN] = 0 });
        Assert.Equal(Elements(Enumerable.Range(0, theirs.Width).Select(i => theirs[i, 0]).ToList()), Elements(Code39.Modules(all)));
    }

    /// <summary>The bars and spaces of a row of modules: "B" and "S" for narrow ones, "W" and "V" for wide ones.</summary>
    private static string Elements(IReadOnlyList<bool> modules)
    {
        var runs = new List<(bool Bar, int Length)>();
        foreach (bool m in modules)
        {
            if (runs.Count > 0 && runs[^1].Bar == m) runs[^1] = (m, runs[^1].Length + 1);
            else runs.Add((m, 1));
        }
        int narrow = runs.Min(r => r.Length);
        return string.Concat(runs.Select(r => r.Length > narrow ? (r.Bar ? 'W' : 'V') : (r.Bar ? 'B' : 'S')));
    }

    [Fact]
    public void AStack_SplitsAtItsCodeSheets_AndTheirTextNamesTheDocuments()
    {
        var qr = new ZXingQrEncoder();
        // A document page: text, n marks, and maybe a code of its own (an order number) at the top.
        GrayImage Document(int n, string? own = null) => Printed(8.5, 11, (pixels, w, h) =>
        {
            TextLines(pixels, w, h);
            if (own is not null) Code(BarcodeFormat.CODE_128, own, 4.5, 0.3, 0.015, 0.4)(pixels, w, h);
            for (int k = 0; k < n; k++)
            {
                for (int y = 10 * PrintDpi; y < 10 * PrintDpi + 60; y++)
                {
                    for (int x = PrintDpi + k * 120; x < PrintDpi + k * 120 + 60; x++) pixels[y * w + x] = Toner;
                }
            }
        });
        var stack = new[]
        {
            Document(1),
            QrSeparatorSheet.Render(qr.Encode(QrSeparatorSheet.Text("Lease 2026"))!, "Lease 2026", 8.5, 11, 300),
            Document(2),
            Document(3, "ORDER-4711"),
            Printed(8.5, 11, Code(BarcodeFormat.CODE_128, "LS-SEP INV-7", 2, 2, 0.02, 0.8)),
            Document(4),
            QrSeparatorSheet.Render(qr.Encode(QrSeparatorSheet.Text(null))!, null, 8.5, 11, 300),
            Document(5),
        };
        var pages = stack.Select((page, i) => new ScannedPage(Scanned(page, 200, i % 2 == 0 ? 1 : -1.5, seed: i).ToRgba(), 200, ColorMode.Color))
                         .ToList();
        var settings = TaskCatalog.Apply(ScanTask.Batch, new ScanSettings());
        settings.Document.SplitMode = SplitMode.Barcode;
        var processed = PageProcessor.ForScan(settings, barcodes: Reader).Process(pages).Pages;
        Assert.Equal("ORDER-4711", Assert.Single(processed[3].Barcodes!).Text);
        // The order number on a document's page is no separator code: it splits nothing.
        var plan = DocumentSplitter.Plan(processed, settings.Document);
        Assert.Equal([[0], [2, 3], [5], [7]], plan.Documents.Select(d => d.Pages.ToArray()));
        Assert.Equal([null, "Lease 2026", "INV-7", null], plan.Documents.Select(d => d.Label));
        // A barcode starts a new document: the sheets are kept as their documents' first pages, and
        // every code counts, the order number too.
        settings.Document.BarcodeStartsDocument = true;
        var kept = DocumentSplitter.Plan(processed, settings.Document);
        Assert.Equal([[0], [1, 2], [3], [4, 5], [6, 7]], kept.Documents.Select(d => d.Pages.ToArray()));
        Assert.Equal([null, "Lease 2026", "ORDER-4711", "INV-7", null], kept.Documents.Select(d => d.Label));
    }

    [Fact]
    public void TheQrEncoder_MakesAQrCodesModules()
    {
        var encoder = new ZXingQrEncoder();
        var code = encoder.Encode("SEPARATOR");
        Assert.NotNull(code);
        Assert.Equal(0, (code.Size - 21) % 4);
        // The three finder patterns: a dark 7 × 7 ring with a dark 3 × 3 middle, in three corners.
        foreach (var (cx, cy) in new[] { (0, 0), (code.Size - 7, 0), (0, code.Size - 7) })
        {
            for (int k = 0; k < 7; k++)
            {
                Assert.True(code[cx + k, cy] && code[cx + k, cy + 6] && code[cx, cy + k] && code[cx + 6, cy + k]);
            }
            Assert.False(code[cx + 1, cy + 1]);
            Assert.True(code[cx + 3, cy + 3]);
        }
        Assert.Null(encoder.Encode(""));
        Assert.Null(encoder.Encode(new string('x', 4000)));
        Assert.True(encoder.Encode(new string('漢', DocumentSplitter.MaxLabelLength))!.Size <= 177);
    }
}
