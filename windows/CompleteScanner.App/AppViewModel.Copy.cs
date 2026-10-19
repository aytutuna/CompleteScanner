using System.IO;
using CompleteScanner.App.Services;
using CompleteScanner.Core;

namespace CompleteScanner.App;

/// <summary>
/// Printing: the Copy task (scan, then print at real size, like a photocopier), printing the ID
/// card's page, and the ruler test page. Pages are placed with <see cref="PrintLayout"/> and sent
/// through <see cref="IPrintService"/> with no print dialog; the printer and the number of copies are
/// chosen in the inspector (<see cref="TaskOptions"/>). Twin of the Mac's AppState+Copy.swift.
/// </summary>
public sealed partial class AppViewModel
{
    /// <summary>Prints through Windows (a stand-in in tests).</summary>
    private readonly IPrintService _print;
    /// <summary>The installed printers as last read; null until they have been read, and when the print system could not be read.</summary>
    private IReadOnlyList<PrinterInfo>? _printers;
    /// <summary>The paper in the default printer, when it is a named size; Automatic paper for the ID card follows it.</summary>
    private PaperSize? _defaultPrinterPaper;
    /// <summary>What the printer chosen for copies offers (paper, margins), for the inspector.</summary>
    private PrinterSetup? _copySetup;
    /// <summary>The paper <see cref="_copySetup"/> was asked for.</summary>
    private PaperSize? _copySetupPaper;
    /// <summary>Bumped for every read of the printers; a late one is dropped.</summary>
    private int _printerRevision;
    /// <summary>Bumped for every read of what the printer for copies offers; a late one is dropped.</summary>
    private int _copySetupRevision;
    /// <summary>The latest read of the printers.</summary>
    private Task? _printerRead;

    /// <summary>The installed printers, as last read (empty until then).</summary>
    public IReadOnlyList<PrinterInfo> Printers => _printers ?? [];

    /// <summary>
    /// Whether a printer is installed: false only once the printers were read and there are none
    /// (not when the print system could not be read).
    /// </summary>
    public bool HasPrinter => _printers is null || _printers.Count > 0;

    /// <summary>The scans of the settings go straight to the printer (the Copy task).</summary>
    public bool IsCopyFlow => TaskCatalog.FlowOf(Settings) == TaskFlowKind.Copy;

    /// <summary>
    /// The printer copies are printed on: the one chosen, while it is installed, else the default
    /// printer; null when there is none (or the printers were not read yet and none was chosen).
    /// </summary>
    public string? CopyPrinterName =>
        Settings.TaskOptions.CopyPrinterName is { } chosen && (_printers is null || _printers.Any(p => SameName(p.Name, chosen)))
            ? chosen
            : _printers?.FirstOrDefault(p => p.IsDefault)?.Name;

    /// <summary>The paper the chosen printer prints copies on, e.g. "Letter (8.5 × 11 in)"; empty while unknown.</summary>
    public string CopyPaperText => _copySetup?.Paper.Description ?? "";

    /// <summary>
    /// "Edges may be cut by up to 5 mm (printer margins)." when copies at real size from the corner of
    /// the paper lose an edge to the chosen printer's margins; null otherwise.
    /// </summary>
    public string? CopyMarginWarning =>
        _copySetup is { } setup && !Settings.TaskOptions.CopyFitToPage && setup.Paper.LargestMargin > PrintLayout.ClipWarningInches
            ? $"Edges may be cut by up to {PrintLayout.Millimetres(setup.Paper.LargestMargin)} mm (printer margins)."
            : null;

    private static bool SameName(string a, string b) => string.Equals(a, b, StringComparison.OrdinalIgnoreCase);

    /// <summary>
    /// Reads the installed printers, the default printer's paper (for Automatic paper of the ID card)
    /// and what the printer chosen for copies offers. Only reads: nothing is changed on any printer.
    /// </summary>
    public Task RefreshPrintersAsync()
    {
        var read = ReadPrintersAsync();
        _printerRead = read;
        return read;
    }

    /// <summary>
    /// Printers may have been added or removed meanwhile (the window was switched back to, the
    /// start screen shown): reads them again, unless a read is under way.
    /// </summary>
    public void PrintersMayHaveChanged()
    {
        if (_printerRead is { IsCompleted: false }) return;
        _ = RefreshPrintersAsync();
    }

    private async Task ReadPrintersAsync()
    {
        int revision = ++_printerRevision;
        IReadOnlyList<PrinterInfo>? printers;
        PrinterSetup? defaultSetup = null;
        try
        {
            printers = await _print.GetPrintersAsync();
        }
        catch (Exception e) when (e is not OutOfMemoryException)
        {
            // The print system could not be read (its service stopped, say). That is not "no
            // printer": the Copy task and Print stay offered, and read the printers again.
            printers = null;
        }
        if (printers is { Count: > 0 })
        {
            try { defaultSetup = await _print.GetSetupAsync(null, null); }
            catch (Exception e) when (e is not OutOfMemoryException) { defaultSetup = null; }
        }
        if (revision != _printerRevision) return;
        var paperBefore = IdCardPaperSize;
        _printers = printers;
        _defaultPrinterPaper = defaultSetup?.Paper.Size;
        await RefreshCopySetupAsync();
        if (revision != _printerRevision) return;
        // Automatic paper of the ID card follows the default printer's paper.
        if (paperBefore != IdCardPaperSize && ShowIdCardReview) _ = RefreshIdCardPreview();
        NotifyAll();
    }

    /// <summary>Reads what the printer chosen for copies offers, for the inspector.</summary>
    private async Task RefreshCopySetupAsync()
    {
        // Each read runs on a thread of its own and they may finish in any order: the latest counts.
        int revision = ++_copySetupRevision;
        var s = Settings.Clone();
        _copySetupPaper = RequestedPaper(s);
        PrinterSetup? setup = null;
        if (HasPrinter)
        {
            try { setup = await SetupForAsync(s, RequestedPaper(s)); }
            catch (Exception e) when (e is not OutOfMemoryException) { setup = null; }
        }
        if (revision != _copySetupRevision) return;
        _copySetup = setup;
        NotifyAll();
    }

    /// <summary>
    /// What printing with these settings would use: the printer chosen for copies, else (and when it
    /// is no longer installed) the default printer.
    /// </summary>
    private async Task<PrinterSetup?> SetupForAsync(ScanSettings s, PaperSize? requested)
    {
        var setup = s.TaskOptions.CopyPrinterName is { } name ? await _print.GetSetupAsync(name, requested) : null;
        return setup ?? await _print.GetSetupAsync(null, requested);
    }

    /// <summary>The paper asked of the printer for copies: the paper size chosen in the inspector; null (the printer's own) for Automatic.</summary>
    private static PaperSize? RequestedPaper(ScanSettings s) =>
        s.PaperSize is PaperSize.Auto or PaperSize.IdCard ? null : s.PaperSize;

    /// <summary>The printer for copies (and for the ID card): null for the default printer. Saved with the settings.</summary>
    public void SetCopyPrinter(string? name)
    {
        if (IsBusy) return;
        var defaultName = _printers?.FirstOrDefault(p => p.IsDefault)?.Name;
        // Choosing the default printer follows the default, should it change.
        string? stored = name is not null && defaultName is not null && SameName(name, defaultName) ? null : name;
        if (Settings.TaskOptions.CopyPrinterName == stored) return;
        Settings.TaskOptions.CopyPrinterName = stored;
        SettingsEdited();
        _ = RefreshCopySetupAsync();
        NotifyAll();
    }

    /// <summary>How many copies to print (1 to 99).</summary>
    public void SetCopyCount(int count)
    {
        int clamped = PrintCopies.Clamp(count);
        if (IsBusy || Settings.TaskOptions.CopyCount == clamped) return;
        Settings.TaskOptions.CopyCount = clamped;
        SettingsEdited();
        NotifyAll();
    }

    /// <summary>Copies are made smaller to fit the printable area (on), or printed at real size (off).</summary>
    public void SetCopyFitToPage(bool fit)
    {
        if (IsBusy || Settings.TaskOptions.CopyFitToPage == fit) return;
        Settings.TaskOptions.CopyFitToPage = fit;
        SettingsEdited();
        NotifyAll();
    }

    /// <summary>Each copy is also saved as a PDF.</summary>
    public void SetCopyAlsoSavePdf(bool save)
    {
        if (IsBusy || Settings.TaskOptions.CopyAlsoSavePdf == save) return;
        Settings.TaskOptions.CopyAlsoSavePdf = save;
        SettingsEdited();
        NotifyAll();
    }

    /// <summary>
    /// Before a copy is scanned: the printer it goes to, asked for the paper chosen; and, on the glass
    /// with nothing selected and Automatic paper, the part of the glass that paper covers from the
    /// corner (a copier copies the sheet it prints on).
    /// </summary>
    private async Task<(PrinterSetup Setup, RectD? Selection)> PrepareCopyAsync(ScanSettings s, RectD? selection)
    {
        StatusMessage = "Getting the printer ready…";
        NotifyAll();
        var setup = await SetupForAsync(s, RequestedPaper(s)) ?? throw new PrintException(PrintText.NoPrinterMessage);
        if (s.Source == ScanSource.Flatbed && SelectionRect is null && s.PaperSize == PaperSize.Auto
            && Capabilities is { FlatbedSizeInches: var bed } && bed.Width > 0 && bed.Height > 0)
        {
            var paper = setup.Paper.Paper;
            selection = new RectD(0, 0, Math.Min(1, paper.Width / bed.Width), Math.Min(1, paper.Height / bed.Height));
        }
        return (setup, selection);
    }

    /// <summary>
    /// Prints the pages of a copy: each at real size (or fitted, when chosen) on the printer's paper,
    /// against the corner as it lay on the glass or centred when an area was selected, as many copies
    /// as asked, in grey for a grey or black-and-white scan; then saves them as a PDF too when asked,
    /// also when printing failed (the pages are kept nowhere else; the print error is reported after).
    /// The status says where they went and what the printer's margins cut off.
    /// </summary>
    private async Task PrintCopyPages(List<ScannedPage> pages, ScanSettings s, PrinterSetup setup, bool areaSelected,
                                   CancellationToken token)
    {
        var options = s.TaskOptions;
        var mode = options.CopyFitToPage ? PrintMode.FitToPrintable : PrintMode.ActualSize;
        var align = PrintLayout.AlignFor(areaSelected);
        var printPages = pages
            .Select(p => new PrintPage(p.Image, p.Dpi, PrintLayout.Place(p.Image.Width, p.Image.Height, p.Dpi, setup.Paper, mode, align)))
            .ToList();
        int copies = PrintCopies.Clamp(options.CopyCount);
        var plan = PrintCopies.Plan(copies, setup.MaxCopyCount, printPages.Count, setup.CanCollate);
        var job = new PrintJob(setup.PrinterName, "Copy", setup.Paper, RequestedPaper(s), printPages,
                               plan, Gray: s.ColorMode != ColorMode.Color);
        StatusMessage = $"Printing on {setup.PrinterName}…";
        NotifyAll();
        Exception? printError = null;
        try
        {
            await _print.PrintAsync(job, token);
        }
        catch (Exception e) when (options.CopyAlsoSavePdf && !IsCancellation(e) && e is not OutOfMemoryException)
        {
            // The PDF asked for is still written: the pages are kept nowhere else.
            printError = e;
        }
        string sent = PrintText.Sent(pages.Count, copies, setup.PrinterName);
        string? warning = printPages.Select(p => PrintLayout.ClipWarning(p.Placement, setup.Paper.Paper)).FirstOrDefault(w => w is not null);
        string warningNote = warning is null ? "" : $" {warning}";
        if (!options.CopyAlsoSavePdf)
        {
            StatusMessage = sent + warningNote;
            return;
        }
        StatusMessage = "Saving the PDF…";
        NotifyAll();
        // After a copy went to the printer, a PDF that cannot be written is reported, not undone.
        string path;
        try
        {
            path = await WritePdfAtomically(pages, s, OutputPath(s, "pdf"), token);
        }
        catch (Exception e) when (IsCancellation(e))
        {
            if (printError is not null) throw CopyNotPrinted(printError, setup, " The PDF was not saved (cancelled).");
            // The copy has gone to the printer: only the PDF was cancelled.
            StatusMessage = $"{sent} PDF not saved (cancelled).";
            return;
        }
        catch (Exception e) when (printError is not null && e is not OutOfMemoryException)
        {
            throw CopyNotPrinted(printError, setup, $" The PDF could not be saved either: {e.Message}");
        }
        MarkSaved([path]);
        if (printError is not null) throw CopyNotPrinted(printError, setup, $" The scan was saved as {Path.GetFileName(path)}.");
        StatusMessage = $"{sent} Saved {Path.GetFileName(path)}{PdfSizeSuffix()}.{warningNote}";
    }

    /// <summary>The error of a copy that could not be printed: why, then what became of its PDF.</summary>
    private static PrintException CopyNotPrinted(Exception printError, PrinterSetup setup, string pdfNote) =>
        new((printError is PrintException ? printError.Message : $"Could not print on {setup.PrinterName}: {printError.Message}") + pdfNote,
            printError);

    /// <summary>
    /// Prints the ID card's page: both sides at real size, laid out on the paper the printer prints
    /// on (the review's paper when the printer has it), one copy, on the printer chosen for copies.
    /// The review stays open: the card is still saved or discarded there.
    /// </summary>
    public Task PrintIdCard()
    {
        if (IdCardFront is null) return Task.CompletedTask;
        var s = Settings.Clone();
        var paper = IdCardPaperSize;
        return RunExclusive(async token =>
        {
            // A crop correction applied just before printing must be on the paper.
            await Settled(_recropChain);
            if (IdCardFront is not { } frontItem) return;
            var frontPhoto = frontItem.Photo;
            var backPhoto = IdCardBack?.Photo;
            int frontTurns = frontPhoto.RotationQuarterTurns, backTurns = backPhoto?.RotationQuarterTurns ?? 0;
            StatusMessage = "Getting the printer ready…";
            NotifyAll();
            var setup = await SetupForAsync(s, paper) ?? throw new PrintException(PrintText.NoPrinterMessage);
            token.ThrowIfCancellationRequested();
            var paperInches = setup.Paper.Paper;
            int dpi = IdCardComposer.PageDpi(frontPhoto.Dpi);
            var (page, layout) = await Task.Run(() =>
            {
                var f = IdCardSideOf(frontPhoto, frontTurns);
                var b = backPhoto is null ? null : IdCardSideOf(backPhoto, backTurns);
                return (IdCardComposer.Compose(f, b, dpi, paperInches), IdCardLayout.Place(f.Inches, b?.Inches, paperInches));
            }, token);
            // The page is the paper; what matters is whether the printer's margins reach the card.
            double clipped = PrintLayout.ClippedInches(layout.Front, setup.Paper.Printable);
            if (layout.Back is { } backRect) clipped = Math.Max(clipped, PrintLayout.ClippedInches(backRect, setup.Paper.Printable));
            var placement = new PrintPlacement(new RectD(0, 0, paperInches.Width, paperInches.Height), 1, 0, clipped);
            var job = new PrintJob(setup.PrinterName, "ID card", setup.Paper, paper,
                                   [new PrintPage(page, dpi, placement)], new PrintCopiesPlan(1, 1),
                                   Gray: s.ColorMode != ColorMode.Color);
            StatusMessage = $"Printing the ID card on {setup.PrinterName}…";
            NotifyAll();
            await _print.PrintAsync(job, token);
            string size = layout.ScaledToFit ? "made smaller to fit" : "at real size";
            string? warning = PrintLayout.ClipWarning(placement, paperInches);
            StatusMessage = $"Sent the ID card to {setup.PrinterName} on {setup.Paper.Description}, {size}."
                            + (warning is null ? "" : $" {warning}");
        });
    }

    /// <summary>
    /// Prints a page with a 1-inch grid and centimetre ticks at real size on the printer chosen for
    /// copies, to check with a ruler that copies come out at real size.
    /// </summary>
    public Task PrintRulerPage()
    {
        var s = Settings.Clone();
        return RunExclusive(async token =>
        {
            StatusMessage = "Getting the printer ready…";
            NotifyAll();
            var setup = await SetupForAsync(s, RequestedPaper(s)) ?? throw new PrintException(PrintText.NoPrinterMessage);
            token.ThrowIfCancellationRequested();
            const int dpi = 300;
            var page = await Task.Run(() => PrintCalibration.MakeRulerPage(setup.Paper.Paper, dpi), token);
            var placement = PrintLayout.Place(page.Width, page.Height, dpi, setup.Paper, PrintMode.ActualSize, PrintAlign.PaperOrigin);
            var job = new PrintJob(setup.PrinterName, "Ruler test page", setup.Paper, RequestedPaper(s),
                                   [new PrintPage(page, dpi, placement)], new PrintCopiesPlan(1, 1), Gray: true);
            StatusMessage = $"Printing the ruler test page on {setup.PrinterName}…";
            NotifyAll();
            await _print.PrintAsync(job, token);
            StatusMessage = $"Sent the ruler test page to {setup.PrinterName}. At real size each square measures 1 inch (2.54 cm) and each tick 1 cm.";
        });
    }
}
