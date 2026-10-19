namespace CompleteScanner.Core;

// Twin of Sources/CompleteScannerKit/Output/PDFImageEncoding.swift: the same table, the same
// rules and the same rounding. Windows encodes the planned JPEG with WIC
// (WpfImageCodec.EncodeJpeg) and embeds it through PdfBuilder; macOS encodes it with ImageIO
// and hands CoreGraphics a JPEG-backed image.

/// <summary>How a page image is stored in the PDF.</summary>
public enum PdfImageKind
{
    /// <summary>A three-component (RGB) JPEG.</summary>
    JpegColor,
    /// <summary>A one-component JPEG, embedded as /DeviceGray.</summary>
    JpegGray,
}

/// <summary>What one PDF size does.</summary>
/// <param name="MaxDpi">Pages scanned finer than this (with <see cref="PdfImageEncoding.DownsampleSlack"/>) are downsampled to it; null keeps the scan resolution.</param>
/// <param name="ColorQuality">JPEG quality for color pages.</param>
/// <param name="GrayQuality">JPEG quality for gray and black &amp; white pages.</param>
/// <param name="AutoGray">Pages scanned in color that have no color are stored as gray.</param>
public sealed record PdfSizeProfile(int? MaxDpi, double ColorQuality, double GrayQuality, bool AutoGray);

/// <summary>How to store one page image.</summary>
/// <param name="TargetDpi">The resolution of the stored image (the page's own when it is not downsampled).</param>
/// <param name="Kind">Color or gray JPEG.</param>
/// <param name="Quality">JPEG quality, 0...1.</param>
public sealed record PdfImagePlan(int TargetDpi, PdfImageKind Kind, double Quality)
{
    public bool IsGray => Kind == PdfImageKind.JpegGray;
}

public static class PdfSizePresets
{
    /// <summary>The sizes as the inspector lists them: largest file first.</summary>
    public static IReadOnlyList<PdfSizePreset> DisplayOrder { get; } =
        [PdfSizePreset.Best, PdfSizePreset.Standard, PdfSizePreset.Compact, PdfSizePreset.Smallest];
}

/// <summary>
/// The size presets of saved PDFs and the per-page plan they lead to: downsampling, gray
/// storage and JPEG quality. The page size in the PDF never changes; only the stored image
/// gets fewer pixels. Black &amp; white pages are stored as gray JPEG (CCITT G4 is a later
/// step).
/// </summary>
public static class PdfImageEncoding
{
    /// <summary>A page is downsampled only when it is finer than this many times the size's limit.</summary>
    public const double DownsampleSlack = 1.1;

    /// <summary>
    /// The size table. The size alone sets the JPEG quality of PDF pages; the JPEG quality
    /// setting is for JPEG files. Best stores what Windows PDFs held before sizes existed:
    /// the scan resolution at quality 0.9.
    /// </summary>
    public static PdfSizeProfile Profile(PdfSizePreset size) => size switch
    {
        PdfSizePreset.Best => new PdfSizeProfile(null, 0.90, 0.90, false),
        PdfSizePreset.Compact => new PdfSizeProfile(200, 0.65, 0.70, true),
        PdfSizePreset.Smallest => new PdfSizeProfile(150, 0.50, 0.55, true),
        _ => new PdfSizeProfile(300, 0.80, 0.80, true), // Standard
    };

    /// <summary>
    /// How to store a page. <paramref name="imageDpi"/> is the resolution of the pixels at hand
    /// (see <see cref="EffectiveDpi"/>); <paramref name="mode"/> is the page's own color mode;
    /// <paramref name="looksGray"/> says whether a color page has no color
    /// (<see cref="ColorAnalysis.IsEffectivelyGray(RgbaImage)"/>), and only counts for sizes
    /// with <see cref="PdfSizeProfile.AutoGray"/>.
    /// </summary>
    public static PdfImagePlan Plan(ColorMode mode, int imageDpi, PdfSizePreset size, bool looksGray)
    {
        var profile = Profile(size);
        int dpi = Math.Max(imageDpi, 1);
        int target = profile.MaxDpi is int max && dpi > DownsampleSlack * max ? max : dpi;
        bool gray = mode != ColorMode.Color || (profile.AutoGray && looksGray);
        double quality = gray ? profile.GrayQuality : profile.ColorQuality;
        return new PdfImagePlan(target, gray ? PdfImageKind.JpegGray : PdfImageKind.JpegColor, quality);
    }

    /// <summary>
    /// <see cref="Plan(ColorMode, int, PdfSizePreset, bool)"/> for a page image; the
    /// color check runs only for color pages with a size that stores gray pages as gray.
    /// </summary>
    public static PdfImagePlan Plan(ColorMode mode, int imageDpi, PdfSizePreset size, RgbaImage image)
    {
        bool looksGray = mode == ColorMode.Color && Profile(size).AutoGray && ColorAnalysis.IsEffectivelyGray(image);
        return Plan(mode, imageDpi, size, looksGray);
    }

    /// <summary>
    /// The resolution of the pixels at hand: the page's own, or less when only a preview of
    /// the page is left (its spool file is missing).
    /// </summary>
    public static int EffectiveDpi(int imageWidth, int pagePixelWidth, int pageDpi)
    {
        if (pagePixelWidth <= 0 || imageWidth == pagePixelWidth) return pageDpi;
        return Math.Max(1, (int)Math.Round((double)pageDpi * imageWidth / pagePixelWidth, MidpointRounding.AwayFromZero));
    }

    /// <summary>The pixel size of an image of <paramref name="width"/> × <paramref name="height"/> at <paramref name="imageDpi"/> stored at <paramref name="targetDpi"/>.</summary>
    public static (int Width, int Height) TargetSize(int width, int height, int imageDpi, int targetDpi)
    {
        if (targetDpi >= imageDpi || imageDpi <= 0) return (width, height);
        double scale = (double)targetDpi / imageDpi;
        return (Math.Max(1, (int)Math.Round(width * scale, MidpointRounding.AwayFromZero)),
                Math.Max(1, (int)Math.Round(height * scale, MidpointRounding.AwayFromZero)));
    }

    /// <summary>
    /// The image at the plan's resolution (box filter, <see cref="RgbaImage.Resized"/>); the
    /// image itself when the plan keeps its resolution.
    /// </summary>
    public static RgbaImage Downsample(RgbaImage image, int imageDpi, PdfImagePlan plan)
    {
        var (width, height) = TargetSize(image.Width, image.Height, imageDpi, plan.TargetDpi);
        return width == image.Width && height == image.Height ? image : image.Resized(width, height);
    }
}
