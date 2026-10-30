using LazyScan.Core;
using Xunit;

namespace LazyScan.Core.Tests;

// Mirrored by Tests/LazyScanTests/SyncFolderWatcherTests.swift (same cases). The sync keys are
// kept with the Data Protection API, so these run on Windows only.

public sealed class SyncFolderWatcherTests : IDisposable
{
    private const string PhoneId = "phone-0001";
    private readonly string _root;
    private readonly string _folder;
    private readonly PairedDeviceStore _devices;
    private readonly CompanionInbox _inbox;
    private readonly SyncFolderWatcher _watcher;
    private readonly List<CompanionPackageReceivedEventArgs> _received = [];
    private readonly List<string> _problems = [];
    private DateTimeOffset _now = new(2026, 10, 22, 9, 0, 0, TimeSpan.Zero);

    public SyncFolderWatcherTests()
    {
        _root = Path.Combine(Path.GetTempPath(), "CompleteScannerTests-" + Guid.NewGuid().ToString("N"));
        _folder = Path.Combine(_root, "OneDrive", "CompleteScanner");
        Directory.CreateDirectory(_folder);
        _devices = new PairedDeviceStore(_root);
        _inbox = new CompanionInbox(Path.Combine(_root, "Inbox"));
        _watcher = new SyncFolderWatcher(_folder, _devices, _inbox, () => _now);
        _watcher.PackageReceived += (_, e) => _received.Add(e);
        _watcher.Problem += (_, message) => _problems.Add(message);
    }

    public void Dispose()
    {
        _watcher.Dispose();
        try
        {
            Directory.Delete(_root, recursive: true);
        }
        catch (IOException)
        {
        }
    }

    private byte[] PairPhone(string id = PhoneId)
    {
        _devices.Pair(id, "Aytu's iPhone", "ios", "1.0", _now);
        return _devices.SyncKey(id)!;
    }

    private string Put(string packageId, byte[] key, string phoneId = PhoneId, CompanionTarget target = CompanionTarget.Current)
    {
        string path = Path.Combine(_folder, SyncPackage.FileName(packageId));
        File.WriteAllBytes(path, SyncPackage.Seal(packageId, phoneId, target, CompanionPackage.Make(CompanionFixtures.Minimal), key));
        return path;
    }

    /// <summary>Looks once, then again once the files have settled.</summary>
    private async Task PollTwiceAsync()
    {
        await _watcher.PollAsync();
        _now += SyncFolderWatcher.SettleTime;
        await _watcher.PollAsync();
    }

    [Fact]
    public async Task SealedFile_IsReceivedOnceSettled_ThenDeleted()
    {
        if (!OperatingSystem.IsWindows()) return;
        string path = Put("package-0001", PairPhone());

        await _watcher.PollAsync();
        Assert.Empty(_received);
        _now += TimeSpan.FromSeconds(1);
        await _watcher.PollAsync();
        Assert.Empty(_received);
        _now += TimeSpan.FromSeconds(1);
        await _watcher.PollAsync();

        var received = Assert.Single(_received);
        Assert.Equal(PhoneId, received.Device.Id);
        Assert.Equal("package-0001", received.Package.PackageId);
        Assert.Equal(CompanionTarget.Current, received.Package.Target);
        Assert.Equal(CompanionFixtures.Minimal.Pages.Count, received.Package.Document.Pages.Count);
        Assert.True(File.Exists(received.Package.Path));
        Assert.NotNull(_inbox.Find(PhoneId, "package-0001"));
        Assert.False(File.Exists(path));
        Assert.Empty(_problems);

        await PollTwiceAsync();
        Assert.Single(_received);
    }

    [Fact]
    public async Task ThePhoneIsFoundByItsKey()
    {
        if (!OperatingSystem.IsWindows()) return;
        PairPhone("phone-0002");
        byte[] key = PairPhone();
        Put("package-0001", key, target: CompanionTarget.New);

        await PollTwiceAsync();

        var received = Assert.Single(_received);
        Assert.Equal(PhoneId, received.Device.Id);
        Assert.Equal(CompanionTarget.New, received.Package.Target);
    }

    [Fact]
    public async Task APackageReceivedBefore_IsOnlyDeleted()
    {
        if (!OperatingSystem.IsWindows()) return;
        byte[] key = PairPhone();
        Put("package-0001", key);
        await PollTwiceAsync();
        Assert.Single(_received);

        string again = Put("package-0001", key);
        await PollTwiceAsync();

        Assert.Single(_received);
        Assert.False(File.Exists(again));
        Assert.Empty(_problems);
    }

    [Fact]
    public async Task AFileNoPairedPhoneOpens_IsLeftAndReportedOnce()
    {
        if (!OperatingSystem.IsWindows()) return;
        PairPhone();
        string path = Put("package-0001", new byte[SyncPackage.KeyByteCount]);
        string other = Path.Combine(_folder, "notes.cssync");
        File.WriteAllText(other, "not a package");

        await PollTwiceAsync();
        await PollTwiceAsync();

        Assert.Empty(_received);
        Assert.True(File.Exists(path));
        Assert.True(File.Exists(other));
        Assert.Equal(2, _problems.Count);
        Assert.Contains(SyncFolderWatcher.UnreadableMessage("package-0001.cssync", SyncPackage.WrongKeyMessage), _problems);
        Assert.Contains(SyncFolderWatcher.UnreadableMessage("notes.cssync", SyncPackage.NotASyncPackageMessage), _problems);
    }

    [Fact]
    public async Task AFileStillGrowing_WaitsUntilItSettles()
    {
        if (!OperatingSystem.IsWindows()) return;
        byte[] key = PairPhone();
        string path = Put("package-0001", key);
        byte[] whole = File.ReadAllBytes(path);
        File.WriteAllBytes(path, whole[..100]);

        await _watcher.PollAsync();
        _now += SyncFolderWatcher.SettleTime;
        File.WriteAllBytes(path, whole);
        await _watcher.PollAsync();
        Assert.Empty(_received);
        _now += SyncFolderWatcher.SettleTime;
        await _watcher.PollAsync();

        Assert.Single(_received);
        Assert.Empty(_problems);
    }

    [Fact]
    public async Task AReportedFile_IsTriedAgainOnlyAfterAMinute()
    {
        if (!OperatingSystem.IsWindows()) return;
        string path = Put("package-0001", PairPhone());
        string devicesFile = Path.Combine(_root, PairedDeviceStore.FileName);
        string paired = File.ReadAllText(devicesFile);
        File.WriteAllText(devicesFile, """{"devices":[{"id":"phone-0001","name":"Aytu's iPhone"}]}""");
        await PollTwiceAsync();
        Assert.Equal([SyncFolderWatcher.UnreadableMessage("package-0001.cssync", SyncPackage.WrongKeyMessage)], _problems);

        File.WriteAllText(devicesFile, paired);
        _now += SyncFolderWatcher.RetryTime - TimeSpan.FromSeconds(1);
        await _watcher.PollAsync();
        Assert.Empty(_received);

        _now += TimeSpan.FromSeconds(1);
        await _watcher.PollAsync();

        Assert.Single(_received);
        Assert.False(File.Exists(path));
        Assert.Single(_problems);
    }

    [Fact]
    public async Task AKeyThatCannotBeUnprotected_IsReportedOnce_AndTheFileWaitsAMinute()
    {
        if (!OperatingSystem.IsWindows()) return;
        string path = Put("package-0001", PairPhone());
        Put("package-0002", new byte[SyncPackage.KeyByteCount]);
        string devicesFile = Path.Combine(_root, PairedDeviceStore.FileName);
        string paired = File.ReadAllText(devicesFile);
        File.WriteAllText(devicesFile,
            """{"devices":[{"id":"phone-0001","name":"Aytu's iPhone","syncKeyProtected":"bm90IGEgYmxvYg=="}]}""");

        await PollTwiceAsync();
        await PollTwiceAsync();

        Assert.Empty(_received);
        Assert.True(File.Exists(path));
        Assert.Equal([SyncFolderWatcher.KeyUnreadableMessage("Aytu's iPhone")], _problems);

        // Not read again before a minute has passed, though the key opens now.
        File.WriteAllText(devicesFile, paired);
        await PollTwiceAsync();
        Assert.Empty(_received);

        _now += SyncFolderWatcher.RetryTime;
        await _watcher.PollAsync();

        Assert.Single(_received);
        Assert.False(File.Exists(path));
        Assert.Equal(2, _problems.Count);
        Assert.Equal(SyncFolderWatcher.UnreadableMessage("package-0002.cssync", SyncPackage.WrongKeyMessage), _problems[1]);
    }

    [Fact]
    public async Task AFileFromARemovedPhone_IsNotReceived()
    {
        if (!OperatingSystem.IsWindows()) return;
        byte[] key = PairPhone();
        _devices.Remove(PhoneId);
        Put("package-0001", key);

        await PollTwiceAsync();

        Assert.Empty(_received);
        Assert.Single(_problems);
    }
}
