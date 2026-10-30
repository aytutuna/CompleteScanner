using LazyScan.Core;

namespace LazyScan.Core.Tests;

// Twin of Tests/CompleteScannerTests/CameraFixtures.swift: the same pixels, checked by FNV-1a
// (PhotoScenes.Checksum). Drawn here with integers only, no real document.

/// <summary>
/// Pages a camera took, after the warp: a sheet of warm paper with lines of print, a red stamp and, if
/// asked, a large dark picture, under a shadow that darkens it from full light at the top left to about
/// 37 % at the bottom right (255 − 130·x/(W − 1) − 30·y/(H − 1), integer divisions).
/// </summary>
public static class EnhancerPages
{
    public static readonly (int R, int G, int B) Paper = (232, 226, 212);
    public static readonly (int R, int G, int B) Ink = (40, 38, 44);
    public static readonly (int R, int G, int B) Stamp = (196, 48, 44);
    public static readonly (int R, int G, int B) Dark = (70, 74, 80);

    public static bool IsInk(int x, int y, int width, int height) =>
        x >= 24 && x < width - 24 && y >= 70 && y < height - 30 && (y - 70) % 12 < 3 && (x - 24) / 18 % 5 != 4;

    public static bool IsStamp(int x, int y) => x >= 150 && x < 200 && y >= 24 && y < 52;

    public static bool IsPicture(int x, int y) => x >= 40 && x < 140 && y >= 200 && y < 290;

    /// <summary>The light at (x, y), out of 255.</summary>
    public static int Light(int x, int y, int width, int height) => 255 - 130 * x / (width - 1) - 30 * y / (height - 1);

    /// <summary>What the pixel at (x, y) shows: 0 paper, 1 print, 2 the stamp, 3 the picture.</summary>
    public static int Kind(int x, int y, int width, int height, bool stamp, bool picture)
    {
        int kind = 0;
        if (IsInk(x, y, width, height)) kind = 1;
        if (stamp && IsStamp(x, y)) kind = 2;
        if (picture && IsPicture(x, y)) kind = 3;
        return kind;
    }

    public static RgbaImage Shadowed(int width = 240, int height = 320, bool stamp = true, bool picture = false)
    {
        var pixels = new byte[width * height * 4];
        for (int y = 0; y < height; y++)
        {
            for (int x = 0; x < width; x++)
            {
                var c = Kind(x, y, width, height, stamp, picture) switch
                {
                    1 => Ink,
                    2 => Stamp,
                    3 => Dark,
                    _ => Paper,
                };
                int s = Light(x, y, width, height);
                int o = (y * width + x) * 4;
                pixels[o] = (byte)((c.R * s + 127) / 255);
                pixels[o + 1] = (byte)((c.G * s + 127) / 255);
                pixels[o + 2] = (byte)((c.B * s + 127) / 255);
                pixels[o + 3] = 255;
            }
        }
        return new RgbaImage(width, height, pixels);
    }

    /// <summary>Where the light print of <see cref="DarkGround"/> is: 1 px lines every 12 px, words of 18 px with every fifth left out.</summary>
    public static bool IsLightPrint(int x, int y, int width, int height) =>
        x >= 24 && x < width - 24 && y >= 70 && y < height - 30 && (y - 70) % 12 < 1 && (x - 24) / 18 % 5 != 4;

    /// <summary>A page with no paper to whiten: a dark ground (luma 55) with sparse light print (235) on it, as a chalkboard or a dark flyer.</summary>
    public static RgbaImage DarkGround(int width = 240, int height = 320)
    {
        var pixels = new byte[width * height * 4];
        for (int y = 0; y < height; y++)
        {
            for (int x = 0; x < width; x++)
            {
                byte v = IsLightPrint(x, y, width, height) ? (byte)235 : (byte)55;
                int o = (y * width + x) * 4;
                pixels[o] = v;
                pixels[o + 1] = v;
                pixels[o + 2] = v;
                pixels[o + 3] = 255;
            }
        }
        return new RgbaImage(width, height, pixels);
    }

    /// <summary>Where the hard shadow of <see cref="HardShadow"/> starts: everything right of it is in shadow (mid-tile, not on a tile's edge).</summary>
    public const int ShadowEdge = 130;
    /// <summary>The light in the hard shadow, out of 255 (45 %).</summary>
    public const int ShadowLight = 115;

    /// <summary>How much print <see cref="HardShadow"/> has.</summary>
    public enum ShadowPrint
    {
        /// <summary>The lines of <see cref="IsInk"/>.</summary>
        Lines,
        /// <summary>Five 2 px lines (<see cref="IsFewLines"/>): a short note.</summary>
        FewLines,
        /// <summary>None: a blank sheet.</summary>
        Blank,
    }

    /// <summary>Where the print of a short note is: 2 px lines every 12 px from y = 70 to 130, words as <see cref="IsInk"/>.</summary>
    public static bool IsFewLines(int x, int y, int width, int height) =>
        x >= 24 && x < width - 24 && y >= 70 && y < 130 && (y - 70) % 12 < 2 && (x - 24) / 18 % 5 != 4;

    /// <summary>Whether (x, y) is print on a <see cref="HardShadow"/> page with <paramref name="print"/>.</summary>
    public static bool IsPrint(int x, int y, int width, int height, ShadowPrint print) => print switch
    {
        ShadowPrint.Lines => IsInk(x, y, width, height),
        ShadowPrint.FewLines => IsFewLines(x, y, width, height),
        _ => false,
    };

    /// <summary>
    /// The warm paper with <paramref name="print"/> in full light, under a hard-edged shadow (a phone or a
    /// hand under one lamp) from <paramref name="edge"/> (<see cref="ShadowEdge"/>) to the right edge at
    /// <see cref="ShadowLight"/>.
    /// </summary>
    public static RgbaImage HardShadow(int width = 240, int height = 320, ShadowPrint print = ShadowPrint.Lines, int edge = ShadowEdge)
    {
        var pixels = new byte[width * height * 4];
        for (int y = 0; y < height; y++)
        {
            for (int x = 0; x < width; x++)
            {
                var c = IsPrint(x, y, width, height, print) ? Ink : Paper;
                int s = x < edge ? 255 : ShadowLight;
                int o = (y * width + x) * 4;
                pixels[o] = (byte)((c.R * s + 127) / 255);
                pixels[o + 1] = (byte)((c.G * s + 127) / 255);
                pixels[o + 2] = (byte)((c.B * s + 127) / 255);
                pixels[o + 3] = 255;
            }
        }
        return new RgbaImage(width, height, pixels);
    }

    /// <summary>Where the picture of <see cref="PictureWithCaption"/> is (mid-tile on every side).</summary>
    public static bool IsBigPicture(int x, int y) => x >= 30 && x < 210 && y >= 50 && y < 230;

    /// <summary>Where the caption of <see cref="PictureWithCaption"/> is: two 2 px lines under the picture.</summary>
    public static bool IsCaption(int x, int y) =>
        x >= 40 && x < 200 && y >= 262 && y < 290 && (y - 262) % 12 < 2 && (x - 40) / 18 % 5 != 4;

    /// <summary>
    /// A 240 × 320 page in full light that is mostly a dark picture (<see cref="Dark"/>, <see cref="IsBigPicture"/>)
    /// with a short caption under it (<see cref="Ink"/>, <see cref="IsCaption"/>) on the warm paper.
    /// </summary>
    public static RgbaImage PictureWithCaption(int width = 240, int height = 320)
    {
        var pixels = new byte[width * height * 4];
        for (int y = 0; y < height; y++)
        {
            for (int x = 0; x < width; x++)
            {
                var c = IsBigPicture(x, y) ? Dark : IsCaption(x, y) ? Ink : Paper;
                int o = (y * width + x) * 4;
                pixels[o] = (byte)c.R;
                pixels[o + 1] = (byte)c.G;
                pixels[o + 2] = (byte)c.B;
                pixels[o + 3] = 255;
            }
        }
        return new RgbaImage(width, height, pixels);
    }

    /// <summary>Where <see cref="OnATable"/> lays the sheet in its photo.</summary>
    public static readonly Quad TableQuad = new(new PointD(100, 60), new PointD(340, 60), new PointD(340, 380), new PointD(100, 380));

    /// <summary>A 240 × 320 <paramref name="sheet"/> laid on a dark table (30, 32, 36) at <see cref="TableQuad"/>, in a 440 × 440 photo.</summary>
    public static RgbaImage OnATable(RgbaImage sheet)
    {
        var pixels = new byte[440 * 440 * 4];
        for (int y = 0; y < 440; y++)
        {
            for (int x = 0; x < 440; x++)
            {
                int o = (y * 440 + x) * 4;
                bool onSheet = x >= 100 && x < 340 && y >= 60 && y < 380;
                int s = onSheet ? ((y - 60) * 240 + (x - 100)) * 4 : -1;
                pixels[o] = onSheet ? sheet.Pixels[s] : (byte)30;
                pixels[o + 1] = onSheet ? sheet.Pixels[s + 1] : (byte)32;
                pixels[o + 2] = onSheet ? sheet.Pixels[s + 2] : (byte)36;
                pixels[o + 3] = 255;
            }
        }
        return new RgbaImage(440, 440, pixels);
    }
}

/// <summary>
/// Live frames as the page search reads them, 320 × 240: a wooden table and a sheet from (80, 40) to
/// (240, 200), with fine lines of print if asked (2 px lines every 4 px, words of 7 px every 10 px);
/// blurred by a box of (2·blur + 1)² pixels (kept within the frame, rounded half up) and darkened to
/// dim/255 (rounded), if asked.
/// </summary>
public static class QualityFrames
{
    public const int Width = 320, Height = 240;

    public static readonly Quad Sheet = new(new PointD(80, 40), new PointD(240, 40), new PointD(240, 200), new PointD(80, 200));

    public static RgbaImage Frame(bool printed = true, int blur = 0, int dim = 255)
    {
        var r = new int[Width * Height];
        var g = new int[Width * Height];
        var b = new int[Width * Height];
        for (int y = 0; y < Height; y++)
        {
            for (int x = 0; x < Width; x++)
            {
                (int R, int G, int B) c = (88, 80, 72);
                if (x >= 80 && x < 240 && y >= 40 && y < 200)
                {
                    bool print = printed && x >= 96 && x < 224 && y >= 56 && y < 184 && (y - 56) % 4 < 2 && (x - 96) % 10 < 7;
                    c = print ? (95, 92, 100) : (205, 200, 192);
                }
                int i = y * Width + x;
                r[i] = c.R;
                g[i] = c.G;
                b[i] = c.B;
            }
        }
        var pixels = new byte[Width * Height * 4];
        for (int y = 0; y < Height; y++)
        {
            for (int x = 0; x < Width; x++)
            {
                int sr = 0, sg = 0, sb = 0, n = 0;
                for (int yy = Math.Max(0, y - blur); yy < Math.Min(Height, y + blur + 1); yy++)
                {
                    for (int xx = Math.Max(0, x - blur); xx < Math.Min(Width, x + blur + 1); xx++)
                    {
                        int i = yy * Width + xx;
                        sr += r[i];
                        sg += g[i];
                        sb += b[i];
                        n++;
                    }
                }
                int o = (y * Width + x) * 4;
                pixels[o] = (byte)(((sr + n / 2) / n * dim + 127) / 255);
                pixels[o + 1] = (byte)(((sg + n / 2) / n * dim + 127) / 255);
                pixels[o + 2] = (byte)(((sb + n / 2) / n * dim + 127) / 255);
                pixels[o + 3] = 255;
            }
        }
        return new RgbaImage(Width, Height, pixels);
    }
}
