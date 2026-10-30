using System.Text;

namespace LazyScan.Core;

// Twin of Sources/LazyScanKit/Output/TextExport.swift: the same bytes and the same messages.

/// <summary>
/// The text file of a save (<see cref="OutputFormat.Text"/>, or the text beside a PDF with
/// <see cref="OutputOptions.AlsoSaveText"/>), and what the app says about text it saved or could
/// not read. The text is <see cref="OcrText.PlainText"/>: UTF-8 without a byte order mark, "\n"
/// line breaks, one line of text per line on the page, a blank line between paragraphs and two
/// between pages.
/// </summary>
public static class TextExport
{
    private static readonly UTF8Encoding Utf8NoBom = new(encoderShouldEmitUTF8Identifier: false);

    /// <summary>The bytes of the text file for <paramref name="pages"/>.</summary>
    public static byte[] Encode(IReadOnlyList<OcrPage> pages) => Utf8NoBom.GetBytes(OcrText.PlainText(pages));

    /// <summary>Whether any page has text to save.</summary>
    public static bool HasText(IReadOnlyList<OcrPage> pages) => OcrText.PlainText(pages).Length > 0;

    /// <summary>
    /// "Saved 3-page Word document: Scan 1.docx", "Saved 1-page text file: Scan 1.txt", with
    /// " — no text was found" when the pages had none (the file is saved all the same).
    /// </summary>
    public static string SavedMessage(OutputFormat format, int pageCount, string fileName, bool hasText)
    {
        string kind = format == OutputFormat.Word ? "Word document" : "text file";
        return $"Saved {pageCount}-page {kind}: {fileName}" + (hasText ? "" : " — no text was found");
    }

    /// <summary>" and its text, Scan 1.txt": added after a PDF's name when its text was saved beside it.</summary>
    public static string SidecarSuffix(string textFileName) => $" and its text, {textFileName}";

    /// <summary>
    /// What the user reads when the text could not be read: "The text could not be read: no OCR
    /// language pack is installed (…)." from the OCR error's message ("Scan failed: OCR failed: …").
    /// </summary>
    public static string RecognitionFailed(string ocrMessage) => $"The text could not be read: {Reason(ocrMessage)}";

    /// <summary>
    /// "The PDF was saved, but not its text file: …": the text beside a PDF could not be read or
    /// written (<paramref name="message"/>, an OCR or file error); the PDF is kept.
    /// </summary>
    public static string SidecarFailed(string message) => $"The PDF was saved, but not its text file: {Reason(message)}";

    /// <summary>
    /// What the user reads when a scan to be saved at once as Word or text could not be (its text
    /// could not be read, its file could not be written, or the save was cancelled) and its pages
    /// went to the queue instead: "The 3 pages are kept in the queue: press Save Word once the text
    /// can be read, or choose PDF to save them as scanned." when <paramref name="textUnreadable"/>
    /// (OCR failed), "… press Save Word to try again, or choose PDF …" for any other failure, or
    /// "Cancelled — the page is kept in the queue.".
    /// </summary>
    public static string KeptInQueue(OutputFormat format, int pageCount, bool cancelled, bool textUnreadable = true)
    {
        string pages = pageCount == 1 ? "the page is" : $"the {pageCount} pages are";
        if (cancelled) return $"Cancelled — {pages} kept in the queue.";
        string them = pageCount == 1 ? "it" : "them";
        string advice = textUnreadable ? "once the text can be read" : "to try again";
        return $"{char.ToUpperInvariant(pages[0])}{pages[1..]} kept in the queue: press {OutputFormats.SaveTitle(format)} {advice}, or choose PDF to save {them} as scanned.";
    }

    /// <summary>An error's message without the "Scan failed: " and "OCR failed: " it starts with, ending in a full stop.</summary>
    private static string Reason(string message)
    {
        string reason = message.Trim();
        foreach (string prefix in new[] { "Scan failed: ", "OCR failed: " })
        {
            if (reason.StartsWith(prefix, StringComparison.Ordinal)) reason = reason[prefix.Length..];
        }
        if (reason.Length == 0) reason = "the text recognition did not work";
        if (!reason.EndsWith('.')) reason += ".";
        return reason;
    }

    /// <summary>
    /// "Copied the text of page 2." or "No text was found on page 2." after Copy Text;
    /// <paramref name="pageNumber"/> counts from 1.
    /// </summary>
    public static string CopiedMessage(int pageNumber, bool hasText) =>
        hasText ? $"Copied the text of page {pageNumber}." : $"No text was found on page {pageNumber}.";

    /// <summary>
    /// Write <paramref name="content"/> to a hidden temporary file next to <paramref name="path"/>
    /// and move it into place without ever replacing a file: when the name is taken, the next free
    /// " 2", " 3", … name is used (<see cref="NamingTemplate.MoveToFreePath"/>), as for PDFs.
    /// Returns the path written.
    /// </summary>
    public static string WriteNewFile(byte[] content, string path)
    {
        string directory = Path.GetDirectoryName(Path.GetFullPath(path))!;
        string extension = Path.GetExtension(path).TrimStart('.');
        string tmp = Path.Combine(directory, $".{Guid.NewGuid()}.{extension}.tmp");
        try
        {
            using (var stream = File.Create(tmp))
            {
                PdfBuilder.SetHidden(tmp, true);
                stream.Write(content);
            }
            PdfBuilder.SetHidden(tmp, false);
            string written = NamingTemplate.MoveToFreePath(tmp, path);
            PdfBuilder.SetHidden(written, false);
            return written;
        }
        catch
        {
            try { File.Delete(tmp); } catch { /* best effort */ }
            throw;
        }
    }
}
