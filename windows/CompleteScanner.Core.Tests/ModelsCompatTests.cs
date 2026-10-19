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
        settings.Output.PdfSize = PdfSizePreset.Compact;
        settings.Output.AfterSave = AfterSaveAction.Share;
        settings.Duplex = DuplexMode.Manual;
        settings.BackBinding = DuplexBinding.ShortEdge;
        settings.PaperSize = PaperSize.A4;
        settings.Document.RemoveBlankPages = true;
        settings.Document.BlankSensitivity = BlankSensitivity.High;
        settings.Document.AutoCrop = true;
        settings.Document.AutoStraighten = true;
        settings.TaskOptions.IdCardPaper = IdCardPaper.Letter;
        settings.TaskOptions.IdCardSaveSidesAsImages = true;
        return settings;
    }

    /// <summary>
    /// <see cref="NonDefaultSettings"/> as a presets file written by the serializer before
    /// tolerant decoding existed (indented, camelCase, every property present), and before the
    /// PDF size, the after-save action and two-sided scanning existed: it has no "output",
    /// "duplex", "backBinding" or "paperSize".
    /// </summary>
    public const string PresetsJsonBeforePdfSize = """
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

    /// <summary>
    /// <see cref="NonDefaultSettings"/> as this version writes it: <see cref="PresetsJsonBeforePdfSize"/>
    /// with the "output" object, then the sides, the paper size, the "document" object and the
    /// "taskOptions" object, after the earlier keys.
    /// </summary>
    public static readonly string CurrentFormatPresetsJson = PresetsJsonBeforePdfSize.ReplaceLineEndings("\n").Replace(
        "        \"blackWhiteThreshold\": 0.375\n      }\n",
        "        \"blackWhiteThreshold\": 0.375\n      },\n      \"output\": {\n        \"pdfSize\": \"compact\",\n        \"afterSave\": \"share\"\n      },\n"
        + "      \"duplex\": \"manual\",\n      \"backBinding\": \"shortEdge\",\n      \"paperSize\": \"a4\",\n"
        + "      \"document\": {\n        \"removeBlankPages\": true,\n        \"blankSensitivity\": \"high\",\n"
        + "        \"autoCrop\": true,\n        \"autoStraighten\": true\n      },\n"
        + "      \"taskOptions\": {\n        \"idCardPaper\": \"letter\",\n        \"idCardSaveSidesAsImages\": true\n      }\n");

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
            {"resolution": 200, "staple": "corner", "hologram": {"depth": 3}}
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
                "pdfSearchable", "ocrLanguages", "adjustments", "output", "duplex", "backBinding", "paperSize",
                "document", "taskOptions",
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

    // MARK: - Task (CONTRACTS.md, rule 6: the task is stored as text)

    [Fact]
    public void OldSettingsWithoutTask_LoadWithNoTask()
    {
        var presets = Decode<List<Preset>>(CompatFixtures.CurrentFormatPresetsJson);
        Assert.Null(presets[0].Settings.TaskId);
        Assert.Null(presets[0].Settings.Task);
        Assert.Null(Decode<ScanSettings>("{}").Task);
    }

    [Fact]
    public void UnknownTask_LoadsAsNoTask_AndIsWrittenBackUnchanged()
    {
        var settings = Decode<ScanSettings>("""{"resolution": 200, "taskId": "whiteboard"}""");
        Assert.Equal("whiteboard", settings.TaskId);
        Assert.Null(settings.Task);
        Assert.Equal(200, settings.Resolution);
        using var written = JsonDocument.Parse(CompatFixtures.Encode(settings));
        Assert.Equal("whiteboard", written.RootElement.GetProperty("taskId").GetString());
    }

    [Fact]
    public void KnownTask_RoundTrips()
    {
        var settings = CompatFixtures.NonDefaultSettings();
        settings.TaskId = "photoRestore";
        var back = Decode<ScanSettings>(CompatFixtures.Encode(settings));
        Assert.Equal(ScanTask.PhotoRestore, back.Task);
        CompatFixtures.AssertSettingsEqual(settings, back);
    }

    [Fact]
    public void WrongTypedOrNullTask_IsNoTask_RestIntact()
    {
        var number = Decode<ScanSettings>("""{"taskId": 5, "resolution": 150}""");
        Assert.Null(number.TaskId);
        Assert.Equal(150, number.Resolution);
        var obj = Decode<ScanSettings>("""{"taskId": {"id": "photos"}, "pdfSearchable": false}""");
        Assert.Null(obj.TaskId);
        Assert.False(obj.PdfSearchable);
        Assert.Null(Decode<ScanSettings>("""{"taskId": null}""").TaskId);
    }

    [Fact]
    public void NoTask_IsLeftOutOfTheFile()
    {
        Assert.DoesNotContain("taskId", CompatFixtures.Encode(new ScanSettings()));
        Assert.DoesNotContain("taskId", CompatFixtures.Encode(
            new List<Preset> { new("P", CompatFixtures.NonDefaultSettings()) { Id = CompatFixtures.SampleId } }));
    }

    [Fact]
    public void Task_IsWrittenAfterTheEarlierKeys()
    {
        var settings = CompatFixtures.NonDefaultSettings();
        settings.TaskId = "document";
        using var written = JsonDocument.Parse(CompatFixtures.Encode(settings));
        Assert.Equal(
            [
                "intent", "source", "resolution", "colorMode", "format", "jpegQuality",
                "destinationPath", "namingTemplate", "photoAutoSplit", "photoAutoDeskew",
                "photoMinSideInches", "photoCropInsetPixels", "documentMultiPage",
                "pdfSearchable", "ocrLanguages", "adjustments", "taskId", "output", "duplex", "backBinding", "paperSize",
                "document", "taskOptions",
            ],
            written.RootElement.EnumerateObject().Select(p => p.Name));
        Assert.Equal("document", written.RootElement.GetProperty("taskId").GetString());
    }

    // MARK: - PDF size (CONTRACTS.md, rule 6; Standard is the default for everyone)

    [Fact]
    public void PdfSize_StandardIsTheFirstMemberAndTheDefault()
    {
        Assert.Equal(["standard", "best", "compact", "smallest"],
                     Enum.GetValues<PdfSizePreset>().Select(p => JsonSerializer.Serialize(p, StoreFiles.JsonOptions).Trim('"')));
        Assert.Equal(PdfSizePreset.Standard, new ScanSettings().Output.PdfSize);
        Assert.Equal(PdfSizePreset.Standard, new OutputOptions().PdfSize);
    }

    [Fact]
    public void SettingsWithoutPdfSize_GetStandard_RestIntact()
    {
        var presets = Decode<List<Preset>>(CompatFixtures.PresetsJsonBeforePdfSize);
        var expected = CompatFixtures.NonDefaultSettings();
        expected.Output.PdfSize = PdfSizePreset.Standard;
        expected.Output.AfterSave = AfterSaveAction.None;
        expected.Duplex = DuplexMode.Off;
        expected.BackBinding = DuplexBinding.LongEdge;
        expected.PaperSize = PaperSize.Auto;
        expected.Document = new DocumentOptions();
        expected.TaskOptions = new TaskOptions();
        CompatFixtures.AssertSettingsEqual(expected, presets[0].Settings);
        Assert.Equal(PdfSizePreset.Standard, Decode<ScanSettings>("{}").Output.PdfSize);
        Assert.Equal(PdfSizePreset.Standard, Decode<ScanSettings>("""{"output": {}}""").Output.PdfSize);
    }

    [Fact]
    public void UnknownOrCorruptPdfSize_FallsBackToStandard_RestIntact()
    {
        foreach (string output in new[] { """{"pdfSize": "tiny"}""", """{"pdfSize": "Compact"}""", """{"pdfSize": 2}""",
                                          """{"pdfSize": null}""", "\"compact\"", "null", "[]" })
        {
            var settings = Decode<ScanSettings>($$"""{"resolution": 150, "output": {{output}}, "pdfSearchable": false}""");
            Assert.Equal(PdfSizePreset.Standard, settings.Output.PdfSize);
            Assert.Equal(150, settings.Resolution);
            Assert.False(settings.PdfSearchable);
        }
        var nested = Decode<ScanSettings>("""{"output": {"pdfSize": "smallest", "afterSave": "share"}}""");
        Assert.Equal(PdfSizePreset.Smallest, nested.Output.PdfSize);
        Assert.Equal(AfterSaveAction.Share, nested.Output.AfterSave);
    }

    [Fact]
    public void PdfSize_IsWrittenUnderOutput_AndRoundTrips()
    {
        foreach (var size in Enum.GetValues<PdfSizePreset>())
        {
            var settings = new ScanSettings();
            settings.Output.PdfSize = size;
            string json = CompatFixtures.Encode(settings);
            using var written = JsonDocument.Parse(json);
            Assert.Equal(["pdfSize", "afterSave"], written.RootElement.GetProperty("output").EnumerateObject().Select(p => p.Name));
            Assert.Equal(size, Decode<ScanSettings>(json).Output.PdfSize);
        }
    }

    [Fact]
    public void Clone_CopiesTheOutputOptions()
    {
        var settings = new ScanSettings();
        settings.Output.PdfSize = PdfSizePreset.Smallest;
        var clone = settings.Clone();
        Assert.Equal(PdfSizePreset.Smallest, clone.Output.PdfSize);
        Assert.NotSame(settings.Output, clone.Output);
        clone.Output.PdfSize = PdfSizePreset.Best;
        Assert.Equal(PdfSizePreset.Smallest, settings.Output.PdfSize);
    }

    // MARK: - Two-sided scanning and paper size (CONTRACTS.md, rule 6)

    [Fact]
    public void Sides_FirstMembersAreTheDefaults()
    {
        static string Name<T>(T value) => JsonSerializer.Serialize(value, StoreFiles.JsonOptions).Trim('"');
        Assert.Equal(["off", "both", "manual"], Enum.GetValues<DuplexMode>().Select(Name));
        Assert.Equal(["longEdge", "shortEdge"], Enum.GetValues<DuplexBinding>().Select(Name));
        Assert.Equal(["auto", "letter", "legal", "executive", "a4", "a5", "a6", "b5Jis", "idCard"],
                     Enum.GetValues<PaperSize>().Select(Name));
        var settings = new ScanSettings();
        Assert.Equal((DuplexMode.Off, DuplexBinding.LongEdge, PaperSize.Auto),
                     (settings.Duplex, settings.BackBinding, settings.PaperSize));
    }

    [Fact]
    public void SettingsWithoutSides_ScanOneSideOnTheWholeArea()
    {
        var settings = Decode<ScanSettings>("""{"resolution": 150, "source": "documentFeeder"}""");
        Assert.Equal((DuplexMode.Off, DuplexBinding.LongEdge, PaperSize.Auto, 150),
                     (settings.Duplex, settings.BackBinding, settings.PaperSize, settings.Resolution));
    }

    [Fact]
    public void UnknownOrCorruptSides_FallBackToTheDefaults_RestIntact()
    {
        foreach (string sides in new[]
                 {
                     """ "duplex": "triple", "backBinding": "spiral", "paperSize": "tabloid" """,
                     """ "duplex": "Both", "backBinding": "LongEdge", "paperSize": "A4" """,
                     """ "duplex": 1, "backBinding": true, "paperSize": {"width": 8} """,
                     """ "duplex": null, "backBinding": null, "paperSize": null """,
                 })
        {
            var settings = Decode<ScanSettings>($$"""{"resolution": 150, {{sides}}, "pdfSearchable": false}""");
            Assert.Equal((DuplexMode.Off, DuplexBinding.LongEdge, PaperSize.Auto),
                         (settings.Duplex, settings.BackBinding, settings.PaperSize));
            Assert.Equal(150, settings.Resolution);
            Assert.False(settings.PdfSearchable);
        }
        var known = Decode<ScanSettings>("""{"duplex": "both", "backBinding": "shortEdge", "paperSize": "b5Jis"}""");
        Assert.Equal((DuplexMode.Both, DuplexBinding.ShortEdge, PaperSize.B5Jis), (known.Duplex, known.BackBinding, known.PaperSize));
    }

    [Fact]
    public void Sides_RoundTrip()
    {
        foreach (var duplex in Enum.GetValues<DuplexMode>())
        {
            foreach (var paper in Enum.GetValues<PaperSize>())
            {
                var settings = new ScanSettings { Duplex = duplex, BackBinding = DuplexBinding.ShortEdge, PaperSize = paper };
                var back = Decode<ScanSettings>(CompatFixtures.Encode(settings));
                Assert.Equal((duplex, DuplexBinding.ShortEdge, paper), (back.Duplex, back.BackBinding, back.PaperSize));
            }
        }
        var clone = CompatFixtures.NonDefaultSettings().Clone();
        Assert.Equal((DuplexMode.Manual, DuplexBinding.ShortEdge, PaperSize.A4), (clone.Duplex, clone.BackBinding, clone.PaperSize));
    }

    // MARK: - Blank pages (CONTRACTS.md, rule 6)

    [Fact]
    public void BlankSensitivity_MediumIsTheFirstMemberAndTheDefault()
    {
        static string Name<T>(T value) => JsonSerializer.Serialize(value, StoreFiles.JsonOptions).Trim('"');
        Assert.Equal(["medium", "low", "high"], Enum.GetValues<BlankSensitivity>().Select(Name));
        var document = new ScanSettings().Document;
        Assert.Equal((false, BlankSensitivity.Medium), (document.RemoveBlankPages, document.BlankSensitivity));
        Assert.Equal([BlankSensitivity.Low, BlankSensitivity.Medium, BlankSensitivity.High], BlankSensitivities.DisplayOrder);
    }

    [Fact]
    public void SettingsWithoutDocument_KeepEveryPage_RestIntact()
    {
        var presets = Decode<List<Preset>>(CompatFixtures.PresetsJsonBeforePdfSize);
        Assert.False(presets[0].Settings.Document.RemoveBlankPages);
        Assert.Equal(BlankSensitivity.Medium, presets[0].Settings.Document.BlankSensitivity);
        Assert.False(Decode<ScanSettings>("""{"document": {}}""").Document.RemoveBlankPages);
        Assert.Equal(600, presets[0].Settings.Resolution);
        Assert.Equal(PdfSizePreset.Standard, presets[0].Settings.Output.PdfSize);
    }

    [Fact]
    public void UnknownOrCorruptDocument_FallsBackToTheDefaults_RestIntact()
    {
        foreach (string document in new[]
                 {
                     """ "document": {"removeBlankPages": true, "blankSensitivity": "extreme"} """,
                     """ "document": {"removeBlankPages": true, "blankSensitivity": "High"} """,
                     """ "document": {"removeBlankPages": true, "blankSensitivity": 2} """,
                     """ "document": {"removeBlankPages": true, "blankSensitivity": null} """,
                 })
        {
            var settings = Decode<ScanSettings>($$"""{"resolution": 150, {{document}}, "pdfSearchable": false}""");
            Assert.True(settings.Document.RemoveBlankPages);
            Assert.Equal(BlankSensitivity.Medium, settings.Document.BlankSensitivity);
            Assert.Equal(150, settings.Resolution);
            Assert.False(settings.PdfSearchable);
        }
        foreach (string document in new[]
                 {
                     """ "document": "skip blanks" """,
                     """ "document": null """,
                     """ "document": {"removeBlankPages": "yes", "blankSensitivity": "low"} """,
                 })
        {
            var settings = Decode<ScanSettings>($$"""{"resolution": 150, {{document}}, "pdfSearchable": false}""");
            Assert.False(settings.Document.RemoveBlankPages);
            Assert.Equal(150, settings.Resolution);
            Assert.False(settings.PdfSearchable);
        }
        Assert.Equal(BlankSensitivity.Low,
                     Decode<ScanSettings>("""{"document": {"removeBlankPages": "yes", "blankSensitivity": "low"}}""").Document.BlankSensitivity);
    }

    [Fact]
    public void Document_RoundTrips_AndCloneIsIndependent()
    {
        foreach (var sensitivity in Enum.GetValues<BlankSensitivity>())
        {
            foreach (bool remove in new[] { false, true })
            {
                var settings = new ScanSettings();
                settings.Document.RemoveBlankPages = remove;
                settings.Document.BlankSensitivity = sensitivity;
                var back = Decode<ScanSettings>(CompatFixtures.Encode(settings));
                Assert.Equal((remove, sensitivity), (back.Document.RemoveBlankPages, back.Document.BlankSensitivity));
                Assert.Equal(settings.Document, back.Document);
            }
        }
        var original = CompatFixtures.NonDefaultSettings();
        var clone = original.Clone();
        Assert.NotSame(original.Document, clone.Document);
        Assert.Equal(original.Document, clone.Document);
        clone.Document.RemoveBlankPages = false;
        clone.Document.BlankSensitivity = BlankSensitivity.Low;
        Assert.True(original.Document.RemoveBlankPages);
        Assert.Equal(BlankSensitivity.High, original.Document.BlankSensitivity);
    }

    // MARK: - Crop and straighten (CONTRACTS.md, rule 6)

    [Fact]
    public void CropAndStraighten_AreOffByDefault_AndInFilesWithoutThem()
    {
        var document = new ScanSettings().Document;
        Assert.Equal((false, false), (document.AutoCrop, document.AutoStraighten));
        var presets = Decode<List<Preset>>(CompatFixtures.PresetsJsonBeforePdfSize);
        Assert.Equal((false, false), (presets[0].Settings.Document.AutoCrop, presets[0].Settings.Document.AutoStraighten));
        // A "document" object written before crop and straighten existed keeps its blank-page settings.
        var older = Decode<ScanSettings>("""{"document": {"removeBlankPages": true, "blankSensitivity": "low"}}""");
        Assert.Equal((true, BlankSensitivity.Low, false, false),
                     (older.Document.RemoveBlankPages, older.Document.BlankSensitivity, older.Document.AutoCrop, older.Document.AutoStraighten));
    }

    [Fact]
    public void CorruptCropOrStraighten_FallsBackToOff_RestIntact()
    {
        var settings = Decode<ScanSettings>("""{"resolution": 150, "document": {"removeBlankPages": true, "autoCrop": "yes", "autoStraighten": 1}, "pdfSearchable": false}""");
        Assert.Equal((false, false), (settings.Document.AutoCrop, settings.Document.AutoStraighten));
        Assert.True(settings.Document.RemoveBlankPages);
        Assert.Equal(150, settings.Resolution);
        Assert.False(settings.PdfSearchable);
        var straighten = Decode<ScanSettings>("""{"document": {"autoCrop": null, "autoStraighten": true}}""");
        Assert.Equal((false, true), (straighten.Document.AutoCrop, straighten.Document.AutoStraighten));
    }

    [Fact]
    public void CropAndStraighten_RoundTrip_AndCloneIsIndependent()
    {
        foreach (bool crop in new[] { false, true })
        {
            foreach (bool straighten in new[] { false, true })
            {
                var settings = new ScanSettings();
                settings.Document.AutoCrop = crop;
                settings.Document.AutoStraighten = straighten;
                var back = Decode<ScanSettings>(CompatFixtures.Encode(settings));
                Assert.Equal((crop, straighten), (back.Document.AutoCrop, back.Document.AutoStraighten));
                Assert.Equal(settings.Document, back.Document);
            }
        }
        var original = CompatFixtures.NonDefaultSettings();
        var clone = original.Clone();
        clone.Document.AutoCrop = false;
        clone.Document.AutoStraighten = false;
        Assert.True(original.Document.AutoCrop);
        Assert.True(original.Document.AutoStraighten);
        Assert.NotEqual(original.Document, clone.Document);
    }

    // MARK: - Task options (CONTRACTS.md, rule 6)

    [Fact]
    public void TaskOptions_AutomaticPaperAndNoSideImagesByDefault_AndInFilesWithoutThem()
    {
        static string Name<T>(T value) => JsonSerializer.Serialize(value, StoreFiles.JsonOptions).Trim('"');
        Assert.Equal(["auto", "a4", "letter"], Enum.GetValues<IdCardPaper>().Select(Name));
        var options = new ScanSettings().TaskOptions;
        Assert.Equal((IdCardPaper.Auto, false), (options.IdCardPaper, options.IdCardSaveSidesAsImages));
        var presets = Decode<List<Preset>>(CompatFixtures.PresetsJsonBeforePdfSize);
        Assert.Equal(new TaskOptions(), presets[0].Settings.TaskOptions);
        Assert.Equal(new TaskOptions(), Decode<ScanSettings>("""{"taskOptions": {}}""").TaskOptions);
    }

    [Fact]
    public void UnknownOrCorruptTaskOptions_FallBackToTheDefaults_RestIntact()
    {
        foreach (string taskOptions in new[]
                 {
                     """ "taskOptions": {"idCardPaper": "tabloid", "idCardSaveSidesAsImages": true} """,
                     """ "taskOptions": {"idCardPaper": "A4", "idCardSaveSidesAsImages": true} """,
                     """ "taskOptions": {"idCardPaper": 1, "idCardSaveSidesAsImages": true} """,
                     """ "taskOptions": {"idCardPaper": null, "idCardSaveSidesAsImages": true} """,
                 })
        {
            var settings = Decode<ScanSettings>($$"""{"resolution": 150, {{taskOptions}}, "pdfSearchable": false}""");
            Assert.Equal((IdCardPaper.Auto, true), (settings.TaskOptions.IdCardPaper, settings.TaskOptions.IdCardSaveSidesAsImages));
            Assert.Equal(150, settings.Resolution);
            Assert.False(settings.PdfSearchable);
        }
        foreach (string taskOptions in new[]
                 {
                     """ "taskOptions": "id card" """,
                     """ "taskOptions": null """,
                     """ "taskOptions": [] """,
                     """ "taskOptions": {"idCardPaper": "a4", "idCardSaveSidesAsImages": "yes"} """,
                 })
        {
            var settings = Decode<ScanSettings>($$"""{"resolution": 150, {{taskOptions}}, "pdfSearchable": false}""");
            Assert.False(settings.TaskOptions.IdCardSaveSidesAsImages);
            Assert.Equal(150, settings.Resolution);
            Assert.False(settings.PdfSearchable);
        }
        Assert.Equal(IdCardPaper.A4,
                     Decode<ScanSettings>("""{"taskOptions": {"idCardPaper": "a4", "idCardSaveSidesAsImages": "yes"}}""").TaskOptions.IdCardPaper);
    }

    [Fact]
    public void TaskOptions_RoundTrip_AndCloneIsIndependent()
    {
        foreach (var paper in Enum.GetValues<IdCardPaper>())
        {
            foreach (bool sides in new[] { false, true })
            {
                var settings = new ScanSettings();
                settings.TaskOptions.IdCardPaper = paper;
                settings.TaskOptions.IdCardSaveSidesAsImages = sides;
                string json = CompatFixtures.Encode(settings);
                using var written = JsonDocument.Parse(json);
                Assert.Equal(["idCardPaper", "idCardSaveSidesAsImages"],
                             written.RootElement.GetProperty("taskOptions").EnumerateObject().Select(p => p.Name));
                Assert.Equal(settings.TaskOptions, Decode<ScanSettings>(json).TaskOptions);
            }
        }
        var original = CompatFixtures.NonDefaultSettings();
        var clone = original.Clone();
        Assert.NotSame(original.TaskOptions, clone.TaskOptions);
        Assert.Equal(original.TaskOptions, clone.TaskOptions);
        clone.TaskOptions.IdCardPaper = IdCardPaper.A4;
        clone.TaskOptions.IdCardSaveSidesAsImages = false;
        Assert.Equal((IdCardPaper.Letter, true), (original.TaskOptions.IdCardPaper, original.TaskOptions.IdCardSaveSidesAsImages));
    }

    [Fact]
    public void Clone_CopiesTheTask()
    {
        var settings = new ScanSettings { TaskId = "feeder" };
        var clone = settings.Clone();
        Assert.Equal(ScanTask.Feeder, clone.Task);
        clone.TaskId = null;
        Assert.Equal("feeder", settings.TaskId);
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

    [Fact]
    public void TwainDriverWindow_MissingOrCorrupt_IsEmptyAndRoundTrips()
    {
        Assert.Empty(Decode<AppPreferences>("""{ "appearance": "dark" }""").TwainDriverWindow);
        var corrupt = Decode<AppPreferences>("""{ "appearance": "dark", "twainDriverWindow": { "a": 1 } }""");
        Assert.Empty(corrupt.TwainDriverWindow);
        Assert.Equal(AppAppearance.Dark, corrupt.Appearance);

        var preferences = new AppPreferences { TwainDriverWindow = ["twain:EPSON Perfection V600"] };
        string json = CompatFixtures.Encode(preferences);
        Assert.Contains("\"twainDriverWindow\"", json);
        Assert.Equal(["twain:EPSON Perfection V600"], Decode<AppPreferences>(json).TwainDriverWindow);
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
    public void MissingPresetsFile_StartsEmptyWithoutKeepingAnything()
    {
        var presets = new PresetStore(_directory).Load();

        // New installs get no starter presets: the start screen's task cards replace them.
        Assert.Empty(presets);
        Assert.True(File.Exists(PresetsPath));
        Assert.Empty(KeptFiles("presets.unreadable-"));
        // The written file is what the next launch reads.
        Assert.Empty(new PresetStore(_directory).Load());
    }

    [Fact]
    public void StarterPresetsOfEarlierVersions_StayAndKeepWorking()
    {
        // A presets.json as earlier versions seeded it (two of the five starters).
        File.WriteAllText(PresetsPath, """
            [
              {
                "id": "7b0f4c84-3c55-4f56-9d0f-0b4b5f1d2a01",
                "name": "Document → PDF (300 dpi)",
                "settings": { "intent": "document", "resolution": 300, "colorMode": "color", "format": "pdf",
                              "pdfSearchable": true, "documentMultiPage": true }
              },
              {
                "id": "7b0f4c84-3c55-4f56-9d0f-0b4b5f1d2a02",
                "name": "Old photo restoration (600 dpi, PNG)",
                "settings": { "intent": "photo", "resolution": 600, "colorMode": "color", "format": "png",
                              "adjustments": { "restoreFadedColors": true, "autoEnhance": true } }
              }
            ]
            """);

        var presets = new PresetStore(_directory).Load();

        Assert.Equal(["Document → PDF (300 dpi)", "Old photo restoration (600 dpi, PNG)"], presets.Select(p => p.Name));
        Assert.Equal([ScanTask.Document, ScanTask.PhotoRestore], presets.Select(p => TaskCatalog.Infer(p.Settings)));
        Assert.All(presets, p => Assert.Null(p.Settings.TaskId));
        Assert.Empty(KeptFiles("presets.unreadable-"));
    }

    [Fact]
    public void UnreadablePresetsFile_IsKeptBeforeSeeding()
    {
        File.WriteAllBytes(PresetsPath, Garbage);

        var presets = new PresetStore(_directory).Load();

        Assert.Empty(presets);
        var kept = KeptFiles("presets.unreadable-");
        string name = Assert.Single(kept);
        Assert.Matches(new Regex(@"^presets\.unreadable-\d{8}-\d{6}\.json$"), name);
        Assert.Equal(Garbage, File.ReadAllBytes(Path.Combine(_directory, name)));
        // An empty list was written to a fresh presets.json; the next launch keeps nothing new.
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

        Assert.Empty(presets);
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
            Assert.Empty(new PresetStore(_directory).Load());
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
            Assert.Empty(new PresetStore(_directory).Load());
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

        Assert.Empty(presets);
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
