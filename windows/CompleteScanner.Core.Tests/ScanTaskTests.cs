using CompleteScanner.Core;
using Xunit;

namespace CompleteScanner.Core.Tests;

// Mirrored by Tests/CompleteScannerTests/ScanTaskTests.swift: the same cases.

public class ScanTaskTests
{
    [Fact]
    public void RawValues_AreTheStoredNames()
    {
        Assert.Equal(["document", "feeder", "photos", "photoRestore", "quickScan", "email", "twoSided", "idCard", "copy", "word", "receipt", "batch", "book"],
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
                      "Email a document", "Two-sided document", "ID card", "Copy", "Scan to Word", "Receipts",
                      "Batch of separate documents", "Book or magazine"],
                     TaskCatalog.All.Select(d => d.Title));
        Assert.Equal(["document", "feeder", "photos", "restore", "quick", "email", "twoSided", "idCard", "copy", "word", "receipt", "batch", "book"],
                     TaskCatalog.All.Select(d => d.IconKey));
        foreach (var definition in TaskCatalog.All)
        {
            Assert.Same(definition, TaskCatalog.Definition(definition.Task));
            Assert.False(string.IsNullOrWhiteSpace(definition.Subtitle));
        }
        // Every task but the ID card has one repeating scan step.
        foreach (var definition in TaskCatalog.All.Where(d => d.Task != ScanTask.IdCard))
        {
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
                (TaskFlowKind.IdCard, ScanIntent.Document, ScanSource.Flatbed),
                (TaskFlowKind.Copy, ScanIntent.Document, null),
                (TaskFlowKind.DocumentQueue, ScanIntent.Document, null),
                (TaskFlowKind.ReceiptSplit, ScanIntent.Document, null),
                (TaskFlowKind.DocumentQueue, ScanIntent.Document, ScanSource.DocumentFeeder),
                (TaskFlowKind.DocumentQueue, ScanIntent.Document, ScanSource.Flatbed),
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
        s.TaskOptions.IdCardPaper = IdCardPaper.Letter;
        s.TaskOptions.IdCardSaveSidesAsImages = true;
        s.TaskOptions.CopyCount = 4;
        s.TaskOptions.CopyFitToPage = true;
        s.TaskOptions.CopyPrinterName = "Office";
        s.TaskOptions.CopyAlsoSavePdf = true;
        s.TaskOptions.ReceiptNameByDate = false;
        s.TaskOptions.ReceiptCombine = true;
        s.TaskOptions.BookRightToLeft = true;
        s.TaskOptions.BookRotationQuarterTurns = 3;
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
            // Thermal print has no color: receipts are scanned in grayscale.
            Assert.Equal(task == ScanTask.Receipt ? ColorMode.Grayscale : ColorMode.Color, s.ColorMode);
            Assert.True(s.PhotoAutoSplit && s.PhotoAutoDeskew);
            // The ID card's numbers are better not indexed, and a copy is for paper: no text layer.
            Assert.Equal(task is not (ScanTask.IdCard or ScanTask.Copy), s.PdfSearchable);
            // How the user wants a task done is kept.
            Assert.Equal((IdCardPaper.Letter, true), (s.TaskOptions.IdCardPaper, s.TaskOptions.IdCardSaveSidesAsImages));
            Assert.Equal((4, true, "Office", true), (s.TaskOptions.CopyCount, s.TaskOptions.CopyFitToPage,
                                                     s.TaskOptions.CopyPrinterName, s.TaskOptions.CopyAlsoSavePdf));
            Assert.Equal((false, true), (s.TaskOptions.ReceiptNameByDate, s.TaskOptions.ReceiptCombine));
            Assert.Equal((true, 3), (s.TaskOptions.BookRightToLeft, s.TaskOptions.BookRotationQuarterTurns));
            Assert.NotSame(current.TaskOptions, s.TaskOptions);
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
                    s.Adjustments.RestoreFadedColors, s.Adjustments.AutoEnhance, s.Output.PdfSize, s.Document.SplitMode);
        });
        Assert.Equal(
            [
                (ScanIntent.Document, ScanSource.Flatbed, 300, OutputFormat.Pdf, true, "Scan {date} {counter}", false, false, PdfSizePreset.Standard, SplitMode.None),
                (ScanIntent.Document, ScanSource.DocumentFeeder, 300, OutputFormat.Pdf, true, "Scan {date} {counter}", false, false, PdfSizePreset.Standard, SplitMode.None),
                (ScanIntent.Photo, ScanSource.Flatbed, 600, OutputFormat.Jpeg, true, "Photo {date} {counter}", false, false, PdfSizePreset.Standard, SplitMode.None),
                (ScanIntent.Photo, ScanSource.Flatbed, 600, OutputFormat.Png, true, "Photo {date} {counter}", true, true, PdfSizePreset.Standard, SplitMode.None),
                (ScanIntent.Document, ScanSource.Flatbed, 150, OutputFormat.Jpeg, false, "Scan {date} {counter}", false, false, PdfSizePreset.Standard, SplitMode.None),
                (ScanIntent.Document, ScanSource.Flatbed, 300, OutputFormat.Pdf, true, "Scan {date} {counter}", false, false, PdfSizePreset.Compact, SplitMode.None),
                (ScanIntent.Document, ScanSource.DocumentFeeder, 300, OutputFormat.Pdf, true, "Scan {date} {counter}", false, false, PdfSizePreset.Standard, SplitMode.None),
                (ScanIntent.Document, ScanSource.Flatbed, 300, OutputFormat.Pdf, true, "ID card {date}", false, false, PdfSizePreset.Standard, SplitMode.None),
                (ScanIntent.Document, ScanSource.Flatbed, 300, OutputFormat.Pdf, true, "Copy {date} {counter}", false, false, PdfSizePreset.Standard, SplitMode.None),
                (ScanIntent.Document, ScanSource.Flatbed, 300, OutputFormat.Word, true, "Scan {date} {counter}", false, false, PdfSizePreset.Standard, SplitMode.None),
                (ScanIntent.Document, ScanSource.Flatbed, 300, OutputFormat.Pdf, true, "Receipt {docdate} {counter}", false, false, PdfSizePreset.Compact, SplitMode.None),
                (ScanIntent.Document, ScanSource.DocumentFeeder, 300, OutputFormat.Pdf, true, "Document {label} {date} {counter}", false, false, PdfSizePreset.Standard, SplitMode.SeparatorSheet),
                (ScanIntent.Document, ScanSource.Flatbed, 300, OutputFormat.Pdf, true, "{task} {date} {counter}", false, false, PdfSizePreset.Standard, SplitMode.None),
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
    public void Apply_OnlyTheTwoSidedTaskSkipsBlankPages_HowMuchCountsAsBlankIsKept()
    {
        var current = Customized();
        current.Document.RemoveBlankPages = true;
        current.Document.BlankSensitivity = BlankSensitivity.High;
        foreach (var task in ScanTasks.All)
        {
            var s = TaskCatalog.Apply(task, current);
            Assert.Equal(task is ScanTask.TwoSided or ScanTask.Batch, s.Document.RemoveBlankPages);
            Assert.Equal(BlankSensitivity.High, s.Document.BlankSensitivity);
        }
        Assert.True(current.Document.RemoveBlankPages);
        Assert.True(TaskCatalog.Apply(ScanTask.TwoSided, new ScanSettings()).Document.RemoveBlankPages);
    }

    [Fact]
    public void Apply_OnlyTheTwoSidedAndBookTasksStraighten_NoTaskCrops()
    {
        var current = Customized();
        current.Document.AutoCrop = true;
        current.Document.AutoStraighten = true;
        foreach (var task in ScanTasks.All)
        {
            var s = TaskCatalog.Apply(task, current);
            Assert.False(s.Document.AutoCrop);
            Assert.Equal(task is ScanTask.TwoSided or ScanTask.Book, s.Document.AutoStraighten);
        }
        Assert.True(current.Document.AutoCrop);
        Assert.True(TaskCatalog.Apply(ScanTask.TwoSided, new ScanSettings()).Document.AutoStraighten);
    }

    [Fact]
    public void Apply_OnlyTheTwoSidedAndBookTasksTurnPagesUpright()
    {
        var current = Customized();
        current.Document.AutoRotate = true;
        foreach (var task in ScanTasks.All)
        {
            Assert.Equal(task is ScanTask.TwoSided or ScanTask.Book, TaskCatalog.Apply(task, current).Document.AutoRotate);
        }
        Assert.True(current.Document.AutoRotate);
        Assert.True(TaskCatalog.Apply(ScanTask.TwoSided, new ScanSettings()).Document.AutoRotate);
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
    public void IdCard_IsAFlatbedPdfWithItsOwnSteps()
    {
        var definition = TaskCatalog.Definition(ScanTask.IdCard);
        Assert.Equal(IdCardSteps.Steps, definition.Steps);
        Assert.Equal("Scan front", definition.Steps[0].PrimaryActionLabel);
        var s = TaskCatalog.Apply(ScanTask.IdCard, new ScanSettings());
        Assert.Equal((ScanIntent.Document, ScanSource.Flatbed, OutputFormat.Pdf, 300, ColorMode.Color, DuplexMode.Off),
                     (s.Intent, s.Source, s.Format, s.Resolution, s.ColorMode, s.Duplex));
        Assert.False(s.PdfSearchable);
        Assert.Equal(AfterSaveAction.None, s.Output.AfterSave);
        Assert.Equal(TaskFlowKind.IdCard, TaskCatalog.FlowOf(s));
        Assert.Equal(IdCardSteps.Steps, TaskCatalog.GuidedSteps(s, null));
        Assert.Equal("300 dpi · Color · PDF", TaskCatalog.Summary(s));
        Assert.True(TaskCatalog.Fits(ScanTask.IdCard, s));
        // Saving JPEG or PNG keeps the task; the feeder or Photos mode ends it.
        s.Format = OutputFormat.Png;
        Assert.True(TaskCatalog.Fits(ScanTask.IdCard, s));
        s.Source = ScanSource.DocumentFeeder;
        Assert.False(TaskCatalog.Fits(ScanTask.IdCard, s));
        Assert.Equal(TaskFlowKind.DocumentQueue, TaskCatalog.FlowOf(s));
        s.Source = ScanSource.Flatbed;
        s.Intent = ScanIntent.Photo;
        Assert.False(TaskCatalog.Fits(ScanTask.IdCard, s));
        // Settings never look like an ID card without the task stored.
        var untagged = TaskCatalog.Apply(ScanTask.IdCard, new ScanSettings());
        untagged.TaskId = null;
        Assert.Equal(ScanTask.Document, TaskCatalog.Infer(untagged));
    }

    [Fact]
    public void Copy_PrintsAtRealSizeFromAnySource()
    {
        var definition = TaskCatalog.Definition(ScanTask.Copy);
        Assert.Equal("Copy", definition.Steps[0].PrimaryActionLabel);
        var s = TaskCatalog.Apply(ScanTask.Copy, new ScanSettings());
        Assert.Equal((ScanIntent.Document, ScanSource.Flatbed, OutputFormat.Pdf, 300, ColorMode.Color, DuplexMode.Off),
                     (s.Intent, s.Source, s.Format, s.Resolution, s.ColorMode, s.Duplex));
        Assert.False(s.PdfSearchable);
        Assert.Equal(AfterSaveAction.None, s.Output.AfterSave);
        Assert.Equal(TaskFlowKind.Copy, TaskCatalog.FlowOf(s));
        Assert.Equal(definition.Steps, TaskCatalog.GuidedSteps(s, null));
        // Printed at real size, one copy, unless chosen otherwise.
        Assert.Equal((1, false, (string?)null, false), (s.TaskOptions.CopyCount, s.TaskOptions.CopyFitToPage,
                                                        s.TaskOptions.CopyPrinterName, s.TaskOptions.CopyAlsoSavePdf));
        // The feeder copies a stack; Photos mode ends the task.
        s.Source = ScanSource.DocumentFeeder;
        Assert.True(TaskCatalog.Fits(ScanTask.Copy, s));
        Assert.Equal(TaskFlowKind.Copy, TaskCatalog.FlowOf(s));
        s.Intent = ScanIntent.Photo;
        Assert.False(TaskCatalog.Fits(ScanTask.Copy, s));
        Assert.Equal(TaskFlowKind.PhotoSplit, TaskCatalog.FlowOf(s));
        // Settings never look like a copy without the task stored.
        var untagged = TaskCatalog.Apply(ScanTask.Copy, new ScanSettings());
        untagged.TaskId = null;
        Assert.Equal(ScanTask.Document, TaskCatalog.Infer(untagged));
    }

    [Fact]
    public void Copy_NeedsAPrinter_TheOtherTasksDoNot()
    {
        var unavailable = TaskCatalog.Availability(ScanTask.Copy, null, hasPrinter: false);
        Assert.False(unavailable.IsAvailable);
        Assert.Equal("No printer is installed.", unavailable.Reason);
        Assert.Equal(TaskAvailability.Available, TaskCatalog.Availability(ScanTask.Copy, null, hasPrinter: true));
        Assert.Equal(TaskAvailability.Available, TaskCatalog.Availability(ScanTask.Copy, null));
        Assert.All(ScanTasks.All.Where(t => t != ScanTask.Copy),
                   task => Assert.Equal(TaskAvailability.Available, TaskCatalog.Availability(task, null, hasPrinter: false)));
        // Any scanner will do: the glass or the feeder.
        var feederOnly = new ScannerCapabilities { Sources = [ScanSource.DocumentFeeder], SupportsOverview = false };
        Assert.True(TaskCatalog.Availability(ScanTask.Copy, feederOnly, hasPrinter: true).IsAvailable);
        Assert.Equal("This scanner has no flatbed.", TaskCatalog.Availability(ScanTask.IdCard, feederOnly, hasPrinter: false).Reason);
    }

    [Fact]
    public void Summary_OfACopy_SaysHowItPrints()
    {
        var s = TaskCatalog.Apply(ScanTask.Copy, new ScanSettings());
        Assert.Equal("300 dpi · Color · Actual size", TaskCatalog.Summary(s));
        s.ColorMode = ColorMode.Grayscale;
        s.TaskOptions.CopyFitToPage = true;
        s.TaskOptions.CopyCount = 3;
        Assert.Equal("300 dpi · Grayscale · Fit to page · 3 copies", TaskCatalog.Summary(s));
        // A count beyond what can be asked for is read as the most.
        s.TaskOptions.CopyCount = 500;
        Assert.Equal("300 dpi · Grayscale · Fit to page · 99 copies", TaskCatalog.Summary(s));
        // Without the task the settings describe a file again.
        s.TaskId = null;
        Assert.Equal("300 dpi · Grayscale · PDF", TaskCatalog.Summary(s));
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
        // One PDF per scan is still a document, and so is the text of each scan.
        Assert.Equal(ScanTask.Document, Infer(s => s.DocumentMultiPage = false));
        Assert.Equal(ScanTask.Document, Infer(s =>
        {
            s.DocumentMultiPage = false;
            s.Format = OutputFormat.Text;
        }));
        // A Word document is Scan to Word, collected or not; from the feeder it is a feeder scan.
        Assert.Equal(ScanTask.Word, Infer(s => s.Format = OutputFormat.Word));
        Assert.Equal(ScanTask.Word, Infer(s =>
        {
            s.DocumentMultiPage = false;
            s.Format = OutputFormat.Word;
        }));
        Assert.Equal(ScanTask.Feeder, Infer(s =>
        {
            s.Source = ScanSource.DocumentFeeder;
            s.Format = OutputFormat.Word;
        }));
        // A task of a newer version is inferred from the settings.
        Assert.Equal(ScanTask.Photos, Infer(s =>
        {
            s.TaskId = "whiteboard";
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
        foreach (var task in new[] { ScanTask.Feeder, ScanTask.TwoSided, ScanTask.Batch })
        {
            var availability = TaskCatalog.Availability(task, caps);
            Assert.False(availability.IsAvailable);
            Assert.Equal("This scanner has no document feeder.", availability.Reason);
        }
        Assert.All(ScanTasks.All.Where(t => t is not (ScanTask.Feeder or ScanTask.TwoSided or ScanTask.Batch)),
                   task => Assert.True(TaskCatalog.Availability(task, caps).IsAvailable));
    }

    [Fact]
    public void Availability_FeederOnlyScanner_NoQuickScanOrIdCard()
    {
        var caps = new ScannerCapabilities { Sources = [ScanSource.DocumentFeeder], SupportsOverview = false };
        foreach (var task in new[] { ScanTask.QuickScan, ScanTask.IdCard, ScanTask.Book })
        {
            var availability = TaskCatalog.Availability(task, caps);
            Assert.False(availability.IsAvailable);
            Assert.Equal("This scanner has no flatbed.", availability.Reason);
        }
        // Documents and photos fall back to the feeder (SettingsAdapter).
        Assert.All(ScanTasks.All.Where(t => t is not (ScanTask.QuickScan or ScanTask.IdCard or ScanTask.Book)),
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
        Assert.Equal(["Document", "Document", "Photo", "Restored photo", "Scan", "Document", "Document", "ID card", "Copy", "Document", "Receipt", "Document", "Book"],
                     TaskCatalog.All.Select(d => d.FileLabel));
    }

    [Fact]
    public void Word_SavesTheTextAsAWordDocument_AndEndsWithAnotherFormat()
    {
        var definition = TaskCatalog.Definition(ScanTask.Word);
        Assert.Equal("Scan page", definition.Steps[0].PrimaryActionLabel);
        var s = TaskCatalog.Apply(ScanTask.Word, new ScanSettings());
        Assert.Equal(OutputFormat.Word, s.Format);
        Assert.True(s.DocumentMultiPage);
        Assert.Equal(TaskFlowKind.DocumentQueue, TaskCatalog.FlowOf(s));
        Assert.Equal("300 dpi · Color · Word (.docx)", TaskCatalog.Summary(s));
        Assert.True(TaskCatalog.Fits(ScanTask.Word, s));
        // Any source will do.
        s.Source = ScanSource.DocumentFeeder;
        Assert.True(TaskCatalog.Fits(ScanTask.Word, s));
        // Another format ends the task.
        s.Format = OutputFormat.Pdf;
        Assert.False(TaskCatalog.Fits(ScanTask.Word, s));
        Assert.Equal(TaskAvailability.Available,
                     TaskCatalog.Availability(ScanTask.Word, new ScannerCapabilities { Sources = [ScanSource.DocumentFeeder] }));
    }

    [Fact]
    public void Receipt_IsAGrayCompactSearchablePdf_NamedByTheReceiptsDate()
    {
        var definition = TaskCatalog.Definition(ScanTask.Receipt);
        Assert.Equal(("Scan receipts", "receipt", "Receipt"), (definition.Steps[0].PrimaryActionLabel, definition.IconKey, definition.FileLabel));
        var s = TaskCatalog.Apply(ScanTask.Receipt, new ScanSettings());
        Assert.Equal((ScanIntent.Document, ScanSource.Flatbed, OutputFormat.Pdf, 300, ColorMode.Grayscale, PdfSizePreset.Compact),
                     (s.Intent, s.Source, s.Format, s.Resolution, s.ColorMode, s.Output.PdfSize));
        Assert.True(s.PdfSearchable);
        Assert.False(s.Document.AutoCrop || s.Document.AutoStraighten || s.Document.RemoveBlankPages);
        Assert.Equal(TaskFlowKind.ReceiptSplit, TaskCatalog.FlowOf(s));
        Assert.Equal("300 dpi · Grayscale · Compact PDF", TaskCatalog.Summary(s));
        Assert.Equal((true, false), (s.TaskOptions.ReceiptNameByDate, s.TaskOptions.ReceiptCombine));
        // The feeder takes one receipt a sheet; another format or size keeps the task; photo mode ends it.
        s.Source = ScanSource.DocumentFeeder;
        s.Format = OutputFormat.Jpeg;
        s.Output.PdfSize = PdfSizePreset.Smallest;
        Assert.True(TaskCatalog.Fits(ScanTask.Receipt, s));
        Assert.Equal(TaskFlowKind.ReceiptSplit, TaskCatalog.FlowOf(s));
        s.Intent = ScanIntent.Photo;
        Assert.False(TaskCatalog.Fits(ScanTask.Receipt, s));
        Assert.True(TaskCatalog.Availability(ScanTask.Receipt, new ScannerCapabilities { Sources = [ScanSource.DocumentFeeder] }).IsAvailable);
    }

    [Fact]
    public void Apply_TurnsTheTextBesideAPdfOff()
    {
        var current = Customized();
        current.Output.AlsoSaveText = true;
        foreach (var task in ScanTasks.All)
        {
            Assert.False(TaskCatalog.Apply(task, current).Output.AlsoSaveText);
        }
        Assert.True(current.Output.AlsoSaveText);
    }

    [Fact]
    public void Batch_SplitsAFeederStackAtSeparatorSheets_AndEndsWithoutASplit()
    {
        var definition = TaskCatalog.Definition(ScanTask.Batch);
        Assert.Equal("Scan stack", definition.Steps[0].PrimaryActionLabel);
        var s = TaskCatalog.Apply(ScanTask.Batch, new ScanSettings());
        Assert.Equal((ScanIntent.Document, ScanSource.DocumentFeeder, OutputFormat.Pdf, DuplexMode.Off, SplitMode.SeparatorSheet, true),
                     (s.Intent, s.Source, s.Format, s.Duplex, s.Document.SplitMode, s.Document.RemoveBlankPages));
        Assert.True(s.DocumentMultiPage && s.PdfSearchable);
        Assert.Equal(TaskFlowKind.DocumentQueue, TaskCatalog.FlowOf(s));
        Assert.Equal("300 dpi · Color · PDF · Split at separator sheets", TaskCatalog.Summary(s));
        Assert.True(TaskCatalog.Fits(ScanTask.Batch, s));
        // Another split still fits; no split ends the task, as leaving the feeder does.
        s.Document.SplitMode = SplitMode.BlankSheet;
        Assert.True(TaskCatalog.Fits(ScanTask.Batch, s));
        Assert.Equal("300 dpi · Color · PDF · Split at blank sheets", TaskCatalog.Summary(s));
        s.Document.SplitMode = SplitMode.SheetCount;
        s.Document.SplitSheetCount = 3;
        Assert.Equal("300 dpi · Color · PDF · Split every 3 sheets", TaskCatalog.Summary(s));
        s.Document.SplitSheetCount = 1;
        Assert.Equal("300 dpi · Color · PDF · Split every sheet", TaskCatalog.Summary(s));
        s.Document.SplitMode = SplitMode.None;
        Assert.False(TaskCatalog.Fits(ScanTask.Batch, s));
        s.Document.SplitMode = SplitMode.SeparatorSheet;
        s.Source = ScanSource.Flatbed;
        Assert.False(TaskCatalog.Fits(ScanTask.Batch, s));
        // Saved at once, nothing is split: the summary says nothing of it.
        s.DocumentMultiPage = false;
        Assert.Equal("300 dpi · Color · PDF", TaskCatalog.Summary(s));
    }

    [Fact]
    public void Apply_OnlyTheBatchTaskSplits_TheSheetCountIsKept()
    {
        var current = Customized();
        current.Document.SplitMode = SplitMode.BlankSheet;
        current.Document.SplitSheetCount = 4;
        foreach (var task in ScanTasks.All)
        {
            var s = TaskCatalog.Apply(task, current);
            Assert.Equal(task == ScanTask.Batch ? SplitMode.SeparatorSheet : SplitMode.None, s.Document.SplitMode);
            Assert.Equal(4, s.Document.SplitSheetCount);
        }
        Assert.Equal(SplitMode.BlankSheet, current.Document.SplitMode);
        // Without a stored task, split documents look like a batch.
        var untagged = TaskCatalog.Apply(ScanTask.Batch, new ScanSettings());
        untagged.TaskId = null;
        Assert.Equal(ScanTask.Batch, TaskCatalog.Infer(untagged));
        untagged.Source = ScanSource.Flatbed;
        Assert.Equal(ScanTask.Batch, TaskCatalog.Infer(untagged));
        untagged.Document.SplitMode = SplitMode.None;
        Assert.Equal(ScanTask.Document, TaskCatalog.Infer(untagged));
    }

    [Fact]
    public void Book_SplitsFacingPagesOnTheGlass_AndEndsWithoutTheSplit()
    {
        var definition = TaskCatalog.Definition(ScanTask.Book);
        Assert.Equal(("Scan spread", "book", "Book"), (definition.Steps[0].PrimaryActionLabel, definition.IconKey, definition.FileLabel));
        var s = TaskCatalog.Apply(ScanTask.Book, new ScanSettings());
        Assert.Equal((ScanIntent.Document, ScanSource.Flatbed, OutputFormat.Pdf, 300, ColorMode.Color, DuplexMode.Off),
                     (s.Intent, s.Source, s.Format, s.Resolution, s.ColorMode, s.Duplex));
        Assert.True(s.DocumentMultiPage && s.PdfSearchable);
        // Each page is straightened and turned upright on its own; nothing is cropped or skipped.
        Assert.Equal((true, true, true, false, false, SplitMode.None),
                     (s.Document.SplitFacingPages, s.Document.AutoStraighten, s.Document.AutoRotate, s.Document.AutoCrop,
                      s.Document.RemoveBlankPages, s.Document.SplitMode));
        // Left to right and not turned, unless chosen.
        Assert.Equal((false, 0), (s.TaskOptions.BookRightToLeft, s.TaskOptions.BookRotationQuarterTurns));
        Assert.Equal(TaskFlowKind.DocumentQueue, TaskCatalog.FlowOf(s));
        Assert.Equal(definition.Steps, TaskCatalog.GuidedSteps(s, null));
        Assert.Equal("300 dpi · Color · PDF · Facing pages split", TaskCatalog.Summary(s));
        s.TaskOptions.BookRightToLeft = true;
        Assert.Equal("300 dpi · Color · PDF · Facing pages split, right to left", TaskCatalog.Summary(s));
        // Two-sided feeder scans keep their pages as scanned: the line does not promise a split.
        var bothSides = s.Clone();
        bothSides.Source = ScanSource.DocumentFeeder;
        bothSides.Duplex = DuplexMode.Both;
        Assert.Equal("300 dpi · Color · PDF · Both sides", TaskCatalog.Summary(bothSides));
        Assert.True(TaskCatalog.Fits(ScanTask.Book, s));
        // Another format or color keeps the task; the feeder or no split ends it.
        s.ColorMode = ColorMode.Grayscale;
        s.Format = OutputFormat.Word;
        Assert.True(TaskCatalog.Fits(ScanTask.Book, s));
        s.Source = ScanSource.DocumentFeeder;
        Assert.False(TaskCatalog.Fits(ScanTask.Book, s));
        s.Source = ScanSource.Flatbed;
        s.Document.SplitFacingPages = false;
        Assert.False(TaskCatalog.Fits(ScanTask.Book, s));
        Assert.Equal("This scanner has no flatbed.",
                     TaskCatalog.Availability(ScanTask.Book, new ScannerCapabilities { Sources = [ScanSource.DocumentFeeder] }).Reason);
        // Saved at once, nothing is split: the summary says nothing of it.
        var once = TaskCatalog.Apply(ScanTask.Book, new ScanSettings());
        once.DocumentMultiPage = false;
        Assert.Equal("300 dpi · Color · PDF", TaskCatalog.Summary(once));
    }

    [Fact]
    public void Apply_OnlyTheBookTaskSplitsFacingPages_ItsReadingOrderAndTurnAreKept()
    {
        var current = Customized();
        current.Document.SplitFacingPages = true;
        foreach (var task in ScanTasks.All)
        {
            var s = TaskCatalog.Apply(task, current);
            Assert.Equal(task == ScanTask.Book, s.Document.SplitFacingPages);
            Assert.Equal((true, 3), (s.TaskOptions.BookRightToLeft, s.TaskOptions.BookRotationQuarterTurns));
        }
        Assert.True(current.Document.SplitFacingPages);
        // Without a stored task, split spreads look like a book; split documents still like a batch.
        var untagged = TaskCatalog.Apply(ScanTask.Book, new ScanSettings());
        untagged.TaskId = null;
        Assert.Equal(ScanTask.Book, TaskCatalog.Infer(untagged));
        untagged.Document.SplitMode = SplitMode.BlankSheet;
        Assert.Equal(ScanTask.Batch, TaskCatalog.Infer(untagged));
        untagged.Document.SplitMode = SplitMode.None;
        untagged.DocumentMultiPage = false;
        Assert.Equal(ScanTask.Document, TaskCatalog.Infer(untagged));
    }
}
