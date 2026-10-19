namespace CompleteScanner.Core;

// WIA facts the Windows WIA backend (CompleteScanner.App/Scanning/WiaScannerBackend.cs)
// needs, kept here so they can be unit-tested: the App cannot be referenced by the tests.
// Values are from the Windows SDK headers (wiadef.h, wiadevd.h). WIA exists only on
// Windows, so there is no Swift twin.

/// <summary>Maps WIA error HRESULTs (WIA_ERROR_*) to <see cref="ScannerProblem"/>.</summary>
public static class WiaErrors
{
    public const uint GeneralError = 0x80210001;
    public const uint PaperJam = 0x80210002;
    public const uint PaperEmpty = 0x80210003;
    public const uint PaperProblem = 0x80210004;
    public const uint Offline = 0x80210005;
    public const uint Busy = 0x80210006;
    public const uint WarmingUp = 0x80210007;
    public const uint UserIntervention = 0x80210008;
    public const uint ItemDeleted = 0x80210009;
    public const uint DeviceCommunication = 0x8021000A;
    public const uint InvalidCommand = 0x8021000B;
    public const uint IncorrectHardwareSetting = 0x8021000C;
    public const uint DeviceLocked = 0x8021000D;
    public const uint ExceptionInDriver = 0x8021000E;
    public const uint InvalidDriverResponse = 0x8021000F;
    /// <summary>WIA_S_NO_DEVICE_AVAILABLE.</summary>
    public const uint NoDeviceAvailable = 0x80210015;
    public const uint CoverOpen = 0x80210016;
    public const uint LampOff = 0x80210017;
    public const uint MultiFeed = 0x80210020;

    /// <summary>The scanner problem an HRESULT stands for; null when it is not one the user can fix.</summary>
    public static ScannerProblem? ProblemFor(int hresult) => unchecked((uint)hresult) switch
    {
        PaperJam => ScannerProblem.PaperJam,
        PaperEmpty => ScannerProblem.FeederEmpty,
        PaperProblem => ScannerProblem.PaperProblem,
        Offline or NoDeviceAvailable or ItemDeleted => ScannerProblem.Offline,
        Busy or DeviceLocked => ScannerProblem.Busy,
        WarmingUp => ScannerProblem.WarmingUp,
        UserIntervention or LampOff => ScannerProblem.NeedsAttention,
        DeviceCommunication => ScannerProblem.CommunicationError,
        CoverOpen => ScannerProblem.CoverOpen,
        MultiFeed => ScannerProblem.MultiFeed,
        _ => null,
    };

    /// <summary>
    /// The <see cref="ScanException"/> for a failed WIA call: the problem's own text when the
    /// HRESULT maps to one (with the code as detail), otherwise a generic scan failure
    /// carrying the code and the driver's message.
    /// </summary>
    public static ScanException ToScanException(int hresult, string? driverMessage)
    {
        string code = $"WIA error 0x{unchecked((uint)hresult):X8}";
        if (ProblemFor(hresult) is { } problem) return ScanException.ForProblem(problem, code);
        return ScanException.ScanFailed(string.IsNullOrWhiteSpace(driverMessage) ? code : $"{code}: {driverMessage}");
    }
}

/// <summary>
/// The scan sources a WIA device really has, read from WIA_DPS_DOCUMENT_HANDLING_CAPABILITIES
/// (property 3086) instead of assuming a flatbed is always present.
/// </summary>
public static class WiaDocumentHandling
{
    /// <summary>FEED: the device has a document feeder.</summary>
    public const int Feed = 0x01;
    /// <summary>FLAT: the device has a flatbed.</summary>
    public const int Flat = 0x02;
    /// <summary>DUP: the feeder can scan both sides.</summary>
    public const int Duplex = 0x04;

    /// <summary>
    /// Sources from the capabilities flags. A device that does not report the property (or
    /// reports neither a flatbed nor a feeder) is treated as flatbed-only: drivers with a
    /// feeder are required to report it.
    /// </summary>
    public static List<ScanSource> Sources(int? capabilities)
    {
        var sources = new List<ScanSource>();
        if (capabilities is int flags)
        {
            if ((flags & Flat) != 0) sources.Add(ScanSource.Flatbed);
            if ((flags & Feed) != 0) sources.Add(ScanSource.DocumentFeeder);
        }
        if (sources.Count == 0) sources.Add(ScanSource.Flatbed);
        return sources;
    }

    /// <summary>Whether the feeder scans both sides (only meaningful when it has a feeder).</summary>
    public static bool SupportsDuplex(int? capabilities) =>
        capabilities is int flags && (flags & Feed) != 0 && (flags & Duplex) != 0;

    /// <summary>
    /// Feeder sheet size from WIA_DPS_HORIZONTAL/VERTICAL_SHEET_FEED_SIZE (3076/3077, in
    /// thousandths of an inch); null unless both are positive.
    /// </summary>
    public static SizeD? FeederSizeInches(int? widthThousandths, int? heightThousandths) =>
        widthThousandths is > 0 && heightThousandths is > 0
            ? new SizeD(widthThousandths.Value / 1000.0, heightThousandths.Value / 1000.0)
            : null;
}
