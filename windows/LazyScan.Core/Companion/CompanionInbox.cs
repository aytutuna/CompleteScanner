namespace LazyScan.Core;

// The desktop's side of the companion link (Windows now; the Mac server later reuses the protocol
// with its own host). C# only for now: see CONTRACTS.md, "The phone companion".

/// <summary>A package a paired phone sent, checked and waiting to be added to the queue.</summary>
/// <param name="Path">The package file in the inbox; <see cref="CompanionInbox.Release"/> deletes it once imported.</param>
public sealed record ReceivedPackage(string DeviceId, string PackageId, string Path, CompanionDocument Document,
                                     CompanionTarget Target, DateTimeOffset Received);

/// <summary>A package received before (from received.json).</summary>
public sealed class ReceivedEntry
{
    public string PackageId { get; set; } = "";
    public int PageCount { get; set; }
    public DateTimeOffset? Received { get; set; }
}

/// <summary>The contents of a phone's received.json.</summary>
public sealed class ReceivedLog
{
    public List<ReceivedEntry> Packages { get; set; } = [];
}

/// <summary>
/// Where uploads from paired phones land (one folder per phone under the inbox folder). A body is
/// streamed to "&lt;id&gt;.part", must be exactly as long as announced, is read in full as a
/// <see cref="CompanionPackage"/> (through <see cref="ZipStoreReader"/>: every picture's checksum and
/// format checked) and only then renamed to "&lt;id&gt;.lsdoc" and logged in received.json, so a
/// package is either received whole and valid or not at all. Uploads are idempotent by package id:
/// one received before is answered from the log (the last <see cref="MaxLoggedPackages"/> per phone),
/// and the same id cannot be received twice at once. Ids are checked by
/// <see cref="CompanionProtocol.IsValidId"/>, so they are safe file names. Safe to use from any thread.
/// </summary>
public sealed class CompanionInbox
{
    public const int MaxLoggedPackages = 1000;
    public const string LogFileName = "received.json";

    private readonly string _directory;
    private readonly object _gate = new();
    private readonly HashSet<string> _inProgress = [];

    public CompanionInbox(string directory)
    {
        _directory = directory;
    }

    /// <summary>The default inbox: %LOCALAPPDATA%\Lazy Scan\Companion\Inbox.</summary>
    public static string DefaultDirectory =>
        System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                               "Lazy Scan", "Companion", "Inbox");

    /// <summary>The package <paramref name="packageId"/> received from <paramref name="deviceId"/> before; null when it was not.</summary>
    public ReceivedEntry? Find(string deviceId, string packageId)
    {
        Check(deviceId, packageId);
        lock (_gate)
        {
            return Log(deviceId).Packages.FirstOrDefault(p => p.PackageId == packageId);
        }
    }

    /// <summary>Claims the package id for one upload; false while another upload of it runs.</summary>
    public bool TryBegin(string deviceId, string packageId)
    {
        Check(deviceId, packageId);
        lock (_gate) return _inProgress.Add(Key(deviceId, packageId));
    }

    /// <summary>Ends the claim of <see cref="TryBegin"/>.</summary>
    public void End(string deviceId, string packageId)
    {
        lock (_gate) _inProgress.Remove(Key(deviceId, packageId));
    }

    /// <summary>
    /// Receives the package: copies exactly <paramref name="length"/> bytes of
    /// <paramref name="body"/>, checks it and logs it. Throws <see cref="CompanionPackageException"/>
    /// for a package that is refused, <see cref="EndOfStreamException"/> when the body ends early,
    /// <see cref="IOException"/> when it cannot be stored; nothing is kept then.
    /// </summary>
    public async Task<ReceivedPackage> ReceiveAsync(string deviceId, string packageId, CompanionTarget target, Stream body,
                                                    long length, DateTimeOffset now, CancellationToken cancellation)
    {
        Check(deviceId, packageId);
        string folder = DeviceFolder(deviceId);
        Directory.CreateDirectory(folder);
        string part = System.IO.Path.Combine(folder, packageId + ".part");
        string final = System.IO.Path.Combine(folder, packageId + "." + CompanionPackage.FileExtension);
        try
        {
            await using (var file = new FileStream(part, FileMode.Create, FileAccess.Write, FileShare.None, 81920,
                                                   FileOptions.Asynchronous))
            {
                var buffer = new byte[81920];
                long remaining = length;
                while (remaining > 0)
                {
                    int read = await body.ReadAsync(buffer.AsMemory(0, (int)Math.Min(buffer.Length, remaining)), cancellation).ConfigureAwait(false);
                    if (read == 0) throw new EndOfStreamException("The upload ended before all of it arrived.");
                    await file.WriteAsync(buffer.AsMemory(0, read), cancellation).ConfigureAwait(false);
                    remaining -= read;
                }
            }
            var document = CompanionPackage.ReadFile(part);
            File.Move(part, final, overwrite: true);
            lock (_gate)
            {
                var log = Log(deviceId);
                log.Packages.RemoveAll(p => p.PackageId == packageId);
                log.Packages.Add(new ReceivedEntry { PackageId = packageId, PageCount = document.Pages.Count, Received = now });
                if (log.Packages.Count > MaxLoggedPackages) log.Packages.RemoveRange(0, log.Packages.Count - MaxLoggedPackages);
                if (!StoreFiles.Write(log, LogPath(deviceId)))
                {
                    File.Delete(final);
                    throw new IOException("The list of received documents could not be saved.");
                }
            }
            return new ReceivedPackage(deviceId, packageId, final, document, target, now);
        }
        finally
        {
            TryDelete(part);
        }
    }

    /// <summary>Deletes a received package's file once its pages are in the queue; its log entry stays, so a retry is still a duplicate.</summary>
    public void Release(ReceivedPackage package) => TryDelete(package.Path);

    /// <summary>
    /// The packages received but not released (the app ended before adding them), oldest first,
    /// each read again; a file that no longer reads is deleted.
    /// </summary>
    public IReadOnlyList<ReceivedPackage> Pending()
    {
        var pending = new List<ReceivedPackage>();
        if (!Directory.Exists(_directory)) return pending;
        foreach (string folder in Directory.GetDirectories(_directory))
        {
            string deviceId = System.IO.Path.GetFileName(folder);
            if (!CompanionProtocol.IsValidId(deviceId)) continue;
            foreach (string path in Directory.GetFiles(folder, "*." + CompanionPackage.FileExtension))
            {
                string packageId = System.IO.Path.GetFileNameWithoutExtension(path);
                if (!CompanionProtocol.IsValidId(packageId)) continue;
                try
                {
                    var document = CompanionPackage.ReadFile(path);
                    pending.Add(new ReceivedPackage(deviceId, packageId, path, document, CompanionTarget.New,
                                                    new DateTimeOffset(File.GetLastWriteTimeUtc(path), TimeSpan.Zero)));
                }
                catch (IOException)
                {
                    TryDelete(path);
                }
            }
        }
        return [.. pending.OrderBy(p => p.Received)];
    }

    /// <summary>Deletes everything received from <paramref name="deviceId"/> (the phone was removed).</summary>
    public void RemoveDevice(string deviceId)
    {
        if (!CompanionProtocol.IsValidId(deviceId)) return;
        try
        {
            string folder = DeviceFolder(deviceId);
            if (Directory.Exists(folder)) Directory.Delete(folder, recursive: true);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            System.Diagnostics.Trace.TraceWarning($"Could not delete a phone's inbox: {e.Message}");
        }
    }

    private string DeviceFolder(string deviceId) => System.IO.Path.Combine(_directory, deviceId);

    private string LogPath(string deviceId) => System.IO.Path.Combine(DeviceFolder(deviceId), LogFileName);

    private ReceivedLog Log(string deviceId) => StoreFiles.Load<ReceivedLog>(LogPath(deviceId)) ?? new ReceivedLog();

    private static string Key(string deviceId, string packageId) => deviceId + "/" + packageId;

    private static void Check(string deviceId, string packageId)
    {
        if (!CompanionProtocol.IsValidId(deviceId)) throw new ArgumentException("The phone's id is not valid.", nameof(deviceId));
        if (!CompanionProtocol.IsValidId(packageId)) throw new ArgumentException("The package id is not valid.", nameof(packageId));
    }

    private static void TryDelete(string path)
    {
        try
        {
            if (File.Exists(path)) File.Delete(path);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            System.Diagnostics.Trace.TraceWarning($"Could not delete {System.IO.Path.GetFileName(path)}: {e.Message}");
        }
    }
}
