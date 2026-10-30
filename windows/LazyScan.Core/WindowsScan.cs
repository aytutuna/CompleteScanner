using System.Globalization;
using System.Text;

namespace LazyScan.Core;

// The Windows Scan connection (Windows.Devices.Scanners, the WinRT ImageScanner API over the
// same WIA 2.0 drivers): a backup to the WIA Automation connection, chosen in the connection
// chooser. What the app's adapter (LazyScan.App/Scanning/WinRtScannerBackend.cs) needs
// to decide, kept here so it can be unit-tested: the App cannot be referenced by the Core
// tests. The enums mirror the WinRT ones by name and value, so Core stays free of WinRT.
// Windows only, so there is no Swift twin.

/// <summary>How entries of the Windows Scan connection appear in the device list.</summary>
public static class WindowsScanConnection
{
    /// <summary><see cref="ScannerInfo.Backend"/> of a scanner reached through Windows Scan.</summary>
    public const string Backend = "winrt";

    /// <summary>
    /// <see cref="ScannerInfo.Transport"/> of those entries. <see cref="DeviceMerge.ConnectionLabel"/>
    /// shows it in the connection chooser ("via Windows Scan (backup)"), and the connection ranks
    /// after every connection <see cref="DeviceMerge.WindowsRanking"/> lists (it lists no
    /// "winrt"), so WIA Automation stays the one used unless the user picks this one or it is
    /// the only connection left to the scanner.
    /// </summary>
    public const string Transport = "Windows Scan (backup)";

    public const string IdPrefix = "winrt:";

    /// <summary>The device-list entry of a Windows Scan device: its name as Windows gives it ("Scanner" when it gives none).</summary>
    public static ScannerInfo Info(string deviceId, string? name) =>
        new(IdPrefix + deviceId, string.IsNullOrWhiteSpace(name) ? "Scanner" : name.Trim(), Transport, Backend: Backend);

    /// <summary>The Windows device id inside a device-list id; null when the id is not a Windows Scan one.</summary>
    public static string? DeviceId(string id) =>
        id.StartsWith(IdPrefix, StringComparison.Ordinal) && id.Length > IdPrefix.Length ? id[IdPrefix.Length..] : null;
}

/// <summary>Mirrors <c>Windows.Devices.Scanners.ImageScannerScanSource</c> (same names and values).</summary>
public enum WindowsScanSource
{
    Default = 0,
    Flatbed = 1,
    Feeder = 2,
    /// <summary>The device picks the source and its settings itself (it offers neither a flatbed nor a feeder to configure).</summary>
    AutoConfigured = 3,
}

/// <summary>Mirrors <c>Windows.Devices.Scanners.ImageScannerColorMode</c> (same names and values).</summary>
public enum WindowsScanColorMode
{
    Color = 0,
    Grayscale = 1,
    /// <summary>One bit per pixel: black and white.</summary>
    Monochrome = 2,
    AutoColor = 3,
}

/// <summary>Mirrors <c>Windows.Devices.Scanners.ImageScannerFormat</c> (same names and values).</summary>
public enum WindowsScanFormat
{
    Jpeg = 0,
    Png = 1,
    DeviceIndependentBitmap = 2,
    Tiff = 3,
    Xps = 4,
    OpenXps = 5,
    Pdf = 6,
}

/// <summary>
/// What one scan source of a Windows Scan device reports (its <c>FlatbedConfiguration</c> or
/// <c>FeederConfiguration</c>): resolutions in dpi, areas in inches, and what it supports.
/// </summary>
public sealed record WindowsScanSourceFacts
{
    /// <summary><see cref="ScanSource.Flatbed"/> or <see cref="ScanSource.DocumentFeeder"/>.</summary>
    public ScanSource Source { get; init; }
    public double MinDpi { get; init; }
    public double MaxDpi { get; init; }
    /// <summary>The optical resolution; values above it are interpolated. 0 when unknown.</summary>
    public double OpticalDpi { get; init; }
    public SizeD MinScanAreaInches { get; init; }
    /// <summary>The glass, or the feeder's largest sheet; zero when unknown.</summary>
    public SizeD MaxScanAreaInches { get; init; }
    public IReadOnlyList<WindowsScanColorMode> ColorModes { get; init; } = [];
    public IReadOnlyList<WindowsScanFormat> Formats { get; init; } = [];
    /// <summary>The device makes a quick preview of this source (<c>IsPreviewSupported</c>).</summary>
    public bool PreviewSupported { get; init; }
    /// <summary>Feeder only: it scans both sides in one pass.</summary>
    public bool CanScanDuplex { get; init; }
    /// <summary>Feeder only: it can measure each sheet itself.</summary>
    public bool CanAutoDetectPageSize { get; init; }
    /// <summary>Feeder only: the paper sizes it takes by name (portrait).</summary>
    public IReadOnlyList<PaperSize> PageSizes { get; init; } = [];

    /// <summary>The resolutions to offer (<see cref="ResolutionList.FromBounds"/>).</summary>
    public List<int> Resolutions =>
        ResolutionList.FromBounds(WindowsScanRequest.Dpi(MinDpi), WindowsScanRequest.Dpi(MaxDpi), WindowsScanRequest.Dpi(OpticalDpi));

    /// <summary>One line for the device diagnostics, e.g. "flatbed: 50-1200 dpi (optical 600), up to 8.50 x 11.69 in, Color Grayscale, Png Jpeg, preview".</summary>
    public string Describe()
    {
        var text = new StringBuilder(Source == ScanSource.DocumentFeeder ? "feeder: " : "flatbed: ");
        text.Append(CultureInfo.InvariantCulture,
                    $"{WindowsScanRequest.Dpi(MinDpi)}-{WindowsScanRequest.Dpi(MaxDpi)} dpi (optical {WindowsScanRequest.Dpi(OpticalDpi)})");
        text.Append(CultureInfo.InvariantCulture,
                    $", up to {MaxScanAreaInches.Width:0.00} x {MaxScanAreaInches.Height:0.00} in");
        text.Append(", colors ").Append(ColorModes.Count > 0 ? string.Join(' ', ColorModes) : "none listed");
        text.Append(", formats ").Append(Formats.Count > 0 ? string.Join(' ', Formats) : "none listed");
        if (PreviewSupported) text.Append(", preview");
        if (Source == ScanSource.DocumentFeeder)
        {
            if (CanScanDuplex) text.Append(", two-sided");
            if (CanAutoDetectPageSize) text.Append(", detects page size");
            text.Append(", sizes ").Append(PageSizes.Count > 0 ? string.Join(' ', PageSizes) : "none listed");
        }
        return text.ToString();
    }
}

/// <summary>The shared <see cref="ScannerCapabilities"/> of a Windows Scan device.</summary>
public static class WindowsScanCapabilities
{
    /// <summary>Offered when the device reports no usable resolution bounds; the scan snaps to what it accepts.</summary>
    public static readonly IReadOnlyList<int> FallbackResolutions = [75, 150, 200, 300, 600, 1200];

    /// <summary>
    /// The capabilities from the sources the device has (null for a source it lacks). A device
    /// with neither picks its source itself (<see cref="WindowsScanSource.AutoConfigured"/>):
    /// it is offered as a flatbed without a preview. Resolutions are the flatbed's (the feeder's
    /// on a feeder-only device), like the WIA connection's.
    /// </summary>
    public static ScannerCapabilities Map(WindowsScanSourceFacts? flatbed, WindowsScanSourceFacts? feeder)
    {
        var caps = new ScannerCapabilities();
        var sources = new List<ScanSource>();
        if (flatbed is not null) sources.Add(ScanSource.Flatbed);
        if (feeder is not null) sources.Add(ScanSource.DocumentFeeder);
        if (sources.Count == 0) sources.Add(ScanSource.Flatbed);
        caps.Sources = sources;
        caps.SupportsOverview = flatbed is not null;

        var main = flatbed ?? feeder;
        var resolutions = main?.Resolutions ?? [];
        caps.SupportedResolutions = resolutions.Count > 0 ? resolutions : [.. FallbackResolutions];
        if (flatbed is not null && Positive(flatbed.MaxScanAreaInches)) caps.FlatbedSizeInches = flatbed.MaxScanAreaInches;
        if (feeder is not null)
        {
            caps.FeederSizeInches = Positive(feeder.MaxScanAreaInches) ? feeder.MaxScanAreaInches : null;
            caps.SupportsDuplex = feeder.CanScanDuplex;
        }
        return caps;
    }

    internal static bool Positive(SizeD size) => size.Width > 0 && size.Height > 0;
}

/// <summary>
/// What one Windows Scan scan asks of the device. Null members are left as the device has them.
/// </summary>
/// <param name="Dpi">Both directions.</param>
/// <param name="RegionInches">
/// The area to scan, in inches from the top-left corner of the glass or sheet. A feeder plan
/// always states it when the feeder's size is known (the whole feeder unless the paper is asked
/// for as an area), because the device keeps an area set by an earlier scan of the session.
/// When the size is unknown, see <see cref="SetsFeederArea"/>.
/// </param>
/// <param name="Duplex">Feeder: scan both sides of each sheet.</param>
/// <param name="PageSize">Feeder: the paper size to ask for by name.</param>
/// <param name="AutoDetectPageSize">Feeder: let it measure each sheet (only set when it can).</param>
public sealed record WindowsScanPlan(WindowsScanSource Source, int Dpi, WindowsScanColorMode? ColorMode,
                                     WindowsScanFormat? Format, RectD? RegionInches, bool Duplex = false,
                                     PaperSize? PageSize = null, bool? AutoDetectPageSize = null)
{
    /// <summary>
    /// The region is set before the paper size or measuring: it is then the whole feeder and
    /// only clears an area an earlier scan set, and setting it afterwards would override what
    /// they ask for. A region that is the paper's area is set last.
    /// </summary>
    public bool RegionFirst => PageSize is not null || AutoDetectPageSize == true;

    /// <summary>
    /// Feeder: the plan sets the area to scan, as a region or a paper size by name. One that
    /// sets neither (the feeder's size is unknown, and Automatic or a size it does not take by
    /// name is asked for) has the session first put back the page size and area the feeder had
    /// before the session changed them, so an earlier scan's paper size does not stay.
    /// </summary>
    public bool SetsFeederArea => PageSize is not null || RegionInches is not null;
}

/// <summary>
/// Whether a refusal from opening a Windows Scan device means Windows refuses the API to this
/// app, so the connection is hidden. Once any device has opened, the API works and nothing
/// hides it. Before that, the codes only the API gives (no package identity, an edition without
/// it) hide it at once; an access denial can also come from one device (its driver refusing,
/// the device held by another program), so it hides the connection only once every device the
/// watcher lists has refused: one scanner refusing does not take the others with it. Not
/// thread-safe: the backend calls it under its lock.
/// </summary>
public sealed class WindowsScanAccess
{
    private readonly HashSet<string> _denied = new(StringComparer.Ordinal);

    /// <summary>A device has opened since the connection was made.</summary>
    public bool AnyOpened { get; private set; }

    /// <summary>A device opened: from now on no error hides the connection.</summary>
    public void Opened()
    {
        AnyOpened = true;
        _denied.Clear();
    }

    /// <summary>The watcher starts again: the access denials so far are forgotten.</summary>
    public void Restart() => _denied.Clear();

    /// <summary>
    /// Opening <paramref name="deviceId"/> failed with <paramref name="hresult"/>: whether that
    /// hides the connection. <paramref name="listed"/> are the ids of the devices the watcher lists now.
    /// </summary>
    public bool HidesConnection(string deviceId, int hresult, IEnumerable<string> listed)
    {
        if (AnyOpened || !WindowsScanErrors.UnavailableToThisApp(hresult)) return false;
        if (unchecked((uint)hresult) != WindowsScanErrors.AccessDenied) return true;
        _denied.Add(deviceId);
        return listed.All(_denied.Contains);
    }
}

/// <summary>What happens to a feeder batch the device stopped with an error.</summary>
public enum WindowsScanFailureOutcome
{
    /// <summary>Nothing worth keeping, or the user cancelled: the scan fails with the error.</summary>
    Fail,
    /// <summary>The feeder ran out after some sheets: the batch simply ended.</summary>
    Finished,
    /// <summary>A jam or another problem after some sheets: they are kept and the reason is told.</summary>
    Stopped,
}

/// <summary>Turns the app's settings into a <see cref="WindowsScanPlan"/>.</summary>
public static class WindowsScanRequest
{
    /// <summary>The resolution of an overview scan when the device makes no preview of its own (the WIA connection's).</summary>
    public const int OverviewDpi = 150;

    /// <summary>File formats to ask for, best first: lossless ones, then JPEG.</summary>
    public static readonly IReadOnlyList<WindowsScanFormat> FormatPreference =
        [WindowsScanFormat.Png, WindowsScanFormat.Tiff, WindowsScanFormat.DeviceIndependentBitmap, WindowsScanFormat.Jpeg];

    /// <summary>
    /// The plan for a scan with <paramref name="settings"/>. <paramref name="facts"/> are the
    /// requested source's; null on a device that configures itself (a flatbed scan then uses
    /// <see cref="WindowsScanSource.AutoConfigured"/>). A feeder scan on a device without a feeder
    /// is refused. The flatbed scans <paramref name="selection"/> (the whole glass without one);
    /// the feeder asks for the paper size by name when it takes it, otherwise for the paper's
    /// area, and for Automatic lets the feeder measure each sheet when it can, otherwise scans
    /// its largest sheet. Every feeder plan states the area (the whole feeder when the paper is
    /// not asked for as an area), so nothing an earlier scan of the session set stays; when the
    /// feeder's size is unknown, a plan that cannot (<see cref="WindowsScanPlan.SetsFeederArea"/>)
    /// has the session put back the feeder's own page size and area.
    /// </summary>
    public static WindowsScanPlan Plan(ScanSettings settings, RectD? selection, WindowsScanSourceFacts? facts)
    {
        bool feeder = settings.Source == ScanSource.DocumentFeeder;
        if (facts is null)
        {
            if (feeder) throw ScanException.Unsupported("This scanner has no document feeder.");
            return new WindowsScanPlan(WindowsScanSource.AutoConfigured, settings.Resolution, null, null, null);
        }
        int dpi = Resolution(settings.Resolution, facts);
        var color = ColorModeFor(settings.ColorMode, facts.ColorModes);
        var format = Format(facts.Formats);
        if (!feeder)
        {
            return new WindowsScanPlan(WindowsScanSource.Flatbed, dpi, color, format, FlatbedRegion(selection, facts));
        }

        bool duplex = settings.Duplex == DuplexMode.Both && facts.CanScanDuplex;
        var size = settings.PaperSize;
        bool knownSize = WindowsScanCapabilities.Positive(facts.MaxScanAreaInches);
        // The whole feeder (FeederRegionInches of Automatic is its largest sheet).
        RectD? whole = knownSize ? PaperSizes.FeederRegionInches(PaperSize.Auto, facts.MaxScanAreaInches) : null;
        if (size == PaperSize.Auto)
        {
            return new WindowsScanPlan(WindowsScanSource.Feeder, dpi, color, format, whole, duplex,
                                       AutoDetectPageSize: facts.CanAutoDetectPageSize ? true : null);
        }
        bool? autoDetect = facts.CanAutoDetectPageSize ? false : null;
        if (facts.PageSizes.Contains(size) && MediaSizeName(size) is not null)
        {
            return new WindowsScanPlan(WindowsScanSource.Feeder, dpi, color, format, whole, duplex, size, autoDetect);
        }
        RectD? region = knownSize ? PaperSizes.FeederRegionInches(size, facts.MaxScanAreaInches) : null;
        return new WindowsScanPlan(WindowsScanSource.Feeder, dpi, color, format, region, duplex, AutoDetectPageSize: autoDetect);
    }

    /// <summary>
    /// The plan for an overview of the whole glass in color, at <see cref="OverviewDpi"/> (or
    /// the nearest the flatbed offers); used when the device makes no preview of its own.
    /// </summary>
    public static WindowsScanPlan Overview(WindowsScanSourceFacts flatbed) =>
        new(WindowsScanSource.Flatbed, Resolution(OverviewDpi, flatbed),
            ColorModeFor(ColorMode.Color, flatbed.ColorModes), Format(flatbed.Formats), FlatbedRegion(null, flatbed));

    /// <summary>
    /// The device's color mode for <paramref name="wanted"/>: the same kind when it is listed,
    /// otherwise the nearest one it lists (black &amp; white falls back to gray, which the app
    /// then turns black and white itself). With nothing listed, the same kind.
    /// </summary>
    public static WindowsScanColorMode ColorModeFor(ColorMode wanted, IReadOnlyList<WindowsScanColorMode> supported)
    {
        WindowsScanColorMode[] order = wanted switch
        {
            ColorMode.Grayscale => [WindowsScanColorMode.Grayscale, WindowsScanColorMode.Color, WindowsScanColorMode.AutoColor, WindowsScanColorMode.Monochrome],
            ColorMode.BlackWhite => [WindowsScanColorMode.Monochrome, WindowsScanColorMode.Grayscale, WindowsScanColorMode.Color, WindowsScanColorMode.AutoColor],
            _ => [WindowsScanColorMode.Color, WindowsScanColorMode.AutoColor, WindowsScanColorMode.Grayscale, WindowsScanColorMode.Monochrome],
        };
        foreach (var mode in order)
        {
            if (supported.Contains(mode)) return mode;
        }
        return order[0];
    }

    /// <summary>The first of <see cref="FormatPreference"/> the source supports; null (the device's own format) when it lists none of them.</summary>
    public static WindowsScanFormat? Format(IReadOnlyList<WindowsScanFormat> supported)
    {
        foreach (var format in FormatPreference)
        {
            if (supported.Contains(format)) return format;
        }
        return null;
    }

    /// <summary>The offered resolution nearest <paramref name="wanted"/> (the lower one on a tie); <paramref name="wanted"/> when the source reports none.</summary>
    public static int Resolution(int wanted, WindowsScanSourceFacts facts)
    {
        var list = facts.Resolutions;
        if (list.Count == 0) return wanted;
        return list.OrderBy(dpi => Math.Abs(dpi - wanted)).ThenBy(dpi => dpi).First();
    }

    /// <summary>
    /// The flatbed area to scan, in inches: the normalized <paramref name="selection"/> of the
    /// glass (the whole glass without one, or when it is degenerate), grown to the smallest area
    /// the flatbed scans and kept on the glass. null when the glass size is unknown.
    /// </summary>
    public static RectD? FlatbedRegion(RectD? selection, WindowsScanSourceFacts facts)
    {
        var bed = facts.MaxScanAreaInches;
        if (!WindowsScanCapabilities.Positive(bed)) return null;
        var full = new RectD(0, 0, bed.Width, bed.Height);
        if (selection is not { } sel) return full;
        var clamped = sel.Standardized.Intersection(new RectD(0, 0, 1, 1));
        if (clamped.Width <= 0.001 || clamped.Height <= 0.001) return full;
        double width = Math.Min(Math.Max(clamped.Width * bed.Width, facts.MinScanAreaInches.Width), bed.Width);
        double height = Math.Min(Math.Max(clamped.Height * bed.Height, facts.MinScanAreaInches.Height), bed.Height);
        double x = Math.Min(clamped.MinX * bed.Width, bed.Width - width);
        double y = Math.Min(clamped.MinY * bed.Height, bed.Height - height);
        return new RectD(x, y, width, height);
    }

    /// <summary>
    /// The name of the <c>Windows.Graphics.Printing.PrintMediaSize</c> member for a paper size
    /// (the feeder's page size); null for Automatic.
    /// </summary>
    public static string? MediaSizeName(PaperSize size) => size switch
    {
        PaperSize.Letter => "NorthAmericaLetter",
        PaperSize.Legal => "NorthAmericaLegal",
        PaperSize.Executive => "NorthAmericaExecutive",
        PaperSize.A4 => "IsoA4",
        PaperSize.A5 => "IsoA5",
        PaperSize.A6 => "IsoA6",
        PaperSize.B5Jis => "JisB5",
        PaperSize.IdCard => "CreditCard",
        _ => null,
    };

    /// <summary>
    /// What a feeder batch that failed with <paramref name="error"/> after
    /// <paramref name="pagesKept"/> readable pages comes to: like the WIA connection, an empty
    /// feeder after some sheets ends the batch, any other problem keeps the sheets already
    /// scanned and says why it stopped, and a cancel or a failure before the first sheet fails.
    /// </summary>
    public static WindowsScanFailureOutcome AfterFailure(ScanException error, int pagesKept)
    {
        if (error.Kind == ScanErrorKind.Cancelled || pagesKept <= 0) return WindowsScanFailureOutcome.Fail;
        return error.Problem == ScannerProblem.FeederEmpty ? WindowsScanFailureOutcome.Finished : WindowsScanFailureOutcome.Stopped;
    }

    /// <summary>
    /// The order of the files a scan left in its folder, as page order: by name with runs of
    /// digits compared as numbers and the name without its extension first, so "Scan.png",
    /// "Scan (2).png", "Scan (10).png" stay in the order they were scanned.
    /// </summary>
    public static List<string> FileOrder(IEnumerable<string> fileNames) =>
        [.. fileNames.Order(Comparer<string>.Create(CompareFileNames))];

    /// <summary>A resolution in whole dpi; 0 for a value that is not positive.</summary>
    public static int Dpi(double value) =>
        double.IsFinite(value) && value > 0 ? (int)Math.Min(Math.Round(value), int.MaxValue) : 0;

    /// <summary>The highest resolution a scanned file is believed to record (<see cref="FileDpi"/>).</summary>
    public const int MaxFileDpi = 19200;

    /// <summary>
    /// The resolution a scanned file records, in whole dpi; 0 when it records none worth
    /// trusting: not positive, above <see cref="MaxFileDpi"/>, or 72 or 96 dpi, which image
    /// writers and Windows' decoders put in a file that records no resolution.
    /// </summary>
    public static int FileDpi(double dpiX)
    {
        int dpi = Dpi(dpiX);
        return dpi is 72 or 96 || dpi > MaxFileDpi ? 0 : dpi;
    }

    /// <summary>
    /// The resolution a scanned page is tagged with (it sets the page's size on paper): what the
    /// driver reports it scanned at (<paramref name="reportedDpi"/>, 0 when it reports nothing:
    /// a device that configures itself, or a read that failed), else what the file records
    /// (<see cref="FileDpi"/>), else the resolution asked for.
    /// </summary>
    public static int PageDpi(int reportedDpi, double fileDpiX, int askedDpi)
    {
        if (reportedDpi > 0) return reportedDpi;
        int file = FileDpi(fileDpiX);
        return file > 0 ? file : askedDpi;
    }

    private static int CompareFileNames(string a, string b)
    {
        int byStem = CompareNatural(Path.GetFileNameWithoutExtension(a), Path.GetFileNameWithoutExtension(b));
        return byStem != 0 ? byStem : string.CompareOrdinal(a, b);
    }

    /// <summary>Runs of ASCII digits compare as numbers, everything else ordinally, ignoring ASCII case.</summary>
    private static int CompareNatural(string a, string b)
    {
        int i = 0, j = 0;
        while (i < a.Length && j < b.Length)
        {
            if (IsDigit(a[i]) && IsDigit(b[j]))
            {
                int startA = i, startB = j;
                while (i < a.Length && IsDigit(a[i])) i++;
                while (j < b.Length && IsDigit(b[j])) j++;
                string numberA = a[startA..i].TrimStart('0'), numberB = b[startB..j].TrimStart('0');
                if (numberA.Length != numberB.Length) return numberA.Length.CompareTo(numberB.Length);
                int digits = string.CompareOrdinal(numberA, numberB);
                if (digits != 0) return digits;
                continue;
            }
            int chars = Lower(a[i]).CompareTo(Lower(b[j]));
            if (chars != 0) return chars;
            i++;
            j++;
        }
        return (a.Length - i).CompareTo(b.Length - j);
    }

    private static bool IsDigit(char c) => c is >= '0' and <= '9';

    private static char Lower(char c) => c is >= 'A' and <= 'Z' ? (char)(c + 32) : c;
}

/// <summary>Maps the errors of Windows Scan calls to <see cref="ScanException"/>s and says when the API is not usable at all.</summary>
public static class WindowsScanErrors
{
    /// <summary>APPMODEL_ERROR_NO_PACKAGE: the call needs the identity of a packaged app.</summary>
    public const uint NoPackageIdentity = 0x80073D54;
    public const uint AccessDenied = 0x80070005;
    /// <summary>REGDB_E_CLASSNOTREG: the WinRT class is not registered (a stripped-down Windows).</summary>
    public const uint ClassNotRegistered = 0x80040154;
    public const uint ClassNotAvailable = 0x80040111;
    /// <summary>RO_E_METADATA_NAME_NOT_FOUND: Windows does not know the API.</summary>
    public const uint MetadataNameNotFound = 0x8000000F;
    public const uint Aborted = 0x80004004;
    public const uint Cancelled = 0x800704C7;
    public const uint NotFound = 0x80070490;
    public const uint DeviceNotConnected = 0x8007048F;
    public const uint DeviceNotAvailable = 0x800710DF;
    public const uint NotReady = 0x80070015;
    public const uint RpcServerUnavailable = 0x800706BA;
    public const uint RpcCallFailed = 0x800706BE;
    public const uint RpcDisconnected = 0x80010108;
    public const uint NotImplemented = 0x80004001;
    public const uint NotSupported = 0x80070032;

    /// <summary>
    /// The error says Windows Scan cannot be used by this app at all (it would need package
    /// identity or a capability, or the API is missing), rather than that a scanner failed: the
    /// connection is then hidden with a note in the device diagnostics. Only the errors of the
    /// API's entry points (starting the device watcher, opening a device) are read this way: once
    /// a device is open the API works, and an access denial is then an ordinary failure (it is
    /// also the code of a file or folder the app may not write). An access denial from opening a
    /// device hides the connection only as <see cref="WindowsScanAccess"/> decides.
    /// </summary>
    public static bool UnavailableToThisApp(int hresult) => unchecked((uint)hresult) switch
    {
        NoPackageIdentity or AccessDenied or ClassNotRegistered or ClassNotAvailable or MetadataNameNotFound => true,
        _ => false,
    };

    /// <summary>The diagnostics note for an error <see cref="UnavailableToThisApp"/> accepts.</summary>
    public static string UnavailableNote(int hresult, string? message)
    {
        string why = unchecked((uint)hresult) switch
        {
            NoPackageIdentity => "Windows allows it only to apps installed as a package",
            AccessDenied => "Windows refused this app access to it",
            ClassNotRegistered or ClassNotAvailable or MetadataNameNotFound => "this edition of Windows does not have it",
            _ => "Windows would not start it",
        };
        string code = $"0x{unchecked((uint)hresult):X8}";
        string detail = FirstLine(message);
        return detail.Length > 0 ? $"{why} ({code}: {detail})" : $"{why} ({code})";
    }

    /// <summary>
    /// The <see cref="ScanException"/> for a failed Windows Scan call: the WIA codes Windows Scan
    /// passes on become the scanner problem they stand for (<see cref="WiaErrors.ProblemFor"/>);
    /// a cancelled call is a cancel; a device that went away is offline; a broken link to the
    /// WIA service is a communication error; an unsupported request says so; when
    /// <paramref name="opening"/>, a refusal of the API itself (<see cref="UnavailableToThisApp"/>)
    /// says Windows Scan is not available; anything else is a failed scan with the code and the
    /// first line of Windows' message.
    /// </summary>
    /// <param name="opening">The error came from opening the device, an entry point of the API.</param>
    public static ScanException ToScanException(int hresult, string? message, bool opening = false)
    {
        string code = $"Windows Scan error 0x{unchecked((uint)hresult):X8}";
        if (WiaErrors.ProblemFor(hresult) is { } problem) return ScanException.ForProblem(problem, code);
        string detail = FirstLine(message);
        string withDetail = detail.Length > 0 ? $"{code}: {detail}" : code;
        return unchecked((uint)hresult) switch
        {
            Aborted or Cancelled => ScanException.Cancelled(),
            NotFound or DeviceNotConnected or DeviceNotAvailable or NotReady => ScanException.ForProblem(ScannerProblem.Offline, code),
            RpcServerUnavailable or RpcCallFailed or RpcDisconnected => ScanException.ForProblem(ScannerProblem.CommunicationError, code),
            NotImplemented or NotSupported => ScanException.Unsupported($"the scanner does not do this through Windows Scan ({withDetail})."),
            _ when opening && UnavailableToThisApp(hresult) => ScanException.SessionFailed($"Windows Scan is not available: {UnavailableNote(hresult, message)}."),
            _ => ScanException.ScanFailed(withDetail),
        };
    }

    /// <summary>The first non-empty line of a Windows message, trimmed ("" for none).</summary>
    private static string FirstLine(string? message) =>
        message?.Split('\n').Select(line => line.Trim()).FirstOrDefault(line => line.Length > 0) ?? "";
}

/// <summary>How the Windows Scan device watcher is doing.</summary>
public enum WindowsScanStatus
{
    /// <summary>Not looking for scanners.</summary>
    Off,
    /// <summary>The watcher's first pass is running.</summary>
    Searching,
    /// <summary>The first pass is complete; scanners plugged in or out later are followed.</summary>
    Running,
    /// <summary>Windows Scan cannot be used here; the connection is hidden.</summary>
    Unavailable,
}

/// <summary>The Windows Scan section of devices.txt.</summary>
public static class WindowsScanDiagnostics
{
    /// <summary>
    /// The status line, then one line per device with its capabilities when a session has read
    /// them (<see cref="WindowsScanSourceFacts.Describe"/>).
    /// </summary>
    /// <param name="note">Why the connection is unavailable, or what else to say about it.</param>
    /// <param name="facts">The sources each device reported, by device-list id.</param>
    public static string Report(WindowsScanStatus status, string? note, IReadOnlyList<ScannerInfo> devices,
                                IReadOnlyDictionary<string, IReadOnlyList<WindowsScanSourceFacts>> facts)
    {
        string state = status switch
        {
            WindowsScanStatus.Off => "off",
            WindowsScanStatus.Searching => "searching",
            WindowsScanStatus.Running => $"watching, {devices.Count} scanner(s)",
            _ => "unavailable, connection hidden",
        };
        var text = new StringBuilder("Windows Scan (backup): ").Append(state);
        if (!string.IsNullOrWhiteSpace(note)) text.Append(" - ").Append(note.Trim());
        text.Append('\n');
        foreach (var device in devices)
        {
            text.Append($"  \"{device.Name}\" id=\"{device.Id}\"\n");
            if (!facts.TryGetValue(device.Id, out var sources)) continue;
            if (sources.Count == 0) text.Append("    configures itself (no flatbed or feeder settings)\n");
            foreach (var source in sources) text.Append("    ").Append(source.Describe()).Append('\n');
        }
        return text.ToString();
    }
}
