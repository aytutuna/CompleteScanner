using System.IO;
using LazyScan.App.Services;
using LazyScan.App.Services.Companion;
using LazyScan.Core;
using Xunit;

namespace LazyScan.App.Tests;

// A .csdoc opened by hand, and the queue written as one (AppViewModel.Package.cs), decoded and
// encoded with WIC. The view model itself reads the user's settings, so, as for CompanionAppTests,
// its pieces are tested here: what is offered, the pages Open as new takes, and the written
// document. Twin of Tests/LazyScanTests/AppStatePackageTests.swift, which also adds and
// opens through AppState. A package the Swift writer makes is read here through the golden package
// (CompanionPackageTests: the Swift suite writes the same bytes).

public sealed class PackageAppTests : IDisposable
{
    private readonly string _folder = Path.Combine(Path.GetTempPath(), "PackageAppTests-" + Guid.NewGuid().ToString("N"));

    public PackageAppTests() => Directory.CreateDirectory(_folder);

    public void Dispose()
    {
        try { Directory.Delete(_folder, true); } catch (IOException) { }
    }

    private static RgbaImage Picture(int width, int height, byte red)
    {
        var pixels = new byte[width * height * 4];
        for (int i = 0; i < pixels.Length; i += 4)
        {
            pixels[i] = red;
            pixels[i + 1] = 40;
            pixels[i + 2] = 80;
            pixels[i + 3] = 255;
        }
        return new RgbaImage(width, height, pixels);
    }

    private static CompanionImage Jpeg(int width, int height, int dpi = 200) =>
        new(WpfImageCodec.EncodeJpeg(Picture(width, height, 200), dpi), CompanionImageFormat.Jpeg, width, height, dpi, ColorMode.Color);

    private static CompanionDocument Document() => new(
        "Receipt",
        [
            new CompanionPage(Jpeg(40, 60)) { RotationQuarterTurns = 1, Side = PageSide.Front, SheetIndex = 0 },
            new CompanionPage(Jpeg(40, 60)) { Side = PageSide.Back, SheetIndex = 0, Original = Jpeg(80, 100) },
        ])
    {
        SuggestedName = "Lunch 2026-10-20",
    };

    private string Write(string name, byte[] package)
    {
        string path = Path.Combine(_folder, name);
        File.WriteAllBytes(path, package);
        return path;
    }

    [Fact]
    public void OpenedPackage_IsOfferedWithItsPagesAndName()
    {
        var offered = PendingPackage.Read(Write("Receipt.csdoc", CompanionPackage.Make(Document())), PendingPackage.Decode);
        Assert.Equal("Receipt.csdoc", offered.FileName);
        Assert.Equal(2, offered.PageCount);
        Assert.Equal("Lunch 2026-10-20", offered.DocumentName);
        Assert.Equal("Opened Receipt.csdoc: 2 pages", PackageText.OpenedMessage(offered.FileName, offered.PageCount));
        Assert.Equal("Opened Receipt.csdoc: 1 page", PackageText.OpenedMessage(offered.FileName, 1));
        Assert.All(offered.Pages, page => Assert.Equal(PageSource.Phone, page.Source));
        Assert.Equal((60, 40), (offered.Pages[0].Image.Width, offered.Pages[0].Image.Height));
        Assert.True(offered.Pages[1].CanSwapVersions);
        // Add to pages joins the current document: no break, no name.
        Assert.All(offered.Pages, page => Assert.Equal(DocumentBreak.Automatic, page.DocumentBreak));
        Assert.All(offered.Pages, page => Assert.Null(page.DocumentLabel));
        // Open as new starts the queue under the document's name.
        var asNew = offered.AsNewDocument();
        Assert.Equal(2, asNew.Count);
        Assert.Equal("Lunch 2026-10-20", asNew[0].DocumentLabel);
        Assert.Equal(DocumentBreak.Automatic, asNew[0].DocumentBreak);
        Assert.Null(asNew[1].DocumentLabel);
        Assert.Equal(offered.Pages[0].Id, asNew[0].Id);
    }

    [Fact]
    public void PackageFiles_AreKnownByTheirExtension()
    {
        Assert.True(PendingPackage.IsPackageFile(@"C:\Scans\Receipt.csdoc"));
        Assert.True(PendingPackage.IsPackageFile("RECEIPT.CSDOC"));
        Assert.False(PendingPackage.IsPackageFile("Receipt.csdoc.pdf"));
        Assert.False(PendingPackage.IsPackageFile("csdoc"));
        Assert.False(PendingPackage.IsPackageFile("Receipt.jpg"));
    }

    [Fact]
    public void NewerPackage_IsRefusedWithTheMessage()
    {
        var entries = CompanionPackage.Entries(Document()).ToList();
        string manifest = System.Text.Encoding.UTF8.GetString(entries[0].Data).Replace("\"formatVersion\":1", "\"formatVersion\":2");
        entries[0] = entries[0] with { Data = System.Text.Encoding.UTF8.GetBytes(manifest) };
        string path = Write("Newer.csdoc", ZipStore.Make(entries));
        var e = Assert.Throws<CompanionPackageException>(() => PendingPackage.Read(path, PendingPackage.Decode));
        Assert.Equal(CompanionPackageErrorKind.NewerVersion, e.Kind);
        Assert.Equal("This document was made by a newer version of Lazy Scan (package format 2). Update Lazy Scan to open it.",
                     e.Message);
    }

    [Fact]
    public void PackageWithAPictureThatCannotBeDecoded_IsRefused()
    {
        byte[] broken = [0xFF, 0xD8, 0xFF, 0xE0, 0, 0, 0, 0];
        var document = new CompanionDocument("Scan", [new CompanionPage(new CompanionImage(broken, CompanionImageFormat.Jpeg, 8, 8, 300, ColorMode.Color))]);
        string path = Write("Broken.csdoc", CompanionPackage.Make(document));
        var e = Assert.Throws<CompanionPackageException>(() => PendingPackage.Read(path, PendingPackage.Decode));
        Assert.Equal("Broken.csdoc cannot be opened: one of its pictures cannot be read.", e.Message);
    }

    [Fact]
    public void PackageWithAPictureThatClaimsTooManyPixels_IsRefused()
    {
        // A real JPEG whose start-of-frame is changed to claim 20000 × 10000 pixels.
        byte[] bytes = Jpeg(40, 30).Data;
        int sof = Enumerable.Range(2, bytes.Length - 11).First(i => bytes[i] == 0xFF && bytes[i + 1] == 0xC0);
        bytes[sof + 5] = 0x27;
        bytes[sof + 6] = 0x10;
        bytes[sof + 7] = 0x4E;
        bytes[sof + 8] = 0x20;
        var document = new CompanionDocument("Scan", [new CompanionPage(new CompanionImage(bytes, CompanionImageFormat.Jpeg, 40, 30, 200, ColorMode.Color))]);
        string path = Write("Huge.csdoc", CompanionPackage.Make(document));
        var e = Assert.Throws<CompanionPackageException>(() => PendingPackage.Read(path, PendingPackage.Decode));
        Assert.Equal("Huge.csdoc cannot be opened: one of its pictures cannot be read.", e.Message);
    }

    [Fact]
    public void Queue_IsWrittenAsADocumentThatReadsBack()
    {
        var capture = new CaptureFacts(new Quad(new PointD(10, 12), new PointD(70, 14), new PointD(68, 95), new PointD(8, 92)), 80, 100);
        List<ScannedPage> pages =
        [
            new ScannedPage(Picture(40, 60, 200), 200, ColorMode.Color) { Side = PageSide.Front, SheetIndex = 0, Capture = capture },
            new ScannedPage(Picture(40, 60, 128), 150, ColorMode.Grayscale) { Side = PageSide.Back, SheetIndex = 0 },
            new ScannedPage(Picture(64, 32, 0), 300, ColorMode.BlackWhite),
        ];
        var document = CompanionPages.ToDocument(pages, "Scan 7", 0.9, page => page.Image);
        Assert.Equal("Scan 7", document.Title);
        Assert.Equal("Scan 7", document.SuggestedName);
        var read = CompanionPackage.Read(CompanionPackage.Make(document));
        Assert.Equal(3, read.Pages.Count);
        Assert.Equal(CompanionImageFormat.Jpeg, read.Pages[0].Image.Format);
        Assert.Equal(CompanionImageFormat.Jpeg, read.Pages[1].Image.Format);
        Assert.Equal(CompanionImageFormat.Tiff, read.Pages[2].Image.Format);
        Assert.Equal([ColorMode.Color, ColorMode.Grayscale, ColorMode.BlackWhite], read.Pages.Select(p => p.Image.ColorMode));
        Assert.Equal([200, 150, 300], read.Pages.Select(p => p.Image.Dpi));
        Assert.Equal((PageSide?)PageSide.Back, read.Pages[1].Side);
        Assert.Equal(capture, read.Pages[0].Capture);
        // Opened again, the pages are the queue's.
        var offered = PendingPackage.Read(Write("Scan 7.csdoc", CompanionPackage.Make(document)), PendingPackage.Decode);
        Assert.Equal("Scan 7", offered.DocumentName);
        Assert.Equal([(40, 60), (40, 60), (64, 32)], offered.Pages.Select(p => (p.Image.Width, p.Image.Height)));
        Assert.Equal(capture, offered.Pages[0].Capture);
    }
}
