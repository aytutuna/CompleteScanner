namespace CompleteScanner.Core;

// Port of Sources/CompleteScannerKit/Core/PaperSize.swift: one paper size model for scan areas,
// the ID card page and printing.

/// <summary>
/// A paper size (<see cref="ScanSettings.PaperSize"/>). <see cref="Auto"/> comes first: it is
/// the default and the fallback for a size a newer version adds, and it scans the whole glass
/// or the feeder's own sheet size, as before the setting existed. Stored as the camelCase name
/// ("a4", "b5Jis", "idCard"). Add new sizes after the existing ones.
/// </summary>
public enum PaperSize
{
    Auto,
    Letter,
    Legal,
    Executive,
    A4,
    A5,
    A6,
    B5Jis,
    /// <summary>An ID-1 card (credit card, most ID cards and driving licences), 85.6 × 54 mm.</summary>
    IdCard,
}

/// <summary>Dimensions of the paper sizes and where they apply.</summary>
public static class PaperSizes
{
    /// <summary>A size fits an area when it is at most this much larger (in inches): A4's 11.69 in on an 11.7 in glass, rounding in drivers.</summary>
    public const double FitTolerance = 0.05;

    /// <summary>
    /// Countries and territories that use US Letter (the ICU paper-size list): everywhere else
    /// uses A4.
    /// </summary>
    public static readonly IReadOnlyList<string> LetterRegions =
        ["US", "CA", "MX", "PH", "CL", "CO", "CR", "DO", "GT", "NI", "PA", "PR", "SV", "VE"];

    /// <summary>Every size, in declaration order (Automatic first).</summary>
    public static IReadOnlyList<PaperSize> All { get; } = Enum.GetValues<PaperSize>();

    /// <summary>Portrait width × height in inches; null for <see cref="PaperSize.Auto"/>.</summary>
    public static SizeD? Inches(PaperSize size) => size switch
    {
        PaperSize.Letter => new SizeD(8.5, 11),
        PaperSize.Legal => new SizeD(8.5, 14),
        PaperSize.Executive => new SizeD(7.25, 10.5),
        PaperSize.A4 => new SizeD(8.2677, 11.6929),
        PaperSize.A5 => new SizeD(5.8268, 8.2677),
        PaperSize.A6 => new SizeD(4.1339, 5.8268),
        PaperSize.B5Jis => new SizeD(7.1654, 10.1181),
        PaperSize.IdCard => new SizeD(2.125, 3.370),
        _ => null,
    };

    /// <summary>The stored name: "auto", "letter", "a4", "b5Jis", "idCard" (the Swift raw values).</summary>
    public static string RawValue(this PaperSize size) => size switch
    {
        PaperSize.Auto => "auto",
        PaperSize.Letter => "letter",
        PaperSize.Legal => "legal",
        PaperSize.Executive => "executive",
        PaperSize.A4 => "a4",
        PaperSize.A5 => "a5",
        PaperSize.A6 => "a6",
        PaperSize.B5Jis => "b5Jis",
        PaperSize.IdCard => "idCard",
        _ => throw new ArgumentOutOfRangeException(nameof(size), size, null),
    };

    /// <summary>
    /// The size stored as <paramref name="text"/> (its raw value, compared without regard to
    /// case and surrounding spaces); <see cref="PaperSize.Auto"/> for null and anything else.
    /// </summary>
    public static PaperSize Parse(string? text)
    {
        string trimmed = text?.Trim() ?? "";
        foreach (var size in All)
        {
            if (string.Equals(size.RawValue(), trimmed, StringComparison.OrdinalIgnoreCase)) return size;
        }
        return PaperSize.Auto;
    }

    /// <summary>
    /// The usual paper where the user lives: Letter in <see cref="LetterRegions"/>, A4
    /// everywhere else and when the region is unknown. <paramref name="regionCode"/> is a
    /// two-letter ISO 3166 code in any case.
    /// </summary>
    public static PaperSize DefaultForRegion(string? regionCode)
    {
        string code = regionCode?.Trim().ToUpperInvariant() ?? "";
        return LetterRegions.Contains(code) ? PaperSize.Letter : PaperSize.A4;
    }

    /// <summary>
    /// The named size a sheet of <paramref name="inches"/> is (a printer's paper), either way round,
    /// each side within <see cref="FitTolerance"/>; null for a size without a name here.
    /// </summary>
    public static PaperSize? Match(SizeD inches)
    {
        double shortSide = Math.Min(inches.Width, inches.Height), longSide = Math.Max(inches.Width, inches.Height);
        if (shortSide <= 0) return null;
        foreach (var size in All)
        {
            if (Inches(size) is not { } paper) continue;
            if (Math.Abs(paper.Width - shortSide) <= FitTolerance && Math.Abs(paper.Height - longSide) <= FitTolerance) return size;
        }
        return null;
    }

    /// <summary>The sizes as pickers list them: Automatic, the region's usual size, then the others in declaration order.</summary>
    public static IReadOnlyList<PaperSize> DisplayOrder(string? regionCode)
    {
        var usual = DefaultForRegion(regionCode);
        return [PaperSize.Auto, usual, .. All.Where(size => size != PaperSize.Auto && size != usual)];
    }

    /// <summary>
    /// The size fits <paramref name="area"/> (portrait, within <see cref="FitTolerance"/>).
    /// Automatic always fits, and so does every size when the area is unknown.
    /// </summary>
    public static bool Fits(PaperSize size, SizeD? area)
    {
        if (Inches(size) is not { } paper || area is not { } a || a.Width <= 0 || a.Height <= 0) return true;
        return paper.Width <= a.Width + FitTolerance && paper.Height <= a.Height + FitTolerance;
    }

    /// <summary>
    /// The part of the glass a paper size covers, as a selection (normalized 0...1, origin
    /// top-left, where sheets are laid against the corner), clamped to the glass; null for
    /// Automatic (the whole glass) and for an unknown glass size.
    /// </summary>
    public static RectD? FlatbedSelection(PaperSize size, SizeD bed)
    {
        if (Inches(size) is not { } paper || bed.Width <= 0 || bed.Height <= 0) return null;
        return new RectD(0, 0, Math.Min(1, paper.Width / bed.Width), Math.Min(1, paper.Height / bed.Height));
    }

    /// <summary>
    /// The area a feeder scan asks for, in inches from the top-left corner: the paper size,
    /// clamped to the feeder's largest sheet <paramref name="max"/>; the largest sheet itself
    /// for Automatic.
    /// </summary>
    public static RectD FeederRegionInches(PaperSize size, SizeD max)
    {
        if (Inches(size) is not { } paper) return new RectD(0, 0, max.Width, max.Height);
        return new RectD(0, 0, Math.Min(paper.Width, max.Width), Math.Min(paper.Height, max.Height));
    }

    /// <summary>One line saying what a size scans from <paramref name="source"/>, shown under the paper size picker.</summary>
    public static string Hint(PaperSize size, ScanSource source)
    {
        bool feeder = source == ScanSource.DocumentFeeder;
        if (size == PaperSize.Auto)
        {
            return feeder ? "The sheet size the feeder takes." : "The whole glass, or the area selected on the preview.";
        }
        return feeder
            ? $"{size.Detail()} sheets."
            : $"{size.Detail()}, from the corner of the glass. An area selected on the preview takes its place.";
    }

    /// <summary>Why a size is not offered: it is larger than the glass or the feeder of the scanner.</summary>
    public static string DoesNotFitReason(ScanSource source) =>
        $"Larger than this scanner's {(source == ScanSource.DocumentFeeder ? "feeder" : "glass")} takes.";

    /// <summary>What a picker shows: "Automatic", "Letter", "B5 (JIS)", "ID card".</summary>
    public static string Label(this PaperSize size) => size switch
    {
        PaperSize.Auto => "Automatic",
        PaperSize.Letter => "Letter",
        PaperSize.Legal => "Legal",
        PaperSize.Executive => "Executive",
        PaperSize.A4 => "A4",
        PaperSize.A5 => "A5",
        PaperSize.A6 => "A6",
        PaperSize.B5Jis => "B5 (JIS)",
        PaperSize.IdCard => "ID card",
        _ => size.ToString(),
    };

    /// <summary>The dimensions as people know them: "8.5 × 11 in", "210 × 297 mm"; for Automatic, what it scans.</summary>
    public static string Detail(this PaperSize size) => size switch
    {
        PaperSize.Auto => "The whole glass, or the sheet in the feeder",
        PaperSize.Letter => "8.5 × 11 in",
        PaperSize.Legal => "8.5 × 14 in",
        PaperSize.Executive => "7.25 × 10.5 in",
        PaperSize.A4 => "210 × 297 mm",
        PaperSize.A5 => "148 × 210 mm",
        PaperSize.A6 => "105 × 148 mm",
        PaperSize.B5Jis => "182 × 257 mm",
        PaperSize.IdCard => "85.6 × 54 mm",
        _ => "",
    };
}
