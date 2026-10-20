using System.Collections.Concurrent;

namespace CompleteScanner.App.Scanning;

/// <summary>
/// The one thread that touches WIA Automation (wiaaut.dll) in this process: a background STA
/// thread that runs WIA work one item at a time, in the order it was asked for. Every WIA object
/// is created, used and released on it, by every WIA backend and session alike.
///
/// WIA Automation keeps state shared by the whole process, and its objects are apartment-threaded:
/// used from several STA threads at once, objects created on one thread are handed to another and
/// are released or torn down under it (RPC_E_DISCONNECTED, "COM object that has been separated from
/// its underlying RCW", and at worst an access violation inside CoCreateInstance, which ends the
/// process). One thread, one item at a time, rules that out.
/// </summary>
internal static class WiaApartment
{
    private static readonly BlockingCollection<Action> Queue = [];
    private static readonly Lazy<Thread> Worker = new(Start, LazyThreadSafetyMode.ExecutionAndPublication);
    private static int _active;
    private static int _mostAtOnce;
    private static long _completed;

    /// <summary>The managed id of the WIA thread (it is started if it was not yet).</summary>
    internal static int ThreadId => Worker.Value.ManagedThreadId;

    /// <summary>The most WIA work items that ever ran at the same time: 1 once any has run (harnesses).</summary>
    internal static int MostAtOnce => Volatile.Read(ref _mostAtOnce);

    /// <summary>How many WIA work items have finished (harnesses).</summary>
    internal static long Completed => Interlocked.Read(ref _completed);

    /// <summary>
    /// Runs <paramref name="work"/> on the WIA thread after the work asked for before it. The task
    /// completes (or faults with its exception) off that thread, so a continuation never holds it up.
    /// </summary>
    public static Task<T> Run<T>(Func<T> work)
    {
        var done = new TaskCompletionSource<T>(TaskCreationOptions.RunContinuationsAsynchronously);
        _ = Worker.Value;
        Queue.Add(() =>
        {
            try
            {
                done.SetResult(work());
            }
            catch (Exception e)
            {
                done.SetException(e);
            }
        });
        return done.Task;
    }

    private static Thread Start()
    {
        var thread = new Thread(Loop)
        {
            IsBackground = true,
            Name = "WIA",
        };
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        return thread;
    }

    private static void Loop()
    {
        // Waiting for the next item on an STA thread pumps COM messages, as the apartment requires.
        foreach (var item in Queue.GetConsumingEnumerable())
        {
            int active = Interlocked.Increment(ref _active);
            int most;
            while (active > (most = Volatile.Read(ref _mostAtOnce))
                   && Interlocked.CompareExchange(ref _mostAtOnce, active, most) != most)
            {
            }
            try
            {
                item();
            }
            catch (Exception e)
            {
                // Run catches the work's exceptions; nothing else may end the WIA thread.
                System.Diagnostics.Trace.TraceWarning($"WIA work failed: {e.Message}");
            }
            finally
            {
                Interlocked.Decrement(ref _active);
                Interlocked.Increment(ref _completed);
            }
        }
    }
}
