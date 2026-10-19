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
    /// Same as <see cref="BaseFilename(NamingContext)"/> without a task.
    /// </summary>
    public string BaseFilename(int counter, DateTime date, ScanIntent intent, int? index) =>
        BaseFilename(new NamingContext(counter, date, intent) { Index = index });

    /// <summary>
    /// The file name (without extension) for <paramref name="context"/>: the tokens of
    /// <see cref="BaseFilename(int, DateTime, ScanIntent, int?)"/>, plus {task} (the task's
    /// <see cref="TaskDefinition.FileLabel"/>, or the {intent} text when there is no task).
    /// </summary>
    public string BaseFilename(NamingContext context)
    {
        string result = Template;
        int counter = context.Counter;
        var date = context.Date;
        int? index = context.Index;

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
            ("{intent}", context.Intent.Label()),
            ("{index}", index?.ToString(CultureInfo.InvariantCulture) ?? ""),
            ("{task}", context.Task is { } task ? TaskCatalog.Definition(task).FileLabel : context.Intent.Label()),
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

    /// <summary>Give up after this many names that were taken between the check and the move.</summary>
    private const int MaxMoveAttempts = 1000;

    /// <summary>
    /// Move <paramref name="sourceFile"/> to <paramref name="path"/> without ever replacing an
    /// existing file. <see cref="UniquePath"/> only checks a name; another writer can take it
    /// before the file lands. Here the existence check and the move are one rename that fails
    /// when the name is taken, and the next free " 2", " 3", … name is tried instead.
    /// Returns the path the file was moved to.
    /// </summary>
    public static string MoveToFreePath(string sourceFile, string path)
    {
        string fullPath = Path.GetFullPath(path);
        string directory = Path.GetDirectoryName(fullPath)!;
        string baseName = Path.GetFileNameWithoutExtension(fullPath);
        string extension = Path.GetExtension(fullPath);
        string candidate = fullPath;
        for (int attempt = 1; ; attempt++)
        {
            try
            {
                File.Move(sourceFile, candidate, overwrite: false);
                return candidate;
            }
            catch (IOException) when (attempt < MaxMoveAttempts && File.Exists(candidate))
            {
                int suffix = 2;
                do
                {
                    candidate = Path.Combine(directory, $"{baseName} {suffix}{extension}");
                    suffix += 1;
                } while (File.Exists(candidate));
            }
        }
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

/// <summary>
/// Everything a file name can be built from (see <see cref="NamingTemplate.BaseFilename(NamingContext)"/>).
/// Later naming tokens add their values here as further optional properties, so the
/// signature of <see cref="NamingTemplate.BaseFilename(NamingContext)"/> stays the same.
/// </summary>
/// <param name="Counter">The running number for {counter}.</param>
/// <param name="Date">The scan date and time for {date}, {time}, {year}, {month} and {day}.</param>
/// <param name="Intent">The scan mode for {intent}.</param>
public sealed record NamingContext(int Counter, DateTime Date, ScanIntent Intent)
{
    /// <summary>The file's number within a batch for {index}; appended when the template has no {index}.</summary>
    public int? Index { get; init; }

    /// <summary>The task for {task}; null gives the {intent} text.</summary>
    public ScanTask? Task { get; init; }
}
