using System.IO;
using System.Windows.Threading;
using CompleteScanner.App.Services;
using CompleteScanner.App.Services.Companion;
using CompleteScanner.Core;

namespace CompleteScanner.App;

/// <summary>
/// The phone link (<see cref="CompanionService"/>): started when a phone is paired (or the Phone
/// window opens), receiving only on trusted networks, and documents from paired phones added to the
/// queue on their own, with a notification. Documents phones put in the cloud sync folder (C2) come
/// the same way: the service watches the folder while it runs and receives them into the inbox.
/// </summary>
public sealed partial class AppViewModel
{
    /// <summary>One instance per user session receives from phones; others say so.</summary>
    private const string CompanionMutexName = @"Local\CompleteScanner.PhoneLink";

    private CompanionService? _companion;
    private Mutex? _companionMutex;
    private WindowsNetworkSource? _companionNetworks;
    /// <summary>Documents from phones waiting to be added to the queue, oldest first, with the phone's name.</summary>
    private readonly Queue<(ReceivedPackage Package, string PhoneName)> _phoneDocuments = new();
    /// <summary>Retries adding waiting documents while the app is busy or the queue does not collect pages.</summary>
    private DispatcherTimer? _phoneRetryTimer;
    /// <summary>The queue's page count, for phones asking from the server's threads.</summary>
    private volatile int _queuedPageCount;

    /// <summary>The phone link; null until it is started, and when another window of the app has it.</summary>
    public CompanionService? Companion => _companion;

    /// <summary>Another window of the app receives from phones (<see cref="CompanionListenState.Elsewhere"/>).</summary>
    public bool CompanionElsewhere { get; private set; }

    /// <summary>Why the link could not start; null when it started or was not tried.</summary>
    public string? CompanionError { get; private set; }

    /// <summary>The last file in the cloud folder that could not be read; null since the folder was chosen.</summary>
    public string? SyncFolderProblem { get; private set; }

    /// <summary>
    /// Asks the user whether a phone that presented the pairing code may pair (the Phone window shows
    /// it). Without anyone to ask, the pairing is allowed: the code was only on this screen.
    /// </summary>
    public Func<PairRequest, CancellationToken, Task<bool>>? ConfirmPhonePairing { get; set; }

    /// <summary>Raised on the UI thread with the message after a phone's pages were added, or are waiting.</summary>
    public event Action<string>? PhoneDocumentArrived;

    /// <summary>Raised on the UI thread when the link's status, phones or networks changed.</summary>
    public event Action? CompanionChanged;

    /// <summary>"3 pages from Aytu's iPhone are waiting: …"; null when nothing waits.</summary>
    public string? PhoneDocumentsWaitingMessage { get; private set; }

    /// <summary>The queue can take a phone's pages now: it collects pages and nothing else is going on.</summary>
    public bool CanTakePhonePages =>
        !IsBusy && PhotoImport.IsOffered(Settings) && !IsTurningOverByHand && !ShowPhotoReview && !ShowIdCardReview;

    /// <summary>
    /// Starts the phone link at launch when a phone is paired (nothing listens otherwise, and no
    /// certificate is made). <paramref name="options"/> replaces the platform's pieces (harnesses).
    /// </summary>
    public void StartCompanionIfPaired(CompanionServiceOptions? options = null)
    {
        string settings = options?.SettingsDirectory ?? CompanionSettingsDirectory;
        if (new PairedDeviceStore(settings).Count > 0) EnsureCompanion(options);
    }

    /// <summary>The phone link, started now if it was not (the Phone window opens); null when another window has it.</summary>
    public CompanionService? EnsureCompanion(CompanionServiceOptions? options = null)
    {
        if (_companion is not null || CompanionElsewhere) return _companion;
        _companionMutex ??= new Mutex(false, CompanionMutexName, out _);
        bool owned;
        try
        {
            owned = _companionMutex.WaitOne(0);
        }
        catch (AbandonedMutexException)
        {
            owned = true;
        }
        if (!owned)
        {
            CompanionElsewhere = true;
            _companionMutex.Dispose();
            _companionMutex = null;
            return null;
        }
        try
        {
            if (options is null)
            {
                var certificates = new CompanionCertificateStore();
                _companionNetworks = new WindowsNetworkSource();
                options = new CompanionServiceOptions
                {
                    SettingsDirectory = CompanionSettingsDirectory,
                    DataDirectory = CompanionDataDirectory,
                    Certificate = certificates.Current,
                    RenewCertificate = certificates.Renew,
                    Networks = _companionNetworks,
                    Advertiser = new WindowsDnsSdAdvertiser(),
                    DesktopName = Environment.MachineName,
                };
            }
            var companion = new CompanionService(options);
            companion.Router.ApprovePairing = ApprovePhonePairingAsync;
            companion.Router.QueuedPages = () => _queuedPageCount;
            companion.PackageReceived += (_, e) =>
                _dispatcher.BeginInvoke(() => QueuePhoneDocument(e.Package, e.Device.Name));
            companion.Changed += (_, _) => _dispatcher.BeginInvoke(() => CompanionChanged?.Invoke());
            companion.SyncFolderProblem += (_, message) => _dispatcher.BeginInvoke(() =>
            {
                SyncFolderProblem = message;
                StatusMessage = message;
                NotifyAll();
                CompanionChanged?.Invoke();
            });
            _companion = companion;
            _queuedPageCount = ScannedPages.Count;
            ScannedPages.CollectionChanged += (_, _) => _queuedPageCount = ScannedPages.Count;
            _ = StartCompanionAsync(companion);
            QueuePendingPhoneDocuments(companion);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or InvalidOperationException
                                      or System.Runtime.InteropServices.COMException)
        {
            CompanionError = e.Message;
            System.Diagnostics.Trace.TraceError($"The phone link did not start: {e}");
        }
        return _companion;
    }

    /// <summary>Chooses the cloud folder phones put documents in (null: none); false when that could not be saved.</summary>
    public bool SetPhoneSyncFolder(string? path)
    {
        if (_companion is null || !_companion.SetSyncFolder(path)) return false;
        SyncFolderProblem = null;
        CompanionChanged?.Invoke();
        return true;
    }

    /// <summary>Documents received before the app last closed, not yet in the queue; an inbox that cannot be read is left for next time.</summary>
    private void QueuePendingPhoneDocuments(CompanionService companion)
    {
        IReadOnlyList<ReceivedPackage> pending;
        try
        {
            pending = companion.Inbox.Pending();
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            System.Diagnostics.Trace.TraceWarning($"Could not read the documents waiting from phones: {e.Message}");
            return;
        }
        var names = companion.Devices.Devices.ToDictionary(d => d.Id, d => d.Name);
        foreach (var package in pending)
        {
            QueuePhoneDocument(package, names.GetValueOrDefault(package.DeviceId, "a phone"));
        }
    }

    private static string CompanionSettingsDirectory =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "CompleteScanner");

    private static string CompanionDataDirectory =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CompleteScanner", "Companion");

    private async Task StartCompanionAsync(CompanionService companion)
    {
        try
        {
            await companion.StartAsync();
        }
        catch (Exception e)
        {
            System.Diagnostics.Trace.TraceError($"The phone link did not start: {e}");
        }
    }

    /// <summary>Asks <see cref="ConfirmPhonePairing"/> on the UI thread; allows the pairing when nobody is there to ask.</summary>
    private async Task<bool> ApprovePhonePairingAsync(PairRequest request, CancellationToken cancellation)
    {
        var ask = await _dispatcher.InvokeAsync(() => ConfirmPhonePairing);
        if (ask is null) return true;
        return await await _dispatcher.InvokeAsync(() => ask(request, cancellation));
    }

    /// <summary>A document a phone sent: added to the queue now, or as soon as the queue can take it.</summary>
    private void QueuePhoneDocument(ReceivedPackage package, string phoneName)
    {
        _phoneDocuments.Enqueue((package, phoneName.Length > 0 ? phoneName : "a phone"));
        AddWaitingPhoneDocuments();
    }

    /// <summary>Adds the oldest waiting document when the queue can take it; otherwise says what waits and tries again shortly.</summary>
    private void AddWaitingPhoneDocuments()
    {
        if (_phoneDocuments.Count == 0)
        {
            _phoneRetryTimer?.Stop();
            if (PhoneDocumentsWaitingMessage is not null)
            {
                PhoneDocumentsWaitingMessage = null;
                NotifyAll();
            }
            return;
        }
        if (!CanTakePhonePages)
        {
            string waiting = WaitingMessage();
            if (waiting != PhoneDocumentsWaitingMessage)
            {
                PhoneDocumentsWaitingMessage = waiting;
                // Only the reason the user can act on is announced; being busy passes on its own.
                if (!IsBusy) PhoneDocumentArrived?.Invoke(waiting);
                NotifyAll();
            }
            if (_phoneRetryTimer is null)
            {
                _phoneRetryTimer = new DispatcherTimer(DispatcherPriority.Background, _dispatcher) { Interval = TimeSpan.FromSeconds(1) };
                _phoneRetryTimer.Tick += (_, _) => AddWaitingPhoneDocuments();
            }
            _phoneRetryTimer.Start();
            return;
        }
        _phoneRetryTimer?.Stop();
        var (package, phoneName) = _phoneDocuments.Dequeue();
        PhoneDocumentsWaitingMessage = null;
        _ = AddPhoneDocumentAsync(package, phoneName);
    }

    private string WaitingMessage()
    {
        int pages = _phoneDocuments.Sum(d => d.Package.Document.Pages.Count);
        string what = pages == 1 ? "1 page" : $"{pages} pages";
        string from = _phoneDocuments.Select(d => d.PhoneName).Distinct().Count() == 1 ? _phoneDocuments.Peek().PhoneName : "your phones";
        string are = pages == 1 ? "is" : "are";
        string them = pages == 1 ? "it" : "them";
        return PhotoImport.IsOffered(Settings)
            ? $"{what} from {from} will be added to the queue when the current step is done."
            : $"{what} from {from} {are} waiting: choose Document mode or a document task to add {them} to the queue.";
    }

    /// <summary>
    /// Decodes, spools and queues the document's pages; the package is then released from the
    /// inbox. A document with a picture that cannot be read is released too (it never will be); one
    /// that could not be spooled (the disk is full, the folder cannot be made) stays in the inbox and
    /// is added the next time the app starts.
    /// </summary>
    private async Task AddPhoneDocumentAsync(ReceivedPackage package, string phoneName)
    {
        int added = 0;
        string? problem = null;
        bool unreadable = false;
        await RunExclusive(async token =>
        {
            SavedBarPaths = null;
            StatusMessage = $"Adding pages from {phoneName}…";
            NotifyAll();
            bool queueHasPages = ScannedPages.Count > 0;
            string spoolDirectory = _spool.Directory;
            List<ScannedPage> pages;
            try
            {
                // The pictures are decoded from the package's bytes in memory: a failure here is the picture's.
                pages = await Task.Run(() => CompanionPages.ToScannedPages(package.Document, package.Target, queueHasPages,
                                                                           WpfImageCodec.Decode), token);
            }
            catch (Exception e) when (e is NotSupportedException or System.IO.FileFormatException or ArgumentException
                                          or InvalidOperationException or IOException)
            {
                unreadable = true;
                problem = $"The document from {phoneName} could not be added: one of its pictures could not be read ({e.Message}).";
                StatusMessage = "Ready.";
                return;
            }
            List<PageItem> spooled;
            try
            {
                spooled = await Task.Run(() => SpoolPages(pages, spoolDirectory).Select(p => new PageItem(p)).ToList(), token);
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                problem = $"The document from {phoneName} could not be added to the queue now ({e.Message.TrimEnd('.')}). "
                          + "It is kept on this PC and added the next time Lazy Scan starts.";
                StatusMessage = "Ready.";
                return;
            }
            foreach (var item in spooled) ScannedPages.Add(item);
            added = spooled.Count;
            if (spooled.Count > 0) SetLastScan(ScanHistory.MakePreview(spooled[^1].Page.Image, CanvasPreviewMaxSide));
            if (PageProcessor.ReadsBarcodes(Settings)) _readBarcodesAfterWork = true;
            StatusMessage = $"{CompanionProtocol.AddedMessage(added, phoneName)} {ScannedPages.Count} in queue.";
        });
        if (problem is not null)
        {
            ErrorMessage = problem;
            NotifyAll();
        }
        // A document whose import was cancelled or could not be spooled stays in the inbox: it is
        // added the next time the app starts.
        if (added > 0 || unreadable) _companion?.Inbox.Release(package);
        if (added > 0) PhoneDocumentArrived?.Invoke(CompanionProtocol.AddedMessage(added, phoneName));
        AddWaitingPhoneDocuments();
    }

    /// <summary>On app exit: the phone link stops listening and withdraws its advertisement.</summary>
    private void ShutdownCompanion()
    {
        _phoneRetryTimer?.Stop();
        if (_companion is { } companion)
        {
            _companion = null;
            try
            {
                companion.DisposeAsync().AsTask().Wait(TimeSpan.FromSeconds(5));
            }
            catch (Exception e)
            {
                System.Diagnostics.Trace.TraceWarning($"The phone link did not stop cleanly: {e.Message}");
            }
        }
        _companionNetworks?.Dispose();
        _companionNetworks = null;
        if (_companionMutex is { } mutex)
        {
            _companionMutex = null;
            try
            {
                mutex.ReleaseMutex();
            }
            catch (ApplicationException)
            {
                // Not held by this thread: closing the handle releases it.
            }
            mutex.Dispose();
        }
    }
}
