using System.IO;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using LazyScan.Core;

namespace LazyScan.App;

// The short visible texts of the scan screen and the state shown instead of instructions: the status
// line (the whole sentence stays its accessible name), the Save button with its page count, lock and
// menu, the selected area of the preview, and the overlay while photos are dragged over the window.
public partial class MainWindow
{
    /// <summary>The status sentence last shown, so a change is read out once.</summary>
    private string? _statusShown;

    /// <summary>
    /// At most six words, facts only (<see cref="StatusLine.Shown"/>). While a review is open (photos,
    /// receipts, the ID card) its title says what was found, so the line stays empty; while the Saved
    /// bar shows, it says "Saved", with any warning a setting changed for the scanner adds ("Saved ·
    /// 600 dpi used").
    /// </summary>
    private void SyncStatusLine()
    {
        string full = ViewModel.StatusMessage;
        bool idle = !ViewModel.IsBusy;
        string device = ViewModel.Devices.FirstOrDefault(d => d.Id == ViewModel.SelectedDeviceId)?.Name ?? "";
        string shown = StatusLine.Shown(full, device,
                                        reviewShown: idle && (ViewModel.ShowPhotoReview || ViewModel.ShowIdCardReview),
                                        savedShown: idle && ViewModel.SavedBarPaths is not null);
        StatusText.Text = shown;
        AutomationProperties.SetName(StatusText, full);
        if (full != _statusShown)
        {
            _statusShown = full;
            if (StatusText.IsVisible)
            {
                var peer = UIElementAutomationPeer.FromElement(StatusText) ?? UIElementAutomationPeer.CreatePeerForElement(StatusText);
                peer?.RaiseAutomationEvent(AutomationEvents.LiveRegionChanged);
            }
        }
    }

    /// <summary>
    /// "Save PDF" with a badge of the pages it saves ("Save 3 PDFs" for a split queue), a lock instead
    /// of the PDF glyph while the PDF gets a password, and its name for screen readers: "Save PDF, 5
    /// pages" or "Save password-protected PDF, 5 pages". With pages queued but none to save, it is
    /// greyed out and its tooltip says why. While a PDF picked on the start screen takes the pages it
    /// reads "Add to Contract.pdf", with the file's path and a × under it.
    /// </summary>
    private void SyncSaveButton(SavePlan savePlan, int pageCount)
    {
        var format = ViewModel.Settings.Format;
        int saveCount = savePlan.PageCount;
        string? target = ViewModel.AppendTarget;
        string label = target is not null
            ? PdfAppender.SaveTitle(Path.GetFileName(target))
            : Regex.Replace(savePlan.SaveTitle(format), @" \(\d+ pages?\)$", "");
        bool pdf = target is not null || OutputFormats.QueueFormat(format) == OutputFormat.Pdf;
        // The file decides: pages added to it get no password.
        bool locked = target is null && pdf && ViewModel.Settings.Output.Protect;
        SavePdfButton.Content = label;
        SavePdfButton.Tag = saveCount > 0 ? saveCount.ToString(System.Globalization.CultureInfo.CurrentCulture) : null;
        global::LazyScan.App.Icon.SetGlyph(SavePdfButton, locked ? "" : pdf ? "" : "");
        string spoken = locked ? label.Replace("PDF", "password-protected PDF", StringComparison.Ordinal) : label;
        AutomationProperties.SetName(SavePdfButton,
            saveCount > 0 ? $"{spoken}, {saveCount} page{(saveCount == 1 ? "" : "s")}" : spoken);
        bool nothingToSave = pageCount > 0 && saveCount == 0;
        SavePdfButton.ToolTip = nothingToSave ? PageFilter.NothingToSaveMessage : null;
        ToolTipService.SetShowOnDisabled(SavePdfButton, true);
        SavePdfButton.IsEnabled = saveCount > 0 && !ViewModel.IsBusy;
        // The menu's ways to save need pages to save too: it greys out with the button.
        SaveMenuButton.IsEnabled = saveCount > 0 && !ViewModel.IsBusy;
        AddToPdfButton.IsEnabled = saveCount > 0 && !ViewModel.IsBusy;
        AddToPdfButton.ToolTip = nothingToSave ? PageFilter.NothingToSaveMessage : PdfAppender.ButtonHint;
        AppendTargetText.Text = target ?? "";
        AppendTargetText.ToolTip = target;
        ClearAppendTargetButton.IsEnabled = !ViewModel.IsBusy;
    }

    /// <summary>The Save button's ▾: the other ways to save the queue.</summary>
    private void SaveMenu_Click(object sender, RoutedEventArgs e)
    {
        if (SaveMenuButton.ContextMenu is not { } menu) return;
        menu.PlacementTarget = SaveMenuButton;
        menu.Placement = PlacementMode.Bottom;
        menu.IsOpen = true;
    }

    /// <summary>"Using the selected area" under Paper size while an area of the preview is selected, with × to clear it.</summary>
    private void SyncSelectedArea()
    {
        bool area = ViewModel.SelectionRect is not null && ViewModel.OverviewImage is not null
                    && ViewModel.Settings.Source == ScanSource.Flatbed;
        SelectedAreaRow.Visibility = area ? Visibility.Visible : Visibility.Collapsed;
        PaperSizeHint.Text = area ? PaperSizes.SelectedAreaNote : "";
        ClearSelectionButton.IsEnabled = !ViewModel.IsBusy;
    }

    private void ClearSelection_Click(object sender, RoutedEventArgs e)
    {
        ViewModel.SelectionRect = null;
        UpdateMarquee();
        RefreshFromViewModel();
        PaperSizeBox.Focus();
    }

    /// <summary>Photos the window would import are dragged over it: the overlay says where they go.</summary>
    private void ShowDropOverlay(bool show) =>
        DropOverlay.Visibility = show ? Visibility.Visible : Visibility.Collapsed;

    /// <summary>
    /// The drag left an element, the window, or was cancelled: the overlay goes. Moving from one part
    /// of the window to another raises DragEnter on the next part in the same step, which shows the
    /// overlay again before anything is drawn. (The position of a DragLeave is not the pointer's, so
    /// it can't tell the two apart.)
    /// </summary>
    private void Window_PreviewDragLeave(object sender, DragEventArgs e) => ShowDropOverlay(false);

    /// <summary>Codes are on separator sheets (left out) or on the documents' first pages (kept).</summary>
    private void CodesOn_Changed(object sender, RoutedEventArgs e)
    {
        if (_updatingUi || !IsLoaded) return;
        ViewModel.SetBarcodeStartsDocument(CodesOnFirstPagesButton.IsChecked == true);
        SyncSplitOptions();
        RefreshFromViewModel();
    }
}

/// <summary>Shows a placeholder over a text box while the box is empty.</summary>
internal static class Placeholders
{
    public static void Attach(TextBox box, TextBlock placeholder)
    {
        void Sync() => placeholder.Visibility = box.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        box.TextChanged += (_, _) => Sync();
        Sync();
    }
}
