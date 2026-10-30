using System.Security.Cryptography;

namespace LazyScan.Core;

// Twin of Sources/CompleteScannerKit/Companion/SyncFolderWatcher.swift: the same rules for taking,
// skipping and leaving a file; a FileSystemWatcher where the Mac has a DispatchSource.

/// <summary>
/// Watches the cloud sync folder (C2) for the packages phones put there (<see cref="SyncPackage"/>)
/// and receives them as if they had been uploaded. A "&lt;packageId&gt;.cssync" file is taken once its
/// size has not changed for <see cref="SettleTime"/> (the sync client may still be writing it): the
/// phone that sealed it is found by trying each paired phone's sync key, its package is received into
/// the inbox under that phone, raised through <see cref="PackageReceived"/> and the file deleted. A
/// package the inbox has received before (over the network or from the folder) is only deleted. A
/// file no paired phone's key opens is left where it is and reported once (<see cref="Problem"/>),
/// then tried again only once its size or modification date changes or <see cref="RetryTime"/> has
/// passed. A phone whose key cannot be unprotected is reported once and skipped for the rest of the
/// poll; a file no key opened while that was so is not reported (it may be that phone's) but waits the
/// same way. One that cannot be read now (a placeholder still downloading, a file in use) is tried
/// again on the next poll. The folder is looked at every <see cref="PollInterval"/>, at once when it
/// changes, and again after <see cref="SettleTime"/> while a file is still settling.
/// </summary>
public sealed class SyncFolderWatcher : IDisposable
{
    public static readonly TimeSpan PollInterval = TimeSpan.FromSeconds(5);
    public static readonly TimeSpan SettleTime = TimeSpan.FromSeconds(2);
    public static readonly TimeSpan RetryTime = TimeSpan.FromSeconds(60);

    private readonly PairedDeviceStore _devices;
    private readonly CompanionInbox _inbox;
    private readonly Func<DateTimeOffset> _clock;
    /// <summary>Each file's size and modification time, and since when it has had them (touched by one poll at a time).</summary>
    private readonly Dictionary<string, (long Size, DateTime Modified, DateTimeOffset Since)> _seen = [];
    /// <summary>The files reported, not reported again while they stay as they are.</summary>
    private readonly HashSet<string> _reported = [];
    /// <summary>When each file that did not open was last tried.</summary>
    private readonly Dictionary<string, DateTimeOffset> _failed = [];
    /// <summary>The phones whose key could not be unprotected: reported until it can be again, skipped for the poll.</summary>
    private readonly HashSet<string> _reportedKeys = [];
    private readonly HashSet<string> _unreadKeys = [];
    private FileSystemWatcher? _watcher;
    private Timer? _timer;
    private int _polling;

    public SyncFolderWatcher(string folder, PairedDeviceStore devices, CompanionInbox inbox, Func<DateTimeOffset>? clock = null)
    {
        Folder = folder;
        _devices = devices;
        _inbox = inbox;
        _clock = clock ?? (() => DateTimeOffset.UtcNow);
    }

    public string Folder { get; }

    /// <summary>A phone's package was received from the folder (on a pool thread). Release it from the inbox once imported.</summary>
    public event EventHandler<CompanionPackageReceivedEventArgs>? PackageReceived;

    /// <summary>A file in the folder could not be opened, or a phone's key read: the message to show, once per file or phone.</summary>
    public event EventHandler<string>? Problem;

    /// <summary>"A file in the cloud folder could not be read: 1a2b3c4d.cssync. …"</summary>
    public static string UnreadableMessage(string fileName, string reason) =>
        $"A file in the cloud folder could not be read: {fileName}. {reason}";

    /// <summary>"The key for Aytu's iPhone could not be read, so files from it cannot be opened. Pair the phone again."</summary>
    public static string KeyUnreadableMessage(string phoneName) =>
        $"The key for {phoneName} could not be read, so files from it cannot be opened. Pair the phone again.";

    /// <summary>Starts polling and watching; a folder that is not there now is polled until it is.</summary>
    public void Start()
    {
        _timer = new Timer(_ => _ = PollAsync(), null, TimeSpan.Zero, PollInterval);
        try
        {
            _watcher = new FileSystemWatcher(Folder, "*." + SyncPackage.FileExtension)
            {
                NotifyFilter = NotifyFilters.FileName | NotifyFilters.Size | NotifyFilters.LastWrite,
            };
            _watcher.Created += (_, _) => _ = PollAsync();
            _watcher.Changed += (_, _) => _ = PollAsync();
            _watcher.Renamed += (_, _) => _ = PollAsync();
            _watcher.EnableRaisingEvents = true;
        }
        catch (Exception e) when (e is ArgumentException or IOException or PlatformNotSupportedException)
        {
            _watcher?.Dispose();
            _watcher = null;
        }
    }

    /// <summary>Looks at the folder once; does nothing while another look runs.</summary>
    public async Task PollAsync()
    {
        if (Interlocked.Exchange(ref _polling, 1) == 1) return;
        try
        {
            string[] files;
            try
            {
                files = Directory.GetFiles(Folder, "*." + SyncPackage.FileExtension);
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                return;
            }
            var now = _clock();
            var names = files.Select(f => Path.GetFileName(f)).ToHashSet();
            foreach (string gone in _seen.Keys.Where(n => !names.Contains(n)).ToList()) _seen.Remove(gone);
            _reported.RemoveWhere(n => !names.Contains(n));
            foreach (string gone in _failed.Keys.Where(n => !names.Contains(n)).ToList()) _failed.Remove(gone);
            _unreadKeys.Clear();
            bool settling = false;
            foreach (string path in files)
            {
                string name = Path.GetFileName(path);
                long size;
                DateTime modified;
                try
                {
                    var info = new FileInfo(path);
                    size = info.Length;
                    modified = info.LastWriteTimeUtc;
                }
                catch (Exception e) when (e is IOException or UnauthorizedAccessException)
                {
                    continue;
                }
                if (!_seen.TryGetValue(name, out var seen) || seen.Size != size || seen.Modified != modified)
                {
                    _seen[name] = (size, modified, now);
                    _reported.Remove(name);
                    _failed.Remove(name);
                    settling = true;
                }
                else if (now - seen.Since < SettleTime)
                {
                    settling = true;
                }
                else if (!_failed.TryGetValue(name, out var tried) || now - tried >= RetryTime)
                {
                    await TakeAsync(path, name, size).ConfigureAwait(false);
                }
            }
            if (settling)
            {
                try
                {
                    _timer?.Change(SettleTime, PollInterval);
                }
                catch (ObjectDisposedException)
                {
                    // Stopped meanwhile.
                }
            }
        }
        finally
        {
            Volatile.Write(ref _polling, 0);
        }
    }

    public void Dispose()
    {
        _watcher?.Dispose();
        _watcher = null;
        _timer?.Dispose();
        _timer = null;
    }

    private async Task TakeAsync(string path, string name, long size)
    {
        string packageId = Path.GetFileNameWithoutExtension(name);
        if (!CompanionProtocol.IsValidId(packageId))
        {
            Report(name, SyncPackage.NotASyncPackageMessage);
            return;
        }
        if (size > SyncPackage.MaxFileBytes)
        {
            Report(name, CompanionError.TooLarge.Message);
            return;
        }
        byte[] data;
        try
        {
            data = await File.ReadAllBytesAsync(path).ConfigureAwait(false);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return;
        }
        PairedDevice? device = null;
        var target = CompanionTarget.New;
        byte[]? plaintext = null;
        bool keyUnread = false;
        try
        {
            foreach (var candidate in _devices.Devices)
            {
                if (_unreadKeys.Contains(candidate.Id))
                {
                    keyUnread = true;
                    continue;
                }
                byte[]? key;
                try
                {
                    key = _devices.SyncKey(candidate.Id);
                    _reportedKeys.Remove(candidate.Id);
                }
                catch (CryptographicException)
                {
                    keyUnread = true;
                    _unreadKeys.Add(candidate.Id);
                    if (_reportedKeys.Add(candidate.Id))
                    {
                        Problem?.Invoke(this, KeyUnreadableMessage(candidate.Name.Length > 0 ? candidate.Name : "a phone"));
                    }
                    continue;
                }
                if (key is null) continue;
                try
                {
                    (target, plaintext) = SyncPackage.Open(data, packageId, candidate.Id, key);
                    device = candidate;
                    break;
                }
                catch (SyncPackageException e) when (e.Kind == SyncPackageErrorKind.WrongKeyOrTampered)
                {
                }
            }
        }
        catch (SyncPackageException e)
        {
            Report(name, e.Message);
            return;
        }
        if (device is null || plaintext is null)
        {
            if (keyUnread) _failed[name] = _clock();
            else Report(name, SyncPackage.WrongKeyMessage);
            return;
        }
        if (_inbox.Find(device.Id, packageId) is not null)
        {
            Delete(path);
            return;
        }
        // An upload of the same package runs: the next poll finds it received.
        if (!_inbox.TryBegin(device.Id, packageId)) return;
        try
        {
            if (_inbox.Find(device.Id, packageId) is not null)
            {
                Delete(path);
                return;
            }
            using var body = new MemoryStream(plaintext, writable: false);
            var package = await _inbox.ReceiveAsync(device.Id, packageId, target, body, body.Length, _clock(),
                                                    CancellationToken.None).ConfigureAwait(false);
            Delete(path);
            PackageReceived?.Invoke(this, new CompanionPackageReceivedEventArgs(package, device));
        }
        catch (CompanionPackageException e)
        {
            Report(name, e.Message);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            // Tried again on the next poll.
        }
        finally
        {
            _inbox.End(device.Id, packageId);
        }
    }

    private void Report(string name, string reason)
    {
        _failed[name] = _clock();
        if (_reported.Add(name)) Problem?.Invoke(this, UnreadableMessage(name, reason));
    }

    private static void Delete(string path)
    {
        try
        {
            File.Delete(path);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            // The next poll finds it received and deletes it then.
        }
    }
}
