namespace CompleteScanner.Core;

/// <summary>
/// The paper sizes of ICAP_SUPPORTEDSIZES (TWSS_* in twain.h 2.3) with their dimensions, so a
/// source that lists sizes instead of a physical feeder size still yields one. Windows only,
/// like the rest of the TWAIN support (see TwainCodes.cs).
/// </summary>
public static class TwainSizes
{
    public const int None = 0;
    public const int A4 = 1;
    public const int JisB5 = 2;
    public const int UsLetter = 3;
    public const int UsLegal = 4;
    public const int A5 = 5;
    public const int IsoB4 = 6;
    public const int IsoB6 = 7;
    // 8 was TWSS_B, withdrawn in TWAIN 2.0.
    public const int UsLedger = 9;
    public const int UsExecutive = 10;
    public const int A3 = 11;
    public const int IsoB3 = 12;
    public const int A6 = 13;
    public const int C4 = 14;
    public const int C5 = 15;
    public const int C6 = 16;
    public const int FourA0 = 17;
    public const int TwoA0 = 18;
    public const int A0 = 19;
    public const int A1 = 20;
    public const int A2 = 21;
    public const int A7 = 22;
    public const int A8 = 23;
    public const int A9 = 24;
    public const int A10 = 25;
    public const int IsoB0 = 26;
    public const int IsoB1 = 27;
    public const int IsoB2 = 28;
    public const int IsoB5 = 29;
    public const int IsoB7 = 30;
    public const int IsoB8 = 31;
    public const int IsoB9 = 32;
    public const int IsoB10 = 33;
    public const int JisB0 = 34;
    public const int JisB1 = 35;
    public const int JisB2 = 36;
    public const int JisB3 = 37;
    public const int JisB4 = 38;
    public const int JisB6 = 39;
    public const int JisB7 = 40;
    public const int JisB8 = 41;
    public const int JisB9 = 42;
    public const int JisB10 = 43;
    public const int C0 = 44;
    public const int C1 = 45;
    public const int C2 = 46;
    public const int C3 = 47;
    public const int C7 = 48;
    public const int C8 = 49;
    public const int C9 = 50;
    public const int C10 = 51;
    public const int UsStatement = 52;
    public const int BusinessCard = 53;
    /// <summary>TWSS_MAXSIZE: "the largest the device can scan", no fixed dimensions.</summary>
    public const int MaxSize = 54;

    private const double MillimetersPerInch = 25.4;

    // Portrait width × height. ISO 216 / ISO 269 / JIS P 0138 sizes in millimeters, the US
    // sizes in inches; the business card is TWAIN's 90 × 55 mm.
    private static readonly Dictionary<int, (double Width, double Height, bool Inches)> Table = new()
    {
        [FourA0] = (1682, 2378, false),
        [TwoA0] = (1189, 1682, false),
        [A0] = (841, 1189, false),
        [A1] = (594, 841, false),
        [A2] = (420, 594, false),
        [A3] = (297, 420, false),
        [A4] = (210, 297, false),
        [A5] = (148, 210, false),
        [A6] = (105, 148, false),
        [A7] = (74, 105, false),
        [A8] = (52, 74, false),
        [A9] = (37, 52, false),
        [A10] = (26, 37, false),
        [IsoB0] = (1000, 1414, false),
        [IsoB1] = (707, 1000, false),
        [IsoB2] = (500, 707, false),
        [IsoB3] = (353, 500, false),
        [IsoB4] = (250, 353, false),
        [IsoB5] = (176, 250, false),
        [IsoB6] = (125, 176, false),
        [IsoB7] = (88, 125, false),
        [IsoB8] = (62, 88, false),
        [IsoB9] = (44, 62, false),
        [IsoB10] = (31, 44, false),
        [JisB0] = (1030, 1456, false),
        [JisB1] = (728, 1030, false),
        [JisB2] = (515, 728, false),
        [JisB3] = (364, 515, false),
        [JisB4] = (257, 364, false),
        [JisB5] = (182, 257, false),
        [JisB6] = (128, 182, false),
        [JisB7] = (91, 128, false),
        [JisB8] = (64, 91, false),
        [JisB9] = (45, 64, false),
        [JisB10] = (32, 45, false),
        [C0] = (917, 1297, false),
        [C1] = (648, 917, false),
        [C2] = (458, 648, false),
        [C3] = (324, 458, false),
        [C4] = (229, 324, false),
        [C5] = (162, 229, false),
        [C6] = (114, 162, false),
        [C7] = (81, 114, false),
        [C8] = (57, 81, false),
        [C9] = (40, 57, false),
        [C10] = (28, 40, false),
        [UsLetter] = (8.5, 11, true),
        [UsLegal] = (8.5, 14, true),
        [UsLedger] = (11, 17, true),
        [UsExecutive] = (7.25, 10.5, true),
        [UsStatement] = (5.5, 8.5, true),
        [BusinessCard] = (55, 90, false),
    };

    /// <summary>Portrait width × height in inches of a TWSS value; null for None, MaxSize and unknown values.</summary>
    public static SizeD? Inches(int size)
    {
        if (!Table.TryGetValue(size, out var entry)) return null;
        return entry.Inches
            ? new SizeD(entry.Width, entry.Height)
            : new SizeD(entry.Width / MillimetersPerInch, entry.Height / MillimetersPerInch);
    }

    /// <summary>
    /// The TWSS value of an app paper size; <see cref="None"/> for Automatic and for the ID
    /// card, which TWAIN has no size for (its business card is 90 × 55 mm).
    /// </summary>
    public static int FromPaperSize(PaperSize size) => size switch
    {
        PaperSize.Letter => UsLetter,
        PaperSize.Legal => UsLegal,
        PaperSize.Executive => UsExecutive,
        PaperSize.A4 => A4,
        PaperSize.A5 => A5,
        PaperSize.A6 => A6,
        PaperSize.B5Jis => JisB5,
        _ => None,
    };

    /// <summary>
    /// The area every listed size fits in (the widest width by the tallest height): the
    /// biggest sheet a feeder that reports sizes rather than a physical area takes. Null when
    /// none has fixed dimensions.
    /// </summary>
    public static SizeD? Largest(IEnumerable<int> sizes)
    {
        double width = 0, height = 0;
        foreach (int size in sizes)
        {
            if (Inches(size) is not { } inches) continue;
            width = Math.Max(width, inches.Width);
            height = Math.Max(height, inches.Height);
        }
        return width > 0 && height > 0 ? new SizeD(width, height) : null;
    }
}
