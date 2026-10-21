namespace CompleteScanner.Core;

// Twin of Sources/CompleteScannerKit/Escl/EsclTxtRecord.swift: the same rules and tests on both platforms.

/// <summary>
/// The TXT record a network scanner advertises with its _uscan._tcp / _uscans._tcp DNS-SD
/// service (Mopria eSCL): where the eSCL resource lives, what the device is and roughly what
/// it can do, known before connecting to it.
/// </summary>
public sealed class EsclTxtRecord
{
    /// <summary>The eSCL resource path below the host, without slashes ("eSCL" unless the device says otherwise; "" for the root).</summary>
    public string ResourcePath { get; init; } = "eSCL";
    /// <summary>Make and model (ty), e.g. "HP Color LaserJet MFP M479fdw".</summary>
    public string? Model { get; init; }
    /// <summary>The device UUID (UUID), the same value its ScannerCapabilities report.</summary>
    public string? Uuid { get; init; }
    /// <summary>The device's web page (adminurl).</summary>
    public string? AdminUrl { get; init; }
    /// <summary>eSCL version (vers), e.g. "2.63".</summary>
    public string? Version { get; init; }
    /// <summary>The user-assigned location (note).</summary>
    public string? Note { get; init; }
    /// <summary>The feeder scans both sides (duplex=T); null when not advertised.</summary>
    public bool? Duplex { get; init; }
    /// <summary>Input sources (is), lowercased, e.g. "platen", "adf".</summary>
    public IReadOnlyList<string> InputSources { get; init; } = [];
    /// <summary>Color spaces (cs), lowercased, e.g. "color", "grayscale", "binary".</summary>
    public IReadOnlyList<string> ColorSpaces { get; init; } = [];
    /// <summary>Document formats (pdl), e.g. "image/jpeg", "application/pdf".</summary>
    public IReadOnlyList<string> DocumentFormats { get; init; } = [];

    /// <summary>
    /// Reads "key=value" strings (the form Windows reports TXT attributes in). Keys are
    /// matched without regard to ASCII case and only the first occurrence of a key counts
    /// (RFC 6763, 6.4); entries without '=' and unknown keys are ignored.
    /// </summary>
    public static EsclTxtRecord Parse(IEnumerable<string>? attributes)
    {
        var values = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (string attribute in attributes ?? [])
        {
            if (attribute is null) continue;
            int equals = attribute.IndexOf('=');
            if (equals <= 0) continue;
            string key = attribute[..equals].Trim();
            if (key.Length > 0) values.TryAdd(key, attribute[(equals + 1)..].Trim());
        }

        string? Value(string key) => values.TryGetValue(key, out var v) && v.Length > 0 ? v : null;
        IReadOnlyList<string> List(string key, bool lowercase) =>
            Value(key) is { } text
                ? text.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
                      .Select(item => lowercase ? item.ToLowerInvariant() : item)
                      .Distinct(StringComparer.OrdinalIgnoreCase).ToList()
                : [];

        return new EsclTxtRecord
        {
            // A present but empty rs means the resource is at the root.
            ResourcePath = values.TryGetValue("rs", out var rs) ? rs.Trim('/') : "eSCL",
            Model = Value("ty"),
            Uuid = Value("UUID"),
            AdminUrl = Value("adminurl"),
            Version = Value("vers"),
            Note = Value("note"),
            Duplex = Value("duplex")?.ToUpperInvariant() switch
            {
                "T" or "TRUE" => true,
                "F" or "FALSE" => false,
                _ => null,
            },
            InputSources = List("is", lowercase: true),
            ColorSpaces = List("cs", lowercase: true),
            DocumentFormats = List("pdl", lowercase: false),
        };
    }

    /// <summary>
    /// A UUID reduced to its lowercase letters and digits ("urn:uuid:" and braces dropped), so
    /// the forms devices use in TXT records and capabilities compare equal; null when empty.
    /// </summary>
    public static string? UuidKey(string? uuid)
    {
        if (string.IsNullOrWhiteSpace(uuid)) return null;
        string text = uuid.Trim().ToLowerInvariant();
        if (text.StartsWith("urn:uuid:", StringComparison.Ordinal)) text = text["urn:uuid:".Length..];
        string key = new([.. text.Where(char.IsAsciiLetterOrDigit)]);
        return key.Length > 0 ? key : null;
    }
}
