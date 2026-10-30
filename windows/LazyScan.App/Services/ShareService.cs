using Windows.ApplicationModel.DataTransfer;
using Windows.Storage;

namespace LazyScan.App.Services;

/// <summary>
/// The Windows share window for saved files, opened for a desktop window through
/// <see cref="DataTransferManagerInterop"/> (the SDK projection's wrapper of
/// IDataTransferManagerInterop). It lists Mail, Outlook, nearby sharing and other apps; the
/// files go only where the user sends them there. Use on the UI thread.
/// </summary>
public sealed class ShareService
{
    private readonly Func<IntPtr> _ownerWindow;
    private DataTransferManager? _manager;
    private IntPtr _managerWindow;
    /// <summary>What the next share window offers; read when Windows asks for the data.</summary>
    private (IReadOnlyList<string> Paths, string Title)? _pending;

    /// <param name="ownerWindow">The top-level window the share window belongs to (its HWND).</param>
    public ShareService(Func<IntPtr> ownerWindow)
    {
        _ownerWindow = ownerWindow;
    }

    /// <summary>Whether this Windows edition has the share window.</summary>
    public static bool IsSupported
    {
        get
        {
            try
            {
                return DataTransferManager.IsSupported();
            }
            catch
            {
                return false;
            }
        }
    }

    /// <summary>Opens the share window for <paramref name="paths"/>; returns as soon as it is up.</summary>
    /// <exception cref="InvalidOperationException">The app has no window to share from.</exception>
    public void Share(IReadOnlyList<string> paths, string title)
    {
        IntPtr window = _ownerWindow();
        if (window == IntPtr.Zero) throw new InvalidOperationException("The app window is not open.");
        if (_manager is null || _managerWindow != window)
        {
            if (_manager is not null) _manager.DataRequested -= OnDataRequested;
            _manager = DataTransferManagerInterop.GetForWindow(window);
            _manager.DataRequested += OnDataRequested;
            _managerWindow = window;
        }
        _pending = ([.. paths], title);
        DataTransferManagerInterop.ShowShareUIForWindow(window);
    }

    private async void OnDataRequested(DataTransferManager sender, DataRequestedEventArgs args)
    {
        var request = args.Request;
        if (_pending is not { } pending)
        {
            request.FailWithDisplayText("There is nothing to share.");
            return;
        }
        var deferral = request.GetDeferral();
        try
        {
            var files = new List<IStorageItem>();
            foreach (string path in pending.Paths)
            {
                files.Add(await StorageFile.GetFileFromPathAsync(path));
            }
            Fill(request.Data, files, pending.Title);
        }
        catch (Exception e)
        {
            request.FailWithDisplayText($"The file could not be shared: {e.Message}");
        }
        finally
        {
            deferral.Complete();
        }
    }

    /// <summary>Puts the files into a share package: as read-only copies, titled for the share window.</summary>
    internal static void Fill(DataPackage data, IReadOnlyList<IStorageItem> files, string title)
    {
        data.Properties.Title = title;
        data.Properties.Description = files.Count == 1 ? "Saved by Lazy Scan" : $"{files.Count} files saved by Lazy Scan";
        data.Properties.ApplicationName = "Lazy Scan";
        data.RequestedOperation = DataPackageOperation.Copy;
        data.SetStorageItems(files, readOnly: true);
    }
}
