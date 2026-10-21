using System.ComponentModel;
using System.Globalization;
using System.IO;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using CompleteScanner.App.Services;
using CompleteScanner.Core;

namespace CompleteScanner.App;

/// <summary>A card in the Saved tab.</summary>
public sealed class SavedFileItem(SavedFile file) : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;

    private SavedFile _file = file;
    /// <summary>Replaced after a rotate, so the card shows the file's new date and size.</summary>
    public SavedFile File
    {
        get => _file;
        set
        {
            _file = value;
            Changed(nameof(File)); Changed(nameof(Name)); Changed(nameof(Caption));
            Changed(nameof(DateText)); Changed(nameof(SizeText)); Changed(nameof(ToolTipText));
        }
    }
    public string Name => File.Name;
    public string Caption => $"{DateText} · {SizeText}";
    public string DateText => File.Modified.ToString("g");
    public string SizeText => SavedFiles.SizeText(File.Size);
    /// <summary>The card's tooltip: the whole name (it may be cut on the card) and the size.</summary>
    public string ToolTipText => $"{Name} · {SizeText}";
    /// <summary>Short file type label shown on the card (PDF, JPG, PNG, TIFF).</summary>
    public string TypeText => Path.GetExtension(File.Path).ToLowerInvariant() switch
    {
        ".jpg" or ".jpeg" => "JPG",
        ".tif" or ".tiff" => "TIFF",
        var other => other.TrimStart('.').ToUpperInvariant(),
    };
    /// <summary>Icon font glyph shown until (or instead of) the thumbnail.</summary>
    public string PlaceholderGlyph => File.IsPdf || File.IsTextDocument ? "" : "";
    public Visibility RotateVisibility => File.ImageFormat is null ? Visibility.Collapsed : Visibility.Visible;

    private BitmapSource? _thumbnail;
    public BitmapSource? Thumbnail
    {
        get => _thumbnail;
        set { _thumbnail = value; Changed(nameof(Thumbnail)); }
    }

    private bool _rotating;
    /// <summary>A rotate is in flight: the button is disabled so a double-click can't queue a second one.</summary>
    public bool IsRotating
    {
        get => _rotating;
        set { _rotating = value; Changed(nameof(IsRotating)); Changed(nameof(CanRotate)); }
    }
    public bool CanRotate => !_rotating;

    // Thumbnail bookkeeping for the virtualized list (UI thread only).

    /// <summary>The card elements currently showing this item; the thumbnail is kept only while there is one.</summary>
    internal HashSet<FrameworkElement> Cards { get; } = [];
    /// <summary>Bumped whenever the thumbnail is dropped or goes stale; loads of an older version are discarded.</summary>
    internal int ThumbnailVersion { get; set; }
    /// <summary>The version a load is in flight for, if any.</summary>
    internal int? LoadingVersion { get; set; }

    private void Changed(string name) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}

/// <summary>One row of cards in the Saved tab (the list virtualizes by row).</summary>
public sealed class SavedFileRow(IReadOnlyList<SavedFileItem> items)
{
    public IReadOnlyList<SavedFileItem> Items { get; } = items;
}

/// <summary>
/// The Saved tab: everything in the destination folder, newest first, with open, open with,
/// show in folder, share, email, copy (<see cref="AppViewModel.RunFileAction"/>) and 90°
/// rotate-in-place for saved image files. Port of UI/SavedFilesView.swift; the file work lives
/// in <see cref="SavedFiles"/>.
/// </summary>
public partial class SavedFilesView : UserControl
{
    /// <summary>Decode width of a card thumbnail (cards show ~180 px; leaves room for HiDPI).</summary>
    private const int ThumbnailDecodeWidth = 360;

    /// <summary>Side insets of every row of cards (see <see cref="GridInsets"/>).</summary>
    public static readonly DependencyProperty RowInsetProperty = DependencyProperty.Register(
        nameof(RowInset), typeof(Thickness), typeof(SavedFilesView),
        new PropertyMetadata(new Thickness(GridInsets.EdgeMargin, 0, GridInsets.EdgeMargin, 0)));

    public Thickness RowInset
    {
        get => (Thickness)GetValue(RowInsetProperty);
        set => SetValue(RowInsetProperty, value);
    }

    private List<SavedFileItem> _items = [];
    private int _columns;
    private AppViewModel? _viewModel;
    private Action<string>? _showError;
    /// <summary>Bumped per reload; a listing that finishes after a newer one started is dropped.</summary>
    private int _generation;
    /// <summary>At most two thumbnails decode at once, so a fast scroll never floods the thread pool.</summary>
    private readonly SemaphoreSlim _thumbnailGate = new(2, 2);
    /// <summary>The item each realized card element is showing.</summary>
    private readonly Dictionary<FrameworkElement, SavedFileItem> _cardItems = [];
    private Task _pendingWork = Task.CompletedTask;

    public SavedFilesView()
    {
        InitializeComponent();
    }

    public void Attach(AppViewModel viewModel, Action<string> showError)
    {
        _viewModel = viewModel;
        _showError = showError;
    }

    /// <summary>Completes when no file write started here (rotate in place) is still running.</summary>
    public Task PendingWork => _pendingWork;

    /// <summary>
    /// Re-read the destination folder off the UI thread. Only the listing is read here;
    /// thumbnails load as their cards scroll into view.
    /// </summary>
    public async void Reload()
    {
        if (_viewModel is null) return;
        int generation = ++_generation;
        string folder = _viewModel.DestinationFolder;
        ShowFolder(folder);
        var files = await Task.Run(() =>
        {
            SavedFiles.SweepStaleTempFiles(folder, SavedFiles.StaleTempFileAge);
            return SavedFiles.List(folder);
        });
        if (generation != _generation) return;

        _items = (files ?? []).Select(file => new SavedFileItem(file)).ToList();
        RebuildRows(force: true);
        bool empty = _items.Count == 0;
        EmptyState.Visibility = empty ? Visibility.Visible : Visibility.Collapsed;
        Rows.Visibility = empty ? Visibility.Collapsed : Visibility.Visible;
        bool unreadable = files is null;
        EmptyGlyph.Text = unreadable ? "\uE7BA" : "\uE8B7";
        EmptyTitle.Text = unreadable ? "The destination folder could not be read." : "Nothing saved yet";
        EmptyBody.Text = unreadable
            ? "Check that the folder exists and that you have permission to open it."
            : "Scans you save to this folder appear here, newest first.";
        EmptyFolder.Text = folder;
        // The header already names the folder; the full path is repeated only when it failed.
        EmptyFolder.Visibility = unreadable ? Visibility.Visible : Visibility.Collapsed;
    }

    // MARK: - Folder header

    private void ShowFolder(string folder)
    {
        string name = Path.GetFileName(folder.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar));
        FolderName.Text = name.Length > 0 ? name : folder;
        FolderName.ToolTip = folder;
        AutomationProperties.SetHelpText(FolderName, folder);
    }

    // MARK: - Rows and thumbnails

    /// <summary>Columns per row; room is always kept for a vertical scrollbar.</summary>
    private int ColumnCount() => GridInsets.Columns(Rows.ActualWidth);

    /// <summary>
    /// Centre the rows in the scroll viewport and line the header up with them, exactly as the
    /// Scans tab does, so switching between the two tabs does not shift the grid.
    /// </summary>
    private void UpdateInsets()
    {
        double width = Rows.Template?.FindName("RowsScroller", Rows) is ScrollViewer { ViewportWidth: > 0 } scroller
            ? scroller.ViewportWidth
            : Rows.ActualWidth;
        var (cards, header) = GridInsets.For(width, ColumnCount());
        RowInset = cards;
        Header.Margin = new Thickness(header.Left, 16, header.Right, 8);
    }

    /// <summary>The viewport changed width (a scrollbar came or went): re-centre.</summary>
    private void Rows_ScrollChanged(object sender, ScrollChangedEventArgs e)
    {
        if (e.ViewportWidthChange != 0) UpdateInsets();
    }

    /// <summary>Cut the items into rows that fit the current width (only when the column count changes, unless forced).</summary>
    private void RebuildRows(bool force)
    {
        int columns = ColumnCount();
        if (!force && columns == _columns) return;
        _columns = columns;
        var rows = new List<SavedFileRow>();
        for (int i = 0; i < _items.Count; i += columns)
        {
            rows.Add(new SavedFileRow(_items.GetRange(i, Math.Min(columns, _items.Count - i))));
        }
        Rows.ItemsSource = rows;
    }

    private void Rows_SizeChanged(object sender, SizeChangedEventArgs e)
    {
        if (!e.WidthChanged) return;
        RebuildRows(force: false);
        UpdateInsets();
    }

    private void Card_Loaded(object sender, RoutedEventArgs e)
    {
        if (sender is not FrameworkElement card) return;
        // When the list discards a row it clears the row's data context before (or instead
        // of) unloading its cards, so the card is tracked by element, not by DataContext.
        card.DataContextChanged -= Card_DataContextChanged;
        card.DataContextChanged += Card_DataContextChanged;
        AttachCard(card);
    }

    private void Card_Unloaded(object sender, RoutedEventArgs e)
    {
        if (sender is not FrameworkElement card) return;
        card.DataContextChanged -= Card_DataContextChanged;
        DetachCard(card);
    }

    private void Card_DataContextChanged(object sender, DependencyPropertyChangedEventArgs e)
    {
        if (sender is not FrameworkElement card) return;
        DetachCard(card);
        if (card.IsLoaded) AttachCard(card);
    }

    private void AttachCard(FrameworkElement card)
    {
        DetachCard(card);
        if (card.DataContext is not SavedFileItem item) return;
        _cardItems[card] = item;
        item.Cards.Add(card);
        LoadThumbnail(item, replace: false);
    }

    private void DetachCard(FrameworkElement card)
    {
        if (!_cardItems.Remove(card, out var item)) return;
        item.Cards.Remove(card);
        if (item.Cards.Count > 0) return;
        // Scrolled out of view (or the list was rebuilt): drop the decoded pixels.
        item.ThumbnailVersion++;
        item.Thumbnail = null;
    }

    /// <summary>
    /// Decode the item's thumbnail if a card is showing it. With <paramref name="replace"/>
    /// the current thumbnail stays up until the new one is ready (used after a rotate).
    /// </summary>
    private async void LoadThumbnail(SavedFileItem item, bool replace)
    {
        if (replace) item.ThumbnailVersion++;
        else if (item.Thumbnail is not null || item.LoadingVersion == item.ThumbnailVersion) return;
        int version = item.ThumbnailVersion;
        item.LoadingVersion = version;
        await _thumbnailGate.WaitAsync();
        try
        {
            // Scrolled past or superseded while waiting: skip the decode entirely.
            if (version != item.ThumbnailVersion || item.Cards.Count == 0) return;
            var thumbnail = await SavedFiles.LoadThumbnailAsync(item.File, ThumbnailDecodeWidth);
            if (version == item.ThumbnailVersion && item.Cards.Count > 0) item.Thumbnail = thumbnail;
        }
        finally
        {
            _thumbnailGate.Release();
            if (item.LoadingVersion == version) item.LoadingVersion = null;
        }
    }

    private static SavedFileItem? ItemOf(object sender) =>
        (sender as FrameworkElement)?.DataContext as SavedFileItem;

    private void Refresh_Click(object sender, RoutedEventArgs e) => Reload();

    private void RevealFolder_Click(object sender, RoutedEventArgs e)
    {
        if (_viewModel is null) return;
        string folder = _viewModel.DestinationFolder;
        try
        {
            Directory.CreateDirectory(folder);
            SavedFiles.Reveal(folder);
        }
        catch (Exception ex)
        {
            _showError?.Invoke($"Could not open {folder}: {ex.Message}");
        }
    }

    private void Thumbnail_MouseDown(object sender, MouseButtonEventArgs e)
    {
        if (e.ClickCount == 2 && ItemOf(sender) is { } item) Open(item);
    }

    private void Open_Click(object sender, RoutedEventArgs e)
    {
        if (ItemOf(sender) is { } item) Open(item);
    }

    private void Open(SavedFileItem item) => Run(FileAction.Open, item);

    private void Reveal_Click(object sender, RoutedEventArgs e)
    {
        if (ItemOf(sender) is { } item) Run(FileAction.Reveal, item);
    }

    private void Share_Click(object sender, RoutedEventArgs e)
    {
        if (ItemOf(sender) is { } item) Run(FileAction.Share, item);
    }

    /// <summary>The card's More button: every action on the file, under the button.</summary>
    private void More_Click(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement button && ItemOf(sender) is { } item)
        {
            FileActionMenu.ShowBelow(BuildFileMenu(item), button);
        }
    }

    /// <summary>The card's context menu (right-click, Shift+F10, Menu key): the same as More.</summary>
    private void Card_ContextMenuOpening(object sender, ContextMenuEventArgs e)
    {
        if (sender is FrameworkElement card && card.DataContext is SavedFileItem item)
        {
            card.ContextMenu = BuildFileMenu(item);
        }
        else
        {
            e.Handled = true;
        }
    }

    /// <summary>Every action on one saved file, then Rotate for image files or Add the scanned pages for a PDF.</summary>
    internal ContextMenu BuildFileMenu(SavedFileItem item)
    {
        List<MenuItem> extra = [];
        if (item.File.ImageFormat is not null)
        {
            var rotate = FileActionMenu.Item("Rotate 90° clockwise", "\uE7AD", "Rotate the saved file 90° clockwise",
                                             () => RotateItem(item));
            rotate.IsEnabled = item.CanRotate;
            extra.Add(rotate);
        }
        // A PDF takes the pages waiting in the queue at its end (offered while there are pages to
        // save and nothing else runs).
        if (item.File.IsPdf && _viewModel is { } viewModel)
        {
            var add = FileActionMenu.Item(PdfAppender.SavedMenuLabel, "\uE8E5", PdfAppender.SavedMenuHint,
                                          () => _ = viewModel.AppendToPdf(item.File.Path));
            add.IsEnabled = viewModel.CanAppendPages;
            extra.Add(add);
        }
        return FileActionMenu.Build(SaveActions.Offered(1), 1, action => Run(action, item), extra);
    }

    /// <summary>Carries out an action on the card's file; problems are reported in the InfoBar.</summary>
    private void Run(FileAction action, SavedFileItem item) => _viewModel?.RunFileAction(action, [item.File.Path]);

    private void Rotate_Click(object sender, RoutedEventArgs e)
    {
        if (ItemOf(sender) is { } item) RotateItem(item);
    }

    private async void RotateItem(SavedFileItem item)
    {
        if (item.IsRotating) return;
        item.IsRotating = true;
        var rotation = SavedFiles.RotateClockwiseAsync(item.File.Path);
        _pendingWork = Task.WhenAll(_pendingWork, rotation);
        string? failure = await rotation;
        item.IsRotating = false;
        if (failure is not null)
        {
            _showError?.Invoke($"Could not rotate {item.Name}: {failure}");
            return;
        }
        // Refresh just this card (new date, size and thumbnail) instead of the whole folder.
        if (SavedFiles.Describe(item.File.Path) is { } updated) item.File = updated;
        LoadThumbnail(item, replace: true);
    }
}
