using System.Runtime.InteropServices.WindowsRuntime;
using CompleteScanner.Core;
using Windows.Globalization;
using Windows.Graphics.Imaging;
using Windows.Media.Ocr;

namespace CompleteScanner.App.Services;

/// <summary>
/// Text recognition backed by Windows.Media.Ocr (built into Windows 10/11; per-language
/// packs installed via Settings → Language). The Windows counterpart of the macOS app's
/// Apple Vision OCRService.
///
/// Windows OCR reports word rectangles in top-left-origin pixels; this service converts
/// them to the Core convention (normalized, bottom-left origin) so PdfBuilder maps them
/// straight into PDF user space.
/// </summary>
public sealed class WindowsOcrService : IOcrService
{
    public async Task<IReadOnlyList<OcrLine>> RecognizeLinesAsync(RgbaImage image, IReadOnlyList<string> languages)
    {
        var engine = CreateEngine(languages)
            ?? throw ScanException.ScanFailed(
                "OCR failed: no OCR language pack is installed (Settings → Time & Language → Language).");

        // The engine rejects very large bitmaps; downscale as needed and the normalized
        // boxes stay valid because they are resolution-independent.
        var working = image;
        int maxDim = (int)OcrEngine.MaxImageDimension;
        if (image.Width > maxDim || image.Height > maxDim)
        {
            double scale = Math.Min((double)maxDim / image.Width, (double)maxDim / image.Height);
            working = image.Resized(Math.Max(1, (int)(image.Width * scale)),
                                    Math.Max(1, (int)(image.Height * scale)));
        }

        using var bitmap = new SoftwareBitmap(BitmapPixelFormat.Rgba8, working.Width, working.Height,
                                              BitmapAlphaMode.Ignore);
        bitmap.CopyFromBuffer(working.Pixels.AsBuffer());

        OcrResult result;
        try
        {
            result = await engine.RecognizeAsync(bitmap);
        }
        catch (Exception e)
        {
            throw ScanException.ScanFailed($"OCR failed: {e.Message}");
        }

        double w = working.Width, h = working.Height;
        var lines = new List<OcrLine>();
        foreach (var line in result.Lines)
        {
            if (string.IsNullOrWhiteSpace(line.Text)) continue;
            // Union of the word rects = the line's bounding box.
            double minX = double.MaxValue, minY = double.MaxValue;
            double maxX = double.MinValue, maxY = double.MinValue;
            foreach (var word in line.Words)
            {
                var r = word.BoundingRect;
                minX = Math.Min(minX, r.X);
                minY = Math.Min(minY, r.Y);
                maxX = Math.Max(maxX, r.X + r.Width);
                maxY = Math.Max(maxY, r.Y + r.Height);
            }
            if (maxX <= minX || maxY <= minY) continue;
            // Top-left pixel rect → normalized bottom-left origin.
            var box = new RectD(minX / w, 1.0 - maxY / h, (maxX - minX) / w, (maxY - minY) / h);
            // Windows OCR has no per-line confidence; report 1.
            lines.Add(new OcrLine(line.Text, box, 1.0f));
        }
        return lines;
    }

    /// <summary>
    /// First requested language with an installed pack wins; otherwise fall back to the
    /// user-profile languages (mirroring the Swift service's silent language filtering).
    /// </summary>
    private static OcrEngine? CreateEngine(IReadOnlyList<string> languages)
    {
        foreach (var tag in languages)
        {
            try
            {
                var language = new Language(tag);
                if (OcrEngine.IsLanguageSupported(language))
                {
                    if (OcrEngine.TryCreateFromLanguage(language) is { } engine) return engine;
                }
            }
            catch
            {
                // Malformed BCP-47 tag: skip it, mirroring the Swift service's silent drop.
            }
        }
        return OcrEngine.TryCreateFromUserProfileLanguages();
    }
}
