using System.Security.Cryptography;
using System.Text;
using CompleteScanner.Core;
using Xunit;

namespace CompleteScanner.Core.Tests;

// Mirrored by Tests/CompleteScannerTests/CompanionPackageTests.swift: the same cases, the same
// golden package (CompanionFixtures, written here and pinned as hex, length and SHA-256), which
// the Swift writer must reproduce byte for byte and the Swift reader must decode.

public class CompanionPackageTests
{
    [Fact]
    public void Golden_ManifestText()
    {
        Assert.Equal(CompanionFixtures.GoldenManifest, CompanionPackage.ManifestJson(CompanionFixtures.Sample));
    }

    [Fact]
    public void Golden_PackageBytesArePinned()
    {
        byte[] package = CompanionPackage.Make(CompanionFixtures.Sample);
        Assert.Equal(CompanionFixtures.GoldenLength, package.Length);
        Assert.Equal(CompanionFixtures.GoldenSha256, Convert.ToHexStringLower(SHA256.HashData(package)));
        Assert.Equal(CompanionFixtures.GoldenHex, Convert.ToHexString(package));
        Assert.Equal(package, CompanionPackage.Make(CompanionFixtures.Sample));
    }

    [Fact]
    public void Golden_EntriesInPackageOrder()
    {
        using var reader = ZipStoreReader.Open(Convert.FromHexString(CompanionFixtures.GoldenHex));
        Assert.Equal(["manifest.json", "pages/0001.jpg", "pages/0001-original.png", "pages/0002.png"], reader.Entries.Select(e => e.Name));
    }

    // Windows only: another zip reader opens the package as it is.
    [Fact]
    public void Golden_OpensWithZipArchive()
    {
        using var archive = new System.IO.Compression.ZipArchive(new MemoryStream(Convert.FromHexString(CompanionFixtures.GoldenHex)));
        Assert.Equal(4, archive.Entries.Count);
        using var manifest = new StreamReader(archive.GetEntry("manifest.json")!.Open(), Encoding.UTF8);
        Assert.Equal(CompanionFixtures.GoldenManifest, manifest.ReadToEnd());
    }

    [Fact]
    public void Golden_Decodes()
    {
        var document = CompanionPackage.Read(Convert.FromHexString(CompanionFixtures.GoldenHex));
        Assert.Equal("Résumé \"draft\" \\ 1\t\u0001", document.Title);
        Assert.Equal(new CompanionWriterInfo("CompleteScanner", "1.0", "test"), document.Writer);
        Assert.Equal(new DateTimeOffset(2026, 10, 20, 8, 30, 0, TimeSpan.Zero), document.Created);
        Assert.Equal("receipts", document.TaskId);
        Assert.Equal("Scan 1", document.SuggestedName);
        Assert.Equal("{date} {title}", document.NamingTemplate);
        Assert.Equal(2, document.Pages.Count);

        var first = document.Pages[0];
        AssertImage(first.Image, DocxFixtures.Jpeg, CompanionImageFormat.Jpeg, 16, 12, 300, ColorMode.Grayscale);
        Assert.Equal(1, first.RotationQuarterTurns);
        Assert.Equal(PageSide.Front, first.Side);
        Assert.Equal(0, first.SheetIndex);
        Assert.Equal(
            new[]
            {
                new OcrLine("Hello", new RectD(0.1, 0.2, 0.5, 0.125), 0.98f),
                new OcrLine("naïve 日本", new RectD(0.000123, 0.75, 0.333333, 0.05), 0.5f),
            },
            first.OcrLines!);
        AssertImage(first.Original!, DocxFixtures.Png, CompanionImageFormat.Png, 16, 12, 300, ColorMode.BlackWhite);

        var second = document.Pages[1];
        AssertImage(second.Image, DocxFixtures.Png, CompanionImageFormat.Png, 16, 12, 200, ColorMode.BlackWhite);
        Assert.Equal(0, second.RotationQuarterTurns);
        Assert.Equal(PageSide.Back, second.Side);
        Assert.Equal(0, second.SheetIndex);
        Assert.NotNull(second.OcrLines);
        Assert.Empty(second.OcrLines!);
        Assert.Null(second.Original);
    }

    [Fact]
    public void Minimal_RoundTripsWithDefaults()
    {
        Assert.Equal(CompanionFixtures.MinimalManifest, CompanionPackage.ManifestJson(CompanionFixtures.Minimal));
        var document = CompanionPackage.Read(CompanionPackage.Make(CompanionFixtures.Minimal));
        Assert.Equal("Scan", document.Title);
        Assert.Equal(new CompanionWriterInfo("CompleteScanner", "", ""), document.Writer);
        Assert.Null(document.Created);
        Assert.Null(document.TaskId);
        Assert.Null(document.SuggestedName);
        Assert.Null(document.NamingTemplate);
        var page = Assert.Single(document.Pages);
        AssertImage(page.Image, DocxFixtures.Jpeg, CompanionImageFormat.Jpeg, 16, 12, 300, ColorMode.Color);
        Assert.Equal(0, page.RotationQuarterTurns);
        Assert.Null(page.Side);
        Assert.Null(page.SheetIndex);
        Assert.Null(page.OcrLines);
        Assert.Null(page.Original);
    }

    [Fact]
    public void Tiff_ForBlackAndWhitePages()
    {
        byte[] tiff = [0x49, 0x49, 0x2A, 0x00, 0x08, 0x00, 0x00, 0x00];
        var document = new CompanionDocument("T", [new CompanionPage(new CompanionImage(tiff, CompanionImageFormat.Tiff, 8, 8, 300, ColorMode.BlackWhite))]);
        byte[] package = CompanionPackage.Make(document);
        using (var reader = ZipStoreReader.Open(package)) Assert.Equal("pages/0001.tif", reader.Entries[1].Name);
        var read = CompanionPackage.Read(package);
        AssertImage(read.Pages[0].Image, tiff, CompanionImageFormat.Tiff, 8, 8, 300, ColorMode.BlackWhite);

        var gray = new CompanionDocument("T", [new CompanionPage(new CompanionImage(tiff, CompanionImageFormat.Tiff, 8, 8, 300, ColorMode.Grayscale))]);
        var error = AssertWriteRefused(CompanionPackageErrorKind.InvalidDocument, gray);
        Assert.Equal("Page 1's picture is a TIFF, which only black & white pages can be.", error.Message);
    }

    [Fact]
    public void Created_IsWrittenInUtcToTheSecond()
    {
        var created = new DateTimeOffset(2026, 10, 20, 10, 30, 0, 500, TimeSpan.FromHours(2));
        string manifest = CompanionPackage.ManifestJson(CompanionFixtures.Minimal with { Created = created });
        Assert.Contains("\"created\":\"2026-10-20T08:30:00Z\",", manifest);
    }

    [Fact]
    public void Write_Refusals()
    {
        var jpeg = new CompanionImage(DocxFixtures.Jpeg, CompanionImageFormat.Jpeg, 16, 12, 300, ColorMode.Color);
        Assert.Equal("This document has no pages.", AssertWriteRefused(CompanionPackageErrorKind.NoPages, new CompanionDocument("x", [])).Message);
        Assert.Equal("This document has more than 2000 pages.",
                     AssertWriteRefused(CompanionPackageErrorKind.TooManyPages,
                                        new CompanionDocument("x", Enumerable.Repeat(new CompanionPage(jpeg), 2001).ToList())).Message);
        Assert.Equal("Page 1's picture is not a PNG file.",
                     AssertWriteRefused(CompanionPackageErrorKind.InvalidDocument,
                                        new CompanionDocument("x", [new CompanionPage(jpeg with { Format = CompanionImageFormat.Png })])).Message);
        Assert.Equal("Page 2's original picture is not a JPEG file.",
                     AssertWriteRefused(CompanionPackageErrorKind.InvalidDocument,
                                        new CompanionDocument("x", [new CompanionPage(jpeg), new CompanionPage(jpeg) { Original = jpeg with { Data = [1, 2, 3] } }])).Message);
        Assert.Equal("Page 1's picture needs a size in pixels and a resolution.",
                     AssertWriteRefused(CompanionPackageErrorKind.InvalidDocument,
                                        new CompanionDocument("x", [new CompanionPage(jpeg with { Dpi = 0 })])).Message);
        AssertWriteRefused(CompanionPackageErrorKind.InvalidDocument, new CompanionDocument("x", [new CompanionPage(jpeg with { PixelWidth = 0 })]));
        Assert.Equal("Page 1's rotation must be 0 to 3 quarter turns.",
                     AssertWriteRefused(CompanionPackageErrorKind.InvalidDocument,
                                        new CompanionDocument("x", [new CompanionPage(jpeg) { RotationQuarterTurns = 4 }])).Message);
        Assert.Equal("Page 1's sheet cannot be negative.",
                     AssertWriteRefused(CompanionPackageErrorKind.InvalidDocument,
                                        new CompanionDocument("x", [new CompanionPage(jpeg) { SheetIndex = -1 }])).Message);
        Assert.Equal("The document is larger than 512 MB, too large for one package.", CompanionPackage.TooLargeMessage);
    }

    [Fact]
    public void Read_IsLenient()
    {
        string m = CompanionFixtures.MinimalManifest;
        // Unknown keys anywhere are ignored; a newer minor version reads.
        var document = ReadManifest(m.Replace("\"title\":", "\"future\":{\"x\":[1,2]},\"title\":")
                                     .Replace("\"rotationQuarterTurns\":0", "\"rotationQuarterTurns\":0,\"stamp\":\"x\"")
                                     .Replace("\"formatMinor\":0", "\"formatMinor\":9"));
        Assert.Equal("Scan", document.Title);
        // Unknown and wrong-typed values fall back.
        var page = ReadManifest(m.Replace("\"colorMode\":\"color\"", "\"colorMode\":\"sepia\"")
                                 .Replace("\"rotationQuarterTurns\":0", "\"rotationQuarterTurns\":7,\"side\":\"middle\",\"sheetIndex\":-1")
                                 .Replace("\"dpi\":300", "\"dpi\":\"x\"")
                                 .Replace("\"pixelWidth\":16,", "")).Pages[0];
        Assert.Equal(ColorMode.Color, page.Image.ColorMode);
        Assert.Equal(0, page.RotationQuarterTurns);
        Assert.Null(page.Side);
        Assert.Null(page.SheetIndex);
        Assert.Equal(CompanionPackage.DefaultDpi, page.Image.Dpi);
        Assert.Equal(0, page.Image.PixelWidth);
        Assert.Equal(12, page.Image.PixelHeight);

        page = ReadManifest(m.Replace("\"colorMode\":\"color\"", "\"colorMode\":\"grayscale\"")
                             .Replace("\"rotationQuarterTurns\":0", "\"rotationQuarterTurns\":\"2\",\"side\":\"back\",\"sheetIndex\":\"x\"")
                             .Replace("\"dpi\":300", "\"dpi\":0")).Pages[0];
        Assert.Equal(ColorMode.Grayscale, page.Image.ColorMode);
        Assert.Equal(0, page.RotationQuarterTurns);
        Assert.Equal(PageSide.Back, page.Side);
        Assert.Null(page.SheetIndex);
        Assert.Equal(CompanionPackage.DefaultDpi, page.Image.Dpi);

        page = ReadManifest(m.Replace("\"rotationQuarterTurns\":0", "\"rotationQuarterTurns\":3,\"sheetIndex\":4")).Pages[0];
        Assert.Equal(3, page.RotationQuarterTurns);
        Assert.Equal(4, page.SheetIndex);

        // Writer, created, title, OCR lines.
        document = ReadManifest(m.Replace("\"writer\":{\"app\":\"CompleteScanner\",\"appVersion\":\"\",\"platform\":\"\"}", "\"writer\":5,\"created\":\"yesterday\"")
                                 .Replace("\"title\":\"Scan\",", "")
                                 .Replace("\"rotationQuarterTurns\":0", "\"rotationQuarterTurns\":0,\"ocrLines\":[{\"text\":5,\"x\":\"a\",\"y\":0.5},{}]"));
        Assert.Equal(new CompanionWriterInfo("", "", ""), document.Writer);
        Assert.Null(document.Created);
        Assert.Equal("", document.Title);
        Assert.Equal(new[] { new OcrLine("", new RectD(0, 0.5, 0, 0), 0), new OcrLine("", new RectD(0, 0, 0, 0), 0) }, document.Pages[0].OcrLines!);

        Assert.Null(ReadManifest(m.Replace("\"rotationQuarterTurns\":0", "\"rotationQuarterTurns\":0,\"ocrLines\":\"none\"")).Pages[0].OcrLines);
        Assert.Equal(new DateTimeOffset(2026, 1, 2, 3, 4, 5, TimeSpan.Zero),
                     ReadManifest(m.Replace("\"title\":", "\"created\":\"2026-01-02T03:04:05Z\",\"title\":")).Created);

        // A picture without a format is taken for what its bytes are.
        Assert.Equal(CompanionImageFormat.Jpeg, ReadManifest(m.Replace("\"format\":\"jpeg\",", "")).Pages[0].Image.Format);
        // A byte BOM before the JSON is skipped.
        Assert.Equal("Scan", CompanionPackage.Read(Package("\uFEFF" + m)).Title);
        // UTF-16 with its byte-order mark reads, as JSONDecoder reads it.
        Assert.Equal("Scan", CompanionPackage.Read(Package([0xFF, 0xFE, .. Encoding.Unicode.GetBytes(m)])).Title);

        // Whole numbers written with a fraction or an exponent read as JSONDecoder reads them;
        // a fraction that is not whole falls back.
        document = ReadManifest(m.Replace("\"formatVersion\":1", "\"formatVersion\":1.0").Replace("\"formatMinor\":0", "\"formatMinor\":0e5"));
        Assert.Equal("Scan", document.Title);
        Assert.Equal("Scan", ReadManifest(m.Replace("\"formatVersion\":1", "\"formatVersion\":1e0")).Title);
        page = ReadManifest(m.Replace("\"pixelWidth\":16", "\"pixelWidth\":16.0").Replace("\"pixelHeight\":12", "\"pixelHeight\":1.2e1")
                             .Replace("\"dpi\":300", "\"dpi\":200.5").Replace("\"byteCount\":421", "\"byteCount\":421.0")
                             .Replace("\"rotationQuarterTurns\":0", "\"rotationQuarterTurns\":2.0,\"sheetIndex\":1E0")).Pages[0];
        Assert.Equal(16, page.Image.PixelWidth);
        Assert.Equal(12, page.Image.PixelHeight);
        Assert.Equal(CompanionPackage.DefaultDpi, page.Image.Dpi);
        Assert.Equal(2, page.RotationQuarterTurns);
        Assert.Equal(1, page.SheetIndex);
        page = ReadManifest(m.Replace("\"pixelWidth\":16", "\"pixelWidth\":16.5").Replace("\"byteCount\":421", "\"byteCount\":420.5")
                             .Replace("\"rotationQuarterTurns\":0", "\"rotationQuarterTurns\":1.5,\"sheetIndex\":2147483648.0")).Pages[0];
        Assert.Equal(0, page.Image.PixelWidth);
        Assert.Equal(0, page.RotationQuarterTurns);
        Assert.Null(page.SheetIndex);
    }

    [Fact]
    public void Read_RefusesWhatIsNotAPackage()
    {
        string m = CompanionFixtures.MinimalManifest;
        AssertReadRefused(CompanionPackageErrorKind.NotPackage, ZipStore.Make([new("pages/0001.jpg", DocxFixtures.Jpeg)]),
                          "This file is not a CompleteScanner document.");
        AssertReadRefused(CompanionPackageErrorKind.NotPackage, Package(m.Replace("\"format\":\"csdoc\"", "\"format\":\"other\"")));
        AssertReadRefused(CompanionPackageErrorKind.NotPackage, Package(m.Replace("\"format\":\"csdoc\",", "")));
        AssertReadRefused(CompanionPackageErrorKind.NotPackage, Package(m.Replace("\"formatVersion\":1", "\"formatVersion\":0")));
        AssertReadRefused(CompanionPackageErrorKind.NewerVersion, Package(m.Replace("\"formatVersion\":1", "\"formatVersion\":2")),
                          "This document was made by a newer version of CompleteScanner (package format 2). Update CompleteScanner to open it.");
        AssertReadRefused(CompanionPackageErrorKind.NewerVersion, Package(m.Replace("\"formatVersion\":1", "\"formatVersion\":2.0")),
                          "This document was made by a newer version of CompleteScanner (package format 2). Update CompleteScanner to open it.");
        AssertReadRefused(CompanionPackageErrorKind.NotPackage, Package(m.Replace("\"formatVersion\":1", "\"formatVersion\":1.5")));
        // Text that is not valid UTF-8 anywhere, in a known key's value or an unknown one's, damages
        // the whole manifest (as for JSONDecoder), not just that value.
        AssertReadRefused(CompanionPackageErrorKind.InvalidManifest, Package(WithByte(m.Replace("\"title\":\"Scan\"", "\"title\":\"S#an\""), 0xFF)),
                          "This document cannot be opened: its list of pages is damaged.");
        AssertReadRefused(CompanionPackageErrorKind.InvalidManifest, Package(WithByte(m.Replace("\"title\":", "\"future\":\"#\",\"title\":"), 0xC3)),
                          "This document cannot be opened: its list of pages is damaged.");
        foreach (string json in new[] { "{not json", "[]", "null", "", "{\"format\":\"csdoc\",}" })
        {
            AssertReadRefused(CompanionPackageErrorKind.InvalidManifest, Package(json),
                              "This document cannot be opened: its list of pages is damaged.");
        }
        AssertReadRefused(CompanionPackageErrorKind.NoPages, Package(m.Replace(m[m.IndexOf("[{", StringComparison.Ordinal)..m.LastIndexOf("]}", StringComparison.Ordinal)], "[")),
                          "This document has no pages.");
        AssertReadRefused(CompanionPackageErrorKind.NoPages, Package(Regex(m, "\"pages\":\\[.*\\]", "\"pages\":[null]")));
        AssertReadRefused(CompanionPackageErrorKind.TooManyPages,
                          Package(Regex(m, "\"pages\":\\[.*\\]", "\"pages\":[" + string.Join(",", Enumerable.Repeat("{}", 2001)) + "]")),
                          "This document has more than 2000 pages.");
    }

    [Fact]
    public void Read_RefusesDamagedOrMissingPictures()
    {
        string m = CompanionFixtures.MinimalManifest;
        string sha = CompanionPackage.Sha256Hex(DocxFixtures.Jpeg);
        string damaged = "Page 1's picture is damaged: its checksum does not match.";
        AssertReadRefused(CompanionPackageErrorKind.ChecksumMismatch, Package(m.Replace(sha, "0" + sha[1..])), damaged);
        AssertReadRefused(CompanionPackageErrorKind.ChecksumMismatch, Package(m.Replace($"\"sha256\":\"{sha}\",", "")), damaged);
        AssertReadRefused(CompanionPackageErrorKind.ChecksumMismatch, Package(m.Replace("\"byteCount\":421", "\"byteCount\":420")), damaged);
        // Upper-case hex is the same checksum.
        Assert.Equal("Scan", ReadManifest(m.Replace(sha, sha.ToUpperInvariant())).Title);

        string missing = "Page 1's picture is missing from the document.";
        AssertReadRefused(CompanionPackageErrorKind.MissingImage, Package(m.Replace("pages/0001.jpg", "pages/0009.jpg")), missing);
        AssertReadRefused(CompanionPackageErrorKind.MissingImage, Package(Regex(m, "\"image\":\\{[^}]*\\}", "\"image\":null")), missing);
        AssertReadRefused(CompanionPackageErrorKind.MissingImage, Package(m.Replace("\"rotationQuarterTurns\":0", "\"rotationQuarterTurns\":0,\"original\":{\"file\":\"x.png\"}")),
                          "Page 1's original picture is missing from the document.");
        AssertReadRefused(CompanionPackageErrorKind.MissingImage, Package(m.Replace("pages/0001.jpg", "manifest.json")));

        string page = Regex(m, "^.*\"pages\":\\[(.*)\\]\\}\\n$", "$1");
        AssertReadRefused(CompanionPackageErrorKind.InvalidManifest, Package(m.Replace(page, page + "," + page)),
                          "This document cannot be opened: Page 2's picture is listed twice.");

        string unsupported = "Page 1's picture is in a format this version of CompleteScanner cannot read.";
        AssertReadRefused(CompanionPackageErrorKind.UnsupportedImage, Package(m.Replace("\"format\":\"jpeg\"", "\"format\":\"png\"")), unsupported);
        AssertReadRefused(CompanionPackageErrorKind.UnsupportedImage, Package(m.Replace("\"format\":\"jpeg\"", "\"format\":\"heic\"")), unsupported);
        byte[] text = "not a picture"u8.ToArray();
        string textManifest = m.Replace(sha, CompanionPackage.Sha256Hex(text)).Replace("\"byteCount\":421", $"\"byteCount\":{text.Length}");
        AssertReadRefused(CompanionPackageErrorKind.UnsupportedImage,
                          ZipStore.Make([new("manifest.json", Encoding.UTF8.GetBytes(textManifest)), new("pages/0001.jpg", text)]), unsupported);
    }

    [Fact]
    public void Read_RefusesArchivesTheZipReaderRefuses()
    {
        byte[] package = CompanionPackage.Make(CompanionFixtures.Minimal);
        int dataOffset;
        using (var reader = ZipStoreReader.Open(package)) dataOffset = (int)reader.Find("pages/0001.jpg")!.DataOffset;
        package[dataOffset + 100] ^= 0xFF;
        AssertReadRefused(CompanionPackageErrorKind.InvalidArchive, package,
                          "This document cannot be opened: \"pages/0001.jpg\" is damaged: its checksum does not match its data.");
        AssertReadRefused(CompanionPackageErrorKind.InvalidArchive,
                          RawZip.Build([new RawEntry("manifest.json", Encoding.UTF8.GetBytes(CompanionFixtures.MinimalManifest)) { Method = 8 }]),
                          "This document cannot be opened: \"manifest.json\" is compressed. Only archives of uncompressed (stored) entries can be read.");
        AssertReadRefused(CompanionPackageErrorKind.InvalidArchive, RawZip.Build([new RawEntry("../manifest.json", [1])]));
        // An entry name never reaches the message as it is.
        AssertReadRefused(CompanionPackageErrorKind.InvalidArchive, RawZip.Build([new RawEntry("x\nGo to evil.example\n", [1])]),
                          "This document cannot be opened: The archive holds an entry with an unsafe name (\"x\uFFFDGo to evil.example\uFFFD\").");
        AssertReadRefused(CompanionPackageErrorKind.InvalidArchive, CompanionPackage.Make(CompanionFixtures.Minimal)[..^5]);
        AssertReadRefused(CompanionPackageErrorKind.InvalidArchive, CompanionPackage.Make(CompanionFixtures.Minimal),
                          limits: ZipReadLimits.Standard with { MaxTotalBytes = 400 });
    }

    [Fact]
    public void ReadFile_ReadsFromDisk()
    {
        string path = Path.Combine(Path.GetTempPath(), $"companion-{Guid.NewGuid():N}.csdoc");
        File.WriteAllBytes(path, Convert.FromHexString(CompanionFixtures.GoldenHex));
        try
        {
            Assert.Equal(2, CompanionPackage.ReadFile(path).Pages.Count);
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public void Number_Format()
    {
        Assert.Equal("0", CompanionPackage.Number(0));
        Assert.Equal("0", CompanionPackage.Number(-0.0000001));
        Assert.Equal("0.5", CompanionPackage.Number(0.5));
        Assert.Equal("-0.25", CompanionPackage.Number(-0.25));
        Assert.Equal("1.5", CompanionPackage.Number(1.5));
        Assert.Equal("2", CompanionPackage.Number(2.0000004));
        Assert.Equal("123.456789", CompanionPackage.Number(123.456789));
        Assert.Equal("0.000123", CompanionPackage.Number(0.0001234567));
        Assert.Equal("0.333333", CompanionPackage.Number(1.0 / 3));
        Assert.Equal("0.666667", CompanionPackage.Number(2.0 / 3));
        Assert.Equal("-0.666667", CompanionPackage.Number(-2.0 / 3));
        Assert.Equal("0.98", CompanionPackage.Number(0.98f));
        Assert.Equal("1000000", CompanionPackage.Number(1e6));
        Assert.Equal("0", CompanionPackage.Number(double.NaN));
        Assert.Equal("0", CompanionPackage.Number(double.PositiveInfinity));
        Assert.Equal("0", CompanionPackage.Number(1e20));
    }

    [Fact]
    public void Quote_Escapes()
    {
        Assert.Equal("\"plain\"", CompanionPackage.Quote("plain"));
        Assert.Equal("\"a\\\"b\\\\c\"", CompanionPackage.Quote("a\"b\\c"));
        Assert.Equal("\"\\n\\r\\t\\b\\f\\u0000\\u001f\"", CompanionPackage.Quote("\n\r\t\b\f\0\u001F"));
        Assert.Equal("\"/ é 日本 \u007F\"", CompanionPackage.Quote("/ é 日本 \u007F"));
        Assert.Equal("\"\U0001F4C4\"", CompanionPackage.Quote("\U0001F4C4"));
    }

    [Fact]
    public void Dates()
    {
        Assert.Equal("2026-10-20T08:30:00Z", CompanionPackage.FormatDate(new DateTimeOffset(2026, 10, 20, 8, 30, 0, TimeSpan.Zero)));
        Assert.Equal(new DateTimeOffset(2026, 10, 20, 8, 30, 0, TimeSpan.Zero), CompanionPackage.ParseDate("2026-10-20T08:30:00Z"));
        Assert.Equal(new DateTimeOffset(2024, 2, 29, 23, 59, 59, TimeSpan.Zero), CompanionPackage.ParseDate("2024-02-29T23:59:59Z"));
        string[] refused =
        [
            "2026-02-30T00:00:00Z", "2026-13-01T00:00:00Z", "2026-10-20T24:00:00Z", "2026-10-20T08:30:00+01:00",
            "2026-10-20T08:30:00.5Z", "2026-10-20 08:30:00Z", "2026-10-20T08:30:00", "0000-01-01T00:00:00Z", "", "yesterday",
        ];
        foreach (string text in refused) Assert.Null(CompanionPackage.ParseDate(text));
    }

    [Fact]
    public void Sha256_KnownValues()
    {
        Assert.Equal("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", CompanionPackage.Sha256Hex([]));
        Assert.Equal("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", CompanionPackage.Sha256Hex("abc"u8));
        Assert.Equal("248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1",
                     CompanionPackage.Sha256Hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"u8));
        Assert.Equal("9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318", CompanionPackage.Sha256Hex(Repeat(55)));
        Assert.Equal("b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a", CompanionPackage.Sha256Hex(Repeat(56)));
        Assert.Equal("ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb", CompanionPackage.Sha256Hex(Repeat(64)));
        Assert.Equal("41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3", CompanionPackage.Sha256Hex(Repeat(1000)));
        Assert.Equal("f1794218ec714df25067c3eb5ac220220d81e9eaaaac9535d5dfb163c87503b7", CompanionPackage.Sha256Hex(DocxFixtures.Jpeg));
        Assert.Equal("f45eb33d36e152c974c50a807e04f6e45b357376a1f584016f27ef19829b5861", CompanionPackage.Sha256Hex(DocxFixtures.Png));

        static byte[] Repeat(int count) => Enumerable.Repeat((byte)'a', count).ToArray();
    }

    [Fact]
    public void Sniff_And_Names()
    {
        Assert.Equal(CompanionImageFormat.Jpeg, CompanionPackage.Sniff(DocxFixtures.Jpeg));
        Assert.Equal(CompanionImageFormat.Png, CompanionPackage.Sniff(DocxFixtures.Png));
        Assert.Equal(CompanionImageFormat.Tiff, CompanionPackage.Sniff([0x49, 0x49, 0x2A, 0x00]));
        Assert.Equal(CompanionImageFormat.Tiff, CompanionPackage.Sniff([0x4D, 0x4D, 0x00, 0x2A]));
        Assert.Null(CompanionPackage.Sniff([0xFF, 0xD8]));
        Assert.Null(CompanionPackage.Sniff([0x89, 0x50, 0x4E, 0x47]));
        Assert.Null(CompanionPackage.Sniff("GIF89a"u8));
        Assert.Null(CompanionPackage.Sniff([]));
        Assert.Equal("pages/0001.jpg", CompanionPackage.ImageEntryName(1, CompanionImageFormat.Jpeg, false));
        Assert.Equal("pages/0012-original.png", CompanionPackage.ImageEntryName(12, CompanionImageFormat.Png, true));
        Assert.Equal("pages/2000.tif", CompanionPackage.ImageEntryName(2000, CompanionImageFormat.Tiff, false));
    }

    private static void AssertImage(CompanionImage image, byte[] data, CompanionImageFormat format, int width, int height, int dpi, ColorMode mode)
    {
        Assert.Equal(data, image.Data);
        Assert.Equal(format, image.Format);
        Assert.Equal(width, image.PixelWidth);
        Assert.Equal(height, image.PixelHeight);
        Assert.Equal(dpi, image.Dpi);
        Assert.Equal(mode, image.ColorMode);
    }

    /// <summary>A package of <paramref name="manifest"/> and the minimal document's picture.</summary>
    private static byte[] Package(string manifest) => Package(Encoding.UTF8.GetBytes(manifest));

    /// <summary>A package of the manifest bytes <paramref name="manifest"/> and the minimal document's picture.</summary>
    private static byte[] Package(byte[] manifest) =>
        ZipStore.Make([new("manifest.json", manifest), new("pages/0001.jpg", DocxFixtures.Jpeg)]);

    /// <summary><paramref name="text"/> as UTF-8 with its one "#" replaced by the byte <paramref name="value"/>.</summary>
    private static byte[] WithByte(string text, byte value)
    {
        byte[] bytes = Encoding.UTF8.GetBytes(text);
        Assert.Single(bytes, b => b == (byte)'#');
        bytes[Array.IndexOf(bytes, (byte)'#')] = value;
        return bytes;
    }

    private static CompanionDocument ReadManifest(string manifest) => CompanionPackage.Read(Package(manifest));

    private static string Regex(string input, string pattern, string replacement) =>
        System.Text.RegularExpressions.Regex.Replace(input, pattern, replacement, System.Text.RegularExpressions.RegexOptions.Singleline);

    private static CompanionPackageException AssertWriteRefused(CompanionPackageErrorKind kind, CompanionDocument document)
    {
        var error = Assert.Throws<CompanionPackageException>(() => CompanionPackage.Make(document));
        Assert.Equal(kind, error.Kind);
        return error;
    }

    private static void AssertReadRefused(CompanionPackageErrorKind kind, byte[] package, string? message = null, ZipReadLimits? limits = null)
    {
        var error = Assert.Throws<CompanionPackageException>(() => CompanionPackage.Read(package, limits));
        Assert.Equal(kind, error.Kind);
        if (message is not null) Assert.Equal(message, error.Message);
    }
}

/// <summary>
/// The documents both suites package: <see cref="Sample"/> is the golden package (its bytes
/// pinned below, the same in CompanionPackageTests.swift), <see cref="Minimal"/> the one the
/// lenient-reading cases bend.
/// </summary>
internal static class CompanionFixtures
{
    public static CompanionDocument Sample => new(
        "Résumé \"draft\" \\ 1\t\u0001",
        [
            new CompanionPage(new CompanionImage(DocxFixtures.Jpeg, CompanionImageFormat.Jpeg, 16, 12, 300, ColorMode.Grayscale))
            {
                RotationQuarterTurns = 1,
                Side = PageSide.Front,
                SheetIndex = 0,
                OcrLines =
                [
                    new OcrLine("Hello", new RectD(0.1, 0.2, 0.5, 0.125), 0.98f),
                    new OcrLine("naïve 日本", new RectD(0.0001234567, 0.75, 0.333333333, 0.05), 0.5f),
                ],
                Original = new CompanionImage(DocxFixtures.Png, CompanionImageFormat.Png, 16, 12, 300, ColorMode.BlackWhite),
            },
            new CompanionPage(new CompanionImage(DocxFixtures.Png, CompanionImageFormat.Png, 16, 12, 200, ColorMode.BlackWhite))
            {
                Side = PageSide.Back,
                SheetIndex = 0,
                OcrLines = [],
            },
        ])
    {
        Writer = new CompanionWriterInfo("CompleteScanner", "1.0", "test"),
        Created = new DateTimeOffset(2026, 10, 20, 8, 30, 0, TimeSpan.Zero),
        TaskId = "receipts",
        SuggestedName = "Scan 1",
        NamingTemplate = "{date} {title}",
    };

    public static CompanionDocument Minimal => new(
        "Scan", [new CompanionPage(new CompanionImage(DocxFixtures.Jpeg, CompanionImageFormat.Jpeg, 16, 12, 300, ColorMode.Color))]);

    public const string GoldenManifest =
        """{"format":"csdoc","formatVersion":1,"formatMinor":0,"writer":{"app":"CompleteScanner","appVersion":"1.0","platform":"test"},"created":"2026-10-20T08:30:00Z","title":"Résumé \"draft\" \\ 1\t\u0001","taskId":"receipts","naming":{"suggestedName":"Scan 1","template":"{date} {title}"},"pages":[{"image":{"file":"pages/0001.jpg","format":"jpeg","byteCount":421,"sha256":"f1794218ec714df25067c3eb5ac220220d81e9eaaaac9535d5dfb163c87503b7","pixelWidth":16,"pixelHeight":12,"dpi":300,"colorMode":"grayscale"},"rotationQuarterTurns":1,"side":"front","sheetIndex":0,"ocrLines":[{"text":"Hello","x":0.1,"y":0.2,"width":0.5,"height":0.125,"confidence":0.98},{"text":"naïve 日本","x":0.000123,"y":0.75,"width":0.333333,"height":0.05,"confidence":0.5}],"original":{"file":"pages/0001-original.png","format":"png","byteCount":127,"sha256":"f45eb33d36e152c974c50a807e04f6e45b357376a1f584016f27ef19829b5861","pixelWidth":16,"pixelHeight":12,"dpi":300,"colorMode":"blackWhite"}},{"image":{"file":"pages/0002.png","format":"png","byteCount":127,"sha256":"f45eb33d36e152c974c50a807e04f6e45b357376a1f584016f27ef19829b5861","pixelWidth":16,"pixelHeight":12,"dpi":200,"colorMode":"blackWhite"},"rotationQuarterTurns":0,"side":"back","sheetIndex":0,"ocrLines":[]}]}"""
        + "\n";

    public const string MinimalManifest =
        """{"format":"csdoc","formatVersion":1,"formatMinor":0,"writer":{"app":"CompleteScanner","appVersion":"","platform":""},"title":"Scan","pages":[{"image":{"file":"pages/0001.jpg","format":"jpeg","byteCount":421,"sha256":"f1794218ec714df25067c3eb5ac220220d81e9eaaaac9535d5dfb163c87503b7","pixelWidth":16,"pixelHeight":12,"dpi":300,"colorMode":"color"},"rotationQuarterTurns":0}]}"""
        + "\n";

    public const int GoldenLength = 2375;
    public const string GoldenSha256 = "7875e75b4b30114850eed1a64c88f59efaea27e1e5b9ccf5eaabd0feb7ab1868";
    public const string GoldenHex =
        "504B03040A00000000000000210004B4A913DE040000DE0400000D0000006D616E69666573742E6A736F6E7B22666F72" +
        "6D6174223A226373646F63222C22666F726D617456657273696F6E223A312C22666F726D61744D696E6F72223A302C22" +
        "777269746572223A7B22617070223A22436F6D706C6574655363616E6E6572222C2261707056657273696F6E223A2231" +
        "2E30222C22706C6174666F726D223A2274657374227D2C2263726561746564223A22323032362D31302D32305430383A" +
        "33303A30305A222C227469746C65223A2252C3A973756DC3A9205C2264726166745C22205C5C20315C745C7530303031" +
        "222C227461736B4964223A227265636569707473222C226E616D696E67223A7B227375676765737465644E616D65223A" +
        "225363616E2031222C2274656D706C617465223A227B646174657D207B7469746C657D227D2C227061676573223A5B7B" +
        "22696D616765223A7B2266696C65223A2270616765732F303030312E6A7067222C22666F726D6174223A226A70656722" +
        "2C2262797465436F756E74223A3432312C22736861323536223A22663137393432313865633731346466323530363763" +
        "33656235616332323032323064383165396561616161633935333564356466623136336338373530336237222C227069" +
        "78656C5769647468223A31362C22706978656C486569676874223A31322C22647069223A3330302C22636F6C6F724D6F" +
        "6465223A22677261797363616C65227D2C22726F746174696F6E517561727465725475726E73223A312C227369646522" +
        "3A2266726F6E74222C227368656574496E646578223A302C226F63724C696E6573223A5B7B2274657874223A2248656C" +
        "6C6F222C2278223A302E312C2279223A302E322C227769647468223A302E352C22686569676874223A302E3132352C22" +
        "636F6E666964656E6365223A302E39387D2C7B2274657874223A226E61C3AF766520E697A5E69CAC222C2278223A302E" +
        "3030303132332C2279223A302E37352C227769647468223A302E3333333333332C22686569676874223A302E30352C22" +
        "636F6E666964656E6365223A302E357D5D2C226F726967696E616C223A7B2266696C65223A2270616765732F30303031" +
        "2D6F726967696E616C2E706E67222C22666F726D6174223A22706E67222C2262797465436F756E74223A3132372C2273" +
        "6861323536223A2266343565623333643336653135326339373463353061383037653034663665343562333537333736" +
        "613166353834303136663237656631393832396235383631222C22706978656C5769647468223A31362C22706978656C" +
        "486569676874223A31322C22647069223A3330302C22636F6C6F724D6F6465223A22626C61636B5768697465227D7D2C" +
        "7B22696D616765223A7B2266696C65223A2270616765732F303030322E706E67222C22666F726D6174223A22706E6722" +
        "2C2262797465436F756E74223A3132372C22736861323536223A22663435656233336433366531353263393734633530" +
        "61383037653034663665343562333537333736613166353834303136663237656631393832396235383631222C227069" +
        "78656C5769647468223A31362C22706978656C486569676874223A31322C22647069223A3230302C22636F6C6F724D6F" +
        "6465223A22626C61636B5768697465227D2C22726F746174696F6E517561727465725475726E73223A302C2273696465" +
        "223A226261636B222C227368656574496E646578223A302C226F63724C696E6573223A5B5D7D5D7D0A504B03040A0000" +
        "0000000000210085915458A5010000A50100000E00000070616765732F303030312E6A7067FFD8FFE000104A46494600" +
        "010101012C012C0000FFDB00430006040506050406060506070706080A100A0A09090A140E0F0C101714181817141616" +
        "1A1D251F1A1B231C1616202C20232627292A29191F2D302D283025282928FFC0000B08000C001001011100FFC4001F00" +
        "00010501010101010100000000000000000102030405060708090A0BFFC400B510000201030302040305050404000001" +
        "7D01020300041105122131410613516107227114328191A1082342B1C11552D1F02433627282090A161718191A252627" +
        "28292A3435363738393A434445464748494A535455565758595A636465666768696A737475767778797A838485868788" +
        "898A92939495969798999AA2A3A4A5A6A7A8A9AAB2B3B4B5B6B7B8B9BAC2C3C4C5C6C7C8C9CAD2D3D4D5D6D7D8D9DAE1" +
        "E2E3E4E5E6E7E8E9EAF1F2F3F4F5F6F7F8F9FAFFDA0008010100003F00E13E1B685FEABE4F4AF6BF166B7FF0807C38BC" +
        "D560F97529B16761F2E7F7EE0E1B9561F2A867C30C1D9B73C8AE73E1B59C3FBAF97D2B9FFDA4A5925F1FF8774D77CD95" +
        "BE982E228F68F96492575739C64E4451F04E06DE3A9CFF00FFD9504B03040A000000000000002100063A73A67F000000" +
        "7F0000001700000070616765732F303030312D6F726967696E616C2E706E6789504E470D0A1A0A0000000D4948445200" +
        "0000100000000C0100000000439C002C000000017352474200AECE1CE90000000467414D410000B18F0BFC6105000000" +
        "097048597300002E2300002E230178A53F76000000144944415418D363C8DDC6703B9761DB6D06DC0C0019EB0FF11F83" +
        "7D3C0000000049454E44AE426082504B03040A000000000000002100063A73A67F0000007F0000000E00000070616765" +
        "732F303030322E706E6789504E470D0A1A0A0000000D49484452000000100000000C0100000000439C002C0000000173" +
        "52474200AECE1CE90000000467414D410000B18F0BFC6105000000097048597300002E2300002E230178A53F76000000" +
        "144944415418D363C8DDC6703B9761DB6D06DC0C0019EB0FF11F837D3C0000000049454E44AE426082504B010214000A" +
        "00000000000000210004B4A913DE040000DE0400000D00000000000000000000000000000000006D616E69666573742E" +
        "6A736F6E504B010214000A00000000000000210085915458A5010000A50100000E000000000000000000000000000905" +
        "000070616765732F303030312E6A7067504B010214000A000000000000002100063A73A67F0000007F00000017000000" +
        "00000000000000000000DA06000070616765732F303030312D6F726967696E616C2E706E67504B010214000A00000000" +
        "0000002100063A73A67F0000007F0000000E000000000000000000000000008E07000070616765732F303030322E706E" +
        "67504B05060000000004000400F8000000390800000000";
}
