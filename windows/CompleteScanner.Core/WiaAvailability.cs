namespace CompleteScanner.Core;

// Whether the Windows WIA backend (CompleteScanner.App/Scanning/WiaScannerBackend.cs) may create
// WIA Automation objects, and what devices.txt says about it, kept here so it can be unit-tested.
// WIA exists only on Windows, so there is no Swift twin.

/// <summary>
/// Decides, before any WIA Automation object is created, whether WIA can be asked for scanners:
/// the Windows Image Acquisition service (stisvc) must be running (or starting) and WIA
/// Automation (wiaaut.dll) registered. Otherwise the connection lists nothing and says why,
/// instead of calling into a WIA that is not there.
/// </summary>
public static class WiaAvailability
{
    /// <summary>
    /// Why WIA cannot be asked now; null when it can. A service state that could not be read
    /// (<see cref="ServiceStatus.Unknown"/>) does not stop it: WIA then answers for itself.
    /// </summary>
    public static string? Unavailable(ServiceStatus service, bool automationRegistered)
    {
        if (!automationRegistered) return "WIA Automation (wiaaut.dll) is not registered on this PC";
        return service switch
        {
            ServiceStatus.NotInstalled => "the Windows Image Acquisition service (stisvc) is not installed",
            ServiceStatus.Disabled => "the Windows Image Acquisition service (stisvc) is disabled",
            ServiceStatus.Stopped or ServiceStatus.Stopping or ServiceStatus.Paused
                => "the Windows Image Acquisition service (stisvc) is not running",
            _ => null,
        };
    }

    /// <summary>The WIA section of devices.txt: off, listing N scanners, or unavailable and why.</summary>
    public static string Report(bool browsing, string? unavailable, int scanners)
    {
        string state = !browsing ? "off"
            : unavailable is not null ? "unavailable - " + unavailable
            : $"{scanners} scanner(s)";
        return $"WIA: {state}\n";
    }
}
