using System.Globalization;
using System.Text;

namespace CompleteScanner.Core;

/// <summary>Which standard a written PDF follows. The first member is the default.</summary>
public enum PdfConformance
{
    /// <summary>A plain PDF file: PDF 1.4, or PDF 1.7 when it is password-protected.</summary>
    Standard,
    /// <summary>
    /// PDF/A-2b (ISO 19005-2, level B) for long-term keeping: PDF 1.7, XMP metadata matching the
    /// document information, an sRGB output intent and a file identifier. Never encrypted.
    /// </summary>
    PdfA2b,
}

/// <summary>
/// How <see cref="PdfBuilder"/> writes a document beyond its pages. The date, the file identifier
/// and (for a protected file) the random bytes are taken from here when given, so the same input
/// gives the same bytes (tests); otherwise the current time and random bytes are used.
/// </summary>
public sealed record PdfWriteOptions
{
    /// <summary>The options of a plain PDF.</summary>
    public static readonly PdfWriteOptions Standard = new();

    public PdfConformance Conformance { get; init; } = PdfConformance.Standard;

    /// <summary>The document's title (the file name without its extension); null leaves it out.</summary>
    public string? Title { get; init; }

    /// <summary>When the document was made (whole seconds, with its offset); null means now.</summary>
    public DateTimeOffset? CreationDate { get; init; }

    /// <summary>The 16-byte file identifier (/ID); null means random bytes.</summary>
    public byte[]? DocumentId { get; init; }

    /// <summary>
    /// The password the file opens with and its permissions (AES-256, <see cref="PdfEncryption"/>);
    /// null writes a file anyone can open. A PDF/A file can't have one: <see cref="PdfBuilder"/>
    /// refuses options asking for both.
    /// </summary>
    public PdfProtection? Protection { get; init; }

    /// <summary>Where a protected file's key, salts and IVs come from (tests); null: the system's cryptographic random generator.</summary>
    internal Action<Span<byte>>? Random { get; init; }

    public bool IsArchival => Conformance == PdfConformance.PdfA2b;

    public bool IsProtected => Protection is not null;

    /// <summary>
    /// The options a save with <paramref name="output"/> asks for, titled <paramref name="title"/>:
    /// protected with <paramref name="protection"/> when the password option is on
    /// (<see cref="OutputOptions.Protect"/>; it must then be given), else PDF/A-2b when the archival
    /// option is on (<see cref="OutputOptions.Archival"/>). The two exclude each other; a settings
    /// file with both on gets the password, never a file anyone can open.
    /// </summary>
    public static PdfWriteOptions For(OutputOptions output, string? title, PdfProtection? protection = null)
    {
        if (output.Protect && protection is null)
        {
            throw new ArgumentNullException(nameof(protection), "The password option is on: a password is needed.");
        }
        return new()
        {
            Conformance = output.Archival && !output.Protect ? PdfConformance.PdfA2b : PdfConformance.Standard,
            Title = title,
            Protection = output.Protect ? protection : null,
        };
    }
}

/// <summary>
/// What a PDF/A-2b file carries besides its pages: the XMP metadata packet, the document
/// information dictionary that must say the same, and the sRGB output intent. Used by
/// <see cref="PdfBuilder"/>; the texts of the archival option are here too.
/// </summary>
public static class PdfA
{
    /// <summary>What the file names as its producer and creator tool (pdf:Producer, xmp:CreatorTool).</summary>
    public const string Producer = "CompleteScanner";

    /// <summary>The output intent's condition: the color space of the embedded profile.</summary>
    public const string OutputConditionIdentifier = "sRGB IEC61966-2.1";

    /// <summary>The archival switch in the inspector's Archive &amp; password section.</summary>
    public const string OptionLabel = "Archival PDF (PDF/A)";

    /// <summary>What the switch does, on hover.</summary>
    public const string OptionHint = "Made to look the same for years. Can't have a password.";

    /// <summary>What the switch does, for screen readers.</summary>
    public const string OptionHelp =
        "Made to be kept for years: a PDF/A file holds everything it needs to look the same later. PDF/A files can't have a password.";

    /// <summary>Why the switch is greyed out while the password is on, shown next to it.</summary>
    public const string NotWithPasswordReason = "Not with a password";

    /// <summary>Why the password option is greyed out while the archival option is on, and the other way round.</summary>
    public const string CannotProtectNote = "PDF/A can't be password-protected.";

    /// <summary>
    /// The sRGB color profile embedded as the output intent: "sRGB-v2-magic.icc" from
    /// Compact-ICC-Profiles by Clinton Ingram (https://github.com/saucecontrol/Compact-ICC-Profiles),
    /// released to the public domain under CC0 1.0. An ICC v2.1 display profile, 736 bytes,
    /// SHA-256 af4efe28f6d311799865f325ba39184a2e978b113ca74124d60af7de22b105f4.
    /// Do not change the array.
    /// </summary>
    public static readonly byte[] SrgbProfile =
    [
        0x00, 0x00, 0x02, 0xE0, 0x6C, 0x63, 0x6D, 0x73, 0x02, 0x10, 0x00, 0x00, 0x6D, 0x6E, 0x74, 0x72,
        0x52, 0x47, 0x42, 0x20, 0x58, 0x59, 0x5A, 0x20, 0x07, 0xE2, 0x00, 0x03, 0x00, 0x14, 0x00, 0x09,
        0x00, 0x0E, 0x00, 0x1D, 0x61, 0x63, 0x73, 0x70, 0x4D, 0x53, 0x46, 0x54, 0x00, 0x00, 0x00, 0x00,
        0x73, 0x61, 0x77, 0x73, 0x63, 0x74, 0x72, 0x6C, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xF6, 0xD6, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0xD3, 0x2D,
        0x68, 0x61, 0x6E, 0x64, 0x93, 0xB2, 0x34, 0xA9, 0x0E, 0xB0, 0x22, 0x8A, 0x98, 0xFD, 0x9A, 0xAF,
        0xA3, 0x67, 0x89, 0x9B, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x09, 0x64, 0x65, 0x73, 0x63, 0x00, 0x00, 0x00, 0xF0, 0x00, 0x00, 0x00, 0x5F,
        0x63, 0x70, 0x72, 0x74, 0x00, 0x00, 0x01, 0x0C, 0x00, 0x00, 0x00, 0x0C, 0x77, 0x74, 0x70, 0x74,
        0x00, 0x00, 0x01, 0x18, 0x00, 0x00, 0x00, 0x14, 0x72, 0x58, 0x59, 0x5A, 0x00, 0x00, 0x01, 0x2C,
        0x00, 0x00, 0x00, 0x14, 0x67, 0x58, 0x59, 0x5A, 0x00, 0x00, 0x01, 0x40, 0x00, 0x00, 0x00, 0x14,
        0x62, 0x58, 0x59, 0x5A, 0x00, 0x00, 0x01, 0x54, 0x00, 0x00, 0x00, 0x14, 0x72, 0x54, 0x52, 0x43,
        0x00, 0x00, 0x01, 0x68, 0x00, 0x00, 0x01, 0x78, 0x67, 0x54, 0x52, 0x43, 0x00, 0x00, 0x01, 0x68,
        0x00, 0x00, 0x01, 0x78, 0x62, 0x54, 0x52, 0x43, 0x00, 0x00, 0x01, 0x68, 0x00, 0x00, 0x01, 0x78,
        0x64, 0x65, 0x73, 0x63, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x05, 0x73, 0x52, 0x47, 0x42,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x74, 0x65, 0x78, 0x74,
        0x00, 0x00, 0x00, 0x00, 0x43, 0x43, 0x30, 0x00, 0x58, 0x59, 0x5A, 0x20, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0xF3, 0x54, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x16, 0xC9, 0x58, 0x59, 0x5A, 0x20,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x6F, 0xA0, 0x00, 0x00, 0x38, 0xF2, 0x00, 0x00, 0x03, 0x8F,
        0x58, 0x59, 0x5A, 0x20, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x62, 0x96, 0x00, 0x00, 0xB7, 0x89,
        0x00, 0x00, 0x18, 0xDA, 0x58, 0x59, 0x5A, 0x20, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x24, 0xA0,
        0x00, 0x00, 0x0F, 0x85, 0x00, 0x00, 0xB6, 0xC4, 0x63, 0x75, 0x72, 0x76, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0xB6, 0x00, 0x00, 0x00, 0x1C, 0x00, 0x38, 0x00, 0x54, 0x00, 0x70, 0x00, 0x8C,
        0x00, 0xA8, 0x00, 0xC4, 0x00, 0xE1, 0x01, 0x00, 0x01, 0x22, 0x01, 0x46, 0x01, 0x6D, 0x01, 0x95,
        0x01, 0xC1, 0x01, 0xF0, 0x02, 0x20, 0x02, 0x55, 0x02, 0x8B, 0x02, 0xC4, 0x03, 0x01, 0x03, 0x3F,
        0x03, 0x82, 0x03, 0xC6, 0x04, 0x0E, 0x04, 0x59, 0x04, 0xA7, 0x04, 0xF9, 0x05, 0x4C, 0x05, 0xA4,
        0x05, 0xFE, 0x06, 0x5C, 0x06, 0xBE, 0x07, 0x21, 0x07, 0x8A, 0x07, 0xF4, 0x08, 0x63, 0x08, 0xD5,
        0x09, 0x49, 0x09, 0xC3, 0x0A, 0x3F, 0x0A, 0xBF, 0x0B, 0x42, 0x0B, 0xC9, 0x0C, 0x54, 0x0C, 0xE1,
        0x0D, 0x74, 0x0E, 0x09, 0x0E, 0xA2, 0x0F, 0x40, 0x0F, 0xE0, 0x10, 0x85, 0x11, 0x2D, 0x11, 0xDA,
        0x12, 0x8A, 0x13, 0x3E, 0x13, 0xF6, 0x14, 0xB2, 0x15, 0x71, 0x16, 0x36, 0x16, 0xFD, 0x17, 0xCA,
        0x18, 0x99, 0x19, 0x6E, 0x1A, 0x46, 0x1B, 0x22, 0x1C, 0x03, 0x1C, 0xE7, 0x1D, 0xD0, 0x1E, 0xBD,
        0x1F, 0xAE, 0x20, 0xA4, 0x21, 0x9E, 0x22, 0x9C, 0x23, 0x9F, 0x24, 0xA5, 0x25, 0xB1, 0x26, 0xC0,
        0x27, 0xD5, 0x28, 0xED, 0x2A, 0x0A, 0x2B, 0x2B, 0x2C, 0x51, 0x2D, 0x7C, 0x2E, 0xAA, 0x2F, 0xDE,
        0x31, 0x16, 0x32, 0x52, 0x33, 0x94, 0x34, 0xD9, 0x36, 0x24, 0x37, 0x73, 0x38, 0xC6, 0x3A, 0x20,
        0x3B, 0x7C, 0x3C, 0xDF, 0x3E, 0x45, 0x3F, 0xB0, 0x41, 0x21, 0x42, 0x96, 0x44, 0x10, 0x45, 0x8F,
        0x47, 0x12, 0x48, 0x9B, 0x4A, 0x28, 0x4B, 0xBB, 0x4D, 0x51, 0x4E, 0xEE, 0x50, 0x8F, 0x52, 0x35,
        0x53, 0xE0, 0x55, 0x90, 0x57, 0x45, 0x59, 0x00, 0x5A, 0xBE, 0x5C, 0x84, 0x5E, 0x4C, 0x60, 0x1B,
        0x61, 0xEF, 0x63, 0xC7, 0x65, 0xA6, 0x67, 0x89, 0x69, 0x71, 0x6B, 0x5F, 0x6D, 0x51, 0x6F, 0x4A,
        0x71, 0x46, 0x73, 0x4A, 0x75, 0x51, 0x77, 0x5E, 0x79, 0x71, 0x7B, 0x88, 0x7D, 0xA6, 0x7F, 0xC8,
        0x81, 0xF0, 0x84, 0x1E, 0x86, 0x50, 0x88, 0x89, 0x8A, 0xC5, 0x8D, 0x09, 0x8F, 0x51, 0x91, 0x9F,
        0x93, 0xF3, 0x96, 0x4B, 0x98, 0xAB, 0x9B, 0x0E, 0x9D, 0x78, 0x9F, 0xE7, 0xA2, 0x5B, 0xA4, 0xD6,
        0xA7, 0x56, 0xA9, 0xDB, 0xAC, 0x67, 0xAE, 0xF7, 0xB1, 0x8F, 0xB4, 0x2A, 0xB6, 0xCC, 0xB9, 0x74,
        0xBC, 0x21, 0xBE, 0xD5, 0xC1, 0x8D, 0xC4, 0x4C, 0xC7, 0x10, 0xC9, 0xDA, 0xCC, 0xAB, 0xCF, 0x7F,
        0xD2, 0x5C, 0xD5, 0x3D, 0xD8, 0x24, 0xDB, 0x12, 0xDE, 0x04, 0xE0, 0xFE, 0xE3, 0xFC, 0xE7, 0x01,
        0xEA, 0x0C, 0xED, 0x1C, 0xF0, 0x34, 0xF3, 0x50, 0xF6, 0x73, 0xF9, 0x9B, 0xFC, 0xCA, 0xFF, 0xFF,
    ];

    /// <summary>A date in a PDF string: "D:20261019213005+03'00'".</summary>
    public static string PdfDate(DateTimeOffset date) =>
        "D:" + date.ToString("yyyyMMddHHmmss", CultureInfo.InvariantCulture) + Offset(date.Offset, "'") + "'";

    /// <summary>The same date in XMP: "2026-10-19T21:30:05+03:00".</summary>
    public static string XmpDate(DateTimeOffset date) =>
        date.ToString("yyyy-MM-dd'T'HH:mm:ss", CultureInfo.InvariantCulture) + Offset(date.Offset, ":");

    /// <summary>"+03" + separator + "00"; "-05" + separator + "30".</summary>
    private static string Offset(TimeSpan offset, string separator)
    {
        char sign = offset < TimeSpan.Zero ? '-' : '+';
        var magnitude = offset.Duration();
        return sign + magnitude.Hours.ToString("D2", CultureInfo.InvariantCulture) + separator
               + magnitude.Minutes.ToString("D2", CultureInfo.InvariantCulture);
    }

    /// <summary>
    /// <paramref name="text"/> as a PDF text string: a literal "(...)" when it is printable ASCII
    /// (with "\", "(" and ")" escaped), otherwise UTF-16BE with its byte order mark, in hex.
    /// </summary>
    public static string TextString(string text)
    {
        if (text.All(c => c is >= ' ' and <= '~'))
        {
            return "(" + text.Replace("\\", "\\\\").Replace("(", "\\(").Replace(")", "\\)") + ")";
        }
        var sb = new StringBuilder("<FEFF");
        foreach (char c in text) sb.Append(((int)c).ToString("X4", CultureInfo.InvariantCulture));
        return sb.Append('>').ToString();
    }

    /// <summary>
    /// A title with the characters XML cannot hold removed (control characters, U+FFFE, U+FFFF
    /// and lone surrogates), so the XMP and the information dictionary carry the same text.
    /// </summary>
    public static string CleanTitle(string title)
    {
        var sb = new StringBuilder(title.Length);
        for (int i = 0; i < title.Length; i++)
        {
            char c = title[i];
            if (char.IsHighSurrogate(c) && i + 1 < title.Length && char.IsLowSurrogate(title[i + 1]))
            {
                sb.Append(c).Append(title[++i]);
            }
            else if (!char.IsSurrogate(c) && c >= ' ' && c != '\u007F' && c != '￾' && c != '￿')
            {
                sb.Append(c);
            }
        }
        return sb.ToString();
    }

    /// <summary>
    /// The document information dictionary: /Title (when given), /Producer, /Creator,
    /// /CreationDate and /ModDate, each the same as its XMP property (<see cref="Xmp"/>).
    /// </summary>
    public static string InfoDictionary(string? title, DateTimeOffset date)
    {
        var sb = new StringBuilder("<<");
        if (title is not null) sb.Append("/Title ").Append(TextString(title)).Append(' ');
        string pdfDate = PdfDate(date);
        sb.Append("/Producer (").Append(Producer).Append(") /Creator (").Append(Producer).Append(") ");
        sb.Append("/CreationDate (").Append(pdfDate).Append(") /ModDate (").Append(pdfDate).Append(")>>");
        return sb.ToString();
    }

    /// <summary>
    /// The XMP packet, UTF-8 without a byte order mark: PDF/A-2 level B (pdfaid), the title
    /// (dc:title, when given), the dates (xmp:CreateDate, ModifyDate and MetadataDate) and the
    /// producer (pdf:Producer, xmp:CreatorTool), matching <see cref="InfoDictionary"/>.
    /// </summary>
    public static byte[] Xmp(string? title, DateTimeOffset date)
    {
        string xmpDate = XmpDate(date);
        var sb = new StringBuilder();
        sb.Append("<?xpacket begin=\"﻿\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?>\n");
        sb.Append("<x:xmpmeta xmlns:x=\"adobe:ns:meta/\">\n");
        sb.Append(" <rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\">\n");
        sb.Append("  <rdf:Description rdf:about=\"\"\n");
        sb.Append("    xmlns:pdfaid=\"http://www.aiim.org/pdfa/ns/id/\"\n");
        sb.Append("    xmlns:dc=\"http://purl.org/dc/elements/1.1/\"\n");
        sb.Append("    xmlns:xmp=\"http://ns.adobe.com/xap/1.0/\"\n");
        sb.Append("    xmlns:pdf=\"http://ns.adobe.com/pdf/1.3/\">\n");
        sb.Append("   <pdfaid:part>2</pdfaid:part>\n");
        sb.Append("   <pdfaid:conformance>B</pdfaid:conformance>\n");
        sb.Append("   <dc:format>application/pdf</dc:format>\n");
        if (title is not null)
        {
            sb.Append("   <dc:title><rdf:Alt><rdf:li xml:lang=\"x-default\">")
              .Append(EscapeXml(title)).Append("</rdf:li></rdf:Alt></dc:title>\n");
        }
        sb.Append("   <xmp:CreateDate>").Append(xmpDate).Append("</xmp:CreateDate>\n");
        sb.Append("   <xmp:ModifyDate>").Append(xmpDate).Append("</xmp:ModifyDate>\n");
        sb.Append("   <xmp:MetadataDate>").Append(xmpDate).Append("</xmp:MetadataDate>\n");
        sb.Append("   <xmp:CreatorTool>").Append(Producer).Append("</xmp:CreatorTool>\n");
        sb.Append("   <pdf:Producer>").Append(Producer).Append("</pdf:Producer>\n");
        sb.Append("  </rdf:Description>\n");
        sb.Append(" </rdf:RDF>\n");
        sb.Append("</x:xmpmeta>\n");
        sb.Append("<?xpacket end=\"w\"?>");
        return new UTF8Encoding(encoderShouldEmitUTF8Identifier: false).GetBytes(sb.ToString());
    }

    private static string EscapeXml(string text) =>
        text.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;").Replace("\"", "&quot;");

    /// <summary>The catalog's /OutputIntents entry, its profile in object <paramref name="profileObject"/>.</summary>
    public static string OutputIntents(int profileObject) =>
        $"[<</Type /OutputIntent /S /GTS_PDFA1 /OutputConditionIdentifier ({OutputConditionIdentifier}) " +
        $"/Info ({OutputConditionIdentifier}) /DestOutputProfile {profileObject} 0 R>>]";
}
