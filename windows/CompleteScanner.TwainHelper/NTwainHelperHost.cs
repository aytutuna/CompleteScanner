using CompleteScanner.App.Scanning.Twain;
using CompleteScanner.Core;

namespace CompleteScanner.TwainHelper;

/// <summary>The helper's TWAIN: NTwain against the 32-bit Data Source Manager, through the app's own session code.</summary>
internal sealed class NTwainHelperHost : ITwainHelperHost
{
    private readonly NTwainSessionHost _session = new();

    public TwainHelperSourceList ListSources()
    {
        var availability = _session.EnsureSession();
        return new TwainHelperSourceList(availability,
                                         availability == TwainAvailability.Available ? _session.Sources() : []);
    }

    public ITwainTransport Open(string name) => _session.Open(name);

    public void Close(ITwainTransport source)
    {
        if (source is NTwainDriver driver) driver.Close();
    }
}
