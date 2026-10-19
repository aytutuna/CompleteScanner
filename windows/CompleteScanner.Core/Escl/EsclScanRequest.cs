using System.Globalization;
using System.Text;

namespace CompleteScanner.Core;

/// <summary>A scan region in eSCL units (1/300 inch), origin top-left.</summary>
public readonly record struct EsclRegion(int XOffset, int YOffset, int Width, int Height);

/// <summary>
/// The settings of one eSCL scan job, chosen from what the device offers, and the
/// ScanSettings document that requests them.
/// </summary>
public sealed class EsclScanRequest
{
    /// <summary>
    /// Tallest default feeder region, in inches (tabloid / ledger). Feeders that also take long
    /// paper report heights of several feet; asking for that much could produce one enormous
    /// image per sheet.
    /// </summary>
    public const double MaxFeederHeightInches = 17;

    /// <summary>"Platen" or "Feeder".</summary>
    public required string InputSource { get; init; }
    /// <summary>eSCL color mode, e.g. "RGB24" or "Grayscale8". Never "BlackAndWhite1": see <see cref="Create"/>.</summary>
    public required string ColorMode { get; init; }
    public required string DocumentFormat { get; init; }
    public required int Resolution { get; init; }
    public required EsclRegion Region { get; init; }
    /// <summary>Scan both sides of each sheet (feeder jobs on a device with a two-sided feeder only).</summary>
    public bool Duplex { get; init; }

    /// <summary>
    /// Choose the job settings for a scan.
    /// <list type="bullet">
    /// <item>Flatbed: the whole platen, or <paramref name="selection"/> (normalized 0...1,
    /// top-left origin) of it.</item>
    /// <item>Feeder: <paramref name="paperSize"/> from the top-left corner, clamped to the
    /// feeder's largest sheet; for Automatic the feeder's own maximum sheet size (height capped
    /// at <see cref="MaxFeederHeightInches"/>). The selection is ignored.</item>
    /// <item>Two-sided (<paramref name="duplex"/>): only for feeder jobs on a device that lists
    /// two-sided feeding; the job then uses the feeder's two-sided capabilities when it lists
    /// them separately.</item>
    /// <item>Black &amp; white is requested as 8-bit grayscale: most devices reject 1-bit
    /// JPEG, and the app's image pipeline thresholds the page afterwards, as it does for
    /// every non-color scan.</item>
    /// <item>The resolution snaps to the nearest one the input offers.</item>
    /// <item>The format is JPEG, else PNG, else TIFF, whichever the input offers first.</item>
    /// </list>
    /// </summary>
    public static EsclScanRequest Create(EsclCapabilities caps, ScanSource source, ColorMode colorMode,
                                         int dpi, RectD? selection, bool duplex = false,
                                         PaperSize paperSize = PaperSize.Auto)
    {
        bool feeder = source == ScanSource.DocumentFeeder;
        bool twoSided = feeder && duplex && caps.SupportsDuplex;
        var input = twoSided ? caps.AdfDuplex ?? caps.Feeder : caps.InputCaps(source);

        SizeD area;
        if (feeder)
        {
            var max = input?.MaxSizeInches ?? caps.Feeder?.MaxSizeInches ?? caps.Platen?.MaxSizeInches
                      ?? EsclCapabilities.DefaultAreaInches;
            var paper = PaperSizes.FeederRegionInches(paperSize, max);
            area = new SizeD(paper.Width, Math.Min(paper.Height, MaxFeederHeightInches));
        }
        else
        {
            area = caps.Platen?.MaxSizeInches ?? EsclCapabilities.DefaultAreaInches;
        }
        var region = MakeRegion(area, input?.MinSizeInches, feeder ? null : selection);

        int resolution = dpi;
        if (input is { Resolutions.Count: > 0 } withResolutions)
        {
            resolution = withResolutions.Resolutions.MinBy(r => Math.Abs(r - dpi));
        }

        string[] colorPreference = colorMode == Core.ColorMode.Color
            ? ["RGB24"]
            : ["Grayscale8", "RGB24"];
        string[] formatPreference = ["image/jpeg", "image/png", "image/tiff"];

        return new EsclScanRequest
        {
            InputSource = feeder ? "Feeder" : "Platen",
            ColorMode = Pick(colorPreference, input?.ColorModes, StringComparer.Ordinal),
            DocumentFormat = Pick(formatPreference, input?.DocumentFormats, StringComparer.OrdinalIgnoreCase),
            Resolution = resolution,
            Region = region,
            Duplex = twoSided,
        };
    }

    /// <summary>The first preferred value the device offers; the first preference when it lists nothing usable.</summary>
    private static string Pick(string[] preference, IReadOnlyList<string>? offered, StringComparer comparer)
    {
        if (offered is null || offered.Count == 0) return preference[0];
        return preference.FirstOrDefault(p => offered.Contains(p, comparer)) ?? preference[0];
    }

    private static EsclRegion MakeRegion(SizeD area, SizeD? minimum, RectD? selection)
    {
        int fullWidth = Math.Max(1, (int)Math.Round(area.Width * 300));
        int fullHeight = Math.Max(1, (int)Math.Round(area.Height * 300));
        if (selection is not { } sel) return new EsclRegion(0, 0, fullWidth, fullHeight);

        var clamped = sel.Standardized.Intersection(new RectD(0, 0, 1, 1));
        if (clamped.Width <= 0.001 || clamped.Height <= 0.001) return new EsclRegion(0, 0, fullWidth, fullHeight);

        // Devices state the minimum in whole 1/300 inch units, so rounding recovers it exactly.
        int minWidth = minimum is { } min ? (int)Math.Round(min.Width * 300) : 1;
        int minHeight = minimum is { } minH ? (int)Math.Round(minH.Height * 300) : 1;
        var (x, width) = Span(clamped.MinX, clamped.Width, fullWidth, minWidth);
        var (y, height) = Span(clamped.MinY, clamped.Height, fullHeight, minHeight);
        return new EsclRegion(x, y, width, height);
    }

    /// <summary>
    /// One axis of a selection in 1/300 inch: never past the far edge (rounding could
    /// otherwise overshoot the device maximum by one unit) and never under the device minimum.
    /// </summary>
    private static (int Offset, int Length) Span(double start, double length, int full, int minimum)
    {
        int offset = Math.Clamp((int)Math.Round(start * full), 0, full - 1);
        int size = Math.Max(1, (int)Math.Round(length * full));
        size = Math.Min(size, full - offset);
        int floor = Math.Min(Math.Max(1, minimum), full);
        if (size < floor)
        {
            size = floor;
            offset = Math.Min(offset, full - size);
        }
        return (offset, size);
    }

    /// <summary>The eSCL ScanSettings document for this job (UTF-8 text, "\n" line breaks).</summary>
    public string ToXml()
    {
        static string N(int value) => value.ToString(CultureInfo.InvariantCulture);
        var xml = new StringBuilder();
        void Line(string text) => xml.Append(text).Append('\n');
        Line("""<?xml version="1.0" encoding="UTF-8"?>""");
        Line("""<scan:ScanSettings xmlns:scan="http://schemas.hp.com/imaging/escl/2011/05/03" xmlns:pwg="http://www.pwg.org/schemas/2010/12/sm">""");
        Line("  <pwg:Version>2.0</pwg:Version>");
        Line("  <pwg:ScanRegions>");
        Line("    <pwg:ScanRegion>");
        Line("      <pwg:ContentRegionUnits>escl:ThreeHundredthsOfInches</pwg:ContentRegionUnits>");
        Line($"      <pwg:XOffset>{N(Region.XOffset)}</pwg:XOffset>");
        Line($"      <pwg:YOffset>{N(Region.YOffset)}</pwg:YOffset>");
        Line($"      <pwg:Width>{N(Region.Width)}</pwg:Width>");
        Line($"      <pwg:Height>{N(Region.Height)}</pwg:Height>");
        Line("    </pwg:ScanRegion>");
        Line("  </pwg:ScanRegions>");
        Line($"  <pwg:InputSource>{InputSource}</pwg:InputSource>");
        Line($"  <scan:ColorMode>{Escape(ColorMode)}</scan:ColorMode>");
        Line($"  <scan:XResolution>{N(Resolution)}</scan:XResolution>");
        Line($"  <scan:YResolution>{N(Resolution)}</scan:YResolution>");
        // After the resolutions, where sane-airscan writes it; left out for one-sided jobs.
        if (Duplex) Line("  <scan:Duplex>true</scan:Duplex>");
        Line($"  <pwg:DocumentFormat>{Escape(DocumentFormat)}</pwg:DocumentFormat>");
        Line("</scan:ScanSettings>");
        return xml.ToString();
    }

    private static string Escape(string text) =>
        text.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;");
}

/// <summary>Addresses of an eSCL scan job.</summary>
public static class EsclJob
{
    /// <summary>
    /// The job's address from the Location header of the ScanJobs response. Devices send an
    /// absolute URL, a host-relative path ("/eSCL/ScanJobs/12") or a path relative to the
    /// ScanJobs URL ("ScanJobs/12"); a trailing slash is dropped so "/NextDocument" can be
    /// appended. null when the header is missing or unusable.
    /// </summary>
    public static Uri? ResolveLocation(Uri scanJobsUri, string? location)
    {
        string value = location?.Trim() ?? "";
        if (value.Length == 0) return null;
        Uri? resolved;
        if (value.StartsWith('/') && !value.StartsWith("//", StringComparison.Ordinal))
        {
            // Build host-relative paths by hand: on Unix a bare "/path" parses as a file URI.
            resolved = Uri.TryCreate(scanJobsUri.GetLeftPart(UriPartial.Authority) + value, UriKind.Absolute, out var u)
                ? u : null;
        }
        else if (Uri.TryCreate(value, UriKind.Absolute, out var absolute)
                 && (absolute.Scheme == Uri.UriSchemeHttp || absolute.Scheme == Uri.UriSchemeHttps))
        {
            resolved = absolute;
        }
        else
        {
            resolved = Uri.TryCreate(scanJobsUri, value, out var relative) ? relative : null;
        }
        if (resolved is null) return null;
        string text = resolved.AbsoluteUri;
        return text.EndsWith('/') ? new Uri(text.TrimEnd('/')) : resolved;
    }

    /// <summary>The URL that delivers the job's next page.</summary>
    public static Uri NextDocument(Uri job) => new(job.AbsoluteUri.TrimEnd('/') + "/NextDocument");
}
