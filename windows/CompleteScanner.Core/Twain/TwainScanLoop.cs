namespace CompleteScanner.Core;

/// <summary>How long <see cref="TwainScanLoop"/> waits for a source before giving up on it.</summary>
/// <param name="FirstImage">From enabling the source to its first image: scanners warm their lamp and pick the first sheet.</param>
/// <param name="NextEvent">Between any two later events (strips, images, the end). Not applied while a native
/// transfer runs: that is one call lasting the whole physical scan, with no events in between.</param>
/// <param name="Stop">For the source to stop and disable after the app asked it to.</param>
public sealed record TwainLoopTimeouts(TimeSpan FirstImage, TimeSpan NextEvent, TimeSpan Stop)
{
    public static TwainLoopTimeouts Default { get; } =
        new(TimeSpan.FromMinutes(3), TimeSpan.FromMinutes(3), TimeSpan.FromSeconds(15));
}

/// <summary>One page a TWAIN acquisition delivered.</summary>
public sealed record TwainPage(RgbaImage Image, int Dpi, ColorMode ColorMode);

/// <summary>How a TWAIN acquisition ended.</summary>
public sealed class TwainScanResult
{
    /// <summary>The pages that transferred completely, in order. Empty when <see cref="Error"/> is set.</summary>
    public List<TwainPage> Pages { get; } = [];
    /// <summary>Why a batch stopped before the feeder ran out, while still returning its pages.</summary>
    public ScanStop? Stop { get; set; }
    /// <summary>Why nothing was returned (cancelled, a scanner problem, a failure).</summary>
    public ScanException? Error { get; set; }
    /// <summary>
    /// The source did not get back to state 4 when asked: the driver is stuck, and the session
    /// should not be used again until it is reopened.
    /// </summary>
    public bool DriverStuck { get; set; }
    /// <summary>A memory transfer came in a format the app cannot read: use native transfers from now on.</summary>
    public bool UseNativeTransfers { get; set; }
    /// <summary>
    /// The pages alternate front, back: two-sided was asked for and the source confirmed
    /// CAP_DUPLEXENABLED (read after the scan when its own window was shown). False when it
    /// could not be confirmed, so one-sided pages are never paired up as sheets.
    /// </summary>
    public bool Duplex { get; set; }

    /// <summary>The pages, or <see cref="Error"/> thrown.</summary>
    public List<TwainPage> PagesOrThrow() => Error is { } error ? throw error : Pages;
}

/// <summary>
/// The TWAIN acquisition state machine, run on the app's TWAIN thread against an
/// <see cref="ITwainTransport"/>: negotiate, enable, collect images until the source is
/// disabled again, and decide what the scan returns.
/// <list type="bullet">
/// <item>A source that reports itself offline, or a feeder it says is empty, fails before
/// anything is enabled.</item>
/// <item>Memory strips are assembled per image (<see cref="TwainImageAssembler"/>); native
/// images are decoded as bitmaps. An image counts once the next one is announced or the
/// source finishes; an image whose transfer failed or was cancelled is dropped.</item>
/// <item>A failure before the first page fails the scan with the matching
/// <see cref="ScannerProblem"/>; a later one keeps the pages and reports a
/// <see cref="ScanStop"/>, except an empty feeder, which is just the end of the stack.</item>
/// <item>Cancelling (the token) resets the pending transfers and returns
/// <see cref="ScanException.Cancelled"/>; a cancel in the driver's window keeps the pages
/// already scanned, and with none is a cancelled scan.</item>
/// <item>A source that stays silent past <see cref="TwainLoopTimeouts"/> is stopped the same
/// way and the scan fails (or stops, keeping its pages) with "not responding". The wait for
/// the first image has no limit while the driver's own window is open (the user is in it),
/// nor has a native transfer once its image was announced (the source sends nothing until
/// the whole image is scanned, however long that takes); cancelling still ends both.</item>
/// <item>A two-sided request reports <see cref="TwainScanResult.Duplex"/> only when the
/// source confirms CAP_DUPLEXENABLED.</item>
/// </list>
/// </summary>
public static class TwainScanLoop
{
    /// <param name="started">
    /// Called once the scan is under way, before the first wait; from there on only the loop's
    /// own time limits apply. That is once the source is enabled, or, with the driver's own
    /// window, just before enabling it: the user is in the window from then on, and some
    /// drivers keep it open inside the enable call.
    /// </param>
    public static TwainScanResult Run(ITwainTransport transport, TwainScanRequest request, TwainLoopTimeouts timeouts,
                                      CancellationToken token, Action<ScanProgress>? progress = null,
                                      Action? started = null)
    {
        var result = new TwainScanResult();
        TwainApplied applied;
        try
        {
            applied = transport.Apply(request);
        }
        catch (TwainException e)
        {
            result.Error = TwainErrors.ToScanException(e);
            return result;
        }
        if (request.Feeder && applied.FeederLoaded == false)
        {
            result.Error = ScanException.ForProblem(ScannerProblem.FeederEmpty);
            return result;
        }
        if (token.IsCancellationRequested)
        {
            result.Error = ScanException.Cancelled();
            return result;
        }
        if (request.ShowDriverWindow) started?.Invoke();
        try
        {
            transport.Enable(request.ShowDriverWindow);
        }
        catch (TwainException e)
        {
            result.Error = TwainErrors.ToScanException(e);
            if (!transport.Disable(timeouts.Stop)) result.DriverStuck = true;
            return result;
        }
        if (!request.ShowDriverWindow) started?.Invoke();

        var pages = new List<TwainPage>();
        TwainImageAssembler? current = null;
        TwainImageInfo? currentInfo = null;
        ScanException? failure = null;
        bool cancelled = false, driverCancelled = false, timedOut = false, stopping = false, finished = false;
        // A native image was announced and has not arrived yet.
        bool nativeTransfer = false;

        // An interrupted image is dropped, unless every row of it had already arrived.
        void Settle()
        {
            if (current is { IsComplete: true }) Complete();
            current = null;
            currentInfo = null;
            nativeTransfer = false;
        }

        void Stop()
        {
            if (stopping) return;
            stopping = true;
            Settle();
            transport.RequestStop();
        }

        void Complete()
        {
            if (current is { HasData: true } done)
            {
                try
                {
                    pages.Add(Page(done.ToImage(), currentInfo, request));
                    progress?.Invoke(new ScanProgress($"Transferred page {pages.Count}…"));
                }
                catch (FormatException e)
                {
                    failure ??= ScanException.ScanFailed(e.Message);
                }
            }
            current = null;
            currentInfo = null;
        }

        while (!finished)
        {
            if (!stopping && token.IsCancellationRequested)
            {
                cancelled = true;
                Stop();
            }
            TimeSpan wait = stopping ? timeouts.Stop
                : nativeTransfer ? Timeout.InfiniteTimeSpan
                : pages.Count == 0 && current is null
                    ? (request.ShowDriverWindow ? Timeout.InfiniteTimeSpan : timeouts.FirstImage)
                    : timeouts.NextEvent;
            var next = transport.WaitForEvent(wait, stopping ? CancellationToken.None : token);
            if (next is null)
            {
                if (!stopping && token.IsCancellationRequested) continue; // stop at the top of the loop
                if (stopping)
                {
                    // Asked to stop and still nothing: the driver is stuck.
                    result.DriverStuck = true;
                    break;
                }
                timedOut = true;
                Stop();
                continue;
            }
            switch (next)
            {
                case TwainImageReady ready:
                    Complete();
                    if (stopping) break;
                    currentInfo = ready.Info;
                    if (applied.TransferMechanism == TwainTransferMechanisms.Memory)
                    {
                        if (ready.Info is not { } info)
                        {
                            failure ??= ScanException.ScanFailed("The scanner did not describe the image it was sending.");
                            result.UseNativeTransfers = true;
                            Stop();
                            break;
                        }
                        try
                        {
                            current = new TwainImageAssembler(info, applied.PixelFlavor, applied.MsbFirst);
                        }
                        catch (Exception e) when (e is NotSupportedException or FormatException)
                        {
                            failure ??= ScanException.ScanFailed($"{e.Message} Scan again: the next scan uses another transfer method.");
                            result.UseNativeTransfers = true;
                            Stop();
                        }
                    }
                    else
                    {
                        nativeTransfer = true;
                    }
                    break;
                case TwainStripReceived received:
                    if (current is null) break;
                    try
                    {
                        current.Add(received.Strip);
                    }
                    catch (FormatException e)
                    {
                        failure ??= ScanException.ScanFailed($"{e.Message} Scan again: the next scan uses another transfer method.");
                        result.UseNativeTransfers = true;
                        Stop();
                    }
                    break;
                case TwainNativeImage native:
                    current = null;
                    nativeTransfer = false;
                    if (stopping) break;
                    try
                    {
                        var image = TwainRaster.DecodeBitmap(native.Bitmap, out double bitmapDpi);
                        var info = currentInfo is null
                            ? new TwainImageInfo(image.Width, image.Height, request.PixelType, 0, bitmapDpi)
                            : currentInfo.XResolution > 0 ? currentInfo : currentInfo with { XResolution = bitmapDpi };
                        pages.Add(Page(image, info, request));
                        progress?.Invoke(new ScanProgress($"Transferred page {pages.Count}…"));
                    }
                    catch (FormatException e)
                    {
                        failure ??= ScanException.ScanFailed(e.Message);
                        Stop();
                    }
                    currentInfo = null;
                    break;
                case TwainTransferFailed failed:
                    Settle();
                    failure ??= TwainErrors.ToScanException(failed.ReturnCode, failed.ConditionCode, failed.Detail);
                    // The source resets its pending transfers after an error; make sure it stops.
                    Stop();
                    break;
                case TwainTransferCancelled:
                    Settle();
                    driverCancelled = true;
                    break;
                case TwainFinished:
                    if (!stopping) Complete();
                    nativeTransfer = false;
                    finished = true;
                    break;
            }
        }
        if (!transport.Disable(timeouts.Stop)) result.DriverStuck = true;

        if (cancelled)
        {
            result.Error = ScanException.Cancelled();
            return result;
        }
        if (failure is null && timedOut)
        {
            failure = ScanException.ScanFailed(
                "The scanner stopped responding. Check that it is turned on and connected, then try again.");
        }
        if (failure is not null)
        {
            if (pages.Count == 0)
            {
                result.Error = failure;
                return result;
            }
            // An empty feeder after some sheets is just the end of the stack.
            if (failure.Problem != ScannerProblem.FeederEmpty) result.Stop = ScanStop.From(failure);
        }
        else if (pages.Count == 0)
        {
            result.Error = driverCancelled || request.ShowDriverWindow
                ? ScanException.Cancelled()
                : request.Feeder
                    ? ScanException.ForProblem(ScannerProblem.FeederEmpty)
                    : ScanException.ScanFailed("The scanner did not return any image data.");
            return result;
        }
        result.Pages.AddRange(pages);
        if (request.Duplex)
        {
            // What the source really did, not what was asked. The user can turn two-sided off
            // in the driver's window: read it back once the source is disabled again; a stuck
            // source cannot be asked, and is taken as one-sided.
            bool? enabled = !request.ShowDriverWindow ? applied.DuplexEnabled
                : result.DriverStuck ? null
                : transport.ReadDuplexEnabled();
            result.Duplex = enabled == true;
        }
        return result;
    }

    /// <summary>
    /// A delivered page: its resolution is the source's when it reports one (the driver's
    /// window may change it), else the requested one; its color mode follows the image's
    /// pixel type when known, else the request's.
    /// </summary>
    private static TwainPage Page(RgbaImage image, TwainImageInfo? info, TwainScanRequest request)
    {
        int dpi = info is { XResolution: > 0 } ? (int)Math.Round(info.XResolution) : request.Resolution;
        var mode = info is null ? request.ColorMode : info.PixelType switch
        {
            TwainPixelTypes.BlackWhite => ColorMode.BlackWhite,
            TwainPixelTypes.Gray => ColorMode.Grayscale,
            TwainPixelTypes.Rgb => ColorMode.Color,
            _ => request.ColorMode,
        };
        return new TwainPage(image, dpi > 0 ? dpi : request.Resolution, mode);
    }
}
