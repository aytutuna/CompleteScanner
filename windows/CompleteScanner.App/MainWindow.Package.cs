using System.Windows;

namespace CompleteScanner.App;

/// <summary>
/// A <c>.csdoc</c> opened by hand: given on the command line (File Explorer, through
/// <see cref="Services.FileAssociation"/>), dropped on the window or picked with Import photos. The bar
/// above the window content offers it (<see cref="AppViewModel.PendingPackage"/>) until it is added,
/// opened as new or dismissed.
/// </summary>
public partial class MainWindow
{
    /// <summary>The offer the bar shows; a new one is announced.</summary>
    private PendingPackage? _shownPackage;

    /// <summary>Opens the first <c>.csdoc</c> among the command line's arguments (File Explorer passes one).</summary>
    private void OpenCommandLinePackage()
    {
        if (Environment.GetCommandLineArgs().Skip(1).FirstOrDefault(PendingPackage.IsPackageFile) is { } path)
        {
            _ = ViewModel.OpenPackage(path);
        }
    }

    private void SyncPackageBar()
    {
        if (ViewModel.PendingPackage is not { } package)
        {
            if (PackageBar.IsKeyboardFocusWithin) FocusMainAction();
            PackageBar.Visibility = Visibility.Collapsed;
            _shownPackage = null;
            return;
        }
        bool isNew = !ReferenceEquals(package, _shownPackage);
        _shownPackage = package;
        PackageBarMessage.Text = PackageText.OpenedMessage(package.FileName, package.PageCount);
        // While work runs or a review is open the buttons wait; where the queue collects no pages a click says why.
        bool takes = ViewModel.CanTakePhonePages || (!ViewModel.IsBusy && !ViewModel.CollectsPackages);
        PackageAddButton.IsEnabled = takes;
        PackageOpenButton.IsEnabled = takes;
        PackageBar.Visibility = Visibility.Visible;
        if (isNew) AnnounceWhenShown(PackageBarText);
    }

    private void PackageAdd_Click(object sender, RoutedEventArgs e) => _ = ViewModel.AddPendingPackageToPages();

    private void PackageOpen_Click(object sender, RoutedEventArgs e) => _ = ViewModel.OpenPendingPackageAsNew();

    private void PackageBarClose_Click(object sender, RoutedEventArgs e)
    {
        FocusMainAction();
        ViewModel.DismissPendingPackage();
    }
}
