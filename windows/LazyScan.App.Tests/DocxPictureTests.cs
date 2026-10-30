using System.IO;
using System.IO.Compression;
using System.Text;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Xml.Linq;
using LazyScan.App.Services;
using LazyScan.Core;
using Xunit;

namespace LazyScan.App.Tests;

// The page pictures of a Word document as the Windows app encodes them (WpfImageCodec.EncodeDocxPicture),
// read back by Windows' own decoders, and a document holding them opened as a zip with every picture
// decoded. The Mac's twin decodes its pictures with ImageIO (DocxWriterTests.swift).
public class DocxPictureTests
{
    private static RgbaImage Page(int width, int height, Func<int, int, (byte R, byte G, byte B)> color)
    {
        var pixels = new byte[width * height * 4];
        for (int y = 0; y < height; y++)
        {
            for (int x = 0; x < width; x++)
            {
                var (r, g, b) = color(x, y);
                int i = (y * width + x) * 4;
                pixels[i] = r;
                pixels[i + 1] = g;
                pixels[i + 2] = b;
                pixels[i + 3] = 255;
            }
        }
        return new RgbaImage(width, height, pixels);
    }

    /// <summary>Text-like black blocks on white, already thresholded as the black &amp; white mode leaves a page.</summary>
    private static bool Ink(int x, int y) => (y / 6) % 3 == 1 && (x / 5) % 4 != 3;

    private static BitmapDecoder Decode(byte[] data) =>
        BitmapDecoder.Create(new MemoryStream(data), BitmapCreateOptions.PreservePixelFormat, BitmapCacheOption.OnLoad);

    private static byte[] Gray8(BitmapSource frame)
    {
        var gray = new FormatConvertedBitmap(frame, PixelFormats.Gray8, null, 0);
        var pixels = new byte[frame.PixelWidth * frame.PixelHeight];
        gray.CopyPixels(pixels, frame.PixelWidth, 0);
        return pixels;
    }

    [Fact]
    public void ColorPage_IsAColorJpeg_AtTheSizesResolution()
    {
        // 2 × 2.5 in at 600 dpi, red on the left half, blue on the right.
        var page = Page(1200, 1500, (x, _) => x < 600 ? ((byte)220, (byte)30, (byte)30) : ((byte)30, (byte)40, (byte)200));
        var picture = WpfImageCodec.EncodeDocxPicture(page, 600, ColorMode.Color, PdfSizePreset.Standard);
        Assert.Equal(DocxPictureFormat.Jpeg, picture.Format);
        var decoder = Decode(picture.Data);
        Assert.IsType<JpegBitmapDecoder>(decoder);
        var frame = decoder.Frames[0];
        // Standard keeps 300 dpi: half the pixels each way.
        Assert.Equal((600, 750), (frame.PixelWidth, frame.PixelHeight));
        Assert.True(frame.Format.BitsPerPixel >= 24, frame.Format.ToString());
        var bgr = new FormatConvertedBitmap(frame, PixelFormats.Bgr32, null, 0);
        var pixels = new byte[600 * 750 * 4];
        bgr.CopyPixels(pixels, 600 * 4, 0);
        int left = (375 * 600 + 150) * 4, right = (375 * 600 + 450) * 4;
        Assert.True(pixels[left + 2] > 180 && pixels[left] < 80, "red stays red");
        Assert.True(pixels[right] > 160 && pixels[right + 2] < 80, "blue stays blue");
        // Best keeps the scan's resolution.
        var best = Decode(WpfImageCodec.EncodeDocxPicture(page, 600, ColorMode.Color, PdfSizePreset.Best).Data).Frames[0];
        Assert.Equal((1200, 1500), (best.PixelWidth, best.PixelHeight));
    }

    [Fact]
    public void GrayPages_AreGrayJpegs()
    {
        var page = Page(300, 400, (x, y) => ((byte)(x % 256), (byte)(x % 256), (byte)(x % 256)));
        // A color scan without color is stored gray at Standard, as in a PDF; a grayscale scan always.
        foreach (var (mode, size) in new[] { (ColorMode.Color, PdfSizePreset.Standard), (ColorMode.Grayscale, PdfSizePreset.Best) })
        {
            var picture = WpfImageCodec.EncodeDocxPicture(page, 300, mode, size);
            Assert.Equal(DocxPictureFormat.Jpeg, picture.Format);
            var frame = Decode(picture.Data).Frames[0];
            Assert.Equal(PixelFormats.Gray8, frame.Format);
            Assert.Equal((300, 400), (frame.PixelWidth, frame.PixelHeight));
        }
        // Best keeps a color scan in color, gray or not.
        var best = Decode(WpfImageCodec.EncodeDocxPicture(page, 300, ColorMode.Color, PdfSizePreset.Best).Data).Frames[0];
        Assert.True(best.Format.BitsPerPixel >= 24, best.Format.ToString());
    }

    [Fact]
    public void BlackAndWhitePage_IsALosslessOneBitPng()
    {
        var page = Page(330, 210, (x, y) => Ink(x, y) ? ((byte)0, (byte)0, (byte)0) : ((byte)255, (byte)255, (byte)255));
        var picture = WpfImageCodec.EncodeDocxPicture(page, 300, ColorMode.BlackWhite, PdfSizePreset.Standard);
        Assert.Equal(DocxPictureFormat.Png, picture.Format);
        var decoder = Decode(picture.Data);
        Assert.IsType<PngBitmapDecoder>(decoder);
        var frame = decoder.Frames[0];
        Assert.Equal(1, frame.Format.BitsPerPixel);
        Assert.Equal((330, 210), (frame.PixelWidth, frame.PixelHeight));
        byte[] gray = Gray8(frame);
        for (int y = 0; y < 210; y++)
        {
            for (int x = 0; x < 330; x++)
            {
                Assert.True(gray[y * 330 + x] == (Ink(x, y) ? 0 : 255), $"pixel ({x}, {y})");
            }
        }
        // Far smaller than the gray JPEG a writer without one-bit pictures would store.
        int grayJpeg = WpfImageCodec.EncodeJpeg(page, 300, 0.8, gray: true).Length;
        Assert.True(picture.Data.Length * 2 < grayJpeg, $"{picture.Data.Length} vs {grayJpeg}");

        // 1200 dpi at Compact is stored at 300 dpi, thresholded again after the box filter.
        var fine = Page(1320, 840, (x, y) => Ink(x / 4, y / 4) ? ((byte)0, (byte)0, (byte)0) : ((byte)255, (byte)255, (byte)255));
        var compact = Decode(WpfImageCodec.EncodeDocxPicture(fine, 1200, ColorMode.BlackWhite, PdfSizePreset.Compact).Data).Frames[0];
        Assert.Equal((330, 210, 1), (compact.PixelWidth, compact.PixelHeight, compact.Format.BitsPerPixel));
        Assert.Equal(gray, Gray8(compact));
    }

    [Fact]
    public void WordDocument_WithPictures_OpensAndEveryPictureDecodes()
    {
        XNamespace w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main";
        XNamespace wp = "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing";
        XNamespace a = "http://schemas.openxmlformats.org/drawingml/2006/main";
        XNamespace r = "http://schemas.openxmlformats.org/officeDocument/2006/relationships";
        XNamespace rels = "http://schemas.openxmlformats.org/package/2006/relationships";

        // A Letter page in color and a narrow black & white receipt, both at 300 dpi.
        var color = Page(2550, 3300, (x, y) => ((byte)(x * 255 / 2550), (byte)(y * 255 / 3300), 128));
        var receipt = Page(900, 3000, (x, y) => Ink(x, y) ? ((byte)0, (byte)0, (byte)0) : ((byte)255, (byte)255, (byte)255));
        var pages = new List<OcrPage> { OcrPage.Of([], 2550, 3300, 300), OcrPage.Of([], 900, 3000, 300) };
        var pictures = new List<DocxPicture?>
        {
            WpfImageCodec.EncodeDocxPicture(color, 300, ColorMode.Color, PdfSizePreset.Standard),
            WpfImageCodec.EncodeDocxPicture(receipt, 300, ColorMode.BlackWhite, PdfSizePreset.Standard),
        };
        byte[] docx = DocxWriter.Make(pages, pictures);

        using var archive = new ZipArchive(new MemoryStream(docx), ZipArchiveMode.Read);
        XDocument Part(string name)
        {
            using var stream = archive.GetEntry(name)!.Open();
            return XDocument.Load(stream);
        }
        var targets = Part("word/_rels/document.xml.rels").Root!.Elements(rels + "Relationship")
            .ToDictionary(e => (string)e.Attribute("Id")!, e => "word/" + (string)e.Attribute("Target")!);
        var document = Part("word/document.xml");
        var inlines = document.Descendants(wp + "inline").ToList();
        Assert.Equal(2, inlines.Count);
        var expectedFormats = new[] { typeof(JpegBitmapDecoder), typeof(PngBitmapDecoder) };
        for (int i = 0; i < inlines.Count; i++)
        {
            string id = (string)inlines[i].Descendants(a + "blip").Single().Attribute(r + "embed")!;
            using var stream = archive.GetEntry(targets[id])!.Open();
            using var copy = new MemoryStream();
            stream.CopyTo(copy);
            var decoder = Decode(copy.ToArray());
            Assert.IsType(expectedFormats[i], decoder);
            var frame = decoder.Frames[0];
            var extent = inlines[i].Element(wp + "extent")!;
            double cx = (double)extent.Attribute("cx")!, cy = (double)extent.Attribute("cy")!;
            // The picture keeps the page's shape on the paper.
            Assert.Equal((double)frame.PixelWidth / frame.PixelHeight, cx / cy, 2);
        }
        // Letter paper from the first page; the Letter page fills the space inside the margins'
        // width, the receipt (3 × 10 in) keeps its width and is shrunk to the 9 in of height.
        var size = document.Root!.Element(w + "body")!.Element(w + "sectPr")!.Element(w + "pgSz")!;
        Assert.Equal(("12240", "15840"), ((string)size.Attribute(w + "w")!, (string)size.Attribute(w + "h")!));
        Assert.Equal("5943600", (string)inlines[0].Element(wp + "extent")!.Attribute("cx")!);
        Assert.Equal(("2468880", "8229600"),
                     ((string)inlines[1].Element(wp + "extent")!.Attribute("cx")!, (string)inlines[1].Element(wp + "extent")!.Attribute("cy")!));
        // Stored entries: the pictures are already compressed, and the package is about their size.
        long media = archive.Entries.Where(e => e.FullName.StartsWith("word/media/", StringComparison.Ordinal)).Sum(e => e.Length);
        Assert.True(docx.Length < media + 8000, $"{docx.Length} vs {media}");
        Assert.Contains("image/png", Encoding.UTF8.GetString(docx));
    }
}
