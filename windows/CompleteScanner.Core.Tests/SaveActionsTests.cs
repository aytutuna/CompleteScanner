using System.Text.Json;
using CompleteScanner.Core;
using Xunit;

namespace CompleteScanner.Core.Tests;

// Port of Tests/CompleteScannerTests/SaveActionsTests.swift: what happens after a save, the
// actions offered for saved files, what Copy puts on the clipboard and how files are sent.
public class SaveActionsTests
{
    private static readonly string[] OnePdf = ["Scan 2026-10-19 1.pdf"];
    private static readonly string[] ThreePhotos = ["Photo 1.jpg", "Photo 2.jpg", "Photo 3.jpg"];

    [Fact]
    public void AfterSave_NoneIsTheFirstMemberAndTheDefault()
    {
        Assert.Equal(["none", "open", "reveal", "share"],
                     Enum.GetValues<AfterSaveAction>().Select(a => JsonSerializer.Serialize(a, StoreFiles.JsonOptions).Trim('"')));
        Assert.Equal(AfterSaveAction.None, new OutputOptions().AfterSave);
        Assert.Equal(AfterSaveAction.None, new ScanSettings().Output.AfterSave);
    }

    [Fact]
    public void AfterSave_Labels()
    {
        Assert.Equal(["Do nothing", "Open", "Show in folder", "Share…"],
                     Enum.GetValues<AfterSaveAction>().Select(a => a.Label()));
        Assert.All(Enum.GetValues<AfterSaveAction>(), a => Assert.False(string.IsNullOrEmpty(a.Hint())));
        Assert.Equal(["Open", "Open with…", "Show in folder", "Share…", "Email…", "Copy"],
                     Enum.GetValues<FileAction>().Select(a => a.Label()));
    }

    [Fact]
    public void Plan_NothingToDo()
    {
        Assert.Null(SaveActions.Plan(AfterSaveAction.None, OnePdf));
        Assert.Null(SaveActions.Plan(AfterSaveAction.None, ThreePhotos));
        foreach (var action in Enum.GetValues<AfterSaveAction>())
        {
            Assert.Null(SaveActions.Plan(action, []));
        }
        Assert.Null(SaveActions.Plan((AfterSaveAction)99, OnePdf));
    }

    [Fact]
    public void Plan_OneFile_DoesWhatWasChosen()
    {
        Assert.Equal(new SaveFollowUp(AfterSaveAction.Open, OnePdf), SaveActions.Plan(AfterSaveAction.Open, OnePdf));
        Assert.Equal(new SaveFollowUp(AfterSaveAction.Reveal, OnePdf), SaveActions.Plan(AfterSaveAction.Reveal, OnePdf));
        Assert.Equal(new SaveFollowUp(AfterSaveAction.Share, OnePdf), SaveActions.Plan(AfterSaveAction.Share, OnePdf));
    }

    [Fact]
    public void Plan_SeveralFiles_AreShownInsteadOfOpenedOneByOne()
    {
        Assert.Equal(new SaveFollowUp(AfterSaveAction.Reveal, ThreePhotos), SaveActions.Plan(AfterSaveAction.Open, ThreePhotos));
        Assert.Equal(new SaveFollowUp(AfterSaveAction.Reveal, ThreePhotos), SaveActions.Plan(AfterSaveAction.Reveal, ThreePhotos));
        Assert.Equal(new SaveFollowUp(AfterSaveAction.Share, ThreePhotos), SaveActions.Plan(AfterSaveAction.Share, ThreePhotos));
    }

    [Fact]
    public void FollowUp_IsCarriedOutByItsFileAction()
    {
        Assert.Equal(FileAction.Open, SaveActions.Plan(AfterSaveAction.Open, OnePdf)!.FileAction);
        Assert.Equal(FileAction.Reveal, SaveActions.Plan(AfterSaveAction.Open, ThreePhotos)!.FileAction);
        Assert.Equal(FileAction.Reveal, SaveActions.Plan(AfterSaveAction.Reveal, OnePdf)!.FileAction);
        Assert.Equal(FileAction.Share, SaveActions.Plan(AfterSaveAction.Share, ThreePhotos)!.FileAction);
    }

    [Fact]
    public void Plan_CopiesThePaths()
    {
        var paths = new List<string>(OnePdf);
        var plan = SaveActions.Plan(AfterSaveAction.Share, paths)!;
        paths.Add("later.pdf");
        Assert.Equal(OnePdf, plan.Paths);
    }

    [Fact]
    public void Offered_DependsOnTheNumberOfFiles()
    {
        Assert.Empty(SaveActions.Offered(0));
        Assert.Equal([FileAction.Open, FileAction.OpenWith, FileAction.Reveal, FileAction.Share, FileAction.Email, FileAction.Copy],
                     SaveActions.Offered(1));
        Assert.Equal([FileAction.Reveal, FileAction.Share, FileAction.Email, FileAction.Copy], SaveActions.Offered(2));
        Assert.Equal(SaveActions.Offered(2), SaveActions.Offered(40));
    }

    [Fact]
    public void IsImageFile_ByExtension()
    {
        foreach (string name in new[] { "a.jpg", "a.JPG", "a.jpeg", "a.png", "a.tif", "a.TIFF", "Scan 1.2.png" })
        {
            Assert.True(SaveActions.IsImageFile(name), name);
        }
        foreach (string name in new[] { "a.pdf", "a.txt", "a", "jpg", "a.jpg.pdf", "a.webp" })
        {
            Assert.False(SaveActions.IsImageFile(name), name);
        }
    }

    [Fact]
    public void ClipboardContent_ThePictureOnlyForOneImage()
    {
        Assert.Equal(new ClipboardContent(["Photo 1.jpg"], "Photo 1.jpg"), SaveActions.ClipboardContentFor(["Photo 1.jpg"]));
        Assert.Equal(new ClipboardContent(["Scan.tiff"], "Scan.tiff"), SaveActions.ClipboardContentFor(["Scan.tiff"]));
        Assert.Equal(new ClipboardContent(OnePdf, null), SaveActions.ClipboardContentFor(OnePdf));
        Assert.Equal(new ClipboardContent(ThreePhotos, null), SaveActions.ClipboardContentFor(ThreePhotos));
        Assert.Equal(new ClipboardContent([], null), SaveActions.ClipboardContentFor([]));
    }

    [Fact]
    public void EmailRoute_ComposeThenShareThenFolder()
    {
        Assert.Equal(SendRoute.Compose, SaveActions.EmailRoute(new SendProbe(CanCompose: true, CanShare: true)));
        Assert.Equal(SendRoute.Compose, SaveActions.EmailRoute(new SendProbe(CanCompose: true, CanShare: false)));
        Assert.Equal(SendRoute.ShareSheet, SaveActions.EmailRoute(new SendProbe(CanCompose: false, CanShare: true)));
        Assert.Equal(SendRoute.ShowInFolder, SaveActions.EmailRoute(new SendProbe(CanCompose: false, CanShare: false)));
    }

    [Fact]
    public void ShareRoute_ShareThenFolder()
    {
        Assert.Equal(SendRoute.ShareSheet, SaveActions.ShareRoute(new SendProbe(CanCompose: true, CanShare: true)));
        Assert.Equal(SendRoute.ShareSheet, SaveActions.ShareRoute(new SendProbe(CanCompose: false, CanShare: true)));
        Assert.Equal(SendRoute.ShowInFolder, SaveActions.ShareRoute(new SendProbe(CanCompose: true, CanShare: false)));
        Assert.Equal(SendRoute.ShowInFolder, SaveActions.ShareRoute(new SendProbe(CanCompose: false, CanShare: false)));
    }

    [Fact]
    public void ShareTitle_NamesOneFileOrCountsThem()
    {
        Assert.Equal("Scan 2026-10-19 1.pdf", SaveActions.ShareTitle(OnePdf));
        Assert.Equal("Scan.pdf", SaveActions.ShareTitle([Path.Combine("folder", "Scan.pdf")]));
        Assert.Equal("3 files", SaveActions.ShareTitle(ThreePhotos));
    }

    // MARK: - The setting in settings files (CONTRACTS.md, rule 6)

    [Fact]
    public void AfterSave_IsWrittenUnderOutput_AndRoundTrips()
    {
        foreach (var action in Enum.GetValues<AfterSaveAction>())
        {
            var settings = new ScanSettings();
            settings.Output.AfterSave = action;
            string json = CompatFixtures.Encode(settings);
            using var written = JsonDocument.Parse(json);
            var output = written.RootElement.GetProperty("output");
            Assert.Equal(["pdfSize", "afterSave", "alsoSaveText", "archival", "protect", "wordPageImages"], output.EnumerateObject().Select(p => p.Name));
            Assert.Equal(JsonNamingPolicy.CamelCase.ConvertName(action.ToString()), output.GetProperty("afterSave").GetString());
            Assert.Equal(action, CompatFixtures.Decode<ScanSettings>(json).Output.AfterSave);
        }
    }

    [Fact]
    public void SettingsWithoutAfterSave_GetNone_RestIntact()
    {
        Assert.Equal(AfterSaveAction.None, CompatFixtures.Decode<ScanSettings>("{}").Output.AfterSave);
        var settings = CompatFixtures.Decode<ScanSettings>("""{"resolution": 150, "output": {"pdfSize": "compact"}}""");
        Assert.Equal(AfterSaveAction.None, settings.Output.AfterSave);
        Assert.Equal(PdfSizePreset.Compact, settings.Output.PdfSize);
        Assert.Equal(150, settings.Resolution);
    }

    [Fact]
    public void UnknownOrCorruptAfterSave_FallsBackToNone_RestIntact()
    {
        foreach (string value in new[] { "\"print\"", "\"Share\"", "\"SHARE\"", "3", "null", "true", "{}", "[\"share\"]" })
        {
            var settings = CompatFixtures.Decode<ScanSettings>(
                $$"""{"resolution": 150, "output": {"pdfSize": "smallest", "afterSave": {{value}}}, "pdfSearchable": false}""");
            Assert.Equal(AfterSaveAction.None, settings.Output.AfterSave);
            Assert.Equal(PdfSizePreset.Smallest, settings.Output.PdfSize);
            Assert.Equal(150, settings.Resolution);
            Assert.False(settings.PdfSearchable);
        }
    }

    [Fact]
    public void Clone_CopiesTheAfterSaveAction()
    {
        var settings = new ScanSettings();
        settings.Output.AfterSave = AfterSaveAction.Share;
        var clone = settings.Clone();
        Assert.Equal(AfterSaveAction.Share, clone.Output.AfterSave);
        clone.Output.AfterSave = AfterSaveAction.Open;
        Assert.Equal(AfterSaveAction.Share, settings.Output.AfterSave);
        Assert.NotEqual(settings.Output, clone.Output);
    }

    // MARK: - Tasks

    [Fact]
    public void EmailTask_SharesAfterSaving_OtherTasksDoNothing()
    {
        var current = new ScanSettings();
        current.Output.AfterSave = AfterSaveAction.Open;
        foreach (var task in ScanTasks.All)
        {
            var expected = task == ScanTask.Email ? AfterSaveAction.Share : AfterSaveAction.None;
            Assert.Equal(expected, TaskCatalog.Apply(task, current).Output.AfterSave);
        }
        Assert.Equal(AfterSaveAction.Open, current.Output.AfterSave);
        // Choosing another action by hand keeps the task.
        var email = TaskCatalog.Apply(ScanTask.Email, current);
        email.Output.AfterSave = AfterSaveAction.Reveal;
        Assert.True(TaskCatalog.Fits(ScanTask.Email, email));
        Assert.Contains("share window", TaskCatalog.Definition(ScanTask.Email).Steps[0].Prompt);
    }
}
