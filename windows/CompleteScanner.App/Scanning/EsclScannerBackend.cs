using System.IO;
using System.Net;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using CompleteScanner.App.Services;
using CompleteScanner.Core;

namespace CompleteScanner.App.Scanning;

/// <summary>
/// Driverless network scanners over eSCL (AirScan) — plain HTTP + XML, the same protocol
/// the macOS app reaches through ImageCaptureCore's Bonjour support. The protocol logic
/// (capabilities, job settings, retries, status) lives in Core (Escl/*.cs) and is tested
/// there; this class does the I/O.
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

    /// <summary>Discovery and capability requests: a host that does not answer soon is skipped.</summary>
    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(10) };
    /// <summary>
    /// Scan jobs: some devices hold a NextDocument request open until the page has been
    /// scanned, which at high resolution takes far longer than a discovery request.
    /// </summary>
    private static readonly HttpClient JobHttp = new() { Timeout = TimeSpan.FromMinutes(2) };

    private readonly string _hostsPath;

    public EsclScannerBackend() : this(Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
        "CompleteScanner", "escl-hosts.json"))
    {
    }

    /// <param name="hostsPath">The JSON list of hosts to probe (tests point it elsewhere).</param>
    internal EsclScannerBackend(string hostsPath)
    {
        _hostsPath = hostsPath;
    }

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
            hosts = File.Exists(_hostsPath)
                ? JsonSerializer.Deserialize<List<string>>(await File.ReadAllTextAsync(_hostsPath)) ?? []
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
                var info = new ScannerInfo($"escl:{host}", name, "Network", Backend: "escl",
                                           Model: caps.MakeAndModel, HardwareId: caps.Uuid);
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
        return new EsclScannerSession(info, host, caps, JobHttp);
    }

    internal static Uri BaseUri(string host) => new($"http://{host}/eSCL/");

    internal static async Task<EsclCapabilities> FetchCapabilities(string host) =>
        EsclCapabilitiesParser.Parse(await Http.GetStringAsync(new Uri(BaseUri(host), "ScannerCapabilities")));
}

internal sealed class EsclScannerSession(ScannerInfo info, string host, EsclCapabilities caps,
                                         HttpClient http) : IScannerSession
{
    public ScannerInfo Info { get; } = info;
    public Action<ScanProgress>? ProgressHandler { get; set; }
    public ScanStop? LastScanStop { get; private set; }

    private readonly Uri _baseUri = EsclScannerBackend.BaseUri(host);
    private CancellationTokenSource? _jobCancellation;
    private volatile bool _cancelRequested;

    public Task<ScannerCapabilities> GetCapabilitiesAsync() => Task.FromResult(caps.ToScannerCapabilities());

    public async Task<RgbaImage> PerformOverviewScanAsync(ScanSettings settings)
    {
        _cancelRequested = false;
        if (!caps.HasPlaten) throw ScanException.Unsupported("This scanner has no flatbed to preview.");
        ProgressHandler?.Invoke(new ScanProgress("Scanning overview…"));
        int dpi = caps.Platen!.Resolutions.FirstOrDefault(r => r >= 150, 150);
        var pages = await RunJob(dpi, ColorMode.Color, ScanSource.Flatbed, selection: null);
        if (pages.Count == 0) throw ScanException.ScanFailed("The scanner returned no overview image.");
        return pages[0].Image;
    }

    public async Task<IReadOnlyList<ScannedPage>> PerformScanAsync(ScanSettings settings, RectD? selection)
    {
        _cancelRequested = false;
        LastScanStop = null;
        ProgressHandler?.Invoke(new ScanProgress("Scanning…"));
        var pages = await RunJob(settings.Resolution, settings.ColorMode, settings.Source,
                                 settings.Source == ScanSource.Flatbed ? selection : null);
        if (pages.Count == 0) throw ScanException.ScanFailed("The scanner did not return any image data.");
        return pages;
    }

    /// <summary>
    /// Stops the job: its requests are abandoned, and the job loop deletes the job on the
    /// device on its way out.
    /// </summary>
    public void CancelScan()
    {
        _cancelRequested = true;
        try
        {
            _jobCancellation?.Cancel();
        }
        catch (ObjectDisposedException)
        {
            // The job just finished.
        }
    }

    public Task CloseAsync() => Task.CompletedTask;

    // MARK: - One eSCL job

    private async Task<List<ScannedPage>> RunJob(int dpi, ColorMode colorMode, ScanSource source,
                                                 RectD? selection)
    {
        // Black & white arrives as grayscale; the app's pipeline thresholds every page that
        // is not a color scan, so the pages keep the requested color mode.
        var request = EsclScanRequest.Create(caps, source, colorMode, dpi, selection);
        using var cancellation = new CancellationTokenSource();
        _jobCancellation = cancellation;
        if (_cancelRequested) cancellation.Cancel();
        try
        {
            return await RunJob(request, colorMode, source, cancellation.Token);
        }
        catch (OperationCanceledException) when (_cancelRequested)
        {
            throw ScanException.Cancelled();
        }
        catch (OperationCanceledException e)
        {
            // HttpClient reports its own timeout as a cancellation.
            throw ScanException.ForProblem(ScannerProblem.CommunicationError, e.Message);
        }
        finally
        {
            _jobCancellation = null;
        }
    }

    private async Task<List<ScannedPage>> RunJob(EsclScanRequest request, ColorMode colorMode, ScanSource source,
                                                 CancellationToken token)
    {
        var scanJobs = new Uri(_baseUri, "ScanJobs");
        string body = request.ToXml();
        HttpResponseMessage jobResponse;
        try
        {
            jobResponse = await EsclRetry.SendAsync(ct => PostJob(scanJobs, body, ct), token);
        }
        catch (HttpRequestException e)
        {
            throw ScanException.ScanFailed($"Could not reach {host}: {e.Message}");
        }

        Uri jobUri;
        using (jobResponse)
        {
            if (jobResponse.StatusCode != HttpStatusCode.Created)
            {
                throw await JobFailure(source, jobResponse.StatusCode,
                    $"{Info.Name} rejected the scan job (HTTP {(int)jobResponse.StatusCode}).", token);
            }
            jobUri = EsclJob.ResolveLocation(scanJobs, jobResponse.Headers.Location?.OriginalString)
                ?? throw ScanException.ScanFailed($"{Info.Name} accepted the scan job but did not say where to fetch it.");
        }

        var pages = new List<ScannedPage>();
        // Only a job the device reported as finished (404 on NextDocument) is left alone. Any
        // other way out (cancel, error, a batch cut short) deletes it, so the device stops
        // feeding and the next scan does not find it busy.
        bool finished = false;
        try
        {
            var next = EsclJob.NextDocument(jobUri);
            // Pull page documents until the job reports no more (404). A failure after the
            // first page keeps the pages that already transferred and records why in
            // LastScanStop; before it, the failure is the scan's error.
            while (true)
            {
                if (_cancelRequested) throw ScanException.Cancelled();
                byte[] data;
                try
                {
                    using var doc = await EsclRetry.SendAsync(ct => http.GetAsync(next, ct), token);
                    if (doc.StatusCode == HttpStatusCode.NotFound)
                    {
                        // Job complete. A feeder job that ends before its first page usually
                        // means an empty feeder: ask the device.
                        finished = true;
                        if (pages.Count == 0 && await ProbeProblem(source, token) is { } problem)
                        {
                            throw ScanException.ForProblem(problem);
                        }
                        break;
                    }
                    if (!doc.IsSuccessStatusCode)
                    {
                        var failure = await JobFailure(source, doc.StatusCode,
                            $"{Info.Name} returned HTTP {(int)doc.StatusCode}.", token);
                        if (pages.Count == 0) throw failure;
                        LastScanStop = ScanStop.From(failure);
                        break;
                    }
                    data = await doc.Content.ReadAsByteArrayAsync(token);
                }
                catch (HttpRequestException e)
                {
                    if (pages.Count == 0) throw ScanException.ScanFailed(e.Message);
                    LastScanStop = ScanStop.From(ScanException.ForProblem(ScannerProblem.CommunicationError));
                    break;
                }
                catch (OperationCanceledException) when (!token.IsCancellationRequested && pages.Count > 0)
                {
                    // HttpClient's own timeout: the device stalled on this page.
                    LastScanStop = ScanStop.From(ScanException.ForProblem(ScannerProblem.CommunicationError));
                    break;
                }
                if (data.Length == 0) break;
                ProgressHandler?.Invoke(new ScanProgress($"Transferring page {pages.Count + 1}…"));
                RgbaImage image;
                try
                {
                    image = WpfImageCodec.Decode(data);
                }
                catch (Exception e)
                {
                    var unreadable = ScanException.ScanFailed(
                        $"{Info.Name} sent page {pages.Count + 1} in a form that could not be read ({e.Message}).");
                    if (pages.Count == 0) throw unreadable;
                    LastScanStop = ScanStop.From(unreadable);
                    break;
                }
                pages.Add(new ScannedPage(image, request.Resolution, colorMode));
            }
        }
        finally
        {
            if (!finished) _ = DeleteQuietly(jobUri.AbsoluteUri);
        }
        return pages;
    }

    /// <summary>
    /// POST a job request. The request itself is not cancelled with <paramref name="token"/>:
    /// a device that has already created the job would keep it (and keep feeding paper) with
    /// nobody left to delete it. A cancel stops the wait instead, and the job is deleted as
    /// soon as the device answers with its address.
    /// </summary>
    private async Task<HttpResponseMessage> PostJob(Uri scanJobs, string body, CancellationToken token)
    {
        var post = http.PostAsync(scanJobs, new StringContent(body, Encoding.UTF8, "text/xml"), CancellationToken.None);
        try
        {
            return await post.WaitAsync(token);
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested)
        {
            _ = DeleteOnceCreated(post, scanJobs);
            throw;
        }
    }

    private async Task DeleteOnceCreated(Task<HttpResponseMessage> post, Uri scanJobs)
    {
        try
        {
            using var response = await post;
            if (response.StatusCode == HttpStatusCode.Created
                && EsclJob.ResolveLocation(scanJobs, response.Headers.Location?.OriginalString) is { } job)
            {
                await DeleteQuietly(job.AbsoluteUri);
            }
        }
        catch
        {
            // The request failed, so there is no job to delete.
        }
    }

    /// <summary>
    /// The error for a failed job request: the scanner's own problem when its status names
    /// one (or "busy" for a 503 that outlasted the retries), else <paramref name="fallback"/>.
    /// </summary>
    private async Task<ScanException> JobFailure(ScanSource source, HttpStatusCode status, string fallback,
                                                 CancellationToken token)
    {
        var problem = await ProbeProblem(source, token);
        if (problem is null && EsclRetry.IsRetryable(status)) problem = ScannerProblem.Busy;
        return problem is { } p
            ? ScanException.ForProblem(p, $"HTTP {(int)status}")
            : ScanException.ScanFailed(fallback);
    }

    /// <summary>What the device's ScannerStatus says is wrong; null when it says nothing or cannot be read.</summary>
    private async Task<ScannerProblem?> ProbeProblem(ScanSource source, CancellationToken token)
    {
        try
        {
            string xml = await http.GetStringAsync(new Uri(_baseUri, "ScannerStatus"), token);
            return EsclScannerStatus.Parse(xml)?.Problem(source);
        }
        catch (Exception) when (!token.IsCancellationRequested)
        {
            return null; // no status to go on: the caller reports the original failure
        }
    }

    private async Task DeleteQuietly(string job)
    {
        try
        {
            using var response = await http.DeleteAsync(job);
        }
        catch
        {
            // best effort
        }
    }
}
