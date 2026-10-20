using System.Globalization;
using System.Text;

namespace CompleteScanner.Core;

// Twin of Sources/CompleteScannerKit/Output/DocxWriter.swift: the same package, byte for byte.

/// <summary>How the picture of a page is stored in a Word document.</summary>
public enum DocxPictureFormat
{
    /// <summary>Color and gray pages, as the PDF size stores them in a PDF.</summary>
    Jpeg,
    /// <summary>Black &amp; white pages, one bit per pixel and lossless.</summary>
    Png,
}

/// <summary>The picture of a page as it goes into a Word document: its encoded bytes and their format.</summary>
public sealed record DocxPicture(byte[] Data, DocxPictureFormat Format);

/// <summary>
/// The Word document of a save (<see cref="OutputFormat.Word"/>): the recognized text of the
/// pages, one Word paragraph per paragraph found (<see cref="OcrText.Paragraphs(OcrPage)"/>), each
/// page after the first starting on a new page. The smallest package Word and LibreOffice open:
/// "[Content_Types].xml", "_rels/.rels" and "word/document.xml", stored in a zip by
/// <see cref="ZipStore"/>. No styles part, so the text takes the reader's default font. The
/// paper is the first page's size, with one-inch margins (less on a page under 8 inches).
/// <para>
/// With page pictures (<see cref="OutputOptions.WordPageImages"/>) each page starts with its
/// picture, an inline DrawingML picture in a centred paragraph of its own, at the page's real
/// size or shrunk to fit inside the margins with its shape kept, and its text follows: a full
/// page's picture fills the paper and its text starts on the next one. The pictures are
/// "word/media/image1.jpeg" (or .png) and on, linked from "word/_rels/document.xml.rels".
/// Without pictures the package is byte for byte the text-only one.
/// </para>
/// </summary>
public static class DocxWriter
{
    /// <summary>One inch in twentieths of a point, Word's unit for page sizes.</summary>
    public const int TwipsPerInch = 1440;
    /// <summary>Word's smallest and largest paper side, in twips (0.1 in and 22 in).</summary>
    public const int MinPageTwips = 144, MaxPageTwips = 31680;
    /// <summary>DrawingML's unit: English Metric Units per point and per twip (914,400 per inch).</summary>
    public const long EmuPerPoint = 12700, EmuPerTwip = 635;

    /// <summary>The page pictures switch (<see cref="OutputOptions.WordPageImages"/>) as the inspector shows it.</summary>
    public const string PageImagesLabel = "Include page images";

    /// <summary>What the page pictures switch does, on and off.</summary>
    public static string PageImagesHint(bool on) => on
        ? "Each page as scanned, then its text you can edit. The pictures are stored at the size chosen below."
        : "Only the text you can edit: the pictures of the pages are left out.";

    /// <summary>The relationship type of a picture's part.</summary>
    public const string ImageRelationshipType = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/image";

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

    /// <summary>
    /// The .docx file for <paramref name="pages"/>; <paramref name="pictures"/> holds each page's
    /// picture by index (null, or no entry, for a page without one).
    /// </summary>
    public static byte[] Make(IReadOnlyList<OcrPage> pages, IReadOnlyList<DocxPicture?>? pictures = null) =>
        ZipStore.Make(PackageEntries(pages, pictures));

    /// <summary>
    /// The largest Word document a save writes, in bytes (2 GB): within what a zip without zip64
    /// addresses and what one array holds in memory, on both platforms alike.
    /// </summary>
    public const long MaxPackageBytes = 2_000_000_000;

    /// <summary>Why a Word document over <see cref="MaxPackageBytes"/> is not written, and what to do instead.</summary>
    public const string TooLargeMessage =
        "The Word document would be larger than 2 GB, too large to write. Save fewer pages in each document, "
        + "choose a smaller page image size, or turn off \"Include page images\".";

    /// <summary>
    /// The size in bytes of the .docx file <see cref="Make"/> writes for <paramref name="pages"/>
    /// and <paramref name="pictures"/>, worked out without writing it; a save checks it against
    /// <see cref="MaxPackageBytes"/> first.
    /// </summary>
    public static long PackageSize(IReadOnlyList<OcrPage> pages, IReadOnlyList<DocxPicture?>? pictures = null) =>
        ZipStore.PackageSize(PackageEntries(pages, pictures));

    /// <summary>The parts of the package, in the order they are stored.</summary>
    private static List<ZipStoreEntry> PackageEntries(IReadOnlyList<OcrPage> pages, IReadOnlyList<DocxPicture?>? pictures)
    {
        var utf8 = new UTF8Encoding(encoderShouldEmitUTF8Identifier: false);
        var placed = PlacedPictures(pages, pictures);
        var entries = new List<ZipStoreEntry>
        {
            new("[Content_Types].xml", utf8.GetBytes(PackageContentTypesXml(placed))),
            new("_rels/.rels", utf8.GetBytes(RelationshipsXml)),
            new("word/document.xml", utf8.GetBytes(DocumentXml(pages, pictures))),
        };
        if (placed.Count > 0)
        {
            entries.Add(new ZipStoreEntry("word/_rels/document.xml.rels", utf8.GetBytes(DocumentRelationshipsXml(placed))));
            for (int i = 0; i < placed.Count; i++)
            {
                entries.Add(new ZipStoreEntry("word/media/" + MediaName(i + 1, placed[i].Format), placed[i].Data));
            }
        }
        return entries;
    }

    /// <summary>
    /// "word/document.xml": the paragraphs of every page (after its picture, when it has one),
    /// then the paper and margins.
    /// </summary>
    public static string DocumentXml(IReadOnlyList<OcrPage> pages, IReadOnlyList<DocxPicture?>? pictures = null)
    {
        var (width, height) = PageSizeTwips(pages.Count > 0 ? pages[0] : null);
        int margin = MarginTwips(width, height);
        bool anyPicture = PlacedPictures(pages, pictures).Count > 0;

        var sb = new StringBuilder();
        sb.Append("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n");
        sb.Append("<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"");
        if (anyPicture) sb.Append(PictureNamespaces);
        sb.Append("><w:body>");
        int pictureNumber = 0;
        for (int index = 0; index < pages.Count; index++)
        {
            var paragraphs = OcrText.Paragraphs(pages[index]);
            bool breakBefore = index > 0;
            if (PictureAt(pictures, index) is { } picture)
            {
                pictureNumber++;
                var (cx, cy) = PictureSizeEmu(pages[index], width, height);
                AppendPicture(sb, pictureNumber, index + 1, picture.Format, cx, cy, breakBefore);
                breakBefore = false;
            }
            else if (paragraphs.Count == 0)
            {
                AppendParagraph(sb, "", pageBreakBefore: breakBefore);
                continue;
            }
            for (int p = 0; p < paragraphs.Count; p++)
            {
                AppendParagraph(sb, paragraphs[p].Text, pageBreakBefore: breakBefore && p == 0);
            }
        }
        if (pages.Count == 0) AppendParagraph(sb, "", pageBreakBefore: false);

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

    /// <summary>
    /// "[Content_Types].xml" for a package holding <paramref name="pictures"/> (the pictures in
    /// document order): <see cref="ContentTypesXml"/> with a default content type for each
    /// picture format used, JPEG first, before the document's override.
    /// </summary>
    public static string PackageContentTypesXml(IReadOnlyList<DocxPicture> pictures)
    {
        bool jpeg = pictures.Any(p => p.Format == DocxPictureFormat.Jpeg);
        bool png = pictures.Any(p => p.Format == DocxPictureFormat.Png);
        if (!jpeg && !png) return ContentTypesXml;
        string defaults = (jpeg ? DefaultContentType(DocxPictureFormat.Jpeg) : "")
                          + (png ? DefaultContentType(DocxPictureFormat.Png) : "");
        int at = ContentTypesXml.IndexOf("<Override ", StringComparison.Ordinal);
        return ContentTypesXml[..at] + defaults + ContentTypesXml[at..];
    }

    /// <summary>
    /// "word/_rels/document.xml.rels": one image relationship per picture, "rId1" to
    /// "media/image1.jpeg" and on, in document order.
    /// </summary>
    public static string DocumentRelationshipsXml(IReadOnlyList<DocxPicture> pictures)
    {
        var sb = new StringBuilder();
        sb.Append("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n");
        sb.Append("<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">");
        for (int i = 0; i < pictures.Count; i++)
        {
            sb.Append("<Relationship Id=\"rId").Append(I(i + 1))
              .Append("\" Type=\"").Append(ImageRelationshipType)
              .Append("\" Target=\"media/").Append(MediaName(i + 1, pictures[i].Format)).Append("\"/>");
        }
        sb.Append("</Relationships>");
        return sb.ToString();
    }

    /// <summary>The file name of the <paramref name="number"/>th picture (from 1) in "word/media": "image1.jpeg".</summary>
    public static string MediaName(int number, DocxPictureFormat format) => "image" + I(number) + "." + PictureExtension(format);

    /// <summary>"jpeg" or "png".</summary>
    public static string PictureExtension(DocxPictureFormat format) => format == DocxPictureFormat.Png ? "png" : "jpeg";

    /// <summary>"image/jpeg" or "image/png".</summary>
    public static string PictureContentType(DocxPictureFormat format) => format == DocxPictureFormat.Png ? "image/png" : "image/jpeg";

    /// <summary>
    /// How a page planned for a PDF (<see cref="PdfImageEncoding.Plan(ColorMode, int, PdfSizePreset, bool)"/>)
    /// is stored as a picture: a black &amp; white page (G4 in a PDF) as PNG, the others as the
    /// planned JPEG.
    /// </summary>
    public static DocxPictureFormat PictureFormat(PdfImagePlan plan) => plan.IsBilevel ? DocxPictureFormat.Png : DocxPictureFormat.Jpeg;

    /// <summary>
    /// The picture's size on the paper in EMU: the page's real size (points × 12,700), shrunk
    /// with its shape kept until it fits inside the margins of a paper of
    /// <paramref name="paperWidthTwips"/> × <paramref name="paperHeightTwips"/>, never enlarged.
    /// Whole EMU, rounded down where shrunk; a page without a size fills the space inside the margins.
    /// </summary>
    public static (long Width, long Height) PictureSizeEmu(OcrPage page, int paperWidthTwips, int paperHeightTwips)
    {
        int margin = MarginTwips(paperWidthTwips, paperHeightTwips);
        long boxWidth = Math.Max(1L, paperWidthTwips - 2L * margin) * EmuPerTwip;
        long boxHeight = Math.Max(1L, paperHeightTwips - 2L * margin) * EmuPerTwip;
        if (!(page.WidthPoints > 0) || !(page.HeightPoints > 0)) return (boxWidth, boxHeight);
        long width = Emu(page.WidthPoints), height = Emu(page.HeightPoints);
        if (width <= boxWidth && height <= boxHeight) return (width, height);
        if (width * boxHeight >= height * boxWidth) return (boxWidth, Math.Max(1L, height * boxWidth / width));
        return (Math.Max(1L, width * boxHeight / height), boxHeight);
    }

    /// <summary>The namespaces a document with pictures declares on its root, after w.</summary>
    private const string PictureNamespaces =
        " xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\""
        + " xmlns:wp=\"http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing\""
        + " xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\""
        + " xmlns:pic=\"http://schemas.openxmlformats.org/drawingml/2006/picture\"";

    /// <summary>
    /// The largest page side taken as it is, in EMU (over 100,000 inches), so that the products
    /// in <see cref="PictureSizeEmu"/> stay within 64 bits.
    /// </summary>
    private const double MaxEmu = 1e11;

    private static long Emu(double points) =>
        (long)Math.Clamp(Math.Round(points * EmuPerPoint, MidpointRounding.AwayFromZero), 1, MaxEmu);

    private static string DefaultContentType(DocxPictureFormat format) =>
        "<Default Extension=\"" + PictureExtension(format) + "\" ContentType=\"" + PictureContentType(format) + "\"/>";

    private static DocxPicture? PictureAt(IReadOnlyList<DocxPicture?>? pictures, int index) =>
        pictures is not null && index < pictures.Count ? pictures[index] : null;

    /// <summary>The pictures that go into the document: one per page that has one, in page order.</summary>
    private static List<DocxPicture> PlacedPictures(IReadOnlyList<OcrPage> pages, IReadOnlyList<DocxPicture?>? pictures)
    {
        var placed = new List<DocxPicture>();
        for (int index = 0; index < pages.Count; index++)
        {
            if (PictureAt(pictures, index) is { } picture) placed.Add(picture);
        }
        return placed;
    }

    /// <summary>
    /// The paragraph holding a page's picture: centred, no space around it, the picture inline
    /// (it moves with the text) with its shape locked, named after the page for screen readers.
    /// </summary>
    private static void AppendPicture(StringBuilder sb, int number, int pageNumber, DocxPictureFormat format,
                                      long cx, long cy, bool pageBreakBefore)
    {
        string n = I(number), page = I(pageNumber);
        string extent = "cx=\"" + L(cx) + "\" cy=\"" + L(cy) + "\"";
        sb.Append("<w:p><w:pPr>");
        if (pageBreakBefore) sb.Append("<w:pageBreakBefore/>");
        sb.Append("<w:spacing w:before=\"0\" w:after=\"0\"/><w:jc w:val=\"center\"/></w:pPr>");
        sb.Append("<w:r><w:drawing><wp:inline distT=\"0\" distB=\"0\" distL=\"0\" distR=\"0\">");
        sb.Append("<wp:extent ").Append(extent).Append("/><wp:effectExtent l=\"0\" t=\"0\" r=\"0\" b=\"0\"/>");
        sb.Append("<wp:docPr id=\"").Append(n).Append("\" name=\"Page ").Append(page)
          .Append("\" descr=\"Page ").Append(page).Append(" as scanned\"/>");
        sb.Append("<wp:cNvGraphicFramePr><a:graphicFrameLocks noChangeAspect=\"1\"/></wp:cNvGraphicFramePr>");
        sb.Append("<a:graphic><a:graphicData uri=\"http://schemas.openxmlformats.org/drawingml/2006/picture\"><pic:pic>");
        sb.Append("<pic:nvPicPr><pic:cNvPr id=\"").Append(n).Append("\" name=\"").Append(MediaName(number, format))
          .Append("\"/><pic:cNvPicPr><a:picLocks noChangeAspect=\"1\"/></pic:cNvPicPr></pic:nvPicPr>");
        sb.Append("<pic:blipFill><a:blip r:embed=\"rId").Append(n).Append("\"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>");
        sb.Append("<pic:spPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext ").Append(extent)
          .Append("/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></pic:spPr>");
        sb.Append("</pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>");
    }

    private static string L(long value) => value.ToString(CultureInfo.InvariantCulture);

    private static int Twips(double points) =>
        (int)Math.Clamp(Math.Round(points * 20, MidpointRounding.AwayFromZero), MinPageTwips, MaxPageTwips);

    private static string I(int value) => value.ToString(CultureInfo.InvariantCulture);
}
