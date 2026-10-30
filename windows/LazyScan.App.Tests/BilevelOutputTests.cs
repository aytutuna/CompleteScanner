using System.Buffers.Binary;
using System.IO;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using LazyScan.App.Services;
using LazyScan.Core;
using Xunit;

namespace LazyScan.App.Tests;

// Black & white output read back by Windows' own decoders: WIC decodes the G4 TIFFs (and, as a
// separate encoder, gives the same G4 bytes for the same rows) and Windows.Data.Pdf renders the G4
// PDF pages. Windows only: the Mac's twin of the encoder comes with its port of the PDF writer and
// is to be checked with ImageIO there (see CONTRACTS.md, "CCITT G4 for black & white pages").
public class BilevelOutputTests : IDisposable
{
    private readonly string _folder = Directory.CreateTempSubdirectory("LazyScan-bilevel-tests-").FullName;

    public void Dispose()
    {
        try { Directory.Delete(_folder, recursive: true); }
        catch (IOException) { }
    }

    // MARK: - Pages

    /// <summary>xorshift32 (13, 17, 5), as the Core tests' TestPages.Rng.</summary>
    private sealed class Rng(uint seed)
    {
        private uint _state = seed == 0 ? 1u : seed;

        public int Below(int n)
        {
            _state ^= _state << 13;
            _state ^= _state >> 17;
            _state ^= _state << 5;
            return (int)(_state % (uint)n);
        }
    }

    private static byte[] Packed(int width, int height, Func<int, int, bool> black)
    {
        int stride = Bilevel.Stride(width);
        var packed = new byte[stride * height];
        packed.AsSpan().Fill(0xFF);
        for (int y = 0; y < height; y++)
        {
            for (int x = 0; x < width; x++)
            {
                if (black(x, y)) packed[y * stride + (x >> 3)] &= (byte)~(0x80 >> (x & 7));
            }
        }
        return packed;
    }

    private static RgbaImage Image(int width, int height, Func<int, int, bool> black) =>
        Bilevel.Unpack(Packed(width, height, black), width, height);

    /// <summary>
    /// A page of 8.4 × 10.8 in at 100 dpi (840 × 1080, both multiples of 60 so that rendering at
    /// 100 %, 125 %, 150 % or 200 % display scale can map its pixels one to one) with 34 lines of
    /// word-like blocks, letters 1–3 px apart.
    /// </summary>
    private static RgbaImage TextPage()
    {
        var rng = new Rng(0x7E57AA6E);
        var ink = new bool[840 * 1080];
        for (int line = 0; line < 34; line++)
        {
            int y0 = 100 + line * 28, x = 100;
            while (x < 750)
            {
                int word = 3 + rng.Below(8);
                for (int letter = 0; letter < word && x < 750; letter++)
                {
                    int w = 3 + rng.Below(5), h = 9 + rng.Below(6);
                    for (int dy = 0; dy < h; dy++)
                    {
                        for (int dx = 0; dx < w; dx++)
                        {
                            if (rng.Below(5) != 0) ink[(y0 + 14 - h + dy) * 840 + x + dx] = true;
                        }
                    }
                    x += w + 1 + rng.Below(3);
                }
                x += 6 + rng.Below(4);
            }
        }
        return Image(840, 1080, (x, y) => ink[y * 840 + x]);
    }

    public static TheoryData<string> Pages() => ["text", "noise", "all white", "all black", "1 × 1", "1729 × 5", "20000 × 3", "1 × 40"];

    private static RgbaImage PageNamed(string name) => name switch
    {
        "text" => TextPage(),
        "noise" => NoiseImage(517, 211, 0xC0FFEE01),
        "all white" => RgbaImage.Filled(1728, 10, 255, 255, 255),
        "all black" => RgbaImage.Filled(1728, 10, 0, 0, 0),
        "1 × 1" => Image(1, 1, (_, _) => true),
        "1729 × 5" => Image(1729, 5, (x, y) => (x * 7 + y * 3) % 11 < 4 || x == 1728),
        "20000 × 3" => Image(20000, 3, (x, y) => y == 1 ? x >= 2 && x < 17000 : x % 2629 == 0),
        _ => Image(1, 40, (_, y) => y % 3 == 0),
    };

    private static RgbaImage NoiseImage(int width, int height, uint seed)
    {
        var rng = new Rng(seed);
        var black = new bool[width * height];
        for (int i = 0; i < black.Length; i++) black[i] = rng.Below(2) == 0;
        return Image(width, height, (x, y) => black[y * width + x]);
    }

    // MARK: - Decoding

    private static RgbaImage FromBitmap(BitmapSource source) => WpfImageCodec.FromBitmapSource(source);

    /// <summary>How many pixels are black in one image and white in the other (luma below 128 is black).</summary>
    private static int Differing(RgbaImage expected, RgbaImage actual)
    {
        Assert.Equal((expected.Width, expected.Height), (actual.Width, actual.Height));
        byte[] a = Bilevel.Pack(expected), b = Bilevel.Pack(actual);
        int differing = 0;
        for (int y = 0; y < expected.Height; y++)
        {
            for (int x = 0; x < expected.Width; x++)
            {
                if (Bilevel.IsBlack(a, expected.Width, x, y) != Bilevel.IsBlack(b, expected.Width, x, y)) differing++;
            }
        }
        return differing;
    }

    private static void AssertSamePixels(RgbaImage expected, RgbaImage actual, string what)
    {
        int differing = Differing(expected, actual);
        Assert.True(differing == 0, $"{what}: {differing} pixels differ");
    }

    private static BitmapDecoder Decode(byte[] data) =>
        BitmapDecoder.Create(new MemoryStream(data), BitmapCreateOptions.PreservePixelFormat, BitmapCacheOption.OnLoad);

    /// <summary>The first directory's value of <paramref name="tag"/> (a short or a long held in the entry).</summary>
    private static uint TiffTag(byte[] tiff, int tag)
    {
        Assert.Equal("II*\0"u8.ToArray(), tiff[..4]);
        int ifd = (int)BinaryPrimitives.ReadUInt32LittleEndian(tiff.AsSpan(4));
        int count = BinaryPrimitives.ReadUInt16LittleEndian(tiff.AsSpan(ifd));
        for (int e = 0; e < count; e++)
        {
            var entry = tiff.AsSpan(ifd + 2 + e * 12, 12);
            if (BinaryPrimitives.ReadUInt16LittleEndian(entry) != tag) continue;
            int type = BinaryPrimitives.ReadUInt16LittleEndian(entry[2..]);
            return type == 3 ? BinaryPrimitives.ReadUInt16LittleEndian(entry[8..]) : BinaryPrimitives.ReadUInt32LittleEndian(entry[8..]);
        }
        throw new KeyNotFoundException($"tag {tag}");
    }

    // MARK: - TIFF through WIC

    [Theory]
    [MemberData(nameof(Pages))]
    public void Wic_DecodesOurG4Tiff_PixelExact(string name)
    {
        var image = PageNamed(name);
        var decoder = Decode(BilevelTiff.Make(image, 300));
        var frame = Assert.Single(decoder.Frames);
        Assert.Equal(PixelFormats.BlackWhite, frame.Format);
        Assert.Equal(300, frame.DpiX, 3);
        Assert.Equal(300, frame.DpiY, 3);
        AssertSamePixels(image, FromBitmap(frame), name);
    }

    [Fact]
    public void Wic_DecodesAMultiPageG4Tiff()
    {
        var pages = new[] { (TextPage(), 100), (NoiseImage(301, 97, 7), 300), (RgbaImage.Filled(9, 2, 0, 0, 0), 600) };
        var decoder = Decode(BilevelTiff.Make(pages.Select(p => new BilevelTiffPage(p.Item1, p.Item2)).ToList()));
        Assert.Equal(3, decoder.Frames.Count);
        for (int i = 0; i < 3; i++)
        {
            Assert.Equal(pages[i].Item2, decoder.Frames[i].DpiX, 3);
            AssertSamePixels(pages[i].Item1, FromBitmap(decoder.Frames[i]), $"page {i + 1}");
        }
    }

    /// <summary>WIC's own G4 encoding of the rows: each strip it writes, with its first row.</summary>
    private static List<(int FirstRow, int Rows, byte[] Data)> WicStrips(byte[] packed, int width, int height)
    {
        var bitmap = BitmapSource.Create(width, height, 300, 300, PixelFormats.BlackWhite, null, packed, Bilevel.Stride(width));
        var encoder = new TiffBitmapEncoder { Compression = TiffCompressOption.Ccitt4 };
        encoder.Frames.Add(BitmapFrame.Create(bitmap));
        using var stream = new MemoryStream();
        encoder.Save(stream);
        byte[] tiff = stream.ToArray();
        Assert.Equal(4u, TiffTag(tiff, 259));
        int rowsPerStrip = (int)TiffTag(tiff, 278);
        int strips = (height + rowsPerStrip - 1) / rowsPerStrip;
        uint offsets = TiffTag(tiff, 273), counts = TiffTag(tiff, 279);
        var result = new List<(int, int, byte[])>();
        for (int s = 0; s < strips; s++)
        {
            int offset = (int)(strips == 1 ? offsets : BinaryPrimitives.ReadUInt32LittleEndian(tiff.AsSpan((int)offsets + s * 4)));
            int count = (int)(strips == 1 ? counts : BinaryPrimitives.ReadUInt32LittleEndian(tiff.AsSpan((int)counts + s * 4)));
            result.Add((s * rowsPerStrip, Math.Min(rowsPerStrip, height - s * rowsPerStrip), tiff.AsSpan(offset, count).ToArray()));
        }
        return result;
    }

    [Theory]
    [MemberData(nameof(Pages))]
    public void OurG4_EqualsWicsEncoder_StripByStrip(string name)
    {
        var image = PageNamed(name);
        byte[] packed = Bilevel.Pack(image);
        int stride = Bilevel.Stride(image.Width);
        var strips = WicStrips(packed, image.Width, image.Height);
        Assert.Equal(image.Height, strips.Sum(s => s.Rows));
        foreach (var (first, rows, data) in strips)
        {
            byte[] ours = CcittG4Encoder.Encode(packed.AsSpan(first * stride, rows * stride), image.Width, rows);
            Assert.True(ours.AsSpan().SequenceEqual(data), $"{name}: rows {first}–{first + rows - 1} ({ours.Length} vs {data.Length} bytes)");
        }
    }

    [Fact]
    public void OurG4_EqualsWicsEncoder_ForEveryRunLength()
    {
        // As CcittG4EncoderTests.RoundTrip_EveryRunLengthOfBothColors: white L then black, and
        // black L then white, between white rows, for L = 1 ... 2700.
        const int width = 2710, height = 2700 * 4;
        byte[] packed = Packed(width, height, (x, y) => (y % 4) switch
        {
            1 => x >= y / 4 + 1,
            3 => x < y / 4 + 1,
            _ => false,
        });
        int stride = Bilevel.Stride(width);
        foreach (var (first, rows, data) in WicStrips(packed, width, height))
        {
            byte[] ours = CcittG4Encoder.Encode(packed.AsSpan(first * stride, rows * stride), width, rows);
            Assert.True(ours.AsSpan().SequenceEqual(data), $"rows {first}–{first + rows - 1}");
        }
    }

    // MARK: - The app's TIFF files

    [Fact]
    public void SaveAsNew_BlackAndWhiteTiff_IsG4_OtherTiffsStayLzw()
    {
        var page = TextPage();
        string bw = WpfImageCodec.SaveAsNew(page, Path.Combine(_folder, "bw.tif"), OutputFormat.Tiff, 300, 0.9, ColorMode.BlackWhite);
        byte[] bytes = File.ReadAllBytes(bw);
        Assert.Equal(BilevelTiff.Make(page, 300), bytes);
        Assert.Equal(4u, TiffTag(bytes, 259));
        AssertSamePixels(page, FromBitmap(Decode(bytes).Frames[0]), "saved");

        string gray = WpfImageCodec.SaveAsNew(page, Path.Combine(_folder, "gray.tif"), OutputFormat.Tiff, 300, 0.9, ColorMode.Grayscale);
        Assert.Equal(5u, TiffTag(File.ReadAllBytes(gray), 259)); // LZW
        string before = WpfImageCodec.SaveAsNew(page, Path.Combine(_folder, "default.tif"), OutputFormat.Tiff, 300, 0.9);
        Assert.Equal(5u, TiffTag(File.ReadAllBytes(before), 259));
        string png = WpfImageCodec.SaveAsNew(page, Path.Combine(_folder, "bw.png"), OutputFormat.Png, 300, 0.9, ColorMode.BlackWhite);
        Assert.Equal(new byte[] { 0x89, 0x50, 0x4E, 0x47 }, File.ReadAllBytes(png)[..4]);
        Assert.True(bytes.Length * 2 < new FileInfo(before).Length, $"G4 {bytes.Length} bytes, LZW {new FileInfo(before).Length}");
    }

    [Fact]
    public async Task RotateInPlace_KeepsABlackAndWhiteTiffG4()
    {
        var page = Image(13, 7, (x, y) => x == 0 || y == 0 || (x + y) % 4 == 0);
        string path = Path.Combine(_folder, "turn.tif");
        File.WriteAllBytes(path, BilevelTiff.Make(page, 200));
        Assert.Null(await SavedFiles.RotateClockwiseAsync(path));
        byte[] bytes = File.ReadAllBytes(path);
        Assert.Equal(4u, TiffTag(bytes, 259));
        var frame = Decode(bytes).Frames[0];
        Assert.Equal(200, frame.DpiX, 3);
        // 90° clockwise: the new (x, y) is the old (y, height − 1 − x).
        var turned = Image(7, 13, (x, y) => Bilevel.IsBlack(Bilevel.Pack(page), 13, y, 6 - x));
        AssertSamePixels(turned, FromBitmap(frame), "turned");
    }

    // MARK: - PDF through Windows.Data.Pdf

    /// <summary>
    /// Page <paramref name="page"/> (from 0) as Windows.Data.Pdf renders it, read back at the image's
    /// <paramref name="width"/> × <paramref name="height"/> pixels. The renderer multiplies the size
    /// asked for by the display scale and smooths images on the way (any image: a gray JPEG of the
    /// same pixels renders the same), so the page is rendered at three times the image's size or
    /// more and each image pixel is read at its center, where the smoothing leaves its own value.
    /// </summary>
    private static async Task<RgbaImage> Render(byte[] pdf, uint page, int width, int height)
    {
        using var source = System.IO.WindowsRuntimeStreamExtensions.AsRandomAccessStream(new MemoryStream(pdf));
        var document = await Windows.Data.Pdf.PdfDocument.LoadFromStreamAsync(source);
        using var pdfPage = document.GetPage(page);
        var probe = await RenderPage(pdfPage, 100, 100);
        double scale = probe.Width / 100.0;
        var big = await RenderPage(pdfPage, (uint)Math.Ceiling(3 * width / scale), (uint)Math.Ceiling(3 * height / scale));
        Assert.True(big.Width >= 3 * width && big.Height >= 3 * height,
                    $"display scale {scale:0.###}: rendered {big.Width} × {big.Height} for {width} × {height}");
        var pixels = new byte[width * height * 4];
        for (int y = 0; y < height; y++)
        {
            int v = (int)((y + 0.5) * big.Height / height);
            for (int x = 0; x < width; x++)
            {
                int u = (int)((x + 0.5) * big.Width / width);
                Array.Copy(big.Pixels, (v * big.Width + u) * 4, pixels, (y * width + x) * 4, 4);
            }
        }
        return new RgbaImage(width, height, pixels);
    }

    private static async Task<RgbaImage> RenderPage(Windows.Data.Pdf.PdfPage page, uint width, uint height)
    {
        using var rendered = new Windows.Storage.Streams.InMemoryRandomAccessStream();
        await page.RenderToStreamAsync(rendered, new Windows.Data.Pdf.PdfPageRenderOptions
        {
            DestinationWidth = width,
            DestinationHeight = height,
        });
        rendered.Seek(0);
        using var managed = System.IO.WindowsRuntimeStreamExtensions.AsStreamForRead(rendered);
        var buffer = new MemoryStream();
        await managed.CopyToAsync(buffer);
        return FromBitmap(Decode(buffer.ToArray()).Frames[0]);
    }

    private static PdfPageInput G4Page(RgbaImage image, int dpi) =>
        new(PdfCcittImage.Encode(image), image.Width, image.Height, dpi, null);

    [Fact]
    public async Task WindowsDataPdf_RendersAG4Page_PixelExact()
    {
        var page = TextPage();
        byte[] pdf = PdfBuilder.Make([G4Page(page, 100)]);
        var rendered = await Render(pdf, 0, 840, 1080);
        AssertSamePixels(page, rendered, "plain PDF");
        // The check sees a single pixel: the page with one pixel turned differs from the render there.
        var changed = page.Clone();
        changed.Pixels[(500 * 840 + 400) * 4] ^= 0xFF;
        changed.Pixels[(500 * 840 + 400) * 4 + 1] ^= 0xFF;
        changed.Pixels[(500 * 840 + 400) * 4 + 2] ^= 0xFF;
        Assert.Equal(1, Differing(changed, rendered));
    }

    [Fact]
    public async Task WindowsDataPdf_RendersG4Pages_InPdfA_AndAddedToAPdf()
    {
        var page = TextPage();
        var noise = NoiseImage(420, 300, 99);
        byte[] archival = PdfBuilder.Make([G4Page(page, 100), G4Page(noise, 200)],
                                          options: new PdfWriteOptions { Conformance = PdfConformance.PdfA2b, Title = "B&W" });
        AssertSamePixels(page, await Render(archival, 0, 840, 1080), "PDF/A page 1");
        AssertSamePixels(noise, await Render(archival, 1, 420, 300), "PDF/A page 2");

        byte[] appended = PdfAppender.Append(PdfBuilder.Make([G4Page(noise, 200)]), [G4Page(page, 100)]);
        AssertSamePixels(page, await Render(appended, 1, 840, 1080), "added page");
    }
}
