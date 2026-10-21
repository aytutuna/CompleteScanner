using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Globalization;
using System.IO;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using CompleteScanner.App.Services;
using CompleteScanner.Core;

namespace CompleteScanner.App;

/// <summary>
/// A page in the queue strip, wrapped with its display thumbnail and what the strip says about
/// it under the current blank-page settings (<see cref="Options"/>) and after crop and straighten.
/// </summary>
public sealed class PageItem : INotifyPropertyChanged
{
    /// <summary>Long side of a strip thumbnail, in pixels.</summary>
    public const int ThumbnailMaxSide = 240;

    public event PropertyChangedEventHandler? PropertyChanged;

    private DocumentOptions _options;
    private ScannedPage _page;

    /// <summary>Builds the thumbnail from the (already rotated) in-memory image; construct off the UI thread.</summary>
    public PageItem(ScannedPage page) : this(page, WpfImageCodec.ToThumbnail(page.Image, ThumbnailMaxSide)) { }

    /// <summary>
    /// The page with a thumbnail already made: the same pixels with other page facts (its side
    /// and sheet, kept or skipped).
    /// </summary>
    public PageItem(ScannedPage page, BitmapSource thumbnail, DocumentOptions? options = null)
    {
        _page = page;
        Thumbnail = thumbnail;
        _options = options?.Clone() ?? new DocumentOptions();
    }

    /// <summary>
    /// The page. Its facts (kept or skipped) change in place, so the strip keeps the item's
    /// container, and with it the keyboard focus on the item's Keep or Skip button.
    /// </summary>
    public ScannedPage Page
    {
        get => _page;
        set
        {
            if (ReferenceEquals(_page, value)) return;
            _page = value;
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(string.Empty));
        }
    }

    public BitmapSource Thumbnail { get; }

    /// <summary>The blank-page settings the strip shows the page with; the view model keeps it current.</summary>
    public DocumentOptions Options
    {
        get => _options;
        set
        {
            if (_options.Equals(value)) return;
            _options = value.Clone();
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(string.Empty));
        }
    }

    private PageSplitView? _split;

    /// <summary>
    /// What the split plan says about the page (its document, the gap before it, separator pages);
    /// the view model keeps it current. Null until then: the page is shown as the blank-page
    /// settings say.
    /// </summary>
    public PageSplitView? Split
    {
        get => _split;
        set
        {
            if (Equals(_split, value)) return;
            _split = value;
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(string.Empty));
        }
    }

    private PageBookView? _book;

    /// <summary>
    /// What the strip says about a page cut from a spread of a book (its spread, and its split and join
    /// actions); the view model keeps it current. Null for other pages.
    /// </summary>
    public PageBookView? Book
    {
        get => _book;
        set
        {
            if (Equals(_book, value)) return;
            _book = value;
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(string.Empty));
        }
    }

    /// <summary>
    /// "2 · back" for a page of a two-sided stack, "2 · left" for a page of a book, "Photo" for a page
    /// imported from a photo, "From phone" for one a paired phone sent; null for other pages.
    /// </summary>
    public string? SideLabel => DocumentSides.SideLabel(Page.Side, Page.SheetIndex) ?? _book?.Label ?? PhotoImport.SourceLabel(Page);

    /// <summary>
    /// The side badge spelled out ("Sheet 2, back", "Spread 2, left page"), or where a photo's or phone's
    /// page came from.
    /// </summary>
    public string? SideToolTip => DocumentSides.SideName(Page.Side, Page.SheetIndex) ?? _book?.Help
                                  ?? PhotoImport.SourceHelp(Page);

    /// <summary>
    /// The side badge on the thumbnail: "1 · front" for a page of a two-sided stack, "2 · left" for a
    /// page of a book, "Photo" or "From phone"; null for other pages and for a spread kept whole, which
    /// shows its "Not split" badge instead.
    /// </summary>
    public string? BadgeText => IsNotSplit ? null : SideLabel;

    /// <summary>The thumbnail's tooltip: where a photo's or phone's page came from; null for other pages.</summary>
    public string? SourceToolTip => Page.Side is null && _book is null ? PhotoImport.SourceHelp(Page) : null;

    /// <summary>A spread of a book kept as one page: its spine was not found, or its pages were joined.</summary>
    public bool IsNotSplit => _book is not null && Page.Spread is { IsWhole: true };

    /// <summary>The gap's tooltip: what a click does, in two words.</summary>
    public string? BreakToolTip => BreakLabel is null ? null : StartsDocument ? "Join" : "Split here";

    /// <summary>The page menu's "Split this spread…" or "Change the split…"; null when the page has none.</summary>
    public string? SplitSpreadLabel => _book?.SplitLabel;

    /// <summary>The page menu's "Join the two pages"; null when the page has none.</summary>
    public string? JoinSpreadLabel => _book?.JoinLabel;

    public bool HasSplitSpread => SplitSpreadLabel is not null;

    public bool HasJoinSpread => JoinSpreadLabel is not null;

    /// <summary>
    /// "Separator", "Blank, skipped", "Skipped", "Looks blank", or null
    /// (<see cref="DocumentSplitter.Badge"/>, <see cref="PageFilter.Badge"/>).
    /// </summary>
    public string? BlankBadge => _split is { } split ? split.Badge : PageFilter.Badge(Page, _options);

    /// <summary>Saving the queue leaves this page out.</summary>
    public bool IsExcluded => _split?.IsExcluded ?? PageFilter.IsExcluded(Page, _options);

    /// <summary>What the page's one-click button does ("Keep this page", "Skip this page"); null when it has none.</summary>
    public string? ToggleLabel => _split is { } split ? split.ToggleLabel : PageFilter.ToggleLabel(Page, _options);

    /// <summary>The badge's tooltip: what a separator page is; none for other badges, which say it all.</summary>
    public string? BadgeToolTip => _split?.SeparatorNote;

    /// <summary>"Document 2 · Lease" on the first page of each document when the queue is split; null otherwise.</summary>
    public string? DividerTitle => _split?.DividerTitle;

    /// <summary>What a click on the gap before the page does ("Start a new document here", "Join with document 1"); null: no gap button.</summary>
    public string? BreakLabel => _split?.BreakLabel;

    /// <summary>The page menu's split or join item; null when the page cannot start a document.</summary>
    public string? MenuBreakLabel => _split?.MenuBreakLabel;

    /// <summary>The page starts a document after the first: the gap before it is drawn as a divider.</summary>
    public bool StartsDocument => _split?.StartsDocument == true;

    /// <summary>The strip shows where documents start, so the page has room for the gap before it.</summary>
    public bool ShowsBreaks => _split?.ShowsBreaks == true;

    /// <summary>The page is saved in a document, so the document can be named from its menu.</summary>
    public bool CanNameDocument => _split?.Document is not null;

    /// <summary>The strip shows a gap button before the page.</summary>
    public bool HasBreakButton => BreakLabel is not null;

    /// <summary>The page's menu offers to split or join here.</summary>
    public bool HasMenuBreak => MenuBreakLabel is not null;

    /// <summary>The page's menu has a split or name item.</summary>
    public bool HasSplitMenu => HasMenuBreak || CanNameDocument;

    private bool _isNaming;

    /// <summary>The name box of the page's document is open (the strip's popup).</summary>
    public bool IsNaming
    {
        get => _isNaming;
        set
        {
            if (_isNaming == value) return;
            _isNaming = value;
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(IsNaming)));
        }
    }

    /// <summary>The name being typed in the name box.</summary>
    public string NameDraft { get; set; } = "";

    /// <summary>The button's short text: "Keep" for a left-out page, "Skip" otherwise.</summary>
    public string? ToggleText => ToggleLabel is null ? null : IsExcluded ? "Keep" : "Skip";

    /// <summary>
    /// "Cropped and straightened 2.4°", "As scanned", or null for a page crop and straighten left
    /// alone (<see cref="PageCorrections.Caption"/>).
    /// </summary>
    public string? GeometryCaption => PageCorrections.Caption(Page);

    /// <summary>What the page's swap button does ("Show as scanned", "Show straightened"); null when it has none.</summary>
    public string? GeometryToggleLabel => PageCorrections.ToggleLabel(Page);

    /// <summary>The swap button's tooltip: what was done to the page, then what a click does.</summary>
    public string? GeometryToolTip => GeometryToggleLabel is { } label ? $"{GeometryCaption}. {label}." : null;

    /// <summary>The swap button's glyph: undo while the changed page shows, redo while the page as scanned shows.</summary>
    public string GeometryGlyph => Page.ShowsOriginal ? "\uE7A6" : "\uE7A7";

    /// <summary>
    /// "Turned upright 180°", "Turned back as scanned", or null for a page not turned upright
    /// (<see cref="PageTurns.Caption"/>).
    /// </summary>
    public string? UprightCaption => PageTurns.Caption(Page);

    /// <summary>What the page's turn button does ("Undo turn", "Turn upright again"); null when it has none.</summary>
    public string? UprightToggleLabel => PageTurns.ToggleLabel(Page);

    /// <summary>The turn button's tooltip: what was done to the page, then what a click does.</summary>
    public string? UprightToolTip => UprightToggleLabel is { } label ? $"{UprightCaption}. {label}." : null;

    /// <summary>
    /// The page's name for screen readers: "Page 3, Sheet 2, back, Blank, skipped, Straightened
    /// 1.5°, Turned upright 180°", or "Page 3"; the first page of a document after the first starts
    /// with its title ("Document 2, Page 3").
    /// </summary>
    /// <param name="number">The page's position in the queue, from 1.</param>
    public string AccessibleName(int number)
    {
        string? side = DocumentSides.SideName(Page.Side, Page.SheetIndex) ?? _book?.Help ?? PhotoImport.SourceLabel(Page);
        string name = side is { } label ? $"Page {number}, {label}" : $"Page {number}";
        if (DividerTitle is { } title) name = $"{title}, {name}";
        if (_split?.SeparatorNote is { } note) name = $"{name}, {note}";
        else if (BlankBadge is { } badge) name = $"{name}, {badge}";
        if (GeometryCaption is { } caption) name = $"{name}, {caption}";
        return UprightCaption is { } turn ? $"{name}, {turn}" : name;
    }
}

/// <summary>A detected photo in the review grid, wrapped with its display thumbnail.</summary>
public sealed class PhotoItem : INotifyPropertyChanged
{
    /// <summary>Long side of a review thumbnail, in pixels.</summary>
    public const int ThumbnailMaxSide = 400;

    public event PropertyChangedEventHandler? PropertyChanged;

    public PhotoItem(DetectedPhoto photo, BitmapSource? thumbnail = null)
    {
        Photo = photo;
        Thumbnail = thumbnail ?? WpfImageCodec.ToThumbnail(photo.Image, ThumbnailMaxSide);
    }

    public DetectedPhoto Photo { get; }
    public BitmapSource Thumbnail { get; }

    public bool Included
    {
        get => Photo.Included;
        set
        {
            Photo.Included = value;
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(Included)));
        }
    }

    public void RotateClockwise()
    {
        Photo.RotationQuarterTurns = (Photo.RotationQuarterTurns + 1) % 4;
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(RotationDegrees)));
    }

    public double RotationDegrees => Photo.RotationQuarterTurns * 90;
}

/// <summary>
/// A scanner in the sidebar: one row per physical scanner, however many connections reach it
/// (WIA, TWAIN, network). <see cref="Info"/> is the entry the row stands for: the connection
/// in use while the scanner is selected, otherwise the one it would connect through.
/// </summary>
public sealed class DeviceRow(ScannerInfo info, DeviceGroup group, string? chosenConnection)
{
    public ScannerInfo Info { get; } = info;
    public DeviceGroup Group { get; } = group;
    /// <summary>The connection the user chose for this scanner (<see cref="DeviceMerge.ConnectionId"/>); null = Automatic.</summary>
    public string? ChosenConnection { get; } = chosenConnection;

    public string Id => Info.Id;
    public string Name => Info.Name;
    public string Transport => Info.Transport;
    public bool IsDemo => Info.IsDemo;
    /// <summary>More than one connection reaches the scanner, so the row offers a choice.</summary>
    public bool HasConnectionChoice => Group.Members.Count > 1;
    public string ConnectionLabel => DeviceMerge.ConnectionLabel(Info);
    /// <summary>The row's second line: how the scanner is reached.</summary>
    public string Caption =>
        IsDemo ? "Demo (no hardware)"
        : HasConnectionChoice ? $"via {ConnectionLabel}"
        // TWAIN lists installed drivers, so a scanner reached only that way is named for its driver
        // (a 32-bit one says so here too: a long name cuts off its "(32-bit driver)").
        : Info.Backend == TwainHelperSources.Backend ? "TWAIN (32-bit driver)"
        : AppViewModel.IsTwain(Info) ? "TWAIN driver"
        : ConnectionLabel;
    public string ConnectionChooserName => $"Connection for {Name}: {ConnectionLabel}";

    /// <summary>Equal for rows that look and behave the same, so an unchanged list is not rebuilt.</summary>
    internal string Signature =>
        string.Join('\u001f', [Info.Id, Info.Name, Info.Transport, Group.Key, ChosenConnection ?? "",
                               .. Group.Members.Select(m => m.Id)]);
}

/// <summary>One card in the Scans tab: a history entry plus its display bitmap.</summary>
public sealed class HistoryItem(ScanHistoryEntry entry, BitmapSource thumbnail)
{
    /// <summary>
    /// Stand-in thumbnail for the metadata-only entries the app keeps: the preview pixels
    /// live once, in <see cref="Thumbnail"/>.
    /// </summary>
    public static readonly RgbaImage NoPixels = new(1, 1, new byte[4]);

    /// <summary>Metadata of the scan; its <see cref="ScanHistoryEntry.Thumbnail"/> is <see cref="NoPixels"/>.</summary>
    public ScanHistoryEntry Entry { get; } = entry;
    public BitmapSource Thumbnail { get; } = thumbnail;

    public string Summary => $"{Entry.Intent.Label()} · {Entry.Dpi} dpi";
    public string PixelSizeText => $"{(int)Entry.PixelSize.Width} × {(int)Entry.PixelSize.Height} px";
    public string TimeText => Entry.Date.ToString("T");
    public string DetailText =>
        $"{Summary} · {PixelSizeText} · {Entry.Date:d} {Entry.Date:T}";

    /// <summary>The card's name for screen readers: "Document scan, 300 dpi, 2550 by 3510 pixels, 4:23 PM".</summary>
    public string AccessibleName =>
        $"{(Entry.Intent == ScanIntent.Photo ? "Photo scan" : "Document scan")}, {Entry.Dpi} dpi, "
        + $"{(int)Entry.PixelSize.Width} by {(int)Entry.PixelSize.Height} pixels, {Entry.Date:t}";

    /// <summary>The card's tooltip: what the card does not show ("300 dpi · 2550 × 3510 px · Just now").</summary>
    public string ToolTipText(DateTime now) =>
        $"{Entry.Dpi} dpi · {PixelSizeText} · {ScanTimeConverter.Relative(Entry.Date, now)}";
}

/// <summary>
/// Central controller: owns backends, the open scanner session, settings, scan results, and
/// every user-triggered operation. All UI binds to this object. Port of
/// Sources/CompleteScannerKit/App/AppState.swift — the orchestration logic (device merging,
/// generation-guarded switching, scan flows, page spooling, atomic saves, cooperative
/// cancellation, scan history, live preview) carries over; only the change-notification
/// plumbing is WPF-flavored. Must be created and used on a Dispatcher thread.
/// </summary>
public sealed partial class AppViewModel : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;

    /// <summary>Long side of the retained raw scan the live preview renders from.</summary>
    public const int CanvasPreviewMaxSide = 2600;

    /// <summary>Slider edits are coalesced: a render starts once they pause this long.</summary>
    private static readonly TimeSpan CanvasRenderDebounce = TimeSpan.FromMilliseconds(80);

    // MARK: Published state

    /// <summary>The sidebar's scanners: one row per physical scanner (see <see cref="DeviceMerge"/>).</summary>
    public ObservableCollection<DeviceRow> Devices { get; } = [];
    /// <summary>Every backend entry grouped by physical scanner, in sidebar order.</summary>
    public IReadOnlyList<DeviceGroup> DeviceGroups { get; private set; } = [];

    public string? SelectedDeviceId { get; private set; }
    public ScannerCapabilities? Capabilities { get; private set; }
    public ScanSettings Settings { get; private set; }

    /// <summary>Low-res preview of the full bed; the selection marquee is only valid over this image.</summary>
    public RgbaImage? OverviewImage { get; private set; }
    /// <summary>
    /// Downsampled RAW copy (≤ <see cref="CanvasPreviewMaxSide"/>) of the most recent scan;
    /// the canvas renders it through the CURRENT adjustments, so slider edits show without
    /// rescanning. Pages already queued keep the settings they were scanned with.
    /// </summary>
    public RgbaImage? LastScanImage { get; private set; }
    /// <summary>Normalized (0...1) crop rect within the flatbed, origin top-left. null = full bed.</summary>
    public RectD? SelectionRect { get; set; }

    public ObservableCollection<PageItem> ScannedPages { get; } = [];
    /// <summary>The open photo batch; replaced wholesale per scan, items replaced on re-crop.</summary>
    public ObservableCollection<PhotoItem> DetectedPhotos { get; private set; } = [];
    public bool ShowPhotoReview { get; private set; }

    /// <summary>The front of the ID card, cut out of its scan; null until it is scanned.</summary>
    public PhotoItem? IdCardFront { get; private set; }
    /// <summary>The back of the ID card; null until it is scanned, and when it was skipped.</summary>
    public PhotoItem? IdCardBack { get; private set; }
    /// <summary>What to check about the front's crop (<see cref="IdCardPick.Note"/>); null when the card was found.</summary>
    public string? IdCardFrontNote { get; private set; }
    /// <summary>What to check about the back's crop; null when the card was found.</summary>
    public string? IdCardBackNote { get; private set; }
    /// <summary>The sides are in (or the back was skipped): the review to check and save them is open.</summary>
    public bool ShowIdCardReview { get; private set; }
    /// <summary>A small picture of the page the sides are saved on; null while there is no front.</summary>
    public BitmapSource? IdCardPreview { get; private set; }
    /// <summary>What the page holds: "Front and back on one A4 page, at real size."</summary>
    public string IdCardLayoutCaption { get; private set; } = "";
    /// <summary>Set when the sides had to be made smaller to fit the page (<see cref="IdCardLayout.NotRealSizeMessage"/>).</summary>
    public string? IdCardSizeWarning { get; private set; }

    /// <summary>This session's scans, newest first (small previews only) — the Scans tab.</summary>
    public ObservableCollection<HistoryItem> History { get; } = [];

    public bool IsBusy { get; private set; }
    public ScanProgress? Progress { get; private set; }
    public string StatusMessage { get; private set; } = "Looking for scanners…";
    public string? ErrorMessage { get; set; }
    public List<string> LastSavedPaths { get; private set; } = [];
    /// <summary>Size of the PDF saved last in this session, in bytes; null before the first one.</summary>
    public long? LastPdfBytes { get; private set; }
    /// <summary>The PDF saved last was password-protected.</summary>
    public bool LastPdfProtected { get; private set; }

    /// <summary>
    /// Asks for the password of a protected PDF (<see cref="OutputOptions.Protect"/>) when a save
    /// needs one: the window shows its dialog; null (cancelled, or nobody to ask) saves nothing.
    /// Asked once per save; the answer is used for every PDF of that save and wiped when it ends.
    /// </summary>
    public Func<PdfProtection?>? AskPdfPassword { get; set; }

    /// <summary>The password of the save running now (<see cref="ProtectionFor"/>); null between saves.</summary>
    private PdfProtection? _savePassword;
    /// <summary>"Last PDF: 412 KB", shown under the PDF size choice; empty before the first PDF.</summary>
    public string LastPdfSizeText => LastPdfBytes is { } bytes ? $"Last PDF: {RoundedSizeText(bytes)}" : "";

    /// <summary>A file size as the inspector shows it: whole kilobytes ("498 KB"), else as <see cref="SavedFiles.SizeText"/> ("1.2 MB").</summary>
    internal static string RoundedSizeText(long bytes) =>
        bytes >= 1000 && Math.Round(bytes / 1000.0) < 1000 ? $"{Math.Round(bytes / 1000.0):0} KB" : SavedFiles.SizeText(bytes);

    /// <summary>
    /// The name the next file gets with <paramref name="template"/> and the current settings, for the
    /// inspector's preview ("Scan 2026-10-20 4.pdf"); null when it can't be worked out. Only reads
    /// the counter: nothing is written.
    /// </summary>
    public string? FileNamePreview(string template)
    {
        var s = Settings;
        try
        {
            var flow = TaskCatalog.FlowOf(s);
            var format = flow == TaskFlowKind.ReceiptSplit ? OutputFormats.PageFormat(s.Format)
                : s.Intent == ScanIntent.Photo ? OutputFormats.ImageFormatOrJpeg(s.Format)
                : s.DocumentMultiPage ? OutputFormats.QueueFormat(s.Format)
                : s.Format;
            string name = new NamingTemplate(template)
                .BaseFilename(new NamingContext(PeekCounter() + 1, DateTime.Now, s.Intent) { Task = TaskCatalog.Infer(s) });
            return $"{name}.{format.FileExtension()}";
        }
        catch
        {
            return null;
        }
    }
    /// <summary>Bumped whenever files are written to the destination folder (drives the Saved tab).</summary>
    public int SavedRevision { get; private set; }

    /// <summary>
    /// The files of the last save, offered with their actions (open, share, copy, …) in the bar
    /// above the window content; null once the bar is dismissed or the next scan starts.
    /// </summary>
    public IReadOnlyList<string>? SavedBarPaths { get; private set; }

    /// <summary>What the last save's several files are, for the Saved bar: "photos", "receipts" or "files".</summary>
    public string SavedBarNoun { get; private set; } = "files";
    /// <summary>What the bar says was saved: "Scan 2026-10-19 3.pdf (412 KB)", or "3 files in Scans".</summary>
    public string SavedBarText { get; private set; } = "";

    public ObservableCollection<Preset> Presets { get; } = [];

    /// <summary>No settings were saved before this start: the app opens on the start screen.</summary>
    public bool IsFirstRun { get; }

    /// <summary>The task the settings are set up for (picked on the start screen); null for settings chosen by hand.</summary>
    public ScanTask? ActiveTask => Settings.Task;

    public TaskDefinition? ActiveTaskDefinition => ActiveTask is { } task ? TaskCatalog.Definition(task) : null;

    /// <summary>
    /// Where the user is in the guided steps: the active task's, or turning a stack over by
    /// hand (<see cref="DocumentSides.ManualSteps"/>); null when nothing is guided.
    /// </summary>
    public TaskFlow? Flow { get; private set; }
    /// <summary>What <see cref="Flow"/> was made for: a task, or (Manual) turning the stack over by hand.</summary>
    private (ScanTask? Task, bool Manual) _flowKey;

    /// <summary>Caption of the Scan button: the current step's action ("Scan page"), or "Scan".</summary>
    public string PrimaryActionLabel => Flow?.Current?.PrimaryActionLabel ?? "Scan";

    /// <summary>The steps guide turning a stack over by hand: fronts, then backs.</summary>
    public bool IsTurningOverByHand => Flow is not null && _flowKey.Manual;

    /// <summary>Turning over by hand, the backs are next (or were scanned and did not pair up).</summary>
    public bool AwaitingBacks => IsTurningOverByHand && Flow?.Current?.Id == DocumentSides.BacksStepId;

    /// <summary>
    /// Turning over by hand, fronts are in the queue but the stack was not turned over yet (the
    /// feeder stopped early, or more fronts were asked for): <see cref="FinishFronts"/> moves on
    /// to the backs.
    /// </summary>
    public bool CanFinishFronts =>
        IsTurningOverByHand && Flow?.Current?.Id == DocumentSides.FrontsStepId && QueuedCaptures(DocumentSides.FrontsStepId) > 0;

    /// <summary>
    /// The backs are due but none was scanned yet: <see cref="ScanMoreFronts"/> goes back to the
    /// fronts, for a stack larger than the feeder holds.
    /// </summary>
    public bool CanScanMoreFronts => AwaitingBacks && QueuedCaptures(DocumentSides.BacksStepId) == 0;

    /// <summary>
    /// The fronts and backs of a stack turned over by hand did not pair up, e.g. "3 fronts but 2
    /// backs"; null otherwise. The user scans the backs again, combines the pages as they are,
    /// or keeps the fronts only.
    /// </summary>
    public string? SidesMismatch { get; private set; }

    /// <summary>How the next scan captures the sheets (one side, both, or turned over by hand).</summary>
    public DuplexMode EffectiveDuplex => DocumentSides.Effective(Settings, Capabilities);

    /// <summary>The steps guide the ID card task: front, back, then the review.</summary>
    public bool IsIdCardFlow => Flow is not null && _flowKey.Task == ScanTask.IdCard && !_flowKey.Manual;

    /// <summary>A side of an ID card is held in memory and not saved yet.</summary>
    public bool HasIdCardCaptures => IdCardFront is not null || IdCardBack is not null;

    /// <summary>
    /// The skip button of the banner is offered: the back of an ID card (<see cref="IdCardSteps.OffersSkip"/>).
    /// </summary>
    public bool CanSkipStep => IsIdCardFlow && IdCardSteps.OffersSkip(Flow?.Current);

    /// <summary>
    /// A switch of scanner made by the app (the scanner went away, another connection or a real
    /// scanner appeared) waits: it would discard a running operation or the open photo review, or
    /// the ID card's sides, whose other side and new scans need this scanner's glass. The switch is
    /// made once these end (<see cref="EndOfWork"/>).
    /// </summary>
    private bool AutoSwitchMustWait => IsBusy || ShowPhotoReview || ShowIdCardReview || HasIdCardCaptures;

    /// <summary>
    /// The page the ID card is saved on: the choice in the review; Automatic is the default printer's
    /// paper when it is A4 or Letter, else the paper usual where the user lives.
    /// </summary>
    public PaperSize IdCardPaperSize => IdCardPapers.Resolve(Settings.TaskOptions.IdCardPaper, RegionCode, _defaultPrinterPaper);

    /// <summary>How the review's paper picker names a choice, Automatic with the paper it is now.</summary>
    public string IdCardPaperChoiceLabel(IdCardPaper paper) => IdCardPapers.ChoiceLabel(paper, RegionCode, _defaultPrinterPaper);

    /// <summary>The user's country or region (two letters), for the paper usual there; null when unknown.</summary>
    public static string? RegionCode
    {
        get
        {
            try { return RegionInfo.CurrentRegion.TwoLetterISORegionName; }
            catch (ArgumentException) { return null; }
        }
    }

    /// <summary>The start screen's task cards, with what the connected scanner (and, for Copy, the printers) can do.</summary>
    public IReadOnlyList<TaskCardItem> TaskCards =>
        TaskCatalog.All.Select(definition => new TaskCardItem(
            definition,
            TaskCatalog.Availability(definition.Task, Capabilities, HasPrinter),
            ActiveTask == definition.Task,
            TaskCatalog.Summary(SettingsAdapter.Adapt(TaskCatalog.Apply(definition.Task, new ScanSettings()),
                                                      Capabilities).Settings))).ToList();

    /// <summary>Image shown in the preview canvas (before live adjustments).</summary>
    public RgbaImage? CanvasImage => OverviewImage ?? LastScanImage;
    /// <summary><see cref="CanvasImage"/> rendered through the current adjustments.</summary>
    public BitmapSource? CanvasBitmap { get; private set; }
    /// <summary>True while a live-preview render is scheduled or running.</summary>
    public bool IsCanvasRenderPending => _renderTimer.IsEnabled || _renderInFlight;

    /// <summary>The destination folder with environment variables expanded.</summary>
    public string DestinationFolder => Environment.ExpandEnvironmentVariables(Settings.DestinationPath);

    public static readonly int[] FallbackResolutions = [75, 150, 200, 300, 600, 1200];

    // MARK: Private

    private readonly IReadOnlyList<IScannerBackend> _backends;
    private readonly PresetStore _presetStore;
    private readonly IOcrService _ocrService;
    /// <summary>Reads pages for "Rotate pages upright" (<see cref="OrientationStep"/>).</summary>
    private readonly IOrientationScorer _orientation;
    /// <summary>Reads barcodes and QR codes on pages, when the stack is split at barcode or QR sheets.</summary>
    private readonly IBarcodeReader _barcodes;
    /// <summary>Makes the QR code of a QR separator sheet.</summary>
    private readonly IQrEncoder _qrEncoder;
    /// <summary>Opens, shows, shares and copies saved files through Windows (a stand-in in tests).</summary>
    private readonly IFileActions _fileActions;
    private readonly Dispatcher _dispatcher;
    /// <summary>Where queued document pages are spilled to disk (this process's own folder).</summary>
    private readonly PageSpool _spool;
    private IScannerSession? _session;
    private bool _userPickedDevice;
    /// <summary>The user's connection choice per scanner (<see cref="AppPreferences.PreferredConnection"/>).</summary>
    private readonly Dictionary<string, string> _preferredConnection;
    /// <summary>Devices that scan through their driver's own window (<see cref="AppPreferences.TwainDriverWindow"/>).</summary>
    private readonly HashSet<string> _driverWindowDevices;
    /// <summary>The backend entry of the selected device, kept so its scanner is found again when that entry goes away.</summary>
    private ScannerInfo? _selectedEntry;
    /// <summary>
    /// Devices whose certificate changed and was not trusted this session (refused when the app
    /// opened them on its own, or declined by the user): never selected automatically again,
    /// so only the user choosing one asks about its certificate.
    /// </summary>
    private readonly HashSet<string> _certificateRefused = [];
    /// <summary>WIA Automation, which finds scanners by polling (null when the app runs without it).</summary>
    private readonly Scanning.IPolledScannerBackend? _polled;
    /// <summary>
    /// Each Windows Scan entry listed now, with how many WIA enumerations had started when it was
    /// first listed: until WIA finishes a later one, its scanner may simply not be in WIA's list
    /// yet (see <see cref="AwaitingWia"/>).
    /// </summary>
    private readonly Dictionary<string, long> _windowsScanListedAt = [];
    /// <summary>The last merge found a Windows Scan entry <see cref="AwaitingWia"/>: the end of a WIA enumeration merges again.</summary>
    private bool _windowsScanAwaitingWia;
    /// <summary>The device diagnostics last written (see <see cref="WriteDeviceDiagnostics"/>).</summary>
    private string _lastDeviceReport = "";
    /// <summary>Reads the WIA service and the network for the troubleshooter; opens Settings and copies (a stand-in in tests).</summary>
    private readonly ISystemDiagnostics _system;
    /// <summary>The WIA service and network as last read (<see cref="ReadSystemStateAsync"/>); Unknown until then.</summary>
    private (ServiceStatus Wia, NetworkStatus Network) _systemState;
    /// <summary>The last failed connection or scan, for the troubleshooter; cleared by the next one that works.</summary>
    private ScannerFailure? _lastFailure;
    /// <summary>
    /// A real scanner appeared, the selected one went away, or another connection to it became
    /// the preferred one, during an operation/review; re-evaluate the selection afterwards.
    /// </summary>
    private bool _autoSwitchDeferred;
    /// <summary>
    /// Device switches are serialized through this chain; concurrent clicks must never
    /// interleave open/close on hardware sessions.
    /// </summary>
    private Task _switchTask = Task.CompletedTask;
    private int _switchGeneration;
    private DispatcherTimer? _settingsSaveTimer;
    private int _counterFallback;
    /// <summary>The current exclusive operation's cancellation (null when idle).</summary>
    private CancellationTokenSource? _operationCts;
    private Task _currentOperation = Task.CompletedTask;
    /// <summary>Core-side history list (authoritative order/cap); <see cref="History"/> mirrors it.</summary>
    private readonly List<ScanHistoryEntry> _history = [];
    private readonly Dictionary<Guid, HistoryItem> _historyItems = [];
    /// <summary>
    /// Full-resolution sources of the current photo batch, keyed by scanned-page id and
    /// retained only while the photo review is open, so manual crop corrections can
    /// re-extract each photo from the correct sheet at full quality.
    /// </summary>
    private Dictionary<Guid, RgbaImage> _photoSourceImages = [];
    /// <summary>
    /// The scans the ID card's sides were cut from, by scanned-page id, so a crop can be fixed. In
    /// memory only (ID card scans are never spooled), and dropped with the sides.
    /// </summary>
    private readonly Dictionary<Guid, RgbaImage> _idCardSources = [];
    /// <summary>
    /// What each of those scans covers (resolution, size, selection), so a back that does not stand
    /// out takes the front's place only on a scan of the same part of the glass.
    /// </summary>
    private readonly Dictionary<Guid, IdCardScanArea> _idCardScanAreas = [];
    /// <summary>Bumped for every new picture of the ID card's page; a late one is dropped.</summary>
    private int _idCardPreviewRevision;
    /// <summary>Page rotations run in order (rapid clicks accumulate instead of racing).</summary>
    private Task _pageRotateChain = Task.CompletedTask;
    /// <summary>In-flight re-crops; saving the batch waits for them first.</summary>
    private Task _recropChain = Task.CompletedTask;

    // Live preview.
    private readonly DispatcherTimer _renderTimer;
    private int _canvasRevision;
    private CanvasRenderKey? _renderedKey;
    private bool _renderInFlight;
    private bool _renderQueued;

    private readonly record struct CanvasRenderKey(int Revision, AdjustmentSettings Adjustments, ColorMode ColorMode);

    public AppViewModel(IReadOnlyList<IScannerBackend>? backends = null,
                        IOcrService? ocrService = null,
                        IFileActions? fileActions = null,
                        ISystemDiagnostics? systemDiagnostics = null,
                        IPrintService? printService = null,
                        IOrientationScorer? orientationScorer = null,
                        IBarcodeReader? barcodeReader = null,
                        IQrEncoder? qrEncoder = null)
    {
        _dispatcher = Dispatcher.CurrentDispatcher;
        var saved = SettingsStore.Load();
        IsFirstRun = saved is null;
        // A task saved last time is still active: its banner comes back with the settings.
        Settings = saved ?? new ScanSettings();
        _labelsCarriedUnder = Settings.Document.Clone();
        _readsBarcodes = PageProcessor.ReadsBarcodes(Settings);
        SyncTaskFlow();
        // Windows Scan writes each scan's files to the page spool, created below; it is read only once a scan runs.
        _backends = backends ?? DefaultBackends(SpoolDirectory);
        _polled = _backends.OfType<Scanning.IPolledScannerBackend>().FirstOrDefault();
        _presetStore = new PresetStore();
        var preferences = AppPreferencesStore.Load();
        // A null value can only come from a hand-edited file; it means no choice.
        _preferredConnection = preferences.PreferredConnection
            .Where(pair => pair.Value is not null)
            .ToDictionary(pair => pair.Key, pair => pair.Value);
        _driverWindowDevices = [.. preferences.TwainDriverWindow.Where(id => id is not null)];
        _ocrService = ocrService ?? new WindowsOcrService();
        _fileActions = fileActions ?? new WindowsFileActions(MainWindowHandle);
        _system = systemDiagnostics ?? new WindowsSystemDiagnostics();
        _print = printService ?? new WindowsPrintService();
        _orientation = orientationScorer ?? new WindowsOrientationScorer();
        _barcodes = barcodeReader ?? new ZXingBarcodeReader();
        _qrEncoder = qrEncoder ?? new ZXingQrEncoder();
        foreach (var preset in _presetStore.Load()) Presets.Add(preset);
        _renderTimer = new DispatcherTimer(DispatcherPriority.Normal, _dispatcher) { Interval = CanvasRenderDebounce };
        _renderTimer.Tick += (_, _) =>
        {
            _renderTimer.Stop();
            StartCanvasRender();
        };
        // Clears the spill files of earlier runs, never those of another running instance.
        _spool = new PageSpool();
    }

    /// <summary>
    /// Completes when the current exclusive operation (scan, export, PDF build) has finished,
    /// including its cleanup; already completed when idle. Never faults.
    /// </summary>
    public Task CurrentOperation => _currentOperation;

    /// <summary>This process's page spool folder.</summary>
    private string SpoolDirectory() => _spool.Directory;

    /// <param name="spoolFolder">This process's page spool folder, where Windows Scan writes the files of a scan.</param>
    private static IReadOnlyList<IScannerBackend> DefaultBackends(Func<string> spoolFolder)
    {
        var twain = new Scanning.Twain.TwainScannerBackend();
        return [new Scanning.WiaScannerBackend(),
                // The backup connection to WIA scanners: ranked after every other connection, and
                // listed before the 32-bit TWAIN helper, which also ranks last.
                new Scanning.WinRtScannerBackend(spoolFolder),
                new Scanning.EsclScannerBackend(),
                twain,
                // Drivers installed only for 32-bit programs, through the 32-bit helper.
                new Scanning.Twain.Twain32ScannerBackend(twain),
                // The demo's second sheet has a blank back, to show blank pages being flagged.
                new MockScannerBackend { FeederBlankBackSheets = [1] }];
    }

    /// <summary>On app exit: flush settings, remove this process's page spill files and end the 32-bit TWAIN helper.</summary>
    public void Shutdown()
    {
        ShutdownCompanion();
        FlushSettings();
        _spool.Dispose();
        foreach (var backend in _backends.OfType<IDisposable>())
        {
            try
            {
                backend.Dispose();
            }
            catch (Exception e)
            {
                System.Diagnostics.Trace.TraceWarning($"Closing a scanner connection failed: {e.Message}");
            }
        }
    }

    private void NotifyAll()
    {
        SyncPageOptions();
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(string.Empty));
    }

    /// <summary>
    /// The page strip shows every page under the current blank-page and split settings, and the spread of
    /// each book page; spreads no page is cut from any more are dropped.
    /// </summary>
    private void SyncPageOptions()
    {
        foreach (var item in ScannedPages) item.Options = Settings.Document;
        SyncPagePlan();
        PruneSpreads();
        SyncBookLabels();
    }

    /// <summary>Call after mutating Settings from the UI: debounced persist + live preview refresh.</summary>
    public void SettingsEdited()
    {
        // A feeder that scans one side turns two-sided scanning into turning over by hand.
        if (Settings.Duplex == DuplexMode.Both && EffectiveDuplex == DuplexMode.Manual) Settings.Duplex = DuplexMode.Manual;
        SyncTaskFlow();
        // A named document whose first page the settings now leave out keeps its name.
        CarryDocumentLabelsAcrossSettings();
        // Split at barcode or QR sheets just chosen: the pages queued before are read too.
        BarcodeSettingsEdited();
        // The page strip's badges follow the blank-page settings.
        SyncPageOptions();
        // The Copies section shows the paper the printer is asked for.
        if (IsCopyFlow && RequestedPaper(Settings) != _copySetupPaper) _ = RefreshCopySetupAsync();
        _settingsSaveTimer?.Stop();
        _settingsSaveTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(400) };
        var snapshot = Settings.Clone();
        _settingsSaveTimer.Tick += (_, _) =>
        {
            _settingsSaveTimer?.Stop();
            SettingsStore.Save(snapshot);
        };
        _settingsSaveTimer.Start();
        RequestCanvasRender(debounce: true);
    }

    /// <summary>Flush the debounced settings write on app exit.</summary>
    public void FlushSettings()
    {
        _settingsSaveTimer?.Stop();
        SettingsStore.Save(Settings);
    }

    // MARK: Devices

    public void Start()
    {
        // A Windows Scan entry WIA had not confirmed waits for the end of a WIA enumeration (see AwaitingWia).
        if (_polled is not null) _polled.EnumerationFinished += () => _dispatcher.BeginInvoke(AfterWiaEnumeration);
        foreach (var backend in _backends)
        {
            backend.DevicesChanged += () => _dispatcher.BeginInvoke(MergeDevices);
            backend.StartBrowsing();
        }
        MergeDevices();
        // The troubleshooter's part of devices.txt needs the WIA service and the network.
        _ = ReadSystemStateAsync();
        // The Copy card needs a printer; Automatic paper for the ID card is the default printer's.
        _ = RefreshPrintersAsync();
        // Remove partial files an export cut off by a crash left in the destination folder.
        string folder = DestinationFolder;
        _ = Task.Run(() => SavedFiles.SweepStaleTempFiles(folder, SavedFiles.StaleTempFileAge));
    }

    /// <summary>
    /// Rebuilds the scanner list from every backend: entries for the same physical scanner are
    /// grouped (<see cref="DeviceMerge.Group"/>) and the selection follows its scanner. When
    /// another connection to the selected scanner becomes the preferred one (a better one
    /// appeared, the user chose one, or the one in use went away), the session moves to it.
    /// </summary>
    private void MergeDevices()
    {
        var entries = _backends.SelectMany(b => b.Devices).ToList();
        TrackWindowsScanEntries(entries);
        DeviceGroups = DeviceMerge.Group(entries, DeviceMerge.WindowsRanking, _preferredConnection);
        WriteDeviceDiagnostics();

        if (SelectedDeviceId is { } sel)
        {
            if (entries.FirstOrDefault(d => d.Id == sel) is { } current) _selectedEntry = current;
            var group = GroupOfSelection(sel);
            // When the connection in use went away and only TWAIN still lists the scanner, it
            // was most likely unplugged or turned off (TWAIN lists installed drivers): treat
            // it as gone rather than opening its driver.
            if (group is not null && TwainOnly(group) && group.Members.All(m => m.Id != sel)) group = null;
            if (group is null)
            {
                // The device went away (unplugged, powered off). Switching would discard a
                // running operation or an open photo review, whose pixels no longer need the
                // scanner, so wait for those to end (EndOfWork re-runs this merge).
                if (AutoSwitchMustWait)
                {
                    _autoSwitchDeferred = true;
                }
                else
                {
                    _userPickedDevice = false;
                    SelectDevice(PreferredDefaultDevice());
                }
            }
            else if (group.Primary.Id != sel)
            {
                // Same scanner, another connection: the same deferral rules apply. The user's
                // pick of this scanner stands.
                if (AutoSwitchMustWait) _autoSwitchDeferred = true;
                else SelectDevice(group.Primary.Id);
            }
            else if (!_userPickedDevice && PreferredDefaultDevice() is { } real
                     && group.Primary.IsDemo
                     && DeviceGroups.First(g => g.Primary.Id == real).Primary is { IsDemo: false })
            {
                // A real scanner appeared while we were auto-parked on the demo device. Switching
                // would discard a running operation or an open photo review, so wait for those
                // to end (EndOfWork re-runs this merge).
                if (AutoSwitchMustWait) _autoSwitchDeferred = true;
                else SelectDevice(real);
            }
        }
        else if (PreferredDefaultDevice() is { } def)
        {
            SelectDevice(def);
        }
        RefreshDeviceRows();
        NotifyAll();
    }

    /// <summary>
    /// Notes when each Windows Scan entry was first listed, and has WIA Automation look again for a
    /// new one: Windows Scan reports a scanner as soon as it is plugged in, WIA only on its next
    /// poll (up to a minute later), so the WIA entry of the same scanner is usually on its way.
    /// </summary>
    private void TrackWindowsScanEntries(List<ScannerInfo> entries)
    {
        var listed = entries.Where(e => e.Backend == WindowsScanConnection.Backend).Select(e => e.Id).ToHashSet();
        foreach (string gone in _windowsScanListedAt.Keys.Where(id => !listed.Contains(id)).ToList())
        {
            _windowsScanListedAt.Remove(gone);
        }
        if (_polled is null) return;
        bool added = false;
        foreach (string id in listed)
        {
            added |= _windowsScanListedAt.TryAdd(id, _polled.EnumerationsStarted);
        }
        if (added) _polled.RefreshDevices();
        _windowsScanAwaitingWia = _windowsScanListedAt.Values.Any(listedAt => _polled.EnumerationsFinished <= listedAt);
    }

    /// <summary>
    /// A Windows Scan entry listed before WIA Automation finished an enumeration that started after
    /// it appeared: WIA may list the same scanner any moment, so it is not chosen on its own yet.
    /// </summary>
    private bool AwaitingWia(ScannerInfo device) =>
        device.Backend == WindowsScanConnection.Backend && _polled is { } wia
        && _windowsScanListedAt.TryGetValue(device.Id, out long listedAt) && wia.EnumerationsFinished <= listedAt;

    /// <summary>WIA Automation finished looking: a scanner waiting for it is either in its list now or reached only through Windows Scan.</summary>
    private void AfterWiaEnumeration()
    {
        if (_windowsScanAwaitingWia) MergeDevices();
    }

    /// <summary>Re-evaluate a deferred automatic device switch once nothing is in progress.</summary>
    private void EndOfWork()
    {
        if (_autoSwitchDeferred && !AutoSwitchMustWait)
        {
            _autoSwitchDeferred = false;
            MergeDevices();
        }
        // Queued pages a scan or a busy moment left unread (AppViewModel.Split.cs).
        ReadQueuedBarcodesAfterWork();
    }

    /// <summary>
    /// The first real scanner (else the demo device), through its preferred connection. A
    /// scanner only TWAIN reaches is never chosen on its own: TWAIN lists installed drivers,
    /// not connected scanners, and opening the driver of one that is off or gone can show the
    /// driver's own error messages and fails anyway. It is opened only when the user picks it.
    /// Nor is a scanner whose changed certificate was not trusted (<see cref="_certificateRefused"/>),
    /// nor, for now, one only Windows Scan (and TWAIN) lists before WIA Automation has looked
    /// again (<see cref="AwaitingWia"/>): Windows Scan is a backup, and the WIA entry of the same
    /// scanner is usually on its way. Once WIA has looked and does not list it, Windows Scan is
    /// the connection left, and it is chosen.
    /// </summary>
    private string? PreferredDefaultDevice() =>
        (DeviceGroups.FirstOrDefault(g => !g.Primary.IsDemo && !NotChosenOnItsOwn(g) && !_certificateRefused.Contains(g.Primary.Id))
         ?? DeviceGroups.FirstOrDefault(g => g.Primary.IsDemo))?.Primary.Id;

    private static bool TwainOnly(DeviceGroup group) => group.Members.All(m => IsTwain(m));

    /// <summary>Every connection to the scanner is TWAIN or a Windows Scan entry <see cref="AwaitingWia"/> (see <see cref="PreferredDefaultDevice"/>).</summary>
    private bool NotChosenOnItsOwn(DeviceGroup group) => group.Members.All(m => IsTwain(m) || AwaitingWia(m));

    /// <summary>A TWAIN connection, in this process (64-bit drivers) or through the 32-bit helper.</summary>
    internal static bool IsTwain(ScannerInfo device) => device.Backend is "twain" or TwainHelperSources.Backend;

    /// <summary>
    /// The scanner the selected device belongs to: the group listing it, or, when that entry
    /// went away, the group holding another connection to the same scanner.
    /// </summary>
    private DeviceGroup? GroupOfSelection(string id) =>
        DeviceGroups.FirstOrDefault(g => g.Members.Any(m => m.Id == id))
        ?? (_selectedEntry is { } entry && entry.Id == id
            ? DeviceGroups.FirstOrDefault(g => g.Members.Any(m => DeviceMerge.SameDevice(m, entry)))
            : null);

    /// <summary>
    /// One row per scanner; the selected scanner's row shows the connection in use (until a
    /// deferred switch moves it), the others the connection they would use.
    /// </summary>
    private void RefreshDeviceRows()
    {
        string? sel = SelectedDeviceId;
        var rows = DeviceGroups.Select(group =>
        {
            var shown = group.Members.FirstOrDefault(m => m.Id == sel) ?? group.Primary;
            string? chosen = _preferredConnection.TryGetValue(group.Key, out var connection)
                             && group.Members.Any(m => string.Equals(DeviceMerge.ConnectionId(m), connection,
                                                                     StringComparison.OrdinalIgnoreCase))
                ? connection : null;
            return new DeviceRow(shown, group, chosen);
        }).ToList();
        if (rows.Select(r => r.Signature).SequenceEqual(Devices.Select(r => r.Signature))) return;
        Devices.Clear();
        foreach (var row in rows) Devices.Add(row);
    }

    /// <summary>
    /// The user chose how to reach a scanner (<see cref="DeviceMerge.ConnectionId"/>, or null
    /// for Automatic). The choice is saved, and the scanner is selected through it. For the
    /// selected scanner, a running operation or open photo review is not discarded: the switch
    /// waits for it to end, like any other connection change (see <see cref="MergeDevices"/>).
    /// </summary>
    public void ChooseConnection(string groupKey, string? connectionId)
    {
        if (connectionId is null) _preferredConnection.Remove(groupKey);
        else _preferredConnection[groupKey] = connectionId;
        AppPreferencesStore.Update(preferences =>
        {
            if (connectionId is null) preferences.PreferredConnection.Remove(groupKey);
            else preferences.PreferredConnection[groupKey] = connectionId;
        });
        MergeDevices();
        if (DeviceGroups.FirstOrDefault(g => g.Key == groupKey) is not { } group) return;
        bool selectedScanner = SelectedDeviceId is { } sel && GroupOfSelection(sel)?.Key == groupKey;
        if (selectedScanner && AutoSwitchMustWait)
        {
            // MergeDevices deferred the switch; EndOfWork makes it.
            _userPickedDevice = true;
            return;
        }
        UserSelectDevice(group.Primary.Id);
    }

    /// <summary>
    /// The network (eSCL) connection: adds scanners by address and asks before trusting a
    /// scanner's certificate. null when the app runs without it.
    /// </summary>
    public Scanning.EsclScannerBackend? NetworkScanners => _backends.OfType<Scanning.EsclScannerBackend>().FirstOrDefault();

    /// <summary>
    /// A scanner was just added by address (<paramref name="deviceId"/>): list it, and select
    /// it unless an operation or the photo review is in progress, which a switch would end.
    /// </summary>
    public void SelectAddedDevice(string deviceId)
    {
        MergeDevices();
        if (DeviceGroups.FirstOrDefault(g => g.Members.Any(m => m.Id == deviceId)) is not { } group) return;
        if (AutoSwitchMustWait) return;
        UserSelectDevice(group.Primary.Id);
    }

    /// <summary>The connected scanner can scan through its driver's own settings window (TWAIN).</summary>
    public bool HasDriverWindowOption => _session is Scanning.IDriverWindowOption;

    /// <summary>The connected scanner cannot scan without its driver's window, so it is always used.</summary>
    public bool DriverWindowRequired => _session is Scanning.IDriverWindowOption { DriverWindowOptional: false };

    /// <summary>Scans go through the driver's own settings window.</summary>
    public bool UseDriverWindow =>
        _session is Scanning.IDriverWindowOption option && (option.UseDriverWindow || !option.DriverWindowOptional);

    /// <summary>
    /// The user's choice for the connected scanner: scan through its driver's own window, or
    /// with the app's settings. Remembered per connection (<see cref="AppPreferences.TwainDriverWindow"/>).
    /// </summary>
    public void SetUseDriverWindow(bool use)
    {
        if (_session is not Scanning.IDriverWindowOption option) return;
        option.UseDriverWindow = use;
        string id = _session.Info.Id;
        bool changed = use ? _driverWindowDevices.Add(id) : _driverWindowDevices.Remove(id);
        if (changed)
        {
            AppPreferencesStore.Update(preferences =>
            {
                preferences.TwainDriverWindow.RemoveAll(entry => entry == id);
                if (use) preferences.TwainDriverWindow.Add(id);
            });
        }
        NotifyAll();
    }

    /// <summary>
    /// Writes the raw device names, how they were grouped, what each connection reports and the
    /// troubleshooter's checks to %LOCALAPPDATA%\CompleteScanner\Logs\devices.txt whenever they
    /// change, so the names real drivers report can be collected to tune <see cref="DeviceMerge"/>
    /// and a user's setup can be read from one file. Best effort.
    /// </summary>
    private void WriteDeviceDiagnostics()
    {
        string report = DiagnosticsText(TroubleshootSnapshot());
        if (report == _lastDeviceReport) return;
        _lastDeviceReport = report;
        try
        {
            string folder = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                                         "CompleteScanner", "Logs");
            Directory.CreateDirectory(folder);
            File.WriteAllText(Path.Combine(folder, "devices.txt"), report);
        }
        catch (Exception e)
        {
            System.Diagnostics.Trace.TraceWarning($"Could not write the device diagnostics: {e.Message}");
        }
    }

    // MARK: Troubleshooter ("Why isn't my scanner listed?")

    /// <summary>A scanner other than the demo scanner is listed; without one the sidebar offers the troubleshooter.</summary>
    public bool HasRealDevices => DeviceGroups.Any(group => !group.Primary.IsDemo);

    /// <summary>The last failed connection or scan (null after one that worked).</summary>
    public ScannerFailure? LastFailure => _lastFailure;

    /// <summary>
    /// <see cref="ErrorMessage"/> is about a scanner that would not connect or scan, so the
    /// error bar offers the troubleshooter. The window clears it when it shows the error.
    /// </summary>
    public bool ErrorSuggestsTroubleshooter { get; set; }

    /// <summary>
    /// What the troubleshooter looks at now: the scanners listed, the last failure, the WIA
    /// service and network as last read, and what each connection adds
    /// (<see cref="IScannerBackendDiagnostics"/>). Read <see cref="ReadSystemStateAsync"/> first
    /// for a fresh service and network state.
    /// </summary>
    public DiscoverySnapshot TroubleshootSnapshot()
    {
        var snapshot = new DiscoverySnapshot
        {
            Platform = TroubleshootPlatform.Windows,
            Devices = [.. DeviceGroups.Select(group => group.Primary)],
            Network = _systemState.Network,
            WiaService = _systemState.Wia,
            LastFailure = _lastFailure,
        };
        return _backends.OfType<IScannerBackendDiagnostics>().Aggregate(snapshot, (s, backend) => backend.AddStatus(s));
    }

    /// <summary>
    /// Reads the WIA service and the network off the UI thread (the network list can be slow to
    /// answer), then rewrites devices.txt when that changes it. Only reads; never changes either.
    /// </summary>
    public async Task ReadSystemStateAsync()
    {
        var system = _system;
        try
        {
            _systemState = await Task.Run(() => (system.WiaService(), system.Network()));
        }
        catch (Exception e)
        {
            // A stand-in that throws: keep what was read before.
            System.Diagnostics.Trace.TraceWarning($"Could not read the system's state: {e.Message}");
        }
        WriteDeviceDiagnostics();
    }

    /// <summary>
    /// The troubleshooter's Refresh: every connection that can looks for scanners again
    /// (<see cref="IScannerBackendDiagnostics.Rescan"/>); the list updates as they answer.
    /// </summary>
    public void RefreshScanners()
    {
        foreach (var backend in _backends.OfType<IScannerBackendDiagnostics>()) backend.Rescan();
        _ = ReadSystemStateAsync();
    }

    /// <summary>
    /// The text of devices.txt and of Copy diagnostics: how the device list was grouped, what
    /// each connection reports, then the troubleshooter's checks for <paramref name="snapshot"/>.
    /// </summary>
    public string DiagnosticsText(DiscoverySnapshot snapshot) =>
        DeviceMerge.DiagnosticsReport(DeviceGroups)
        + string.Concat(_backends.OfType<Scanning.IBackendDiagnostics>()
                                 .Select(b => b.DiagnosticsReport)
                                 .Where(text => !string.IsNullOrEmpty(text)))
        + "\n" + Troubleshooter.Report(snapshot, Troubleshooter.Diagnose(snapshot));

    /// <summary>Copies <see cref="DiagnosticsText"/> to the clipboard; a refusal is reported in <see cref="ErrorMessage"/>.</summary>
    public bool CopyDiagnostics(DiscoverySnapshot snapshot)
    {
        try
        {
            _system.CopyText(DiagnosticsText(snapshot));
            return true;
        }
        catch (Exception e)
        {
            ErrorMessage = $"Copy diagnostics did not work: {FileActionErrors.Describe(e)}";
            NotifyAll();
            return false;
        }
    }

    /// <summary>
    /// Opens the Windows Settings page an action names (Printers &amp; scanners, or Network &amp;
    /// internet); a refusal is reported in <see cref="ErrorMessage"/>. Nothing is changed there.
    /// </summary>
    public bool OpenSystemSettings(TroubleshootAction action)
    {
        try
        {
            _system.OpenSettings(action);
            return true;
        }
        catch (Exception e)
        {
            ErrorMessage = $"{Troubleshooter.Label(action, TroubleshootPlatform.Windows)} did not work: {FileActionErrors.Describe(e)}";
            NotifyAll();
            return false;
        }
    }

    /// <summary>Keeps a failed connection or scan for the troubleshooter (errors that say nothing about the scanner are skipped).</summary>
    private void RecordFailure(string deviceName, Exception error)
    {
        if (Troubleshooter.FailureFrom(deviceName, error) is not { } failure) return;
        _lastFailure = failure;
        // Set right after the error it explains, so the error bar offers the troubleshooter.
        ErrorSuggestsTroubleshooter = true;
        WriteDeviceDiagnostics();
    }

    private void ClearFailure()
    {
        if (_lastFailure is null) return;
        _lastFailure = null;
        WriteDeviceDiagnostics();
    }

    /// <summary>Device selection driven by the user (sidebar click).</summary>
    public void UserSelectDevice(string? id)
    {
        _userPickedDevice = true;
        SelectDevice(id, interactive: true);
    }

    /// <param name="interactive">
    /// The user chose the device just now, so opening it may ask them something (a network
    /// scanner's changed certificate). Automatic selections never ask.
    /// </param>
    private void SelectDevice(string? id, bool interactive = false)
    {
        // Ignore re-clicks on a device that is already connected or connecting.
        if (id == SelectedDeviceId && (_session != null || !_switchTask.IsCompleted)) return;
        SelectedDeviceId = id;
        _selectedEntry = id is null ? null
            : DeviceGroups.SelectMany(g => g.Members).FirstOrDefault(m => m.Id == id) ?? _selectedEntry;
        RefreshDeviceRows();
        _switchGeneration += 1;
        int generation = _switchGeneration;
        var previous = _switchTask;
        _switchTask = RunSwitch();
        NotifyAll();
        return;

        async Task RunSwitch()
        {
            await previous;
            if (_switchGeneration != generation) return;
            await SwitchSession(id, interactive);
        }
    }

    private async Task SwitchSession(string? id, bool interactive)
    {
        if (_session is { } old)
        {
            old.ProgressHandler = null;
            // Abort any in-flight scan so its results can't land after the switch.
            old.CancelScan();
            await old.CloseAsync();
        }
        _session = null;
        Capabilities = null;
        // The preview, marquee and detections belong to the previous device's bed.
        OverviewImage = null;
        LastScanImage = null;
        SelectionRect = null;
        DetectedPhotos = [];
        ShowPhotoReview = false;
        IsReceiptReview = false;
        _photoSourceImages = [];
        CanvasImageChanged();

        if (id is null)
        {
            StatusMessage = "No scanner selected.";
            NotifyAll();
            return;
        }
        var backend = _backends.FirstOrDefault(b => b.Devices.Any(d => d.Id == id));
        if (backend is null)
        {
            StatusMessage = "Scanner is no longer available.";
            NotifyAll();
            return;
        }
        string name = DeviceGroups.SelectMany(g => g.Members).FirstOrDefault(d => d.Id == id)?.Name ?? "scanner";
        StatusMessage = $"Connecting to {name}…";
        NotifyAll();
        try
        {
            var session = backend is Scanning.EsclScannerBackend network
                ? await network.OpenSessionAsync(id, interactive)
                : await backend.OpenSessionAsync(id);
            _certificateRefused.Remove(id);
            if (SelectedDeviceId != id) { await session.CloseAsync(); return; }
            session.ProgressHandler = p => _dispatcher.BeginInvoke(() =>
            {
                // Progress is posted, so a report can arrive after its operation finished (a
                // backend that reports and completes synchronously always does). It would put
                // a stale "Scanning…" over the outcome in the status bar: drop it.
                if (!IsBusy) return;
                Progress = p;
                if (!string.IsNullOrEmpty(p.Message)) StatusMessage = p.Message;
                NotifyAll();
            });
            _session = session;
            // Before reading the capabilities: when that fails (the scanner is off), the session
            // stays and a later scan reads them itself, still with the user's choice.
            if (session is Scanning.IDriverWindowOption option)
            {
                option.UseDriverWindow = _driverWindowDevices.Contains(session.Info.Id);
            }
            var caps = await session.GetCapabilitiesAsync();
            Capabilities = caps;
            ClearFailure();
            var adapted = SettingsAdapter.Adapt(Settings, caps);
            Settings = adapted.Settings;
            // A task the scanner cannot do (the feeder task on a flatbed) ends here.
            SyncTaskFlow();
            StatusMessage = WithNotes($"Ready — {session.Info.Name}", adapted.Notes);
        }
        catch (EsclCertificateException e) when (e.CanTrust)
        {
            // The certificate changed and was not trusted. Not chosen on its own again this
            // session; when the app had chosen it, it moves on to another scanner, and choosing
            // this one in the list shows the certificate.
            _certificateRefused.Add(id);
            StatusMessage = $"Could not connect to {name}.";
            RecordFailure(name, e);
            if (interactive)
            {
                ErrorMessage = e.Message;
            }
            else
            {
                ErrorMessage = e.Message + " To review the new certificate, choose the scanner in the list.";
                if (!_userPickedDevice)
                {
                    _ = _dispatcher.BeginInvoke(() =>
                    {
                        if (!_userPickedDevice && SelectedDeviceId == id && !AutoSwitchMustWait)
                        {
                            SelectDevice(PreferredDefaultDevice());
                        }
                    });
                }
            }
        }
        catch (Exception e)
        {
            ErrorMessage = e.Message;
            StatusMessage = $"Could not connect to {name}.";
            RecordFailure(name, e);
        }
        NotifyAll();
    }

    // MARK: Scanning

    public Task PerformOverview()
    {
        if (_session is not { } session) { NoDevice(); return Task.CompletedTask; }
        // The preview shows the flatbed; a feeder scan would ignore a selection drawn on it.
        if (Settings.Source == ScanSource.DocumentFeeder)
        {
            StatusMessage = "Preview needs the flatbed. Choose Flatbed as the source to preview.";
            NotifyAll();
            return Task.CompletedTask;
        }
        int generation = _switchGeneration;
        // The backend reads the settings on its own thread: hand it a snapshot, never the
        // live object the inspector edits.
        var s = Settings.Clone();
        return RunExclusive(async token =>
        {
            StatusMessage = "Scanning overview…";
            NotifyAll();
            var image = await session.PerformOverviewScanAsync(s);
            // Discard results that arrive after the user switched devices.
            if (_switchGeneration != generation) return;
            ClearFailure();
            token.ThrowIfCancellationRequested();
            OverviewImage = image;
            StatusMessage = "Overview ready — drag on the preview to select an area, then Scan.";
            CanvasImageChanged();
        });
    }

    public Task PerformScan()
    {
        if (_session is not { } session) { NoDevice(); return Task.CompletedTask; }
        int generation = _switchGeneration;
        // One snapshot for the whole operation: the backend reads it on its own thread (and
        // again to tag each page), and processing, history and saving must all agree with
        // what was actually scanned.
        var s = Settings.Clone();
        // The ID card task scans the side its steps are at; once the sides are in, Scan opens
        // the review again.
        bool idCard = TaskCatalog.FlowOf(s) == TaskFlowKind.IdCard;
        PageSide? cardSide = idCard ? IdCardSteps.SideOf(Flow?.Current?.Id) : null;
        if (idCard && cardSide is null)
        {
            OpenIdCardReview();
            return Task.CompletedTask;
        }
        // The backend is asked for a two-sided scan only when its feeder can do one; turning
        // the stack over by hand scans one side at a time, and the steps say which.
        var sides = DocumentSides.Effective(s, Capabilities);
        s.Duplex = sides;
        PageSide? manualSide = sides == DuplexMode.Manual && IsTurningOverByHand && Flow?.Current is { } step
            ? step.Id == DocumentSides.BacksStepId ? PageSide.Back : PageSide.Front
            : null;
        // The flatbed scans the selection, else the paper size's part of the glass; an ID card
        // may lie anywhere on it, so its scans take the whole glass. A copy with Automatic paper
        // scans the part the printer's paper covers (PrepareCopyAsync).
        var selection = s.Source == ScanSource.Flatbed
            ? SelectionRect ?? (!idCard && Capabilities is { } caps ? PaperSizes.FlatbedSelection(s.PaperSize, caps.FlatbedSizeInches) : null)
            : null;
        bool copy = TaskCatalog.FlowOf(s) == TaskFlowKind.Copy;
        // A copy of an area selected on the preview is centred on the paper; of a page, it lies in the corner.
        bool areaSelected = s.Source == ScanSource.Flatbed && SelectionRect is not null;
        return RunExclusive(async token =>
        {
            PrinterSetup? copySetup = null;
            if (copy)
            {
                // The printer goes first: the copy needs one, and its paper says what part of the glass to scan.
                (copySetup, selection) = await PrepareCopyAsync(s, selection);
                if (_switchGeneration != generation) return;
                token.ThrowIfCancellationRequested();
            }
            StatusMessage = "Scanning…";
            // The bar of the previous save makes way for the new scan.
            SavedBarPaths = null;
            NotifyAll();
            var scanned = await session.PerformScanAsync(s, selection);
            // Discard results that arrive after the user switched devices.
            if (_switchGeneration != generation) return;
            if (scanned.Count == 0) throw ScanException.ScanFailed("The scanner returned no pages.");
            ClearFailure();
            // A feeder batch cut short (a jam, a dropped connection) still returns its pages;
            // once they are handled the user is told the stack was not finished.
            var stop = session.LastScanStop;
            // A scanner that fell back to one side (its feeder or driver could not scan both, or
            // its capabilities were never read) delivered one side of each sheet.
            bool twoSided = sides == DuplexMode.Both && session.LastScanDuplex != false;
            token.ThrowIfCancellationRequested();
            StatusMessage = "Processing…";
            NotifyAll();
            // The clean-up stage: two-sided pages in reading order with their sides marked and the
            // backs turned upright, then the blank-page check and the adjustments. Pixel-heavy
            // work runs off the UI thread so the window stays live; the token is checked between
            // pages and steps.
            var arrangement = twoSided ? ScanArrangement.TwoSided
                : manualSide == PageSide.Back ? ScanArrangement.TurnedOverBacks
                : manualSide == PageSide.Front ? ScanArrangement.TurnedOverFronts
                : ScanArrangement.AsScanned;
            var processor = PageProcessor.ForScan(s, arrangement, _orientation, _barcodes);
            var cleaned = await Task.Run(() => processor.Process(scanned, token), token);
            if (_switchGeneration != generation) return;
            token.ThrowIfCancellationRequested();
            var raw = cleaned.Arranged;
            var processed = cleaned.Pages.ToList();
            // " 2 look blank and will be skipped. 3 straightened." after the pages added to the queue.

            // The canvas shows the RAW scan through the live adjustments (only a downsampled
            // copy is retained), and every scanned page is recorded in the session history.
            var (rawPreview, historyItems) = await Task.Run(() =>
            {
                var preview = ScanHistory.MakePreview(raw[^1].Image, CanvasPreviewMaxSide);
                // ID cards are kept out of the history: nothing of them is left once saved or discarded.
                if (idCard) return (preview, new List<HistoryItem>());
                var entries = ScanHistory.MakeEntries(raw, s.Intent, DateTime.Now);
                // The cards only display the bitmap: keep metadata-only entries so each
                // preview's pixels are held once, not twice.
                var items = entries
                    .Select(e => new HistoryItem(
                        new ScanHistoryEntry(e.Date, e.Intent, e.Dpi, HistoryItem.NoPixels, e.PixelSize, e.Id),
                        WpfImageCodec.ToBitmapSource(e.Thumbnail)))
                    .ToList();
                return (preview, items);
            }, token);
            if (_switchGeneration != generation) return;
            token.ThrowIfCancellationRequested();
            if (!idCard) RecordHistory(historyItems);

            switch (TaskCatalog.FlowOf(s))
            {
                case TaskFlowKind.DocumentQueue:
                    if (s.DocumentMultiPage)
                    {
                        // Spill full-resolution pages to disk; keep only previews in the queue. The
                        // spreads book pages were cut from are kept too, to join or split them again.
                        string spoolDirectory = _spool.Directory;
                        var spreads = cleaned.Spreads;
                        var (spooled, spreadSources) = await Task.Run(() =>
                            (SpoolPages(processed, spoolDirectory).Select(p => new PageItem(p)).ToList(),
                             SpoolSpreads(spreads, spoolDirectory)));
                        if (_switchGeneration != generation || token.IsCancellationRequested)
                        {
                            DeleteSpoolFiles(spooled.Select(p => p.Page));
                            DeleteSpreadFiles(spreadSources.Values);
                            if (_switchGeneration != generation) return;
                            token.ThrowIfCancellationRequested();
                        }
                        foreach (var (spreadId, source) in spreadSources) _spreads[spreadId] = source;
                        foreach (var item in spooled) ScannedPages.Add(item);
                        // Pages queued earlier and never read (a reading stopped) are read once the scan is done.
                        if (PageProcessor.ReadsBarcodes(Settings)) _readBarcodesAfterWork = true;
                        RecordCaptures(spooled.Select(item => item.Page.Id));
                        SetLastScan(rawPreview);
                        int n = processed.Count;
                        if (manualSide is { } scannedSide)
                        {
                            AfterTurnedOverScan(scannedSide, n, stopped: stop is not null);
                        }
                        else if (twoSided)
                        {
                            int sheets = processed.Select(p => p.SheetIndex).Distinct().Count();
                            StatusMessage = $"Added {n} page{(n == 1 ? "" : "s")} from {sheets} sheet{(sheets == 1 ? "" : "s")}, both sides — {ScannedPages.Count} in queue. Scan more or {OutputFormats.SaveTitle(Settings.Format)}.";
                        }
                        else if (sides == DuplexMode.Both)
                        {
                            StatusMessage = $"Added {n} page{(n == 1 ? "" : "s")}, one side of each sheet: the scanner did not scan both sides — {ScannedPages.Count} in queue. Scan more or {OutputFormats.SaveTitle(Settings.Format)}.";
                        }
                        else
                        {
                            StatusMessage = $"Added {n} page{(n == 1 ? "" : "s")} — {ScannedPages.Count} in queue. Scan more or {OutputFormats.SaveTitle(Settings.Format)}.";
                        }
                        StatusMessage += QueueScanNote(processed, s.Document);
                        if (PageProcessor.TurnsPagesUpright(s) && !_orientation.IsAvailable) StatusMessage += PageTurns.UnavailableNote;
                    }
                    else
                    {
                        SetLastScan(rawPreview);
                        await SaveImmediately(processed, s, token);
                        RecordCaptures(processed.Select(page => page.Id));
                    }
                    break;
                case TaskFlowKind.PhotoSplit:
                    SetLastScan(rawPreview);
                    StatusMessage = "Detecting photos…";
                    NotifyAll();
                    var found = await Task.Run(() =>
                    {
                        var all = new List<PhotoItem>();
                        foreach (var page in processed)
                        {
                            token.ThrowIfCancellationRequested();
                            all.AddRange(SplitPhotos(page, s, token).Select(p => new PhotoItem(p)));
                        }
                        return all;
                    }, token);
                    if (_switchGeneration != generation) return;
                    token.ThrowIfCancellationRequested();
                    // Keep every sheet's full-resolution source while the review is open so
                    // manual crop corrections can re-extract from the correct page.
                    _photoSourceImages = processed.ToDictionary(p => p.Id, p => p.Image);
                    DetectedPhotos = new ObservableCollection<PhotoItem>(found);
                    IsReceiptReview = false;
                    RecordCaptures(found.Select(item => item.Photo.Id));
                    ShowPhotoReview = found.Count > 0;
                    if (!ShowPhotoReview) _photoSourceImages = [];
                    StatusMessage = $"Found {found.Count} photo{(found.Count == 1 ? "" : "s")} on the bed.";
                    break;
                case TaskFlowKind.IdCard:
                    if (!IsIdCardFlow)
                    {
                        DropIdCardScanOutsideTask();
                        break;
                    }
                    SetLastScan(rawPreview);
                    await CaptureIdCardSide(cardSide!.Value, processed[^1], selection, generation, token);
                    break;
                case TaskFlowKind.Copy:
                    SetLastScan(rawPreview);
                    await PrintCopyPages(processed, s, copySetup!, areaSelected, token);
                    RecordCaptures(processed.Select(page => page.Id));
                    break;
                case TaskFlowKind.ReceiptSplit:
                    SetLastScan(rawPreview);
                    await ShowReceipts(processed, s, generation, token);
                    break;
            }
            if (stop is not null) ErrorMessage = stop.Message(raw.Count);
            if (Capabilities is null) await ReadCapabilitiesAfterScan(session, generation);
            NotifyAll();
        });
    }

    /// <summary>
    /// The capabilities could not be read on connect (the scanner was off, say) yet a scan just
    /// worked: read them now, so the inspector shows what the scanner can do and the next scan
    /// knows whether its feeder scans both sides. Still unknown when that fails too.
    /// </summary>
    private async Task ReadCapabilitiesAfterScan(IScannerSession session, int generation)
    {
        ScannerCapabilities caps;
        try
        {
            caps = await session.GetCapabilitiesAsync();
        }
        catch (Exception e) when (e is not OperationCanceledException)
        {
            return;
        }
        if (_switchGeneration != generation || !ReferenceEquals(_session, session) || Capabilities is not null) return;
        Capabilities = caps;
        var adapted = SettingsAdapter.Adapt(Settings, caps);
        Settings = adapted.Settings;
        SyncTaskFlow();
        StatusMessage = WithNotes(StatusMessage, adapted.Notes);
    }

    private static List<DetectedPhoto> SplitPhotos(ScannedPage page, ScanSettings s, CancellationToken token)
    {
        if (!s.PhotoAutoSplit) return [WholePagePhoto(page)];
        var options = new PhotoDetectorOptions
        {
            MinPhotoSideInches = s.PhotoMinSideInches,
            EdgeInsetPixels = s.PhotoCropInsetPixels,
        };
        var regions = PhotoDetector.DetectRegions(page.Image, page.Dpi, options);
        if (regions.Count == 0) return [WholePagePhoto(page)];
        var photos = new List<DetectedPhoto>();
        foreach (var region in regions)
        {
            token.ThrowIfCancellationRequested();
            if (PhotoDetector.ExtractPhoto(page.Image, region, s.PhotoAutoDeskew) is { } image)
            {
                photos.Add(new DetectedPhoto(region, image, page.Dpi, sourcePageId: page.Id, colorMode: page.ColorMode));
            }
        }
        return photos;
    }

    private static DetectedPhoto WholePagePhoto(ScannedPage page)
    {
        double w = page.Image.Width, h = page.Image.Height;
        var region = new DetectedPhotoRegion(new PointD(w / 2, h / 2), new SizeD(w, h), 0);
        return new DetectedPhoto(region, page.Image, page.Dpi, sourcePageId: page.Id, colorMode: page.ColorMode);
    }

    /// <summary>
    /// Cancel whatever is running: the hardware if it is mid-scan, AND the software phases
    /// (processing, photo detection, OCR, PDF build, exports) — either may be the one running.
    /// </summary>
    public void CancelScan()
    {
        _session?.CancelScan();
        _operationCts?.Cancel();
    }

    // MARK: Saving

    /// <summary>
    /// Saves the collected pages as one file: a PDF (with its text beside it when
    /// <see cref="OutputOptions.AlsoSaveText"/> is on), or a Word document or text file when that
    /// is the format chosen (<see cref="OutputFormats.QueueFormat"/>). OCR reads each page once.
    /// </summary>
    public Task SavePdf()
    {
        if (ScannedPages.Count == 0) return Task.CompletedTask;
        var s = Settings.Clone();
        return RunExclusive(async token =>
        {
            // Let page rotations that were clicked before the save land first.
            await Settled(_pageRotateChain);
            var queued = ScannedPages.Select(p => p.Page).ToList();
            if (queued.Count == 0) return;
            // Pages flagged in the strip (blank, separator sheets, or skipped by hand) are left out
            // now, and only now; the documents are the ones the strip shows.
            var plan = SavePlan.Make(queued, s.Document);
            if (plan.IsEmpty)
            {
                ErrorMessage = PageFilter.NothingToSaveMessage;
                StatusMessage = DocumentSplitter.QueueSummary(queued, s.Document) + ".";
                return;
            }
            if (plan.IsSplit)
            {
                await SaveDocuments(plan, s, queued, token);
                return;
            }
            var document = plan.Documents[0];
            var pages = document.Pages.ToList();
            string left = plan.LeftOutNote();
            var format = OutputFormats.QueueFormat(s.Format);
            if (format.IsTextFormat())
            {
                StatusMessage = "Reading the text of the pages…";
                NotifyAll();
                var (written, hasText) = await WriteTextDocument(pages, format, OutputPath(s, format.FileExtension(), label: document.Label), s, token);
                MarkSaved([written]);
                DeleteSpoolFiles(queued);
                ScannedPages.Clear();
                ResetFlow();
                StatusMessage = TextExport.SavedMessage(format, pages.Count, Path.GetFileName(written), hasText) + left;
                RunAfterSave(s.Output.AfterSave, [written]);
                return;
            }
            var text = s.Output.AlsoSaveText ? new PdfText() : null;
            StatusMessage = s.PdfSearchable || text is not null ? "Running OCR and building PDF…" : "Building PDF…";
            NotifyAll();
            string path = await WritePdfAtomically(pages, s, OutputPath(s, "pdf", label: document.Label), token, text);
            string? textPath = text is null ? null : await WriteTextBeside(path, text);
            MarkSaved([path]);
            DeleteSpoolFiles(queued);
            ScannedPages.Clear();
            ResetFlow();
            string textNote = textPath is null ? "" : TextExport.SidecarSuffix(Path.GetFileName(textPath));
            StatusMessage = $"Saved {pages.Count}-page PDF: {Path.GetFileName(path)}{PdfSizeSuffix()}{textNote}{left}";
            RunAfterSave(s.Output.AfterSave, [path]);
        });
    }

    /// <summary>
    /// Used when DocumentMultiPage is off: write each scan to disk as soon as it lands. The
    /// pages are held nowhere else, so the files are the only full-resolution copy: a failure
    /// or Cancel part-way keeps every file already written and reports the partial result. A Word
    /// document or text file is one file: when its text cannot be read or it cannot be written (or
    /// the save is cancelled) the pages are put in the queue instead.
    /// </summary>
    private async Task SaveImmediately(List<ScannedPage> pages, ScanSettings s, CancellationToken token)
    {
        var saved = new List<string>();
        string note = "";
        if (s.Format.IsTextFormat())
        {
            string written;
            bool hasText;
            try
            {
                (written, hasText) = await WriteTextDocument(pages, s.Format, OutputPath(s, s.Format.FileExtension()), s, token);
            }
            catch (Exception e)
            {
                // Nothing was written: the pages go to the queue rather than being lost, to be
                // saved once the text can be read or the file written, or in another format.
                await KeepInQueue(pages);
                bool cancelled = IsCancellation(e);
                if (!cancelled) ErrorMessage = e.Message;
                StatusMessage = TextExport.KeptInQueue(s.Format, pages.Count, cancelled,
                                                       textUnreadable: e is TextUnreadableException);
                return;
            }
            MarkSaved([written]);
            StatusMessage = TextExport.SavedMessage(s.Format, pages.Count, Path.GetFileName(written), hasText);
            RunAfterSave(s.Output.AfterSave, [written]);
            return;
        }
        if (s.Format == OutputFormat.Pdf)
        {
            // These pages are held nowhere else: without the password they wait in the queue.
            try { ProtectionFor(s); }
            catch (PasswordNotGivenException)
            {
                await KeepInQueue(pages);
                StatusMessage = PdfProtection.KeptInQueueMessage(pages.Count);
                return;
            }
            var text = s.Output.AlsoSaveText ? new PdfText() : null;
            saved = [await WritePdfAtomically(pages, s, OutputPath(s, "pdf"), token, text)];
            string? textPath = text is null ? null : await WriteTextBeside(saved[0], text);
            note = PdfSizeSuffix() + (textPath is null ? "" : TextExport.SidecarSuffix(Path.GetFileName(textPath)));
        }
        else
        {
            try
            {
                foreach (var page in pages)
                {
                    token.ThrowIfCancellationRequested();
                    string path = OutputPath(s, s.Format.FileExtension());
                    saved.Add(await Task.Run(() =>
                        WpfImageCodec.SaveAsNew(page.Image, path, s.Format, page.Dpi, s.JpegQuality, page.ColorMode)));
                }
            }
            catch (Exception e) when (saved.Count > 0)
            {
                MarkSaved(saved);
                string kept = $"{saved.Count} of {pages.Count} pages ({string.Join(", ", saved.Select(Path.GetFileName))})";
                if (IsCancellation(e))
                {
                    StatusMessage = $"Cancelled — saved {kept}.";
                    return;
                }
                throw new IOException($"Saved {kept}; the rest could not be written: {e.Message}", e);
            }
        }
        MarkSaved(saved);
        StatusMessage = $"Saved {string.Join(", ", saved.Select(Path.GetFileName))}{note}";
        RunAfterSave(s.Output.AfterSave, saved);
    }

    /// <summary>Spool <paramref name="pages"/> and add them to the queue, as a collected scan is.</summary>
    private async Task KeepInQueue(List<ScannedPage> pages)
    {
        string spoolDirectory = _spool.Directory;
        var spooled = await Task.Run(() => SpoolPages(pages, spoolDirectory).Select(p => new PageItem(p)).ToList());
        foreach (var item in spooled) ScannedPages.Add(item);
    }

    public Task SaveReviewedPhotos()
    {
        if (!DetectedPhotos.Any(p => p.Photo.Included)) { CancelPhotoReview(); return Task.CompletedTask; }
        // Receipts are named by their date and saved as PDFs or images (AppViewModel.Receipts.cs).
        if (IsReceiptReview) return SaveReceipts();
        var s = Settings.Clone();
        var format = OutputFormats.ImageFormatOrJpeg(s.Format);
        return RunExclusive(async token =>
        {
            // A crop correction applied just before saving must be in the files.
            await Settled(_recropChain);
            var photos = DetectedPhotos.Where(p => p.Photo.Included).Select(p => p.Photo).ToList();
            if (photos.Count == 0) return;
            var saved = new List<string>();
            await WriteImagesRollingBack(saved, async () =>
            {
                for (int index = 0; index < photos.Count; index++)
                {
                    token.ThrowIfCancellationRequested();
                    var photo = photos[index];
                    string path = OutputPath(s, format.FileExtension(), index + 1);
                    StatusMessage = $"Saving photo {index + 1} of {photos.Count}…";
                    NotifyAll();
                    saved.Add(await Task.Run(() =>
                    {
                        var image = photo.RotationQuarterTurns == 0
                            ? photo.Image
                            : ImagePipeline.Rotate(photo.Image, photo.RotationQuarterTurns);
                        // The mode the photo was scanned in: a black & white TIFF is G4.
                        return WpfImageCodec.SaveAsNew(image, path, format, photo.Dpi, s.JpegQuality, photo.ColorMode);
                    }));
                }
            });
            MarkSaved(saved);
            DetectedPhotos = [];
            ShowPhotoReview = false;
            _photoSourceImages = [];
            ResetFlow();
            StatusMessage = $"Saved {saved.Count} photo{(saved.Count == 1 ? "" : "s")} to {s.DestinationPath}";
            RunAfterSave(s.Output.AfterSave, saved);
        });
    }

    /// <summary>
    /// Run a multi-file export of the photo review as all-or-nothing: if it is cancelled or
    /// fails part-way, the files it already wrote are removed again, so the batch leaves
    /// nothing behind and can simply be retried from the review (which stays open) without
    /// duplicates. Once every file is written the export counts as done, even if Cancel
    /// arrives at that moment.
    /// </summary>
    private static async Task WriteImagesRollingBack(List<string> written, Func<Task> export, List<string>? alsoWritten = null)
    {
        try
        {
            await export();
        }
        catch
        {
            foreach (string path in alsoWritten is null ? written : written.Concat(alsoWritten))
            {
                try { File.Delete(path); } catch { /* best effort */ }
            }
            written.Clear();
            alsoWritten?.Clear();
            throw;
        }
    }

    public void CancelPhotoReview()
    {
        bool receipts = IsReceiptReview;
        DetectedPhotos = [];
        ShowPhotoReview = false;
        IsReceiptReview = false;
        _photoSourceImages = [];
        ResetFlow();
        StatusMessage = receipts ? "Receipts discarded." : "Photo batch discarded.";
        NotifyAll();
        EndOfWork();
    }

    // MARK: Photo crop correction

    /// <summary>The full-resolution page a detected photo was extracted from (null once the review is closed).</summary>
    public RgbaImage? PhotoSource(DetectedPhoto photo) =>
        photo.SourcePageId is { } id && _photoSourceImages.TryGetValue(id, out var image) ? image : null;

    /// <summary>
    /// Manual crop correction from the review: re-extract one photo from its full-resolution
    /// source page with a user-adjusted region (image pixel coordinates, top-left origin).
    /// The extraction runs off the UI thread; the photo keeps its id, inclusion and rotation.
    /// Returns false when nothing changed (busy, review closed, or extraction failed).
    /// </summary>
    public Task<bool> RecropPhoto(Guid id, DetectedPhotoRegion region)
    {
        if (IsBusy) return Task.FromResult(false);
        var item = DetectedPhotos.FirstOrDefault(p => p.Photo.Id == id);
        if (item is null || PhotoSource(item.Photo) is not { } source) return Task.FromResult(false);
        // Defensive cap (the editor already keeps crops on the page): a region far larger
        // than the page would only allocate a huge, mostly blank image.
        double diagonal = Math.Sqrt((double)source.Width * source.Width + (double)source.Height * source.Height);
        if (!(region.Size.Width >= 1 && region.Size.Height >= 1
              && region.Size.Width <= diagonal && region.Size.Height <= diagonal))
        {
            return Task.FromResult(false);
        }
        var batch = DetectedPhotos;
        bool deskew = Settings.PhotoAutoDeskew;
        bool receipt = IsReceiptReview;
        int dpi = item.Photo.Dpi;
        var edited = new DetectedPhotoRegion(region.Center, region.Size, region.AngleDegrees, region.Id);
        // Re-crops apply strictly in the order they were requested.
        var previous = _recropChain;
        var task = Run();
        _recropChain = Settled(task);
        NotifyAll();
        return task;

        async Task<bool> Run()
        {
            await Settled(previous);
            StatusMessage = "Updating crop…";
            NotifyAll();
            (RgbaImage, BitmapSource)? result;
            try
            {
                result = await Task.Run(() =>
                {
                    // A receipt is cut out upright and cleaned up again, as it was found.
                    var image = receipt
                        ? ReceiptDetector.ExtractEnhanced(source, edited, dpi)
                        : PhotoDetector.ExtractPhoto(source, edited, deskew);
                    return image is null
                        ? ((RgbaImage, BitmapSource)?)null
                        : (image, WpfImageCodec.ToThumbnail(image, PhotoItem.ThumbnailMaxSide));
                });
            }
            catch (Exception e)
            {
                ErrorMessage = $"The crop could not be applied: {e.Message}";
                StatusMessage = "Ready.";
                NotifyAll();
                return false;
            }
            // The batch may have been saved, discarded or replaced meanwhile.
            if (!ReferenceEquals(batch, DetectedPhotos)) return false;
            int index = IndexOfPhoto(id);
            if (index < 0) return false;
            if (result is not { } r)
            {
                StatusMessage = "That crop could not be extracted.";
                NotifyAll();
                return false;
            }
            // Rebuild from the CURRENT item so Keep/rotate changes made meanwhile survive.
            var current = DetectedPhotos[index];
            DetectedPhotos[index] = new PhotoItem(current.Photo.Recropped(edited, r.Item1), r.Item2);
            StatusMessage = "Crop updated.";
            NotifyAll();
            return true;
        }
    }

    /// <summary>True while a crop correction is still being extracted.</summary>
    public bool IsRecropPending => !_recropChain.IsCompleted;

    /// <summary>A task that completes when <paramref name="task"/> does, but never faults.</summary>
    private static async Task Settled(Task task)
    {
        try { await task; } catch { /* reported by the operation itself */ }
    }

    private int IndexOfPhoto(Guid id)
    {
        for (int i = 0; i < DetectedPhotos.Count; i++)
        {
            if (DetectedPhotos[i].Photo.Id == id) return i;
        }
        return -1;
    }

    // MARK: Page queue

    public void RemovePage(Guid id)
    {
        // Never mutate the queue (or unlink spool files) while a save is reading from it.
        if (IsBusy) return;
        var item = ScannedPages.FirstOrDefault(p => p.Page.Id == id);
        if (item is null) return;
        DeleteSpoolFiles([item.Page]);
        ScannedPages.Remove(item);
        NotifyAll();
    }

    public void MovePage(Guid id, int offset)
    {
        if (IsBusy) return;
        int idx = -1;
        for (int i = 0; i < ScannedPages.Count; i++)
        {
            if (ScannedPages[i].Page.Id == id) { idx = i; break; }
        }
        if (idx < 0) return;
        int newIdx = idx + offset;
        if (newIdx < 0 || newIdx >= ScannedPages.Count) return;
        ScannedPages.Move(idx, newIdx);
        NotifyAll();
    }

    /// <summary>
    /// Rotate a queued page 90° clockwise. The in-memory preview (and its strip thumbnail)
    /// turns right away; the full-resolution spool file stays untouched and the accumulated
    /// rotation is applied when the PDF is written. Rotations are chained so rapid clicks
    /// accumulate in order.
    /// </summary>
    public Task RotatePage(Guid id)
    {
        if (IsBusy) return Task.CompletedTask;
        var previous = _pageRotateChain;
        var task = Run();
        _pageRotateChain = Settled(task);
        return task;

        async Task Run()
        {
            await Settled(previous);
            var item = ScannedPages.FirstOrDefault(p => p.Page.Id == id);
            if (item is null) return;
            PageItem rotated;
            try
            {
                rotated = await Task.Run(() => new PageItem(item.Page.RotatedClockwise()));
            }
            catch (Exception e)
            {
                ErrorMessage = $"The page could not be rotated: {e.Message}";
                NotifyAll();
                return;
            }
            // The page may have been removed (or the queue saved) meanwhile. It may also have been
            // kept or skipped, or put in order with its stack: the turned pixels take the page's
            // facts as they are now.
            int index = IndexOfPage(id);
            if (index < 0) return;
            var current = ScannedPages[index].Page;
            ScannedPages[index] = new PageItem(rotated.Page.CopyMeta(current), rotated.Thumbnail, Settings.Document);
            NotifyAll();
        }
    }

    private int IndexOfPage(Guid id)
    {
        for (int i = 0; i < ScannedPages.Count; i++)
        {
            if (ScannedPages[i].Page.Id == id) return i;
        }
        return -1;
    }

    /// <summary>
    /// One click on a queued page's Keep or Skip button: the page is saved or left out, whatever
    /// the blank-page setting says; a second click goes back to what the setting says.
    /// </summary>
    public void TogglePageInclusion(Guid id)
    {
        if (IsBusy) return;
        int index = IndexOfPage(id);
        if (index < 0) return;
        var item = ScannedPages[index];
        var facts = ScannedPages.Select(p => PageFacts.Of(p.Page, Settings.Document)).ToList();
        // Separator pages count: a separator page kept is saved, and its sheet no longer splits.
        var page = item.Page.WithInclusion(DocumentSplitter.ToggledInclusion(facts, index, Settings.Document));
        // Updated in place, not replaced: a replaced item gets a new container in the strip,
        // and the Keep or Skip button the user pressed (and its keyboard focus) goes with the old one.
        item.Options = Settings.Document;
        item.Page = page;
        // A document whose first page is now left out (or now saved) keeps its name.
        CarryDocumentLabels(facts);
        var queued = ScannedPages.Select(p => p.Page).ToList();
        string summary = DocumentSplitter.QueueSummary(queued, Settings.Document);
        StatusMessage = DocumentSplitter.Plan(queued, Settings.Document).Pages[index].Role != PageRole.Content
            ? $"Page {index + 1} will be left out when you save. {summary}."
            : $"Page {index + 1} will be saved. {summary}.";
        NotifyAll();
    }

    /// <summary>
    /// One click on a cropped or straightened page's swap button: the page as scanned is shown,
    /// and saved, instead; a second click brings the cropped and straightened page back. The other
    /// version is read from its spool file off the UI thread; swaps and turns run one after another
    /// (<see cref="RotatePage"/>), and a save waits for them.
    /// </summary>
    public Task TogglePageGeometry(Guid id)
    {
        if (IsBusy) return Task.CompletedTask;
        var previous = _pageRotateChain;
        var task = Run();
        _pageRotateChain = Settled(task);
        return task;

        async Task Run()
        {
            await Settled(previous);
            var item = ScannedPages.FirstOrDefault(p => p.Page.Id == id);
            if (item is null || !item.Page.CanSwapVersions) return;
            var page = item.Page;
            (RgbaImage Shown, System.Windows.Media.Imaging.BitmapSource Thumbnail) other;
            try
            {
                other = await Task.Run(() =>
                {
                    var shown = OtherVersionPreview(page);
                    return (shown, WpfImageCodec.ToThumbnail(shown, PageItem.ThumbnailMaxSide));
                });
            }
            catch (Exception e)
            {
                // Removed while its file was read: the file may be gone (nothing to report), or
                // still there because the read held it open when the page's files were deleted.
                if (IndexOfPage(id) < 0)
                {
                    DeleteSpoolFiles([page]);
                    return;
                }
                ErrorMessage = $"The page could not be switched: {e.Message}";
                NotifyAll();
                return;
            }
            // The page may have been removed, saved or kept meanwhile: the swap applies to the page
            // as it is now, if it still shows the same version. A removed page's files are deleted
            // again, as the read may have held one open when the removal tried.
            int index = IndexOfPage(id);
            if (index < 0)
            {
                DeleteSpoolFiles([page]);
                return;
            }
            var current = ScannedPages[index].Page;
            if (!current.CanSwapVersions || current.ShowsOriginal != page.ShowsOriginal) return;
            var swapped = current.WithVersionsSwapped(other.Shown);
            ScannedPages[index] = new PageItem(swapped, other.Thumbnail, Settings.Document);
            StatusMessage = PageCorrections.SwapNote(swapped, index + 1);
            NotifyAll();
        }
    }

    /// <summary>Whether pages can be turned upright: text recognition can read them (a recognizer language is installed).</summary>
    public bool CanTurnPagesUpright => _orientation.IsAvailable;

    /// <summary>
    /// One click on a turned page's turn button: the turn is undone and the page saved the way it was
    /// scanned; a second click turns it upright again. The preview turns at once, the spool file
    /// through the page's rotation when it is saved (<see cref="ScannedPage.WithUprightToggled"/>);
    /// it runs after the swaps and turns clicked before it (<see cref="RotatePage"/>).
    /// </summary>
    public Task TogglePageUpright(Guid id)
    {
        if (IsBusy) return Task.CompletedTask;
        var previous = _pageRotateChain;
        var task = Run();
        _pageRotateChain = Settled(task);
        return task;

        async Task Run()
        {
            await Settled(previous);
            var item = ScannedPages.FirstOrDefault(p => p.Page.Id == id);
            if (item?.Page.Upright is null) return;
            PageItem toggled;
            try
            {
                toggled = await Task.Run(() => new PageItem(item.Page.WithUprightToggled()));
            }
            catch (Exception e)
            {
                ErrorMessage = $"The page could not be turned: {e.Message}";
                NotifyAll();
                return;
            }
            // The page may have been removed, saved or kept meanwhile: the turned pixels take the
            // page's facts as they are now, with the turn's new state.
            int index = IndexOfPage(id);
            if (index < 0) return;
            var current = ScannedPages[index].Page;
            var page = toggled.Page.CopyMeta(current).WithUpright(toggled.Page.Upright);
            ScannedPages[index] = new PageItem(page, toggled.Thumbnail, Settings.Document);
            StatusMessage = PageTurns.ToggleNote(page, index + 1);
            NotifyAll();
        }
    }

    /// <summary>
    /// The version of <paramref name="page"/> not shown, as the queue shows a page: its pixels in
    /// memory, or a preview of its spool file turned like the page.
    /// </summary>
    private static RgbaImage OtherVersionPreview(ScannedPage page)
    {
        var other = page.Alternate ?? throw new InvalidOperationException("The page has no other version.");
        if (other.Image is { } image) return image;
        if (other.FilePath is not { } path) throw new InvalidOperationException("The other version of the page is no longer available.");
        var preview = ScanHistory.MakePreview(WpfImageCodec.Load(path), SpoolPreviewMaxSide);
        return ImagePipeline.Rotate(preview, page.RotationQuarterTurns);
    }

    public void ClearPages()
    {
        if (IsBusy) return;
        DeleteSpoolFiles(ScannedPages.Select(p => p.Page));
        ScannedPages.Clear();
        ResetFlow();
        StatusMessage = "Page queue cleared.";
        NotifyAll();
    }

    // MARK: Presets

    /// <summary>
    /// Replaces the settings with the preset's, fitted to the connected scanner. A preset saved
    /// while a task was active brings that task (and its banner) back.
    /// </summary>
    public void ApplyPreset(Preset preset)
    {
        var adapted = SettingsAdapter.Adapt(preset.Settings, Capabilities);
        Settings = adapted.Settings;
        bool wasBusy = IsBusy;
        SettingsEdited();
        string applied = WithNotes($"Applied preset “{preset.Name}”.", adapted.Notes);
        // A reading of the queued pages the preset started (split at barcode or QR sheets) says so.
        StatusMessage = !wasBusy && IsBusy ? $"{applied} {StatusMessage}" : applied;
        NotifyAll();
    }

    // MARK: Tasks

    /// <summary>
    /// Sets everything up for a task picked on the start screen: its settings are laid over the
    /// current ones (the destination folder is kept) and fitted to the connected scanner, and
    /// its guided steps start. Refused (false) while an operation runs, or when the connected
    /// scanner cannot do the task (the reason is shown).
    /// </summary>
    public bool StartTask(ScanTask task)
    {
        if (IsBusy) return false;
        var availability = TaskCatalog.Availability(task, Capabilities, HasPrinter);
        if (!availability.IsAvailable)
        {
            ErrorMessage = TaskCatalog.UnavailableMessage(task, availability.Reason ?? "");
            // A printer installed since they were read makes the card available once read again.
            if (task == ScanTask.Copy && !HasPrinter) PrintersMayHaveChanged();
            NotifyAll();
            return false;
        }
        var adapted = SettingsAdapter.Adapt(TaskCatalog.Apply(task, Settings), Capabilities);
        Settings = adapted.Settings;
        // Fresh steps, even for the same task: nothing of an ID card is kept, on the stage either.
        if (IsIdCardFlow || HasIdCardCaptures || ShowIdCardReview) ClearIdCard(clearCanvas: true);
        Flow = null;
        SettingsEdited();
        StatusMessage = WithNotes($"Ready for “{TaskCatalog.Definition(task).Title}”.", adapted.Notes);
        // Printers come and go: the Copy task reads them again.
        if (task == ScanTask.Copy) _ = RefreshPrintersAsync();
        NotifyAll();
        return true;
    }

    /// <summary>
    /// Leaves the active task: the settings stay as they are, without the task's banner, so
    /// the scan screen is back to plain settings. Refused while an operation runs: a scan under
    /// way belongs to the task's steps.
    /// </summary>
    public void ExitTask()
    {
        if (IsBusy || Settings.TaskId is null) return;
        Settings.TaskId = null;
        SettingsEdited();
        NotifyAll();
    }

    /// <summary>
    /// Stops turning stacks over by hand (the close button of its banner without a task):
    /// feeder scans are one-sided again. Pages already in the queue stay.
    /// </summary>
    public void ScanOneSideOnly()
    {
        if (IsBusy || Settings.Duplex == DuplexMode.Off) return;
        Settings.Duplex = DuplexMode.Off;
        SettingsEdited();
        StatusMessage = "Scanning one side of each sheet.";
        NotifyAll();
    }

    /// <summary>
    /// Keeps the guided steps in line with the settings: a task the settings no longer fit
    /// (the mode was changed by hand, or the scanner lacks the task's source) ends; turning
    /// stacks over by hand gets its own steps (<see cref="TaskCatalog.GuidedSteps"/>), whatever
    /// the task; an active task gets its steps. A task id this version does not know stays
    /// stored, without steps. Steps already under way are kept while they still apply.
    /// </summary>
    private void SyncTaskFlow()
    {
        bool wasIdCard = IsIdCardFlow;
        if (Settings.Task is { } task && !TaskCatalog.Fits(task, Settings)) Settings.TaskId = null;
        bool manual = DocumentSides.UsesManualSteps(Settings, Capabilities);
        (ScanTask?, bool) key = manual ? (null, true) : (Settings.Task, false);
        if (TaskCatalog.GuidedSteps(Settings, Capabilities) is not { } steps)
        {
            Flow = null;
            _flowKey = default;
            SidesMismatch = null;
        }
        else if (Flow is null || _flowKey != key)
        {
            Flow = new TaskFlow(steps);
            _flowKey = key;
            SidesMismatch = null;
        }
        else
        {
            return;
        }
        // Steps started afresh, or none: the sides of an ID card scanned before go, and the stage
        // no longer shows the card (also a scan whose card was not found, or a preview of the glass).
        if (wasIdCard || HasIdCardCaptures || ShowIdCardReview) ClearIdCard(clearCanvas: true);
    }

    /// <summary>Back to the first step with nothing captured; a stack's count mismatch goes with it.</summary>
    private void ResetFlow()
    {
        Flow?.Reset();
        SidesMismatch = null;
    }

    // MARK: Turning a stack over by hand

    /// <summary>
    /// After a scan of a stack turned over by hand: the fronts move the steps on to the backs,
    /// unless the feeder stopped early (<paramref name="stopped"/>, a jam): then the steps stay
    /// at the fronts so the rest of them can be scanned (<see cref="FinishFronts"/> moves on).
    /// The backs put the stack in reading order when they pair up with the fronts, otherwise
    /// the mismatch is shown (<see cref="SidesMismatch"/>).
    /// </summary>
    private void AfterTurnedOverScan(PageSide side, int count, bool stopped)
    {
        if (Flow is null) return;
        if (side == PageSide.Front)
        {
            if (stopped)
            {
                StatusMessage = $"Scanned {count} front side{(count == 1 ? "" : "s")} before the feeder stopped. {MoreFrontsPrompt}";
                return;
            }
            Flow.Advance();
            StatusMessage = $"Scanned {count} front side{(count == 1 ? "" : "s")}. Turn the stack over and scan the back sides.";
            return;
        }
        CollateTurnedOverStack(combineAnyway: false);
    }

    /// <summary>What to do while the fronts are scanned a part at a time.</summary>
    private const string MoreFrontsPrompt =
        "Load the sheets not scanned yet and scan more fronts; once every front is scanned, choose Done with fronts.";

    /// <summary>Every front is scanned: on to the backs (after a batch cut short, or more fronts).</summary>
    public void FinishFronts()
    {
        if (IsBusy || !CanFinishFronts || Flow is null) return;
        int fronts = QueuedCaptures(DocumentSides.FrontsStepId);
        Flow.Advance();
        StatusMessage = $"{fronts} front side{(fronts == 1 ? "" : "s")} scanned. Turn the stack over and scan the back sides.";
        NotifyAll();
    }

    /// <summary>
    /// Back to the fronts before any back was scanned, keeping the fronts scanned so far: for a
    /// stack larger than the feeder holds, scanned a part at a time.
    /// </summary>
    public void ScanMoreFronts()
    {
        if (IsBusy || !CanScanMoreFronts || Flow is null) return;
        // Retake makes the fronts the current step; the fronts already scanned are kept, in order.
        foreach (var id in Flow.Retake(DocumentSides.FrontsStepId)) Flow.Record(DocumentSides.FrontsStepId, id);
        SidesMismatch = null;
        StatusMessage = MoreFrontsPrompt;
        NotifyAll();
    }

    /// <summary>How many captures of a step are still in the queue.</summary>
    private int QueuedCaptures(string stepId)
    {
        if (Flow is null) return 0;
        var queued = ScannedPages.Select(item => item.Page.Id).ToHashSet();
        return Flow.Captures(stepId).Count(queued.Contains);
    }

    /// <summary>
    /// Puts the fronts and backs of the stack in reading order in the queue, unless their counts
    /// differ and <paramref name="combineAnyway"/> is false: then the mismatch is shown and the
    /// steps stay at the backs.
    /// </summary>
    private void CollateTurnedOverStack(bool combineAnyway)
    {
        if (Flow is null) return;
        var collation = DocumentSides.CollateQueue([.. ScannedPages.Select(item => item.Page.Id)],
                                                   Flow.Captures(DocumentSides.FrontsStepId),
                                                   Flow.Captures(DocumentSides.BacksStepId));
        var counts = collation.Interleave;
        if (counts.Mismatch && !combineAnyway)
        {
            SidesMismatch = counts.MismatchMessage;
            StatusMessage = $"{SidesMismatch}. Scan the rest of the back sides, scan them again, or combine the pages as they are.";
            return;
        }
        var items = ScannedPages.ToDictionary(item => item.Page.Id);
        var ordered = collation.Order.Select(id => collation.Positions.TryGetValue(id, out var position)
            ? new PageItem(items[id].Page.WithSide(position.Side, position.SheetIndex), items[id].Thumbnail)
            : items[id]).ToList();
        ScannedPages.Clear();
        foreach (var item in ordered) ScannedPages.Add(item);
        ResetFlow();
        int sheets = Math.Max(counts.Fronts, counts.Backs);
        int pages = counts.Fronts + counts.Backs;
        StatusMessage = $"Put {sheets} sheet{(sheets == 1 ? "" : "s")} in order ({pages} page{(pages == 1 ? "" : "s")}) — {ScannedPages.Count} in queue. Scan another stack or {OutputFormats.SaveTitle(Settings.Format)}.";
    }

    /// <summary>The backs did not pair up with the fronts, but the pages are combined as they are (the extra pages at the end).</summary>
    public void CombineSidesAnyway()
    {
        if (IsBusy || !AwaitingBacks) return;
        CollateTurnedOverStack(combineAnyway: true);
        NotifyAll();
    }

    /// <summary>The back sides scanned so far leave the queue, to be scanned again.</summary>
    public void ScanBacksAgain()
    {
        if (IsBusy || !AwaitingBacks || Flow is null) return;
        RemoveQueuedPages(Flow.Retake(DocumentSides.BacksStepId));
        SidesMismatch = null;
        StatusMessage = "Load the turned-over stack in the feeder again and scan the back sides.";
        NotifyAll();
    }

    /// <summary>
    /// The stack stays one-sided: the backs scanned so far leave the queue, the fronts stay
    /// (in scan order), and the next scan starts a new stack.
    /// </summary>
    public void KeepFrontsOnly()
    {
        if (IsBusy || !AwaitingBacks || Flow is null) return;
        RemoveQueuedPages(Flow.Captures(DocumentSides.BacksStepId));
        int fronts = Flow.Captures(DocumentSides.FrontsStepId).Count(id => ScannedPages.Any(item => item.Page.Id == id));
        ResetFlow();
        StatusMessage = $"Kept {fronts} front side{(fronts == 1 ? "" : "s")} — {ScannedPages.Count} in queue. Scan another stack or {OutputFormats.SaveTitle(Settings.Format)}.";
        NotifyAll();
    }

    private void RemoveQueuedPages(IReadOnlyCollection<Guid> ids)
    {
        if (ids.Count == 0) return;
        var set = ids.ToHashSet();
        var removed = ScannedPages.Where(item => set.Contains(item.Page.Id)).ToList();
        DeleteSpoolFiles(removed.Select(item => item.Page));
        foreach (var item in removed) ScannedPages.Remove(item);
    }

    /// <summary>Notes the current step of the active task what a scan produced (page or photo ids).</summary>
    private void RecordCaptures(IEnumerable<Guid> ids)
    {
        if (Flow?.Current is not { } step) return;
        foreach (var id in ids) Flow.Record(step.Id, id);
    }

    /// <summary>
    /// Leaves out the back of an ID card with nothing on it (<see cref="CanSkipStep"/>), after which
    /// the card's review opens. The backs of a stack turned over by hand are not skipped here: Keep
    /// fronts only (<see cref="KeepFrontsOnly"/>) leaves them out.
    /// </summary>
    public void SkipStep()
    {
        if (IsBusy || !CanSkipStep || Flow is null) return;
        Flow.Skip();
        SetIdCardSide(PageSide.Back, null, null);
        StatusMessage = "No back side. Check the front, then save.";
        OpenIdCardReview();
        NotifyAll();
    }

    // MARK: ID card

    /// <summary>
    /// One side of the ID card was scanned: the card is found on the scan and cut out straight
    /// (<see cref="IdCardDetector"/>; a back that does not stand out takes the front's place when
    /// both scans cover the same part of the glass), the step records it and moves on (past a back
    /// already scanned or skipped, when the front was scanned again), and once the sides are in, the
    /// review opens. The scan is kept in memory only while the side is, so its crop can be fixed;
    /// nothing is spooled. <paramref name="selection"/> is the part of the glass scanned (null: all of it).
    /// </summary>
    private async Task CaptureIdCardSide(PageSide side, ScannedPage page, RectD? selection, int generation, CancellationToken token)
    {
        StatusMessage = "Finding the card…";
        NotifyAll();
        var area = new IdCardScanArea(page.Dpi, new SizeD(page.Image.Width, page.Image.Height), selection);
        var fallback = side == PageSide.Back && IdCardFront is { } front
                       && front.Photo.SourcePageId is { } frontScan && _idCardScanAreas.TryGetValue(frontScan, out var frontArea)
            ? IdCardDetector.FrontPlaceOnBack(front.Photo.Region, frontArea, area)
            : null;
        var (item, note) = await Task.Run(() =>
        {
            var pick = IdCardDetector.Detect(page.Image, page.Dpi, fallback);
            token.ThrowIfCancellationRequested();
            var image = IdCardDetector.Extract(page.Image, pick);
            var photo = new DetectedPhoto(pick.Region, image, page.Dpi, sourcePageId: page.Id, colorMode: page.ColorMode);
            return (new PhotoItem(photo, WpfImageCodec.ToThumbnail(image, PhotoItem.ThumbnailMaxSide)), pick.Note);
        }, token);
        if (_switchGeneration != generation) return;
        token.ThrowIfCancellationRequested();
        if (!IsIdCardFlow)
        {
            DropIdCardScanOutsideTask();
            return;
        }
        _idCardSources[page.Id] = page.Image;
        _idCardScanAreas[page.Id] = area;
        SetIdCardSide(side, item, note);
        if (Flow is { } flow)
        {
            flow.Record(IdCardSteps.StepId(side), item.Photo.Id);
            flow.Advance();
            if (flow.Current?.Id == IdCardSteps.BackStepId
                && (IdCardBack is not null || flow.IsSkipped(IdCardSteps.BackStepId)))
            {
                flow.Advance();
            }
        }
        string check = note is null ? "" : $" {note}";
        if (Flow?.Current?.Id == IdCardSteps.ReviewStepId)
        {
            StatusMessage = $"{(side == PageSide.Front ? "Front" : "Back")} scanned. Check the sides, then save.{check}";
            OpenIdCardReview();
        }
        else
        {
            StatusMessage = $"Front scanned. Turn the card over where it lies and scan the back, or skip it.{check}";
        }
    }

    /// <summary>
    /// A scan of the ID card finished outside its steps (the task ended while it ran): nothing of
    /// it is kept, a side never stays held without the task, and the stage no longer shows the card.
    /// </summary>
    private void DropIdCardScanOutsideTask()
    {
        ClearIdCard(clearCanvas: true);
        StatusMessage = "The ID card task ended during the scan. Nothing of the card was kept.";
    }

    /// <summary>Puts a side in place (null: none), dropping the scan the one it replaces came from.</summary>
    private void SetIdCardSide(PageSide side, PhotoItem? item, string? note)
    {
        var old = side == PageSide.Front ? IdCardFront : IdCardBack;
        if (side == PageSide.Front)
        {
            IdCardFront = item;
            IdCardFrontNote = note;
        }
        else
        {
            IdCardBack = item;
            IdCardBackNote = note;
        }
        if (old?.Photo.SourcePageId is { } id
            && IdCardFront?.Photo.SourcePageId != id && IdCardBack?.Photo.SourcePageId != id)
        {
            _idCardSources.Remove(id);
            _idCardScanAreas.Remove(id);
        }
    }

    /// <summary>Opens the review of the ID card's sides, once there is a front.</summary>
    private void OpenIdCardReview()
    {
        if (IdCardFront is null) return;
        ShowIdCardReview = true;
        _ = RefreshIdCardPreview();
        NotifyAll();
    }

    /// <summary>Resolution of the page picture in the review.</summary>
    private const int IdCardPreviewDpi = 40;

    /// <summary>
    /// Draws the page the sides go on again (after a turn, a new crop, swapping the sides or another
    /// paper), small and off the UI thread, with what it holds and whether it is at real size. A
    /// picture overtaken by a newer one is dropped.
    /// </summary>
    public async Task RefreshIdCardPreview()
    {
        int revision = ++_idCardPreviewRevision;
        var paper = IdCardPaperSize;
        var paperInches = PaperSizes.Inches(paper)!.Value;
        if (IdCardFront is not { } front)
        {
            IdCardPreview = null;
            IdCardLayoutCaption = "";
            IdCardSizeWarning = null;
            NotifyAll();
            return;
        }
        var frontPhoto = front.Photo;
        var backPhoto = IdCardBack?.Photo;
        int frontTurns = frontPhoto.RotationQuarterTurns, backTurns = backPhoto?.RotationQuarterTurns ?? 0;
        (BitmapSource Bitmap, IdCardLayoutResult Layout) result;
        try
        {
            result = await Task.Run(() =>
            {
                var f = IdCardSideOf(frontPhoto, frontTurns);
                var b = backPhoto is null ? null : IdCardSideOf(backPhoto, backTurns);
                var layout = IdCardLayout.Place(f.Inches, b?.Inches, paperInches);
                var page = IdCardComposer.Compose(f, b, IdCardPreviewDpi, paperInches);
                return (WpfImageCodec.ToBitmapSource(page), layout);
            });
        }
        catch (Exception e)
        {
            if (revision != _idCardPreviewRevision) return;
            ErrorMessage = $"The page could not be drawn: {e.Message}";
            NotifyAll();
            return;
        }
        if (revision != _idCardPreviewRevision) return;
        IdCardPreview = result.Bitmap;
        IdCardLayoutCaption = IdCardLayout.Caption(paper, backPhoto is not null, result.Layout.ScaledToFit);
        IdCardSizeWarning = result.Layout.ScaledToFit ? IdCardLayout.NotRealSizeMessage : null;
        NotifyAll();
    }

    /// <summary>A side as it is saved: turned as the user turned it.</summary>
    private static IdCardSide IdCardSideOf(DetectedPhoto photo, int quarterTurns) =>
        new(quarterTurns == 0 ? photo.Image : ImagePipeline.Rotate(photo.Image, quarterTurns), photo.Dpi);

    /// <summary>The scan a side of the ID card was cut from (null once the sides are saved or discarded).</summary>
    public RgbaImage? IdCardSource(PageSide side) =>
        (side == PageSide.Front ? IdCardFront : IdCardBack)?.Photo.SourcePageId is { } id
        && _idCardSources.TryGetValue(id, out var image) ? image : null;

    /// <summary>Turns a side of the ID card 90° clockwise.</summary>
    public void RotateIdCardSide(PageSide side)
    {
        if (IsBusy || (side == PageSide.Front ? IdCardFront : IdCardBack) is not { } item) return;
        item.RotateClockwise();
        _ = RefreshIdCardPreview();
        NotifyAll();
    }

    /// <summary>The front becomes the back and the back the front (scanned in the wrong order).</summary>
    public void SwapIdCardSides()
    {
        if (IsBusy || IdCardFront is null || IdCardBack is null) return;
        (IdCardFront, IdCardBack) = (IdCardBack, IdCardFront);
        (IdCardFrontNote, IdCardBackNote) = (IdCardBackNote, IdCardFrontNote);
        StatusMessage = "Front and back swapped.";
        _ = RefreshIdCardPreview();
        NotifyAll();
    }

    /// <summary>
    /// Scans a side of the ID card again, or the back after all: the review closes, the side goes
    /// and the steps go back to it. The other side stays.
    /// </summary>
    public void RetakeIdCardSide(PageSide side)
    {
        if (IsBusy || !IsIdCardFlow || Flow is null) return;
        Flow.Retake(IdCardSteps.StepId(side));
        SetIdCardSide(side, null, null);
        ShowIdCardReview = false;
        IdCardPreview = null;
        _idCardPreviewRevision++;
        StatusMessage = Flow.Current?.Prompt ?? "";
        NotifyAll();
        // The only side held went: a scanner switch that waited for the card is made now.
        EndOfWork();
    }

    /// <summary>
    /// Manual crop correction of a side of the ID card: cut out again from its scan with a region
    /// the user adjusted (full-resolution pixels, top-left origin), turned straight, off the UI
    /// thread. The side keeps its turn. False when nothing changed (busy, the side scanned again,
    /// swapped or saved meanwhile, or nothing could be cut out). Saving waits for it.
    /// </summary>
    public Task<bool> RecropIdCardSide(PageSide side, DetectedPhotoRegion region)
    {
        if (IsBusy) return Task.FromResult(false);
        var item = side == PageSide.Front ? IdCardFront : IdCardBack;
        if (item is null || IdCardSource(side) is not { } source) return Task.FromResult(false);
        double diagonal = Math.Sqrt((double)source.Width * source.Width + (double)source.Height * source.Height);
        if (!(region.Size.Width >= 1 && region.Size.Height >= 1
              && region.Size.Width <= diagonal && region.Size.Height <= diagonal))
        {
            return Task.FromResult(false);
        }
        var edited = new DetectedPhotoRegion(region.Center, region.Size, region.AngleDegrees, region.Id);
        var previous = _recropChain;
        var task = Run();
        _recropChain = Settled(task);
        NotifyAll();
        return task;

        async Task<bool> Run()
        {
            await Settled(previous);
            StatusMessage = "Updating crop…";
            NotifyAll();
            (RgbaImage, BitmapSource)? result;
            try
            {
                result = await Task.Run(() =>
                {
                    var image = PhotoDetector.ExtractPhoto(source, edited, deskew: true);
                    return image is null
                        ? ((RgbaImage, BitmapSource)?)null
                        : (image, WpfImageCodec.ToThumbnail(image, PhotoItem.ThumbnailMaxSide));
                });
            }
            catch (Exception e)
            {
                ErrorMessage = $"The crop could not be applied: {e.Message}";
                StatusMessage = "Ready.";
                NotifyAll();
                return false;
            }
            if (!ReferenceEquals(side == PageSide.Front ? IdCardFront : IdCardBack, item)) return false;
            if (result is not { } r)
            {
                StatusMessage = "That crop could not be cut out.";
                NotifyAll();
                return false;
            }
            SetIdCardSide(side, new PhotoItem(item.Photo.Recropped(edited, r.Item1), r.Item2), null);
            StatusMessage = "Crop updated.";
            _ = RefreshIdCardPreview();
            NotifyAll();
            return true;
        }
    }

    /// <summary>The paper the ID card is laid out on (saved with the settings); the page is drawn again.</summary>
    public void SetIdCardPaper(IdCardPaper paper)
    {
        if (Settings.TaskOptions.IdCardPaper == paper) return;
        Settings.TaskOptions.IdCardPaper = paper;
        SettingsEdited();
        _ = RefreshIdCardPreview();
        NotifyAll();
    }

    /// <summary>Whether each side of the ID card is also saved as an image of its own (saved with the settings).</summary>
    public void SetIdCardSaveSidesAsImages(bool save)
    {
        if (Settings.TaskOptions.IdCardSaveSidesAsImages == save) return;
        Settings.TaskOptions.IdCardSaveSidesAsImages = save;
        SettingsEdited();
        NotifyAll();
    }

    /// <summary>
    /// Saves the ID card: both sides on one page at real size (<see cref="IdCardComposer"/>) on the
    /// paper chosen, as a PDF or an image in the chosen format, and each side as an image of its own
    /// when asked for. All or nothing: a failed or cancelled save removes what it wrote, and the
    /// review stays open. Once saved, the sides and their scans are dropped from memory and the
    /// stage is cleared, and the steps start again.
    /// </summary>
    public Task SaveIdCard()
    {
        if (IdCardFront is null) return Task.CompletedTask;
        var s = Settings.Clone();
        // The card is a picture: a PDF or an image, never a text format.
        var pageFormat = OutputFormats.PageFormat(s.Format);
        var paper = IdCardPaperSize;
        var paperInches = PaperSizes.Inches(paper)!.Value;
        return RunExclusive(async token =>
        {
            // A crop correction applied just before saving must be in the files.
            await Settled(_recropChain);
            if (IdCardFront is not { } frontItem) return;
            var frontPhoto = frontItem.Photo;
            var backPhoto = IdCardBack?.Photo;
            int frontTurns = frontPhoto.RotationQuarterTurns, backTurns = backPhoto?.RotationQuarterTurns ?? 0;
            StatusMessage = "Saving the ID card…";
            NotifyAll();
            // The page at the scan's resolution, at most 600 dpi; each side's own image keeps the scan's.
            int dpi = IdCardComposer.PageDpi(frontPhoto.Dpi);
            // The sides are what they were scanned as, whatever the color mode is now.
            var pageMode = IdCardComposer.PageColorMode(frontPhoto.ColorMode, backPhoto?.ColorMode);
            var (front, back, page) = await Task.Run(() =>
            {
                var f = IdCardSideOf(frontPhoto, frontTurns);
                var b = backPhoto is null ? null : IdCardSideOf(backPhoto, backTurns);
                return (f, b, IdCardComposer.Compose(f, b, dpi, paperInches));
            }, token);
            var saved = new List<string>();
            await WriteImagesRollingBack(saved, async () =>
            {
                if (pageFormat == OutputFormat.Pdf)
                {
                    saved.Add(await WritePdfAtomically([new ScannedPage(page, dpi, pageMode)], s, OutputPath(s, "pdf"), token));
                }
                else
                {
                    string path = OutputPath(s, pageFormat.FileExtension());
                    saved.Add(await Task.Run(() => WpfImageCodec.SaveAsNew(page, path, pageFormat, dpi, s.JpegQuality, pageMode), token));
                }
                if (!s.TaskOptions.IdCardSaveSidesAsImages) return;
                var sideFormat = OutputFormats.ImageFormatOrJpeg(s.Format);
                string folder = Path.GetDirectoryName(saved[0])!;
                string baseName = Path.GetFileNameWithoutExtension(saved[0]);
                foreach (var (side, image, mode) in back is null
                             ? new[] { (PageSide.Front, front, frontPhoto.ColorMode) }
                             : new[] { (PageSide.Front, front, frontPhoto.ColorMode), (PageSide.Back, back, backPhoto!.ColorMode) })
                {
                    token.ThrowIfCancellationRequested();
                    string sidePath = NamingTemplate.UniquePath(folder, IdCardComposer.SideFileBase(baseName, side),
                                                                sideFormat.FileExtension());
                    saved.Add(await Task.Run(() => WpfImageCodec.SaveAsNew(image.Image, sidePath, sideFormat, image.Dpi, s.JpegQuality, mode)));
                }
            });
            MarkSaved(saved);
            ClearIdCard(clearCanvas: true);
            ResetFlow();
            string sizeNote = pageFormat == OutputFormat.Pdf ? PdfSizeSuffix() : "";
            StatusMessage = saved.Count == 1
                ? $"Saved the ID card on one {paper.Label()} page: {Path.GetFileName(saved[0])}{sizeNote}"
                : $"Saved the ID card on one {paper.Label()} page: {Path.GetFileName(saved[0])}{sizeNote}, and each side as an image";
            RunAfterSave(s.Output.AfterSave, saved);
        });
    }

    /// <summary>Drops the ID card's sides without saving them, and starts the steps again.</summary>
    public void DiscardIdCard()
    {
        if (IsBusy) return;
        ClearIdCard(clearCanvas: true);
        ResetFlow();
        StatusMessage = "ID card discarded. Nothing of it was kept.";
        NotifyAll();
        EndOfWork();
    }

    /// <summary>
    /// Drops everything of the ID card from memory: its sides, the scans they came from, the review
    /// and its page and, with <paramref name="clearCanvas"/>, the preview and the last scan on the
    /// stage, which show the card too.
    /// </summary>
    private void ClearIdCard(bool clearCanvas)
    {
        IdCardFront = null;
        IdCardBack = null;
        IdCardFrontNote = null;
        IdCardBackNote = null;
        _idCardSources.Clear();
        _idCardScanAreas.Clear();
        ShowIdCardReview = false;
        IdCardPreview = null;
        IdCardLayoutCaption = "";
        IdCardSizeWarning = null;
        _idCardPreviewRevision++;
        if (clearCanvas && (OverviewImage is not null || LastScanImage is not null))
        {
            OverviewImage = null;
            LastScanImage = null;
            SelectionRect = null;
            CanvasImageChanged();
        }
        // A scanner switch that waited for the card is made now, after whatever dropped it
        // (it may be in the middle of a switch already).
        if (_autoSwitchDeferred) _ = _dispatcher.BeginInvoke(new Action(EndOfWork));
    }

    private static string WithNotes(string message, IReadOnlyList<SettingsNote> notes) =>
        notes.Count == 0 ? message : $"{message} {string.Join(" ", notes.Select(n => n.Message))}";

    public void SaveCurrentAsPreset(string name)
    {
        string trimmed = name.Trim();
        if (trimmed.Length == 0) return;
        Presets.Add(new Preset(trimmed, Settings.Clone()));
        _presetStore.Save([.. Presets]);
        NotifyAll();
    }

    public void DeletePreset(Guid id)
    {
        if (Presets.FirstOrDefault(p => p.Id == id) is { } preset) Presets.Remove(preset);
        _presetStore.Save([.. Presets]);
        NotifyAll();
    }

    // MARK: Live preview

    private void SetLastScan(RgbaImage preview)
    {
        LastScanImage = preview;
        CanvasImageChanged();
    }

    /// <summary>The overview or last scan was replaced: re-render right away.</summary>
    private void CanvasImageChanged()
    {
        _canvasRevision++;
        RequestCanvasRender(debounce: false);
    }

    private CanvasRenderKey CurrentRenderKey() =>
        new(_canvasRevision, Settings.Adjustments.Clone(), Settings.ColorMode);

    /// <summary>
    /// Schedule a render of <see cref="CanvasImage"/> through the current adjustments. Slider
    /// edits are debounced; only one render runs at a time and a result that a newer edit
    /// has superseded is dropped.
    /// </summary>
    private void RequestCanvasRender(bool debounce)
    {
        if (CanvasImage is null)
        {
            _renderTimer.Stop();
            _renderedKey = null;
            if (CanvasBitmap is not null)
            {
                CanvasBitmap = null;
                NotifyAll();
            }
            return;
        }
        if (_renderedKey == CurrentRenderKey() && !_renderInFlight)
        {
            _renderTimer.Stop();
            return;
        }
        _renderTimer.Stop();
        if (debounce) _renderTimer.Start();
        else StartCanvasRender();
    }

    private async void StartCanvasRender()
    {
        if (_renderInFlight)
        {
            _renderQueued = true;
            return;
        }
        if (CanvasImage is not { } baseImage) return;
        var key = CurrentRenderKey();
        if (key == _renderedKey) return;
        _renderInFlight = true;
        BitmapSource? rendered = null;
        try
        {
            rendered = await Task.Run(() =>
            {
                var down = ScanHistory.MakePreview(baseImage, CanvasPreviewMaxSide);
                var adjusted = ImagePipeline.Apply(key.Adjustments, down, key.ColorMode);
                return WpfImageCodec.ToBitmapSource(adjusted);
            });
        }
        catch
        {
            // A failed preview render just leaves the previous one up.
        }
        finally
        {
            _renderInFlight = false;
        }
        bool current = key == CurrentRenderKey() && ReferenceEquals(baseImage, CanvasImage);
        if (current && rendered is not null)
        {
            CanvasBitmap = rendered;
            _renderedKey = key;
            NotifyAll();
        }
        if (_renderQueued || !current)
        {
            _renderQueued = false;
            if (CanvasImage is null) RequestCanvasRender(debounce: false);
            else if (CurrentRenderKey() != _renderedKey && !_renderTimer.IsEnabled) StartCanvasRender();
        }
    }

    // MARK: Helpers

    private void RecordHistory(List<HistoryItem> items)
    {
        foreach (var item in items) _historyItems[item.Entry.Id] = item;
        ScanHistory.Record(_history, items.Select(i => i.Entry).ToList());
        var keep = _history.Select(e => e.Id).ToHashSet();
        foreach (var stale in _historyItems.Keys.Where(k => !keep.Contains(k)).ToList())
        {
            _historyItems.Remove(stale);
        }
        History.Clear();
        foreach (var entry in _history) History.Add(_historyItems[entry.Id]);
    }

    private void MarkSaved(List<string> paths)
    {
        LastSavedPaths = paths;
        SavedRevision++;
        SavedBarPaths = paths.Count > 0 ? [.. paths] : null;
        SavedBarText = SavedSummary(paths);
        SavedBarNoun = Settings.Intent == ScanIntent.Photo ? "photos" : IsReceiptFlow ? "receipts" : "files";
    }

    /// <summary>"Scan 3.pdf (412 KB)" for one file (the size for PDFs), "3 files in Scans" for several.</summary>
    private string SavedSummary(IReadOnlyList<string> paths)
    {
        if (paths.Count == 1)
        {
            bool pdf = Path.GetExtension(paths[0]).Equals(".pdf", StringComparison.OrdinalIgnoreCase);
            return Path.GetFileName(paths[0]) + (pdf ? PdfSizeSuffix() : "");
        }
        string folder = paths.Count > 0 ? Path.GetFileName(Path.GetDirectoryName(paths[0]) ?? "") : "";
        return folder.Length > 0 ? $"{paths.Count} files in {folder}" : $"{paths.Count} files";
    }

    // MARK: Saved files: open, share, copy

    /// <summary>The main window's handle, for the share window and the Open with dialog; zero without one.</summary>
    private static IntPtr MainWindowHandle() =>
        Application.Current?.MainWindow is { } window ? new WindowInteropHelper(window).Handle : IntPtr.Zero;

    /// <summary>Hides the bar of the last save.</summary>
    public void DismissSavedBar()
    {
        if (SavedBarPaths is null) return;
        SavedBarPaths = null;
        NotifyAll();
    }

    /// <summary>The actions the bar offers for the last save's files.</summary>
    public IReadOnlyList<FileAction> SavedBarActions => SaveActions.Offered(SavedBarPaths?.Count ?? 0);

    /// <summary>
    /// Opens, shows, shares, emails or copies saved files (the Saved tab and the bar after a
    /// save). Nothing leaves the PC here: sharing and email open the share window, where the
    /// user picks where the files go. A file that is gone, or an action Windows refuses, is
    /// reported in the InfoBar. Open and Open with use the first file. Returns whether the
    /// action was carried out.
    /// </summary>
    public bool RunFileAction(FileAction action, IReadOnlyList<string> paths)
    {
        if (paths.Count == 0) return false;
        var missing = paths.Where(path => !File.Exists(path)).ToList();
        if (missing.Count > 0)
        {
            ErrorMessage = missing.Count == 1
                ? $"{Path.GetFileName(missing[0])} is no longer in its folder. It may have been moved, renamed or deleted."
                : $"{missing.Count} of the files are no longer in their folder. They may have been moved, renamed or deleted.";
            NotifyAll();
            return false;
        }
        try
        {
            switch (action)
            {
                case FileAction.Open:
                    _fileActions.Open(paths[0]);
                    break;
                case FileAction.OpenWith:
                    _fileActions.OpenWith(paths[0]);
                    break;
                case FileAction.Reveal:
                    _fileActions.Reveal(paths);
                    break;
                case FileAction.Share:
                    Send(SaveActions.ShareRoute(_fileActions.SendProbe), paths);
                    break;
                case FileAction.Email:
                    Send(SaveActions.EmailRoute(_fileActions.SendProbe), paths);
                    break;
                case FileAction.Copy:
                    var content = SaveActions.ClipboardContentFor(paths);
                    _fileActions.Copy(content);
                    StatusMessage = paths.Count == 1
                        ? $"Copied {Path.GetFileName(paths[0])}{(content.ImageFile is null ? "" : " and its picture")} to the clipboard."
                        : $"Copied {paths.Count} files to the clipboard.";
                    break;
            }
        }
        catch (Exception e)
        {
            ErrorMessage = $"{action.Label().TrimEnd('…')} did not work: {FileActionErrors.Describe(e)}";
            NotifyAll();
            return false;
        }
        NotifyAll();
        return true;
    }

    private void Send(SendRoute route, IReadOnlyList<string> paths)
    {
        switch (route)
        {
            case SendRoute.Compose:
                _fileActions.ComposeEmail(paths);
                break;
            case SendRoute.ShareSheet:
                _fileActions.Share(paths, SaveActions.ShareTitle(paths));
                break;
            case SendRoute.ShowInFolder:
                _fileActions.Reveal(paths);
                StatusMessage = SaveActions.ShowInFolderMessage;
                break;
        }
    }

    /// <summary>
    /// The after-save action of the settings the files were saved with, once a save has
    /// finished (never after a cancelled or partial one). A refusal is reported; the save stands.
    /// </summary>
    private void RunAfterSave(AfterSaveAction action, IReadOnlyList<string> saved)
    {
        if (SaveActions.Plan(action, saved) is { } step) RunFileAction(step.FileAction, step.Paths);
    }

    private void NoDevice()
    {
        ErrorMessage = "No scanner is connected. Select a device in the sidebar (or use the Demo Scanner).";
        NotifyAll();
    }

    /// <summary>Long side of the in-memory preview of a spooled page.</summary>
    private const int SpoolPreviewMaxSide = 1600;

    /// <summary>
    /// Write each full-resolution page to a spool PNG and return queue entries that carry
    /// only a preview in memory. A page whose spill fails is kept fully in memory instead. The
    /// page as scanned, kept by crop and straighten, gets a spool file of its own (and keeps its
    /// pixels in memory when that fails), so one click can show it.
    /// </summary>
    private static List<ScannedPage> SpoolPages(List<ScannedPage> pages, string spoolDirectory)
    {
        Directory.CreateDirectory(spoolDirectory);
        return pages.Select(page =>
        {
            string path = Path.Combine(spoolDirectory, $"{page.Id}.png");
            try
            {
                WpfImageCodec.Save(page.Image, path, OutputFormat.Png, page.Dpi, 1.0);
            }
            catch
            {
                return page;
            }
            var preview = ScanHistory.MakePreview(page.Image, SpoolPreviewMaxSide);
            var spooled = page.WithImage(preview, filePath: path, fullPixelSize: new SizeD(page.Image.Width, page.Image.Height));
            if (page.Alternate is { Image: { } other })
            {
                string otherPath = Path.Combine(spoolDirectory, $"{page.Id}-other.png");
                try
                {
                    WpfImageCodec.Save(other, otherPath, OutputFormat.Png, page.Dpi, 1.0);
                    spooled = spooled.WithAlternate(new PageVersion(null, otherPath, new SizeD(other.Width, other.Height)));
                }
                catch
                {
                    // Kept in memory: the page can still be shown as scanned.
                }
            }
            return spooled;
        }).ToList();
    }

    /// <summary>
    /// The recognized text of a PDF's pages, collected while the PDF is written for the text file
    /// beside it (<see cref="OutputOptions.AlsoSaveText"/>), so OCR reads each page once.
    /// </summary>
    private sealed class PdfText
    {
        public List<OcrPage> Pages { get; } = [];
        /// <summary>The OCR error of the first page whose text could not be read; no text file is written then.</summary>
        public string? Problem { get; set; }
    }

    /// <summary>
    /// OCR (when searchable, or when <paramref name="text"/> collects the text; never when the lines
    /// were read beforehand, <paramref name="knownLines"/>, one per page) + JPEG-encode each
    /// page as the PDF size plans it, then write the PDF through
    /// PdfBuilder.WriteNewFile, which builds it under a hidden temp name and moves it into
    /// place — a failed, interrupted or cancelled build never leaves a truncated PDF at the
    /// destination, and an existing file is never replaced. The token is checked before
    /// every page and passed to the writer. Returns the path written.
    /// </summary>
    private async Task<string> WritePdfAtomically(List<ScannedPage> pages, ScanSettings s, string path,
                                                  CancellationToken token, PdfText? text = null,
                                                  IReadOnlyList<IReadOnlyList<OcrLine>?>? knownLines = null)
    {
        // A protected PDF's password is asked for before any page is read or written.
        var protection = ProtectionFor(s);
        var inputs = await PdfPageInputs(pages, s, token, text, knownLines);

        StatusMessage = "Writing PDF…";
        NotifyAll();
        // Protected with the password when that option is on, else PDF/A when the archival option
        // is; titled with the file's name (WriteNewFile retitles the file when it has to take
        // another free name).
        var options = PdfWriteOptions.For(s.Output, Path.GetFileNameWithoutExtension(path), protection);
        string written = await Task.Run(() => PdfBuilder.WriteNewFile(inputs, path, progress: null, token, options), token);
        LastPdfProtected = options.IsProtected;
        try { LastPdfBytes = new FileInfo(written).Length; }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { LastPdfBytes = null; }
        return written;
    }

    /// <summary>
    /// The pages as a PDF stores them (<see cref="WritePdfAtomically"/>, and pages added to an
    /// existing PDF): each one read at full resolution with its rotation, read by OCR when the
    /// text layer or <paramref name="text"/> asks for it (unless <paramref name="knownLines"/> were
    /// read beforehand), and encoded as the PDF size plans it (JPEG, or G4 for black &amp; white).
    /// </summary>
    private async Task<List<PdfPageInput>> PdfPageInputs(List<ScannedPage> pages, ScanSettings s, CancellationToken token,
                                                         PdfText? text = null,
                                                         IReadOnlyList<IReadOnlyList<OcrLine>?>? knownLines = null)
    {
        var inputs = new List<PdfPageInput>();
        for (int i = 0; i < pages.Count; i++)
        {
            token.ThrowIfCancellationRequested();
            var page = pages[i];
            // Spilled pages hold only a preview in memory — reload the full-resolution
            // pixels one page at a time; PreparePage applies the page's rotation.
            var prepared = await Task.Run(() => PdfBuilder.PreparePage(page, SpoolImage(page)), token);
            var image = prepared.Image;
            IReadOnlyList<OcrLine>? lines = null;
            if (knownLines is not null)
            {
                // Read beforehand (the receipts' one OCR pass per save): no OCR here.
                lines = i < knownLines.Count ? knownLines[i] : null;
            }
            else if (s.PdfSearchable || text is { Problem: null })
            {
                StatusMessage = $"OCR page {i + 1} of {pages.Count}…";
                NotifyAll();
                // If OCR fails for a page, the PDF is still produced without a text layer (and
                // without the text file beside it). Cancel stops waiting at once (the recognizer
                // has no cancellation of its own; its late result is simply ignored).
                try { lines = await _ocrService.RecognizeLinesAsync(image).WaitAsync(token); }
                catch (OperationCanceledException) { throw; }
                catch (Exception e)
                {
                    lines = null;
                    if (text is not null) text.Problem ??= e.Message;
                }
                if (lines is not null && text is { Problem: null })
                {
                    text.Pages.Add(OcrPage.Of(lines, prepared.PixelWidth, prepared.PixelHeight, page.Dpi));
                }
            }
            // The PDF size decides how the page is stored (PdfImageEncoding): OCR above has
            // read the full pixels; the stored image may be downsampled and gray, and a black &
            // white page is CCITT G4. The page keeps its physical size either way.
            PdfImageData stored = await Task.Run(() =>
            {
                int imageDpi = PdfImageEncoding.EffectiveDpi(image.Width, prepared.PixelWidth, page.Dpi);
                var plan = PdfImageEncoding.Plan(page.ColorMode, imageDpi, s.Output.PdfSize, image);
                var pixels = PdfImageEncoding.Downsample(image, imageDpi, plan);
                return plan.IsBilevel
                    ? PdfCcittImage.Encode(pixels)
                    : (PdfImageData)new PdfJpegImage(WpfImageCodec.EncodeJpeg(pixels, plan.TargetDpi, plan.Quality, plan.IsGray));
            }, token);
            inputs.Add(new PdfPageInput(stored, prepared.PixelWidth, prepared.PixelHeight, page.Dpi,
                                        s.PdfSearchable ? lines : null));
        }
        return inputs;
    }

    /// <summary>
    /// The password the PDFs of this save are protected with: null when the option is off; else
    /// the one given earlier in this save, or asked for now (<see cref="AskPdfPassword"/>). No
    /// answer throws <see cref="PasswordNotGivenException"/>, a cancellation: nothing is saved
    /// unprotected. Kept nowhere but here, and wiped when the save ends (<see cref="ForgetPdfPassword"/>).
    /// </summary>
    private PdfProtection? ProtectionFor(ScanSettings s)
    {
        if (!s.Output.Protect) return null;
        if (_savePassword is { } given) return given;
        _savePassword = AskPdfPassword?.Invoke() ?? throw new PasswordNotGivenException();
        return _savePassword;
    }

    /// <summary>Wipes the password of the save that just ended.</summary>
    private void ForgetPdfPassword()
    {
        _savePassword?.Dispose();
        _savePassword = null;
    }

    /// <summary>A save that needed a password got none: handled as a cancellation, with its own message.</summary>
    private sealed class PasswordNotGivenException() : OperationCanceledException(PdfProtection.NotSavedMessage);

    /// <summary>
    /// The text file beside a PDF just saved, with the PDF's name (the next free one when that is
    /// taken). Returns its path; null when the text could not be read or written, which
    /// <see cref="ErrorMessage"/> then says: the PDF is saved either way.
    /// </summary>
    private async Task<string?> WriteTextBeside(string pdfPath, PdfText text)
    {
        if (text.Problem is { } problem)
        {
            ErrorMessage = TextExport.SidecarFailed(problem);
            return null;
        }
        try
        {
            byte[] bytes = TextExport.Encode(text.Pages);
            return await Task.Run(() => TextExport.WriteNewFile(bytes, Path.ChangeExtension(pdfPath, "txt")));
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            ErrorMessage = TextExport.SidecarFailed(e.Message);
            return null;
        }
    }

    /// <summary>
    /// Reads the text of every page with OCR, on full-resolution pixels with the page's rotation,
    /// and writes it as a Word document or a text file (<paramref name="format"/>) under a hidden
    /// temporary name moved into place without replacing a file. A page whose text cannot be read
    /// fails the save, saying why (a missing OCR language names the setting to add one).
    /// A Word document shows each page's picture before its text when <see cref="OutputOptions.WordPageImages"/>
    /// is on, stored as <see cref="OutputOptions.PdfSize"/> stores a PDF page. A Word document
    /// past <see cref="DocxWriter.MaxPackageBytes"/> fails the save with <see cref="DocxWriter.TooLargeMessage"/>.
    /// Returns the path written and whether any text was found.
    /// </summary>
    private async Task<(string Path, bool HasText)> WriteTextDocument(List<ScannedPage> pages, OutputFormat format,
                                                                     string path, ScanSettings s, CancellationToken token)
    {
        bool withPictures = format == OutputFormat.Word && s.Output.WordPageImages;
        var size = s.Output.PdfSize;
        var ocrPages = new List<OcrPage>();
        var pictures = new List<DocxPicture?>();
        long pictureBytes = 0;
        for (int i = 0; i < pages.Count; i++)
        {
            token.ThrowIfCancellationRequested();
            var page = pages[i];
            var prepared = await Task.Run(() => PdfBuilder.PreparePage(page, SpoolImage(page)), token);
            StatusMessage = $"Reading the text of page {i + 1} of {pages.Count}…";
            NotifyAll();
            ocrPages.Add(OcrPage.Of(await RecognizeForText(prepared.Image, token),
                                    prepared.PixelWidth, prepared.PixelHeight, page.Dpi));
            if (withPictures)
            {
                // OCR above has read the full pixels; the picture is stored as the PDF size plans it.
                var picture = await Task.Run(() => WpfImageCodec.EncodeDocxPicture(
                    prepared.Image, PdfImageEncoding.EffectiveDpi(prepared.Image.Width, prepared.PixelWidth, page.Dpi),
                    page.ColorMode, size), token);
                pictures.Add(picture);
                // Stop as soon as the pictures alone are past the limit, not after reading every page.
                pictureBytes += picture?.Data.LongLength ?? 0;
                if (pictureBytes > DocxWriter.MaxPackageBytes) throw new IOException(DocxWriter.TooLargeMessage);
            }
        }
        StatusMessage = format == OutputFormat.Word ? "Writing the Word document…" : "Writing the text file…";
        NotifyAll();
        byte[] bytes = await Task.Run(() =>
        {
            if (format != OutputFormat.Word) return TextExport.Encode(ocrPages);
            if (DocxWriter.PackageSize(ocrPages, pictures) > DocxWriter.MaxPackageBytes) throw new IOException(DocxWriter.TooLargeMessage);
            return DocxWriter.Make(ocrPages, pictures);
        }, token);
        string written = await Task.Run(() => TextExport.WriteNewFile(bytes, path), token);
        return (written, TextExport.HasText(ocrPages));
    }

    /// <summary>
    /// The lines OCR finds on <paramref name="image"/>, for text the user asked for: a failure is an
    /// error that says why (not a scanner failure, so the troubleshooter does not record it).
    /// </summary>
    private async Task<IReadOnlyList<OcrLine>> RecognizeForText(RgbaImage image, CancellationToken token)
    {
        try
        {
            return await _ocrService.RecognizeLinesAsync(image).WaitAsync(token);
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (Exception e)
        {
            throw new TextUnreadableException(TextExport.RecognitionFailed(e.Message), e);
        }
    }

    /// <summary>
    /// The text of a page could not be read (<see cref="RecognizeForText"/>); the OCR error is the
    /// inner exception. Told apart from a file that could not be written, which has other advice.
    /// </summary>
    private sealed class TextUnreadableException(string message, Exception inner)
        : InvalidOperationException(message, inner);

    /// <summary>
    /// Copy Text on a page in the queue: reads its text with OCR (full resolution, as turned) and
    /// puts it on the clipboard, a blank line between paragraphs.
    /// </summary>
    public Task CopyPageText(Guid id)
    {
        if (IsBusy || IndexOfPage(id) < 0) return Task.CompletedTask;
        return RunExclusive(async token =>
        {
            // A turn clicked just before must be in the text's reading order.
            await Settled(_pageRotateChain);
            int index = IndexOfPage(id);
            if (index < 0) return;
            var page = ScannedPages[index].Page;
            StatusMessage = $"Reading the text of page {index + 1}…";
            NotifyAll();
            var prepared = await Task.Run(() => PdfBuilder.PreparePage(page, SpoolImage(page)), token);
            var lines = await RecognizeForText(prepared.Image, token);
            string text = OcrText.PageText(OcrPage.Of(lines, prepared.PixelWidth, prepared.PixelHeight, page.Dpi));
            if (text.Length > 0)
            {
                try
                {
                    _fileActions.CopyText(text.ReplaceLineEndings("\r\n"));
                }
                catch (Exception e) when (e is not OperationCanceledException)
                {
                    throw new InvalidOperationException($"Copy did not work: {e.Message}", e);
                }
            }
            StatusMessage = TextExport.CopiedMessage(index + 1, text.Length > 0);
        });
    }

    /// <summary>
    /// " (412 KB)" after the name of the PDF just saved, " (412 KB, password-protected)" when it is
    /// protected; without a known size, " (password-protected)" or nothing.
    /// </summary>
    private string PdfSizeSuffix() => PdfNote(LastPdfBytes is { } bytes ? SavedFiles.SizeText(bytes) : null, LastPdfProtected) is { } note
        ? $" ({note})"
        : "";

    /// <summary>
    /// What is said in brackets after saved PDFs: their size and "password-protected" when they are
    /// ("412 KB, password-protected"); null when there is neither.
    /// </summary>
    private static string? PdfNote(string? size, bool isProtected) =>
        (size, isProtected) switch
        {
            (null, false) => null,
            (null, true) => ProtectedNote,
            (_, false) => size,
            _ => $"{size}, {ProtectedNote}",
        };

    private const string ProtectedNote = "password-protected";

    /// <summary>
    /// The full-resolution UNROTATED pixels from the page's spill file, or null when the page
    /// was never spooled (or the file is unreadable) — PdfBuilder.PreparePage then falls back
    /// to the in-memory image, which already carries any user rotation.
    /// </summary>
    private static RgbaImage? SpoolImage(ScannedPage page)
    {
        if (page.FilePath is null) return null;
        try
        {
            return WpfImageCodec.Load(page.FilePath);
        }
        catch
        {
            return null;
        }
    }

    private static void DeleteSpoolFiles(IEnumerable<ScannedPage> pages)
    {
        foreach (var page in pages)
        {
            foreach (var path in new[] { page.FilePath, page.Alternate?.FilePath })
            {
                if (path is null) continue;
                try { File.Delete(path); } catch { /* best effort */ }
            }
        }
    }

    /// <summary>The counter's last value, without taking the next one (0 when none was taken yet).</summary>
    private int PeekCounter()
    {
        string counterPath = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            "CompleteScanner", "counter.txt");
        try
        {
            return File.Exists(counterPath) ? int.Parse(File.ReadAllText(counterPath).Trim()) : _counterFallback;
        }
        catch
        {
            return _counterFallback;
        }
    }

    private int NextCounter()
    {
        // The macOS app keeps the counter in UserDefaults; here a tiny file next to the
        // presets serves the same purpose.
        string counterPath = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            "CompleteScanner", "counter.txt");
        try
        {
            int value = File.Exists(counterPath) ? int.Parse(File.ReadAllText(counterPath).Trim()) : 0;
            value += 1;
            Directory.CreateDirectory(Path.GetDirectoryName(counterPath)!);
            File.WriteAllText(counterPath, value.ToString());
            return value;
        }
        catch
        {
            return ++_counterFallback;
        }
    }

    /// <summary>
    /// A free file name in the snapshot's destination folder. It is only a proposal: the
    /// writers move into place without replacing and pick the next free name if another
    /// file took this one meanwhile.
    /// </summary>
    private string OutputPath(ScanSettings s, string fileExtension, int? index = null, DocumentDate? documentDate = null,
                              string? label = null)
    {
        string dir = Environment.ExpandEnvironmentVariables(s.DestinationPath);
        Directory.CreateDirectory(dir);
        string baseName = new NamingTemplate(s.NamingTemplate)
            .BaseFilename(new NamingContext(NextCounter(), DateTime.Now, s.Intent)
            {
                Index = index,
                Task = TaskCatalog.Infer(s),
                DocumentDate = documentDate,
                Label = label,
            });
        return NamingTemplate.UniquePath(dir, baseName, fileExtension);
    }

    private static bool IsCancellation(Exception e) =>
        e is OperationCanceledException || e is ScanException { Kind: ScanErrorKind.Cancelled };

    /// <summary>
    /// Run one long operation at a time; surface errors; manage busy state. The operation
    /// receives a token that Cancel trips; it must check it between heavy work units. The
    /// returned task never faults.
    /// </summary>
    private Task RunExclusive(Func<CancellationToken, Task> operation)
    {
        if (IsBusy) return Task.CompletedTask;
        _currentOperation = RunExclusiveCore(operation);
        return _currentOperation;
    }

    private async Task RunExclusiveCore(Func<CancellationToken, Task> operation)
    {
        IsBusy = true;
        using var cts = new CancellationTokenSource();
        _operationCts = cts;
        NotifyAll();
        try
        {
            await operation(cts.Token);
        }
        catch (PasswordNotGivenException)
        {
            StatusMessage = PdfProtection.NotSavedMessage;
        }
        catch (Exception e) when (IsCancellation(e))
        {
            StatusMessage = "Cancelled.";
        }
        catch (Exception e)
        {
            ErrorMessage = e.Message;
            StatusMessage = "Ready.";
            // A scan the scanner refused (busy, offline, ...) is what the troubleshooter explains.
            if (e is ScanException && _session is { } session) RecordFailure(session.Info.Name, e);
        }
        finally
        {
            ForgetPdfPassword();
        }
        _operationCts = null;
        Progress = null;
        IsBusy = false;
        NotifyAll();
        EndOfWork();
    }
}
