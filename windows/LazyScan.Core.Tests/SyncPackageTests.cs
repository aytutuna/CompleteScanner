using System.Text;
using LazyScan.Core;
using Xunit;

namespace LazyScan.Core.Tests;

// Mirrored by Tests/CompleteScannerTests/SyncPackageTests.swift (the same golden bytes).

public class SyncPackageTests
{
    private const string PackageId = "pkg_golden_1234";
    private const string PhoneId = "phone_golden_1";

    /// <summary>0x01...0x20.</summary>
    private static readonly byte[] Key = [.. Enumerable.Range(1, 32).Select(i => (byte)i)];
    /// <summary>0x10...0x1b.</summary>
    private static readonly byte[] Nonce = [.. Enumerable.Range(0x10, 12).Select(i => (byte)i)];
    private static readonly byte[] Plaintext = Encoding.UTF8.GetBytes("hello sync");

    /// <summary>"CSSYNC01", version 1, target current, the nonce, then "hello sync" sealed and its tag.</summary>
    private const string Golden =
        "435353594e433031" + "01010000" + "101112131415161718191a1b" + "da8ed674e45b6fdc2533" + "7cacc7081262a9c7e1084e3576d63d53";

    private static byte[] Sealed() => SyncPackage.Seal(PackageId, PhoneId, CompanionTarget.Current, Plaintext, Key, Nonce);

    [Fact]
    public void Seal_WritesTheGoldenBytes()
    {
        Assert.Equal(Golden, Convert.ToHexStringLower(Sealed()));
    }

    [Fact]
    public void Open_GivesBackThePackageAndItsTarget()
    {
        var (target, plaintext) = SyncPackage.Open(Convert.FromHexString(Golden), PackageId, PhoneId, Key);
        Assert.Equal(CompanionTarget.Current, target);
        Assert.Equal(Plaintext, plaintext);

        byte[] fresh = SyncPackage.Seal(PackageId, PhoneId, CompanionTarget.New, Plaintext, Key);
        Assert.Equal(8 + 16 + Plaintext.Length + 16, fresh.Length);
        Assert.Equal(CompanionTarget.New, SyncPackage.Open(fresh, PackageId, PhoneId, Key).Target);
        Assert.NotEqual(fresh[12..24], SyncPackage.Seal(PackageId, PhoneId, CompanionTarget.New, Plaintext, Key)[12..24]);
    }

    [Fact]
    public void Open_RefusesAnotherKey()
    {
        byte[] other = [.. Key];
        other[31] ^= 1;
        Assert.Equal(SyncPackageErrorKind.WrongKeyOrTampered, Refused(Sealed(), PackageId, PhoneId, other));
        Assert.Equal(SyncPackageErrorKind.WrongKeyOrTampered, Refused(Sealed(), PackageId, PhoneId, Key[..16]));
    }

    [Theory]
    [InlineData(9)]
    [InlineData(13)]
    [InlineData(30)]
    [InlineData(-1)]
    public void Open_RefusesAFlippedByte(int index)
    {
        byte[] data = Sealed();
        data[index < 0 ? data.Length + index : index] ^= 0x40;
        Assert.Equal(SyncPackageErrorKind.WrongKeyOrTampered, Refused(data, PackageId, PhoneId, Key));
    }

    [Fact]
    public void Open_RefusesAnotherPackageIdOrPhone()
    {
        Assert.Equal(SyncPackageErrorKind.WrongKeyOrTampered, Refused(Sealed(), "pkg_golden_1235", PhoneId, Key));
        Assert.Equal(SyncPackageErrorKind.WrongKeyOrTampered, Refused(Sealed(), PackageId, "phone_golden_2", Key));
    }

    [Fact]
    public void Open_RefusesANewerVersion()
    {
        byte[] data = Sealed();
        data[8] = 2;
        Assert.Equal(SyncPackageErrorKind.NewerVersion, Refused(data, PackageId, PhoneId, Key));
    }

    [Fact]
    public void Open_RefusesWhatIsNotASyncPackage()
    {
        byte[] data = Sealed();
        Assert.Equal(SyncPackageErrorKind.NotASyncPackage, Refused(data[..39], PackageId, PhoneId, Key));
        Assert.Equal(SyncPackageErrorKind.WrongKeyOrTampered, Refused(data[..^1], PackageId, PhoneId, Key));
        Assert.Equal(SyncPackageErrorKind.NotASyncPackage, Refused([], PackageId, PhoneId, Key));
        data[0] = (byte)'X';
        Assert.Equal(SyncPackageErrorKind.NotASyncPackage, Refused(data, PackageId, PhoneId, Key));
    }

    private static SyncPackageErrorKind Refused(byte[] data, string packageId, string phoneId, byte[] key) =>
        Assert.Throws<SyncPackageException>(() => SyncPackage.Open(data, packageId, phoneId, key)).Kind;
}
