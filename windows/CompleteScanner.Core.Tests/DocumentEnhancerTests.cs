using CompleteScanner.Core;
using Xunit;

namespace CompleteScanner.Core.Tests;

// Twin of Tests/CompleteScannerTests/DocumentEnhancerTests.swift: the same pages, the same bytes. The
// checksums were recomputed by an independent model of the algorithm as CONTRACTS.md describes it.

public class DocumentEnhancerTests
{
    private static int Luma(RgbaImage image, int x, int y)
    {
        int i = (y * image.Width + x) * 4;
        return (299 * image.Pixels[i] + 587 * image.Pixels[i + 1] + 114 * image.Pixels[i + 2] + 500) / 1000;
    }

    /// <summary>Min, max and mean luma of the pixels of one kind (<see cref="EnhancerPages.Kind"/>).</summary>
    private static (int Min, int Max, double Mean) Lumas(RgbaImage image, int kind, bool stamp = true, bool picture = false)
    {
        int min = 255, max = 0;
        long sum = 0, count = 0;
        for (int y = 0; y < image.Height; y++)
        {
            for (int x = 0; x < image.Width; x++)
            {
                if (EnhancerPages.Kind(x, y, image.Width, image.Height, stamp, picture) != kind) continue;
                int v = Luma(image, x, y);
                min = Math.Min(min, v);
                max = Math.Max(max, v);
                sum += v;
                count++;
            }
        }
        return (min, max, (double)sum / count);
    }

    [Fact]
    public void TheFixturesAreTheSharedPixels()
    {
        Assert.Equal(0x4329E79Au, PhotoScenes.Checksum(EnhancerPages.Shadowed()));
        Assert.Equal(0x8F960753u, PhotoScenes.Checksum(EnhancerPages.Shadowed(stamp: false)));
        Assert.Equal(0x2C86F2C0u, PhotoScenes.Checksum(EnhancerPages.Shadowed(stamp: false, picture: true)));
    }

    [Fact]
    public void AShadowedPageComesOutWithOneWhitePaper()
    {
        var page = EnhancerPages.Shadowed();
        var before = Lumas(page, 0);
        // The shadow: the paper from about 37 % to full light.
        Assert.True(before.Max - before.Min >= 100, $"paper {before.Min}...{before.Max}");
        var result = DocumentEnhancer.Enhance(page, DocumentEnhanceMode.Gray);
        Assert.Equal(DocumentEnhanceMode.Gray, result.Mode);
        Assert.Equal(page.Width, result.Image.Width);
        Assert.Equal(page.Height, result.Image.Height);
        var paper = Lumas(result.Image, 0);
        Assert.True(paper.Min >= 250, $"paper {paper.Min}...{paper.Max}");
        // The print stays black everywhere, in the shadow too: the contrast is kept.
        var print = Lumas(result.Image, 1);
        Assert.True(print.Max <= 10, $"print {print.Min}...{print.Max}");
        var printBefore = Lumas(page, 1);
        Assert.True(paper.Mean - print.Mean >= before.Max - printBefore.Min, "contrast kept");
        for (int i = 0; i < result.Image.Pixels.Length; i += 4)
        {
            Assert.Equal(result.Image.Pixels[i], result.Image.Pixels[i + 1]);
            Assert.Equal(result.Image.Pixels[i], result.Image.Pixels[i + 2]);
            Assert.Equal(255, result.Image.Pixels[i + 3]);
        }
    }

    [Fact]
    public void ColorTakesThePapersTintOutAndKeepsTheStampRed()
    {
        var result = DocumentEnhancer.Enhance(EnhancerPages.Shadowed(), DocumentEnhanceMode.Color);
        Assert.Equal(DocumentEnhanceMode.Color, result.Mode);
        var image = result.Image;
        long stampR = 0, stampG = 0, stamps = 0;
        for (int y = 0; y < image.Height; y++)
        {
            for (int x = 0; x < image.Width; x++)
            {
                int i = (y * image.Width + x) * 4;
                int kind = EnhancerPages.Kind(x, y, image.Width, image.Height, true, false);
                if (kind == 0)
                {
                    // White and neutral: the warm paper's tint is gone.
                    Assert.True(image.Pixels[i] >= 250 && image.Pixels[i + 1] >= 250 && image.Pixels[i + 2] >= 250, $"paper at {x}, {y}");
                    Assert.True(Math.Abs(image.Pixels[i] - image.Pixels[i + 2]) <= 3, $"tint at {x}, {y}");
                }
                else if (kind == 2)
                {
                    stampR += image.Pixels[i];
                    stampG += image.Pixels[i + 1];
                    stamps++;
                }
            }
        }
        Assert.True((stampR - stampG) / (double)stamps >= 150, "the stamp stays red");
        Assert.True(Lumas(image, 1).Max <= 10);
    }

    [Fact]
    public void AutoKeepsColorOnlyWhereThePageHasColor()
    {
        var colored = EnhancerPages.Shadowed();
        var auto = DocumentEnhancer.Enhance(colored, DocumentEnhanceMode.Auto);
        Assert.Equal(DocumentEnhanceMode.Color, auto.Mode);
        Assert.Equal(DocumentEnhancer.Enhance(colored, DocumentEnhanceMode.Color).Image.Pixels, auto.Image.Pixels);

        var plain = EnhancerPages.Shadowed(stamp: false);
        var grayAuto = DocumentEnhancer.Enhance(plain, DocumentEnhanceMode.Auto);
        Assert.Equal(DocumentEnhanceMode.Gray, grayAuto.Mode);
        Assert.Equal(DocumentEnhancer.Enhance(plain, DocumentEnhanceMode.Gray).Image.Pixels, grayAuto.Image.Pixels);
    }

    [Fact]
    public void BlackAndWhiteIsPrintOnPaper()
    {
        var result = DocumentEnhancer.Enhance(EnhancerPages.Shadowed(), DocumentEnhanceMode.BlackAndWhite);
        Assert.Equal(DocumentEnhanceMode.BlackAndWhite, result.Mode);
        var image = result.Image;
        for (int y = 0; y < image.Height; y++)
        {
            for (int x = 0; x < image.Width; x++)
            {
                int i = (y * image.Width + x) * 4;
                byte v = image.Pixels[i];
                Assert.True(v == 0 || v == 255);
                int kind = EnhancerPages.Kind(x, y, image.Width, image.Height, true, false);
                if (kind == 0) Assert.Equal(255, v);
                if (kind == 1) Assert.Equal(0, v);
            }
        }
        // Every pixel is kept as it is when the page is packed for CCITT G4.
        var packed = Bilevel.Pack(image);
        Assert.Equal(image.Pixels, Bilevel.Unpack(packed, image.Width, image.Height).Pixels);
    }

    [Fact]
    public void ALargeDarkPictureIsNotWashedOut()
    {
        var page = EnhancerPages.Shadowed(stamp: false, picture: true);
        var result = DocumentEnhancer.Enhance(page, DocumentEnhanceMode.Gray).Image;
        Assert.True(Lumas(result, 0, false, true).Min >= 250);
        var picture = Lumas(result, 3, false, true);
        Assert.True(picture.Mean <= 70, $"picture mean {picture.Mean}");
        // Its tiles were filled in from the paper around it.
        var gray = GrayImage.Luma(page);
        var raw = BackgroundMap.Estimate(gray, 0, 0, page.Width, page.Height, DocumentEnhancer.TileSize(page.Width, page.Height))!;
        var paper = DocumentEnhancer.PaperMap(gray);
        Assert.True(raw.ValueAt(90, 245) < 80);
        Assert.True(paper.ValueAt(90, 245) > 120);
    }

    [Fact]
    public void APhotoIsStretchedAsAWholeNotEvenedOut()
    {
        var page = EnhancerPages.Shadowed();
        var result = DocumentEnhancer.Enhance(page, DocumentEnhanceMode.Photo);
        Assert.Equal(DocumentEnhanceMode.Photo, result.Mode);
        var paper = Lumas(result.Image, 0);
        // The shadow stays (the light is the photo's), the ends of the range are stretched.
        Assert.True(paper.Max - paper.Min >= 100, $"paper {paper.Min}...{paper.Max}");
        Assert.True(paper.Max >= 250);
        Assert.True(Lumas(result.Image, 1).Min <= 5);
        // A flat picture is left as it is.
        var flat = RgbaImage.Filled(40, 30, 120, 110, 100);
        var same = DocumentEnhancer.Enhance(flat, DocumentEnhanceMode.Photo).Image;
        Assert.Equal(flat.Pixels, same.Pixels);
        Assert.NotSame(flat, same);
    }

    [Fact]
    public void TheBytesAreTheSameOnBothPlatforms()
    {
        var page = EnhancerPages.Shadowed();
        Assert.Equal(0x70604295u, PhotoScenes.Checksum(DocumentEnhancer.Enhance(page, DocumentEnhanceMode.Auto).Image));
        Assert.Equal(0x70604295u, PhotoScenes.Checksum(DocumentEnhancer.Enhance(page, DocumentEnhanceMode.Color).Image));
        Assert.Equal(0xEC4526A3u, PhotoScenes.Checksum(DocumentEnhancer.Enhance(page, DocumentEnhanceMode.Gray).Image));
        Assert.Equal(0x43422875u, PhotoScenes.Checksum(DocumentEnhancer.Enhance(page, DocumentEnhanceMode.BlackAndWhite).Image));
        Assert.Equal(0xBCA2862Cu, PhotoScenes.Checksum(DocumentEnhancer.Enhance(page, DocumentEnhanceMode.Photo).Image));
        var plain = EnhancerPages.Shadowed(stamp: false);
        Assert.Equal(0xF81468D6u, PhotoScenes.Checksum(DocumentEnhancer.Enhance(plain, DocumentEnhanceMode.Auto).Image));
        var picture = EnhancerPages.Shadowed(stamp: false, picture: true);
        Assert.Equal(0x13CF7A4Cu, PhotoScenes.Checksum(DocumentEnhancer.Enhance(picture, DocumentEnhanceMode.Gray).Image));
    }

    [Fact]
    public void DarkTilesAreFilledFromThePaperBesideThem()
    {
        // A 4 × 4 map: paper at 200 with a gentle step (still paper) and a 2 × 2 dark block.
        var tiles = new byte[]
        {
            200, 200, 190, 180,
            200, 60, 50, 175,
            200, 55, 40, 170,
            200, 200, 180, 170,
        };
        var gray = new byte[16 * 16];
        for (int y = 0; y < 16; y++)
        {
            for (int x = 0; x < 16; x++) gray[y * 16 + x] = tiles[y / 4 * 4 + x / 4];
        }
        var map = BackgroundMap.Estimate(new GrayImage(16, 16, gray), 0, 0, 16, 16, 4)!;
        Assert.Equal(tiles, map.Tiles);
        var raised = map.RaisedDarkTiles(DocumentEnhancer.DarkTileShare);
        // The block takes the paper beside it; the gentle step stays.
        Assert.Equal(new byte[]
        {
            200, 200, 190, 180,
            200, 200, 200, 175,
            200, 200, 200, 170,
            200, 200, 180, 170,
        }, raised.Tiles);
        // A block wider than a tile's neighbors is filled pass after pass, from the paper inwards.
        var wide = new byte[8 * 8];
        for (int i = 0; i < wide.Length; i++) wide[i] = 210;
        for (int y = 1; y < 7; y++)
        {
            for (int x = 1; x < 7; x++) wide[y * 8 + x] = 50;
        }
        var widePixels = new byte[32 * 32];
        for (int y = 0; y < 32; y++)
        {
            for (int x = 0; x < 32; x++) widePixels[y * 32 + x] = wide[y / 4 * 8 + x / 4];
        }
        var filled = BackgroundMap.Estimate(new GrayImage(32, 32, widePixels), 0, 0, 32, 32, 4)!.RaisedDarkTiles(0.7);
        Assert.All(filled.Tiles, tile => Assert.Equal(210, tile));
        Assert.Equal(map.Width, raised.Width);
        Assert.Equal(map.Columns, raised.Columns);
        // A dark region that reaches the map's edge is a shadow cast from beyond the sheet: it keeps its own
        // tiles, the one inside it too, while a dark tile inside the paper is still filled.
        var mixed = new byte[]
        {
            200, 200, 200, 200, 200, 90,
            200, 50, 200, 200, 60, 80,
            200, 200, 200, 200, 200, 85,
            200, 200, 200, 200, 200, 200,
        };
        var mixedPixels = new byte[24 * 16];
        for (int y = 0; y < 16; y++)
        {
            for (int x = 0; x < 24; x++) mixedPixels[y * 24 + x] = mixed[y / 4 * 6 + x / 4];
        }
        var kept = BackgroundMap.Estimate(new GrayImage(24, 16, mixedPixels), 0, 0, 24, 16, 4)!.RaisedDarkTiles(DocumentEnhancer.DarkTileShare);
        var expected = (byte[])mixed.Clone();
        expected[7] = 200;
        Assert.Equal(expected, kept.Tiles);
    }

    [Fact]
    public void AHardShadowFromTheEdgeIsEvenedOutNotFilledIn()
    {
        var page = EnhancerPages.HardShadow();
        Assert.Equal(0xA8CB3FCDu, PhotoScenes.Checksum(page));
        int w = page.Width, h = page.Height;
        int tile = DocumentEnhancer.TileSize(w, h);
        // The shadowed paper is at 45 % of the lit paper, so its tiles are much darker than their lit
        // neighbors; the shadow reaches the page's edge, so the paper map follows it instead of filling it in.
        var gray = GrayImage.Luma(page);
        Assert.True(gray.Pixels[20 * w + 200] <= 105);
        var paper = DocumentEnhancer.PaperMap(gray);
        Assert.True(paper.ValueAt(200, 20) < 110, $"shadowed paper map {paper.ValueAt(200, 20)}");
        Assert.True(paper.ValueAt(40, 20) > 220);
        // The paper one white on both sides (but within a tile of the shadow's edge, where the map steps
        // between tile centers), the print black on both; in black and white the print stays in the shadow too.
        var result = DocumentEnhancer.Enhance(page, DocumentEnhanceMode.Gray);
        var bw = DocumentEnhancer.Enhance(page, DocumentEnhanceMode.BlackAndWhite);
        Assert.Equal(DocumentEnhanceMode.BlackAndWhite, bw.Mode);
        for (int y = 0; y < h; y++)
        {
            for (int x = 0; x < w; x++)
            {
                bool ink = EnhancerPages.IsInk(x, y, w, h);
                bool nearEdge = x >= EnhancerPages.ShadowEdge && x < EnhancerPages.ShadowEdge + tile;
                int v = Luma(result.Image, x, y);
                byte b = bw.Image.Pixels[(y * w + x) * 4];
                if (ink)
                {
                    Assert.True(v <= 30, $"print {v} at {x}, {y}");
                    Assert.Equal(0, b);
                }
                else if (!nearEdge)
                {
                    Assert.True(v >= 250, $"paper {v} at {x}, {y}");
                    Assert.Equal(255, b);
                }
            }
        }
        Assert.Equal(0x2E7FEF38u, PhotoScenes.Checksum(result.Image));
        Assert.Equal(0x1EDFC6F4u, PhotoScenes.Checksum(bw.Image));
        Assert.Equal(0x2C520A1Du, PhotoScenes.Checksum(DocumentEnhancer.Enhance(page, DocumentEnhanceMode.Color).Image));
        var auto = DocumentEnhancer.Enhance(page, DocumentEnhanceMode.Auto);
        Assert.Equal(DocumentEnhanceMode.Gray, auto.Mode);
        Assert.Equal(result.Image.Pixels, auto.Image.Pixels);
    }

    [Fact]
    public void LightPrintOnADarkGroundIsKeptNotWhitenedAway()
    {
        var page = EnhancerPages.DarkGround();
        Assert.Equal(0xE4CFC2D5u, PhotoScenes.Checksum(page));
        Assert.True(DocumentEnhancer.IsLightOnDark(GrayImage.Luma(page)));
        int w = page.Width, h = page.Height;
        var modes = new[]
        {
            (DocumentEnhanceMode.Gray, DocumentEnhanceMode.Gray),
            (DocumentEnhanceMode.BlackAndWhite, DocumentEnhanceMode.BlackAndWhite),
            (DocumentEnhanceMode.Auto, DocumentEnhanceMode.Gray),
            (DocumentEnhanceMode.Color, DocumentEnhanceMode.Color),
        };
        foreach (var (mode, applied) in modes)
        {
            // Stretched as a whole: the ground black, the print white, never the whole page white.
            var result = DocumentEnhancer.Enhance(page, mode);
            Assert.Equal(applied, result.Mode);
            for (int y = 0; y < h; y++)
            {
                for (int x = 0; x < w; x++)
                {
                    int i = (y * w + x) * 4;
                    int v = Luma(result.Image, x, y);
                    if (EnhancerPages.IsLightPrint(x, y, w, h)) Assert.True(v >= 250, $"{mode}: print {v} at {x}, {y}");
                    else Assert.True(v <= 5, $"{mode}: ground {v} at {x}, {y}");
                    Assert.Equal(result.Image.Pixels[i], result.Image.Pixels[i + 2]);
                    Assert.Equal(255, result.Image.Pixels[i + 3]);
                }
            }
            Assert.Equal(0x6EDC8C95u, PhotoScenes.Checksum(result.Image));
        }
        // A page with paper is not light on dark: shadowed, with a dark picture, or under a hard shadow.
        Assert.False(DocumentEnhancer.IsLightOnDark(GrayImage.Luma(EnhancerPages.Shadowed())));
        Assert.False(DocumentEnhancer.IsLightOnDark(GrayImage.Luma(EnhancerPages.Shadowed(stamp: false, picture: true))));
        Assert.False(DocumentEnhancer.IsLightOnDark(GrayImage.Luma(EnhancerPages.HardShadow())));
        // Nor is a blank dark sheet: it has no light print.
        Assert.False(DocumentEnhancer.IsLightOnDark(GrayImage.Luma(RgbaImage.Filled(240, 320, 55, 55, 55))));
        // Nor a page with little or no print beside a hard step: the lit paper next to a shadow's edge or
        // around a big dark picture is the ground of the tile beside it, not light print, wherever in its
        // tile the edge falls.
        foreach (int edge in new[] { 109, 127, EnhancerPages.ShadowEdge, 148 })
        {
            foreach (var print in new[] { EnhancerPages.ShadowPrint.FewLines, EnhancerPages.ShadowPrint.Blank })
            {
                var shadowed = EnhancerPages.HardShadow(print: print, edge: edge);
                Assert.False(DocumentEnhancer.IsLightOnDark(GrayImage.Luma(shadowed)), $"{print}, edge at {edge}");
            }
        }
        Assert.False(DocumentEnhancer.IsLightOnDark(GrayImage.Luma(EnhancerPages.PictureWithCaption())));
    }

    [Fact]
    public void AHardShadowOnAPageWithLittlePrintIsEvenedOutToo()
    {
        Assert.Equal(0x4B4A6495u, PhotoScenes.Checksum(EnhancerPages.HardShadow(print: EnhancerPages.ShadowPrint.FewLines)));
        Assert.Equal(0x2EC994C5u, PhotoScenes.Checksum(EnhancerPages.HardShadow(print: EnhancerPages.ShadowPrint.Blank)));
        Assert.Equal(0x263A9905u, PhotoScenes.Checksum(EnhancerPages.HardShadow(print: EnhancerPages.ShadowPrint.FewLines, edge: 109)));
        Assert.Equal(0xA99E33C5u, PhotoScenes.Checksum(EnhancerPages.HardShadow(print: EnhancerPages.ShadowPrint.Blank, edge: 148)));
        foreach (var print in new[] { EnhancerPages.ShadowPrint.FewLines, EnhancerPages.ShadowPrint.Blank })
        {
            var page = EnhancerPages.HardShadow(print: print);
            int w = page.Width, h = page.Height;
            int tile = DocumentEnhancer.TileSize(w, h);
            // A short note or a blank sheet under a phone's shadow: the shadowed paper white like the lit
            // paper (not black), the print black in the shadow too, in gray and in black and white.
            var gray = DocumentEnhancer.Enhance(page, DocumentEnhanceMode.Gray);
            var bw = DocumentEnhancer.Enhance(page, DocumentEnhanceMode.BlackAndWhite);
            Assert.Equal(DocumentEnhanceMode.Gray, gray.Mode);
            Assert.Equal(DocumentEnhanceMode.BlackAndWhite, bw.Mode);
            for (int y = 0; y < h; y++)
            {
                for (int x = 0; x < w; x++)
                {
                    bool nearEdge = x >= EnhancerPages.ShadowEdge && x < EnhancerPages.ShadowEdge + tile;
                    int v = Luma(gray.Image, x, y);
                    byte b = bw.Image.Pixels[(y * w + x) * 4];
                    if (EnhancerPages.IsPrint(x, y, w, h, print))
                    {
                        Assert.True(v <= 30, $"{print}: print {v} at {x}, {y}");
                        Assert.Equal(0, b);
                    }
                    else if (!nearEdge)
                    {
                        Assert.True(v >= 250, $"{print}: paper {v} at {x}, {y}");
                        Assert.Equal(255, b);
                    }
                }
            }
        }
        var note = EnhancerPages.HardShadow(print: EnhancerPages.ShadowPrint.FewLines);
        var noteGray = DocumentEnhancer.Enhance(note, DocumentEnhanceMode.Gray).Image;
        Assert.Equal(0x7181A6C5u, PhotoScenes.Checksum(noteGray));
        var noteAuto = DocumentEnhancer.Enhance(note, DocumentEnhanceMode.Auto);
        Assert.Equal(DocumentEnhanceMode.Gray, noteAuto.Mode);
        Assert.Equal(noteGray.Pixels, noteAuto.Image.Pixels);
        Assert.Equal(0xF84323D5u, PhotoScenes.Checksum(DocumentEnhancer.Enhance(note, DocumentEnhanceMode.BlackAndWhite).Image));
        var blank = EnhancerPages.HardShadow(print: EnhancerPages.ShadowPrint.Blank);
        Assert.Equal(0x55EE99C5u, PhotoScenes.Checksum(DocumentEnhancer.Enhance(blank, DocumentEnhanceMode.BlackAndWhite).Image));
    }

    [Fact]
    public void ABigDarkPictureWithACaptionKeepsItsPaperAndItsPicture()
    {
        var page = EnhancerPages.PictureWithCaption();
        Assert.Equal(0x78DD9B25u, PhotoScenes.Checksum(page));
        int w = page.Width, h = page.Height;
        var gray = DocumentEnhancer.Enhance(page, DocumentEnhanceMode.Gray);
        Assert.Equal(DocumentEnhanceMode.Gray, gray.Mode);
        int paperMin = 255, captionMax = 0;
        long pictureSum = 0, pictureCount = 0;
        for (int y = 0; y < h; y++)
        {
            for (int x = 0; x < w; x++)
            {
                int v = Luma(gray.Image, x, y);
                if (EnhancerPages.IsBigPicture(x, y))
                {
                    pictureSum += v;
                    pictureCount++;
                }
                else if (EnhancerPages.IsCaption(x, y)) captionMax = Math.Max(captionMax, v);
                else paperMin = Math.Min(paperMin, v);
            }
        }
        Assert.True(paperMin >= 250, $"paper {paperMin}");
        Assert.True(captionMax <= 30, $"caption {captionMax}");
        Assert.True(pictureSum / (double)pictureCount <= 70, $"picture mean {pictureSum / (double)pictureCount}");
        Assert.Equal(0x895657F5u, PhotoScenes.Checksum(gray.Image));
        Assert.Equal(0x4ACCE6B5u, PhotoScenes.Checksum(DocumentEnhancer.Enhance(page, DocumentEnhanceMode.BlackAndWhite).Image));
    }

    [Fact]
    public void TheModeFollowsTheTaskAndWhatWasShot()
    {
        var settings = new ScanSettings();
        Assert.Equal(DocumentEnhanceMode.Auto, DocumentEnhancer.ModeFor(settings));
        settings.ColorMode = ColorMode.Grayscale;
        Assert.Equal(DocumentEnhanceMode.Gray, DocumentEnhancer.ModeFor(settings));
        settings.ColorMode = ColorMode.BlackWhite;
        Assert.Equal(DocumentEnhanceMode.BlackAndWhite, DocumentEnhancer.ModeFor(settings));
        settings.Intent = ScanIntent.Photo;
        Assert.Equal(DocumentEnhanceMode.Photo, DocumentEnhancer.ModeFor(settings));
        Assert.Equal(DocumentEnhanceMode.Photo, DocumentEnhancer.ModeFor(DocumentEnhanceMode.Gray, CaptureKind.Photo));
        Assert.Equal(DocumentEnhanceMode.Photo, DocumentEnhancer.ModeFor(DocumentEnhanceMode.Auto, CaptureKind.IdCard));
        Assert.Equal(DocumentEnhanceMode.Gray, DocumentEnhancer.ModeFor(DocumentEnhanceMode.Gray, CaptureKind.Receipt));
        Assert.Equal(DocumentEnhanceMode.BlackAndWhite, DocumentEnhancer.ModeFor(DocumentEnhanceMode.BlackAndWhite, CaptureKind.Document));
        Assert.Equal(20, DocumentEnhancer.TileSize(240, 320));
        Assert.Equal(DocumentEnhancer.MinTileSize, DocumentEnhancer.TileSize(40, 30));
    }

    [Fact]
    public void TheEnhanceStepCleansACutPageUpOnce()
    {
        var quad = new Quad(new PointD(100, 60), new PointD(340, 60), new PointD(340, 380), new PointD(100, 380));
        // The shadowed page laid on a dark table, as a camera took it.
        var sheet = EnhancerPages.Shadowed();
        var photoPixels = new byte[440 * 440 * 4];
        for (int y = 0; y < 440; y++)
        {
            for (int x = 0; x < 440; x++)
            {
                int o = (y * 440 + x) * 4;
                bool onSheet = x >= 100 && x < 340 && y >= 60 && y < 380;
                int s = onSheet ? ((y - 60) * 240 + (x - 100)) * 4 : -1;
                photoPixels[o] = onSheet ? sheet.Pixels[s] : (byte)30;
                photoPixels[o + 1] = onSheet ? sheet.Pixels[s + 1] : (byte)32;
                photoPixels[o + 2] = onSheet ? sheet.Pixels[s + 2] : (byte)36;
                photoPixels[o + 3] = 255;
            }
        }
        var photo = new RgbaImage(440, 440, photoPixels);
        var page = new ScannedPage(photo, CaptureScale.NominalDpi, ColorMode.Color) { Source = PageSource.Photo }
            .WithCapture(new CaptureFacts(quad, 440, 440));
        var cut = new PerspectiveStep().Apply(page);
        var step = new EnhanceStep(DocumentEnhanceMode.Auto);
        var cleaned = step.Apply(cut);
        Assert.Equal(DocumentEnhanceMode.Color, cleaned.Capture!.Enhancement);
        Assert.Equal(cut.Capture! with { Enhancement = DocumentEnhanceMode.Color }, cleaned.Capture);
        Assert.Equal(DocumentEnhancer.Enhance(cut.Image, DocumentEnhanceMode.Auto).Image.Pixels, cleaned.Image.Pixels);
        Assert.Same(photo, cleaned.Alternate!.Image);
        Assert.Equal(cut.Geometry, cleaned.Geometry);
        Assert.Equal(cut.Dpi, cleaned.Dpi);
        Assert.Equal(ColorMode.Color, cleaned.ColorMode);
        // Once only.
        Assert.Same(cleaned, step.Apply(cleaned));
        // Gray sets the page's color mode.
        var grayed = new EnhanceStep(DocumentEnhanceMode.Gray).Apply(cut);
        Assert.Equal(ColorMode.Grayscale, grayed.ColorMode);
        Assert.Equal(DocumentEnhanceMode.Gray, grayed.Capture!.Enhancement);
        var bw = new EnhanceStep(DocumentEnhanceMode.BlackAndWhite).Apply(cut);
        Assert.Equal(ColorMode.BlackWhite, bw.ColorMode);
        // A photo print is a photo, whatever the task says.
        var print = new PerspectiveStep().Apply(page.WithCapture(new CaptureFacts(quad, 440, 440) { Kind = CaptureKind.Photo }));
        Assert.Equal(DocumentEnhanceMode.Photo, new EnhanceStep(DocumentEnhanceMode.Gray).Apply(print).Capture!.Enhancement);
        // Not cut out yet, cut out whole (Apple's scanner) or a scanner's page: left alone.
        Assert.Same(page, step.Apply(page));
        var whole = new ScannedPage(sheet, 200, ColorMode.Color).WithCapture(new CaptureFacts(quad, 440, 440)
        {
            Scale = CaptureScale.FromAspect(240, 320, CaptureKind.Document),
        });
        Assert.Same(whole, step.Apply(whole));
        var scanned = new ScannedPage(sheet, 300, ColorMode.Color);
        Assert.Same(scanned, step.Apply(scanned));
    }
}
