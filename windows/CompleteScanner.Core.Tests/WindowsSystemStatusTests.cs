using CompleteScanner.Core;
using Xunit;

namespace CompleteScanner.Core.Tests;

// The Windows service and network facts are Windows-only: no Swift counterpart.

public class WindowsSystemStatusTests
{
    public static TheoryData<int, int?, ServiceStatus> Services => new()
    {
        { WindowsSystemStatus.ServiceRunning, 2, ServiceStatus.Running },
        { WindowsSystemStatus.ServiceRunning, WindowsSystemStatus.ServiceDisabledStart, ServiceStatus.Running },
        { WindowsSystemStatus.ServiceStartPending, 3, ServiceStatus.Starting },
        { WindowsSystemStatus.ServiceContinuePending, 2, ServiceStatus.Starting },
        { WindowsSystemStatus.ServiceStopPending, 2, ServiceStatus.Stopping },
        { WindowsSystemStatus.ServicePausePending, 2, ServiceStatus.Paused },
        { WindowsSystemStatus.ServicePaused, 2, ServiceStatus.Paused },
        { WindowsSystemStatus.ServiceStopped, 2, ServiceStatus.Stopped },
        { WindowsSystemStatus.ServiceStopped, 3, ServiceStatus.Stopped },
        { WindowsSystemStatus.ServiceStopped, null, ServiceStatus.Stopped },
        { WindowsSystemStatus.ServiceStopped, WindowsSystemStatus.ServiceDisabledStart, ServiceStatus.Disabled },
        { 0, 2, ServiceStatus.Unknown },
        { 99, 2, ServiceStatus.Unknown },
    };

    [Theory]
    [MemberData(nameof(Services))]
    public void ServiceStateMapsToStatus(int currentState, int? startType, ServiceStatus expected)
    {
        Assert.Equal(expected, WindowsSystemStatus.Service(currentState, startType));
    }

    [Fact]
    public void WiaServiceName()
    {
        Assert.Equal("stisvc", WindowsSystemStatus.WiaServiceName);
    }

    [Theory]
    [InlineData(0, NetworkStatus.PublicNetwork)]
    [InlineData(1, NetworkStatus.PrivateNetwork)]
    [InlineData(2, NetworkStatus.DomainNetwork)]
    [InlineData(7, NetworkStatus.Unknown)]
    public void NetworkCategoryMapsToStatus(int category, NetworkStatus expected)
    {
        Assert.Equal(expected, WindowsSystemStatus.Network(category));
    }
}
