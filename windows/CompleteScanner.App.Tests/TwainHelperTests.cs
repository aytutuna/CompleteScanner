using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using CompleteScanner.App.Scanning.Twain;
using CompleteScanner.Core;
using Xunit;

namespace CompleteScanner.App.Tests;

/// <summary>
/// A test that starts the real 32-bit helper, which needs the 32-bit (x86) .NET Desktop Runtime.
/// Without it the test is skipped, unless COMPLETESCANNER_REQUIRE_TWAIN_HELPER=1 (CI installs the
/// runtime and sets it, so the tests can never be skipped there unnoticed).
/// </summary>
public sealed class HelperFactAttribute : FactAttribute
{
    public HelperFactAttribute()
    {
        if (Environment.GetEnvironmentVariable("COMPLETESCANNER_REQUIRE_TWAIN_HELPER") != "1" && !X86DesktopRuntimeInstalled())
        {
            Skip = "The 32-bit .NET Desktop Runtime (x86) is not installed, so the 32-bit TWAIN helper cannot run here.";
        }
    }

    private static bool X86DesktopRuntimeInstalled()
    {
        string root = Environment.GetEnvironmentVariable("DOTNET_ROOT(x86)")
                      ?? Environment.GetEnvironmentVariable("DOTNET_ROOT_X86")
                      ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86), "dotnet");
        string frameworks = Path.Combine(root, "shared", "Microsoft.WindowsDesktop.App");
        return Directory.Exists(frameworks) && Directory.EnumerateDirectories(frameworks, "10.*").Any();
    }
}

// The 32-bit TWAIN helper as the app runs it: the real CompleteScanner.TwainHelper.exe (x86),
// started by Twain32ScannerBackend through TwainHelperProcess over a named pipe, with its stand-in
// scanners (--simulate) instead of TWAIN, since no test machine is expected to have a 32-bit
// scanner driver. Scans run end to end through the app's TWAIN session code. Nothing is shown on
// screen: the helper is a console program started without a window, and the stand-ins have no UI.
public class TwainHelperTests
{
    private const string Scanner = "CompleteScanner Simulated Scanner";

    private static string HelperPath => Path.Combine(AppContext.BaseDirectory, TwainHelperOptions.FileName);

    private static Twain32ScannerBackend NewBackend(TwainHelperTimeouts? timeouts = null, string? helperPath = null,
                                                    IReadOnlyList<string>? thirtyTwoBitOnly = null) =>
        new(null, new TwainHelperOptions(helperPath ?? HelperPath, Simulate: true, Timeouts: timeouts),
            () => thirtyTwoBitOnly ?? [@"Acme\acme.ds"]);

    /// <summary>Starts listing and waits for the first list.</summary>
    private static async Task<IReadOnlyList<ScannerInfo>> Listed(Twain32ScannerBackend backend)
    {
        var changed = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        backend.DevicesChanged += () => changed.TrySetResult();
        backend.StartBrowsing();
        await changed.Task.WaitAsync(TimeSpan.FromSeconds(60));
        return backend.Devices;
    }

    private static string Id(string source) => TwainHelperSources.IdPrefix + source;

    /// <summary>Sample (x, y) of page n of the helper's gray stand-in pages (SimulatedTwainHost).</summary>
    private static byte Sample(int x, int y, int page) => (byte)((x + 2 * y + 37 * page) % 251);

    private static ScanSettings Gray(ScanSource source) =>
        new() { Source = source, ColorMode = ColorMode.Grayscale, Resolution = 100 };

    private static async Task<bool> ExitsWithin(int processId, TimeSpan time)
    {
        Process process;
        try
        {
            process = Process.GetProcessById(processId);
        }
        catch (ArgumentException)
        {
            return true;
        }
        using (process)
        {
            using var limit = new CancellationTokenSource(time);
            try
            {
                await process.WaitForExitAsync(limit.Token);
                return true;
            }
            catch (OperationCanceledException)
            {
                return false;
            }
        }
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool IsWow64Process(IntPtr process, [MarshalAs(UnmanagedType.Bool)] out bool wow64);

    [HelperFact]
    public async Task ListsOpensAndScans_ThroughTheRealHelper()
    {
        using var backend = NewBackend();
        var devices = await Listed(backend);

        Assert.True(backend.Status == TwainHelperStatus.Available, backend.DiagnosticsReport);
        // The WIA bridge is left out.
        Assert.Equal(8, devices.Count);
        Assert.DoesNotContain(devices, d => d.Name.StartsWith("WIA-", StringComparison.Ordinal));
        var info = Assert.Single(devices, d => d.Id == Id(Scanner));
        Assert.Equal((Scanner + " (32-bit driver)", "TWAIN (32-bit driver)", "twain32"), (info.Name, info.Transport, info.Backend));
        Assert.Contains("TWAIN 32-bit helper: works", backend.DiagnosticsReport);
        Assert.Contains("left out (WIA bridge, or also a 64-bit driver) \"WIA-CompleteScanner Simulated Bridge\"", backend.DiagnosticsReport);

        // It is the 32-bit helper, running as a separate process.
        int helper = backend.HelperProcessId ?? throw new Xunit.Sdk.XunitException("No helper is running.");
        Assert.NotEqual(Environment.ProcessId, helper);
        using (var process = Process.GetProcessById(helper))
        {
            Assert.True(IsWow64Process(process.Handle, out bool wow64));
            Assert.True(wow64);
            Assert.Equal("CompleteScanner.TwainHelper", process.ProcessName);
        }

        var session = await backend.OpenSessionAsync(info.Id);
        var caps = await session.GetCapabilitiesAsync();
        Assert.Equal([ScanSource.Flatbed, ScanSource.DocumentFeeder], caps.Sources);

        var pages = await session.PerformScanAsync(Gray(ScanSource.DocumentFeeder), null);
        Assert.Equal(3, pages.Count);
        for (int page = 1; page <= 3; page++)
        {
            var image = pages[page - 1].Image;
            Assert.Equal((850, 1100, 100, ColorMode.Grayscale),
                         (image.Width, image.Height, pages[page - 1].Dpi, pages[page - 1].ColorMode));
            foreach (var (x, y) in new[] { (0, 0), (849, 0), (400, 549), (400, 550), (849, 1099) })
            {
                Assert.Equal(Sample(x, y, page), image.Pixels[(y * image.Width + x) * 4]);
            }
        }
        Assert.Null(session.LastScanStop);

        var preview = await session.PerformOverviewScanAsync(Gray(ScanSource.Flatbed));
        Assert.Equal((850, 1100), (preview.Width, preview.Height));

        await session.CloseAsync();
        // The app closing ends the helper.
        backend.Dispose();
        Assert.True(await ExitsWithin(helper, TimeSpan.FromSeconds(15)));
    }

    [HelperFact]
    public async Task NativeTransfers_ArriveInChunks_WithProgress()
    {
        using var backend = NewBackend();
        await Listed(backend);
        var session = await backend.OpenSessionAsync(Id("CompleteScanner Simulated Native"));
        var progress = new List<ScanProgress>();
        session.ProgressHandler = p =>
        {
            lock (progress) progress.Add(p);
        };
        var pages = await session.PerformScanAsync(new ScanSettings { Resolution = 100 }, null);

        var image = Assert.Single(pages).Image;
        Assert.Equal((850, 1100), (image.Width, image.Height));
        int at = (700 * 850 + 300) * 4;
        // Red is x, green is y, blue the page.
        Assert.Equal((300 % 256, 700 % 256, 40), (image.Pixels[at], image.Pixels[at + 1], image.Pixels[at + 2]));
        lock (progress)
        {
            var fractions = progress.Where(p => p.Fraction is not null).Select(p => p.Fraction!.Value).ToList();
            // 2.8 MB in chunks of 256 kB.
            Assert.Equal(11, fractions.Count);
            Assert.Equal(1.0, fractions[^1]);
            Assert.Contains(progress, p => p.Message == "Transferred page 1…");
        }
        await session.CloseAsync();
    }

    [HelperFact]
    public async Task ScannerProblems_CrossFromTheHelper()
    {
        using var backend = NewBackend();
        await Listed(backend);

        var jam = await backend.OpenSessionAsync(Id("CompleteScanner Simulated Jam"));
        var kept = await jam.PerformScanAsync(Gray(ScanSource.DocumentFeeder), null);
        Assert.Single(kept);
        Assert.Equal(ScannerProblem.PaperJam, jam.LastScanStop?.Problem);
        await jam.CloseAsync();

        var offline = await backend.OpenSessionAsync(Id("CompleteScanner Simulated Offline"));
        var notThere = await Assert.ThrowsAsync<ScanException>(offline.GetCapabilitiesAsync);
        Assert.Equal(ScannerProblem.Offline, notThere.Problem);
        await offline.CloseAsync();

        var busy = await Assert.ThrowsAsync<ScanException>(() => backend.OpenSessionAsync(Id("CompleteScanner Simulated Busy")));
        Assert.Equal(ScannerProblem.Busy, busy.Problem);
        Assert.Equal(ScanException.ForProblem(ScannerProblem.Busy, "TWAIN TWCC_MAXCONNECTIONS").Message, busy.Message);
    }

    [HelperFact]
    public async Task ACrash_SaysSo_AndTheNextScanStartsANewHelper()
    {
        using var backend = NewBackend();
        await Listed(backend);
        int first = backend.HelperProcessId!.Value;

        var crashing = await backend.OpenSessionAsync(Id("CompleteScanner Simulated Crash"));
        await crashing.GetCapabilitiesAsync();
        var error = await Assert.ThrowsAsync<ScanException>(() => crashing.PerformScanAsync(Gray(ScanSource.Flatbed), null));
        Assert.Equal(ScanException.ScanFailed(TwainHelperConnection.StoppedMessage).Message, error.Message);
        Assert.True(await ExitsWithin(first, TimeSpan.FromSeconds(15)));
        await crashing.CloseAsync();

        var session = await backend.OpenSessionAsync(Id(Scanner));
        Assert.Single(await session.PerformScanAsync(Gray(ScanSource.Flatbed), null));
        Assert.NotEqual(first, backend.HelperProcessId);
        await session.CloseAsync();
    }

    [HelperFact]
    public async Task AHang_TimesOut_StopsTheHelper_AndTheNextScanWorks()
    {
        using var backend = NewBackend(TwainHelperTimeouts.Default with { Request = TimeSpan.FromSeconds(3) });
        await Listed(backend);
        int first = backend.HelperProcessId!.Value;

        var hanging = await backend.OpenSessionAsync(Id("CompleteScanner Simulated Hang"));
        var error = await Assert.ThrowsAsync<ScanException>(hanging.GetCapabilitiesAsync);
        Assert.Equal(ScanException.ScanFailed(TwainHelperConnection.NotRespondingMessage).Message, error.Message);
        Assert.True(await ExitsWithin(first, TimeSpan.FromSeconds(15)));
        await hanging.CloseAsync();

        var session = await backend.OpenSessionAsync(Id(Scanner));
        Assert.Equal(3, (await session.PerformScanAsync(Gray(ScanSource.DocumentFeeder), null)).Count);
        Assert.NotEqual(first, backend.HelperProcessId);
        await session.CloseAsync();
    }

    [HelperFact]
    public async Task Cancel_EndsAScanInTheHelper_AndTheHelperGoesOn()
    {
        using var backend = NewBackend();
        await Listed(backend);
        int helper = backend.HelperProcessId!.Value;

        var slow = await backend.OpenSessionAsync(Id("CompleteScanner Simulated Slow"));
        slow.ProgressHandler = p =>
        {
            if (p.Message == "Transferred page 2…") slow.CancelScan();
        };
        var error = await Assert.ThrowsAsync<ScanException>(() => slow.PerformScanAsync(Gray(ScanSource.DocumentFeeder), null));
        Assert.Equal(ScanErrorKind.Cancelled, error.Kind);
        await slow.CloseAsync();

        var session = await backend.OpenSessionAsync(Id(Scanner));
        Assert.Single(await session.PerformScanAsync(Gray(ScanSource.Flatbed), null));
        Assert.Equal(helper, backend.HelperProcessId);
        await session.CloseAsync();
    }

    [HelperFact]
    public async Task TheHelper_ExitsByItself_WhenTheAppsEndOfThePipeCloses()
    {
        string name = $"CompleteScanner.TwainHelper.Test.{Guid.NewGuid():N}";
        using var pipe = NamedPipeServerStreamAcl.Create(name, PipeDirection.InOut, 1, PipeTransmissionMode.Byte,
                                                         PipeOptions.Asynchronous, 0, 0, TwainHelperProcess.CreatePipeSecurity());
        var start = new ProcessStartInfo(HelperPath)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        // As TwainHelperProcess does: the test host's DOTNET_ROOT names the 64-bit runtime.
        start.Environment.Remove("DOTNET_ROOT");
        foreach (string arg in new[] { "--pipe", name, "--parent", Environment.ProcessId.ToString(CultureInfo.InvariantCulture), "--simulate" })
        {
            start.ArgumentList.Add(arg);
        }
        using var process = Process.Start(start)!;
        var errors = new System.Text.StringBuilder();
        process.ErrorDataReceived += (_, e) =>
        {
            lock (errors) errors.Append(e.Data);
        };
        process.BeginErrorReadLine();
        process.BeginOutputReadLine();
        try
        {
            var connecting = pipe.WaitForConnectionAsync();
            await Task.WhenAny(connecting, process.WaitForExitAsync(), Task.Delay(TimeSpan.FromSeconds(30)));
            lock (errors) Assert.True(connecting.IsCompletedSuccessfully, $"The helper did not connect: {errors}");
            var connection = new TwainHelperConnection(pipe);
            connection.Handshake(TimeSpan.FromSeconds(30));
            Assert.IsType<TwainHelperDone>(connection.Request(new TwainHelperOpen(Scanner), TimeSpan.FromSeconds(30)));
            // The app goes away without saying goodbye: no shutdown request, nobody ends the process.
            connection.Dispose();
            Assert.True(await ExitsWithin(process.Id, TimeSpan.FromSeconds(15)));
            Assert.Equal(0, process.ExitCode);
        }
        finally
        {
            if (!process.HasExited) process.Kill();
        }
    }

    [Fact]
    public void ThePipe_IsForTheCurrentUserOnly_AndNeverTheNetwork()
    {
        using var identity = WindowsIdentity.GetCurrent();
        var network = new SecurityIdentifier(WellKnownSidType.NetworkSid, null);
        string name = $"CompleteScanner.TwainHelper.Test.{Guid.NewGuid():N}";
        using var pipe = NamedPipeServerStreamAcl.Create(name, PipeDirection.InOut, 1, PipeTransmissionMode.Byte,
                                                         PipeOptions.Asynchronous, 0, 0, TwainHelperProcess.CreatePipeSecurity());
        // What the system holds for the pipe, read back.
        var security = pipe.GetAccessControl();
        Assert.True(security.AreAccessRulesProtected);
        Assert.Equal(identity.Owner ?? identity.User, security.GetOwner(typeof(SecurityIdentifier)));
        var rules = security.GetAccessRules(true, true, typeof(SecurityIdentifier)).Cast<PipeAccessRule>().ToList();
        Assert.Equal(2, rules.Count);
        Assert.Contains(rules, r => r.AccessControlType == AccessControlType.Allow && r.IdentityReference.Equals(identity.User)
                                    && r.PipeAccessRights.HasFlag(PipeAccessRights.ReadWrite));
        Assert.Contains(rules, r => r.AccessControlType == AccessControlType.Deny && r.IdentityReference.Equals(network));
        Assert.DoesNotContain(rules, r => r.AccessControlType == AccessControlType.Allow && !r.IdentityReference.Equals(identity.User));
    }

    [Fact]
    public async Task NoHelper_IsStarted_WithoutA32BitOnlyDriver()
    {
        using var backend = NewBackend(thirtyTwoBitOnly: []);
        Assert.Empty(await Listed(backend));
        Assert.Equal(TwainHelperStatus.NotNeeded, backend.Status);
        Assert.Null(backend.HelperProcessId);
        Assert.Equal("TWAIN 32-bit helper: not needed (no 32-bit-only drivers)\n", backend.DiagnosticsReport);
        // The troubleshooter's view is left as the 64-bit backend made it.
        var snapshot = new DiscoverySnapshot { ThirtyTwoBitOnlyDrivers = ["x.ds"] };
        Assert.Same(snapshot, backend.AddStatus(snapshot));
    }

    [Fact]
    public async Task AMissingHelper_IsReportedClearly_AndNotTriedAgainOnItsOwn()
    {
        string missing = Path.Combine(AppContext.BaseDirectory, "no-such-folder", TwainHelperOptions.FileName);
        using var backend = new Twain32ScannerBackend(null, new TwainHelperOptions(missing, Simulate: true), () => [@"Acme\acme.ds"])
        {
            RetryDelays = [TimeSpan.FromMilliseconds(50)],
        };
        int published = 0;
        backend.DevicesChanged += () => Interlocked.Increment(ref published);
        Assert.Empty(await Listed(backend));
        Assert.Equal(TwainHelperStatus.Failed, backend.Status);
        Assert.StartsWith("TWAIN 32-bit helper: failed (", backend.DiagnosticsReport);
        Assert.Contains("CompleteScanner.TwainHelper.exe) is missing", backend.DiagnosticsReport);
        // The 32-bit drivers stay a problem for the troubleshooter, which says why and what to do.
        var snapshot = backend.AddStatus(new DiscoverySnapshot { ThirtyTwoBitOnlyDrivers = ["x.ds"] });
        Assert.Equal(["x.ds"], snapshot.ThirtyTwoBitOnlyDrivers);
        Assert.Equal("It cannot run: the 32-bit TWAIN helper (CompleteScanner.TwainHelper.exe) is missing from "
                     + "CompleteScanner's folder. Reinstall CompleteScanner.", snapshot.ThirtyTwoBitHelperProblem);
        var check = Troubleshooter.Diagnose(snapshot with { Platform = TroubleshootPlatform.Windows }).Single(c => c.Id == "twain32");
        Assert.Contains(snapshot.ThirtyTwoBitHelperProblem!, check.More);
        Assert.DoesNotContain("can use only 64-bit drivers", check.FullDetail);
        // Trying again on its own cannot help (the troubleshooter's Refresh does, after a reinstall).
        await Task.Delay(500);
        Assert.Equal(1, Volatile.Read(ref published));
    }

    [Fact]
    public async Task AFailedListing_IsTriedAgainOnItsOwn()
    {
        // When it tries again there is no 32-bit-only driver any more, so the retry only looks and starts nothing.
        int asked = 0;
        using var backend = new Twain32ScannerBackend(null, new TwainHelperOptions(HelperPath, Simulate: true), () =>
        {
            Interlocked.Increment(ref asked);
            return [];
        })
        {
            RetryDelays = [TimeSpan.FromMilliseconds(50)],
        };
        var retried = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        backend.DevicesChanged += () =>
        {
            if (backend.Status == TwainHelperStatus.NotNeeded) retried.TrySetResult();
        };
        // The helper started, but its Data Source Manager would not open: that may pass.
        backend.Publish(0, new TwainHelperSourceList(TwainAvailability.Failed, []));
        Assert.Equal(TwainHelperStatus.Failed, backend.Status);
        Assert.Equal("TWAIN 32-bit helper: failed (the helper started, but its TWAIN Data Source Manager would not open)\n",
                     backend.DiagnosticsReport);
        Assert.Equal(TwainDiagnostics.HelperProblem(TwainHelperStatus.Failed, null, reachedAny: false),
                     backend.AddStatus(new DiscoverySnapshot { ThirtyTwoBitOnlyDrivers = ["x.ds"] }).ThirtyTwoBitHelperProblem);
        await retried.Task.WaitAsync(TimeSpan.FromSeconds(10));
        Assert.Equal(1, asked);
        Assert.Null(backend.HelperProcessId);
    }

    [HelperFact]
    public async Task AHelperTooSlowToStart_IsTriedAgainOnItsOwn()
    {
        using var backend = new Twain32ScannerBackend(
            null, new TwainHelperOptions(HelperPath, Simulate: true, StartTimeout: TimeSpan.FromMilliseconds(1)), () => [@"Acme\acme.ds"])
        {
            RetryDelays = [TimeSpan.FromMilliseconds(100)],
        };
        int published = 0;
        var again = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        backend.DevicesChanged += () =>
        {
            if (Interlocked.Increment(ref published) == 2) again.TrySetResult();
        };
        backend.StartBrowsing();
        await again.Task.WaitAsync(TimeSpan.FromSeconds(60));
        Assert.Equal(TwainHelperStatus.Failed, backend.Status);
        Assert.Contains("did not connect in time", backend.DiagnosticsReport);
        backend.StopBrowsing();
    }

    [Fact]
    public void AHelperThatReachesNoDriver_LeavesThe32BitDriversAProblem_AndSaysWhy()
    {
        using var backend = NewBackend();
        var before = new DiscoverySnapshot
        {
            Platform = TroubleshootPlatform.Windows,
            Twain = TwainStatus.NotInstalled,
            ThirtyTwoBitOnlyDrivers = [@"Acme\acme.ds"],
        };
        // The Data Source Manager lists only the WIA bridge (acme.ds did not load).
        backend.Publish(0, new TwainHelperSourceList(TwainAvailability.Available, [new TwainHelperSource("WIA-Canon LiDE 400")]));
        Assert.Equal(TwainHelperStatus.Available, backend.Status);
        Assert.Empty(backend.Devices);
        Assert.StartsWith("TWAIN 32-bit helper: reached no usable driver\n", backend.DiagnosticsReport);
        var snapshot = backend.AddStatus(before);
        Assert.Equal([@"Acme\acme.ds"], snapshot.ThirtyTwoBitOnlyDrivers);
        Assert.Equal((TwainStatus.NotInstalled, 0), (snapshot.Twain, snapshot.TwainDriverCount));
        string problem = TwainDiagnostics.HelperProblem(TwainHelperStatus.Available, null, reachedAny: false)!;
        Assert.Equal(problem, snapshot.ThirtyTwoBitHelperProblem);
        Assert.Contains(problem, Troubleshooter.Diagnose(snapshot).Single(c => c.Id == "twain32").More);

        // No 32-bit Data Source Manager: said so.
        backend.Publish(0, new TwainHelperSourceList(TwainAvailability.NoDataSourceManager, []));
        Assert.Equal(TwainDiagnostics.HelperProblem(TwainHelperStatus.NoDataSourceManager, null, reachedAny: false),
                     backend.AddStatus(before).ThirtyTwoBitHelperProblem);

        // Once it reaches a driver, the 32-bit drivers are no longer a problem.
        backend.Publish(0, new TwainHelperSourceList(TwainAvailability.Available,
                                                     [new TwainHelperSource("Acme Scan 32"), new TwainHelperSource("WIA-Canon LiDE 400")]));
        Assert.Single(backend.Devices);
        snapshot = backend.AddStatus(before);
        Assert.Empty(snapshot.ThirtyTwoBitOnlyDrivers);
        Assert.Null(snapshot.ThirtyTwoBitHelperProblem);
        Assert.Equal((TwainStatus.Available, 1), (snapshot.Twain, snapshot.TwainDriverCount));
        Assert.StartsWith("TWAIN 32-bit helper: works\n", backend.DiagnosticsReport);
    }

    [HelperFact]
    public async Task AWorkingHelper_Makes32BitDriversUsable_ForTheTroubleshooter()
    {
        using var backend = NewBackend();
        var devices = await Listed(backend);
        var snapshot = backend.AddStatus(new DiscoverySnapshot
        {
            Twain = TwainStatus.NotInstalled,
            TwainDriverCount = 0,
            ThirtyTwoBitOnlyDrivers = [@"Acme\acme.ds"],
        });
        Assert.Empty(snapshot.ThirtyTwoBitOnlyDrivers);
        Assert.Equal(devices.Count, snapshot.TwainDriverCount);
        Assert.Equal(TwainStatus.Available, snapshot.Twain);
    }
}
