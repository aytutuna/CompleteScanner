using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace LazyScan.Core;

// Twin of Sources/LazyScanKit/Output/CompanionPackage.swift: the same manifest, the same
// bytes for the same document, the same checks and messages when reading one.

/// <summary>How a page's picture is stored in a companion package.</summary>
public enum CompanionImageFormat
{
    Jpeg,
    Png,
    /// <summary>A bilevel TIFF (CCITT G4), for black &amp; white pages only.</summary>
    Tiff,
}

/// <summary>One picture in a companion package: its encoded bytes and what they show.</summary>
/// <param name="PixelWidth">Its width in pixels; 0 when a package did not say (decode the picture).</param>
/// <param name="PixelHeight">Its height in pixels; 0 when a package did not say.</param>
public sealed record CompanionImage(byte[] Data, CompanionImageFormat Format, int PixelWidth, int PixelHeight,
                                    int Dpi, ColorMode ColorMode);

/// <summary>
/// One page of a companion package: its picture as the app shows it and, optionally, what the
/// app knows about it (rotation still to apply, side and sheet of a two-sided scan, recognized
/// text, the picture as scanned before clean-up).
/// </summary>
public sealed record CompanionPage(CompanionImage Image)
{
    /// <summary>Quarter turns clockwise still to apply to <see cref="Image"/> (0...3), as <see cref="ScannedPage.RotationQuarterTurns"/>.</summary>
    public int RotationQuarterTurns { get; init; }

    /// <summary>Which side of its sheet the page is, for two-sided scans.</summary>
    public PageSide? Side { get; init; }

    /// <summary>The sheet the page belongs to (0 = first), for two-sided scans.</summary>
    public int? SheetIndex { get; init; }

    /// <summary>The recognized text (Vision-normalized boxes, origin bottom-left); null when not recognized, empty when no text was found.</summary>
    public IReadOnlyList<OcrLine>? OcrLines { get; init; }

    /// <summary>The page as scanned, before crop, clean-up and the like; null when there is no other version.</summary>
    public CompanionImage? Original { get; init; }

    /// <summary>
    /// What the camera recorded about the page (<see cref="ScannedPage.Capture"/>), its corners in the
    /// pixels of <see cref="Original"/> as stored; null for a page not taken by a camera, and when a
    /// package's record of it cannot be read.
    /// </summary>
    public CaptureFacts? Capture { get; init; }
}

/// <summary>The app that wrote a package: its name, version and platform ("windows", "macos", "ios").</summary>
public sealed record CompanionWriterInfo(string App, string AppVersion, string Platform);

/// <summary>A document moved between the phone and the desktop as one <c>.csdoc</c> package.</summary>
public sealed record CompanionDocument(string Title, IReadOnlyList<CompanionPage> Pages)
{
    public CompanionWriterInfo Writer { get; init; } = new("CompleteScanner", "", "");

    /// <summary>When the document was made; kept to the second, in UTC.</summary>
    public DateTimeOffset? Created { get; init; }

    /// <summary>The id of the task the document was scanned with (a <see cref="ScanTask"/> id).</summary>
    public string? TaskId { get; init; }

    /// <summary>The file name the sender would give it, without an extension.</summary>
    public string? SuggestedName { get; init; }

    /// <summary>The naming template the sender used (see <see cref="NamingTemplate"/>).</summary>
    public string? NamingTemplate { get; init; }
}

/// <summary>Why a companion package could not be written or read.</summary>
public enum CompanionPackageErrorKind
{
    /// <summary>The zip archive itself was refused (see <see cref="ZipReadException"/>).</summary>
    InvalidArchive,
    /// <summary>No manifest, or a manifest that is not a CompleteScanner document's.</summary>
    NotPackage,
    /// <summary>A newer major format version than this app reads.</summary>
    NewerVersion,
    /// <summary>The manifest is not JSON, too large, or names a picture twice.</summary>
    InvalidManifest,
    NoPages,
    TooManyPages,
    MissingImage,
    /// <summary>A picture's SHA-256 or byte count does not match the manifest.</summary>
    ChecksumMismatch,
    /// <summary>A picture is not a JPEG, PNG or TIFF, or not the format the manifest names.</summary>
    UnsupportedImage,
    /// <summary>Writing: a page that cannot be packaged (see the message).</summary>
    InvalidDocument,
    /// <summary>Writing: the package would be past the limits a reader holds it to.</summary>
    TooLarge,
}

/// <summary>A companion package that cannot be written or read, with a message for the user.</summary>
public sealed class CompanionPackageException : IOException
{
    public CompanionPackageException(CompanionPackageErrorKind kind, string message, Exception? inner = null)
        : base(message, inner)
    {
        Kind = kind;
    }

    public CompanionPackageErrorKind Kind { get; }
}

/// <summary>
/// The <c>.csdoc</c> package: a <see cref="ZipStore"/> archive holding <c>manifest.json</c> first
/// and then each page's picture ("pages/0001.jpg") followed by its original
/// ("pages/0001-original.png"). Writing is deterministic: the manifest is compact JSON written by
/// hand with a fixed key order and fixed number format, entries are stored and dated 1980-01-01,
/// so this and the Swift twin write the same bytes for the same document. Reading goes through
/// <see cref="ZipStoreReader"/>, decodes the manifest leniently (rule 6: unknown keys ignored,
/// missing or wrong-typed fields default, unknown enum values fall back), refuses a newer major
/// version, and checks every picture's byte count, SHA-256 and format.
/// </summary>
public static class CompanionPackage
{
    public const string FileExtension = "csdoc";
    public const string FormatName = "csdoc";
    /// <summary>The major version: a reader refuses a larger one.</summary>
    public const int FormatVersion = 1;
    /// <summary>The minor version: raised for additions older readers can ignore (1: the pages' capture facts).</summary>
    public const int FormatMinor = 1;
    public const string ManifestName = "manifest.json";
    public const int MaxPages = 2000;
    public const int MaxManifestBytes = 16 * 1024 * 1024;
    /// <summary>The resolution a page gets when its manifest gives none.</summary>
    public const int DefaultDpi = 300;

    // ---- Writing ----

    /// <summary>The package for <paramref name="document"/>; throws <see cref="CompanionPackageException"/> for a document it cannot hold.</summary>
    public static byte[] Make(CompanionDocument document) => ZipStore.Make(Entries(document));

    /// <summary>The entries of the package for <paramref name="document"/>, in package order.</summary>
    public static IReadOnlyList<ZipStoreEntry> Entries(CompanionDocument document)
    {
        Validate(document);
        var entries = new List<ZipStoreEntry> { new(ManifestName, Encoding.UTF8.GetBytes(ManifestJson(document))) };
        for (int i = 0; i < document.Pages.Count; i++)
        {
            var page = document.Pages[i];
            entries.Add(new ZipStoreEntry(ImageEntryName(i + 1, page.Image.Format, false), page.Image.Data));
            if (page.Original is { } original)
            {
                entries.Add(new ZipStoreEntry(ImageEntryName(i + 1, original.Format, true), original.Data));
            }
        }
        var limits = ZipReadLimits.Standard;
        long total = entries.Sum(e => (long)e.Data.Length);
        if (entries[0].Data.Length > MaxManifestBytes || total > limits.MaxTotalBytes
            || entries.Any(e => e.Data.Length > limits.MaxEntryBytes))
        {
            throw new CompanionPackageException(CompanionPackageErrorKind.TooLarge, TooLargeMessage);
        }
        return entries;
    }

    /// <summary>"The document is larger than 512 MB, too large for one package."</summary>
    public static string TooLargeMessage =>
        $"The document is larger than {ZipReadLimits.Standard.MaxTotalBytes / (1024 * 1024)} MB, too large for one package.";

    /// <summary>The manifest's exact text: compact JSON, keys in a fixed order, a line break at the end.</summary>
    public static string ManifestJson(CompanionDocument document)
    {
        var json = new StringBuilder();
        json.Append("{\"format\":").Append(Quote(FormatName));
        json.Append(",\"formatVersion\":").Append(FormatVersion.ToString(CultureInfo.InvariantCulture));
        json.Append(",\"formatMinor\":").Append(FormatMinor.ToString(CultureInfo.InvariantCulture));
        json.Append(",\"writer\":{\"app\":").Append(Quote(document.Writer.App));
        json.Append(",\"appVersion\":").Append(Quote(document.Writer.AppVersion));
        json.Append(",\"platform\":").Append(Quote(document.Writer.Platform)).Append('}');
        if (document.Created is { } created) json.Append(",\"created\":").Append(Quote(FormatDate(created)));
        json.Append(",\"title\":").Append(Quote(document.Title));
        if (document.TaskId is { } taskId) json.Append(",\"taskId\":").Append(Quote(taskId));
        if (document.SuggestedName is not null || document.NamingTemplate is not null)
        {
            json.Append(",\"naming\":{");
            bool first = true;
            if (document.SuggestedName is { } name)
            {
                json.Append("\"suggestedName\":").Append(Quote(name));
                first = false;
            }
            if (document.NamingTemplate is { } template)
            {
                json.Append(first ? "" : ",").Append("\"template\":").Append(Quote(template));
            }
            json.Append('}');
        }
        json.Append(",\"pages\":[");
        for (int i = 0; i < document.Pages.Count; i++)
        {
            var page = document.Pages[i];
            if (i > 0) json.Append(',');
            json.Append("{\"image\":");
            AppendImage(json, page.Image, ImageEntryName(i + 1, page.Image.Format, false));
            json.Append(",\"rotationQuarterTurns\":").Append(Integer(page.RotationQuarterTurns));
            if (page.Side is { } side) json.Append(",\"side\":").Append(Quote(SideName(side)));
            if (page.SheetIndex is { } sheet) json.Append(",\"sheetIndex\":").Append(Integer(sheet));
            if (page.OcrLines is { } lines)
            {
                json.Append(",\"ocrLines\":[");
                for (int k = 0; k < lines.Count; k++)
                {
                    var line = lines[k];
                    if (k > 0) json.Append(',');
                    json.Append("{\"text\":").Append(Quote(line.Text));
                    json.Append(",\"x\":").Append(Number(line.BoundingBox.X));
                    json.Append(",\"y\":").Append(Number(line.BoundingBox.Y));
                    json.Append(",\"width\":").Append(Number(line.BoundingBox.Width));
                    json.Append(",\"height\":").Append(Number(line.BoundingBox.Height));
                    json.Append(",\"confidence\":").Append(Number(line.Confidence)).Append('}');
                }
                json.Append(']');
            }
            if (page.Capture is { } capture) AppendCapture(json, capture);
            if (page.Original is { } original)
            {
                json.Append(",\"original\":");
                AppendImage(json, original, ImageEntryName(i + 1, original.Format, true));
            }
            json.Append('}');
        }
        json.Append("]}\n");
        return json.ToString();
    }

    /// <summary>"pages/0001.jpg", "pages/0001-original.png", "pages/0002.tif".</summary>
    public static string ImageEntryName(int pageNumber, CompanionImageFormat format, bool original) =>
        $"pages/{pageNumber.ToString("D4", CultureInfo.InvariantCulture)}{(original ? "-original" : "")}.{ImageExtension(format)}";

    /// <summary>"jpg", "png", "tif".</summary>
    public static string ImageExtension(CompanionImageFormat format) => format switch
    {
        CompanionImageFormat.Png => "png",
        CompanionImageFormat.Tiff => "tif",
        _ => "jpg",
    };

    /// <summary>The manifest's name for <paramref name="format"/>: "jpeg", "png", "tiff".</summary>
    public static string FormatValue(CompanionImageFormat format) => format switch
    {
        CompanionImageFormat.Png => "png",
        CompanionImageFormat.Tiff => "tiff",
        _ => "jpeg",
    };

    /// <summary>The format the bytes start like (JPEG SOI, PNG signature, TIFF "II*\0" or "MM\0*"); null for anything else.</summary>
    public static CompanionImageFormat? Sniff(ReadOnlySpan<byte> data)
    {
        if (data.Length >= 3 && data[0] == 0xFF && data[1] == 0xD8 && data[2] == 0xFF) return CompanionImageFormat.Jpeg;
        if (data.Length >= 8 && data[..8].SequenceEqual(new byte[] { 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A }))
        {
            return CompanionImageFormat.Png;
        }
        if (data.Length >= 4 && ((data[0] == 0x49 && data[1] == 0x49 && data[2] == 0x2A && data[3] == 0)
                                 || (data[0] == 0x4D && data[1] == 0x4D && data[2] == 0 && data[3] == 0x2A)))
        {
            return CompanionImageFormat.Tiff;
        }
        return null;
    }

    /// <summary>The SHA-256 of <paramref name="data"/> as 64 lowercase hex digits.</summary>
    public static string Sha256Hex(ReadOnlySpan<byte> data) => Convert.ToHexStringLower(SHA256.HashData(data));

    /// <summary>A number as the manifest writes it: rounded half away from zero to 6 decimals, no exponent, no trailing zeros.</summary>
    internal static string Number(double value)
    {
        if (!double.IsFinite(value)) return "0";
        double scaled = Math.Round(value * 1_000_000, MidpointRounding.AwayFromZero);
        if (Math.Abs(scaled) >= 9e15) return "0";
        long units = (long)scaled;
        bool negative = units < 0;
        ulong magnitude = (ulong)Math.Abs(units);
        string text = (magnitude / 1_000_000).ToString(CultureInfo.InvariantCulture);
        ulong fraction = magnitude % 1_000_000;
        if (fraction != 0) text += "." + fraction.ToString("D6", CultureInfo.InvariantCulture).TrimEnd('0');
        return negative ? "-" + text : text;
    }

    /// <summary>A string as a JSON literal: quote, backslash and control characters escaped (\n, \r, \t, \b, \f, else \u00xx), the rest as is.</summary>
    internal static string Quote(string text)
    {
        var json = new StringBuilder(text.Length + 2).Append('"');
        foreach (char c in text)
        {
            switch (c)
            {
                case '"': json.Append("\\\""); break;
                case '\\': json.Append("\\\\"); break;
                case '\n': json.Append("\\n"); break;
                case '\r': json.Append("\\r"); break;
                case '\t': json.Append("\\t"); break;
                case '\b': json.Append("\\b"); break;
                case '\f': json.Append("\\f"); break;
                default:
                    if (c < 0x20) json.Append("\\u00").Append(((int)c).ToString("x2", CultureInfo.InvariantCulture));
                    else json.Append(c);
                    break;
            }
        }
        return json.Append('"').ToString();
    }

    /// <summary>"2026-10-20T08:30:00Z": UTC, to the second.</summary>
    internal static string FormatDate(DateTimeOffset date) =>
        date.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture);

    /// <summary>A date in exactly <see cref="FormatDate"/>'s form; null for anything else.</summary>
    internal static DateTimeOffset? ParseDate(string? text)
    {
        if (text is null || text.Length != 20) return null;
        return DateTimeOffset.TryParseExact(text, "yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture,
                                            DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out var date)
            ? date
            : null;
    }

    private static void Validate(CompanionDocument document)
    {
        if (document.Pages.Count == 0) throw new CompanionPackageException(CompanionPackageErrorKind.NoPages, NoPagesMessage);
        if (document.Pages.Count > MaxPages) throw new CompanionPackageException(CompanionPackageErrorKind.TooManyPages, TooManyPagesMessage);
        for (int i = 0; i < document.Pages.Count; i++)
        {
            var page = document.Pages[i];
            ValidateImage(page.Image, i + 1, false);
            if (page.Original is { } original) ValidateImage(original, i + 1, true);
            if (page.RotationQuarterTurns is < 0 or > 3)
            {
                throw Invalid($"Page {i + 1}'s rotation must be 0 to 3 quarter turns.");
            }
            if (page.SheetIndex is < 0) throw Invalid($"Page {i + 1}'s sheet cannot be negative.");
        }
    }

    private static void ValidateImage(CompanionImage image, int pageNumber, bool original)
    {
        string subject = Subject(pageNumber, original);
        if (Sniff(image.Data) != image.Format)
        {
            throw Invalid($"{subject} is not a {FormatValue(image.Format).ToUpperInvariant()} file.");
        }
        if (image.Format == CompanionImageFormat.Tiff && image.ColorMode != ColorMode.BlackWhite)
        {
            throw Invalid($"{subject} is a TIFF, which only black & white pages can be.");
        }
        if (image.PixelWidth <= 0 || image.PixelHeight <= 0 || image.Dpi <= 0)
        {
            throw Invalid($"{subject} needs a size in pixels and a resolution.");
        }
    }

    private static CompanionPackageException Invalid(string message) => new(CompanionPackageErrorKind.InvalidDocument, message);

    private static void AppendImage(StringBuilder json, CompanionImage image, string file)
    {
        json.Append("{\"file\":").Append(Quote(file));
        json.Append(",\"format\":").Append(Quote(FormatValue(image.Format)));
        json.Append(",\"byteCount\":").Append(image.Data.LongLength.ToString(CultureInfo.InvariantCulture));
        json.Append(",\"sha256\":").Append(Quote(Sha256Hex(image.Data)));
        json.Append(",\"pixelWidth\":").Append(Integer(image.PixelWidth));
        json.Append(",\"pixelHeight\":").Append(Integer(image.PixelHeight));
        json.Append(",\"dpi\":").Append(Integer(image.Dpi));
        json.Append(",\"colorMode\":").Append(Quote(ColorModeName(image.ColorMode))).Append('}');
    }

    private static string Integer(int value) => value.ToString(CultureInfo.InvariantCulture);

    /// <summary>
    /// ,"capture":{"quad":[x, y of the four corners clockwise from the top-left],"sourceWidth",
    /// "sourceHeight","kind"[,"focalLength"][,"scale":{"basis"[,"size"],"dpi","pixelWidth",
    /// "pixelHeight","widthInches","heightInches"}]}.
    /// </summary>
    private static void AppendCapture(StringBuilder json, CaptureFacts capture)
    {
        json.Append(",\"capture\":{\"quad\":[");
        for (int i = 0; i < 4; i++)
        {
            if (i > 0) json.Append(',');
            json.Append(Number(capture.Quad[i].X)).Append(',').Append(Number(capture.Quad[i].Y));
        }
        json.Append("],\"sourceWidth\":").Append(Integer(capture.SourceWidth));
        json.Append(",\"sourceHeight\":").Append(Integer(capture.SourceHeight));
        json.Append(",\"kind\":").Append(Quote(CaptureKindName(capture.Kind)));
        if (capture.FocalLength is { } focalLength) json.Append(",\"focalLength\":").Append(Number(focalLength));
        if (capture.Scale is { } scale)
        {
            json.Append(",\"scale\":{\"basis\":").Append(Quote(ScaleBasisName(scale.Basis)));
            if (scale.Size is { } size) json.Append(",\"size\":").Append(Quote(size));
            json.Append(",\"dpi\":").Append(Integer(scale.Dpi));
            json.Append(",\"pixelWidth\":").Append(Integer(scale.PixelWidth));
            json.Append(",\"pixelHeight\":").Append(Integer(scale.PixelHeight));
            json.Append(",\"widthInches\":").Append(Number(scale.WidthInches));
            json.Append(",\"heightInches\":").Append(Number(scale.HeightInches)).Append('}');
        }
        json.Append('}');
    }

    private static string CaptureKindName(CaptureKind kind) => kind switch
    {
        CaptureKind.Receipt => "receipt",
        CaptureKind.Photo => "photo",
        CaptureKind.IdCard => "idCard",
        _ => "document",
    };

    private static string ScaleBasisName(CaptureScaleBasis basis) => basis switch
    {
        CaptureScaleBasis.Paper => "paper",
        CaptureScaleBasis.ReceiptWidth => "receiptWidth",
        CaptureScaleBasis.PhotoSize => "photoSize",
        _ => "nominal",
    };

    private static string ColorModeName(ColorMode mode) => mode switch
    {
        ColorMode.Grayscale => "grayscale",
        ColorMode.BlackWhite => "blackWhite",
        _ => "color",
    };

    private static string SideName(PageSide side) => side == PageSide.Back ? "back" : "front";

    // ---- Reading ----

    /// <summary>The document in the package <paramref name="data"/>, every picture checked.</summary>
    public static CompanionDocument Read(byte[] data, ZipReadLimits? limits = null)
    {
        using var stream = new MemoryStream(data, writable: false);
        return Read(stream, limits);
    }

    /// <summary>The document in the package file at <paramref name="path"/>.</summary>
    public static CompanionDocument ReadFile(string path, ZipReadLimits? limits = null)
    {
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 81920);
        return Read(stream, limits);
    }

    /// <summary>
    /// The document in the package in <paramref name="stream"/> (readable and seekable, left
    /// open). Throws <see cref="CompanionPackageException"/> for anything it refuses.
    /// </summary>
    public static CompanionDocument Read(Stream stream, ZipReadLimits? limits = null)
    {
        try
        {
            using var reader = ZipStoreReader.Open(stream, limits, leaveOpen: true);
            return Read(reader);
        }
        catch (ZipReadException error)
        {
            throw new CompanionPackageException(CompanionPackageErrorKind.InvalidArchive,
                                                $"This document cannot be opened: {error.Message}", error);
        }
    }

    public static string NotPackageMessage => "This file is not a Lazy Scan document.";
    public static string NoPagesMessage => "This document has no pages.";
    public static string TooManyPagesMessage => $"This document has more than {MaxPages} pages.";
    public static string DamagedManifestMessage => "This document cannot be opened: its list of pages is damaged.";

    /// <summary>"This document was made by a newer version of Lazy Scan (package format 2). Update Lazy Scan to open it."</summary>
    public static string NewerVersionMessage(int version) =>
        $"This document was made by a newer version of Lazy Scan (package format {version}). Update Lazy Scan to open it.";

    /// <summary>"Page 3's picture", "Page 3's original picture".</summary>
    public static string Subject(int pageNumber, bool original) =>
        $"Page {pageNumber}'s {(original ? "original picture" : "picture")}";

    private static CompanionDocument Read(ZipStoreReader reader)
    {
        var manifestEntry = reader.Find(ManifestName)
            ?? throw new CompanionPackageException(CompanionPackageErrorKind.NotPackage, NotPackageMessage);
        if (manifestEntry.Size > MaxManifestBytes)
        {
            throw new CompanionPackageException(CompanionPackageErrorKind.InvalidManifest, DamagedManifestMessage);
        }
        var manifest = DecodeManifest(reader.Read(manifestEntry));
        if (manifest.Format != FormatName || manifest.FormatVersion < 1)
        {
            throw new CompanionPackageException(CompanionPackageErrorKind.NotPackage, NotPackageMessage);
        }
        if (manifest.FormatVersion > FormatVersion)
        {
            throw new CompanionPackageException(CompanionPackageErrorKind.NewerVersion, NewerVersionMessage(manifest.FormatVersion));
        }
        if (manifest.Pages.Count == 0) throw new CompanionPackageException(CompanionPackageErrorKind.NoPages, NoPagesMessage);
        if (manifest.Pages.Count > MaxPages)
        {
            throw new CompanionPackageException(CompanionPackageErrorKind.TooManyPages, TooManyPagesMessage);
        }

        var used = new HashSet<string>(StringComparer.Ordinal);
        var pages = new List<CompanionPage>(manifest.Pages.Count);
        for (int i = 0; i < manifest.Pages.Count; i++)
        {
            var dto = manifest.Pages[i];
            var image = ReadImage(reader, dto.Image, i + 1, false, used);
            var original = dto.Original is null ? null : ReadImage(reader, dto.Original, i + 1, true, used);
            pages.Add(new CompanionPage(image)
            {
                RotationQuarterTurns = dto.RotationQuarterTurns is >= 0 and <= 3 ? dto.RotationQuarterTurns : 0,
                Side = dto.Side switch { "front" => PageSide.Front, "back" => PageSide.Back, _ => null },
                SheetIndex = dto.SheetIndex is >= 0 ? dto.SheetIndex : null,
                OcrLines = dto.OcrLines?.Select(l => new OcrLine(l.Text, new RectD(l.X, l.Y, l.Width, l.Height), (float)l.Confidence)).ToList(),
                Original = original,
                Capture = ReadCapture(dto.Capture),
            });
        }
        return new CompanionDocument(manifest.Title, pages)
        {
            Writer = new CompanionWriterInfo(manifest.Writer.App, manifest.Writer.AppVersion, manifest.Writer.Platform),
            Created = ParseDate(manifest.Created),
            TaskId = manifest.TaskId,
            SuggestedName = manifest.Naming.SuggestedName,
            NamingTemplate = manifest.Naming.Template,
        };
    }

    /// <summary>
    /// The capture facts as a package records them; null when missing or unusable (not four finite
    /// corners, no photo size), so a damaged record costs the page only them. An unknown kind reads as
    /// a document; an unusable scale (no resolution or size) is left out, an unknown basis reads as nominal.
    /// </summary>
    private static CaptureFacts? ReadCapture(CaptureDto? dto)
    {
        if (dto?.Quad is not { Count: 8 } q || dto.SourceWidth <= 0 || dto.SourceHeight <= 0) return null;
        foreach (double value in q)
        {
            if (!double.IsFinite(value)) return null;
        }
        var quad = new Quad(new PointD(q[0], q[1]), new PointD(q[2], q[3]), new PointD(q[4], q[5]), new PointD(q[6], q[7]));
        var kind = dto.Kind switch
        {
            "receipt" => CaptureKind.Receipt,
            "photo" => CaptureKind.Photo,
            "idCard" => CaptureKind.IdCard,
            _ => CaptureKind.Document,
        };
        double? focalLength = dto.FocalLength is { } f && f > 0 && double.IsFinite(f) ? f : null;
        CaptureScaleResult? scale = null;
        if (dto.Scale is { } s && s.Dpi > 0 && s.PixelWidth > 0 && s.PixelHeight > 0
            && s.WidthInches > 0 && double.IsFinite(s.WidthInches) && s.HeightInches > 0 && double.IsFinite(s.HeightInches))
        {
            var basis = s.Basis switch
            {
                "paper" => CaptureScaleBasis.Paper,
                "receiptWidth" => CaptureScaleBasis.ReceiptWidth,
                "photoSize" => CaptureScaleBasis.PhotoSize,
                _ => CaptureScaleBasis.Nominal,
            };
            scale = new CaptureScaleResult(basis, s.Size, s.Dpi, s.PixelWidth, s.PixelHeight, s.WidthInches, s.HeightInches);
        }
        return new CaptureFacts(quad, dto.SourceWidth, dto.SourceHeight) { Kind = kind, FocalLength = focalLength, Scale = scale };
    }

    /// <summary>
    /// The manifest as Swift's JSONDecoder reads it (<see cref="StoreFiles.Decode{T}"/>): UTF-8
    /// with or without a byte-order mark, UTF-16 or UTF-32, valid in that encoding throughout, not null.
    /// </summary>
    private static ManifestDto DecodeManifest(byte[] bytes)
    {
        try
        {
            return StoreFiles.Decode<ManifestDto>(bytes);
        }
        catch (Exception error) when (error is JsonException or InvalidOperationException or NotSupportedException
                                      or ArgumentException)
        {
            throw new CompanionPackageException(CompanionPackageErrorKind.InvalidManifest, DamagedManifestMessage, error);
        }
    }

    private static CompanionImage ReadImage(ZipStoreReader reader, ImageDto? dto, int pageNumber, bool original,
                                            HashSet<string> used)
    {
        string subject = Subject(pageNumber, original);
        if (dto is null || dto.File.Length == 0 || dto.File == ManifestName)
        {
            throw new CompanionPackageException(CompanionPackageErrorKind.MissingImage, $"{subject} is missing from the document.");
        }
        if (!used.Add(dto.File))
        {
            throw new CompanionPackageException(CompanionPackageErrorKind.InvalidManifest,
                                                $"This document cannot be opened: {subject} is listed twice.");
        }
        var entry = reader.Find(dto.File)
            ?? throw new CompanionPackageException(CompanionPackageErrorKind.MissingImage, $"{subject} is missing from the document.");
        string damaged = $"{subject} is damaged: its checksum does not match.";
        if (dto.ByteCount is { } count && count != entry.Size)
        {
            throw new CompanionPackageException(CompanionPackageErrorKind.ChecksumMismatch, damaged);
        }
        byte[] data = reader.Read(entry);
        if (!string.Equals(dto.Sha256, Sha256Hex(data), StringComparison.OrdinalIgnoreCase))
        {
            throw new CompanionPackageException(CompanionPackageErrorKind.ChecksumMismatch, damaged);
        }
        string unsupported = $"{subject} is in a format this version of Lazy Scan cannot read.";
        var format = Sniff(data) ?? throw new CompanionPackageException(CompanionPackageErrorKind.UnsupportedImage, unsupported);
        if (dto.Format is { } named)
        {
            CompanionImageFormat? declared = named switch
            {
                "jpeg" => CompanionImageFormat.Jpeg,
                "png" => CompanionImageFormat.Png,
                "tiff" => CompanionImageFormat.Tiff,
                _ => null,
            };
            if (declared != format) throw new CompanionPackageException(CompanionPackageErrorKind.UnsupportedImage, unsupported);
        }
        return new CompanionImage(data, format, Math.Max(dto.PixelWidth, 0), Math.Max(dto.PixelHeight, 0),
                                  dto.Dpi > 0 ? dto.Dpi : DefaultDpi, dto.ColorMode);
    }

    // The manifest as read: every property on its own and leniently (StoreFiles.JsonOptions), the
    // defaults below for anything missing, null, wrong-typed or unknown. Whole numbers go through
    // WholeNumberConverter so that "1.0" or "3e2" read as Swift's JSONDecoder reads them.

    private sealed class ManifestDto
    {
        public string Format { get; set; } = "";
        [JsonConverter(typeof(WholeNumberConverter))]
        public int FormatVersion { get; set; }
        [JsonConverter(typeof(WholeNumberConverter))]
        public int FormatMinor { get; set; }
        public WriterDto Writer { get; set; } = new();
        public string? Created { get; set; }
        public string Title { get; set; } = "";
        public string? TaskId { get; set; }
        public NamingDto Naming { get; set; } = new();
        public List<PageDto> Pages { get; set; } = [];
    }

    private sealed class WriterDto
    {
        public string App { get; set; } = "";
        public string AppVersion { get; set; } = "";
        public string Platform { get; set; } = "";
    }

    private sealed class NamingDto
    {
        public string? SuggestedName { get; set; }
        public string? Template { get; set; }
    }

    private sealed class PageDto
    {
        public ImageDto? Image { get; set; }
        [JsonConverter(typeof(WholeNumberConverter))]
        public int RotationQuarterTurns { get; set; }
        public string? Side { get; set; }
        [JsonConverter(typeof(WholeNumberConverter))]
        public int? SheetIndex { get; set; }
        public List<OcrLineDto>? OcrLines { get; set; }
        public ImageDto? Original { get; set; }
        public CaptureDto? Capture { get; set; }
    }

    private sealed class CaptureDto
    {
        public List<double>? Quad { get; set; }
        [JsonConverter(typeof(WholeNumberConverter))]
        public int SourceWidth { get; set; }
        [JsonConverter(typeof(WholeNumberConverter))]
        public int SourceHeight { get; set; }
        public string? Kind { get; set; }
        public double? FocalLength { get; set; }
        public ScaleDto? Scale { get; set; }
    }

    private sealed class ScaleDto
    {
        public string? Basis { get; set; }
        public string? Size { get; set; }
        [JsonConverter(typeof(WholeNumberConverter))]
        public int Dpi { get; set; }
        [JsonConverter(typeof(WholeNumberConverter))]
        public int PixelWidth { get; set; }
        [JsonConverter(typeof(WholeNumberConverter))]
        public int PixelHeight { get; set; }
        public double WidthInches { get; set; }
        public double HeightInches { get; set; }
    }

    private sealed class ImageDto
    {
        public string File { get; set; } = "";
        public string? Format { get; set; }
        [JsonConverter(typeof(WholeNumberConverter))]
        public long? ByteCount { get; set; }
        public string Sha256 { get; set; } = "";
        [JsonConverter(typeof(WholeNumberConverter))]
        public int PixelWidth { get; set; }
        [JsonConverter(typeof(WholeNumberConverter))]
        public int PixelHeight { get; set; }
        [JsonConverter(typeof(WholeNumberConverter))]
        public int Dpi { get; set; }
        public ColorMode ColorMode { get; set; } = ColorMode.Color;
    }

    private sealed class OcrLineDto
    {
        public string Text { get; set; } = "";
        public double X { get; set; }
        public double Y { get; set; }
        public double Width { get; set; }
        public double Height { get; set; }
        public double Confidence { get; set; }
    }
}

/// <summary>
/// Reads an int, long or their nullable forms from a JSON number the way Swift's JSONDecoder
/// does: a plain integer in range, or a number written with a fraction or an exponent ("1.0",
/// "3e2") whose value is whole and in range (tried as a double, then as a decimal, as
/// JSONDecoder tries Double and then Decimal). Anything else, strings included, throws, so the
/// lenient property reader falls back to the default. Writes the plain integer.
/// </summary>
internal sealed class WholeNumberConverter : JsonConverterFactory
{
    public override bool CanConvert(Type typeToConvert) =>
        typeToConvert == typeof(int) || typeToConvert == typeof(int?) || typeToConvert == typeof(long) || typeToConvert == typeof(long?);

    public override JsonConverter CreateConverter(Type typeToConvert, JsonSerializerOptions options)
    {
        if (typeToConvert == typeof(int)) return new Int32Converter();
        if (typeToConvert == typeof(int?)) return new NullableConverter<int>(new Int32Converter());
        if (typeToConvert == typeof(long)) return new Int64Converter();
        if (typeToConvert == typeof(long?)) return new NullableConverter<long>(new Int64Converter());
        throw new NotSupportedException($"{typeToConvert.Name} is not a whole-number type.");
    }

    /// <summary>The value of the number token at <paramref name="reader"/> when it is whole and within [min, max].</summary>
    internal static bool TryRead(ref Utf8JsonReader reader, long min, long max, out long value)
    {
        value = 0;
        if (reader.TokenType != JsonTokenType.Number) return false;
        if (reader.TryGetInt64(out long integer))
        {
            value = integer;
            return integer >= min && integer <= max;
        }
        // -2^63 and 2^63 are exact doubles; max + 1 is 2^31 or 2^63.
        if (reader.TryGetDouble(out double number) && double.IsFinite(number) && Math.Floor(number) == number
            && number >= min && number < (double)max + 1)
        {
            value = (long)number;
            return true;
        }
        if (reader.TryGetDecimal(out decimal exact) && decimal.Truncate(exact) == exact && exact >= min && exact <= max)
        {
            value = (long)exact;
            return true;
        }
        return false;
    }

    private sealed class Int32Converter : JsonConverter<int>
    {
        public override int Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) =>
            TryRead(ref reader, int.MinValue, int.MaxValue, out long value)
                ? (int)value
                : throw new JsonException("Not a whole number within Int32.");

        public override void Write(Utf8JsonWriter writer, int value, JsonSerializerOptions options) => writer.WriteNumberValue(value);
    }

    private sealed class Int64Converter : JsonConverter<long>
    {
        public override long Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) =>
            TryRead(ref reader, long.MinValue, long.MaxValue, out long value)
                ? value
                : throw new JsonException("Not a whole number within Int64.");

        public override void Write(Utf8JsonWriter writer, long value, JsonSerializerOptions options) => writer.WriteNumberValue(value);
    }

    private sealed class NullableConverter<T>(JsonConverter<T> inner) : JsonConverter<T?> where T : struct
    {
        public override T? Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) =>
            reader.TokenType == JsonTokenType.Null ? null : inner.Read(ref reader, typeof(T), options);

        public override void Write(Utf8JsonWriter writer, T? value, JsonSerializerOptions options)
        {
            if (value is { } some) inner.Write(writer, some, options);
            else writer.WriteNullValue();
        }
    }
}
