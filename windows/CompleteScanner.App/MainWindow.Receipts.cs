using System.Windows;
using System.Windows.Automation;
using CompleteScanner.Core;

namespace CompleteScanner.App;

// The Receipts task's section of the inspector (AppViewModel.Receipts.cs).
public partial class MainWindow
{
    /// <summary>The Receipts task's section: shown for the task only, with how the receipts are named and saved.</summary>
    private void SyncReceiptOptions()
    {
        bool receipts = ViewModel.IsReceiptFlow;
        ReceiptOptions.Visibility = receipts ? Visibility.Visible : Visibility.Collapsed;
        if (!receipts) return;
        var options = ViewModel.Settings.TaskOptions;
        bool wasUpdating = _updatingUi;
        _updatingUi = true;
        try
        {
            ReceiptDateBox.IsChecked = options.ReceiptNameByDate;
            ReceiptCombineBox.IsChecked = options.ReceiptCombine;
        }
        finally
        {
            _updatingUi = wasUpdating;
        }
        // On without {docdate} in the file name, the switch does nothing: the reason shows under it.
        bool dateUnused = options.ReceiptNameByDate && !Receipts.NamesByDate(ViewModel.Settings);
        const string unusedHint = "The file name has no {docdate}, so the date printed on the receipt is not used.";
        string dateHint = !options.ReceiptNameByDate
            ? "Each file is named by today's date."
            : dateUnused
                ? unusedHint
                : "Each file is named by the date printed on the receipt ({docdate}), read from its text; today's date when none is found.";
        AutomationProperties.SetHelpText(ReceiptDateBox, dateHint);
        ReceiptDateReason.Visibility = dateUnused ? Visibility.Visible : Visibility.Collapsed;
        ReceiptDateBox.ToolTip = dateUnused ? unusedHint : "Uses the date printed on the receipt, or today";
        bool pdf = OutputFormats.PageFormat(ViewModel.Settings.Format) == OutputFormat.Pdf;
        ReceiptCombineBox.IsEnabled = pdf;
        // Greyed out while receipts are saved as images: the reason shows next to it.
        ReceiptCombineReason.Visibility = pdf ? Visibility.Collapsed : Visibility.Visible;
        string combineHint = !pdf
            ? "Only for PDFs: each receipt is saved as an image of its own."
            : options.ReceiptCombine
                ? "All the receipts of a scan go into one PDF, a page each, named by the earliest date."
                : "Each receipt is saved as a PDF of its own.";
        ReceiptCombineBox.ToolTip = "Off: a PDF for each receipt";
        AutomationProperties.SetHelpText(ReceiptCombineBox, combineHint);
    }

    private void ReceiptDate_Changed(object sender, RoutedEventArgs e)
    {
        if (_updatingUi || !IsLoaded) return;
        ViewModel.SetReceiptNameByDate(ReceiptDateBox.IsChecked == true);
    }

    private void ReceiptCombine_Changed(object sender, RoutedEventArgs e)
    {
        if (_updatingUi || !IsLoaded) return;
        ViewModel.SetReceiptCombine(ReceiptCombineBox.IsChecked == true);
    }
}
