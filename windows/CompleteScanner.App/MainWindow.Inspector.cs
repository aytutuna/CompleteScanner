using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Shapes;
using CompleteScanner.Core;

namespace CompleteScanner.App;

// The inspector's sections (InspectorSummary): their headers, which are open (as the user left them,
// remembered in the preferences), what each shows for the task and format, and the summary a collapsed
// header gives of what is on in it. Also the file name's Insert menu and its live preview.
public partial class MainWindow
{
    /// <summary>A section of the inspector: its Expander and the parts of its header.</summary>
    private sealed record InspectorSection(string Id, Expander Expander, TextBlock Title, TextBlock Summary,
                                           FrameworkElement Dot, TextBlock Lock)
    {
        public string TitleText => Title.Text;
    }

    private readonly List<InspectorSection> _sections = [];
    /// <summary>The sections are being opened or closed by the app (a task opening its section): not remembered.</summary>
    private bool _settingSections;

    private void SetUpInspectorSections()
    {
        Add(CopyOptions, InspectorSummary.Task, "", "Photocopy");
        Add(ReceiptOptions, InspectorSummary.Task, "", "Receipts");
        Add(ScannerSection, InspectorSummary.Scanner, "", "Scanner");
        Add(OutputSection, InspectorSummary.Output, "", "Output");
        Add(AdjustmentsSection, InspectorSummary.Adjustments, "", "Adjustments");
        Add(PagesSection, InspectorSummary.Pages, "", "Pages");
        Add(SplitSection, InspectorSummary.Split, "", "Split into documents");
        Add(ArchiveSection, InspectorSummary.Archive, "", "Archive & password");
        Add(MoreSection, InspectorSummary.More, "", "More options");

        Dictionary<string, bool> saved;
        try
        {
            saved = AppPreferencesStore.Load().InspectorSections;
        }
        catch
        {
            saved = [];
        }
        _settingSections = true;
        try
        {
            foreach (var section in _sections)
            {
                section.Expander.IsExpanded = saved.TryGetValue(section.Id, out bool open) ? open : InspectorSummary.OpenByDefault(section.Id);
            }
        }
        finally
        {
            _settingSections = false;
        }
    }

    private void Add(Expander expander, string id, string glyph, string title)
    {
        var icon = new TextBlock { Text = glyph, Margin = new Thickness(0, 2, 12, 0), VerticalAlignment = VerticalAlignment.Top };
        icon.SetResourceReference(StyleProperty, "GlyphText");
        var titleText = new TextBlock { Text = title, TextWrapping = TextWrapping.NoWrap, VerticalAlignment = VerticalAlignment.Center };
        titleText.SetResourceReference(StyleProperty, "BodyStrongText");
        // A 6 DIP accent dot: something in the collapsed section differs from the default.
        var dot = new Ellipse { Width = 6, Height = 6, Margin = new Thickness(8, 1, 0, 0), VerticalAlignment = VerticalAlignment.Center, Visibility = Visibility.Collapsed };
        dot.SetResourceReference(Shape.FillProperty, "AccentFillColorDefaultBrush");
        var titleRow = new StackPanel { Orientation = Orientation.Horizontal };
        titleRow.Children.Add(titleText);
        titleRow.Children.Add(dot);
        var lockGlyph = new TextBlock { Text = "", FontSize = 12, Margin = new Thickness(0, 1, 4, 0), Visibility = Visibility.Collapsed, VerticalAlignment = VerticalAlignment.Top };
        lockGlyph.SetResourceReference(StyleProperty, "GlyphText");
        lockGlyph.SetResourceReference(TextBlock.ForegroundProperty, "TextFillColorSecondaryBrush");
        var summary = new TextBlock { Visibility = Visibility.Collapsed, MaxWidth = 196 };
        summary.SetResourceReference(StyleProperty, "SectionSummaryText");
        var summaryRow = new StackPanel { Orientation = Orientation.Horizontal };
        summaryRow.Children.Add(lockGlyph);
        summaryRow.Children.Add(summary);
        var texts = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        texts.Children.Add(titleRow);
        texts.Children.Add(summaryRow);
        var header = new DockPanel();
        DockPanel.SetDock(icon, Dock.Left);
        header.Children.Add(icon);
        header.Children.Add(texts);
        expander.Header = header;
        expander.Tag = id;
        var section = new InspectorSection(id, expander, titleText, summary, dot, lockGlyph);
        _sections.Add(section);
        expander.Expanded += (_, e) => SectionToggled(section, e);
        expander.Collapsed += (_, e) => SectionToggled(section, e);
    }

    private void SectionToggled(InspectorSection section, RoutedEventArgs e)
    {
        if (!ReferenceEquals(e.OriginalSource, section.Expander)) return;
        if (IsLoaded) SyncInspectorSections();
        if (_settingSections) return;
        bool open = section.Expander.IsExpanded;
        try
        {
            AppPreferencesStore.Update(preferences => preferences.InspectorSections[section.Id] = open);
        }
        catch
        {
            // The preferences could not be written: the section stays as it is for this session.
        }
    }

    /// <summary>Opens a section for a task that needs it (Restore old photos opens Adjustments); not remembered.</summary>
    private void OpenSectionFor(ScanTask task)
    {
        if (InspectorSummary.OpenedBy(task) is not { } id) return;
        _settingSections = true;
        try
        {
            foreach (var section in _sections.Where(s => s.Id == id)) section.Expander.IsExpanded = true;
        }
        finally
        {
            _settingSections = false;
        }
    }

    /// <summary>
    /// Which sections show for the task and format (hide what can't apply), and each collapsed
    /// header's summary, accent dot and accessible name.
    /// </summary>
    private void SyncInspectorSections()
    {
        if (_sections.Count == 0) return;
        var s = ViewModel.Settings;
        var flow = TaskCatalog.FlowOf(s);
        bool copy = flow == TaskFlowKind.Copy, receipts = flow == TaskFlowKind.ReceiptSplit;
        bool documents = s.Intent == ScanIntent.Document;
        var shownFormat = ShownFormat(s);
        bool savesPdf = receipts ? OutputFormats.PageFormat(s.Format) == OutputFormat.Pdf : OutputFormats.SavesPdf(s.Format, s.DocumentMultiPage);
        bool textApplies = documents && savesPdf && (flow == TaskFlowKind.DocumentQueue || receipts);

        PagesSection.Visibility = documents && !copy && !receipts ? Visibility.Visible : Visibility.Collapsed;
        SplitSection.Visibility = PagesSection.Visibility;
        // Archive & password apply whenever the save writes a PDF (a queue of image pages too, and a
        // copy also saved as a PDF), not only when PDF is the format shown.
        ArchiveSection.Visibility = WritesPdf(s) ? Visibility.Visible : Visibility.Collapsed;
        AlsoSaveTextBox.Visibility = textApplies ? Visibility.Visible : Visibility.Collapsed;
        var output = _sections.First(x => x.Id == InspectorSummary.Output);
        output.Title.Text = documents ? "Output" : "Photos";

        foreach (var section in _sections)
        {
            string summary = "";
            bool changed = false;
            bool locked = false;
            string? name = null;
            switch (section.Id)
            {
                case InspectorSummary.Scanner:
                    summary = InspectorSummary.ScannerSummary(s);
                    changed = InspectorSummary.ScannerChanged(s);
                    break;
                case InspectorSummary.Output:
                    summary = InspectorSummary.OutputSummary(s, shownFormat);
                    changed = InspectorSummary.OutputChanged(s, shownFormat);
                    break;
                case InspectorSummary.Adjustments:
                    summary = InspectorSummary.AdjustmentsSummary(s.Adjustments);
                    changed = summary.Length > 0;
                    break;
                case InspectorSummary.Pages:
                    summary = InspectorSummary.PagesSummary(s.Document);
                    changed = summary.Length > 0;
                    int on = InspectorSummary.PagesOn(s.Document);
                    name = on == 0 ? section.TitleText : $"{section.TitleText}, {on} option{(on == 1 ? "" : "s")} on";
                    break;
                case InspectorSummary.Split:
                    summary = InspectorSummary.SplitSummary(s.Document);
                    changed = s.Document.SplitMode != SplitMode.None;
                    break;
                case InspectorSummary.Archive:
                    summary = InspectorSummary.ArchiveSummary(s.Output);
                    changed = s.Output.Protect || s.Output.Archival;
                    locked = s.Output.Protect;
                    break;
                case InspectorSummary.More:
                    summary = InspectorSummary.MoreSummary(s.Output, textApplies);
                    changed = summary.Length > 0;
                    break;
            }
            bool collapsed = !section.Expander.IsExpanded;
            section.Summary.Text = summary;
            section.Summary.Visibility = collapsed && summary.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
            section.Lock.Visibility = collapsed && locked ? Visibility.Visible : Visibility.Collapsed;
            section.Dot.Visibility = collapsed && changed ? Visibility.Visible : Visibility.Collapsed;
            AutomationProperties.SetName(section.Expander,
                name ?? (summary.Length > 0 ? $"{section.TitleText}, {summary}" : section.TitleText));
        }
        SyncFileNamePreview();
    }

    /// <summary>
    /// The save of document pages writes a PDF: a queue saves one for an image format too
    /// (<see cref="OutputFormats.QueueFormat"/>), receipts and the ID card save a PDF or an image
    /// (<see cref="OutputFormats.PageFormat"/>), and a copy with Also save as PDF on saves a PDF
    /// whatever the format. Photos never do.
    /// </summary>
    internal static bool WritesPdf(ScanSettings s)
    {
        if (s.Intent != ScanIntent.Document) return false;
        return TaskCatalog.FlowOf(s) switch
        {
            TaskFlowKind.Copy => s.TaskOptions.CopyAlsoSavePdf,
            TaskFlowKind.ReceiptSplit or TaskFlowKind.IdCard => OutputFormats.PageFormat(s.Format) == OutputFormat.Pdf,
            _ => OutputFormats.SavesPdf(s.Format, s.DocumentMultiPage),
        };
    }

    /// <summary>
    /// The format the inspector shows: photos save an image (a PDF or text format shows as JPEG),
    /// receipts a PDF or an image (Word and text show as PDF).
    /// </summary>
    private static OutputFormat ShownFormat(ScanSettings s) =>
        TaskCatalog.FlowOf(s) == TaskFlowKind.ReceiptSplit ? OutputFormats.PageFormat(s.Format)
        : s.Intent == ScanIntent.Photo ? OutputFormats.ImageFormatOrJpeg(s.Format)
        : s.Format;

    // MARK: - File name: the Insert menu and the preview

    /// <summary>The parts the Insert menu offers, with what each becomes.</summary>
    private static readonly (string Label, string Token)[] FileNameTokens =
    [
        ("Date", "{date}"),
        ("Time", "{time}"),
        ("Number", "{counter}"),
        ("Mode", "{intent}"),
        ("Task", "{task}"),
        ("Document name", "{label}"),
        ("Receipt date", "{docdate}"),
    ];

    private void InsertToken_Click(object sender, RoutedEventArgs e)
    {
        var menu = new ContextMenu { PlacementTarget = InsertTokenButton, Placement = PlacementMode.Bottom };
        foreach (var (label, token) in FileNameTokens)
        {
            var item = new MenuItem { Header = label, InputGestureText = token };
            item.Click += (_, _) => InsertToken(token);
            menu.Items.Add(item);
        }
        menu.IsOpen = true;
    }

    /// <summary>Puts <paramref name="token"/> where the caret was in the file name, and saves the name.</summary>
    internal void InsertToken(string token)
    {
        int at = Math.Clamp(TemplateBox.CaretIndex, 0, TemplateBox.Text.Length);
        string text = TemplateBox.Text;
        bool space = at > 0 && !char.IsWhiteSpace(text[at - 1]);
        string inserted = (space ? " " : "") + token;
        TemplateBox.Text = text.Insert(at, inserted);
        TemplateBox.CaretIndex = at + inserted.Length;
        TemplateBox.Focus();
        if (!string.IsNullOrWhiteSpace(TemplateBox.Text))
        {
            ViewModel.Settings.NamingTemplate = TemplateBox.Text;
            ViewModel.SettingsEdited();
            // Name by receipt date's reason and tooltip follow the file name ({docdate} may just have come in).
            SyncReceiptOptions();
        }
        SyncFileNamePreview();
    }

    private void TemplateBox_TextChanged(object sender, TextChangedEventArgs e)
    {
        if (IsLoaded) SyncFileNamePreview();
    }

    /// <summary>What the preview was last worked out for, so the counter file is not read at every refresh.</summary>
    private string? _previewSignature;

    /// <summary>The name the next file gets ("Scan 2026-10-20 4.pdf"), under the File name box.</summary>
    private void SyncFileNamePreview()
    {
        var s = ViewModel.Settings;
        string template = TemplateBox.Text.Trim().Length > 0 ? TemplateBox.Text : s.NamingTemplate;
        string signature = string.Join('\u001f', template, s.Format, s.Intent, s.DocumentMultiPage, ViewModel.SavedRevision,
                                       DateTime.Now.ToString("yyyyMMddHHmm"), TaskCatalog.Infer(s));
        if (signature == _previewSignature) return;
        _previewSignature = signature;
        string? name = ViewModel.FileNamePreview(template);
        FileNamePreview.Text = name ?? "";
        FileNamePreview.Visibility = name is null ? Visibility.Collapsed : Visibility.Visible;
        AutomationProperties.SetHelpText(TemplateBox, name is null ? "" : $"The next file is named {name}");
    }
}
