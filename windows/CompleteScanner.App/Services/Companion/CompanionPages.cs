using CompleteScanner.App.Services;
using CompleteScanner.Core;

namespace CompleteScanner.App.Services.Companion;

/// <summary>
/// A document from a phone as pages of the queue: each picture decoded, turned by the rotation the
/// phone had still to apply, labelled "From phone" (<see cref="PageSource.Phone"/>), with its side
/// and sheet; a page that came with its picture as photographed keeps that as its other version, so
/// "Show as photographed" works as for an imported photo; what the phone's camera recorded about a page
/// (<see cref="ScannedPage.Capture"/>) comes with it. A document sent as a new one starts a
/// document of its own in the queue (a split before its first page, when pages are already queued)
/// and carries its name.
/// </summary>
public static class CompanionPages
{
    /// <param name="decode">Decodes a picture's bytes (JPEG, PNG or bilevel TIFF).</param>
    /// <param name="queueHasPages">Pages are queued already.</param>
    public static List<ScannedPage> ToScannedPages(CompanionDocument document, CompanionTarget target, bool queueHasPages,
                                                   Func<byte[], RgbaImage> decode, DateTime? createdAt = null)
    {
        var pages = new List<ScannedPage>(document.Pages.Count);
        DateTime created = createdAt ?? DateTime.Now;
        foreach (var source in document.Pages)
        {
            var image = Upright(decode(source.Image.Data), source.RotationQuarterTurns);
            var page = new ScannedPage(image, source.Image.Dpi, source.Image.ColorMode, createdAt: created)
            {
                Side = source.Side,
                SheetIndex = source.SheetIndex,
                Source = PageSource.Phone,
                Capture = source.Capture,
            };
            if (source.Original is { } original)
            {
                var photographed = new ScannedPage(Upright(decode(original.Data), source.RotationQuarterTurns),
                                                   source.Image.Dpi, source.Image.ColorMode, page.Id, created)
                {
                    Side = source.Side,
                    SheetIndex = source.SheetIndex,
                    Source = PageSource.Phone,
                    Capture = source.Capture,
                };
                page = photographed.WithGeometry(image, new PageGeometry(true, 0, GeometryBasis.Perspective));
            }
            pages.Add(page);
        }
        if (pages.Count > 0 && target == CompanionTarget.New)
        {
            string name = DocumentName(document);
            var first = pages[0];
            if (queueHasPages) first = first.WithDocumentBreak(DocumentBreak.Split);
            if (name.Length > 0) first = first.WithDocumentLabel(name);
            pages[0] = first;
        }
        return pages;
    }

    /// <summary>The name a document carries: the sender's file name for it, else its title; "" for none.</summary>
    public static string DocumentName(CompanionDocument document) => (document.SuggestedName ?? document.Title).Trim();

    /// <summary>
    /// The queue's pages as one document named <paramref name="name"/>, for a package: each page's
    /// picture as shown, at full resolution (<paramref name="load"/>, turned as the page is), a black
    /// &amp; white page as a bilevel TIFF and the others as a JPEG at <paramref name="jpegQuality"/>
    /// (a gray one as a gray JPEG), with its side, sheet and what the camera recorded. Document breaks
    /// and recognized text are not carried.
    /// </summary>
    public static CompanionDocument ToDocument(IReadOnlyList<ScannedPage> pages, string name, double jpegQuality,
                                               Func<ScannedPage, RgbaImage> load)
    {
        var packaged = new List<CompanionPage>(pages.Count);
        foreach (var page in pages)
        {
            var image = load(page);
            var picture = page.ColorMode == ColorMode.BlackWhite
                ? new CompanionImage(BilevelTiff.Make(image, page.Dpi), CompanionImageFormat.Tiff, image.Width, image.Height,
                                     page.Dpi, page.ColorMode)
                : new CompanionImage(WpfImageCodec.EncodeJpeg(image, page.Dpi, jpegQuality, page.ColorMode == ColorMode.Grayscale),
                                     CompanionImageFormat.Jpeg, image.Width, image.Height, page.Dpi, page.ColorMode);
            packaged.Add(new CompanionPage(picture) { Side = page.Side, SheetIndex = page.SheetIndex, Capture = page.Capture });
        }
        return new CompanionDocument(name, packaged) { SuggestedName = name };
    }

    private static RgbaImage Upright(RgbaImage image, int quarterTurns) =>
        quarterTurns is > 0 and <= 3 ? image.RotatedQuarterTurns(quarterTurns) : image;
}
