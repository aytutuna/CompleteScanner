namespace LazyScan.Core;

// Port of Sources/LazyScanKit/Output/NamingTokens.swift: what the file name field offers around
// NamingTemplate (same parts, same texts, same tests).

/// <summary>
/// A part a file name can be built from, as the Insert menu offers it: its name, the token typed into the
/// template and what it becomes.
/// </summary>
public sealed record NamingToken(string Label, string Token, string Help);

/// <summary>The template typed with a token put in, and where the caret goes after it.</summary>
public readonly record struct NamingInsertion(string Text, int Caret);

/// <summary>
/// What the file name field offers around <see cref="NamingTemplate"/>: the parts to insert, putting one
/// in, the name the next file gets, and what is wrong with a template.
/// </summary>
public static class NamingTokens
{
    /// <summary>The Insert menu's parts, in order.</summary>
    public static IReadOnlyList<NamingToken> All { get; } =
    [
        new("Date", "{date}", "Scan date, e.g. 2026-08-13"),
        new("Time", "{time}", "Scan time, e.g. 14.05.32"),
        new("Number", "{counter}", "Running number"),
        new("Mode", "{intent}", "“Document” or “Photos”"),
        new("Task", "{task}", "The task, e.g. “Receipt”"),
        new("Document name", "{label}", "The document’s name, given in the page strip"),
        new("Receipt date", "{docdate}", "The date printed on a receipt"),
    ];

    /// <summary>Every token <see cref="NamingTemplate"/> replaces; {counter:N} is known as well.</summary>
    public static IReadOnlyList<string> Known { get; } =
        ["{date}", "{time}", "{year}", "{month}", "{day}", "{counter}", "{intent}", "{index}", "{task}", "{docdate}", "{label}"];

    /// <summary>The line under a blank file name: the last name is kept.</summary>
    public const string EmptyProblem = "Needs a file name";

    /// <summary>The line under a file name with a token <see cref="NamingTemplate"/> does not know (it stays as typed).</summary>
    public static string UnknownProblem(string token) => $"Unknown part {token}";

    /// <summary>
    /// <paramref name="token"/> put into <paramref name="text"/> at <paramref name="offset"/> (kept within
    /// the text), with a space before it unless it follows a space or starts the text; the caret goes right
    /// after it.
    /// </summary>
    public static NamingInsertion Insert(string token, string text, int offset)
    {
        int at = Math.Clamp(offset, 0, text.Length);
        string inserted = at > 0 && !char.IsWhiteSpace(text[at - 1]) ? " " + token : token;
        return new NamingInsertion(text.Insert(at, inserted), at + inserted.Length);
    }

    /// <summary>
    /// What is wrong with <paramref name="template"/>, in a few words: nothing typed, or the first token in
    /// braces it does not know; null when it is fine.
    /// </summary>
    public static string? Problem(string template)
    {
        if (string.IsNullOrWhiteSpace(template)) return EmptyProblem;
        foreach (string token in Braced(template))
        {
            if (!IsKnown(token)) return UnknownProblem(token);
        }
        return null;
    }

    /// <summary>Whether <paramref name="token"/> ("{date}", "{counter:3}") is one <see cref="NamingTemplate"/> replaces.</summary>
    public static bool IsKnown(string token)
    {
        if (Known.Contains(token)) return true;
        const string prefix = "{counter:";
        if (!token.StartsWith(prefix, StringComparison.Ordinal) || !token.EndsWith('}')) return false;
        string digits = token[prefix.Length..^1];
        return digits.Length > 0 && digits.All(char.IsAsciiDigit);
    }

    /// <summary>The parts of <paramref name="template"/> in braces, in order: "{" up to the next "}" with no "{" between.</summary>
    public static IReadOnlyList<string> Braced(string template)
    {
        var tokens = new List<string>();
        int start = -1;
        for (int i = 0; i < template.Length; i++)
        {
            char c = template[i];
            if (c == '{')
            {
                start = i;
            }
            else if (c == '}' && start >= 0)
            {
                tokens.Add(template[start..(i + 1)]);
                start = -1;
            }
        }
        return tokens;
    }

    /// <summary>
    /// The format a save of <paramref name="s"/> writes, for the file name's example: a PDF or an image for
    /// receipts, an image for photos, the queue's file for pages collected before saving, else the format.
    /// </summary>
    public static OutputFormat SavedFormat(ScanSettings s)
    {
        if (TaskCatalog.FlowOf(s) == TaskFlowKind.ReceiptSplit) return OutputFormats.PageFormat(s.Format);
        if (s.Intent == ScanIntent.Photo) return OutputFormats.ImageFormatOrJpeg(s.Format);
        return s.DocumentMultiPage ? OutputFormats.QueueFormat(s.Format) : s.Format;
    }

    /// <summary>
    /// The name the next file gets with <paramref name="template"/>: "Scan 2026-10-20 4.pdf", numbered
    /// <paramref name="counter"/>, dated <paramref name="date"/>, for the settings' task, with
    /// <paramref name="format"/>'s extension.
    /// </summary>
    public static string Example(string template, ScanSettings s, OutputFormat format, int counter, DateTime date)
    {
        string name = new NamingTemplate(template)
            .BaseFilename(new NamingContext(counter, date, s.Intent) { Task = TaskCatalog.Infer(s) });
        return $"{name}.{format.FileExtension()}";
    }
}
