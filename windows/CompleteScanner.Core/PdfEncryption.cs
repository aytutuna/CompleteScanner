using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text;

namespace CompleteScanner.Core;

/// <summary>How hard a password looks to guess (<see cref="PdfProtection.StrengthOf"/>). The first member is the default.</summary>
public enum PasswordStrength
{
    /// <summary>No password typed yet.</summary>
    None,
    Weak,
    Fair,
    Strong,
}

/// <summary>
/// The password a PDF is protected with and what a PDF app may let its reader do once the file is
/// open. Made at save time from what the user typed and used for that save only: the password is
/// never stored (settings keep only <see cref="OutputOptions.Protect"/>), and <see cref="Dispose"/>
/// wipes its prepared bytes. The texts of the password option and its dialog are here too.
/// </summary>
public sealed class PdfProtection : IDisposable
{
    /// <summary>A password is at most this many bytes once prepared; readers cut a longer one the same way.</summary>
    public const int MaxPasswordBytes = 127;

    /// <summary>The password switch in the inspector's Archive &amp; password section.</summary>
    public const string OptionLabel = "Require a password";

    /// <summary>What the switch does, on hover.</summary>
    public const string OptionHint = "PDFs open only with the password. You type it when saving.";

    /// <summary>What the switch does, for screen readers: the hover text with what can't be undone.</summary>
    public const string OptionHelp =
        "Saved PDFs open only with a password. You type it each time you save: it is never stored, and a forgotten password can't be recovered.";

    /// <summary>Why the switch is greyed out while archival PDF (PDF/A) is on, shown next to it.</summary>
    public const string NotWithArchivalReason = "Not with PDF/A";

    /// <summary>The dialog's title and heading.</summary>
    public const string DialogTitle = "Set a PDF password";

    /// <summary>
    /// The warning the dialog shows under its heading: what can't be undone, and that it applies to
    /// every save from now on.
    /// </summary>
    public const string DialogMessage = "It can't be recovered if forgotten. Every PDF you save now gets it.";

    /// <summary>The dialog's whole explanation, for screen readers.</summary>
    public const string DialogHelp =
        "Anyone who opens the file will need this password. It isn't saved anywhere, and it can't be recovered if it's forgotten. Every PDF saved now gets it.";

    /// <summary>The permissions are requests that PDF apps honor, not locks; the dialog says so (on hover and for screen readers).</summary>
    public const string PermissionsNote =
        "Most PDF apps respect these choices, but they are a request, not a lock: someone with the password can get around them with other software.";

    /// <summary>The line under the permissions: short, and always shown, so they are not taken for a lock.</summary>
    public const string PermissionsShortNote = "Some apps ignore these settings.";

    /// <summary>The status when a save that needs a password got none (the dialog was cancelled).</summary>
    public const string NotSavedMessage = "Not saved: no password was given for the protected PDF.";

    /// <summary>The status when pages saved as they were scanned got no password: they wait in the queue.</summary>
    public static string KeptInQueueMessage(int pages) =>
        $"Not saved: no password was given for the protected PDF. The {(pages == 1 ? "page is" : $"{pages} pages are")} in the queue: save with a password, or turn the password off.";

    private readonly byte[] _password;
    private readonly byte[] _decomposed;
    private bool _disposed;

    /// <param name="password">What the user typed; it must pass <see cref="Problem"/> (typed twice the same).</param>
    /// <param name="allowPrinting">PDF apps may print the file.</param>
    /// <param name="allowCopying">PDF apps may copy its text and images.</param>
    public PdfProtection(string password, bool allowPrinting = true, bool allowCopying = true)
    {
        ArgumentNullException.ThrowIfNull(password);
        if (Problem(password, password) is { } problem) throw new ArgumentException(problem, nameof(password));
        _password = PreparePassword(password);
        _decomposed = DecomposePassword(password);
        AllowPrinting = allowPrinting;
        AllowCopying = allowCopying;
    }

    public bool AllowPrinting { get; }

    public bool AllowCopying { get; }

    /// <summary>The file's /P value (<see cref="Permissions"/>).</summary>
    public int PermissionFlags => Permissions(AllowPrinting, AllowCopying);

    /// <summary>The prepared password (<see cref="PreparePassword"/>); throws once disposed.</summary>
    internal ReadOnlySpan<byte> Password
    {
        get
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            return _password;
        }
    }

    /// <summary>The password decomposed (<see cref="DecomposePassword"/>); throws once disposed.</summary>
    internal ReadOnlySpan<byte> DecomposedPassword
    {
        get
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            return _decomposed;
        }
    }

    /// <summary>Wipes the prepared password; the protection can't be used after.</summary>
    public void Dispose()
    {
        CryptographicOperations.ZeroMemory(_password);
        CryptographicOperations.ZeroMemory(_decomposed);
        _disposed = true;
    }

    /// <summary>
    /// The /P value: -4 (every bit an app checks set: print, change, copy, notes, forms, extract
    /// for accessibility, assemble, print in high quality; bits 1-2 clear), with bits 3 and 12
    /// cleared when printing is not allowed and bit 5 when copying is not. Bit 10 (extracting for
    /// accessibility) stays set, as PDF 2.0 asks.
    /// </summary>
    public static int Permissions(bool allowPrinting, bool allowCopying)
    {
        int p = -4;
        if (!allowPrinting) p &= ~((1 << 2) | (1 << 11));
        if (!allowCopying) p &= ~(1 << 4);
        return p;
    }

    /// <summary>
    /// The bytes a typed password stands for, as PDF 2.0 prepares it (SASLprep, RFC 4013): spaces
    /// other than U+0020 become U+0020, characters that are "commonly mapped to nothing" (soft
    /// hyphen, zero-width joiners, variation selectors, ...) are dropped, the rest is NFKC
    /// normalized, encoded as UTF-8 and cut to <see cref="MaxPasswordBytes"/> bytes. SASLprep's
    /// prohibited characters are refused before this by <see cref="Problem"/> (control characters)
    /// or are kept as they are.
    /// </summary>
    public static byte[] PreparePassword(string password) =>
        Utf8Cut(Mapped(password).Normalize(NormalizationForm.FormKC));

    /// <summary>
    /// The bytes the Mac's PDFKit makes of a typed password (<c>PDFDocument.unlock</c>, and so
    /// Preview and the Mac app): the password with <see cref="PreparePassword"/>'s mappings,
    /// decomposed (NFKD) rather than composed, in UTF-8, cut at <see cref="MaxPasswordBytes"/>
    /// bytes. The same bytes as the prepared password unless it has a character that decomposes
    /// (an accented letter, a Hangul syllable, ...).
    /// </summary>
    public static byte[] DecomposePassword(string password) =>
        Utf8Cut(Mapped(password).Normalize(NormalizationForm.FormKD));

    /// <summary>SASLprep's mappings: other spaces to U+0020, the characters mapped to nothing dropped.</summary>
    private static string Mapped(string password)
    {
        var mapped = new StringBuilder(password.Length);
        foreach (var rune in password.EnumerateRunes())
        {
            int c = rune.Value;
            if (IsNonAsciiSpace(c)) mapped.Append(' ');
            else if (!MapsToNothing(c)) mapped.Append(rune.ToString());
        }
        return mapped.ToString();
    }

    /// <summary><paramref name="text"/> in UTF-8, cut at <see cref="MaxPasswordBytes"/> bytes.</summary>
    private static byte[] Utf8Cut(string text)
    {
        byte[] utf8 = Encoding.UTF8.GetBytes(text);
        if (utf8.Length <= MaxPasswordBytes) return utf8;
        byte[] cut = utf8[..MaxPasswordBytes];
        CryptographicOperations.ZeroMemory(utf8);
        return cut;
    }

    private static bool IsNonAsciiSpace(int c) =>
        c is 0x00A0 or 0x1680 or (>= 0x2000 and <= 0x200B) or 0x202F or 0x205F or 0x3000;

    private static bool MapsToNothing(int c) =>
        c is 0x00AD or 0x034F or 0x1806 or (>= 0x180B and <= 0x180D) or 0x200C or 0x200D or 0x2060
            or (>= 0xFE00 and <= 0xFE0F) or 0xFEFF;

    /// <summary>
    /// Why a password typed in the dialog can't be used (null when it can): nothing typed (or
    /// only characters that stand for nothing), a control character, or the second typing
    /// differing from the first. A weak password is allowed; <see cref="StrengthOf"/> says so.
    /// </summary>
    public static string? Problem(string password, string confirmation)
    {
        if (password.Length == 0) return "Type a password.";
        if (password.Any(char.IsControl)) return "A password can't contain tabs, line breaks or other control characters.";
        byte[] prepared = PreparePassword(password);
        bool empty = prepared.Length == 0;
        CryptographicOperations.ZeroMemory(prepared);
        if (empty) return "Type a password.";
        if (!string.Equals(password, confirmation, StringComparison.Ordinal)) return "Passwords don't match";
        return null;
    }

    private static readonly HashSet<string> CommonPasswords = new(StringComparer.Ordinal)
    {
        "password", "passw0rd", "qwerty", "qwertyuiop", "azerty", "asdfgh", "asdfghjkl", "letmein",
        "welcome", "admin", "iloveyou", "monkey", "dragon", "sunshine", "princess", "football",
        "baseball", "master", "secret", "abc", "abcdef", "abcdefgh", "abcd", "test", "login",
    };

    /// <summary>
    /// A rough guess of how hard <paramref name="password"/> is to guess, for the dialog's hint: its
    /// length in characters times the bits per character of the kinds of characters it uses
    /// (lowercase 26, uppercase 26, digits 10, ASCII symbols and space 33, anything else 100).
    /// Under 8 characters, under 40 bits, a well-known password (with digits or symbols after it)
    /// or one or two different characters is weak; under 64 bits fair; else strong.
    /// </summary>
    public static PasswordStrength StrengthOf(string password)
    {
        if (password.Length == 0) return PasswordStrength.None;
        bool lower = false, upper = false, digit = false, symbol = false, other = false;
        var distinct = new HashSet<int>();
        int length = 0;
        foreach (var rune in password.EnumerateRunes())
        {
            length++;
            distinct.Add(rune.Value);
            int c = rune.Value;
            if (c is >= 'a' and <= 'z') lower = true;
            else if (c is >= 'A' and <= 'Z') upper = true;
            else if (c is >= '0' and <= '9') digit = true;
            else if (c is >= 0x20 and < 0x7F) symbol = true;
            else other = true;
        }
        int pool = (lower ? 26 : 0) + (upper ? 26 : 0) + (digit ? 10 : 0) + (symbol ? 33 : 0) + (other ? 100 : 0);
        double bits = length * Math.Log2(Math.Max(pool, 2));
        string core = password.ToLowerInvariant().TrimEnd("0123456789!@#$%^&*()-_=+.?, ".ToCharArray());
        if (length < 8 || bits < 40 || distinct.Count <= 2 || CommonPasswords.Contains(core)
            || core.All(char.IsDigit)) return PasswordStrength.Weak;
        return bits < 64 ? PasswordStrength.Fair : PasswordStrength.Strong;
    }

    /// <summary>The dialog's short line next to the strength bar ("" when nothing is typed).</summary>
    public static string StrengthLabel(PasswordStrength strength) => strength switch
    {
        PasswordStrength.Weak => "Weak · use 12+ characters",
        PasswordStrength.Fair => "Fair · longer is safer",
        PasswordStrength.Strong => "Strong",
        _ => "",
    };

    /// <summary>How many of the strength bar's four segments are filled.</summary>
    public static int StrengthSegments(PasswordStrength strength) => strength switch
    {
        PasswordStrength.Weak => 1,
        PasswordStrength.Fair => 2,
        PasswordStrength.Strong => 4,
        _ => 0,
    };

    /// <summary>The full advice about a password's strength, on hover and for screen readers ("" when nothing is typed).</summary>
    public static string StrengthHint(PasswordStrength strength) => strength switch
    {
        PasswordStrength.Weak => "Weak: easy to guess. Longer is stronger: use 12 or more characters, or a few unrelated words.",
        PasswordStrength.Fair => "Fair. A few more characters, or another word, would make it much harder to guess.",
        PasswordStrength.Strong => "Strong.",
        _ => "",
    };
}

/// <summary>
/// The standard security handler of PDF 2.0 (ISO 32000-2, 7.6.4) at its current level: V 5,
/// R 6, AES-256. One instance encrypts one file: its random 32-byte file key encrypts every
/// string and stream (AES-256-CBC, PKCS#7 padding, a random 16-byte IV before the data), and the
/// /U, /UE, /O, /OE and /Perms values let a PDF app check the password and recover the key
/// (algorithms 8, 9 and 10, with the hash of algorithm 2.B). The owner password is 32 random
/// bytes nobody knows, so the permissions apply to everyone who opens the file; but when the
/// password has a character that decomposes, it is the password as Apple's PDFKit passes it on
/// (<see cref="PdfProtection.DecomposePassword"/>), as PDFKit tries no other form: PDFKit then
/// opens the file as its owner, without the permissions. Only System.Security.Cryptography is used. <see cref="Dispose"/> wipes the file key.
/// </summary>
public sealed class PdfEncryption : IDisposable
{
    /// <summary>The bytes the random source gives, in this order: file key, user validation and
    /// key salts, owner password, owner validation and key salts, the /Perms filler; then 16 per IV.</summary>
    public const int FileKeyLength = 32, SaltLength = 8, OwnerPasswordLength = 32, PermsRandomLength = 4, IvLength = 16;

    private readonly byte[] _fileKey;
    private readonly Action<Span<byte>> _random;
    private bool _disposed;

    private PdfEncryption(byte[] fileKey, Action<Span<byte>> random, int permissions,
                          byte[] o, byte[] u, byte[] oe, byte[] ue, byte[] perms)
    {
        _fileKey = fileKey;
        _random = random;
        P = permissions;
        O = o;
        U = u;
        OE = oe;
        UE = ue;
        Perms = perms;
    }

    /// <summary>The permissions (/P).</summary>
    public int P { get; }

    /// <summary>/O: 48 bytes, the owner password's hash and its validation and key salts.</summary>
    public byte[] O { get; }

    /// <summary>/U: 48 bytes, the user password's hash and its validation and key salts.</summary>
    public byte[] U { get; }

    /// <summary>/OE: the file key encrypted with a key made from the owner password (32 bytes).</summary>
    public byte[] OE { get; }

    /// <summary>/UE: the file key encrypted with a key made from the user password (32 bytes).</summary>
    public byte[] UE { get; }

    /// <summary>/Perms: the permissions encrypted with the file key, so a changed /P is noticed (16 bytes).</summary>
    public byte[] Perms { get; }

    /// <summary>
    /// The encryption of one file protected by <paramref name="protection"/>. Its keys, salts and
    /// IVs come from <paramref name="random"/> (null: the system's cryptographic random generator;
    /// tests give fixed bytes, in the order of <see cref="FileKeyLength"/>'s summary).
    /// </summary>
    public static PdfEncryption Create(PdfProtection protection, Action<Span<byte>>? random = null)
    {
        random ??= RandomNumberGenerator.Fill;
        byte[] fileKey = new byte[FileKeyLength];
        random(fileKey);
        byte[] userValidationSalt = RandomBytes(random, SaltLength), userKeySalt = RandomBytes(random, SaltLength);
        byte[] ownerPassword = RandomBytes(random, OwnerPasswordLength);
        byte[] ownerValidationSalt = RandomBytes(random, SaltLength), ownerKeySalt = RandomBytes(random, SaltLength);
        byte[] permsRandom = RandomBytes(random, PermsRandomLength);
        try
        {
            ReadOnlySpan<byte> decomposed = protection.DecomposedPassword;
            ReadOnlySpan<byte> owner = decomposed.SequenceEqual(protection.Password) ? ownerPassword : decomposed;
            return Create(protection.Password, owner, fileKey, userValidationSalt, userKeySalt,
                          ownerValidationSalt, ownerKeySalt, protection.PermissionFlags, permsRandom, random);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(ownerPassword);
        }
    }

    private static byte[] RandomBytes(Action<Span<byte>> random, int length)
    {
        byte[] bytes = new byte[length];
        random(bytes);
        return bytes;
    }

    /// <summary>The same with every value given (algorithms 8, 9 and 10); <paramref name="fileKey"/> is kept, not copied.</summary>
    internal static PdfEncryption Create(ReadOnlySpan<byte> userPassword, ReadOnlySpan<byte> ownerPassword, byte[] fileKey,
                                         ReadOnlySpan<byte> userValidationSalt, ReadOnlySpan<byte> userKeySalt,
                                         ReadOnlySpan<byte> ownerValidationSalt, ReadOnlySpan<byte> ownerKeySalt,
                                         int permissions, ReadOnlySpan<byte> permsRandom, Action<Span<byte>> random)
    {
        if (fileKey.Length != FileKeyLength) throw new ArgumentException("The file key is 32 bytes.", nameof(fileKey));
        // Algorithm 8: /U and /UE.
        byte[] u = [.. Hash(userPassword, userValidationSalt, []), .. userValidationSalt, .. userKeySalt];
        byte[] userKey = Hash(userPassword, userKeySalt, []);
        byte[] ue = EncryptKey(userKey, fileKey);
        // Algorithm 9: /O and /OE, hashed with the whole /U.
        byte[] o = [.. Hash(ownerPassword, ownerValidationSalt, u), .. ownerValidationSalt, .. ownerKeySalt];
        byte[] ownerKey = Hash(ownerPassword, ownerKeySalt, u);
        byte[] oe = EncryptKey(ownerKey, fileKey);
        CryptographicOperations.ZeroMemory(userKey);
        CryptographicOperations.ZeroMemory(ownerKey);
        // Algorithm 10: /Perms.
        Span<byte> block = stackalloc byte[16];
        BinaryPrimitives.WriteInt32LittleEndian(block, permissions);
        block[4..8].Fill(0xFF);
        block[8] = (byte)'T'; // /EncryptMetadata true
        block[9] = (byte)'a';
        block[10] = (byte)'d';
        block[11] = (byte)'b';
        permsRandom[..4].CopyTo(block[12..]);
        using var aes = Aes.Create();
        aes.Key = fileKey;
        byte[] perms = aes.EncryptEcb(block, PaddingMode.None);
        return new PdfEncryption(fileKey, random, permissions, o, u, oe, ue, perms);
    }

    /// <summary>A 32-byte file key encrypted with AES-256 in CBC mode, a zero IV and no padding (/UE, /OE).</summary>
    private static byte[] EncryptKey(byte[] key, ReadOnlySpan<byte> fileKey)
    {
        using var aes = Aes.Create();
        aes.Key = key;
        return aes.EncryptCbc(fileKey, stackalloc byte[16], PaddingMode.None);
    }

    /// <summary>The /Encrypt dictionary: never encrypted itself; the trailer points at it.</summary>
    public string Dictionary =>
        "<</Filter /Standard /V 5 /R 6 /Length 256 " +
        "/CF <</StdCF <</CFM /AESV3 /AuthEvent /DocOpen /Length 32>>>> /StmF /StdCF /StrF /StdCF " +
        $"/O <{Convert.ToHexString(O)}> /U <{Convert.ToHexString(U)}> " +
        $"/OE <{Convert.ToHexString(OE)}> /UE <{Convert.ToHexString(UE)}> " +
        $"/Perms <{Convert.ToHexString(Perms)}> /P {P} /EncryptMetadata true>>";

    /// <summary>
    /// A string's or stream's bytes as stored: a random 16-byte IV, then the data encrypted with
    /// the file key in AES-256-CBC with PKCS#7 padding. In V 5 the file key itself is used for
    /// every object.
    /// </summary>
    public byte[] Encrypt(ReadOnlySpan<byte> data)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        Span<byte> iv = stackalloc byte[IvLength];
        _random(iv);
        using var aes = Aes.Create();
        aes.Key = _fileKey;
        int length = aes.GetCiphertextLengthCbc(data.Length, PaddingMode.PKCS7);
        byte[] stored = new byte[IvLength + length];
        iv.CopyTo(stored);
        aes.EncryptCbc(data, iv, stored.AsSpan(IvLength), PaddingMode.PKCS7);
        return stored;
    }

    /// <summary>Wipes the file key; nothing more can be encrypted.</summary>
    public void Dispose()
    {
        CryptographicOperations.ZeroMemory(_fileKey);
        _disposed = true;
    }

    // MARK: - Algorithm 2.B and the reader's side

    /// <summary>
    /// Algorithm 2.B of ISO 32000-2, the hash behind /U, /O, /UE and /OE:
    /// K = SHA-256(password ‖ salt ‖ userKey); then rounds of K1 = (password ‖ K ‖ userKey) × 64,
    /// E = AES-128-CBC(K1) keyed with K's first 16 bytes and its next 16 as the IV, no padding,
    /// and K = SHA-256, SHA-384 or SHA-512 of E as the sum of E's first 16 bytes modulo 3 is 0, 1
    /// or 2; at least 64 rounds, and on while E's last byte is above the round number minus 32.
    /// Returns K's first 32 bytes. <paramref name="userKey"/> is the 48-byte /U for the owner
    /// password, else empty.
    /// </summary>
    public static byte[] Hash(ReadOnlySpan<byte> password, ReadOnlySpan<byte> salt, ReadOnlySpan<byte> userKey)
    {
        byte[] first = [.. password, .. salt, .. userKey];
        byte[] k = SHA256.HashData(first);
        CryptographicOperations.ZeroMemory(first);
        using var aes = Aes.Create();
        byte[] e = [];
        int round = 0;
        while (round < 64 || e[^1] > round - 32)
        {
            int part = password.Length + k.Length + userKey.Length;
            byte[] k1 = new byte[part * 64];
            for (int i = 0; i < 64; i++)
            {
                var block = k1.AsSpan(i * part, part);
                password.CopyTo(block);
                k.CopyTo(block[password.Length..]);
                userKey.CopyTo(block[(password.Length + k.Length)..]);
            }
            aes.Key = k[..16];
            CryptographicOperations.ZeroMemory(e);
            e = aes.EncryptCbc(k1, k.AsSpan(16, 16), PaddingMode.None);
            CryptographicOperations.ZeroMemory(k1);
            int sum = 0;
            for (int i = 0; i < 16; i++) sum += e[i];
            CryptographicOperations.ZeroMemory(k);
            k = (sum % 3) switch
            {
                0 => SHA256.HashData(e),
                1 => SHA384.HashData(e),
                _ => SHA512.HashData(e),
            };
            round++;
        }
        CryptographicOperations.ZeroMemory(e);
        byte[] result = k[..32];
        CryptographicOperations.ZeroMemory(k);
        return result;
    }

    /// <summary>
    /// What a PDF app does with a typed password (algorithm 2.A): the file key when the prepared
    /// <paramref name="password"/> is the owner's (checked first) or the user's, else null.
    /// </summary>
    public static byte[]? FileKeyFor(ReadOnlySpan<byte> password, ReadOnlySpan<byte> o, ReadOnlySpan<byte> u,
                                     ReadOnlySpan<byte> oe, ReadOnlySpan<byte> ue)
    {
        if (o.Length < 48 || u.Length < 48 || oe.Length != 32 || ue.Length != 32) return null;
        password = password[..Math.Min(password.Length, PdfProtection.MaxPasswordBytes)];
        var userBytes = u[..48];
        if (Hash(password, o[32..40], userBytes).AsSpan().SequenceEqual(o[..32]))
        {
            return DecryptKey(Hash(password, o[40..48], userBytes), oe);
        }
        if (Hash(password, u[32..40], []).AsSpan().SequenceEqual(u[..32]))
        {
            return DecryptKey(Hash(password, u[40..48], []), ue);
        }
        return null;
    }

    private static byte[] DecryptKey(byte[] key, ReadOnlySpan<byte> encrypted)
    {
        using var aes = Aes.Create();
        aes.Key = key;
        CryptographicOperations.ZeroMemory(key);
        return aes.DecryptCbc(encrypted, stackalloc byte[16], PaddingMode.None);
    }

    /// <summary>
    /// Algorithm 13: /Perms decrypted with the file key holds "adb" and the same /P, so the
    /// permissions were not changed.
    /// </summary>
    public static bool PermsMatch(ReadOnlySpan<byte> fileKey, ReadOnlySpan<byte> perms, int p)
    {
        if (fileKey.Length != FileKeyLength || perms.Length != 16) return false;
        using var aes = Aes.Create();
        aes.Key = fileKey.ToArray();
        byte[] block = aes.DecryptEcb(perms, PaddingMode.None);
        return block[9] == 'a' && block[10] == 'd' && block[11] == 'b'
               && BinaryPrimitives.ReadInt32LittleEndian(block) == p;
    }

    /// <summary>A stored string or stream decrypted with the file key (its first 16 bytes are the IV).</summary>
    public static byte[] Decrypt(ReadOnlySpan<byte> fileKey, ReadOnlySpan<byte> stored)
    {
        if (stored.Length < IvLength * 2 || stored.Length % 16 != 0) throw new CryptographicException("Not an AES-256 encrypted string or stream.");
        using var aes = Aes.Create();
        aes.Key = fileKey.ToArray();
        return aes.DecryptCbc(stored[IvLength..], stored[..IvLength], PaddingMode.PKCS7);
    }
}
