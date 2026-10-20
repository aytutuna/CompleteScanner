using System.IO;
using System.Runtime.InteropServices;
using CompleteScanner.App.Services;
using CompleteScanner.Core;

namespace CompleteScanner.App.Scanning;

/// <summary>
/// Real scanner hardware via WIA 2.0 (the WIA Automation layer, wiaaut.dll) — the Windows
/// counterpart of the macOS ICScannerBackend.
///
/// ⚠ EXPERIMENTAL, UNTESTED AGAINST HARDWARE: this was authored without a Windows machine
/// or scanner attached. The WIA property IDs and flow follow the documented WIA Automation
/// model (DeviceManager → DeviceInfos → Connect → Items → Transfer), but expect to iterate
/// against a real device. Known scaffold limitations:
///   - hot-plug is detected by polling (see the watchdog below), not WIA device events;
///   - Transfer() is synchronous with no progress callbacks — progress is coarse;
///   - CancelScan() cannot abort an in-flight WIA transfer, it only discards the result.
/// </summary>
public sealed class WiaScannerBackend : IPolledScannerBackend, IScannerBackendDiagnostics
{
    public event Action? DevicesChanged;
    public event Action? EnumerationFinished;

    private readonly List<ScannerInfo> _devices = [];
    public IReadOnlyList<ScannerInfo> Devices => _devices;

    // WIA constants.
    private const int ScannerDeviceType = 1;
    internal const string FormatBmp = "{B96B3CAB-0728-11D3-9D7B-0000F81EF32E}";

    // Device-level property IDs (WIA_DPS_*).
    internal const string HorizontalBedSize = "3074";   // thousandths of an inch
    internal const string VerticalBedSize = "3075";
    internal const string HorizontalSheetFeedSize = "3076"; // thousandths of an inch
    internal const string VerticalSheetFeedSize = "3077";
    internal const string DocumentHandlingCapabilities = "3086"; // see WiaDocumentHandling (Core)
    internal const string DocumentHandlingSelect = "3088"; // see WiaDocumentHandling.SelectValues (Core)
    internal const string OpticalXResolution = "3090";
    internal const string Pages = "3096";               // 0 = every sheet in the feeder
    internal const string PageSize = "3097";            // see WiaDocumentHandling.PageSize (Core)
    internal const string PageWidth = "3098";           // thousandths of an inch
    internal const string PageHeight = "3099";
    internal const int HandlingFeeder = 1;
    internal const int HandlingFlatbed = 2;

    // Item-level property IDs (WIA_IPS_* / WIA_IPA_*).
    internal const string CurrentIntent = "6146";       // 1 color, 2 gray, 4 text
    internal const string HorizontalResolution = "6147";
    internal const string VerticalResolution = "6148";
    internal const string XPos = "6149";
    internal const string YPos = "6150";
    internal const string XExtent = "6151";
    internal const string YExtent = "6152";

    /// <summary>First delay of the hot-plug watchdog; doubled after each fruitless poll.</summary>
    internal static readonly TimeSpan InitialRebrowseDelay = TimeSpan.FromSeconds(10);
    /// <summary>Upper bound of the watchdog backoff.</summary>
    internal static readonly TimeSpan MaxRebrowseDelay = TimeSpan.FromSeconds(60);

    private SynchronizationContext? _context;
    private CancellationTokenSource? _watchdog;
    /// <summary>Bumped by every Start/StopBrowsing; enumeration results from an older generation are dropped.</summary>
    private int _browseGeneration;
    /// <summary>The number of the enumeration running now; 0 when none is.</summary>
    private long _running;
    /// <summary>A refresh was asked for while one ran: another starts when it ends.</summary>
    private bool _refreshAgain;
    private long _enumerationsStarted;
    private long _enumerationsFinished;

    public long EnumerationsStarted => Interlocked.Read(ref _enumerationsStarted);
    public long EnumerationsFinished => Interlocked.Read(ref _enumerationsFinished);

    /// <summary>
    /// Enumerate once now, then keep re-enumerating so the list follows the hardware without
    /// a restart: a scanner plugged in later appears, and an unplugged one disappears (the
    /// macOS backend gets both from ICDeviceBrowser add/remove callbacks; WIA device events
    /// are not wired up here, so this polls). While no scanner is listed the poll starts at
    /// 10 s and doubles up to 60 s; while one is listed it runs every 60 s. A session that
    /// finds its device gone also triggers an immediate re-enumeration. Enumeration runs on
    /// a background STA thread, so the UI thread never blocks on WIA.
    /// </summary>
    public void StartBrowsing()
    {
        if (_watchdog is not null) return;
        _context = SynchronizationContext.Current;
        _browseGeneration++;
        // An enumeration still running from before a Stop is stale; don't let it block this one.
        _running = 0;
        _refreshAgain = false;
        _watchdog = new CancellationTokenSource();
        RefreshDevices();
        _ = RunWatchdog(_watchdog.Token);
    }

    public void StopBrowsing()
    {
        _watchdog?.Cancel();
        _watchdog?.Dispose();
        _watchdog = null;
        _browseGeneration++;
        if (_devices.Count == 0) return;
        _devices.Clear();
        DevicesChanged?.Invoke();
    }

    private async Task RunWatchdog(CancellationToken token)
    {
        var delay = InitialRebrowseDelay;
        while (!token.IsCancellationRequested)
        {
            try
            {
                await Task.Delay(delay, token).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                return;
            }
            Post(() =>
            {
                if (token.IsCancellationRequested) return;
                RefreshDevices();
            });
            // Read the count without marshaling: a stale value only shifts the next delay.
            delay = NextRebrowseDelay(delay, devicesListed: _devices.Count > 0);
        }
    }

    /// <summary>
    /// The watchdog's next poll interval: backing off (doubling up to the ceiling) while no
    /// scanner is listed, and the ceiling while one is — slow enough to stay cheap, fast
    /// enough that an unplugged scanner leaves the list.
    /// </summary>
    internal static TimeSpan NextRebrowseDelay(TimeSpan current, bool devicesListed) =>
        devicesListed
            ? MaxRebrowseDelay
            : TimeSpan.FromTicks(Math.Min(current.Ticks * 2, MaxRebrowseDelay.Ticks));

    /// <summary>The WIA service's state is read by the app (Services/SystemDiagnostics.cs); WIA adds nothing else.</summary>
    public DiscoverySnapshot AddStatus(DiscoverySnapshot snapshot) => snapshot;

    /// <summary>The troubleshooter's Refresh: list the WIA scanners again now, while browsing.</summary>
    public void Rescan()
    {
        if (_watchdog is not null) RefreshDevices();
    }

    /// <summary>A session found its device missing: re-enumerate now (callable from any thread).</summary>
    internal void DeviceLost() => Post(() =>
    {
        if (_watchdog is not null) RefreshDevices();
    });

    /// <summary>
    /// Re-enumerate WIA scanners in the background (call again to pick up newly plugged
    /// devices). A call while one runs does not start a second at once: one more starts when the
    /// running one ends, so the result of an enumeration begun after the call always arrives
    /// (the app waits for that before it uses Windows Scan for a scanner WIA does not list yet).
    /// </summary>
    public void RefreshDevices()
    {
        // Without a context to post to, results are applied on the enumeration thread under this
        // lock (see Post); it is re-entered when a result starts the enumeration asked for meanwhile.
        lock (_devices) StartEnumeration();
    }

    private void StartEnumeration()
    {
        if (_running != 0)
        {
            _refreshAgain = true;
            return;
        }
        _refreshAgain = false;
        int generation = _browseGeneration;
        long number = Interlocked.Increment(ref _enumerationsStarted);
        _running = number;
        var thread = new Thread(() =>
        {
            var found = EnumerateScanners();
            Post(() =>
            {
                if (_running == number) _running = 0;
                // A Stop/Start since this enumeration began makes its result stale.
                if (generation != _browseGeneration) return;
                if (number > Interlocked.Read(ref _enumerationsFinished)) Interlocked.Exchange(ref _enumerationsFinished, number);
                ReplaceDevices(found);
                EnumerationFinished?.Invoke();
                if (_refreshAgain && _running == 0) RefreshDevices();
            });
        })
        {
            IsBackground = true,
            Name = "WIA enumeration",
        };
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
    }

    /// <summary>Run on the thread that started browsing (the UI thread in the app).</summary>
    private void Post(Action action)
    {
        if (_context is { } context) context.Post(_ => action(), null);
        else lock (_devices) action();
    }

    private static List<ScannerInfo> EnumerateScanners()
    {
        var found = new List<ScannerInfo>();
        // The watchdog may enumerate for hours: release every COM object deterministically
        // rather than leaving them to the finalizer of a thread that has already exited.
        var comObjects = new List<object>();
        try
        {
            var managerType = Type.GetTypeFromProgID("WIA.DeviceManager");
            if (managerType is null) return found;
            dynamic manager = Activator.CreateInstance(managerType)!;
            comObjects.Add(manager);
            dynamic infos = manager.DeviceInfos;
            comObjects.Add(infos);
            int count = infos.Count;
            for (int i = 1; i <= count; i++) // WIA collections are 1-based
            {
                dynamic info = infos[i];
                comObjects.Add(info);
                if ((int)info.Type != ScannerDeviceType) continue;
                string id = (string)info.DeviceID;
                string name = TryGetProperty(info.Properties, "Name") as string ?? "Scanner";
                found.Add(new ScannerInfo($"wia:{id}", name, "WIA", Backend: "wia",
                                          Model: ModelOf(TryGetProperty(info.Properties, "Manufacturer") as string,
                                                         TryGetProperty(info.Properties, "Description") as string)));
            }
        }
        catch
        {
            // WIA not available (service disabled, no devices): expose nothing.
        }
        finally
        {
            for (int i = comObjects.Count - 1; i >= 0; i--)
            {
                try
                {
                    if (Marshal.IsComObject(comObjects[i])) Marshal.FinalReleaseComObject(comObjects[i]);
                }
                catch
                {
                    // best effort
                }
            }
        }
        return found;
    }

    /// <summary>
    /// "Manufacturer Description" from the device's WIA properties, for matching it with the
    /// same scanner on other connections (DeviceMerge drops a repeated manufacturer); null
    /// when the driver reports neither.
    /// </summary>
    internal static string? ModelOf(string? manufacturer, string? description)
    {
        string model = $"{manufacturer?.Trim()} {description?.Trim()}".Trim();
        return model.Length > 0 ? model : null;
    }

    private void ReplaceDevices(List<ScannerInfo> found)
    {
        if (_devices.SequenceEqual(found)) return;
        _devices.Clear();
        _devices.AddRange(found);
        DevicesChanged?.Invoke();
    }

    public Task<IScannerSession> OpenSessionAsync(string deviceId)
    {
        var info = _devices.FirstOrDefault(d => d.Id == deviceId)
            ?? throw ScanException.DeviceUnavailable("The selected scanner is not connected.");
        string wiaId = deviceId["wia:".Length..];
        return Task.FromResult<IScannerSession>(new WiaScannerSession(info, wiaId, DeviceLost));
    }

    internal static object? TryGetProperty(dynamic properties, string idOrName)
    {
        try
        {
            return properties[idOrName].Value;
        }
        catch
        {
            return null;
        }
    }

    internal static bool TrySetProperty(dynamic properties, string id, object value)
    {
        try
        {
            properties[id].Value = value;
            return true;
        }
        catch
        {
            return false;
        }
    }
}

/// <param name="deviceLost">Called (on the WIA thread) when the device is no longer connected.</param>
internal sealed class WiaScannerSession(ScannerInfo info, string wiaDeviceId, Action deviceLost) : IScannerSession
{
    public ScannerInfo Info { get; } = info;
    public Action<ScanProgress>? ProgressHandler { get; set; }

    /// <summary>Written on the WIA thread before the scan task completes, read after it.</summary>
    private volatile ScanStop? _lastScanStop;
    public ScanStop? LastScanStop => _lastScanStop;

    /// <summary>Written on the WIA thread before the scan task completes, read after it (null, false, true).</summary>
    private volatile int _lastScanDuplex = -1;
    public bool? LastScanDuplex => _lastScanDuplex < 0 ? null : _lastScanDuplex == 1;

    private volatile bool _cancelRequested;
    private SizeD _bedInches = new(8.5, 11.7);
    /// <summary>The feeder's largest sheet, when the device reports it.</summary>
    private SizeD? _feederInches;
    /// <summary>The sources the device reported (null until the capabilities are read).</summary>
    private List<ScanSource>? _sources;
    /// <summary>The feeder scans both sides, as the device reported (null until the capabilities are read).</summary>
    private bool? _supportsDuplex;
    /// <summary>The source selected by the last <see cref="PrepareItemCore"/> scans both sides (WIA thread only).</summary>
    private bool _preparedTwoSided;

    public Task<ScannerCapabilities> GetCapabilitiesAsync() => RunSta(() =>
    {
        var caps = new ScannerCapabilities();
        dynamic device = Connect();
        try
        {
            // The real sources: a feeder-only scanner has no flatbed (and so no overview),
            // whatever other properties its driver exposes.
            int? handling = ToInt(WiaScannerBackend.TryGetProperty(device.Properties,
                WiaScannerBackend.DocumentHandlingCapabilities));
            var sources = WiaDocumentHandling.Sources(handling);
            _sources = sources;
            caps.Sources = sources;
            caps.SupportsOverview = sources.Contains(ScanSource.Flatbed);
            caps.SupportsDuplex = WiaDocumentHandling.SupportsDuplex(handling);
            _supportsDuplex = caps.SupportsDuplex;

            // Physical bed and feeder sizes arrive in thousandths of an inch.
            object? bedWidth = WiaScannerBackend.TryGetProperty(device.Properties, WiaScannerBackend.HorizontalBedSize);
            object? bedHeight = WiaScannerBackend.TryGetProperty(device.Properties, WiaScannerBackend.VerticalBedSize);
            if (ToInt(bedWidth) is int bw && ToInt(bedHeight) is int bh && bw > 0 && bh > 0)
            {
                _bedInches = new SizeD(bw / 1000.0, bh / 1000.0);
                caps.FlatbedSizeInches = _bedInches;
            }
            if (sources.Contains(ScanSource.DocumentFeeder))
            {
                caps.FeederSizeInches = WiaDocumentHandling.FeederSizeInches(
                    ToInt(WiaScannerBackend.TryGetProperty(device.Properties, WiaScannerBackend.HorizontalSheetFeedSize)),
                    ToInt(WiaScannerBackend.TryGetProperty(device.Properties, WiaScannerBackend.VerticalSheetFeedSize)));
                _feederInches = caps.FeederSizeInches;
            }
            // The item's resolution property advertises its valid values as a list or a
            // range; when the driver reports neither, offer the common ladder (the session
            // snaps to whatever the driver accepts on scan).
            List<int>? resolutions = ReadResolutions(device, sources[0]);
            caps.SupportedResolutions = resolutions ?? [75, 150, 200, 300, 600, 1200];
            return caps;
        }
        finally
        {
            Release(device);
        }
    });

    public Task<RgbaImage> PerformOverviewScanAsync(ScanSettings settings)
    {
        _cancelRequested = false;
        if (_sources is { } sources && !sources.Contains(ScanSource.Flatbed))
        {
            return Task.FromException<RgbaImage>(ScanException.Unsupported("This scanner has no flatbed to preview."));
        }
        ProgressHandler?.Invoke(new ScanProgress("Scanning overview…"));
        return RunSta(() =>
        {
            dynamic device = Connect();
            try
            {
                object item = PrepareItem(device, 150, ScanSource.Flatbed, ColorMode.Color, null, false,
                                          PaperSize.Auto);
                try
                {
                    return Transfer(item);
                }
                finally
                {
                    Release(item);
                }
            }
            finally
            {
                Release(device);
            }
        });
    }

    public Task<IReadOnlyList<ScannedPage>> PerformScanAsync(ScanSettings settings, RectD? selection)
    {
        _lastScanStop = null;
        _lastScanDuplex = -1;
        return RunSta<IReadOnlyList<ScannedPage>>(() =>
        {
            _cancelRequested = false;
            ProgressHandler?.Invoke(new ScanProgress("Scanning…"));
            var pages = new List<ScannedPage>();
            // One connection for the whole batch: every sheet of a feeder scan comes from the
            // same prepared item.
            dynamic device = Connect();
            try
            {
                bool feeder = settings.Source == ScanSource.DocumentFeeder;
                // Two-sided feeder scans deliver front, back, front, back… (FRONT_FIRST). A
                // feeder the device reported as one-sided is not asked.
                bool askedBoth = feeder && settings.Duplex == DuplexMode.Both;
                object item = PrepareItem(device, settings.Resolution, settings.Source, settings.ColorMode,
                                           feeder ? null : selection,
                                           askedBoth && _supportsDuplex != false,
                                           feeder ? settings.PaperSize : PaperSize.Auto);
                // Whether the driver took two-sided feeding, so the app knows what the pages are.
                if (askedBoth) _lastScanDuplex = _preparedTwoSided ? 1 : 0;
                try
                {
                    if (feeder)
                    {
                        ScanFeeder(item, settings, pages);
                    }
                    else
                    {
                        RgbaImage image = Transfer(item);
                        if (_cancelRequested) throw ScanException.Cancelled();
                        pages.Add(new ScannedPage(image, settings.Resolution, settings.ColorMode));
                    }
                }
                finally
                {
                    Release(item);
                }
            }
            finally
            {
                Release(device);
            }
            if (pages.Count == 0) throw ScanException.ScanFailed("The scanner did not return any image data.");
            return pages;
        });
    }

    /// <summary>
    /// Keep pulling sheets until the feeder runs out. An empty feeder on the first sheet is
    /// the user's to fix ("Load paper in the feeder"); later it just ends the batch. Any other
    /// failure mid-batch keeps the sheets that already transferred (mirroring the macOS
    /// backend) and records why the scan stopped in <see cref="LastScanStop"/>.
    /// </summary>
    private void ScanFeeder(object item, ScanSettings settings, List<ScannedPage> pages)
    {
        while (true)
        {
            RgbaImage image;
            try
            {
                image = Transfer(item);
            }
            catch (ScanException e) when (e.Problem == ScannerProblem.FeederEmpty && pages.Count > 0)
            {
                return;
            }
            catch (ScanException e) when (pages.Count > 0 && e.Kind != ScanErrorKind.Cancelled)
            {
                _lastScanStop = ScanStop.From(e);
                return;
            }
            if (_cancelRequested) throw ScanException.Cancelled();
            pages.Add(new ScannedPage(image, settings.Resolution, settings.ColorMode));
            ProgressHandler?.Invoke(new ScanProgress($"Transferred sheet {pages.Count}…"));
        }
    }

    public void CancelScan() => _cancelRequested = true;

    public Task CloseAsync() => Task.CompletedTask; // connections are per operation in WIA automation

    // MARK: - Transfers

    /// <summary>
    /// Select the source and set resolution, color and area on the item to scan. WIA errors
    /// (a busy or offline device, ...) become <see cref="ScanException"/>s via <see cref="WiaErrors"/>.
    /// </summary>
    private dynamic PrepareItem(dynamic device, int dpi, ScanSource source, ColorMode colorMode, RectD? selection,
                                bool duplex, PaperSize paperSize)
    {
        try
        {
            return PrepareItemCore(device, dpi, source, colorMode, selection, duplex, paperSize);
        }
        catch (COMException e)
        {
            throw WiaErrors.ToScanException(e.HResult, e.Message);
        }
    }

    private dynamic PrepareItemCore(dynamic device, int dpi, ScanSource source, ColorMode colorMode, RectD? selection,
                                    bool duplex, PaperSize paperSize)
    {
        // The first value the driver accepts: two-sided drivers that refuse FRONT_FIRST get
        // FEEDER | DUPLEX, and drivers that refuse two-sided feeding the feeder alone.
        dynamic properties = device.Properties;
        int? selected = WiaDocumentHandling.SelectSource(source, duplex, value =>
            (bool)WiaScannerBackend.TrySetProperty(properties, WiaScannerBackend.DocumentHandlingSelect, value));
        // A driver that took none of them may already have the feeder selected (single-source
        // drivers can make the property read-only): scan that, with its own sides. A feeder
        // that is not selected would scan whatever source is (the flatbed, over and over).
        // Drivers without the property keep their one source.
        if (selected is null && source == ScanSource.DocumentFeeder
            && (object?)WiaScannerBackend.TryGetProperty(properties, WiaScannerBackend.DocumentHandlingSelect) is { } current)
        {
            selected = WiaDocumentHandling.FeederAlreadySelected(ToInt(current))
                ?? throw ScanException.ScanFailed("The scanner did not accept its document feeder as the source.");
        }
        _preparedTwoSided = WiaDocumentHandling.ScansBothSides(selected);
        // Two-sided: every sheet in the feeder, both of its sides; one-sided feeding keeps the
        // driver's own page count, as before.
        if (_preparedTwoSided) WiaScannerBackend.TrySetProperty(device.Properties, WiaScannerBackend.Pages, WiaDocumentHandling.AllPages);
        var page = source == ScanSource.DocumentFeeder ? WiaDocumentHandling.PageSize(paperSize) : null;
        if (page is not null)
        {
            WiaScannerBackend.TrySetProperty(device.Properties, WiaScannerBackend.PageSize, page.Value.PageSize);
            if (page.Value.PageSize == WiaDocumentHandling.PageCustom)
            {
                WiaScannerBackend.TrySetProperty(device.Properties, WiaScannerBackend.PageWidth, page.Value.WidthThousandths);
                WiaScannerBackend.TrySetProperty(device.Properties, WiaScannerBackend.PageHeight, page.Value.HeightThousandths);
            }
        }

        dynamic item = device.Items[1];
        var props = item.Properties;
        WiaScannerBackend.TrySetProperty(props, WiaScannerBackend.CurrentIntent, colorMode switch
        {
            ColorMode.Color => 1,
            ColorMode.Grayscale => 2,
            _ => 4, // text/threshold
        });
        WiaScannerBackend.TrySetProperty(props, WiaScannerBackend.HorizontalResolution, dpi);
        WiaScannerBackend.TrySetProperty(props, WiaScannerBackend.VerticalResolution, dpi);

        // The paper's area on the feeder, in pixels at the chosen resolution, for drivers that
        // take the extents rather than the page size.
        if (page is not null && _feederInches is { } feederMax)
        {
            var region = PaperSizes.FeederRegionInches(paperSize, feederMax);
            WiaScannerBackend.TrySetProperty(props, WiaScannerBackend.XPos, 0);
            WiaScannerBackend.TrySetProperty(props, WiaScannerBackend.YPos, 0);
            WiaScannerBackend.TrySetProperty(props, WiaScannerBackend.XExtent, (int)Math.Round(region.Width * dpi));
            WiaScannerBackend.TrySetProperty(props, WiaScannerBackend.YExtent, (int)Math.Round(region.Height * dpi));
        }

        // Scan area in pixels at the chosen resolution; the selection is a normalized
        // top-left-origin rect of the bed.
        if (source == ScanSource.Flatbed && selection is { } sel)
        {
            var clamped = sel.Standardized.Intersection(new RectD(0, 0, 1, 1));
            if (clamped.Width > 0.001 && clamped.Height > 0.001)
            {
                WiaScannerBackend.TrySetProperty(props, WiaScannerBackend.XPos,
                    (int)Math.Round(clamped.MinX * _bedInches.Width * dpi));
                WiaScannerBackend.TrySetProperty(props, WiaScannerBackend.YPos,
                    (int)Math.Round(clamped.MinY * _bedInches.Height * dpi));
                WiaScannerBackend.TrySetProperty(props, WiaScannerBackend.XExtent,
                    (int)Math.Round(clamped.Width * _bedInches.Width * dpi));
                WiaScannerBackend.TrySetProperty(props, WiaScannerBackend.YExtent,
                    (int)Math.Round(clamped.Height * _bedInches.Height * dpi));
            }
        }
        return item;
    }

    /// <summary>One transfer (one sheet from the feeder). WIA errors become <see cref="ScanException"/>s via <see cref="WiaErrors"/>.</summary>
    private RgbaImage Transfer(object item)
    {
        ProgressHandler?.Invoke(new ScanProgress("Transferring…"));
        dynamic imageFile;
        try
        {
            imageFile = ((dynamic)item).Transfer(WiaScannerBackend.FormatBmp);
        }
        catch (COMException e)
        {
            throw WiaErrors.ToScanException(e.HResult, e.Message);
        }
        string tempPath = Path.Combine(Path.GetTempPath(), $"CompleteScanner-{Guid.NewGuid()}.bmp");
        try
        {
            imageFile.SaveFile(tempPath);
            return WpfImageCodec.Load(tempPath);
        }
        catch (COMException e)
        {
            throw WiaErrors.ToScanException(e.HResult, e.Message);
        }
        finally
        {
            try { File.Delete(tempPath); } catch { /* best effort */ }
            Release(imageFile);
        }
    }

    private dynamic Connect()
    {
        var managerType = Type.GetTypeFromProgID("WIA.DeviceManager")
            ?? throw ScanException.DeviceUnavailable("WIA is not available on this system.");
        dynamic manager = Activator.CreateInstance(managerType)!;
        dynamic infos = manager.DeviceInfos;
        int count = infos.Count;
        for (int i = 1; i <= count; i++)
        {
            dynamic info = infos[i];
            if ((string)info.DeviceID == wiaDeviceId)
            {
                try
                {
                    return info.Connect();
                }
                catch (COMException e)
                {
                    throw ScanException.SessionFailed(e.Message);
                }
            }
        }
        // Unplugged: refresh the device list now rather than at the next poll, so the
        // sidebar drops it and the app can switch to another scanner.
        deviceLost();
        throw ScanException.DeviceUnavailable($"{Info.Name} is no longer connected.");
    }

    /// <summary>
    /// The device's real resolution list via <see cref="ResolutionList.Build"/>: the valid
    /// values of the item's horizontal-resolution property (WiaSubType List = 2 or Range = 1),
    /// capped at the optical resolution. null when the driver does not expose them.
    /// </summary>
    private static List<int>? ReadResolutions(dynamic device, ScanSource unit)
    {
        try
        {
            // Resolutions are per functional unit: read the flatbed's (the feeder's on a
            // feeder-only scanner), like the macOS backend, rather than whatever unit the
            // driver last had selected.
            WiaScannerBackend.TrySetProperty(device.Properties, WiaScannerBackend.DocumentHandlingSelect,
                unit == ScanSource.DocumentFeeder ? WiaScannerBackend.HandlingFeeder : WiaScannerBackend.HandlingFlatbed);
            dynamic item = device.Items[1];
            dynamic property = item.Properties[WiaScannerBackend.HorizontalResolution];
            int subType = Convert.ToInt32((object)property.SubType);
            var supported = new List<int>();
            if (subType == 2)
            {
                dynamic values = property.SubTypeValues;
                int count = values.Count;
                for (int i = 1; i <= count; i++) // WIA vectors are 1-based
                {
                    object value = values[i];
                    int dpi = Convert.ToInt32(value);
                    if (dpi > 0) supported.Add(dpi);
                }
            }
            else if (subType == 1)
            {
                int min = Convert.ToInt32((object)property.SubTypeMin);
                int max = Convert.ToInt32((object)property.SubTypeMax);
                int step = Convert.ToInt32((object)property.SubTypeStep);
                supported.AddRange(ResolutionList.ExpandRange(min, max, step).Where(v => v > 0));
            }
            else
            {
                return null;
            }
            object? optical = WiaScannerBackend.TryGetProperty(device.Properties, WiaScannerBackend.OpticalXResolution);
            int native = ToInt(optical) ?? 0;
            var list = ResolutionList.Build(preferred: null, supported, native);
            return list.Count > 0 ? list : null;
        }
        catch
        {
            return null;
        }
    }

    /// <summary>A numeric property value; null when missing or not a number.</summary>
    private static int? ToInt(object? value)
    {
        if (value is null) return null;
        try
        {
            return Convert.ToInt32(value);
        }
        catch (Exception e) when (e is FormatException or InvalidCastException or OverflowException)
        {
            return null;
        }
    }

    private static void Release(object com)
    {
        try
        {
            if (OperatingSystem.IsWindows() && Marshal.IsComObject(com)) Marshal.ReleaseComObject(com);
        }
        catch
        {
            // best effort
        }
    }

    /// <summary>
    /// WIA Automation requires an STA apartment; transfers also block, so each call runs
    /// on its own STA thread to keep the UI live.
    /// </summary>
    private static Task<T> RunSta<T>(Func<T> work)
    {
        var tcs = new TaskCompletionSource<T>();
        var thread = new Thread(() =>
        {
            try { tcs.SetResult(work()); }
            catch (Exception e) { tcs.SetException(e); }
        })
        {
            IsBackground = true,
        };
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        return tcs.Task;
    }
}
