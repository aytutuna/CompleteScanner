using System.Text;
using LazyScan.Core;
using Xunit;

namespace LazyScan.Core.Tests;

// Mirrored by Tests/LazyScanTests/TextExportTests.swift: the same cases, except
// WriteNewFile (the Mac writes files with Data.write(.atomic)).

public class TextExportTests
{
    private static OcrLine L(string text, double left, double top, double width, double height = 20) =>
        OcrFixtures.Line(text, left, top, width, height);

    /// <summary>Two pages with accents, Chinese, Hebrew, a row of two pieces and a broken word.</summary>
    internal static IReadOnlyList<OcrPage> SamplePages() =>
    [
        OcrFixtures.Page(
            L("Café menu", 400, 50, 200, 30),
            L("Soupe à l'oignon", 50, 120, 300), L("4,50 €", 800, 121, 100),
            L("東京 ラーメン", 50, 150, 300), L("9.00", 800, 150, 100),
            L("This line is forward-", 50, 220, 800), L("ing the rest.", 50, 246, 300)),
        OcrFixtures.Page(L("שלום עולם", 600, 100, 300), L("Fish & Chips <b>", 50, 160, 400)),
    ];

    [Fact]
    public void Encode_ExactBytes_Utf8WithoutBom_LineFeeds()
    {
        const string expected =
            "Café menu\n\nSoupe à l'oignon\t4,50 €\n東京 ラーメン\t9.00\n\nThis line is forward-\ning the rest.\n\n\n" +
            "שלום עולם\n\nFish & Chips <b>\n";
        byte[] bytes = TextExport.Encode(SamplePages());
        Assert.Equal(Encoding.UTF8.GetBytes(expected), bytes);
        Assert.NotEqual(0xEF, bytes[0]);
        Assert.DoesNotContain((byte)'\r', bytes);
        Assert.Equal(expected, Encoding.UTF8.GetString(bytes));
        Assert.True(TextExport.HasText(SamplePages()));
        Assert.Empty(TextExport.Encode([OcrFixtures.Page()]));
        Assert.False(TextExport.HasText([OcrFixtures.Page()]));
    }

    [Fact]
    public void Encode_Fingerprint_MatchesTheMac()
    {
        // The same number in TextExportTests.swift: both platforms write the same bytes.
        byte[] bytes = TextExport.Encode(SamplePages());
        Assert.Equal((139, 0x7EF26B65u), (bytes.Length, ZipStore.Crc32(bytes)));
    }

    [Fact]
    public void Messages()
    {
        Assert.Equal("Saved 3-page Word document: Scan 1.docx", TextExport.SavedMessage(OutputFormat.Word, 3, "Scan 1.docx", true));
        Assert.Equal("Saved 1-page text file: Scan 1.txt — no text was found",
                     TextExport.SavedMessage(OutputFormat.Text, 1, "Scan 1.txt", false));
        Assert.Equal(" and its text, Scan 1.txt", TextExport.SidecarSuffix("Scan 1.txt"));
        Assert.Equal("Copied the text of page 2.", TextExport.CopiedMessage(2, true));
        Assert.Equal("No text was found on page 1.", TextExport.CopiedMessage(1, false));
        Assert.Equal("The text could not be read: no OCR language pack is installed (Settings → Time & Language → Language).",
                     TextExport.RecognitionFailed(
                         "Scan failed: OCR failed: no OCR language pack is installed (Settings → Time & Language → Language)."));
        Assert.Equal("The text could not be read: the request failed.", TextExport.RecognitionFailed("OCR failed: the request failed"));
        Assert.Equal("The text could not be read: the text recognition did not work.", TextExport.RecognitionFailed("  "));
        Assert.Equal("The PDF was saved, but not its text file: no OCR language pack is installed.",
                     TextExport.SidecarFailed("Scan failed: OCR failed: no OCR language pack is installed."));
        Assert.Equal("The PDF was saved, but not its text file: Access to the path is denied.",
                     TextExport.SidecarFailed("Access to the path is denied."));
        Assert.Equal("The 3 pages are kept in the queue: press Save Word once the text can be read, or choose PDF to save them as scanned.",
                     TextExport.KeptInQueue(OutputFormat.Word, 3, cancelled: false));
        Assert.Equal("The page is kept in the queue: press Save Text once the text can be read, or choose PDF to save it as scanned.",
                     TextExport.KeptInQueue(OutputFormat.Text, 1, cancelled: false));
        // The text was read but the file could not be written: no advice about reading the text.
        Assert.Equal("The 3 pages are kept in the queue: press Save Word to try again, or choose PDF to save them as scanned.",
                     TextExport.KeptInQueue(OutputFormat.Word, 3, cancelled: false, textUnreadable: false));
        Assert.Equal("The page is kept in the queue: press Save Text to try again, or choose PDF to save it as scanned.",
                     TextExport.KeptInQueue(OutputFormat.Text, 1, cancelled: false, textUnreadable: false));
        Assert.Equal("Cancelled — the 2 pages are kept in the queue.", TextExport.KeptInQueue(OutputFormat.Word, 2, cancelled: true));
        Assert.Equal("Cancelled — the page is kept in the queue.", TextExport.KeptInQueue(OutputFormat.Text, 1, cancelled: true));
        Assert.Equal("Cancelled — the page is kept in the queue.",
                     TextExport.KeptInQueue(OutputFormat.Text, 1, cancelled: true, textUnreadable: false));
    }

    [Fact]
    public void WriteNewFile_NeverReplacesAFile_AndLeavesNoTemporaryFile()
    {
        string directory = Path.Combine(Path.GetTempPath(), "ls-text-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        try
        {
            string path = Path.Combine(directory, "Scan 1.txt");
            File.WriteAllText(path, "keep me");
            string written = TextExport.WriteNewFile(Encoding.UTF8.GetBytes("new"), path);
            Assert.Equal(Path.Combine(directory, "Scan 1 2.txt"), written);
            Assert.Equal("keep me", File.ReadAllText(path));
            Assert.Equal("new", File.ReadAllText(written));
            Assert.Equal(2, Directory.GetFiles(directory).Length);
            Assert.Equal(0, (int)(File.GetAttributes(written) & FileAttributes.Hidden));
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }
}

public class OutputFormatsTests
{
    [Fact]
    public void ImageAndTextFormats()
    {
        Assert.Equal([OutputFormat.Jpeg, OutputFormat.Png, OutputFormat.Tiff],
                     Enum.GetValues<OutputFormat>().Where(f => f.IsImageFormat()));
        Assert.Equal([OutputFormat.Text, OutputFormat.Word], Enum.GetValues<OutputFormat>().Where(f => f.IsTextFormat()));
        Assert.Equal(["PDF", "JPEG", "PNG", "TIFF", "Text (.txt)", "Word (.docx)"],
                     Enum.GetValues<OutputFormat>().Select(f => f.Label()));
        Assert.Equal(["pdf", "jpg", "png", "tiff", "txt", "docx"], Enum.GetValues<OutputFormat>().Select(f => f.FileExtension()));
    }

    [Fact]
    public void Offered_DocumentsGetEveryFormat_PhotosTheImageFormats()
    {
        Assert.Equal([OutputFormat.Pdf, OutputFormat.Word, OutputFormat.Text, OutputFormat.Jpeg, OutputFormat.Png, OutputFormat.Tiff],
                     OutputFormats.Offered(ScanIntent.Document));
        Assert.Equal([OutputFormat.Jpeg, OutputFormat.Png, OutputFormat.Tiff], OutputFormats.Offered(ScanIntent.Photo));
    }

    [Fact]
    public void WhatEachSaveWrites()
    {
        Assert.Equal([OutputFormat.Jpeg, OutputFormat.Jpeg, OutputFormat.Png, OutputFormat.Tiff, OutputFormat.Jpeg, OutputFormat.Jpeg],
                     Enum.GetValues<OutputFormat>().Select(OutputFormats.ImageFormatOrJpeg));
        Assert.Equal([OutputFormat.Pdf, OutputFormat.Pdf, OutputFormat.Pdf, OutputFormat.Pdf, OutputFormat.Text, OutputFormat.Word],
                     Enum.GetValues<OutputFormat>().Select(OutputFormats.QueueFormat));
        Assert.Equal([OutputFormat.Pdf, OutputFormat.Jpeg, OutputFormat.Png, OutputFormat.Tiff, OutputFormat.Pdf, OutputFormat.Pdf],
                     Enum.GetValues<OutputFormat>().Select(OutputFormats.PageFormat));
    }

    [Fact]
    public void SavesPdf_CollectedPagesInAnyFormatButText_AScanAtOnceInPdfOnly()
    {
        Assert.Equal([true, true, true, true, false, false],
                     Enum.GetValues<OutputFormat>().Select(f => OutputFormats.SavesPdf(f, collectsPages: true)));
        Assert.Equal([true, false, false, false, false, false],
                     Enum.GetValues<OutputFormat>().Select(f => OutputFormats.SavesPdf(f, collectsPages: false)));
    }

    [Fact]
    public void SaveTitles()
    {
        Assert.Equal(["Save PDF", "Save PDF", "Save PDF", "Save PDF", "Save Text", "Save Word"],
                     Enum.GetValues<OutputFormat>().Select(f => OutputFormats.SaveTitle(f)));
        Assert.Equal("Save Word (3 pages)", OutputFormats.SaveTitle(OutputFormat.Word, 3));
        Assert.Equal("Save PDF (1 page)", OutputFormats.SaveTitle(OutputFormat.Jpeg, 1));
        Assert.Equal("Save Text", OutputFormats.SaveTitle(OutputFormat.Text, 0));
    }
}
