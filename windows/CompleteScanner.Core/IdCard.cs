namespace CompleteScanner.Core;

// Twin of Sources/CompleteScannerKit/Pipeline/IdCard.swift: the ID card task. The front and the
// back of a card are scanned on the flatbed, the card is found on each scan (PhotoDetector), and
// both sides are laid out on one page at their real size (ID-1 is 85.60 × 53.98 mm).

/// <summary>
/// The page an ID card copy is laid out on (<see cref="TaskOptions.IdCardPaper"/>).
/// <see cref="Auto"/> comes first: it is the default and the fallback for a value a newer version
/// adds, and it is the paper usual where the user lives (<see cref="PaperSizes.DefaultForRegion"/>).
/// Stored as "auto", "a4", "letter".
/// </summary>
public enum IdCardPaper
{
    Auto,
    A4,
    Letter,
}

public static class IdCardPapers
{
    /// <summary>Every choice, Automatic first.</summary>
    public static IReadOnlyList<IdCardPaper> All { get; } = Enum.GetValues<IdCardPaper>();

    /// <summary>The stored name: "auto", "a4", "letter" (the Swift raw values).</summary>
    public static string RawValue(this IdCardPaper paper) => paper switch
    {
        IdCardPaper.Auto => "auto",
        IdCardPaper.A4 => "a4",
        IdCardPaper.Letter => "letter",
        _ => throw new ArgumentOutOfRangeException(nameof(paper), paper, null),
    };

    /// <summary>"Automatic", "A4", "Letter".</summary>
    public static string Label(this IdCardPaper paper) => paper switch
    {
        IdCardPaper.A4 => "A4",
        IdCardPaper.Letter => "Letter",
        _ => "Automatic",
    };

    /// <summary>The paper the copy is made on: A4 or Letter as chosen; for Automatic the usual paper in <paramref name="regionCode"/>.</summary>
    public static PaperSize Resolve(IdCardPaper paper, string? regionCode) => paper switch
    {
        IdCardPaper.A4 => PaperSize.A4,
        IdCardPaper.Letter => PaperSize.Letter,
        _ => PaperSizes.DefaultForRegion(regionCode),
    };

    /// <summary>How a picker names a choice: "Automatic (A4)", "A4", "Letter".</summary>
    public static string ChoiceLabel(IdCardPaper paper, string? regionCode) =>
        paper == IdCardPaper.Auto ? $"Automatic ({Resolve(paper, regionCode).Label()})" : paper.Label();
}

/// <summary>The guided steps of the ID card task: the front, the back (skippable), then checking and saving.</summary>
public static class IdCardSteps
{
    public const string FrontStepId = "front";
    public const string BackStepId = "back";
    public const string ReviewStepId = "review";

    /// <summary>
    /// Front, back, review. Only the front must be captured: the back is skipped for a card with
    /// nothing on its back, and the review captures nothing.
    /// </summary>
    public static IReadOnlyList<TaskStep> Steps { get; } =
    [
        new TaskStep(FrontStepId, "Front side",
                     "Place the card face down near a corner of the glass, close the lid and scan the front.",
                     "Scan front"),
        new TaskStep(BackStepId, "Back side",
                     "Turn the card over where it lies, close the lid and scan the back. Skip this if nothing is printed on the back.",
                     "Scan back", Skippable: true, RequiresCapture: false),
        new TaskStep(ReviewStepId, "Check and save",
                     "Check both sides, then save them on one page at their real size.",
                     "Review", RequiresCapture: false),
    ];

    /// <summary>The side a step scans; null for the review and any other step.</summary>
    public static PageSide? SideOf(string? stepId) => stepId switch
    {
        FrontStepId => PageSide.Front,
        BackStepId => PageSide.Back,
        _ => null,
    };

    /// <summary>The step that scans <paramref name="side"/>.</summary>
    public static string StepId(PageSide side) => side == PageSide.Front ? FrontStepId : BackStepId;

    /// <summary>
    /// Whether the scan screen offers to skip <paramref name="step"/>: only the back of an ID card,
    /// which may have nothing printed on it. The backs of a stack turned over by hand are left out
    /// with Keep fronts only instead, which also takes the backs scanned so far out of the queue.
    /// </summary>
    public static bool OffersSkip(TaskStep? step) => step is { Skippable: true, Id: BackStepId };
}

/// <summary>
/// A scan a side of an ID card was found on: its resolution, its size in pixels and the part of the
/// glass it covers (the selection, 0–1 of the glass; null for the whole glass).
/// </summary>
public sealed record IdCardScanArea(int Dpi, SizeD PixelSize, RectD? Selection);

/// <summary>How the card was found on a scan (<see cref="IdCardDetector.PickCard"/>).</summary>
public enum IdCardPickKind
{
    /// <summary>A region the size and shape of a card.</summary>
    Card,
    /// <summary>Nothing card-sized: the largest region found.</summary>
    LargestRegion,
    /// <summary>Nothing card-sized on the back: the place of the front, the card turned over where it lay.</summary>
    FrontPlace,
    /// <summary>Nothing found: the whole scan, to be cropped by hand.</summary>
    WholeScan,
}

/// <summary>Where the card is on a scan, and how sure that is.</summary>
public sealed record IdCardPick(DetectedPhotoRegion Region, IdCardPickKind Kind)
{
    /// <summary>Nothing was found: the crop has to be fixed by hand.</summary>
    public bool NeedsManualCrop => Kind == IdCardPickKind.WholeScan;

    /// <summary>What to check, shown under the side; null when the card was found.</summary>
    public string? Note => IdCardDetector.Note(Kind);
}

/// <summary>
/// Finds the card on a flatbed scan among what <see cref="PhotoDetector"/> finds: the region
/// closest to an ID-1 card in shape and size. Passports (ID-3, up to 4.92 × 3.46 in) qualify too.
/// </summary>
public static class IdCardDetector
{
    /// <summary>Long side of an ID-1 card: 85.60 mm.</summary>
    public const double CardLongSideInches = 3.370;
    /// <summary>Short side of an ID-1 card: 53.98 mm.</summary>
    public const double CardShortSideInches = 2.125;
    /// <summary>Long side over short side of an ID-1 card (1.586).</summary>
    public const double CardAspect = CardLongSideInches / CardShortSideInches;
    /// <summary>A card-sized region's long side is at least this long…</summary>
    public const double MinLongSideInches = 2.5;
    /// <summary>…and at most this long (a passport page fits).</summary>
    public const double MaxLongSideInches = 6.0;
    /// <summary>Smaller things on the glass are ignored.</summary>
    public const double MinSideInches = 1.5;
    /// <summary>The largest regions considered.</summary>
    public const int MaxRegions = 4;

    /// <summary>How the detector is run on a card scan.</summary>
    public static PhotoDetectorOptions DetectionOptions() => new()
    {
        MinPhotoSideInches = MinSideInches,
        MaxPhotoCount = MaxRegions,
    };

    /// <summary>The region's long side, in inches.</summary>
    public static double LongSideInches(DetectedPhotoRegion region, int dpi) =>
        Math.Max(region.Size.Width, region.Size.Height) / Math.Max(1, dpi);

    /// <summary>
    /// How far a region is from a card: |aspect − 1.586| / 1.586 + |long side − 3.370 in| / 3.370
    /// (0 for an exact card; lower is closer).
    /// </summary>
    public static double Score(DetectedPhotoRegion region, int dpi)
    {
        double longSide = Math.Max(region.Size.Width, region.Size.Height);
        double shortSide = Math.Min(region.Size.Width, region.Size.Height);
        if (shortSide <= 0) return double.MaxValue;
        double longInches = longSide / Math.Max(1, dpi);
        return Math.Abs(longSide / shortSide - CardAspect) / CardAspect
               + Math.Abs(longInches - CardLongSideInches) / CardLongSideInches;
    }

    /// <summary>The region's long side is between <see cref="MinLongSideInches"/> and <see cref="MaxLongSideInches"/>.</summary>
    public static bool Qualifies(DetectedPhotoRegion region, int dpi)
    {
        double longInches = LongSideInches(region, dpi);
        return longInches >= MinLongSideInches && longInches <= MaxLongSideInches;
    }

    /// <summary>
    /// The card among <paramref name="regions"/> (full-resolution pixels of a scan
    /// <paramref name="imageSize"/> large at <paramref name="dpi"/>): the qualifying region with the
    /// lowest <see cref="Score"/> (the first of equals). When none qualifies: the
    /// <paramref name="fallback"/> when given (the front's place, for the back of a card turned over
    /// where it lay), else the largest region; with no regions either, the whole scan.
    /// </summary>
    public static IdCardPick PickCard(IReadOnlyList<DetectedPhotoRegion> regions, int dpi, SizeD imageSize,
                                      DetectedPhotoRegion? fallback = null)
    {
        DetectedPhotoRegion? best = null;
        double bestScore = double.MaxValue;
        foreach (var region in regions)
        {
            if (!Qualifies(region, dpi)) continue;
            double score = Score(region, dpi);
            if (score < bestScore)
            {
                best = region;
                bestScore = score;
            }
        }
        if (best is not null) return new IdCardPick(best, IdCardPickKind.Card);
        if (fallback is not null) return new IdCardPick(fallback, IdCardPickKind.FrontPlace);
        DetectedPhotoRegion? largest = null;
        foreach (var region in regions)
        {
            if (largest is null || region.Size.Width * region.Size.Height > largest.Size.Width * largest.Size.Height)
            {
                largest = region;
            }
        }
        if (largest is not null) return new IdCardPick(largest, IdCardPickKind.LargestRegion);
        return new IdCardPick(WholeScan(imageSize), IdCardPickKind.WholeScan);
    }

    /// <summary>The whole scan as a region.</summary>
    public static DetectedPhotoRegion WholeScan(SizeD imageSize) =>
        new(new PointD(imageSize.Width / 2, imageSize.Height / 2), imageSize, 0);

    /// <summary>
    /// Where a card lies after being turned over where it lay: the same place and size, its tilt
    /// mirrored.
    /// </summary>
    public static DetectedPhotoRegion FlippedInPlace(DetectedPhotoRegion region) =>
        new(region.Center, region.Size, region.AngleDegrees == 0 ? 0 : -region.AngleDegrees);

    /// <summary>
    /// The front's place on the back's scan, for a back that does not stand out (the card turned
    /// over where it lay): <see cref="FlippedInPlace"/>, moved to the back's resolution. Null when
    /// the two scans do not cover the same part of the glass (another selection, or sizes that
    /// differ once the resolution is allowed for): the front's place then says nothing about the back's.
    /// </summary>
    public static DetectedPhotoRegion? FrontPlaceOnBack(DetectedPhotoRegion frontRegion, IdCardScanArea front, IdCardScanArea back)
    {
        if (front.Dpi <= 0 || back.Dpi <= 0 || front.Selection != back.Selection) return null;
        double scale = (double)back.Dpi / front.Dpi;
        if (!SameLength(front.PixelSize.Width * scale, back.PixelSize.Width)
            || !SameLength(front.PixelSize.Height * scale, back.PixelSize.Height))
        {
            return null;
        }
        var flipped = FlippedInPlace(frontRegion);
        return new DetectedPhotoRegion(new PointD(flipped.Center.X * scale, flipped.Center.Y * scale),
                                       new SizeD(flipped.Size.Width * scale, flipped.Size.Height * scale),
                                       flipped.AngleDegrees);
    }

    /// <summary>Two lengths in pixels agree but for a scanner's rounding: within 2 pixels or 1 %.</summary>
    private static bool SameLength(double expected, double actual) =>
        Math.Abs(expected - actual) <= Math.Max(2, 0.01 * Math.Abs(actual));

    /// <summary>The card on a scan: <see cref="PhotoDetector.DetectRegions"/>, then <see cref="PickCard"/>.</summary>
    public static IdCardPick Detect(RgbaImage image, int dpi, DetectedPhotoRegion? fallback = null) =>
        PickCard(PhotoDetector.DetectRegions(image, dpi, DetectionOptions()), dpi,
                 new SizeD(image.Width, image.Height), fallback);

    /// <summary>The card cut out of the scan and turned straight; the scan itself when that fails.</summary>
    public static RgbaImage Extract(RgbaImage image, IdCardPick pick) =>
        PhotoDetector.ExtractPhoto(image, pick.Region, deskew: true) ?? image;

    /// <summary>What to check about a side, by how its card was found; null for a card.</summary>
    public static string? Note(IdCardPickKind kind) => kind switch
    {
        IdCardPickKind.LargestRegion => "This does not look like the size of an ID card. Check the crop.",
        IdCardPickKind.FrontPlace => "The card did not stand out on this scan, so the place of the front was used. Check the crop.",
        IdCardPickKind.WholeScan => "No card was found, so the whole glass was kept. Fix the crop, or scan again with the lid closed.",
        _ => null,
    };
}

/// <summary>Where the sides go on the page, in inches from the top-left corner.</summary>
/// <param name="Scale">1 at real size; below 1 when the sides were made smaller to fit the page.</param>
public sealed record IdCardLayoutResult(RectD Front, RectD? Back, double Scale)
{
    /// <summary>The sides were made smaller to fit: the copy is not at real size.</summary>
    public bool ScaledToFit => Scale < 1;
}

/// <summary>Lays the sides out on the page: centred, one under the other, at real size when they fit.</summary>
public static class IdCardLayout
{
    /// <summary>The front's top edge is this far below the top of the page.</summary>
    public const double TopMarginInches = 1.0;
    /// <summary>Space between the front and the back.</summary>
    public const double GapInches = 0.5;
    /// <summary>Nothing comes closer to the paper's edges than this.</summary>
    public const double EdgeMarginInches = 0.25;

    /// <summary>The warning shown when the sides were made smaller to fit the page.</summary>
    public const string NotRealSizeMessage = "Too large for the page at real size, so it was made smaller to fit. It is not at real size.";

    /// <summary>
    /// The places of a front <paramref name="front"/> and back <paramref name="back"/> (inches) on
    /// <paramref name="paper"/>: centred across, the front 1 in from the top, the back 0.5 in under
    /// it, both at real size. When they would come closer than 0.25 in to an edge, both are made
    /// smaller by the same factor (<see cref="IdCardLayoutResult.ScaledToFit"/>).
    /// </summary>
    public static IdCardLayoutResult Place(SizeD front, SizeD? back, SizeD paper)
    {
        double widest = Math.Max(front.Width, back?.Width ?? 0);
        double stacked = front.Height + (back?.Height ?? 0);
        double availableWidth = paper.Width - 2 * EdgeMarginInches;
        double availableHeight = paper.Height - EdgeMarginInches - TopMarginInches - (back is null ? 0 : GapInches);
        double scale = 1;
        if (widest > 0 && widest > availableWidth) scale = Math.Min(scale, availableWidth / widest);
        if (stacked > 0 && stacked > availableHeight) scale = Math.Min(scale, availableHeight / stacked);
        scale = Math.Max(scale, 0.01);

        double frontWidth = front.Width * scale, frontHeight = front.Height * scale;
        var frontRect = new RectD((paper.Width - frontWidth) / 2, TopMarginInches, frontWidth, frontHeight);
        RectD? backRect = null;
        if (back is { } b)
        {
            double backWidth = b.Width * scale, backHeight = b.Height * scale;
            backRect = new RectD((paper.Width - backWidth) / 2, TopMarginInches + frontHeight + GapInches, backWidth, backHeight);
        }
        return new IdCardLayoutResult(frontRect, backRect, scale);
    }

    /// <summary>"Front and back on one A4 page, at real size.", "Front only on one Letter page, made smaller to fit."</summary>
    public static string Caption(PaperSize paper, bool hasBack, bool scaledToFit) =>
        $"{(hasBack ? "Front and back" : "Front only")} on one {paper.Label()} page, {(scaledToFit ? "made smaller to fit" : "at real size")}.";
}

/// <summary>One side of a card as cut out of its scan, at the resolution it was scanned at.</summary>
public sealed record IdCardSide(RgbaImage Image, int Dpi)
{
    /// <summary>Its size on paper, in inches.</summary>
    public SizeD Inches => new(Image.Width / (double)Math.Max(1, Dpi), Image.Height / (double)Math.Max(1, Dpi));
}

/// <summary>Puts the sides of a card on one white page (<see cref="IdCardLayout"/>), ready to save or print.</summary>
public static class IdCardComposer
{
    /// <summary>
    /// The highest resolution the page is composed and saved at. The sides print at real size at
    /// any resolution, and a Letter page at 600 dpi is already 5100 × 6600 pixels; at the 2400 dpi
    /// many flatbeds offer, the page would not even fit in one image.
    /// </summary>
    public const int MaxPageDpi = 600;

    /// <summary>The resolution of the page for sides scanned at <paramref name="sideDpi"/>: theirs, at most <see cref="MaxPageDpi"/>.</summary>
    public static int PageDpi(int sideDpi) => Math.Clamp(sideDpi, 1, MaxPageDpi);

    /// <summary>The page in pixels: round(paper × dpi), for example 2550 × 3300 for Letter at 300 dpi.</summary>
    public static (int Width, int Height) CanvasSize(SizeD paperInches, int dpi) =>
        (Math.Max(1, Pixels(paperInches.Width, dpi)), Math.Max(1, Pixels(paperInches.Height, dpi)));

    /// <summary>
    /// The page at <paramref name="dpi"/>: white, <paramref name="paperInches"/> large, with each
    /// side copied into its place. A side is resampled only when its place in pixels differs from its
    /// own size (another resolution, or made smaller to fit). Saved with <paramref name="dpi"/>, the
    /// page is exactly the paper size, so the sides print at real size.
    /// </summary>
    public static RgbaImage Compose(IdCardSide front, IdCardSide? back, int dpi, SizeD paperInches)
    {
        var (width, height) = CanvasSize(paperInches, dpi);
        var canvas = RgbaImage.Filled(width, height, 255, 255, 255);
        var layout = IdCardLayout.Place(front.Inches, back?.Inches, paperInches);
        Copy(front.Image, layout.Front, dpi, canvas);
        if (back is not null && layout.Back is { } backRect) Copy(back.Image, backRect, dpi, canvas);
        return canvas;
    }

    /// <summary>The name of a side's own file next to the page's: "ID card 2026-10-19 front".</summary>
    public static string SideFileBase(string baseName, PageSide side) =>
        $"{baseName} {(side == PageSide.Front ? "front" : "back")}";

    private static int Pixels(double inches, int dpi) => (int)Math.Round(inches * dpi, MidpointRounding.AwayFromZero);

    private static void Copy(RgbaImage side, RectD rectInches, int dpi, RgbaImage canvas)
    {
        int x0 = Pixels(rectInches.X, dpi), y0 = Pixels(rectInches.Y, dpi);
        int w = Math.Max(1, Pixels(rectInches.Width, dpi)), h = Math.Max(1, Pixels(rectInches.Height, dpi));
        var source = w == side.Width && h == side.Height ? side : side.Resized(w, h);
        int left = Math.Max(0, x0), right = Math.Min(canvas.Width, x0 + w);
        if (right <= left) return;
        int count = (right - left) * 4;
        for (int y = 0; y < h; y++)
        {
            int cy = y0 + y;
            if (cy < 0 || cy >= canvas.Height) continue;
            int from = (y * w + (left - x0)) * 4;
            int to = (cy * canvas.Width + left) * 4;
            Buffer.BlockCopy(source.Pixels, from, canvas.Pixels, to, count);
        }
    }
}
