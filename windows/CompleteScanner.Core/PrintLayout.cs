namespace CompleteScanner.Core;

// Twin of Sources/CompleteScannerKit/Output/PrintLayout.swift: where a scan goes on the paper when
// it is printed (the Copy task, the ID card page, the ruler test page). Printing at real size is
// the point: a page scanned at 300 dpi prints at pixels / 300 inches, never scaled to the page
// unless the user asks for it.

/// <summary>How a page is sized on the paper.</summary>
public enum PrintMode
{
    /// <summary>At real size (pixels / dpi), like a photocopier; what does not fit is cut off.</summary>
    ActualSize,
    /// <summary>Made smaller (never larger) to fit the part of the paper the printer prints on.</summary>
    FitToPrintable,
}

/// <summary>Where a page printed at real size goes on the paper.</summary>
public enum PrintAlign
{
    /// <summary>Against the top-left corner of the paper, where the original lay against the corner of the glass.</summary>
    PaperOrigin,
    /// <summary>In the middle of the paper: an area selected on the preview.</summary>
    Center,
}

/// <summary>
/// The paper a printer prints on and the part of it it can print on (inside its margins), in
/// inches with the origin at the top-left corner of the paper, portrait as the paper is fed.
/// </summary>
public sealed record PrinterPaper(SizeD Paper, RectD Printable)
{
    /// <summary>
    /// <paramref name="paper"/> with <paramref name="printable"/> clamped to it; a missing or empty
    /// printable area (a driver that does not say) is the whole sheet.
    /// </summary>
    public static PrinterPaper Make(SizeD paper, RectD? printable)
    {
        var whole = new RectD(0, 0, paper.Width, paper.Height);
        if (printable is not { } p) return new PrinterPaper(paper, whole);
        var clamped = p.Standardized.Intersection(whole);
        return new PrinterPaper(paper, clamped.IsEmpty ? whole : clamped);
    }

    /// <summary>The named size the paper is (<see cref="PaperSizes.Match"/>); null for any other size.</summary>
    public PaperSize? Size => PaperSizes.Match(Paper);

    /// <summary>The widest edge the printer cannot print on, in inches.</summary>
    public double LargestMargin =>
        Math.Max(Math.Max(Printable.MinX, Printable.MinY),
                 Math.Max(Paper.Width - Printable.MaxX, Paper.Height - Printable.MaxY));

    /// <summary>"Letter (8.5 × 11 in)", "A4 (210 × 297 mm)", or "8.27 × 11.69 in" for a size without a name.</summary>
    public string Description => Size is { } size
        ? $"{size.Label()} ({size.Detail()})"
        : string.Create(System.Globalization.CultureInfo.InvariantCulture, $"{Paper.Width:0.##} × {Paper.Height:0.##} in");
}

/// <summary>
/// Where a page goes on the paper, in inches from the paper's top-left corner, and how: its scale
/// (1 at real size), how many quarter turns clockwise it is turned first, and how far it runs past
/// the part of the paper the printer prints on.
/// </summary>
public sealed record PrintPlacement(RectD Rect, double Scale, int QuarterTurns, double ClippedInches)
{
    /// <summary>Enough is cut off to say so (more than <see cref="PrintLayout.ClipWarningInches"/>).</summary>
    public bool IsClipped => ClippedInches > PrintLayout.ClipWarningInches;
}

/// <summary>Places pages on the paper for printing (see <see cref="PrintMode"/> and <see cref="PrintAlign"/>).</summary>
public static class PrintLayout
{
    /// <summary>Less than this much cut off (about 1 mm) is not worth a warning.</summary>
    public const double ClipWarningInches = 0.05;

    /// <summary>Wiggle room for comparing lengths in inches.</summary>
    private const double Epsilon = 1e-9;

    /// <summary>
    /// Where a scan <paramref name="pixelWidth"/> × <paramref name="pixelHeight"/> at
    /// <paramref name="dpi"/> goes on <paramref name="paper"/> (inches) whose printer prints on
    /// <paramref name="printable"/>. At real size the page is pixels / dpi inches, against the
    /// paper's corner or centred on the paper (<paramref name="align"/>), turned a quarter only when
    /// that cuts off less; <see cref="PrintPlacement.ClippedInches"/> says how far it runs past the
    /// printable area. Fit to the printable area makes it smaller by
    /// min(printable width / width, printable height / height, 1), turned a quarter when that
    /// gives a larger scale, centred in the printable area.
    /// </summary>
    public static PrintPlacement Place(int pixelWidth, int pixelHeight, int dpi, SizeD paper, RectD printable,
                                       PrintMode mode, PrintAlign align)
    {
        double resolution = Math.Max(1, dpi);
        double width = Math.Max(0, pixelWidth) / resolution, height = Math.Max(0, pixelHeight) / resolution;
        var area = printable.Standardized;
        if (area.IsEmpty) area = new RectD(0, 0, paper.Width, paper.Height);

        if (mode == PrintMode.FitToPrintable)
        {
            double upright = FitScale(width, height, area);
            double turned = FitScale(height, width, area);
            int turns = turned > upright + Epsilon ? 1 : 0;
            double scale = Math.Max(upright, turned);
            double w = (turns == 1 ? height : width) * scale, h = (turns == 1 ? width : height) * scale;
            var fitted = new RectD(area.X + (area.Width - w) / 2, area.Y + (area.Height - h) / 2, w, h);
            return new PrintPlacement(fitted, scale, turns, ClippedInches(fitted, area));
        }

        int quarterTurns = Overflow(height, width, paper) + Epsilon < Overflow(width, height, paper) ? 1 : 0;
        double rw = quarterTurns == 1 ? height : width, rh = quarterTurns == 1 ? width : height;
        var rect = align == PrintAlign.Center
            ? new RectD((paper.Width - rw) / 2, (paper.Height - rh) / 2, rw, rh)
            : new RectD(0, 0, rw, rh);
        return new PrintPlacement(rect, 1, quarterTurns, ClippedInches(rect, area));
    }

    /// <summary><see cref="Place(int, int, int, SizeD, RectD, PrintMode, PrintAlign)"/> on a printer's paper.</summary>
    public static PrintPlacement Place(int pixelWidth, int pixelHeight, int dpi, PrinterPaper paper,
                                       PrintMode mode, PrintAlign align) =>
        Place(pixelWidth, pixelHeight, dpi, paper.Paper, paper.Printable, mode, align);

    /// <summary>How far <paramref name="rect"/> runs past <paramref name="printable"/> on its worst side, in inches (0 inside it).</summary>
    public static double ClippedInches(RectD rect, RectD printable)
    {
        var r = rect.Standardized;
        var p = printable.Standardized;
        double worst = Math.Max(Math.Max(p.MinX - r.MinX, p.MinY - r.MinY), Math.Max(r.MaxX - p.MaxX, r.MaxY - p.MaxY));
        return worst > Epsilon ? worst : 0;
    }

    /// <summary>A rectangle in inches in other units: 96 for WPF's device-independent pixels, 72 for points.</summary>
    public static RectD ToUnits(RectD inches, double unitsPerInch) =>
        new(inches.X * unitsPerInch, inches.Y * unitsPerInch, inches.Width * unitsPerInch, inches.Height * unitsPerInch);

    /// <summary>A size in inches in other units (96 for WPF, 72 for points).</summary>
    public static SizeD ToUnits(SizeD inches, double unitsPerInch) =>
        new(inches.Width * unitsPerInch, inches.Height * unitsPerInch);

    /// <summary>
    /// A copy of the whole glass or of a page lies against the corner, as it lay on the glass; an
    /// area selected on the preview is centred.
    /// </summary>
    public static PrintAlign AlignFor(bool hasSelection) => hasSelection ? PrintAlign.Center : PrintAlign.PaperOrigin;

    /// <summary>
    /// What to tell the user about a page cut off by more than <see cref="ClipWarningInches"/>: a page
    /// larger than the paper, or edges in the printer's margins; null when nothing worth saying is cut off.
    /// </summary>
    public static string? ClipWarning(PrintPlacement placement, SizeD paper)
    {
        if (!placement.IsClipped) return null;
        double beyondPaper = ClippedInches(placement.Rect, new RectD(0, 0, paper.Width, paper.Height));
        return beyondPaper > ClipWarningInches
            ? $"Larger than the paper: up to {Millimetres(beyondPaper)} mm is cut off. Turn on Fit to page to print all of it."
            : $"Edges may be cut by up to {Millimetres(placement.ClippedInches)} mm (printer margins).";
    }

    /// <summary>Inches as whole millimetres, rounded up (at least 1).</summary>
    public static int Millimetres(double inches) =>
        Math.Max(1, (int)Math.Ceiling(Math.Round(inches * 25.4, 6)));

    private static double FitScale(double width, double height, RectD area)
    {
        if (width <= 0 || height <= 0) return 1;
        return Math.Min(Math.Min(area.Width / width, area.Height / height), 1);
    }

    /// <summary>How far a page runs past the paper across and down together.</summary>
    private static double Overflow(double width, double height, SizeD paper) =>
        Math.Max(0, width - paper.Width) + Math.Max(0, height - paper.Height);
}

/// <summary>How a number of copies is asked of a printer.</summary>
/// <param name="TicketCopies">The copy count the print job asks the printer for.</param>
/// <param name="DocumentRepeats">How many times the pages are put in the job, one after the other (collated).</param>
public sealed record PrintCopiesPlan(int TicketCopies, int DocumentRepeats);

/// <summary>The number of copies the user can ask for, and how a printer is asked for them.</summary>
public static class PrintCopies
{
    /// <summary>The most copies asked for at once.</summary>
    public const int MaxCount = 99;

    /// <summary><paramref name="count"/> within 1 … <see cref="MaxCount"/>.</summary>
    public static int Clamp(int count) => Math.Clamp(count, 1, MaxCount);

    /// <summary>
    /// The printer makes the copies (collated) when it says it can make that many and, for more than
    /// one page, that it collates (<paramref name="canCollate"/>); otherwise, and when it does not
    /// say, the <paramref name="pageCount"/> pages are put in the job that many times, so the copies
    /// come out in order whatever the printer does.
    /// </summary>
    public static PrintCopiesPlan Plan(int requested, int? maxCopyCount, int pageCount = 1, bool canCollate = true)
    {
        int count = Clamp(requested);
        if (count == 1) return new PrintCopiesPlan(1, 1);
        bool printerMakesThem = maxCopyCount is { } max && max >= count && (pageCount <= 1 || canCollate);
        return printerMakesThem ? new PrintCopiesPlan(count, 1) : new PrintCopiesPlan(1, count);
    }
}

/// <summary>A test page to check that prints come out at real size.</summary>
public static class PrintCalibration
{
    /// <summary>
    /// A white page <paramref name="paper"/> large at <paramref name="dpi"/> (round(paper × dpi)
    /// pixels) with a grey grid line every inch from the paper's top-left corner, and centimetre ticks
    /// in black along the first inch line across and down: 0.15 in long, 0.3 in at every 5 cm.
    /// Printed at real size, the squares measure 1 inch and the ticks 1 cm with a ruler.
    /// </summary>
    public static RgbaImage MakeRulerPage(SizeD paper, int dpi)
    {
        int d = Math.Max(1, dpi);
        int width = Math.Max(1, Pixels(paper.Width, d)), height = Math.Max(1, Pixels(paper.Height, d));
        var page = RgbaImage.Filled(width, height, 255, 255, 255);
        int t = LineWidth(d);
        for (int k = 1; Pixels(k, d) < width; k++) Fill(page, Pixels(k, d) - t / 2, 0, t, height, 128);
        for (int k = 1; Pixels(k, d) < height; k++) Fill(page, 0, Pixels(k, d) - t / 2, width, t, 128);
        int shortTick = Pixels(0.15, d), longTick = Pixels(0.3, d);
        for (int k = 0; ; k++)
        {
            int x = TickPosition(k, d);
            if (x >= width) break;
            Fill(page, x - t / 2, d, t, k % 5 == 0 ? longTick : shortTick, 0);
        }
        for (int k = 0; ; k++)
        {
            int y = TickPosition(k, d);
            if (y >= height) break;
            Fill(page, d, y - t / 2, k % 5 == 0 ? longTick : shortTick, t, 0);
        }
        return page;
    }

    /// <summary>The width of the ruler's lines: about 1/150 in, at least one pixel.</summary>
    public static int LineWidth(int dpi) => Math.Max(1, Pixels(1.0 / 150, Math.Max(1, dpi)));

    /// <summary>The pixel of the <paramref name="k"/>-th centimetre tick from the first inch line.</summary>
    public static int TickPosition(int k, int dpi) =>
        (int)Math.Round(dpi + k * (double)dpi / 2.54, MidpointRounding.AwayFromZero);

    private static int Pixels(double inches, int dpi) => (int)Math.Round(inches * dpi, MidpointRounding.AwayFromZero);

    private static void Fill(RgbaImage page, int x, int y, int w, int h, byte value)
    {
        int x0 = Math.Max(0, x), y0 = Math.Max(0, y);
        int x1 = Math.Min(page.Width, x + w), y1 = Math.Min(page.Height, y + h);
        for (int row = y0; row < y1; row++)
        {
            int i = (row * page.Width + x0) * 4;
            for (int col = x0; col < x1; col++, i += 4)
            {
                page.Pixels[i] = value;
                page.Pixels[i + 1] = value;
                page.Pixels[i + 2] = value;
                page.Pixels[i + 3] = 255;
            }
        }
    }
}

/// <summary>What the app says about printing.</summary>
public static class PrintText
{
    /// <summary>Why the Copy task cannot be started.</summary>
    public const string NoPrinterReason = "No printer is installed.";

    /// <summary>The error when there is nothing to print on.</summary>
    public const string NoPrinterMessage = "No printer is installed. Add a printer, then try again.";

    /// <summary>"Sent 1 page to Office Printer.", "Sent 2 pages to Office Printer, 3 copies."</summary>
    public static string Sent(int pageCount, int copies, string printerName)
    {
        string pages = $"{pageCount} page{(pageCount == 1 ? "" : "s")}";
        return copies > 1 ? $"Sent {pages} to {printerName}, {copies} copies." : $"Sent {pages} to {printerName}.";
    }

    /// <summary>"Actual size" or "Fit to page".</summary>
    public static string ModeLabel(bool fitToPage) => fitToPage ? "Fit to page" : "Actual size";

    /// <summary>
    /// What the paper size picker says for a copy: on the glass, Automatic scans the part the
    /// printer's paper covers (a copier copies the sheet it prints on); otherwise as
    /// <see cref="PaperSizes.Hint"/>.
    /// </summary>
    public static string CopyPaperHint(PaperSize size, ScanSource source) =>
        size == PaperSize.Auto && source == ScanSource.Flatbed
            ? "The printer's paper, from the corner of the glass. An area selected on the preview takes its place."
            : PaperSizes.Hint(size, source);
}
