using System.Windows;
using System.Windows.Automation;
using LazyScan.Core;

namespace LazyScan.App;

/// <summary>
/// Asks whether to trust a network scanner's certificate: the first time the app connects to
/// it over HTTPS, or, with a warning, when it has changed since it was trusted. For a new
/// certificate the trust button is the default; for a changed one, Cancel is.
/// </summary>
public partial class CertificateTrustWindow : Window
{
    /// <summary>The trust button's text when connecting to a listed scanner.</summary>
    public const string ConnectAction = "Trust and connect";
    /// <summary>The trust button's text in the "Add scanner by address" dialog.</summary>
    public const string AddAction = "Trust and add";

    public CertificateTrustWindow(EsclCertificateException certificate, string trustAction)
    {
        InitializeComponent();
        string name = certificate.DeviceName;
        bool changed = certificate.Verdict == EsclTrustVerdict.Changed;

        Title = changed ? "Scanner certificate changed" : "Trust this scanner?";
        HeaderGlyph.Text = changed ? "" : "";
        HeaderGlyph.SetResourceReference(ForegroundProperty,
            changed ? "SystemFillColorCautionBrush" : "AccentTextFillColorPrimaryBrush");
        HeaderText.Text = changed ? $"The certificate of {name} has changed" : $"Trust {name}?";

        string trustedOn = certificate.Previous?.Trusted is { } date ? $" on {date.LocalDateTime:d}" : "";
        ExplanationText.Text = changed
            ? $"The scanner identified itself with a different certificate from the one you trusted{trustedOn}. "
              + "A firmware update or a reset of the scanner can change it, but so can another device on the network "
              + "that pretends to be your scanner."
            : "This scanner offers an encrypted connection and identifies itself with a certificate it made itself. "
              + "Windows cannot vouch for such certificates; that is normal for scanners.";
        AdviceText.Text = changed
            ? "Trust the new certificate only if you know why it changed. Otherwise choose Cancel and check the scanner."
            : "Trust it if this is your scanner. Lazy Scan remembers the certificate and warns you if it ever changes.";

        ScannerText.Text = name;
        AddressText.Text = certificate.Authority;
        if (certificate.Subject.Length > 0)
        {
            SubjectText.Text = certificate.Subject;
        }
        else
        {
            SubjectLabel.Visibility = Visibility.Collapsed;
            SubjectText.Visibility = Visibility.Collapsed;
        }
        FingerprintLabel.Text = changed ? "New fingerprint" : "Fingerprint";
        FingerprintBox.Text = EsclCertificates.Format(certificate.Fingerprint, bytesPerLine: 16);
        AutomationProperties.SetHelpText(FingerprintBox, "SHA-256 of the certificate's public key");
        if (changed && certificate.Previous is { } previous)
        {
            PreviousLabel.Visibility = Visibility.Visible;
            PreviousBox.Visibility = Visibility.Visible;
            PreviousBox.Text = EsclCertificates.Format(previous.Fingerprint, bytesPerLine: 16);
        }

        TrustButton.Content = changed ? "Trust the new certificate" : trustAction;
        var defaultChoice = changed ? CancelButton : TrustButton;
        defaultChoice.IsDefault = true;
        defaultChoice.SetResourceReference(StyleProperty, "AccentButtonStyle");
        Loaded += (_, _) => defaultChoice.Focus();
    }

    private void Trust_Click(object sender, RoutedEventArgs e) => DialogResult = true;
}
