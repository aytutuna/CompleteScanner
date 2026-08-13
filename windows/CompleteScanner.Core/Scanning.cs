namespace CompleteScanner.Core;

// Port of Sources/CompleteScannerKit/Core/ScannerBackend.swift. The Swift protocols are
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

    void CancelScan();
    Task CloseAsync();
}
