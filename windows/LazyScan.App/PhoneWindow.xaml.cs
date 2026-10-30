using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using LazyScan.App.Services;
using LazyScan.App.Services.Companion;
using LazyScan.Core;
using Microsoft.Win32;

namespace LazyScan.App;

/// <summary>
/// "Send from your phone": whether this PC receives from phones and on which networks (with
/// "Allow receiving on this network" for a network Windows treats as public), pairing a phone by
/// QR code (asking the user to allow the phone that presents it), the paired phones with Remove,
/// the cloud folder phones put documents in when they cannot reach this PC (C2), and the connection
/// checks (<see cref="CompanionTroubleshooter"/>). It reads the firewall's
/// rules but never changes them, nor any network setting.
/// </summary>
public partial class PhoneWindow : Window
{
    private readonly AppViewModel _viewModel;
    private readonly CompanionService? _companion;
    private readonly IQrEncoder _qrEncoder;
    private readonly DispatcherTimer _clock;
    private FirewallState _firewall = FirewallState.Unknown;
    private PairingUri? _code;
    private TaskCompletionSource<bool>? _approval;
    private string? _justPaired;
    private bool _closing;
    /// <summary>The network states the cards show now; null when none are shown.</summary>
    private IReadOnlyList<CompanionNetworkState>? _shownNetworks;
    /// <summary>The paired phones' Remove buttons, in the order shown.</summary>
    private readonly List<Button> _removeButtons = [];

    /// <summary>Reads the firewall's state for the app (replaced in harnesses).</summary>
    internal Func<string, FirewallState> ReadFirewall { get; set; } = FirewallReader.Read;

    /// <summary>The app's program file, whose firewall rules count.</summary>
    internal string ApplicationPath { get; set; } = Environment.ProcessPath ?? "";

    public PhoneWindow(AppViewModel viewModel, IQrEncoder? qrEncoder = null)
    {
        InitializeComponent();
        _viewModel = viewModel;
        _qrEncoder = qrEncoder ?? new ZXingQrEncoder();
        _companion = viewModel.EnsureCompanion();
        _clock = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
        _clock.Tick += (_, _) => ShowExpiry();
        _viewModel.CompanionChanged += Refresh;
        _viewModel.ConfirmPhonePairing = AskToAllowAsync;
        if (_companion is not null) _companion.DevicePaired += Companion_DevicePaired;
        Closing += async (_, e) =>
        {
            if (_closing || _companion?.Pairing is null) return;
            // The pairing code stops working when the window closes.
            e.Cancel = true;
            _closing = true;
            await _companion.ClosePairingAsync();
            // Closed again once this Closing has finished (it may not close from inside it).
            _ = Dispatcher.BeginInvoke(new Action(Close));
        };
        Closed += (_, _) =>
        {
            _clock.Stop();
            _viewModel.CompanionChanged -= Refresh;
            if (_viewModel.ConfirmPhonePairing == AskToAllowAsync) _viewModel.ConfirmPhonePairing = null;
            if (_companion is not null) _companion.DevicePaired -= Companion_DevicePaired;
            _approval?.TrySetResult(false);
        };
        Refresh();
        Loaded += async (_, _) =>
        {
            PairButton.Focus();
            await RefreshFirewallAsync();
        };
    }

    /// <summary>The pairing code shown now (harnesses); null when none is.</summary>
    internal PairingUri? ShownCode => PairingPanel.Visibility == Visibility.Visible ? _code : null;

    /// <summary>The checks shown now (harnesses).</summary>
    internal IReadOnlyList<TroubleshootCheck> ShownChecks { get; private set; } = [];

    /// <summary>The headline shown now (harnesses).</summary>
    internal string Headline => HeadlineText.Text;

    /// <summary>Reads the firewall again (off the UI thread), then shows everything again.</summary>
    internal async Task RefreshFirewallAsync()
    {
        string path = ApplicationPath;
        var read = ReadFirewall;
        _firewall = await Task.Run(() => read(path));
        Refresh();
    }

    /// <summary>Shows the link's state: the networks, the pairing, the phones and the checks.</summary>
    internal void Refresh()
    {
        if (_companion is null)
        {
            HeadlineText.Text = _viewModel.CompanionElsewhere
                ? "Another Lazy Scan window receives from phones. Pair and manage phones there."
                : $"The phone link could not start: {_viewModel.CompanionError}";
            PairButton.IsEnabled = false;
            ResetButton.IsEnabled = false;
            NetworksPanel.Children.Clear();
            _shownNetworks = null;
            PhonesPanel.Children.Clear();
            _removeButtons.Clear();
            ShowSyncFolder();
            ShowChecks(new CompanionSnapshot
            {
                Listen = _viewModel.CompanionElsewhere ? CompanionListenState.Elsewhere : CompanionListenState.Failed,
                ListenError = _viewModel.CompanionError,
            });
            return;
        }
        var snapshot = _companion.Snapshot();
        // The firewall's rules for the profiles of the networks received on, not of every adapter.
        var profiles = CompanionFirewall.ProfilesFor(snapshot.Networks);
        snapshot = snapshot with
        {
            Firewall = _firewall.Verdict(ApplicationPath, snapshot.Port, profiles),
            BlockingRules = _firewall.BlockingRules(ApplicationPath, profiles),
        };
        HeadlineText.Text = CompanionTroubleshooter.Headline(snapshot);
        ShowNetworks(snapshot);
        ShowPairing();
        ShowPhones();
        ShowSyncFolder();
        ShowChecks(snapshot);
    }

    // MARK: - Networks

    /// <summary>The network cards, made again only when a network or its trust changed; the focused toggle keeps the focus.</summary>
    private void ShowNetworks(CompanionSnapshot snapshot)
    {
        if (_shownNetworks is not null && _shownNetworks.SequenceEqual(snapshot.Networks)) return;
        _shownNetworks = snapshot.Networks;
        string? focused = NetworksPanel.IsKeyboardFocusWithin
                          && System.Windows.Input.Keyboard.FocusedElement is CheckBox { Tag: CompanionNetwork network } ? network.Id : null;
        NetworksPanel.Children.Clear();
        if (snapshot.Networks.Count == 0)
        {
            NetworksPanel.Children.Add(new TextBlock
            {
                Text = "Not connected to a network.",
                Style = (Style)FindResource("SecondaryBodyText"),
                TextWrapping = TextWrapping.Wrap,
            });
            return;
        }
        foreach (var state in snapshot.Networks) NetworksPanel.Children.Add(NetworkCard(state));
        if (focused is not null && NetworkToggle(focused) is { } again) again.Focus();
    }

    /// <summary>The "Allow receiving" toggle of the network with <paramref name="id"/>; null when it is not shown.</summary>
    internal CheckBox? NetworkToggle(string id) =>
        NetworksPanel.Children.OfType<Border>()
                     .Select(card => card.Child is StackPanel texts ? texts.Children.OfType<CheckBox>().FirstOrDefault() : null)
                     .FirstOrDefault(box => box is { Tag: CompanionNetwork network } && network.Id == id);

    private Border NetworkCard(CompanionNetworkState state)
    {
        var network = state.Network;
        string name = network.Name.Length > 0 ? network.Name : "Unnamed network";
        bool isPrivate = network.Category == CompanionNetworkCategory.Private;
        string kind = network.Category switch
        {
            CompanionNetworkCategory.Private => "Private network",
            CompanionNetworkCategory.Domain => "Work network",
            _ => "Public network",
        };
        string receiving = state.Trust == NetworkTrust.NotTrusted ? "not receiving" : "receiving allowed";
        var texts = new StackPanel();
        texts.Children.Add(new TextBlock { Text = name, Style = (Style)FindResource("BodyStrongText"), TextWrapping = TextWrapping.Wrap });
        texts.Children.Add(new TextBlock
        {
            Text = $"{kind} · {receiving}",
            Style = (Style)FindResource("CaptionText"),
            TextWrapping = TextWrapping.Wrap,
        });
        var allow = new CheckBox
        {
            Content = "Allow receiving on this network",
            IsChecked = state.Trust != NetworkTrust.NotTrusted,
            IsEnabled = !isPrivate,
            Margin = new Thickness(0, 8, 0, 0),
            Tag = network,
            ToolTip = isPrivate
                ? "Windows treats this network as private, so paired phones can always send here."
                : "For a network you trust that Windows treats as public, such as your school's Wi-Fi. Only phones you paired can send.",
        };
        allow.Style = (Style)FindResource("ToggleSwitchStyle");
        AutomationProperties.SetName(allow, $"Allow receiving on {name}");
        allow.Click += Allow_Toggled;
        texts.Children.Add(allow);
        if (state.Trust == NetworkTrust.Approved && !isPrivate)
        {
            texts.Children.Add(new TextBlock
            {
                Text = "The first time a phone connects here, Windows Firewall may ask about Lazy Scan: tick Public networks, then choose Allow.",
                Style = (Style)FindResource("CaptionText"),
                TextWrapping = TextWrapping.Wrap,
                Margin = new Thickness(0, 4, 0, 0),
            });
        }
        var card = new CheckCard
        {
            Style = (Style)FindResource("CardStyle"),
            Padding = new Thickness(16, 12, 16, 12),
            Margin = new Thickness(0, 0, 0, 8),
            Child = texts,
        };
        AutomationProperties.SetName(card, $"{name}, {kind}, {receiving}");
        return card;
    }

    private async void Allow_Toggled(object sender, RoutedEventArgs e)
    {
        if (_companion is null || sender is not CheckBox { Tag: CompanionNetwork network } box) return;
        await SetNetworkAllowedAsync(network, box.IsChecked == true);
    }

    /// <summary>Approves <paramref name="network"/> for receiving, or withdraws that (the toggle; harnesses).</summary>
    internal async Task SetNetworkAllowedAsync(CompanionNetwork network, bool allowed)
    {
        if (_companion is null) return;
        bool saved = await _companion.SetNetworkApprovedAsync(network, allowed);
        if (!saved) ShowStatus("The setting could not be saved.");
        await RefreshFirewallAsync();
        // The cards are not made again when the trust did not change (a setting that could not be
        // saved), so the toggle is set back to what holds.
        if (NetworkToggle(network.Id) is { } box && _shownNetworks?.FirstOrDefault(s => s.Network.Id == network.Id) is { } state)
        {
            box.IsChecked = state.Trust != NetworkTrust.NotTrusted;
        }
    }

    // MARK: - Pairing

    private async void Pair_Click(object sender, RoutedEventArgs e) => await PairAsync();

    /// <summary>Shows a new pairing code (Pair a phone; harnesses), or says why none can be shown.</summary>
    internal async Task PairAsync()
    {
        if (_companion is null) return;
        _justPaired = null;
        PairButton.IsEnabled = false;
        try
        {
            _code = await _companion.OpenPairingAsync();
        }
        finally
        {
            PairButton.IsEnabled = true;
        }
        if (_code is null)
        {
            PairNote.Text = WhyNoCode();
            PairNote.Visibility = Visibility.Visible;
            Announce(PairNote);
        }
        else
        {
            string pairingText = _code.Format();
            QrImage.Source = QrBitmap(pairingText);
            PairingTextBox.Text = pairingText;
            var fingerprint = _code.FingerprintBytes;
            CheckCodeBox.Text = fingerprint is null ? "" : SpkiFingerprint.FormatCheckCode(SpkiFingerprint.CheckCode(fingerprint));
            PairNote.Visibility = Visibility.Collapsed;
            _clock.Start();
        }
        await RefreshFirewallAsync();
    }

    private string WhyNoCode()
    {
        var status = _companion!.Status;
        return status.State switch
        {
            CompanionListenState.Offline => "Connect this PC to a network first, then choose Pair a phone again.",
            CompanionListenState.NoTrustedNetwork =>
                "This PC does not receive on the network it is on. Set the network to Private in Windows network settings, "
                + "or turn on Allow receiving on this network above, then choose Pair a phone again.",
            CompanionListenState.Failed => status.Error ?? "Receiving from phones could not start.",
            _ => "No pairing code could be made.",
        };
    }

    private async void StopPairing_Click(object sender, RoutedEventArgs e)
    {
        if (_companion is null) return;
        _approval?.TrySetResult(false);
        await _companion.ClosePairingAsync();
        _code = null;
        Refresh();
    }

    private void CopyPairingText_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            Clipboard.SetText(PairingTextBox.Text);
            ShowStatus("Copied to the clipboard.");
        }
        catch (COMException error)
        {
            ShowStatus($"Copy did not work: {FileActionErrors.Describe(error)}");
        }
    }

    /// <summary>A phone presented the code and the user has not answered yet.</summary>
    private bool QuestionPending => _approval is { Task.IsCompleted: false };

    private void ShowPairing()
    {
        // The code stays up while its question waits: the session is used by then, but not settled.
        bool open = _code is not null && (_companion?.Pairing is not null || QuestionPending);
        PairingPanel.Visibility = open ? Visibility.Visible : Visibility.Collapsed;
        PairButton.Content = open ? "Show a new code" : "Pair a phone";
        if (!QuestionPending) ApprovalCard.Visibility = Visibility.Collapsed;
        if (!open)
        {
            _clock.Stop();
            if (_justPaired is { } name)
            {
                PairNote.Text = $"Paired with {name}. Documents sent from it are added to the queue.";
                PairNote.Visibility = Visibility.Visible;
            }
        }
        ShowExpiry();
    }

    private void ShowExpiry()
    {
        if (_companion?.Pairing is { } session)
        {
            var left = session.Remaining(DateTimeOffset.UtcNow);
            ExpiryText.Text = $"Scan this code with your phone. It works for {(int)left.TotalMinutes}:{left.Seconds:D2} more.";
        }
        else if (QuestionPending)
        {
            ExpiryText.Text = "A phone scanned this code. Allow it below, or not.";
        }
        else if (PairingPanel.Visibility == Visibility.Visible)
        {
            Refresh();
        }
    }

    private void Companion_DevicePaired(object? sender, PairedDevice device) =>
        Dispatcher.BeginInvoke(() =>
        {
            _justPaired = device.Name;
            Refresh();
        });

    /// <summary>A phone presented the code: the user is asked here whether it may pair.</summary>
    private Task<bool> AskToAllowAsync(PairRequest request, CancellationToken cancellation)
    {
        _approval?.TrySetResult(false);
        var approval = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        _approval = approval;
        ApprovalText.Text = $"Allow \"{request.PhoneName}\" to send documents to this PC?";
        ApprovalCard.Visibility = Visibility.Visible;
        Announce(ApprovalText);
        if (IsVisible)
        {
            Activate();
            DenyButton.Focus();
        }
        cancellation.Register(() => approval.TrySetResult(false));
        approval.Task.ContinueWith(_ => Dispatcher.BeginInvoke(() =>
        {
            if (_approval != approval) return;
            bool focused = ApprovalCard.IsKeyboardFocusWithin;
            ApprovalCard.Visibility = Visibility.Collapsed;
            Refresh();
            if (focused && IsVisible) PairButton.Focus();
        }), TaskScheduler.Default);
        ShowPairing();
        return approval.Task;
    }

    private void Allow_Click(object sender, RoutedEventArgs e) => Answer(true);

    private void Deny_Click(object sender, RoutedEventArgs e) => Answer(false);

    /// <summary>The user's answer to the open question (the buttons; harnesses).</summary>
    internal void Answer(bool allow)
    {
        bool focused = ApprovalCard.IsKeyboardFocusWithin;
        _approval?.TrySetResult(allow);
        ApprovalCard.Visibility = Visibility.Collapsed;
        if (focused) PairButton.Focus();
    }

    /// <summary>The question shown now (harnesses); null when none is.</summary>
    internal string? Question => ApprovalCard.Visibility == Visibility.Visible ? ApprovalText.Text : null;

    /// <summary>The QR code with a quiet zone of four modules, black on white, at whole pixels per module.</summary>
    private BitmapSource? QrBitmap(string text)
    {
        if (_qrEncoder.Encode(text) is not { } modules) return null;
        const int quiet = 4;
        int span = modules.Size + 2 * quiet;
        int scale = Math.Max(3, 232 / span);
        int side = span * scale;
        var pixels = new byte[side * side];
        Array.Fill(pixels, (byte)255);
        for (int y = 0; y < modules.Size; y++)
        {
            for (int x = 0; x < modules.Size; x++)
            {
                if (!modules[x, y]) continue;
                for (int dy = 0; dy < scale; dy++)
                {
                    int row = ((y + quiet) * scale + dy) * side + (x + quiet) * scale;
                    Array.Fill(pixels, (byte)0, row, scale);
                }
            }
        }
        var bitmap = BitmapSource.Create(side, side, 96, 96, PixelFormats.Gray8, null, pixels, side);
        bitmap.Freeze();
        return bitmap;
    }

    // MARK: - Paired phones

    private void ShowPhones()
    {
        string? focused = PhonesPanel.IsKeyboardFocusWithin
                          && System.Windows.Input.Keyboard.FocusedElement is Button { Tag: string focusedId } ? focusedId : null;
        PhonesPanel.Children.Clear();
        _removeButtons.Clear();
        var devices = _companion?.Devices.Devices ?? [];
        ResetButton.IsEnabled = _companion is not null;
        if (devices.Count == 0)
        {
            PhonesPanel.Children.Add(new TextBlock
            {
                Text = "No phone is paired yet.",
                Style = (Style)FindResource("SecondaryBodyText"),
                TextWrapping = TextWrapping.Wrap,
            });
            return;
        }
        foreach (var device in devices)
        {
            var remove = new Button
            {
                Content = "Remove",
                Tag = device.Id,
                VerticalAlignment = VerticalAlignment.Center,
                Style = (Style)FindResource("SubtleButtonStyle"),
                ToolTip = "This phone can no longer send documents here, until it is paired again",
            };
            LazyScan.App.Icon.SetGlyph(remove, "");
            AutomationProperties.SetName(remove, $"Remove {device.Name}");
            remove.Click += Remove_Click;
            DockPanel.SetDock(remove, Dock.Right);
            var texts = new StackPanel();
            texts.Children.Add(new TextBlock { Text = device.Name.Length > 0 ? device.Name : "Phone", Style = (Style)FindResource("BodyStrongText") });
            texts.Children.Add(new TextBlock { Text = PhoneCaption(device), Style = (Style)FindResource("CaptionText"), TextWrapping = TextWrapping.Wrap });
            if (_companion?.Devices.HasSyncKey(device.Id) == false)
            {
                texts.Children.Add(new TextBlock { Text = "Pair again to use the cloud folder", Style = (Style)FindResource("CaptionText"), TextWrapping = TextWrapping.Wrap });
            }
            var row = new DockPanel();
            row.Children.Add(remove);
            row.Children.Add(texts);
            var card = new CheckCard
            {
                Style = (Style)FindResource("CardStyle"),
                Padding = new Thickness(16, 10, 8, 10),
                Margin = new Thickness(0, 0, 0, 8),
                Child = row,
            };
            AutomationProperties.SetName(card, device.Name);
            PhonesPanel.Children.Add(card);
            _removeButtons.Add(remove);
        }
        if (focused is not null && _removeButtons.FirstOrDefault(b => (string)b.Tag == focused) is { } again) again.Focus();
    }

    /// <summary>"Paired 20/10/2026 · last seen today at 14:05".</summary>
    internal static string PhoneCaption(PairedDevice device)
    {
        var parts = new List<string>();
        if (device.Paired is { } paired) parts.Add($"Paired {paired.LocalDateTime.ToString("d", CultureInfo.CurrentCulture)}");
        if (device.LastSeen is { } seen)
        {
            var local = seen.LocalDateTime;
            parts.Add(local.Date == DateTime.Today
                ? $"last seen today at {local.ToString("t", CultureInfo.CurrentCulture)}"
                : $"last seen {local.ToString("d", CultureInfo.CurrentCulture)}");
        }
        return string.Join(" · ", parts);
    }

    private async void Remove_Click(object sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: string id }) await RemovePhoneAsync(id);
    }

    /// <summary>Unpairs a phone (its Remove button; harnesses); the focus moves to the next phone's Remove, or to Pair a phone.</summary>
    internal async Task RemovePhoneAsync(string id)
    {
        if (_companion is null) return;
        int index = _removeButtons.FindIndex(b => (string)b.Tag == id);
        try
        {
            await _companion.RemoveDeviceAsync(id);
            ShowStatus("Removed. That phone can no longer send documents here.");
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            ShowStatus($"The phone could not be removed: {error.Message}");
        }
        Refresh();
        if (index < 0) return;
        if (_removeButtons.Count > 0) _removeButtons[Math.Min(index, _removeButtons.Count - 1)].Focus();
        else PairButton.Focus();
    }

    private async void Reset_Click(object sender, RoutedEventArgs e)
    {
        if (_companion is null) return;
        var answer = MessageBox.Show(this,
            "Every paired phone will be removed and this PC gets a new security key. Phones then pair again with a new code.",
            "Reset pairing?", MessageBoxButton.OKCancel, MessageBoxImage.Warning, MessageBoxResult.Cancel);
        if (answer != MessageBoxResult.OK) return;
        await ResetPairingAsync();
    }

    /// <summary>Resets pairing once the user confirmed (Reset pairing; harnesses); a failure is shown, never thrown.</summary>
    internal async Task ResetPairingAsync()
    {
        if (_companion is null) return;
        try
        {
            await _companion.ResetPairingAsync();
            _code = null;
            ShowStatus("Pairing was reset.");
        }
        catch (Exception error) when (error is CryptographicException or IOException or UnauthorizedAccessException
                                          or InvalidOperationException or PlatformNotSupportedException)
        {
            ShowStatus($"Pairing could not be reset: {error.Message}");
        }
        Refresh();
    }

    // MARK: - Cloud folder

    private void ShowSyncFolder()
    {
        string? folder = _companion?.SyncFolder;
        SyncFolderBox.Text = folder ?? "";
        ChooseSyncFolderButton.IsEnabled = _companion is not null;
        ClearSyncFolderButton.IsEnabled = folder is not null;
        SyncFolderStatus.Text = _companion is null ? "Not watching."
            : folder is null ? "Not watching: no folder chosen."
            : Directory.Exists(folder) ? $"Watching {folder}."
            : $"Waiting for {folder}: the folder is not there now.";
        string? problem = _companion is null ? null : _viewModel.SyncFolderProblem;
        SyncFolderProblemText.Text = problem ?? "";
        SyncFolderProblemText.Visibility = problem is null ? Visibility.Collapsed : Visibility.Visible;
    }

    private void ChooseSyncFolder_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFolderDialog { Title = "Choose the cloud folder" };
        if (_companion?.SyncFolder is { } folder) dialog.InitialDirectory = folder;
        if (dialog.ShowDialog(this) == true) SetSyncFolder(dialog.FolderName);
    }

    private void ClearSyncFolder_Click(object sender, RoutedEventArgs e)
    {
        SetSyncFolder(null);
        ChooseSyncFolderButton.Focus();
    }

    /// <summary>Chooses the cloud folder (null: none; Choose… and Clear; harnesses).</summary>
    internal void SetSyncFolder(string? path)
    {
        if (!_viewModel.SetPhoneSyncFolder(path)) ShowStatus("The setting could not be saved.");
        Refresh();
    }

    // MARK: - Checks

    private void ShowChecks(CompanionSnapshot snapshot)
    {
        var checks = CompanionTroubleshooter.Diagnose(snapshot);
        SummaryText.Text = CompanionTroubleshooter.Summary(checks);
        if (checks.SequenceEqual(ShownChecks)) return;
        ShownChecks = checks;
        ChecksPanel.Children.Clear();
        foreach (var check in checks) ChecksPanel.Children.Add(CheckCardFor(check));
    }

    private Border CheckCardFor(TroubleshootCheck check)
    {
        var (glyph, brush) = check.Status switch
        {
            CheckStatus.Problem => ("", "SystemFillColorCriticalBrush"),
            CheckStatus.Warning => ("", "SystemFillColorCautionBrush"),
            CheckStatus.Ok => ("", "SystemFillColorSuccessBrush"),
            _ => ("", "AccentTextFillColorPrimaryBrush"),
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
        var texts = new StackPanel();
        texts.Children.Add(new TextBlock { Text = check.Title, Style = (Style)FindResource("BodyStrongText"), TextWrapping = TextWrapping.Wrap });
        texts.Children.Add(new TextBlock
        {
            Text = check.Detail,
            Style = (Style)FindResource("BodyText"),
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 2, 0, 0),
        });
        if (check.Actions.Count > 0)
        {
            var buttons = new WrapPanel { Margin = new Thickness(0, 8, 0, 0) };
            foreach (var action in check.Actions)
            {
                var button = new Button
                {
                    Content = Troubleshooter.Label(action, TroubleshootPlatform.Windows),
                    Tag = action,
                    Margin = new Thickness(0, 4, 8, 0),
                    Style = (Style)FindResource("IconTextButtonStyle"),
                };
                LazyScan.App.Icon.SetGlyph(button, action == TroubleshootAction.Refresh ? "" : "");
                AutomationProperties.SetHelpText(button, $"{status}: {check.Title}");
                button.Click += CheckAction_Click;
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

    private async void CheckAction_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: TroubleshootAction action }) return;
        switch (action)
        {
            case TroubleshootAction.OpenNetworkSettings:
                if (!_viewModel.OpenSystemSettings(action)) ShowStatus("Settings did not open.");
                break;
            default:
                if (_companion is not null) await _companion.RefreshAsync();
                await RefreshFirewallAsync();
                break;
        }
    }

    // MARK: - Status

    private DispatcherTimer? _statusTimer;

    private void ShowStatus(string text)
    {
        FooterStatus.Text = text;
        Announce(FooterStatus);
        _statusTimer ??= new DispatcherTimer { Interval = TimeSpan.FromSeconds(6) };
        _statusTimer.Stop();
        _statusTimer.Tick -= ClearStatus;
        _statusTimer.Tick += ClearStatus;
        _statusTimer.Start();
    }

    private void ClearStatus(object? sender, EventArgs e)
    {
        _statusTimer?.Stop();
        FooterStatus.Text = "";
    }

    /// <summary>What the footer says (harnesses).</summary>
    internal string FooterMessage => FooterStatus.Text;

    private static void Announce(TextBlock target)
    {
        var peer = UIElementAutomationPeer.FromElement(target) ?? UIElementAutomationPeer.CreatePeerForElement(target);
        peer?.RaiseAutomationEvent(AutomationEvents.LiveRegionChanged);
    }
}
