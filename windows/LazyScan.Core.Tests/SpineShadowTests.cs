using LazyScan.Core;
using Xunit;

namespace LazyScan.Core.Tests;

// Twin of Tests/CompleteScannerTests/SpineShadowTests.swift: softening the shadow along the spine on a
// page cut from a spread, on the same synthetic book pages (TestPages, byte-identical, checked by
// checksum), with the same softened bytes on both platforms.

public class SpineShadowTests
{
    /// <summary>The page is 550 px wide; the shadow reaches 80 px from its right edge.</summary>
    private const int ShadowZone = 80;

    private static bool InPicture(int x, int y) => x >= 400 && x < 530 && y >= 300 && y < 520;

    private static bool InTint(int x, int y) => x >= 430 && y >= 640 && y < 740;

    /// <summary>What softening did to the paper and the ink within <see cref="ShadowZone"/> of the right edge, against the page with no shadow.</summary>
    private sealed record Zone(double DarkeningBefore, double DarkeningAfter, double WorstColumn, double InkContrastClean,
                               double InkContrastAfter, double InkClean, double InkAfter);

    private static Zone MeasureZone(GrayImage clean, GrayImage shadowed, GrayImage softened, Func<int, int, bool> excluded)
    {
        int w = clean.Width;
        double paperClean = 0, paperShadow = 0, paperSoft = 0, inkClean = 0, inkSoft = 0;
        int paper = 0, ink = 0;
        var columnClean = new double[ShadowZone];
        var columnSoft = new double[ShadowZone];
        for (int y = 0; y < clean.Height; y++)
        {
            for (int d = 0; d < ShadowZone; d++)
            {
                int x = w - 1 - d;
                if (excluded(x, y)) continue;
                int i = y * w + x;
                int c = clean.Pixels[i];
                if (c >= 200)
                {
                    paperClean += c;
                    paperShadow += shadowed.Pixels[i];
                    paperSoft += softened.Pixels[i];
                    columnClean[d] += c;
                    columnSoft[d] += softened.Pixels[i];
                    paper++;
                }
                else if (c <= 60)
                {
                    inkClean += c;
                    inkSoft += softened.Pixels[i];
                    ink++;
                }
            }
        }
        double worst = 0;
        for (int d = 0; d < ShadowZone; d++)
        {
            if (columnClean[d] > 0) worst = Math.Max(worst, Math.Abs(1 - columnSoft[d] / columnClean[d]));
        }
        double pc = paperClean / paper, ps = paperSoft / paper, ic = inkClean / ink, isoft = inkSoft / ink;
        return new Zone(1 - paperShadow / paperClean, 1 - paperSoft / paperClean, worst, (pc - ic) / pc, (ps - isoft) / ps, ic, isoft);
    }

    /// <summary>The largest change of a pixel where <paramref name="where"/> holds.</summary>
    private static int LargestChange(GrayImage before, GrayImage after, Func<int, int, bool> where)
    {
        int largest = 0;
        for (int y = 0; y < before.Height; y++)
        {
            for (int x = 0; x < before.Width; x++)
            {
                if (!where(x, y)) continue;
                int i = y * before.Width + x;
                largest = Math.Max(largest, Math.Abs(after.Pixels[i] - before.Pixels[i]));
            }
        }
        return largest;
    }

    /// <summary>
    /// The largest change of a pixel where <paramref name="where"/> holds (in the page's pixels) when the page is
    /// scanned at 300 dpi, its content <paramref name="shift"/> px further right and down (off the 100 dpi grid).
    /// </summary>
    private static int LargestChangeAt300Dpi(GrayImage page, Func<int, int, bool> where, int shift = 0)
    {
        var scan = Shifted(TestPages.Enlarged(page, 3), shift);
        var result = SpineShadow.Soften(scan, 300, PageEdge.Right);
        Assert.NotNull(result);
        return LargestChange(GrayImage.Luma(scan), GrayImage.Luma(result.Image),
                             (x, y) => x >= shift && y >= shift && where((x - shift) / 3, (y - shift) / 3));
    }

    /// <summary>The image's content <paramref name="shift"/> px further right and down, its first column and row repeated.</summary>
    private static RgbaImage Shifted(RgbaImage image, int shift)
    {
        int w = image.Width, h = image.Height;
        var p = new byte[w * h * 4];
        for (int y = 0; y < h; y++)
        {
            for (int x = 0; x < w; x++)
            {
                Array.Copy(image.Pixels, (Math.Max(0, y - shift) * w + Math.Max(0, x - shift)) * 4, p, (y * w + x) * 4, 4);
            }
        }
        return new RgbaImage(w, h, p);
    }

    /// <summary>A text page with a flat bar <paramref name="width"/> px wide printed all along its right edge, and no shadow.</summary>
    private static GrayImage BarPage(int width, byte tint, int ramp)
    {
        var c = new TestPages.Canvas(550, 850, 245, 0xB00C0030);
        c.TextBlock(60, 60, 430, 36, 20, 40, new TestPages.Rng(0xB00C0031));
        c.FillRect(550 - width, 0, width, 850, tint);
        // A scanned bar's edge is a ramp of a few pixels to the paper.
        for (int k = 1; k <= ramp; k++) c.FillRect(550 - width - k, 0, 1, 850, (byte)(tint + (245 - tint) * k / (ramp + 1)));
        return c.Gray();
    }

    /// <summary>A book page with a flat mid-tone picture (150) where <see cref="InPicture"/> holds, in a shadow 0.8 in wide and 40 % deep.</summary>
    private static GrayImage FlatPicturePage()
    {
        var c = new TestPages.Canvas(550, 850, 245, 0xB00C002A);
        c.TextBlock(60, 60, 460, 36, 20, 40, new TestPages.Rng(0xB00C002B));
        c.FillRect(400, 300, 130, 220, 150);
        c.SpineShadow(80, 400, 400);
        return c.Gray();
    }

    /// <summary>The image mirrored left to right.</summary>
    private static RgbaImage Mirrored(RgbaImage image)
    {
        int w = image.Width, h = image.Height;
        var p = new byte[w * h * 4];
        for (int y = 0; y < h; y++)
        {
            for (int x = 0; x < w; x++) Array.Copy(image.Pixels, (y * w + x) * 4, p, (y * w + w - 1 - x) * 4, 4);
        }
        return new RgbaImage(w, h, p);
    }

    /// <summary>The image transposed: pixel (x, y) moves to (y, x).</summary>
    private static RgbaImage Transposed(RgbaImage image)
    {
        int w = image.Width, h = image.Height;
        var p = new byte[w * h * 4];
        for (int y = 0; y < h; y++)
        {
            for (int x = 0; x < w; x++) Array.Copy(image.Pixels, (y * w + x) * 4, p, (x * h + y) * 4, 4);
        }
        return new RgbaImage(h, w, p);
    }

    private static GrayImage Softened(GrayImage page) =>
        GrayImage.Luma(SpineShadow.Soften(page.ToRgba(), 100, PageEdge.Right)!.Image);

    // MARK: - The pages are the same on both platforms

    [Fact]
    public void BookPages_AreTheSameBytesOnBothPlatforms()
    {
        Assert.Equal(0xFBE58022u, TestPages.Checksum(TestPages.ShadowedBookPage()));
        Assert.Equal(0x1305BF67u, TestPages.Checksum(TestPages.UnshadowedBookPage()));
        Assert.Equal(0xDFE362B3u, TestPages.Checksum(TestPages.PictureBookPage()));
        Assert.Equal(0xE9AD3B0Bu, TestPages.Checksum(TestPages.UnshadowedPictureBookPage()));
        Assert.Equal(0xE58F1808u, TestPages.Checksum(TestPages.TintBookPage()));
    }

    [Fact]
    public void SoftenedPages_AreTheSameBytesOnBothPlatforms()
    {
        Assert.Equal(0xC2E36A2Cu, TestPages.Checksum(Softened(TestPages.ShadowedBookPage())));
        Assert.Equal(0xF5538C1Cu, TestPages.Checksum(Softened(TestPages.PictureBookPage())));
        Assert.Equal(0xDCF26252u, TestPages.Checksum(Softened(TestPages.TintBookPage())));
        var scan = SpineShadow.Soften(TestPages.Enlarged(TestPages.ShadowedBookPage(), 3), 300, PageEdge.Right)!;
        Assert.Equal(0x5592BA21u, TestPages.Checksum(GrayImage.Luma(scan.Image)));
        var picture = SpineShadow.Soften(TestPages.Enlarged(TestPages.PictureBookPage(), 3), 300, PageEdge.Right)!;
        Assert.Equal(0xC77AA721u, TestPages.Checksum(GrayImage.Luma(picture.Image)));
    }

    // MARK: - Which edge runs along the spine

    [Fact]
    public void GutterEdge_IsTheEdgeOfTheCut_TurnedWithTheBook()
    {
        var id = Guid.NewGuid();
        var vertical = BookSplitter.Manual(GutterAxis.Vertical, 0.5, 100, 80);
        var horizontal = BookSplitter.Manual(GutterAxis.Horizontal, 0.5, 80, 100);
        Assert.Equal(PageEdge.Right, SpineShadow.GutterEdge(new SpreadPart(id, 0, vertical), 0));
        Assert.Equal(PageEdge.Left, SpineShadow.GutterEdge(new SpreadPart(id, 1, vertical), 0));
        Assert.Equal(PageEdge.Bottom, SpineShadow.GutterEdge(new SpreadPart(id, 0, horizontal), 0));
        Assert.Equal(PageEdge.Top, SpineShadow.GutterEdge(new SpreadPart(id, 1, horizontal), 0));
        // A book lying sideways: its pages are turned a quarter clockwise, and the cut's edge with them.
        Assert.Equal(PageEdge.Bottom, SpineShadow.GutterEdge(new SpreadPart(id, 0, vertical), 1));
        Assert.Equal(PageEdge.Top, SpineShadow.GutterEdge(new SpreadPart(id, 1, vertical), 1));
        Assert.Equal(PageEdge.Right, SpineShadow.GutterEdge(new SpreadPart(id, 1, horizontal), 1));
        Assert.Equal(PageEdge.Right, SpineShadow.GutterEdge(new SpreadPart(id, 0, horizontal), -1));
        Assert.Equal(PageEdge.Left, SpineShadow.GutterEdge(new SpreadPart(id, 0, vertical), 2));
        // A whole spread, or a page not cut from one, has no spine edge.
        Assert.Null(SpineShadow.GutterEdge(new SpreadPart(id, null, null), 0));
        Assert.Null(SpineShadow.GutterEdge(null, 0));
        Assert.Equal([PageEdge.Top, PageEdge.Right, PageEdge.Bottom, PageEdge.Left],
                     new[] { 0, 1, 2, 3 }.Select(turns => SpineShadow.Turned(PageEdge.Top, turns)));
        Assert.Equal(PageEdge.Bottom, SpineShadow.Turned(PageEdge.Left, 7));
    }

    // MARK: - Softening

    [Fact]
    public void ShadowedPage_PaperComesBackToWhite_AndTextKeepsItsContrast()
    {
        var shadowed = TestPages.ShadowedBookPage();
        var result = SpineShadow.Soften(shadowed.ToRgba(), 100, PageEdge.Right);
        Assert.NotNull(result);
        var zone = MeasureZone(TestPages.UnshadowedBookPage(), shadowed, GrayImage.Luma(result.Image), (_, _) => false);
        // The paper within 0.8 in of the spine was 13 % darker on average (45 % at the edge, top).
        Assert.InRange(zone.DarkeningBefore, 0.12, 0.15);
        Assert.InRange(zone.DarkeningAfter, -0.01, 0.03);
        Assert.True(zone.WorstColumn < 0.05, $"worst column {zone.WorstColumn}");
        // Ink keeps its share of the paper's light: the text is as dark against the paper as without the shadow.
        Assert.InRange(zone.InkContrastAfter / zone.InkContrastClean, 0.98, 1.02);
        Assert.InRange(zone.InkAfter, zone.InkClean - 5, zone.InkClean + 5);
        var r = result.Result;
        Assert.Equal(PageEdge.Right, r.Edge);
        // The shadow most of the edge agrees on: 30-45 % deep at the edge, faded within 0.8 in.
        Assert.InRange(r.Depth, 0.25, 0.45);
        Assert.InRange(r.WidthInches, 0.4, 0.8);
        Assert.InRange(r.MaxGain, 1.4, SpineShadow.MaxGain);
        Assert.Equal(0, r.ProtectedFraction);
    }

    [Fact]
    public void ShadowedPage_ScannedAt300Dpi_IsSoftenedAsAt100()
    {
        var scan = TestPages.Enlarged(TestPages.ShadowedBookPage(), 3);
        var result = SpineShadow.Soften(scan, 300, PageEdge.Right);
        Assert.NotNull(result);
        var softened = GrayImage.Luma(result.Image).Downsampled(550, 850);
        var zone = MeasureZone(TestPages.UnshadowedBookPage(), TestPages.ShadowedBookPage(), softened, (_, _) => false);
        Assert.InRange(zone.DarkeningAfter, -0.01, 0.03);
        Assert.InRange(zone.InkContrastAfter / zone.InkContrastClean, 0.98, 1.02);
        Assert.Equal(1650, result.Image.Width);
        // Alpha is kept, and nothing past the 1.5 in band changes.
        Assert.All(Enumerable.Range(0, scan.Width * scan.Height), i => Assert.Equal(255, result.Image.Pixels[i * 4 + 3]));
        for (int y = 0; y < scan.Height; y += 7)
        {
            for (int x = 0; x < scan.Width - 3 * 150; x++)
            {
                int i = (y * scan.Width + x) * 4;
                Assert.Equal(scan.Pixels[i], result.Image.Pixels[i]);
            }
        }
    }

    [Fact]
    public void EveryEdge_GivesTheSamePage()
    {
        var page = TestPages.ShadowedBookPage().ToRgba();
        var right = SpineShadow.Soften(page, 100, PageEdge.Right)!.Image;
        var left = SpineShadow.Soften(Mirrored(page), 100, PageEdge.Left)!.Image;
        var bottom = SpineShadow.Soften(Transposed(page), 100, PageEdge.Bottom)!.Image;
        var top = SpineShadow.Soften(Transposed(Mirrored(page)), 100, PageEdge.Top)!.Image;
        Assert.Equal(right.Pixels, Mirrored(left).Pixels);
        Assert.Equal(right.Pixels, Transposed(bottom).Pixels);
        Assert.Equal(right.Pixels, Mirrored(Transposed(top)).Pixels);
    }

    [Fact]
    public void ColorPages_AreLiftedEvenly_KeepingThePapersTint()
    {
        // Cream paper: every channel is brightened by the same factor, so the tint stays.
        var gray = TestPages.ShadowedBookPage();
        var p = new byte[gray.Width * gray.Height * 4];
        for (int i = 0; i < gray.Pixels.Length; i++)
        {
            int v = gray.Pixels[i];
            p[i * 4] = (byte)v;
            p[i * 4 + 1] = (byte)(v * 96 / 100);
            p[i * 4 + 2] = (byte)(v * 82 / 100);
            p[i * 4 + 3] = 255;
        }
        var color = new RgbaImage(gray.Width, gray.Height, p);
        var result = SpineShadow.Soften(color, 100, PageEdge.Right);
        Assert.NotNull(result);
        // Paper at the edge, in the middle of the page (between two lines of text): red, green and blue in the cream's proportions.
        int at = (430 * gray.Width + gray.Width - 3) * 4;
        var o = result.Image.Pixels;
        Assert.True(o[at] > p[at] + 40, $"red {p[at]} -> {o[at]}");
        Assert.InRange((double)o[at + 1] / o[at], 0.93, 0.99);
        Assert.InRange((double)o[at + 2] / o[at], 0.79, 0.85);
    }

    [Fact]
    public void PicturesBesideTheSpine_AreLeftAlone()
    {
        var shadowed = TestPages.PictureBookPage();
        var result = SpineShadow.Soften(shadowed.ToRgba(), 100, PageEdge.Right);
        Assert.NotNull(result);
        var softened = GrayImage.Luma(result.Image);
        // The picture keeps its pixels (and the shadow on it): its tones are not washed out.
        Assert.Equal(0, LargestChange(shadowed, softened, InPicture));
        // The paper around it, and the text, are softened as on a page without a picture.
        var zone = MeasureZone(TestPages.UnshadowedPictureBookPage(), shadowed, softened, InPicture);
        Assert.InRange(zone.DarkeningBefore, 0.13, 0.17);
        Assert.InRange(zone.DarkeningAfter, -0.01, 0.03);
        Assert.InRange(zone.InkContrastAfter / zone.InkContrastClean, 0.98, 1.02);
        // The picture is the band's protected part: 1.3 × 2.2 in of 1.5 × 8.5 in.
        Assert.InRange(result.Result.ProtectedFraction, 0.2, 0.25);
        // Scanned at 300 dpi, the picture keeps every pixel too, to its outermost rows and columns, and the paper
        // around it is softened as at 100 dpi.
        Assert.Equal(0, LargestChangeAt300Dpi(shadowed, InPicture));
        var scan = SpineShadow.Soften(TestPages.Enlarged(shadowed, 3), 300, PageEdge.Right)!;
        var zone300 = MeasureZone(TestPages.UnshadowedPictureBookPage(), shadowed, GrayImage.Luma(scan.Image).Downsampled(550, 850), InPicture);
        Assert.InRange(zone300.DarkeningAfter, -0.01, 0.03);
        Assert.InRange(zone300.InkContrastAfter / zone300.InkContrastClean, 0.98, 1.02);
    }

    [Fact]
    public void PictureOffTheAnalysisGrid_KeepsEveryPixel()
    {
        // At 300 dpi a picture's edges need not fall on the 100 dpi grid the shadow is measured on: an analysis
        // pixel only partly on a flat mid-tone picture is lighter than the picture, and left out of its box; the
        // picture's outermost rows and columns in that pixel keep their values all the same.
        var page = FlatPicturePage();
        Assert.Equal(0, LargestChange(page, GrayImage.Luma(SpineShadow.Soften(page.ToRgba(), 100, PageEdge.Right)!.Image), InPicture));
        foreach (int shift in new[] { 0, 1, 2 })
        {
            Assert.Equal(0, LargestChangeAt300Dpi(page, InPicture, shift));
            Assert.Equal(0, LargestChangeAt300Dpi(TestPages.PictureBookPage(), InPicture, shift));
        }
    }

    [Fact]
    public void FlatTintReachingTheSpine_IsLeftAlone()
    {
        var shadowed = TestPages.TintBookPage();
        var result = SpineShadow.Soften(shadowed.ToRgba(), 100, PageEdge.Right);
        Assert.NotNull(result);
        var softened = GrayImage.Luma(result.Image);
        // A flat gray band reaching the spine looks like shadowed paper close up, but not beside the blocks around it.
        Assert.Equal(0, LargestChange(shadowed, softened, InTint));
        var clean = TestPages.BookPage(0, 0, 80, 0xB00C0022, tint: true);
        var zone = MeasureZone(clean, shadowed, softened, InTint);
        Assert.InRange(zone.DarkeningAfter, -0.01, 0.03);
        Assert.True(result.Result.ProtectedFraction > 0.08);
        Assert.Equal(0, LargestChangeAt300Dpi(shadowed, InTint));
    }

    [Fact]
    public void BarPrintedAllAlongTheSpine_IsNoShadow()
    {
        // A tint, a thumb index or a bleed running the whole length of the spine darkens the paper there in
        // every block, but comes back to the paper in a step: it is left as printed.
        foreach (int width in new[] { 10, 20 })
        {
            foreach (byte tint in new byte[] { 200, 160, 120 })
            {
                foreach (int ramp in new[] { 0, 2 })
                {
                    var page = BarPage(width, tint, ramp);
                    Assert.Null(SpineShadow.Estimate(page, PageEdge.Right));
                    Assert.Null(SpineShadow.Soften(TestPages.Enlarged(page, 3), 300, PageEdge.Right));
                }
            }
        }
        // A shadow as narrow and faint (0.2 in, 10 % deep) fades gradually, and is softened.
        Assert.NotNull(SpineShadow.Soften(TestPages.BookPage(100, 100, 20, 0xB00C0029).ToRgba(), 100, PageEdge.Right));
    }

    // MARK: - Pages left alone

    [Fact]
    public void PagesWithoutAShadow_AreLeftAlone()
    {
        Assert.Null(SpineShadow.Soften(TestPages.UnshadowedBookPage().ToRgba(), 100, PageEdge.Right));
        Assert.Null(SpineShadow.Soften(TestPages.UnshadowedPictureBookPage().ToRgba(), 100, PageEdge.Right));
        // The shadow is on the right: the left edge has none.
        Assert.Null(SpineShadow.Soften(TestPages.ShadowedBookPage().ToRgba(), 100, PageEdge.Left));
        Assert.Null(SpineShadow.Estimate(TestPages.ShadowedBookPage(), PageEdge.Top));
        // A shadow too faint to matter (3 %), a dark page, a page too narrow for a band.
        Assert.Null(SpineShadow.Soften(TestPages.BookPage(30, 30, 80, 0xB00C0023).ToRgba(), 100, PageEdge.Right));
        Assert.Null(SpineShadow.Soften(RgbaImage.Filled(550, 850, 60, 60, 60), 100, PageEdge.Right));
        Assert.Null(SpineShadow.Soften(RgbaImage.Filled(40, 850, 200, 200, 200), 100, PageEdge.Right));
    }

    [Fact]
    public void DarkAreasAllAcrossTheBand_AreNoShadow()
    {
        // A dark picture running the whole length of the edge, wider than the band: nothing fades, nothing is softened.
        var c = new TestPages.Canvas(550, 850, 245, 0xB00C0024);
        c.TextBlock(60, 60, 300, 36, 20, 40, new TestPages.Rng(0xB00C0025));
        c.Picture(380, 0, 170, 850);
        Assert.Null(SpineShadow.Soften(c.Gray().ToRgba(), 100, PageEdge.Right));
        // A dark stripe 0.5 in from the edge, the paper at the edge as bright as elsewhere: not the spine's shadow.
        var stripe = new TestPages.Canvas(550, 850, 245, 0xB00C0026);
        stripe.TextBlock(60, 60, 400, 36, 20, 40, new TestPages.Rng(0xB00C0027));
        stripe.FillRect(470, 0, 30, 850, 150);
        Assert.Null(SpineShadow.Soften(stripe.Gray().ToRgba(), 100, PageEdge.Right));
    }

    [Fact]
    public void Gains_AreCapped()
    {
        // A fold 90 % dark at the edge: the paper there is brightened at most MaxGain times.
        var deep = TestPages.BookPage(900, 900, 60, 0xB00C0028);
        var model = SpineShadow.Estimate(deep, PageEdge.Right);
        Assert.NotNull(model);
        Assert.Equal(SpineShadow.MaxGain, model.Result.MaxGain);
        Assert.All(model.Gains, g => Assert.InRange(g, 1.0, SpineShadow.MaxGain));
        Assert.Equal((150, 850, 550), (model.Band, model.Length, model.Extent));
        Assert.Equal(model.Gains.Length, model.Pictures.Length);
    }

    [Fact]
    public void Hint_SaysWhatTheSwitchDoes()
    {
        Assert.Equal("Lightens the dark band along the spine", SpineShadow.Hint(true));
        Assert.Equal("Lightens the dark band along the spine", SpineShadow.Hint(false));
    }
}
