namespace LazyScan.Core;

// Port of Sources/LazyScanKit/Core/DocumentSides.swift: which page is which side of which
// sheet in a two-sided scan, and putting pages in reading order. The one collation helper for
// feeders that scan both sides and for stacks turned over by hand.

/// <summary>A side of a sheet.</summary>
public enum PageSide
{
    Front,
    Back,
}

/// <summary>Where one transfer of a feeder scan belongs: its sheet and side.</summary>
/// <param name="TransferIndex">The position in the order the scanner delivered the pages.</param>
public sealed record SidedTransfer(int TransferIndex, int SheetIndex, PageSide Side);

/// <summary>One page of a stack turned over by hand, in reading order.</summary>
/// <param name="Batch">The scan it came from: <see cref="PageSide.Front"/> for the fronts, <see cref="PageSide.Back"/> for the backs.</param>
/// <param name="Index">Its position within that scan.</param>
/// <param name="SheetIndex">The sheet it is assigned to.</param>
public sealed record ManualPage(PageSide Batch, int Index, int SheetIndex);

/// <summary>
/// The reading order of fronts and backs scanned separately. When the counts differ the pages
/// still come in an order (the leftovers at the end), and <see cref="Mismatch"/> says so.
/// </summary>
public sealed record ManualInterleave(IReadOnlyList<ManualPage> Order, int Fronts, int Backs)
{
    /// <summary>The fronts and backs do not pair up: a sheet was skipped, doubled or left out.</summary>
    public bool Mismatch => Fronts != Backs;

    /// <summary>"12 fronts but 11 backs" when the counts differ; null when they pair up.</summary>
    public string? MismatchMessage => Mismatch ? DocumentSides.CountMessage(Fronts, Backs) : null;
}

/// <summary>A page's place in a two-sided stack.</summary>
public readonly record struct SheetPosition(int SheetIndex, PageSide Side);

/// <summary>
/// The page queue with a stack's fronts and backs put in reading order (see
/// <see cref="DocumentSides.CollateQueue"/>), where each of those pages now sits, and how the
/// counts paired up.
/// </summary>
public sealed record QueueCollation(IReadOnlyList<Guid> Order, IReadOnlyDictionary<Guid, SheetPosition> Positions,
                                    ManualInterleave Interleave);

public static class DocumentSides
{
    /// <summary>Why the sides cannot be chosen while the flatbed is the source (the tooltip of <see cref="NeedsFeederReason"/>).</summary>
    public const string FeederOnlyReason = "Two-sided scanning uses the document feeder.";

    /// <summary>The short reason shown next to Sides while the flatbed of a scanner with a feeder is the source.</summary>
    public const string NeedsFeederReason = "Needs the feeder";

    /// <summary>Why "Both sides" is not offered: the feeder cannot scan both sides in one pass.</summary>
    public const string OneSidedFeederReason =
        "This scanner's feeder scans one side at a time. To scan both sides, turn the stack over by hand.";

    /// <summary>The step that scans the fronts of a stack turned over by hand.</summary>
    public const string FrontsStepId = "fronts";
    /// <summary>The step that scans the backs, after the stack was turned over.</summary>
    public const string BacksStepId = "backs";

    /// <summary>
    /// The guided steps of turning a stack over by hand: scan the fronts, turn the stack over,
    /// scan the backs. Every page is a capture, so both steps repeat; the backs can be left out
    /// ("Keep fronts only").
    /// </summary>
    public static IReadOnlyList<TaskStep> ManualSteps { get; } =
    [
        new TaskStep(FrontsStepId, "Scan the front sides",
                     "Load the stack in the feeder and scan the fronts.",
                     "Scan fronts", Repeats: true,
                     Help: "Only the front of each sheet is scanned this time."),
        new TaskStep(BacksStepId, "Scan the back sides",
                     "Turn the stack over, load it again and scan.",
                     "Scan backs", Skippable: true, Repeats: true, RequiresCapture: false,
                     Help: "Take the stack from the output tray and turn it over as a whole, keeping the sheets in order. Then scan the back sides."),
    ];

    /// <summary>
    /// The sheet and side of each transfer of a feeder scan, in reading order (by sheet, the
    /// front first). One-sided: transfer k is the front of sheet k. Two-sided: transfers come as
    /// front, back, front, back; an odd last transfer is a sheet with only its front.
    /// <paramref name="reverseOrder"/>: the feeder delivers the last sheet first (ImageCaptureCore's
    /// reverseFeederPageOrder), so the sheets are numbered from the end, keeping each sheet's
    /// front before its back.
    /// </summary>
    public static IReadOnlyList<SidedTransfer> AssignSides(int transferCount, bool duplex, bool reverseOrder = false)
    {
        int count = Math.Max(0, transferCount);
        int sheets = duplex ? (count + 1) / 2 : count;
        var result = new List<SidedTransfer>(count);
        for (int k = 0; k < count; k++)
        {
            int scanned = duplex ? k / 2 : k;
            var side = duplex && k % 2 == 1 ? PageSide.Back : PageSide.Front;
            int sheet = reverseOrder ? sheets - 1 - scanned : scanned;
            result.Add(new SidedTransfer(k, sheet, side));
        }
        return [.. result.OrderBy(t => t.SheetIndex).ThenBy(t => t.Side)];
    }

    /// <summary>
    /// Fronts and backs scanned separately, put in reading order: sheet i's front, then its
    /// back. Turning the stack over reverses it, so with <paramref name="backsReversed"/> the
    /// back of sheet i is the (n−1−i)-th back scanned. Counts that differ are paired as far as
    /// they go; the remaining fronts, then the remaining backs, follow as sheets of their own,
    /// and the result says the counts did not match.
    /// </summary>
    public static ManualInterleave InterleaveManual(int fronts, int backs, bool backsReversed = true)
    {
        int f = Math.Max(0, fronts), b = Math.Max(0, backs);
        var order = new List<ManualPage>(f + b);
        int BackIndex(int sheet) => backsReversed ? b - 1 - sheet : sheet;
        for (int sheet = 0; sheet < Math.Max(f, b); sheet++)
        {
            if (sheet < f) order.Add(new ManualPage(PageSide.Front, sheet, sheet));
            if (sheet < b) order.Add(new ManualPage(PageSide.Back, BackIndex(sheet), sheet));
        }
        return new ManualInterleave(order, f, b);
    }

    /// <summary>Quarter turns (clockwise) that put a back side upright: 2 for short-edge sheets, 0 for long-edge ones.</summary>
    public static int BackQuarterTurns(DuplexBinding binding) => binding == DuplexBinding.ShortEdge ? 2 : 0;

    /// <summary>
    /// How a scan with these settings captures the sheets: <see cref="DuplexMode.Off"/> unless
    /// the feeder is the source; a two-sided scan by a feeder that cannot do it is done by hand.
    /// Unknown capabilities (null) leave the choice as it is.
    /// </summary>
    public static DuplexMode Effective(ScanSettings settings, ScannerCapabilities? capabilities)
    {
        if (settings.Source != ScanSource.DocumentFeeder || settings.Duplex == DuplexMode.Off) return DuplexMode.Off;
        if (settings.Duplex == DuplexMode.Both && capabilities is { SupportsDuplex: false }) return DuplexMode.Manual;
        return settings.Duplex;
    }

    /// <summary>
    /// The capabilities to decide the sides with (<see cref="Effective"/>, <see cref="SettingsAdapter.Adapt"/>,
    /// the steps). While it is not known whether the feeder scans both sides
    /// (<paramref name="duplexKnown"/> false: ImageCaptureCore on the Mac tells only once the
    /// feeder is selected), a scanner with a feeder is taken to scan both, so "Both sides" stays
    /// chosen until the scanner says otherwise; the scan then reports what it did
    /// (<see cref="IScannerSession.LastScanDuplex"/>). Otherwise unchanged (the same instance).
    /// </summary>
    public static ScannerCapabilities? CapabilitiesForSides(ScannerCapabilities? capabilities, bool duplexKnown)
    {
        if (duplexKnown || capabilities is null || capabilities.SupportsDuplex
            || !capabilities.Sources.Contains(ScanSource.DocumentFeeder))
        {
            return capabilities;
        }
        return new ScannerCapabilities
        {
            SupportedResolutions = [.. capabilities.SupportedResolutions],
            Sources = [.. capabilities.Sources],
            FlatbedSizeInches = capabilities.FlatbedSizeInches,
            SupportsOverview = capabilities.SupportsOverview,
            FeederSizeInches = capabilities.FeederSizeInches,
            SupportsDuplex = true,
        };
    }

    /// <summary>
    /// The stack is turned over by hand and the app guides it (<see cref="ManualSteps"/>): a
    /// two-sided feeder scan done by hand, whose pages go to the queue to be saved together.
    /// </summary>
    public static bool UsesManualSteps(ScanSettings settings, ScannerCapabilities? capabilities) =>
        Effective(settings, capabilities) == DuplexMode.Manual
        && TaskCatalog.FlowOf(settings) == TaskFlowKind.DocumentQueue
        && settings.DocumentMultiPage;

    /// <summary>
    /// Why turning over by hand cannot be guided with these settings; null when it can (also
    /// when the settings do not ask for it).
    /// </summary>
    public static string? ManualUnavailableReason(ScanSettings settings)
    {
        var flow = TaskCatalog.FlowOf(settings);
        if (flow == TaskFlowKind.Copy)
            return "Copies are made from one side of each sheet; turn the stack over and copy again.";
        if (flow != TaskFlowKind.DocumentQueue)
            return "Turning the stack over by hand works for documents, not photos.";
        if (!settings.DocumentMultiPage)
            return $"Turning the stack over by hand needs “Collect pages, then {OutputFormats.SaveTitle(settings.Format)}”.";
        return null;
    }

    /// <summary>
    /// The badge on the thumbnail of a page of a two-sided stack: "2 · back" (sheet 2), or "Front" /
    /// "Back" before its sheet is known; null for a page without a side.
    /// </summary>
    public static string? SideLabel(PageSide? side, int? sheetIndex) => side switch
    {
        null => null,
        { } s when sheetIndex is { } sheet => $"{sheet + 1} · {SideWord(s)}",
        PageSide.Front => "Front",
        _ => "Back",
    };

    /// <summary>The badge spelled out for screen readers: "Sheet 2, back", or "Front" / "Back"; null for a page without a side.</summary>
    public static string? SideName(PageSide? side, int? sheetIndex) => side switch
    {
        null => null,
        { } s when sheetIndex is { } sheet => $"Sheet {sheet + 1}, {SideWord(s)}",
        PageSide.Front => "Front",
        _ => "Back",
    };

    private static string SideWord(PageSide side) => side == PageSide.Front ? "front" : "back";

    /// <summary>"3 fronts but 2 backs", "1 front but 2 backs".</summary>
    public static string CountMessage(int fronts, int backs) =>
        $"{fronts} front{(fronts == 1 ? "" : "s")} but {backs} back{(backs == 1 ? "" : "s")}";

    /// <summary>
    /// The pages of a two-sided feeder scan (front, back, front, back… as delivered), in
    /// reading order, each marked with its sheet and side; the backs are turned upright for
    /// <paramref name="binding"/>. The input is not changed.
    /// </summary>
    public static List<ScannedPage> ArrangeTwoSided(IReadOnlyList<ScannedPage> pages, DuplexBinding binding,
                                                     bool reverseOrder = false)
    {
        int turns = BackQuarterTurns(binding);
        return AssignSides(pages.Count, duplex: true, reverseOrder)
            .Select(t => Mark(pages[t.TransferIndex], t.Side, t.SheetIndex, turns))
            .ToList();
    }

    /// <summary>
    /// The pages of one scan of a stack turned over by hand, marked as fronts or backs; backs
    /// are turned upright for <paramref name="binding"/>. Their sheets are known only once the
    /// two scans are put together (<see cref="CollateQueue"/>).
    /// </summary>
    public static List<ScannedPage> MarkManual(IReadOnlyList<ScannedPage> pages, PageSide side, DuplexBinding binding)
    {
        int turns = side == PageSide.Back ? BackQuarterTurns(binding) : 0;
        return pages.Select(page => Mark(page, side, null, turns)).ToList();
    }

    /// <summary>
    /// The pages a camera took of one side of their sheets, marked as that side; the sheet a page was
    /// given already is kept. Never turned for a binding: the user turned the sheet over by hand, either
    /// way round, and turning pages upright (<see cref="OrientationStep"/>) fixes a back that came out
    /// upside down. Only the iPhone takes such pages.
    /// </summary>
    public static List<ScannedPage> MarkCamera(IReadOnlyList<ScannedPage> pages, PageSide side) =>
        pages.Select(page => page.WithSide(side, page.SheetIndex)).ToList();

    private static ScannedPage Mark(ScannedPage page, PageSide side, int? sheet, int turns)
    {
        var marked = page.WithSide(side, sheet);
        if (side != PageSide.Back || turns % 4 == 0) return marked;
        var rotated = ImagePipeline.Rotate(page.Image, turns);
        if (page.FilePath is null) return marked.WithImage(rotated);
        // A spooled page: its preview turns now, its full-resolution file when it is saved.
        var turned = marked.WithImage(rotated, filePath: page.FilePath, fullPixelSize: page.FullPixelSize);
        turned.RotationQuarterTurns = (turned.RotationQuarterTurns + turns) % 4;
        return turned;
    }

    /// <summary>
    /// The page queue with a stack's fronts and backs (page ids in scan order) put in reading
    /// order (<see cref="InterleaveManual"/>). Pages no longer in the queue are left out. The
    /// stack takes the place of its first page in the queue; the other pages keep their order
    /// around it. <see cref="QueueCollation.Positions"/> gives each stack page its sheet and side.
    /// </summary>
    public static QueueCollation CollateQueue(IReadOnlyList<Guid> queue, IReadOnlyList<Guid> fronts,
                                              IReadOnlyList<Guid> backs, bool backsReversed = true)
    {
        var present = queue.ToHashSet();
        var f = fronts.Where(present.Contains).Distinct().ToList();
        var stackSet = f.ToHashSet();
        var b = backs.Where(id => present.Contains(id) && !stackSet.Contains(id)).Distinct().ToList();
        stackSet.UnionWith(b);

        var interleave = InterleaveManual(f.Count, b.Count, backsReversed);
        var stack = new List<Guid>(interleave.Order.Count);
        var positions = new Dictionary<Guid, SheetPosition>();
        foreach (var page in interleave.Order)
        {
            var id = page.Batch == PageSide.Front ? f[page.Index] : b[page.Index];
            stack.Add(id);
            positions[id] = new SheetPosition(page.SheetIndex, page.Batch);
        }

        var order = new List<Guid>(queue.Count);
        bool placed = false;
        foreach (var id in queue)
        {
            if (!stackSet.Contains(id))
            {
                order.Add(id);
            }
            else if (!placed)
            {
                order.AddRange(stack);
                placed = true;
            }
        }
        return new QueueCollation(order, positions, interleave);
    }
}
