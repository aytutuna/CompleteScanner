using System.Globalization;
using System.IO;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Xml.Linq;
using CompleteScanner.App.Services;
using CompleteScanner.Core;

namespace CompleteScanner.App.Scanning;

/// <summary>
/// Driverless network scanners over eSCL (AirScan) — plain HTTP + XML, the same protocol
/// the macOS app reaches through ImageCaptureCore's Bonjour support.
///
/// ⚠ EXPERIMENTAL, UNTESTED AGAINST HARDWARE. Scaffold limitations:
///   - no mDNS/Bonjour discovery yet — scanners are configured by hostname/IP in
///     %APPDATA%\CompleteScanner\escl-hosts.json (a JSON array like ["192.168.1.50",
///     "epson.local:8080"]); each reachable host appears as a device;
///   - HTTP only (no TLS variant), root path fixed at /eSCL.
/// </summary>
public sealed class EsclScannerBackend : IScannerBackend
{
    public event Action? DevicesChanged;

    private readonly List<ScannerInfo> _devices = [];
    public IReadOnlyList<ScannerInfo> Devices => _devices;

    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(10) };

    private static string HostsPath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
        "CompleteScanner", "escl-hosts.json");

    public void StartBrowsing()
    {
        _ = ProbeHostsAsync();
    }

    public void StopBrowsing()
    {
        if (_devices.Count == 0) return;
        _devices.Clear();
        DevicesChanged?.Invoke();
    }

    private async Task ProbeHostsAsync()
    {
        List<string> hosts;
        try
        {
            hosts = File.Exists(HostsPath)
                ? JsonSerializer.Deserialize<List<string>>(await File.ReadAllTextAsync(HostsPath)) ?? []
                : [];
        }
        catch
        {
            hosts = [];
        }

        foreach (string host in hosts)
        {
            try
            {
                var caps = await FetchCapabilities(host);
                string name = caps.MakeAndModel ?? host;
                var info = new ScannerInfo($"escl:{host}", name, "Network");
                if (_devices.All(d => d.Id != info.Id))
                {
                    _devices.Add(info);
                    DevicesChanged?.Invoke();
                }
            }
            catch
            {
                // Host unreachable or not an eSCL scanner: skip silently.
            }
        }
    }

    public async Task<IScannerSession> OpenSessionAsync(string deviceId)
    {
        var info = _devices.FirstOrDefault(d => d.Id == deviceId)
            ?? throw ScanException.DeviceUnavailable("The selected scanner is not connected.");
        string host = deviceId["escl:".Length..];
        EsclCapabilities caps;
        try
        {
            caps = await FetchCapabilities(host);
        }
        catch (Exception e)
        {
            throw ScanException.SessionFailed(e.Message);
        }
        return new EsclScannerSession(info, host, caps, Http);
    }

    // MARK: - Capabilities

    internal sealed class EsclCapabilities
    {
        public string? MakeAndModel;
        public List<int> Resolutions = [];
        public SizeD BedInches = new(8.5, 11.7);
        public bool HasAdf;
    }

    internal static async Task<EsclCapabilities> FetchCapabilities(string host)
    {
        var xml = XDocument.Parse(
            await Http.GetStringAsync($"http://{host}/eSCL/ScannerCapabilities"));
        var caps = new EsclCapabilities
        {
            MakeAndModel = FirstLocal(xml, "MakeAndModel")?.Value,
            HasAdf = FirstLocal(xml, "Adf") is not null,
        };
        // Resolutions arrive as discrete values and/or min/max/step ranges; ResolutionList
        // applies the same accuracy rules as the macOS backend (eSCL reports no optical
        // resolution, so nothing is dropped as interpolated).
        var supported = new HashSet<int>();
        foreach (var res in xml.Descendants().Where(e => e.Name.LocalName == "DiscreteResolution"))
        {
            if (int.TryParse(FirstLocal(res, "XResolution")?.Value, out int dpi)) supported.Add(dpi);
        }
        foreach (var range in xml.Descendants().Where(e => e.Name.LocalName == "XResolutionRange"))
        {
            if (int.TryParse(FirstLocal(range, "Min")?.Value, out int min)
                && int.TryParse(FirstLocal(range, "Max")?.Value, out int max)
                && min > 0 && max >= min)
            {
                int step = int.TryParse(FirstLocal(range, "Step")?.Value, out int s) ? s : 1;
                supported.UnionWith(ResolutionList.ExpandRange(min, max, step));
            }
        }
        caps.Resolutions = ResolutionList.Build(preferred: null, supported, nativeResolution: 0);
        // Platen dimensions arrive in 1/300ths of an inch.
        if (FirstLocal(xml, "Platen") is { } platen)
        {
            double? w = ParseThreeHundredths(FirstLocal(platen, "MaxWidth")?.Value);
            double? h = ParseThreeHundredths(FirstLocal(platen, "MaxHeight")?.Value);
            if (w is { } bw && h is { } bh && bw > 0 && bh > 0) caps.BedInches = new SizeD(bw, bh);
        }
        return caps;
    }

    private static XElement? FirstLocal(XContainer root, string localName) =>
        root.Descendants().FirstOrDefault(e => e.Name.LocalName == localName);

    private static double? ParseThreeHundredths(string? value) =>
        double.TryParse(value, NumberStyles.Any, CultureInfo.InvariantCulture, out double v)
            ? v / 300.0
            : null;
}

internal sealed class EsclScannerSession(ScannerInfo info, string host,
                                         EsclScannerBackend.EsclCapabilities caps,
                                         HttpClient http) : IScannerSession
{
    public ScannerInfo Info { get; } = info;
    public Action<ScanProgress>? ProgressHandler { get; set; }

    private string? _activeJobUri;
    private volatile bool _cancelRequested;

    public Task<ScannerCapabilities> GetCapabilitiesAsync() =>
        Task.FromResult(new ScannerCapabilities
        {
            SupportedResolutions = caps.Resolutions.Count > 0
                ? caps.Resolutions
                : [75, 150, 200, 300, 600],
            Sources = caps.HasAdf
                ? [ScanSource.Flatbed, ScanSource.DocumentFeeder]
                : [ScanSource.Flatbed],
            FlatbedSizeInches = caps.BedInches,
            SupportsOverview = true,
        });

    public async Task<RgbaImage> PerformOverviewScanAsync(ScanSettings settings)
    {
        _cancelRequested = false;
        ProgressHandler?.Invoke(new ScanProgress("Scanning overview…"));
        int dpi = caps.Resolutions.FirstOrDefault(r => r >= 150, 150);
        var pages = await RunJob(dpi, ColorMode.Color, ScanSource.Flatbed, selection: null);
        if (pages.Count == 0) throw ScanException.ScanFailed("The scanner returned no overview image.");
        return pages[0].Image;
    }

    public async Task<IReadOnlyList<ScannedPage>> PerformScanAsync(ScanSettings settings, RectD? selection)
    {
        _cancelRequested = false;
        ProgressHandler?.Invoke(new ScanProgress("Scanning…"));
        var pages = await RunJob(settings.Resolution, settings.ColorMode, settings.Source,
                                 settings.Source == ScanSource.Flatbed ? selection : null);
        if (pages.Count == 0) throw ScanException.ScanFailed("The scanner did not return any image data.");
        return pages;
    }

    public void CancelScan()
    {
        _cancelRequested = true;
        if (_activeJobUri is { } job)
        {
            _ = http.DeleteAsync(job); // best-effort eSCL job cancellation
        }
    }

    public Task CloseAsync() => Task.CompletedTask;

    // MARK: - One eSCL job

    private async Task<List<ScannedPage>> RunJob(int dpi, ColorMode colorMode, ScanSource source,
                                                 RectD? selection)
    {
        string colorModeXml = colorMode switch
        {
            ColorMode.Color => "RGB24",
            ColorMode.Grayscale => "Grayscale8",
            _ => "BlackAndWhite1",
        };
        string inputSource = source == ScanSource.DocumentFeeder ? "Feeder" : "Platen";

        // Region in 1/300ths of an inch, from the normalized top-left selection.
        var region = new RectD(0, 0, caps.BedInches.Width, caps.BedInches.Height);
        if (selection is { } sel)
        {
            var clamped = sel.Standardized.Intersection(new RectD(0, 0, 1, 1));
            if (clamped.Width > 0.001 && clamped.Height > 0.001)
            {
                region = new RectD(clamped.MinX * caps.BedInches.Width,
                                   clamped.MinY * caps.BedInches.Height,
                                   clamped.Width * caps.BedInches.Width,
                                   clamped.Height * caps.BedInches.Height);
            }
        }
        string Inches300(double inches) =>
            ((int)Math.Round(inches * 300)).ToString(CultureInfo.InvariantCulture);

        string request = $"""
            <?xml version="1.0" encoding="UTF-8"?>
            <scan:ScanSettings xmlns:scan="http://schemas.hp.com/imaging/escl/2011/05/03"
                               xmlns:pwg="http://www.pwg.org/schemas/2010/12/sm">
              <pwg:Version>2.0</pwg:Version>
              <pwg:ScanRegions>
                <pwg:ScanRegion>
                  <pwg:ContentRegionUnits>escl:ThreeHundredthsOfInches</pwg:ContentRegionUnits>
                  <pwg:XOffset>{Inches300(region.MinX)}</pwg:XOffset>
                  <pwg:YOffset>{Inches300(region.MinY)}</pwg:YOffset>
                  <pwg:Width>{Inches300(region.Width)}</pwg:Width>
                  <pwg:Height>{Inches300(region.Height)}</pwg:Height>
                </pwg:ScanRegion>
              </pwg:ScanRegions>
              <pwg:InputSource>{inputSource}</pwg:InputSource>
              <scan:ColorMode>{colorModeXml}</scan:ColorMode>
              <scan:XResolution>{dpi.ToString(CultureInfo.InvariantCulture)}</scan:XResolution>
              <scan:YResolution>{dpi.ToString(CultureInfo.InvariantCulture)}</scan:YResolution>
              <pwg:DocumentFormat>image/jpeg</pwg:DocumentFormat>
            </scan:ScanSettings>
            """;

        HttpResponseMessage jobResponse;
        try
        {
            jobResponse = await http.PostAsync($"http://{host}/eSCL/ScanJobs",
                new StringContent(request, Encoding.UTF8, "text/xml"));
        }
        catch (Exception e)
        {
            throw ScanException.ScanFailed($"Could not reach {host}: {e.Message}");
        }
        if (jobResponse.StatusCode != System.Net.HttpStatusCode.Created)
        {
            throw ScanException.ScanFailed($"{Info.Name} rejected the scan job (HTTP {(int)jobResponse.StatusCode}).");
        }
        string jobUri = jobResponse.Headers.Location?.IsAbsoluteUri == true
            ? jobResponse.Headers.Location.ToString()
            : $"http://{host}{jobResponse.Headers.Location}";
        _activeJobUri = jobUri;

        var pages = new List<ScannedPage>();
        try
        {
            // Pull page documents until the job reports no more (404).
            while (true)
            {
                if (_cancelRequested) throw ScanException.Cancelled();
                HttpResponseMessage doc;
                try
                {
                    doc = await http.GetAsync($"{jobUri}/NextDocument");
                }
                catch (Exception e)
                {
                    if (pages.Count > 0) break; // keep what already transferred
                    throw ScanException.ScanFailed(e.Message);
                }
                if (doc.StatusCode == System.Net.HttpStatusCode.NotFound) break; // job complete
                if (!doc.IsSuccessStatusCode)
                {
                    if (pages.Count > 0) break;
                    throw ScanException.ScanFailed($"{Info.Name} returned HTTP {(int)doc.StatusCode}.");
                }
                byte[] jpeg = await doc.Content.ReadAsByteArrayAsync();
                if (jpeg.Length == 0) break;
                ProgressHandler?.Invoke(new ScanProgress($"Transferring page {pages.Count + 1}…"));
                var image = WpfImageCodec.Decode(jpeg);
                pages.Add(new ScannedPage(image, dpi, colorMode));
            }
        }
        finally
        {
            _activeJobUri = null;
        }
        return pages;
    }
}
