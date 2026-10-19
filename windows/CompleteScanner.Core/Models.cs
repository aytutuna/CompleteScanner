using System.Text.Json.Serialization;

namespace CompleteScanner.Core;

// Port of Sources/CompleteScannerKit/Core/Models.swift. Enums serialize as camelCase
// strings (see StoreFiles.JsonOptions in Persistence.cs) matching the Swift rawValues, so
// settings/preset files stay conceptually interchangeable. Settings files load across
// versions (CONTRACTS.md, rule 6): every persisted property needs an initializer default,
// and the first member of every persisted enum is its default; add new members after the
// existing ones and never rename one.

// MARK: - Core enums

public enum ScanIntent
{
    Document,
    Photo,
}

public enum ColorMode
{
    Color,
    Grayscale,
    BlackWhite,
}

public enum ScanSource
{
    Flatbed,
    DocumentFeeder,
}

public enum OutputFormat
{
    Pdf,
    Jpeg,
    Png,
    Tiff,
}

/// <summary>
/// The app's color scheme: follow Windows, or force light or dark. An app preference, kept
/// apart from <see cref="ScanSettings"/> so that applying a preset never changes it.
/// </summary>
public enum AppAppearance
{
    System,
    Light,
    Dark,
}

public static class ModelLabels
{
    public static string Label(this ScanIntent intent) => intent switch
    {
        ScanIntent.Document => "Document",
        ScanIntent.Photo => "Photos",
        _ => intent.ToString(),
    };

    public static string Label(this ColorMode mode) => mode switch
    {
        ColorMode.Color => "Color",
        ColorMode.Grayscale => "Grayscale",
        ColorMode.BlackWhite => "Black & White",
        _ => mode.ToString(),
    };

    public static string Label(this ScanSource source) => source switch
    {
        ScanSource.Flatbed => "Flatbed",
        ScanSource.DocumentFeeder => "Document Feeder (ADF)",
        _ => source.ToString(),
    };

    public static string Label(this OutputFormat format) => format switch
    {
        OutputFormat.Pdf => "PDF",
        OutputFormat.Jpeg => "JPEG",
        OutputFormat.Png => "PNG",
        OutputFormat.Tiff => "TIFF",
        _ => format.ToString(),
    };

    public static string FileExtension(this OutputFormat format) => format switch
    {
        OutputFormat.Pdf => "pdf",
        OutputFormat.Jpeg => "jpg",
        OutputFormat.Png => "png",
        OutputFormat.Tiff => "tiff",
        _ => format.ToString().ToLowerInvariant(),
    };
}

// MARK: - Settings

public sealed class AdjustmentSettings : IEquatable<AdjustmentSettings>
{
    public bool AutoEnhance { get; set; } = false;
    /// <summary>-1 ... 1, neutral 0</summary>
    public double Brightness { get; set; } = 0.0;
    /// <summary>0.25 ... 4, neutral 1</summary>
    public double Contrast { get; set; } = 1.0;
    /// <summary>0 ... 2, neutral 1</summary>
    public double Saturation { get; set; } = 1.0;
    /// <summary>-2 ... 2, neutral 0; positive sharpens, negative softens (Gaussian blur)</summary>
    public double Sharpness { get; set; } = 0.0;
    /// <summary>Reduce moiré from scanning printed material.</summary>
    public bool Descreen { get; set; } = false;
    /// <summary>Boost faded colors of old photos.</summary>
    public bool RestoreFadedColors { get; set; } = false;
    /// <summary>0 ... 1 luminance threshold used for ColorMode.BlackWhite conversion.</summary>
    public double BlackWhiteThreshold { get; set; } = 0.5;

    [JsonIgnore]
    public bool IsIdentity =>
        !AutoEnhance && Brightness == 0 && Contrast == 1 && Saturation == 1
            && Sharpness == 0 && !Descreen && !RestoreFadedColors;

    public AdjustmentSettings Clone() => (AdjustmentSettings)MemberwiseClone();

    public bool Equals(AdjustmentSettings? other) =>
        other is not null
        && AutoEnhance == other.AutoEnhance && Brightness == other.Brightness
        && Contrast == other.Contrast && Saturation == other.Saturation
        && Sharpness == other.Sharpness && Descreen == other.Descreen
        && RestoreFadedColors == other.RestoreFadedColors
        && BlackWhiteThreshold == other.BlackWhiteThreshold;

    public override bool Equals(object? obj) => Equals(obj as AdjustmentSettings);
    public override int GetHashCode() =>
        HashCode.Combine(AutoEnhance, Brightness, Contrast, Saturation,
                         Sharpness, Descreen, RestoreFadedColors, BlackWhiteThreshold);
}

public sealed class ScanSettings
{
    public ScanIntent Intent { get; set; } = ScanIntent.Document;
    public ScanSource Source { get; set; } = ScanSource.Flatbed;
    public int Resolution { get; set; } = 300;
    public ColorMode ColorMode { get; set; } = ColorMode.Color;
    public OutputFormat Format { get; set; } = OutputFormat.Pdf;
    /// <summary>0 ... 1</summary>
    public double JpegQuality { get; set; } = 0.9;
    public string DestinationPath { get; set; } = DefaultDestinationPath;
    public string NamingTemplate { get; set; } = "Scan {date} {counter}";

    // Photo mode
    public bool PhotoAutoSplit { get; set; } = true;
    public bool PhotoAutoDeskew { get; set; } = true;
    /// <summary>Smallest photo side considered a real photo (inches).</summary>
    public double PhotoMinSideInches { get; set; } = 1.2;
    /// <summary>Pixels (at scan resolution) shaved off each detected photo edge to remove background slivers.</summary>
    public int PhotoCropInsetPixels { get; set; } = 0;

    // Document / PDF mode
    /// <summary>
    /// true: scans accumulate as pages and are saved together with "Save PDF".
    /// false: every scan is written to disk immediately as its own file.
    /// </summary>
    public bool DocumentMultiPage { get; set; } = true;
    /// <summary>Run OCR and embed an invisible text layer in saved PDFs.</summary>
    public bool PdfSearchable { get; set; } = true;
    /// <summary>
    /// No longer used: recognition is universal (see <see cref="IOcrService"/>). Kept so
    /// settings and preset files written by older versions still round-trip unchanged.
    /// </summary>
    [Obsolete("OCR recognizes every supported language automatically; this setting is ignored.")]
    public List<string> OcrLanguages { get; set; } = ["en-US"];

    public AdjustmentSettings Adjustments { get; set; } = new();

    public static string DefaultDestinationPath =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments), "CompleteScanner");

    public ScanSettings Clone()
    {
        var copy = (ScanSettings)MemberwiseClone();
#pragma warning disable CS0618 // deep-copy the legacy field so the clone stays independent
        copy.OcrLanguages = [.. OcrLanguages];
#pragma warning restore CS0618
        copy.Adjustments = Adjustments.Clone();
        return copy;
    }
}

// MARK: - Runtime objects

public sealed class ScannedPage
{
    public Guid Id { get; }
    /// <summary>
    /// Page pixels. When <see cref="FilePath"/> is set this is a lower-resolution preview;
    /// the full-resolution original lives in the file.
    /// </summary>
    public RgbaImage Image { get; }
    public int Dpi { get; }
    public ColorMode ColorMode { get; }
    public DateTime CreatedAt { get; }
    /// <summary>
    /// Full-resolution spill file backing this page when it was offloaded from memory.
    /// Consumers that need full pixels reload from it.
    /// </summary>
    public string? FilePath { get; }
    /// <summary>
    /// Pixel dimensions of the full-resolution original (recorded when the page is spooled),
    /// so physical page size stays correct even if only the preview is available.
    /// </summary>
    public SizeD? FullPixelSize { get; }
    /// <summary>
    /// User-requested rotation applied at save time (0...3 quarter turns clockwise).
    /// <see cref="Image"/> already shows the rotation; the full-resolution original (spool
    /// file) stays unrotated until <see cref="PdfBuilder.PreparePage"/> applies it.
    /// </summary>
    public int RotationQuarterTurns { get; set; } = 0;

    public ScannedPage(RgbaImage image, int dpi, ColorMode colorMode, Guid? id = null,
                       DateTime? createdAt = null, string? filePath = null, SizeD? fullPixelSize = null)
    {
        Id = id ?? Guid.NewGuid();
        Image = image;
        Dpi = dpi;
        ColorMode = colorMode;
        CreatedAt = createdAt ?? DateTime.Now;
        FilePath = filePath;
        FullPixelSize = fullPixelSize;
    }

    /// <summary>
    /// The page turned 90° clockwise: the in-memory image is rotated right away (thumbnails
    /// follow it) while the spool file stays untouched and the accumulated turn count is
    /// applied at save time. Port of AppState.rotatePage(id:).
    /// </summary>
    public ScannedPage RotatedClockwise() =>
        new(ImagePipeline.Rotate(Image, 1), Dpi, ColorMode, Id, CreatedAt, FilePath, FullPixelSize)
        {
            RotationQuarterTurns = (RotationQuarterTurns + 1) % 4,
        };
}

/// <summary>
/// A rotated rectangle found on a scanned flatbed image.
///
/// Coordinate convention: source-image pixels, origin at TOP-LEFT, x right, y down.
/// <c>AngleDegrees</c> is the rotation of the rectangle; a positive angle appears as a
/// CLOCKWISE rotation on screen. Normalized to (-45, 45]. A point (x, y) in the
/// rectangle's local frame maps to the image as:
///   ix = center.X + x*cos(a) - y*sin(a)
///   iy = center.Y + x*sin(a) + y*cos(a)
/// </summary>
public sealed class DetectedPhotoRegion : IEquatable<DetectedPhotoRegion>
{
    public Guid Id { get; }
    public PointD Center { get; set; }
    public SizeD Size { get; set; }
    public double AngleDegrees { get; set; }

    public DetectedPhotoRegion(PointD center, SizeD size, double angleDegrees, Guid? id = null)
    {
        Id = id ?? Guid.NewGuid();
        Center = center;
        Size = size;
        AngleDegrees = angleDegrees;
    }

    /// <summary>Corners in source-image pixel coordinates (top-left origin), order: TL, TR, BR, BL of the local frame.</summary>
    public PointD[] Corners()
    {
        double a = AngleDegrees * Math.PI / 180;
        double c = Math.Cos(a), s = Math.Sin(a);
        double hw = Size.Width / 2, hh = Size.Height / 2;
        var local = new[]
        {
            new PointD(-hw, -hh), new PointD(hw, -hh), new PointD(hw, hh), new PointD(-hw, hh),
        };
        var result = new PointD[4];
        for (int i = 0; i < 4; i++)
        {
            result[i] = new PointD(Center.X + local[i].X * c - local[i].Y * s,
                                   Center.Y + local[i].X * s + local[i].Y * c);
        }
        return result;
    }

    /// <summary>Axis-aligned bounding box of <see cref="Corners"/>.</summary>
    public RectD BoundingBox()
    {
        var pts = Corners();
        double minX = pts.Min(p => p.X), minY = pts.Min(p => p.Y);
        double maxX = pts.Max(p => p.X), maxY = pts.Max(p => p.Y);
        return new RectD(minX, minY, maxX - minX, maxY - minY);
    }

    public bool Equals(DetectedPhotoRegion? other) =>
        other is not null && Id == other.Id && Center == other.Center
        && Size == other.Size && AngleDegrees == other.AngleDegrees;
    public override bool Equals(object? obj) => Equals(obj as DetectedPhotoRegion);
    public override int GetHashCode() => HashCode.Combine(Id, Center, Size, AngleDegrees);
}

public sealed class DetectedPhoto
{
    public Guid Id { get; }
    public DetectedPhotoRegion Region { get; }
    public RgbaImage Image { get; }
    public int Dpi { get; }
    /// <summary>
    /// The scanned page this photo was extracted from — a multi-sheet (ADF) photo scan
    /// produces photos from several pages, and manual re-cropping must use the right one.
    /// </summary>
    public Guid? SourcePageId { get; }
    public bool Included { get; set; } = true;
    /// <summary>Extra user-requested rotation applied at save time (0...3 quarter turns clockwise).</summary>
    public int RotationQuarterTurns { get; set; } = 0;

    public DetectedPhoto(DetectedPhotoRegion region, RgbaImage image, int dpi, Guid? id = null,
                         Guid? sourcePageId = null)
    {
        Id = id ?? Guid.NewGuid();
        Region = region;
        Image = image;
        Dpi = dpi;
        SourcePageId = sourcePageId;
    }

    /// <summary>
    /// Manual crop correction: the same photo (id, source page, inclusion, rotation) with a
    /// user-adjusted region and its re-extracted pixels (see
    /// <see cref="PhotoDetector.ExtractPhoto"/>). Port of AppState.recropPhoto(id:region:).
    /// </summary>
    public DetectedPhoto Recropped(DetectedPhotoRegion region, RgbaImage image) =>
        new(region, image, Dpi, Id, SourcePageId)
        {
            Included = Included,
            RotationQuarterTurns = RotationQuarterTurns,
        };
}

/// <summary>
/// One entry in the session's scan history ("Scans" tab): a small preview of every scan
/// as it happened, newest first.
/// </summary>
public sealed class ScanHistoryEntry
{
    public Guid Id { get; }
    public DateTime Date { get; }
    public ScanIntent Intent { get; }
    public int Dpi { get; }
    /// <summary>Downsampled preview (≤ ~700 px long side) — history never retains full pixels.</summary>
    public RgbaImage Thumbnail { get; }
    /// <summary>True pixel dimensions of the original scan.</summary>
    public SizeD PixelSize { get; }

    public ScanHistoryEntry(DateTime date, ScanIntent intent, int dpi, RgbaImage thumbnail,
                            SizeD pixelSize, Guid? id = null)
    {
        Id = id ?? Guid.NewGuid();
        Date = date;
        Intent = intent;
        Dpi = dpi;
        Thumbnail = thumbnail;
        PixelSize = pixelSize;
    }
}

/// <summary>
/// The scan-history bookkeeping from AppState's scan handler, extracted so every shell
/// records history identically.
/// </summary>
public static class ScanHistory
{
    /// <summary>Long side of a history thumbnail, in pixels.</summary>
    public const int ThumbnailMaxSide = 700;
    /// <summary>Entries kept; older ones are dropped.</summary>
    public const int MaxEntries = 50;

    /// <summary>One entry per raw (unadjusted, unspooled) scanned page, in scan order.</summary>
    public static List<ScanHistoryEntry> MakeEntries(IReadOnlyList<ScannedPage> rawPages,
                                                     ScanIntent intent, DateTime date) =>
        rawPages.Select(page => new ScanHistoryEntry(
            date, intent, page.Dpi, MakePreview(page.Image, ThumbnailMaxSide),
            new SizeD(page.Image.Width, page.Image.Height))).ToList();

    /// <summary>
    /// Insert a batch at the front of <paramref name="history"/> (newest first, so the last
    /// page of the batch leads) and drop everything beyond <see cref="MaxEntries"/>.
    /// </summary>
    public static void Record(List<ScanHistoryEntry> history, IReadOnlyList<ScanHistoryEntry> entries)
    {
        history.InsertRange(0, entries.Reverse());
        if (history.Count > MaxEntries)
            history.RemoveRange(MaxEntries, history.Count - MaxEntries);
    }

    /// <summary>Downscale so the long side is at most <paramref name="maxSide"/>; smaller images pass through.</summary>
    public static RgbaImage MakePreview(RgbaImage image, int maxSide)
    {
        int longSide = Math.Max(image.Width, image.Height);
        if (longSide <= maxSide) return image;
        double scale = (double)maxSide / longSide;
        return image.Resized(Math.Max(1, (int)(image.Width * scale)),
                             Math.Max(1, (int)(image.Height * scale)));
    }
}

// MARK: - Devices

/// <param name="Transport">"USB", "Network", "Shared", "Demo", ...</param>
public sealed record ScannerInfo(string Id, string Name, string Transport, bool IsDemo = false);

public sealed class ScannerCapabilities
{
    public List<int> SupportedResolutions { get; set; } = [75, 150, 200, 300, 600, 1200];
    public List<ScanSource> Sources { get; set; } = [ScanSource.Flatbed];
    /// <summary>Physical flatbed size in inches.</summary>
    public SizeD FlatbedSizeInches { get; set; } = new(8.5, 11.7);
    public bool SupportsOverview { get; set; } = true;

    public int NearestResolution(int dpi) =>
        SupportedResolutions.Count == 0
            ? dpi
            : SupportedResolutions.MinBy(r => Math.Abs(r - dpi));
}

/// <param name="Fraction">null = indeterminate</param>
public sealed record ScanProgress(double? Fraction, string Message)
{
    public ScanProgress(string message) : this(null, message) { }
}

// MARK: - Presets

public sealed class Preset
{
    /// <summary>Name given to a stored preset whose name is missing or unreadable.</summary>
    internal const string FallbackName = "Untitled preset";

    public Guid Id { get; set; } = Guid.NewGuid();
    public string Name { get; set; } = FallbackName;
    public ScanSettings Settings { get; set; } = new();

    public Preset() { }

    public Preset(string name, ScanSettings settings)
    {
        Name = name;
        Settings = settings;
    }
}

// MARK: - Errors

public enum ScanErrorKind
{
    DeviceUnavailable,
    SessionFailed,
    ScanFailed,
    Cancelled,
    ExportFailed,
    Unsupported,
}

/// <summary>Port of Swift's ScanError: one exception type with a kind and a user-facing message.</summary>
public sealed class ScanException : Exception
{
    public ScanErrorKind Kind { get; }

    private ScanException(ScanErrorKind kind, string message) : base(message)
    {
        Kind = kind;
    }

    public static ScanException DeviceUnavailable(string detail) =>
        new(ScanErrorKind.DeviceUnavailable, $"Scanner unavailable: {detail}");
    public static ScanException SessionFailed(string detail) =>
        new(ScanErrorKind.SessionFailed, $"Could not open a session with the scanner: {detail}");
    public static ScanException ScanFailed(string detail) =>
        new(ScanErrorKind.ScanFailed, $"Scan failed: {detail}");
    public static ScanException Cancelled() =>
        new(ScanErrorKind.Cancelled, "The scan was cancelled.");
    public static ScanException ExportFailed(string detail) =>
        new(ScanErrorKind.ExportFailed, $"Saving failed: {detail}");
    public static ScanException Unsupported(string detail) =>
        new(ScanErrorKind.Unsupported, $"Unsupported: {detail}");
}
