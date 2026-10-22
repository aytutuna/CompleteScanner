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
        settings.Output.AlsoSaveText = true;
        settings.Output.Archival = true;
        settings.Output.Protect = true;
        settings.Output.WordPageImages = false;
        settings.Duplex = DuplexMode.Manual;
        settings.BackBinding = DuplexBinding.ShortEdge;
        settings.PaperSize = PaperSize.A4;
        settings.Document.RemoveBlankPages = true;
        settings.Document.BlankSensitivity = BlankSensitivity.High;
        settings.Document.AutoCrop = true;
        settings.Document.AutoStraighten = true;
        settings.Document.SplitMode = SplitMode.SheetCount;
        settings.Document.SplitSheetCount = 3;
        settings.Document.AutoRotate = true;
        settings.Document.SplitFacingPages = true;
        settings.Document.SoftenSpineShadow = true;
        settings.Document.BarcodeStartsDocument = true;
        settings.Document.SplitBarcodePrefix = "DOC";
        settings.TaskOptions.IdCardPaper = IdCardPaper.Letter;
        settings.TaskOptions.IdCardSaveSidesAsImages = true;
        settings.TaskOptions.CopyCount = 3;
        settings.TaskOptions.CopyFitToPage = true;
        settings.TaskOptions.CopyPrinterName = "Office printer";
        settings.TaskOptions.CopyAlsoSavePdf = true;
        settings.TaskOptions.ReceiptNameByDate = false;
        settings.TaskOptions.ReceiptCombine = true;
        settings.TaskOptions.BookRightToLeft = true;
        settings.TaskOptions.BookRotationQuarterTurns = 1;
        settings.TaskOptions.CameraFrontsFirst = true;
        settings.TaskOptions.CameraSpreads = true;
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
        "        \"blackWhiteThreshold\": 0.375\n      },\n      \"output\": {\n        \"pdfSize\": \"compact\",\n        \"afterSave\": \"share\",\n"
        + "        \"alsoSaveText\": true,\n        \"archival\": true,\n        \"protect\": true,\n        \"wordPageImages\": false\n      },\n"
        + "      \"duplex\": \"manual\",\n      \"backBinding\": \"shortEdge\",\n      \"paperSize\": \"a4\",\n"
        + "      \"document\": {\n        \"removeBlankPages\": true,\n        \"blankSensitivity\": \"high\",\n"
        + "        \"autoCrop\": true,\n        \"autoStraighten\": true,\n        \"splitMode\": \"sheetCount\",\n"
        + "        \"splitSheetCount\": 3,\n        \"autoRotate\": true,\n        \"splitFacingPages\": true,\n"
        + "        \"softenSpineShadow\": true,\n        \"barcodeStartsDocument\": true,\n        \"splitBarcodePrefix\": \"DOC\"\n      },\n"
        + "      \"taskOptions\": {\n        \"idCardPaper\": \"letter\",\n        \"idCardSaveSidesAsImages\": true,\n"
        + "        \"copyCount\": 3,\n        \"copyFitToPage\": true,\n        \"copyPrinterName\": \"Office printer\",\n"
        + "        \"copyAlsoSavePdf\": true,\n        \"receiptNameByDate\": false,\n        \"receiptCombine\": true,\n"
        + "        \"bookRightToLeft\": true,\n        \"bookRotationQuarterTurns\": 1,\n"
        + "        \"cameraFrontsFirst\": true,\n        \"cameraSpreads\": true\n      }\n");

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
        expected.Output.AlsoSaveText = false;
        expected.Output.Archival = false;
        expected.Output.Protect = false;
        expected.Output.WordPageImages = true;
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
            Assert.Equal(["pdfSize", "afterSave", "alsoSaveText", "archival", "protect", "wordPageImages"], written.RootElement.GetProperty("output").EnumerateObject().Select(p => p.Name));
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

    // MARK: - Text output (CONTRACTS.md, rule 6)

    [Fact]
    public void Formats_NewMembersComeLast_WithTheirStoredNames()
    {
        Assert.Equal(["pdf", "jpeg", "png", "tiff", "text", "word"],
                     Enum.GetValues<OutputFormat>().Select(f => JsonSerializer.Serialize(f, StoreFiles.JsonOptions).Trim('"')));
        Assert.Equal(OutputFormat.Word, Decode<ScanSettings>("""{"format": "word"}""").Format);
        Assert.Equal(OutputFormat.Text, Decode<ScanSettings>("""{"format": "text"}""").Format);
        // A format of a newer version is read as PDF.
        Assert.Equal(OutputFormat.Pdf, Decode<ScanSettings>("""{"format": "markdown", "resolution": 150}""").Format);
    }

    [Fact]
    public void AlsoSaveText_OffByDefault_AndInFilesWithoutIt()
    {
        Assert.False(new ScanSettings().Output.AlsoSaveText);
        Assert.False(Decode<List<Preset>>(CompatFixtures.PresetsJsonBeforePdfSize)[0].Settings.Output.AlsoSaveText);
        Assert.False(Decode<ScanSettings>("""{"output": {"pdfSize": "compact", "afterSave": "share"}}""").Output.AlsoSaveText);
        foreach (string value in new[] { "\"yes\"", "1", "null", "{}" })
        {
            var settings = Decode<ScanSettings>($$"""{"output": {"pdfSize": "best", "alsoSaveText": {{value}}}, "resolution": 150}""");
            Assert.False(settings.Output.AlsoSaveText);
            Assert.Equal(PdfSizePreset.Best, settings.Output.PdfSize);
            Assert.Equal(150, settings.Resolution);
        }
        Assert.True(Decode<ScanSettings>("""{"output": {"alsoSaveText": true}}""").Output.AlsoSaveText);
    }

    [Fact]
    public void Clone_CopiesAlsoSaveText()
    {
        var settings = new ScanSettings();
        settings.Output.AlsoSaveText = true;
        var clone = settings.Clone();
        Assert.True(clone.Output.AlsoSaveText);
        clone.Output.AlsoSaveText = false;
        Assert.True(settings.Output.AlsoSaveText);
        Assert.NotEqual(settings.Output, clone.Output);
    }

    // MARK: - Archival PDF (CONTRACTS.md, rule 6)

    [Fact]
    public void Archival_OffByDefault_AndInFilesWithoutIt()
    {
        Assert.False(new ScanSettings().Output.Archival);
        Assert.False(Decode<List<Preset>>(CompatFixtures.PresetsJsonBeforePdfSize)[0].Settings.Output.Archival);
        Assert.False(Decode<ScanSettings>("""{"output": {"pdfSize": "compact", "alsoSaveText": true}}""").Output.Archival);
        foreach (string value in new[] { "\"yes\"", "1", "null", "{}", "[]" })
        {
            var settings = Decode<ScanSettings>($$"""{"output": {"pdfSize": "best", "archival": {{value}}, "alsoSaveText": true}, "resolution": 150}""");
            Assert.False(settings.Output.Archival);
            Assert.Equal(PdfSizePreset.Best, settings.Output.PdfSize);
            Assert.True(settings.Output.AlsoSaveText);
            Assert.Equal(150, settings.Resolution);
        }
        Assert.True(Decode<ScanSettings>("""{"output": {"archival": true}}""").Output.Archival);
    }

    [Fact]
    public void Clone_CopiesArchival()
    {
        var settings = new ScanSettings();
        settings.Output.Archival = true;
        var clone = settings.Clone();
        Assert.True(clone.Output.Archival);
        clone.Output.Archival = false;
        Assert.True(settings.Output.Archival);
        Assert.NotEqual(settings.Output, clone.Output);
    }

    [Fact]
    public void ArchiveTaskSettings_RoundTrip_AsTheMacReadsThem()
    {
        // What the Archive document task writes: both platforms read it as that task with the
        // archival flag on, and write it back unchanged.
        const string json = """{"resolution": 300, "taskId": "archive", "output": {"pdfSize": "best", "archival": true}}""";
        var settings = Decode<ScanSettings>(json);
        Assert.Equal(ScanTask.Archive, settings.Task);
        Assert.True(settings.Output.Archival);
        Assert.Equal(PdfSizePreset.Best, settings.Output.PdfSize);
        using var written = JsonDocument.Parse(CompatFixtures.Encode(settings));
        Assert.Equal("archive", written.RootElement.GetProperty("taskId").GetString());
        Assert.True(written.RootElement.GetProperty("output").GetProperty("archival").GetBoolean());
    }

    // MARK: - Page pictures in Word documents (CONTRACTS.md, rule 6)

    [Fact]
    public void WordPageImages_OnByDefault_AndInFilesWithoutIt()
    {
        Assert.True(new ScanSettings().Output.WordPageImages);
        Assert.True(Decode<List<Preset>>(CompatFixtures.PresetsJsonBeforePdfSize)[0].Settings.Output.WordPageImages);
        Assert.True(Decode<ScanSettings>("""{"output": {"pdfSize": "compact", "alsoSaveText": true}}""").Output.WordPageImages);
        foreach (string value in new[] { "\"no\"", "0", "null", "{}", "[]" })
        {
            var settings = Decode<ScanSettings>($$"""{"output": {"pdfSize": "best", "wordPageImages": {{value}}, "alsoSaveText": true}, "resolution": 150}""");
            Assert.True(settings.Output.WordPageImages);
            Assert.Equal(PdfSizePreset.Best, settings.Output.PdfSize);
            Assert.True(settings.Output.AlsoSaveText);
            Assert.Equal(150, settings.Resolution);
        }
        Assert.False(Decode<ScanSettings>("""{"output": {"wordPageImages": false}}""").Output.WordPageImages);
    }

    [Fact]
    public void Clone_CopiesWordPageImages()
    {
        var settings = new ScanSettings();
        settings.Output.WordPageImages = false;
        var clone = settings.Clone();
        Assert.False(clone.Output.WordPageImages);
        clone.Output.WordPageImages = true;
        Assert.False(settings.Output.WordPageImages);
        Assert.NotEqual(settings.Output, clone.Output);
    }

    // MARK: - Password-protected PDFs (CONTRACTS.md, rule 6)

    [Fact]
    public void Protect_OffByDefault_AndInFilesWithoutIt()
    {
        Assert.False(new ScanSettings().Output.Protect);
        Assert.False(Decode<List<Preset>>(CompatFixtures.PresetsJsonBeforePdfSize)[0].Settings.Output.Protect);
        Assert.False(Decode<ScanSettings>("""{"output": {"pdfSize": "compact", "archival": true}}""").Output.Protect);
        foreach (string value in new[] { "\"yes\"", "1", "null", "{}", "[]" })
        {
            var settings = Decode<ScanSettings>($$"""{"output": {"pdfSize": "best", "protect": {{value}}, "alsoSaveText": true}, "resolution": 150}""");
            Assert.False(settings.Output.Protect);
            Assert.Equal(PdfSizePreset.Best, settings.Output.PdfSize);
            Assert.True(settings.Output.AlsoSaveText);
            Assert.Equal(150, settings.Resolution);
        }
        Assert.True(Decode<ScanSettings>("""{"output": {"protect": true}}""").Output.Protect);
    }

    [Fact]
    public void Clone_CopiesProtect()
    {
        var settings = new ScanSettings();
        settings.Output.Protect = true;
        var clone = settings.Clone();
        Assert.True(clone.Output.Protect);
        clone.Output.Protect = false;
        Assert.True(settings.Output.Protect);
        Assert.NotEqual(settings.Output, clone.Output);
    }

    [Fact]
    public void ProtectSettings_KeepOnlyTheSwitch()
    {
        // Only "protect" is written: a settings file never holds a password, whatever it was read from.
        const string json = """{"output": {"pdfSize": "standard", "protect": true, "password": "Şifre 2026"}}""";
        var settings = Decode<ScanSettings>(json);
        Assert.True(settings.Output.Protect);
        string written = CompatFixtures.Encode(settings);
        Assert.DoesNotContain("password", written, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("Şifre", written, StringComparison.Ordinal);
        using var document = JsonDocument.Parse(written);
        Assert.True(document.RootElement.GetProperty("output").GetProperty("protect").GetBoolean());
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

    // MARK: - Splitting into documents (CONTRACTS.md, rule 6)

    [Fact]
    public void Split_IsOffByDefault_AndInFilesWithoutIt()
    {
        var document = new ScanSettings().Document;
        Assert.Equal((SplitMode.None, 1), (document.SplitMode, document.SplitSheetCount));
        var presets = Decode<List<Preset>>(CompatFixtures.PresetsJsonBeforePdfSize);
        Assert.Equal((SplitMode.None, 1), (presets[0].Settings.Document.SplitMode, presets[0].Settings.Document.SplitSheetCount));
        // A "document" object written before splitting existed keeps its other settings.
        var older = Decode<ScanSettings>("""{"document": {"removeBlankPages": true, "blankSensitivity": "low", "autoStraighten": true}}""");
        Assert.Equal((true, BlankSensitivity.Low, true, SplitMode.None, 1),
                     (older.Document.RemoveBlankPages, older.Document.BlankSensitivity, older.Document.AutoStraighten,
                      older.Document.SplitMode, older.Document.SplitSheetCount));
    }

    [Fact]
    public void UnknownOrCorruptSplit_FallsBackToOff_RestIntact()
    {
        // A mode of a newer version, a wrong case, a number, a null: off; a corrupt count: 1.
        foreach (string document in new[]
                 {
                     """ "document": {"removeBlankPages": true, "splitMode": "everyPage", "splitSheetCount": 4} """,
                     """ "document": {"removeBlankPages": true, "splitMode": "Barcode", "splitSheetCount": 4} """,
                     """ "document": {"removeBlankPages": true, "splitMode": "SeparatorSheet", "splitSheetCount": 4} """,
                     """ "document": {"removeBlankPages": true, "splitMode": 1, "splitSheetCount": 4} """,
                     """ "document": {"removeBlankPages": true, "splitMode": null, "splitSheetCount": 4} """,
                 })
        {
            var settings = Decode<ScanSettings>("{\"resolution\": 150, " + document + ", \"pdfSearchable\": false}");
            Assert.Equal((SplitMode.None, 4, true), (settings.Document.SplitMode, settings.Document.SplitSheetCount, settings.Document.RemoveBlankPages));
            Assert.Equal(150, settings.Resolution);
            Assert.False(settings.PdfSearchable);
        }
        var count = Decode<ScanSettings>("""{"document": {"splitMode": "blankSheet", "splitSheetCount": "three"}}""");
        Assert.Equal((SplitMode.BlankSheet, 1), (count.Document.SplitMode, count.Document.SplitSheetCount));
    }

    [Fact]
    public void Split_RoundTrips_AndCloneIsIndependent()
    {
        foreach (var mode in SplitModes.DisplayOrder)
        {
            var settings = new ScanSettings();
            settings.Document.SplitMode = mode;
            settings.Document.SplitSheetCount = 7;
            var back = Decode<ScanSettings>(CompatFixtures.Encode(settings));
            Assert.Equal((mode, 7), (back.Document.SplitMode, back.Document.SplitSheetCount));
            Assert.Equal(settings.Document, back.Document);
            var clone = settings.Clone();
            clone.Document.SplitMode = SplitMode.None;
            clone.Document.SplitSheetCount = 2;
            Assert.Equal((mode, 7), (settings.Document.SplitMode, settings.Document.SplitSheetCount));
        }
        Assert.Equal(["separatorSheet", "blankSheet", "sheetCount", "barcode"],
                     new[] { SplitMode.SeparatorSheet, SplitMode.BlankSheet, SplitMode.SheetCount, SplitMode.Barcode }.Select(mode =>
                     {
                         var settings = new ScanSettings();
                         settings.Document.SplitMode = mode;
                         using var json = JsonDocument.Parse(CompatFixtures.Encode(settings));
                         return json.RootElement.GetProperty("document").GetProperty("splitMode").GetString();
                     }));
    }

    [Fact]
    public void SplitLabelsAndHints()
    {
        Assert.Equal(["Off", "At separator sheets", "At blank sheets", "Every few sheets", "At QR codes or barcodes"],
                     SplitModes.DisplayOrder.Select(m => m.Label()));
        Assert.Equal(["All pages in one document", "A separator sheet starts each document",
                      "A blank sheet between documents splits them", "A new document every few sheets",
                      "A code starts each document and can name it"],
                     SplitModes.DisplayOrder.Select(m => m.Hint()));
        Assert.Equal(["", "Separator sheets are left out", "Blank sheets are left out", "", ""],
                     SplitModes.DisplayOrder.Select(m => m.Caption()));
        Assert.All(SplitModes.DisplayOrder, mode => Assert.False(string.IsNullOrWhiteSpace(mode.Steps())));
        Assert.StartsWith("1. Save or print a separator sheet. 2. Put one in front of each document after the first.",
                          SplitMode.SeparatorSheet.Steps());
        Assert.EndsWith("Only codes starting with CS-SEP count.", SplitMode.Barcode.Steps());
        Assert.Equal("Put an empty sheet between documents. With both sides scanned, only a sheet blank on both sides splits.",
                     SplitMode.BlankSheet.Steps());
        Assert.Equal("Pages are kept", BarcodeSeparators.StartsDocumentCaption(true));
        Assert.Equal("Sheets are left out", BarcodeSeparators.StartsDocumentCaption(false));
    }

    // MARK: - The settings' short texts (the text spec: tooltips of a few words)

    [Fact]
    public void ChoiceTexts_AreShort_AndNeverRepeatTheLabel()
    {
        Assert.Equal(["Flatbed", "Document feeder"], new[] { ScanSource.Flatbed, ScanSource.DocumentFeeder }.Select(s => s.Label()));
        Assert.Equal("Automatic document feeder (ADF)", ScanSource.DocumentFeeder.Hint());
        Assert.Equal("The scanner's glass", ScanSource.Flatbed.Hint());
        Assert.Equal(["Full quality, largest files", "Good for most documents", "Smaller, for email and uploads",
                      "Smallest, for strict size limits"], PdfSizePresets.DisplayOrder.Select(p => p.Hint()));
        Assert.Equal("Up to 300 dpi (black & white 600), gray pages saved in gray.", PdfSizePreset.Standard.Detail());
        Assert.Equal(["Stay here", "Open the file (several: show the folder)", "Show the files in their folder", "Email or send to an app"],
                     new[] { AfterSaveAction.None, AfterSaveAction.Open, AfterSaveAction.Reveal, AfterSaveAction.Share }.Select(a => a.Hint()));
        Assert.Equal(["Front only", "Both sides in one pass", "Scan the fronts, flip the stack, scan the backs"],
                     new[] { DuplexMode.Off, DuplexMode.Both, DuplexMode.Manual }.Select(m => m.Hint()));
        Assert.Equal(["Long edge (book)", "Short edge (calendar)"],
                     new[] { DuplexBinding.LongEdge, DuplexBinding.ShortEdge }.Select(b => b.Label()));
        Assert.Equal("Which edge the sheets turn on", DuplexBindings.PickerHint);
        Assert.Equal(["Only empty pages", "Also dust or a page number", "Also pages with small marks"],
                     BlankSensitivities.DisplayOrder.Select(b => b.Hint()));
        Assert.Equal("Check flagged pages before saving", BlankSensitivities.HighWarning);
        // A tooltip says more than the label, in fifteen words at most.
        var tips = new List<(string Label, string Hint)>();
        tips.AddRange(PdfSizePresets.DisplayOrder.Select(p => (p.Label(), p.Hint())));
        tips.AddRange(Enum.GetValues<AfterSaveAction>().Select(a => (a.Label(), a.Hint())));
        tips.AddRange(Enum.GetValues<DuplexMode>().Select(m => (m.Label(), m.Hint())));
        tips.AddRange(BlankSensitivities.DisplayOrder.Select(b => (b.Label(), b.Hint())));
        tips.AddRange(SplitModes.DisplayOrder.Select(m => (m.Label(), m.Hint())));
        tips.AddRange(Enum.GetValues<ScanSource>().Select(s => (s.Label(), s.Hint())));
        foreach (var (label, hint) in tips)
        {
            Assert.NotEqual(label, hint);
            Assert.InRange(StatusLine.Words(hint), 1, 15);
        }
    }

    // MARK: - Renamed tasks (CONTRACTS.md, rule 6): files keep the raw values, only the titles changed

    [Theory]
    [InlineData("feeder", ScanTask.Feeder, "Stack from feeder")]
    [InlineData("photoRestore", ScanTask.PhotoRestore, "Restore old photos")]
    [InlineData("copy", ScanTask.Copy, "Photocopy")]
    [InlineData("batch", ScanTask.Batch, "Separate documents")]
    public void RenamedTasks_StillDecode_FromSettingsAndPresetsWrittenBefore(string rawValue, ScanTask task, string title)
    {
        var settings = Decode<ScanSettings>($$"""{"resolution": 300, "taskId": "{{rawValue}}"}""");
        Assert.Equal(rawValue, settings.TaskId);
        Assert.Equal(task, settings.Task);
        Assert.Equal(title, TaskCatalog.Definition(settings.Task!.Value).Title);
        // Written back as it was read: the raw value, never the title.
        using var written = System.Text.Json.JsonDocument.Parse(CompatFixtures.Encode(settings));
        Assert.Equal(rawValue, written.RootElement.GetProperty("taskId").GetString());

        // A preset saved for the task by an earlier version keeps its name and its task.
        var presets = Decode<List<Preset>>($$$"""
            [{"id": "7b0f4c84-3c55-4f56-9d0f-0b4b5f1d2a09", "name": "My {{{rawValue}}} preset",
              "settings": {"intent": "document", "taskId": "{{{rawValue}}}"}}]
            """);
        var preset = Assert.Single(presets);
        Assert.Equal($"My {rawValue} preset", preset.Name);
        Assert.Equal(task, TaskCatalog.Infer(preset.Settings));
    }

    // MARK: - Barcode and QR separator sheets (CONTRACTS.md, rule 6)

    [Fact]
    public void BarcodeStartsDocument_IsOffByDefault_AndInFilesWithoutIt()
    {
        Assert.False(new ScanSettings().Document.BarcodeStartsDocument);
        Assert.False(Decode<List<Preset>>(CompatFixtures.PresetsJsonBeforePdfSize)[0].Settings.Document.BarcodeStartsDocument);
        // A "document" object written before it existed keeps its other settings, the barcode split too.
        var older = Decode<ScanSettings>("""{"document": {"splitMode": "barcode", "softenSpineShadow": true}}""");
        Assert.Equal((SplitMode.Barcode, true, false),
                     (older.Document.SplitMode, older.Document.SoftenSpineShadow, older.Document.BarcodeStartsDocument));
        foreach (string value in new[] { "null", "\"yes\"", "1", "{}" })
        {
            var settings = Decode<ScanSettings>($$"""{"document": {"splitMode": "barcode", "barcodeStartsDocument": {{value}}, "autoRotate": true}, "resolution": 150}""");
            Assert.False(settings.Document.BarcodeStartsDocument);
            Assert.Equal((SplitMode.Barcode, true, 150), (settings.Document.SplitMode, settings.Document.AutoRotate, settings.Resolution));
        }
        Assert.True(Decode<ScanSettings>("""{"document": {"barcodeStartsDocument": true}}""").Document.BarcodeStartsDocument);
    }

    [Fact]
    public void BarcodeStartsDocument_RoundTrips_AndCloneIsIndependent()
    {
        foreach (bool starts in new[] { false, true })
        {
            var settings = new ScanSettings();
            settings.Document.SplitMode = SplitMode.Barcode;
            settings.Document.BarcodeStartsDocument = starts;
            var back = Decode<ScanSettings>(CompatFixtures.Encode(settings));
            Assert.Equal((SplitMode.Barcode, starts), (back.Document.SplitMode, back.Document.BarcodeStartsDocument));
            Assert.Equal(settings.Document, back.Document);
        }
        var original = CompatFixtures.NonDefaultSettings();
        var clone = original.Clone();
        clone.Document.BarcodeStartsDocument = false;
        Assert.True(original.Document.BarcodeStartsDocument);
        Assert.NotEqual(original.Document, clone.Document);
    }

    [Fact]
    public void SplitBarcodePrefix_IsCsSepByDefault_AndInFilesWithoutIt()
    {
        Assert.Equal("CS-SEP", new ScanSettings().Document.SplitBarcodePrefix);
        Assert.Equal("CS-SEP", Decode<List<Preset>>(CompatFixtures.PresetsJsonBeforePdfSize)[0].Settings.Document.SplitBarcodePrefix);
        var older = Decode<ScanSettings>("""{"document": {"splitMode": "barcode", "barcodeStartsDocument": true}}""");
        Assert.Equal((SplitMode.Barcode, true, "CS-SEP"),
                     (older.Document.SplitMode, older.Document.BarcodeStartsDocument, older.Document.SplitBarcodePrefix));
        foreach (string value in new[] { "null", "1", "true", "{}", "[]" })
        {
            var settings = Decode<ScanSettings>($$"""{"document": {"splitMode": "barcode", "splitBarcodePrefix": {{value}}, "autoRotate": true}, "resolution": 150}""");
            Assert.Equal("CS-SEP", settings.Document.SplitBarcodePrefix);
            Assert.Equal((SplitMode.Barcode, true, 150), (settings.Document.SplitMode, settings.Document.AutoRotate, settings.Resolution));
        }
        // Any text is kept as written, an empty one too (every code makes a separator sheet).
        Assert.Equal(" Doc: ", Decode<ScanSettings>("""{"document": {"splitBarcodePrefix": " Doc: "}}""").Document.SplitBarcodePrefix);
        Assert.Equal("", Decode<ScanSettings>("""{"document": {"splitBarcodePrefix": ""}}""").Document.SplitBarcodePrefix);
    }

    [Fact]
    public void SplitBarcodePrefix_RoundTrips_AndCloneIsIndependent()
    {
        foreach (string prefix in new[] { "CS-SEP", "", "Fatura №" })
        {
            var settings = new ScanSettings();
            settings.Document.SplitBarcodePrefix = prefix;
            var back = Decode<ScanSettings>(CompatFixtures.Encode(settings));
            Assert.Equal(prefix, back.Document.SplitBarcodePrefix);
            Assert.Equal(settings.Document, back.Document);
        }
        var original = CompatFixtures.NonDefaultSettings();
        var clone = original.Clone();
        clone.Document.SplitBarcodePrefix = "OTHER";
        Assert.Equal("DOC", original.Document.SplitBarcodePrefix);
        Assert.NotEqual(original.Document, clone.Document);
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

    // MARK: - Rotate pages upright (CONTRACTS.md, rule 6)

    [Fact]
    public void RotatePagesUpright_IsOffByDefault_AndInFilesWithoutIt()
    {
        Assert.False(new ScanSettings().Document.AutoRotate);
        var presets = Decode<List<Preset>>(CompatFixtures.PresetsJsonBeforePdfSize);
        Assert.False(presets[0].Settings.Document.AutoRotate);
        // A "document" object written before it existed keeps its other settings.
        var older = Decode<ScanSettings>("""{"document": {"removeBlankPages": true, "autoStraighten": true, "splitMode": "blankSheet"}}""");
        Assert.Equal((true, true, SplitMode.BlankSheet, false),
                     (older.Document.RemoveBlankPages, older.Document.AutoStraighten, older.Document.SplitMode, older.Document.AutoRotate));
    }

    [Fact]
    public void CorruptRotatePagesUpright_FallsBackToOff_RestIntact()
    {
        var settings = Decode<ScanSettings>("""{"resolution": 150, "document": {"autoStraighten": true, "autoRotate": "yes"}}""");
        Assert.False(settings.Document.AutoRotate);
        Assert.True(settings.Document.AutoStraighten);
        Assert.Equal(150, settings.Resolution);
        Assert.False(Decode<ScanSettings>("""{"document": {"autoRotate": null}}""").Document.AutoRotate);
        Assert.True(Decode<ScanSettings>("""{"document": {"autoRotate": true}}""").Document.AutoRotate);
    }

    [Fact]
    public void RotatePagesUpright_RoundTrips_AndCloneIsIndependent()
    {
        foreach (bool rotate in new[] { false, true })
        {
            var settings = new ScanSettings();
            settings.Document.AutoRotate = rotate;
            var back = Decode<ScanSettings>(CompatFixtures.Encode(settings));
            Assert.Equal(rotate, back.Document.AutoRotate);
            Assert.Equal(settings.Document, back.Document);
        }
        var original = CompatFixtures.NonDefaultSettings();
        var clone = original.Clone();
        clone.Document.AutoRotate = false;
        Assert.True(original.Document.AutoRotate);
        Assert.NotEqual(original.Document, clone.Document);
        Assert.NotEqual(original.Document.GetHashCode(), clone.Document.GetHashCode());
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
                // No printer chosen: the key is left out, as Swift leaves out a nil.
                Assert.Equal(["idCardPaper", "idCardSaveSidesAsImages", "copyCount", "copyFitToPage", "copyAlsoSavePdf",
                              "receiptNameByDate", "receiptCombine", "bookRightToLeft", "bookRotationQuarterTurns",
                              "cameraFrontsFirst", "cameraSpreads"],
                             written.RootElement.GetProperty("taskOptions").EnumerateObject().Select(p => p.Name));
                Assert.Equal(settings.TaskOptions, Decode<ScanSettings>(json).TaskOptions);
            }
        }
        var copy = new ScanSettings();
        copy.TaskOptions.CopyCount = 12;
        copy.TaskOptions.CopyFitToPage = true;
        copy.TaskOptions.CopyPrinterName = "Microsoft Print to PDF";
        copy.TaskOptions.CopyAlsoSavePdf = true;
        string copyJson = CompatFixtures.Encode(copy);
        using (var written = JsonDocument.Parse(copyJson))
        {
            var options = written.RootElement.GetProperty("taskOptions");
            Assert.Equal(12, options.GetProperty("copyCount").GetInt32());
            Assert.Equal("Microsoft Print to PDF", options.GetProperty("copyPrinterName").GetString());
        }
        Assert.Equal(copy.TaskOptions, Decode<ScanSettings>(copyJson).TaskOptions);
        var original = CompatFixtures.NonDefaultSettings();
        var clone = original.Clone();
        Assert.NotSame(original.TaskOptions, clone.TaskOptions);
        Assert.Equal(original.TaskOptions, clone.TaskOptions);
        clone.TaskOptions.IdCardPaper = IdCardPaper.A4;
        clone.TaskOptions.IdCardSaveSidesAsImages = false;
        clone.TaskOptions.CopyCount = 1;
        clone.TaskOptions.CopyPrinterName = null;
        Assert.Equal((IdCardPaper.Letter, true), (original.TaskOptions.IdCardPaper, original.TaskOptions.IdCardSaveSidesAsImages));
        Assert.Equal((3, "Office printer"), (original.TaskOptions.CopyCount, original.TaskOptions.CopyPrinterName));
    }

    [Fact]
    public void CopyOptions_OneCopyAtRealSizeOnTheDefaultPrinter_ByDefaultAndInFilesWithoutThem()
    {
        var options = new ScanSettings().TaskOptions;
        Assert.Equal((1, false, (string?)null, false),
                     (options.CopyCount, options.CopyFitToPage, options.CopyPrinterName, options.CopyAlsoSavePdf));
        // Files of the ID card version have task options without the copy keys.
        var idCardOnly = Decode<ScanSettings>("""{"taskOptions": {"idCardPaper": "a4", "idCardSaveSidesAsImages": true}}""").TaskOptions;
        Assert.Equal((IdCardPaper.A4, true), (idCardOnly.IdCardPaper, idCardOnly.IdCardSaveSidesAsImages));
        Assert.Equal((1, false, (string?)null, false),
                     (idCardOnly.CopyCount, idCardOnly.CopyFitToPage, idCardOnly.CopyPrinterName, idCardOnly.CopyAlsoSavePdf));
    }

    [Fact]
    public void ReceiptOptions_NamedByDateInSeparateFiles_ByDefaultAndInFilesWithoutThem()
    {
        var options = new ScanSettings().TaskOptions;
        Assert.Equal((true, false), (options.ReceiptNameByDate, options.ReceiptCombine));
        // Files of the copy version have task options without the receipt keys.
        var copyOnly = Decode<ScanSettings>("""{"taskOptions": {"copyCount": 2, "copyAlsoSavePdf": true}}""").TaskOptions;
        Assert.Equal((2, true), (copyOnly.CopyCount, copyOnly.CopyAlsoSavePdf));
        Assert.Equal((true, false), (copyOnly.ReceiptNameByDate, copyOnly.ReceiptCombine));
        var settings = new ScanSettings();
        settings.TaskOptions.ReceiptNameByDate = false;
        settings.TaskOptions.ReceiptCombine = true;
        Assert.Equal(settings.TaskOptions, Decode<ScanSettings>(CompatFixtures.Encode(settings)).TaskOptions);
        var clone = settings.Clone();
        clone.TaskOptions.ReceiptCombine = false;
        Assert.True(settings.TaskOptions.ReceiptCombine);
    }

    // MARK: - Book or magazine (CONTRACTS.md, rule 6)

    [Fact]
    public void BookOptions_AreOffByDefault_AndInFilesWithoutThem()
    {
        var settings = new ScanSettings();
        Assert.Equal((false, false, 0), (settings.Document.SplitFacingPages, settings.TaskOptions.BookRightToLeft,
                                         settings.TaskOptions.BookRotationQuarterTurns));
        var presets = Decode<List<Preset>>(CompatFixtures.PresetsJsonBeforePdfSize);
        Assert.False(presets[0].Settings.Document.SplitFacingPages);
        // Objects written before they existed keep their other settings.
        var older = Decode<ScanSettings>("""
            {"document": {"autoStraighten": true, "autoRotate": true}, "taskOptions": {"copyCount": 2, "receiptCombine": true}}
            """);
        Assert.Equal((true, true, false), (older.Document.AutoStraighten, older.Document.AutoRotate, older.Document.SplitFacingPages));
        Assert.Equal((2, true, false, 0), (older.TaskOptions.CopyCount, older.TaskOptions.ReceiptCombine,
                                           older.TaskOptions.BookRightToLeft, older.TaskOptions.BookRotationQuarterTurns));
    }

    [Fact]
    public void CorruptBookOptions_FallBackOneByOne_RestIntact()
    {
        var settings = Decode<ScanSettings>("""
            {"resolution": 150, "document": {"autoRotate": true, "splitFacingPages": "yes"},
             "taskOptions": {"copyCount": 2, "bookRightToLeft": 1, "bookRotationQuarterTurns": "left"}, "pdfSearchable": false}
            """);
        Assert.Equal((150, false), (settings.Resolution, settings.PdfSearchable));
        Assert.Equal((true, false), (settings.Document.AutoRotate, settings.Document.SplitFacingPages));
        Assert.Equal((2, false, 0), (settings.TaskOptions.CopyCount, settings.TaskOptions.BookRightToLeft,
                                     settings.TaskOptions.BookRotationQuarterTurns));
        var nulls = Decode<ScanSettings>("""
            {"document": {"splitFacingPages": null}, "taskOptions": {"bookRightToLeft": true, "bookRotationQuarterTurns": null}}
            """);
        Assert.Equal((false, true, 0), (nulls.Document.SplitFacingPages, nulls.TaskOptions.BookRightToLeft,
                                        nulls.TaskOptions.BookRotationQuarterTurns));
        // A turn out of range is kept as written and read through BookSplitter.NormalizedTurns.
        var turns = Decode<ScanSettings>("""{"taskOptions": {"bookRotationQuarterTurns": 7}}""").TaskOptions;
        Assert.Equal((7, 3), (turns.BookRotationQuarterTurns, BookSplitOptions.Of(new ScanSettings { TaskOptions = turns }).RotationQuarterTurns));
    }

    [Fact]
    public void BookOptions_RoundTrip_AndCloneIsIndependent()
    {
        foreach (bool split in new[] { false, true })
        {
            foreach (int turns in new[] { 0, 1, 2, 3 })
            {
                var settings = new ScanSettings();
                settings.Document.SplitFacingPages = split;
                settings.TaskOptions.BookRightToLeft = !split;
                settings.TaskOptions.BookRotationQuarterTurns = turns;
                var back = Decode<ScanSettings>(CompatFixtures.Encode(settings));
                Assert.Equal(settings.Document, back.Document);
                Assert.Equal(settings.TaskOptions, back.TaskOptions);
            }
        }
        var original = CompatFixtures.NonDefaultSettings();
        var clone = original.Clone();
        clone.Document.SplitFacingPages = false;
        clone.TaskOptions.BookRightToLeft = false;
        clone.TaskOptions.BookRotationQuarterTurns = 0;
        Assert.Equal((true, true, 1), (original.Document.SplitFacingPages, original.TaskOptions.BookRightToLeft,
                                       original.TaskOptions.BookRotationQuarterTurns));
        Assert.NotEqual(original.Document, clone.Document);
        Assert.NotEqual(original.TaskOptions, clone.TaskOptions);
        Assert.NotEqual(original.TaskOptions.GetHashCode(), clone.TaskOptions.GetHashCode());
    }

    // MARK: - The iPhone camera's choices (CONTRACTS.md, rule 6)

    [Fact]
    public void CameraOptions_AreOffByDefault_ReadLeniently_AndRoundTrip()
    {
        var settings = new ScanSettings();
        Assert.Equal((false, false), (settings.TaskOptions.CameraFrontsFirst, settings.TaskOptions.CameraSpreads));
        var older = Decode<ScanSettings>("""{"taskOptions": {"copyCount": 2, "bookRightToLeft": true}}""");
        Assert.Equal((2, true, false, false), (older.TaskOptions.CopyCount, older.TaskOptions.BookRightToLeft,
                                               older.TaskOptions.CameraFrontsFirst, older.TaskOptions.CameraSpreads));
        var corrupt = Decode<ScanSettings>("""
            {"resolution": 150, "taskOptions": {"cameraFrontsFirst": "yes", "cameraSpreads": true, "copyCount": 4}}
            """);
        Assert.Equal((150, 4, false, true), (corrupt.Resolution, corrupt.TaskOptions.CopyCount,
                                             corrupt.TaskOptions.CameraFrontsFirst, corrupt.TaskOptions.CameraSpreads));
        var nulls = Decode<ScanSettings>("""{"taskOptions": {"cameraFrontsFirst": true, "cameraSpreads": null}}""");
        Assert.Equal((true, false), (nulls.TaskOptions.CameraFrontsFirst, nulls.TaskOptions.CameraSpreads));
        foreach (bool frontsFirst in new[] { false, true })
        {
            foreach (bool spreads in new[] { false, true })
            {
                var chosen = new ScanSettings();
                chosen.TaskOptions.CameraFrontsFirst = frontsFirst;
                chosen.TaskOptions.CameraSpreads = spreads;
                Assert.Equal(chosen.TaskOptions, Decode<ScanSettings>(CompatFixtures.Encode(chosen)).TaskOptions);
            }
        }
        // Picking a task keeps them: they say how the user takes that task with the camera.
        var kept = TaskCatalog.Apply(ScanTask.Book, CompatFixtures.NonDefaultSettings());
        Assert.Equal((true, true), (kept.TaskOptions.CameraFrontsFirst, kept.TaskOptions.CameraSpreads));
        var clone = kept.Clone();
        clone.TaskOptions.CameraSpreads = false;
        Assert.True(kept.TaskOptions.CameraSpreads);
        Assert.NotEqual(kept.TaskOptions, clone.TaskOptions);
    }

    // MARK: - Softening the spine's shadow (CONTRACTS.md, rule 6)

    [Fact]
    public void SoftenSpineShadow_OffByDefault_AndInFilesWithoutIt()
    {
        Assert.False(new ScanSettings().Document.SoftenSpineShadow);
        Assert.False(Decode<List<Preset>>(CompatFixtures.PresetsJsonBeforePdfSize)[0].Settings.Document.SoftenSpineShadow);
        // A "document" object written before it existed keeps its other settings.
        var older = Decode<ScanSettings>("""{"document": {"autoStraighten": true, "splitFacingPages": true}}""");
        Assert.Equal((true, true, false), (older.Document.AutoStraighten, older.Document.SplitFacingPages, older.Document.SoftenSpineShadow));
        foreach (string value in new[] { "\"yes\"", "1", "null", "{}", "[]" })
        {
            var settings = Decode<ScanSettings>($$"""{"document": {"splitFacingPages": true, "softenSpineShadow": {{value}}, "autoRotate": true}, "resolution": 150}""");
            Assert.False(settings.Document.SoftenSpineShadow);
            Assert.Equal((true, true, 150), (settings.Document.SplitFacingPages, settings.Document.AutoRotate, settings.Resolution));
        }
        Assert.True(Decode<ScanSettings>("""{"document": {"softenSpineShadow": true}}""").Document.SoftenSpineShadow);
    }

    [Fact]
    public void SoftenSpineShadow_RoundTrips_AndCloneIsIndependent()
    {
        foreach (bool soften in new[] { false, true })
        {
            var settings = new ScanSettings();
            settings.Document.SoftenSpineShadow = soften;
            var back = Decode<ScanSettings>(CompatFixtures.Encode(settings));
            Assert.Equal(soften, back.Document.SoftenSpineShadow);
            Assert.Equal(settings.Document, back.Document);
        }
        var original = CompatFixtures.NonDefaultSettings();
        var clone = original.Clone();
        clone.Document.SoftenSpineShadow = false;
        Assert.True(original.Document.SoftenSpineShadow);
        Assert.NotEqual(original.Document, clone.Document);
        Assert.NotEqual(original.Document.GetHashCode(), clone.Document.GetHashCode());
    }

    [Fact]
    public void CorruptReceiptOptions_FallBackOneByOne_RestIntact()
    {
        var options = Decode<ScanSettings>("""
            {"resolution": 150, "taskOptions": {"copyCount": 2, "receiptNameByDate": "no", "receiptCombine": true},
             "pdfSearchable": false}
            """);
        Assert.Equal((150, false), (options.Resolution, options.PdfSearchable));
        Assert.Equal((2, true, true), (options.TaskOptions.CopyCount, options.TaskOptions.ReceiptNameByDate,
                                       options.TaskOptions.ReceiptCombine));
        var nulls = Decode<ScanSettings>("""{"taskOptions": {"receiptNameByDate": false, "receiptCombine": null}}""").TaskOptions;
        Assert.Equal((false, false), (nulls.ReceiptNameByDate, nulls.ReceiptCombine));
    }

    [Fact]
    public void CorruptCopyOptions_FallBackOneByOne_RestIntact()
    {
        var options = Decode<ScanSettings>("""
            {"resolution": 150, "taskOptions": {"idCardPaper": "letter", "copyCount": "three", "copyFitToPage": 1,
             "copyPrinterName": 42, "copyAlsoSavePdf": true}, "pdfSearchable": false}
            """);
        Assert.Equal(150, options.Resolution);
        Assert.False(options.PdfSearchable);
        Assert.Equal(IdCardPaper.Letter, options.TaskOptions.IdCardPaper);
        Assert.Equal((1, false, (string?)null, true),
                     (options.TaskOptions.CopyCount, options.TaskOptions.CopyFitToPage,
                      options.TaskOptions.CopyPrinterName, options.TaskOptions.CopyAlsoSavePdf));
        var nulls = Decode<ScanSettings>("""{"taskOptions": {"copyCount": null, "copyPrinterName": null, "copyFitToPage": true}}""").TaskOptions;
        Assert.Equal((1, true, (string?)null), (nulls.CopyCount, nulls.CopyFitToPage, nulls.CopyPrinterName));
        // A count out of range is kept as written and read through PrintCopies.Clamp.
        var many = Decode<ScanSettings>("""{"taskOptions": {"copyCount": 500}}""").TaskOptions;
        Assert.Equal(500, many.CopyCount);
        Assert.Equal(99, PrintCopies.Clamp(many.CopyCount));
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

    [Fact]
    public void InspectorSections_MissingOrCorrupt_IsEmptyAndRoundTrips()
    {
        Assert.Empty(Decode<AppPreferences>("""{ "appearance": "dark" }""").InspectorSections);
        var corrupt = Decode<AppPreferences>("""{ "appearance": "dark", "inspectorSections": ["pages"] }""");
        Assert.Empty(corrupt.InspectorSections);
        Assert.Equal(AppAppearance.Dark, corrupt.Appearance);
        Assert.Empty(Decode<AppPreferences>("""{ "inspectorSections": null }""").InspectorSections);

        var preferences = new AppPreferences();
        preferences.InspectorSections["pages"] = true;
        preferences.InspectorSections["output"] = false;
        string json = CompatFixtures.Encode(preferences);
        Assert.Contains("\"inspectorSections\"", json);
        var read = Decode<AppPreferences>(json).InspectorSections;
        Assert.True(read["pages"]);
        Assert.False(read["output"]);
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

    // Swift's JSONDecoder takes a comma before a closing bracket; this reader does not, and the
    // Swift twin refuses it too, so neither app reads such a file.
    [Fact]
    public void PresetsFileWithATrailingComma_IsKept()
    {
        File.WriteAllText(PresetsPath, CompatFixtures.CurrentFormatPresetsJson.Replace("\"name\"", "\"future\":[1,],\"name\""));

        Assert.Empty(new PresetStore(_directory).Load());
        Assert.Single(KeptFiles("presets.unreadable-"));
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
