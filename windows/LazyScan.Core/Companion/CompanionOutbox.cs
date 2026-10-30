using System.Security.Cryptography;

namespace LazyScan.Core;

/// <summary>A file waiting for a phone (an entry of a phone's outbox.json).</summary>
public sealed class OutboxEntry
{
    public string Id { get; set; } = "";
    public string Name { get; set; } = "";
    public string ContentType { get; set; } = "";
    public long ByteCount { get; set; }
    public DateTimeOffset? Created { get; set; }
}

/// <summary>The contents of a phone's outbox.json.</summary>
public sealed class OutboxIndex
{
    public List<OutboxEntry> Items { get; set; } = [];
}

/// <summary>
/// What the desktop sends a phone: files copied into the phone's folder under the outbox folder
/// ("&lt;id&gt;.bin" plus outbox.json), listed and fetched by the phone and deleted when it
/// acknowledges them (<c>DELETE /v1/outbox/{id}</c>) or after <see cref="KeepFor"/>. The phone
/// pulls, since it cannot be reached while its app is closed; a listing may wait
/// (<see cref="WaitAsync"/>) until something arrives. Safe to use from any thread.
/// </summary>
public sealed class CompanionOutbox
{
    public static readonly TimeSpan KeepFor = TimeSpan.FromDays(7);
    public const string IndexFileName = "outbox.json";

    private readonly string _directory;
    private readonly object _gate = new();
    private readonly Dictionary<string, TaskCompletionSource> _waiters = [];

    public CompanionOutbox(string directory)
    {
        _directory = directory;
    }

    /// <summary>The default outbox: %LOCALAPPDATA%\Lazy Scan\Companion\Outbox.</summary>
    public static string DefaultDirectory =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                     "Lazy Scan", "Companion", "Outbox");

    /// <summary>Copies <paramref name="sourcePath"/> into the phone's outbox under <paramref name="name"/>.</summary>
    public OutboxItem Add(string deviceId, string sourcePath, string name, string contentType, DateTimeOffset now)
    {
        CheckDevice(deviceId);
        string id = Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(16));
        string folder = Path.Combine(_directory, deviceId);
        Directory.CreateDirectory(folder);
        string target = Path.Combine(folder, id + ".bin");
        File.Copy(sourcePath, target);
        var entry = new OutboxEntry
        {
            Id = id,
            Name = Path.GetFileName(name),
            ContentType = contentType,
            ByteCount = new FileInfo(target).Length,
            Created = now,
        };
        TaskCompletionSource? waiter;
        lock (_gate)
        {
            var index = Index(deviceId);
            index.Items.Add(entry);
            if (!StoreFiles.Write(index, IndexPath(deviceId)))
            {
                File.Delete(target);
                throw new IOException("The phone's outbox could not be saved.");
            }
            _waiters.Remove(deviceId, out waiter);
        }
        waiter?.TrySetResult();
        return ToItem(entry);
    }

    /// <summary>What waits for the phone, oldest first; items past <see cref="KeepFor"/> or without their file are dropped.</summary>
    public IReadOnlyList<OutboxItem> List(string deviceId, DateTimeOffset now)
    {
        CheckDevice(deviceId);
        lock (_gate)
        {
            var index = Index(deviceId);
            var stale = index.Items.Where(e => !CompanionProtocol.IsValidId(e.Id) || e.Created is not { } created
                                               || now - created > KeepFor || !File.Exists(FilePath(deviceId, e.Id))).ToList();
            if (stale.Count > 0)
            {
                foreach (var entry in stale)
                {
                    index.Items.Remove(entry);
                    if (CompanionProtocol.IsValidId(entry.Id)) TryDelete(FilePath(deviceId, entry.Id));
                }
                StoreFiles.Write(index, IndexPath(deviceId));
            }
            return [.. index.Items.Select(ToItem)];
        }
    }

    /// <summary>The item <paramref name="id"/> and its file, open for reading; null when there is none.</summary>
    public (OutboxItem Item, FileStream Stream)? Open(string deviceId, string id)
    {
        CheckDevice(deviceId);
        if (!CompanionProtocol.IsValidId(id)) return null;
        OutboxEntry? entry;
        lock (_gate) entry = Index(deviceId).Items.FirstOrDefault(e => e.Id == id);
        if (entry is null) return null;
        try
        {
            var stream = new FileStream(FilePath(deviceId, id), FileMode.Open, FileAccess.Read, FileShare.Read | FileShare.Delete,
                                        81920, FileOptions.Asynchronous);
            return (ToItem(entry), stream);
        }
        catch (FileNotFoundException)
        {
            return null;
        }
    }

    /// <summary>Deletes the item (the phone has it); false when there was none.</summary>
    public bool Remove(string deviceId, string id)
    {
        CheckDevice(deviceId);
        if (!CompanionProtocol.IsValidId(id)) return false;
        lock (_gate)
        {
            var index = Index(deviceId);
            if (index.Items.RemoveAll(e => e.Id == id) == 0) return false;
            StoreFiles.Write(index, IndexPath(deviceId));
        }
        TryDelete(FilePath(deviceId, id));
        return true;
    }

    /// <summary>Deletes the phone's outbox (it was removed).</summary>
    public void RemoveDevice(string deviceId)
    {
        if (!CompanionProtocol.IsValidId(deviceId)) return;
        TaskCompletionSource? waiter;
        lock (_gate)
        {
            _waiters.Remove(deviceId, out waiter);
            try
            {
                string folder = Path.Combine(_directory, deviceId);
                if (Directory.Exists(folder)) Directory.Delete(folder, recursive: true);
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                System.Diagnostics.Trace.TraceWarning($"Could not delete a phone's outbox: {e.Message}");
            }
        }
        waiter?.TrySetResult();
    }

    /// <summary>Completes when something is added for the phone, after <paramref name="timeout"/>, or when cancelled.</summary>
    public async Task WaitAsync(string deviceId, TimeSpan timeout, CancellationToken cancellation)
    {
        CheckDevice(deviceId);
        Task signal;
        lock (_gate)
        {
            if (!_waiters.TryGetValue(deviceId, out var waiter))
            {
                waiter = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
                _waiters[deviceId] = waiter;
            }
            signal = waiter.Task;
        }
        try
        {
            await signal.WaitAsync(timeout, cancellation).ConfigureAwait(false);
        }
        catch (TimeoutException)
        {
            // Nothing arrived: the listing answers with what there is.
        }
    }

    private static OutboxItem ToItem(OutboxEntry entry) =>
        new(entry.Id, entry.Name, entry.ContentType, entry.ByteCount, entry.Created ?? DateTimeOffset.UnixEpoch);

    private OutboxIndex Index(string deviceId) => StoreFiles.Load<OutboxIndex>(IndexPath(deviceId)) ?? new OutboxIndex();

    private string IndexPath(string deviceId) => Path.Combine(_directory, deviceId, IndexFileName);

    private string FilePath(string deviceId, string id) => Path.Combine(_directory, deviceId, id + ".bin");

    private static void CheckDevice(string deviceId)
    {
        if (!CompanionProtocol.IsValidId(deviceId)) throw new ArgumentException("The phone's id is not valid.", nameof(deviceId));
    }

    private static void TryDelete(string path)
    {
        try
        {
            if (File.Exists(path)) File.Delete(path);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            System.Diagnostics.Trace.TraceWarning($"Could not delete {Path.GetFileName(path)}: {e.Message}");
        }
    }
}
