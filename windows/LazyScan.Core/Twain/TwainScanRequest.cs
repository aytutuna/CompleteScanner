namespace LazyScan.Core;

/// <summary>The settings of one TWAIN acquisition, chosen from what the source offers.</summary>
/// <param name="Feeder">Scan from the document feeder (CAP_FEEDERENABLED, CAP_AUTOFEED).</param>
/// <param name="PixelType">A <see cref="TwainPixelTypes"/> value.</param>
/// <param name="BitDepth">ICAP_BITDEPTH: bits per sample (1 for black &amp; white, 8 otherwise).</param>
/// <param name="Resolution">Dots per inch, one the source lists when it lists any.</param>
/// <param name="FrameInches">DAT_IMAGELAYOUT frame in inches, origin top-left; null leaves the source's own.</param>
/// <param name="TransferCount">CAP_XFERCOUNT: -1 (as many as the source sends: a feeder batch, or whatever the driver's window starts) or 1.</param>
/// <param name="ShowDriverWindow">Scan through the source's own settings window; the other values are only its starting point.</param>
/// <param name="PreferMemory">Use memory transfers when the source and format allow them; otherwise native.</param>
/// <param name="Duplex">CAP_DUPLEXENABLED: scan both sides of each sheet (feeder scans on a two-sided feeder only). Images then alternate front, back.</param>
/// <param name="SupportedSize">
/// ICAP_SUPPORTEDSIZES to ask for (a <see cref="TwainSizes"/> value the source lists), which
/// takes the place of <paramref name="FrameInches"/>; <see cref="TwainSizes.None"/> uses the frame.
/// </param>
public sealed record TwainScanRequest(bool Feeder, int PixelType, int BitDepth, int Resolution, RectD? FrameInches,
                                      int TransferCount, bool ShowDriverWindow, bool PreferMemory,
                                      bool Duplex = false, int SupportedSize = TwainSizes.None)
{
    /// <summary>The color mode of the pages this request produces.</summary>
    public ColorMode ColorMode => PixelType switch
    {
        TwainPixelTypes.BlackWhite => ColorMode.BlackWhite,
        TwainPixelTypes.Gray => ColorMode.Grayscale,
        _ => ColorMode.Color,
    };
}

/// <summary>Turns what a TWAIN source offers into the app's capabilities and scan requests.</summary>
public static class TwainScanRequests
{
    /// <summary>Resolutions offered when a source lists none.</summary>
    public static readonly IReadOnlyList<int> FallbackResolutions = [75, 150, 200, 300, 600];

    /// <summary>Flatbed size assumed when a source does not report one (US letter by A4 length, like the other backends).</summary>
    public static readonly SizeD DefaultBedInches = new(8.5, 11.7);

    /// <summary>
    /// The app-facing capabilities: the sources the device really has (a feeder-only scanner
    /// offers no flatbed and so no preview, nor does one that cannot scan without its own
    /// window), its resolutions up to the optical one, the bed and feeder sizes (the
    /// feeder's from its sizes list when it reports no physical size), and whether the feeder
    /// scans both sides.
    /// </summary>
    public static ScannerCapabilities Capabilities(TwainDeviceCaps caps)
    {
        var sources = new List<ScanSource>();
        if (caps.HasFlatbed) sources.Add(ScanSource.Flatbed);
        if (caps.HasFeeder) sources.Add(ScanSource.DocumentFeeder);
        if (sources.Count == 0) sources.Add(ScanSource.Flatbed);
        var resolutions = ResolutionList.Build(preferred: null, caps.Resolutions, caps.NativeResolution);
        return new ScannerCapabilities
        {
            Sources = sources,
            SupportsOverview = sources.Contains(ScanSource.Flatbed) && caps.UIControllable,
            SupportedResolutions = resolutions.Count > 0 ? resolutions : [.. FallbackResolutions],
            FlatbedSizeInches = caps.FlatbedSizeInches ?? DefaultBedInches,
            FeederSizeInches = caps.HasFeeder ? caps.FeederSizeInches ?? TwainSizes.Largest(caps.SupportedSizes) : null,
            SupportsDuplex = caps.HasFeeder && caps.DuplexKind != TwainDuplexKinds.None,
        };
    }

    /// <summary>
    /// The request for a scan.
    /// <list type="bullet">
    /// <item>The feeder is used when asked for, or when the device has no flatbed.</item>
    /// <item>Color is 24-bit RGB, grayscale 8-bit gray, black &amp; white 1-bit (scanners
    /// threshold documents well and feeder batches stay small); a pixel type the source does
    /// not list falls back to the next richer one.</item>
    /// <item>The resolution snaps to the nearest one the source lists.</item>
    /// <item>Flatbed: the whole bed or <paramref name="selection"/> (normalized 0...1,
    /// top-left origin) of it. Feeder: the paper size, clamped to its largest sheet (as a
    /// TWSS size when the source lists that size); for Automatic its own largest sheet, at most
    /// <see cref="EsclScanRequest.MaxFeederHeightInches"/> tall, like the other backends.</item>
    /// <item>Two-sided when asked for (<see cref="DuplexMode.Both"/>) on a feeder that can (CAP_DUPLEX).</item>
    /// <item>The source's own window is used when asked for or when the source cannot scan without it.
    /// The user may switch to the feeder there, so the app then accepts any number of images.</item>
    /// </list>
    /// </summary>
    public static TwainScanRequest ForScan(ScanSettings settings, RectD? selection, TwainDeviceCaps caps,
                                           bool showDriverWindow = false, bool preferNative = false)
    {
        bool feeder = caps.HasFeeder && (settings.Source == ScanSource.DocumentFeeder || !caps.HasFlatbed);
        int pixelType = PickPixelType(settings.ColorMode, caps.PixelTypes);
        var bed = caps.FlatbedSizeInches ?? DefaultBedInches;
        RectD? frame;
        int supportedSize = TwainSizes.None;
        if (feeder)
        {
            var sheet = caps.FeederSizeInches ?? TwainSizes.Largest(caps.SupportedSizes);
            if (PaperSizes.Inches(settings.PaperSize) is { } paper)
            {
                var region = PaperSizes.FeederRegionInches(settings.PaperSize, sheet ?? paper);
                frame = new RectD(0, 0, region.Width, Math.Min(region.Height, EsclScanRequest.MaxFeederHeightInches));
                int listed = TwainSizes.FromPaperSize(settings.PaperSize);
                if (listed != TwainSizes.None && caps.SupportedSizes.Contains(listed)) supportedSize = listed;
            }
            else
            {
                frame = sheet is { } size
                    ? new RectD(0, 0, size.Width, Math.Min(size.Height, EsclScanRequest.MaxFeederHeightInches))
                    : null;
            }
        }
        else
        {
            frame = Frame(bed, selection);
        }
        bool driverWindow = showDriverWindow || !caps.UIControllable;
        return new TwainScanRequest(
            Feeder: feeder,
            PixelType: pixelType,
            BitDepth: pixelType == TwainPixelTypes.BlackWhite ? 1 : 8,
            Resolution: Nearest(caps.Resolutions, settings.Resolution),
            FrameInches: frame,
            TransferCount: feeder || driverWindow ? -1 : 1,
            ShowDriverWindow: driverWindow,
            PreferMemory: caps.MemoryTransfer && !preferNative,
            Duplex: feeder && settings.Duplex == DuplexMode.Both && caps.DuplexKind != TwainDuplexKinds.None,
            SupportedSize: supportedSize);
    }

    /// <summary>The request for a preview: the whole flatbed in color at <see cref="OverviewResolution"/>, never through the driver's window.</summary>
    public static TwainScanRequest ForOverview(TwainDeviceCaps caps, bool preferNative = false)
    {
        var bed = caps.FlatbedSizeInches ?? DefaultBedInches;
        int pixelType = PickPixelType(ColorMode.Color, caps.PixelTypes);
        return new TwainScanRequest(
            Feeder: false,
            PixelType: pixelType,
            BitDepth: pixelType == TwainPixelTypes.BlackWhite ? 1 : 8,
            Resolution: OverviewResolution(caps.Resolutions),
            FrameInches: new RectD(0, 0, bed.Width, bed.Height),
            TransferCount: 1,
            ShowDriverWindow: false,
            PreferMemory: caps.MemoryTransfer && !preferNative);
    }

    /// <summary>
    /// A preview resolution: the listed one between 75 and 150 dpi nearest to 100, else the
    /// smallest above 150, else the largest listed; 100 when the source lists none.
    /// </summary>
    public static int OverviewResolution(IReadOnlyList<int> resolutions)
    {
        var listed = resolutions.Where(r => r > 0).ToList();
        if (listed.Count == 0) return 100;
        var inBand = listed.Where(r => r is >= 75 and <= 150).ToList();
        if (inBand.Count > 0) return inBand.MinBy(r => (Math.Abs(r - 100), r));
        var above = listed.Where(r => r > 150).ToList();
        return above.Count > 0 ? above.Min() : listed.Max();
    }

    /// <summary>
    /// The transfer mechanism for a negotiated format: memory when the source offers it, the
    /// request prefers it and <see cref="TwainImageAssembler"/> reads the format; native otherwise.
    /// </summary>
    public static int TransferMechanism(bool memoryOffered, bool preferMemory, int pixelType, int bitDepth) =>
        memoryOffered && preferMemory && TwainRaster.CanAssemble(pixelType, TwainRaster.BitsPerPixel(pixelType, bitDepth))
            ? TwainTransferMechanisms.Memory
            : TwainTransferMechanisms.Native;

    private static int PickPixelType(ColorMode mode, IReadOnlyList<int> offered)
    {
        int[] preference = mode switch
        {
            ColorMode.BlackWhite => [TwainPixelTypes.BlackWhite, TwainPixelTypes.Gray, TwainPixelTypes.Rgb],
            ColorMode.Grayscale => [TwainPixelTypes.Gray, TwainPixelTypes.Rgb, TwainPixelTypes.BlackWhite],
            _ => [TwainPixelTypes.Rgb, TwainPixelTypes.Gray, TwainPixelTypes.BlackWhite],
        };
        if (offered.Count == 0) return preference[0];
        foreach (int type in preference)
        {
            if (offered.Contains(type)) return type;
        }
        return preference[0];
    }

    private static int Nearest(IReadOnlyList<int> listed, int dpi)
    {
        var positive = listed.Where(r => r > 0).ToList();
        return positive.Count == 0 ? dpi : positive.MinBy(r => (Math.Abs(r - dpi), r));
    }

    private static RectD Frame(SizeD bed, RectD? selection)
    {
        if (selection is { } sel)
        {
            var clamped = sel.Standardized.Intersection(new RectD(0, 0, 1, 1));
            if (clamped.Width > 0.001 && clamped.Height > 0.001)
            {
                return new RectD(clamped.X * bed.Width, clamped.Y * bed.Height,
                                 clamped.Width * bed.Width, clamped.Height * bed.Height);
            }
        }
        return new RectD(0, 0, bed.Width, bed.Height);
    }
}
