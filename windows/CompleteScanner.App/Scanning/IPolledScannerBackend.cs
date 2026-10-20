using CompleteScanner.Core;

namespace CompleteScanner.App.Scanning;

/// <summary>
/// A connection that finds scanners by polling rather than from device events (WIA Automation,
/// <see cref="WiaScannerBackend"/>), so for a while it may not list a scanner another connection
/// already reports. The app asks it to look again and waits for that look to end before it
/// treats the scanner as one this connection does not reach (see <c>AppViewModel.MergeDevices</c>).
/// Every member is used on the thread that started browsing.
/// </summary>
public interface IPolledScannerBackend : IScannerBackend
{
    /// <summary>Raised when an enumeration has ended and its result is in <see cref="IScannerBackend.Devices"/>, whether or not the list changed.</summary>
    event Action? EnumerationFinished;

    /// <summary>How many enumerations have started; each one's number is this count right after it starts.</summary>
    long EnumerationsStarted { get; }

    /// <summary>The number of the latest enumeration whose result is in <see cref="IScannerBackend.Devices"/>; 0 before the first.</summary>
    long EnumerationsFinished { get; }

    /// <summary>
    /// Enumerate again now. When an enumeration is already running, another one starts as soon as
    /// it ends, so an enumeration that started after this call always follows.
    /// </summary>
    void RefreshDevices();
}
