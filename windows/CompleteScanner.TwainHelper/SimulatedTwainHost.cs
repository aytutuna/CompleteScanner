using System.Buffers.Binary;
using CompleteScanner.Core;

namespace CompleteScanner.TwainHelper;

/// <summary>
/// Stand-in scanners for <c>--simulate</c>: the app's tests run the real helper process, pipe and
/// protocol against these instead of TWAIN (this PC may have no 32-bit driver, or no Data Source
/// Manager at all). Each source exercises one path: memory strips split into chunks, a native
/// bitmap with progress, a paper jam, an offline scanner, a busy one, a crash, a hang, and a slow
/// feeder to cancel. "WIA-…" stands for the Windows WIA bridge the app leaves out.
/// </summary>
internal sealed class SimulatedTwainHost : ITwainHelperHost
{
    public const string Scanner = "CompleteScanner Simulated Scanner";
    public const string Native = "CompleteScanner Simulated Native";
    public const string Jam = "CompleteScanner Simulated Jam";
    public const string Offline = "CompleteScanner Simulated Offline";
    public const string Busy = "CompleteScanner Simulated Busy";
    public const string Crash = "CompleteScanner Simulated Crash";
    public const string Hang = "CompleteScanner Simulated Hang";
    public const string Slow = "CompleteScanner Simulated Slow";
    public const string WiaBridge = "WIA-CompleteScanner Simulated Bridge";

    private static readonly string[] Names = [Scanner, Native, Jam, Offline, Busy, Crash, Hang, Slow, WiaBridge];

    public TwainHelperSourceList ListSources() =>
        new(TwainAvailability.Available, [.. Names.Select(name => new TwainHelperSource(name, "CompleteScanner", "Simulated"))]);

    public ITwainTransport Open(string name)
    {
        if (!Names.Contains(name)) throw ScanException.DeviceUnavailable($"The TWAIN driver \"{name}\" is no longer installed.");
        if (name == Busy) throw ScanException.ForProblem(ScannerProblem.Busy, "TWAIN TWCC_MAXCONNECTIONS");
        return new SimulatedSource(name);
    }

    public void Close(ITwainTransport source)
    {
    }

    /// <summary>One stand-in source. Its pages are 8.5 × 11 inches at the requested resolution.</summary>
    private sealed class SimulatedSource(string name) : ITwainTransport
    {
        private TwainScanRequest? _request;
        private IEnumerator<(TwainEvent Event, int DelayMs)>? _script;
        private bool _stopRequested;

        public TwainDeviceCaps ReadCapabilities()
        {
            if (name == Hang) Thread.Sleep(Timeout.Infinite);
            return new TwainDeviceCaps
            {
                Online = name != Offline,
                HasFlatbed = name != Slow,
                HasFeeder = name is Scanner or Jam or Slow,
                Resolutions = [75, 100, 150, 200, 300],
                NativeResolution = 300,
                PixelTypes = [TwainPixelTypes.BlackWhite, TwainPixelTypes.Gray, TwainPixelTypes.Rgb],
                FlatbedSizeInches = new SizeD(8.5, 11.7),
                FeederSizeInches = name is Scanner or Jam or Slow ? new SizeD(8.5, 14) : null,
                MemoryTransfer = name != Native,
            };
        }

        public TwainApplied Apply(TwainScanRequest request)
        {
            _request = request;
            return new TwainApplied(name == Native ? TwainTransferMechanisms.Native : TwainTransferMechanisms.Memory,
                                    FeederLoaded: request.Feeder ? true : null);
        }

        public void Enable(bool showDriverWindow)
        {
            // A driver that takes the whole process down with it.
            if (name == Crash) Environment.Exit(70);
            var request = _request ?? throw new TwainException("Starting the scan", TwainReturnCodes.Failure, TwainConditionCodes.SequenceError);
            _stopRequested = false;
            _script = Script(request).GetEnumerator();
        }

        public TwainEvent? WaitForEvent(TimeSpan timeout, CancellationToken token)
        {
            if (_script is null)
            {
                Thread.Sleep(timeout == Timeout.InfiniteTimeSpan ? 25 : (int)Math.Clamp(timeout.TotalMilliseconds, 0, 25));
                return null;
            }
            if (_stopRequested || !_script.MoveNext())
            {
                _script = null;
                return new TwainFinished();
            }
            var (next, delay) = _script.Current;
            if (delay > 0) Thread.Sleep(delay);
            return next;
        }

        public void RequestStop() => _stopRequested = true;

        public bool Disable(TimeSpan timeout)
        {
            _script = null;
            return true;
        }

        public bool? ReadDuplexEnabled() => null;

        private IEnumerable<(TwainEvent, int)> Script(TwainScanRequest request)
        {
            int dpi = Math.Clamp(request.Resolution, 50, 300);
            int width = (int)Math.Round(8.5 * dpi), height = 11 * dpi;
            switch (name)
            {
                case Native:
                    yield return (new TwainImageReady(new TwainImageInfo(width, height, TwainPixelTypes.Rgb, 24, dpi, dpi)), 0);
                    yield return (new TwainNativeImage(Bitmap(width, height, dpi, page: 1)), 0);
                    break;
                case Jam:
                    foreach (var step in GrayPage(width, height, dpi, page: 1, strips: 2, delayMs: 0)) yield return step;
                    yield return (new TwainTransferFailed(TwainReturnCodes.Failure, TwainConditionCodes.PaperJam), 0);
                    break;
                case Slow:
                    for (int page = 1; page <= 50; page++)
                    {
                        foreach (var step in GrayPage(100, 100, dpi, page, strips: 4, delayMs: 100)) yield return step;
                    }
                    break;
                default:
                    int pages = request.Feeder ? 3 : 1;
                    for (int page = 1; page <= pages; page++)
                    {
                        foreach (var step in GrayPage(width, height, dpi, page, strips: 2, delayMs: 0)) yield return step;
                    }
                    break;
            }
        }

        /// <summary>A gray page in memory strips; sample (x, y) of page n is <see cref="Sample"/>.</summary>
        private static IEnumerable<(TwainEvent, int)> GrayPage(int width, int height, int dpi, int page, int strips, int delayMs)
        {
            yield return (new TwainImageReady(new TwainImageInfo(width, height, TwainPixelTypes.Gray, 8, dpi, dpi)), delayMs);
            int rowsPerStrip = (height + strips - 1) / strips;
            for (int top = 0; top < height; top += rowsPerStrip)
            {
                int rows = Math.Min(rowsPerStrip, height - top);
                var data = new byte[width * rows];
                for (int y = 0; y < rows; y++)
                {
                    for (int x = 0; x < width; x++) data[y * width + x] = Sample(x, top + y, page);
                }
                yield return (new TwainStripReceived(new TwainStrip(width, rows, 0, top, width, data)), delayMs);
            }
        }

        public static byte Sample(int x, int y, int page) => (byte)((x + 2 * y + 37 * page) % 251);

        /// <summary>A bottom-up 24-bit device-independent bitmap without file header, as a native transfer delivers it.</summary>
        private static byte[] Bitmap(int width, int height, int dpi, int page)
        {
            int stride = (width * 3 + 3) & ~3;
            var bitmap = new byte[40 + stride * height];
            var header = bitmap.AsSpan(0, 40);
            BinaryPrimitives.WriteInt32LittleEndian(header[0..], 40);
            BinaryPrimitives.WriteInt32LittleEndian(header[4..], width);
            BinaryPrimitives.WriteInt32LittleEndian(header[8..], height);
            BinaryPrimitives.WriteInt16LittleEndian(header[12..], 1);
            BinaryPrimitives.WriteInt16LittleEndian(header[14..], 24);
            BinaryPrimitives.WriteInt32LittleEndian(header[20..], stride * height);
            int pixelsPerMeter = (int)Math.Round(dpi / 0.0254);
            BinaryPrimitives.WriteInt32LittleEndian(header[24..], pixelsPerMeter);
            BinaryPrimitives.WriteInt32LittleEndian(header[28..], pixelsPerMeter);
            for (int y = 0; y < height; y++)
            {
                int row = 40 + (height - 1 - y) * stride;
                for (int x = 0; x < width; x++)
                {
                    bitmap[row + x * 3] = (byte)(40 * page); // blue
                    bitmap[row + x * 3 + 1] = (byte)(y % 256); // green
                    bitmap[row + x * 3 + 2] = (byte)(x % 256); // red
                }
            }
            return bitmap;
        }
    }
}
