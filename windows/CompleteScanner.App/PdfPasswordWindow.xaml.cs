using System.Windows;
using System.Windows.Automation.Peers;
using System.Windows.Input;
using CompleteScanner.Core;

namespace CompleteScanner.App;

/// <summary>
/// Asks for the password of a protected PDF at save time: typed twice, with a hint about its
/// strength, and what PDF apps may let a reader do (print, copy), both allowed unless unticked.
/// On Save, <see cref="Protection"/> holds the prepared password; the password boxes are emptied
/// as the dialog closes, and nothing is stored anywhere.
/// </summary>
public partial class PdfPasswordWindow : Window
{
    /// <summary>The password and permissions given; null until Save.</summary>
    public PdfProtection? Protection { get; private set; }

    public PdfPasswordWindow()
    {
        InitializeComponent();
        Loaded += (_, _) => PasswordInput.Focus();
        Closed += (_, _) =>
        {
            PasswordInput.Clear();
            ConfirmInput.Clear();
        };
    }

    /// <summary>Shows the dialog over <paramref name="owner"/>; the protection given, or null when cancelled.</summary>
    public static PdfProtection? Ask(Window owner)
    {
        var dialog = new PdfPasswordWindow { Owner = owner };
        return dialog.ShowDialog() == true ? dialog.Protection : null;
    }

    private void Password_Changed(object sender, RoutedEventArgs e) => Refresh();

    /// <summary>The strength bar and its words, and Save enabled once the password can be used.</summary>
    internal void Refresh()
    {
        string password = PasswordInput.Password, confirmation = ConfirmInput.Password;
        var strength = PdfProtection.StrengthOf(password);
        string label = PdfProtection.StrengthLabel(strength);
        string hint = PdfProtection.StrengthHint(strength);
        bool hintChanged = StrengthText.Text != label;
        StrengthText.Text = label;
        StrengthPanel.ToolTip = hint.Length == 0 ? null : hint;
        System.Windows.Automation.AutomationProperties.SetName(StrengthText, hint);
        StrengthPanel.Visibility = label.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        int filled = PdfProtection.StrengthSegments(strength);
        string brush = strength switch
        {
            PasswordStrength.Weak => "SystemFillColorCriticalBrush",
            PasswordStrength.Fair => "SystemFillColorCautionBrush",
            _ => "SystemFillColorSuccessBrush",
        };
        var segments = StrengthBar.Children.OfType<System.Windows.Controls.Border>().ToList();
        for (int i = 0; i < segments.Count; i++)
        {
            segments[i].SetResourceReference(System.Windows.Controls.Border.BackgroundProperty,
                                             i < filled ? brush : "ControlStrongFillColorDisabledBrush");
        }
        // Screen readers hear a new hint (when the strength changes, not at every key).
        if (hintChanged && hint.Length > 0) Announce(StrengthText);
        string? problem = PdfProtection.Problem(password, confirmation);
        SaveButton.IsEnabled = problem is null;
        // A difference between the two is pointed out once the second has as many characters as
        // the first; a control character at once. An empty box needs no message.
        bool show = problem is not null && password.Length > 0
                    && (password.Any(char.IsControl) || confirmation.Length >= password.Length);
        ShowProblem(show ? problem : null);
    }

    private void Save_Click(object sender, RoutedEventArgs e) => Save();

    /// <summary>
    /// Enter in a password box while Save is off (the default button then does nothing): the
    /// message says why instead.
    /// </summary>
    private void Password_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter && EnterWithSaveOff()) e.Handled = true;
    }

    /// <summary>Shows why Save is off when it is; false when Save is on (the default button saves).</summary>
    internal bool EnterWithSaveOff()
    {
        if (SaveButton.IsEnabled) return false;
        Save();
        return true;
    }

    /// <summary>
    /// Leaving the second box with something typed in it points out a difference, also a shorter
    /// one, when focus stays in the dialog: not on the way to Cancel, out of the dialog or as it closes.
    /// </summary>
    private void Confirm_LostKeyboardFocus(object sender, KeyboardFocusChangedEventArgs e)
    {
        if (FocusStaysInDialog(e.NewFocus)) ConfirmLeft();
    }

    /// <summary>Whether focus going to <paramref name="newFocus"/> stays in this dialog, and not on Cancel.</summary>
    internal bool FocusStaysInDialog(IInputElement? newFocus) =>
        newFocus is DependencyObject target && !ReferenceEquals(target, CancelButton) && ReferenceEquals(GetWindow(target), this);

    internal void ConfirmLeft()
    {
        if (ConfirmInput.Password.Length == 0) return;
        if (PdfProtection.Problem(PasswordInput.Password, ConfirmInput.Password) is { } problem) ShowProblem(problem);
    }

    /// <summary>Takes the password when it can be used, and closes the dialog.</summary>
    internal void Save()
    {
        string password = PasswordInput.Password;
        if (PdfProtection.Problem(password, ConfirmInput.Password) is { } problem)
        {
            ShowProblem(problem);
            return;
        }
        Protection = new PdfProtection(password, AllowPrintingBox.IsChecked == true, AllowCopyingBox.IsChecked == true);
        PasswordInput.Clear();
        ConfirmInput.Clear();
        if (IsVisible) DialogResult = true;
    }

    /// <summary>The message the dialog shows under the boxes ("" when none; harnesses read it).</summary>
    internal string ProblemMessage => ProblemPanel.Visibility == Visibility.Visible ? ProblemText.Text : "";

    /// <summary>
    /// Shows or hides the message. Hidden keeps its line (emptied, so nothing stale is read out), so a
    /// one-line message (what leaving the second box shows) appearing as focus moves does not shift
    /// the controls under it: a click on a checkbox lands where it was aimed.
    /// </summary>
    private void ShowProblem(string? text)
    {
        if (text is null)
        {
            ProblemPanel.Visibility = Visibility.Hidden;
            ProblemText.Text = "";
            return;
        }
        bool changed = ProblemText.Text != text || ProblemPanel.Visibility != Visibility.Visible;
        ProblemText.Text = text;
        ProblemPanel.Visibility = Visibility.Visible;
        if (changed) Announce(ProblemText);
    }

    /// <summary>Tells screen readers that a live region's text changed: WPF does not do so by itself.</summary>
    private static void Announce(UIElement element)
    {
        var peer = UIElementAutomationPeer.FromElement(element) ?? UIElementAutomationPeer.CreatePeerForElement(element);
        peer?.RaiseAutomationEvent(AutomationEvents.LiveRegionChanged);
    }
}
