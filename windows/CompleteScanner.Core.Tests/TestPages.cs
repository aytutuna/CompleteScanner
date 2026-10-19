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

    // MARK: - Pages for crop and straighten

    /// <summary>
    /// A turn by a small angle as exact fixed-point sine and cosine (× 65536), so both platforms draw
    /// the same pixels without trigonometry.
    /// </summary>
    public readonly record struct Turn(int Sin, int Cos)
    {
        /// <summary>The angle drawn, clockwise on screen positive.</summary>
        public double Degrees => Math.Atan2(Sin, Cos) * 180 / Math.PI;
    }

    public static readonly Turn Straight = new(0, 65536);
    public static readonly Turn Plus0Point1 = new(114, 65536);
    public static readonly Turn Minus1Point5 = new(-1716, 65514);
    public static readonly Turn Plus2 = new(2287, 65496);
    public static readonly Turn Plus3 = new(3430, 65446);
    public static readonly Turn Minus4 = new(-4572, 65376);
    public static readonly Turn Plus6Point5 = new(7419, 65115);

    /// <summary>The sheet of <see cref="SheetOnBackdrop"/>: 6 × 8 in.</summary>
    public const int SheetWidth = 600;
    public const int SheetHeight = 800;

    /// <summary>A page of text: 34 lines of glyphs (<see cref="TextLine"/>) 6.5 in long, every 0.28 in, on noisy paper.</summary>
    public static GrayImage TextPage() => Noisy(0x7E57AA6E, 245, p =>
    {
        var rng = new Rng(0x7E57AA6F);
        for (int line = 0; line < 34; line++) TextLine(p, 100, 100 + line * 28, 650, 40, rng);
    });

    /// <summary>
    /// <paramref name="page"/> with its content turned clockwise by <paramref name="turn"/> about the
    /// center (nearest pixel); what comes in from outside the page is <paramref name="fill"/>.
    /// </summary>
    public static GrayImage Turned(GrayImage page, Turn turn, byte fill)
    {
        int w = page.Width, h = page.Height;
        var p = new byte[w * h];
        for (int y = 0; y < h; y++)
        {
            long dy = 2L * y + 1 - h;
            for (int x = 0; x < w; x++)
            {
                long dx = 2L * x + 1 - w;
                // The pixel's offset from the center (doubled) turned back, in 1/65536 units.
                long sx = FloorDiv(dx * turn.Cos + dy * turn.Sin + (long)w * 65536, 2L * 65536);
                long sy = FloorDiv(-dx * turn.Sin + dy * turn.Cos + (long)h * 65536, 2L * 65536);
                p[y * w + x] = sx >= 0 && sx < w && sy >= 0 && sy < h ? page.Pixels[sy * w + sx] : fill;
            }
        }
        return new GrayImage(w, h, p);
    }

    /// <summary>
    /// A 6 × 8 in sheet (<see cref="SheetWidth"/> × <see cref="SheetHeight"/>: <paramref name="paper"/>
    /// with noise and 24 lines of glyphs) lying at the center of the 850 × 1100 scan on a noisy
    /// <paramref name="backdrop"/>, turned clockwise by <paramref name="turn"/>, with a
    /// <paramref name="shadow"/> px edge shadow (200) all around it when above 0.
    /// </summary>
    public static GrayImage SheetOnBackdrop(Turn turn, int backdrop, int paper, int shadow, uint seed)
    {
        const int sw = SheetWidth, sh = SheetHeight;
        var sheet = new byte[sw * sh];
        var rng = new Rng(seed);
        for (int i = 0; i < sheet.Length; i++) sheet[i] = Clamp(paper + rng.Noise());
        var text = new Rng(seed ^ 0x5A5A5A5A);
        for (int line = 0; line < 24; line++) SheetTextLine(sheet, 60, 60 + line * 28, 480, 40, text);

        var p = new byte[Width * Height];
        var noise = new Rng(seed + 1);
        long halfW = (long)sw * 65536, halfH = (long)sh * 65536;
        long outerW = (long)(sw + 2 * shadow) * 65536, outerH = (long)(sh + 2 * shadow) * 65536;
        for (int y = 0; y < Height; y++)
        {
            long dy = 2L * y + 1 - Height;
            for (int x = 0; x < Width; x++)
            {
                long dx = 2L * x + 1 - Width;
                // The pixel in the sheet's frame (doubled, in 1/65536 units).
                long u = dx * turn.Cos + dy * turn.Sin;
                long v = -dx * turn.Sin + dy * turn.Cos;
                int value;
                if (Math.Abs(u) < halfW && Math.Abs(v) < halfH)
                {
                    long sx = FloorDiv(u + halfW, 2L * 65536), sy = FloorDiv(v + halfH, 2L * 65536);
                    value = sheet[sy * sw + sx];
                }
                else if (shadow > 0 && Math.Abs(u) < outerW && Math.Abs(v) < outerH)
                {
                    value = 200 + noise.Noise();
                }
                else
                {
                    value = backdrop + noise.Noise();
                }
                p[y * Width + x] = Clamp(value);
            }
        }
        return new GrayImage(Width, Height, p);
    }

    /// <summary><see cref="TextLine"/> on the sheet of <see cref="SheetOnBackdrop"/>.</summary>
    private static void SheetTextLine(byte[] p, int x, int y, int maxWidth, byte ink, Rng rng)
    {
        int[] picks = [0b00111, 0b01011, 0b01101, 0b01110, 0b10011, 0b10101, 0b10110, 0b11001, 0b11010, 0b11100];
        void Bar(int bx, int by, int bw, int bh)
        {
            for (int py = by; py < by + bh; py++)
            {
                for (int px = bx; px < bx + bw; px++) p[py * SheetWidth + px] = ink;
            }
        }
        int cx = x;
        while (true)
        {
            int glyphs = 2 + rng.Below(7);
            if (cx + glyphs * 7 > x + maxWidth) break;
            for (int g = 0; g < glyphs; g++)
            {
                int bits = picks[rng.Below(10)];
                if ((bits & 1) != 0) Bar(cx, y, 1, 9);
                if ((bits & 2) != 0) Bar(cx + 4, y, 1, 9);
                if ((bits & 4) != 0) Bar(cx, y, 5, 1);
                if ((bits & 8) != 0) Bar(cx, y + 4, 5, 1);
                if ((bits & 16) != 0) Bar(cx, y + 8, 5, 1);
                cx += 7;
            }
            cx += 7;
        }
    }

    // MARK: - Receipts

    public static readonly Turn Minus3 = new(-3430, 65446);

    /// <summary>The glass of the receipt beds: 8.5 × 11.7 in at 100 dpi.</summary>
    public const int BedWidth = 850;
    public const int BedHeight = 1170;

    /// <summary>A receipt's own pixels, before it is laid on a bed.</summary>
    public sealed record ReceiptSheet(byte[] Pixels, int Width, int Height);

    /// <summary>
    /// A receipt <paramref name="width"/> × <paramref name="height"/> px: <paramref name="paper"/> with
    /// noise and <paramref name="lines"/> lines of print (<paramref name="ink"/>) every 18 px from 0.3 in
    /// down, 0.2 in from the sides: items from the left (2–4 words) and, on every other line, a price
    /// of 4 glyphs against the right margin, <paramref name="priceGap"/> px or more after the items.
    /// </summary>
    public static ReceiptSheet Receipt(int width, int height, int paper, byte ink, int lines, uint seed, int priceGap = 0)
    {
        var p = new byte[width * height];
        var rng = new Rng(seed);
        for (int i = 0; i < p.Length; i++) p[i] = Clamp(paper + rng.Noise());
        var text = new Rng(seed ^ 0x3EC3E1F7);
        int priceX = width - 20 - 4 * 7;
        int itemsEnd = priceGap > 0 ? priceX - priceGap : width - 20;
        for (int line = 0; line < lines; line++)
        {
            int y = 30 + line * 18;
            if (y + 9 > height) break;
            int x = 20;
            int words = 2 + text.Below(3);
            for (int word = 0; word < words; word++)
            {
                int glyphs = 2 + text.Below(5);
                if (x + glyphs * 7 > itemsEnd) break;
                x = Glyphs(p, width, x, y, glyphs, ink, text) + 7;
            }
            if (line % 2 == 1) Glyphs(p, width, priceX, y, 4, ink, text);
        }
        return new ReceiptSheet(p, width, height);
    }

    /// <summary>
    /// <paramref name="glyphs"/> glyphs (as <see cref="TextLine"/> draws them) from (x, y) on a sheet
    /// <paramref name="pitch"/> px wide; returns the x after the last.
    /// </summary>
    private static int Glyphs(byte[] p, int pitch, int x, int y, int glyphs, byte ink, Rng rng)
    {
        int[] picks = [0b00111, 0b01011, 0b01101, 0b01110, 0b10011, 0b10101, 0b10110, 0b11001, 0b11010, 0b11100];
        void Bar(int bx, int by, int bw, int bh)
        {
            for (int py = by; py < by + bh; py++)
            {
                for (int px = bx; px < bx + bw; px++) p[py * pitch + px] = ink;
            }
        }
        for (int g = 0; g < glyphs; g++)
        {
            int bits = picks[rng.Below(10)];
            if ((bits & 1) != 0) Bar(x, y, 1, 9);
            if ((bits & 2) != 0) Bar(x + 4, y, 1, 9);
            if ((bits & 4) != 0) Bar(x, y, 5, 1);
            if ((bits & 8) != 0) Bar(x, y + 4, 5, 1);
            if ((bits & 16) != 0) Bar(x, y + 8, 5, 1);
            x += 7;
        }
        return x;
    }

    /// <summary>A receipt laid on the bed: its center (in pixels) and its turn, clockwise on screen.</summary>
    public sealed record Placed(ReceiptSheet Sheet, int CenterX, int CenterY, Turn Turn);

    /// <summary>
    /// The 850 × 1170 glass (<paramref name="backdrop"/> with noise) with the receipts laid on it,
    /// each turned about its center (nearest pixel).
    /// </summary>
    public static GrayImage ReceiptBed(int backdrop, uint seed, params Placed[] receipts)
    {
        var p = new byte[BedWidth * BedHeight];
        var noise = new Rng(seed);
        for (int y = 0; y < BedHeight; y++)
        {
            for (int x = 0; x < BedWidth; x++)
            {
                int value = backdrop + noise.Noise();
                foreach (var r in receipts)
                {
                    if (SheetPixel(r, x, y) is { } v) value = v;
                }
                p[y * BedWidth + x] = Clamp(value);
            }
        }
        return new GrayImage(BedWidth, BedHeight, p);
    }

    /// <summary>The receipt's pixel at bed pixel (x, y), or null when the receipt does not cover it.</summary>
    private static int? SheetPixel(Placed r, int x, int y)
    {
        int sw = r.Sheet.Width, sh = r.Sheet.Height;
        long dx = 2L * (x - r.CenterX) + 1, dy = 2L * (y - r.CenterY) + 1;
        long u = dx * r.Turn.Cos + dy * r.Turn.Sin;
        long v = -dx * r.Turn.Sin + dy * r.Turn.Cos;
        long halfW = (long)sw * 65536, halfH = (long)sh * 65536;
        if (Math.Abs(u) >= halfW || Math.Abs(v) >= halfH) return null;
        long sx = FloorDiv(u + halfW, 2L * 65536), sy = FloorDiv(v + halfH, 2L * 65536);
        return r.Sheet.Pixels[sy * sw + sx];
    }

    /// <summary>The bed pixels where the receipt's print (pixels at or below <paramref name="ink"/>) lands.</summary>
    public static List<PointD> PrintOnBed(Placed r, byte ink)
    {
        var points = new List<PointD>();
        for (int y = 0; y < BedHeight; y++)
        {
            for (int x = 0; x < BedWidth; x++)
            {
                if (SheetPixel(r, x, y) is { } v && v <= ink) points.Add(new PointD(x + 0.5, y + 0.5));
            }
        }
        return points;
    }

    /// <summary>Division rounding down (toward minus infinity), for negative offsets too.</summary>
    public static long FloorDiv(long a, long b) => a >= 0 ? a / b : -((-a + b - 1) / b);

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
