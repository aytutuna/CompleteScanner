using System.Security.Cryptography;
using CompleteScanner.Core;
using Xunit;

namespace CompleteScanner.Core.Tests;

// Mirrored by Tests/CompleteScannerTests/PairedDeviceStoreTests.swift (same cases; each platform
// writes its own file in its own settings folder, so only the JSON keys are shared, not dates).

public sealed class PairedDeviceStoreTests : IDisposable
{
    private static readonly DateTimeOffset Now = new(2026, 10, 20, 8, 30, 0, TimeSpan.Zero);
    private readonly string _directory;

    public PairedDeviceStoreTests()
    {
        _directory = Path.Combine(Path.GetTempPath(), "CompleteScannerTests-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(_directory);
    }

    public void Dispose()
    {
        try
        {
            Directory.Delete(_directory, recursive: true);
        }
        catch (IOException)
        {
        }
    }

    private string FilePath => Path.Combine(_directory, PairedDeviceStore.FileName);

    [Fact]
    public void HashSecret_IsSha256Hex()
    {
        Assert.Equal(CompanionVectors.SecretHash, PairedDeviceStore.HashSecret(CompanionVectors.Secret));
    }

    [Fact]
    public void Pair_KeepsOnlyTheSecretsHash()
    {
        var store = new PairedDeviceStore(_directory);
        string secret = store.Pair("phone-0001", "Aytu's iPhone", "ios", "1.0", Now, CompanionVectors.Secret);
        Assert.Equal(CompanionVectors.SecretText, secret);
        var device = Assert.Single(store.Devices);
        Assert.Equal("phone-0001", device.Id);
        Assert.Equal("Aytu's iPhone", device.Name);
        Assert.Equal("ios", device.Platform);
        Assert.Equal(CompanionVectors.SecretHash, device.SecretHash);
        Assert.Equal(Now, device.Paired);
        string file = File.ReadAllText(FilePath);
        Assert.Contains(CompanionVectors.SecretHash, file);
        Assert.DoesNotContain(CompanionVectors.SecretText, file);
        // A fresh store reads the same phone.
        Assert.Equal("phone-0001", Assert.Single(new PairedDeviceStore(_directory).Devices).Id);
    }

    [Fact]
    public void Authenticate_NeedsTheRightIdAndSecret()
    {
        var store = new PairedDeviceStore(_directory);
        string secret = store.Pair("phone-0001", "Phone", "ios", "1.0", Now);
        Assert.Equal(43, secret.Length);
        Assert.Equal("phone-0001", store.Authenticate("phone-0001", secret, Now)?.Id);
        Assert.Null(store.Authenticate("phone-0002", secret, Now));
        Assert.Null(store.Authenticate("phone-0001", CompanionVectors.SecretText, Now));
        Assert.Null(store.Authenticate("phone-0001", secret[..^1], Now));
        Assert.Null(store.Authenticate("phone-0001", null, Now));
        Assert.Null(store.Authenticate(null, secret, Now));
        Assert.Null(store.Authenticate("../../x", secret, Now));
    }

    [Fact]
    public void Authenticate_RecordsLastSeenToTheMinute()
    {
        var store = new PairedDeviceStore(_directory);
        string secret = store.Pair("phone-0001", "Phone", "ios", "1.0", Now);
        store.Authenticate("phone-0001", secret, Now.AddSeconds(30));
        Assert.Equal(Now, Assert.Single(store.Devices).LastSeen);
        store.Authenticate("phone-0001", secret, Now.AddMinutes(2));
        Assert.Equal(Now.AddMinutes(2), Assert.Single(new PairedDeviceStore(_directory).Devices).LastSeen);
    }

    [Fact]
    public void PairingAgain_ReplacesTheSecret()
    {
        var store = new PairedDeviceStore(_directory);
        string first = store.Pair("phone-0001", "Old name", "ios", "1.0", Now);
        string second = store.Pair("phone-0001", "New name", "ios", "1.1", Now.AddDays(1));
        Assert.NotEqual(first, second);
        Assert.Null(store.Authenticate("phone-0001", first, Now));
        Assert.Equal("New name", store.Authenticate("phone-0001", second, Now)?.Name);
        Assert.Single(store.Devices);
    }

    [Fact]
    public void Remove_RefusesThePhoneAtOnce()
    {
        var store = new PairedDeviceStore(_directory);
        string secret = store.Pair("phone-0001", "Phone", "ios", "1.0", Now);
        int changes = 0;
        store.Changed += (_, _) => changes++;
        Assert.True(store.Remove("phone-0001"));
        Assert.False(store.Remove("phone-0001"));
        Assert.Null(store.Authenticate("phone-0001", secret, Now));
        Assert.Empty(new PairedDeviceStore(_directory).Devices);
        Assert.Equal(1, changes);
    }

    [Fact]
    public void RemoveAll_UnpairsEveryPhone()
    {
        var store = new PairedDeviceStore(_directory);
        string a = store.Pair("phone-0001", "A", "ios", "1.0", Now);
        string b = store.Pair("phone-0002", "B", "ios", "1.0", Now);
        Assert.Equal(2, store.RemoveAll());
        Assert.Null(store.Authenticate("phone-0001", a, Now));
        Assert.Null(store.Authenticate("phone-0002", b, Now));
        Assert.Equal(0, store.Count);
    }

    [Fact]
    public void Pair_RefusesTooManyPhonesAndBadIds()
    {
        var store = new PairedDeviceStore(_directory);
        for (int i = 0; i < PairedDeviceStore.MaxDevices; i++) store.Pair($"phone-{i:D4}", "P", "ios", "1.0", Now);
        Assert.Throws<InvalidOperationException>(() => store.Pair("phone-9999", "P", "ios", "1.0", Now));
        // Pairing one of them again is fine.
        store.Pair("phone-0003", "P", "ios", "1.0", Now);
        Assert.Throws<ArgumentException>(() => store.Pair("bad id!", "P", "ios", "1.0", Now));
        Assert.Throws<ArgumentException>(() => store.Pair("phone-0001", "P", "ios", "1.0", Now, new byte[16]));
    }

    [Fact]
    public void DesktopId_IsMadeOnceAndKept()
    {
        var store = new PairedDeviceStore(_directory);
        string id = store.DesktopId;
        Assert.Equal(32, id.Length);
        Assert.True(CompanionProtocol.IsValidId(id));
        Assert.Equal(id, store.DesktopId);
        Assert.Equal(id, new PairedDeviceStore(_directory).DesktopId);
    }

    [Fact]
    public void CleanName_DropsControlCharactersAndCutsLongNames()
    {
        Assert.Equal("Aytu's iPhone", PairedDeviceStore.CleanName("  Aytu's\u0001 iPhone\n "));
        Assert.Equal("", PairedDeviceStore.CleanName(null));
        Assert.Equal(new string('é', 64), PairedDeviceStore.CleanName(new string('é', 100)));
    }

    [Fact]
    public void UnreadableFile_IsKeptAsideAndPairingStillWorks()
    {
        File.WriteAllText(FilePath, "{ not json");
        var store = new PairedDeviceStore(_directory);
        Assert.Empty(store.Devices);
        Assert.Single(Directory.GetFiles(_directory, "companion-devices.unreadable-*.json"));
        string secret = store.Pair("phone-0001", "Phone", "ios", "1.0", Now);
        Assert.NotNull(store.Authenticate("phone-0001", secret, Now));
    }

    [Fact]
    public void FileWithOddValues_LoadsLeniently()
    {
        File.WriteAllText(FilePath,
            """{"desktopId":5,"devices":[{"id":"phone-0001","name":7,"secretHash":"""
            + $"\"{CompanionVectors.SecretHash}\"" + ""","paired":"yesterday","later":true}],"extra":{}}""");
        var store = new PairedDeviceStore(_directory);
        var device = Assert.Single(store.Devices);
        Assert.Equal("", device.Name);
        Assert.Null(device.Paired);
        Assert.NotNull(store.Authenticate("phone-0001", CompanionVectors.SecretText, Now));
        Assert.True(CompanionProtocol.IsValidId(store.DesktopId));
    }

    [Fact]
    public void Pair_MakesASyncKeyKeptProtected()
    {
        if (!OperatingSystem.IsWindows()) return;
        var store = new PairedDeviceStore(_directory);
        store.Pair("phone-0001", "Phone", "ios", "1.0", Now);
        byte[] key = Assert.IsType<byte[]>(store.SyncKey("phone-0001"));
        Assert.Equal(SyncPackage.KeyByteCount, key.Length);
        Assert.Equal(key, new PairedDeviceStore(_directory).SyncKey("phone-0001"));
        string file = File.ReadAllText(FilePath);
        Assert.Contains("\"syncKeyProtected\"", file);
        Assert.DoesNotContain(Convert.ToBase64String(key), file);
        Assert.DoesNotContain(CompanionProtocol.EncodeBase64Url(key), file);
        Assert.Null(store.SyncKey("phone-0002"));
        Assert.True(store.HasSyncKey("phone-0001"));
        Assert.False(store.HasSyncKey("phone-0002"));

        // Pairing again keeps the key; removing the phone drops it, and pairing after that makes a new one.
        store.Pair("phone-0001", "Phone", "ios", "1.0", Now);
        Assert.Equal(key, store.SyncKey("phone-0001"));
        store.Remove("phone-0001");
        Assert.Null(store.SyncKey("phone-0001"));
        store.Pair("phone-0001", "Phone", "ios", "1.0", Now);
        Assert.NotEqual(key, store.SyncKey("phone-0001"));
        store.Pair("phone-0002", "Phone", "ios", "1.0", Now);
        store.RemoveAll();
        Assert.Null(store.SyncKey("phone-0002"));
    }

    [Fact]
    public void SyncKey_ThatCannotBeUnprotected_Throws_AndPairingAgainMakesANewOne()
    {
        File.WriteAllText(FilePath,
            """{"devices":[{"id":"phone-0001","secretHash":""" + $"\"{CompanionVectors.SecretHash}\""
            + ""","syncKeyProtected":"bm90IGEgYmxvYg=="},{"id":"phone-0002","syncKeyProtected":"%%"}]}""");
        var store = new PairedDeviceStore(_directory);
        Assert.Null(store.SyncKey("phone-0002"));
        Assert.NotNull(store.Authenticate("phone-0001", CompanionVectors.SecretText, Now));
        if (!OperatingSystem.IsWindows()) return;
        Assert.ThrowsAny<CryptographicException>(() => store.SyncKey("phone-0001"));
        Assert.False(store.HasSyncKey("phone-0001"));
        Assert.False(store.HasSyncKey("phone-0002"));

        store.Pair("phone-0001", "Phone", "ios", "1.0", Now);
        Assert.Equal(SyncPackage.KeyByteCount, store.SyncKey("phone-0001")?.Length);
    }

    [Fact]
    public void SyncFolder_IsKeptWithThePhones()
    {
        var store = new PairedDeviceStore(_directory);
        Assert.Null(store.SyncFolder);
        int changes = 0;
        store.Changed += (_, _) => changes++;
        string folder = Path.Combine(_directory, "OneDrive", "Scans");
        Assert.True(store.SetSyncFolder(folder));
        Assert.Equal(folder, new PairedDeviceStore(_directory).SyncFolder);
        store.Pair("phone-0001", "Phone", "ios", "1.0", Now);
        store.RemoveAll();
        Assert.Equal(folder, store.SyncFolder);
        Assert.True(store.SetSyncFolder(null));
        Assert.Null(new PairedDeviceStore(_directory).SyncFolder);
        Assert.Equal(4, changes);
    }

    [Fact]
    public void RemovedPhone_StaysRemovedWhenTheFileComesBack()
    {
        var store = new PairedDeviceStore(_directory);
        string secret = store.Pair("phone-0001", "Phone", "ios", "1.0", Now);
        string before = File.ReadAllText(FilePath);
        store.Remove("phone-0001");
        // Another window that still had the old list writes it back.
        File.WriteAllText(FilePath, before);
        Assert.Null(store.Authenticate("phone-0001", secret, Now));
    }
}
