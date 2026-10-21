using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using CompleteScanner.Core;

namespace CompleteScanner.App;

// The Copy task's section of the inspector and printing the ID card (AppViewModel.Copy.cs).
public partial class MainWindow
{
    /// <summary>The printer names the printer box was last filled with.</summary>
    private string _copyPrintersShown = "\u0000";

    /// <summary>Fills the copies box (1 to 99) once.</summary>
    private void BuildCopyCountItems()
    {
        for (int count = 1; count <= PrintCopies.MaxCount; count++) CopyCountBox.Items.Add(count);
    }

    /// <summary>The Copy task's section: shown for the task only, with the printers, the paper and the choices.</summary>
    private void SyncCopyOptions()
    {
        bool copy = ViewModel.IsCopyFlow;
        CopyOptions.Visibility = copy ? Visibility.Visible : Visibility.Collapsed;
        if (!copy) return;
        var options = ViewModel.Settings.TaskOptions;
        var printers = ViewModel.Printers;
        bool wasUpdating = _updatingUi;
        _updatingUi = true;
        try
        {
            string shown = string.Join('\u001f', printers.Select(p => $"{p.Name}\u001e{p.IsDefault}"));
            if (shown != _copyPrintersShown)
            {
                _copyPrintersShown = shown;
                CopyPrinterBox.Items.Clear();
                foreach (var printer in printers)
                {
                    CopyPrinterBox.Items.Add(new ComboBoxItem
                    {
                        Content = printer.IsDefault ? $"{printer.Name} (default)" : printer.Name,
                        Tag = printer.Name,
                    });
                }
            }
            string? current = ViewModel.CopyPrinterName;
            CopyPrinterBox.SelectedItem = CopyPrinterBox.Items.Cast<ComboBoxItem>()
                .FirstOrDefault(i => string.Equals((string)i.Tag, current, StringComparison.OrdinalIgnoreCase));
            CopyCountBox.SelectedItem = PrintCopies.Clamp(options.CopyCount);
            CopyFitBox.IsChecked = options.CopyFitToPage;
            CopyPdfBox.IsChecked = options.CopyAlsoSavePdf;
        }
        finally
        {
            _updatingUi = wasUpdating;
        }
        bool none = !ViewModel.HasPrinter;
        CopyNoPrinterNotice.Visibility = none ? Visibility.Visible : Visibility.Collapsed;
        CopyLookAgainButton.Visibility = none ? Visibility.Visible : Visibility.Collapsed;
        CopyPrinterBox.IsEnabled = !none;
        RulerButton.IsEnabled = !none && !ViewModel.IsBusy;
        // "Paper: Letter"; its size is the tooltip, and the whole of it the printer's help text.
        string paper = ViewModel.CopyPaperText;
        int sizeAt = paper.IndexOf(" (", StringComparison.Ordinal);
        string paperName = sizeAt > 0 ? paper[..sizeAt] : paper;
        CopyPaperText.Text = paper.Length > 0 ? $"Paper: {paperName}" : "";
        CopyPaperText.ToolTip = sizeAt > 0 ? paper[(sizeAt + 2)..].TrimEnd(')') : null;
        CopyPaperText.Visibility = CopyPaperText.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        AutomationProperties.SetName(CopyPaperText, paper.Length > 0
            ? $"Printer paper: {paper.Replace(" (", ", ", StringComparison.Ordinal).Replace(" × ", " by ", StringComparison.Ordinal).Replace(" in)", " inches", StringComparison.Ordinal).TrimEnd(')')}"
            : "");
        string fitHint = options.CopyFitToPage
            ? "Made smaller to fit the paper, never larger. It is not at real size."
            : "At real size, like a photocopier: 1 inch on the glass is 1 inch on paper.";
        AutomationProperties.SetHelpText(CopyFitBox, fitHint);
        // Edges a printer can't reach are lost at real size: always shown while that is the case.
        CopyMarginText.Text = ViewModel.CopyMarginWarning ?? "";
        CopyMarginNotice.Visibility = ViewModel.CopyMarginWarning is null ? Visibility.Collapsed : Visibility.Visible;
        AutomationProperties.SetHelpText(CopyPrinterBox, paper.Length > 0 ? $"Paper: {paper}" : "");
    }

    private void CopyPrinterBox_DropDownOpened(object? sender, EventArgs e) => _ = ViewModel.RefreshPrintersAsync();

    private void CopyLookAgain_Click(object sender, RoutedEventArgs e) => _ = ViewModel.RefreshPrintersAsync();

    private void CopyPrinter_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (_updatingUi || !IsLoaded || CopyPrinterBox.SelectedItem is not ComboBoxItem { Tag: string name }) return;
        ViewModel.SetCopyPrinter(name);
    }

    private void CopyCount_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (_updatingUi || !IsLoaded || CopyCountBox.SelectedItem is not int count) return;
        ViewModel.SetCopyCount(count);
    }

    private void CopyFit_Changed(object sender, RoutedEventArgs e)
    {
        if (_updatingUi || !IsLoaded) return;
        ViewModel.SetCopyFitToPage(CopyFitBox.IsChecked == true);
    }

    private void CopyPdf_Changed(object sender, RoutedEventArgs e)
    {
        if (_updatingUi || !IsLoaded) return;
        ViewModel.SetCopyAlsoSavePdf(CopyPdfBox.IsChecked == true);
    }

    private void RulerPage_Click(object sender, RoutedEventArgs e) => _ = ViewModel.PrintRulerPage();

    private void IdCardPrint_Click(object sender, RoutedEventArgs e) => _ = ViewModel.PrintIdCard();

    /// <summary>The review's Print button: on the printer chosen for copies, else the default one.</summary>
    private void SyncIdCardPrint(bool busy)
    {
        string? printer = ViewModel.CopyPrinterName;
        bool canPrint = ViewModel.HasPrinter && ViewModel.IdCardFront is not null;
        IdCardPrintButton.IsEnabled = !busy && canPrint;
        string tip = !ViewModel.HasPrinter
            ? PrintText.NoPrinterMessage
            : $"Print at real size on {printer ?? "the default printer"}";
        IdCardPrintButton.ToolTip = tip;
        AutomationProperties.SetHelpText(IdCardPrintButton, tip);
    }
}
