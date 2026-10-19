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
        CopyNoPrinterText.Visibility = none ? Visibility.Visible : Visibility.Collapsed;
        CopyLookAgainButton.Visibility = none ? Visibility.Visible : Visibility.Collapsed;
        CopyPrinterBox.IsEnabled = !none;
        RulerButton.IsEnabled = !none && !ViewModel.IsBusy;
        CopyPaperText.Text = ViewModel.CopyPaperText.Length > 0 ? $"Paper: {ViewModel.CopyPaperText}" : "";
        CopyPaperText.Visibility = CopyPaperText.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        string fitHint = options.CopyFitToPage
            ? "Made smaller to fit the paper, never larger. It is not at real size."
            : "At real size, like a photocopier: 1 inch on the glass is 1 inch on paper.";
        CopyFitHint.Text = fitHint;
        AutomationProperties.SetHelpText(CopyFitBox, fitHint);
        CopyMarginText.Text = ViewModel.CopyMarginWarning ?? "";
        CopyMarginText.Visibility = ViewModel.CopyMarginWarning is null ? Visibility.Collapsed : Visibility.Visible;
        AutomationProperties.SetHelpText(CopyPrinterBox, CopyPaperText.Text);
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
            : printer is null
                ? "Print the page at real size on the default printer"
                : $"Print the page at real size on {printer}";
        IdCardPrintButton.ToolTip = tip;
        AutomationProperties.SetHelpText(IdCardPrintButton, tip);
    }
}
