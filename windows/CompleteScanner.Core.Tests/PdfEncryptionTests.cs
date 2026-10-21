using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using CompleteScanner.Core;
using UglyToad.PdfPig;
using UglyToad.PdfPig.Exceptions;
using Xunit;

namespace CompleteScanner.Core.Tests;

// Password-protected PDFs: the standard security handler V5 R6 (AES-256) checked against known
// answers, then whole files read back with the password by PdfPig (a test-only package). Mirrored by
// Tests/CompleteScannerTests/PDFEncryptionTests.swift: the same cases and the same bytes (the pinned
// values and SHA-256 below), the files opened there with PDFKit.

public class PdfEncryptionTests
{
    // Known answers for algorithm 2.B and the file key: the PDF 2.0 (revision 6) cases of pdf.js,
    // test/unit/crypto_spec.js ("PDF20Algorithm" and "AES256 Revision 6"), Apache-2.0.
    private static readonly byte[] IsoU = Hex(
        "5EE6CD4BA663FA4CDB801155391121A4962E67B0A09CBBE9A6DFA3FD93EB5FB8" + "53F59265C6F722C6" + "BF0B105EEDD814AF");
    private static readonly byte[] IsoO = Hex(
        "58E83E36F51AF5D1897BDD48C73125D91F4A73A77F9EB04D2DA3572F275AD98D" + "8EE8A9D0CAD605B9" + "1DD0B92E0B4C8795");
    private static readonly byte[] IsoUE = Hex("79D002B5E6599C3CFD8FD41C54B4C4B1AD80DD6B2E145EBA87335F1814DFFE24");
    private static readonly byte[] IsoOE = Hex("D149E04D679BC9B5BE44DF143E5A38D205F0B280EE7C44FEFDF43E6CD0870AFB");
    private static readonly byte[] IsoPerms = Hex("6CAD0FA0EB4D86574D3ECBB5E058C937");
    private const int IsoP = -1084;
    private static readonly byte[] IsoFileKey = Hex("2ADAD527495B484F4326F88512BD3D226B4F1D383BB5D576712241D257AE16EF");

    // The same suite's "AES256 Revision 6 with SASLprep" dictionary: made with the password "SaSLprep".
    private static readonly byte[] SaslU = Latin1Bytes(
        "%98%1E%80%12%14Y%93D%0By%2F%07q%5E%CC%7B%D1%CDg%2C%5B2%DD%B7%C0%7D%C7%D5%1F5Q%23%BD%CA1%FDm%7B%B7%D1%60%29v%91%D23%E1%B4");
    private static readonly byte[] SaslO = Latin1Bytes(
        "%21%14%DF%F5%89%2A%5F%97%B6%B7%EB%F8P%02%7DY%FD%95%82%CA%BD%1C%A6T%5E%8Bq%01%FC%9D%D2%00%84z%F4%89%E8%3EX%DFq%CF%CE%F2F%A6%B2%95");
    private static readonly byte[] SaslOE = Latin1Bytes(
        "A%F1%BF%91%AA%8B%F03%D8m%CF%0B%14%19%D6%BF%8B%2AO%FAln%AAb%85%F2SB%7C%CF%FBX");
    private static readonly byte[] SaslUE = Latin1Bytes(
        "w%20v%EF%AD%EC%02%AD%C6%1B%06%DEP%DE%BE8%DD%A5%DB%C77%8E%035L%1D%FD%DD%13%83%AC%9B");
    private static readonly byte[] SaslPerms = Latin1Bytes("%0E%FE%02%22%FB5f%A68t%0Ca%11%17Jf");

    private static byte[] Hex(string hex) => Convert.FromHexString(hex);

    /// <summary>The JavaScript unescape() of a %XX-escaped Latin-1 string, as bytes.</summary>
    private static byte[] Latin1Bytes(string escaped) =>
        Encoding.Latin1.GetBytes(Regex.Replace(escaped, "%([0-9A-F]{2})", m => ((char)Convert.ToByte(m.Groups[1].Value, 16)).ToString()));

    private static byte[] Utf8(string text) => Encoding.UTF8.GetBytes(text);

    /// <summary>A random source that gives 0, 1, 2, … 255, 0, … across calls, so files come out the same.</summary>
    internal static Action<Span<byte>> Counting()
    {
        byte next = 0;
        return span =>
        {
            for (int i = 0; i < span.Length; i++) span[i] = next++;
        };
    }

    // MARK: - Algorithm 2.B and the file key (known answers)

    [Fact]
    public void Hash_UserPassword_KnownAnswer()
    {
        Assert.Equal(IsoU[..32], PdfEncryption.Hash(Utf8("user"), IsoU[32..40], []));
    }

    [Fact]
    public void Hash_OwnerPassword_IsHashedWithTheWholeU_KnownAnswer()
    {
        Assert.Equal(IsoO[..32], PdfEncryption.Hash(Utf8("owner"), IsoO[32..40], IsoU));
    }

    [Fact]
    public void FileKey_FromUEAndOE_KnownAnswer()
    {
        static byte[] Unwrap(byte[] key, byte[] wrapped)
        {
            using var aes = Aes.Create();
            aes.Key = key;
            return aes.DecryptCbc(wrapped, new byte[16], PaddingMode.None);
        }
        Assert.Equal(IsoFileKey, Unwrap(PdfEncryption.Hash(Utf8("user"), IsoU[40..48], []), IsoUE));
        Assert.Equal(IsoFileKey, Unwrap(PdfEncryption.Hash(Utf8("owner"), IsoO[40..48], IsoU), IsoOE));
    }

    [Fact]
    public void FileKeyFor_OpensTheIsoDictionary_WithEitherPassword_AndNoOther()
    {
        Assert.Equal(IsoFileKey, PdfEncryption.FileKeyFor(Utf8("user"), IsoO, IsoU, IsoOE, IsoUE));
        Assert.Equal(IsoFileKey, PdfEncryption.FileKeyFor(Utf8("owner"), IsoO, IsoU, IsoOE, IsoUE));
        Assert.Null(PdfEncryption.FileKeyFor(Utf8("wrong"), IsoO, IsoU, IsoOE, IsoUE));
        Assert.Null(PdfEncryption.FileKeyFor([], IsoO, IsoU, IsoOE, IsoUE));
        // The fixture's /P (-1084) was changed after its /Perms was made (for -4): what /Perms is there to show.
        Assert.True(PdfEncryption.PermsMatch(IsoFileKey, IsoPerms, -4));
        Assert.False(PdfEncryption.PermsMatch(IsoFileKey, IsoPerms, IsoP));
    }

    [Fact]
    public void PreparedPassword_OpensTheSaslPrepDictionary()
    {
        Assert.Equal(48, SaslU.Length);
        Assert.Equal(48, SaslO.Length);
        // "S" "ª" "SL" soft hyphen "prep": ª is "a" in compatibility form, the soft hyphen is nothing.
        byte[] prepared = PdfProtection.PreparePassword("SªSL­prep");
        Assert.Equal(Utf8("SaSLprep"), prepared);
        byte[]? key = PdfEncryption.FileKeyFor(prepared, SaslO, SaslU, SaslOE, SaslUE);
        Assert.NotNull(key);
        Assert.True(PdfEncryption.PermsMatch(key, SaslPerms, -4));
        Assert.Null(PdfEncryption.FileKeyFor(Utf8("wrong"), SaslO, SaslU, SaslOE, SaslUE));
    }

    // MARK: - Passwords

    [Fact]
    public void PreparePassword_MapsSpaces_DropsInvisibles_Normalizes_AndCutsAt127Bytes()
    {
        Assert.Equal(Utf8("a b c"), PdfProtection.PreparePassword("a b　c"));
        Assert.Equal(Utf8("xy"), PdfProtection.PreparePassword("x­‍y️"));
        Assert.Equal(Utf8("file"), PdfProtection.PreparePassword("ﬁle"));                 // the "fi" ligature
        Assert.Equal(Utf8("Çağrı"), PdfProtection.PreparePassword("Çağrı")); // composed
        Assert.Equal(Utf8("Şifre 2026"), PdfProtection.PreparePassword("Şifre 2026"));
        Assert.Equal(127, PdfProtection.PreparePassword(new string('a', 200)).Length);
        // Readers cut the bytes, not the characters, so a cut may fall inside one: "ğ" is two bytes.
        byte[] cut = PdfProtection.PreparePassword(new string('ğ', 100));
        Assert.Equal(127, cut.Length);
        Assert.Equal(Utf8(new string('ğ', 64))[..127], cut);
    }

    [Fact]
    public void DecomposePassword_IsThePreparedPassword_Decomposed_AsPdfKitPassesItOn()
    {
        // "Ş" is "S" and a combining cedilla (U+0327) once decomposed.
        Assert.Equal(Hex("53CCA7696672652032303236"), PdfProtection.DecomposePassword("Şifre 2026"));
        Assert.Equal(Utf8("C\u0327ag\u0306r\u0131"), PdfProtection.DecomposePassword("\u00C7a\u011Fr\u0131"));
        Assert.Equal(Utf8("file"), PdfProtection.DecomposePassword("\uFB01le")); // the "fi" ligature
        Assert.Equal(Utf8("a b c"), PdfProtection.DecomposePassword("a\u00A0b\u3000c"));
        Assert.Equal(Utf8("xy"), PdfProtection.DecomposePassword("x\u00AD\u200Dy\uFE0F"));
        // A Hangul syllable becomes its letters; ideographs and ASCII stay as they are.
        Assert.Equal(Hex("E18492E185A1E186ABE18480E185B3E186AF"), PdfProtection.DecomposePassword("\uD55C\uAE00"));
        Assert.Equal(PdfProtection.PreparePassword("\u5BC6\u7801"), PdfProtection.DecomposePassword("\u5BC6\u7801"));
        Assert.Equal(Utf8("pw"), PdfProtection.DecomposePassword("pw"));
        Assert.Equal(127, PdfProtection.DecomposePassword(new string('ğ', 100)).Length);
    }

    [Fact]
    public void Problem_NeedsAPassword_TypedTwiceTheSame_WithoutControlCharacters()
    {
        Assert.Null(PdfProtection.Problem("correct horse", "correct horse"));
        Assert.Null(PdfProtection.Problem("a", "a")); // weak but allowed
        Assert.Equal("Type a password.", PdfProtection.Problem("", ""));
        // Only characters that stand for nothing: the file would open without a password.
        Assert.Equal("Type a password.", PdfProtection.Problem("­‍", "­‍"));
        Assert.Equal("Passwords don't match", PdfProtection.Problem("Şifre", "Sifre"));
        Assert.Equal("A password can't contain tabs, line breaks or other control characters.", PdfProtection.Problem("a\tb", "a\tb"));
        Assert.Throws<ArgumentException>(() => new PdfProtection(""));
        Assert.Throws<ArgumentException>(() => new PdfProtection("line\nbreak"));
    }

    [Theory]
    [InlineData("", PasswordStrength.None)]
    [InlineData("abc", PasswordStrength.Weak)]
    [InlineData("Password123!", PasswordStrength.Weak)]   // a well-known word with digits after it
    [InlineData("12345678901234", PasswordStrength.Weak)] // digits only
    [InlineData("aaaaaaaaaaaaaaaaaaaa", PasswordStrength.Weak)]
    [InlineData("kediler", PasswordStrength.Weak)]        // 7 characters
    [InlineData("kedilerim", PasswordStrength.Fair)]      // 9 lowercase letters: 42 bits
    [InlineData("tavukpilavci", PasswordStrength.Fair)]   // 12: 56 bits
    [InlineData("tavuk-pilav9", PasswordStrength.Strong)] // 12 of three kinds: 73 bits
    [InlineData("Uzun bir cümle, üç kelime!", PasswordStrength.Strong)]
    [InlineData("correct horse battery staple", PasswordStrength.Strong)]
    public void StrengthOf_GuessesHowHardAPasswordIsToGuess(string password, PasswordStrength expected)
    {
        Assert.Equal(expected, PdfProtection.StrengthOf(password));
        Assert.Equal(expected == PasswordStrength.None, PdfProtection.StrengthHint(expected).Length == 0);
    }

    [Fact]
    public void StrengthLabel_IsShort_AndTheBarFillsWithTheStrength()
    {
        Assert.Equal("", PdfProtection.StrengthLabel(PasswordStrength.None));
        Assert.Equal("Weak · use 12+ characters", PdfProtection.StrengthLabel(PasswordStrength.Weak));
        Assert.Equal("Strong", PdfProtection.StrengthLabel(PasswordStrength.Strong));
        foreach (var strength in Enum.GetValues<PasswordStrength>())
        {
            // A few words on screen; the full advice stays the tooltip.
            Assert.True(PdfProtection.StrengthLabel(strength).Split(' ').Count(w => w.Any(char.IsLetterOrDigit)) <= 5);
        }
        Assert.Equal([0, 1, 2, 4], new[] { PasswordStrength.None, PasswordStrength.Weak, PasswordStrength.Fair, PasswordStrength.Strong }
            .Select(PdfProtection.StrengthSegments));
    }

    [Fact]
    public void PasswordAndArchival_NameEachOtherInTheirShortReasons()
    {
        Assert.Equal("Not with PDF/A", PdfProtection.NotWithArchivalReason);
        Assert.Equal("Not with a password", PdfA.NotWithPasswordReason);
        // The exception PdfBuilder throws keeps its full sentence.
        Assert.Equal("PDF/A can't be password-protected.", PdfA.CannotProtectNote);
    }

    [Fact]
    public void Permissions_AllowEverything_OrClearThePrintAndCopyBits()
    {
        Assert.Equal(-4, PdfProtection.Permissions(allowPrinting: true, allowCopying: true));
        Assert.Equal(-4 & ~4 & ~2048, PdfProtection.Permissions(allowPrinting: false, allowCopying: true));
        Assert.Equal(-4 & ~16, PdfProtection.Permissions(allowPrinting: true, allowCopying: false));
        Assert.Equal(-2072, PdfProtection.Permissions(allowPrinting: false, allowCopying: false));
        using var protection = new PdfProtection("pw", allowPrinting: false);
        Assert.Equal(-2056, protection.PermissionFlags);
    }

    [Fact]
    public void Protection_WipesItsPasswordWhenDisposed()
    {
        var protection = new PdfProtection("gizli");
        Assert.Equal(Utf8("gizli"), protection.Password.ToArray());
        protection.Dispose();
        Assert.Throws<ObjectDisposedException>(() => protection.Password.Length);
        Assert.Throws<ObjectDisposedException>(() => PdfBuilder.Make([Page()], options: Protected(protection)));
    }

    // MARK: - The security handler's values

    [Fact]
    public void Create_GivenItsRandomBytes_MakesTheSameValues_ThatOpenWithThePassword()
    {
        using var protection = new PdfProtection("Şifre 2026");
        using var encryption = PdfEncryption.Create(protection, Counting());
        // The random bytes are taken in order: file key 0-31, user salts 32-47, owner password 48-79,
        // owner salts 80-95, the /Perms filler 96-99.
        byte[] fileKey = [.. Enumerable.Range(0, 32).Select(i => (byte)i)];
        Assert.Equal(Enumerable.Range(32, 16).Select(i => (byte)i), encryption.U[32..]);
        Assert.Equal(Enumerable.Range(80, 16).Select(i => (byte)i), encryption.O[32..]);
        Assert.Equal((48, 48, 32, 32, 16, -4), (encryption.U.Length, encryption.O.Length, encryption.UE.Length,
                                                encryption.OE.Length, encryption.Perms.Length, encryption.P));
        Assert.Equal(fileKey, PdfEncryption.FileKeyFor(PdfProtection.PreparePassword("Şifre 2026"),
                                                        encryption.O, encryption.U, encryption.OE, encryption.UE));
        Assert.Null(PdfEncryption.FileKeyFor(PdfProtection.PreparePassword("Sifre 2026"),
                                             encryption.O, encryption.U, encryption.OE, encryption.UE));
        // "Ş" decomposes, so the owner password is the password as PDFKit passes it on; the random
        // bytes 48-79 are still taken, and open nothing.
        byte[] decomposed = PdfProtection.DecomposePassword("Şifre 2026");
        Assert.Equal(encryption.O[..32], PdfEncryption.Hash(decomposed, encryption.O[32..40], encryption.U));
        Assert.Equal(fileKey, PdfEncryption.FileKeyFor(decomposed, encryption.O, encryption.U, encryption.OE, encryption.UE));
        Assert.Null(PdfEncryption.FileKeyFor([.. Enumerable.Range(48, 32).Select(i => (byte)i)],
                                             encryption.O, encryption.U, encryption.OE, encryption.UE));
        Assert.True(PdfEncryption.PermsMatch(fileKey, encryption.Perms, -4));
        using var aes = Aes.Create();
        aes.Key = fileKey;
        Assert.Equal(Hex("FCFFFFFFFFFFFFFF5461646260616263"), aes.DecryptEcb(encryption.Perms, PaddingMode.None));
        // Pinned for the Mac's port: the same password and bytes give the same values.
        Assert.Equal(Golden.U, Convert.ToHexString(encryption.U));
        Assert.Equal(Golden.O, Convert.ToHexString(encryption.O));
        Assert.Equal(Golden.UE, Convert.ToHexString(encryption.UE));
        Assert.Equal(Golden.OE, Convert.ToHexString(encryption.OE));
        Assert.Equal(Golden.Perms, Convert.ToHexString(encryption.Perms));
    }

    /// <summary>The values for "Şifre 2026" and the counting bytes (also computed by a separate implementation of algorithm 2.B).</summary>
    private static class Golden
    {
        public const string U = "69E56736D0DC99ADAB81C8C974CB117CD64C8EACD3B03BA79DAA6F37ACA51290202122232425262728292A2B2C2D2E2F";
        public const string O = "5FBC1E5693C9182C7FF0F1F08FCC86C0151769BFD5E52B6BB85C82CA6947FE31505152535455565758595A5B5C5D5E5F";
        public const string UE = "5939E7CB89B321D9B11D24CF5015E35106ED748026E84F76FE7B2542DDEA6E0D";
        public const string OE = "C111D7C0AD5019A4F5F79A04440B045F021A190568483E674680507BF74F1A2C";
        public const string Perms = "A23A07C7EAEAB688EBF15FA2C4DBCB0E";
    }

    [Fact]
    public void Create_KeepsTheRandomOwnerPassword_WhenThePasswordDoesNotDecompose()
    {
        using var protection = new PdfProtection("Gizli 2026");
        using var encryption = PdfEncryption.Create(protection, Counting());
        byte[] fileKey = [.. Enumerable.Range(0, 32).Select(i => (byte)i)];
        // The owner password is the random bytes 48-79, known to nobody.
        byte[] owner = [.. Enumerable.Range(48, 32).Select(i => (byte)i)];
        Assert.Equal(encryption.O[..32], PdfEncryption.Hash(owner, encryption.O[32..40], encryption.U));
        Assert.Equal(fileKey, PdfEncryption.FileKeyFor(owner, encryption.O, encryption.U, encryption.OE, encryption.UE));
        Assert.Equal(fileKey, PdfEncryption.FileKeyFor(Utf8("Gizli 2026"), encryption.O, encryption.U, encryption.OE, encryption.UE));
    }

    [Fact]
    public void Encrypt_PutsARandomIvFirst_PadsToTheBlock_AndDecryptsBack()
    {
        using var protection = new PdfProtection("pw");
        var random = Counting();
        using var encryption = PdfEncryption.Create(protection, random);
        byte[] key = [.. Enumerable.Range(0, 32).Select(i => (byte)i)];
        foreach (int length in new[] { 0, 1, 15, 16, 17, 1000 })
        {
            byte[] data = [.. Enumerable.Range(0, length).Select(i => (byte)(i * 7))];
            byte[] stored = encryption.Encrypt(data);
            Assert.Equal(16 + (length / 16 + 1) * 16, stored.Length);
            Assert.Equal(data, PdfEncryption.Decrypt(key, stored));
        }
        // Each string or stream gets the next 16 random bytes as its IV.
        Assert.NotEqual(encryption.Encrypt("abc"u8)[..16], encryption.Encrypt("abc"u8)[..16]);
    }

    [Fact]
    public void Dictionary_IsTheStandardHandlerV5R6()
    {
        using var protection = new PdfProtection("pw", allowCopying: false);
        using var encryption = PdfEncryption.Create(protection, Counting());
        Assert.Equal("<</Filter /Standard /V 5 /R 6 /Length 256 " +
                     "/CF <</StdCF <</CFM /AESV3 /AuthEvent /DocOpen /Length 32>>>> /StmF /StdCF /StrF /StdCF " +
                     $"/O <{Convert.ToHexString(encryption.O)}> /U <{Convert.ToHexString(encryption.U)}> " +
                     $"/OE <{Convert.ToHexString(encryption.OE)}> /UE <{Convert.ToHexString(encryption.UE)}> " +
                     $"/Perms <{Convert.ToHexString(encryption.Perms)}> /P -20 /EncryptMetadata true>>",
                     encryption.Dictionary);
    }

    // MARK: - Protected files

    private static readonly byte[] Id = [.. Enumerable.Range(0xB0, 16).Select(i => (byte)i)];
    private const string IdHex = "B0B1B2B3B4B5B6B7B8B9BABBBCBDBEBF";

    private static PdfWriteOptions Protected(PdfProtection protection) => new()
    {
        Protection = protection,
        DocumentId = Id,
        Random = Counting(),
    };

    private static PdfPageInput Page(IReadOnlyList<OcrLine>? lines = null) =>
        new(PdfBuilderTests.TinyJpeg, 2550, 3300, 300, lines); // US Letter at 300 dpi

    private static readonly OcrLine Line = new("Gizli belge — Çağrı Işık", new RectD(0.1, 0.8, 0.6, 0.04), 0.9f);

    private static string Latin1(byte[] pdf) => Encoding.Latin1.GetString(pdf);

    [Fact]
    public void Protected_HeaderCatalogNumberingAndTrailer()
    {
        using var protection = new PdfProtection("Şifre 2026");
        string text = Latin1(PdfBuilder.Make([Page([Line]), Page()], options: Protected(protection)));
        Assert.StartsWith("%PDF-1.7\n%", text);
        Assert.EndsWith("%%EOF\n", text);
        // 1 Catalog, 2 Pages, 3-8 the font, 9 Encrypt, then three objects a page.
        Assert.Contains("1 0 obj\n<</Type /Catalog /Pages 2 0 R /Extensions <</ADBE <</BaseVersion /1.7 /ExtensionLevel 8>>>>>>\nendobj\n", text);
        Assert.Contains("2 0 obj\n<</Type /Pages /Kids [10 0 R 13 0 R] /Count 2>>", text);
        Assert.Contains("9 0 obj\n<</Filter /Standard /V 5 /R 6 /Length 256 /CF <</StdCF <</CFM /AESV3", text);
        Assert.Contains($"trailer\n<</Size 16 /Root 1 0 R /Encrypt 9 0 R /ID [<{IdHex}> <{IdHex}>]>>", text);
        // The font's strings are encrypted: no "(Adobe)" in the open.
        Assert.DoesNotContain("(Adobe)", text);
        Assert.Matches(@"/CIDSystemInfo <</Registry <[0-9A-F]{64}> /Ordering <[0-9A-F]{64}> /Supplement 0>>", text);
        // Nothing of the page or its text is in the open.
        Assert.DoesNotContain("BT\n3 Tr", text);
        Assert.DoesNotContain("beginbfrange", text);
        Assert.DoesNotContain(Latin1(PdfBuilderTests.TinyJpeg[..64]), text);
        AssertXrefPointsAtEveryObject(text, 15);
    }

    [Fact]
    public void Protected_StreamsAndStrings_DecryptWithTheKeyThePasswordOpens()
    {
        using var protection = new PdfProtection("Şifre 2026");
        byte[] pdf = PdfBuilder.Make([Page([Line])], options: Protected(protection));
        string text = Latin1(pdf);
        byte[] Value(string key) => Hex(Regex.Match(text, $"/{key} <([0-9A-F]+)>").Groups[1].Value);
        byte[]? fileKey = PdfEncryption.FileKeyFor(PdfProtection.PreparePassword("Şifre 2026"),
                                                   Value("O"), Value("U"), Value("OE"), Value("UE"));
        Assert.NotNull(fileKey);
        Assert.True(PdfEncryption.PermsMatch(fileKey, Value("Perms"), -4));
        byte[] Stream(int number)
        {
            var header = Regex.Match(text, $"\n{number} 0 obj\n<<[^\n]*/Length (\\d+)>>\nstream\n");
            Assert.True(header.Success, $"stream {number}");
            return pdf.AsSpan(header.Index + header.Length, int.Parse(header.Groups[1].Value)).ToArray();
        }
        // 9 Encrypt, 10 Page, 11 Image, 12 Contents.
        Assert.Equal(PdfBuilderTests.TinyJpeg, PdfEncryption.Decrypt(fileKey, Stream(11)));
        Assert.StartsWith("q\n612 0 0 792 0 0 cm\n/Im0 Do\nQ\nBT\n3 Tr\n", Encoding.ASCII.GetString(PdfEncryption.Decrypt(fileKey, Stream(12))));
        Assert.Equal(GlyphlessFont.Program, PdfEncryption.Decrypt(fileKey, Stream(6)));
        // The font program keeps its own length beside the encrypted stream's.
        Assert.Contains($"6 0 obj\n<</Length1 {GlyphlessFont.Program.Length} /Length {16 + (GlyphlessFont.Program.Length / 16 + 1) * 16}>>", text);
        var registry = Regex.Match(text, @"/Registry <([0-9A-F]+)> /Ordering <([0-9A-F]+)>");
        Assert.Equal("Adobe", Encoding.ASCII.GetString(PdfEncryption.Decrypt(fileKey, Hex(registry.Groups[1].Value))));
        Assert.Equal("Identity", Encoding.ASCII.GetString(PdfEncryption.Decrypt(fileKey, Hex(registry.Groups[2].Value))));
    }

    [Fact]
    public void Protected_OpensInAPdfReader_WithThePasswordOnly()
    {
        using var protection = new PdfProtection("Şifre 2026");
        byte[] pdf = PdfBuilder.Make([Page([Line]), Page()], options: new PdfWriteOptions { Protection = protection });
        using (var document = PdfDocument.Open(pdf, new ParsingOptions { Password = "Şifre 2026" }))
        {
            Assert.True(document.IsEncrypted);
            Assert.Equal(2, document.NumberOfPages);
            Assert.Equal(Line.Text, document.GetPage(1).Text);
            Assert.Equal(612, document.GetPage(2).Width, 3);
        }
        Assert.ThrowsAny<PdfDocumentEncryptedException>(() => PdfDocument.Open(pdf, new ParsingOptions { Password = "Sifre 2026" }).Dispose());
        Assert.ThrowsAny<PdfDocumentEncryptedException>(() => PdfDocument.Open(pdf).Dispose());
    }

    [Fact]
    public void Protected_NoPrintingOrCopying_IsWrittenInP()
    {
        using var protection = new PdfProtection("pw", allowPrinting: false, allowCopying: false);
        byte[] pdf = PdfBuilder.Make([Page()], options: Protected(protection));
        Assert.Contains("/P -2072 /EncryptMetadata true>>", Latin1(pdf));
        using var document = PdfDocument.Open(pdf, new ParsingOptions { Password = "pw" });
        Assert.Equal(1, document.NumberOfPages);
    }

    [Fact]
    public void Protected_EachFileGetsItsOwnKey()
    {
        using var protection = new PdfProtection("pw");
        var options = new PdfWriteOptions { Protection = protection };
        string first = Latin1(PdfBuilder.Make([Page()], options: options));
        string second = Latin1(PdfBuilder.Make([Page()], options: options));
        string U(string text) => Regex.Match(text, "/U <([0-9A-F]+)>").Groups[1].Value;
        string Id(string text) => Regex.Match(text, @"/ID \[<([0-9A-F]{32})> <\1>\]").Groups[1].Value;
        Assert.NotEqual(U(first), U(second));
        Assert.NotEqual(Id(first), Id(second));
        Assert.Equal(32, Id(first).Length);
    }

    [Fact]
    public void Protected_AndArchival_AreRefused()
    {
        using var protection = new PdfProtection("pw");
        var both = new PdfWriteOptions { Conformance = PdfConformance.PdfA2b, Protection = protection };
        var e = Assert.Throws<ArgumentException>(() => PdfBuilder.Make([Page()], options: both));
        Assert.StartsWith(PdfA.CannotProtectNote, e.Message);
    }

    [Fact]
    public void WriteOptions_FollowThePasswordSetting()
    {
        using var protection = new PdfProtection("pw");
        var output = new OutputOptions();
        Assert.Null(PdfWriteOptions.For(output, "Scan", protection).Protection); // the option is off
        output.Protect = true;
        Assert.Throws<ArgumentNullException>(() => PdfWriteOptions.For(output, "Scan"));
        var options = PdfWriteOptions.For(output, "Scan", protection);
        Assert.Equal((PdfConformance.Standard, true, "Scan"), (options.Conformance, options.IsProtected, options.Title));
        Assert.Same(protection, options.Protection);
        // A settings file with both switches on gets the password, never an open PDF/A file.
        output.Archival = true;
        options = PdfWriteOptions.For(output, "Scan", protection);
        Assert.Equal((PdfConformance.Standard, true), (options.Conformance, options.IsProtected));
        Assert.False(PdfWriteOptions.Standard.IsProtected);
    }

    [Fact]
    public void Protected_GoldenBytes()
    {
        // One Letter page with a Turkish line, its key, salts and IVs from Counting(): the Mac's
        // writer port must match.
        using var protection = new PdfProtection("Şifre 2026");
        byte[] pdf = PdfBuilder.Make([Page([Line])], options: Protected(protection));
        Assert.Equal(10030, pdf.Length);
        Assert.Equal("CFA0C44FAC59790215E53E6D3D7AD08467844D2FCF53CD6DD87875459AEFD2B1", Convert.ToHexString(SHA256.HashData(pdf)));
    }

    [Fact]
    public void WriteNewFile_WritesAProtectedFile()
    {
        string dir = Path.Combine(Path.GetTempPath(), $"PdfEncryptionTests-{Guid.NewGuid()}");
        Directory.CreateDirectory(dir);
        try
        {
            using var protection = new PdfProtection("Şifre 2026");
            string path = Path.Combine(dir, "Gizli.pdf");
            string written = PdfBuilder.WriteNewFile([Page([Line])], path, options: new PdfWriteOptions { Protection = protection, Title = "Gizli" });
            Assert.Equal(path, written);
            Assert.Equal([path], Directory.GetFiles(dir));
            using var document = PdfDocument.Open(path, new ParsingOptions { Password = "Şifre 2026" });
            Assert.Equal(Line.Text, document.GetPage(1).Text);
        }
        finally
        {
            Directory.Delete(dir, recursive: true);
        }
    }

    // MARK: - Helpers

    /// <summary>Every xref entry points at its "n 0 obj"; the table has <paramref name="objects"/> objects.</summary>
    private static void AssertXrefPointsAtEveryObject(string text, int objects)
    {
        int startxref = text.LastIndexOf("startxref\n", StringComparison.Ordinal) + "startxref\n".Length;
        int xref = int.Parse(text[startxref..text.IndexOf('\n', startxref)]);
        Assert.StartsWith($"xref\n0 {objects + 1}\n0000000000 65535 f \n", text[xref..]);
        string[] entries = text[xref..].Split('\n')[3..(3 + objects)];
        for (int n = 1; n <= objects; n++)
        {
            int offset = int.Parse(entries[n - 1][..10]);
            Assert.StartsWith($"{n} 0 obj\n", text[offset..]);
        }
    }
}
