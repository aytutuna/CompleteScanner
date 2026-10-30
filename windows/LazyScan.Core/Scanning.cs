namespace LazyScan.Core;

// Port of Sources/LazyScanKit/Core/ScannerBackend.swift. The Swift protocols are
// @MainActor; here the contract is: all members are called from the UI thread, and
// implementations marshal their own callbacks back to it.

/// <summary>A source of scanner devices (WIA or eSCL for real hardware, Mock for the demo device).</summary>
public interface IScannerBackend
{
    /// <summary>Raised whenever <see cref="Devices"/> changes.</summary>
    event Action? DevicesChanged;

    IReadOnlyList<ScannerInfo> Devices { get; }

    void StartBrowsing();
    void StopBrowsing();

    /// <summary>Open a session with one of <see cref="Devices"/>. Throws <see cref="ScanException"/> on failure.</summary>
    Task<IScannerSession> OpenSessionAsync(string deviceId);
}

/// <summary>An open connection to one scanner.</summary>
public interface IScannerSession
{
    ScannerInfo Info { get; }
    Action<ScanProgress>? ProgressHandler { get; set; }

    Task<ScannerCapabilities> GetCapabilitiesAsync();

    /// <summary>Fast low-resolution preview of the whole flatbed.</summary>
    Task<RgbaImage> PerformOverviewScanAsync(ScanSettings settings);

    /// <summary>
    /// Perform a real scan.
    /// </summary>
    /// <param name="settings">Scan settings.</param>
    /// <param name="selection">
    /// Normalized (0...1) rect within the flatbed area, origin TOP-LEFT; null scans the
    /// full bed. Ignored for the document feeder.
    /// </param>
    /// <returns>One ScannedPage per sheet (the ADF may produce several).</returns>
    Task<IReadOnlyList<ScannedPage>> PerformScanAsync(ScanSettings settings, RectD? selection);

    /// <summary>
    /// Why the last <see cref="PerformScanAsync"/> ended early while still returning the pages
    /// that transferred; null when it ran to the end (or failed outright). Reset by every scan.
    /// Sessions that never stop a batch early can leave the default.
    /// </summary>
    ScanStop? LastScanStop => null;

    /// <summary>
    /// Whether the last <see cref="PerformScanAsync"/> asked for both sides of each sheet
    /// (<see cref="DuplexMode.Both"/> on the feeder) scanned both: false when the scanner fell
    /// back to one side (its feeder cannot, or its driver refused), so the app does not arrange
    /// the pages as fronts and backs. null when both sides were not asked for, or when the
    /// session cannot tell. Reset by every scan.
    /// </summary>
    bool? LastScanDuplex => null;

    void CancelScan();
    Task CloseAsync();
}

/// <summary>
/// The resolutions a device really offers, up to and including its true maximum. Port of
/// ICScannerBackend.resolutionList(for:) as a pure function so every backend (WIA, eSCL)
/// applies the same accuracy rules.
/// </summary>
public static class ResolutionList
{
    /// <summary>Standard ladder used to thin a huge contiguous range.</summary>
    public static readonly IReadOnlyList<int> StandardLadder =
        [50, 72, 75, 100, 150, 200, 240, 300, 400, 600, 800,
         1200, 1600, 2400, 3200, 4800, 6400, 9600, 12800];

    /// <summary>
    /// Accuracy rules, in order:
    /// 1. <paramref name="preferred"/> — when the driver provides it, that IS the device's
    ///    accurate list; use it verbatim.
    /// 2. Otherwise <paramref name="supported"/>: a small discrete set (≤ 64 values) is used
    ///    as-is; a huge contiguous range is thinned to the standard ladder plus its min and max.
    /// In both fallback shapes, values above <paramref name="nativeResolution"/> (the optical
    /// resolution; ≤ 0 = unknown) are software interpolation, not hardware capability — they
    /// are dropped so the picker never advertises resolutions the scanner can't deliver.
    /// </summary>
    /// <returns>Ascending, without duplicates. Non-positive values are never listed.</returns>
    public static List<int> Build(IEnumerable<int>? preferred, IEnumerable<int> supported,
                                  int nativeResolution)
    {
        var preferredSet = preferred?.Where(dpi => dpi > 0).ToHashSet() ?? [];
        if (preferredSet.Count > 0)
        {
            return [.. preferredSet.Order()];
        }

        var supportedSet = supported.Where(dpi => dpi > 0).ToHashSet();
        if (supportedSet.Count == 0) return [];
        int minDpi = supportedSet.Min(), maxDpi = supportedSet.Max();

        var set = new HashSet<int>();
        if (supportedSet.Count <= 64)
        {
            // A discrete list (even a generous one): offer every reported value.
            set.UnionWith(supportedSet);
        }
        else
        {
            set.UnionWith(StandardLadder.Where(supportedSet.Contains));
            set.Add(minDpi);
            set.Add(maxDpi);
        }
        if (nativeResolution > 0)
        {
            set.RemoveWhere(dpi => dpi > nativeResolution);
            if (supportedSet.Contains(nativeResolution)) set.Add(nativeResolution);
        }
        return [.. set.Order()];
    }

    /// <summary>
    /// The resolutions of a device that reports only its smallest, largest and optical
    /// resolution (the Windows Scan connection): the <see cref="StandardLadder"/> values between
    /// <paramref name="min"/> and <paramref name="max"/>, the two bounds themselves and the
    /// optical resolution when it lies between them, then <see cref="Build"/> with the optical
    /// resolution as the native one. A non-positive maximum is unknown: empty, whatever the
    /// minimum (so the caller offers its fallback list rather than only the minimum). A
    /// non-positive minimum is unknown too (the ladder starts at its lowest value). Two known
    /// bounds given the wrong way round are swapped.
    /// </summary>
    public static List<int> FromBounds(int min, int max, int optical)
    {
        if (max <= 0) return [];
        if (min > max) (min, max) = (max, min);
        int low = Math.Max(min, 1);
        var supported = new HashSet<int>(StandardLadder.Where(dpi => dpi >= low && dpi <= max)) { max };
        if (min > 0) supported.Add(min);
        if (optical >= low && optical <= max) supported.Add(optical);
        return Build(preferred: null, supported, optical);
    }

    /// <summary>
    /// Upper bound for <see cref="ExpandRange"/>: far above any real optical resolution, but
    /// keeps a hostile or broken device (e.g. max = int.MaxValue, step = 1) from making the
    /// expansion enumerate billions of values.
    /// </summary>
    public const int MaxRangeDpi = 100_000;

    /// <summary>
    /// The values of a min/max/step range (eSCL ResolutionRange, WIA range properties), for
    /// feeding <see cref="Build"/>'s <c>supported</c> argument. A non-positive step means 1;
    /// values on the range's lattice that are ≤ 0 or above <see cref="MaxRangeDpi"/> are
    /// skipped, so at most <see cref="MaxRangeDpi"/> values are produced.
    /// </summary>
    public static IEnumerable<int> ExpandRange(int min, int max, int step)
    {
        if (step <= 0) step = 1;
        long first = min;
        if (first <= 0) first += ((1 - first) + step - 1) / step * step; // first positive lattice value
        long last = Math.Min(max, MaxRangeDpi);
        for (long dpi = first; dpi <= last; dpi += step) yield return (int)dpi;
    }
}
