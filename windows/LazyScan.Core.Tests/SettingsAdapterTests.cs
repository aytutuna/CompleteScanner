using LazyScan.Core;
using Xunit;

namespace LazyScan.Core.Tests;

// Mirrored by Tests/LazyScanTests/SettingsAdapterTests.swift: the same cases.

public class SettingsAdapterTests
{
    [Fact]
    public void NoScanner_NothingChanges()
    {
        var settings = new ScanSettings { Resolution = 450, Source = ScanSource.DocumentFeeder };
        var adapted = SettingsAdapter.Adapt(settings, null);
        Assert.NotSame(settings, adapted.Settings);
        Assert.Equal(CompatFixtures.Encode(settings), CompatFixtures.Encode(adapted.Settings));
        Assert.Empty(adapted.Notes);
    }

    [Fact]
    public void SupportedSettings_NothingChanges()
    {
        var caps = new ScannerCapabilities { Sources = [ScanSource.Flatbed, ScanSource.DocumentFeeder] };
        var adapted = SettingsAdapter.Adapt(new ScanSettings { Source = ScanSource.DocumentFeeder }, caps);
        Assert.Equal(ScanSource.DocumentFeeder, adapted.Settings.Source);
        Assert.Equal(300, adapted.Settings.Resolution);
        Assert.Empty(adapted.Notes);
    }

    [Fact]
    public void Resolution_NearestSupported()
    {
        var caps = new ScannerCapabilities { SupportedResolutions = [100, 200, 400, 800] };
        var adapted = SettingsAdapter.Adapt(new ScanSettings { Resolution = 300 }, caps);
        // 300 is as near to 200 as to 400: the first listed wins, as before.
        Assert.Equal(200, adapted.Settings.Resolution);
        var note = Assert.Single(adapted.Notes);
        Assert.Equal(SettingsChange.Resolution, note.Change);
        Assert.Equal("This scanner does not offer 300 dpi, so 200 dpi is used.", note.Message);

        Assert.Equal(800, SettingsAdapter.Adapt(new ScanSettings { Resolution = 1200 }, caps).Settings.Resolution);
    }

    [Fact]
    public void Resolution_NoListedResolutions_Kept()
    {
        var caps = new ScannerCapabilities { SupportedResolutions = [] };
        var adapted = SettingsAdapter.Adapt(new ScanSettings { Resolution = 450 }, caps);
        Assert.Equal(450, adapted.Settings.Resolution);
        Assert.Empty(adapted.Notes);
    }

    [Fact]
    public void Source_NoFeeder_FallsBackToTheFlatbed()
    {
        var caps = new ScannerCapabilities { Sources = [ScanSource.Flatbed] };
        var adapted = SettingsAdapter.Adapt(new ScanSettings { Source = ScanSource.DocumentFeeder }, caps);
        Assert.Equal(ScanSource.Flatbed, adapted.Settings.Source);
        var note = Assert.Single(adapted.Notes);
        Assert.Equal(SettingsChange.Source, note.Change);
        Assert.Equal("This scanner has no document feeder, so the flatbed is used.", note.Message);
    }

    [Fact]
    public void Source_NoFlatbed_FallsBackToTheFeeder()
    {
        var caps = new ScannerCapabilities { Sources = [ScanSource.DocumentFeeder], SupportsOverview = false };
        var adapted = SettingsAdapter.Adapt(new ScanSettings(), caps);
        Assert.Equal(ScanSource.DocumentFeeder, adapted.Settings.Source);
        Assert.Equal("This scanner has no flatbed, so the document feeder is used.", Assert.Single(adapted.Notes).Message);
    }

    [Fact]
    public void Source_NoSourcesListed_Flatbed()
    {
        var caps = new ScannerCapabilities { Sources = [] };
        var feeder = SettingsAdapter.Adapt(new ScanSettings { Source = ScanSource.DocumentFeeder }, caps);
        Assert.Equal(ScanSource.Flatbed, feeder.Settings.Source);
        Assert.Single(feeder.Notes);
        // Already the flatbed: nothing to say.
        Assert.Empty(SettingsAdapter.Adapt(new ScanSettings(), caps).Notes);
    }

    [Fact]
    public void BothChanges_SourceFirst()
    {
        var caps = new ScannerCapabilities { Sources = [ScanSource.Flatbed], SupportedResolutions = [150, 300] };
        var adapted = SettingsAdapter.Adapt(new ScanSettings { Source = ScanSource.DocumentFeeder, Resolution = 1200 }, caps);
        Assert.Equal([SettingsChange.Source, SettingsChange.Resolution], adapted.Notes.Select(n => n.Change));
        Assert.Equal(ScanSource.Flatbed, adapted.Settings.Source);
        Assert.Equal(300, adapted.Settings.Resolution);
    }

    [Fact]
    public void Input_IsNotChanged_AndEverythingElseIsKept()
    {
        var settings = CompatFixtures.NonDefaultSettings();
        settings.TaskId = "photos";
        string before = CompatFixtures.Encode(settings);
        var caps = new ScannerCapabilities { Sources = [ScanSource.Flatbed], SupportedResolutions = [300] };

        var adapted = SettingsAdapter.Adapt(settings, caps);

        Assert.Equal(before, CompatFixtures.Encode(settings));
        var expected = CompatFixtures.NonDefaultSettings();
        expected.TaskId = "photos";
        expected.Source = ScanSource.Flatbed;
        expected.Resolution = 300;
        CompatFixtures.AssertSettingsEqual(expected, adapted.Settings);
        Assert.NotSame(settings.Adjustments, adapted.Settings.Adjustments);
    }

    // MARK: - Two-sided scanning and paper size

    private static ScannerCapabilities FeederScanner(bool duplex, SizeD? feederSize = null) => new()
    {
        Sources = [ScanSource.Flatbed, ScanSource.DocumentFeeder],
        SupportsDuplex = duplex,
        FeederSizeInches = feederSize,
    };

    [Fact]
    public void Duplex_OneSidedFeeder_TurnsTheStackOverByHand()
    {
        var settings = new ScanSettings { Source = ScanSource.DocumentFeeder, Duplex = DuplexMode.Both };
        var adapted = SettingsAdapter.Adapt(settings, FeederScanner(duplex: false));
        Assert.Equal(DuplexMode.Manual, adapted.Settings.Duplex);
        var note = Assert.Single(adapted.Notes);
        Assert.Equal(SettingsChange.Duplex, note.Change);
        Assert.Equal("This scanner's feeder scans one side at a time, so you'll turn the stack over by hand.", note.Message);
    }

    [Fact]
    public void Duplex_TwoSidedFeeder_OrTheFlatbed_NothingChanges()
    {
        var feeder = new ScanSettings { Source = ScanSource.DocumentFeeder, Duplex = DuplexMode.Both };
        var adapted = SettingsAdapter.Adapt(feeder, FeederScanner(duplex: true));
        Assert.Equal(DuplexMode.Both, adapted.Settings.Duplex);
        Assert.Empty(adapted.Notes);

        // The setting does nothing on the flatbed: it is kept for the feeder.
        var flatbed = new ScanSettings { Duplex = DuplexMode.Both };
        adapted = SettingsAdapter.Adapt(flatbed, FeederScanner(duplex: false));
        Assert.Equal(DuplexMode.Both, adapted.Settings.Duplex);
        Assert.Empty(adapted.Notes);

        var byHand = new ScanSettings { Source = ScanSource.DocumentFeeder, Duplex = DuplexMode.Manual };
        Assert.Empty(SettingsAdapter.Adapt(byHand, FeederScanner(duplex: false)).Notes);
    }

    [Fact]
    public void Duplex_AfterFallingBackToTheFeeder()
    {
        var caps = new ScannerCapabilities { Sources = [ScanSource.DocumentFeeder], SupportsOverview = false };
        var adapted = SettingsAdapter.Adapt(new ScanSettings { Duplex = DuplexMode.Both }, caps);
        Assert.Equal((ScanSource.DocumentFeeder, DuplexMode.Manual), (adapted.Settings.Source, adapted.Settings.Duplex));
        Assert.Equal([SettingsChange.Source, SettingsChange.Duplex], adapted.Notes.Select(n => n.Change));
    }

    [Fact]
    public void PaperSize_LargerThanTheGlass_IsAutomatic()
    {
        var caps = new ScannerCapabilities { FlatbedSizeInches = new SizeD(8.5, 11.7) };
        var adapted = SettingsAdapter.Adapt(new ScanSettings { PaperSize = PaperSize.Legal }, caps);
        Assert.Equal(PaperSize.Auto, adapted.Settings.PaperSize);
        var note = Assert.Single(adapted.Notes);
        Assert.Equal(SettingsChange.PaperSize, note.Change);
        Assert.Equal("Legal paper does not fit this scanner's glass, so the paper size is Automatic.", note.Message);
        Assert.Equal(PaperSize.A4, SettingsAdapter.Adapt(new ScanSettings { PaperSize = PaperSize.A4 }, caps).Settings.PaperSize);
    }

    [Fact]
    public void PaperSize_LargerThanTheFeeder_IsAutomatic_UnknownFeederSizeKeepsIt()
    {
        var settings = new ScanSettings { Source = ScanSource.DocumentFeeder, PaperSize = PaperSize.Legal };
        var adapted = SettingsAdapter.Adapt(settings, FeederScanner(duplex: true, new SizeD(8.5, 11)));
        Assert.Equal(PaperSize.Auto, adapted.Settings.PaperSize);
        Assert.Equal("Legal paper does not fit this scanner's feeder, so the paper size is Automatic.",
                     Assert.Single(adapted.Notes).Message);
        Assert.Equal(PaperSize.Legal, SettingsAdapter.Adapt(settings, FeederScanner(duplex: true, new SizeD(8.5, 14))).Settings.PaperSize);
        Assert.Equal(PaperSize.Legal, SettingsAdapter.Adapt(settings, FeederScanner(duplex: true)).Settings.PaperSize);
    }

    [Fact]
    public void TwoSidedTask_OnAOneSidedFeeder_StillFits()
    {
        var adapted = SettingsAdapter.Adapt(TaskCatalog.Apply(ScanTask.TwoSided, new ScanSettings()), FeederScanner(duplex: false));
        Assert.Equal(DuplexMode.Manual, adapted.Settings.Duplex);
        Assert.True(TaskCatalog.Fits(ScanTask.TwoSided, adapted.Settings));
    }

    [Fact]
    public void TwoSidedTask_WhileTheFeederIsNotYetAsked_KeepsBothSides()
    {
        // ImageCaptureCore tells whether the feeder scans both sides only once it is selected.
        var unknown = DocumentSides.CapabilitiesForSides(FeederScanner(duplex: false), duplexKnown: false);
        var task = TaskCatalog.Apply(ScanTask.TwoSided, new ScanSettings());
        var adapted = SettingsAdapter.Adapt(task, unknown);
        Assert.Equal(DuplexMode.Both, adapted.Settings.Duplex);
        Assert.Empty(adapted.Notes);
        Assert.Equal("300 dpi · Color · PDF · Both sides", TaskCatalog.Summary(adapted.Settings));
        Assert.Null(TaskCatalog.GuidedSteps(adapted.Settings, unknown)?.SingleOrDefault(s => s.Id == DocumentSides.BacksStepId));
    }

    [Fact]
    public void TaskSettings_OnAFeederOnlyScanner()
    {
        var caps = new ScannerCapabilities
        {
            Sources = [ScanSource.DocumentFeeder],
            SupportedResolutions = [150, 300, 600],
            SupportsOverview = false,
        };
        var photos = SettingsAdapter.Adapt(TaskCatalog.Apply(ScanTask.Photos, new ScanSettings()), caps).Settings;
        Assert.Equal(ScanSource.DocumentFeeder, photos.Source);
        Assert.True(TaskCatalog.Fits(ScanTask.Photos, photos));
        var quick = SettingsAdapter.Adapt(TaskCatalog.Apply(ScanTask.QuickScan, new ScanSettings()), caps).Settings;
        Assert.False(TaskCatalog.Fits(ScanTask.QuickScan, quick));
    }
}
