using LazyScan.Core;

namespace LazyScan.Core.Tests;

// Twin of Tests/LazyScanTests/PhotoScenes.swift: the same scenes, byte for byte. Integer
// arithmetic only (64-bit, no floating point), and TestPages' xorshift32 generator consumed in the
// same order, so both platforms draw identical pixels (pinned by checksum in both suites).

/// <summary>
/// Synthetic phone photos of a page (360 × 480 RGBA): an A4-shaped sheet (210 × 297 page pixels,
/// one per millimetre, with a header bar, lines of glyphs and a picture) laid on a backdrop under
/// a known perspective, each photo pixel the mean of 2 × 2 samples, then lit: a gradient across
/// the frame, the phone's soft shadow and a glare spot.
/// </summary>
internal static class PhotoScenes
{
    public const int Width = 360;
    public const int Height = 480;
    public const int PageWidth = 210;
    public const int PageHeight = 297;

    /// <summary>
    /// The page-to-photo map x = (A u + B v + C) / (G u + H v + I), y = (D u + E v + F) / (G u + H v + I),
    /// page pixels (u, v) to photo pixels, in integers.
    /// </summary>
    public readonly record struct IntHomography(long A, long B, long C, long D, long E, long F, long G, long H, long I)
    {
        /// <summary>Where page point (u, v) lands in the photo.</summary>
        public PointD Map(double u, double v)
        {
            double w = G * u + H * v + I;
            return new PointD((A * u + B * v + C) / w, (D * u + E * v + F) / w);
        }

        /// <summary>The page's outline in the photo.</summary>
        public Quad Corners(int pageWidth, int pageHeight) => Quad.FromCorners(
            [Map(0, 0), Map(pageWidth, 0), Map(pageWidth, pageHeight), Map(0, pageHeight)]);
    }

    public static readonly IntHomography WoodMap = new(1155332, -122914, 81788928, 177335, 930372, 75497472, 485, -598, 1048576);
    public static readonly IntHomography DarkMap = new(739319, -271102, 110100480, -28187, 541359, 94371840, -96, -1455, 1048576);
    public static readonly IntHomography LightMap = new(1121991, 12060, 62914560, -46867, 1041969, 62914560, 272, -332, 1048576);
    public static readonly IntHomography SimilarMap = new(1095194, -44778, 73400320, -50732, 1055747, 83886080, -11, -267, 1048576);
    public static readonly IntHomography CutOffMap = new(1228481, -108457, 157286400, 195764, 1313578, 41943040, -50, 298, 1048576);
    public static readonly IntHomography UnderMap = new(806253, 18023, 31457280, -48774, 760787, 41943040, 39, -88, 1048576);
    public static readonly IntHomography TopMap = new(1053725, -86609, 125829120, 102517, 953472, 157286400, 16, -160, 1048576);
    public static readonly IntHomography LeftMap = new(741204, 21217, 20971520, -45071, 763036, 125829120, -46, 1, 1048576);
    public static readonly IntHomography RightMap = new(748983, -21183, 199229440, 29959, 766131, 120586240, 0, 0, 1048576);
    public static readonly IntHomography RoundTripMap = new(1454408, -35269, 41943040, 82485, 1426885, 37748736, 50, 1, 1048576);

    /// <summary>
    /// An upright page 1.4 photo pixels per page pixel (294 × 415.8) whose bottom edge lies
    /// <paramref name="gap"/> px above the frame's bottom (below it when negative: cut off).
    /// </summary>
    public static IntHomography BottomGapMap(int gap) =>
        new(1468006, 0, 33L * 1048576, 0, 1468006, (Height - gap) * 1048576L - 1468006L * PageHeight, 0, 0, 1048576);

    /// <summary>The same page with its right edge <paramref name="gap"/> px from the frame's right side.</summary>
    public static IntHomography RightGapMap(int gap) =>
        new(1468006, 0, (Width - gap) * 1048576L - 1468006L * PageWidth, 0, 1468006, 30L * 1048576, 0, 0, 1048576);

    public enum Backdrop { Wood, Dark, Light, Similar, Plain }

    /// <summary>A soft ellipse darkened by <see cref="Depth"/> ‰, fading out to 2.5 × its size (in squared terms).</summary>
    public sealed record Shadow(int Cx, int Cy, int Rx, int Ry, int Depth);

    /// <summary>A spot brightened toward white by up to <see cref="Strength"/> ‰, fading quadratically to its radius.</summary>
    public sealed record Glare(int Cx, int Cy, int R, int Strength);

    /// <summary>The light: dimmed by up to <see cref="AcrossX"/> ‰ toward the right and <see cref="DownY"/> ‰ toward the bottom.</summary>
    public sealed record Lighting(int AcrossX, int DownY, Shadow? Shadow, Glare? Glare);

    /// <summary>A sheet laid in the photo: its own pixels (RGB) and its map.</summary>
    public sealed record Sheet(byte[] Rgb, int SheetWidth, int SheetHeight, IntHomography Map);

    // MARK: - The scenes

    public static RgbaImage WoodScene() => Scene(Backdrop.Wood, 0x3D00D001, new Lighting(180, 0, null, null),
        new Sheet(PageRaster(0x9A6E0001), PageWidth, PageHeight, WoodMap));

    public static RgbaImage DarkScene() => Scene(Backdrop.Dark, 0x3D00D002, new Lighting(0, 120, null, new Glare(280, 120, 70, 900)),
        new Sheet(PageRaster(0x9A6E0002), PageWidth, PageHeight, DarkMap));

    public static RgbaImage LightScene() => Scene(Backdrop.Light, 0x3D00D003, new Lighting(0, 0, new Shadow(40, 470, 220, 260, 380), null),
        new Sheet(PageRaster(0x9A6E0003), PageWidth, PageHeight, LightMap));

    public static RgbaImage SimilarScene() => Scene(Backdrop.Similar, 0x3D00D004, new Lighting(100, 60, null, new Glare(180, 250, 55, 800)),
        new Sheet(PageRaster(0x9A6E0004), PageWidth, PageHeight, SimilarMap));

    public static RgbaImage NoPageScene() => Scene(Backdrop.Wood, 0x3D00D005,
        new Lighting(150, 0, new Shadow(300, 100, 150, 120, 350), new Glare(120, 300, 60, 900)));

    public static RgbaImage PlainScene() => Scene(Backdrop.Plain, 0x3D00D006, new Lighting(0, 0, null, null));

    public static RgbaImage CutOffScene() => Scene(Backdrop.Dark, 0x3D00D007, new Lighting(0, 0, null, null),
        new Sheet(PageRaster(0x9A6E0007), PageWidth, PageHeight, CutOffMap));

    /// <summary>A smaller sheet of cream paper with a larger white one lying over its lower right part.</summary>
    public static RgbaImage OverlapScene() => Scene(Backdrop.Dark, 0x3D00D008, new Lighting(0, 0, null, null),
        new Sheet(PageRaster(0x9A6E0008, 232, 226, 210), PageWidth, PageHeight, UnderMap),
        new Sheet(PageRaster(0x9A6E0009), PageWidth, PageHeight, TopMap));

    /// <summary>Two sheets of the same size side by side.</summary>
    public static RgbaImage TwoPagesScene() => Scene(Backdrop.Light, 0x3D00D00A, new Lighting(0, 0, null, null),
        new Sheet(PageRaster(0x9A6E000A), PageWidth, PageHeight, LeftMap),
        new Sheet(PageRaster(0x9A6E000B), PageWidth, PageHeight, RightMap));

    /// <summary>The colored blocks of <see cref="BlockRaster"/> filling most of the frame, for the round trip.</summary>
    public static RgbaImage RoundTripScene() => Scene(Backdrop.Dark, 0x3D00D00C, new Lighting(0, 0, null, null),
        new Sheet(BlockRaster(0x9A6E000C), PageWidth, PageHeight, RoundTripMap));

    /// <summary>A page on wood filling the frame down to <paramref name="gap"/> px from its bottom (<see cref="BottomGapMap"/>).</summary>
    public static RgbaImage BottomGapScene(int gap) => Scene(Backdrop.Wood, 0x3D00D00D, new Lighting(120, 0, null, null),
        new Sheet(PageRaster(0x9A6E000D), PageWidth, PageHeight, BottomGapMap(gap)));

    /// <summary>A page on wood reaching to <paramref name="gap"/> px from the frame's right side (<see cref="RightGapMap"/>).</summary>
    public static RgbaImage RightGapScene(int gap) => Scene(Backdrop.Wood, 0x3D00D00E, new Lighting(120, 0, null, null),
        new Sheet(PageRaster(0x9A6E000E), PageWidth, PageHeight, RightGapMap(gap)));

    // MARK: - Sheets

    /// <summary>
    /// A page: paper (white, 246, 244, 238, unless given) with noise, a dark blue-gray header bar,
    /// 15 lines of glyphs (as <see cref="TestPages.TextLine"/> draws them) every 14 px and a picture block.
    /// </summary>
    public static byte[] PageRaster(uint seed, int paperR = 246, int paperG = 244, int paperB = 238)
    {
        var p = new byte[PageWidth * PageHeight * 3];
        var rng = new TestPages.Rng(seed);
        for (int i = 0; i < PageWidth * PageHeight; i++)
        {
            int n = rng.Noise();
            p[i * 3] = TestPages.Clamp(paperR + n);
            p[i * 3 + 1] = TestPages.Clamp(paperG + n);
            p[i * 3 + 2] = TestPages.Clamp(paperB + n);
        }
        FillRgb(p, 20, 18, 170, 14, 52, 64, 92);
        var text = new TestPages.Rng(seed ^ 0x5A5A5A5A);
        int[] picks = [0b00111, 0b01011, 0b01101, 0b01110, 0b10011, 0b10101, 0b10110, 0b11001, 0b11010, 0b11100];
        for (int line = 0; line < 15; line++)
        {
            int y = 46 + line * 14;
            int maxWidth = line % 5 == 4 ? 90 : 170;
            int cx = 20;
            while (true)
            {
                int glyphs = 2 + text.Below(7);
                if (cx + glyphs * 7 > 20 + maxWidth) break;
                for (int g = 0; g < glyphs; g++)
                {
                    int bits = picks[text.Below(10)];
                    if ((bits & 1) != 0) FillRgb(p, cx, y, 1, 9, 40, 40, 46);
                    if ((bits & 2) != 0) FillRgb(p, cx + 4, y, 1, 9, 40, 40, 46);
                    if ((bits & 4) != 0) FillRgb(p, cx, y, 5, 1, 40, 40, 46);
                    if ((bits & 8) != 0) FillRgb(p, cx, y + 4, 5, 1, 40, 40, 46);
                    if ((bits & 16) != 0) FillRgb(p, cx, y + 8, 5, 1, 40, 40, 46);
                    cx += 7;
                }
                cx += 7;
            }
        }
        for (int y = 262; y < 286; y++)
        {
            for (int x = 120; x < 190; x++)
            {
                int i = (y * PageWidth + x) * 3;
                int v = 70 + (x * 7 + y * 13) % 120;
                p[i] = (byte)v;
                p[i + 1] = (byte)(v * 9 / 10);
                p[i + 2] = (byte)(v * 7 / 10);
            }
        }
        return p;
    }

    /// <summary>A sheet of 10 × 10 px blocks in random colors (each channel 40...239), for the round trip.</summary>
    public static byte[] BlockRaster(uint seed)
    {
        var p = new byte[PageWidth * PageHeight * 3];
        var rng = new TestPages.Rng(seed);
        for (int by = 0; by < PageHeight; by += 10)
        {
            for (int bx = 0; bx < PageWidth; bx += 10)
            {
                int r = 40 + rng.Below(200), g = 40 + rng.Below(200), b = 40 + rng.Below(200);
                FillRgb(p, bx, by, 10, 10, (byte)r, (byte)g, (byte)b);
            }
        }
        return p;
    }

    /// <summary>The sheet's pixels as an RGBA image (to compare a corrected page with).</summary>
    public static RgbaImage SheetImage(byte[] rgb)
    {
        var rgba = new byte[PageWidth * PageHeight * 4];
        for (int i = 0; i < PageWidth * PageHeight; i++)
        {
            rgba[i * 4] = rgb[i * 3];
            rgba[i * 4 + 1] = rgb[i * 3 + 1];
            rgba[i * 4 + 2] = rgb[i * 3 + 2];
            rgba[i * 4 + 3] = 255;
        }
        return new RgbaImage(PageWidth, PageHeight, rgba);
    }

    private static void FillRgb(byte[] p, int x, int y, int w, int h, byte r, byte g, byte b)
    {
        for (int py = Math.Max(0, y); py < Math.Min(PageHeight, y + h); py++)
        {
            for (int px = Math.Max(0, x); px < Math.Min(PageWidth, x + w); px++)
            {
                int i = (py * PageWidth + px) * 3;
                p[i] = r;
                p[i + 1] = g;
                p[i + 2] = b;
            }
        }
    }

    // MARK: - Drawing

    /// <summary>
    /// The photo: for every pixel the backdrop (with noise from <paramref name="seed"/>, one draw
    /// per pixel), the topmost sheet at each of its 2 × 2 sample points (quarter-pixel positions
    /// 1 and 3) or the backdrop, averaged (rounding half up), then dimmed by the light and
    /// brightened by the glare.
    /// </summary>
    public static RgbaImage Scene(Backdrop backdrop, uint seed, Lighting light, params Sheet[] sheets)
    {
        var rng = new TestPages.Rng(seed);
        var adj = new long[sheets.Length * 9];
        for (int s = 0; s < sheets.Length; s++)
        {
            var m = sheets[s].Map;
            adj[s * 9 + 0] = m.E * m.I - m.F * m.H;
            adj[s * 9 + 1] = m.C * m.H - m.B * m.I;
            adj[s * 9 + 2] = m.B * m.F - m.C * m.E;
            adj[s * 9 + 3] = m.F * m.G - m.D * m.I;
            adj[s * 9 + 4] = m.A * m.I - m.C * m.G;
            adj[s * 9 + 5] = m.C * m.D - m.A * m.F;
            adj[s * 9 + 6] = m.D * m.H - m.E * m.G;
            adj[s * 9 + 7] = m.B * m.G - m.A * m.H;
            adj[s * 9 + 8] = m.A * m.E - m.B * m.D;
        }
        var pixels = new byte[Width * Height * 4];
        for (int y = 0; y < Height; y++)
        {
            for (int x = 0; x < Width; x++)
            {
                var (br, bg, bb) = BackdropColor(backdrop, x, y, rng);
                int sr = 0, sg = 0, sb = 0;
                for (int sample = 0; sample < 4; sample++)
                {
                    long qx = 4L * x + ((sample & 1) == 0 ? 1 : 3);
                    long qy = 4L * y + ((sample >> 1) == 0 ? 1 : 3);
                    int cr = br, cg = bg, cb = bb;
                    for (int s = 0; s < sheets.Length; s++)
                    {
                        long u = adj[s * 9 + 0] * qx + adj[s * 9 + 1] * qy + adj[s * 9 + 2] * 4;
                        long v = adj[s * 9 + 3] * qx + adj[s * 9 + 4] * qy + adj[s * 9 + 5] * 4;
                        long w = adj[s * 9 + 6] * qx + adj[s * 9 + 7] * qy + adj[s * 9 + 8] * 4;
                        if (w < 0)
                        {
                            u = -u;
                            v = -v;
                            w = -w;
                        }
                        var sheet = sheets[s];
                        if (w == 0 || u < 0 || v < 0 || u >= sheet.SheetWidth * w || v >= sheet.SheetHeight * w) continue;
                        int i = (int)((v / w) * sheet.SheetWidth + u / w) * 3;
                        cr = sheet.Rgb[i];
                        cg = sheet.Rgb[i + 1];
                        cb = sheet.Rgb[i + 2];
                    }
                    sr += cr;
                    sg += cg;
                    sb += cb;
                }
                int r = (sr + 2) / 4, g = (sg + 2) / 4, b = (sb + 2) / 4;
                int dim = 1000 - light.AcrossX * x / Width - light.DownY * y / Height;
                if (light.Shadow is { } sh)
                {
                    long dx = x - sh.Cx, dy = y - sh.Cy;
                    long rx2 = (long)sh.Rx * sh.Rx, ry2 = (long)sh.Ry * sh.Ry;
                    long t = (dx * dx * ry2 + dy * dy * rx2) * 1000 / (rx2 * ry2);
                    if (t <= 1000) dim -= sh.Depth;
                    else if (t < 2500) dim -= (int)(sh.Depth * (2500 - t) / 1500);
                }
                r = r * dim / 1000;
                g = g * dim / 1000;
                b = b * dim / 1000;
                if (light.Glare is { } gl)
                {
                    long dx = x - gl.Cx, dy = y - gl.Cy;
                    long t = (dx * dx + dy * dy) * 1000 / ((long)gl.R * gl.R);
                    if (t < 1000)
                    {
                        int k = (int)(gl.Strength * (1000 - t) / 1000);
                        r += (255 - r) * k / 1000;
                        g += (255 - g) * k / 1000;
                        b += (255 - b) * k / 1000;
                    }
                }
                int o = (y * Width + x) * 4;
                pixels[o] = TestPages.Clamp(r);
                pixels[o + 1] = TestPages.Clamp(g);
                pixels[o + 2] = TestPages.Clamp(b);
                pixels[o + 3] = 255;
            }
        }
        return new RgbaImage(Width, Height, pixels);
    }

    /// <summary>The backdrop's color at (x, y), clamped to 0...255; one noise draw.</summary>
    private static (int R, int G, int B) BackdropColor(Backdrop backdrop, int x, int y, TestPages.Rng rng)
    {
        int n = rng.Noise();
        int r, g, b;
        switch (backdrop)
        {
            case Backdrop.Wood:
            {
                // Grain bands warped across the frame, and the seams between planks every 150 px.
                int k = (x + 3 * y / 7) % 240;
                int tri = k < 120 ? 120 - k : k - 120;
                int phase = 2 * y + tri / 2;
                int band = phase / 9 % 7;
                int shade = band == 0 ? -26 : band == 1 ? -12 : band == 3 ? -6 : 0;
                if ((x + 75) % 150 < 2) shade -= 40;
                r = 150 + shade + 2 * n;
                g = 104 + shade * 3 / 4 + 2 * n;
                b = 64 + shade / 2 + 2 * n;
                break;
            }
            case Backdrop.Dark:
                r = 38 + 2 * n; g = 40 + 2 * n; b = 46 + 2 * n;
                break;
            case Backdrop.Light:
                r = 196 + n; g = 198 + n; b = 200 + n;
                break;
            case Backdrop.Similar:
                r = 228 + n; g = 222 + n; b = 210 + n;
                break;
            default:
                r = 128 + n; g = 128 + n; b = 128 + n;
                break;
        }
        return (TestPages.Clamp(r), TestPages.Clamp(g), TestPages.Clamp(b));
    }

    /// <summary>FNV-1a of the RGBA bytes: one number per photo, the same on both platforms.</summary>
    public static uint Checksum(RgbaImage image)
    {
        uint hash = 2166136261;
        foreach (byte b in image.Pixels)
        {
            hash ^= b;
            hash *= 16777619;
        }
        return hash;
    }
}
