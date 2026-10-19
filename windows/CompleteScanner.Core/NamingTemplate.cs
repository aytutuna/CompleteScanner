using System.Globalization;
using System.Text;
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
    /// Same as <see cref="BaseFilename(NamingContext)"/> without a task or document date.
    /// </summary>
    public string BaseFilename(int counter, DateTime date, ScanIntent intent, int? index) =>
        BaseFilename(new NamingContext(counter, date, intent) { Index = index });

    /// <summary>
    /// The file name (without extension) for <paramref name="context"/>: the tokens of
    /// <see cref="BaseFilename(int, DateTime, ScanIntent, int?)"/>, plus {task} (the task's
    /// <see cref="TaskDefinition.FileLabel"/>, or the {intent} text when there is no task) and
    /// {docdate} (the date printed on the document, yyyy-MM-dd, read from its text; the scan date
    /// when there is none) and {label} (the document's name, cut to <see cref="MaxLabelBytes"/> and
    /// sanitized like the rest; empty when it has none).
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
            ("{docdate}", (context.DocumentDate ?? Core.DocumentDate.Of(date)).ToString()),
            ("{label}", CutToBytes(context.Label?.Trim() ?? "", MaxLabelBytes)),
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

    /// <summary>
    /// The most UTF-8 bytes {label} adds to a file name: a long document name is cut (between
    /// characters), so the name stays well within the 255 a file name can have on Windows and the Mac.
    /// </summary>
    public const int MaxLabelBytes = 120;

    /// <summary>The first characters of <paramref name="text"/> that fit in <paramref name="maxBytes"/> bytes of UTF-8; never cuts inside a character.</summary>
    internal static string CutToBytes(string text, int maxBytes)
    {
        if (Encoding.UTF8.GetByteCount(text) <= maxBytes) return text;
        var result = new StringBuilder();
        int bytes = 0;
        var elements = StringInfo.GetTextElementEnumerator(text);
        while (elements.MoveNext())
        {
            string element = elements.GetTextElement();
            int size = Encoding.UTF8.GetByteCount(element);
            if (bytes + size > maxBytes) break;
            bytes += size;
            result.Append(element);
        }
        return result.ToString().TrimEnd();
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

    /// <summary>
    /// The date printed on the document for {docdate} (a receipt's date, read from its text by
    /// <see cref="ReceiptDateExtractor"/>); null gives the date of <see cref="Date"/>.
    /// </summary>
    public DocumentDate? DocumentDate { get; init; }

    /// <summary>
    /// The document's name for {label}: given to it in the page strip when the queue is split into
    /// documents (<see cref="SaveDocument.Label"/>); null gives an empty text.
    /// </summary>
    public string? Label { get; init; }
}

/// <summary>
/// A calendar day with no time and no time zone: the date printed on a document. Twin of the
/// Swift <c>DocumentDate</c> in NamingTemplate.swift.
/// </summary>
/// <param name="Year">The year, 1 to 9999.</param>
/// <param name="Month">The month, 1 to 12.</param>
/// <param name="Day">The day of the month, 1 to its last day.</param>
public readonly record struct DocumentDate(int Year, int Month, int Day) : IComparable<DocumentDate>
{
    /// <summary>The day of <paramref name="date"/> as its calendar shows it (the Gregorian calendar, its own time zone).</summary>
    public static DocumentDate Of(DateTime date) => new(date.Year, date.Month, date.Day);

    /// <summary>The day when it exists in the Gregorian calendar (years 1 to 9999), else null.</summary>
    public static DocumentDate? TryCreate(int year, int month, int day) =>
        IsValid(year, month, day) ? new DocumentDate(year, month, day) : null;

    /// <summary>Whether the day exists: a month of 1 to 12 and a day up to its last, leap years included.</summary>
    public static bool IsValid(int year, int month, int day) =>
        year is >= 1 and <= 9999 && month is >= 1 and <= 12 && day >= 1 && day <= DaysInMonth(year, month);

    /// <summary>The days of <paramref name="month"/> in <paramref name="year"/> (Gregorian leap years).</summary>
    public static int DaysInMonth(int year, int month) => month switch
    {
        2 => year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) ? 29 : 28,
        4 or 6 or 9 or 11 => 30,
        _ => 31,
    };

    /// <summary>Days since 1970-01-01 (negative before it), for counting days between dates.</summary>
    public int DayNumber
    {
        get
        {
            // Days from civil (H. Hinnant's algorithm), integer arithmetic only.
            int y = Month <= 2 ? Year - 1 : Year;
            int era = (y >= 0 ? y : y - 399) / 400;
            int yoe = y - era * 400;
            int mp = (Month + 9) % 12;
            int doy = (153 * mp + 2) / 5 + Day - 1;
            int doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
            return era * 146097 + doe - 719468;
        }
    }

    /// <summary>The same day <paramref name="years"/> years later (earlier when negative); 29 February becomes the 28th in a common year.</summary>
    public DocumentDate AddingYears(int years)
    {
        int year = Year + years;
        return new DocumentDate(year, Month, Math.Min(Day, DaysInMonth(year, Month)));
    }

    public int CompareTo(DocumentDate other) =>
        Year != other.Year ? Year.CompareTo(other.Year)
        : Month != other.Month ? Month.CompareTo(other.Month)
        : Day.CompareTo(other.Day);

    public static bool operator <(DocumentDate a, DocumentDate b) => a.CompareTo(b) < 0;
    public static bool operator >(DocumentDate a, DocumentDate b) => a.CompareTo(b) > 0;
    public static bool operator <=(DocumentDate a, DocumentDate b) => a.CompareTo(b) <= 0;
    public static bool operator >=(DocumentDate a, DocumentDate b) => a.CompareTo(b) >= 0;

    /// <summary>"2026-03-12": the form file names use.</summary>
    public override string ToString() =>
        string.Create(CultureInfo.InvariantCulture, $"{Year:D4}-{Month:D2}-{Day:D2}");
}
