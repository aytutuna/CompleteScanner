using System.Collections.Concurrent;
using LazyScan.Core;

namespace LazyScan.App.Scanning.Twain;

/// <summary>
/// The one thread every TWAIN call of the app is made from, so the UI thread never waits on
/// a driver. Work runs in the order it was queued, one item at a time. The TWAIN library's
/// own message loop (which receives the driver's messages and runs the transfers) is a
/// separate thread the library starts; transfers reach this thread as queued events
/// (<see cref="NTwainDriver"/>).
///
/// A driver can block indefinitely (a dialog nobody sees, a hung device). Every call
/// therefore has a time limit (<see cref="RunAsync{T}"/>; a scan's covers getting the source
/// enabled, <see cref="RunWithStartLimitAsync{T}"/>, after which the scan loop's own limits
/// apply); while a call that overran is still running, the thread is <see cref="Wedged"/> and
/// new work is refused instead of queueing behind it.
/// </summary>
internal sealed class TwainThread
{
    private sealed class Item
    {
        public bool Finished;
        public bool Overran;
        /// <summary>The work lifted its own time limit (<see cref="RunWithStartLimitAsync{T}"/>).</summary>
        public bool Released;
    }

    private readonly BlockingCollection<Action> _queue = [];
    private readonly object _gate = new();
    private int _overrunning;

    public TwainThread()
    {
        var thread = new Thread(Loop)
        {
            IsBackground = true,
            Name = "TWAIN",
        };
        // TWAIN drivers expect a single-threaded COM apartment, like a UI thread.
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
    }

    /// <summary>A call overran its time limit and has not returned yet.</summary>
    public bool Wedged
    {
        get
        {
            lock (_gate) return _overrunning > 0;
        }
    }

    private void Loop()
    {
        foreach (var work in _queue.GetConsumingEnumerable())
        {
            try
            {
                work();
            }
            catch
            {
                // RunAsync reports every failure through its task.
            }
        }
    }

    /// <summary>
    /// Runs <paramref name="work"/> on the TWAIN thread. The returned task ends when the work
    /// does, when <paramref name="timeout"/> passes (<see cref="NotResponding"/>; the work goes
    /// on, and the thread is <see cref="Wedged"/> until it returns) or when
    /// <paramref name="token"/> is cancelled (<see cref="ScanException.Cancelled"/>; the work
    /// goes on and is expected to notice the token itself), whichever comes first. The time
    /// counts from queueing, so work stuck behind a hung call also gives up. While the thread
    /// is wedged, nothing new is queued.
    /// </summary>
    /// <param name="whenAbandoned">
    /// Called on the TWAIN thread with the result of work that finished after its time limit
    /// passed (nobody receives that result), to release what it holds.
    /// </param>
    public Task<T> RunAsync<T>(Func<T> work, TimeSpan timeout, CancellationToken token = default,
                               Action<T>? whenAbandoned = null) =>
        Run(_ => work(), timeout, token, whenAbandoned);

    /// <summary>
    /// Like <see cref="RunAsync{T}"/>, but <paramref name="startTimeout"/> covers the work only
    /// until it calls the action it is given (the end of its start phase, e.g. a scan whose
    /// source is enabled); from then on it runs without a limit, ended only by
    /// <paramref name="token"/>, and has to watch its own progress.
    /// </summary>
    public Task<T> RunWithStartLimitAsync<T>(Func<Action, T> work, TimeSpan startTimeout, CancellationToken token = default) =>
        Run(work, startTimeout, token, null);

    private async Task<T> Run<T>(Func<Action, T> work, TimeSpan timeout, CancellationToken token, Action<T>? whenAbandoned)
    {
        if (Wedged) throw NotResponding();
        var item = new Item();
        var completion = new TaskCompletionSource<T>(TaskCreationOptions.RunContinuationsAsynchronously);
        var released = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        void Release()
        {
            lock (_gate)
            {
                // Too late once the caller gave up on it.
                if (item.Overran || item.Released) return;
                item.Released = true;
            }
            released.TrySetResult();
        }

        _queue.Add(() =>
        {
            T value;
            try
            {
                value = work(Release);
            }
            catch (Exception e)
            {
                lock (_gate) item.Finished = true;
                completion.TrySetException(e);
                EndItem(item);
                return;
            }
            bool abandoned;
            lock (_gate)
            {
                item.Finished = true;
                abandoned = item.Overran;
            }
            if (abandoned && whenAbandoned is not null)
            {
                try
                {
                    whenAbandoned(value);
                }
                catch (Exception e)
                {
                    System.Diagnostics.Trace.TraceWarning($"TWAIN: cleaning up after a late call failed: {e.Message}");
                }
            }
            completion.TrySetResult(value);
            EndItem(item);
        });

        bool inTime;
        try
        {
            await Task.WhenAny(completion.Task, released.Task).WaitAsync(timeout, token).ConfigureAwait(false);
            inTime = true;
        }
        catch (TimeoutException)
        {
            lock (_gate)
            {
                // It finished (or lifted its limit) just as the time ran out: go on with it.
                inTime = item.Finished || item.Released;
                if (!inTime)
                {
                    item.Overran = true;
                    _overrunning++;
                }
            }
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested)
        {
            throw ScanException.Cancelled();
        }
        if (!inTime) throw NotResponding();
        try
        {
            return await completion.Task.WaitAsync(token).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested)
        {
            throw ScanException.Cancelled();
        }
    }

    /// <summary>An item's work and clean-up are done: an overrun one no longer wedges the thread.</summary>
    private void EndItem(Item item)
    {
        lock (_gate)
        {
            if (item.Overran) _overrunning--;
        }
    }

    /// <summary>The error for a driver that does not answer.</summary>
    public static ScanException NotResponding() => ScanException.ScanFailed(
        "The scanner's TWAIN driver is not responding. If it shows a window, close it; otherwise "
        + "turn the scanner off and on, or restart Lazy Scan.");
}
