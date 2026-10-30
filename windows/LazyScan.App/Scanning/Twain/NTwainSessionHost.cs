using System.IO;
using LazyScan.Core;
using NTwain;
using NTwain.Data;

namespace LazyScan.App.Scanning.Twain;

/// <summary>
/// The process's TWAIN session: opening the Data Source Manager, listing its sources and
/// opening one. Used by the in-process 64-bit backend (<see cref="TwainScannerBackend"/>) and
/// compiled into the 32-bit helper (LazyScan.TwainHelper) as well, so both load drivers
/// the same way. Every member is called from one thread (the TWAIN thread of the process).
/// </summary>
internal sealed class NTwainSessionHost
{
    private const string DataSourceManagerFile = "TWAINDSM.dll";

    private TwainSession? _session;
    /// <summary>The driver of the source opened last.</summary>
    private NTwainDriver? _lastDriver;

    /// <summary>Opens the Data Source Manager once per process.</summary>
    public TwainAvailability EnsureSession()
    {
        if (_session is { IsDsmOpen: true }) return TwainAvailability.Available;
        try
        {
            // Only the copy scanner drivers install system-wide; the app never ships one. A
            // 64-bit process needs TWAINDSM.dll; a 32-bit one (the helper) can also use the
            // twain_32.dll Windows has always had, which NTwain picks when TWAINDSM.dll is missing.
            if (!PlatformInfo.Current.DsmExists
                || (Environment.Is64BitProcess
                    && !File.Exists(Path.Combine(Environment.SystemDirectory, DataSourceManagerFile))))
            {
                return TwainAvailability.NoDataSourceManager;
            }
            var version = typeof(NTwainSessionHost).Assembly.GetName().Version ?? new Version(1, 0);
            // StopOnTransferError stays off: with it on, NTwain 3.7 resets the pending transfers
            // after every finished one (TWRC_XFERDONE), ending feeder batches after one sheet.
            _session ??= new TwainSession(TWIdentity.Create(DataGroups.Image, version, "CompleteScanner",
                                                            "CompleteScanner", "CompleteScanner", "CompleteScanner"));
            return _session.Open() == ReturnCode.Success ? TwainAvailability.Available : TwainAvailability.Failed;
        }
        catch (Exception e) when (e is DllNotFoundException or BadImageFormatException or EntryPointNotFoundException)
        {
            return TwainAvailability.NoDataSourceManager;
        }
        catch (Exception e)
        {
            System.Diagnostics.Trace.TraceWarning($"TWAIN: the data source manager would not open: {e.Message}");
            return TwainAvailability.Failed;
        }
    }

    /// <summary>The sources the Data Source Manager lists; call after <see cref="EnsureSession"/> returned Available.</summary>
    public List<TwainHelperSource> Sources() =>
        _session is { IsDsmOpen: true } session
            ? [.. session.GetSources().Select(source => new TwainHelperSource(source.Name, source.Manufacturer, source.ProductFamily))]
            : [];

    /// <summary>
    /// Opens the source named <paramref name="name"/> (exactly as listed), closing one a previous
    /// session could not close. Throws <see cref="ScanException"/> when it cannot.
    /// </summary>
    public NTwainDriver Open(string name)
    {
        var availability = EnsureSession();
        if (availability == TwainAvailability.NoDataSourceManager)
        {
            throw ScanException.DeviceUnavailable(TwainDiagnostics.NoDataSourceManagerMessage);
        }
        if (availability != TwainAvailability.Available)
        {
            throw ScanException.SessionFailed("The TWAIN Data Source Manager would not open.");
        }
        var session = _session!;
        // The previous source's driver stops listening even if its session never got to close
        // it: NTwain hands out one shared object per source, so a forgotten driver would
        // otherwise also receive every image of the next session that opens the same scanner.
        _lastDriver?.Dispose();
        _lastDriver = null;
        // One source at a time: close one a previous session could not close (its driver was stuck).
        if (session.State >= 4 && session.CurrentSource is { } previous)
        {
            try
            {
                if (session.State > 4) session.ForceStepDown(4);
                previous.Close();
            }
            catch (Exception e)
            {
                System.Diagnostics.Trace.TraceWarning($"TWAIN: could not close the previous source: {e.Message}");
            }
        }
        var source = session.GetSources().FirstOrDefault(s => string.Equals(s.Name, name, StringComparison.Ordinal))
            ?? throw ScanException.DeviceUnavailable($"The TWAIN driver \"{name}\" is no longer installed.");
        var rc = source.Open();
        if (rc != ReturnCode.Success)
        {
            int condition;
            try
            {
                condition = (int)session.GetStatus().ConditionCode;
            }
            catch
            {
                condition = TwainConditionCodes.Bummer;
            }
            if (TwainErrors.ProblemFor((int)rc, condition) is { } problem)
            {
                throw ScanException.ForProblem(problem, $"TWAIN {TwainErrors.ConditionName(condition)}");
            }
            throw ScanException.SessionFailed($"the TWAIN driver could not open the scanner ({TwainErrors.ConditionName(condition)}).");
        }
        _lastDriver = new NTwainDriver(session, source);
        return _lastDriver;
    }
}
