using LazyScan.Core;
using Xunit;

namespace LazyScan.Core.Tests;

// Mirrored by Tests/LazyScanTests/ReceiptTests.swift: the same cases, on the same synthetic
// beds (TestPages.ReceiptBed) and the same date table (ReceiptDateCases).

public class ReceiptTests
{
    private const byte Ink = 153;     // faded thermal print, 0.6
    private const int Paper = 237;    // thermal paper, 0.93
    private const int Lid = 245;      // a white lid, 0.96

    private static TestPages.Placed LeftReceipt(int paper = Paper) =>
        new(TestPages.Receipt(300, 800, paper, Ink, 40, 0xC0FFEE01), 220, 585, TestPages.Plus3);

    private static TestPages.Placed RightReceipt(int paper = Paper) =>
        new(TestPages.Receipt(300, 800, paper, Ink, 40, 0xC0FFEE02), 630, 585, TestPages.Minus3);

    /// <summary>Every print pixel of the receipt lies inside the region.</summary>
    private static void AssertCoversPrint(DetectedPhotoRegion region, TestPages.Placed receipt, double scale = 1)
    {
        double a = region.AngleDegrees * Math.PI / 180;
        double c = Math.Cos(a), s = Math.Sin(a);
        int outside = 0;
        foreach (var p in TestPages.PrintOnBed(receipt, Ink))
        {
            double dx = p.X * scale - region.Center.X, dy = p.Y * scale - region.Center.Y;
            double u = dx * c + dy * s, v = -dx * s + dy * c;
            if (Math.Abs(u) > region.Size.Width / 2 || Math.Abs(v) > region.Size.Height / 2) outside++;
        }
        Assert.Equal(0, outside);
    }

    [Fact]
    public void Fixtures_AreTheSameOnBothPlatforms()
    {
        var bed = TestPages.ReceiptBed(Lid, 0xBED00001, LeftReceipt(), RightReceipt());
        Assert.Equal(TestPages.BedWidth * TestPages.BedHeight, bed.Pixels.Length);
        Assert.Equal(0xF91D277Du, TestPages.Checksum(bed));
    }

    [Fact]
    public void TwoReceipts_OnAWhiteLid_AreFoundApart_EachHoldingAllItsPrint()
    {
        var left = LeftReceipt();
        var right = RightReceipt();
        var bed = TestPages.ReceiptBed(Lid, 0xBED00001, left, right);
        var found = ReceiptDetector.Find(bed);
        Assert.Equal(2, found.Count);
        // Left to right, as photos are sorted.
        Assert.True(found[0].Region.Center.X < found[1].Region.Center.X);
        AssertCoversPrint(found[0].Region, left);
        AssertCoversPrint(found[1].Region, right);
        Assert.InRange(found[0].Region.AngleDegrees, 3 - 1, 3 + 1);
        Assert.InRange(found[1].Region.AngleDegrees, -3 - 1, -3 + 1);
        // Paper three levels darker than the lid still shows: each is cut along its own edges.
        foreach (var receipt in found)
        {
            Assert.Equal(ReceiptBasis.Paper, receipt.Basis);
            Assert.InRange(Math.Min(receipt.Region.Size.Width, receipt.Region.Size.Height), 296, 306);
            Assert.InRange(Math.Max(receipt.Region.Size.Width, receipt.Region.Size.Height), 796, 806);
        }
    }

    [Fact]
    public void PaperAsLightAsTheLid_IsCutAroundItsPrint()
    {
        var left = LeftReceipt(paper: Lid);
        var right = RightReceipt(paper: Lid);
        var bed = TestPages.ReceiptBed(Lid, 0xBED00002, left, right);
        var found = ReceiptDetector.Find(bed);
        Assert.Equal(2, found.Count);
        AssertCoversPrint(found[0].Region, left);
        AssertCoversPrint(found[1].Region, right);
        Assert.All(found, r => Assert.Equal(ReceiptBasis.Text, r.Basis));
        Assert.InRange(found[0].Region.AngleDegrees, 3 - 1, 3 + 1);
        Assert.InRange(found[1].Region.AngleDegrees, -3 - 1, -3 + 1);
        // Tight: the print (0.2 in in from the paper's sides) plus the margin, not the whole paper.
        foreach (var receipt in found)
        {
            double width = Math.Min(receipt.Region.Size.Width, receipt.Region.Size.Height);
            Assert.InRange(width, 260, 290);
        }
    }

    [Fact]
    public void ALongReceipt_IsTooLongForAPage_ButNotForAReceipt()
    {
        // 2 × 11 in on a darker lid: 5.5 times as long as wide.
        var receipt = new TestPages.Placed(TestPages.Receipt(200, 1100, 240, Ink, 58, 0xC0FFEE03), 425, 585, TestPages.Straight);
        var bed = TestPages.ReceiptBed(200, 0xBED00003, receipt);
        Assert.Equal(PageRejection.NotRectangular, DocumentGeometry.FindPage(bed).Rejection);
        var page = DocumentGeometry.FindPage(bed, ReceiptDetector.PageSearch);
        Assert.Equal(PageRejection.None, page.Rejection);

        var found = Assert.Single(ReceiptDetector.Find(bed));
        Assert.Equal(ReceiptBasis.Paper, found.Basis);
        AssertCoversPrint(found.Region, receipt);
        Assert.InRange(Math.Min(found.Region.Size.Width, found.Region.Size.Height), 196, 206);
        Assert.InRange(Math.Max(found.Region.Size.Width, found.Region.Size.Height), 1096, 1106);
    }

    [Fact]
    public void DefaultPageSearchOptions_AreTheConstants()
    {
        var sheet = TestPages.SheetOnBackdrop(TestPages.Plus3, 120, 245, 0, 0x5EE70001);
        var page = DocumentGeometry.FindPage(sheet).Page!;
        var same = DocumentGeometry.FindPage(sheet, PageSearchOptions.Default).Page!;
        Assert.Equal((page.Center, page.Size, page.AngleDegrees), (same.Center, same.Size, same.AngleDegrees));
        Assert.Equal(DocumentGeometry.PageContrast, PageSearchOptions.Default.PageContrast);
        Assert.Equal(DocumentGeometry.MaxPageAspect, PageSearchOptions.Default.MaxPageAspect);
        Assert.Equal(DocumentGeometry.MinPageFill, PageSearchOptions.Default.MinPageFill);
        Assert.Equal((0.02, 0.85, 15.0), (ReceiptDetector.PageSearch.PageContrast, ReceiptDetector.PageSearch.MinPageFill,
                                          ReceiptDetector.PageSearch.MaxPageAspect));
    }

    [Fact]
    public void PricesFarFromTheItems_StayOnTheirReceipt()
    {
        // The prices stand 1.2 in after the longest item: their column is a block of its own.
        var receipt = new TestPages.Placed(TestPages.Receipt(300, 700, Lid, Ink, 30, 0xC0FFEE04, priceGap: 120), 300, 500, TestPages.Straight);
        var bed = TestPages.ReceiptBed(Lid, 0xBED00004, receipt);
        var found = Assert.Single(ReceiptDetector.Find(bed));
        AssertCoversPrint(found.Region, receipt);
    }

    [Fact]
    public void ReceiptsCloseTogether_StayApart_WhenTheirPaperShows()
    {
        // 0.15 in apart side by side: the left one's prices are nearer the right one's items than its own.
        var left = new TestPages.Placed(TestPages.Receipt(300, 800, Paper, Ink, 40, 0xC0FFEE08), 270, 585, TestPages.Straight);
        var right = new TestPages.Placed(TestPages.Receipt(300, 800, Paper, Ink, 40, 0xC0FFEE09), 585, 585, TestPages.Straight);
        var bed = TestPages.ReceiptBed(Lid, 0xBED00008, left, right);
        var found = ReceiptDetector.Find(bed);
        Assert.Equal(2, found.Count);
        AssertCoversPrint(found[0].Region, left);
        AssertCoversPrint(found[1].Region, right);
    }

    [Fact]
    public void OneReceiptPerScan_TakesEverythingPrinted()
    {
        // Two blocks of print 1.5 in apart: two receipts on the glass, one from the feeder.
        var top = new TestPages.Placed(TestPages.Receipt(300, 300, Lid, Ink, 14, 0xC0FFEE05), 300, 250, TestPages.Straight);
        var bottom = new TestPages.Placed(TestPages.Receipt(300, 300, Lid, Ink, 14, 0xC0FFEE06), 300, 700, TestPages.Straight);
        var bed = TestPages.ReceiptBed(Lid, 0xBED00005, top, bottom);
        Assert.Equal(2, ReceiptDetector.Find(bed).Count);
        var one = Assert.Single(ReceiptDetector.Find(bed, new ReceiptDetectorOptions { SingleReceipt = true }));
        AssertCoversPrint(one.Region, top);
        AssertCoversPrint(one.Region, bottom);
        Assert.Single(ReceiptDetector.Find(bed, new ReceiptDetectorOptions { MaxReceipts = 1 }));
    }

    [Fact]
    public void NothingOnTheGlass_FindsNoReceipt()
    {
        Assert.Empty(ReceiptDetector.Find(TestPages.ReceiptBed(Lid, 0xBED00006)));
        // Dust and a scrap too small to be a receipt.
        var scrap = new TestPages.Placed(TestPages.Receipt(80, 60, Paper, Ink, 2, 0xC0FFEE07), 400, 400, TestPages.Straight);
        Assert.Empty(ReceiptDetector.Find(TestPages.ReceiptBed(Lid, 0xBED00007, scrap)));
    }

    [Fact]
    public void FullResolutionScan_GivesTheSameReceipts()
    {
        var left = LeftReceipt();
        var right = RightReceipt();
        var bed = TestPages.ReceiptBed(Lid, 0xBED00001, left, right);
        var scan = TestPages.Enlarged(bed, 3);
        var regions = ReceiptDetector.DetectRegions(scan, 300);
        Assert.Equal(2, regions.Count);
        AssertCoversPrint(regions[0], left, scale: 3);
        AssertCoversPrint(regions[1], right, scale: 3);
        var analysis = ReceiptDetector.Find(bed);
        for (int i = 0; i < 2; i++)
        {
            Assert.InRange(regions[i].Center.X, analysis[i].Region.Center.X * 3 - 9, analysis[i].Region.Center.X * 3 + 9);
            Assert.InRange(regions[i].Center.Y, analysis[i].Region.Center.Y * 3 - 9, analysis[i].Region.Center.Y * 3 + 9);
        }
        // Cut out and cleaned up: upright, gray, about 3 × 8 in.
        var receipt = ReceiptDetector.ExtractEnhanced(scan, regions[0], 300)!;
        Assert.InRange(receipt.Width, 880, 930);
        Assert.InRange(receipt.Height, 2380, 2430);
    }

    // MARK: Enhancer

    /// <summary>A 3 × 4 in receipt at 100 dpi: paper darkening from 0.95 at the top to 0.80 at the bottom, with print at 0.62.</summary>
    private static RgbaImage FadedReceipt(out bool[] print)
    {
        const int w = 300, h = 400;
        var gray = new byte[w * h];
        print = new bool[w * h];
        for (int y = 0; y < h; y++)
        {
            byte paper = (byte)((242 * (h - 1 - y) + 204 * y) / (h - 1));
            for (int x = 0; x < w; x++) gray[y * w + x] = paper;
        }
        var rng = new TestPages.Rng(0xFADE0001);
        for (int line = 0; line < 20; line++)
        {
            int y = 20 + line * 18;
            int x = 20;
            while (x < w - 40)
            {
                int length = 5 + rng.Below(30);
                for (int py = y; py < y + 6; py++)
                {
                    for (int px = x; px < Math.Min(w - 20, x + length); px++)
                    {
                        gray[py * w + px] = 158;
                        print[py * w + px] = true;
                    }
                }
                x += length + 8 + rng.Below(10);
            }
        }
        var rgba = new byte[w * h * 4];
        for (int i = 0; i < gray.Length; i++)
        {
            rgba[i * 4] = rgba[i * 4 + 1] = rgba[i * 4 + 2] = gray[i];
            rgba[i * 4 + 3] = 255;
        }
        return new RgbaImage(w, h, rgba);
    }

    [Fact]
    public void Enhancer_WhitensFadingPaper_AndDarkensFadedPrint()
    {
        var image = FadedReceipt(out var print);
        var enhanced = ReceiptEnhancer.Enhance(image, 100);
        Assert.Equal((image.Width, image.Height), (enhanced.Width, enhanced.Height));
        int paperMin = 255, printMax = 0;
        for (int i = 0; i < print.Length; i++)
        {
            byte r = enhanced.Pixels[i * 4], g = enhanced.Pixels[i * 4 + 1], b = enhanced.Pixels[i * 4 + 2];
            Assert.True(r == g && g == b);
            Assert.Equal(255, enhanced.Pixels[i * 4 + 3]);
            if (print[i]) printMax = Math.Max(printMax, r);
            else paperMin = Math.Min(paperMin, r);
        }
        Assert.True(paperMin >= 242, $"paper {paperMin}");     // ≥ 0.95
        Assert.True(printMax <= 153, $"print {printMax}");     // ≤ 0.60
    }

    [Fact]
    public void Enhancer_KeepsALittlePrintFromTurningGray()
    {
        // One short line on a whole receipt: under 1 % of the pixels, so the darkest print is capped.
        const int w = 300, h = 400;
        var image = RgbaImage.Filled(w, h, 236, 236, 236);
        for (int y = 200; y < 206; y++)
        {
            for (int x = 40; x < 140; x++)
            {
                int i = (y * w + x) * 4;
                image.Pixels[i] = image.Pixels[i + 1] = image.Pixels[i + 2] = 150;
            }
        }
        var enhanced = ReceiptEnhancer.Enhance(image, 100);
        Assert.Equal(255, enhanced.Pixels[(10 * w + 10) * 4]);
        Assert.True(enhanced.Pixels[(203 * w + 90) * 4] <= 40);
    }

    [Fact]
    public void Enhancer_LeavesADarkLogoDark()
    {
        // A solid 1 in black block: its tiles' paper is the floor below the middle tile, not the block.
        const int w = 300, h = 400;
        var image = RgbaImage.Filled(w, h, 236, 236, 236);
        for (int y = 50; y < 150; y++)
        {
            for (int x = 100; x < 200; x++)
            {
                int i = (y * w + x) * 4;
                image.Pixels[i] = image.Pixels[i + 1] = image.Pixels[i + 2] = 30;
            }
        }
        var enhanced = ReceiptEnhancer.Enhance(image, 100);
        Assert.True(enhanced.Pixels[(100 * w + 150) * 4] <= 20);
        Assert.Equal(255, enhanced.Pixels[(300 * w + 150) * 4]);
    }

    // MARK: Dates

    private static readonly DocumentDate Today = new(2026, 10, 19);

    private static string? Find(string text, bool dayFirst) =>
        ReceiptDateExtractor.FindDate(text.Split('\n'), Today, dayFirst)?.ToString();

    [Fact]
    public void Dates_ThePlanCases()
    {
        Assert.Equal("2025-03-12", Find("12/03/2025", dayFirst: true));
        Assert.Equal("2025-12-03", Find("12/03/2025", dayFirst: false));
        Assert.Equal("2025-12-31", Find("31/12/25", dayFirst: false));
        Assert.Equal("2026-01-05", Find("2026-01-05", dayFirst: true));
        Assert.Equal("2026-01-05", Find("Jan 5, 2026", dayFirst: true));
        Assert.Null(Find("12/03/2030", dayFirst: true));
        Assert.Null(Find("12:30", dayFirst: true));
        Assert.Null(Find("Tel 12.34.56", dayFirst: true));
    }

    [Fact]
    public void Dates_RangeIsTenYearsBackToTomorrow()
    {
        Assert.Equal("2026-10-20", Find("20.10.2026", dayFirst: true));
        Assert.Null(Find("21.10.2026", dayFirst: true));
        Assert.Equal("2016-10-19", Find("19.10.2016", dayFirst: true));
        Assert.Null(Find("18.10.2016", dayFirst: true));
        Assert.Null(Find("29.02.2026", dayFirst: true));
        Assert.Equal("2024-02-29", Find("29.02.2024", dayFirst: true));
    }

    [Fact]
    public void Dates_DateLinesWin_ValidityLinesDoNot()
    {
        Assert.Equal("2026-09-14", Find("Printed 01.09.2026\nTarih: 14.09.2026", dayFirst: true));
        Assert.Equal("2026-10-02", Find("Valid until 2026-10-18\n2026-10-02 18:03", dayFirst: true));
        Assert.Null(Find("EXP 10/03/2026", dayFirst: false));
    }

    [Fact]
    public void Dates_AWordThatIsNotAMonthDoesNotHideTheDate()
    {
        // "4 sat 18" reads like a day, a month name and a year; it must not use up the "18" of the date.
        Assert.Equal("2026-04-18", Find("TABLE 4 SAT 18 APR 2026 10:41", dayFirst: false));
        Assert.Equal("2026-03-12", Find("Reg 3 Fri 12 Mar 2026", dayFirst: true));
        Assert.Equal("2026-03-15", Find("Till 2 Sun Mar 15, 2026", dayFirst: false));
        Assert.Equal([new DocumentDate(2026, 4, 18)], ReceiptDateExtractor.DatesIn("table 4 sat 18 apr 2026 10:41", preferDayFirst: false));
        // The patterns take every month name, the longest first, and nothing else.
        var names = ReceiptDateExtractor.MonthAlternation.Split('|');
        Assert.Equal(ReceiptDateExtractor.MonthNames.Keys.Order(StringComparer.Ordinal), names.Order(StringComparer.Ordinal));
        Assert.Equal(names.Select(n => n.Length).OrderByDescending(n => n), names.Select(n => n.Length));
    }

    [Fact]
    public void Dates_AccuracyOnTheTestSet()
    {
        var misses = new List<string>();
        var byCategory = new Dictionary<string, (int Right, int Total)>();
        foreach (var c in ReceiptDateCases.All)
        {
            string? got = ReceiptDateExtractor.FindDate(c.Lines, Today, c.DayFirst)?.ToString();
            bool right = got == c.Expected;
            var (r, t) = byCategory.GetValueOrDefault(c.Category);
            byCategory[c.Category] = (r + (right ? 1 : 0), t + 1);
            if (!right) misses.Add($"{c.Category}: {string.Join(" | ", c.Lines)} -> {got ?? "none"} (expected {c.Expected ?? "none"})");
        }
        // Every case of the set is read as a person reads it, except the known misses of OCR noise.
        Assert.Equal(ReceiptDateCases.KnownMisses, misses.Count);
        Assert.All(misses, m => Assert.StartsWith("OCR noise", m));
        Assert.True(byCategory.Values.Sum(v => v.Total) >= 90);
    }

    [Fact]
    public void Fold_LowersAndDropsAccents()
    {
        Assert.Equal("tarih 12 mart 2026 persembe", ReceiptDateExtractor.Fold("TARİH 12 Mart 2026 Perşembe"));
        Assert.Equal("12. marz 2026", ReceiptDateExtractor.Fold("12. März 2026"));
        Assert.Equal("1 fevrier aout eylul aralik", ReceiptDateExtractor.Fold("1 février août Eylül Aralık"));
        Assert.Equal("12 mai", ReceiptDateExtractor.Fold("12 Mai"));
        Assert.Equal("2026年3月12日", ReceiptDateExtractor.Fold("2026年3月12日"));
    }

    [Fact]
    public void PrefersDayFirst_FromTheShortDatePattern()
    {
        Assert.True(ReceiptDateExtractor.PrefersDayFirst("dd.MM.yyyy"));
        Assert.True(ReceiptDateExtractor.PrefersDayFirst("d/M/yyyy"));
        Assert.False(ReceiptDateExtractor.PrefersDayFirst("M/d/yyyy"));
        Assert.False(ReceiptDateExtractor.PrefersDayFirst("yyyy-MM-dd"));
        Assert.False(ReceiptDateExtractor.PrefersDayFirst(""));
    }

    // MARK: DocumentDate

    [Fact]
    public void DocumentDate_Calendar()
    {
        Assert.True(DocumentDate.IsValid(2024, 2, 29));
        Assert.False(DocumentDate.IsValid(2025, 2, 29));
        Assert.False(DocumentDate.IsValid(1900, 2, 29));
        Assert.True(DocumentDate.IsValid(2000, 2, 29));
        Assert.False(DocumentDate.IsValid(2026, 4, 31));
        Assert.False(DocumentDate.IsValid(2026, 13, 1));
        Assert.False(DocumentDate.IsValid(2026, 0, 1));
        Assert.Null(DocumentDate.TryCreate(2026, 6, 31));
        Assert.Equal(0, new DocumentDate(1970, 1, 1).DayNumber);
        Assert.Equal(20544, new DocumentDate(2026, 4, 1).DayNumber);
        Assert.Equal(1, new DocumentDate(2026, 3, 1).DayNumber - new DocumentDate(2026, 2, 28).DayNumber);
        Assert.Equal(new DocumentDate(2023, 2, 28), new DocumentDate(2024, 2, 29).AddingYears(-1));
        Assert.Equal("2026-03-05", new DocumentDate(2026, 3, 5).ToString());
        Assert.True(new DocumentDate(2026, 3, 5) < new DocumentDate(2026, 3, 6));
        Assert.True(new DocumentDate(2025, 12, 31) < new DocumentDate(2026, 1, 1));
        Assert.Equal(new DocumentDate(2026, 10, 19), DocumentDate.Of(new DateTime(2026, 10, 19, 23, 59, 0)));
    }

    // MARK: What the task shows

    [Fact]
    public void Receipts_TitlesAndMessages()
    {
        Assert.Equal("Found 4 receipts", Receipts.ReviewTitle(4));
        Assert.Equal("Found 1 receipt", Receipts.ReviewTitle(1));
        Assert.Equal("Save 3 Receipts", Receipts.SaveTitle(3, combine: false, OutputFormat.Pdf));
        Assert.Equal("Save 1 Receipt", Receipts.SaveTitle(1, combine: true, OutputFormat.Pdf));
        Assert.Equal("Save as One PDF", Receipts.SaveTitle(3, combine: true, OutputFormat.Pdf));
        Assert.Equal("Save as One PDF", Receipts.SaveTitle(3, combine: true, OutputFormat.Word));
        Assert.Equal("Save 3 Receipts", Receipts.SaveTitle(3, combine: true, OutputFormat.Jpeg));
        Assert.Equal("Saved 2 receipts: a.pdf, b.pdf", Receipts.SavedMessage(2, ["a.pdf", "b.pdf"], combined: false, undated: 0));
        Assert.Equal("Saved 3 receipts in one PDF: a.pdf", Receipts.SavedMessage(3, ["a.pdf"], combined: true, undated: 0));
        Assert.Equal("Saved 1 receipt: a.pdf. No date was found on it; it is named by today's date.",
                     Receipts.SavedMessage(1, ["a.pdf"], combined: false, undated: 1));
        Assert.Equal("Saved 3 receipts: a, b, c. No date was found on 1 of them; it is named by today's date.",
                     Receipts.SavedMessage(3, ["a", "b", "c"], combined: false, undated: 1));
        Assert.Equal("Saved 3 receipts: a, b, c. No date was found on 2 of them; they are named by today's date.",
                     Receipts.SavedMessage(3, ["a", "b", "c"], combined: false, undated: 2));
        Assert.Equal("Saved 2 receipts: a, b. No date was found on them; they are named by today's date.",
                     Receipts.SavedMessage(2, ["a", "b"], combined: false, undated: 2));
        // One PDF is named by the earliest date found: by today's only when no receipt had a date.
        Assert.Equal("Saved 3 receipts in one PDF: a.pdf", Receipts.SavedMessage(3, ["a.pdf"], combined: true, undated: 1));
        Assert.Equal("Saved 3 receipts in one PDF: a.pdf", Receipts.SavedMessage(3, ["a.pdf"], combined: true, undated: 2));
        Assert.Equal("Saved 3 receipts in one PDF: a.pdf. No date was found on them; the PDF is named by today's date.",
                     Receipts.SavedMessage(3, ["a.pdf"], combined: true, undated: 3));
    }

    [Fact]
    public void Receipts_CombinedDateIsTheEarliest()
    {
        Assert.Equal(new DocumentDate(2026, 3, 2),
                     Receipts.CombinedDate([new DocumentDate(2026, 3, 15), null, new DocumentDate(2026, 3, 2)]));
        Assert.Null(Receipts.CombinedDate([null, null]));
        Assert.Null(Receipts.CombinedDate([]));
    }

    [Fact]
    public void Receipts_ReadTextForTheDateOrTheTextLayer()
    {
        var s = TaskCatalog.Apply(ScanTask.Receipt, new ScanSettings());
        Assert.True(Receipts.ReadsText(s));
        s.TaskOptions.ReceiptNameByDate = false;
        Assert.True(Receipts.ReadsText(s));
        s.PdfSearchable = false;
        Assert.False(Receipts.ReadsText(s));
        s.Output.AlsoSaveText = true;
        Assert.True(Receipts.ReadsText(s));
        s.Format = OutputFormat.Jpeg;
        Assert.False(Receipts.ReadsText(s));
    }

    [Fact]
    public void Receipts_NamedByDateOnlyWhenTheTemplateHasDocDate()
    {
        var s = TaskCatalog.Apply(ScanTask.Receipt, new ScanSettings());
        s.Format = OutputFormat.Jpeg;
        Assert.True(Receipts.NamesByDate(s));
        Assert.True(Receipts.ReadsText(s));
        // Without {docdate} the date goes nowhere: it is not read for the name.
        s.NamingTemplate = "Expenses {date} {counter}";
        Assert.False(Receipts.NamesByDate(s));
        Assert.False(Receipts.ReadsText(s));
        s.NamingTemplate = "Expenses {DOCDATE} {counter}";
        Assert.False(Receipts.NamesByDate(s));
        s.NamingTemplate = "{docdate}";
        Assert.True(Receipts.NamesByDate(s));
        s.TaskOptions.ReceiptNameByDate = false;
        Assert.False(Receipts.NamesByDate(s));
    }

    [Fact]
    public void Receipts_TextLinesAreInReadingOrder()
    {
        // Bottom-left origin: the higher line comes first; a price on the same row joins its item.
        OcrLine[] lines =
        [
            new("TOTAL 4.20", new RectD(0.1, 0.10, 0.6, 0.03), 1),
            new("DEMO CAFE", new RectD(0.3, 0.90, 0.4, 0.04), 1),
            new("Date 12/03/2026", new RectD(0.1, 0.80, 0.6, 0.03), 1),
        ];
        Assert.Equal(["DEMO CAFE", "Date 12/03/2026", "TOTAL 4.20"], Receipts.TextLines(lines, 900, 2400));
    }
}

/// <summary>
/// The date test set: receipt text as OCR returns it, with the date a person reads on it. Mirrored
/// by the Swift <c>ReceiptDateCases</c>. Merchants are made up.
/// </summary>
internal static class ReceiptDateCases
{
    public sealed record Case(string Category, string[] Lines, bool DayFirst, string? Expected);

    private static Case C(string category, string text, bool dayFirst, string? expected) =>
        new(category, text.Split('\n'), dayFirst, expected);

    /// <summary>OCR noise the extractor does not repair: letters read for digits, spaces inside a date.</summary>
    public const int KnownMisses = 3;

    public static IReadOnlyList<Case> All { get; } =
    [
        // ISO and year-first.
        C("ISO", "2026-03-12", false, "2026-03-12"),
        C("ISO", "Date: 2026/03/12 14:22", false, "2026-03-12"),
        C("ISO", "2026.03.12", true, "2026-03-12"),
        C("ISO", "2026-3-5", false, "2026-03-05"),
        C("ISO", "DATE 2025-12-31 23:59", true, "2025-12-31"),
        C("ISO", "Bon 0042 2026-10-19T08:15", true, "2026-10-19"),
        C("ISO", "Order 2026-0012", true, null),
        // United States: month first.
        C("US", "03/12/2026", false, "2026-03-12"),
        C("US", "12/31/2025", false, "2025-12-31"),
        C("US", "1/5/26", false, "2026-01-05"),
        C("US", "Date: 10/01/2026 08:15 PM", false, "2026-10-01"),
        C("US", "Trans 4471 07-04-2026", false, "2026-07-04"),
        C("US", "SALE 09/30/26 11:02", false, "2026-09-30"),
        C("US", "Store 0815 Reg 3 Date 6/7/2026", false, "2026-06-07"),
        C("US", "Cashier: Pat 08/15/2026", false, "2026-08-15"),
        // Europe: day first.
        C("EU", "12/03/2026", true, "2026-03-12"),
        C("EU", "31/12/25", true, "2025-12-31"),
        C("EU", "05-01-2026", true, "2026-01-05"),
        C("EU", "Datum: 12.03.2026", true, "2026-03-12"),
        C("EU", "Fecha: 07/08/2026 13:45", true, "2026-08-07"),
        C("EU", "Le 15/09/2026 à 10:12", true, "2026-09-15"),
        C("EU", "Data 3.9.2026", true, "2026-09-03"),
        C("EU", "13/05/2026", false, "2026-05-13"),
        C("EU", "12. 03. 2026", true, "2026-03-12"),
        // Turkish: day first with dots.
        C("Turkish", "Tarih: 12.03.2026 Saat: 14:35", false, "2026-03-12"),
        C("Turkish", "TARİH : 05.01.2026", true, "2026-01-05"),
        C("Turkish", "12.03.26", true, "2026-03-12"),
        C("Turkish", "FİŞ TARİHİ: 30.09.2026", true, "2026-09-30"),
        C("Turkish", "Düzenleme tarihi 01.10.2026", true, "2026-10-01"),
        C("Turkish", "14/09/2026 SAAT 19:20", true, "2026-09-14"),
        C("Turkish", "12 Mart 2026", true, "2026-03-12"),
        C("Turkish", "5 Ağustos 2025 Salı", true, "2025-08-05"),
        C("Turkish", "01 OCAK 2026", true, "2026-01-01"),
        C("Turkish", "28 Şubat 2026 Cumartesi", true, "2026-02-28"),
        C("Turkish", "3 Eylül 2026", true, "2026-09-03"),
        C("Turkish", "19 Ekim 2026", true, "2026-10-19"),
        C("Turkish", "9 Kasım 2025", true, "2025-11-09"),
        C("Turkish", "31 Aralık 2025", true, "2025-12-31"),
        C("Turkish", "7 Haziran 2026", true, "2026-06-07"),
        C("Turkish", "15 Mayıs 2026", true, "2026-05-15"),
        // English month names.
        C("Month names", "12 Mar 2026", false, "2026-03-12"),
        C("Month names", "Mar 12, 2026", true, "2026-03-12"),
        C("Month names", "March 12th, 2026", true, "2026-03-12"),
        C("Month names", "12-MAR-26", false, "2026-03-12"),
        C("Month names", "Jan 5,2026", true, "2026-01-05"),
        C("Month names", "5 January 2026", false, "2026-01-05"),
        C("Month names", "Sept 9, 2025", true, "2025-09-09"),
        C("Month names", "Dec. 3 2025", true, "2025-12-03"),
        C("Month names", "1st February 2026", false, "2026-02-01"),
        C("Month names", "SAT 18 APR 2026 10:41", false, "2026-04-18"),
        C("Month names", "TABLE 4 SAT 18 APR 2026 10:41", false, "2026-04-18"),
        C("Month names", "Reg 3 Fri 12 Mar 2026", true, "2026-03-12"),
        C("Month names", "18-OCT-26 07:55", false, "2026-10-18"),
        C("Month names", "Thursday, October 1, 2026", false, "2026-10-01"),
        // Other languages.
        C("Month names", "12. März 2026", true, "2026-03-12"),
        C("Month names", "12 mars 2026", true, "2026-03-12"),
        C("Month names", "12 de marzo de 2026", true, "2026-03-12"),
        C("Month names", "3 giugno 2026", true, "2026-06-03"),
        C("Month names", "12 maart 2026", true, "2026-03-12"),
        C("Month names", "1 février 2026", true, "2026-02-01"),
        C("Month names", "15 dezembro 2025", true, "2025-12-15"),
        C("Month names", "2 août 2026", true, "2026-08-02"),
        C("Month names", "21 Okt. 2025", true, "2025-10-21"),
        // Chinese, Japanese, Korean.
        C("CJK", "2026年3月12日", false, "2026-03-12"),
        C("CJK", "2026 年 10 月 1 日 14:20", false, "2026-10-01"),
        C("CJK", "2026년 3월 12일", false, "2026-03-12"),
        // Day or month: a part above 12 decides, dots put the day first, otherwise the region.
        C("Ambiguous", "03/04/2026", true, "2026-04-03"),
        C("Ambiguous", "03/04/2026", false, "2026-03-04"),
        C("Ambiguous", "03.04.2026", false, "2026-04-03"),
        C("Ambiguous", "04/25/2026", true, "2026-04-25"),
        // Not dates.
        C("Not a date", "12:30", true, null),
        C("Not a date", "Tel 12.34.56", true, null),
        C("Not a date", "Total 12.50", true, null),
        C("Not a date", "Card **** 1234", true, null),
        C("Not a date", "EXP 12/28", true, null),
        C("Not a date", "31/02/2026", true, null),
        C("Not a date", "12/03/2030", true, null),
        C("Not a date", "12/03/2010", true, null),
        C("Not a date", "Qty 2 x 3.50", true, null),
        C("Not a date", "1 SET 25.00", true, null),
        C("Not a date", "IP 192.168.1.10", true, null),
        C("Not a date", "Ref 20260312", true, null),
        C("Not a date", "Phone 0212 555 12 34", true, null),
        C("Not a date", "Mar 12", true, null),
        // Whole receipts: the date among times, phone numbers, amounts and expiry dates.
        C("Receipts", "DEMO CAFE\n123 Example St\nTel 555-0100\n12:41 Table 4\nLatte 3.50\nTOTAL 3.50\nVISA **** 4242 EXP 09/28\nDate 03/12/2026", false, "2026-03-12"),
        C("Receipts", "TEST MARKET A.Ş.\nVKN 1234567890\nTARİH: 14.09.2026\nSAAT: 19:20\nFİŞ NO: 0042\nTOPLAM *45,90", true, "2026-09-14"),
        C("Receipts", "SAMPLE MART\nReturns accepted until 2026-12-31\n2026-10-02 18:03\nBREAD 2.10", true, "2026-10-02"),
        C("Receipts", "FICTIONAL FUEL CO\nPump 3 Unleaded\n18-OCT-26 07:55\n40.12 L @ 1.799\nTOTAL 72.18", false, "2026-10-18"),
        C("Receipts", "DEMO CAFE\nLatte 3.50\nTOTAL 3.50", true, null),
        C("Receipts", "EXAMPLE BAKERY\n2 x Croissant 2.40\nBest before 25.10.2026\nPrinted 17.10.2026 09:12", true, "2026-10-17"),
        C("Receipts", "MUSTERLADEN GMBH\nBon 1234 Kasse 2\nDatum 12.03.2026 Uhrzeit 10:15\nGültig bis 12.04.2026", true, "2026-03-12"),
        C("Receipts", "PLACEHOLDER PHARMACY\nRx 55120\nFILLED 09/02/2026\nEXPIRES 09/02/2027", false, "2026-09-02"),
        C("Receipts", "SAMPLE TAXI\nFrom 22:10 to 22:41\nFare 18.40\n4 Oct 2026", true, "2026-10-04"),
        C("Receipts", "DEMO HOTEL\nArrival 01/10/2026\nDeparture 04/10/2026\nInvoice date 04/10/2026", true, "2026-10-04"),
        // OCR noise: letters read as digits and spaces inside a date are not repaired.
        C("OCR noise", "2O26-03-12", true, "2026-03-12"),
        C("OCR noise", "12/03/2O26", true, "2026-03-12"),
        C("OCR noise", "12 / 03 / 2026", true, "2026-03-12"),
        C("OCR noise", "Date:12/03/2026", true, "2026-03-12"),
        C("OCR noise", "DATE12.03.2026", true, "2026-03-12"),
    ];
}
