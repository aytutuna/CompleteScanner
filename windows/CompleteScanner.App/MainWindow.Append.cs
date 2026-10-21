using System.IO;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using CompleteScanner.Core;
using Microsoft.Win32;

namespace CompleteScanner.App;

/// <summary>
/// Add to existing PDF…: the item in the Save button's menu picks a PDF and the view model adds the pages
/// to its end (<see cref="AppViewModel.AppendToPdf"/>); a question first when the file is signed or
/// is a PDF/A file the pages may not keep so.
/// </summary>
public partial class MainWindow
{
    private void SetUpAddToPdf()
    {
        AddToPdfButton.Header = PdfAppender.ButtonLabel;
        AddToPdfButton.ToolTip = PdfAppender.ButtonHint;
        ToolTipService.SetShowOnDisabled(AddToPdfButton, true);
        AutomationProperties.SetName(AddToPdfButton, PdfAppender.ButtonLabel);
        AutomationProperties.SetHelpText(AddToPdfButton, PdfAppender.ButtonHint);
        ViewModel.ConfirmAppend = message =>
            MessageBox.Show(this, message, "CompleteScanner", MessageBoxButton.YesNo, MessageBoxImage.Warning,
                            MessageBoxResult.No) == MessageBoxResult.Yes;
    }

    private void AddToPdf_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFileDialog
        {
            Title = PdfAppender.PickerTitle,
            Filter = "PDF documents (*.pdf)|*.pdf",
            CheckFileExists = true,
            Multiselect = false,
        };
        // Start where the app saves, where the PDF the pages belong to most likely is.
        if (Directory.Exists(ViewModel.DestinationFolder)) dialog.InitialDirectory = ViewModel.DestinationFolder;
        if (dialog.ShowDialog(this) == true) _ = ViewModel.AppendToPdf(dialog.FileName);
    }
}
