namespace CompleteScanner.Core;

// Windows facts the troubleshooter reads (CompleteScanner.App/Services/SystemDiagnostics.cs),
// kept here so they can be unit-tested: the App cannot be referenced by the tests. Values are
// from the Windows SDK headers (winsvc.h, netlistmgr.h). They exist only on Windows, so there is
// no Swift twin; the statuses they map to (Troubleshooter.cs) are shared.

/// <summary>Maps what Windows reports about services and networks to the troubleshooter's statuses.</summary>
public static class WindowsSystemStatus
{
    /// <summary>The Windows Image Acquisition (WIA) service.</summary>
    public const string WiaServiceName = "stisvc";

    // SERVICE_STATUS.dwCurrentState (winsvc.h).
    public const int ServiceStopped = 1;
    public const int ServiceStartPending = 2;
    public const int ServiceStopPending = 3;
    public const int ServiceRunning = 4;
    public const int ServiceContinuePending = 5;
    public const int ServicePausePending = 6;
    public const int ServicePaused = 7;

    // QUERY_SERVICE_CONFIG.dwStartType (winsvc.h).
    public const int ServiceDisabledStart = 4;

    // NLM_NETWORK_CATEGORY (netlistmgr.h).
    public const int NetworkCategoryPublic = 0;
    public const int NetworkCategoryPrivate = 1;
    public const int NetworkCategoryDomainAuthenticated = 2;

    /// <summary>
    /// A service's status from its current state and start type; a stopped service set not to
    /// start is <see cref="ServiceStatus.Disabled"/>. A start type that could not be read is
    /// null (the service then counts as stopped, not disabled).
    /// </summary>
    public static ServiceStatus Service(int currentState, int? startType) => currentState switch
    {
        ServiceRunning => ServiceStatus.Running,
        ServiceStartPending or ServiceContinuePending => ServiceStatus.Starting,
        ServiceStopPending => ServiceStatus.Stopping,
        ServicePausePending or ServicePaused => ServiceStatus.Paused,
        ServiceStopped => startType == ServiceDisabledStart ? ServiceStatus.Disabled : ServiceStatus.Stopped,
        _ => ServiceStatus.Unknown,
    };

    /// <summary>A connected network's category (NLM_NETWORK_CATEGORY) as a network status.</summary>
    public static NetworkStatus Network(int category) => category switch
    {
        NetworkCategoryPublic => NetworkStatus.PublicNetwork,
        NetworkCategoryPrivate => NetworkStatus.PrivateNetwork,
        NetworkCategoryDomainAuthenticated => NetworkStatus.DomainNetwork,
        _ => NetworkStatus.Unknown,
    };
}
