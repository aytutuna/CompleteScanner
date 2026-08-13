using System.IO;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using CompleteScanner.Core;

namespace CompleteScanner.App.Services;

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
