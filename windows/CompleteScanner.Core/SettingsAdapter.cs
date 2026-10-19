namespace CompleteScanner.Core;

// Port of Sources/CompleteScannerKit/Core/SettingsAdapter.swift.

/// <summary>Which setting <see cref="SettingsAdapter.Adapt"/> changed.</summary>
public enum SettingsChange
{
    Source,
    Resolution,
}

/// <summary>A setting changed to suit the scanner, with a sentence saying so.</summary>
public sealed record SettingsNote(SettingsChange Change, string Message);

/// <summary>The settings as the scanner can use them, and what had to change.</summary>
public sealed record AdaptedSettings(ScanSettings Settings, IReadOnlyList<SettingsNote> Notes);

/// <summary>
/// Fits settings to what a scanner offers: a source it has (the first one it lists when the
/// chosen one is missing; the flatbed when it lists none) and the nearest resolution it
/// supports. Used whenever settings meet a scanner: applying a preset or task, and
/// connecting to another scanner.
/// </summary>
public static class SettingsAdapter
{
    /// <summary>
    /// A copy of <paramref name="settings"/> adapted to <paramref name="capabilities"/>
    /// (unchanged when null: no scanner connected yet). <paramref name="settings"/> itself is
    /// not changed.
    /// </summary>
    public static AdaptedSettings Adapt(ScanSettings settings, ScannerCapabilities? capabilities)
    {
        var s = settings.Clone();
        var notes = new List<SettingsNote>();
        if (capabilities is null) return new AdaptedSettings(s, notes);

        if (!capabilities.Sources.Contains(s.Source))
        {
            var fallback = capabilities.Sources.Count > 0 ? capabilities.Sources[0] : ScanSource.Flatbed;
            if (fallback != s.Source)
            {
                notes.Add(new SettingsNote(SettingsChange.Source, fallback == ScanSource.DocumentFeeder
                    ? "This scanner has no flatbed, so the document feeder is used."
                    : "This scanner has no document feeder, so the flatbed is used."));
                s.Source = fallback;
            }
        }

        int resolution = capabilities.NearestResolution(s.Resolution);
        if (resolution != s.Resolution)
        {
            notes.Add(new SettingsNote(SettingsChange.Resolution,
                $"This scanner does not offer {s.Resolution} dpi, so {resolution} dpi is used."));
            s.Resolution = resolution;
        }
        return new AdaptedSettings(s, notes);
    }
}
