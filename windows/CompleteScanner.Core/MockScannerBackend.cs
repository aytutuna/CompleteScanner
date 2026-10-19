namespace CompleteScanner.Core;

/// <summary>
/// A demo scanner that needs no hardware: it renders deterministic synthetic flatbed
/// images in pure C#, so the whole app (overview, selection, photo splitting, PDF export)
/// can be exercised end to end. It also has a document feeder holding
/// <see cref="FeederSheetCount"/> two-sided letter-size sheets, which it scans one side or
/// both (<see cref="FeederDuplex"/>), so two-sided scanning, turning the stack over by hand and
/// paper sizes can be tried without hardware. Port of
/// Sources/CompleteScannerKit/Backends/MockScannerBackend.swift.
///
/// Divergence from the macOS mock: the demo document page renders text-shaped bars rather
/// than real glyphs (the Core has no font rasterizer), so OCR demos need a real scan or a
/// shell-provided page. The photo bed — what exercises the detector — is faithful.
/// </summary>
public sealed class MockScannerBackend : IScannerBackend
{
    /// <summary>Sheets the demo feeder holds unless <see cref="FeederSheetCount"/> is changed.</summary>
    public const int DefaultFeederSheetCount = 3;

    public event Action? DevicesChanged;

    private readonly List<ScannerInfo> _devices = [];
    public IReadOnlyList<ScannerInfo> Devices => _devices;

    /// <summary>
    /// Sheets a feeder scan delivers, read when the scan starts; 0 simulates an empty feeder
    /// (the scan fails with <see cref="ScannerProblem.FeederEmpty"/>).
    /// </summary>
    public int FeederSheetCount { get; set; } = DefaultFeederSheetCount;

    /// <summary>
    /// Simulates a paper jam: after this many sheets the next one jams, read when the scan
    /// starts. The sheets before it are kept and the session's
    /// <see cref="IScannerSession.LastScanStop"/> says why the batch stopped; a jam on the first
    /// sheet fails the scan with <see cref="ScannerProblem.PaperJam"/>. null (the default)
    /// never jams.
    /// </summary>
    public int? FeederJamsAfter { get; set; }

    /// <summary>
    /// The feeder scans both sides in one pass (reported as <see cref="ScannerCapabilities.SupportsDuplex"/>,
    /// read when the capabilities are read). Default true; false shows a feeder that scans one side.
    /// </summary>
    public bool FeederDuplex { get; set; } = true;

    /// <summary>
    /// The stack in the feeder is turned over: a one-sided scan delivers the backs, last sheet
    /// first. The demo turns its stack over by itself after every one-sided scan made for
    /// turning over by hand (<see cref="DuplexMode.Manual"/>), as the user is asked to; any
    /// other feeder scan puts it back the right way up. A scan cut short by a jam leaves it as
    /// it is: the user clears the jam and scans the rest of the same side. Settable to start
    /// from either side.
    /// </summary>
    public bool FeederStackTurnedOver { get; set; }

    public void StartBrowsing()
    {
        if (_devices.Count > 0) return;
        _devices.Add(new ScannerInfo("mock:demo", "Demo Scanner", "Demo", IsDemo: true, Backend: "mock"));
        DevicesChanged?.Invoke();
    }

    public void StopBrowsing()
    {
        if (_devices.Count == 0) return;
        _devices.Clear();
        DevicesChanged?.Invoke();
    }

    public Task<IScannerSession> OpenSessionAsync(string deviceId)
    {
        var info = _devices.FirstOrDefault(d => d.Id == deviceId)
            ?? throw ScanException.DeviceUnavailable("The demo scanner is not available.");
        return Task.FromResult<IScannerSession>(new MockScannerSession(info, this));
    }
}

/// <param name="backend">Source of the feeder's settings, read at the start of each feeder scan.</param>
internal sealed class MockScannerSession(ScannerInfo info, MockScannerBackend backend) : IScannerSession
{
    public ScannerInfo Info { get; } = info;
    public Action<ScanProgress>? ProgressHandler { get; set; }
    public ScanStop? LastScanStop { get; private set; }
    public bool? LastScanDuplex { get; private set; }

    private volatile bool _cancelRequested;

    private static readonly SizeD BedSizeInches = new(8.5, 11.7);

    public Task<ScannerCapabilities> GetCapabilitiesAsync() =>
        Task.FromResult(new ScannerCapabilities
        {
            SupportedResolutions = [75, 150, 200, 300, 600, 1200],
            Sources = [ScanSource.Flatbed, ScanSource.DocumentFeeder],
            FlatbedSizeInches = BedSizeInches,
            SupportsOverview = true,
            FeederSizeInches = MockBedRenderer.FeederMaxInches,
            SupportsDuplex = backend.FeederDuplex,
        });

    public Task<RgbaImage> PerformOverviewScanAsync(ScanSettings settings)
    {
        _cancelRequested = false;
        ProgressHandler?.Invoke(new ScanProgress(0.5, "Scanning overview…"));
        return Task.FromResult(MockBedRenderer.RenderBed(100, settings.Intent));
    }

    public async Task<IReadOnlyList<ScannedPage>> PerformScanAsync(ScanSettings settings, RectD? selection)
    {
        _cancelRequested = false;
        LastScanStop = null;
        LastScanDuplex = null;
        int dpi = Math.Min(settings.Resolution, 600); // cap memory use
        if (settings.Source == ScanSource.DocumentFeeder) return await ScanFeeder(settings, dpi);

        ProgressHandler?.Invoke(new ScanProgress(0.2, "Warming up…"));
        await SleepCheckingCancellation(0.25);

        ProgressHandler?.Invoke(new ScanProgress(0.6, "Scanning…"));
        var image = await Task.Run(() => MockBedRenderer.RenderBed(dpi, settings.Intent));
        await SleepCheckingCancellation(0.25);

        ProgressHandler?.Invoke(new ScanProgress(0.9, "Transferring…"));
        await SleepCheckingCancellation(0.2);

        // Honor the selection: a normalized rect of the bed with top-left origin, which
        // matches RgbaImage's cropping coordinate space.
        if (selection is { } sel)
        {
            var clamped = sel.Standardized.Intersection(new RectD(0, 0, 1, 1));
            if (clamped.Width > 0.005 && clamped.Height > 0.005)
            {
                var pixelRect = new RectD(clamped.MinX * image.Width, clamped.MinY * image.Height,
                                          clamped.Width * image.Width, clamped.Height * image.Height);
                if (image.Cropped(pixelRect) is { } cropped)
                {
                    image = cropped;
                }
            }
        }
        return [new ScannedPage(image, dpi, settings.ColorMode)];
    }

    /// <summary>
    /// The demo feeder (the selection does not apply): one sheet per page, the paper size
    /// asked for (letter for Automatic), each side marked with its sheet number. Two-sided
    /// (when asked for and <see cref="MockScannerBackend.FeederDuplex"/>) it delivers front,
    /// back, front, back…; one-sided it delivers the side facing up
    /// (<see cref="MockScannerBackend.FeederStackTurnedOver"/>), and says so when both sides were
    /// asked for (<see cref="LastScanDuplex"/>). An empty feeder or a jam fails like a real one;
    /// a jam keeps the sheets before it.
    /// </summary>
    private async Task<IReadOnlyList<ScannedPage>> ScanFeeder(ScanSettings settings, int dpi)
    {
        int sheets = backend.FeederSheetCount;
        int? jamsAfter = backend.FeederJamsAfter;
        bool twoSided = settings.Duplex == DuplexMode.Both && backend.FeederDuplex;
        bool turnedOver = backend.FeederStackTurnedOver;
        var region = PaperSizes.FeederRegionInches(settings.PaperSize, MockBedRenderer.FeederMaxInches);
        var sheetInches = settings.PaperSize == PaperSize.Auto
            ? MockBedRenderer.SheetInches
            : new SizeD(region.Width, region.Height);
        ProgressHandler?.Invoke(new ScanProgress(0.1, "Warming up…"));
        await SleepCheckingCancellation(0.25);
        if (sheets <= 0) throw ScanException.ForProblem(ScannerProblem.FeederEmpty);
        LastScanDuplex = settings.Duplex == DuplexMode.Both ? twoSided : null;

        var pages = new List<ScannedPage>();
        for (int index = 0; index < sheets; index++)
        {
            if (jamsAfter is int jam && index >= jam)
            {
                var error = ScanException.ForProblem(ScannerProblem.PaperJam);
                if (pages.Count == 0) throw error;
                LastScanStop = ScanStop.From(error);
                break;
            }
            ProgressHandler?.Invoke(new ScanProgress(0.1 + 0.9 * index / sheets,
                                                     $"Scanning sheet {index + 1} of {sheets}…"));
            // A turned-over stack feeds its last sheet first, showing the backs.
            int sheet = turnedOver && !twoSided ? sheets - 1 - index : index;
            PageSide[] sides = twoSided ? [PageSide.Front, PageSide.Back]
                : [turnedOver ? PageSide.Back : PageSide.Front];
            foreach (var side in sides)
            {
                var image = await Task.Run(() => MockBedRenderer.RenderSheet(dpi, settings.Intent, sheet, side, sheetInches));
                pages.Add(new ScannedPage(image, dpi, settings.ColorMode));
            }
            await SleepCheckingCancellation(0.15);
        }
        // The user turns the stack over between the two scans of turning over by hand, and
        // loads it the right way up for any other scan; after a jam the rest of the same side
        // comes next.
        if (LastScanStop is null)
        {
            backend.FeederStackTurnedOver = settings.Duplex == DuplexMode.Manual && !twoSided && !turnedOver;
        }
        return pages;
    }

    public void CancelScan() => _cancelRequested = true;

    public Task CloseAsync() => Task.CompletedTask;

    private async Task SleepCheckingCancellation(double seconds)
    {
        await Task.Delay(TimeSpan.FromSeconds(seconds));
        if (_cancelRequested) throw ScanException.Cancelled();
    }
}

/// <summary>
/// Draws the deterministic synthetic flatbed. Everything works in a top-left-origin,
/// y-down coordinate space measured in inches — RgbaImage's native orientation, so unlike
/// the CG version no flip is needed.
/// </summary>
internal static class MockBedRenderer
{
    private static readonly SizeD BedInches = new(8.5, 11.7);
    /// <summary>Sheet size of the demo feeder's stack (US Letter), scanned when the paper size is Automatic.</summary>
    public static readonly SizeD SheetInches = new(8.5, 11);
    /// <summary>The largest sheet the demo feeder takes (US Legal).</summary>
    public static readonly SizeD FeederMaxInches = new(8.5, 14);

    public static RgbaImage RenderBed(int dpi, ScanIntent intent)
    {
        double scale = dpi;
        int width = (int)(BedInches.Width * scale);
        int height = (int)(BedInches.Height * scale);

        var image = RgbaImage.Filled(width, height, 245, 245, 245);
        DrawBedBackground(image);

        switch (intent)
        {
            case ScanIntent.Photo:
                DrawPhotos(image, scale, Photos);
                break;
            case ScanIntent.Document:
                // A white page lying on the bed, slightly inset from the glass edges.
                DrawDocument(image, scale, new RectD(0.25, 0.25, BedInches.Width - 0.5, BedInches.Height - 0.5),
                             sheetIndex: null);
                break;
        }
        return image;
    }

    /// <summary>
    /// One side of a sheet from the demo feeder, <paramref name="sheetInches"/> in size
    /// (<see cref="SheetInches"/> by default). The front of a document sheet is the demo page
    /// edge to edge with <paramref name="sheetIndex"/> + 1 marks near the bottom left; its back
    /// is a shorter page with as many marks near the bottom right, both upright, as a two-sided
    /// feeder delivers long-edge sheets. A photo sheet's front holds one of the demo photos,
    /// centered, cycling through them; its back is blank paper with a short pencilled note.
    /// </summary>
    public static RgbaImage RenderSheet(int dpi, ScanIntent intent, int sheetIndex,
                                        PageSide side = PageSide.Front, SizeD? sheetInches = null)
    {
        var sheetSize = sheetInches ?? SheetInches;
        double scale = dpi;
        int width = Math.Max(1, (int)(sheetSize.Width * scale));
        int height = Math.Max(1, (int)(sheetSize.Height * scale));
        var image = RgbaImage.Filled(width, height, 255, 255, 255);
        var page = new RectD(0, 0, sheetSize.Width, sheetSize.Height);
        switch (intent)
        {
            case ScanIntent.Photo when side == PageSide.Back:
                // A note pencilled on the back of the print.
                FillRect(image, 0.75 * scale, 0.9 * scale, 2.2 * scale, 0.12 * scale, 120, 120, 128);
                break;
            case ScanIntent.Photo:
                DrawBedBackground(image);
                int design = sheetIndex % Photos.Length;
                var centered = Photos[design] with
                {
                    CenterInches = new PointD(sheetSize.Width / 2, sheetSize.Height / 2),
                };
                DrawPhotos(image, scale, [centered], firstDesign: design);
                break;
            case ScanIntent.Document when side == PageSide.Back:
                DrawDocumentBack(image, scale, page, sheetIndex);
                break;
            case ScanIntent.Document:
                DrawDocument(image, scale, page, sheetIndex);
                break;
        }
        return image;
    }

    // MARK: Background

    /// <summary>Near-white bed with a very subtle vertical gradient (0.97 → 0.945 gray).</summary>
    private static void DrawBedBackground(RgbaImage image)
    {
        for (int y = 0; y < image.Height; y++)
        {
            double t = (double)y / Math.Max(1, image.Height - 1);
            byte v = (byte)Math.Round((0.97 + (0.945 - 0.97) * t) * 255);
            int row = y * image.Width * 4;
            for (int x = 0; x < image.Width; x++)
            {
                image.Pixels[row] = v;
                image.Pixels[row + 1] = v;
                image.Pixels[row + 2] = v;
                image.Pixels[row + 3] = 255;
                row += 4;
            }
        }
    }

    // MARK: Photos

    private readonly record struct MockPhoto(PointD CenterInches, SizeD SizeInches, double AngleDegrees);

    /// <summary>Exactly three well-separated "photos" lying fully inside the bed.</summary>
    private static readonly MockPhoto[] Photos =
    [
        new(new PointD(2.5, 2.3), new SizeD(4.0, 3.0), -12),
        new(new PointD(6.3, 6.0), new SizeD(3.0, 3.0), 3),
        new(new PointD(2.9, 9.5), new SizeD(3.5, 2.5), 17),
    ];

    /// <param name="firstDesign">Content design (see <see cref="PhotoContent"/>) of the first photo in <paramref name="photos"/>.</param>
    private static void DrawPhotos(RgbaImage image, double scale, MockPhoto[] photos, int firstDesign = 0)
    {
        double border = 0.08 * scale;
        for (int index = 0; index < photos.Length; index++)
        {
            var photo = photos[index];
            double w = photo.SizeInches.Width * scale;
            double h = photo.SizeInches.Height * scale;
            var center = new PointD(photo.CenterInches.X * scale, photo.CenterInches.Y * scale);
            double angle = photo.AngleDegrees * Math.PI / 180;
            double cos = Math.Cos(angle), sin = Math.Sin(angle);

            // Iterate the axis-aligned bounding box of the rotated outer rect; for each pixel,
            // inverse-rotate into the photo's local frame and paint by layer.
            double halfDiag = Math.Sqrt(w * w + h * h) / 2;
            int minX = Math.Max(0, (int)(center.X - halfDiag));
            int maxX = Math.Min(image.Width - 1, (int)Math.Ceiling(center.X + halfDiag));
            int minY = Math.Max(0, (int)(center.Y - halfDiag));
            int maxY = Math.Min(image.Height - 1, (int)Math.Ceiling(center.Y + halfDiag));

            for (int py = minY; py <= maxY; py++)
            {
                for (int px = minX; px <= maxX; px++)
                {
                    // Inverse rotation: image → local frame (positive angle clockwise on screen).
                    double dx = px + 0.5 - center.X;
                    double dy = py + 0.5 - center.Y;
                    double lx = dx * cos + dy * sin;
                    double ly = -dx * sin + dy * cos;
                    if (Math.Abs(lx) > w / 2 || Math.Abs(ly) > h / 2) continue;

                    (byte r, byte g, byte b) color;
                    bool insideInner = Math.Abs(lx) <= w / 2 - border && Math.Abs(ly) <= h / 2 - border;
                    if (!insideInner)
                    {
                        color = (255, 255, 255); // white print border
                    }
                    else
                    {
                        color = PhotoContent(firstDesign + index, lx, ly, w - 2 * border, h - 2 * border, scale);
                    }

                    int pi = (py * image.Width + px) * 4;
                    image.Pixels[pi] = color.r;
                    image.Pixels[pi + 1] = color.g;
                    image.Pixels[pi + 2] = color.b;
                    image.Pixels[pi + 3] = 255;
                }
            }
        }
    }

    /// <summary>Per-photo content at local coordinates (lx, ly), matching the macOS demo bed.</summary>
    private static (byte, byte, byte) PhotoContent(int index, double lx, double ly,
                                                   double innerW, double innerH, double scale)
    {
        // Diagonal gradient parameter across the inner rect (top-left → bottom-right).
        double t = Math.Clamp(((lx + innerW / 2) + (ly + innerH / 2)) / (innerW + innerH), 0, 1);
        switch (index)
        {
            case 0:
            {
                // Blue gradient with a dark disc at local (0.7", -0.4"), radius 0.45".
                double dx = lx - 0.7 * scale, dy = ly + 0.4 * scale;
                if (dx * dx + dy * dy <= 0.45 * scale * 0.45 * scale)
                    return Rgb(0.10, 0.12, 0.16);
                return Lerp((0.36, 0.62, 0.80), (0.16, 0.34, 0.55), t);
            }
            case 1:
            {
                // Orange gradient with a dark square (side 0.9") at local (-0.55", 0.35").
                double side = 0.9 * scale;
                if (Math.Abs(lx + 0.55 * scale) <= side / 2 && Math.Abs(ly - 0.35 * scale) <= side / 2)
                    return Rgb(0.15, 0.10, 0.08);
                return Lerp((0.93, 0.62, 0.25), (0.75, 0.30, 0.16), t);
            }
            default:
            {
                // Solid purple with a dark triangle: (-1.0, 0.6), (-0.2, -0.6), (0.6, 0.6) inches.
                var a = new PointD(-1.0 * scale, 0.6 * scale);
                var b = new PointD(-0.2 * scale, -0.6 * scale);
                var c = new PointD(0.6 * scale, 0.6 * scale);
                if (InsideTriangle(new PointD(lx, ly), a, b, c))
                    return Rgb(0.10, 0.09, 0.15);
                return Rgb(0.42, 0.40, 0.62);
            }
        }
    }

    private static bool InsideTriangle(PointD p, PointD a, PointD b, PointD c)
    {
        static double Sign(PointD p1, PointD p2, PointD p3) =>
            (p1.X - p3.X) * (p2.Y - p3.Y) - (p2.X - p3.X) * (p1.Y - p3.Y);
        double d1 = Sign(p, a, b), d2 = Sign(p, b, c), d3 = Sign(p, c, a);
        bool hasNeg = d1 < 0 || d2 < 0 || d3 < 0;
        bool hasPos = d1 > 0 || d2 > 0 || d3 > 0;
        return !(hasNeg && hasPos);
    }

    private static (byte, byte, byte) Rgb(double r, double g, double b) =>
        ((byte)Math.Round(r * 255), (byte)Math.Round(g * 255), (byte)Math.Round(b * 255));

    private static (byte, byte, byte) Lerp((double r, double g, double b) from,
                                           (double r, double g, double b) to, double t) =>
        Rgb(from.r + (to.r - from.r) * t,
            from.g + (to.g - from.g) * t,
            from.b + (to.b - from.b) * t);

    // MARK: Document

    /// <summary>
    /// A white page with text-shaped bars (title + paragraph lines). Bar widths derive from
    /// the macOS demo's actual line lengths so the layout matches visually.
    /// </summary>
    /// <param name="pageInches">The white page, in inches.</param>
    /// <param name="sheetIndex">When set, sheetIndex + 1 square marks are drawn near the bottom edge so feeder sheets can be told apart.</param>
    private static void DrawDocument(RgbaImage image, double scale, RectD pageInches, int? sheetIndex)
    {
        double pageX = pageInches.X * scale, pageY = pageInches.Y * scale;
        double pageW = pageInches.Width * scale;
        double pageH = pageInches.Height * scale;
        FillRect(image, pageX, pageY, pageW, pageH, 255, 255, 255);

        // Line lengths of the macOS demo text, in characters (title, then body).
        int[] bodyLineChars = [62, 63, 64, 40, 0, 60, 63, 57, 63, 52, 0, 43];
        double pointSize = scale / 72; // 1pt at this dpi
        double left = pageX + 0.75 * scale;
        double y = pageY + 0.9 * scale;

        // Title bar (18pt bold ≈ taller, darker bar).
        double titleSize = 18 * pointSize;
        FillRect(image, left, y, 30 * 0.5 * titleSize, titleSize * 0.72, 56, 56, 61);
        y += titleSize * 2.2;

        double bodySize = 12 * pointSize;
        double lineHeight = bodySize * 1.55;
        foreach (int chars in bodyLineChars)
        {
            if (chars > 0)
            {
                FillRect(image, left, y, chars * 0.5 * bodySize, bodySize * 0.6, 56, 56, 61);
            }
            y += lineHeight;
        }

        if (sheetIndex is int sheet)
        {
            // Sheet marks: 0.2 in squares, 0.35 in apart, their top 0.9 in above the page's bottom edge.
            double side = 0.2 * scale, pitch = 0.35 * scale;
            double markY = pageY + pageH - 0.9 * scale;
            for (int mark = 0; mark <= sheet; mark++)
            {
                FillRect(image, left + mark * pitch, markY, side, side, 56, 56, 61);
            }
        }
    }

    /// <summary>
    /// The back of a demo sheet: a short paragraph (six text bars) and
    /// <paramref name="sheetIndex"/> + 1 square marks near the bottom right, so backs can be
    /// told from fronts and their orientation seen.
    /// </summary>
    private static void DrawDocumentBack(RgbaImage image, double scale, RectD pageInches, int sheetIndex)
    {
        double pageX = pageInches.X * scale, pageY = pageInches.Y * scale;
        double pageW = pageInches.Width * scale, pageH = pageInches.Height * scale;
        FillRect(image, pageX, pageY, pageW, pageH, 255, 255, 255);

        int[] lineChars = [48, 55, 51, 30, 0, 44, 22];
        double bodySize = 12 * scale / 72;
        double left = pageX + 0.75 * scale;
        double y = pageY + 0.9 * scale;
        foreach (int chars in lineChars)
        {
            if (chars > 0) FillRect(image, left, y, chars * 0.5 * bodySize, bodySize * 0.6, 56, 56, 61);
            y += bodySize * 1.55;
        }

        // Sheet marks: 0.2 in squares, 0.35 in apart, the first one's right edge 0.75 in from
        // the page's right edge, their top 0.9 in above the bottom edge.
        double side = 0.2 * scale, pitch = 0.35 * scale;
        double right = pageX + pageW - 0.75 * scale;
        double markY = pageY + pageH - 0.9 * scale;
        for (int mark = 0; mark <= sheetIndex; mark++)
        {
            FillRect(image, right - side - mark * pitch, markY, side, side, 56, 56, 61);
        }
    }

    private static void FillRect(RgbaImage image, double x, double y, double w, double h,
                                 byte r, byte g, byte b)
    {
        int x0 = Math.Max(0, (int)x), y0 = Math.Max(0, (int)y);
        int x1 = Math.Min(image.Width, (int)Math.Ceiling(x + w));
        int y1 = Math.Min(image.Height, (int)Math.Ceiling(y + h));
        for (int py = y0; py < y1; py++)
        {
            int pi = (py * image.Width + x0) * 4;
            for (int px = x0; px < x1; px++)
            {
                image.Pixels[pi] = r;
                image.Pixels[pi + 1] = g;
                image.Pixels[pi + 2] = b;
                image.Pixels[pi + 3] = 255;
                pi += 4;
            }
        }
    }
}
