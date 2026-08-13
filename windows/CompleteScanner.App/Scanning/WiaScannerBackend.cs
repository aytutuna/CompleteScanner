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
///   - devices are enumerated once per StartBrowsing (WIA hot-plug events are not wired up);
///   - Transfer() is synchronous with no progress callbacks — progress is coarse;
///   - CancelScan() cannot abort an in-flight WIA transfer, it only discards the result.
/// </summary>
public sealed class WiaScannerBackend : IScannerBackend
{
    public event Action? DevicesChanged;

    private readonly List<ScannerInfo> _devices = [];
    public IReadOnlyList<ScannerInfo> Devices => _devices;

    // WIA constants.
    private const int ScannerDeviceType = 1;
    internal const string FormatBmp = "{B96B3CAB-0728-11D3-9D7B-0000F81EF32E}";

    // Device-level property IDs (WIA_DPS_*).
    internal const string HorizontalBedSize = "3074";   // thousandths of an inch
    internal const string VerticalBedSize = "3075";
    internal const string DocumentHandlingSelect = "3088"; // 1 = FEEDER, 2 = FLATBED
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

    internal const uint PaperEmptyHResult = 0x80210003;  // WIA_ERROR_PAPER_EMPTY

    public void StartBrowsing()
    {
        RefreshDevices();
    }

    public void StopBrowsing()
    {
        if (_devices.Count == 0) return;
        _devices.Clear();
        DevicesChanged?.Invoke();
    }

    /// <summary>Re-enumerate WIA scanners (call again to pick up newly plugged devices).</summary>
    public void RefreshDevices()
    {
        var found = new List<ScannerInfo>();
        try
        {
            var managerType = Type.GetTypeFromProgID("WIA.DeviceManager");
            if (managerType is null) { ReplaceDevices(found); return; }
            dynamic manager = Activator.CreateInstance(managerType)!;
            dynamic infos = manager.DeviceInfos;
            int count = infos.Count;
            for (int i = 1; i <= count; i++) // WIA collections are 1-based
            {
                dynamic info = infos[i];
                if ((int)info.Type != ScannerDeviceType) continue;
                string id = (string)info.DeviceID;
                string name = TryGetProperty(info.Properties, "Name") as string ?? "Scanner";
                found.Add(new ScannerInfo($"wia:{id}", name, "WIA"));
            }
        }
        catch
        {
            // WIA not available (service disabled, no devices): expose nothing.
        }
        ReplaceDevices(found);
    }

    private void ReplaceDevices(List<ScannerInfo> found)
    {
        if (_devices.Select(d => d.Id).SequenceEqual(found.Select(d => d.Id))) return;
        _devices.Clear();
        _devices.AddRange(found);
        DevicesChanged?.Invoke();
    }

    public Task<IScannerSession> OpenSessionAsync(string deviceId)
    {
        var info = _devices.FirstOrDefault(d => d.Id == deviceId)
            ?? throw ScanException.DeviceUnavailable("The selected scanner is not connected.");
        string wiaId = deviceId["wia:".Length..];
        return Task.FromResult<IScannerSession>(new WiaScannerSession(info, wiaId));
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

internal sealed class WiaScannerSession(ScannerInfo info, string wiaDeviceId) : IScannerSession
{
    public ScannerInfo Info { get; } = info;
    public Action<ScanProgress>? ProgressHandler { get; set; }

    private volatile bool _cancelRequested;
    private SizeD _bedInches = new(8.5, 11.7);

    public Task<ScannerCapabilities> GetCapabilitiesAsync() => RunSta(() =>
    {
        var caps = new ScannerCapabilities();
        dynamic device = Connect();
        try
        {
            // Physical bed size arrives in thousandths of an inch.
            if (ToInt(WiaScannerBackend.TryGetProperty(device.Properties, WiaScannerBackend.HorizontalBedSize)) is { } bw
                && ToInt(WiaScannerBackend.TryGetProperty(device.Properties, WiaScannerBackend.VerticalBedSize)) is { } bh
                && bw > 0 && bh > 0)
            {
                _bedInches = new SizeD(bw / 1000.0, bh / 1000.0);
                caps.FlatbedSizeInches = _bedInches;
            }
            // The automation layer exposes no clean "supported resolutions" list; offer the
            // common ladder (the session snaps to whatever the driver accepts on scan).
            caps.SupportedResolutions = [75, 150, 200, 300, 600, 1200];
            var sources = new List<ScanSource> { ScanSource.Flatbed };
            if (WiaScannerBackend.TryGetProperty(device.Properties, WiaScannerBackend.DocumentHandlingSelect) is not null)
            {
                sources.Add(ScanSource.DocumentFeeder);
            }
            caps.Sources = sources;
            caps.SupportsOverview = true;
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
        ProgressHandler?.Invoke(new ScanProgress("Scanning overview…"));
        return RunSta(() => ScanOnce(dpi: 150, ScanSource.Flatbed, ColorMode.Color, selection: null));
    }

    public Task<IReadOnlyList<ScannedPage>> PerformScanAsync(ScanSettings settings, RectD? selection) =>
        RunSta<IReadOnlyList<ScannedPage>>(() =>
        {
            _cancelRequested = false;
            ProgressHandler?.Invoke(new ScanProgress("Scanning…"));
            var pages = new List<ScannedPage>();
            if (settings.Source == ScanSource.DocumentFeeder)
            {
                // Keep pulling sheets until the feeder reports empty; a failure mid-batch
                // keeps the sheets that already transferred (mirroring the macOS backend).
                while (true)
                {
                    RgbaImage image;
                    try
                    {
                        image = ScanOnce(settings.Resolution, ScanSource.DocumentFeeder,
                                         settings.ColorMode, selection: null);
                    }
                    catch (ScanException) when (pages.Count > 0)
                    {
                        break;
                    }
                    catch (COMException e) when ((uint)e.HResult == WiaScannerBackend.PaperEmptyHResult)
                    {
                        break;
                    }
                    if (_cancelRequested) throw ScanException.Cancelled();
                    pages.Add(new ScannedPage(image, settings.Resolution, settings.ColorMode));
                    ProgressHandler?.Invoke(new ScanProgress($"Transferred sheet {pages.Count}…"));
                }
            }
            else
            {
                var image = ScanOnce(settings.Resolution, ScanSource.Flatbed, settings.ColorMode, selection);
                if (_cancelRequested) throw ScanException.Cancelled();
                pages.Add(new ScannedPage(image, settings.Resolution, settings.ColorMode));
            }
            if (pages.Count == 0) throw ScanException.ScanFailed("The scanner did not return any image data.");
            return pages;
        });

    public void CancelScan() => _cancelRequested = true;

    public Task CloseAsync() => Task.CompletedTask; // connections are per-transfer in WIA automation

    // MARK: - One transfer

    private RgbaImage ScanOnce(int dpi, ScanSource source, ColorMode colorMode, RectD? selection)
    {
        dynamic device = Connect();
        try
        {
            if (source == ScanSource.DocumentFeeder)
            {
                WiaScannerBackend.TrySetProperty(device.Properties,
                    WiaScannerBackend.DocumentHandlingSelect, WiaScannerBackend.HandlingFeeder);
            }
            else
            {
                WiaScannerBackend.TrySetProperty(device.Properties,
                    WiaScannerBackend.DocumentHandlingSelect, WiaScannerBackend.HandlingFlatbed);
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

            ProgressHandler?.Invoke(new ScanProgress("Transferring…"));
            dynamic imageFile = item.Transfer(WiaScannerBackend.FormatBmp);
            string tempPath = Path.Combine(Path.GetTempPath(), $"CompleteScanner-{Guid.NewGuid()}.bmp");
            try
            {
                imageFile.SaveFile(tempPath);
                return WpfImageCodec.Load(tempPath);
            }
            finally
            {
                try { File.Delete(tempPath); } catch { /* best effort */ }
                Release(imageFile);
            }
        }
        catch (COMException e) when ((uint)e.HResult == WiaScannerBackend.PaperEmptyHResult)
        {
            throw; // handled by the ADF loop
        }
        catch (COMException e)
        {
            throw ScanException.ScanFailed($"WIA error 0x{e.HResult:X8}: {e.Message}");
        }
        finally
        {
            Release(device);
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
        throw ScanException.DeviceUnavailable($"{Info.Name} is no longer connected.");
    }

    private static int? ToInt(object? value) => value is null ? null : Convert.ToInt32(value);

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
