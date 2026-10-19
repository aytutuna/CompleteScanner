namespace CompleteScanner.Core;

/// <summary>
/// A demo scanner that needs no hardware: it renders deterministic synthetic flatbed
/// images in pure C#, so the whole app (overview, selection, photo splitting, PDF export)
/// can be exercised end to end. It also has a document feeder holding
/// <see cref="FeederSheetCount"/> two-sided letter-size sheets, which it scans one side or
/// both (<see cref="FeederDuplex"/>), so two-sided scanning, turning the stack over by hand and
/// paper sizes can be tried without hardware. For the ID card task its glass holds a sample card
/// (an obviously made-up design, no real document), which it turns over after every scan
/// (<see cref="IdCardTurnedOver"/>). Port of
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

    /// <summary>
    /// The sheets (counted from 0) whose backs are blank, read when the scan starts: unprinted
    /// paper with the scanner's noise, a few specks of dust and the front showing through faintly,
    /// like the back of a one-sided page in a two-sided stack. Empty by default; the app's demo
    /// scanner has a blank back on its second sheet.
    /// </summary>
    public IReadOnlyCollection<int> FeederBlankBackSheets { get; set; } = [];

    /// <summary>
    /// The sample ID card on the glass lies with its back up: a scan for the ID card task shows its
    /// back. The demo turns the card over by itself after every such scan, as the user is asked to,
    /// so scans alternate front, back, front… A preview shows the side facing down without turning it.
    /// </summary>
    public bool IdCardTurnedOver { get; set; }

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
        return Task.FromResult(settings.Task == ScanTask.IdCard
            ? MockBedRenderer.RenderIdCardBed(100, backend.IdCardTurnedOver ? PageSide.Back : PageSide.Front)
            : MockBedRenderer.RenderBed(100, settings.Intent));
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
        // The ID card task scans the sample card, then turns it over as the user would.
        bool idCard = settings.Task == ScanTask.IdCard;
        var cardSide = backend.IdCardTurnedOver ? PageSide.Back : PageSide.Front;
        var image = await Task.Run(() => idCard
            ? MockBedRenderer.RenderIdCardBed(dpi, cardSide)
            : MockBedRenderer.RenderBed(dpi, settings.Intent));
        if (idCard) backend.IdCardTurnedOver = cardSide == PageSide.Front;
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
        var blankBacks = backend.FeederBlankBackSheets.ToHashSet();
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
                bool blank = side == PageSide.Back && blankBacks.Contains(sheet);
                var image = await Task.Run(() => blank
                    ? MockBedRenderer.RenderBlankBack(dpi, settings.Intent, sheet, sheetInches)
                    : MockBedRenderer.RenderSheet(dpi, settings.Intent, sheet, side, sheetInches));
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

    /// <summary>
    /// The back of sheet <paramref name="sheetIndex"/> when nothing is printed on it, as a scanner
    /// sees it: off-white paper with noise (σ ≈ 4 levels), a few specks of dust, and the front
    /// showing through mirrored at a tenth of its darkness. Deterministic for a sheet and size.
    /// </summary>
    public static RgbaImage RenderBlankBack(int dpi, ScanIntent intent, int sheetIndex, SizeD? sheetInches = null)
    {
        var front = RenderSheet(dpi, intent, sheetIndex, PageSide.Front, sheetInches);
        int width = front.Width, height = front.Height;
        var pixels = new byte[width * height * 4];
        uint state = 0x9E3779B9u ^ (uint)(sheetIndex + 1) * 2654435761u;
        uint Next()
        {
            state ^= state << 13;
            state ^= state >> 17;
            state ^= state << 5;
            return state;
        }
        for (int y = 0; y < height; y++)
        {
            for (int x = 0; x < width; x++)
            {
                // The front seen from behind: mirrored left to right.
                int fi = (y * width + (width - 1 - x)) * 4;
                int frontLuma = (299 * front.Pixels[fi] + 587 * front.Pixels[fi + 1] + 114 * front.Pixels[fi + 2] + 500) / 1000;
                int noise = (int)(Next() % 7 + Next() % 7 + Next() % 7 + Next() % 7) - 12;
                int value = Math.Clamp(246 - (255 - frontLuma) / 10 + noise, 0, 255);
                int i = (y * width + x) * 4;
                pixels[i] = (byte)value;
                pixels[i + 1] = (byte)value;
                pixels[i + 2] = (byte)Math.Max(0, value - 3); // a slightly warm paper
                pixels[i + 3] = 255;
            }
        }
        // Dust: specks of one or two pixels at 300 dpi (never less than a pixel).
        var image = new RgbaImage(width, height, pixels);
        for (int n = 0; n < 40; n++)
        {
            int x = (int)(Next() % (uint)width), y = (int)(Next() % (uint)height);
            int size = Math.Max(1, (dpi * (1 + (int)(Next() % 2)) + 150) / 300);
            FillRect(image, x, y, size, size, 70, 70, 70);
        }
        return image;
    }

    // MARK: ID card

    /// <summary>Where the sample card lies on the glass, front down (its centre, in inches from the top-left corner).</summary>
    public static readonly PointD IdCardCenterInches = new(2.35, 1.75);
    /// <summary>The sample card's tilt with its front down; turned over where it lay, the other way.</summary>
    public const double IdCardAngleDegrees = 4;

    /// <summary>
    /// The glass with the sample ID card on it, near the top-left corner and tilted 4°: the
    /// <paramref name="side"/> facing the glass. Turned over where it lay, the card's back is tilted
    /// the other way. The design is made up and says SAMPLE: a header band, a grey photo
    /// placeholder and field bars on the front; a barcode, SAMPLE and three lines of code blocks on
    /// the back. ID-1 size (3.370 × 2.125 in), with rounded corners.
    /// </summary>
    public static RgbaImage RenderIdCardBed(int dpi, PageSide side)
    {
        double scale = dpi;
        int width = (int)(BedInches.Width * scale);
        int height = (int)(BedInches.Height * scale);
        var image = RgbaImage.Filled(width, height, 245, 245, 245);
        DrawBedBackground(image);

        double w = IdCardDetector.CardLongSideInches * scale, h = IdCardDetector.CardShortSideInches * scale;
        var center = new PointD(IdCardCenterInches.X * scale, IdCardCenterInches.Y * scale);
        double angle = (side == PageSide.Front ? IdCardAngleDegrees : -IdCardAngleDegrees) * Math.PI / 180;
        double cos = Math.Cos(angle), sin = Math.Sin(angle);
        double halfDiag = Math.Sqrt(w * w + h * h) / 2;
        int minX = Math.Max(0, (int)(center.X - halfDiag)), maxX = Math.Min(width - 1, (int)Math.Ceiling(center.X + halfDiag));
        int minY = Math.Max(0, (int)(center.Y - halfDiag)), maxY = Math.Min(height - 1, (int)Math.Ceiling(center.Y + halfDiag));
        for (int py = minY; py <= maxY; py++)
        {
            for (int px = minX; px <= maxX; px++)
            {
                double dx = px + 0.5 - center.X, dy = py + 0.5 - center.Y;
                // Image → the card's own frame, in inches from its top-left corner.
                double lx = (dx * cos + dy * sin) / scale + IdCardDetector.CardLongSideInches / 2;
                double ly = (-dx * sin + dy * cos) / scale + IdCardDetector.CardShortSideInches / 2;
                if (CardColor(lx, ly, side) is not { } color) continue;
                int pi = (py * width + px) * 4;
                image.Pixels[pi] = color.R;
                image.Pixels[pi + 1] = color.G;
                image.Pixels[pi + 2] = color.B;
                image.Pixels[pi + 3] = 255;
            }
        }
        return image;
    }

    /// <summary>The sample card's color at (<paramref name="x"/>, <paramref name="y"/>) inches from its top-left corner; null outside it.</summary>
    private static (byte R, byte G, byte B)? CardColor(double x, double y, PageSide side)
    {
        const double cardW = IdCardDetector.CardLongSideInches, cardH = IdCardDetector.CardShortSideInches;
        const double radius = 0.125;
        if (x < 0 || y < 0 || x >= cardW || y >= cardH) return null;
        // Rounded corners.
        double cx = Math.Clamp(x, radius, cardW - radius), cy = Math.Clamp(y, radius, cardH - radius);
        if ((x - cx) * (x - cx) + (y - cy) * (y - cy) > radius * radius) return null;

        (byte, byte, byte) paper = (196, 224, 220), ink = (36, 44, 52);
        if (side == PageSide.Front)
        {
            // Header band with SAMPLE in white.
            if (y < 0.42)
            {
                return SampleText(x - 0.2, y - 0.07, 0.04) ? ((byte)250, (byte)250, (byte)250) : ((byte)30, (byte)96, (byte)104);
            }
            // Photo placeholder: a grey box with a head-and-shoulders outline.
            if (x >= 0.18 && x < 0.98 && y >= 0.58 && y < 1.6)
            {
                double hx = x - 0.58, hy = y - 0.92, sy = y - 1.62;
                bool head = hx * hx + hy * hy <= 0.17 * 0.17;
                bool shoulders = hx * hx / (0.34 * 0.34) + sy * sy / (0.42 * 0.42) <= 1;
                return head || shoulders ? ((byte)120, (byte)128, (byte)136) : ((byte)176, (byte)184, (byte)190);
            }
            // Field labels and values.
            for (int line = 0; line < CardFieldWidths.Length; line++)
            {
                double top = 0.6 + line * 0.3;
                if (x >= 1.15 && x < 1.65 && y >= top && y < top + 0.05) return (90, 130, 135);
                if (x >= 1.15 && x < 1.15 + CardFieldWidths[line] && y >= top + 0.08 && y < top + 0.17) return ink;
            }
            // SAMPLE again along the bottom, in red.
            if (SampleText(x - 1.15, y - 1.82, 0.032)) return (190, 40, 40);
            return paper;
        }

        // Back: a barcode, SAMPLE, and three lines of code blocks.
        if (y >= 0.2 && y < 0.62 && x >= 0.2 && x < cardW - 0.2)
        {
            int bar = (int)((x - 0.2) / 0.018);
            return bar * 7 % 5 < 2 ? ink : paper;
        }
        if (SampleText(x - 1.0, y - 0.8, 0.045)) return (190, 40, 40);
        for (int line = 0; line < 3; line++)
        {
            double top = cardH - 0.62 + line * 0.17;
            if (y >= top && y < top + 0.1 && x >= 0.2 && x < cardW - 0.2)
            {
                int cell = (int)((x - 0.2) / 0.085);
                double inCell = x - 0.2 - cell * 0.085;
                return inCell < 0.06 && (cell * 3 + line) % 7 != 0 ? ink : paper;
            }
        }
        return paper;
    }

    /// <summary>Lengths of the sample card's field values, in inches.</summary>
    private static readonly double[] CardFieldWidths = [1.7, 1.25, 1.45, 0.95];

    /// <summary>5 × 7 blocks of the letters S, A, M, P, L, E.</summary>
    private static readonly string[] SampleGlyphs =
    [
        "01111" + "10000" + "10000" + "01110" + "00001" + "00001" + "11110",
        "01110" + "10001" + "10001" + "11111" + "10001" + "10001" + "10001",
        "10001" + "11011" + "10101" + "10101" + "10001" + "10001" + "10001",
        "11110" + "10001" + "10001" + "11110" + "10000" + "10000" + "10000",
        "10000" + "10000" + "10000" + "10000" + "10000" + "10000" + "11111",
        "11111" + "10000" + "10000" + "11110" + "10000" + "10000" + "11111",
    ];

    /// <summary>Whether (<paramref name="x"/>, <paramref name="y"/>), relative to the word's top-left corner, is ink of the word SAMPLE drawn in blocks of <paramref name="cell"/> inches.</summary>
    private static bool SampleText(double x, double y, double cell)
    {
        if (x < 0 || y < 0) return false;
        int column = (int)(x / cell), row = (int)(y / cell);
        if (row >= 7) return false;
        int letter = column / 6, within = column % 6;
        if (letter >= SampleGlyphs.Length || within >= 5) return false;
        return SampleGlyphs[letter][row * 5 + within] == '1';
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
