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
}
