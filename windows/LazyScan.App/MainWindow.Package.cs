using System.Windows;
using LazyScan.Core;

namespace LazyScan.App;

/// <summary>
/// A <c>.lsdoc</c> opened by hand: given on the command line (File Explorer, through
/// <see cref="Services.FileAssociation"/>), dropped on the window or picked with Import photos. The bar
/// above the window content offers it (<see cref="AppViewModel.PendingPackage"/>) until it is added,
/// opened as new or dismissed.
/// </summary>
public partial class MainWindow
{
    /// <summary>The offer the bar shows; a new one is announced.</summary>
    private PendingPackage? _shownPackage;

    /// <summary>Opens the first <c>.lsdoc</c> among the command line's arguments (File Explorer passes one).</summary>
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
        bool turningOver = ViewModel.IsTurningOverByHand;
        PackageAddButton.ToolTip = turningOver ? DocumentSides.NotWhileTurningOverReason : "Add its pages after the pages in the queue";
        PackageOpenButton.ToolTip = turningOver ? DocumentSides.NotWhileTurningOverReason : "Clear the queue and open the document in its place";
        PackageBar.Visibility = Visibility.Visible;
        if (isNew) AnnounceWhenShown(PackageBarText);
    }

    private void PackageAdd_Click(object sender, RoutedEventArgs e) => _ = ViewModel.AddPendingPackageToPages();

    /// <summary>Open as new asks first while it would drop queued pages, as on the Mac and the iPhone.</summary>
    private void PackageOpen_Click(object sender, RoutedEventArgs e)
    {
        int n = ViewModel.ScannedPages.Count;
        // Where the settings collect no pages the click only says why, and the queue stays.
        if (n > 0 && ViewModel.CanTakePhonePages && ViewModel.PendingPackage is { } package)
        {
            string question = n == 1
                ? $"The page in the queue has not been saved. “{package.FileName}” opens in its place.\n\nDiscard the page?"
                : $"The {n} pages in the queue have not been saved. “{package.FileName}” opens in their place.\n\nDiscard the pages?";
            if (MessageBox.Show(this, question, "Lazy Scan", MessageBoxButton.YesNo, MessageBoxImage.Warning,
                                MessageBoxResult.No) != MessageBoxResult.Yes) return;
        }
        _ = ViewModel.OpenPendingPackageAsNew();
    }

    private void PackageBarClose_Click(object sender, RoutedEventArgs e)
    {
        FocusMainAction();
        ViewModel.DismissPendingPackage();
    }
}
