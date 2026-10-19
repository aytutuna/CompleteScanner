namespace CompleteScanner.Core;

// The seam between the TWAIN scan logic in Core (TwainScanLoop, TwainScanRequests) and the
// TWAIN library the Windows app hosts (CompleteScanner.App/Scanning/Twain/NTwainDriver.cs).
// Tests drive the same logic through a scripted fake. Windows only, like TwainCodes.cs.

/// <summary>
/// What an open TWAIN data source reports about itself (state 4), in the units the app uses.
/// </summary>
public sealed class TwainDeviceCaps
{
    /// <summary>CAP_DEVICEONLINE: false when the driver is installed but the scanner is off or unplugged; null when not reported.</summary>
    public bool? Online { get; init; }
    /// <summary>CAP_UICONTROLLABLE: the source can scan without showing its own window.</summary>
    public bool UIControllable { get; init; } = true;
    public bool HasFlatbed { get; init; } = true;
    /// <summary>CAP_FEEDERENABLED can be turned on.</summary>
    public bool HasFeeder { get; init; }
    /// <summary>CAP_DUPLEX, a <see cref="TwainDuplexKinds"/> value.</summary>
    public int DuplexKind { get; init; } = TwainDuplexKinds.None;
    /// <summary>ICAP_XRESOLUTION values (a range already expanded).</summary>
    public IReadOnlyList<int> Resolutions { get; init; } = [];
    /// <summary>ICAP_XNATIVERESOLUTION, the optical resolution; 0 when unknown.</summary>
    public int NativeResolution { get; init; }
    /// <summary>ICAP_PIXELTYPE values (<see cref="TwainPixelTypes"/>).</summary>
    public IReadOnlyList<int> PixelTypes { get; init; } = [];
    /// <summary>ICAP_PHYSICALWIDTH × HEIGHT with the feeder off, in inches.</summary>
    public SizeD? FlatbedSizeInches { get; init; }
    /// <summary>ICAP_PHYSICALWIDTH × HEIGHT with the feeder on, in inches.</summary>
    public SizeD? FeederSizeInches { get; init; }
    /// <summary>ICAP_SUPPORTEDSIZES values (<see cref="TwainSizes"/>) with the feeder on.</summary>
    public IReadOnlyList<int> SupportedSizes { get; init; } = [];
    /// <summary>ICAP_XFERMECH offers memory transfers.</summary>
    public bool MemoryTransfer { get; init; } = true;
}

/// <summary>What <see cref="ITwainTransport.Apply"/> set up, as the source reports it back.</summary>
/// <param name="TransferMechanism">A <see cref="TwainTransferMechanisms"/> value: Memory or Native.</param>
/// <param name="PixelFlavor">ICAP_PIXELFLAVOR in effect (<see cref="TwainPixelFlavors"/>).</param>
/// <param name="FeederLoaded">CAP_FEEDERLOADED for a feeder scan when the source detects paper; null when it cannot tell.</param>
/// <param name="MsbFirst">ICAP_BITORDER in effect for 1-bit memory strips.</param>
public sealed record TwainApplied(int TransferMechanism, int PixelFlavor = TwainPixelFlavors.Chocolate,
                                  bool? FeederLoaded = null, bool MsbFirst = true);

/// <summary>Something the source reported while it is enabled (states 5 to 7).</summary>
public abstract record TwainEvent;

/// <summary>An image is about to transfer (MSG_XFERREADY / the next pending transfer); the previous one, if any, is complete.</summary>
/// <param name="Info">The image's description; null when the source would not give one.</param>
public sealed record TwainImageReady(TwainImageInfo? Info) : TwainEvent;

/// <summary>One block of the current image (memory transfer).</summary>
public sealed record TwainStripReceived(TwainStrip Strip) : TwainEvent;

/// <summary>The whole current image as a device-independent bitmap (native transfer), copied out of the source's memory.</summary>
public sealed record TwainNativeImage(byte[] Bitmap) : TwainEvent;

/// <summary>The current transfer failed; the source reported these codes.</summary>
public sealed record TwainTransferFailed(int ReturnCode, int ConditionCode, string? Detail = null) : TwainEvent;

/// <summary>The user cancelled the current transfer in the driver's own window (TWRC_CANCEL).</summary>
public sealed record TwainTransferCancelled : TwainEvent;

/// <summary>The source is disabled again (back to state 4): nothing more will arrive.</summary>
public sealed record TwainFinished : TwainEvent;

/// <summary>
/// One open TWAIN data source, as the scan logic sees it. All members are called from one
/// thread (the app's TWAIN thread); events produced on other threads are queued until
/// <see cref="WaitForEvent"/> takes them.
/// </summary>
public interface ITwainTransport
{
    /// <summary>Reads what the source offers. Throws <see cref="TwainException"/> when the source fails.</summary>
    TwainDeviceCaps ReadCapabilities();

    /// <summary>
    /// Negotiates the scan: units, feeder, transfer count, pixel type and depth, resolution,
    /// area, transfer mechanism (memory when <see cref="TwainScanRequest.PreferMemory"/> and the
    /// source and format allow it, else native), no progress indicators. Values the source
    /// rejects are left at its own; throws <see cref="TwainException"/> only when nothing can be set.
    /// </summary>
    TwainApplied Apply(TwainScanRequest request);

    /// <summary>Enables the source (state 5), with or without its own window. Throws <see cref="TwainException"/> when it refuses.</summary>
    void Enable(bool showDriverWindow);

    /// <summary>
    /// The next event, waiting at most <paramref name="timeout"/>
    /// (<see cref="Timeout.InfiniteTimeSpan"/> = no limit); null when nothing arrived in time
    /// or <paramref name="token"/> was cancelled first.
    /// </summary>
    TwainEvent? WaitForEvent(TimeSpan timeout, CancellationToken token);

    /// <summary>
    /// Asks the source to stop: the pending transfers are reset (MSG_RESET) at the next
    /// chance, and a source waiting for paper or showing its window is disabled. Returns at
    /// once; <see cref="TwainFinished"/> follows. Idempotent.
    /// </summary>
    void RequestStop();

    /// <summary>
    /// Makes sure the source is disabled (state 4) whatever happened, waiting at most
    /// <paramref name="timeout"/>. False when it is still not disabled: the driver is stuck.
    /// </summary>
    bool Disable(TimeSpan timeout);
}
