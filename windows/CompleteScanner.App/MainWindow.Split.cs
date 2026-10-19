using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using CompleteScanner.Core;

namespace CompleteScanner.App;

// Splitting a stack into documents (AppViewModel.Split.cs): the inspector's choice, the page
// strip's gaps and dividers, naming a document, and saving or printing the separator sheet.
public partial class MainWindow
{
    /// <summary>The split choices (as the inspector lists them) and the sheets per document, 1 to 99.</summary>
    private void BuildSplitChoices()
    {
        foreach (var mode in SplitModes.DisplayOrder)
        {
            SplitModeBox.Items.Add(new ComboBoxItem { Content = mode.Label(), Tag = mode, ToolTip = mode.Hint() });
        }
        SplitCountBox.ItemsSource = Enumerable.Range(1, 99).ToList();
    }

    /// <summary>
    /// Splitting works on pages collected in the queue only, where the strip shows the documents
    /// before saving: with each scan saved at once, for copies and receipts, the choice is off and
    /// says why.
    /// </summary>
    private void SyncSplitOptions()
    {
        var s = ViewModel.Settings;
        var flow = TaskCatalog.FlowOf(s);
        bool copy = flow == TaskFlowKind.Copy;
        bool receipts = flow == TaskFlowKind.ReceiptSplit;
        bool collecting = s.DocumentMultiPage && !copy && !receipts;
        bool wasUpdating = _updatingUi;
        _updatingUi = true;
        try
        {
            SplitModeBox.SelectedItem = SplitModeBox.Items.Cast<ComboBoxItem>().FirstOrDefault(i => (SplitMode)i.Tag == s.Document.SplitMode);
            int count = DocumentSplitter.ClampSheetCount(s.Document.SplitSheetCount);
            if (SplitCountBox.ItemsSource is List<int> counts && !counts.Contains(count))
            {
                SplitCountBox.ItemsSource = counts.Append(count).Order().ToList();
            }
            SplitCountBox.SelectedItem = count;
        }
        finally
        {
            _updatingUi = wasUpdating;
        }
        SplitModeBox.IsEnabled = collecting && !ViewModel.IsBusy;
        SplitCountRow.Visibility = collecting && s.Document.SplitMode == SplitMode.SheetCount ? Visibility.Visible : Visibility.Collapsed;
        string hint = copy
            ? "Copies print every page as scanned: nothing is split."
            : receipts
            ? "Each receipt is saved on its own."
            : !collecting
            ? "Only for pages collected before saving: a scan saved at once is one file."
            : s.Document.SplitMode == SplitMode.None
            ? s.Document.SplitMode.Hint() + " Right-click a page to start a new document there."
            : s.Document.SplitMode.Hint() + " Check the page strip before saving: click the gap between two pages to split or join there.";
        SplitHint.Text = hint;
        SplitModeBox.ToolTip = hint;
        AutomationProperties.SetHelpText(SplitModeBox, hint);
        // The separator sheet: a PDF in the scans folder, to print on any printer; or printed at
        // once on the printer chosen for copies.
        bool separators = collecting && s.Document.SplitMode == SplitMode.SeparatorSheet;
        var sheetPaper = SeparatorSheet.Paper(AppViewModel.RegionCode);
        SaveSeparatorButton.Visibility = separators ? Visibility.Visible : Visibility.Collapsed;
        SaveSeparatorButton.IsEnabled = !ViewModel.IsBusy;
        string saveHint = $"Saves a Patch T separator sheet ({sheetPaper.Label()}) as a PDF in the scans folder. Print it at actual size (100%) on any printer.";
        SaveSeparatorButton.ToolTip = saveHint;
        AutomationProperties.SetHelpText(SaveSeparatorButton, saveHint);
        PrintSeparatorButton.Visibility = separators ? Visibility.Visible : Visibility.Collapsed;
        PrintSeparatorButton.IsEnabled = ViewModel.HasPrinter && !ViewModel.IsBusy;
        string printHint = ViewModel.HasPrinter
            ? $"Prints a Patch T separator sheet at actual size on {ViewModel.CopyPrinterName ?? "the default printer"}, on the paper it has, with no print dialog. Print as many as you need."
            : PrintText.NoPrinterReason + " Save the separator sheet as a PDF to print it elsewhere.";
        PrintSeparatorButton.ToolTip = printHint;
        AutomationProperties.SetHelpText(PrintSeparatorButton, printHint);
        // At blank sheets one-sided, Skip blank pages has no say.
        SyncBlankPageOptions();
    }

    private void SplitMode_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (_updatingUi || !IsLoaded || SplitModeBox.SelectedItem is not ComboBoxItem { Tag: SplitMode mode }) return;
        ViewModel.SetSplitMode(mode);
        SyncSplitOptions();
        RefreshFromViewModel();
    }

    private void SplitCount_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (_updatingUi || !IsLoaded || SplitCountBox.SelectedItem is not int count) return;
        ViewModel.SetSplitSheetCount(count);
        RefreshFromViewModel();
    }

    private void SaveSeparator_Click(object sender, RoutedEventArgs e) => _ = SaveSeparatorAsync();

    private async Task SaveSeparatorAsync()
    {
        await ViewModel.SaveSeparatorSheet();
        RefreshFromViewModel();
    }

    private void PrintSeparator_Click(object sender, RoutedEventArgs e) => _ = PrintSeparatorAsync();

    private async Task PrintSeparatorAsync()
    {
        await ViewModel.PrintSeparatorSheet();
        RefreshFromViewModel();
    }

    /// <summary>The gap before a page, or its menu item: start a new document there, or join the page to the one before.</summary>
    private void PageBreak_Click(object sender, RoutedEventArgs e)
    {
        if (PageIdOf(sender) is not { } id) return;
        ViewModel.ToggleDocumentBreak(id);
        RefreshFromViewModel();
        Dispatcher.InvokeAsync(NamePageItems, System.Windows.Threading.DispatcherPriority.Loaded);
    }

    /// <summary>"Name this document…" in a page's menu: the name box opens over the page.</summary>
    private void PageName_Click(object sender, RoutedEventArgs e)
    {
        if (PageIdOf(sender) is not { } id || ViewModel.IsBusy) return;
        var item = ViewModel.ScannedPages.FirstOrDefault(p => p.Page.Id == id);
        if (item is null) return;
        _nameCancelled = false;
        item.NameDraft = ViewModel.DocumentLabelOf(id);
        item.IsNaming = true;
    }

    /// <summary>Esc in the name box: the name is left as it was.</summary>
    private bool _nameCancelled;

    private void NamePopup_Opened(object? sender, EventArgs e)
    {
        if (sender is Popup { Child: Border { Child: StackPanel panel } } && panel.Children.OfType<TextBox>().FirstOrDefault() is { } box)
        {
            // Focus once the popup's window is up, with the name selected to type over.
            Dispatcher.InvokeAsync(() =>
            {
                box.Focus();
                Keyboard.Focus(box);
                box.SelectAll();
            }, System.Windows.Threading.DispatcherPriority.Input);
        }
    }

    /// <summary>The name box closed (Enter, a click elsewhere): the name typed is kept, unless Esc cancelled it.</summary>
    private void NamePopup_Closed(object? sender, EventArgs e)
    {
        if (sender is not Popup { Tag: Guid id }) return;
        var item = ViewModel.ScannedPages.FirstOrDefault(p => p.Page.Id == id);
        bool cancelled = _nameCancelled;
        _nameCancelled = false;
        if (item is null) return;
        item.IsNaming = false;
        if (!cancelled) ViewModel.SetDocumentLabel(id, item.NameDraft);
        RefreshFromViewModel();
        Dispatcher.InvokeAsync(NamePageItems, System.Windows.Threading.DispatcherPriority.Loaded);
        int index = IndexOfPage(id);
        if (index >= 0 && PageList.ItemContainerGenerator.ContainerFromIndex(index) is ListBoxItem container) container.Focus();
    }

    private void NameBox_KeyDown(object sender, KeyEventArgs e)
    {
        if (PageIdOf(sender) is not { } id) return;
        var item = ViewModel.ScannedPages.FirstOrDefault(p => p.Page.Id == id);
        if (item is null) return;
        if (e.Key == Key.Escape)
        {
            _nameCancelled = true;
            item.IsNaming = false;
            e.Handled = true;
        }
        else if (e.Key == Key.Enter)
        {
            item.IsNaming = false;
            e.Handled = true;
        }
    }
}
