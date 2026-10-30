namespace LazyScan.Core;

// TWAIN facts the Windows TWAIN backend (LazyScan.App/Scanning/Twain) needs, kept here
// so they can be unit-tested: the App cannot be referenced by the tests. Values are from
// twain.h 2.3 (TWAIN Working Group). TWAIN is reached only on Windows (macOS talks to the same
// scanners through ImageCaptureCore), so there is no Swift twin.

/// <summary>ICAP_PIXELTYPE values (TWPT_*).</summary>
public static class TwainPixelTypes
{
    public const int BlackWhite = 0;
    public const int Gray = 1;
    public const int Rgb = 2;
}

/// <summary>ICAP_PIXELFLAVOR values (TWPF_*): what a zero sample means.</summary>
public static class TwainPixelFlavors
{
    /// <summary>TWPF_CHOCOLATE: zero is black (the TWAIN default).</summary>
    public const int Chocolate = 0;
    /// <summary>TWPF_VANILLA: zero is white.</summary>
    public const int Vanilla = 1;
}

/// <summary>ICAP_XFERMECH values (TWSX_*).</summary>
public static class TwainTransferMechanisms
{
    /// <summary>TWSX_NATIVE: one device-independent bitmap per image.</summary>
    public const int Native = 0;
    public const int File = 1;
    /// <summary>TWSX_MEMORY: the image arrives in strips the app assembles.</summary>
    public const int Memory = 2;
}

/// <summary>CAP_DUPLEX values (TWDX_*).</summary>
public static class TwainDuplexKinds
{
    public const int None = 0;
    public const int OnePass = 1;
    public const int TwoPass = 2;
}

/// <summary>ICAP_COMPRESSION: TWCP_NONE, the only one the memory-strip assembler reads.</summary>
public static class TwainCompression
{
    public const int None = 0;
}

/// <summary>Return codes of TWAIN operations (TWRC_*).</summary>
public static class TwainReturnCodes
{
    public const int Success = 0;
    public const int Failure = 1;
    public const int CheckStatus = 2;
    /// <summary>TWRC_CANCEL: the user cancelled in the driver's own window.</summary>
    public const int Cancel = 3;
    public const int XferDone = 6;
    public const int Busy = 10;
    public const int ScannerLocked = 11;
}

/// <summary>Condition codes a data source reports after a failure (TWCC_*).</summary>
public static class TwainConditionCodes
{
    public const int Success = 0;
    public const int Bummer = 1;
    public const int LowMemory = 2;
    public const int NoDataSource = 3;
    public const int MaxConnections = 4;
    public const int OperationError = 5;
    public const int BadCapability = 6;
    public const int BadProtocol = 9;
    public const int BadValue = 10;
    public const int SequenceError = 11;
    public const int BadDestination = 12;
    public const int CapabilityUnsupported = 13;
    public const int CapabilityBadOperation = 14;
    public const int CapabilitySequenceError = 15;
    public const int Denied = 16;
    public const int FileExists = 17;
    public const int FileNotFound = 18;
    public const int NotEmpty = 19;
    public const int PaperJam = 20;
    public const int PaperDoubleFeed = 21;
    public const int FileWriteError = 22;
    public const int CheckDeviceOnline = 23;
    public const int Interlock = 24;
    public const int DamagedCorner = 25;
    public const int FocusError = 26;
    public const int DocumentTooLight = 27;
    public const int DocumentTooDark = 28;
    public const int NoMedia = 29;
}

/// <summary>A TWAIN operation that did not succeed, with the codes the source reported.</summary>
public sealed class TwainException(string operation, int returnCode, int conditionCode, string? detail = null)
    : Exception(detail is null
        ? $"{operation} failed (return code {returnCode}, condition code {conditionCode})."
        : $"{operation} failed (return code {returnCode}, condition code {conditionCode}): {detail}")
{
    /// <summary>What was being done, e.g. "Opening the scanner".</summary>
    public string Operation { get; } = operation;
    public int ReturnCode { get; } = returnCode;
    public int ConditionCode { get; } = conditionCode;
}

/// <summary>Maps TWAIN return and condition codes to <see cref="ScannerProblem"/> and <see cref="ScanException"/>.</summary>
public static class TwainErrors
{
    /// <summary>The scanner problem the codes stand for; null when it is not one the user can fix.</summary>
    public static ScannerProblem? ProblemFor(int returnCode, int conditionCode)
    {
        if (returnCode is TwainReturnCodes.Busy or TwainReturnCodes.ScannerLocked) return ScannerProblem.Busy;
        return conditionCode switch
        {
            TwainConditionCodes.PaperJam => ScannerProblem.PaperJam,
            TwainConditionCodes.PaperDoubleFeed => ScannerProblem.MultiFeed,
            TwainConditionCodes.CheckDeviceOnline => ScannerProblem.Offline,
            TwainConditionCodes.Interlock => ScannerProblem.CoverOpen,
            TwainConditionCodes.DamagedCorner => ScannerProblem.PaperProblem,
            TwainConditionCodes.NoMedia => ScannerProblem.FeederEmpty,
            // Another program has the scanner open.
            TwainConditionCodes.MaxConnections => ScannerProblem.Busy,
            _ => null,
        };
    }

    /// <summary>The twain.h name of a condition code ("TWCC_PAPERJAM"), or the number.</summary>
    public static string ConditionName(int conditionCode) => conditionCode switch
    {
        TwainConditionCodes.Success => "TWCC_SUCCESS",
        TwainConditionCodes.Bummer => "TWCC_BUMMER",
        TwainConditionCodes.LowMemory => "TWCC_LOWMEMORY",
        TwainConditionCodes.NoDataSource => "TWCC_NODS",
        TwainConditionCodes.MaxConnections => "TWCC_MAXCONNECTIONS",
        TwainConditionCodes.OperationError => "TWCC_OPERATIONERROR",
        TwainConditionCodes.BadCapability => "TWCC_BADCAP",
        TwainConditionCodes.BadProtocol => "TWCC_BADPROTOCOL",
        TwainConditionCodes.BadValue => "TWCC_BADVALUE",
        TwainConditionCodes.SequenceError => "TWCC_SEQERROR",
        TwainConditionCodes.BadDestination => "TWCC_BADDEST",
        TwainConditionCodes.CapabilityUnsupported => "TWCC_CAPUNSUPPORTED",
        TwainConditionCodes.CapabilityBadOperation => "TWCC_CAPBADOPERATION",
        TwainConditionCodes.CapabilitySequenceError => "TWCC_CAPSEQERROR",
        TwainConditionCodes.Denied => "TWCC_DENIED",
        TwainConditionCodes.FileExists => "TWCC_FILEEXISTS",
        TwainConditionCodes.FileNotFound => "TWCC_FILENOTFOUND",
        TwainConditionCodes.NotEmpty => "TWCC_NOTEMPTY",
        TwainConditionCodes.PaperJam => "TWCC_PAPERJAM",
        TwainConditionCodes.PaperDoubleFeed => "TWCC_PAPERDOUBLEFEED",
        TwainConditionCodes.FileWriteError => "TWCC_FILEWRITEERROR",
        TwainConditionCodes.CheckDeviceOnline => "TWCC_CHECKDEVICEONLINE",
        TwainConditionCodes.Interlock => "TWCC_INTERLOCK",
        TwainConditionCodes.DamagedCorner => "TWCC_DAMAGEDCORNER",
        TwainConditionCodes.FocusError => "TWCC_FOCUSERROR",
        TwainConditionCodes.DocumentTooLight => "TWCC_DOCTOOLIGHT",
        TwainConditionCodes.DocumentTooDark => "TWCC_DOCTOODARK",
        TwainConditionCodes.NoMedia => "TWCC_NOMEDIA",
        _ => $"condition code {conditionCode}",
    };

    /// <summary>
    /// The <see cref="ScanException"/> for a failed TWAIN operation: a cancel in the driver's
    /// window is a cancelled scan; a problem the user can fix gets its own text (with the
    /// condition as detail); anything else is a scan failure naming the condition.
    /// </summary>
    public static ScanException ToScanException(int returnCode, int conditionCode, string? detail = null)
    {
        if (returnCode == TwainReturnCodes.Cancel) return ScanException.Cancelled();
        string code = $"TWAIN {ConditionName(conditionCode)}";
        if (ProblemFor(returnCode, conditionCode) is { } problem) return ScanException.ForProblem(problem, code);
        if (conditionCode == TwainConditionCodes.LowMemory)
        {
            return ScanException.ScanFailed($"The scanner driver ran out of memory. Try a lower resolution. ({code})");
        }
        return ScanException.ScanFailed(string.IsNullOrWhiteSpace(detail)
            ? $"The scanner driver reported an error. ({code})"
            : $"The scanner driver reported an error: {detail.Trim()} ({code})");
    }

    /// <inheritdoc cref="ToScanException(int, int, string?)"/>
    public static ScanException ToScanException(TwainException error) =>
        ToScanException(error.ReturnCode, error.ConditionCode, null);
}
