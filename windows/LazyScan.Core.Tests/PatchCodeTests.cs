using LazyScan.Core;
using Xunit;

namespace LazyScan.Core.Tests;

// Twin of Tests/LazyScanTests/PatchCodeTests.swift: the same pages, the same expectations.

public class PatchCodeTests
{
    [Fact]
    public void Codes_TheirBarsAndLabels()
    {
        Assert.Equal(["Patch 1", "Patch 2", "Patch 3", "Patch 4", "Patch 6", "Patch T"], PatchCodes.All.Select(c => c.Label()));
        Assert.Equal(["1100", "1001", "1010", "0110", "0011", "0101"],
                     PatchCodes.All.Select(c => string.Concat(c.Bars().Select(wide => wide ? '1' : '0'))));
        foreach (var code in PatchCodes.All)
        {
            var bars = code.Bars();
            Assert.Equal(code, PatchCodes.FromBars(bars[0], bars[1], bars[2], bars[3]));
        }
        Assert.Null(PatchCodes.FromBars(true, true, true, false));
        Assert.Null(PatchCodes.FromBars(false, false, false, false));
        // Read from the other end: 1 and 6, 3 and T swap; 2 and 4 read the same.
        Assert.Equal([PatchCode.Patch6, PatchCode.Patch2, PatchCode.PatchT, PatchCode.Patch4, PatchCode.Patch1, PatchCode.Patch3],
                     PatchCodes.All.Select(c => c.Reversed()));
    }

    [Fact]
    public void Fixtures_AreTheSameBytesOnBothPlatforms()
    {
        Assert.Equal(
            [Expected.PatchT, Expected.Patch2Vertical, Expected.PatchTPlus2Point5, Expected.RuledTable, Expected.SheetLetter100],
            new[]
            {
                TestPages.PatchPage(PatchCode.PatchT, false, TestPages.Straight),
                TestPages.PatchPage(PatchCode.Patch2, true, TestPages.Straight),
                TestPages.PatchPage(PatchCode.PatchT, false, TestPages.Plus2Point5),
                TestPages.RuledTable(),
                PatchCodeDetector.RenderSheet(PatchCode.PatchT, 8.5, 11, 100),
            }.Select(TestPages.Checksum));
    }

    [Fact]
    public void EveryCode_AcrossAndDownThePage()
    {
        foreach (var code in PatchCodes.All)
        {
            var across = PatchCodeDetector.Detect(TestPages.PatchPage(code, false, TestPages.Straight));
            Assert.NotNull(across);
            Assert.Equal(code, across.Code);
            Assert.False(across.VerticalBars);
            // The bars: x 275 ..< 575; y from 200, 80 px deep (2 wide, 2 narrow, 3 gaps).
            Assert.Equal(new RectD(275, 200, 300, 80), across.Bounds);
            Assert.Equal(300, across.Length);

            var down = PatchCodeDetector.Detect(TestPages.PatchPage(code, true, TestPages.Straight));
            Assert.NotNull(down);
            Assert.Equal(code, down.Code);
            Assert.True(down.VerticalBars);
            Assert.Equal(new RectD(200, 400, 80, 300), down.Bounds);
        }
    }

    [Fact]
    public void ASlantOfAFewDegrees_IsRead()
    {
        foreach (var turn in new[] { TestPages.Plus2Point5, TestPages.Minus2Point5, TestPages.Plus3, TestPages.Minus3 })
        {
            foreach (var code in new[] { PatchCode.PatchT, PatchCode.Patch2, PatchCode.Patch1 })
            {
                foreach (bool vertical in new[] { false, true })
                {
                    var hit = PatchCodeDetector.Detect(TestPages.PatchPage(code, vertical, turn));
                    Assert.True(hit is not null, $"{code} vertical {vertical} at {turn.Degrees:F1}°");
                    Assert.Equal(code, hit.Code);
                    Assert.Equal(vertical, hit.VerticalBars);
                    Assert.InRange(hit.Length, 280, 300);
                }
            }
        }
    }

    [Fact]
    public void TextTablesAndPagesWithoutACode_AreNotRead()
    {
        Assert.Null(PatchCodeDetector.Detect(TestPages.TextPage()));
        Assert.Null(PatchCodeDetector.Detect(TestPages.Turned(TestPages.TextPage(), TestPages.Plus3, 245)));
        Assert.Null(PatchCodeDetector.Detect(TestPages.RuledTable()));
        Assert.Null(PatchCodeDetector.Detect(TestPages.QuarterTurned(TestPages.RuledTable())));
        foreach (var (name, page) in TestPages.All()) Assert.True(PatchCodeDetector.Detect(page) is null, name);
        Assert.Null(PatchCodeDetector.Detect(TestPages.SheetOnBackdrop(TestPages.Plus2, 245, 250, 2, 0x5EE70001)));
    }

    [Fact]
    public void BarsShorterThanAnInchAndAHalf_AreNotACode()
    {
        Assert.Null(PatchCodeDetector.Detect(TestPages.PatchPage(PatchCode.PatchT, false, TestPages.Straight, length: 140)));
        Assert.NotNull(PatchCodeDetector.Detect(TestPages.PatchPage(PatchCode.PatchT, false, TestPages.Straight, length: 160)));
    }

    [Fact]
    public void TheSeparatorSheet_ReadsItsCode_EitherWayRound_AtAnyResolution()
    {
        foreach (var code in PatchCodes.All)
        {
            var sheet = PatchCodeDetector.RenderSheet(code, 8.5, 11, 100);
            Assert.Equal((850, 1100), (sheet.Width, sheet.Height));
            var hit = PatchCodeDetector.Detect(sheet);
            Assert.NotNull(hit);
            Assert.Equal(code, hit.Code);
            Assert.False(hit.VerticalBars);
            // 6 in bars, centred, 1 in from the top.
            Assert.Equal(new RectD(125, 100, 600, code.Bars().Sum(wide => wide ? 20 : 8) + 3 * 8), hit.Bounds);
            // Fed the other way round, the copy near the other edge reads the same code.
            Assert.Equal(code, PatchCodeDetector.Detect(TestPages.HalfTurned(sheet))?.Code);
            // Fed sideways, its bars run down the page.
            Assert.True(PatchCodeDetector.Detect(TestPages.QuarterTurned(sheet))?.VerticalBars);
        }
        // A4 at 300 dpi, read at the analysis resolution.
        var a4 = PatchCodeDetector.RenderSheet(PatchCode.PatchT, 8.27, 11.69, 300);
        Assert.Equal((2481, 3507), (a4.Width, a4.Height));
        Assert.Equal(PatchCode.PatchT, PatchCodeDetector.Detect(a4)?.Code);
        Assert.Equal(PatchCode.PatchT, PatchCodeDetector.Detect(a4.ToRgba(), 300)?.Code);
    }

    [Fact]
    public void TheSeparatorSheetPdf_IsPatchT_OnThePaperUsualWhereTheUserLives()
    {
        Assert.Equal(PatchCode.PatchT, SeparatorSheet.Code);
        Assert.Equal(300, SeparatorSheet.Dpi);
        Assert.Equal(PaperSize.Letter, SeparatorSheet.Paper("US"));
        Assert.Equal(PaperSize.Letter, SeparatorSheet.Paper("ca"));
        Assert.Equal(PaperSize.A4, SeparatorSheet.Paper("DE"));
        Assert.Equal(PaperSize.A4, SeparatorSheet.Paper(null));
        Assert.Equal("Separator sheet (Patch T, Letter)", SeparatorSheet.FileBaseName(PaperSize.Letter));
        Assert.Equal("Separator sheet (Patch T, A4)", SeparatorSheet.FileBaseName(PaperSize.A4));
        Assert.Equal("Saved the separator sheet: Separator sheet (Patch T, A4).pdf. Print it at actual size (100%), as many as you need, and put one in front of each document after the first.",
                     SeparatorSheet.SavedMessage("Separator sheet (Patch T, A4).pdf"));
    }

    [Fact]
    public void TheSeparatorSheet_HasTheStandardBarWidths()
    {
        var sheet = PatchCodeDetector.RenderSheet(PatchCode.PatchT, 8.5, 11, 300);
        // Down the middle column from the top: white to 1 in, then narrow 24, gap 24, wide 60,
        // gap 24, narrow 24, gap 24, wide 60 (0.08 and 0.20 in at 300 dpi).
        int x = sheet.Width / 2;
        var runs = new List<(bool Ink, int Length)>();
        for (int y = 0; y < 600; y++)
        {
            bool ink = sheet[x, y] == 0;
            if (runs.Count > 0 && runs[^1].Ink == ink) runs[^1] = (ink, runs[^1].Length + 1);
            else runs.Add((ink, 1));
        }
        Assert.Equal([(false, 300), (true, 24), (false, 24), (true, 60), (false, 24), (true, 24), (false, 24), (true, 60), (false, 60)],
                     runs);
        // The words lie between the two codes, clear of their quiet zones (0.3 in).
        bool RowHasInk(int y) => Enumerable.Range(0, sheet.Width).Any(column => sheet[column, y] == 0);
        Assert.DoesNotContain(Enumerable.Range(540, 90), RowHasInk);
        Assert.DoesNotContain(Enumerable.Range(2670, 90), RowHasInk);
        Assert.Contains(Enumerable.Range(1100, 1100), RowHasInk);
    }

    [Fact]
    public void ASeparatorSheetScannedAsADocumentPage_IsFound()
    {
        // The page processor's step: the patch code is recorded on the page; other pages get none.
        var sheet = PatchCodeDetector.RenderSheet(PatchCode.PatchT, 8.5, 11, 200).ToRgba();
        var page = new SeparatorStep().Apply(new ScannedPage(sheet, 200, ColorMode.Color));
        Assert.Equal(PatchCode.PatchT, page.Patch);
        var text = new SeparatorStep().Apply(new ScannedPage(TestPages.Enlarged(TestPages.TextPage(), 2), 200, ColorMode.Color));
        Assert.Null(text.Patch);
    }

    private static class Expected
    {
        public const uint PatchT = 0x1C4A46D4u;
        public const uint Patch2Vertical = 0x405A20EBu;
        public const uint PatchTPlus2Point5 = 0xC526D510u;
        public const uint RuledTable = 0xDC4EED7Du;
        public const uint SheetLetter100 = 0xDA73C7FAu;
    }
}
