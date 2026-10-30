using LazyScan.Core;
using Xunit;

namespace LazyScan.Core.Tests;

// WIA is Windows-only: no Swift counterpart.

public class WiaAvailabilityTests
{
    [Theory]
    [InlineData(ServiceStatus.Running)]
    [InlineData(ServiceStatus.Starting)]
    [InlineData(ServiceStatus.Unknown)]
    // Stopped, stopping or paused: creating WIA's Device Manager starts stisvc on demand.
    [InlineData(ServiceStatus.Stopped)]
    [InlineData(ServiceStatus.Stopping)]
    [InlineData(ServiceStatus.Paused)]
    public void WiaIsAskedWhenItsServiceRunsOrCanBeStarted(ServiceStatus service)
    {
        Assert.Null(WiaAvailability.Unavailable(service, automationRegistered: true));
    }

    [Theory]
    [InlineData(ServiceStatus.NotInstalled, "the Windows Image Acquisition service (stisvc) is not installed")]
    [InlineData(ServiceStatus.Disabled, "the Windows Image Acquisition service (stisvc) is disabled")]
    public void WiaIsNotAskedWhenItsServiceCannotStart(ServiceStatus service, string reason)
    {
        Assert.Equal(reason, WiaAvailability.Unavailable(service, automationRegistered: true));
    }

    [Theory]
    [InlineData(ServiceStatus.Running)]
    [InlineData(ServiceStatus.Unknown)]
    [InlineData(ServiceStatus.Stopped)]
    [InlineData(ServiceStatus.NotInstalled)]
    public void WiaIsNotAskedWithoutWiaAutomation(ServiceStatus service)
    {
        Assert.Equal("WIA Automation (wiaaut.dll) is not registered on this PC",
                     WiaAvailability.Unavailable(service, automationRegistered: false));
    }

    [Fact]
    public void TheReportSaysWhetherWiaIsOffListingOrUnavailable()
    {
        Assert.Equal("WIA: off\n", WiaAvailability.Report(browsing: false, unavailable: "anything", scanners: 3));
        Assert.Equal("WIA: 2 scanner(s)\n", WiaAvailability.Report(browsing: true, unavailable: null, scanners: 2));
        Assert.Equal("WIA: unavailable - the Windows Image Acquisition service (stisvc) is disabled\n",
                     WiaAvailability.Report(true, WiaAvailability.Unavailable(ServiceStatus.Disabled, true), 0));
    }
}
