using System.IO;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using LazyScan.App.Services;
using LazyScan.Core;
using Xunit;

namespace LazyScan.App.Tests;

// Photos of documents read for import with Windows' own decoders (WIC): the orientation tag is read
// (and left for PhotoImport.Oriented to apply), the file is only read, and files that cannot be read
// say why. Windows only: the Mac reads photos with ImageIO (App/AppState+Import.swift), and the
// shared rules are PhotoImportTests in both Core suites.
public class PhotoFileReaderTests : IDisposable
{
    private readonly string _folder = Directory.CreateTempSubdirectory("LazyScan-photo-import-tests-").FullName;

    public void Dispose()
    {
        try { Directory.Delete(_folder, recursive: true); }
        catch (IOException) { }
    }

    /// <summary>A picture whose left half is red and right half blue, so a turn shows.</summary>
    private static BitmapSource Picture(int width, int height)
    {
        var bgra = new byte[width * height * 4];
        for (int y = 0; y < height; y++)
        {
            for (int x = 0; x < width; x++)
            {
                int i = (y * width + x) * 4;
                bool left = x < width / 2;
                bgra[i] = (byte)(left ? 0 : 255);
                bgra[i + 1] = 0;
                bgra[i + 2] = (byte)(left ? 255 : 0);
                bgra[i + 3] = 255;
            }
        }
        var bitmap = BitmapSource.Create(width, height, 72, 72, PixelFormats.Bgra32, null, bgra, width * 4);
        bitmap.Freeze();
        return bitmap;
    }

    private string Write(string name, BitmapEncoder encoder)
    {
        string path = Path.Combine(_folder, name);
        using var stream = File.Create(path);
        encoder.Save(stream);
        return path;
    }

    /// <summary>A JPEG as a phone writes one held sideways: the pixels as the sensor saw them, and the tag that turns them.</summary>
    private string Jpeg(string name, int width, int height, ushort? orientation)
    {
        BitmapMetadata? metadata = null;
        if (orientation is { } tag)
        {
            metadata = new BitmapMetadata("jpg");
            metadata.SetQuery("/app1/ifd/{ushort=274}", tag);
        }
        var encoder = new JpegBitmapEncoder { QualityLevel = 95 };
        encoder.Frames.Add(BitmapFrame.Create(Picture(width, height), null, metadata, null));
        return Write(name, encoder);
    }

    [Theory]
    [InlineData((ushort)1)]
    [InlineData((ushort)3)]
    [InlineData((ushort)6)]
    [InlineData((ushort)8)]
    public void TheOrientationTagIsReadAndLeftToBeApplied(ushort tag)
    {
        string path = Jpeg($"tag{tag}.jpg", 64, 40, tag);
        var photo = PhotoFileReader.Read(path);
        Assert.Equal("tag" + tag + ".jpg", photo.FileName);
        Assert.Equal((64, 40), (photo.Stored.Width, photo.Stored.Height));
        Assert.Equal(PhotoOrientation.FromExif(tag), photo.Orientation);
        // Turned as the tag says, a sideways photo shows upright: for 6 the red left half is now on top.
        var upright = PhotoImport.Oriented(photo.Stored, photo.Orientation);
        if (tag == 6)
        {
            Assert.Equal((40, 64), (upright.Width, upright.Height));
            int top = (5 * upright.Width + 20) * 4, bottom = (58 * upright.Width + 20) * 4;
            Assert.True(upright.Pixels[top] > 200 && upright.Pixels[top + 2] < 60, "red on top");
            Assert.True(upright.Pixels[bottom + 2] > 200 && upright.Pixels[bottom] < 60, "blue below");
        }
    }

    [Fact]
    public void APhotoWithoutATagIsUpright()
    {
        var png = new PngBitmapEncoder();
        png.Frames.Add(BitmapFrame.Create(Picture(30, 20)));
        Assert.True(PhotoFileReader.Read(Write("plain.png", png)).Orientation.IsUpright);
        Assert.True(PhotoFileReader.Read(Jpeg("untagged.jpg", 30, 20, null)).Orientation.IsUpright);
    }

    [Fact]
    public void ThePhotoFileIsOnlyRead()
    {
        string path = Jpeg("original.jpg", 48, 32, 6);
        byte[] before = File.ReadAllBytes(path);
        var written = File.GetLastWriteTimeUtc(path);
        var attributes = File.GetAttributes(path);
        // Another app has the photo open, as a viewer would: it is read all the same.
        using (new FileStream(path, FileMode.Open, FileAccess.ReadWrite, FileShare.ReadWrite))
        {
            Assert.Equal(48, PhotoFileReader.Read(path).Stored.Width);
        }
        PhotoFileReader.Read(path);
        Assert.Equal(before, File.ReadAllBytes(path));
        Assert.Equal(written, File.GetLastWriteTimeUtc(path));
        Assert.Equal(attributes, File.GetAttributes(path));
        Assert.Equal(["original.jpg"], Directory.GetFiles(_folder).Select(Path.GetFileName));
        // Nothing holds the file once it is read: another app can open it to write at once.
        using var writer = new FileStream(path, FileMode.Open, FileAccess.Write, FileShare.None);
        Assert.True(writer.CanWrite);
    }

    [Fact]
    public void AHeicPhotoThatCannotBeReadSaysWhatToInstall()
    {
        string path = Path.Combine(_folder, "IMG_0001.HEIC");
        File.WriteAllBytes(path, [0, 0, 0, 24, (byte)'f', (byte)'t', (byte)'y', (byte)'p', (byte)'h', (byte)'e', (byte)'i', (byte)'c', 1, 2, 3, 4]);
        var error = Assert.Throws<PhotoUnreadableException>(() => PhotoFileReader.Read(path));
        Assert.Equal(PhotoImport.HeifUnavailableMessage("IMG_0001.HEIC"), error.Message);
        Assert.Contains("HEIF Image Extensions", error.Message);
    }

    /// <summary>A PNG whose header says <paramref name="width"/> × <paramref name="height"/>, with next to no pixel data.</summary>
    private static byte[] PngClaiming(int width, int height)
    {
        var png = new List<byte> { 0x89, (byte)'P', (byte)'N', (byte)'G', 0x0D, 0x0A, 0x1A, 0x0A };
        void Chunk(string type, byte[] data)
        {
            png.AddRange(BigEndian((uint)data.Length));
            var typed = System.Text.Encoding.ASCII.GetBytes(type).Concat(data).ToArray();
            png.AddRange(typed);
            png.AddRange(BigEndian(ZipStore.Crc32(typed)));
        }
        static byte[] BigEndian(uint value) => [(byte)(value >> 24), (byte)(value >> 16), (byte)(value >> 8), (byte)value];
        // 8 bits a channel, RGBA, no interlacing.
        Chunk("IHDR", [.. BigEndian((uint)width), .. BigEndian((uint)height), 8, 6, 0, 0, 0]);
        Chunk("IDAT", [0x78, 0x9C, 0x03, 0x00, 0x00, 0x00, 0x00, 0x01]);
        Chunk("IEND", []);
        return png.ToArray();
    }

    [Theory]
    // More than 150 megapixels; then a damaged header no memory could hold.
    [InlineData(13000, 12000)]
    [InlineData(60000, 60000)]
    public void APhotoTooLargeIsTurnedDownBeforeItsPixelsAreDecoded(int width, int height)
    {
        string path = Path.Combine(_folder, "huge.png");
        File.WriteAllBytes(path, PngClaiming(width, height));
        var watch = System.Diagnostics.Stopwatch.StartNew();
        var error = Assert.Throws<PhotoUnreadableException>(() => PhotoFileReader.Read(path));
        Assert.Equal(PhotoImport.UnreadableMessage("huge.png", PhotoImport.TooLargeDetail), error.Message);
        // Only the header was read: decoding the pixels would take seconds and gigabytes.
        Assert.True(watch.ElapsedMilliseconds < 2000, $"{watch.ElapsedMilliseconds} ms");
    }

    [Fact]
    public void AJpegTooLargeIsTurnedDownFromItsHeader()
    {
        // A real JPEG whose start-of-frame is changed to claim 20000 × 10000 pixels.
        byte[] bytes = File.ReadAllBytes(Jpeg("small.jpg", 40, 30, null));
        int sof = Enumerable.Range(2, bytes.Length - 11).First(i => bytes[i] == 0xFF && bytes[i + 1] == 0xC0);
        bytes[sof + 5] = 0x27;
        bytes[sof + 6] = 0x10;
        bytes[sof + 7] = 0x4E;
        bytes[sof + 8] = 0x20;
        string path = Path.Combine(_folder, "huge.jpg");
        File.WriteAllBytes(path, bytes);
        var error = Assert.Throws<PhotoUnreadableException>(() => PhotoFileReader.Read(path));
        Assert.Equal(PhotoImport.UnreadableMessage("huge.jpg", PhotoImport.TooLargeDetail), error.Message);
    }

    [Fact]
    public void EveryPageOfATiffIsReadInTurn()
    {
        var tiff = new TiffBitmapEncoder();
        foreach (var (w, h) in new[] { (40, 30), (50, 20), (24, 36) }) tiff.Frames.Add(BitmapFrame.Create(Picture(w, h)));
        string path = Write("fax.tif", tiff);
        var first = PhotoFileReader.Read(path);
        Assert.Equal((1, 3, "fax.tif"), (first.Page, first.PageCount, first.FileName));
        Assert.Equal("fax.tif, page 1 of 3", first.DisplayName);
        Assert.Equal((40, 30), (first.Stored.Width, first.Stored.Height));
        byte[] bytes = PhotoFileReader.ReadBytes(path);
        var second = PhotoFileReader.Decode(bytes, path, 2);
        var third = PhotoFileReader.Decode(bytes, path, 3);
        Assert.Equal((2, 3, 50, 20), (second.Page, second.PageCount, second.Stored.Width, second.Stored.Height));
        Assert.Equal((3, 3, 24, 36), (third.Page, third.PageCount, third.Stored.Width, third.Stored.Height));
        Assert.Equal("fax.tif, page 3 of 3", third.DisplayName);
        Assert.Throws<PhotoUnreadableException>(() => PhotoFileReader.Decode(bytes, path, 4));
        // Other files are one page, named by the file alone.
        var jpeg = PhotoFileReader.Read(Jpeg("one.jpg", 30, 20, null));
        Assert.Equal((1, 1, "one.jpg"), (jpeg.Page, jpeg.PageCount, jpeg.DisplayName));
    }

    /// <summary>
    /// <paramref name="tiff"/> with the header of its first page changed to claim <paramref name="width"/> ×
    /// <paramref name="height"/> pixels, as a damaged file might; the pages after it are left as they are.
    /// </summary>
    private static byte[] FirstPageClaiming(byte[] tiff, uint width, uint height)
    {
        var bytes = (byte[])tiff.Clone();
        bool little = bytes[0] == (byte)'I';
        ushort Read16(int at) => little ? System.Buffers.Binary.BinaryPrimitives.ReadUInt16LittleEndian(bytes.AsSpan(at))
                                        : System.Buffers.Binary.BinaryPrimitives.ReadUInt16BigEndian(bytes.AsSpan(at));
        uint Read32(int at) => little ? System.Buffers.Binary.BinaryPrimitives.ReadUInt32LittleEndian(bytes.AsSpan(at))
                                      : System.Buffers.Binary.BinaryPrimitives.ReadUInt32BigEndian(bytes.AsSpan(at));
        void Write16(int at, ushort value)
        {
            if (little) System.Buffers.Binary.BinaryPrimitives.WriteUInt16LittleEndian(bytes.AsSpan(at), value);
            else System.Buffers.Binary.BinaryPrimitives.WriteUInt16BigEndian(bytes.AsSpan(at), value);
        }
        void Write32(int at, uint value)
        {
            if (little) System.Buffers.Binary.BinaryPrimitives.WriteUInt32LittleEndian(bytes.AsSpan(at), value);
            else System.Buffers.Binary.BinaryPrimitives.WriteUInt32BigEndian(bytes.AsSpan(at), value);
        }
        int ifd = (int)Read32(4);
        int changed = 0;
        for (int i = 0; i < Read16(ifd); i++)
        {
            int entry = ifd + 2 + i * 12;
            ushort tag = Read16(entry);
            if (tag is not (256 or 257 or 278)) continue;
            // ImageWidth, ImageLength and RowsPerStrip (one strip, as the header then expects), one LONG each.
            Write16(entry + 2, 4);
            Write32(entry + 4, 1);
            Write32(entry + 8, tag == 256 ? width : height);
            if (tag != 278) changed++;
        }
        Assert.Equal(2, changed);
        return bytes;
    }

    private static byte[] Tiff(params (int Width, int Height)[] sizes)
    {
        var tiff = new TiffBitmapEncoder();
        foreach (var (w, h) in sizes) tiff.Frames.Add(BitmapFrame.Create(Picture(w, h)));
        using var stream = new MemoryStream();
        tiff.Save(stream);
        return stream.ToArray();
    }

    [Fact]
    public void APageThatCannotBeReadDoesNotHideThePagesAfterIt()
    {
        // The first page claims 20000 × 20000 pixels, more than 150 megapixels.
        byte[] bytes = FirstPageClaiming(Tiff((40, 30), (50, 20), (24, 36)), 20000, 20000);
        string path = Path.Combine(_folder, "fax.tif");
        // The count comes from the file's header, not from decoding its first page.
        Assert.Equal(3, PhotoFileReader.PageCount(bytes));
        Assert.Equal(PhotoImport.UnreadableMessage("fax.tif, page 1 of 3", PhotoImport.TooLargeDetail),
                     Assert.Throws<PhotoUnreadableException>(() => PhotoFileReader.Decode(bytes, path, 1)).Message);
        var second = PhotoFileReader.Decode(bytes, path, 2);
        var third = PhotoFileReader.Decode(bytes, path, 3);
        Assert.Equal((2, 3, 50, 20), (second.Page, second.PageCount, second.Stored.Width, second.Stored.Height));
        Assert.Equal((3, 3, 24, 36), (third.Page, third.PageCount, third.Stored.Width, third.Stored.Height));
    }

    [Fact]
    public void APageClaimingSizesBeyondAnyNumberIsTurnedDown()
    {
        // 4294967295 × 4294967295: the pixel count does not fit in 64 bits.
        byte[] bytes = FirstPageClaiming(Tiff((40, 30), (50, 20)), uint.MaxValue, uint.MaxValue);
        Assert.StartsWith("fax.tif", Assert.Throws<PhotoUnreadableException>(
            () => PhotoFileReader.Decode(bytes, Path.Combine(_folder, "fax.tif"), 1)).Message, StringComparison.Ordinal);
    }

    [Fact]
    public void OtherFilesAndFilesThatAreNoPictureAreOnePage()
    {
        Assert.Equal(3, PhotoFileReader.PageCount(Tiff((40, 30), (50, 20), (24, 36))));
        Assert.Equal(1, PhotoFileReader.PageCount(Tiff((40, 30))));
        Assert.Equal(1, PhotoFileReader.PageCount(File.ReadAllBytes(Jpeg("one.jpg", 30, 20, null))));
        Assert.Equal(1, PhotoFileReader.PageCount(System.Text.Encoding.ASCII.GetBytes("These are notes; they are not a photo.")));
        Assert.Equal(1, PhotoFileReader.PageCount([]));
    }

    [Fact]
    public void AFileThatIsNoPictureOrIsGoneSaysSo()
    {
        string notes = Path.Combine(_folder, "notes.jpg");
        File.WriteAllText(notes, "These are notes; they are not a photo.");
        Assert.Equal(PhotoImport.UnreadableMessage("notes.jpg", PhotoImport.UnreadableDetail),
                     Assert.Throws<PhotoUnreadableException>(() => PhotoFileReader.Read(notes)).Message);
        string gone = Path.Combine(_folder, "gone.jpg");
        Assert.Equal(PhotoImport.UnreadableMessage("gone.jpg", PhotoImport.MissingDetail),
                     Assert.Throws<PhotoUnreadableException>(() => PhotoFileReader.Read(gone)).Message);
    }
}
