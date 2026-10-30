using System.Net;
using System.Net.Http;
using System.Text;

namespace LazyScan.Core;

// Twin of Sources/CompleteScannerKit/Escl/EsclClient.swift (URLSession there: the same job rules and
// tests on both platforms; the Swift one downloads each page to a file and also stops for the app
// being suspended, which only the iPhone has).

/// <summary>Timeouts and retry timing of an <see cref="EsclClient"/>.</summary>
public sealed class EsclClientOptions
{
    /// <summary>Capabilities, status and delete requests: a device that does not answer this soon is treated as gone.</summary>
    public TimeSpan RequestTimeout { get; init; } = TimeSpan.FromSeconds(10);
    /// <summary>
    /// Job requests: some devices hold a NextDocument request open until the page has been
    /// scanned, which at high resolution takes far longer than other requests.
    /// </summary>
    public TimeSpan JobTimeout { get; init; } = TimeSpan.FromMinutes(2);
    /// <summary>Waits between 503 answers; null = <see cref="EsclRetryPolicy.Default"/>.</summary>
    public EsclRetryPolicy? RetryPolicy { get; init; }
    /// <summary>How a retry waits; null = real time (tests pass a fake clock).</summary>
    public Func<TimeSpan, CancellationToken, Task>? Delay { get; init; }
    /// <summary>Time since a request's first attempt, for the retry policy; null = real time.</summary>
    public Func<Func<TimeSpan>>? StartClock { get; init; }
}

/// <summary>The pages one eSCL job delivered, and why it ended early when it did.</summary>
/// <param name="Stop">Set when a feeder job failed after its first page; the pages are kept.</param>
public sealed record EsclJobResult(IReadOnlyList<ScannedPage> Pages, ScanStop? Stop);

/// <summary>
/// The eSCL (AirScan) protocol over HTTP(S) for one scanner: capabilities, status, and scan
/// jobs (create, pull pages until the device reports the end, delete a job cut short). The
/// transport is an injected <see cref="HttpMessageHandler"/> and image decoding an injected
/// function, so it runs against a stub handler in tests. Errors are
/// <see cref="ScanException"/>s, or an <see cref="EsclCertificateException"/> when
/// <paramref name="validator"/> refused the scanner's certificate.
/// </summary>
/// <param name="baseUri">The eSCL root, ending in a slash (<see cref="ScannerAddress.BaseUri"/>).</param>
/// <param name="handler">Owned by the client and disposed with it.</param>
/// <param name="deviceName">The scanner's name in messages.</param>
public sealed class EsclClient(Uri baseUri, HttpMessageHandler handler, Func<byte[], RgbaImage> decodeImage,
                               string deviceName, EsclCertificateValidator? validator = null,
                               EsclClientOptions? options = null) : IDisposable
{
    private readonly EsclClientOptions _options = options ?? new EsclClientOptions();
    private readonly HttpClient _http = new(handler, disposeHandler: false)
    {
        Timeout = (options ?? new EsclClientOptions()).RequestTimeout,
    };
    private readonly HttpClient _jobHttp = new(handler, disposeHandler: false)
    {
        Timeout = (options ?? new EsclClientOptions()).JobTimeout,
    };
    private readonly object _cleanupGate = new();
    private Task _cleanup = Task.CompletedTask;

    public Uri BaseUri { get; } = baseUri;
    public string DeviceName { get; } = deviceName;

    /// <summary>
    /// The device's ScannerCapabilities. Throws <see cref="HttpRequestException"/> (no answer,
    /// an error status), <see cref="TaskCanceledException"/> (timeout), <see cref="FormatException"/>
    /// (not a capabilities document) or <see cref="EsclCertificateException"/>.
    /// </summary>
    public async Task<EsclCapabilities> GetCapabilitiesAsync(CancellationToken token = default)
    {
        try
        {
            string xml = await _http.GetStringAsync(new Uri(BaseUri, "ScannerCapabilities"), token).ConfigureAwait(false);
            return EsclCapabilitiesParser.Parse(xml);
        }
        catch (HttpRequestException) when (validator?.TakeRejection() is { } rejection)
        {
            throw rejection;
        }
    }

    /// <summary>What the device's ScannerStatus says is wrong for <paramref name="source"/>; null when it says nothing or cannot be read.</summary>
    public async Task<ScannerProblem?> GetProblemAsync(ScanSource source, CancellationToken token = default)
    {
        try
        {
            string xml = await _http.GetStringAsync(new Uri(BaseUri, "ScannerStatus"), token).ConfigureAwait(false);
            return EsclScannerStatus.Parse(xml)?.Problem(source);
        }
        catch (Exception) when (!token.IsCancellationRequested)
        {
            validator?.TakeRejection();
            return null; // no status to go on: the caller reports the original failure
        }
    }

    /// <summary>
    /// Runs one scan job: posts <paramref name="request"/>, then pulls page documents until the
    /// device answers 404 (the job is complete), retrying 503 answers (<see cref="EsclRetry"/>).
    /// <list type="bullet">
    /// <item>A failure before the first page fails the scan, explained by the device's status
    /// when it names a problem (an empty feeder, a jam, …).</item>
    /// <item>A failure after it (an error answer, a dropped or stalled connection, a page that
    /// cannot be decoded) keeps the pages received and reports why in
    /// <see cref="EsclJobResult.Stop"/>.</item>
    /// <item>A job that ends without pages is reported as the device's problem when its status
    /// names one; otherwise an empty page list is returned.</item>
    /// <item>Any way out but the device's 404 (cancel, error, a batch cut short) deletes the
    /// job on the device, so it stops feeding and the next scan does not find it busy.</item>
    /// <item>Cancelling <paramref name="token"/> throws <see cref="ScanException.Cancelled"/>;
    /// a request timing out is a communication error.</item>
    /// </list>
    /// </summary>
    public async Task<EsclJobResult> ScanAsync(EsclScanRequest request, ColorMode colorMode, ScanSource source,
                                               Action<ScanProgress>? progress, CancellationToken token)
    {
        try
        {
            return await RunJob(request, colorMode, source, progress, token).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested)
        {
            throw ScanException.Cancelled();
        }
        catch (OperationCanceledException e)
        {
            // HttpClient reports its own timeout as a cancellation.
            throw ScanException.ForProblem(ScannerProblem.CommunicationError, e.Message);
        }
    }

    /// <summary>Completes when the job deletions started so far have finished (they never fault).</summary>
    public Task WhenCleanedUp()
    {
        lock (_cleanupGate) return _cleanup;
    }

    public void Dispose()
    {
        _http.Dispose();
        _jobHttp.Dispose();
        handler.Dispose();
    }

    private Task<HttpResponseMessage> SendWithRetry(Func<CancellationToken, Task<HttpResponseMessage>> send,
                                                    CancellationToken token) =>
        EsclRetry.SendAsync(send, token, _options.RetryPolicy, _options.Delay, _options.StartClock?.Invoke());

    private async Task<EsclJobResult> RunJob(EsclScanRequest request, ColorMode colorMode, ScanSource source,
                                             Action<ScanProgress>? progress, CancellationToken token)
    {
        var scanJobs = new Uri(BaseUri, "ScanJobs");
        string body = request.ToXml();
        HttpResponseMessage jobResponse;
        try
        {
            jobResponse = await SendWithRetry(ct => PostJob(scanJobs, body, ct), token).ConfigureAwait(false);
        }
        catch (HttpRequestException e)
        {
            if (validator?.TakeRejection() is { } rejection) throw rejection;
            throw ScanException.ScanFailed($"Could not reach {DeviceName}: {e.Message}");
        }

        Uri jobUri;
        using (jobResponse)
        {
            if (jobResponse.StatusCode != HttpStatusCode.Created)
            {
                throw await JobFailure(source, jobResponse.StatusCode,
                    $"{DeviceName} rejected the scan job (HTTP {(int)jobResponse.StatusCode}).", token).ConfigureAwait(false);
            }
            jobUri = EsclJob.ResolveLocation(scanJobs, jobResponse.Headers.Location?.OriginalString)
                ?? throw ScanException.ScanFailed($"{DeviceName} accepted the scan job but did not say where to fetch it.");
        }

        var pages = new List<ScannedPage>();
        ScanStop? stop = null;
        bool finished = false;
        try
        {
            var next = EsclJob.NextDocument(jobUri);
            while (true)
            {
                if (token.IsCancellationRequested) throw ScanException.Cancelled();
                byte[] data;
                try
                {
                    using var doc = await SendWithRetry(ct => _jobHttp.GetAsync(next, ct), token).ConfigureAwait(false);
                    if (doc.StatusCode == HttpStatusCode.NotFound)
                    {
                        // Job complete. A feeder job that ends before its first page usually
                        // means an empty feeder: ask the device.
                        finished = true;
                        if (pages.Count == 0 && await GetProblemAsync(source, token).ConfigureAwait(false) is { } problem)
                        {
                            throw ScanException.ForProblem(problem);
                        }
                        break;
                    }
                    if (!doc.IsSuccessStatusCode)
                    {
                        var failure = await JobFailure(source, doc.StatusCode,
                            $"{DeviceName} returned HTTP {(int)doc.StatusCode}.", token).ConfigureAwait(false);
                        if (pages.Count == 0) throw failure;
                        stop = ScanStop.From(failure);
                        break;
                    }
                    data = await doc.Content.ReadAsByteArrayAsync(token).ConfigureAwait(false);
                }
                catch (HttpRequestException e)
                {
                    if (validator?.TakeRejection() is { } rejection) throw rejection;
                    if (pages.Count == 0) throw ScanException.ScanFailed(e.Message);
                    stop = ScanStop.From(ScanException.ForProblem(ScannerProblem.CommunicationError));
                    break;
                }
                catch (OperationCanceledException) when (!token.IsCancellationRequested && pages.Count > 0)
                {
                    // HttpClient's own timeout: the device stalled on this page.
                    stop = ScanStop.From(ScanException.ForProblem(ScannerProblem.CommunicationError));
                    break;
                }
                if (data.Length == 0) break;
                progress?.Invoke(new ScanProgress($"Transferring page {pages.Count + 1}…"));
                RgbaImage image;
                try
                {
                    image = decodeImage(data);
                }
                catch (Exception e)
                {
                    var unreadable = ScanException.ScanFailed(
                        $"{DeviceName} sent page {pages.Count + 1} in a form that could not be read ({e.Message}).");
                    if (pages.Count == 0) throw unreadable;
                    stop = ScanStop.From(unreadable);
                    break;
                }
                pages.Add(new ScannedPage(image, request.Resolution, colorMode));
            }
        }
        finally
        {
            if (!finished) TrackCleanup(DeleteQuietly(jobUri));
        }
        return new EsclJobResult(pages, stop);
    }

    /// <summary>
    /// POST a job request. The request itself is not cancelled with <paramref name="token"/>:
    /// a device that has already created the job would keep it (and keep feeding paper) with
    /// nobody left to delete it. A cancel stops the wait instead, and the job is deleted as
    /// soon as the device answers with its address.
    /// </summary>
    private async Task<HttpResponseMessage> PostJob(Uri scanJobs, string body, CancellationToken token)
    {
        var post = _jobHttp.PostAsync(scanJobs, new StringContent(body, Encoding.UTF8, "text/xml"), CancellationToken.None);
        try
        {
            return await post.WaitAsync(token).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested)
        {
            TrackCleanup(DeleteOnceCreated(post, scanJobs));
            throw;
        }
    }

    private async Task DeleteOnceCreated(Task<HttpResponseMessage> post, Uri scanJobs)
    {
        try
        {
            using var response = await post.ConfigureAwait(false);
            if (response.StatusCode == HttpStatusCode.Created
                && EsclJob.ResolveLocation(scanJobs, response.Headers.Location?.OriginalString) is { } job)
            {
                await DeleteQuietly(job).ConfigureAwait(false);
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
        var problem = await GetProblemAsync(source, token).ConfigureAwait(false);
        if (problem is null && EsclRetry.IsRetryable(status)) problem = ScannerProblem.Busy;
        return problem is { } p
            ? ScanException.ForProblem(p, $"HTTP {(int)status}")
            : ScanException.ScanFailed(fallback);
    }

    private async Task DeleteQuietly(Uri job)
    {
        try
        {
            using var response = await _http.DeleteAsync(job).ConfigureAwait(false);
        }
        catch
        {
            // Best effort.
        }
    }

    private void TrackCleanup(Task deletion)
    {
        lock (_cleanupGate) _cleanup = Task.WhenAll(_cleanup, deletion);
    }
}
