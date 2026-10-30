using System.Text;
using System.Text.RegularExpressions;
using LazyScan.Core;
using UglyToad.PdfPig;
using Xunit;

namespace LazyScan.Core.Tests;

// Adding scanned pages to an existing PDF as an incremental update: the original bytes untouched,
// the update in the same style as the file's newest section, the new pages as PdfBuilder writes
// them; checked in the bytes, by reading the result back with PdfReaderLite, and through PdfPig (a
// test-only package) with its lenient parsing off, so a broken offset fails instead of being
// repaired. The Swift twin is PDFAppenderTests.swift, with the same cases; it reads the results
// with PDFReaderLite and PDFKit.

public class PdfAppenderTests
{
    private static readonly byte[] NewId = [.. Enumerable.Range(0x10, 16).Select(i => (byte)i)];
    private static readonly PdfAppendOptions Fixed = new() { DocumentId = NewId };

    private static readonly OcrLine[] Lines =
    [
        new("Ek sayfa: imza Çağrı Işık", new RectD(0.1, 0.8, 0.8, 0.05), 0.9f),
    ];

    /// <summary>A Letter page at 300 dpi (612 × 792 pt), with the text layer when asked.</summary>
    private static PdfPageInput Page(bool text = false, int width = 2550, int height = 3300) =>
        new(PdfBuilderTests.TinyJpeg, width, height, 300, text ? Lines : null);

    private static PdfDocument Open(byte[] pdf) => PdfDocument.Open(pdf, new ParsingOptions { UseLenientParsing = false });

    private static string Latin1(byte[] pdf) => Encoding.Latin1.GetString(pdf);

    /// <summary>The update: everything after the original.</summary>
    private static string Update(byte[] original, byte[] appended) => Latin1(appended[original.Length..]);

    /// <summary>The original is an unchanged prefix, the result reads back with every page, and its newest section points at the original's.</summary>
    private static PdfReaderLite CheckAppended(byte[] original, byte[] appended, int added)
    {
        Assert.True(appended.AsSpan(0, original.Length).SequenceEqual(original), "the original bytes are unchanged at the start");
        var before = new PdfReaderLite(original);
        var after = new PdfReaderLite(appended);
        Assert.Equal(before.PageCount + added, after.PageCount);
        Assert.Equal(before.SectionCount + 1, after.SectionCount);
        Assert.Equal(before.StartXref, after.LatestPrev);
        Assert.Equal(before.Pages, after.Pages.Take(before.PageCount));
        using var document = Open(appended);
        Assert.Equal(before.PageCount + added, document.NumberOfPages);
        return after;
    }

    // MARK: - Our own files

    [Fact]
    public void OurPdf_GetsPagesAfterItsUnchangedBytes()
    {
        byte[] original = PdfBuilder.Make([Page(), Page()]);
        byte[] appended = PdfAppender.Append(original, [Page(text: true), Page()], Fixed);
        var reader = CheckAppended(original, appended, 2);

        using var document = Open(appended);
        for (int n = 1; n <= 4; n++)
        {
            var page = document.GetPage(n);
            Assert.Equal((612, 792), ((int)page.Width, (int)page.Height));
            Assert.Single(page.GetImages());
        }
        Assert.Equal("Ek sayfa: imza Çağrı Işık", document.GetPage(3).Text);
        Assert.Equal("", document.GetPage(4).Text);

        // A plain PDF's update: a classic table of the font, the pages and the tree root again.
        string update = Update(original, appended);
        Assert.StartsWith("9 0 obj\n<</Type /Font /Subtype /Type0 /BaseFont /GlyphLessFont", update);
        Assert.Contains("15 0 obj\n<</Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources <</XObject <</Im0 16 0 R>> /Font <</F1 9 0 R>>>> /Contents 17 0 R /Rotate 0>>", update);
        Assert.Contains("18 0 obj\n<</Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources <</XObject <</Im1 19 0 R>>>> /Contents 20 0 R /Rotate 0>>", update);
        Assert.Contains("2 0 obj\n<</Type /Pages /Kids [3 0 R 6 0 R 15 0 R 18 0 R] /Count 4>>\nendobj\n", update);
        Assert.Matches(new Regex(@"xref\n2 1\n\d{10} 00000 n \n9 12\n(\d{10} 00000 n \n){12}trailer\n"), update);
        string id = Convert.ToHexString(NewId);
        Assert.EndsWith($"trailer\n<</Size 21 /Root 1 0 R /ID [<{id}> <{id}>] /Prev {reader.LatestPrev}>>\nstartxref\n{reader.StartXref}\n%%EOF\n", update);
    }

    [Fact]
    public void Twice_ChainsTheUpdates()
    {
        byte[] original = PdfBuilder.Make([Page()]);
        byte[] once = PdfAppender.Append(original, [Page()]);
        byte[] twice = PdfAppender.Append(once, [Page(text: true), Page(), Page()]);
        var reader = CheckAppended(once, twice, 3);
        Assert.Equal(3, reader.SectionCount);
        Assert.Equal(5, reader.PageCount);
        using var document = Open(twice);
        Assert.Contains("Çağrı", document.GetPage(3).Text);
    }

    [Fact]
    public void PdfA_KeepsItsIdentifierMetadataAndConformance()
    {
        var options = new PdfWriteOptions
        {
            Conformance = PdfConformance.PdfA2b,
            Title = "Sözleşme",
            CreationDate = new DateTimeOffset(2026, 10, 19, 21, 30, 5, TimeSpan.FromHours(3)),
            DocumentId = [.. Enumerable.Range(0xA0, 16).Select(i => (byte)i)],
        };
        byte[] original = PdfBuilder.Make([Page(text: true)], options: options);
        var target = PdfAppender.Describe(new PdfReaderLite(original), "Sözleşme.pdf");
        Assert.True(target.IsPdfA);
        Assert.True(target.KeepsPdfA);
        Assert.Empty(target.Warnings);
        Assert.Null(target.ConfirmMessage);

        byte[] appended = PdfAppender.Append(original, [Page(text: true)], Fixed);
        CheckAppended(original, appended, 1);
        string update = Update(original, appended);
        // The first half of the identifier stays; the catalog, Info and metadata are not rewritten.
        Assert.Contains($"/Info 9 0 R /ID [<A0A1A2A3A4A5A6A7A8A9AAABACADAEAF> <{Convert.ToHexString(NewId)}>]", update);
        Assert.DoesNotContain("/Type /Catalog", update);
        Assert.DoesNotContain("/Metadata", update);
        using var document = Open(appended);
        Assert.Equal("Sözleşme", document.Information.Title);
        Assert.Equal(2, document.NumberOfPages);
    }

    [Fact]
    public void Encrypted_IsRefused_AndLeftAsItWas()
    {
        using var protection = new PdfProtection("Şifre 2026");
        byte[] original = PdfBuilder.Make([Page()], options: new PdfWriteOptions { Protection = protection });
        Assert.Equal(PdfReadProblem.Encrypted, Assert.Throws<PdfReadException>(() => PdfAppender.Append(original, [Page()])).Problem);
        var e = Assert.Throws<PdfAppendException>(() => PdfAppender.Describe(new PdfReaderLite(original), @"C:\x\Gizli.pdf"));
        Assert.Equal(PdfAppendProblem.Encrypted, e.Problem);
        Assert.Equal("Gizli.pdf is password-protected, so pages can't be added to it. Save them as a new PDF instead.", e.Message);
    }

    // MARK: - Other writers' layouts

    [Fact]
    public void Classic_WithEveryEndOfLine_AndNoFinalOne()
    {
        foreach (var (newline, final) in new[] { ("\n", true), ("\r\n", true), ("\r", true), ("\n", false) })
        {
            byte[] original = PdfFixture.Classic(newline, final);
            byte[] appended = PdfAppender.Append(original, [Page()]);
            CheckAppended(original, appended, 1);
            // An end of line is added only where the original has none.
            Assert.Equal(final ? "9 0 obj" : "\n9 0 obj", Update(original, appended)[..(final ? 7 : 8)]);
            using var document = Open(appended);
            Assert.Equal("one", document.GetPage(1).Text);
            Assert.Equal("two", document.GetPage(2).Text);
        }
    }

    [Fact]
    public void AlreadyUpdated_AddsAThirdSection()
    {
        byte[] original = PdfFixture.AlreadyUpdated();
        byte[] appended = PdfAppender.Append(original, [Page()]);
        var reader = CheckAppended(original, appended, 1);
        Assert.Equal(3, reader.SectionCount);
        Assert.Equal([3, 4, 9, 11], reader.Pages.Select(p => p.Number));
        // The Info reference and the identifier come through from the older trailers.
        Assert.Matches(new Regex(@"/Root 1 0 R /Info 8 0 R /ID \[<00112233445566778899AABBCCDDEEFF> <[0-9A-F]{32}>\]"), Update(original, appended));
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public void ObjectStreams_GetAnUncompressedCrossReferenceStream(bool text)
    {
        byte[] original = PdfFixture.ObjectStreams();
        byte[] appended = PdfAppender.Append(original, [Page(text), Page()], Fixed);
        var reader = CheckAppended(original, appended, 2);
        Assert.True(reader.XrefIsStream);
        string update = Update(original, appended);
        // The tree root lived in an object stream; the update gives it a place of its own.
        Assert.Contains("2 0 obj\n<</Type /Pages /Kids [3 0 R 4 0 R ", update);
        int first = 12, xref = first + (text ? 6 : 0) + 6;
        Assert.Contains($"{xref} 0 obj\n<</Type /XRef /W [1 4 2] /Index [2 1 {first} {xref - first + 1}] /Size {xref + 1} /Root 1 0 R /ID [<A0A1A2A3A4A5A6A7A8A9AAABACADAEAF> <{Convert.ToHexString(NewId)}>] /Prev {reader.LatestPrev} /Length {7 * (xref - first + 2)}>>\nstream\n", update);
        Assert.EndsWith($"\nendstream\nendobj\nstartxref\n{reader.StartXref}\n%%EOF\n", update);
        using var document = Open(appended);
        Assert.Equal("two", document.GetPage(2).Text);
        Assert.Single(document.GetPage(4).GetImages());
    }

    [Fact]
    public void Hybrid_GetsAClassicTable()
    {
        byte[] original = PdfFixture.Hybrid();
        byte[] appended = PdfAppender.Append(original, [Page()]);
        var reader = CheckAppended(original, appended, 1);
        Assert.False(reader.XrefIsStream);
        Assert.True(reader.IsHybrid);
        Assert.Contains("\nxref\n2 1\n", Update(original, appended));
    }

    [Fact]
    public void InheritedAttributes_DoNotReachTheNewPages()
    {
        byte[] original = PdfFixture.Inherited();
        byte[] appended = PdfAppender.Append(original, [Page()]);
        CheckAppended(original, appended, 1);
        string update = Update(original, appended);
        Assert.Contains("/Contents 10 0 R /Rotate 0 /CropBox [0 0 612 792]>>", update);
        // The root keeps what it passes down to the pages that were there.
        Assert.Contains("/MediaBox [0 0 200 300] /CropBox [10 10 190 290] /Rotate 90 /Resources <</Font <</F1 7 0 R>>>>>>", update);
        using var document = Open(appended);
        Assert.Equal(90, document.GetPage(1).Rotation.Value);
        Assert.Equal(0, document.GetPage(2).Rotation.Value);
        Assert.Equal((612, 792), ((int)document.GetPage(2).Width, (int)document.GetPage(2).Height));
    }

    [Fact]
    public void NestedTree_NewPagesComeLast()
    {
        byte[] original = PdfFixture.Nested();
        byte[] appended = PdfAppender.Append(original, [Page(width: 1250, height: 1250)]);
        CheckAppended(original, appended, 1);
        Assert.Contains("2 0 obj\n<</Type /Pages /Kids [3 0 R 6 0 R 10 0 R] /Count 4>>", Update(original, appended));
        using var document = Open(appended);
        Assert.Equal([100, 200, 300, 300], Enumerable.Range(1, 4).Select(n => (int)document.GetPage(n).Width));
    }

    [Fact]
    public void IndirectKidsAndCount_NamesStringsAndGeneration_WrittenBackAsTheyWere()
    {
        byte[] original = PdfFixture.IndirectKids();
        byte[] appended = PdfAppender.Append(original, [Page()]);
        CheckAppended(original, appended, 1);
        string update = Update(original, appended);
        Assert.Contains("6 0 obj\n<</Type /Page /Parent 2 1 R ", update);
        Assert.Contains("2 1 obj\n<</Type /Pages /Kids [3 0 R 6 0 R] /Count 2 /Odd#20Name (a\\(b\\)c\\\\ \\r end) /Hex <4142> /Real -.5>>", update);
        Assert.Matches(new Regex(@"xref\n2 1\n\d{10} 00001 n \n6 3\n"), update);
    }

    // MARK: - Before adding: warnings and refusals

    [Fact]
    public void Warnings_SignedFiles_AndPdfALevelsThatAreNotKept()
    {
        var signed = PdfAppender.Describe(new PdfReaderLite(PdfFixture.WithCatalog("/AcroForm <</Fields [] /SigFlags 3>>")), @"C:\x\Contract.pdf");
        Assert.True(signed.IsSigned);
        Assert.Equal(["Contract.pdf is signed. Adding pages keeps the signature, but PDF apps will show that the file was changed after it was signed."], signed.Warnings);
        Assert.Equal(signed.Warnings[0] + "\n\nAdd the pages anyway?", signed.ConfirmMessage);

        var a1 = PdfAppender.Describe(new PdfReaderLite(PdfFixture.PdfA(1, "A")), "Old.pdf");
        Assert.False(a1.KeepsPdfA);
        Assert.Equal(["Old.pdf is a PDF/A-1a file. The added pages may not meet that standard, so it may no longer pass as PDF/A."], a1.Warnings);
        Assert.False(PdfAppender.Describe(new PdfReaderLite(PdfFixture.PdfA(2, "B", components: 4)), "Print.pdf").KeepsPdfA);
        Assert.True(PdfAppender.Describe(new PdfReaderLite(PdfFixture.PdfA(3, "U")), "Kept.pdf").KeepsPdfA);
    }

    [Fact]
    public void Warnings_CertifiedFiles_AreToldTheCertificationBreaks()
    {
        var certified = PdfAppender.Describe(new PdfReaderLite(PdfFixture.WithCatalog("/AcroForm <</Fields [] /SigFlags 3>> /Perms <</DocMDP 4 0 R>>",
                                                                                       f => f.Obj(4, "<</Type /Sig>>"))), @"C:\x\Form.pdf");
        Assert.True(certified.IsSigned);
        Assert.True(certified.IsCertified);
        Assert.Equal(["Form.pdf is certified. Its certification does not allow adding pages, so PDF apps will show the certification as no longer valid."], certified.Warnings);
        Assert.False(PdfAppender.Describe(new PdfReaderLite(PdfFixture.WithCatalog("/AcroForm <</Fields [] /SigFlags 3>>")), "a.pdf").IsCertified);
    }

    private static byte[] Replace(byte[] pdf, string from, string to)
    {
        string text = Latin1(pdf);
        Assert.Contains(from, text);
        return Encoding.Latin1.GetBytes(text.Replace(from, to));
    }

    [Fact]
    public void ObjectsReadWhenAskedFor_AreRefusedInWords_BeforeAnyPageIsMade()
    {
        // The page tree reads fine; the form, or the PDF/A output intent's profile, is listed where another object is.
        var cases = new[]
        {
            Replace(PdfFixture.WithCatalog("/AcroForm 4 0 R", f => f.Obj(4, "<</Fields [] /SigFlags 3>>")), "4 0 obj", "5 0 obj"),
            Replace(PdfFixture.PdfA(2, "B"), "5 0 obj", "6 0 obj"),
        };
        using var folder = new Folder();
        foreach (byte[] bytes in cases)
        {
            var e = Assert.Throws<PdfAppendException>(() => PdfAppender.Describe(new PdfReaderLite(bytes), @"C:\x\Form.pdf"));
            Assert.Equal(PdfAppendProblem.Damaged, e.Problem);
            Assert.Equal(PdfAppender.Message(PdfAppendProblem.Damaged, "Form.pdf"), e.Message);
            Assert.IsType<PdfReadException>(e.InnerException);

            string path = folder.File("Form.pdf", bytes);
            Assert.Equal(PdfAppendProblem.Damaged, Assert.Throws<PdfAppendException>(() => PdfAppender.Inspect(path)).Problem);
            Assert.Equal(PdfAppendProblem.Damaged, Assert.Throws<PdfAppendException>(() => PdfAppender.AppendToFile(path, [Page()])).Problem);
            Assert.Equal(bytes, File.ReadAllBytes(path));
            Assert.Equal([path], Directory.GetFiles(folder.Path));
        }
    }

    [Fact]
    public void ATreeWhoseRootIsAPage_IsRefusedWhenInspected()
    {
        var f = new PdfFixture();
        f.Obj(1, "<</Type /Catalog /Pages 3 0 R>>");
        f.Obj(3, "<</Type /Page /MediaBox [0 0 612 792] /Resources <<>>>>");
        f.Table("/Size 4 /Root 1 0 R");
        using var folder = new Folder();
        string path = folder.File("One.pdf", f.ToArray());
        var e = Assert.Throws<PdfAppendException>(() => PdfAppender.Inspect(path));
        Assert.Equal(PdfAppendProblem.Damaged, e.Problem);
        Assert.Equal(PdfAppender.Message(PdfAppendProblem.Damaged, "One.pdf"), e.Message);
    }

    [Fact]
    public void ObjectNumbers_StayWithinPdfsLimit()
    {
        // All numbers used: refused before anything is written.
        byte[] full = Replace(PdfFixture.WithCatalog(""), "/Size 6 ", "/Size 8388608 ");
        Assert.Equal(PdfReadProblem.Unsupported, Assert.Throws<PdfReadException>(() => PdfAppender.Append(full, [Page()])).Problem);
        using var folder = new Folder();
        string path = folder.File("Full.pdf", full);
        var e = Assert.Throws<PdfAppendException>(() => PdfAppender.AppendToFile(path, [Page()]));
        Assert.Equal(PdfAppendProblem.Unsupported, e.Problem);
        Assert.Equal(full, File.ReadAllBytes(path));
        Assert.Equal([path], Directory.GetFiles(folder.Path));

        // Room for exactly one page (three objects) in a classic table.
        byte[] nearly = Replace(PdfFixture.WithCatalog(""), "/Size 6 ", "/Size 8388605 ");
        var reader = new PdfReaderLite(PdfAppender.Append(nearly, [Page()]));
        Assert.Equal(2, reader.PageCount);
        Assert.Equal(8_388_605, reader.Pages[1].Number);
        Assert.Equal(PdfReadProblem.Unsupported, Assert.Throws<PdfReadException>(() => PdfAppender.Append(nearly, [Page(), Page()])).Problem);
    }

    [Fact]
    public void WriteUpdate_NoObjectNumbersLeft_LeavesTheCallersStreamAsItWas()
    {
        // A file that does not end with an end of line: the refusal comes before that end of line is written.
        byte[] full = Replace(PdfFixture.WithCatalog(""), "/Size 6 ", "/Size 8388608 ");
        int end = full.Length;
        while (full[end - 1] is 10 or 13) end--;
        byte[] unterminated = full[..end];
        var reader = new PdfReaderLite(unterminated);
        using var output = new MemoryStream();
        output.Write(unterminated);
        var e = Assert.Throws<PdfReadException>(() => PdfAppender.WriteUpdate(reader, output, [Page()]));
        Assert.Equal(PdfReadProblem.Unsupported, e.Problem);
        Assert.Equal(unterminated, output.ToArray());
    }

    [Theory]
    [InlineData(1, "B", 3, true)]
    [InlineData(1, "U", 3, false)]
    [InlineData(1, "A", 3, false)]
    [InlineData(2, "B", 3, true)]
    [InlineData(2, "U", 3, true)]
    [InlineData(2, "A", 3, false)]
    [InlineData(3, "B", 3, true)]
    [InlineData(4, null, 3, false)]
    [InlineData(2, "B", 4, false)]
    [InlineData(2, "B", null, false)]
    public void KeepsPdfA_Table(int part, string? conformance, int? components, bool keeps) =>
        Assert.Equal(keeps, PdfAppender.KeepsPdfA(part, conformance, components));

    [Fact]
    public void Messages_SayWhatToDo()
    {
        Assert.Equal("Scan.pdf looks damaged, so pages can't be added to it safely. Save them as a new PDF instead.",
                     PdfAppender.Message(PdfAppendProblem.Damaged, "Scan.pdf"));
        Assert.Equal("Scan.pdf is open in another app. Close it there, then add the pages again.",
                     PdfAppender.Message(PdfAppendProblem.InUse, "Scan.pdf"));
        Assert.Equal("The pages could not be added to Scan.pdf, and the file could not be put back under its name. It is unchanged, "
                     + "in the same folder, named .1234.pdf.bak. Rename it back to Scan.pdf, then add the pages again.",
                     PdfAppender.LeftAsBackupMessage("Scan.pdf", ".1234.pdf.bak"));
        Assert.Equal("The pages could not be added to Scan.pdf, and the file could not be put back under its name. It is unchanged, "
                     + "in the same folder, under a name ending in .pdf.bak. Rename it back to Scan.pdf, then add the pages again.",
                     PdfAppender.Message(PdfAppendProblem.LeftAsBackup, "Scan.pdf"));
        Assert.Equal("Added 1 page to Scan.pdf (now 2 pages, 1.4 MB)", PdfAppender.AddedMessage(1, "Scan.pdf", 2, "1.4 MB"));
        Assert.Equal("Added 3 pages to Scan.pdf (now 4 pages)", PdfAppender.AddedMessage(3, "Scan.pdf", 4, null));
        Assert.Equal(Enum.GetValues<PdfAppendProblem>().Length,
                     Enum.GetValues<PdfAppendProblem>().Select(p => PdfAppender.Message(p, "x.pdf")).Distinct().Count());
    }

    [Fact]
    public void SaveTexts_NameTheTarget()
    {
        Assert.Equal("Add to Contract.pdf", PdfAppender.SaveTitle("Contract.pdf"));
        Assert.Equal("Add to existing PDF…", PdfAppender.ButtonLabel);
    }

    // MARK: - The file on disk

    private sealed class Folder : IDisposable
    {
        public string Path { get; } = System.IO.Path.Combine(System.IO.Path.GetTempPath(), $"PdfAppenderTests-{Guid.NewGuid()}");
        public Folder() => Directory.CreateDirectory(Path);
        public string File(string name, byte[] bytes)
        {
            string path = System.IO.Path.Combine(Path, name);
            System.IO.File.WriteAllBytes(path, bytes);
            return path;
        }
        public void Dispose()
        {
            foreach (string f in Directory.GetFiles(Path)) System.IO.File.SetAttributes(f, FileAttributes.Normal);
            Directory.Delete(Path, recursive: true);
        }
    }

    [Fact]
    public void AppendToFile_ReplacesTheFile_KeepingItsCreationTime()
    {
        using var folder = new Folder();
        byte[] original = PdfFixture.ObjectStreams();
        string path = folder.File("Sözleşme.pdf", original);
        var created = new DateTime(2020, 1, 2, 3, 4, 5, DateTimeKind.Utc);
        File.SetCreationTimeUtc(path, created);
        var messages = new List<string>();
        var result = PdfAppender.AppendToFile(path, [Page(text: true), Page()], messages.Add);
        Assert.Equal(new PdfAppendResult(Path.GetFullPath(path), 2, 2, new FileInfo(path).Length), result);
        Assert.Equal(4, result.PageCount);
        Assert.Equal(["Adding page 1 of 2…", "Adding page 2 of 2…"], messages);
        CheckAppended(original, File.ReadAllBytes(path), 2);
        Assert.Equal(created, File.GetCreationTimeUtc(path));
        Assert.False(File.GetAttributes(path).HasFlag(FileAttributes.Hidden));
        Assert.Equal([path], Directory.GetFiles(folder.Path)); // no temporary file left
        Assert.Equal(4, PdfAppender.Inspect(path).PageCount);
    }

    [Fact]
    [System.Runtime.Versioning.SupportedOSPlatform("windows")]
    public void AppendToFile_KeepsTheFilesPermissionsAndAlternateStreams()
    {
        if (!OperatingSystem.IsWindows()) return;
        using var folder = new Folder();
        string path = folder.File("Downloaded.pdf", PdfFixture.Classic());
        // The mark a browser or mail app gives a downloaded file, and a permission given to this file alone.
        const string zone = "[ZoneTransfer]\r\nZoneId=3\r\n";
        File.WriteAllText(path + ":Zone.Identifier", zone);
        var everyone = new System.Security.Principal.SecurityIdentifier(System.Security.Principal.WellKnownSidType.WorldSid, null);
        var info = new FileInfo(path);
        var security = info.GetAccessControl();
        security.AddAccessRule(new System.Security.AccessControl.FileSystemAccessRule(
            everyone, System.Security.AccessControl.FileSystemRights.ReadData, System.Security.AccessControl.AccessControlType.Allow));
        info.SetAccessControl(security);

        PdfAppender.AppendToFile(path, [Page()]);

        Assert.Equal(3, PdfAppender.Inspect(path).PageCount);
        Assert.Equal(zone, File.ReadAllText(path + ":Zone.Identifier"));
        var rules = new FileInfo(path).GetAccessControl()
            .GetAccessRules(includeExplicit: true, includeInherited: false, typeof(System.Security.Principal.SecurityIdentifier))
            .Cast<System.Security.AccessControl.FileSystemAccessRule>();
        Assert.Contains(rules, r => r.IdentityReference == everyone && r.FileSystemRights.HasFlag(System.Security.AccessControl.FileSystemRights.ReadData));
        Assert.Equal([path], Directory.GetFiles(folder.Path)); // neither the temporary file nor the backup is left
    }

    [Fact]
    public void AppendToFile_AFolderThatTakesNoNewFiles_IsRefusedAsReadOnly()
    {
        if (!OperatingSystem.IsWindows()) return;
        using var folder = new Folder();
        byte[] original = PdfFixture.Classic();
        string path = folder.File("Shared.pdf", original);
        // The file may be changed, but no file may be created next to it.
        var directory = new DirectoryInfo(folder.Path);
        var security = directory.GetAccessControl();
        var deny = new System.Security.AccessControl.FileSystemAccessRule(
            System.Security.Principal.WindowsIdentity.GetCurrent().User!, System.Security.AccessControl.FileSystemRights.CreateFiles,
            System.Security.AccessControl.InheritanceFlags.None, System.Security.AccessControl.PropagationFlags.None,
            System.Security.AccessControl.AccessControlType.Deny);
        security.AddAccessRule(deny);
        directory.SetAccessControl(security);
        try
        {
            var e = Assert.Throws<PdfAppendException>(() => PdfAppender.AppendToFile(path, [Page()]));
            Assert.Equal(PdfAppendProblem.ReadOnly, e.Problem);
            Assert.Equal(PdfAppender.Message(PdfAppendProblem.ReadOnly, "Shared.pdf"), e.Message);
        }
        finally
        {
            security.RemoveAccessRule(deny);
            directory.SetAccessControl(security);
        }
        Assert.Equal(original, File.ReadAllBytes(path));
        Assert.Equal([path], Directory.GetFiles(folder.Path));
    }

    [Fact]
    public void AppendToFile_RefusesWithoutTouchingTheFile()
    {
        using var folder = new Folder();
        byte[] damaged = PdfFixture.Classic()[..^30];
        using var protection = new PdfProtection("pw");
        var cases = new (string Name, byte[] Bytes, PdfAppendProblem Problem)[]
        {
            ("damaged.pdf", damaged, PdfAppendProblem.Damaged),
            ("text.pdf", Encoding.ASCII.GetBytes("not a pdf"), PdfAppendProblem.NotPdf),
            ("junk.pdf", [.. Encoding.ASCII.GetBytes("junk\n"), .. PdfFixture.Classic()], PdfAppendProblem.Unsupported),
            ("locked.pdf", PdfBuilder.Make([Page()], options: new PdfWriteOptions { Protection = protection }), PdfAppendProblem.Encrypted),
        };
        foreach (var (name, bytes, problem) in cases)
        {
            string path = folder.File(name, bytes);
            var e = Assert.Throws<PdfAppendException>(() => PdfAppender.AppendToFile(path, [Page()]));
            Assert.Equal(problem, e.Problem);
            Assert.Equal(PdfAppender.Message(problem, name), e.Message);
            Assert.Equal(problem, Assert.Throws<PdfAppendException>(() => PdfAppender.Inspect(path)).Problem);
            Assert.Equal(bytes, File.ReadAllBytes(path));
        }
        Assert.Equal(cases.Length, Directory.GetFiles(folder.Path).Length);
        Assert.Equal(PdfAppendProblem.Missing,
                     Assert.Throws<PdfAppendException>(() => PdfAppender.AppendToFile(Path.Combine(folder.Path, "gone.pdf"), [Page()])).Problem);
    }

    [Fact]
    public void AppendToFile_ReadOnlyOrOpenElsewhere_IsRefused()
    {
        using var folder = new Folder();
        byte[] original = PdfFixture.Classic();
        string readOnly = folder.File("read-only.pdf", original);
        File.SetAttributes(readOnly, FileAttributes.ReadOnly);
        Assert.Equal(PdfAppendProblem.ReadOnly, Assert.Throws<PdfAppendException>(() => PdfAppender.AppendToFile(readOnly, [Page()])).Problem);

        string open = folder.File("open.pdf", original);
        using (new FileStream(open, FileMode.Open, FileAccess.Read, FileShare.Read)) // a viewer that shares reading only
        {
            var e = Assert.Throws<PdfAppendException>(() => PdfAppender.AppendToFile(open, [Page()]));
            Assert.Equal(PdfAppendProblem.InUse, e.Problem);
            Assert.Equal(PdfAppendProblem.InUse, Assert.Throws<PdfAppendException>(() => PdfAppender.Inspect(open)).Problem);
        }
        Assert.Equal(original, File.ReadAllBytes(open));
        Assert.Equal(original, File.ReadAllBytes(readOnly));
        Assert.Equal(2, Directory.GetFiles(folder.Path).Length);
    }

    [Fact]
    public void AReplacementThatFailedAfterMovingTheOriginalAside_PutsItBackOrNamesTheBackup()
    {
        using var folder = new Folder();
        byte[] original = PdfFixture.Classic();
        var cause = new IOException("Unable to move the replacement file to the file to be replaced.", unchecked((int)0x80070499));

        // Moved back: the user is asked to close the other app and try again.
        string path = Path.Combine(folder.Path, "Report.pdf");
        string backup = folder.File(".1111.pdf.bak", original);
        var back = PdfAppender.PutBack(backup, path, cause);
        Assert.Equal(PdfAppendProblem.InUse, back.Problem);
        Assert.Equal(PdfAppender.Message(PdfAppendProblem.InUse, "Report.pdf"), back.Message);
        Assert.Equal(original, File.ReadAllBytes(path));
        Assert.Equal([path], Directory.GetFiles(folder.Path));

        // Not moved back (another app holds the backup): the refusal says where the file is.
        if (!OperatingSystem.IsWindows()) return;
        string other = Path.Combine(folder.Path, "Contract.pdf");
        string held = folder.File(".2222.pdf.bak", original);
        PdfAppendException left;
        using (new FileStream(held, FileMode.Open, FileAccess.Read, FileShare.Read))
        {
            left = PdfAppender.PutBack(held, other, cause);
        }
        Assert.Equal(PdfAppendProblem.LeftAsBackup, left.Problem);
        Assert.Equal(PdfAppender.LeftAsBackupMessage("Contract.pdf", ".2222.pdf.bak"), left.Message);
        Assert.Same(cause, left.InnerException);
        Assert.False(File.Exists(other));
        Assert.Equal(original, File.ReadAllBytes(held));
    }

    [Fact]
    public void AppendToFile_Cancelled_LeavesTheFile()
    {
        using var folder = new Folder();
        byte[] original = PdfFixture.Classic();
        string path = folder.File("a.pdf", original);
        using var cts = new CancellationTokenSource();
        var e = Assert.Throws<ScanException>(() => PdfAppender.AppendToFile(path, [Page(), Page()], _ => cts.Cancel(), cts.Token));
        Assert.Equal(ScanErrorKind.Cancelled, e.Kind);
        Assert.Equal(original, File.ReadAllBytes(path));
        Assert.Equal([path], Directory.GetFiles(folder.Path));
    }

    /// <summary>
    /// PDF/A files with pages added, for veraPDF in CI next to PdfATests' samples
    /// (LAZYSCAN_PDFA_SAMPLES); without that folder they are written, read back and removed.
    /// </summary>
    [Fact]
    public void PdfA_ValidationSamples()
    {
        string? samples = Environment.GetEnvironmentVariable("LAZYSCAN_PDFA_SAMPLES");
        bool keep = !string.IsNullOrWhiteSpace(samples);
        string dir = keep ? samples! : Path.Combine(Path.GetTempPath(), $"PdfAppenderTests-{Guid.NewGuid()}");
        Directory.CreateDirectory(dir);
        try
        {
            string path = Path.Combine(dir, "pdfa-pages-added.pdf");
            PdfBuilder.WriteFile([Page(text: true)], path, options: new PdfWriteOptions { Conformance = PdfConformance.PdfA2b, Title = "Pages added" });
            Assert.True(PdfAppender.Inspect(path).KeepsPdfA);
            PdfAppender.AppendToFile(path, [Page(text: true), Page()]);
            PdfAppender.AppendToFile(path, [Page()]);
            using var document = PdfDocument.Open(path, new ParsingOptions { UseLenientParsing = false });
            Assert.Equal(4, document.NumberOfPages);
        }
        finally
        {
            if (!keep) Directory.Delete(dir, recursive: true);
        }
    }

    // MARK: - The object writer's update sections

    [Fact]
    public void ObjectWriter_UpdateTable_ListsRunsWithTheirGenerations()
    {
        using var stream = new MemoryStream();
        var w = new PdfObjectWriter(stream, 1000);
        w.WriteObject(7, "<<>>");
        w.WriteObject(2, 3, "<<>>");
        w.WriteObject(8, "<<>>");
        w.FinishUpdate("/Size 9 /Prev 500");
        Assert.Equal(
            "7 0 obj\n<<>>\nendobj\n2 3 obj\n<<>>\nendobj\n8 0 obj\n<<>>\nendobj\n" +
            "xref\n2 1\n0000001020 00003 n \n7 2\n0000001000 00000 n \n0000001040 00000 n \n" +
            "trailer\n<</Size 9 /Prev 500>>\nstartxref\n1060\n%%EOF\n", Latin1(stream.ToArray()));
    }

    [Fact]
    public void ObjectWriter_UpdateStream_ListsItself()
    {
        using var stream = new MemoryStream();
        var w = new PdfObjectWriter(stream, 0x01_0000_0000L); // past 4 GB: offsets take 5 bytes
        w.WriteObject(3, "<<>>");
        w.FinishUpdateStream(4, "/Size 5 /Prev 9");
        byte[] bytes = stream.ToArray();
        string text = Latin1(bytes);
        Assert.StartsWith("3 0 obj\n<<>>\nendobj\n4 0 obj\n<</Type /XRef /W [1 5 2] /Index [3 2] /Size 5 /Prev 9 /Length 16>>\nstream\n", text);
        int data = text.IndexOf("stream\n", StringComparison.Ordinal) + 7;
        Assert.Equal(new byte[] { 1, 1, 0, 0, 0, 0, 0, 0, 1, 1, 0, 0, 0, 20, 0, 0 }, bytes[data..(data + 16)]);
        Assert.EndsWith("\nendstream\nendobj\nstartxref\n4294967316\n%%EOF\n", text);
    }
}
