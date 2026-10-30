using System.Text.Json;
using LazyScan.Core;
using Xunit;

namespace LazyScan.Core.Tests;

// Windows-side tests for model additions ported from Core/Models.swift and the history /
// page-rotation / re-crop bookkeeping ported from AppState.swift.

public class ModelsTests
{
    private static RgbaImage Gray(int width, int height) => RgbaImage.Filled(width, height, 128, 128, 128);

    // MARK: - Scan history

    private static ScanHistoryEntry Entry(int dpi) =>
        new(DateTime.Now, ScanIntent.Document, dpi, Gray(4, 4), new SizeD(4, 4));

    [Fact]
    public void HistoryRecordsNewestFirst()
    {
        var history = new List<ScanHistoryEntry>();
        ScanHistory.Record(history, [Entry(1), Entry(2)]);
        ScanHistory.Record(history, [Entry(3), Entry(4), Entry(5)]);
        // Within a batch the last page leads; later batches go in front of earlier ones.
        Assert.Equal([5, 4, 3, 2, 1], history.Select(e => e.Dpi));
    }

    [Fact]
    public void HistoryIsCappedAtFiftyEntries()
    {
        var history = new List<ScanHistoryEntry>();
        for (int i = 1; i <= 60; i++) ScanHistory.Record(history, [Entry(i)]);
        Assert.Equal(ScanHistory.MaxEntries, history.Count);
        Assert.Equal(50, history.Count);
        Assert.Equal(60, history[0].Dpi);
        Assert.Equal(11, history[^1].Dpi);
    }

    [Fact]
    public void HistoryEntriesCarrySmallThumbnailsAndTrueSize()
    {
        var date = new DateTime(2026, 8, 13, 14, 5, 9);
        var big = new ScannedPage(Gray(1400, 700), 300, ColorMode.Color);
        var small = new ScannedPage(Gray(500, 650), 150, ColorMode.Grayscale);
        var entries = ScanHistory.MakeEntries([big, small], ScanIntent.Photo, date);

        Assert.Equal(2, entries.Count);
        Assert.Equal(700, entries[0].Thumbnail.Width);
        Assert.Equal(350, entries[0].Thumbnail.Height);
        Assert.Equal(new SizeD(1400, 700), entries[0].PixelSize);
        Assert.Equal(300, entries[0].Dpi);
        Assert.Equal(ScanIntent.Photo, entries[0].Intent);
        Assert.Equal(date, entries[0].Date);
        // Already small enough: passed through untouched.
        Assert.Same(small.Image, entries[1].Thumbnail);
        Assert.Equal(new SizeD(500, 650), entries[1].PixelSize);
        Assert.NotEqual(entries[0].Id, entries[1].Id);
    }

    // MARK: - Detected photos

    [Fact]
    public void DetectedPhotoSourcePageIdDefaultsToNull()
    {
        var region = new DetectedPhotoRegion(new PointD(5, 5), new SizeD(10, 10), 0);
        Assert.Null(new DetectedPhoto(region, Gray(10, 10), 300).SourcePageId);
        var pageId = Guid.NewGuid();
        Assert.Equal(pageId, new DetectedPhoto(region, Gray(10, 10), 300, sourcePageId: pageId).SourcePageId);
    }

    [Fact]
    public void RecroppedPhotoKeepsIdentityAndUserChoices()
    {
        var pageId = Guid.NewGuid();
        var original = new DetectedPhoto(new DetectedPhotoRegion(new PointD(50, 50), new SizeD(80, 60), 3),
                                         Gray(80, 60), 600, sourcePageId: pageId)
        {
            Included = false,
            RotationQuarterTurns = 3,
        };
        var source = Gray(200, 200);
        var edited = new DetectedPhotoRegion(new PointD(60, 55), new SizeD(90, 70), -2);
        var image = PhotoDetector.ExtractPhoto(source, edited, deskew: true)!;
        var updated = original.Recropped(edited, image);

        Assert.Equal(original.Id, updated.Id);
        Assert.Equal(pageId, updated.SourcePageId);
        Assert.Equal(600, updated.Dpi);
        Assert.False(updated.Included);
        Assert.Equal(3, updated.RotationQuarterTurns);
        Assert.Same(edited, updated.Region);
        Assert.Equal(90, updated.Image.Width);
        Assert.Equal(70, updated.Image.Height);
    }

    // MARK: - Page rotation

    [Fact]
    public void RotatedClockwiseTurnsPreviewAndCountsTurns()
    {
        var page = new ScannedPage(Gray(40, 20), 300, ColorMode.Grayscale, filePath: "spool.png",
                                   fullPixelSize: new SizeD(400, 200));
        var once = page.RotatedClockwise();
        Assert.Equal(page.Id, once.Id);
        Assert.Equal(page.CreatedAt, once.CreatedAt);
        Assert.Equal("spool.png", once.FilePath);
        Assert.Equal(new SizeD(400, 200), once.FullPixelSize); // recorded pre-rotation
        Assert.Equal(ColorMode.Grayscale, once.ColorMode);
        Assert.Equal(20, once.Image.Width);
        Assert.Equal(40, once.Image.Height);
        Assert.Equal(1, once.RotationQuarterTurns);

        var four = once.RotatedClockwise().RotatedClockwise().RotatedClockwise();
        Assert.Equal(0, four.RotationQuarterTurns);
        Assert.Equal(40, four.Image.Width);
    }

    // MARK: - Settings compatibility

    [Fact]
    public void LegacySettingsWithOcrLanguagesStillLoad()
    {
        const string json = """
            {
              "intent": "photo",
              "resolution": 600,
              "pdfSearchable": false,
              "ocrLanguages": ["de-DE", "fr-FR"],
              "adjustments": { "sharpness": -1.5 }
            }
            """;
        var settings = JsonSerializer.Deserialize<ScanSettings>(json, StoreFiles.JsonOptions);
        Assert.NotNull(settings);
        Assert.Equal(ScanIntent.Photo, settings!.Intent);
        Assert.Equal(600, settings.Resolution);
        Assert.False(settings.PdfSearchable);
        Assert.Equal(-1.5, settings.Adjustments.Sharpness);
        // The legacy value is really bound (not silently dropped as an unknown member)...
#pragma warning disable CS0618 // the legacy field is exactly what is under test
        Assert.Equal(["de-DE", "fr-FR"], settings.OcrLanguages);
#pragma warning restore CS0618
        // ...and written back under the same name, so older versions still read it.
        AssertRoundTripsOcrLanguages(JsonSerializer.Serialize(settings, StoreFiles.JsonOptions));
    }

    /// <summary>The serialized JSON carries "ocrLanguages": ["de-DE", "fr-FR"] (at any depth).</summary>
    private static void AssertRoundTripsOcrLanguages(string json)
    {
        Assert.Contains("\"ocrLanguages\"", json);
        using var document = JsonDocument.Parse(json);
        static JsonElement? Find(JsonElement element)
        {
            switch (element.ValueKind)
            {
                case JsonValueKind.Object:
                    foreach (var property in element.EnumerateObject())
                    {
                        if (property.Name == "ocrLanguages") return property.Value;
                        if (Find(property.Value) is { } nested) return nested;
                    }
                    break;
                case JsonValueKind.Array:
                    foreach (var item in element.EnumerateArray())
                        if (Find(item) is { } nested) return nested;
                    break;
            }
            return null;
        }
        var languages = Find(document.RootElement);
        Assert.NotNull(languages);
        Assert.Equal(["de-DE", "fr-FR"], languages!.Value.EnumerateArray().Select(e => e.GetString()));
    }

    [Fact]
    public void SettingsWithoutOcrLanguagesLoad()
    {
        const string json = """{ "intent": "document", "resolution": 200 }""";
        var settings = JsonSerializer.Deserialize<ScanSettings>(json, StoreFiles.JsonOptions);
        Assert.NotNull(settings);
        Assert.Equal(200, settings!.Resolution);
    }

    [Fact]
    public void LegacyPresetsWithOcrLanguagesStillLoad()
    {
        const string json = """
            [ { "id": "6f1c1f43-58f4-4d2b-9a43-0a1d0f6a8f10", "name": "Old",
                "settings": { "resolution": 300, "ocrLanguages": ["de-DE", "fr-FR"] } } ]
            """;
        var presets = JsonSerializer.Deserialize<List<Preset>>(json, StoreFiles.JsonOptions);
        Assert.NotNull(presets);
        Assert.Single(presets!);
        Assert.Equal("Old", presets[0].Name);
        Assert.Equal(300, presets[0].Settings.Resolution);
        // Not the default (["en-US"]): the stored value was actually loaded and is written back.
#pragma warning disable CS0618 // the legacy field is exactly what is under test
        Assert.Equal(["de-DE", "fr-FR"], presets[0].Settings.OcrLanguages);
#pragma warning restore CS0618
        AssertRoundTripsOcrLanguages(JsonSerializer.Serialize(presets, StoreFiles.JsonOptions));
    }

    // MARK: - App preferences

    [Theory]
    [InlineData(AppAppearance.System, "system")]
    [InlineData(AppAppearance.Light, "light")]
    [InlineData(AppAppearance.Dark, "dark")]
    public void AppearanceRoundTripsAsCamelCaseString(AppAppearance appearance, string expected)
    {
        string json = JsonSerializer.Serialize(new AppPreferences { Appearance = appearance }, StoreFiles.JsonOptions);
        using (var document = JsonDocument.Parse(json))
        {
            Assert.Equal(expected, document.RootElement.GetProperty("appearance").GetString());
        }
        var back = JsonSerializer.Deserialize<AppPreferences>(json, StoreFiles.JsonOptions);
        Assert.Equal(appearance, back!.Appearance);
    }

    [Fact]
    public void EmptyPreferencesFollowTheSystem()
    {
        var preferences = JsonSerializer.Deserialize<AppPreferences>("{}", StoreFiles.JsonOptions);
        Assert.Equal(AppAppearance.System, preferences!.Appearance);
        Assert.Equal(AppAppearance.System, new AppPreferences().Appearance);
    }

    [Fact]
    public void UnknownAppearanceFallsBackToSystemAndTheFileStaysInPlace()
    {
        const string json = """{ "appearance": "sepia" }""";
        // A value written by a newer version resets only that field (see ModelsCompatTests).
        var preferences = JsonSerializer.Deserialize<AppPreferences>(json, StoreFiles.JsonOptions);
        Assert.Equal(AppAppearance.System, preferences!.Appearance);

        string dir = Path.Combine(Path.GetTempPath(), "CompleteScanner.Tests." + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dir);
        try
        {
            string path = Path.Combine(dir, "preferences.json");
            File.WriteAllText(path, json);
            Assert.Equal(AppAppearance.System, AppPreferencesStore.Load(dir).Appearance);
            // The file decoded, so nothing was moved aside.
            Assert.Equal([path], Directory.GetFiles(dir));
        }
        finally
        {
            Directory.Delete(dir, recursive: true);
        }
    }
}
