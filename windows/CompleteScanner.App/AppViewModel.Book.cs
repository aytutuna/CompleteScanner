using System.IO;
using CompleteScanner.App.Services;
using CompleteScanner.Core;

namespace CompleteScanner.App;

/// <summary>
/// Books and magazines: the spreads the queued pages were cut from (kept in the spool so a spread can
/// be joined or split again), the page strip's spread labels, joining and splitting a spread by hand,
/// and the book options of the inspector. Twin of the Mac's AppState+Book.swift.
/// </summary>
public sealed partial class AppViewModel
{
    /// <summary>
    /// A spread pages in the queue were cut from, as scanned: its full-resolution pixels in a spool
    /// file (or in memory when the file could not be written), how it was scanned, and its size in pixels.
    /// </summary>
    private sealed record SpreadSource(string? FilePath, RgbaImage? Image, int Dpi, ColorMode ColorMode, DateTime CreatedAt,
                                       int Width, int Height);

    /// <summary>The spreads of the book pages in the queue, by spread id; dropped with their last page (<see cref="PruneSpreads"/>).</summary>
    private readonly Dictionary<Guid, SpreadSource> _spreads = [];

    /// <summary>
    /// Writes each spread as scanned to a spool PNG of its own ("{id}-spread.png"), for joining and
    /// splitting it again; a spread whose file cannot be written is kept in memory.
    /// </summary>
    private static Dictionary<Guid, SpreadSource> SpoolSpreads(IReadOnlyList<ScannedPage> spreads, string spoolDirectory)
    {
        var sources = new Dictionary<Guid, SpreadSource>();
        foreach (var spread in spreads)
        {
            string path = Path.Combine(spoolDirectory, $"{spread.Id}-spread.png");
            try
            {
                Directory.CreateDirectory(spoolDirectory);
                WpfImageCodec.Save(spread.Image, path, OutputFormat.Png, spread.Dpi, 1.0);
                sources[spread.Id] = new SpreadSource(path, null, spread.Dpi, spread.ColorMode, spread.CreatedAt,
                                                      spread.Image.Width, spread.Image.Height);
            }
            catch
            {
                sources[spread.Id] = new SpreadSource(null, spread.Image, spread.Dpi, spread.ColorMode, spread.CreatedAt,
                                                      spread.Image.Width, spread.Image.Height);
            }
        }
        return sources;
    }

    private static void DeleteSpreadFiles(IEnumerable<SpreadSource> sources)
    {
        foreach (var source in sources)
        {
            if (source.FilePath is not { } path) continue;
            try { File.Delete(path); } catch { /* best effort */ }
        }
    }

    /// <summary>Drops the spreads no queued page was cut from any more, and their files.</summary>
    private void PruneSpreads()
    {
        if (_spreads.Count == 0) return;
        var used = ScannedPages.Select(item => item.Page.SpreadId).OfType<Guid>().ToHashSet();
        var unused = _spreads.Where(pair => !used.Contains(pair.Key)).ToList();
        foreach (var (id, source) in unused)
        {
            DeleteSpreadFiles([source]);
            _spreads.Remove(id);
        }
    }

    /// <summary>
    /// The page strip shows each book page's spread and offers to join or split it. Runs on every
    /// refresh, so the labels are worked out in one pass over the queue (<see cref="BookPages.Labels"/>).
    /// </summary>
    private void SyncBookLabels()
    {
        var pages = ScannedPages.Select(item => item.Page).ToList();
        var labels = BookPages.Labels(pages);
        for (int i = 0; i < ScannedPages.Count; i++)
        {
            var page = pages[i];
            bool editable = page.SpreadId is { } id && _spreads.ContainsKey(id);
            ScannedPages[i].Book = labels[i] is not { } label
                ? null
                : new PageBookView(label.Label, label.Help,
                                   editable ? BookPages.SplitActionLabel(page) : null,
                                   editable ? BookPages.JoinActionLabel(page) : null);
        }
    }

    /// <summary>Which spread of the queue (from 1, in queue order) the page was cut from; 0 when none.</summary>
    private int SpreadNumber(Guid spreadId)
    {
        var order = new List<Guid>();
        foreach (var item in ScannedPages)
        {
            if (item.Page.SpreadId is { } id && !order.Contains(id)) order.Add(id);
        }
        return order.IndexOf(spreadId) + 1;
    }

    /// <summary>The spread a queued page was cut from can be joined or split again: its spread is at hand.</summary>
    public bool CanEditSpread(Guid pageId) =>
        IndexOfPage(pageId) is int index && index >= 0
        && ScannedPages[index].Page.SpreadId is { } id && _spreads.ContainsKey(id);

    /// <summary>
    /// What the split dialog shows for the spread a queued page was cut from: a preview of the spread
    /// as scanned, where it is cut now (a spread kept whole: up and down its middle), and its number.
    /// Null when the page is no book page or its spread can no longer be read.
    /// </summary>
    public async Task<SpreadEditorSource?> LoadSpreadEditor(Guid pageId)
    {
        int index = IndexOfPage(pageId);
        if (index < 0 || ScannedPages[index].Page.Spread is not { } part || !_spreads.TryGetValue(part.SpreadId, out var source))
        {
            return null;
        }
        RgbaImage preview;
        try
        {
            preview = await Task.Run(() => ScanHistory.MakePreview(LoadSpread(source), SpoolPreviewMaxSide));
        }
        catch (Exception e)
        {
            ErrorMessage = $"The spread could not be read: {e.Message}";
            NotifyAll();
            return null;
        }
        var axis = part.Gutter?.Axis ?? GutterAxis.Vertical;
        double fraction = part.Gutter?.Fraction(source.Width, source.Height) ?? 0.5;
        return new SpreadEditorSource(pageId, preview, axis, fraction, !part.IsWhole, SpreadNumber(part.SpreadId));
    }

    /// <summary>The spread's full-resolution pixels: from memory, or read from its spool file.</summary>
    private static RgbaImage LoadSpread(SpreadSource source) =>
        source.Image ?? WpfImageCodec.Load(source.FilePath ?? throw new InvalidOperationException("The spread is no longer available."));

    /// <summary>
    /// The split dialog's Split: the spread the page was cut from is cut again along
    /// <paramref name="axis"/> at <paramref name="fraction"/> of it, and its pages in the queue are
    /// replaced by the new ones, checked, straightened and turned as a scan is
    /// (<see cref="PageProcessor.ProcessSpread"/>); a page the user removed stays out, and each page
    /// keeps its document break, name and keep or skip (<see cref="BookPages.ReplacementPages"/>).
    /// </summary>
    public Task SplitSpread(Guid pageId, GutterAxis axis, double fraction) => ReplaceSpread(pageId, (axis, fraction));

    /// <summary>
    /// "Join the two pages" (and the dialog's "Keep as one page"): the pages cut from the spread are
    /// replaced by the whole spread, as one page.
    /// </summary>
    public Task JoinSpread(Guid pageId) => ReplaceSpread(pageId, null);

    private Task ReplaceSpread(Guid pageId, (GutterAxis Axis, double Fraction)? cut)
    {
        if (IsBusy || !CanEditSpread(pageId)) return Task.CompletedTask;
        var s = Settings.Clone();
        return RunExclusive(async token =>
        {
            // Turns and swaps clicked before must not land on pages about to be replaced.
            await Settled(_pageRotateChain);
            int index = IndexOfPage(pageId);
            if (index < 0 || ScannedPages[index].Page is not { SpreadId: { } spreadId } clicked
                || !_spreads.TryGetValue(spreadId, out var source)) return;
            StatusMessage = cut is null ? "Joining the pages…" : "Splitting the spread…";
            NotifyAll();
            var image = await Task.Run(() => LoadSpread(source), token);
            // The spread keeps the sheet and side its pages were given. Its pages are made with the
            // current settings, color mode included: the adjustment step makes the pixels that mode
            // says (black & white thresholded at the user's level); when it does not run (color, no
            // adjustments) the pages are the spread as scanned, labelled color. A black & white spread
            // the scanner sent unthresholded is never stored as G4 without the user's threshold.
            var spread = new ScannedPage(image, source.Dpi, s.ColorMode, spreadId, source.CreatedAt)
            {
                Side = clicked.Side,
                SheetIndex = clicked.SheetIndex,
            };
            var gutter = cut is { } c ? BookSplitter.Manual(c.Axis, c.Fraction, image.Width, image.Height) : null;
            var processor = PageProcessor.ForScan(s, ScanArrangement.AsScanned, _orientation, _barcodes);
            var pages = await Task.Run(() => processor.ProcessSpread(spread, gutter, BookSplitOptions.Of(s), token).ToList(), token);
            string spoolDirectory = _spool.Directory;
            var spooled = await Task.Run(() => SpoolPages(pages, spoolDirectory).Select(p => new PageItem(p)).ToList());
            var indices = Enumerable.Range(0, ScannedPages.Count).Where(i => ScannedPages[i].Page.SpreadId == spreadId).ToList();
            if (token.IsCancellationRequested || indices.Count == 0)
            {
                DeleteSpoolFiles(spooled.Select(item => item.Page));
                token.ThrowIfCancellationRequested();
                return;
            }
            // The new pages take what the user decided about the old ones; a part the user removed stays out.
            var removed = indices.Select(i => ScannedPages[i].Page).ToList();
            var replacement = BookPages.ReplacementPages(removed, spooled.Select(item => item.Page).ToList());
            var thumbnails = spooled.ToDictionary(item => item.Page.Id, item => item.Thumbnail);
            var items = replacement.Select(page => new PageItem(page, thumbnails[page.Id], Settings.Document)).ToList();
            var kept = replacement.Select(page => page.Id).ToHashSet();
            DeleteSpoolFiles(spooled.Select(item => item.Page).Where(page => !kept.Contains(page.Id)));
            for (int k = indices.Count - 1; k >= 0; k--) ScannedPages.RemoveAt(indices[k]);
            for (int k = 0; k < items.Count; k++) ScannedPages.Insert(indices[0] + k, items[k]);
            DeleteSpoolFiles(removed);
            StatusMessage = BookPages.SplitNote(SpreadNumber(spreadId), cut is not null)
                            + PageFilter.ScanNote(replacement, s.Document) + PageCorrections.ScanNote(replacement)
                            + PageTurns.ScanNote(replacement);
        });
    }

    /// <summary>Split facing pages, from the inspector.</summary>
    public void SetSplitFacingPages(bool split)
    {
        if (Settings.Document.SplitFacingPages == split) return;
        Settings.Document.SplitFacingPages = split;
        SettingsEdited();
        NotifyAll();
    }

    /// <summary>Softening the spine's shadow, from the inspector: for the spreads scanned (or split again) from now on.</summary>
    public void SetSoftenSpineShadow(bool soften)
    {
        if (Settings.Document.SoftenSpineShadow == soften) return;
        Settings.Document.SoftenSpineShadow = soften;
        SettingsEdited();
        NotifyAll();
    }

    /// <summary>Right-to-left reading order, from the inspector: for the spreads scanned from now on.</summary>
    public void SetBookRightToLeft(bool rightToLeft)
    {
        if (Settings.TaskOptions.BookRightToLeft == rightToLeft) return;
        Settings.TaskOptions.BookRightToLeft = rightToLeft;
        SettingsEdited();
        NotifyAll();
    }

    /// <summary>The book's rotation (quarter turns clockwise), from the inspector: for the spreads scanned from now on.</summary>
    public void SetBookRotation(int quarterTurns)
    {
        int turns = BookSplitter.NormalizedTurns(quarterTurns);
        if (Settings.TaskOptions.BookRotationQuarterTurns == turns) return;
        Settings.TaskOptions.BookRotationQuarterTurns = turns;
        SettingsEdited();
        NotifyAll();
    }
}

/// <summary>What the page strip says about a page cut from a spread (<see cref="PageItem.Book"/>).</summary>
/// <param name="Label">"2 · left", "2 · not split".</param>
/// <param name="Help">The label's tooltip.</param>
/// <param name="SplitLabel">The page menu's split item ("Split this spread…", "Change the split…"); null when the spread is not at hand.</param>
/// <param name="JoinLabel">The page menu's join item ("Join the two pages"); null for a whole spread, or when the spread is not at hand.</param>
public sealed record PageBookView(string? Label, string? Help, string? SplitLabel, string? JoinLabel);

/// <summary>What the split dialog shows for a spread (<see cref="AppViewModel.LoadSpreadEditor"/>).</summary>
/// <param name="PageId">The queued page the dialog was opened from.</param>
/// <param name="Preview">The spread as scanned, at most <c>SpoolPreviewMaxSide</c> long.</param>
/// <param name="Axis">How it is cut now.</param>
/// <param name="Fraction">Where it is cut now, along <paramref name="Axis"/> (0...1).</param>
/// <param name="IsSplit">It is cut now (not kept whole).</param>
/// <param name="SpreadNumber">Its number in the queue, from 1.</param>
public sealed record SpreadEditorSource(Guid PageId, RgbaImage Preview, GutterAxis Axis, double Fraction, bool IsSplit, int SpreadNumber);
