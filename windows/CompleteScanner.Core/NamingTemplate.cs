using System.Globalization;
using System.Text.RegularExpressions;

namespace CompleteScanner.Core;

/// <summary>
/// Filename templating, ported from Sources/CompleteScannerKit/Output/NamingTemplate.swift.
/// </summary>
public sealed partial class NamingTemplate
{
    public string Template { get; }

    public NamingTemplate(string template)
    {
        Template = template;
    }

    [GeneratedRegex(@"\{counter:[0-9]+\}")]
    private static partial Regex PaddedCounterRegex();

    /// <summary>
    /// Tokens: {date}=yyyy-MM-dd, {time}=HH.mm.ss, {year} {month} {day}, {counter} (also
    /// {counter:N} zero-padded), {intent} ("Document"/"Photos"), {index} (photo number in a
    /// batch, empty when null). Unknown tokens pass through; result sanitized for the
    /// filesystem (the Windows port strips the full invalid set, not just "/" and ":").
    /// </summary>
    public string BaseFilename(int counter, DateTime date, ScanIntent intent, int? index)
    {
        string result = Template;

        // {counter:N} — zero-padded to N digits.
        result = PaddedCounterRegex().Replace(result, match =>
        {
            string widthText = match.Value["{counter:".Length..^1];
            int width = Math.Min(int.TryParse(widthText, out int parsed) ? parsed : 1, 20);
            return counter.ToString(CultureInfo.InvariantCulture)
                          .PadLeft(width, '0');
        });

        var replacements = new (string Token, string Value)[]
        {
            ("{date}", date.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture)),
            ("{time}", date.ToString("HH.mm.ss", CultureInfo.InvariantCulture)),
            ("{year}", date.ToString("yyyy", CultureInfo.InvariantCulture)),
            ("{month}", date.ToString("MM", CultureInfo.InvariantCulture)),
            ("{day}", date.ToString("dd", CultureInfo.InvariantCulture)),
            ("{counter}", counter.ToString(CultureInfo.InvariantCulture)),
            ("{intent}", intent.Label()),
            ("{index}", index?.ToString(CultureInfo.InvariantCulture) ?? ""),
        };
        foreach (var (token, value) in replacements)
        {
            result = result.Replace(token, value);
        }

        // In a photo batch, make sure every file gets its index even when the template has
        // no {index} token, so batch photos never collide.
        if (index is { } idx && !Template.Contains("{index}"))
        {
            result += $" {idx}";
        }

        return Sanitized(result);
    }

    /// <summary>base.ext, appending " 2", " 3", … until the name is free.</summary>
    public static string UniquePath(string directory, string baseName, string fileExtension)
    {
        string candidate = Path.Combine(directory, $"{baseName}.{fileExtension}");
        int suffix = 2;
        while (File.Exists(candidate))
        {
            candidate = Path.Combine(directory, $"{baseName} {suffix}.{fileExtension}");
            suffix += 1;
        }
        return candidate;
    }

    /// <summary>
    /// Make the name safe for the filesystem: no path separators or Windows-reserved
    /// characters, no leading/trailing whitespace, no doubled spaces, never empty.
    /// </summary>
    private static string Sanitized(string name)
    {
        var chars = name.ToCharArray();
        for (int i = 0; i < chars.Length; i++)
        {
            // The Swift original replaces "/" and ":"; Windows additionally reserves \ * ? " < > |
            // and control characters.
            char c = chars[i];
            if (c is '/' or ':' or '\\' or '*' or '?' or '"' or '<' or '>' or '|' || char.IsControl(c))
                chars[i] = '-';
        }
        string result = new string(chars).Trim();
        while (result.Contains("  "))
        {
            result = result.Replace("  ", " ");
        }
        return result.Length == 0 ? "Scan" : result;
    }
}
