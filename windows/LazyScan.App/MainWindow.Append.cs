using System.IO;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using LazyScan.Core;
using Microsoft.Win32;

namespace LazyScan.App;

/// <summary>
/// Add to existing PDF…: the item in the Save button's menu picks a PDF and the view model adds the pages
/// to its end (<see cref="AppViewModel.AppendToPdf"/>); a question first when the file is signed or
/// is a PDF/A file the pages may not keep so. The start screen's "Add pages to a PDF" picks the PDF
/// before scanning instead, and Save adds the pages to it (<see cref="AppViewModel.AppendTarget"/>).
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
            MessageBox.Show(this, message, "Lazy Scan", MessageBoxButton.YesNo, MessageBoxImage.Warning,
                            MessageBoxResult.No) == MessageBoxResult.Yes;
    }

    private void AddToPdf_Click(object sender, RoutedEventArgs e)
    {
        if (PickPdfToAddTo() is { } path) _ = ViewModel.AppendToPdf(path);
    }

    private void StartAddingToPdf()
    {
        if (ViewModel.IsBusy || PickPdfToAddTo() is not { } path) return;
        if (!ConfirmDropIdCard() || !ViewModel.StartTask(ScanTask.Document)) return;
        ViewModel.SetAppendTarget(path);
        OpenSectionFor(ScanTask.Document);
        PushSettingsToUi();
        ShowScanScreen();
    }

    private void ClearAppendTarget_Click(object sender, RoutedEventArgs e)
    {
        ViewModel.ClearAppendTarget();
        // The × goes away with the row.
        if (SavePdfButton.IsEnabled) SavePdfButton.Focus();
        else FocusMainAction();
    }

    private string? PickPdfToAddTo()
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
        return dialog.ShowDialog(this) == true ? dialog.FileName : null;
    }
}
