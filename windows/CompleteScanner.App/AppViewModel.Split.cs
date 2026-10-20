using System.IO;
using CompleteScanner.App.Services;
using CompleteScanner.Core;

namespace CompleteScanner.App;

/// <summary>
/// Splitting a stack into separate documents: the plan the page strip shows
/// (<see cref="DocumentSplitter"/>), splitting and joining by hand, naming a document, saving
/// several files all or nothing (<see cref="SavePlan"/>), and saving or printing the separator sheet. Twin of
/// the Mac's AppState+Split.swift.
/// </summary>
public sealed partial class AppViewModel
{
    /// <summary>The documents the queue is saved as, and what saving does with each page, under the current settings.</summary>
    public SplitPlan QueuePlan => DocumentSplitter.Plan(ScannedPages.Select(item => item.Page).ToList(), Settings.Document);

    /// <summary>What saving the queue writes under the current settings.</summary>
    public SavePlan QueueSavePlan => SavePlan.Make(ScannedPages.Select(item => item.Page).ToList(), Settings.Document);

    /// <summary>The page strip shows each page's place in the plan: its badge, its document, the gap before it.</summary>
    private void SyncPagePlan()
    {
        var pages = ScannedPages.Select(item => item.Page).ToList();
        var options = Settings.Document;
        var plan = DocumentSplitter.Plan(pages, options);
        bool showsBreaks = DocumentSplitter.ShowsBreaks(plan, options);
        for (int i = 0; i < ScannedPages.Count; i++)
        {
            var planned = plan.Pages[i];
            ScannedPages[i].Split = new PageSplitView(
                Badge: DocumentSplitter.Badge(plan, i, pages[i], options),
                IsExcluded: planned.Role != PageRole.Content,
                ToggleLabel: DocumentSplitter.ToggleLabel(plan, i, pages[i], options),
                DividerTitle: DocumentSplitter.DividerTitle(plan, i),
                BreakLabel: showsBreaks ? DocumentSplitter.BreakLabel(plan, i) : null,
                MenuBreakLabel: DocumentSplitter.BreakLabel(plan, i),
                StartsDocument: plan.IsSplit && planned.StartsDocument && planned.Document > 1,
                ShowsBreaks: showsBreaks,
                SeparatorNote: DocumentSplitter.SeparatorNote(plan, i, pages[i]),
                Document: planned.Document);
        }
    }

    /// <summary>
    /// The status after a scan's pages were queued: the spreads split or kept whole, the blank pages
    /// among them (not counting the separators), what crop and straighten did, the pages turned
    /// upright, and the separator pages found with the documents the queue now makes.
    /// </summary>
    private string QueueScanNote(IReadOnlyList<ScannedPage> added, DocumentOptions options)
    {
        var plan = QueuePlan;
        var separatorIds = ScannedPages.Where((_, i) => plan.Pages[i].Role == PageRole.Separator)
            .Select(item => item.Page.Id).ToHashSet();
        var notSeparators = added.Where(page => !separatorIds.Contains(page.Id)).ToList();
        int separatorsAdded = added.Count - notSeparators.Count;
        return BookPages.ScanNote(added) + PageFilter.ScanNote(notSeparators, options) + PageCorrections.ScanNote(added)
               + PageTurns.ScanNote(added) + DocumentSplitter.ScanNote(plan, separatorsAdded);
    }

    /// <summary>
    /// One click on the gap before a queued page: a new document starts there, or the page joins the
    /// document before; a second click goes back to what the split setting says.
    /// </summary>
    public void ToggleDocumentBreak(Guid id)
    {
        if (IsBusy) return;
        int index = IndexOfPage(id);
        if (index < 0) return;
        var facts = ScannedPages.Select(item => PageFacts.Of(item.Page, Settings.Document)).ToList();
        if (!DocumentSplitter.CanToggleBreak(DocumentSplitter.Plan(facts, Settings.Document), index)) return;
        var item = ScannedPages[index];
        // Updated in place, so the gap's button keeps its container and the keyboard focus.
        item.Page = item.Page.WithDocumentBreak(DocumentSplitter.ToggledBreak(facts, index, Settings.Document));
        CarryDocumentLabels(facts);
        var plan = QueuePlan;
        int documents = plan.Documents.Count;
        string count = $"{documents} document{(documents == 1 ? "" : "s")} to save.";
        StatusMessage = plan.Pages[index] is { StartsDocument: true, Document: > 1 } page
            ? $"Document {page.Document} starts at page {index + 1}. {count}"
            : $"Page {index + 1} joins the document before it. {count}";
        NotifyAll();
    }

    /// <summary>
    /// After a page's inclusion or document break changed (<paramref name="before"/>: the facts
    /// until then), or the settings (<paramref name="beforeOptions"/>: the document settings until
    /// then; null: unchanged): a document whose first saved page changed keeps its name, moved to
    /// its new first page (<see cref="DocumentSplitter.CarriedLabels(IReadOnlyList{PageFacts}, DocumentOptions, IReadOnlyList{PageFacts}, DocumentOptions)"/>).
    /// Pages are updated in place.
    /// </summary>
    private void CarryDocumentLabels(IReadOnlyList<PageFacts> before, DocumentOptions? beforeOptions = null)
    {
        var after = ScannedPages.Select(item => PageFacts.Of(item.Page, Settings.Document)).ToList();
        var labels = DocumentSplitter.CarriedLabels(before, beforeOptions ?? Settings.Document, after, Settings.Document);
        for (int i = 0; i < ScannedPages.Count; i++)
        {
            var item = ScannedPages[i];
            if (item.Page.DocumentLabel != labels[i]) item.Page = item.Page.WithDocumentLabel(labels[i]);
        }
    }

    /// <summary>The document settings the queue's names were last carried under (<see cref="CarryDocumentLabelsAcrossSettings"/>).</summary>
    private DocumentOptions _labelsCarriedUnder = new();

    /// <summary>
    /// After the document settings changed (Skip blank pages, what counts as blank, the split; by
    /// hand, a task or a preset): a named document whose first saved page they now leave out, or
    /// that a page before it now joins, keeps its name, as after a click on Keep or Skip.
    /// </summary>
    private void CarryDocumentLabelsAcrossSettings()
    {
        var before = _labelsCarriedUnder;
        if (before.Equals(Settings.Document)) return;
        _labelsCarriedUnder = Settings.Document.Clone();
        if (ScannedPages.Count == 0) return;
        CarryDocumentLabels(ScannedPages.Select(item => PageFacts.Of(item.Page, before)).ToList(), before);
    }

    /// <summary>The name of the document the queued page is in (empty when it has none, or the page is left out).</summary>
    public string DocumentLabelOf(Guid id)
    {
        int index = IndexOfPage(id);
        if (index < 0) return "";
        var plan = QueuePlan;
        return plan.Pages[index].Document is { } number ? plan.Documents[number - 1].Label ?? "" : "";
    }

    /// <summary>
    /// Names the document the queued page is in ({label} in the file name): the name is kept on the
    /// document's first page, and any other name among its pages is dropped. An empty name removes it.
    /// </summary>
    public void SetDocumentLabel(Guid id, string? label)
    {
        if (IsBusy) return;
        int index = IndexOfPage(id);
        if (index < 0) return;
        var plan = QueuePlan;
        if (plan.Pages[index].Document is not { } number) return;
        var document = plan.Documents[number - 1];
        string? cleaned = DocumentSplitter.Cleaned(label);
        for (int k = 0; k < document.Pages.Count; k++)
        {
            var item = ScannedPages[document.Pages[k]];
            string? wanted = k == 0 ? cleaned : null;
            if (item.Page.DocumentLabel != wanted) item.Page = item.Page.WithDocumentLabel(wanted);
        }
        StatusMessage = cleaned is null
            ? $"Document {number} has no name."
            : $"Document {number} is named “{cleaned}”: {{label}} in the file name.";
        NotifyAll();
    }

    /// <summary>Where the queue is split into documents: a split setting from the inspector.</summary>
    public void SetSplitMode(SplitMode mode)
    {
        if (Settings.Document.SplitMode == mode) return;
        Settings.Document.SplitMode = mode;
        SettingsEdited();
        if (ScannedPages.Count > 0) StatusMessage = DocumentSplitter.QueueSummary(ScannedPages.Select(item => item.Page).ToList(), Settings.Document) + ".";
        NotifyAll();
    }

    /// <summary>The sheets per document for <see cref="SplitMode.SheetCount"/> (1 to 999).</summary>
    public void SetSplitSheetCount(int count)
    {
        int clamped = DocumentSplitter.ClampSheetCount(count);
        if (Settings.Document.SplitSheetCount == clamped) return;
        Settings.Document.SplitSheetCount = clamped;
        SettingsEdited();
        if (ScannedPages.Count > 0) StatusMessage = DocumentSplitter.QueueSummary(ScannedPages.Select(item => item.Page).ToList(), Settings.Document) + ".";
        NotifyAll();
    }

    /// <summary>
    /// Saves the documents of a split queue, a file each (with its text beside it when asked for),
    /// all or nothing: a failure or Cancel part-way removes every file written, and the queue stays
    /// as it was so it can be saved again.
    /// </summary>
    private async Task SaveDocuments(SavePlan plan, ScanSettings s, List<ScannedPage> queued, CancellationToken token)
    {
        var format = OutputFormats.QueueFormat(s.Format);
        var files = new WrittenFiles();
        var saved = new List<string>();
        var textFiles = new List<string>();
        var noText = new List<string>();
        long? totalBytes = 0;
        // Each PDF written sets the last PDF's size and protection; a save undone puts back the ones before.
        long? lastPdfBytes = LastPdfBytes;
        bool lastPdfProtected = LastPdfProtected;
        try
        {
            await SavePlan.WriteAllOrNothingAsync(files, async () =>
            {
                foreach (var document in plan.Documents)
                {
                    token.ThrowIfCancellationRequested();
                    StatusMessage = $"Saving document {document.Number} of {plan.Documents.Count}…";
                    NotifyAll();
                    var pages = document.Pages.ToList();
                    string path = OutputPath(s, format.FileExtension(), plan.FileIndex(document), label: document.Label);
                    if (format.IsTextFormat())
                    {
                        var (written, hasText) = await WriteTextDocument(pages, format, path, token);
                        files.Add(written);
                        saved.Add(written);
                        if (!hasText) noText.Add(Path.GetFileName(written));
                        continue;
                    }
                    var text = s.Output.AlsoSaveText ? new PdfText() : null;
                    string pdf = await WritePdfAtomically(pages, s, path, token, text);
                    files.Add(pdf);
                    saved.Add(pdf);
                    totalBytes = LastPdfBytes is { } bytes ? totalBytes + bytes : null;
                    if (text is not null && await WriteTextBeside(pdf, text) is { } textPath)
                    {
                        files.Add(textPath);
                        textFiles.Add(Path.GetFileName(textPath));
                    }
                }
            });
        }
        catch (Exception e)
        {
            LastPdfBytes = lastPdfBytes;
            LastPdfProtected = lastPdfProtected;
            if (IsCancellation(e)) throw;
            throw new IOException(SavePlan.NotSavedMessage(e.Message), e);
        }
        MarkSaved(saved);
        DeleteSpoolFiles(queued);
        ScannedPages.Clear();
        ResetFlow();
        // The PDFs' size together, and "password-protected" when they are, in the brackets after the page count.
        string? size = format == OutputFormat.Pdf
            ? PdfNote(totalBytes is { } total ? SavedFiles.SizeText(total) : null, LastPdfProtected)
            : null;
        StatusMessage = plan.SavedMessage(format, saved.Select(path => Path.GetFileName(path)).ToList(), size, textFiles, noText);
        RunAfterSave(s.Output.AfterSave, saved);
    }

    /// <summary>
    /// Saves the separator sheet (Patch T) as a PDF in the scans folder, on the paper usual where the
    /// user lives (Letter or A4), to print at actual size on any printer, here or elsewhere: the
    /// saved bar opens it. Works with no printer installed.
    /// </summary>
    public Task SaveSeparatorSheet()
    {
        var s = Settings.Clone();
        return RunExclusive(async token =>
        {
            StatusMessage = "Saving the separator sheet…";
            NotifyAll();
            var paper = SeparatorSheet.Paper(RegionCode);
            var inches = PaperSizes.Inches(paper) ?? new SizeD(8.5, 11);
            string dir = Environment.ExpandEnvironmentVariables(s.DestinationPath);
            Directory.CreateDirectory(dir);
            string path = NamingTemplate.UniquePath(dir, SeparatorSheet.FileBaseName(paper), "pdf");
            string written = await Task.Run(() =>
            {
                var sheet = PatchCodeDetector.RenderSheet(SeparatorSheet.Code, inches.Width, inches.Height, SeparatorSheet.Dpi).ToRgba();
                byte[] jpeg = WpfImageCodec.EncodeJpeg(sheet, SeparatorSheet.Dpi, 0.9, gray: true);
                return PdfBuilder.WriteNewFile([new PdfPageInput(jpeg, sheet.Width, sheet.Height, SeparatorSheet.Dpi, null)],
                                               path, progress: null, token);
            }, token);
            // The sheet is never protected, whatever the last PDF saved was.
            LastPdfProtected = false;
            try { LastPdfBytes = new FileInfo(written).Length; }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { LastPdfBytes = null; }
            MarkSaved([written]);
            StatusMessage = SeparatorSheet.SavedMessage(Path.GetFileName(written));
        });
    }

    /// <summary>
    /// Prints the separator sheet (Patch T) at real size on the printer chosen for copies, on the
    /// paper it has (whatever paper size the scan asks for), with no dialog: the sheet goes in front
    /// of each document after the first.
    /// </summary>
    public Task PrintSeparatorSheet()
    {
        var s = Settings.Clone();
        return RunExclusive(async token =>
        {
            StatusMessage = "Getting the printer ready…";
            NotifyAll();
            var setup = await SetupForAsync(s, requested: null) ?? throw new PrintException(PrintText.NoPrinterMessage);
            token.ThrowIfCancellationRequested();
            const int dpi = SeparatorSheet.Dpi;
            var paper = setup.Paper.Paper;
            var page = await Task.Run(() => PatchCodeDetector.RenderSheet(SeparatorSheet.Code, paper.Width, paper.Height, dpi).ToRgba(), token);
            var placement = PrintLayout.Place(page.Width, page.Height, dpi, setup.Paper, PrintMode.ActualSize, PrintAlign.PaperOrigin);
            var job = new PrintJob(setup.PrinterName, "Separator sheet (Patch T)", setup.Paper, RequestedPaper: null,
                                   [new PrintPage(page, dpi, placement)], new PrintCopiesPlan(1, 1), Gray: true);
            StatusMessage = $"Printing the separator sheet on {setup.PrinterName}…";
            NotifyAll();
            await _print.PrintAsync(job, token);
            StatusMessage = $"Sent the separator sheet to {setup.PrinterName}. Put one in front of each document after the first; print more copies as you need them.";
        });
    }
}

/// <summary>What the split plan says about a queued page, for the page strip (<see cref="PageItem.Split"/>).</summary>
/// <param name="BreakLabel">What a click on the gap before the page does, while the strip shows document breaks; null: no gap button.</param>
/// <param name="MenuBreakLabel">The same for the page's menu, shown whether or not the strip shows breaks.</param>
/// <param name="StartsDocument">The page starts a document after the first: the gap before it is a divider.</param>
/// <param name="ShowsBreaks">The strip shows where documents start (a split is chosen, or the queue is split by hand).</param>
public sealed record PageSplitView(string? Badge, bool IsExcluded, string? ToggleLabel, string? DividerTitle,
                                   string? BreakLabel, string? MenuBreakLabel, bool StartsDocument, bool ShowsBreaks,
                                   string? SeparatorNote, int? Document);
