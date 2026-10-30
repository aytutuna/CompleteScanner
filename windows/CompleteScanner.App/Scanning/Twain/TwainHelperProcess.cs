using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using CompleteScanner.Core;
using Microsoft.Win32.SafeHandles;

namespace CompleteScanner.App.Scanning.Twain;

/// <summary>How the app starts its 32-bit TWAIN helper.</summary>
/// <param name="HelperPath">CompleteScanner.TwainHelper.exe; the build puts it next to the app.</param>
/// <param name="Simulate">Start the helper with its stand-in scanners instead of TWAIN (for tests).</param>
/// <param name="StartTimeout">How long the helper has to connect to the app's pipe.</param>
internal sealed record TwainHelperOptions(string HelperPath, bool Simulate = false, TimeSpan? StartTimeout = null,
                                          TwainHelperTimeouts? Timeouts = null)
{
    public const string FileName = "CompleteScanner.TwainHelper.exe";

    public static TwainHelperOptions Default => new(Path.Combine(AppContext.BaseDirectory, FileName));

    public TimeSpan ConnectTimeout => StartTimeout ?? TimeSpan.FromSeconds(30);

    public TwainHelperTimeouts Limits => Timeouts ?? TwainHelperTimeouts.Default;
}

/// <summary>
/// The app's one 32-bit TWAIN helper process, started when first needed and again after it
/// stopped. The two talk over a named pipe with a random name that only the current user may
/// open, never from the network, created by the app with a single instance and checked to be
/// opened by the process the app started. The helper is tied to the app: it is in a job that
/// ends it when the app's handle to the job closes (the app exits or crashes), it watches the
/// app's process, and it exits when the pipe closes. When the connection is lost (the helper
/// crashed, or did not answer in time), the process is ended; the next call starts a new one.
/// </summary>
internal sealed class TwainHelperProcess : IDisposable
{
    private readonly TwainHelperOptions _options;
    private readonly object _gate = new();
    private Process? _process;
    private TwainHelperConnection? _connection;
    private KillOnCloseJob? _job;
    /// <summary>Why the helper cannot run at all (missing, or no 32-bit .NET); kept until <see cref="Retry"/>.</summary>
    private string? _permanentFailure;
    private bool _disposed;

    public TwainHelperProcess(TwainHelperOptions options) => _options = options;

    /// <summary>The helper's process id while it runs.</summary>
    public int? ProcessId
    {
        get
        {
            lock (_gate) return _connection is { IsAlive: true } && _process is { } process ? process.Id : null;
        }
    }

    /// <summary>Why the helper cannot run at all (missing, no 32-bit .NET, refused by Windows); null when it may.</summary>
    public string? PermanentFailure
    {
        get
        {
            lock (_gate) return _permanentFailure;
        }
    }

    /// <summary>The connection to the running helper, starting one first when none runs.</summary>
    /// <exception cref="ScanException">The helper could not be started.</exception>
    public TwainHelperConnection Connect()
    {
        lock (_gate)
        {
            if (_disposed) throw ScanException.SessionFailed("Lazy Scan is closing.");
            if (_connection is { IsAlive: true } live) return live;
            EndProcess();
            if (_permanentFailure is { } failure) throw ScanException.DeviceUnavailable(failure);
            try
            {
                return Start();
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException or InvalidOperationException)
            {
                // The pipe could not be created, or the process not watched: said like every other failure.
                throw ScanException.SessionFailed($"the 32-bit TWAIN helper did not start: {e.Message}");
            }
        }
    }

    /// <summary>Forgets a failure that kept the helper from starting (the troubleshooter's Refresh).</summary>
    public void Retry()
    {
        lock (_gate) _permanentFailure = null;
    }

    /// <summary>Asks the helper to close its source and exit, and makes sure it did.</summary>
    public void Shutdown()
    {
        TwainHelperConnection? connection;
        lock (_gate) connection = _connection;
        if (connection is { IsAlive: true })
        {
            try
            {
                connection.Request(new TwainHelperShutdown(), TimeSpan.FromSeconds(5));
            }
            catch (ScanException)
            {
                // Ended below.
            }
        }
        lock (_gate)
        {
            if (_process is { } process)
            {
                try
                {
                    process.WaitForExit(TimeSpan.FromSeconds(5));
                }
                catch (Exception e) when (e is InvalidOperationException or Win32Exception)
                {
                    // Not started or already gone.
                }
            }
            EndProcess();
        }
    }

    public void Dispose()
    {
        lock (_gate)
        {
            if (_disposed) return;
            _disposed = true;
        }
        Shutdown();
        lock (_gate)
        {
            _job?.Dispose();
            _job = null;
        }
    }

    /// <summary>The pipe's access: the current user only (the owner the system would give it), and nobody over the network.</summary>
    internal static PipeSecurity CreatePipeSecurity()
    {
        using var identity = WindowsIdentity.GetCurrent();
        var user = identity.User ?? throw new InvalidOperationException("The current user has no security identifier.");
        var security = new PipeSecurity();
        security.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
        security.SetOwner(identity.Owner ?? user);
        security.AddAccessRule(new PipeAccessRule(user, PipeAccessRights.FullControl, AccessControlType.Allow));
        security.AddAccessRule(new PipeAccessRule(new SecurityIdentifier(WellKnownSidType.NetworkSid, null),
                                                  PipeAccessRights.FullControl, AccessControlType.Deny));
        return security;
    }

    private TwainHelperConnection Start()
    {
        string path = _options.HelperPath;
        if (!File.Exists(path))
        {
            _permanentFailure = $"the 32-bit TWAIN helper ({TwainHelperOptions.FileName}) is missing from Lazy Scan's "
                                + "folder. Reinstall Lazy Scan.";
            throw ScanException.DeviceUnavailable(_permanentFailure);
        }
        string pipeName = $"CompleteScanner.TwainHelper.{Environment.ProcessId}.{Guid.NewGuid():N}";
        var pipe = NamedPipeServerStreamAcl.Create(pipeName, PipeDirection.InOut, maxNumberOfServerInstances: 1,
                                                   PipeTransmissionMode.Byte, PipeOptions.Asynchronous,
                                                   inBufferSize: 0, outBufferSize: 0, CreatePipeSecurity());
        Process process;
        var errors = new StderrTail();
        try
        {
            var start = new ProcessStartInfo(path)
            {
                UseShellExecute = false,
                CreateNoWindow = true,
                // Drivers may write to the console; nothing of it reaches the user, and the last
                // lines of the error output explain a helper that could not start.
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                WorkingDirectory = Path.GetDirectoryName(path) ?? AppContext.BaseDirectory,
            };
            // DOTNET_ROOT names the 64-bit runtime (the .NET host sets it for apps it starts); the
            // helper's 32-bit host would load that runtime's host library and fail. Without it, it
            // finds the 32-bit runtime (DOTNET_ROOT_X86, DOTNET_ROOT(x86), the registered or the
            // default location).
            start.Environment.Remove("DOTNET_ROOT");
            start.ArgumentList.Add("--pipe");
            start.ArgumentList.Add(pipeName);
            start.ArgumentList.Add("--parent");
            start.ArgumentList.Add(Environment.ProcessId.ToString(CultureInfo.InvariantCulture));
            if (_options.Simulate) start.ArgumentList.Add("--simulate");
            process = Process.Start(start) ?? throw new Win32Exception("The helper process did not start.");
        }
        catch (Win32Exception e)
        {
            pipe.Dispose();
            _permanentFailure = $"Windows would not start the 32-bit TWAIN helper ({e.Message.TrimEnd('.')}).";
            throw ScanException.DeviceUnavailable(_permanentFailure);
        }
        process.OutputDataReceived += (_, _) => { };
        process.ErrorDataReceived += (_, e) => errors.Add(e.Data);
        process.BeginOutputReadLine();
        process.BeginErrorReadLine();
        try
        {
            _job ??= KillOnCloseJob.Create();
            _job.Assign(process);
        }
        catch (Win32Exception e)
        {
            // The pipe closing and the helper watching the app still end it with the app.
            Trace.TraceWarning($"TWAIN helper: could not tie the helper to the app's lifetime: {e.Message}");
        }

        try
        {
            using var cancel = new CancellationTokenSource();
            var connecting = pipe.WaitForConnectionAsync(cancel.Token);
            var exited = process.WaitForExitAsync(cancel.Token);
            int first = Task.WaitAny(new Task[] { connecting, exited }, _options.ConnectTimeout);
            if (first != 0 || connecting.IsFaulted)
            {
                cancel.Cancel();
                Kill(process);
                string reason = first == 1 ? ExitReason(process, errors.Text) : "it did not connect in time.";
                if (first == 1 && IsRuntimeMissing(process, errors.Text)) _permanentFailure = reason;
                throw ScanException.SessionFailed($"the 32-bit TWAIN helper did not start: {reason}");
            }
            if (!GetNamedPipeClientProcessId(pipe.SafePipeHandle, out uint client) || client != (uint)process.Id)
            {
                Kill(process);
                throw ScanException.SessionFailed("another program connected to the 32-bit TWAIN helper's pipe.");
            }
        }
        catch
        {
            pipe.Dispose();
            process.Dispose();
            throw;
        }

        var connection = new TwainHelperConnection(pipe);
        // A helper that crashed or hangs is ended; the next call starts a new one.
        connection.Lost += _ => Kill(process);
        try
        {
            connection.Handshake(_options.Limits.Hello);
        }
        catch
        {
            connection.Dispose();
            Kill(process);
            process.Dispose();
            throw;
        }
        _process = process;
        _connection = connection;
        return connection;
    }

    /// <summary>Ends the current helper (if any) and forgets it.</summary>
    private void EndProcess()
    {
        _connection?.Dispose();
        _connection = null;
        if (_process is { } process)
        {
            Kill(process);
            process.Dispose();
        }
        _process = null;
    }

    private static void Kill(Process process)
    {
        try
        {
            if (!process.HasExited) process.Kill();
        }
        catch (Exception e) when (e is InvalidOperationException or Win32Exception or NotSupportedException)
        {
            // Already gone.
        }
    }

    /// <summary>The .NET host's exit codes for a missing runtime or framework (hostfxr: CoreHostLibMissingFailure,
    /// CoreHostCurHostFindFailure, FrameworkMissingFailure).</summary>
    private static readonly HashSet<uint> RuntimeMissingCodes = [0x80008083, 0x80008085, 0x80008096];

    private static bool IsRuntimeMissing(Process process, string errors)
    {
        try
        {
            if (RuntimeMissingCodes.Contains(unchecked((uint)process.ExitCode))) return true;
        }
        catch (InvalidOperationException)
        {
            // No exit code.
        }
        return errors.Contains("install", StringComparison.OrdinalIgnoreCase)
               && errors.Contains(".NET", StringComparison.OrdinalIgnoreCase);
    }

    private static string ExitReason(Process process, string errors)
    {
        if (IsRuntimeMissing(process, errors))
        {
            return "it needs the .NET 10 Desktop Runtime for 32-bit programs (x86), which is not installed. "
                   + "Install it from https://dotnet.microsoft.com/download/dotnet/10.0, then restart Lazy Scan.";
        }
        string code;
        try
        {
            code = $"exit code 0x{unchecked((uint)process.ExitCode):X8}";
        }
        catch (InvalidOperationException)
        {
            code = "no exit code";
        }
        return string.IsNullOrWhiteSpace(errors) ? $"it stopped ({code})." : $"it stopped ({code}): {errors.Trim()}";
    }

    /// <summary>The last lines a helper wrote to its error output.</summary>
    private sealed class StderrTail
    {
        private readonly Queue<string> _lines = new();

        public void Add(string? line)
        {
            if (string.IsNullOrWhiteSpace(line)) return;
            lock (_lines)
            {
                _lines.Enqueue(line.Trim());
                while (_lines.Count > 5) _lines.Dequeue();
            }
        }

        public string Text
        {
            get
            {
                lock (_lines) return string.Join(" ", _lines);
            }
        }
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetNamedPipeClientProcessId(SafePipeHandle pipe, out uint clientProcessId);

    /// <summary>A job object whose processes end when its last handle closes: when the app exits, however it exits.</summary>
    private sealed class KillOnCloseJob : IDisposable
    {
        private const int JobObjectExtendedLimitInformation = 9;
        private const uint JobObjectLimitKillOnJobClose = 0x2000;

        private readonly SafeFileHandle _handle;

        private KillOnCloseJob(SafeFileHandle handle) => _handle = handle;

        public static KillOnCloseJob Create()
        {
            var handle = CreateJobObject(IntPtr.Zero, null);
            if (handle.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
            var limits = new JobObjectExtendedLimits
            {
                BasicLimitInformation = new JobObjectBasicLimits { LimitFlags = JobObjectLimitKillOnJobClose },
            };
            if (!SetInformationJobObject(handle, JobObjectExtendedLimitInformation, ref limits, Marshal.SizeOf<JobObjectExtendedLimits>()))
            {
                int error = Marshal.GetLastWin32Error();
                handle.Dispose();
                throw new Win32Exception(error);
            }
            return new KillOnCloseJob(handle);
        }

        public void Assign(Process process)
        {
            if (!AssignProcessToJobObject(_handle, process.Handle)) throw new Win32Exception(Marshal.GetLastWin32Error());
        }

        public void Dispose() => _handle.Dispose();

        [StructLayout(LayoutKind.Sequential)]
        private struct JobObjectBasicLimits
        {
            public long PerProcessUserTimeLimit;
            public long PerJobUserTimeLimit;
            public uint LimitFlags;
            public UIntPtr MinimumWorkingSetSize;
            public UIntPtr MaximumWorkingSetSize;
            public uint ActiveProcessLimit;
            public UIntPtr Affinity;
            public uint PriorityClass;
            public uint SchedulingClass;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct IoCounters
        {
            public ulong ReadOperationCount;
            public ulong WriteOperationCount;
            public ulong OtherOperationCount;
            public ulong ReadTransferCount;
            public ulong WriteTransferCount;
            public ulong OtherTransferCount;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct JobObjectExtendedLimits
        {
            public JobObjectBasicLimits BasicLimitInformation;
            public IoCounters IoInfo;
            public UIntPtr ProcessMemoryLimit;
            public UIntPtr JobMemoryLimit;
            public UIntPtr PeakProcessMemoryUsed;
            public UIntPtr PeakJobMemoryUsed;
        }

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern SafeFileHandle CreateJobObject(IntPtr attributes, string? name);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool SetInformationJobObject(SafeFileHandle job, int infoClass, ref JobObjectExtendedLimits info, int length);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool AssignProcessToJobObject(SafeFileHandle job, IntPtr process);
    }
}
