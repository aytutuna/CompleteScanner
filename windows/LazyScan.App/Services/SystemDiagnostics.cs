using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows;
using LazyScan.Core;

namespace LazyScan.App.Services;

/// <summary>
/// What the troubleshooter reads from Windows and the two things it does there: open a page of
/// Windows Settings and copy text. It never changes a service or a setting. Harnesses stand in
/// for it so checks open nothing and leave the clipboard alone.
/// </summary>
public interface ISystemDiagnostics
{
    /// <summary>The Windows Image Acquisition service (stisvc). Any thread; never throws.</summary>
    ServiceStatus WiaService();

    /// <summary>The networks this PC is connected to, combined (<see cref="Troubleshooter.CombineNetworks"/>). Any thread; never throws.</summary>
    NetworkStatus Network();

    /// <summary>
    /// Opens the Windows Settings page for <see cref="TroubleshootAction.OpenScannerSettings"/> or
    /// <see cref="TroubleshootAction.OpenNetworkSettings"/>. UI thread; throws when Windows refuses.
    /// </summary>
    void OpenSettings(TroubleshootAction action);

    /// <summary>Puts the text on the clipboard. UI thread; throws when the clipboard is busy.</summary>
    void CopyText(string text);
}

/// <summary>
/// The Windows implementation: the service through the Service Control Manager
/// (QueryServiceStatus, read-only access), the network category through the Network List
/// Manager (COM), Settings through its ms-settings: links.
/// </summary>
public sealed class WindowsSystemDiagnostics : ISystemDiagnostics
{
    /// <summary>Settings, Bluetooth &amp; devices, Printers &amp; scanners.</summary>
    public const string ScannerSettingsUri = "ms-settings:printers";
    /// <summary>Settings, Network &amp; internet.</summary>
    public const string NetworkSettingsUri = "ms-settings:network-status";

    public ServiceStatus WiaService()
    {
        IntPtr manager = IntPtr.Zero, service = IntPtr.Zero;
        try
        {
            manager = OpenSCManager(null, null, ScManagerConnect);
            if (manager == IntPtr.Zero) return ServiceStatus.Unknown;
            service = OpenService(manager, WindowsSystemStatus.WiaServiceName, ServiceQueryStatus | ServiceQueryConfig);
            if (service == IntPtr.Zero)
            {
                return Marshal.GetLastWin32Error() == ErrorServiceDoesNotExist ? ServiceStatus.NotInstalled : ServiceStatus.Unknown;
            }
            if (!QueryServiceStatus(service, out var status)) return ServiceStatus.Unknown;
            return WindowsSystemStatus.Service(status.CurrentState, StartType(service));
        }
        catch (Exception e)
        {
            // Never throws: the troubleshooter shows no service check rather than failing.
            Trace.TraceWarning($"Could not read the WIA service: {e.Message}");
            return ServiceStatus.Unknown;
        }
        finally
        {
            if (service != IntPtr.Zero) CloseServiceHandle(service);
            if (manager != IntPtr.Zero) CloseServiceHandle(manager);
        }
    }

    /// <summary>The service's start type (QUERY_SERVICE_CONFIG.dwStartType); null when it cannot be read.</summary>
    private static int? StartType(IntPtr service)
    {
        QueryServiceConfig(service, IntPtr.Zero, 0, out uint needed);
        if (Marshal.GetLastWin32Error() != ErrorInsufficientBuffer || needed == 0) return null;
        IntPtr buffer = Marshal.AllocHGlobal((int)needed);
        try
        {
            if (!QueryServiceConfig(service, buffer, needed, out _)) return null;
            // QUERY_SERVICE_CONFIG starts with dwServiceType, then dwStartType.
            return Marshal.ReadInt32(buffer, 4);
        }
        finally
        {
            Marshal.FreeHGlobal(buffer);
        }
    }

    public NetworkStatus Network()
    {
        INetworkListManager? manager = null;
        IEnumNetworks? networks = null;
        try
        {
            var type = Type.GetTypeFromCLSID(NetworkListManagerClsid, throwOnError: false);
            if (type is null) return NetworkStatus.Unknown;
            manager = (INetworkListManager)Activator.CreateInstance(type)!;
            if (!manager.IsConnected) return NetworkStatus.Offline;
            networks = manager.GetNetworks(NlmEnumNetworkConnected);
            var categories = new List<NetworkStatus>();
            while (networks.Next(1, out var network, out int fetched) == 0 && fetched == 1 && network is not null)
            {
                try
                {
                    categories.Add(WindowsSystemStatus.Network(network.GetCategory()));
                }
                finally
                {
                    Marshal.ReleaseComObject(network);
                }
            }
            return categories.Count == 0 ? NetworkStatus.Unknown : Troubleshooter.CombineNetworks(categories);
        }
        catch (Exception e)
        {
            // Never throws: the troubleshooter shows no network check rather than failing.
            Trace.TraceWarning($"Could not read the network category: {e.Message}");
            return NetworkStatus.Unknown;
        }
        finally
        {
            if (networks is not null) Marshal.ReleaseComObject(networks);
            if (manager is not null) Marshal.ReleaseComObject(manager);
        }
    }

    public void OpenSettings(TroubleshootAction action)
    {
        string uri = action switch
        {
            TroubleshootAction.OpenScannerSettings => ScannerSettingsUri,
            TroubleshootAction.OpenNetworkSettings => NetworkSettingsUri,
            _ => throw new ArgumentOutOfRangeException(nameof(action), action, "Not a Windows Settings page."),
        };
        using var process = Process.Start(new ProcessStartInfo(uri) { UseShellExecute = true });
    }

    public void CopyText(string text)
    {
        var data = new DataObject();
        data.SetText(text, TextDataFormat.UnicodeText);
        // copy: true keeps the text on the clipboard after the app exits.
        Clipboard.SetDataObject(data, copy: true);
    }

    // MARK: - Service Control Manager (winsvc.h); read-only access rights only.

    private const uint ScManagerConnect = 0x0001;
    private const uint ServiceQueryConfig = 0x0001;
    private const uint ServiceQueryStatus = 0x0004;
    private const int ErrorInsufficientBuffer = 122;
    private const int ErrorServiceDoesNotExist = 1060;

    [StructLayout(LayoutKind.Sequential)]
    private struct ServiceStatusRecord
    {
        public int ServiceType;
        public int CurrentState;
        public int ControlsAccepted;
        public int Win32ExitCode;
        public int ServiceSpecificExitCode;
        public int CheckPoint;
        public int WaitHint;
    }

    [DllImport("advapi32.dll", EntryPoint = "OpenSCManagerW", CharSet = CharSet.Unicode, SetLastError = true, ExactSpelling = true)]
    private static extern IntPtr OpenSCManager(string? machineName, string? databaseName, uint desiredAccess);

    [DllImport("advapi32.dll", EntryPoint = "OpenServiceW", CharSet = CharSet.Unicode, SetLastError = true, ExactSpelling = true)]
    private static extern IntPtr OpenService(IntPtr manager, string serviceName, uint desiredAccess);

    [DllImport("advapi32.dll", SetLastError = true, ExactSpelling = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool QueryServiceStatus(IntPtr service, out ServiceStatusRecord status);

    [DllImport("advapi32.dll", EntryPoint = "QueryServiceConfigW", CharSet = CharSet.Unicode, SetLastError = true, ExactSpelling = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool QueryServiceConfig(IntPtr service, IntPtr config, uint bufferSize, out uint bytesNeeded);

    [DllImport("advapi32.dll", SetLastError = true, ExactSpelling = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CloseServiceHandle(IntPtr handle);

    // MARK: - Network List Manager (netlistmgr.h). Only reading members are called; the others
    // are declared because the interfaces are called through their vtables, in header order.

    private static readonly Guid NetworkListManagerClsid = new("DCB00C01-570F-4A9B-8D69-199FDBA5723B");
    private const int NlmEnumNetworkConnected = 0x01;

    [ComImport, Guid("DCB00000-570F-4A9B-8D69-199FDBA5723B"), InterfaceType(ComInterfaceType.InterfaceIsDual)]
    private interface INetworkListManager
    {
        IEnumNetworks GetNetworks(int flags);
        [return: MarshalAs(UnmanagedType.IUnknown)] object GetNetwork(Guid networkId);
        [return: MarshalAs(UnmanagedType.IUnknown)] object GetNetworkConnections();
        [return: MarshalAs(UnmanagedType.IUnknown)] object GetNetworkConnection(Guid connectionId);
        bool IsConnectedToInternet { [return: MarshalAs(UnmanagedType.VariantBool)] get; }
        bool IsConnected { [return: MarshalAs(UnmanagedType.VariantBool)] get; }
    }

    [ComImport, Guid("DCB00003-570F-4A9B-8D69-199FDBA5723B"), InterfaceType(ComInterfaceType.InterfaceIsDual)]
    private interface IEnumNetworks
    {
        [return: MarshalAs(UnmanagedType.IUnknown)] object GetNewEnum();
        [PreserveSig] int Next(int count, out INetwork? network, out int fetched);
    }

    [ComImport, Guid("DCB00002-570F-4A9B-8D69-199FDBA5723B"), InterfaceType(ComInterfaceType.InterfaceIsDual)]
    private interface INetwork
    {
        [return: MarshalAs(UnmanagedType.BStr)] string GetName();
        void SetName([MarshalAs(UnmanagedType.BStr)] string name);
        [return: MarshalAs(UnmanagedType.BStr)] string GetDescription();
        void SetDescription([MarshalAs(UnmanagedType.BStr)] string description);
        Guid GetNetworkId();
        int GetDomainType();
        [return: MarshalAs(UnmanagedType.IUnknown)] object GetNetworkConnections();
        void GetTimeCreatedAndConnected(out uint lowCreated, out uint highCreated, out uint lowConnected, out uint highConnected);
        bool IsConnectedToInternet { [return: MarshalAs(UnmanagedType.VariantBool)] get; }
        bool IsConnected { [return: MarshalAs(UnmanagedType.VariantBool)] get; }
        int GetConnectivity();
        int GetCategory();
    }
}
