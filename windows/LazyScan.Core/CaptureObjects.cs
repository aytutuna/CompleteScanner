namespace LazyScan.Core;

// Twin of Sources/CompleteScannerKit/Pipeline/CaptureObjects.swift: the same kinds, pages and rules.

/// <summary>
/// The objects of one camera shot as pages (I13): several receipts or photos, or the side of an ID
/// card, each the photo as taken with the object's corners as its capture facts, so the clean-up
/// stage cuts each out along them at its real size (<see cref="PerspectiveStep"/>, which measures it
/// with <see cref="CaptureScale"/> for its kind) and cleans it up for its kind
/// (<see cref="EnhanceStep"/>: photos and cards as photos, never evened out). The task decides the
/// kind (<see cref="KindFor"/>); a shot in which no object was found comes in whole
/// (<see cref="FallbackPage"/>), for the flatbed's own search to look at it (receipts on a white
/// table: <see cref="ReceiptDetector"/>; photos on a plain table: <see cref="PhotoDetector"/>) at
/// <see cref="FallbackDpi"/>. A page cut out this way (<see cref="IsCutOut"/>) is one object already:
/// the review takes it whole.
/// </summary>
public static class CaptureObjects
{
    /// <summary>
    /// The resolution a whole shot is searched at when no object was found in it: a phone held over a
    /// table takes in about 20 in across, about 200 pixels an inch of a 4000-pixel photo.
    /// </summary>
    public const int FallbackDpi = CaptureScale.NominalDpi;

    /// <summary>The kind of object the settings' task photographs: photos, receipts, an ID card, else document pages.</summary>
    public static CaptureKind KindFor(ScanSettings settings) => TaskCatalog.FlowOf(settings) switch
    {
        TaskFlowKind.PhotoSplit => CaptureKind.Photo,
        TaskFlowKind.ReceiptSplit => CaptureKind.Receipt,
        TaskFlowKind.IdCard => CaptureKind.IdCard,
        _ => CaptureKind.Document,
    };

    /// <summary>One shot may hold several objects of <paramref name="kind"/> (receipts, photos), each a page of its own.</summary>
    public static bool FindsSeveral(CaptureKind kind) => MultiQuadPicker.OptionsFor(kind).MaxCount > 1;

    /// <summary>
    /// The page was cut out of its photo along its corners (<see cref="PerspectiveStep"/>): its
    /// capture facts carry the real size it was measured at, and its geometry is the perspective's.
    /// </summary>
    public static bool IsCutOut(ScannedPage page) =>
        page.Capture?.Scale is not null && page.Geometry?.Basis == GeometryBasis.Perspective;

    /// <summary>The upright rectangle around <paramref name="quad"/> (its bounding box), in the same pixels.</summary>
    public static DetectedPhotoRegion RegionAround(Quad quad)
    {
        var corners = quad.Corners;
        double minX = corners[0].X, maxX = corners[0].X, minY = corners[0].Y, maxY = corners[0].Y;
        for (int i = 1; i < 4; i++)
        {
            minX = Math.Min(minX, corners[i].X);
            maxX = Math.Max(maxX, corners[i].X);
            minY = Math.Min(minY, corners[i].Y);
            maxY = Math.Max(maxY, corners[i].Y);
        }
        return new DetectedPhotoRegion(new PointD((minX + maxX) / 2, (minY + maxY) / 2), new SizeD(maxX - minX, maxY - minY), 0);
    }

    /// <summary>
    /// A page for each of <paramref name="quads"/> (in their order): the photo as taken, at
    /// <see cref="CaptureScale.NominalDpi"/> in color, from a photo (<see cref="PageSource.Photo"/>),
    /// with the object's corners (named again, <see cref="Quad.FromCorners"/>), the photo's size,
    /// <paramref name="kind"/> and the camera's <paramref name="focalLength"/> as its capture facts.
    /// The pages share the photo's pixels until each is cut out.
    /// </summary>
    public static List<ScannedPage> Pages(RgbaImage photo, IReadOnlyList<Quad> quads, CaptureKind kind,
                                          double? focalLength = null, DateTime? createdAt = null)
    {
        var pages = new List<ScannedPage>(quads.Count);
        var when = createdAt ?? DateTime.Now;
        foreach (var quad in quads)
        {
            var facts = new CaptureFacts(Quad.FromCorners(quad.Corners), photo.Width, photo.Height)
            {
                Kind = kind,
                FocalLength = focalLength,
            };
            pages.Add(new ScannedPage(photo, CaptureScale.NominalDpi, ColorMode.Color, createdAt: when) { Source = PageSource.Photo }
                .WithCapture(facts));
        }
        return pages;
    }

    /// <summary>
    /// A shot in which no object was found, whole: the photo at <see cref="FallbackDpi"/> in color,
    /// from a photo, with no capture facts, so nothing cuts it and the task's flatbed search looks at it.
    /// </summary>
    public static ScannedPage FallbackPage(RgbaImage photo, DateTime? createdAt = null) =>
        new(photo, FallbackDpi, ColorMode.Color, createdAt: createdAt) { Source = PageSource.Photo };

    /// <summary>
    /// The note on a side of the ID card cut out of a shot whose shape matched no ID-1 card
    /// (<see cref="CaptureScaleResult.IsRealSize"/> false): its size is made up.
    /// </summary>
    public const string CardNotRealSizeNote =
        "This does not look like the shape of an ID card, so it is not at real size. Fix the crop, or take it again.";

    /// <summary>
    /// The note on a side of the ID card cut out of a shot: <see cref="CardNotRealSizeNote"/> when it was
    /// not measured at its real size, then <see cref="GlareDetector.Hint"/> when the photo shows glare on
    /// the card; null for neither.
    /// </summary>
    public static string? CardNote(bool realSize, bool glare) => (realSize, glare) switch
    {
        (true, false) => null,
        (true, true) => GlareDetector.Hint,
        (false, false) => CardNotRealSizeNote,
        (false, true) => CardNotRealSizeNote + " " + GlareDetector.Hint,
    };
}

/// <summary>The photo review's short texts, the same on every platform (the receipts' are <see cref="Receipts"/>').</summary>
public static class PhotoReview
{
    /// <summary>The review's title: "Found 3 photos", "Found 1 photo".</summary>
    public static string Title(int found) => $"Found {found} photo{(found == 1 ? "" : "s")}";

    /// <summary>The review's save button: "Save 3 photos", "Save 1 photo".</summary>
    public static string SaveTitle(int included) => $"Save {included} photo{(included == 1 ? "" : "s")}";
}
