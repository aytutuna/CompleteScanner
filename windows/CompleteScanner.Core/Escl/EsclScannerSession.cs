namespace CompleteScanner.Core;

// Twin of Sources/CompleteScannerKit/Escl/EsclScannerSession.swift: the same rules and tests on both
// platforms (the Swift one also asks the iPhone for background time while a job runs).

/// <summary>
/// An open eSCL scanner: the app's scan calls turned into eSCL jobs on an
/// <see cref="EsclClient"/> (which it owns). The capabilities were read when it was opened.
/// </summary>
public sealed class EsclScannerSession(ScannerInfo info, EsclClient client, EsclCapabilities capabilities)
    : IScannerSession
{
    private CancellationTokenSource? _jobCancellation;
    private volatile bool _cancelRequested;
    /// <summary>The last job started; the connection is released only after it has ended.</summary>
    private Task _lastJob = Task.CompletedTask;

    public ScannerInfo Info { get; } = info;
    public Action<ScanProgress>? ProgressHandler { get; set; }
    public ScanStop? LastScanStop { get; private set; }
    public bool? LastScanDuplex { get; private set; }

    /// <summary>The device's capabilities as read when the session opened.</summary>
    public EsclCapabilities EsclCapabilities { get; } = capabilities;
    /// <summary>The connection in use.</summary>
    public EsclClient Client { get; } = client;

    public Task<ScannerCapabilities> GetCapabilitiesAsync() => Task.FromResult(EsclCapabilities.ToScannerCapabilities());

    public async Task<RgbaImage> PerformOverviewScanAsync(ScanSettings settings)
    {
        _cancelRequested = false;
        if (!EsclCapabilities.HasPlaten) throw ScanException.Unsupported("This scanner has no flatbed to preview.");
        ProgressHandler?.Invoke(new ScanProgress("Scanning overview…"));
        int dpi = EsclCapabilities.Platen!.Resolutions.FirstOrDefault(r => r >= 150, 150);
        var result = await RunJob(dpi, ColorMode.Color, ScanSource.Flatbed, selection: null).ConfigureAwait(true);
        if (result.Pages.Count == 0) throw ScanException.ScanFailed("The scanner returned no overview image.");
        return result.Pages[0].Image;
    }

    public async Task<IReadOnlyList<ScannedPage>> PerformScanAsync(ScanSettings settings, RectD? selection)
    {
        _cancelRequested = false;
        LastScanStop = null;
        LastScanDuplex = null;
        ProgressHandler?.Invoke(new ScanProgress("Scanning…"));
        // Black & white arrives as grayscale; the app's pipeline thresholds every page that
        // is not a color scan, so the pages keep the requested color mode. A two-sided job
        // delivers front, back, front, back…, as the app expects.
        var result = await RunJob(settings.Resolution, settings.ColorMode, settings.Source,
                                  settings.Source == ScanSource.Flatbed ? selection : null,
                                  settings.Duplex == DuplexMode.Both, settings.PaperSize).ConfigureAwait(true);
        if (result.Pages.Count == 0) throw ScanException.ScanFailed("The scanner did not return any image data.");
        LastScanStop = result.Stop;
        // A device that does not list two-sided feeding scans one side (EsclScanRequest.Create).
        if (settings.Source == ScanSource.DocumentFeeder && settings.Duplex == DuplexMode.Both)
        {
            LastScanDuplex = EsclCapabilities.SupportsDuplex;
        }
        return result.Pages;
    }

    /// <summary>
    /// Stops the job: its requests are abandoned, and the job is deleted on the device on the
    /// way out.
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

    /// <summary>
    /// Closes at once. The connection is released in the background, once a cancelled job has
    /// wound down and its deletion has been sent to the device.
    /// </summary>
    public Task CloseAsync()
    {
        CancelScan();
        _ = ReleaseWhenIdle();
        return Task.CompletedTask;
    }

    private async Task ReleaseWhenIdle()
    {
        try
        {
            await _lastJob.ConfigureAwait(false);
        }
        catch
        {
            // The scan reported its own outcome.
        }
        await Client.WhenCleanedUp().ConfigureAwait(false);
        Client.Dispose();
    }

    private async Task<EsclJobResult> RunJob(int dpi, ColorMode colorMode, ScanSource source, RectD? selection,
                                             bool duplex = false, PaperSize paperSize = PaperSize.Auto)
    {
        var request = EsclScanRequest.Create(EsclCapabilities, source, colorMode, dpi, selection, duplex, paperSize);
        using var cancellation = new CancellationTokenSource();
        _jobCancellation = cancellation;
        if (_cancelRequested) cancellation.Cancel();
        try
        {
            var job = Client.ScanAsync(request, colorMode, source, ProgressHandler, cancellation.Token);
            _lastJob = job;
            return await job.ConfigureAwait(true);
        }
        finally
        {
            _jobCancellation = null;
        }
    }
}
