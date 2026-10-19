using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;
using CompleteScanner.Core;
using Xunit;

namespace CompleteScanner.Core.Tests;

// Port of Tests/CompleteScannerTests/ModelsCompatTests.swift: settings files load across
// versions (CONTRACTS.md, rule 6). Same cases, same fixtures; the fixture JSON is in the
// format this platform writes (declaration order, lowercase id).

internal static class CompatFixtures
{
    public static T Decode<T>(string json) where T : class =>
        JsonSerializer.Deserialize<T>(json, StoreFiles.JsonOptions)!;

    /// <summary>Encoded exactly the way the stores write files.</summary>
    public static string Encode<T>(T value) => JsonSerializer.Serialize(value, StoreFiles.JsonOptions);

    public static readonly Guid SampleId = Guid.Parse("3F2504E0-4F89-41D3-9A0C-0305E82C3301");

    /// <summary>
    /// Every field set to a non-default value. Values are exactly representable in binary
    /// so equality after a JSON round trip does not depend on decimal parsing.
    /// </summary>
    public static ScanSettings NonDefaultSettings()
    {
        var settings = new ScanSettings
        {
            Intent = ScanIntent.Photo,
            Source = ScanSource.DocumentFeeder,
            Resolution = 600,
            ColorMode = ColorMode.Grayscale,
            Format = OutputFormat.Tiff,
            JpegQuality = 0.625,
            DestinationPath = "/Users/someone/Scans",
            NamingTemplate = "Receipt {date}",
            PhotoAutoSplit = false,
            PhotoAutoDeskew = false,
            PhotoMinSideInches = 2.5,
            PhotoCropInsetPixels = 4,
            DocumentMultiPage = false,
            PdfSearchable = false,
        };
#pragma warning disable CS0618 // the legacy field is persisted and must round-trip
        settings.OcrLanguages = ["de-DE", "en-US"];
#pragma warning restore CS0618
        settings.Adjustments.AutoEnhance = true;
        settings.Adjustments.Brightness = 0.25;
        settings.Adjustments.Contrast = 1.5;
        settings.Adjustments.Saturation = 0.75;
        settings.Adjustments.Sharpness = -0.5;
        settings.Adjustments.Descreen = true;
        settings.Adjustments.RestoreFadedColors = true;
        settings.Adjustments.BlackWhiteThreshold = 0.375;
        return settings;
    }

    /// <summary>
    /// <see cref="NonDefaultSettings"/> as a presets file written by the serializer before
    /// tolerant decoding existed (indented, camelCase, every property present).
    /// </summary>
    public const string CurrentFormatPresetsJson = """
        [
          {
            "id": "3f2504e0-4f89-41d3-9a0c-0305e82c3301",
            "name": "Receipts",
            "settings": {
              "intent": "photo",
              "source": "documentFeeder",
              "resolution": 600,
              "colorMode": "grayscale",
              "format": "tiff",
              "jpegQuality": 0.625,
              "destinationPath": "/Users/someone/Scans",
              "namingTemplate": "Receipt {date}",
              "photoAutoSplit": false,
              "photoAutoDeskew": false,
              "photoMinSideInches": 2.5,
              "photoCropInsetPixels": 4,
              "documentMultiPage": false,
              "pdfSearchable": false,
              "ocrLanguages": [
                "de-DE",
                "en-US"
              ],
              "adjustments": {
                "autoEnhance": true,
                "brightness": 0.25,
                "contrast": 1.5,
                "saturation": 0.75,
                "sharpness": -0.5,
                "descreen": true,
                "restoreFadedColors": true,
                "blackWhiteThreshold": 0.375
              }
            }
          }
        ]
        """;

    /// <summary>Field-by-field equality, including the legacy OCR languages.</summary>
    public static void AssertSettingsEqual(ScanSettings expected, ScanSettings actual)
    {
        Assert.Equal(Encode(expected), Encode(actual));
    }

    public static void AssertPresetsEqual(IReadOnlyList<Preset> expected, IReadOnlyList<Preset> actual)
    {
        Assert.Equal(Encode(expected), Encode(actual));
    }
}

// MARK: - Decoding compatibility

public class ModelsCompatTests
{
    private static T Decode<T>(string json) where T : class => CompatFixtures.Decode<T>(json);

    [Fact]
    public void EmptyObject_DecodesToDefaults()
    {
        CompatFixtures.AssertSettingsEqual(new ScanSettings(), Decode<ScanSettings>("{}"));
        Assert.Equal(new AdjustmentSettings(), Decode<AdjustmentSettings>("{}"));
    }

    [Fact]
    public void MissingKeys_KeepPresentValuesAndDefaultTheRest()
    {
        var settings = Decode<ScanSettings>("""
            {"resolution": 600, "colorMode": "grayscale", "adjustments": {"contrast": 1.5}}
            """);
        var expected = new ScanSettings { Resolution = 600, ColorMode = ColorMode.Grayscale };
        expected.Adjustments.Contrast = 1.5;
        CompatFixtures.AssertSettingsEqual(expected, settings);
    }

    [Fact]
    public void PresetMissingEverything_GetsNameAndDefaultSettings()
    {
        var preset = Decode<Preset>("{}");
        Assert.Equal(Preset.FallbackName, preset.Name);
        CompatFixtures.AssertSettingsEqual(new ScanSettings(), preset.Settings);
    }

    [Fact]
    public void PresetMissingId_GetsFreshIdAndKeepsTheRest()
    {
        var preset = Decode<Preset>("""{"name": "Mine", "settings": {"resolution": 150}}""");
        Assert.Equal("Mine", preset.Name);
        Assert.Equal(150, preset.Settings.Resolution);
        Assert.NotEqual(Guid.Empty, preset.Id);
        Assert.NotEqual(preset.Id, Decode<Preset>("""{"name": "Mine"}""").Id);
    }

    [Fact]
    public void UnknownEnumValues_FallBackToDefault_RestOfPresetIntact()
    {
        string json = CompatFixtures.CurrentFormatPresetsJson
            .Replace("\"grayscale\"", "\"hyperspectral\"")
            .Replace("\"tiff\"", "\"webp\"")
            .Replace("\"photo\"", "\"receipt\"")
            .Replace("\"documentFeeder\"", "\"transparencyUnit\"");
        var presets = Decode<List<Preset>>(json);

        Assert.Single(presets);
        var expected = CompatFixtures.NonDefaultSettings();
        expected.ColorMode = new ScanSettings().ColorMode;
        expected.Format = new ScanSettings().Format;
        expected.Intent = new ScanSettings().Intent;
        expected.Source = new ScanSettings().Source;
        Assert.Equal(CompatFixtures.SampleId, presets[0].Id);
        Assert.Equal("Receipts", presets[0].Name);
        CompatFixtures.AssertSettingsEqual(expected, presets[0].Settings);
    }

    [Fact]
    public void NumericOrMiscasedEnumValues_FallBackToDefault()
    {
        // Swift enums decode only their exact raw value: no numbers, no other casing.
        var settings = Decode<ScanSettings>("""
            {"colorMode": 1, "format": "Tiff", "intent": "PHOTO", "source": "documentFeeder"}
            """);
        var expected = new ScanSettings { Source = ScanSource.DocumentFeeder };
        CompatFixtures.AssertSettingsEqual(expected, settings);
    }

    [Fact]
    public void WrongTypedField_FallsBackToDefault_RestIntact()
    {
        var settings = Decode<ScanSettings>("""
            {"resolution": "high", "pdfSearchable": false, "ocrLanguages": "en-US"}
            """);
        var expected = new ScanSettings { PdfSearchable = false };
        CompatFixtures.AssertSettingsEqual(expected, settings);
    }

    [Fact]
    public void NullListElement_ResetsThatField()
    {
        var settings = Decode<ScanSettings>("""
            {"resolution": 150, "ocrLanguages": ["de-DE", null]}
            """);
        var expected = new ScanSettings { Resolution = 150 };
        CompatFixtures.AssertSettingsEqual(expected, settings);
    }

    [Fact]
    public void CorruptNestedObject_ResetsOnlyThatField()
    {
        var settings = Decode<ScanSettings>("""
            {"resolution": 1200, "adjustments": "not an object"}
            """);
        var expected = new ScanSettings { Resolution = 1200 };
        CompatFixtures.AssertSettingsEqual(expected, settings);
    }

    [Fact]
    public void CorruptNestedField_ResetsOnlyThatNestedField()
    {
        var settings = Decode<ScanSettings>("""
            {"adjustments": {"brightness": "bright", "contrast": 2.5, "descreen": true}}
            """);
        var expected = new ScanSettings();
        expected.Adjustments.Contrast = 2.5;
        expected.Adjustments.Descreen = true;
        CompatFixtures.AssertSettingsEqual(expected, settings);
    }

    [Fact]
    public void NullValues_FallBackToDefault()
    {
        var preset = Decode<Preset>("""{"name": "Nulls", "settings": null}""");
        Assert.Equal("Nulls", preset.Name);
        CompatFixtures.AssertSettingsEqual(new ScanSettings(), preset.Settings);

        var settings = Decode<ScanSettings>("""{"resolution": null, "adjustments": null}""");
        CompatFixtures.AssertSettingsEqual(new ScanSettings(), settings);

        var named = Decode<Preset>("""{"id": null, "name": null}""");
        Assert.Equal(Preset.FallbackName, named.Name);
        Assert.NotEqual(Guid.Empty, named.Id);
    }

    [Fact]
    public void KeysFromNewerVersions_AreIgnored()
    {
        var settings = Decode<ScanSettings>("""
            {"resolution": 200, "duplex": "both", "output": {"pdfSize": "compact"}}
            """);
        var expected = new ScanSettings { Resolution = 200 };
        CompatFixtures.AssertSettingsEqual(expected, settings);
    }

    [Fact]
    public void CurrentFormatJson_DecodesIdentically()
    {
        var presets = Decode<List<Preset>>(CompatFixtures.CurrentFormatPresetsJson);
        CompatFixtures.AssertPresetsEqual(
            [new Preset("Receipts", CompatFixtures.NonDefaultSettings()) { Id = CompatFixtures.SampleId }],
            presets);
    }

    [Fact]
    public void RoundTrip_PreservesEveryField()
    {
        List<Preset> presets =
        [
            new Preset("Receipts", CompatFixtures.NonDefaultSettings()) { Id = CompatFixtures.SampleId },
            new Preset("Defaults", new ScanSettings()),
        ];
        var decoded = Decode<List<Preset>>(CompatFixtures.Encode(presets));
        Assert.Equal(presets.Select(p => p.Id), decoded.Select(p => p.Id));
        Assert.Equal(presets.Select(p => p.Name), decoded.Select(p => p.Name));
        Assert.Equal(presets[0].Settings.Adjustments, decoded[0].Settings.Adjustments);
        CompatFixtures.AssertPresetsEqual(presets, decoded);
    }

    [Fact]
    public void Encoding_WritesTheSameKeysAsBefore()
    {
        using var settings = JsonDocument.Parse(CompatFixtures.Encode(CompatFixtures.NonDefaultSettings()));
        Assert.Equal(
            [
                "intent", "source", "resolution", "colorMode", "format", "jpegQuality",
                "destinationPath", "namingTemplate", "photoAutoSplit", "photoAutoDeskew",
                "photoMinSideInches", "photoCropInsetPixels", "documentMultiPage",
                "pdfSearchable", "ocrLanguages", "adjustments",
            ],
            settings.RootElement.EnumerateObject().Select(p => p.Name));
        var adjustments = settings.RootElement.GetProperty("adjustments");
        Assert.Equal(
            [
                "autoEnhance", "brightness", "contrast", "saturation", "sharpness",
                "descreen", "restoreFadedColors", "blackWhiteThreshold",
            ],
            adjustments.EnumerateObject().Select(p => p.Name));
        Assert.Equal("grayscale", settings.RootElement.GetProperty("colorMode").GetString());
        Assert.Equal("documentFeeder", settings.RootElement.GetProperty("source").GetString());

        using var preset = JsonDocument.Parse(CompatFixtures.Encode(
            new Preset("P", new ScanSettings()) { Id = CompatFixtures.SampleId }));
        Assert.Equal(["id", "name", "settings"], preset.RootElement.EnumerateObject().Select(p => p.Name));
        Assert.Equal(CompatFixtures.SampleId.ToString(), preset.RootElement.GetProperty("id").GetString());
    }

    [Fact]
    public void Encoding_MatchesCurrentFormatFile()
    {
        string written = CompatFixtures.Encode(new List<Preset>
        {
            new("Receipts", CompatFixtures.NonDefaultSettings()) { Id = CompatFixtures.SampleId },
        });
        Assert.Equal(CompatFixtures.CurrentFormatPresetsJson.ReplaceLineEndings("\n"), written.ReplaceLineEndings("\n"));
    }

    // MARK: - Property converters (Windows only)

    /// <summary>Reads any string upper-cased, writes lower-case; anything but a string fails.</summary>
    private sealed class CaseConverter : JsonConverter<string>
    {
        public override string Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) =>
            reader.TokenType == JsonTokenType.String
                ? reader.GetString()!.ToUpperInvariant()
                : throw new JsonException("not a string");

        public override void Write(Utf8JsonWriter writer, string value, JsonSerializerOptions options) =>
            writer.WriteStringValue(value.ToLowerInvariant());
    }

    public sealed class ConverterAttributeSample
    {
        [JsonConverter(typeof(CaseConverter))]
        public string Code { get; set; } = "DEFAULT";

        [JsonConverter(typeof(JsonStringEnumConverter))]
        public ColorMode Mode { get; set; } = ColorMode.Color;

        public int Count { get; set; } = 7;
    }

    [Fact]
    public void PropertyConverterAttributes_StillApply_AndStayLenient()
    {
        string json = CompatFixtures.Encode(new ConverterAttributeSample { Code = "ABC", Mode = ColorMode.Grayscale });
        using (var document = JsonDocument.Parse(json))
        {
            Assert.Equal("abc", document.RootElement.GetProperty("code").GetString());
            // The attribute's factory (no naming policy) wins over the options' camelCase enums.
            Assert.Equal("Grayscale", document.RootElement.GetProperty("mode").GetString());
        }

        var back = Decode<ConverterAttributeSample>(json);
        Assert.Equal("ABC", back.Code);
        Assert.Equal(ColorMode.Grayscale, back.Mode);

        var bad = Decode<ConverterAttributeSample>("""{"code": 5, "mode": "nope", "count": 3}""");
        Assert.Equal("DEFAULT", bad.Code);
        Assert.Equal(ColorMode.Color, bad.Mode);
        Assert.Equal(3, bad.Count);
    }

    // MARK: - App preferences (Windows only: the Mac app has no preferences file)

    [Fact]
    public void UnknownOrCorruptAppearance_FallsBackToSystem()
    {
        Assert.Equal(AppAppearance.System, Decode<AppPreferences>("""{ "appearance": "sepia" }""").Appearance);
        Assert.Equal(AppAppearance.System, Decode<AppPreferences>("""{ "appearance": 2 }""").Appearance);
        Assert.Equal(AppAppearance.System, Decode<AppPreferences>("""{ "appearance": null }""").Appearance);
        Assert.Equal(AppAppearance.Dark,
                     Decode<AppPreferences>("""{ "appearance": "dark", "accent": "teal" }""").Appearance);
    }

    [Fact]
    public void PreferredConnection_MissingOrCorrupt_IsEmptyAndKeepsTheAppearance()
    {
        Assert.Empty(Decode<AppPreferences>("""{ "appearance": "dark" }""").PreferredConnection);
        var corrupt = Decode<AppPreferences>("""{ "appearance": "dark", "preferredConnection": [1, 2] }""");
        Assert.Empty(corrupt.PreferredConnection);
        Assert.Equal(AppAppearance.Dark, corrupt.Appearance);
        Assert.Empty(Decode<AppPreferences>("""{ "preferredConnection": null }""").PreferredConnection);
    }

    [Fact]
    public void PreferredConnection_KeysAreWrittenUnchanged()
    {
        var preferences = new AppPreferences();
        preferences.PreferredConnection["model:epson perfection v600"] = "twain:USB";
        string json = CompatFixtures.Encode(preferences);
        Assert.Contains("\"preferredConnection\"", json);
        Assert.Contains("\"model:epson perfection v600\": \"twain:USB\"", json);
        Assert.Equal("twain:USB", Decode<AppPreferences>(json).PreferredConnection["model:epson perfection v600"]);
    }
}

// MARK: - Store files

public sealed class PresetStoreFileTests : IDisposable
{
    private readonly string _directory;

    public PresetStoreFileTests()
    {
        _directory = Path.Combine(Path.GetTempPath(), "CompleteScannerTests-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(_directory);
    }

    public void Dispose()
    {
        try { Directory.Delete(_directory, recursive: true); } catch (IOException) { }
    }

    private string PresetsPath => Path.Combine(_directory, "presets.json");
    private string SettingsPath => Path.Combine(_directory, "settings.json");
    private string PreferencesPath => Path.Combine(_directory, "preferences.json");

    private List<string> KeptFiles(string prefix) =>
        Directory.GetFiles(_directory)
            .Select(Path.GetFileName)
            .Select(name => name!)
            .Where(name => name.StartsWith(prefix, StringComparison.Ordinal))
            .Order(StringComparer.Ordinal)
            .ToList();

    private static readonly byte[] Garbage = Encoding.UTF8.GetBytes("this is not JSON {");

    [Fact]
    public void MissingPresetsFile_SeedsBuiltInsWithoutKeepingAnything()
    {
        var presets = new PresetStore(_directory).Load();

        Assert.NotEmpty(presets);
        Assert.True(File.Exists(PresetsPath));
        Assert.Empty(KeptFiles("presets.unreadable-"));
        // The seeded file is what the next launch reads.
        CompatFixtures.AssertPresetsEqual(presets, new PresetStore(_directory).Load());
    }

    [Fact]
    public void UnreadablePresetsFile_IsKeptBeforeSeeding()
    {
        File.WriteAllBytes(PresetsPath, Garbage);

        var presets = new PresetStore(_directory).Load();

        Assert.NotEmpty(presets);
        var kept = KeptFiles("presets.unreadable-");
        string name = Assert.Single(kept);
        Assert.Matches(new Regex(@"^presets\.unreadable-\d{8}-\d{6}\.json$"), name);
        Assert.Equal(Garbage, File.ReadAllBytes(Path.Combine(_directory, name)));
        // Built-ins were written to a fresh presets.json; the next launch keeps nothing new.
        CompatFixtures.AssertPresetsEqual(presets, new PresetStore(_directory).Load());
        Assert.Single(KeptFiles("presets.unreadable-"));
    }

    [Fact]
    public void WrongShapePresetsFile_IsKept()
    {
        byte[] wrongShape = Encoding.UTF8.GetBytes("""{"presets": []}""");
        File.WriteAllBytes(PresetsPath, wrongShape);

        _ = new PresetStore(_directory).Load();

        var kept = KeptFiles("presets.unreadable-");
        Assert.Single(kept);
        Assert.Equal(wrongShape, File.ReadAllBytes(Path.Combine(_directory, kept[0])));
    }

    [Theory]
    [InlineData("null")]
    [InlineData("[null]")]
    public void NullPresetsFile_IsKept(string json)
    {
        File.WriteAllText(PresetsPath, json);

        var presets = new PresetStore(_directory).Load();

        Assert.NotEmpty(presets);
        Assert.All(presets, preset => Assert.NotNull(preset));
        var kept = KeptFiles("presets.unreadable-");
        Assert.Single(kept);
        Assert.Equal(json, File.ReadAllText(Path.Combine(_directory, kept[0])));
    }

    [Fact]
    public void UnreadableFile_TakenName_GetsNumberedSuffix()
    {
        // Occupy the kept names (plain and -2) for this second and the next few, so the
        // load below finds them taken whenever it runs.
        var now = DateTime.Now;
        var taken = new List<string>();
        for (int second = 0; second <= 5; second++)
        {
            string stamp = now.AddSeconds(second).ToString("yyyyMMdd-HHmmss", CultureInfo.InvariantCulture);
            foreach (string name in new[] { $"presets.unreadable-{stamp}.json", $"presets.unreadable-{stamp}-2.json" })
            {
                File.WriteAllText(Path.Combine(_directory, name), "taken");
                taken.Add(name);
            }
        }
        File.WriteAllBytes(PresetsPath, Garbage);

        _ = new PresetStore(_directory).Load();

        var added = KeptFiles("presets.unreadable-").Except(taken).ToList();
        string kept = Assert.Single(added);
        Assert.Matches(new Regex(@"^presets\.unreadable-\d{8}-\d{6}-3\.json$"), kept);
        Assert.Equal(Garbage, File.ReadAllBytes(Path.Combine(_directory, kept)));
        Assert.All(taken, name => Assert.Equal("taken", File.ReadAllText(Path.Combine(_directory, name))));
    }

    /// <summary>
    /// Keeps <paramref name="path"/> open with no sharing for the duration of
    /// <paramref name="body"/>, so reading it fails with an I/O error (the Windows counterpart
    /// of the Swift test's permission change).
    /// </summary>
    private static void WithoutReadAccess(string path, Action body)
    {
        using (new FileStream(path, FileMode.Open, FileAccess.ReadWrite, FileShare.None))
        {
            body();
        }
    }

    [Fact]
    public void InaccessiblePresetsFile_IsLeftInPlaceAndNotOverwritten()
    {
        List<Preset> saved = [new Preset("Receipts", CompatFixtures.NonDefaultSettings()) { Id = CompatFixtures.SampleId }];
        new PresetStore(_directory).Save(saved);
        byte[] original = File.ReadAllBytes(PresetsPath);

        WithoutReadAccess(PresetsPath, () =>
        {
            var presets = new PresetStore(_directory).Load();
            Assert.NotEmpty(presets);
            Assert.DoesNotContain(presets, preset => preset.Id == CompatFixtures.SampleId);
        });

        Assert.Empty(KeptFiles("presets.unreadable-"));
        Assert.Equal(original, File.ReadAllBytes(PresetsPath));
        // Writes stay refused for the session even once the file is readable again.
        new PresetStore(_directory).Save([]);
        Assert.Equal(original, File.ReadAllBytes(PresetsPath));
    }

    [Fact]
    public void InaccessibleSettingsFile_IsLeftInPlaceAndNotOverwritten()
    {
        SettingsStore.Save(CompatFixtures.NonDefaultSettings(), _directory);
        byte[] original = File.ReadAllBytes(SettingsPath);

        WithoutReadAccess(SettingsPath, () => Assert.Null(SettingsStore.Load(_directory)));

        Assert.Empty(KeptFiles("settings.unreadable-"));
        Assert.Equal(original, File.ReadAllBytes(SettingsPath));
        SettingsStore.Save(new ScanSettings(), _directory);
        CompatFixtures.AssertSettingsEqual(CompatFixtures.NonDefaultSettings(), SettingsStore.Load(_directory)!);
    }

    [Fact]
    public void UndecodableFileThatCannotBeMoved_IsNotOverwritten()
    {
        // Windows only: an open handle without delete sharing blocks the move aside (on
        // other systems a rename succeeds regardless).
        if (!OperatingSystem.IsWindows()) return;
        File.WriteAllBytes(PresetsPath, Garbage);

        using (new FileStream(PresetsPath, FileMode.Open, FileAccess.Read, FileShare.Read))
        {
            Assert.NotEmpty(new PresetStore(_directory).Load());
        }

        Assert.Empty(KeptFiles("presets.unreadable-"));
        Assert.Equal(Garbage, File.ReadAllBytes(PresetsPath));
        new PresetStore(_directory).Save([new Preset("Mine", new ScanSettings())]);
        Assert.Equal(Garbage, File.ReadAllBytes(PresetsPath));
    }

    [Fact]
    public void PresetsFileWithUnknownValues_LoadsInPlace()
    {
        File.WriteAllText(PresetsPath, CompatFixtures.CurrentFormatPresetsJson.Replace("\"tiff\"", "\"webp\""));

        var presets = new PresetStore(_directory).Load();

        Assert.Single(presets);
        Assert.Equal(CompatFixtures.SampleId, presets[0].Id);
        Assert.Equal(new ScanSettings().Format, presets[0].Settings.Format);
        Assert.Equal(600, presets[0].Settings.Resolution);
        Assert.Empty(KeptFiles("presets.unreadable-"));
    }

    [Fact]
    public void PresetsFileWithByteOrderMark_LoadsInPlace()
    {
        File.WriteAllBytes(PresetsPath,
            [0xEF, 0xBB, 0xBF, .. Encoding.UTF8.GetBytes(CompatFixtures.CurrentFormatPresetsJson)]);

        var presets = new PresetStore(_directory).Load();

        Assert.Equal(CompatFixtures.SampleId, Assert.Single(presets).Id);
        Assert.Empty(KeptFiles("presets.unreadable-"));
    }

    // Notepad's "UTF-16 LE" and Windows PowerShell 5.1's Out-File write UTF-16 with a
    // byte-order mark; Swift's JSONDecoder also reads UTF-32 and UTF-16 without one.
    [Theory]
    [InlineData("utf-16", true)]
    [InlineData("utf-16BE", true)]
    [InlineData("utf-32", true)]
    [InlineData("utf-32BE", true)]
    [InlineData("utf-16", false)]
    [InlineData("utf-16BE", false)]
    [InlineData("utf-32", false)]
    [InlineData("utf-32BE", false)]
    public void PresetsFileInUtf16OrUtf32_LoadsInPlace(string encodingName, bool withByteOrderMark)
    {
        var encoding = Encoding.GetEncoding(encodingName);
        byte[] text = encoding.GetBytes(CompatFixtures.CurrentFormatPresetsJson);
        File.WriteAllBytes(PresetsPath, withByteOrderMark ? [.. encoding.GetPreamble(), .. text] : text);

        var presets = new PresetStore(_directory).Load();

        Assert.Equal(CompatFixtures.SampleId, Assert.Single(presets).Id);
        Assert.Empty(KeptFiles("presets.unreadable-"));
    }

    [Fact]
    public void SettingsFileInUtf16_LoadsInPlace()
    {
        File.WriteAllText(SettingsPath, CompatFixtures.Encode(CompatFixtures.NonDefaultSettings()), Encoding.Unicode);

        CompatFixtures.AssertSettingsEqual(CompatFixtures.NonDefaultSettings(), SettingsStore.Load(_directory)!);
        Assert.Empty(KeptFiles("settings.unreadable-"));
    }

    [Fact]
    public void InvalidUtf16PresetsFile_IsKept()
    {
        // A byte-order mark followed by an unpaired high surrogate inside a string.
        byte[] damaged = [0xFF, 0xFE, .. Encoding.Unicode.GetBytes("[{\"name\": \""), 0x00, 0xD8,
                          .. Encoding.Unicode.GetBytes("\"}]")];
        File.WriteAllBytes(PresetsPath, damaged);

        var presets = new PresetStore(_directory).Load();

        Assert.NotEmpty(presets);
        var kept = Assert.Single(KeptFiles("presets.unreadable-"));
        Assert.Equal(damaged, File.ReadAllBytes(Path.Combine(_directory, kept)));
    }

    [Fact]
    public void PresetsSaveThenLoad_RoundTrips()
    {
        List<Preset> presets = [new Preset("Receipts", CompatFixtures.NonDefaultSettings()) { Id = CompatFixtures.SampleId }];
        new PresetStore(_directory).Save(presets);
        CompatFixtures.AssertPresetsEqual(presets, new PresetStore(_directory).Load());
    }

    [Fact]
    public void MissingSettingsFile_ReturnsNullWithoutKeepingAnything()
    {
        Assert.Null(SettingsStore.Load(_directory));
        Assert.Empty(KeptFiles("settings.unreadable-"));
    }

    [Fact]
    public void MissingFolder_CountsAsMissing()
    {
        string absent = Path.Combine(_directory, "absent");
        Assert.Null(SettingsStore.Load(absent));
        Assert.Equal(StoreReadStatus.Missing, StoreFiles.Read<ScanSettings>(StoreFiles.SettingsPath(absent)).Status);
        // Not protected: the first save creates the folder and the file.
        SettingsStore.Save(CompatFixtures.NonDefaultSettings(), absent);
        CompatFixtures.AssertSettingsEqual(CompatFixtures.NonDefaultSettings(), SettingsStore.Load(absent)!);
    }

    [Fact]
    public void UnreadableSettingsFile_IsKept()
    {
        byte[] garbage = [0xFF, 0x00, 0x7B];
        File.WriteAllBytes(SettingsPath, garbage);

        Assert.Null(SettingsStore.Load(_directory));

        var kept = KeptFiles("settings.unreadable-");
        Assert.Single(kept);
        Assert.Equal(garbage, File.ReadAllBytes(Path.Combine(_directory, kept[0])));
        Assert.False(File.Exists(SettingsPath));
    }

    [Fact]
    public void SettingsSaveThenLoad_RoundTrips()
    {
        SettingsStore.Save(CompatFixtures.NonDefaultSettings(), _directory);
        CompatFixtures.AssertSettingsEqual(CompatFixtures.NonDefaultSettings(), SettingsStore.Load(_directory)!);
    }

    // MARK: - App preferences (Windows only: the Mac app has no preferences file)

    [Fact]
    public void PreferencesSaveThenLoad_RoundTrips()
    {
        Assert.Equal(AppAppearance.System, AppPreferencesStore.Load(_directory).Appearance);
        AppPreferencesStore.Save(new AppPreferences { Appearance = AppAppearance.Dark }, _directory);
        Assert.Equal(AppAppearance.Dark, AppPreferencesStore.Load(_directory).Appearance);
        Assert.Empty(KeptFiles("preferences.unreadable-"));
    }

    [Fact]
    public void PreferencesUpdate_ChangesOnlyWhatItSets()
    {
        AppPreferencesStore.Save(new AppPreferences { Appearance = AppAppearance.Dark }, _directory);
        AppPreferencesStore.Update(p => p.PreferredConnection["id:abc"] = "escl:Network", _directory);
        AppPreferencesStore.Update(p => p.Appearance = AppAppearance.Light, _directory);

        var loaded = AppPreferencesStore.Load(_directory);
        Assert.Equal(AppAppearance.Light, loaded.Appearance);
        Assert.Equal("escl:Network", loaded.PreferredConnection["id:abc"]);
    }

    [Fact]
    public void UnreadablePreferencesFile_IsKeptAndDefaultsUsed()
    {
        File.WriteAllBytes(PreferencesPath, Garbage);

        Assert.Equal(AppAppearance.System, AppPreferencesStore.Load(_directory).Appearance);

        var kept = KeptFiles("preferences.unreadable-");
        Assert.Single(kept);
        Assert.Equal(Garbage, File.ReadAllBytes(Path.Combine(_directory, kept[0])));
        AppPreferencesStore.Save(new AppPreferences { Appearance = AppAppearance.Light }, _directory);
        Assert.Equal(AppAppearance.Light, AppPreferencesStore.Load(_directory).Appearance);
    }

    [Fact]
    public void InaccessiblePreferencesFile_IsLeftInPlaceAndNotOverwritten()
    {
        AppPreferencesStore.Save(new AppPreferences { Appearance = AppAppearance.Dark }, _directory);
        byte[] original = File.ReadAllBytes(PreferencesPath);

        WithoutReadAccess(PreferencesPath,
            () => Assert.Equal(AppAppearance.System, AppPreferencesStore.Load(_directory).Appearance));

        AppPreferencesStore.Save(new AppPreferences { Appearance = AppAppearance.Light }, _directory);
        Assert.Equal(original, File.ReadAllBytes(PreferencesPath));
        Assert.Empty(KeptFiles("preferences.unreadable-"));
    }
}
