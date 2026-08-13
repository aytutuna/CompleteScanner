using System.Text.Json;
using System.Text.Json.Serialization;

namespace CompleteScanner.Core;

// Port of Sources/CompleteScannerKit/Persistence/PresetStore.swift.

public sealed class PresetStore
{
    /// <summary>Loads saved presets; on first run returns (and persists) built-in starter presets.</summary>
    public List<Preset> Load()
    {
        if (StoreFiles.Read<List<Preset>>(StoreFiles.PresetsPath) is { } presets)
        {
            return presets;
        }
        var builtIns = BuiltInPresets();
        Save(builtIns);
        return builtIns;
    }

    public void Save(List<Preset> presets)
    {
        StoreFiles.Write(presets, StoreFiles.PresetsPath);
    }

    // MARK: Built-in starter presets

    private static List<Preset> BuiltInPresets()
    {
        var documentPdf = new ScanSettings
        {
            Intent = ScanIntent.Document,
            Resolution = 300,
            ColorMode = ColorMode.Color,
            Format = OutputFormat.Pdf,
            PdfSearchable = true,
            DocumentMultiPage = true,
        };

        var compactText = new ScanSettings
        {
            Intent = ScanIntent.Document,
            Resolution = 200,
            ColorMode = ColorMode.Grayscale,
            Format = OutputFormat.Pdf,
            PdfSearchable = true,
        };

        var photosJpeg = new ScanSettings
        {
            Intent = ScanIntent.Photo,
            Resolution = 600,
            ColorMode = ColorMode.Color,
            Format = OutputFormat.Jpeg,
            PhotoAutoSplit = true,
            PhotoAutoDeskew = true,
        };

        var photoRestoration = new ScanSettings
        {
            Intent = ScanIntent.Photo,
            Resolution = 600,
            ColorMode = ColorMode.Color,
            Format = OutputFormat.Png,
        };
        photoRestoration.Adjustments.RestoreFadedColors = true;
        photoRestoration.Adjustments.AutoEnhance = true;

        var quickPreview = new ScanSettings
        {
            Intent = ScanIntent.Document,
            Resolution = 150,
            ColorMode = ColorMode.Color,
            Format = OutputFormat.Jpeg,
            DocumentMultiPage = false,
        };

        return
        [
            new Preset("Document → PDF (300 dpi)", documentPdf),
            new Preset("Text document, compact (200 dpi, grayscale)", compactText),
            new Preset("Photos → JPEG (600 dpi, auto-split)", photosJpeg),
            new Preset("Old photo restoration (600 dpi, PNG)", photoRestoration),
            new Preset("Quick preview scan (150 dpi)", quickPreview),
        ];
    }
}

public static class SettingsStore
{
    public static ScanSettings? Load() => StoreFiles.Read<ScanSettings>(StoreFiles.SettingsPath);

    public static void Save(ScanSettings settings) => StoreFiles.Write(settings, StoreFiles.SettingsPath);
}

/// <summary>
/// JSON storage under %APPDATA%\CompleteScanner\ (the Windows analogue of
/// ~/Library/Application Support/CompleteScanner/), created on demand.
/// </summary>
internal static class StoreFiles
{
    internal static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase) },
    };

    internal static string Directory =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                     "CompleteScanner");

    internal static string PresetsPath => Path.Combine(Directory, "presets.json");
    internal static string SettingsPath => Path.Combine(Directory, "settings.json");

    /// <summary>null when the file is missing or does not decode.</summary>
    internal static T? Read<T>(string path) where T : class
    {
        try
        {
            if (!File.Exists(path)) return null;
            return JsonSerializer.Deserialize<T>(File.ReadAllText(path), JsonOptions);
        }
        catch
        {
            return null;
        }
    }

    /// <summary>Best-effort atomic write; creates the directory on demand.</summary>
    internal static void Write<T>(T value, string path)
    {
        try
        {
            System.IO.Directory.CreateDirectory(Directory);
            string tmp = path + ".tmp";
            File.WriteAllText(tmp, JsonSerializer.Serialize(value, JsonOptions));
            File.Move(tmp, path, overwrite: true);
        }
        catch
        {
            // Best effort, mirroring the Swift store's try?.
        }
    }
}
