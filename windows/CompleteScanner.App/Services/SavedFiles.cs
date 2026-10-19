using System.Collections.Concurrent;
using System.Diagnostics;
using System.IO;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using CompleteScanner.Core;

namespace CompleteScanner.App.Services;

/// <summary>One file in the destination folder, as listed by the Saved tab.</summary>
public sealed record SavedFile(string Path, DateTime Modified, long Size)
{
    public string Name => System.IO.Path.GetFileName(Path);
    public bool IsPdf => System.IO.Path.GetExtension(Path).Equals(".pdf", StringComparison.OrdinalIgnoreCase);

    /// <summary>The image format for rotatable files; null for PDFs.</summary>
    public OutputFormat? ImageFormat => System.IO.Path.GetExtension(Path).ToLowerInvariant() switch
    {
        ".jpg" or ".jpeg" => OutputFormat.Jpeg,
        ".png" => OutputFormat.Png,
        ".tif" or ".tiff" => OutputFormat.Tiff,
        _ => null,
    };
}

/// <summary>
/// File-system side of the Saved tab (port of the logic in UI/SavedFilesView.swift):
/// listing the destination folder, thumbnails, open/reveal, and rotate-in-place.
/// Everything here may run on a worker thread except where noted.
/// </summary>
public static class SavedFiles
{
    private static readonly HashSet<string> KnownExtensions =
        new(StringComparer.OrdinalIgnoreCase) { ".pdf", ".jpg", ".jpeg", ".png", ".tif", ".tiff" };

    /// <summary>One lock per file so concurrent rotates of the same file run one after another.</summary>
    private static readonly ConcurrentDictionary<string, SemaphoreSlim> FileLocks =
        new(StringComparer.OrdinalIgnoreCase);

    /// <summary>
    /// Saved scans in <paramref name="directory"/>, newest first. Returns null when the folder
    /// exists but cannot be read; an empty list when it does not exist yet.
    /// </summary>
    public static List<SavedFile>? List(string directory)
    {
        if (!Directory.Exists(directory)) return [];
        try
        {
            var info = new DirectoryInfo(directory);
            return info.EnumerateFiles()
                .Where(f => !f.Name.StartsWith('.')
                            && (f.Attributes & FileAttributes.Hidden) == 0
                            && KnownExtensions.Contains(f.Extension))
                .Select(f => new SavedFile(f.FullName, f.LastWriteTime, f.Length))
                .OrderByDescending(f => f.Modified)
                .ToList();
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or System.Security.SecurityException)
        {
            return null;
        }
    }

    /// <summary>The current listing entry for one file; null when it is gone or unreadable.</summary>
    public static SavedFile? Describe(string path)
    {
        try
        {
            var info = new FileInfo(path);
            return info.Exists ? new SavedFile(info.FullName, info.LastWriteTime, info.Length) : null;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or System.Security.SecurityException)
        {
            return null;
        }
    }

    /// <summary>A temporary file is only treated as abandoned once it is at least this old.</summary>
    public static readonly TimeSpan StaleTempFileAge = TimeSpan.FromHours(1);

    /// <summary>
    /// Delete temporary files that an interrupted export or rotate left in
    /// <paramref name="directory"/>: ".{guid}.{ext}.tmp" files that still carry the Hidden
    /// attribute (set while a write is in progress, cleared once the file is complete) and
    /// have not been written to for <paramref name="minAge"/>. A complete temporary file
    /// (visible) may be the only copy of a rotated image, so it is left alone. Returns the
    /// number of files deleted; never throws.
    /// </summary>
    public static int SweepStaleTempFiles(string directory, TimeSpan minAge)
    {
        int deleted = 0;
        try
        {
            if (!Directory.Exists(directory)) return 0;
            var cutoff = DateTime.UtcNow - minAge;
            foreach (var file in new DirectoryInfo(directory).EnumerateFiles(".*.tmp"))
            {
                try
                {
                    if (!IsWriterTempName(file.Name)
                        || (file.Attributes & FileAttributes.Hidden) == 0
                        || file.LastWriteTimeUtc > cutoff)
                    {
                        continue;
                    }
                    file.Delete();
                    deleted++;
                }
                catch
                {
                    // In use or not ours to delete: leave it.
                }
            }
        }
        catch
        {
            // Unreadable folder: nothing to sweep.
        }
        return deleted;
    }

    /// <summary>".{guid}.{ext}.tmp", the name WpfImageCodec and PdfBuilder give their temporary files.</summary>
    internal static bool IsWriterTempName(string name)
    {
        if (!name.StartsWith('.') || !name.EndsWith(".tmp", StringComparison.OrdinalIgnoreCase)) return false;
        string inner = name[1..^".tmp".Length];
        int dot = inner.IndexOf('.');
        return dot == 36 && inner.Length > dot + 1 && Guid.TryParseExact(inner[..dot], "D", out _);
    }

    /// <summary>Open with the default app.</summary>
    public static void Open(string path) =>
        Process.Start(new ProcessStartInfo(path) { UseShellExecute = true });

    /// <summary>Show the file (or a folder) in Explorer.</summary>
    public static void Reveal(string path)
    {
        if (Directory.Exists(path))
        {
            Process.Start(new ProcessStartInfo("explorer.exe", $"\"{path}\"") { UseShellExecute = true });
        }
        else
        {
            Process.Start(new ProcessStartInfo("explorer.exe", $"/select,\"{path}\"") { UseShellExecute = true });
        }
    }

    public static string SizeText(long bytes)
    {
        string[] units = ["bytes", "KB", "MB", "GB"];
        double value = bytes;
        int unit = 0;
        while (value >= 1000 && unit < units.Length - 1)
        {
            value /= 1000;
            unit++;
        }
        return unit == 0 ? $"{bytes} bytes" : $"{value:0.#} {units[unit]}";
    }

    // MARK: - Thumbnails

    /// <summary>
    /// A small frozen preview: images decode at <paramref name="decodeWidth"/> (never the full
    /// pixels) with their EXIF orientation applied; PDFs render their first page through the
    /// built-in Windows PDF renderer. null when the file cannot be read.
    /// </summary>
    public static async Task<BitmapSource?> LoadThumbnailAsync(SavedFile file, int decodeWidth)
    {
        try
        {
            if (file.IsPdf) return await RenderPdfThumbnailAsync(file.Path, decodeWidth);
            return await Task.Run(() => LoadImageThumbnail(file.Path, decodeWidth));
        }
        catch
        {
            return null;
        }
    }

    private static BitmapSource LoadImageThumbnail(string path, int decodeWidth)
    {
        int orientation;
        using (var probe = OpenShared(path))
        {
            var frame = BitmapFrame.Create(probe, BitmapCreateOptions.DelayCreation, BitmapCacheOption.None);
            orientation = ReadOrientation(frame);
        }
        using var stream = OpenShared(path);
        var image = new BitmapImage();
        image.BeginInit();
        image.CacheOption = BitmapCacheOption.OnLoad;
        image.CreateOptions = BitmapCreateOptions.IgnoreColorProfile;
        image.StreamSource = stream;
        // Orientations 5-8 store the image sideways: the displayed width is the stored height.
        if (orientation >= 5) image.DecodePixelHeight = decodeWidth;
        else image.DecodePixelWidth = decodeWidth;
        image.EndInit();
        image.Freeze();
        return ApplyOrientation(image, orientation, extraClockwiseDegrees: 0);
    }

    /// <summary>PDFs above this size get the placeholder icon instead of a rendered first page.</summary>
    private const long MaxPdfThumbnailBytes = 200L * 1024 * 1024;

    private static async Task<BitmapSource?> RenderPdfThumbnailAsync(string path, int width)
    {
        // Load from an in-memory copy: a PdfDocument opened from the file keeps a handle on it
        // until it is garbage-collected, which would block renaming or deleting the PDF.
        byte[]? bytes = await Task.Run(() =>
        {
            using var file = OpenShared(path);
            if (file.Length > MaxPdfThumbnailBytes) return null;
            var data = new byte[file.Length];
            file.ReadExactly(data);
            return data;
        });
        if (bytes is null) return null;
        using var source = System.IO.WindowsRuntimeStreamExtensions.AsRandomAccessStream(new MemoryStream(bytes));
        var document = await Windows.Data.Pdf.PdfDocument.LoadFromStreamAsync(source);
        if (document.PageCount == 0) return null;
        using var page = document.GetPage(0);
        using var rendered = new Windows.Storage.Streams.InMemoryRandomAccessStream();
        await page.RenderToStreamAsync(rendered, new Windows.Data.Pdf.PdfPageRenderOptions
        {
            DestinationWidth = (uint)width,
        });
        rendered.Seek(0);
        using var managed = System.IO.WindowsRuntimeStreamExtensions.AsStreamForRead(rendered);
        var buffer = new MemoryStream();
        await managed.CopyToAsync(buffer);
        buffer.Position = 0;
        var image = new BitmapImage();
        image.BeginInit();
        image.CacheOption = BitmapCacheOption.OnLoad;
        image.StreamSource = buffer;
        image.EndInit();
        image.Freeze();
        return image;
    }

    // MARK: - Rotate in place

    /// <summary>
    /// "Turn after save": rewrite a saved image file rotated 90° clockwise, keeping its
    /// format, DPI and (for JPEG) its estimated compression quality. The EXIF orientation is
    /// baked into the pixels first so the result matches what the user saw.
    ///
    /// Safety: the rotated file is written beside the original and swapped in atomically, so
    /// a failed write never destroys the only copy; rotates of the same file are serialized;
    /// multi-page TIFFs and PDFs are refused rather than silently truncated.
    /// Returns null on success, or a user-facing reason for the failure.
    /// </summary>
    public static async Task<string?> RotateClockwiseAsync(string path)
    {
        var file = new SavedFile(path, default, 0);
        if (file.IsPdf) return "PDFs can't be rotated here — rotate the pages in the queue before saving.";
        if (file.ImageFormat is not { } format) return "This file type can't be rotated.";

        var gate = FileLocks.GetOrAdd(Path.GetFullPath(path), _ => new SemaphoreSlim(1, 1));
        await gate.WaitAsync();
        try
        {
            return await Task.Run(() => RotateFile(path, format));
        }
        finally
        {
            gate.Release();
        }
    }

    private static string? RotateFile(string path, OutputFormat format)
    {
        // The pixels stay a BitmapSource in the file's own pixel format, so alpha, gray,
        // bilevel and 16-bit images survive the rotate unchanged.
        BitmapSource rotated;
        double quality = 0.95;
        try
        {
            using var stream = OpenShared(path);
            var decoder = BitmapDecoder.Create(stream, BitmapCreateOptions.PreservePixelFormat,
                                               BitmapCacheOption.OnLoad);
            if (decoder.Frames.Count != 1)
            {
                return "It has multiple pages — rotate it in another app instead.";
            }
            var frame = decoder.Frames[0];
            int orientation = ReadOrientation(frame);
            // Orientations 5-8 store the image sideways, and the 90° turn swaps the axes
            // once more: the output's horizontal DPI is the stored vertical one exactly
            // when the total turn is an odd number of quarter turns.
            bool storedSideways = orientation >= 5;
            double dpiX = storedSideways ? frame.DpiX : frame.DpiY;
            double dpiY = storedSideways ? frame.DpiY : frame.DpiX;
            rotated = WithDpi(ApplyOrientation(frame, orientation, extraClockwiseDegrees: 90),
                              dpiX, dpiY, frame.Palette);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return "The file could not be read.";
        }
        catch
        {
            return "The image could not be decoded.";
        }

        if (format == OutputFormat.Jpeg && EstimateJpegQuality(path) is { } estimated)
        {
            quality = estimated;
        }
        try
        {
            BitmapEncoder encoder = format switch
            {
                OutputFormat.Jpeg => new JpegBitmapEncoder
                {
                    QualityLevel = Math.Clamp((int)Math.Round(quality * 100), 1, 100),
                },
                OutputFormat.Png => new PngBitmapEncoder(),
                _ => new TiffBitmapEncoder { Compression = TiffCompressOption.Lzw },
            };
            encoder.Frames.Add(BitmapFrame.Create(rotated));
            WpfImageCodec.ReplaceAtomically(path, encoder.Save);
            return null;
        }
        catch (TempFileKeptException e)
        {
            return $"The original was removed but the rotated copy could not take its name. It was kept as \"{Path.GetFileName(e.TempPath)}\" in the same folder.";
        }
        catch
        {
            return "The rotated copy could not be written.";
        }
    }

    // MARK: - Metadata helpers

    /// <summary>A frozen copy of <paramref name="source"/> in the same pixel format, carrying the given DPI.</summary>
    private static BitmapSource WithDpi(BitmapSource source, double dpiX, double dpiY, BitmapPalette? palette)
    {
        int stride = (source.PixelWidth * source.Format.BitsPerPixel + 7) / 8;
        var buffer = new byte[(long)stride * source.PixelHeight];
        source.CopyPixels(buffer, stride, 0);
        var copy = BitmapSource.Create(source.PixelWidth, source.PixelHeight,
                                       dpiX > 0 ? dpiX : 96, dpiY > 0 ? dpiY : 96,
                                       source.Format, source.Palette ?? palette, buffer, stride);
        copy.Freeze();
        return copy;
    }

    private static FileStream OpenShared(string path) =>
        new(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);

    /// <summary>EXIF orientation (1...8) of a JPEG/TIFF frame; 1 when absent.</summary>
    internal static int ReadOrientation(BitmapFrame frame)
    {
        try
        {
            if (frame.Metadata is not BitmapMetadata metadata) return 1;
            foreach (string query in new[] { "/app1/ifd/{ushort=274}", "/ifd/{ushort=274}" })
            {
                if (metadata.ContainsQuery(query) && metadata.GetQuery(query) is ushort value
                    && value is >= 1 and <= 8)
                {
                    return value;
                }
            }
        }
        catch
        {
            // Formats without an EXIF block (PNG, some TIFF writers) throw on queries.
        }
        return 1;
    }

    /// <summary>
    /// <paramref name="source"/> transformed to display orientation (EXIF semantics: flip
    /// first, then rotate clockwise), then turned a further
    /// <paramref name="extraClockwiseDegrees"/>. WPF rotations are clockwise in its y-down space.
    /// </summary>
    internal static BitmapSource ApplyOrientation(BitmapSource source, int orientation, int extraClockwiseDegrees)
    {
        (bool flip, int rotate) = orientation switch
        {
            2 => (true, 0),
            3 => (false, 180),
            4 => (true, 180),   // vertical flip = horizontal flip + 180°
            5 => (true, 270),
            6 => (false, 90),
            7 => (true, 90),
            8 => (false, 270),
            _ => (false, 0),
        };
        int total = (rotate + extraClockwiseDegrees) % 360;
        if (!flip && total == 0) return source;
        var group = new TransformGroup();
        if (flip) group.Children.Add(new ScaleTransform(-1, 1));
        if (total != 0) group.Children.Add(new RotateTransform(total));
        var transformed = new TransformedBitmap(source, group);
        transformed.Freeze();
        return transformed;
    }

    /// <summary>Standard (IJG / Annex K) luminance quantization table.</summary>
    private static readonly int[] StandardLuminanceTable =
    [
        16, 11, 10, 16, 24, 40, 51, 61, 12, 12, 14, 19, 26, 58, 60, 55,
        14, 13, 16, 24, 40, 57, 69, 56, 14, 17, 22, 29, 51, 87, 80, 62,
        18, 22, 37, 56, 68, 109, 103, 77, 24, 35, 55, 64, 81, 104, 113, 92,
        49, 64, 78, 87, 103, 121, 120, 101, 72, 92, 95, 98, 112, 100, 103, 99,
    ];

    /// <summary>
    /// The JPEG's compression quality (0...1), estimated from its luminance quantization
    /// table against the IJG scaling the WIC encoder also uses. null when the file has no
    /// readable table. The table sums are compared, so zig-zag order does not matter.
    /// </summary>
    internal static double? EstimateJpegQuality(string path)
    {
        try
        {
            using var stream = OpenShared(path);
            using var reader = new BinaryReader(stream);
            if (reader.ReadByte() != 0xFF || reader.ReadByte() != 0xD8) return null;
            while (stream.Position < stream.Length)
            {
                if (reader.ReadByte() != 0xFF) return null;
                byte marker = reader.ReadByte();
                while (marker == 0xFF) marker = reader.ReadByte(); // fill bytes
                if (marker is 0xD9 or 0xDA) return null;            // EOI / start of scan
                if (marker is >= 0xD0 and <= 0xD7 or 0x01) continue; // markers without length
                int length = (reader.ReadByte() << 8) | reader.ReadByte();
                long end = stream.Position + length - 2;
                if (marker == 0xDB)
                {
                    while (stream.Position < end)
                    {
                        byte pqTq = reader.ReadByte();
                        bool wide = (pqTq >> 4) != 0;
                        int tableId = pqTq & 0x0F;
                        long sum = 0;
                        for (int i = 0; i < 64; i++)
                        {
                            sum += wide ? (reader.ReadByte() << 8) | reader.ReadByte() : reader.ReadByte();
                        }
                        if (tableId == 0)
                        {
                            double scale = sum * 100.0 / StandardLuminanceTable.Sum();
                            double q = scale <= 100 ? (200 - scale) / 2 : 5000 / scale;
                            return Math.Clamp(Math.Round(q) / 100, 0.01, 1.0);
                        }
                    }
                }
                stream.Position = end;
            }
        }
        catch
        {
            // Truncated or unusual file: no estimate.
        }
        return null;
    }
}
