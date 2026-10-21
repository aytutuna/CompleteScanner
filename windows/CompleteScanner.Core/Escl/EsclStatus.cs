using System.Xml;
using System.Xml.Linq;

namespace CompleteScanner.Core;

// Twin of Sources/CompleteScannerKit/Escl/EsclStatus.swift: the same rules and tests on both platforms.

/// <summary>
/// A parsed eSCL ScannerStatus document: the device state (pwg:State) and the feeder state
/// (scan:AdfState), read after a job fails to tell the user what is wrong at the scanner.
/// </summary>
public sealed class EsclScannerStatus
{
    /// <summary>"Idle", "Processing", "Testing", "Stopped" or "Down".</summary>
    public string? State { get; init; }
    /// <summary>e.g. "ScannerAdfLoaded", "ScannerAdfEmpty", "ScannerAdfJam"; null without a feeder.</summary>
    public string? AdfState { get; init; }

    /// <summary>The status document, or null when the text is not XML.</summary>
    public static EsclScannerStatus? Parse(string xml)
    {
        XElement? root;
        try
        {
            root = XDocument.Parse(xml).Root;
        }
        catch (XmlException)
        {
            return null;
        }
        if (root is null) return null;
        return new EsclScannerStatus
        {
            State = Text(root, "State"),
            AdfState = Text(root, "AdfState"),
        };
    }

    /// <summary>
    /// What stops a scan from <paramref name="source"/>: the feeder state first for feeder
    /// jobs (the platen ignores it), then the device state. null when nothing is wrong.
    /// </summary>
    public ScannerProblem? Problem(ScanSource source)
    {
        if (source == ScanSource.DocumentFeeder && AdfProblem(AdfState) is { } adf) return adf;
        return State switch
        {
            "Down" => ScannerProblem.Offline,
            "Stopped" => ScannerProblem.NeedsAttention,
            "Testing" => ScannerProblem.WarmingUp,
            "Processing" => ScannerProblem.Busy,
            _ => null,
        };
    }

    private static ScannerProblem? AdfProblem(string? adfState) => adfState switch
    {
        "ScannerAdfEmpty" => ScannerProblem.FeederEmpty,
        "ScannerAdfJam" => ScannerProblem.PaperJam,
        "ScannerAdfHatchOpen" => ScannerProblem.CoverOpen,
        "ScannerAdfMultipickDetected" => ScannerProblem.MultiFeed,
        "ScannerAdfMispick" or "ScannerAdfDuplexPageTooShort" or "ScannerAdfDuplexPageTooLong"
            or "ScannerAdfInputTrayFailed" or "ScannerAdfInputTrayOverloaded" => ScannerProblem.PaperProblem,
        _ => null,
    };

    private static string? Text(XElement root, string localName) =>
        root.Descendants().FirstOrDefault(e => e.Name.LocalName == localName)?.Value.Trim() is { Length: > 0 } text
            ? text
            : null;
}
