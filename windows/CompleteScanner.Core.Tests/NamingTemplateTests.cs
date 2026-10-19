using CompleteScanner.Core;
using Xunit;

namespace CompleteScanner.Core.Tests;

// Port of Tests/CompleteScannerTests/NamingTemplateTests.swift — the same cases, so the two
// implementations stay behaviorally identical.

public class NamingTemplateTests
{
    /// <summary>2026-08-13 14:05:09, so formatter output is deterministic.</summary>
    private static DateTime FixedDate() => new(2026, 8, 13, 14, 5, 9);

    private static string Render(string template, int counter = 1,
                                 ScanIntent intent = ScanIntent.Document, int? index = null) =>
        new NamingTemplate(template).BaseFilename(counter, FixedDate(), intent, index);

    [Fact]
    public void DateToken() => Assert.Equal("2026-08-13", Render("{date}"));

    [Fact]
    public void TimeToken() => Assert.Equal("14.05.09", Render("{time}"));

    [Fact]
    public void YearMonthDayTokens()
    {
        Assert.Equal("2026", Render("{year}"));
        Assert.Contains(Render("{month}"), new[] { "08", "8" });
        Assert.Equal("13", Render("{day}"));
    }

    [Fact]
    public void CounterToken()
    {
        Assert.Equal("7", Render("{counter}", counter: 7));
        Assert.Equal("123", Render("{counter}", counter: 123));
    }

    [Fact]
    public void CounterZeroPadding()
    {
        Assert.Equal("0007", Render("{counter:4}", counter: 7));
        Assert.Equal("0123", Render("{counter:4}", counter: 123));
    }

    [Fact]
    public void IntentToken()
    {
        Assert.Equal("Document", Render("{intent}", intent: ScanIntent.Document));
        Assert.Equal("Photos", Render("{intent}", intent: ScanIntent.Photo));
    }

    [Fact]
    public void IndexTokenSubstituted() => Assert.Equal("Photo 7", Render("Photo {index}", index: 7));

    [Fact]
    public void IndexNullLeavesNoResidue()
    {
        string result = Render("Photo {index}", index: null);
        Assert.DoesNotContain("{", result);
        Assert.DoesNotContain("}", result);
        Assert.Equal("Photo", result.Trim());
    }

    [Fact]
    public void IndexAppendedWhenTokenAbsent()
    {
        string result = Render("Photo", index: 3);
        Assert.StartsWith("Photo", result);
        Assert.Contains("3", result);
    }

    [Fact]
    public void UnknownTokenPassesThrough() => Assert.Equal("{bogus}", Render("{bogus}"));

    [Fact]
    public void Sanitization() => Assert.Equal("a-b-c", Render("a/b:c"));

    [Fact]
    public void WindowsReservedCharactersSanitized()
    {
        // Windows-specific extension of the Swift behavior: the full reserved set is stripped.
        string result = Render(@"a\b*c?d""e<f>g|h");
        Assert.Equal("a-b-c-d-e-f-g-h", result);
    }

    [Fact]
    public void CombinedTemplate() =>
        Assert.Equal("Scan 2026-08-13 4", Render("Scan {date} {counter}", counter: 4));

    // MARK: - NamingContext and {task}

    private static string Render(string template, NamingContext context) =>
        new NamingTemplate(template).BaseFilename(context);

    [Fact]
    public void TaskToken_IsTheTasksFileLabel()
    {
        var context = new NamingContext(1, FixedDate(), ScanIntent.Photo) { Task = ScanTask.PhotoRestore };
        Assert.Equal("Restored photo 2026-08-13", Render("{task} {date}", context));
        Assert.Equal("Document 3", Render("{task} {counter}",
            new NamingContext(3, FixedDate(), ScanIntent.Document) { Task = ScanTask.Feeder }));
        Assert.Equal("Scan", Render("{task}",
            new NamingContext(1, FixedDate(), ScanIntent.Document) { Task = ScanTask.QuickScan }));
    }

    [Fact]
    public void TaskToken_WithoutATask_IsTheIntent()
    {
        Assert.Equal("Photos 2026-08-13", Render("{task} {date}", new NamingContext(1, FixedDate(), ScanIntent.Photo)));
        Assert.Equal("Document", Render("{task}", new NamingContext(1, FixedDate(), ScanIntent.Document)));
        // The old overload has no task.
        Assert.Equal("Photos", Render("{task}", intent: ScanIntent.Photo));
    }

    [Fact]
    public void Context_GivesTheSameNamesAsTheOldOverload()
    {
        foreach (string template in new[] { "Scan {date} {counter}", "{counter:3} {intent} {time}", "Photo", "Photo {index}" })
        {
            foreach (int? index in new int?[] { null, 4 })
            {
                Assert.Equal(Render(template, counter: 12, intent: ScanIntent.Photo, index: index),
                             Render(template, new NamingContext(12, FixedDate(), ScanIntent.Photo) { Index = index }));
            }
        }
    }

    [Fact]
    public void Context_IndexAndTaskTogether()
    {
        var context = new NamingContext(7, FixedDate(), ScanIntent.Photo) { Index = 2, Task = ScanTask.Photos };
        Assert.Equal("Photo 7 2", Render("{task} {counter}", context));
        Assert.Equal("Photo 2 of batch 7", Render("{task} {index} of batch {counter}", context));
    }

    [Fact]
    public void UniquePathSuffixes()
    {
        string dir = Path.Combine(Path.GetTempPath(), $"NamingTemplateTests-{Guid.NewGuid()}");
        Directory.CreateDirectory(dir);
        try
        {
            string first = NamingTemplate.UniquePath(dir, "Report", "pdf");
            Assert.Equal("Report.pdf", Path.GetFileName(first));
            File.WriteAllBytes(first, []);

            string second = NamingTemplate.UniquePath(dir, "Report", "pdf");
            Assert.Equal("Report 2.pdf", Path.GetFileName(second));
            File.WriteAllBytes(second, []);

            string third = NamingTemplate.UniquePath(dir, "Report", "pdf");
            Assert.Equal("Report 3.pdf", Path.GetFileName(third));
        }
        finally
        {
            Directory.Delete(dir, recursive: true);
        }
    }

    [Fact]
    public void MoveToFreePathMovesToAFreeName()
    {
        string dir = Path.Combine(Path.GetTempPath(), $"NamingTemplateTests-{Guid.NewGuid()}");
        Directory.CreateDirectory(dir);
        try
        {
            string source = Path.Combine(dir, ".tmp");
            File.WriteAllText(source, "new");
            string target = Path.Combine(dir, "Report.pdf");
            Assert.Equal(target, NamingTemplate.MoveToFreePath(source, target));
            Assert.Equal("new", File.ReadAllText(target));
            Assert.False(File.Exists(source));
        }
        finally
        {
            Directory.Delete(dir, recursive: true);
        }
    }

    [Fact]
    public void MoveToFreePathNeverOverwritesAndTakesTheNextFreeSuffix()
    {
        string dir = Path.Combine(Path.GetTempPath(), $"NamingTemplateTests-{Guid.NewGuid()}");
        Directory.CreateDirectory(dir);
        try
        {
            // The name was free when it was picked, then two other files landed.
            string target = Path.Combine(dir, "Report.pdf");
            File.WriteAllText(target, "first");
            File.WriteAllText(Path.Combine(dir, "Report 2.pdf"), "second");
            string source = Path.Combine(dir, ".tmp");
            File.WriteAllText(source, "new");

            string written = NamingTemplate.MoveToFreePath(source, target);

            Assert.Equal(Path.Combine(dir, "Report 3.pdf"), written);
            Assert.Equal("first", File.ReadAllText(target));
            Assert.Equal("second", File.ReadAllText(Path.Combine(dir, "Report 2.pdf")));
            Assert.Equal("new", File.ReadAllText(written));
            Assert.False(File.Exists(source));
        }
        finally
        {
            Directory.Delete(dir, recursive: true);
        }
    }

    [Fact]
    public void MoveToFreePathRethrowsOtherFailures()
    {
        string dir = Path.Combine(Path.GetTempPath(), $"NamingTemplateTests-{Guid.NewGuid()}");
        Directory.CreateDirectory(dir);
        try
        {
            // A missing source is not a name collision: no retry loop, the error surfaces.
            Assert.Throws<FileNotFoundException>(() =>
                NamingTemplate.MoveToFreePath(Path.Combine(dir, "missing"), Path.Combine(dir, "Report.pdf")));
            Assert.Empty(Directory.GetFiles(dir));
        }
        finally
        {
            Directory.Delete(dir, recursive: true);
        }
    }
}
