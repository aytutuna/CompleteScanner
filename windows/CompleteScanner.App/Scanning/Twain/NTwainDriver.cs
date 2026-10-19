using System.Collections.Concurrent;
using System.Runtime.InteropServices;
using CompleteScanner.Core;
using NTwain;
using NTwain.Data;
using TwainException = CompleteScanner.Core.TwainException;

namespace CompleteScanner.App.Scanning.Twain;

/// <summary>
/// <see cref="ITwainTransport"/> over one open NTwain data source. Capability calls run on
/// the caller's thread (the app's <see cref="TwainThread"/>); NTwain runs enabling, the
/// driver's messages and the transfers on its own message-loop thread and raises its events
/// there. The handlers only copy what arrived into a queue (<see cref="WaitForEvent"/>) and
/// answer "cancel all" once a stop was requested, so a slow consumer never holds up the driver.
///
/// The driver's own settings window gets no owner window: as a child of the app's main
/// window (owned by another thread) it would tie the two threads' input together, and a
/// modal one would disable the main window and its Cancel button.
///
/// Experimental, untested against real TWAIN drivers: the flow follows the TWAIN 2.3
/// specification and NTwain 3.7's documented behaviour, and the scan logic it feeds is
/// covered by tests in Core (TwainScanLoopTests) through a fake transport.
/// </summary>
internal sealed class NTwainDriver : ITwainTransport, IDisposable
{
    private readonly TwainSession _session;
    private readonly DataSource _source;
    private readonly BlockingCollection<TwainEvent> _events = [];
    private volatile bool _stopRequested;
    private bool _disposed;

    /// <param name="session">The process-wide TWAIN session, with the data source manager open.</param>
    /// <param name="source">An opened data source (state 4).</param>
    public NTwainDriver(TwainSession session, DataSource source)
    {
        _session = session;
        _source = source;
        _session.TransferReady += OnTransferReady;
        _session.DataTransferred += OnDataTransferred;
        _session.TransferError += OnTransferError;
        _session.TransferCanceled += OnTransferCanceled;
        _session.SourceDisabled += OnSourceDisabled;
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _session.TransferReady -= OnTransferReady;
        _session.DataTransferred -= OnDataTransferred;
        _session.TransferError -= OnTransferError;
        _session.TransferCanceled -= OnTransferCanceled;
        _session.SourceDisabled -= OnSourceDisabled;
    }

    // MARK: - Capabilities

    public TwainDeviceCaps ReadCapabilities()
    {
        try
        {
            var caps = _source.Capabilities;
            caps.ICapUnits.SetValue(Unit.Inches);

            bool? online = caps.CapDeviceOnline.IsSupported ? caps.CapDeviceOnline.GetCurrent() == BoolType.True : null;
            bool uiControllable = !caps.CapUIControllable.IsSupported || caps.CapUIControllable.GetCurrent() == BoolType.True;

            // A source without CAP_FEEDERENABLED is a flatbed. Otherwise try both settings:
            // a feeder-only scanner refuses "off", a flatbed-only one refuses "on".
            bool hasFeeder = false, hasFlatbed = true;
            SizeD? feederSize = null, bedSize = null;
            List<int> sizes = [];
            int duplex = TwainDuplexKinds.None;
            if (caps.CapFeederEnabled.IsSupported)
            {
                hasFeeder = caps.CapFeederEnabled.SetValue(BoolType.True) == ReturnCode.Success
                            && caps.CapFeederEnabled.GetCurrent() == BoolType.True;
                if (hasFeeder)
                {
                    feederSize = PhysicalSize(caps);
                    if (caps.ICapSupportedSizes.IsSupported)
                    {
                        sizes = [.. caps.ICapSupportedSizes.GetValues().Select(s => (int)s)];
                    }
                    if (caps.CapDuplex.IsSupported) duplex = (int)caps.CapDuplex.GetCurrent();
                }
                hasFlatbed = caps.CapFeederEnabled.SetValue(BoolType.False) == ReturnCode.Success
                             && caps.CapFeederEnabled.GetCurrent() == BoolType.False;
                if (!hasFlatbed && !hasFeeder) hasFlatbed = true;
            }
            if (hasFlatbed) bedSize = PhysicalSize(caps);

            int native = caps.ICapXNativeResolution.IsSupported ? (int)Math.Round((double)caps.ICapXNativeResolution.GetCurrent()) : 0;
            return new TwainDeviceCaps
            {
                Online = online,
                UIControllable = uiControllable,
                HasFlatbed = hasFlatbed,
                HasFeeder = hasFeeder,
                DuplexKind = duplex,
                Resolutions = Resolutions(caps.ICapXResolution),
                NativeResolution = native,
                PixelTypes = caps.ICapPixelType.IsSupported ? [.. caps.ICapPixelType.GetValues().Select(p => (int)p)] : [],
                FlatbedSizeInches = bedSize,
                FeederSizeInches = feederSize,
                SupportedSizes = sizes,
                MemoryTransfer = MemoryOffered(caps),
            };
        }
        catch (Exception e) when (e is not TwainException)
        {
            throw new TwainException("Reading the scanner's capabilities", TwainReturnCodes.Failure, TwainConditionCodes.Bummer, e.Message);
        }
    }

    private static SizeD? PhysicalSize(ICapabilities caps)
    {
        if (!caps.ICapPhysicalWidth.IsSupported || !caps.ICapPhysicalHeight.IsSupported) return null;
        double width = caps.ICapPhysicalWidth.GetCurrent();
        double height = caps.ICapPhysicalHeight.GetCurrent();
        return width > 0 && height > 0 ? new SizeD(width, height) : null;
    }

    private static bool MemoryOffered(ICapabilities caps) =>
        caps.ICapXferMech.IsSupported && caps.ICapXferMech.GetValues().Contains(XferMech.Memory);

    /// <summary>ICAP_XRESOLUTION as whole dpi: a range is expanded with its own step (bounded by <see cref="ResolutionList.ExpandRange"/>).</summary>
    private static List<int> Resolutions(ICapWrapper<TWFix32> resolution)
    {
        if (!resolution.IsSupported) return [];
        var raw = resolution.GetValuesRaw();
        if (raw.ContainerType == ContainerType.Range)
        {
            int min = (int)Math.Round(Convert.ToDouble(raw.RangeMinValue));
            int max = (int)Math.Round(Convert.ToDouble(raw.RangeMaxValue));
            int step = (int)Math.Round(Convert.ToDouble(raw.RangeStepSize));
            return [.. ResolutionList.ExpandRange(min, max, step)];
        }
        IEnumerable<object> values = raw.ContainerType switch
        {
            ContainerType.OneValue => raw.OneValue is { } one ? [one] : [],
            _ => raw.CollectionValues ?? [],
        };
        return [.. values.Select(v => (int)Math.Round(Convert.ToDouble(v))).Where(v => v > 0).Distinct()];
    }

    // MARK: - Negotiation

    public TwainApplied Apply(TwainScanRequest request)
    {
        try
        {
            var caps = _source.Capabilities;
            caps.ICapUnits.SetValue(Unit.Inches);
            // No progress windows of the driver's own when the app shows progress itself.
            if (!request.ShowDriverWindow && caps.CapIndicators.IsSupported) caps.CapIndicators.SetValue(BoolType.False);
            if (caps.CapFeederEnabled.IsSupported)
            {
                caps.CapFeederEnabled.SetValue(request.Feeder ? BoolType.True : BoolType.False);
                if (request.Feeder && caps.CapAutoFeed.IsSupported) caps.CapAutoFeed.SetValue(BoolType.True);
            }
            // Both sides only when asked for; a driver that defaults to two-sided scans one side otherwise.
            // What the source settled on is read back: a refused value leaves the driver's own.
            if (caps.CapDuplexEnabled.IsSupported)
            {
                caps.CapDuplexEnabled.SetValue(request.Duplex ? BoolType.True : BoolType.False);
            }
            bool? duplexEnabled = ReadDuplexEnabled();
            if (caps.CapXferCount.IsSupported) caps.CapXferCount.SetValue(request.TransferCount);

            caps.ICapPixelType.SetValue((PixelType)request.PixelType);
            if (caps.ICapBitDepth.IsSupported) caps.ICapBitDepth.SetValue(request.BitDepth);
            if (caps.ICapPixelFlavor.IsSupported) caps.ICapPixelFlavor.SetValue(PixelFlavor.Chocolate);
            if (caps.ICapBitOrder.IsSupported) caps.ICapBitOrder.SetValue(BitOrder.MsbFirst);
            if (caps.ICapCompression.IsSupported) caps.ICapCompression.SetValue(CompressionType.None);
            caps.ICapXResolution.SetValue((float)request.Resolution);
            caps.ICapYResolution.SetValue((float)request.Resolution);

            bool sizeSet = request.SupportedSize != TwainSizes.None && caps.ICapSupportedSizes.IsSupported
                           && caps.ICapSupportedSizes.SetValue((SupportedSize)request.SupportedSize) == ReturnCode.Success;
            if (!sizeSet && request.FrameInches is { } frame)
            {
                // A fixed paper size would override the frame.
                if (caps.ICapSupportedSizes.IsSupported) caps.ICapSupportedSizes.SetValue(SupportedSize.None);
                var layout = new TWImageLayout
                {
                    Frame = new TWFrame
                    {
                        Left = (float)frame.MinX,
                        Top = (float)frame.MinY,
                        Right = (float)frame.MaxX,
                        Bottom = (float)frame.MaxY,
                    },
                    DocumentNumber = 1,
                    PageNumber = 1,
                    FrameNumber = 1,
                };
                _source.DGImage.ImageLayout.Set(layout);
            }

            // The format the source settled on decides whether the app can read memory strips.
            int pixelType = (int)caps.ICapPixelType.GetCurrent();
            int bitDepth = caps.ICapBitDepth.IsSupported ? caps.ICapBitDepth.GetCurrent() : request.BitDepth;
            int mechanism = TwainScanRequests.TransferMechanism(MemoryOffered(caps), request.PreferMemory, pixelType, bitDepth);
            if (mechanism == TwainTransferMechanisms.Memory
                && caps.ICapXferMech.SetValue(XferMech.Memory) != ReturnCode.Success)
            {
                mechanism = TwainTransferMechanisms.Native;
            }
            if (mechanism == TwainTransferMechanisms.Native && caps.ICapXferMech.IsSupported)
            {
                caps.ICapXferMech.SetValue(XferMech.Native);
            }

            int flavor = caps.ICapPixelFlavor.IsSupported ? (int)caps.ICapPixelFlavor.GetCurrent() : TwainPixelFlavors.Chocolate;
            bool msbFirst = !caps.ICapBitOrder.IsSupported || caps.ICapBitOrder.GetCurrent() == BitOrder.MsbFirst;
            bool? feederLoaded = null;
            if (request.Feeder && caps.CapPaperDetectable.IsSupported && caps.CapPaperDetectable.GetCurrent() == BoolType.True
                && caps.CapFeederLoaded.IsSupported)
            {
                feederLoaded = caps.CapFeederLoaded.GetCurrent() == BoolType.True;
            }
            return new TwainApplied(mechanism, flavor, feederLoaded, msbFirst, duplexEnabled);
        }
        catch (Exception e) when (e is not TwainException)
        {
            throw new TwainException("Setting up the scan", TwainReturnCodes.Failure, TwainConditionCodes.Bummer, e.Message);
        }
    }

    // MARK: - Acquisition

    public void Enable(bool showDriverWindow)
    {
        while (_events.TryTake(out _))
        {
            // Leftovers of an earlier acquisition.
        }
        _stopRequested = false;
        ReturnCode rc;
        try
        {
            rc = _source.Enable(showDriverWindow ? SourceEnableMode.ShowUI : SourceEnableMode.NoUI, false, IntPtr.Zero);
        }
        catch (Exception e)
        {
            throw new TwainException("Starting the scan", TwainReturnCodes.Failure, TwainConditionCodes.Bummer, e.Message);
        }
        if (rc != ReturnCode.Success)
        {
            throw new TwainException("Starting the scan", (int)rc, ConditionOf(_source));
        }
    }

    public TwainEvent? WaitForEvent(TimeSpan timeout, CancellationToken token)
    {
        int milliseconds = timeout == Timeout.InfiniteTimeSpan
            ? Timeout.Infinite
            : (int)Math.Clamp(timeout.TotalMilliseconds, 0, int.MaxValue);
        try
        {
            return _events.TryTake(out var next, milliseconds, token) ? next : null;
        }
        catch (OperationCanceledException)
        {
            return null;
        }
    }

    public void RequestStop()
    {
        _stopRequested = true;
        // Pending transfers are cancelled at the next "transfer ready". A source that is
        // enabled but not transferring (waiting for paper, or showing its window) has to be
        // disabled. That call goes through NTwain's message-loop thread, which may be busy
        // with a transfer, so it is not waited for here.
        if (_session.State == 5) _ = Task.Run(StepDown);
    }

    public bool Disable(TimeSpan timeout)
    {
        if (_session.State <= 4) return true;
        var stepDown = Task.Run(StepDown);
        stepDown.Wait(timeout);
        return _session.State <= 4;
    }

    public bool? ReadDuplexEnabled()
    {
        try
        {
            var duplexEnabled = _source.Capabilities.CapDuplexEnabled;
            return duplexEnabled.IsSupported ? duplexEnabled.GetCurrent() == BoolType.True : null;
        }
        catch (Exception e)
        {
            System.Diagnostics.Trace.TraceWarning($"TWAIN: could not read CAP_DUPLEXENABLED: {e.Message}");
            return null;
        }
    }

    private void StepDown()
    {
        try
        {
            if (_session.State > 4) _session.ForceStepDown(4);
        }
        catch (Exception e)
        {
            System.Diagnostics.Trace.TraceWarning($"TWAIN: could not disable the source: {e.Message}");
        }
    }

    /// <summary>Closes the data source (back to state 3).</summary>
    public void Close()
    {
        Disable(TimeSpan.FromSeconds(5));
        try
        {
            if (_session.State == 4) _source.Close();
        }
        catch (Exception e)
        {
            System.Diagnostics.Trace.TraceWarning($"TWAIN: could not close the source: {e.Message}");
        }
        Dispose();
    }

    private static int ConditionOf(DataSource source)
    {
        try
        {
            return (int)source.GetStatus().ConditionCode;
        }
        catch
        {
            return TwainConditionCodes.Bummer;
        }
    }

    // MARK: - NTwain events (raised on NTwain's message-loop thread)

    private bool IsMine() => !_disposed && ReferenceEquals(_session.CurrentSource, _source);

    private void OnTransferReady(object? sender, TransferReadyEventArgs e)
    {
        if (!IsMine()) return;
        if (_stopRequested)
        {
            e.CancelAll = true;
            return;
        }
        TwainImageInfo? info = null;
        try
        {
            if (e.PendingImageInfo is { } pending) info = Describe(pending);
        }
        catch
        {
            // No description: the scan loop decides what to do.
        }
        _events.Add(new TwainImageReady(info));
    }

    private void OnDataTransferred(object? sender, DataTransferredEventArgs e)
    {
        if (!IsMine()) return;
        try
        {
            if (e.TransferType == XferMech.Memory && e.MemoryData is { } data && e.MemoryInfo is { } block)
            {
                _events.Add(new TwainStripReceived(new TwainStrip(
                    (int)block.Columns, (int)block.Rows, (int)block.XOffset, (int)block.YOffset,
                    (int)block.BytesPerRow, data, (int)block.Compression)));
            }
            else if (e.NativeData != IntPtr.Zero)
            {
                // The bitmap is freed as soon as this handler returns: copy it now.
                _events.Add(new TwainNativeImage(CopyBitmap(e.NativeData)));
            }
        }
        catch (FormatException)
        {
            _events.Add(new TwainTransferFailed(TwainReturnCodes.Failure, TwainConditionCodes.Bummer,
                                                "The scanner sent an image in a format this app cannot read."));
        }
        catch (Exception error)
        {
            _events.Add(new TwainTransferFailed(TwainReturnCodes.Failure, TwainConditionCodes.Bummer, error.Message));
        }
    }

    /// <summary>
    /// Copies the device-independent bitmap of a native transfer, sized from its own header and
    /// passed on without a file header. NTwain's GetNativeImageStream is not used: its file
    /// header leaves the bit-field masks out of the pixel offset, it trusts biSizeImage (which
    /// may be 0), and it refuses V4 and V5 headers.
    /// </summary>
    /// <exception cref="FormatException">Not a bitmap the app reads.</exception>
    private static byte[] CopyBitmap(IntPtr bitmap)
    {
        var header = new byte[40];
        Marshal.Copy(bitmap, header, 0, header.Length);
        long length = TwainRaster.BitmapLength(header);
        // Never read past the memory block the driver allocated; a short one is reported as cut short.
        long allocated = AllocatedSize(bitmap);
        if (allocated > 0) length = Math.Min(length, allocated);
        if (length > Array.MaxLength) throw new FormatException("The scanner sent an image too large to read.");
        var copy = new byte[length];
        Marshal.Copy(bitmap, copy, 0, copy.Length);
        return copy;
    }

    /// <summary>The size of the global memory block <paramref name="pointer"/> (a locked handle) points to; 0 when unknown.</summary>
    private static long AllocatedSize(IntPtr pointer)
    {
        IntPtr handle = GlobalHandle(pointer);
        return handle == IntPtr.Zero ? 0 : (long)(ulong)GlobalSize(handle);
    }

    [DllImport("kernel32.dll")]
    private static extern IntPtr GlobalHandle(IntPtr pointer);

    [DllImport("kernel32.dll")]
    private static extern UIntPtr GlobalSize(IntPtr handle);

    private void OnTransferError(object? sender, TransferErrorEventArgs e)
    {
        if (!IsMine()) return;
        int condition = e.SourceStatus is { } status ? (int)status.ConditionCode : TwainConditionCodes.Bummer;
        _events.Add(new TwainTransferFailed((int)e.ReturnCode, condition, e.Exception?.Message));
    }

    private void OnTransferCanceled(object? sender, TransferCanceledEventArgs e)
    {
        if (!IsMine()) return;
        _events.Add(new TwainTransferCancelled());
    }

    private void OnSourceDisabled(object? sender, EventArgs e)
    {
        if (!IsMine()) return;
        _events.Add(new TwainFinished());
    }

    private static TwainImageInfo Describe(TWImageInfo info) => new(
        Width: info.ImageWidth,
        Height: info.ImageLength,
        PixelType: (int)info.PixelType,
        BitsPerPixel: info.BitsPerPixel,
        XResolution: info.XResolution,
        YResolution: info.YResolution,
        Compression: (int)info.Compression,
        Planar: info.Planar);
}
