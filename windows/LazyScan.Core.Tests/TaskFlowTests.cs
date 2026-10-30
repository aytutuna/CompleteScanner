using LazyScan.Core;
using Xunit;

namespace LazyScan.Core.Tests;

// Mirrored by Tests/CompleteScannerTests/TaskFlowTests.swift: the same cases.

public class TaskFlowTests
{
    /// <summary>A two-sided card: front, then an optional back, then a review that captures nothing.</summary>
    private static TaskFlow CardFlow() => new(
    [
        new TaskStep("front", "Front", "Place the card face down.", "Scan front"),
        new TaskStep("back", "Back", "Turn the card over.", "Scan back", Skippable: true, RequiresCapture: false),
        new TaskStep("review", "Review", "Check both sides.", "Save", RequiresCapture: false),
    ]);

    private static readonly Guid A = Guid.Parse("00000000-0000-0000-0000-00000000000a");
    private static readonly Guid B = Guid.Parse("00000000-0000-0000-0000-00000000000b");
    private static readonly Guid C = Guid.Parse("00000000-0000-0000-0000-00000000000c");

    [Fact]
    public void StartsAtTheFirstStep()
    {
        var flow = CardFlow();
        Assert.Equal(0, flow.StepIndex);
        Assert.Equal(3, flow.StepCount);
        Assert.Equal("front", flow.Current?.Id);
        Assert.False(flow.IsComplete);
        Assert.False(flow.CanFinish);
    }

    [Fact]
    public void Advance_NeedsTheCapture()
    {
        var flow = CardFlow();
        Assert.False(flow.Advance());
        Assert.Equal("front", flow.Current?.Id);

        Assert.Empty(flow.Record("front", A));
        Assert.True(flow.CanFinish);
        Assert.Equal("front", flow.Current?.Id);
        Assert.True(flow.Advance());
        Assert.Equal("back", flow.Current?.Id);
    }

    [Fact]
    public void FinishOnlyAfterTheFront()
    {
        var flow = CardFlow();
        flow.Record("back", B);
        Assert.False(flow.CanFinish);
        flow.Record("front", A);
        Assert.True(flow.CanFinish);
    }

    [Fact]
    public void NonRepeatingStep_KeepsTheNewestCapture()
    {
        var flow = CardFlow();
        flow.Record("front", A);
        Assert.Equal([A], flow.Record("front", B));
        Assert.Equal([B], flow.Captures("front"));
    }

    [Fact]
    public void RepeatingStep_KeepsEveryCapture()
    {
        var flow = new TaskFlow([new TaskStep("scan", "Scan", "Scan each page.", "Scan page", Repeats: true)]);
        Assert.False(flow.CanFinish);
        Assert.Empty(flow.Record("scan", A));
        Assert.Empty(flow.Record("scan", B));
        Assert.Equal([A, B], flow.Captures("scan"));
        Assert.True(flow.CanFinish);
        Assert.Equal("scan", flow.Current?.Id);
        Assert.True(flow.Advance());
        Assert.True(flow.IsComplete);
        Assert.Null(flow.Current);
        Assert.False(flow.Advance());
    }

    [Fact]
    public void Skip_TheBack()
    {
        var flow = CardFlow();
        Assert.False(flow.Skip()); // the front cannot be skipped
        flow.Record("front", A);
        flow.Advance();
        flow.Record("back", B);
        Assert.True(flow.Skip());
        Assert.Equal("review", flow.Current?.Id);
        Assert.True(flow.IsSkipped("back"));
        Assert.Empty(flow.Captures("back"));
        Assert.True(flow.CanFinish);
        Assert.False(flow.Skip()); // the review cannot be skipped
    }

    [Fact]
    public void Retake_TheFront_FromTheReview()
    {
        var flow = CardFlow();
        flow.Record("front", A);
        flow.Advance();
        flow.Record("back", B);
        flow.Advance();
        Assert.Equal("review", flow.Current?.Id);

        Assert.Equal([A], flow.Retake("front"));
        Assert.Equal("front", flow.Current?.Id);
        Assert.Empty(flow.Captures("front"));
        Assert.Equal([B], flow.Captures("back"));
        Assert.False(flow.CanFinish);

        flow.Record("front", C);
        Assert.True(flow.Advance());
        Assert.Equal("back", flow.Current?.Id);
        Assert.Equal([B], flow.Captures("back"));
    }

    [Fact]
    public void Retake_ASkippedStep_UnskipsIt()
    {
        var flow = CardFlow();
        flow.Record("front", A);
        flow.Advance();
        flow.Skip();
        Assert.Empty(flow.Retake("back"));
        Assert.False(flow.IsSkipped("back"));
        Assert.Equal("back", flow.Current?.Id);
    }

    [Fact]
    public void Record_UnskipsAStep()
    {
        var flow = CardFlow();
        flow.Record("front", A);
        flow.Advance();
        flow.Skip();
        flow.Record("back", B);
        Assert.False(flow.IsSkipped("back"));
        Assert.Equal([B], flow.Captures("back"));
    }

    [Fact]
    public void UnknownStep_IsIgnored()
    {
        var flow = CardFlow();
        Assert.Empty(flow.Record("side", A));
        Assert.Empty(flow.Captures("side"));
        Assert.Empty(flow.Retake("side"));
        Assert.Equal(0, flow.StepIndex);
        Assert.False(flow.CanFinish);
    }

    [Fact]
    public void Reset_StartsOver()
    {
        var flow = CardFlow();
        flow.Record("front", A);
        flow.Advance();
        flow.Skip();
        flow.Reset();
        Assert.Equal(0, flow.StepIndex);
        Assert.Empty(flow.Captures("front"));
        Assert.False(flow.IsSkipped("back"));
        Assert.False(flow.CanFinish);
    }

    [Fact]
    public void Captures_AreACopy()
    {
        var flow = CardFlow();
        flow.Record("front", A);
        var captures = flow.Captures("front");
        flow.Record("front", B);
        Assert.Equal([A], captures);
    }

    [Fact]
    public void NoSteps_IsCompleteAndFinishable()
    {
        var flow = new TaskFlow([]);
        Assert.True(flow.IsComplete);
        Assert.True(flow.CanFinish);
        Assert.Null(flow.Current);
        Assert.False(flow.Advance());
        Assert.False(flow.Skip());
    }

    [Fact]
    public void CatalogFlows_OneRepeatingScanStep()
    {
        // The ID card's front, back and review are checked in IdCardTests.
        foreach (var definition in TaskCatalog.All.Where(d => d.Task != ScanTask.IdCard))
        {
            var flow = new TaskFlow(definition.Steps);
            Assert.Equal(1, flow.StepCount);
            Assert.False(flow.CanFinish);
            flow.Record("scan", A);
            flow.Record("scan", B);
            Assert.True(flow.CanFinish);
            Assert.Equal("scan", flow.Current?.Id);
        }
    }

    [Theory]
    [InlineData("Front side", "Front")]
    [InlineData("Back side", "Back")]
    [InlineData("Check and save", "Check")]
    [InlineData("Scan the front sides", "Front")]
    [InlineData("Scan the back sides", "Back")]
    [InlineData("Scan each page", "Each")]
    [InlineData("Scan", "Scan")]
    [InlineData("", "")]
    public void Word_IsTheStepInOneWord(string title, string expected)
    {
        Assert.Equal(expected, new TaskStep("x", title, "p", "a").Word);
    }

    [Fact]
    public void Words_OfEveryTaskWithSteps_AreDistinct()
    {
        foreach (var steps in TaskCatalog.All.Where(t => t.Steps.Count > 1).Select(t => t.Steps).Append(DocumentSides.ManualSteps))
        {
            var words = steps.Select(s => s.Word).ToList();
            Assert.Equal(words.Count, words.Distinct().Count());
        }
    }

    [Fact]
    public void Help_IsOptional_AndFollowsThePromptForScreenReaders()
    {
        var plain = new TaskStep("x", "Scan", "Scan it.", "Scan");
        Assert.Equal(("", "Scan it."), (plain.Help, plain.FullPrompt));
        var helped = plain with { Help = "Close the lid." };
        Assert.Equal("Scan it. Close the lid.", helped.FullPrompt);
        Assert.NotEqual(plain, helped);
    }
}
