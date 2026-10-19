using System.ComponentModel;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Threading;
using CompleteScanner.Core;

namespace CompleteScanner.App;

/// <summary>
/// "Why isn't my scanner listed?": the troubleshooter's checks (<see cref="Troubleshooter.Diagnose"/>),
/// one card each with its status, what it means and the buttons that help (Refresh, Add scanner
/// by address, the Windows Settings pages), and Copy diagnostics. It follows the app: the checks
/// are made again whenever the scanner list or the view model changes. It only reads the
/// system's state; the Settings buttons open Windows Settings, where the user decides.
/// </summary>
public partial class TroubleshooterWindow : Window
{
    /// <summary>How long a Refresh waits for the connections to answer before the checks are made again.</summary>
    internal static readonly TimeSpan RefreshSettleTime = TimeSpan.FromSeconds(3);

    private readonly AppViewModel _viewModel;
    private readonly DispatcherTimer _updateTimer;
    private readonly DispatcherTimer _statusTimer;
    private IReadOnlyList<TroubleshootCheck> _shownChecks = [];
    private int _refreshes;

    /// <summary>The snapshot the cards show (Copy diagnostics copies it).</summary>
    internal DiscoverySnapshot Snapshot { get; private set; } = new();

    /// <summary>
    /// Opens "Add scanner by address" over this window and selects the scanner added; returns
    /// whether one was added (replaced in harnesses).
    /// </summary>
    internal Func<bool> AddScanner { get; set; }

    public TroubleshooterWindow(AppViewModel viewModel)
    {
        InitializeComponent();
        _viewModel = viewModel;
        AddScanner = ShowAddScannerDialog;
        _updateTimer = new DispatcherTimer(DispatcherPriority.Background) { Interval = TimeSpan.FromMilliseconds(400) };
        _updateTimer.Tick += async (_, _) =>
        {
            _updateTimer.Stop();
            await UpdateAsync();
        };
        _statusTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(6) };
        _statusTimer.Tick += (_, _) =>
        {
            _statusTimer.Stop();
            FooterStatus.Text = "";
        };
        _viewModel.PropertyChanged += ViewModel_PropertyChanged;
        _viewModel.Devices.CollectionChanged += Devices_CollectionChanged;
        Closed += (_, _) =>
        {
            _viewModel.PropertyChanged -= ViewModel_PropertyChanged;
            _viewModel.Devices.CollectionChanged -= Devices_CollectionChanged;
            _updateTimer.Stop();
            _statusTimer.Stop();
        };
        // The checks of the moment at once (the service and network as last read), then fresh ones.
        ShowChecks(_viewModel.TroubleshootSnapshot());
        Loaded += async (_, _) =>
        {
            FocusFirstAction();
            await UpdateAsync();
        };
    }

    private void ViewModel_PropertyChanged(object? sender, PropertyChangedEventArgs e) => ScheduleUpdate();

    private void Devices_CollectionChanged(object? sender, System.Collections.Specialized.NotifyCollectionChangedEventArgs e) =>
        ScheduleUpdate();

    /// <summary>Makes the checks again soon; a burst of changes (a scan's progress) makes them once.</summary>
    private void ScheduleUpdate()
    {
        if (!_updateTimer.IsEnabled) _updateTimer.Start();
    }

    /// <summary>Reads the WIA service and the network again, then shows the checks.</summary>
    internal async Task UpdateAsync()
    {
        await _viewModel.ReadSystemStateAsync();
        ShowChecks(_viewModel.TroubleshootSnapshot());
    }

    /// <summary>
    /// Shows the checks for <paramref name="snapshot"/>. The cards are rebuilt only when the
    /// checks changed, and keyboard focus stays on the same button when its card is still there.
    /// </summary>
    internal void ShowChecks(DiscoverySnapshot snapshot)
    {
        Snapshot = snapshot;
        var checks = Troubleshooter.Diagnose(snapshot);
        HeadlineText.Text = Troubleshooter.Headline(snapshot);
        string summary = Troubleshooter.Summary(checks);
        if (SummaryText.Text != summary && _refreshes == 0) Announce(SummaryText, summary);
        if (checks.SequenceEqual(_shownChecks)) return;

        // Where keyboard focus was: the check and the action of the focused button.
        (string Id, TroubleshootAction Action)? focused =
            Keyboard.FocusedElement is Button { Tag: ActionTag tag } && ChecksPanel.IsKeyboardFocusWithin
                ? (tag.CheckId, tag.Action) : null;
        _shownChecks = checks;
        ChecksPanel.Children.Clear();
        foreach (var check in checks) ChecksPanel.Children.Add(Card(check));
        if (focused is { } was)
        {
            var again = ActionButtons().FirstOrDefault(b => ((ActionTag)b.Tag).CheckId == was.Id && ((ActionTag)b.Tag).Action == was.Action);
            if (again is not null) again.Focus();
            else FocusFirstAction();
        }
    }

    /// <summary>A check's button: which check it belongs to and what it does.</summary>
    private sealed record ActionTag(string CheckId, TroubleshootAction Action);

    internal IEnumerable<Button> ActionButtons() =>
        ChecksPanel.Children.OfType<FrameworkElement>()
            .SelectMany(card => FindButtons(card));

    private static IEnumerable<Button> FindButtons(DependencyObject root)
    {
        foreach (var child in LogicalTreeHelper.GetChildren(root).OfType<DependencyObject>())
        {
            if (child is Button button) yield return button;
            foreach (var nested in FindButtons(child)) yield return nested;
        }
    }

    private void FocusFirstAction()
    {
        // The first check's first button, else Refresh: Tab then reaches the rest in reading order.
        if (ActionButtons().FirstOrDefault() is { } first) first.Focus();
        else RefreshButton.Focus();
    }

    /// <summary>
    /// One check as a card: the status glyph (named for screen readers), the title, the detail
    /// and its buttons. Screen readers see the card as a group named with the status and title.
    /// </summary>
    private Border Card(TroubleshootCheck check)
    {
        var (glyph, brush) = check.Status switch
        {
            CheckStatus.Problem => ("", "SystemFillColorCriticalBrush"),
            CheckStatus.Warning => ("", "SystemFillColorCautionBrush"),
            CheckStatus.Ok => ("", "SystemFillColorSuccessBrush"),
            _ => ("", "AccentTextFillColorPrimaryBrush"),
        };
        string status = Troubleshooter.StatusLabel(check.Status);
        var icon = new TextBlock
        {
            Text = glyph,
            Style = (Style)FindResource("GlyphText"),
            VerticalAlignment = VerticalAlignment.Top,
            Margin = new Thickness(0, 2, 12, 0),
        };
        icon.SetResourceReference(TextBlock.ForegroundProperty, brush);
        AutomationProperties.SetName(icon, status);
        DockPanel.SetDock(icon, Dock.Left);

        var title = new TextBlock { Text = check.Title, Style = (Style)FindResource("BodyStrongText"), TextWrapping = TextWrapping.Wrap };
        var detail = new TextBlock
        {
            Text = check.Detail,
            Style = (Style)FindResource("BodyText"),
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 2, 0, 0),
        };
        var texts = new StackPanel();
        texts.Children.Add(title);
        texts.Children.Add(detail);
        if (check.Actions.Count > 0)
        {
            var buttons = new WrapPanel { Margin = new Thickness(0, 8, 0, 0) };
            foreach (var action in check.Actions)
            {
                var button = new Button
                {
                    Content = Troubleshooter.Label(action, TroubleshootPlatform.Windows),
                    Tag = new ActionTag(check.Id, action),
                    Margin = new Thickness(0, 4, 8, 0),
                };
                CompleteScanner.App.Icon.SetGlyph(button, ActionGlyph(action));
                button.Style = (Style)FindResource("IconTextButtonStyle");
                // The button's own name plus which check it is for (several cards offer the same one).
                AutomationProperties.SetHelpText(button, $"{status}: {check.Title}");
                button.Click += Action_Click;
                buttons.Children.Add(button);
            }
            texts.Children.Add(buttons);
        }

        var row = new DockPanel();
        row.Children.Add(icon);
        row.Children.Add(texts);
        var card = new CheckCard
        {
            Style = (Style)FindResource("CardStyle"),
            Padding = new Thickness(16, 12, 16, 12),
            Margin = new Thickness(0, 0, 0, 8),
            Child = row,
        };
        AutomationProperties.SetName(card, $"{status}: {check.Title}");
        AutomationProperties.SetAutomationId(card, check.Id);
        return card;
    }

    private static string ActionGlyph(TroubleshootAction action) => action switch
    {
        TroubleshootAction.Refresh => "",
        TroubleshootAction.AddByAddress => "",
        TroubleshootAction.OpenScannerSettings => "",
        TroubleshootAction.OpenNetworkSettings => "",
        TroubleshootAction.CopyDiagnostics => "",
        _ => "",
    };

    private async void Action_Click(object sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: ActionTag tag }) await RunAsync(tag.Action);
    }

    /// <summary>Carries out an action of a card or the footer.</summary>
    internal async Task RunAsync(TroubleshootAction action)
    {
        switch (action)
        {
            case TroubleshootAction.Refresh:
                await RefreshAsync();
                break;
            case TroubleshootAction.AddByAddress:
                if (AddScanner()) await UpdateAsync();
                break;
            case TroubleshootAction.OpenScannerSettings:
            case TroubleshootAction.OpenNetworkSettings:
                if (!_viewModel.OpenSystemSettings(action)) ShowStatus("Settings did not open.");
                break;
            case TroubleshootAction.CopyDiagnostics:
                Copy();
                break;
        }
    }

    private async void Refresh_Click(object sender, RoutedEventArgs e) => await RefreshAsync();

    private void Copy_Click(object sender, RoutedEventArgs e) => Copy();

    /// <summary>
    /// Looks for scanners again, waits for the connections to answer, then makes the checks again.
    /// A Refresh while one runs is ignored, so the search is not restarted before it can answer.
    /// The buttons stay enabled: disabling the focused one would move keyboard focus away.
    /// </summary>
    internal async Task RefreshAsync()
    {
        if (_refreshes > 0) return;
        _refreshes++;
        Announce(SummaryText, "Looking for scanners…");
        try
        {
            _viewModel.RefreshScanners();
            await Task.Delay(RefreshSettleTime);
        }
        finally
        {
            _refreshes--;
        }
        SummaryText.Text = "";
        await UpdateAsync();
    }

    private void Copy()
    {
        if (_viewModel.CopyDiagnostics(Snapshot)) ShowStatus("Copied to the clipboard.");
        else ShowStatus("Could not copy.");
    }

    /// <summary>What the footer says after Copy or a Settings button (harnesses read it).</summary>
    internal string FooterMessage => FooterStatus.Text;

    private void ShowStatus(string text)
    {
        _statusTimer.Stop();
        Announce(FooterStatus, text);
        _statusTimer.Start();
    }

    /// <summary>Sets the text and tells screen readers it changed.</summary>
    private static void Announce(TextBlock target, string text)
    {
        target.Text = text;
        var peer = UIElementAutomationPeer.FromElement(target) ?? UIElementAutomationPeer.CreatePeerForElement(target);
        peer?.RaiseAutomationEvent(AutomationEvents.LiveRegionChanged);
    }

    private bool ShowAddScannerDialog()
    {
        if (_viewModel.NetworkScanners is not { } network) return false;
        var dialog = new AddScannerWindow(network) { Owner = this };
        if (dialog.ShowDialog() != true || dialog.DeviceId is not { } id) return false;
        _viewModel.SelectAddedDevice(id);
        return true;
    }
}

/// <summary>
/// A troubleshooter card. A plain Border has no automation peer, so its name would never reach
/// screen readers; this one is a named group around the card's texts and buttons.
/// </summary>
internal sealed class CheckCard : Border
{
    protected override AutomationPeer OnCreateAutomationPeer() => new CheckCardAutomationPeer(this);

    private sealed class CheckCardAutomationPeer(CheckCard owner) : FrameworkElementAutomationPeer(owner)
    {
        protected override AutomationControlType GetAutomationControlTypeCore() => AutomationControlType.Group;

        protected override string GetClassNameCore() => nameof(CheckCard);
    }
}
