using System.Windows;
using System.Windows.Automation.Peers;
using System.Windows.Controls;
using CompleteScanner.App.Scanning;
using CompleteScanner.Core;

namespace CompleteScanner.App;

/// <summary>
/// "Add scanner by address": checks that an eSCL scanner answers at the typed address (asking
/// first when it presents a certificate to trust), then adds it to escl-hosts.json. On success
/// <see cref="DeviceId"/> is the id the scanner is listed under.
/// </summary>
public partial class AddScannerWindow : Window
{
    private readonly EsclScannerBackend _backend;
    private CancellationTokenSource? _check;

    /// <summary>The added scanner's device id; null until one was added.</summary>
    public string? DeviceId { get; private set; }

    /// <summary>Asks the user to trust a scanner's certificate (replaced in harnesses).</summary>
    internal Func<EsclCertificateException, bool> ConfirmCertificate { get; set; }

    public AddScannerWindow(EsclScannerBackend backend)
    {
        InitializeComponent();
        Placeholders.Attach(AddressBox, AddressPlaceholder);
        _backend = backend;
        ConfirmCertificate = certificate =>
            new CertificateTrustWindow(certificate, CertificateTrustWindow.AddAction) { Owner = this }.ShowDialog() == true;
        Loaded += (_, _) => AddressBox.Focus();
        // Closing (Cancel, Esc, the close box) abandons a check in progress.
        Closed += (_, _) => _check?.Cancel();
    }

    private async void Add_Click(object sender, RoutedEventArgs e) => await AddAsync();

    /// <summary>Checks the address and adds the scanner; the dialog closes once it is added.</summary>
    internal async Task AddAsync()
    {
        if (_check is not null) return;
        if (!ScannerAddress.TryParse(AddressBox.Text, out var parsed, out string error))
        {
            ShowProblem(error);
            AddressBox.Focus();
            AddressBox.SelectAll();
            return;
        }
        var address = parsed!;
        using var cancellation = new CancellationTokenSource();
        _check = cancellation;
        ShowProgress($"Connecting to {address}…");
        try
        {
            var result = await _backend.CheckAddressAsync(address, cancellation.Token);
            // Closing the dialog cancels, but a check that had already finished still resumes
            // here: nothing may be trusted or added after that.
            if (cancellation.IsCancellationRequested) return;
            // A new certificate is trusted once the scanner's UUID shows it is not a changed
            // certificate of a scanner trusted before; a changed one is asked about as such.
            bool firstUseAsked = false, trusted = false;
            while (!trusted && result.Certificate is { CanTrust: true } certificate)
            {
                ShowProgress("Confirm the scanner's certificate to continue.");
                if (!ConfirmCertificate(certificate))
                {
                    ShowProblem("The scanner was not added, because its certificate was not trusted.");
                    return;
                }
                if (cancellation.IsCancellationRequested) return;
                ShowProgress($"Connecting to {address}…");
                if (certificate.Verdict == EsclTrustVerdict.Unknown && !firstUseAsked)
                {
                    firstUseAsked = true;
                    result = await _backend.CheckAddressAsync(address, certificate.Fingerprint, cancellation.Token);
                }
                else
                {
                    _backend.TrustCertificate(certificate, deviceUuid: null, certificate.DeviceName);
                    trusted = true;
                    result = await _backend.CheckAddressAsync(address, cancellation.Token);
                }
                if (cancellation.IsCancellationRequested) return;
            }
            if (result.Capabilities is { } capabilities)
            {
                DeviceId = _backend.AddAddress(address, capabilities);
                if (IsVisible) DialogResult = true;
                return;
            }
            ShowProblem(result.Certificate?.Message ?? result.Error ?? $"No scanner answered at {address}.");
        }
        catch (OperationCanceledException)
        {
            // The dialog was closed while checking.
        }
        finally
        {
            _check = null;
            AddButton.IsEnabled = true;
            AddressBox.IsReadOnly = false;
            Progress.Visibility = Visibility.Collapsed;
        }
    }

    private void AddressBox_TextChanged(object sender, TextChangedEventArgs e)
    {
        // A message about the previous text no longer applies.
        if (_check is null) StatusPanel.Visibility = Visibility.Collapsed;
    }

    private void ShowProgress(string text)
    {
        AddButton.IsEnabled = false;
        AddressBox.IsReadOnly = true;
        StatusGlyph.Visibility = Visibility.Collapsed;
        Progress.Visibility = Visibility.Visible;
        SetStatus(text);
    }

    private void ShowProblem(string text)
    {
        StatusGlyph.Visibility = Visibility.Visible;
        Progress.Visibility = Visibility.Collapsed;
        SetStatus(text);
    }

    /// <summary>Error or progress text the dialog currently shows (harnesses read it).</summary>
    internal string StatusMessage => StatusPanel.Visibility == Visibility.Visible ? StatusText.Text : "";

    private void SetStatus(string text)
    {
        StatusText.Text = text;
        StatusPanel.Visibility = Visibility.Visible;
        var peer = UIElementAutomationPeer.FromElement(StatusText) ?? UIElementAutomationPeer.CreatePeerForElement(StatusText);
        peer?.RaiseAutomationEvent(AutomationEvents.LiveRegionChanged);
    }
}
