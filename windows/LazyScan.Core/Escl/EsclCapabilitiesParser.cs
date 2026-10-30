using System.Globalization;
using System.Xml;
using System.Xml.Linq;

namespace LazyScan.Core;

// eSCL (AirScan) protocol logic used by LazyScan.App/Scanning/EsclScannerBackend.cs,
// kept in Core so it can be tested against fixture XML (Tests/Fixtures/Escl, shared with the Swift
// suite). Twin of Sources/LazyScanKit/Escl/EsclCapabilities.swift, which the iPhone's eSCL
// connection uses: the same rules and tests on both platforms.

/// <summary>What one eSCL input source (platen, feeder simplex, feeder duplex) offers.</summary>
public sealed class EsclInputCaps
{
    /// <summary>Largest scan area in inches (MaxWidth × MaxHeight); null when not reported.</summary>
    public SizeD? MaxSizeInches { get; init; }
    /// <summary>Smallest scan area in inches (MinWidth × MinHeight); null when not reported.</summary>
    public SizeD? MinSizeInches { get; init; }
    /// <summary>Resolutions after <see cref="ResolutionList.Build"/>: ascending, no duplicates.</summary>
    public IReadOnlyList<int> Resolutions { get; init; } = [];
    /// <summary>eSCL color modes as written by the device, e.g. "RGB24", "Grayscale8", "BlackAndWhite1".</summary>
    public IReadOnlyList<string> ColorModes { get; init; } = [];
    /// <summary>MIME types, e.g. "image/jpeg", "application/pdf".</summary>
    public IReadOnlyList<string> DocumentFormats { get; init; } = [];
}

/// <summary>A parsed eSCL ScannerCapabilities document.</summary>
public sealed class EsclCapabilities
{
    /// <summary>Scan area used when a device reports no platen size (US Letter width, A4 height).</summary>
    public static readonly SizeD DefaultAreaInches = new(8.5, 11.7);
    /// <summary>Resolutions offered when a device lists none.</summary>
    public static readonly IReadOnlyList<int> FallbackResolutions = [75, 150, 200, 300, 600];

    public string? Version { get; init; }
    public string? MakeAndModel { get; init; }
    /// <summary>The device's UUID (scan:UUID), used to recognize it across addresses.</summary>
    public string? Uuid { get; init; }
    public EsclInputCaps? Platen { get; init; }
    public EsclInputCaps? AdfSimplex { get; init; }
    public EsclInputCaps? AdfDuplex { get; init; }
    /// <summary>The feeder scans both sides: AdfDuplexInputCaps, or "Duplex" among the AdfOptions.</summary>
    public bool SupportsDuplex { get; init; }

    public bool HasPlaten => Platen is not null;
    public bool HasAdf => Feeder is not null;
    /// <summary>The feeder's one-sided capabilities (or the two-sided ones when that is all it lists).</summary>
    public EsclInputCaps? Feeder => AdfSimplex ?? AdfDuplex;

    /// <summary>The input capabilities a scan from <paramref name="source"/> uses.</summary>
    public EsclInputCaps? InputCaps(ScanSource source) =>
        source == ScanSource.DocumentFeeder ? Feeder : Platen;

    /// <summary>
    /// The backend-neutral capabilities. Sources are the inputs the device lists (a device
    /// listing neither is treated as a flatbed, as before); the resolution list is the
    /// platen's, or the feeder's on a feeder-only device; the overview needs a platen.
    /// </summary>
    public ScannerCapabilities ToScannerCapabilities()
    {
        bool flatbed = HasPlaten || !HasAdf;
        var sources = new List<ScanSource>();
        if (flatbed) sources.Add(ScanSource.Flatbed);
        if (HasAdf) sources.Add(ScanSource.DocumentFeeder);
        var primary = Platen ?? Feeder;
        return new ScannerCapabilities
        {
            SupportedResolutions = primary is { Resolutions.Count: > 0 }
                ? [.. primary.Resolutions]
                : [.. FallbackResolutions],
            Sources = sources,
            FlatbedSizeInches = Platen?.MaxSizeInches ?? DefaultAreaInches,
            SupportsOverview = flatbed,
            FeederSizeInches = Feeder?.MaxSizeInches,
            SupportsDuplex = SupportsDuplex,
        };
    }
}

public static class EsclCapabilitiesParser
{
    /// <summary>
    /// Parse a ScannerCapabilities document. Elements are matched by local name, so the
    /// namespace prefixes devices use do not matter. Throws <see cref="FormatException"/>
    /// when the text is not XML.
    /// </summary>
    public static EsclCapabilities Parse(string xml)
    {
        XDocument doc;
        try
        {
            doc = XDocument.Parse(xml);
        }
        catch (XmlException e)
        {
            throw new FormatException($"The scanner capabilities are not valid XML: {e.Message}", e);
        }
        var root = doc.Root ?? throw new FormatException("The scanner capabilities document is empty.");

        EsclInputCaps? platen = null;
        if (Child(root, "Platen") is { } platenElement)
        {
            platen = ParseInputCaps(Child(platenElement, "PlatenInputCaps") ?? platenElement);
        }

        EsclInputCaps? simplex = null, duplex = null;
        bool duplexOption = false;
        if (Child(root, "Adf") is { } adf)
        {
            if (Child(adf, "AdfSimplexInputCaps") is { } s) simplex = ParseInputCaps(s);
            if (Child(adf, "AdfDuplexInputCaps") is { } d) duplex = ParseInputCaps(d);
            // An Adf section without input caps still means there is a feeder.
            if (simplex is null && duplex is null) simplex = ParseInputCaps(adf);
            duplexOption = Descendants(adf, "AdfOption").Any(o => o.Value.Trim() == "Duplex");
        }

        return new EsclCapabilities
        {
            Version = Text(Child(root, "Version")),
            MakeAndModel = Text(Child(root, "MakeAndModel")),
            Uuid = Text(Child(root, "UUID")),
            Platen = platen,
            AdfSimplex = simplex,
            AdfDuplex = duplex,
            SupportsDuplex = duplex is not null || duplexOption,
        };
    }

    private static EsclInputCaps ParseInputCaps(XElement caps)
    {
        // Resolutions arrive as discrete values and/or min/max/step ranges; ResolutionList
        // applies the same accuracy rules as the other backends. Only square resolutions are
        // offered, since requests always use the same X and Y resolution.
        var supported = new HashSet<int>();
        foreach (var res in Descendants(caps, "DiscreteResolution"))
        {
            int? x = Int(Child(res, "XResolution")), y = Int(Child(res, "YResolution"));
            if (x is int dpi && (y is null || y == dpi)) supported.Add(dpi);
        }
        foreach (var range in Descendants(caps, "XResolutionRange"))
        {
            if (Int(Child(range, "Min")) is int min && Int(Child(range, "Max")) is int max
                && min > 0 && max >= min)
            {
                supported.UnionWith(ResolutionList.ExpandRange(min, max, Int(Child(range, "Step")) ?? 1));
            }
        }

        var colorModes = Descendants(caps, "ColorMode")
            .Select(e => e.Value.Trim()).Where(v => v.Length > 0).Distinct().ToList();
        // eSCL 2.1+ lists DocumentFormatExt next to the older DocumentFormat.
        var formats = Descendants(caps, "DocumentFormat").Concat(Descendants(caps, "DocumentFormatExt"))
            .Select(e => e.Value.Trim()).Where(v => v.Length > 0)
            .Distinct(StringComparer.OrdinalIgnoreCase).ToList();

        return new EsclInputCaps
        {
            MaxSizeInches = Size(Child(caps, "MaxWidth"), Child(caps, "MaxHeight")),
            MinSizeInches = Size(Child(caps, "MinWidth"), Child(caps, "MinHeight")),
            Resolutions = ResolutionList.Build(preferred: null, supported, nativeResolution: 0),
            ColorModes = colorModes,
            DocumentFormats = formats,
        };
    }

    /// <summary>Dimensions arrive in 1/300ths of an inch.</summary>
    private static SizeD? Size(XElement? width, XElement? height) =>
        Double(width) is double w && Double(height) is double h && w > 0 && h > 0
            ? new SizeD(w / 300.0, h / 300.0)
            : null;

    private static XElement? Child(XElement parent, string localName) =>
        parent.Elements().FirstOrDefault(e => e.Name.LocalName == localName);

    private static IEnumerable<XElement> Descendants(XElement parent, string localName) =>
        parent.Descendants().Where(e => e.Name.LocalName == localName);

    private static string? Text(XElement? element) =>
        element?.Value.Trim() is { Length: > 0 } text ? text : null;

    private static int? Int(XElement? element) =>
        int.TryParse(element?.Value.Trim(), NumberStyles.Integer, CultureInfo.InvariantCulture, out int v) ? v : null;

    private static double? Double(XElement? element) =>
        double.TryParse(element?.Value.Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out double v) ? v : null;
}
