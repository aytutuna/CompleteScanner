namespace LazyScan.Core;

// Twin of Sources/CompleteScannerKit/Core/SavePlan.swift.

/// <summary>A document of the queue as saved: its number (from 1), its pages in order and its name, if any.</summary>
public sealed record SaveDocument(int Number, IReadOnlyList<ScannedPage> Pages, string? Label);

/// <summary>
/// What saving the collected pages writes: the documents of the split plan
/// (<see cref="DocumentSplitter"/>), each its own file, and what is left out. The files of one
/// save are written all or nothing (<see cref="WriteAllOrNothingAsync"/>): a save that fails or is
/// cancelled part-way removes what it wrote, so the queue, which stays as it was, can be saved
/// again without duplicates.
/// </summary>
public sealed record SavePlan(IReadOnlyList<SaveDocument> Documents, int SeparatorPages, int SkippedPages)
{
    /// <summary>The plan for saving <paramref name="queue"/> with <paramref name="options"/>.</summary>
    public static SavePlan Make(IReadOnlyList<ScannedPage> queue, DocumentOptions options)
    {
        var plan = DocumentSplitter.Plan(queue, options);
        var documents = plan.Documents
            .Select(d => new SaveDocument(d.Number, d.Pages.Select(i => queue[i]).ToList(), d.Label))
            .ToList();
        return new SavePlan(documents, plan.SeparatorCount, plan.SkippedCount);
    }

    /// <summary>The pages written, in every document.</summary>
    public int PageCount => Documents.Sum(d => d.Pages.Count);

    /// <summary>Nothing would be written: every page is left out.</summary>
    public bool IsEmpty => Documents.Count == 0;

    /// <summary>More than one file is written.</summary>
    public bool IsSplit => Documents.Count > 1;

    /// <summary>The {index} of the document's file name: its number when the queue is split, else none.</summary>
    public int? FileIndex(SaveDocument document) => IsSplit ? document.Number : null;

    /// <summary>"PDF", "PDFs", "Word document", "text files": what the collected pages are saved as.</summary>
    public static string FileKind(OutputFormat format, int count) => OutputFormats.QueueFormat(format) switch
    {
        OutputFormat.Word => count == 1 ? "Word document" : "Word documents",
        OutputFormat.Text => count == 1 ? "text file" : "text files",
        _ => count == 1 ? "PDF" : "PDFs",
    };

    /// <summary>
    /// The save button: "Save 3 PDFs (7 pages)" for a split queue, otherwise
    /// <see cref="OutputFormats.SaveTitle(OutputFormat, int)"/> ("Save PDF (7 pages)").
    /// </summary>
    public string SaveTitle(OutputFormat format) =>
        IsSplit
            ? $"Save {Documents.Count} {FileKind(format, Documents.Count)} ({PageCount} page{(PageCount == 1 ? "" : "s")})"
            : OutputFormats.SaveTitle(format, PageCount);

    /// <summary>
    /// What was left out, after the saved message: " — 1 skipped page was left out", " — 2 separator
    /// pages were left out", " — 2 separator pages and 1 skipped page were left out"; empty when nothing was.
    /// </summary>
    public string LeftOutNote()
    {
        int s = SeparatorPages, k = SkippedPages;
        if (s == 0 && k == 0) return "";
        if (s == 0) return $" — {k} skipped page{(k == 1 ? " was" : "s were")} left out";
        if (k == 0) return $" — {s} separator page{(s == 1 ? " was" : "s were")} left out";
        return $" — {s} separator page{(s == 1 ? "" : "s")} and {k} skipped page{(k == 1 ? "" : "s")} were left out";
    }

    /// <summary>
    /// "Saved 3 PDFs (7 pages, 1.2 MB): A.pdf, B.pdf, C.pdf and their text, A.txt, B.txt, C.txt — 2
    /// separator pages were left out" after a split save: <paramref name="size"/> is the files' size
    /// together (null when unknown), <paramref name="textFileNames"/> the text files written beside
    /// the PDFs, and <paramref name="noTextFound"/> the Word or text files with no text in them
    /// (" — no text was found" when that is all of them, " — no text was found in B.txt" otherwise).
    /// </summary>
    public string SavedMessage(OutputFormat format, IReadOnlyList<string> fileNames, string? size = null,
                               IReadOnlyList<string>? textFileNames = null, IReadOnlyList<string>? noTextFound = null)
    {
        string pages = $"{PageCount} page{(PageCount == 1 ? "" : "s")}" + (size is null ? "" : $", {size}");
        string text = textFileNames is { Count: > 0 } names ? " and their text, " + string.Join(", ", names) : "";
        string empty = noTextFound is not { Count: > 0 } none
            ? ""
            : none.Count == fileNames.Count
            ? " — no text was found"
            : " — no text was found in " + string.Join(", ", none);
        return $"Saved {fileNames.Count} {FileKind(format, fileNames.Count)} ({pages}): "
               + string.Join(", ", fileNames) + text + empty + LeftOutNote();
    }

    /// <summary>The error when a split save fails: nothing of it is kept, and the queue is still there.</summary>
    public static string NotSavedMessage(string reason) =>
        $"None of the documents was saved; the pages are still in the queue. {reason}";

    /// <summary>
    /// Runs <paramref name="write"/>, which records every file it writes in <paramref name="files"/>;
    /// when it fails or is cancelled, every file recorded is removed again and the exception goes on.
    /// Once <paramref name="write"/> has finished the save counts as done.
    /// </summary>
    public static async Task WriteAllOrNothingAsync(WrittenFiles files, Func<Task> write)
    {
        try
        {
            await write();
        }
        catch
        {
            files.RollBack();
            throw;
        }
    }
}

/// <summary>The files one save has written so far, so that a save that does not finish can remove them (<see cref="SavePlan.WriteAllOrNothingAsync"/>).</summary>
public sealed class WrittenFiles
{
    private readonly List<string> _paths = [];

    /// <summary>The files written, in order.</summary>
    public IReadOnlyList<string> Paths => _paths;

    public void Add(string path) => _paths.Add(path);

    /// <summary>Deletes every file written (best effort) and forgets them.</summary>
    public void RollBack()
    {
        foreach (string path in _paths)
        {
            try { File.Delete(path); } catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
        }
        _paths.Clear();
    }
}
