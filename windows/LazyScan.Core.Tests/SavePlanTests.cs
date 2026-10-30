using LazyScan.Core;
using Xunit;

namespace LazyScan.Core.Tests;

// Twin of Tests/LazyScanTests/SavePlanTests.swift: the same cases.

public class SavePlanTests
{
    private static ScannedPage MakePage(PatchCode? patch = null, bool blank = false) =>
        new ScannedPage(RgbaImage.Filled(4, 4, 255, 255, 255), 300, ColorMode.Color)
            .WithPatch(patch)
            .WithBlank(blank ? new BlankPageResult(0, 0, false, true) : null);

    [Fact]
    public void Make_TheDocumentsOfTheSplit_WithTheQueuesPages()
    {
        var queue = new List<ScannedPage>
        {
            MakePage(), MakePage(), MakePage(PatchCode.PatchT), MakePage(blank: true), MakePage().WithDocumentLabel("Lease"),
        };
        var options = new DocumentOptions { SplitMode = SplitMode.SeparatorSheet, RemoveBlankPages = true };
        var plan = SavePlan.Make(queue, options);
        Assert.Equal(2, plan.Documents.Count);
        Assert.Equal([queue[0].Id, queue[1].Id], plan.Documents[0].Pages.Select(p => p.Id));
        Assert.Equal([queue[4].Id], plan.Documents[1].Pages.Select(p => p.Id));
        Assert.Equal([null, "Lease"], plan.Documents.Select(d => d.Label));
        Assert.Equal((3, 1, 1), (plan.PageCount, plan.SeparatorPages, plan.SkippedPages));
        Assert.True(plan.IsSplit);
        Assert.False(plan.IsEmpty);
        Assert.Equal([1, 2], plan.Documents.Select(plan.FileIndex));

        var whole = SavePlan.Make(queue, new DocumentOptions());
        Assert.Single(whole.Documents);
        Assert.Null(whole.FileIndex(whole.Documents[0]));
        Assert.Equal((5, 0, 0), (whole.PageCount, whole.SeparatorPages, whole.SkippedPages));

        Assert.True(SavePlan.Make([MakePage(PatchCode.Patch2)], options).IsEmpty);
    }

    [Fact]
    public void Texts()
    {
        var one = new SavePlan([new SaveDocument(1, [MakePage(), MakePage()], null)], 0, 0);
        Assert.Equal("Save PDF (2 pages)", one.SaveTitle(OutputFormat.Pdf));
        Assert.Equal(OutputFormats.SaveTitle(OutputFormat.Word, 2), one.SaveTitle(OutputFormat.Word));
        Assert.Equal("", one.LeftOutNote());

        var three = new SavePlan(
            [new SaveDocument(1, [MakePage(), MakePage()], null), new SaveDocument(2, [MakePage()], "Lease"), new SaveDocument(3, [MakePage()], null)],
            2, 1);
        Assert.Equal("Save 3 PDFs (4 pages)", three.SaveTitle(OutputFormat.Pdf));
        Assert.Equal("Save 3 PDFs (4 pages)", three.SaveTitle(OutputFormat.Jpeg));
        Assert.Equal("Save 3 Word documents (4 pages)", three.SaveTitle(OutputFormat.Word));
        Assert.Equal("Save 3 text files (4 pages)", three.SaveTitle(OutputFormat.Text));
        Assert.Equal(" — 2 separator pages and 1 skipped page were left out", three.LeftOutNote());
        Assert.Equal("Saved 3 PDFs (4 pages): A.pdf, B.pdf, C.pdf — 2 separator pages and 1 skipped page were left out",
                     three.SavedMessage(OutputFormat.Pdf, ["A.pdf", "B.pdf", "C.pdf"]));
        // Like a single save: the size, the text beside the PDFs, and files with no text in them.
        Assert.Equal("Saved 3 PDFs (4 pages, 1.2 MB): A.pdf, B.pdf, C.pdf and their text, A.txt, B.txt, C.txt — 2 separator pages and 1 skipped page were left out",
                     three.SavedMessage(OutputFormat.Pdf, ["A.pdf", "B.pdf", "C.pdf"], "1.2 MB", ["A.txt", "B.txt", "C.txt"]));
        Assert.Equal("Saved 3 text files (4 pages): A.txt, B.txt, C.txt — no text was found — 2 separator pages and 1 skipped page were left out",
                     three.SavedMessage(OutputFormat.Text, ["A.txt", "B.txt", "C.txt"], noTextFound: ["A.txt", "B.txt", "C.txt"]));
        Assert.Equal("Saved 3 Word documents (4 pages): A.docx, B.docx, C.docx — no text was found in B.docx — 2 separator pages and 1 skipped page were left out",
                     three.SavedMessage(OutputFormat.Word, ["A.docx", "B.docx", "C.docx"], noTextFound: ["B.docx"]));
        Assert.Equal("Saved 3 PDFs (4 pages): A.pdf, B.pdf, C.pdf — 2 separator pages and 1 skipped page were left out",
                     three.SavedMessage(OutputFormat.Pdf, ["A.pdf", "B.pdf", "C.pdf"], null, [], []));

        Assert.Equal(" — 1 skipped page was left out", (one with { SkippedPages = 1 }).LeftOutNote());
        Assert.Equal(" — 3 skipped pages were left out", (one with { SkippedPages = 3 }).LeftOutNote());
        Assert.Equal(" — 1 separator page was left out", (one with { SeparatorPages = 1 }).LeftOutNote());
        Assert.Equal(" — 2 separator pages were left out", (one with { SeparatorPages = 2 }).LeftOutNote());
        Assert.Equal(" — 1 separator page and 2 skipped pages were left out", (one with { SeparatorPages = 1, SkippedPages = 2 }).LeftOutNote());
        Assert.Equal("None of the documents was saved; the pages are still in the queue. The disk is full.",
                     SavePlan.NotSavedMessage("The disk is full."));
        Assert.Equal(["PDF", "PDFs", "Word document", "Word documents", "text file", "text files"],
                     new[] { (OutputFormat.Pdf, 1), (OutputFormat.Pdf, 2), (OutputFormat.Word, 1), (OutputFormat.Word, 2),
                             (OutputFormat.Text, 1), (OutputFormat.Text, 2) }.Select(c => SavePlan.FileKind(c.Item1, c.Item2)));
    }

    private static string TempFolder()
    {
        string folder = Path.Combine(Path.GetTempPath(), "LazyScanTests", "SavePlan-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(folder);
        return folder;
    }

    [Fact]
    public async Task WriteAllOrNothing_KeepsEveryFile_WhenItFinishes()
    {
        string folder = TempFolder();
        try
        {
            var files = new WrittenFiles();
            await SavePlan.WriteAllOrNothingAsync(files, async () =>
            {
                foreach (string name in new[] { "a.pdf", "a.txt", "b.pdf" })
                {
                    string path = Path.Combine(folder, name);
                    await File.WriteAllTextAsync(path, name);
                    files.Add(path);
                }
            });
            Assert.Equal(3, files.Paths.Count);
            Assert.All(files.Paths, path => Assert.True(File.Exists(path)));
        }
        finally
        {
            Directory.Delete(folder, recursive: true);
        }
    }

    [Fact]
    public async Task WriteAllOrNothing_RemovesWhatItWrote_WhenItFailsOrIsCancelled()
    {
        string folder = TempFolder();
        try
        {
            foreach (var failure in new Exception[] { new IOException("The disk is full."), new OperationCanceledException() })
            {
                var files = new WrittenFiles();
                string other = Path.Combine(folder, "not ours.pdf");
                await File.WriteAllTextAsync(other, "kept");
                var thrown = await Assert.ThrowsAnyAsync<Exception>(() => SavePlan.WriteAllOrNothingAsync(files, async () =>
                {
                    string path = Path.Combine(folder, "a.pdf");
                    await File.WriteAllTextAsync(path, "a");
                    files.Add(path);
                    files.Add(Path.Combine(folder, "never written.pdf"));
                    throw failure;
                }));
                Assert.Same(failure, thrown);
                Assert.Empty(files.Paths);
                Assert.Equal(["not ours.pdf"], Directory.GetFiles(folder).Select(Path.GetFileName));
            }
        }
        finally
        {
            Directory.Delete(folder, recursive: true);
        }
    }
}
