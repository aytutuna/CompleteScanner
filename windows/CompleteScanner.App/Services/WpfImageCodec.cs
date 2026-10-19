using System.IO;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using CompleteScanner.Core;

namespace CompleteScanner.App.Services;

/// <summary>
/// An in-place rewrite failed after the original was already gone; the finished new
/// version could not be moved into place either and was left at <see cref="TempPath"/>.
/// </summary>
public sealed class TempFileKeptException(string tempPath, Exception inner)
    : IOException($"The new version was kept as {tempPath}.", inner)
{
    public string TempPath { get; } = tempPath;
}

/// <summary>
/// RgbaImage ↔ WPF bitmap conversion plus file export with DPI metadata — the Windows
/// counterpart of Sources/CompleteScannerKit/Output/ImageExporter.swift (which uses ImageIO).
/// Uses only WPF's built-in encoders, so no package dependencies.
/// </summary>
public static class WpfImageCodec
{
    /// <summary>An RgbaImage as a frozen (thread-safe) BitmapSource for display.</summary>
    public static BitmapSource ToBitmapSource(RgbaImage image, double dpi = 96)
    {
        // WPF has no RGBA8 format; swap to BGRA for Bgra32.
        var bgra = (byte[])image.Pixels.Clone();
        for (int i = 0; i < bgra.Length; i += 4)
        {
            (bgra[i], bgra[i + 2]) = (bgra[i + 2], bgra[i]);
        }
        var bitmap = BitmapSource.Create(image.Width, image.Height, dpi, dpi,
                                         PixelFormats.Bgra32, null, bgra, image.Width * 4);
        bitmap.Freeze();
        return bitmap;
    }

    /// <summary>Decode any image file WPF understands into an RgbaImage.</summary>
    public static RgbaImage Load(string path)
    {
        using var stream = File.OpenRead(path);
        var decoder = BitmapDecoder.Create(stream, BitmapCreateOptions.None, BitmapCacheOption.OnLoad);
        return FromBitmapSource(decoder.Frames[0]);
    }

    /// <summary>Decode in-memory image bytes (e.g. a JPEG fetched over eSCL) into an RgbaImage.</summary>
    public static RgbaImage Decode(byte[] data)
    {
        using var stream = new MemoryStream(data);
        var decoder = BitmapDecoder.Create(stream, BitmapCreateOptions.None, BitmapCacheOption.OnLoad);
        return FromBitmapSource(decoder.Frames[0]);
    }

    /// <summary>Convert any BitmapSource into an RgbaImage.</summary>
    public static RgbaImage FromBitmapSource(BitmapSource source)
    {
        var converted = source.Format == PixelFormats.Bgra32
            ? source
            : new FormatConvertedBitmap(source, PixelFormats.Bgra32, null, 0);
        int width = converted.PixelWidth, height = converted.PixelHeight;
        var bgra = new byte[width * height * 4];
        converted.CopyPixels(bgra, width * 4, 0);
        // BGRA → RGBA.
        for (int i = 0; i < bgra.Length; i += 4)
        {
            (bgra[i], bgra[i + 2]) = (bgra[i + 2], bgra[i]);
        }
        return new RgbaImage(width, height, bgra);
    }

    /// <summary>
    /// Write jpeg/png/tiff with DPI metadata. Throws ScanException (Unsupported) for Pdf —
    /// use PdfBuilder for PDF files, mirroring the Swift exporter.
    /// </summary>
    public static void Save(RgbaImage image, string path, OutputFormat format, int dpi, double jpegQuality)
    {
        var encoder = CreateEncoder(image, format, dpi, jpegQuality);
        try
        {
            using var stream = File.Create(path);
            encoder.Save(stream);
        }
        catch (Exception e) when (e is not ScanException)
        {
            throw ScanException.ExportFailed($"Could not write {Path.GetFileName(path)}: {e.Message}");
        }
    }

    private static BitmapEncoder CreateEncoder(RgbaImage image, OutputFormat format, int dpi, double jpegQuality)
    {
        BitmapEncoder encoder = format switch
        {
            OutputFormat.Jpeg => new JpegBitmapEncoder
            {
                QualityLevel = Math.Clamp((int)Math.Round(jpegQuality * 100), 1, 100),
            },
            OutputFormat.Png => new PngBitmapEncoder(),
            OutputFormat.Tiff => new TiffBitmapEncoder { Compression = TiffCompressOption.Lzw },
            _ => throw ScanException.Unsupported("Use PdfBuilder to write PDF files."),
        };
        encoder.Frames.Add(BitmapFrame.Create(WithDpi(image, dpi)));
        return encoder;
    }

    /// <summary>
    /// Export a NEW file: <see cref="Save"/> into a hidden temporary file in the same folder,
    /// then move it to <paramref name="path"/> — or, when that name was taken meanwhile, to
    /// the next free " 2", " 3", … name. An existing file is never replaced, and a failed
    /// or interrupted write never leaves a truncated file under the final name.
    /// Returns the path actually written.
    /// </summary>
    public static string SaveAsNew(RgbaImage image, string path, OutputFormat format, int dpi,
                                   double jpegQuality)
    {
        var encoder = CreateEncoder(image, format, dpi, jpegQuality);
        string tmp = WriteTempFile(path, encoder.Save);
        try
        {
            string written = NamingTemplate.MoveToFreePath(tmp, path);
            SetHidden(written, false); // in case clearing the temp file's attribute failed
            return written;
        }
        catch (Exception e)
        {
            try { File.Delete(tmp); } catch { /* best effort */ }
            throw ScanException.ExportFailed($"Could not write {Path.GetFileName(path)}: {e.Message}");
        }
    }

    /// <summary>
    /// Rewrite an existing file in place: run <paramref name="write"/> into a hidden temporary
    /// file in the same folder, then swap it over <paramref name="path"/> atomically. A failed
    /// write removes the temporary file and leaves the original untouched.
    /// </summary>
    public static void ReplaceAtomically(string path, Action<Stream> write) =>
        ReplaceAtomically(path, write, (tmp, target) =>
            File.Replace(tmp, target, destinationBackupFileName: null, ignoreMetadataErrors: true));

    /// <param name="replace">The swap step (File.Replace in production; replaceable for tests).</param>
    internal static void ReplaceAtomically(string path, Action<Stream> write, Action<string, string> replace)
    {
        string tmp = WriteTempFile(path, write);
        try
        {
            if (File.Exists(path)) replace(tmp, path);
            else File.Move(tmp, path);
        }
        catch (Exception e)
        {
            // ReplaceFile can fail AFTER it has removed the original (it then reports
            // ERROR_UNABLE_TO_MOVE_REPLACEMENT): the finished temporary file is the only copy
            // left, so move it into place instead of deleting it.
            if (!File.Exists(path) && File.Exists(tmp))
            {
                try
                {
                    NamingTemplate.MoveToFreePath(tmp, path);
                    return;
                }
                catch
                {
                    // Keep it (visible, so the stale-temp sweep leaves it alone) and say where.
                    throw new TempFileKeptException(tmp, e);
                }
            }
            try { File.Delete(tmp); } catch { /* best effort */ }
            throw ScanException.ExportFailed($"Could not write {Path.GetFileName(path)}: {e.Message}");
        }
    }

    /// <summary>
    /// Write a ".{guid}.{ext}.tmp" file beside <paramref name="path"/>. It carries the Hidden
    /// attribute while it is being written (like PdfBuilder's temporary PDF), so a write cut
    /// off by a crash leaves a hidden orphan that <see cref="SavedFiles.SweepStaleTempFiles"/>
    /// can recognize; the attribute is cleared once the file is complete, before any move.
    /// </summary>
    private static string WriteTempFile(string path, Action<Stream> write)
    {
        string directory = Path.GetDirectoryName(Path.GetFullPath(path))!;
        string tmp = Path.Combine(directory, $".{Guid.NewGuid()}{Path.GetExtension(path)}.tmp");
        try
        {
            using (var stream = new FileStream(tmp, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                SetHidden(tmp, true);
                write(stream);
            }
            // Clear Hidden first: moves and replaces carry the source's attributes along.
            SetHidden(tmp, false);
            return tmp;
        }
        catch (Exception e)
        {
            try { File.Delete(tmp); } catch { /* best effort */ }
            if (e is ScanException) throw;
            throw ScanException.ExportFailed($"Could not write {Path.GetFileName(path)}: {e.Message}");
        }
    }

    /// <summary>Best-effort toggle of the Hidden attribute; a temp file left visible is only cosmetic.</summary>
    private static void SetHidden(string path, bool hidden)
    {
        try
        {
            var attributes = File.GetAttributes(path);
            var updated = hidden ? attributes | FileAttributes.Hidden : attributes & ~FileAttributes.Hidden;
            if (updated != attributes) File.SetAttributes(path, updated);
        }
        catch
        {
            // best effort
        }
    }

    /// <summary>
    /// A small display bitmap (long side at most <paramref name="maxSide"/>), frozen so it can
    /// be built on a worker thread and handed to the UI.
    /// </summary>
    public static BitmapSource ToThumbnail(RgbaImage image, int maxSide) =>
        ToBitmapSource(ScanHistory.MakePreview(image, maxSide));

    /// <summary>JPEG-encode for embedding into a PDF page (see Core.PdfBuilder).</summary>
    public static byte[] EncodeJpeg(RgbaImage image, int dpi, double quality = 0.9)
    {
        var encoder = new JpegBitmapEncoder
        {
            QualityLevel = Math.Clamp((int)Math.Round(quality * 100), 1, 100),
        };
        encoder.Frames.Add(BitmapFrame.Create(WithDpi(image, dpi)));
        using var stream = new MemoryStream();
        encoder.Save(stream);
        return stream.ToArray();
    }

    /// <summary>An RgbaImage as a BitmapSource carrying real DPI metadata (for encoders).</summary>
    private static BitmapSource WithDpi(RgbaImage image, int dpi)
    {
        // Rgb24 drops alpha (scans are opaque) and keeps JPEG/TIFF encoders happy.
        var rgb = new byte[image.Width * image.Height * 3];
        for (int i = 0, o = 0; i < image.Pixels.Length; i += 4, o += 3)
        {
            rgb[o] = image.Pixels[i];
            rgb[o + 1] = image.Pixels[i + 1];
            rgb[o + 2] = image.Pixels[i + 2];
        }
        var bitmap = BitmapSource.Create(image.Width, image.Height, dpi, dpi,
                                         PixelFormats.Rgb24, null, rgb, image.Width * 3);
        bitmap.Freeze();
        return bitmap;
    }

}
