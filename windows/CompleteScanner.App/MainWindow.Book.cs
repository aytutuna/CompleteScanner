using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using CompleteScanner.Core;

namespace CompleteScanner.App;

// Books and magazines (AppViewModel.Book.cs): the inspector's book options, and splitting or joining
// a spread from a page's menu.
public partial class MainWindow
{
    /// <summary>The book's rotations, as the inspector lists them.</summary>
    private void BuildBookChoices()
    {
        foreach (int turns in BookPages.RotationChoices)
        {
            BookRotationBox.Items.Add(new ComboBoxItem { Content = BookPages.RotationLabel(turns), Tag = turns });
        }
    }

    /// <summary>
    /// Splitting facing pages works on pages collected in the queue only, where the strip shows the
    /// pages, scanned one side of each sheet: with two-sided scanning the switch is greyed out with
    /// "Not with two-sided" next to it (with each scan saved at once the section says so once). The
    /// reading order, the rotation and softening the spine's shadow show, indented, while spreads are split.
    /// </summary>
    private void SyncBookOptions()
    {
        var s = ViewModel.Settings;
        bool queue = PageProcessor.ChecksBlankPages(s);
        bool oneSide = BookPages.ScansOneSide(s);
        bool collecting = queue && oneSide;
        bool wasUpdating = _updatingUi;
        _updatingUi = true;
        try
        {
            SplitFacingPagesBox.IsChecked = s.Document.SplitFacingPages;
            BookRightToLeftBox.IsChecked = s.TaskOptions.BookRightToLeft;
            int turns = BookSplitter.NormalizedTurns(s.TaskOptions.BookRotationQuarterTurns);
            BookRotationBox.SelectedItem = BookRotationBox.Items.Cast<ComboBoxItem>().FirstOrDefault(i => (int)i.Tag == turns);
            SoftenSpineShadowBox.IsChecked = s.Document.SoftenSpineShadow;
        }
        finally
        {
            _updatingUi = wasUpdating;
        }
        SplitFacingPagesBox.IsEnabled = collecting && !ViewModel.IsBusy;
        BookOptions.Visibility = collecting && s.Document.SplitFacingPages ? Visibility.Visible : Visibility.Collapsed;
        string hint = BookPages.Hint(s);
        bool twoSided = queue && !oneSide;
        SplitFacingPagesHint.Text = twoSided ? BookPages.NotWithTwoSidedReason : "";
        SplitFacingPagesReason.Visibility = twoSided ? Visibility.Visible : Visibility.Collapsed;
        SplitFacingPagesBox.ToolTip = hint;
        AutomationProperties.SetHelpText(SplitFacingPagesBox, twoSided ? $"{BookPages.NotWithTwoSidedReason}. {hint}" : hint);
        string shadowHint = SpineShadow.Hint(s.Document.SoftenSpineShadow);
        SoftenSpineShadowBox.ToolTip = shadowHint;
        AutomationProperties.SetHelpText(SoftenSpineShadowBox, shadowHint);
    }

    private void SoftenSpineShadow_Changed(object sender, RoutedEventArgs e)
    {
        if (_updatingUi || !IsLoaded) return;
        ViewModel.SetSoftenSpineShadow(SoftenSpineShadowBox.IsChecked == true);
        SyncBookOptions();
        RefreshFromViewModel();
    }

    private void SplitFacingPages_Changed(object sender, RoutedEventArgs e)
    {
        if (_updatingUi || !IsLoaded) return;
        ViewModel.SetSplitFacingPages(SplitFacingPagesBox.IsChecked == true);
        SyncBookOptions();
        RefreshFromViewModel();
    }

    private void BookRightToLeft_Changed(object sender, RoutedEventArgs e)
    {
        if (_updatingUi || !IsLoaded) return;
        ViewModel.SetBookRightToLeft(BookRightToLeftBox.IsChecked == true);
        RefreshFromViewModel();
    }

    private void BookRotation_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (_updatingUi || !IsLoaded || BookRotationBox.SelectedItem is not ComboBoxItem { Tag: int turns }) return;
        ViewModel.SetBookRotation(turns);
        RefreshFromViewModel();
    }

    /// <summary>"Split this spread…" or "Change the split…" in a page's menu: the split dialog, then the spread split or joined.</summary>
    private async void PageSplitSpread_Click(object sender, RoutedEventArgs e)
    {
        if (PageIdOf(sender) is not { } id || ViewModel.IsBusy) return;
        var source = await ViewModel.LoadSpreadEditor(id);
        if (source is null)
        {
            RefreshFromViewModel();
            return;
        }
        var dialog = new SpreadSplitWindow(source) { Owner = this };
        if (dialog.ShowDialog() != true) return;
        if (dialog.Choice == SpreadSplitChoice.KeepWhole)
        {
            await ViewModel.JoinSpread(id);
        }
        else
        {
            await ViewModel.SplitSpread(id, dialog.Axis, dialog.Fraction);
        }
        RefreshFromViewModel();
    }

    /// <summary>"Join the two pages" in a page's menu: the spread becomes one page again.</summary>
    private async void PageJoinSpread_Click(object sender, RoutedEventArgs e)
    {
        if (PageIdOf(sender) is not { } id) return;
        await ViewModel.JoinSpread(id);
        RefreshFromViewModel();
    }
}
