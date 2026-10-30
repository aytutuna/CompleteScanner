using System.Diagnostics;
using System.Globalization;
using System.IO.Pipes;
using LazyScan.Core;

namespace LazyScan.TwainHelper;

/// <summary>
/// CompleteScanner's 32-bit TWAIN helper. Started by the app only:
/// <c>LazyScan.TwainHelper.exe --pipe NAME --parent PID [--simulate]</c>. It connects to
/// the app's pipe (which only the current user may open), serves TWAIN requests on its main
/// thread (single-threaded apartment, as drivers expect) and exits when the app asks, when the
/// pipe closes, or when the app's process ends. With <c>--simulate</c> it offers stand-in
/// scanners instead of loading TWAIN, for the app's tests.
/// </summary>
internal static class Program
{
    /// <summary>How long the helper waits for its own requests to finish after the app went away.</summary>
    private static readonly TimeSpan ExitGrace = TimeSpan.FromSeconds(5);

    [STAThread]
    private static int Main(string[] args)
    {
        string? pipeName = null;
        int parent = 0;
        bool simulate = false;
        for (int i = 0; i < args.Length; i++)
        {
            switch (args[i])
            {
                case "--pipe" when i + 1 < args.Length:
                    pipeName = args[++i];
                    break;
                case "--parent" when i + 1 < args.Length:
                    int.TryParse(args[++i], NumberStyles.None, CultureInfo.InvariantCulture, out parent);
                    break;
                case "--simulate":
                    simulate = true;
                    break;
            }
        }
        if (string.IsNullOrEmpty(pipeName))
        {
            Console.Error.WriteLine("Lazy Scan starts this helper itself when a scanner needs it.");
            return 2;
        }
        WatchParent(parent);

        using var pipe = new NamedPipeClientStream(".", pipeName, PipeDirection.InOut,
                                                   PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
        try
        {
            pipe.Connect(30_000);
        }
        catch (Exception e) when (e is TimeoutException or IOException or UnauthorizedAccessException)
        {
            Console.Error.WriteLine($"Could not connect to Lazy Scan: {e.Message}");
            return 3;
        }

        ITwainHelperHost host = simulate ? new SimulatedTwainHost() : new NTwainHelperHost();
        var server = new TwainHelperServer(pipe, host, IntPtr.Size * 8);
        // A driver call that never returns must not keep the helper alive once the app is gone.
        server.Disconnected += () => ExitAfter(ExitGrace);
        server.Run();
        return 0;
    }

    /// <summary>Exits when the app's process ends, even if the pipe somehow stays open.</summary>
    private static void WatchParent(int processId)
    {
        if (processId <= 0) return;
        Process parent;
        try
        {
            parent = Process.GetProcessById(processId);
        }
        catch (ArgumentException)
        {
            // Already gone.
            Environment.Exit(0);
            return;
        }
        new Thread(() =>
        {
            parent.WaitForExit();
            Environment.Exit(0);
        })
        { IsBackground = true, Name = "App watcher" }.Start();
    }

    private static void ExitAfter(TimeSpan delay)
    {
        new Thread(() =>
        {
            Thread.Sleep(delay);
            Environment.Exit(0);
        })
        { IsBackground = true, Name = "Exit timer" }.Start();
    }
}
