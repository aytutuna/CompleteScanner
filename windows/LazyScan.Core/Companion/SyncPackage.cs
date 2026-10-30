using System.Security.Cryptography;
using System.Text;

namespace LazyScan.Core;

// Twin of Sources/LazyScanKit/Companion/SyncPackage.swift: the same bytes for the same
// package, key and nonce, and the same checks when opening one.

/// <summary>Why a <c>.cssync</c> file could not be opened.</summary>
public enum SyncPackageErrorKind
{
    /// <summary>Too short, or not starting with <see cref="SyncPackage.Magic"/>.</summary>
    NotASyncPackage,
    /// <summary>A newer format version than this app reads.</summary>
    NewerVersion,
    /// <summary>Sealed with another key, for another package id or phone, or changed since.</summary>
    WrongKeyOrTampered,
    TooLarge,
}

/// <summary>A <c>.cssync</c> file that cannot be made or opened, with a message for the user.</summary>
public sealed class SyncPackageException(SyncPackageErrorKind kind, string message) : IOException(message)
{
    public SyncPackageErrorKind Kind { get; } = kind;
}

/// <summary>
/// A <c>.csdoc</c> package sealed for the cloud sync folder (C2): what a phone writes into a folder
/// the user syncs (iCloud Drive, OneDrive) when the desktop cannot be reached, as
/// "&lt;packageId&gt;.cssync". The bytes are <see cref="Magic"/>, a 16-byte header (version, target,
/// two reserved zero bytes, the 12-byte nonce) and the package encrypted with AES-256-GCM under the
/// sync key the desktop handed out at pairing, its 16-byte tag last. The magic and header, the
/// package id and the phone's id are authenticated with it, so a file renamed, moved to another
/// phone's name or changed in any byte does not open.
/// </summary>
public static class SyncPackage
{
    public const string FileExtension = "cssync";
    public const int Version = 1;
    public const int KeyByteCount = 32;
    public const int NonceByteCount = 12;
    public const int TagByteCount = 16;
    public const int HeaderByteCount = 16;

    /// <summary>"CSSYNC01".</summary>
    public static ReadOnlySpan<byte> Magic => "CSSYNC01"u8;

    /// <summary>The largest file opened: a package as large as an upload may be, plus the framing.</summary>
    public static long MaxFileBytes => CompanionProtocol.MaxUploadBytes + 64;

    /// <summary>
    /// <paramref name="plaintext"/> (a <c>.csdoc</c>) sealed under <paramref name="key"/> with a random
    /// nonce. Throws <see cref="SyncPackageException"/> for a package larger than an upload may be.
    /// </summary>
    public static byte[] Seal(string packageId, string phoneId, CompanionTarget target, ReadOnlySpan<byte> plaintext,
                              ReadOnlySpan<byte> key) =>
        Seal(packageId, phoneId, target, plaintext, key, RandomNumberGenerator.GetBytes(NonceByteCount));

    /// <summary>Same as <see cref="Seal(string, string, CompanionTarget, ReadOnlySpan{byte}, ReadOnlySpan{byte})"/> with a given nonce (tests).</summary>
    public static byte[] Seal(string packageId, string phoneId, CompanionTarget target, ReadOnlySpan<byte> plaintext,
                              ReadOnlySpan<byte> key, ReadOnlySpan<byte> nonce)
    {
        if (plaintext.Length > CompanionProtocol.MaxUploadBytes)
        {
            throw new SyncPackageException(SyncPackageErrorKind.TooLarge, CompanionError.TooLarge.Message);
        }
        int prefix = Magic.Length + HeaderByteCount;
        var output = new byte[prefix + plaintext.Length + TagByteCount];
        Magic.CopyTo(output);
        output[Magic.Length] = Version;
        output[Magic.Length + 1] = (byte)(target == CompanionTarget.Current ? 1 : 0);
        nonce.CopyTo(output.AsSpan(Magic.Length + 4, NonceByteCount));
        using var aes = new AesGcm(key, TagByteCount);
        aes.Encrypt(nonce, plaintext, output.AsSpan(prefix, plaintext.Length), output.AsSpan(prefix + plaintext.Length),
                    AssociatedData(output.AsSpan(0, prefix), packageId, phoneId));
        return output;
    }

    /// <summary>
    /// The package sealed in <paramref name="data"/> for <paramref name="packageId"/> by
    /// <paramref name="phoneId"/>, and where it goes. Throws <see cref="SyncPackageException"/>.
    /// </summary>
    public static (CompanionTarget Target, byte[] Plaintext) Open(ReadOnlySpan<byte> data, string packageId, string phoneId,
                                                                  ReadOnlySpan<byte> key)
    {
        if (data.Length > MaxFileBytes) throw new SyncPackageException(SyncPackageErrorKind.TooLarge, CompanionError.TooLarge.Message);
        int prefix = Magic.Length + HeaderByteCount;
        if (data.Length < prefix + TagByteCount || !data[..Magic.Length].SequenceEqual(Magic) || data[Magic.Length] == 0)
        {
            throw new SyncPackageException(SyncPackageErrorKind.NotASyncPackage, NotASyncPackageMessage);
        }
        if (data[Magic.Length] > Version) throw new SyncPackageException(SyncPackageErrorKind.NewerVersion, NewerVersionMessage);
        if (key.Length != KeyByteCount) throw new SyncPackageException(SyncPackageErrorKind.WrongKeyOrTampered, WrongKeyMessage);
        var target = data[Magic.Length + 1] == 1 ? CompanionTarget.Current : CompanionTarget.New;
        var ciphertext = data[prefix..^TagByteCount];
        var plaintext = new byte[ciphertext.Length];
        try
        {
            using var aes = new AesGcm(key, TagByteCount);
            aes.Decrypt(data.Slice(Magic.Length + 4, NonceByteCount), ciphertext, data[^TagByteCount..], plaintext,
                        AssociatedData(data[..prefix], packageId, phoneId));
        }
        catch (AuthenticationTagMismatchException)
        {
            throw new SyncPackageException(SyncPackageErrorKind.WrongKeyOrTampered, WrongKeyMessage);
        }
        return (target, plaintext);
    }

    /// <summary>The file name a package is put in the folder under.</summary>
    public static string FileName(string packageId) => packageId + "." + FileExtension;

    public const string NotASyncPackageMessage = "This file was not put in the cloud folder by Lazy Scan.";
    public const string NewerVersionMessage = "This file was put in the cloud folder by a newer version of Lazy Scan.";
    public const string WrongKeyMessage = "This file was not put there by a phone paired with this computer, or it was changed.";

    /// <summary>The magic and header, the package id, a zero byte and the phone's id.</summary>
    private static byte[] AssociatedData(ReadOnlySpan<byte> prefix, string packageId, string phoneId)
    {
        byte[] package = Encoding.UTF8.GetBytes(packageId);
        byte[] phone = Encoding.UTF8.GetBytes(phoneId);
        var data = new byte[prefix.Length + package.Length + 1 + phone.Length];
        prefix.CopyTo(data);
        package.CopyTo(data, prefix.Length);
        phone.CopyTo(data, prefix.Length + package.Length + 1);
        return data;
    }
}
