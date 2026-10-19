using CompleteScanner.Core;

namespace CompleteScanner.Core.Tests;

// Twin of Tests/CompleteScannerTests/TestPages.swift: the same pages, byte for byte. Integer
// arithmetic only (no floating point, no trigonometry), and one xorshift32 generator consumed in
// the same order, so both platforms draw identical pixels.

/// <summary>
/// Synthetic US Letter pages at 100 dpi (850 × 1100 gray pixels) for the blank-page tests: blank
/// pages the way scanners deliver them (noise, dust, gradients, edge shadows, punched holes,
/// show-through) and pages with little on them (one text line, a signature, a page number, a
/// photo, text on tinted paper).
/// </summary>
internal static class TestPages
{
    public const int Width = 850;
    public const int Height = 1100;

    /// <summary>xorshift32 (13, 17, 5).</summary>
    public sealed class Rng(uint seed)
    {
        private uint _state = seed == 0 ? 1u : seed;

        public uint Next()
        {
            _state ^= _state << 13;
            _state ^= _state >> 17;
            _state ^= _state << 5;
            return _state;
        }

        /// <summary>0 ..< n.</summary>
        public int Below(int n) => (int)(Next() % (uint)n);

        /// <summary>Scanner noise: the sum of four uniform 0...6 values minus 12 (σ = 4 levels).</summary>
        public int Noise() => Below(7) + Below(7) + Below(7) + Below(7) - 12;
    }

    // MARK: - The pages

    /// <summary>(a) Clean blank paper.</summary>
    public static GrayImage CleanBlank() => GrayImage.Filled(Width, Height, 245);

    /// <summary>
    /// (b) Blank paper as a cheap scanner delivers it: noise, a top-to-bottom gradient from 92 %
    /// to 98 % white, 200 specks of dust of 1–2 pixels, a 0.15 in dark shadow along the left
    /// edge and three punched holes.
    /// </summary>
    public static GrayImage NoisyBlank()
    {
        var rng = new Rng(0xB1A2C3D4);
        var p = new byte[Width * Height];
        for (int y = 0; y < Height; y++)
        {
            int paper = 255 * (920 + 60 * y / (Height - 1)) / 1000;
            for (int x = 0; x < Width; x++) p[y * Width + x] = Clamp(paper + rng.Noise());
        }
        for (int n = 0; n < 200; n++)
        {
            int size = 1 + rng.Below(2);
            Fill(p, rng.Below(Width - 2), rng.Below(Height - 2), size, size, 60);
        }
        // Edge shadow: darkest at the edge, fading over 15 px.
        for (int y = 0; y < Height; y++)
        {
            for (int x = 0; x < 15; x++)
            {
                int i = y * Width + x;
                p[i] = (byte)Math.Min(p[i], 40 + x * 12);
            }
        }
        foreach (int cy in new[] { 200, 550, 900 }) Disc(p, 40, cy, 12, 30);
        return new GrayImage(Width, Height, p);
    }

    /// <summary>
    /// (c) Blank paper with the other side's text showing through: a page of text mirrored left
    /// to right, darkening the paper by 12 %, with noise.
    /// </summary>
    public static GrayImage ShowThrough()
    {
        var front = new byte[Width * Height];
        var textRng = new Rng(0x5EED0003);
        for (int line = 0; line < 30; line++) TextLine(front, 75, 110 + line * 28, 700, 1, textRng);
        var rng = new Rng(0x0C0FFEE3);
        var p = new byte[Width * Height];
        for (int y = 0; y < Height; y++)
        {
            for (int x = 0; x < Width; x++)
            {
                int paper = front[y * Width + (Width - 1 - x)] == 1 ? 245 * 88 / 100 : 245;
                p[y * Width + x] = Clamp(paper + rng.Noise());
            }
        }
        return new GrayImage(Width, Height, p);
    }

    /// <summary>(d) One line of text across the page, on noisy paper.</summary>
    public static GrayImage OneTextLine() =>
        Noisy(0xD0D0D0D4, 245, p => TextLine(p, 100, 400, 650, 50, new Rng(0x7E7E0004)));

    /// <summary>(e) A signature: a 3 px pen stroke zigzagging over about 3 inches, on noisy paper.</summary>
    public static GrayImage Signature() => Noisy(0xE5E5E5E5, 245, p =>
    {
        int[] xs = [450, 470, 490, 505, 520, 540, 560, 580, 610, 640, 670, 700, 730, 760];
        int[] ys = [880, 840, 900, 850, 905, 845, 895, 860, 890, 865, 885, 870, 880, 872];
        for (int k = 0; k + 1 < xs.Length; k++) Stroke(p, xs[k], ys[k], xs[k + 1], ys[k + 1], 3, 40);
    });

    /// <summary>(f) Nothing but a page number ("12") near the bottom, on noisy paper.</summary>
    public static GrayImage PageNumber() => Noisy(0xF0F0F0F6, 245, p =>
    {
        // "1": a stem and a foot.
        Fill(p, 415, 1000, 2, 12, 50);
        Fill(p, 413, 1011, 6, 1, 50);
        // "2": top, upper right, middle, lower left, bottom.
        Fill(p, 424, 1000, 7, 2, 50);
        Fill(p, 429, 1000, 2, 6, 50);
        Fill(p, 424, 1005, 7, 2, 50);
        Fill(p, 424, 1005, 2, 6, 50);
        Fill(p, 424, 1010, 7, 2, 50);
    });

    /// <summary>(g) A mid-gray 3 × 4 in photo with some texture, on noisy paper.</summary>
    public static GrayImage Photo()
    {
        var page = Noisy(0x9A9A9A97, 245, _ => { });
        var rng = new Rng(0x9707007);
        for (int y = 300; y < 700; y++)
        {
            for (int x = 275; x < 575; x++) page.Pixels[y * Width + x] = Clamp(128 + (x / 20 + y / 30) % 5 * 6 + rng.Noise() * 2);
        }
        return page;
    }

    /// <summary>(h) Recycled paper (85 % gray, flecked) with a short paragraph.</summary>
    public static GrayImage TintedWithText()
    {
        var page = Noisy(0x8181818A, 217, _ => { });
        var rng = new Rng(0xF1EC0008);
        for (int n = 0; n < 400; n++) Fill(page.Pixels, rng.Below(Width), rng.Below(Height), 1, 1, 170);
        var text = new Rng(0x7E7E0008);
        for (int line = 0; line < 5; line++) TextLine(page.Pixels, 100, 300 + line * 25, 640, 60, text);
        return page;
    }

    /// <summary>Every page with its letter, for reports.</summary>
    public static IReadOnlyList<(string Name, GrayImage Page)> All() =>
    [
        ("a clean blank", CleanBlank()),
        ("b noisy blank", NoisyBlank()),
        ("c show-through", ShowThrough()),
        ("d one text line", OneTextLine()),
        ("e signature", Signature()),
        ("f page number", PageNumber()),
        ("g photo", Photo()),
        ("h tinted with text", TintedWithText()),
    ];

    // MARK: - Drawing

    /// <summary>Paper of one value with noise, then <paramref name="draw"/> on top.</summary>
    public static GrayImage Noisy(uint seed, int paper, Action<byte[]> draw)
    {
        var rng = new Rng(seed);
        var p = new byte[Width * Height];
        for (int i = 0; i < p.Length; i++) p[i] = Clamp(paper + rng.Noise());
        draw(p);
        return new GrayImage(Width, Height, p);
    }

    /// <summary>
    /// A line of text-like glyphs from (x, y), up to <paramref name="maxWidth"/> wide: words of 2–8
    /// glyphs, each glyph 5 × 9 px in a 7 px cell made of three of five strokes (left, right, top,
    /// middle, bottom). <paramref name="ink"/> is the value written.
    /// </summary>
    public static void TextLine(byte[] p, int x, int y, int maxWidth, byte ink, Rng rng)
    {
        int cx = x;
        while (true)
        {
            int glyphs = 2 + rng.Below(7);
            if (cx + glyphs * 7 > x + maxWidth) break;
            for (int g = 0; g < glyphs; g++)
            {
                int strokes = rng.Below(10);
                // The ten ways to pick three of the five strokes.
                int[] picks = [0b00111, 0b01011, 0b01101, 0b01110, 0b10011, 0b10101, 0b10110, 0b11001, 0b11010, 0b11100];
                int bits = picks[strokes];
                if ((bits & 1) != 0) Fill(p, cx, y, 1, 9, ink);
                if ((bits & 2) != 0) Fill(p, cx + 4, y, 1, 9, ink);
                if ((bits & 4) != 0) Fill(p, cx, y, 5, 1, ink);
                if ((bits & 8) != 0) Fill(p, cx, y + 4, 5, 1, ink);
                if ((bits & 16) != 0) Fill(p, cx, y + 8, 5, 1, ink);
                cx += 7;
            }
            cx += 7;
        }
    }

    /// <summary>A straight pen stroke <paramref name="thickness"/> px wide from (x0, y0) to (x1, y1).</summary>
    public static void Stroke(byte[] p, int x0, int y0, int x1, int y1, int thickness, byte ink)
    {
        int dx = x1 - x0, dy = y1 - y0;
        int steps = Math.Max(Math.Abs(dx), Math.Abs(dy));
        for (int i = 0; i <= steps; i++)
        {
            int x = x0 + (steps == 0 ? 0 : dx * i / steps);
            int y = y0 + (steps == 0 ? 0 : dy * i / steps);
            Fill(p, x - thickness / 2, y - thickness / 2, thickness, thickness, ink);
        }
    }

    public static void Fill(byte[] p, int x, int y, int w, int h, byte value)
    {
        for (int py = Math.Max(0, y); py < Math.Min(Height, y + h); py++)
        {
            for (int px = Math.Max(0, x); px < Math.Min(Width, x + w); px++) p[py * Width + px] = value;
        }
    }

    public static void Disc(byte[] p, int cx, int cy, int r, byte value)
    {
        for (int y = cy - r; y <= cy + r; y++)
        {
            for (int x = cx - r; x <= cx + r; x++)
            {
                if (x < 0 || y < 0 || x >= Width || y >= Height) continue;
                if ((x - cx) * (x - cx) + (y - cy) * (y - cy) <= r * r) p[y * Width + x] = value;
            }
        }
    }

    public static byte Clamp(int value) => (byte)Math.Clamp(value, 0, 255);

    /// <summary>A gray page as an RGBA scan at <paramref name="factor"/> times the resolution (each pixel repeated).</summary>
    public static RgbaImage Enlarged(GrayImage page, int factor)
    {
        int w = page.Width * factor, h = page.Height * factor;
        var rgba = new byte[w * h * 4];
        for (int y = 0; y < h; y++)
        {
            for (int x = 0; x < w; x++)
            {
                byte v = page.Pixels[(y / factor) * page.Width + x / factor];
                int i = (y * w + x) * 4;
                rgba[i] = v;
                rgba[i + 1] = v;
                rgba[i + 2] = v;
                rgba[i + 3] = 255;
            }
        }
        return new RgbaImage(w, h, rgba);
    }

    /// <summary>FNV-1a of the pixels: one number per page, the same on both platforms.</summary>
    public static uint Checksum(GrayImage page)
    {
        uint hash = 2166136261;
        foreach (byte b in page.Pixels)
        {
            hash ^= b;
            hash *= 16777619;
        }
        return hash;
    }
}
