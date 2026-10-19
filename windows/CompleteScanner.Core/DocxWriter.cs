using System.Globalization;
using System.Text;

namespace CompleteScanner.Core;

// Twin of Sources/CompleteScannerKit/Output/DocxWriter.swift: the same package, byte for byte.

/// <summary>
/// The Word document of a save (<see cref="OutputFormat.Word"/>): the recognized text of the
/// pages, one Word paragraph per paragraph found (<see cref="OcrText.Paragraphs(OcrPage)"/>), each
/// page after the first starting on a new page. The smallest package Word and LibreOffice open:
/// "[Content_Types].xml", "_rels/.rels" and "word/document.xml", stored in a zip by
/// <see cref="ZipStore"/>. No styles part, so the text takes the reader's default font. The
/// paper is the first page's size, with one-inch margins (less on a page under 8 inches).
/// </summary>
public static class DocxWriter
{
    /// <summary>One inch in twentieths of a point, Word's unit for page sizes.</summary>
    public const int TwipsPerInch = 1440;
    /// <summary>Word's smallest and largest paper side, in twips (0.1 in and 22 in).</summary>
    public const int MinPageTwips = 144, MaxPageTwips = 31680;

    public const string ContentTypesXml =
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n" +
        "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">" +
        "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>" +
        "<Default Extension=\"xml\" ContentType=\"application/xml\"/>" +
        "<Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/>" +
        "</Types>";

    public const string RelationshipsXml =
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n" +
        "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">" +
        "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/>" +
        "</Relationships>";

    /// <summary>The .docx file for <paramref name="pages"/>.</summary>
    public static byte[] Make(IReadOnlyList<OcrPage> pages)
    {
        var utf8 = new UTF8Encoding(encoderShouldEmitUTF8Identifier: false);
        return ZipStore.Make(
        [
            new ZipStoreEntry("[Content_Types].xml", utf8.GetBytes(ContentTypesXml)),
            new ZipStoreEntry("_rels/.rels", utf8.GetBytes(RelationshipsXml)),
            new ZipStoreEntry("word/document.xml", utf8.GetBytes(DocumentXml(pages))),
        ]);
    }

    /// <summary>"word/document.xml": the paragraphs of every page, then the paper and margins.</summary>
    public static string DocumentXml(IReadOnlyList<OcrPage> pages)
    {
        var sb = new StringBuilder();
        sb.Append("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n");
        sb.Append("<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:body>");
        for (int index = 0; index < pages.Count; index++)
        {
            var paragraphs = OcrText.Paragraphs(pages[index]);
            if (paragraphs.Count == 0)
            {
                AppendParagraph(sb, "", pageBreakBefore: index > 0);
                continue;
            }
            for (int p = 0; p < paragraphs.Count; p++)
            {
                AppendParagraph(sb, paragraphs[p].Text, pageBreakBefore: index > 0 && p == 0);
            }
        }
        if (pages.Count == 0) AppendParagraph(sb, "", pageBreakBefore: false);

        var (width, height) = PageSizeTwips(pages.Count > 0 ? pages[0] : null);
        int margin = MarginTwips(width, height);
        sb.Append("<w:sectPr><w:pgSz w:w=\"").Append(I(width)).Append("\" w:h=\"").Append(I(height)).Append('"');
        if (width > height) sb.Append(" w:orient=\"landscape\"");
        sb.Append("/><w:pgMar w:top=\"").Append(I(margin)).Append("\" w:right=\"").Append(I(margin))
          .Append("\" w:bottom=\"").Append(I(margin)).Append("\" w:left=\"").Append(I(margin))
          .Append("\" w:header=\"").Append(I(margin / 2)).Append("\" w:footer=\"").Append(I(margin / 2))
          .Append("\" w:gutter=\"0\"/></w:sectPr>");
        sb.Append("</w:body></w:document>");
        return sb.ToString();
    }

    /// <summary>
    /// The paper of the document in twips: the page's size in points × 20, each side kept within
    /// <see cref="MinPageTwips"/>...<see cref="MaxPageTwips"/>; US Letter without a page.
    /// </summary>
    public static (int Width, int Height) PageSizeTwips(OcrPage? page)
    {
        if (page is null || page.WidthPoints <= 0 || page.HeightPoints <= 0) return (12240, 15840);
        return (Twips(page.WidthPoints), Twips(page.HeightPoints));
    }

    /// <summary>One inch, or an eighth of the shorter side of a smaller page.</summary>
    public static int MarginTwips(int width, int height) => Math.Min(TwipsPerInch, Math.Min(width, height) / 8);

    /// <summary>
    /// <paramref name="text"/> made safe for an XML text node: &amp;, &lt; and &gt; escaped, and
    /// the characters XML cannot hold (control characters other than tab, line feed and carriage
    /// return, U+FFFE, U+FFFF, unpaired surrogates) left out.
    /// </summary>
    public static string EscapeXml(string text)
    {
        var sb = new StringBuilder(text.Length);
        for (int i = 0; i < text.Length; i++)
        {
            char c = text[i];
            if (char.IsHighSurrogate(c) && i + 1 < text.Length && char.IsLowSurrogate(text[i + 1]))
            {
                sb.Append(c).Append(text[i + 1]);
                i++;
                continue;
            }
            if (char.IsSurrogate(c)) continue;
            switch (c)
            {
                case '&': sb.Append("&amp;"); break;
                case '<': sb.Append("&lt;"); break;
                case '>': sb.Append("&gt;"); break;
                case '\t' or '\n' or '\r': sb.Append(c); break;
                default:
                    if (c < 0x20 || c == '\uFFFE' || c == '\uFFFF') break;
                    sb.Append(c);
                    break;
            }
        }
        return sb.ToString();
    }

    /// <summary>
    /// One paragraph: its text in one run, a line break (between the rows of a table) as
    /// <c>w:br</c>, a tab (between the pieces of a row) as <c>w:tab</c>.
    /// </summary>
    private static void AppendParagraph(StringBuilder sb, string text, bool pageBreakBefore)
    {
        sb.Append("<w:p>");
        if (pageBreakBefore) sb.Append("<w:pPr><w:pageBreakBefore/></w:pPr>");
        string clean = EscapeXml(text).Replace("\r", "");
        if (clean.Length > 0)
        {
            sb.Append("<w:r>");
            string[] lines = clean.Split('\n');
            for (int l = 0; l < lines.Length; l++)
            {
                if (l > 0) sb.Append("<w:br/>");
                string[] pieces = lines[l].Split('\t');
                for (int i = 0; i < pieces.Length; i++)
                {
                    if (i > 0) sb.Append("<w:tab/>");
                    if (pieces[i].Length > 0) sb.Append("<w:t xml:space=\"preserve\">").Append(pieces[i]).Append("</w:t>");
                }
            }
            sb.Append("</w:r>");
        }
        sb.Append("</w:p>");
    }

    private static int Twips(double points) =>
        (int)Math.Clamp(Math.Round(points * 20, MidpointRounding.AwayFromZero), MinPageTwips, MaxPageTwips);

    private static string I(int value) => value.ToString(CultureInfo.InvariantCulture);
}
