using System.Collections.Specialized;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using CompleteScanner.Core;

namespace CompleteScanner.App;

/// <summary>
/// The start screen: one tile per task (<see cref="TaskCatalog"/>) in its group (<see cref="TaskCatalog.Sections"/>),
/// greyed out with a short reason when the connected scanner cannot do it, and the user's presets.
/// Picking a tile is reported to the window, which sets it up and opens the scan screen.
/// The twin of UI/TaskStartView.swift.
/// </summary>
public partial class TaskStartView : UserControl
{
    /// <summary>The side insets of the groups' headings (see <see cref="UpdateInsets"/>).</summary>
    public static readonly DependencyProperty HeaderMarginProperty = DependencyProperty.Register(
        nameof(HeaderMargin), typeof(Thickness), typeof(TaskStartView), new PropertyMetadata(new Thickness(16, 16, 16, 2)));

    /// <summary>The side insets of the groups' tiles.</summary>
    public static readonly DependencyProperty GridMarginProperty = DependencyProperty.Register(
        nameof(GridMargin), typeof(Thickness), typeof(TaskStartView), new PropertyMetadata(new Thickness(10, 0, 10, 0)));

    /// <summary>A tile's width (168) and its margin on both sides (6).</summary>
    internal const double TileSlotWidth = 168 + 2 * GridInsets.CardMargin;

    private AppViewModel? _viewModel;
    private List<TaskGroupItem> _groups = [];
    private List<PresetCardItem> _presetCards = [];

    /// <summary>A task tile was picked.</summary>
    public event Action<ScanTask>? TaskChosen;
    /// <summary>A preset tile was picked.</summary>
    public event Action<Preset>? PresetChosen;
    /// <summary>"Go to Scan": open the scan screen without changing anything.</summary>
    public event Action? GoToScanRequested;
    /// <summary>"Add pages to a PDF": the window picks the PDF and starts Document to PDF.</summary>
    public event Action? AddToPdfRequested;

    public TaskStartView()
    {
        InitializeComponent();
    }

    public Thickness HeaderMargin
    {
        get => (Thickness)GetValue(HeaderMarginProperty);
        set => SetValue(HeaderMarginProperty, value);
    }

    public Thickness GridMargin
    {
        get => (Thickness)GetValue(GridMarginProperty);
        set => SetValue(GridMarginProperty, value);
    }

    public void Attach(AppViewModel viewModel)
    {
        _viewModel = viewModel;
        viewModel.Presets.CollectionChanged += Presets_CollectionChanged;
        Refresh();
    }

    private void Presets_CollectionChanged(object? sender, NotifyCollectionChangedEventArgs e) => Refresh();

    /// <summary>
    /// Updates the tiles from the view model. The groups are rebuilt only when a tile changed, so
    /// keyboard focus stays on the tile it was on.
    /// </summary>
    public void Refresh()
    {
        if (_viewModel is not { } vm) return;

        var cards = vm.TaskCards.ToDictionary(c => c.Task);
        var groups = TaskCatalog.Sections
            .Select(g => new TaskGroupItem(g.Group.Title(),
                                           g.Definitions.Where(d => cards.ContainsKey(d.Task)).Select(d => cards[d.Task]).ToList()))
            .ToList();
        if (!groups.Select(g => g.Signature).SequenceEqual(_groups.Select(g => g.Signature)))
        {
            _groups = groups;
            TaskGrid.ItemsSource = _groups;
        }

        var presets = vm.Presets.Select(p => new PresetCardItem(p)).ToList();
        if (!presets.Select(c => c.Signature).SequenceEqual(_presetCards.Select(c => c.Signature)))
        {
            _presetCards = presets;
            PresetGrid.ItemsSource = _presetCards;
        }
        PresetsPanel.Visibility = _presetCards.Count > 0 ? Visibility.Visible : Visibility.Collapsed;

        // Like the presets in the side pane, the tiles replace the settings, which an operation
        // in progress works from a snapshot of: they wait until it ends.
        TaskGrid.IsEnabled = !vm.IsBusy;
        PresetGrid.IsEnabled = !vm.IsBusy;
        AddToPdfTile.IsEnabled = !vm.IsBusy;
    }

    /// <summary>The task tiles on screen, in reading order (group by group).</summary>
    internal List<Button> TaskTiles()
    {
        UpdateLayout();
        var tiles = new List<Button>();
        void Walk(DependencyObject node)
        {
            for (int i = 0; i < VisualTreeHelper.GetChildrenCount(node); i++)
            {
                var child = VisualTreeHelper.GetChild(node, i);
                if (child is Button { Name: "Card", DataContext: TaskCardItem } button) tiles.Add(button);
                else Walk(child);
            }
        }
        Walk(TaskGrid);
        return tiles;
    }

    /// <summary>
    /// Puts keyboard focus on the current task's tile (else the first tile that can be started),
    /// so a returning user can press Enter to carry on.
    /// </summary>
    public void FocusDefaultCard()
    {
        var tiles = TaskTiles();
        var preferred = tiles.FirstOrDefault(b => b.DataContext is TaskCardItem { IsCurrent: true, IsAvailable: true })
                        ?? tiles.FirstOrDefault(b => b.DataContext is TaskCardItem { IsAvailable: true });
        if (preferred is null) return;
        preferred.Focus();
        Keyboard.Focus(preferred);
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

    private void AddToPdfTile_Click(object sender, RoutedEventArgs e) => AddToPdfRequested?.Invoke();

    /// <summary>The scroll viewport changed width (resize, scrollbar shown or hidden): re-centre the tiles.</summary>
    private void Scroller_ScrollChanged(object sender, ScrollChangedEventArgs e)
    {
        if (e.ViewportWidthChange != 0) UpdateInsets();
    }

    /// <summary>
    /// Centre the tiles: split the width left over after the last whole column between both sides,
    /// and line the header and the group headings up with the tiles' outer edges.
    /// </summary>
    private void UpdateInsets()
    {
        var (cards, header) = GridInsets.For(Scroller.ViewportWidth, slotWidth: TileSlotWidth);
        GridMargin = new Thickness(cards.Left, 0, cards.Right, 0);
        PresetGrid.Margin = new Thickness(cards.Left, 0, cards.Right, 0);
        HeaderMargin = new Thickness(header.Left, 16, header.Right, 2);
        Header.Margin = new Thickness(header.Left, 20, header.Right, 4);
        PresetsHeader.Margin = new Thickness(header.Left, 16, header.Right, 2);
    }
}

/// <summary>A group of task tiles on the start screen ("Documents").</summary>
public sealed class TaskGroupItem(string title, IReadOnlyList<TaskCardItem> cards)
{
    public string Title { get; } = title;
    public IReadOnlyList<TaskCardItem> Cards { get; } = cards;

    internal string Signature => Title + "\u001e" + string.Join('\u001e', Cards.Select(c => c.Signature));
}
