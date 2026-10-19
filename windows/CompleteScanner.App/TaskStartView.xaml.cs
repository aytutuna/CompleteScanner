using System.Collections.Specialized;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using CompleteScanner.Core;

namespace CompleteScanner.App;

/// <summary>
/// The start screen: one card per task (<see cref="TaskCatalog"/>), greyed out with the reason
/// when the connected scanner cannot do it, and the user's presets badged with their task.
/// Picking a card is reported to the window, which sets it up and opens the scan screen.
/// The twin of UI/TaskStartView.swift.
/// </summary>
public partial class TaskStartView : UserControl
{
    private AppViewModel? _viewModel;
    private List<TaskCardItem> _taskCards = [];
    private List<PresetCardItem> _presetCards = [];

    /// <summary>A task card was picked.</summary>
    public event Action<ScanTask>? TaskChosen;
    /// <summary>A preset card was picked.</summary>
    public event Action<Preset>? PresetChosen;
    /// <summary>"Go to Scan": open the scan screen without changing anything.</summary>
    public event Action? GoToScanRequested;

    public TaskStartView()
    {
        InitializeComponent();
    }

    public void Attach(AppViewModel viewModel)
    {
        _viewModel = viewModel;
        viewModel.Presets.CollectionChanged += Presets_CollectionChanged;
        Refresh();
    }

    private void Presets_CollectionChanged(object? sender, NotifyCollectionChangedEventArgs e) => Refresh();

    /// <summary>
    /// Updates the cards from the view model. A grid is rebuilt only when its cards changed, so
    /// keyboard focus stays on the card it was on.
    /// </summary>
    public void Refresh()
    {
        if (_viewModel is not { } vm) return;

        var tasks = vm.TaskCards.ToList();
        if (!tasks.Select(c => c.Signature).SequenceEqual(_taskCards.Select(c => c.Signature)))
        {
            _taskCards = tasks;
            TaskGrid.ItemsSource = _taskCards;
        }

        var presets = vm.Presets.Select(p => new PresetCardItem(p)).ToList();
        if (!presets.Select(c => c.Signature).SequenceEqual(_presetCards.Select(c => c.Signature)))
        {
            _presetCards = presets;
            PresetGrid.ItemsSource = _presetCards;
        }
        bool hasPresets = _presetCards.Count > 0;
        PresetGrid.Visibility = hasPresets ? Visibility.Visible : Visibility.Collapsed;
        NoPresetsText.Visibility = hasPresets ? Visibility.Collapsed : Visibility.Visible;

        // Like the presets in the side pane, the cards replace the settings, which an operation
        // in progress works from a snapshot of: they wait until it ends.
        TaskGrid.IsEnabled = !vm.IsBusy;
        PresetGrid.IsEnabled = !vm.IsBusy;
    }

    /// <summary>
    /// Puts keyboard focus on the current task's card (else the first card that can be started),
    /// so a returning user can press Enter to carry on.
    /// </summary>
    public void FocusDefaultCard()
    {
        UpdateLayout();
        var cards = TaskGrid.Items.Cast<TaskCardItem>().ToList();
        var preferred = cards.FirstOrDefault(c => c.IsCurrent && c.IsAvailable) ?? cards.FirstOrDefault(c => c.IsAvailable);
        if (preferred is null) return;
        if (TaskGrid.ItemContainerGenerator.ContainerFromItem(preferred) is ContentPresenter presenter
            && presenter.ContentTemplate?.FindName("Card", presenter) is Button card)
        {
            card.Focus();
            Keyboard.Focus(card);
        }
    }

    private void TaskCard_Click(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { DataContext: TaskCardItem card } && card.IsAvailable)
        {
            TaskChosen?.Invoke(card.Task);
        }
    }

    private void PresetCard_Click(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { DataContext: PresetCardItem card }) PresetChosen?.Invoke(card.Preset);
    }

    private void GoToScan_Click(object sender, RoutedEventArgs e) => GoToScanRequested?.Invoke();

    /// <summary>The scroll viewport changed width (resize, scrollbar shown or hidden): re-centre the grids.</summary>
    private void Scroller_ScrollChanged(object sender, ScrollChangedEventArgs e)
    {
        if (e.ViewportWidthChange != 0) UpdateInsets();
    }

    /// <summary>
    /// Centre the card grids: split the width left over after the last whole column between
    /// both sides, and line the header and section titles up with the grids' outer card edges.
    /// </summary>
    private void UpdateInsets()
    {
        var (cards, header) = GridInsets.For(Scroller.ViewportWidth);
        TaskGrid.Margin = new Thickness(cards.Left, 0, cards.Right, 0);
        PresetGrid.Margin = new Thickness(cards.Left, 0, cards.Right, 0);
        Header.Margin = new Thickness(header.Left, 20, header.Right, 4);
        TasksHeader.Margin = new Thickness(header.Left, 16, header.Right, 2);
        PresetsHeader.Margin = new Thickness(header.Left, 16, header.Right, 2);
        NoPresetsText.Margin = new Thickness(header.Left, 4, header.Right, 0);
    }
}
