using System.IO;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using CompleteScanner.Core;
using Microsoft.Win32;

namespace CompleteScanner.App;

/// <summary>
/// Import photos of documents: the button under Preview and Scan and the empty stage's link pick photo
/// files, and photos dropped anywhere on the window are taken too; the view model adds their pages
/// (<see cref="AppViewModel.ImportPhotos"/>), asking for the corners of a page it did not find
/// clearly in the corner editor (<see cref="PhotoCornersWindow"/>).
/// </summary>
public partial class MainWindow
{
    /// <summary>The picker's filter: the photo types first, then every file.</summary>
    private static string PhotoFilter =>
        "Photos (" + string.Join(", ", PhotoImport.FileExtensions.Select(e => "*." + e)) + ")|"
        + string.Join(";", PhotoImport.FileExtensions.Select(e => "*." + e)) + "|All files (*.*)|*.*";

    private void SetUpImport()
    {
        // An icon button: its tooltip is its name; what it does is its help text.
        string importName = PhotoImport.ButtonLabel.TrimEnd('…');
        ImportPhotosButton.ToolTip = importName;
        ToolTipService.SetShowOnDisabled(ImportPhotosButton, true);
        AutomationProperties.SetName(ImportPhotosButton, importName);
        AutomationProperties.SetHelpText(ImportPhotosButton, PhotoImport.ButtonHelp);
        CanvasImportButton.Content = PhotoImport.ButtonLabel;
        CanvasImportButton.ToolTip = PhotoImport.ButtonHint;
        AutomationProperties.SetHelpText(CanvasImportButton, PhotoImport.ButtonHelp);
        CanvasDropHint.Text = PhotoImport.DropHint;
        ViewModel.ReviewPhotoCorners = request => PhotoCornersWindow.Ask(this, request);
    }

    /// <summary>Import is offered with the queue: the button and the stage's link follow the settings and the work running.</summary>
    private void SyncImportOptions()
    {
        bool offered = PhotoImport.IsOffered(ViewModel.Settings);
        ImportPhotosButton.Visibility = offered ? Visibility.Visible : Visibility.Collapsed;
        ImportPhotosButton.IsEnabled = ViewModel.CanImportPhotos;
        CanvasImport.Visibility = offered ? Visibility.Visible : Visibility.Collapsed;
        CanvasImportButton.IsEnabled = ViewModel.CanImportPhotos;
    }

    private void ImportPhotos_Click(object sender, RoutedEventArgs e)
    {
        if (!ViewModel.CanImportPhotos) return;
        var dialog = new OpenFileDialog
        {
            Title = PhotoImport.PickerTitle,
            Filter = PhotoFilter,
            CheckFileExists = true,
            Multiselect = true,
        };
        string pictures = Environment.GetFolderPath(Environment.SpecialFolder.MyPictures);
        if (Directory.Exists(pictures)) dialog.InitialDirectory = pictures;
        if (dialog.ShowDialog(this) == true) _ = ViewModel.ImportPhotos(dialog.FileNames);
    }

    /// <summary>
    /// The files a drag carries, when they include photos and the window takes them now: to import
    /// them, or, while the settings do not collect pages in the queue (Photos mode, the ID card…) and
    /// nothing is running, to say why they are not imported (<see cref="PhotoImport.NotOfferedMessage"/>).
    /// Null otherwise: no photos, the source does not let them be copied, or work is running.
    /// </summary>
    private string[]? DroppedPhotos(DragEventArgs e)
    {
        if (e.Data.GetData(DataFormats.FileDrop) is not string[] paths || PhotoImport.PhotoFiles(paths).Count == 0) return null;
        if ((e.AllowedEffects & DragDropEffects.Copy) == 0) return null;
        bool takes = ViewModel.CanImportPhotos || (!ViewModel.IsBusy && !PhotoImport.IsOffered(ViewModel.Settings));
        return takes ? paths : null;
    }

    /// <summary>
    /// Files dragged over the window (it takes drops everywhere): photos it takes show the copy
    /// pointer (the files stay where they are), every other file drag the no-drop pointer. Drags of
    /// anything else (text, say) go on to the control under the pointer.
    /// </summary>
    private void Window_PreviewDragOver(object sender, DragEventArgs e)
    {
        if (!e.Data.GetDataPresent(DataFormats.FileDrop)) return;
        var photos = DroppedPhotos(e);
        e.Effects = photos is null ? DragDropEffects.None : DragDropEffects.Copy;
        // "Drop to add as pages" while the drop would add them (not when it would only say why not).
        ShowDropOverlay(photos is not null && ViewModel.CanImportPhotos);
        e.Handled = true;
    }

    private void Window_PreviewDrop(object sender, DragEventArgs e)
    {
        ShowDropOverlay(false);
        if (!e.Data.GetDataPresent(DataFormats.FileDrop)) return;
        e.Handled = true;
        if (DroppedPhotos(e) is not { } paths)
        {
            e.Effects = DragDropEffects.None;
            return;
        }
        // A copy: the source keeps its files.
        e.Effects = DragDropEffects.Copy;
        // Let the drag finish in the other app before the import (and any corner editor) starts; where
        // the settings do not import photos, the view model says why.
        Dispatcher.BeginInvoke(() => _ = ViewModel.ImportPhotos(paths));
    }
}
