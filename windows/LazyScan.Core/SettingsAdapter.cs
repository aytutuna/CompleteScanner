namespace LazyScan.Core;

// Port of Sources/CompleteScannerKit/Core/SettingsAdapter.swift.

/// <summary>Which setting <see cref="SettingsAdapter.Adapt"/> changed.</summary>
public enum SettingsChange
{
    Source,
    Resolution,
    Duplex,
    PaperSize,
}

/// <summary>A setting changed to suit the scanner, with a sentence saying so.</summary>
public sealed record SettingsNote(SettingsChange Change, string Message);

/// <summary>The settings as the scanner can use them, and what had to change.</summary>
public sealed record AdaptedSettings(ScanSettings Settings, IReadOnlyList<SettingsNote> Notes);

/// <summary>
/// Fits settings to what a scanner offers: a source it has (the first one it lists when the
/// chosen one is missing; the flatbed when it lists none), two-sided feeder scans by hand when
/// its feeder scans one side, a paper size that fits the glass or the feeder (Automatic
/// otherwise), and the nearest resolution it supports. Used whenever settings meet a scanner:
/// applying a preset or task, and connecting to another scanner.
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

        if (s.Source == ScanSource.DocumentFeeder && s.Duplex == DuplexMode.Both && !capabilities.SupportsDuplex)
        {
            notes.Add(new SettingsNote(SettingsChange.Duplex,
                "This scanner's feeder scans one side at a time, so you'll turn the stack over by hand."));
            s.Duplex = DuplexMode.Manual;
        }

        bool feeder = s.Source == ScanSource.DocumentFeeder;
        var area = feeder ? capabilities.FeederSizeInches : capabilities.FlatbedSizeInches;
        if (!PaperSizes.Fits(s.PaperSize, area))
        {
            notes.Add(new SettingsNote(SettingsChange.PaperSize,
                $"{s.PaperSize.Label()} paper does not fit this scanner's {(feeder ? "feeder" : "glass")}, so the paper size is Automatic."));
            s.PaperSize = PaperSize.Auto;
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
