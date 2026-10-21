using System.Text.RegularExpressions;

namespace CompleteScanner.Core;

// Port of Sources/CompleteScannerKit/Core/StatusLine.swift: the status line's short text. Both apps
// show at most six words of their status sentence, facts only, and keep the whole sentence as the
// line's accessible name.

/// <summary>
/// The status line's visible text: at most <see cref="MaxWords"/> words, facts only. The full
/// sentence stays the status line's accessible name, so screen readers hear all of it.
/// </summary>
public static class StatusLine
{
    public const int MaxWords = 6;

    private static readonly Regex WordToken = new(@"[\p{L}\p{N}]", RegexOptions.Compiled);

    /// <summary>Words as the text spec counts them: whitespace-separated tokens with a letter or digit.</summary>
    public static int Words(string text) =>
        text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Count(t => WordToken.IsMatch(t));

    /// <summary>
    /// The sentences <see cref="SettingsAdapter"/> adds when a setting had to change for the scanner,
    /// each with its short form: a warning stays visible, not only in the accessible name.
    /// </summary>
    private static readonly (Regex Note, string Short)[] SettingsNotes =
    [
        (new(@"This scanner has no flatbed, so the document feeder is used\."), "Feeder used"),
        (new(@"This scanner has no document feeder, so the flatbed is used\."), "Flatbed used"),
        (new(@"This scanner's feeder scans one side at a time, so you'll turn the stack over by hand\."), "Two-sided by hand"),
        (new($@"(?:{string.Join("|", Enum.GetValues<PaperSize>().Select(p => Regex.Escape(p.Label())))}) paper does not fit this scanner's (?:feeder|glass), so the paper size is Automatic\."),
         "Paper size Automatic"),
        (new(@"This scanner does not offer \d+ dpi, so (\d+) dpi is used\."), "$1 dpi used"),
    ];

    /// <summary>A two-sided scan came back with one side of each sheet.</summary>
    private const string OneSidedMark = "the scanner did not scan both sides";
    private const string OneSidedShort = "One side only";

    /// <param name="message">The app's status sentence.</param>
    /// <param name="deviceName">The connected scanner, for "Ready — Demo Scanner" after a task is picked.</param>
    /// <remarks>
    /// A setting changed for the scanner, or a two-sided scan that came back one-sided, keeps a short
    /// warning on the line ("Ready — Demo · feeder used", "3 pages added · one side only"); when the
    /// line can't hold both, the warnings win.
    /// </remarks>
    public static string Short(string message, string? deviceName = null)
    {
        string text = message.Trim();
        if (text.Length == 0) return "";
        var (shorts, notesAt) = FindWarnings(text);
        string head = notesAt > 0 ? Head(text[..notesAt].Trim(), deviceName) : "";
        return Compose(head, shorts);
    }

    /// <summary>
    /// <paramref name="head"/> with the short warnings found in <paramref name="message"/>, the same
    /// way <see cref="Short"/> adds them: "Saved · 600 dpi used", or the warnings alone when the line
    /// can't hold both; just <paramref name="head"/> when there are none.
    /// </summary>
    public static string WithWarnings(string head, string message) => Compose(head, Warnings(message));

    /// <summary>
    /// The short warnings in <paramref name="message"/>, in the order they come: a setting changed for
    /// the scanner ("600 dpi used"), a two-sided scan that came back one-sided ("One side only").
    /// </summary>
    public static IReadOnlyList<string> Warnings(string message) => FindWarnings(message.Trim()).Shorts;

    /// <summary>
    /// What the status line shows while the app is idle: nothing while a review shows its own title
    /// (<paramref name="reviewShown"/>), "Saved" with any warning while the saved files' bar shows
    /// (<paramref name="savedShown"/>, for a message about a save), else <see cref="Short"/>.
    /// </summary>
    public static string Shown(string message, string? deviceName, bool reviewShown, bool savedShown)
    {
        if (reviewShown) return "";
        if (savedShown && message.TrimStart().StartsWith("Saved", StringComparison.Ordinal)) return WithWarnings("Saved", message);
        return Short(message, deviceName);
    }

    /// <summary>The warnings in <paramref name="text"/>, and where the first settings note starts (the text's length when none does).</summary>
    private static (List<string> Shorts, int NotesAt) FindWarnings(string text)
    {
        // The notes are appended after the message: the message is what comes before the first one.
        var warnings = new List<(int At, string Short)>();
        int notesAt = text.Length;
        foreach (var (note, shortForm) in SettingsNotes)
        {
            foreach (Match m in note.Matches(text))
            {
                warnings.Add((m.Index, m.Result(shortForm)));
                notesAt = Math.Min(notesAt, m.Index);
            }
        }
        int oneSided = text.IndexOf(OneSidedMark, StringComparison.Ordinal);
        if (oneSided >= 0) warnings.Add((oneSided, OneSidedShort));
        return (warnings.OrderBy(w => w.At).Select(w => w.Short).ToList(), notesAt);
    }

    /// <summary>The head, then the warnings while they fit; when the line can't hold both, the warnings win.</summary>
    private static string Compose(string head, IReadOnlyList<string> shorts)
    {
        if (shorts.Count == 0) return head;
        if (head.Length > 0)
        {
            string all = string.Join(" · ", shorts.Select(LowerFirst).Prepend(head));
            if (Words(all) <= MaxWords) return all;
        }
        // Not room for the message too: the warnings alone, as many as fit, then how many more.
        string shown = shorts[0];
        int i = 1;
        while (i < shorts.Count)
        {
            string next = $"{shown} · {LowerFirst(shorts[i])}";
            // While more would follow, keep a word free for "+N".
            if (Words(next) > MaxWords - (i < shorts.Count - 1 ? 1 : 0)) break;
            shown = next;
            i++;
        }
        return i < shorts.Count ? $"{shown} +{shorts.Count - i}" : shown;
    }

    /// <summary>"Feeder used" after a message reads "… · feeder used"; "300 dpi used" stays as it is.</summary>
    private static string LowerFirst(string text) =>
        text.Length > 0 && char.IsUpper(text[0]) ? char.ToLowerInvariant(text[0]) + text[1..] : text;

    /// <summary>The short form of the message itself (without the notes after it).</summary>
    private static string Head(string text, string? deviceName)
    {
        if (text.Length == 0) return "";
        if (text.StartsWith("Ready for “", StringComparison.Ordinal))
        {
            return deviceName is { Length: > 0 } name ? $"Ready — {name}" : "Ready";
        }
        if (Regex.Match(text, @"^Added (\d+) (?:page|pages)\b") is { Success: true } added)
        {
            int count = int.Parse(added.Groups[1].Value, System.Globalization.CultureInfo.InvariantCulture);
            string head = count == 1 && Regex.Match(text, @"— (\d+) in queue") is { Success: true } queue
                ? $"Page {queue.Groups[1].Value} added"
                : $"{count} {(count == 1 ? "page" : "pages")} added";
            if (Regex.Match(text, @"(\d+) looks? blank") is { Success: true } blank)
            {
                head = Append(head, $"{blank.Groups[1].Value} blank");
            }
            if (Regex.Match(text, @"(\d+) (spreads?) split into pages") is { Success: true } spreads)
            {
                head = Append(head, $"{spreads.Groups[1].Value} {spreads.Groups[2].Value} split");
            }
            return head;
        }
        if (Regex.Match(text, @"^(?:Cancelled — )?Saved (\d+) (photos?|receipts?|documents?|files?|PDFs?|copies)\b",
                        RegexOptions.IgnoreCase) is { Success: true } savedMany)
        {
            return $"Saved {savedMany.Groups[1].Value} {savedMany.Groups[2].Value}";
        }
        if (text.StartsWith("Saved ", StringComparison.Ordinal)) return "Saved";
        if (Regex.Match(text, @"^Found (\d+) (photos?|receipts?)\b") is { Success: true } found)
        {
            return $"Found {found.Groups[1].Value} {found.Groups[2].Value}";
        }
        if (text.StartsWith("Page queue cleared", StringComparison.Ordinal)) return "Queue cleared";
        if (Regex.Match(text, @"^Reading the text of page (\d+)( of \d+)?…") is { Success: true } reading)
        {
            return $"Reading page {reading.Groups[1].Value}{reading.Groups[2].Value}…";
        }
        if (Regex.Match(text, @"^Adding (\d+) (pages?) to .+…$") is { Success: true } adding)
        {
            return $"Adding {adding.Groups[1].Value} {adding.Groups[2].Value}…";
        }
        if (text.StartsWith("Sent ", StringComparison.Ordinal)) return "Sent to the printer";

        // Anything else: its first sentence, then what comes before a dash or a colon, then its whole facts.
        string first = FirstSentence(text);
        if (Words(first) <= MaxWords) return first;
        foreach (string mark in new[] { " — ", ": ", ", " })
        {
            int at = first.IndexOf(mark, StringComparison.Ordinal);
            if (at > 0 && Words(first[..at]) <= MaxWords) return first[..at];
        }
        // Facts joined by " · " ("9 pages · 3 documents · 2 separator pages skipped"): the whole facts that fit.
        var facts = first.Split(" · ");
        if (facts.Length > 1 && Words(facts[0]) <= MaxWords)
        {
            string shown = facts[0];
            for (int i = 1; i < facts.Length && Words($"{shown} · {facts[i]}") <= MaxWords; i++)
            {
                shown = $"{shown} · {facts[i]}";
            }
            return shown;
        }
        var tokens = first.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        var kept = new List<string>();
        int words = 0;
        foreach (var token in tokens)
        {
            if (WordToken.IsMatch(token) && ++words > MaxWords) break;
            kept.Add(token);
        }
        return string.Join(' ', kept).TrimEnd(',', ':', ';', '.', ' ') + "…";
    }

    /// <summary>"6 pages added · 1 blank", while the words stay within the limit.</summary>
    private static string Append(string head, string part)
    {
        string joined = $"{head} · {part}";
        return Words(joined) <= MaxWords ? joined : head;
    }

    /// <summary>The first sentence without its full stop ("…" is kept: it says work is under way).</summary>
    private static string FirstSentence(string text)
    {
        for (int i = 0; i < text.Length - 2; i++)
        {
            if (text[i] is '.' or '!' or '?' && text[i + 1] == ' ' && (char.IsUpper(text[i + 2]) || char.IsDigit(text[i + 2])))
            {
                return text[..i];
            }
        }
        return text.EndsWith('.') && !text.EndsWith("…", StringComparison.Ordinal) ? text[..^1] : text;
    }
}
