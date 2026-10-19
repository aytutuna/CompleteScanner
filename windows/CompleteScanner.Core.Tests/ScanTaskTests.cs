using CompleteScanner.Core;
using Xunit;

namespace CompleteScanner.Core.Tests;

// Mirrored by Tests/CompleteScannerTests/ScanTaskTests.swift: the same cases.

public class ScanTaskTests
{
    [Fact]
    public void RawValues_AreTheStoredNames()
    {
        Assert.Equal(["document", "feeder", "photos", "photoRestore", "quickScan", "email", "twoSided"],
                     ScanTasks.All.Select(t => t.RawValue()));
    }

    [Fact]
    public void TryParse_IsExact()
    {
        foreach (var task in ScanTasks.All) Assert.Equal(task, ScanTasks.TryParse(task.RawValue()));
        Assert.Null(ScanTasks.TryParse(null));
        Assert.Null(ScanTasks.TryParse(""));
        Assert.Null(ScanTasks.TryParse("whiteboard"));
        Assert.Null(ScanTasks.TryParse("Document"));
        Assert.Null(ScanTasks.TryParse("photorestore"));
    }

    [Fact]
    public void Catalog_ListsEveryTaskOnce_InStartScreenOrder()
    {
        Assert.Equal(ScanTasks.All, TaskCatalog.All.Select(d => d.Task));
        Assert.Equal(["Document to PDF", "Multi-page from feeder", "Photos", "Old photo restoration", "Quick scan",
                      "Email a document", "Two-sided document"],
                     TaskCatalog.All.Select(d => d.Title));
        Assert.Equal(["document", "feeder", "photos", "restore", "quick", "email", "twoSided"],
                     TaskCatalog.All.Select(d => d.IconKey));
        foreach (var definition in TaskCatalog.All)
        {
            Assert.Same(definition, TaskCatalog.Definition(definition.Task));
            Assert.False(string.IsNullOrWhiteSpace(definition.Subtitle));
            var step = Assert.Single(definition.Steps);
            Assert.Equal("scan", step.Id);
            Assert.True(step.Repeats);
            Assert.True(step.RequiresCapture);
            Assert.False(step.Skippable);
            Assert.False(string.IsNullOrWhiteSpace(step.Prompt));
            Assert.False(string.IsNullOrWhiteSpace(step.PrimaryActionLabel));
        }
    }

    [Fact]
    public void Definitions_FlowIntentAndRequiredSource()
    {
        Assert.Equal(
            [
                (TaskFlowKind.DocumentQueue, ScanIntent.Document, (ScanSource?)null),
                (TaskFlowKind.DocumentQueue, ScanIntent.Document, ScanSource.DocumentFeeder),
                (TaskFlowKind.PhotoSplit, ScanIntent.Photo, null),
                (TaskFlowKind.PhotoSplit, ScanIntent.Photo, null),
                (TaskFlowKind.DocumentQueue, ScanIntent.Document, ScanSource.Flatbed),
                (TaskFlowKind.DocumentQueue, ScanIntent.Document, null),
                (TaskFlowKind.DocumentQueue, ScanIntent.Document, ScanSource.DocumentFeeder),
            ],
            TaskCatalog.All.Select(d => (d.Flow, d.Intent, d.RequiredSource)));
    }

    private static ScanSettings Customized()
    {
        var s = new ScanSettings
        {
            Intent = ScanIntent.Photo,
            Source = ScanSource.DocumentFeeder,
            Resolution = 1200,
            ColorMode = ColorMode.BlackWhite,
            Format = OutputFormat.Tiff,
            JpegQuality = 0.5,
            DestinationPath = @"D:\Archive\Scans",
            NamingTemplate = "Mine {counter}",
            PhotoAutoSplit = false,
            PhotoAutoDeskew = false,
            PhotoMinSideInches = 2.5,
            PhotoCropInsetPixels = 6,
            DocumentMultiPage = false,
            PdfSearchable = false,
        };
        s.Adjustments.Brightness = 0.5;
        s.Adjustments.Descreen = true;
        s.Adjustments.BlackWhiteThreshold = 0.25;
        s.Output.PdfSize = PdfSizePreset.Smallest;
        s.Duplex = DuplexMode.Manual;
        s.BackBinding = DuplexBinding.ShortEdge;
        s.PaperSize = PaperSize.Legal;
        return s;
    }

    [Fact]
    public void Apply_KeepsDestinationAndDetectionTuning_AndLeavesTheInputAlone()
    {
        var current = Customized();
        string before = CompatFixtures.Encode(current);
        foreach (var task in ScanTasks.All)
        {
            var s = TaskCatalog.Apply(task, current);
            Assert.NotSame(current, s);
            Assert.Equal(@"D:\Archive\Scans", s.DestinationPath);
            Assert.Equal(2.5, s.PhotoMinSideInches);
            Assert.Equal(6, s.PhotoCropInsetPixels);
            Assert.Equal(task.RawValue(), s.TaskId);
            Assert.Equal(task, s.Task);
            Assert.Equal(0.9, s.JpegQuality);
            Assert.Equal(ColorMode.Color, s.ColorMode);
            Assert.True(s.PhotoAutoSplit && s.PhotoAutoDeskew && s.PdfSearchable);
            Assert.Equal(TaskCatalog.Definition(task).Intent, s.Intent);
            Assert.True(TaskCatalog.Fits(task, s));
            Assert.Equal(task, TaskCatalog.Infer(s));
        }
        Assert.Equal(before, CompatFixtures.Encode(current));
    }

    [Fact]
    public void Apply_TaskSettingsTable()
    {
        var current = Customized();
        var rows = ScanTasks.All.Select(task =>
        {
            var s = TaskCatalog.Apply(task, current);
            return (s.Intent, s.Source, s.Resolution, s.Format, s.DocumentMultiPage, s.NamingTemplate,
                    s.Adjustments.RestoreFadedColors, s.Adjustments.AutoEnhance, s.Output.PdfSize);
        });
        Assert.Equal(
            [
                (ScanIntent.Document, ScanSource.Flatbed, 300, OutputFormat.Pdf, true, "Scan {date} {counter}", false, false, PdfSizePreset.Standard),
                (ScanIntent.Document, ScanSource.DocumentFeeder, 300, OutputFormat.Pdf, true, "Scan {date} {counter}", false, false, PdfSizePreset.Standard),
                (ScanIntent.Photo, ScanSource.Flatbed, 600, OutputFormat.Jpeg, true, "Photo {date} {counter}", false, false, PdfSizePreset.Standard),
                (ScanIntent.Photo, ScanSource.Flatbed, 600, OutputFormat.Png, true, "Photo {date} {counter}", true, true, PdfSizePreset.Standard),
                (ScanIntent.Document, ScanSource.Flatbed, 150, OutputFormat.Jpeg, false, "Scan {date} {counter}", false, false, PdfSizePreset.Standard),
                (ScanIntent.Document, ScanSource.Flatbed, 300, OutputFormat.Pdf, true, "Scan {date} {counter}", false, false, PdfSizePreset.Compact),
                (ScanIntent.Document, ScanSource.DocumentFeeder, 300, OutputFormat.Pdf, true, "Scan {date} {counter}", false, false, PdfSizePreset.Standard),
            ],
            rows);
    }

    [Fact]
    public void Apply_OnlyTheTwoSidedTaskScansBothSides_ThePaperIsKept()
    {
        var current = Customized();
        foreach (var task in ScanTasks.All)
        {
            var s = TaskCatalog.Apply(task, current);
            Assert.Equal(task == ScanTask.TwoSided ? DuplexMode.Both : DuplexMode.Off, s.Duplex);
            Assert.Equal(DuplexBinding.ShortEdge, s.BackBinding);
            Assert.Equal(PaperSize.Legal, s.PaperSize);
        }
    }

    [Fact]
    public void TwoSided_IsATwoSidedFeederPdf()
    {
        var definition = TaskCatalog.Definition(ScanTask.TwoSided);
        Assert.Equal("Scan stack", definition.Steps[0].PrimaryActionLabel);
        var s = TaskCatalog.Apply(ScanTask.TwoSided, new ScanSettings());
        Assert.Equal((ScanIntent.Document, ScanSource.DocumentFeeder, OutputFormat.Pdf, DuplexMode.Both),
                     (s.Intent, s.Source, s.Format, s.Duplex));
        Assert.True(TaskCatalog.Fits(ScanTask.TwoSided, s));
        s.Duplex = DuplexMode.Manual;
        Assert.True(TaskCatalog.Fits(ScanTask.TwoSided, s));
        // One side by hand ends the task, as leaving the feeder does.
        s.Duplex = DuplexMode.Off;
        Assert.False(TaskCatalog.Fits(ScanTask.TwoSided, s));
        s.Duplex = DuplexMode.Both;
        s.Source = ScanSource.Flatbed;
        Assert.False(TaskCatalog.Fits(ScanTask.TwoSided, s));
    }

    [Fact]
    public void GuidedSteps_TurningOverByHandWinsOverTheTask()
    {
        Assert.Null(TaskCatalog.GuidedSteps(new ScanSettings(), null));
        Assert.Equal(TaskCatalog.Definition(ScanTask.Document).Steps,
                     TaskCatalog.GuidedSteps(TaskCatalog.Apply(ScanTask.Document, new ScanSettings()), null));
        Assert.Null(TaskCatalog.GuidedSteps(new ScanSettings { TaskId = "whiteboard" }, null));

        var twoSided = TaskCatalog.Apply(ScanTask.TwoSided, new ScanSettings());
        var duplexFeeder = new ScannerCapabilities { Sources = [ScanSource.DocumentFeeder], SupportsDuplex = true };
        var simplexFeeder = new ScannerCapabilities { Sources = [ScanSource.DocumentFeeder], SupportsDuplex = false };
        Assert.Equal(TaskCatalog.Definition(ScanTask.TwoSided).Steps, TaskCatalog.GuidedSteps(twoSided, duplexFeeder));
        Assert.Equal(DocumentSides.ManualSteps, TaskCatalog.GuidedSteps(twoSided, simplexFeeder));

        // Without a task, too.
        var byHand = new ScanSettings { Source = ScanSource.DocumentFeeder, Duplex = DuplexMode.Manual };
        Assert.Equal(DocumentSides.ManualSteps, TaskCatalog.GuidedSteps(byHand, null));
        // Each scan saved at once: nothing to guide.
        byHand.DocumentMultiPage = false;
        Assert.Null(TaskCatalog.GuidedSteps(byHand, null));
    }

    [Fact]
    public void Apply_ResetsAdjustmentsToTheTasks()
    {
        var s = TaskCatalog.Apply(ScanTask.Document, Customized());
        Assert.Equal(new AdjustmentSettings(), s.Adjustments);
        var restore = TaskCatalog.Apply(ScanTask.PhotoRestore, Customized()).Adjustments;
        Assert.Equal(new AdjustmentSettings { RestoreFadedColors = true, AutoEnhance = true }, restore);
    }

    [Fact]
    public void Infer_StoredTaskWins()
    {
        var s = new ScanSettings { Intent = ScanIntent.Photo, TaskId = "quickScan" };
        Assert.Equal(ScanTask.QuickScan, TaskCatalog.Infer(s));
    }

    [Fact]
    public void Infer_FromTheSettingsWhenNoTaskIsStored()
    {
        ScanTask Infer(Action<ScanSettings> change)
        {
            var s = new ScanSettings();
            change(s);
            return TaskCatalog.Infer(s);
        }

        Assert.Equal(ScanTask.Document, Infer(_ => { }));
        Assert.Equal(ScanTask.Photos, Infer(s => s.Intent = ScanIntent.Photo));
        Assert.Equal(ScanTask.PhotoRestore, Infer(s =>
        {
            s.Intent = ScanIntent.Photo;
            s.Adjustments.RestoreFadedColors = true;
        }));
        Assert.Equal(ScanTask.Feeder, Infer(s => s.Source = ScanSource.DocumentFeeder));
        Assert.Equal(ScanTask.TwoSided, Infer(s =>
        {
            s.Source = ScanSource.DocumentFeeder;
            s.Duplex = DuplexMode.Manual;
        }));
        // Two-sided on the flatbed means nothing: still a document.
        Assert.Equal(ScanTask.Document, Infer(s => s.Duplex = DuplexMode.Both));
        Assert.Equal(ScanTask.QuickScan, Infer(s =>
        {
            s.DocumentMultiPage = false;
            s.Format = OutputFormat.Jpeg;
        }));
        // One PDF per scan is still a document.
        Assert.Equal(ScanTask.Document, Infer(s => s.DocumentMultiPage = false));
        // A task of a newer version is inferred from the settings.
        Assert.Equal(ScanTask.Photos, Infer(s =>
        {
            s.TaskId = "receipt";
            s.Intent = ScanIntent.Photo;
        }));
    }

    [Fact]
    public void Infer_TheFiveStarterPresetsOfEarlierVersions()
    {
        // The settings earlier versions seeded presets.json with, as their cards are badged.
        var compactText = new ScanSettings { Resolution = 200, ColorMode = ColorMode.Grayscale };
        var photos = new ScanSettings { Intent = ScanIntent.Photo, Resolution = 600, Format = OutputFormat.Jpeg };
        var restore = new ScanSettings { Intent = ScanIntent.Photo, Resolution = 600, Format = OutputFormat.Png };
        restore.Adjustments.RestoreFadedColors = true;
        restore.Adjustments.AutoEnhance = true;
        var quick = new ScanSettings { Resolution = 150, Format = OutputFormat.Jpeg, DocumentMultiPage = false };

        Assert.Equal(ScanTask.Document, TaskCatalog.Infer(new ScanSettings()));
        Assert.Equal(ScanTask.Document, TaskCatalog.Infer(compactText));
        Assert.Equal(ScanTask.Photos, TaskCatalog.Infer(photos));
        Assert.Equal(ScanTask.PhotoRestore, TaskCatalog.Infer(restore));
        Assert.Equal(ScanTask.QuickScan, TaskCatalog.Infer(quick));
    }

    [Fact]
    public void Availability_WithoutScanner_EverythingIsAvailable()
    {
        Assert.All(ScanTasks.All, task => Assert.Equal(TaskAvailability.Available, TaskCatalog.Availability(task, null)));
    }

    [Fact]
    public void Availability_FlatbedOnlyScanner_NoFeederTasks()
    {
        var caps = new ScannerCapabilities { Sources = [ScanSource.Flatbed] };
        foreach (var task in new[] { ScanTask.Feeder, ScanTask.TwoSided })
        {
            var availability = TaskCatalog.Availability(task, caps);
            Assert.False(availability.IsAvailable);
            Assert.Equal("This scanner has no document feeder.", availability.Reason);
        }
        Assert.All(ScanTasks.All.Where(t => t is not (ScanTask.Feeder or ScanTask.TwoSided)),
                   task => Assert.True(TaskCatalog.Availability(task, caps).IsAvailable));
    }

    [Fact]
    public void Availability_FeederOnlyScanner_NoQuickScan()
    {
        var caps = new ScannerCapabilities { Sources = [ScanSource.DocumentFeeder], SupportsOverview = false };
        var quick = TaskCatalog.Availability(ScanTask.QuickScan, caps);
        Assert.False(quick.IsAvailable);
        Assert.Equal("This scanner has no flatbed.", quick.Reason);
        // Documents and photos fall back to the feeder (SettingsAdapter).
        Assert.All(ScanTasks.All.Where(t => t != ScanTask.QuickScan),
                   task => Assert.True(TaskCatalog.Availability(task, caps).IsAvailable));
    }

    [Fact]
    public void Fits_FollowsModeAndRequiredSource()
    {
        var document = TaskCatalog.Apply(ScanTask.Document, new ScanSettings());
        document.Source = ScanSource.DocumentFeeder;
        Assert.True(TaskCatalog.Fits(ScanTask.Document, document));
        document.Intent = ScanIntent.Photo;
        Assert.False(TaskCatalog.Fits(ScanTask.Document, document));

        var feeder = TaskCatalog.Apply(ScanTask.Feeder, new ScanSettings());
        feeder.Resolution = 600;
        feeder.Format = OutputFormat.Tiff;
        Assert.True(TaskCatalog.Fits(ScanTask.Feeder, feeder));
        feeder.Source = ScanSource.Flatbed;
        Assert.False(TaskCatalog.Fits(ScanTask.Feeder, feeder));

        var quick = TaskCatalog.Apply(ScanTask.QuickScan, new ScanSettings());
        quick.Source = ScanSource.DocumentFeeder;
        Assert.False(TaskCatalog.Fits(ScanTask.QuickScan, quick));

        var photos = TaskCatalog.Apply(ScanTask.Photos, new ScanSettings());
        photos.Source = ScanSource.DocumentFeeder;
        Assert.True(TaskCatalog.Fits(ScanTask.Photos, photos));
        photos.Intent = ScanIntent.Document;
        Assert.False(TaskCatalog.Fits(ScanTask.Photos, photos));
    }

    [Fact]
    public void FlowOf_TaskThenMode()
    {
        Assert.Equal(TaskFlowKind.DocumentQueue, TaskCatalog.FlowOf(new ScanSettings()));
        Assert.Equal(TaskFlowKind.PhotoSplit, TaskCatalog.FlowOf(new ScanSettings { Intent = ScanIntent.Photo }));
        foreach (var task in ScanTasks.All)
        {
            Assert.Equal(TaskCatalog.Definition(task).Flow, TaskCatalog.FlowOf(TaskCatalog.Apply(task, new ScanSettings())));
        }
        // A stored task that no longer fits (a hand-edited file) does not override the mode.
        Assert.Equal(TaskFlowKind.DocumentQueue,
                     TaskCatalog.FlowOf(new ScanSettings { TaskId = "photos", Intent = ScanIntent.Document }));
        Assert.Equal(TaskFlowKind.PhotoSplit,
                     TaskCatalog.FlowOf(new ScanSettings { TaskId = "whiteboard", Intent = ScanIntent.Photo }));
    }

    [Fact]
    public void Summary_OneLine()
    {
        Assert.Equal("300 dpi · Color · PDF", TaskCatalog.Summary(new ScanSettings()));
        Assert.Equal("600 dpi · Color · PNG", TaskCatalog.Summary(TaskCatalog.Apply(ScanTask.PhotoRestore, new ScanSettings())));
        Assert.Equal("200 dpi · Black & White · TIFF", TaskCatalog.Summary(
            new ScanSettings { Resolution = 200, ColorMode = ColorMode.BlackWhite, Format = OutputFormat.Tiff }));
    }

    [Fact]
    public void Summary_NamesANonDefaultPdfSize_ForPdfsOnly()
    {
        Assert.Equal("300 dpi · Color · Compact PDF", TaskCatalog.Summary(TaskCatalog.Apply(ScanTask.Email, new ScanSettings())));
        var smallest = new ScanSettings { Resolution = 150, ColorMode = ColorMode.Grayscale };
        smallest.Output.PdfSize = PdfSizePreset.Smallest;
        Assert.Equal("150 dpi · Grayscale · Smallest PDF", TaskCatalog.Summary(smallest));
        smallest.Format = OutputFormat.Jpeg;
        Assert.Equal("150 dpi · Grayscale · JPEG", TaskCatalog.Summary(smallest));
        var best = new ScanSettings();
        best.Output.PdfSize = PdfSizePreset.Best;
        Assert.Equal("300 dpi · Color · Best PDF", TaskCatalog.Summary(best));
        Assert.Equal("300 dpi · Color · PDF", TaskCatalog.Summary(TaskCatalog.Apply(ScanTask.Document, best)));
    }

    [Fact]
    public void Summary_NamesTwoSidedFeederScans()
    {
        var twoSided = TaskCatalog.Apply(ScanTask.TwoSided, new ScanSettings());
        Assert.Equal("300 dpi · Color · PDF · Both sides", TaskCatalog.Summary(twoSided));
        var simplexFeeder = new ScannerCapabilities { Sources = [ScanSource.DocumentFeeder], SupportsDuplex = false };
        Assert.Equal("300 dpi · Color · PDF · Both sides, turned by hand",
                     TaskCatalog.Summary(SettingsAdapter.Adapt(twoSided, simplexFeeder).Settings));
        // On the flatbed the setting does nothing, so it is not named.
        Assert.Equal("300 dpi · Color · PDF", TaskCatalog.Summary(new ScanSettings { Duplex = DuplexMode.Both }));
    }

    [Fact]
    public void Email_IsACompactDocumentPdf_OnAnyScanner()
    {
        var email = TaskCatalog.Apply(ScanTask.Email, Customized());
        Assert.Equal((ScanIntent.Document, OutputFormat.Pdf, PdfSizePreset.Compact, 300, ColorMode.Color),
                     (email.Intent, email.Format, email.Output.PdfSize, email.Resolution, email.ColorMode));
        Assert.Equal(TaskFlowKind.DocumentQueue, TaskCatalog.FlowOf(email));
        Assert.Equal("Scan page", TaskCatalog.Definition(ScanTask.Email).Steps[0].PrimaryActionLabel);
        Assert.True(TaskCatalog.Availability(ScanTask.Email, new ScannerCapabilities { Sources = [ScanSource.DocumentFeeder] }).IsAvailable);
        Assert.True(TaskCatalog.Availability(ScanTask.Email, new ScannerCapabilities { Sources = [ScanSource.Flatbed] }).IsAvailable);
        // Changing the size by hand keeps the task; leaving document mode ends it.
        email.Output.PdfSize = PdfSizePreset.Best;
        email.Source = ScanSource.DocumentFeeder;
        Assert.True(TaskCatalog.Fits(ScanTask.Email, email));
        email.Intent = ScanIntent.Photo;
        Assert.False(TaskCatalog.Fits(ScanTask.Email, email));
        // Without a stored task a compact PDF is still a plain document.
        var untagged = TaskCatalog.Apply(ScanTask.Email, new ScanSettings());
        untagged.TaskId = null;
        Assert.Equal(ScanTask.Document, TaskCatalog.Infer(untagged));
    }

    [Fact]
    public void FileLabels()
    {
        Assert.Equal(["Document", "Document", "Photo", "Restored photo", "Scan", "Document", "Document"],
                     TaskCatalog.All.Select(d => d.FileLabel));
    }
}
