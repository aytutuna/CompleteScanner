namespace LazyScan.App.Scanning;

/// <summary>
/// A session that can scan through the scanner driver's own settings window (TWAIN's
/// "show UI"). The resolution, color and area the app sets are then only the window's
/// starting point; the user finishes the settings there and starts the scan from it.
/// </summary>
internal interface IDriverWindowOption
{
    /// <summary>The scanner can scan without its window; when false, the window is always used.</summary>
    bool DriverWindowOptional { get; }

    /// <summary>Scan through the window (when it is optional).</summary>
    bool UseDriverWindow { get; set; }
}

/// <summary>A backend that adds a section to the device diagnostics file (devices.txt).</summary>
internal interface IBackendDiagnostics
{
    /// <summary>The section's text; null until the backend has something to say.</summary>
    string? DiagnosticsReport { get; }
}
