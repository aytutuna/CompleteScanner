using System.IO;
using LazyScan.App.Services;
using LazyScan.Core;

namespace LazyScan.App;

/// <summary>
/// Adding the queued pages to the end of an existing PDF the user picks (Add to existing PDF… under
/// the queue, or a PDF's menu in the Saved tab), as an incremental update (<see cref="PdfAppender"/>).
/// The Mac and the iPhone add pages the same way (Sources/LazyScanKit/App/AppState+Append.swift).
/// A PDF picked before scanning (<see cref="AppendTarget"/>) takes the queue when it is saved.
/// </summary>
public sealed partial class AppViewModel
{
    /// <summary>
    /// Asks whether to add pages to a file despite what <see cref="PdfAppendTarget.Warnings"/> say (a
    /// signed file, a PDF/A level the pages may not keep): the window shows a Yes/No question; no
    /// answer, or nobody to ask, adds nothing.
    /// </summary>
    public Func<string, bool>? ConfirmAppend { get; set; }

    /// <summary>
    /// The PDF Save adds the queue to instead of writing a new file (the start screen's "Add pages to
    /// a PDF"); null otherwise. Kept for this session only.
    /// </summary>
    public string? AppendTarget { get; private set; }

    /// <summary>
    /// Makes Save add the queue to <paramref name="path"/> (read when the pages are added, not now)
    /// until the pages are in or <see cref="ClearAppendTarget"/> is called.
    /// </summary>
    public void SetAppendTarget(string path)
    {
        AppendTarget = path;
        NotifyAll();
    }

    /// <summary>Save writes a new file again.</summary>
    public void ClearAppendTarget()
    {
        AppendTarget = null;
        NotifyAll();
    }

    /// <summary>There are pages to add (some are not left out) and nothing else is running.</summary>
    public bool CanAppendPages =>
        !IsBusy && SavePlan.Make([.. ScannedPages.Select(p => p.Page)], Settings.Document).PageCount > 0;

    /// <summary>
    /// Adds the pages the queue would save (all its documents, in order; pages left out stay out) to
    /// the end of <paramref name="targetPath"/>, stored as the PDF size and the text layer settings
    /// say. The file is read first: a password-protected, damaged or unreadable file, or one that
    /// is read-only or open in another app, is refused with what to do, and the pages stay in the
    /// queue. The file decides the rest: no password is added (the password switch is for new
    /// files) and a PDF/A file stays one where it can (<see cref="PdfAppender.KeepsPdfA"/>), with a
    /// question first where it may not, or where it is signed. Once the pages are in, the queue is
    /// cleared and the file is offered like a saved one, with the after-save action, and the
    /// <see cref="AppendTarget"/> is cleared.
    /// </summary>
    public Task AppendToPdf(string targetPath)
    {
        if (ScannedPages.Count == 0) return Task.CompletedTask;
        var s = Settings.Clone();
        return RunExclusive(async token =>
        {
            // Let page rotations that were clicked before land first.
            await Settled(_pageRotateChain);
            var queued = ScannedPages.Select(p => p.Page).ToList();
            if (queued.Count == 0) return;
            var plan = SavePlan.Make(queued, s.Document);
            if (plan.IsEmpty)
            {
                ErrorMessage = PageFilter.NothingToSaveMessage;
                StatusMessage = DocumentSplitter.QueueSummary(queued, s.Document) + ".";
                return;
            }
            string name = Path.GetFileName(targetPath);
            StatusMessage = $"Reading {name}…";
            NotifyAll();
            var target = await Task.Run(() => PdfAppender.Inspect(targetPath), token);
            if (target.ConfirmMessage is { } question && ConfirmAppend?.Invoke(question) != true)
            {
                StatusMessage = $"Nothing was added to {name}.";
                return;
            }
            var pages = plan.Documents.SelectMany(d => d.Pages).ToList();
            StatusMessage = s.PdfSearchable ? "Running OCR and adding pages…" : "Adding pages…";
            NotifyAll();
            var inputs = await PdfPageInputs(pages, s, token);
            StatusMessage = $"Adding {pages.Count} {(pages.Count == 1 ? "page" : "pages")} to {name}…";
            NotifyAll();
            var result = await Task.Run(() => PdfAppender.AppendToFile(targetPath, inputs, progress: null, token), token);
            LastPdfBytes = result.Bytes;
            LastPdfProtected = false;
            MarkSaved([result.Path]);
            AppendTarget = null;
            DeleteSpoolFiles(queued);
            ScannedPages.Clear();
            ResetFlow();
            StatusMessage = PdfAppender.AddedMessage(pages.Count, name, result.PageCount, SavedFiles.SizeText(result.Bytes))
                            + plan.LeftOutNote()
                            + (s.Output.Protect ? ". " + PdfAppender.NoPasswordNote : "");
            RunAfterSave(s.Output.AfterSave, [result.Path]);
        });
    }
}
