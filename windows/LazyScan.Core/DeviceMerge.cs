using System.Text;
using System.Text.RegularExpressions;

namespace LazyScan.Core;

// Twin of Sources/LazyScanKit/Core/DeviceMerge.swift; the tests in DeviceMergeTests
// (both platforms) share one table of cases.

/// <summary>
/// One physical scanner: every entry the backends list for it, and the one the app connects
/// through. <paramref name="Key"/> identifies the scanner across runs (it keys the user's
/// connection choice) and is unique within one grouping.
/// </summary>
/// <param name="Members">All entries for the scanner, in the order the backends listed them.</param>
public sealed record DeviceGroup(string Key, ScannerInfo Primary, IReadOnlyList<ScannerInfo> Members);

/// <summary>
/// Merges the entries several backends list for the same scanner (WIA and TWAIN for one USB
/// scanner, WIA and eSCL for one network MFP, USB and Bonjour on macOS) into one
/// <see cref="DeviceGroup"/>, and picks the connection to use.
/// </summary>
public static class DeviceMerge
{
    /// <summary>Windows connection ranking, best first: WIA, then eSCL, then TWAIN.</summary>
    public static readonly IReadOnlyList<string> WindowsRanking = ["wia:WIA", "escl:Network", "wia:*", "twain:*"];

    /// <summary>macOS connection ranking, best first: USB, then Bonjour, then shared scanners.</summary>
    public static readonly IReadOnlyList<string> MacRanking = ["ic:USB", "ic:Network", "ic:Shared"];

    /// <summary>
    /// iPhone and iPad connection ranking, best first: the scanner's own network connection (eSCL),
    /// then a computer's scanner reached through the desktop companion. Windows never uses it.
    /// </summary>
    public static readonly IReadOnlyList<string> IosRanking = ["escl:Network", "companion:*"];

    /// <summary>Words that say how a device is reached, or what kind of thing it is, rather than which model it is.</summary>
    private static readonly HashSet<string> StopWords =
    [
        "wia", "twain", "tw", "driver", "scanner", "scan", "series", "usb", "network", "net", "wsd",
        "escl", "airscan", "ds", "x64", "x86", "64bit", "32bit", "inc", "corp", "corporation", "co", "ltd",
    ];

    private const RegexOptions Options = RegexOptions.CultureInvariant;

    /// <summary>Text in round, square or curly brackets: "(USB)", "[192.168.1.5]", "{TWAIN}".</summary>
    private static readonly Regex Bracketed = new(@"\([^()]*\)|\[[^\[\]]*\]|\{[^{}]*\}", Options);

    /// <summary>An IPv4 address, with an optional port.</summary>
    private static readonly Regex Ipv4 = new(@"(?<![0-9.])[0-9]{1,3}(?:\.[0-9]{1,3}){3}(?::[0-9]{1,5})?(?![0-9.])", Options);

    /// <summary>An IPv6 address (at least two colons), with an optional zone.</summary>
    private static readonly Regex Ipv6 = new(@"(?<![0-9a-z:])(?:[0-9a-f]{0,4}:){2,7}[0-9a-f]{0,4}(?:%[0-9a-z]+)?(?![0-9a-z:])", Options);

    /// <summary>"64-bit", "32 bit", "64bit": a driver build, not part of the model number.</summary>
    private static readonly Regex BitWidth = new(@"(?<![0-9a-z])(?:32|64)[ -]?bit(?![0-9a-z])", Options);

    /// <summary>
    /// The model words of a device name, normalized so the names different drivers give the
    /// same scanner compare equal: ASCII-lowercased; bracketed text, IP addresses and bit
    /// widths removed; split on everything but a–z and 0–9; vendor aliases mapped (Hewlett /
    /// Packard → hp, Seiko Epson → epson, Kodak Alaris → kodak); connection and filler words
    /// dropped; repeated words kept once. The words are joined by single spaces.
    /// </summary>
    public static string ModelKey(string name) => string.Join(' ', ModelTokens(name));

    private static List<string> ModelTokens(string name)
    {
        string text = AsciiLowercased(name);
        text = Bracketed.Replace(text, " ");
        text = Ipv4.Replace(text, " ");
        text = Ipv6.Replace(text, " ");
        text = BitWidth.Replace(text, " ");

        var raw = new List<string>();
        var word = new StringBuilder();
        foreach (char c in text)
        {
            if (c is >= 'a' and <= 'z' or >= '0' and <= '9')
            {
                word.Append(c);
            }
            else if (word.Length > 0)
            {
                raw.Add(word.ToString());
                word.Clear();
            }
        }
        if (word.Length > 0) raw.Add(word.ToString());

        var tokens = new List<string>();
        for (int i = 0; i < raw.Count; i++)
        {
            string token = raw[i];
            if (token is "hewlett" or "packard") token = "hp";
            else if (token == "seiko" && i + 1 < raw.Count && raw[i + 1] == "epson") continue;
            else if (token == "alaris" && i > 0 && raw[i - 1] == "kodak") continue;
            if (StopWords.Contains(token) || tokens.Contains(token)) continue;
            tokens.Add(token);
        }
        return tokens;
    }

    /// <summary>
    /// Whether two entries are the same physical scanner. Demo devices match nothing. Two
    /// entries from the same backend over the same transport never match, so two identical
    /// scanners stay apart. When both have a hardware id, the ids decide. Otherwise the model
    /// words (<see cref="ModelKey"/>) of the entries' model or name — any pairing of the two,
    /// since some drivers report a generic description and some names are user-chosen — must
    /// be equal, or one set must contain the other while sharing at least two words, one of
    /// them with a digit (the model number).
    /// </summary>
    public static bool SameDevice(ScannerInfo a, ScannerInfo b)
    {
        if (a.IsDemo || b.IsDemo) return false;
        if (AsciiLowercased(a.Backend) == AsciiLowercased(b.Backend)
            && AsciiLowercased(a.Transport) == AsciiLowercased(b.Transport))
        {
            return false;
        }
        string? idA = NormalizedHardwareId(a.HardwareId), idB = NormalizedHardwareId(b.HardwareId);
        if (idA is not null && idB is not null) return idA == idB;

        foreach (string nameA in NamesOf(a))
        {
            foreach (string nameB in NamesOf(b))
            {
                if (SameModelWords(ModelTokens(nameA), ModelTokens(nameB))) return true;
            }
        }
        return false;
    }

    private static bool SameModelWords(List<string> tokensA, List<string> tokensB)
    {
        var wordsA = tokensA.ToHashSet();
        var wordsB = tokensB.ToHashSet();
        if (wordsA.Count == 0 || wordsB.Count == 0) return false;
        if (wordsA.SetEquals(wordsB)) return true;
        if (!wordsA.IsSubsetOf(wordsB) && !wordsB.IsSubsetOf(wordsA)) return false;
        var shared = wordsA.Intersect(wordsB).ToList();
        return shared.Count >= 2 && shared.Any(HasDigit);
    }

    /// <summary>
    /// Groups the entries of all backends into one <see cref="DeviceGroup"/> per scanner, in
    /// the order the scanners first appear. An entry joins the first group whose every member
    /// is the <see cref="SameDevice"/>. The primary is the member whose connection
    /// (<see cref="ConnectionId"/>) <paramref name="overrides"/> names for the group's key,
    /// when that member is present; otherwise the member matching the earliest of
    /// <paramref name="rankPatterns"/> ("backend:transport", '*' matches any text, ASCII case
    /// ignored), the earliest listed among equals.
    /// </summary>
    /// <param name="overrides">The user's connection choice per group key.</param>
    public static IReadOnlyList<DeviceGroup> Group(IEnumerable<ScannerInfo> devices,
                                                   IReadOnlyList<string> rankPatterns,
                                                   IReadOnlyDictionary<string, string>? overrides = null)
    {
        var clusters = new List<List<ScannerInfo>>();
        foreach (var device in devices)
        {
            var cluster = clusters.FirstOrDefault(c => c.All(member => SameDevice(member, device)));
            if (cluster is null) clusters.Add([device]);
            else cluster.Add(device);
        }

        var groups = new List<DeviceGroup>();
        var usedKeys = new HashSet<string>();
        foreach (var members in clusters)
        {
            string baseKey = GroupKey(members);
            string key = baseKey;
            for (int n = 2; !usedKeys.Add(key); n++) key = $"{baseKey}#{n}";

            ScannerInfo? primary = null;
            if (overrides is not null && overrides.TryGetValue(key, out var chosen) && chosen is not null)
            {
                string wanted = AsciiLowercased(chosen);
                primary = members.FirstOrDefault(m => AsciiLowercased(ConnectionId(m)) == wanted);
            }
            primary ??= members.MinBy(m => Rank(m, rankPatterns))!;
            groups.Add(new DeviceGroup(key, primary, members));
        }
        return groups;
    }

    /// <summary>The connection an entry stands for: "backend:transport", e.g. "wia:WIA" or "escl:Network".</summary>
    public static string ConnectionId(ScannerInfo device) => $"{device.Backend}:{device.Transport}";

    /// <summary>A short name for an entry's connection, for the connection chooser.</summary>
    public static string ConnectionLabel(ScannerInfo device) => AsciiLowercased(device.Backend) switch
    {
        "wia" => "WIA",
        "twain" => "TWAIN",
        "escl" => "Network (eSCL)",
        "mock" => "Demo",
        _ => device.Transport,
    };

    /// <summary>
    /// The grouping spelled out, one line per group and one per member with the raw names and
    /// the model key each matched on, for a diagnostics file: real driver names show which
    /// aliases and stop words are still missing.
    /// </summary>
    public static string DiagnosticsReport(IReadOnlyList<DeviceGroup> groups)
    {
        var text = new StringBuilder();
        foreach (var group in groups)
        {
            text.Append($"{group.Key} -> {ConnectionId(group.Primary)} \"{group.Primary.Id}\"\n");
            foreach (var m in group.Members)
            {
                text.Append($"  {ConnectionId(m)} id=\"{m.Id}\" name=\"{m.Name}\" model=\"{m.Model ?? ""}\" "
                            + $"hardwareId=\"{m.HardwareId ?? ""}\" key=\"{ModelKey(MatchName(m))}\"\n");
            }
        }
        return text.ToString();
    }

    /// <summary>
    /// A key that stays the same while the scanner's set of connections changes: its hardware
    /// id when a member has one, otherwise the shortest model key among the members (the
    /// alphabetically first among equals), otherwise the first member's id. Demo devices are
    /// keyed by id.
    /// </summary>
    private static string GroupKey(List<ScannerInfo> members)
    {
        if (members.Any(m => m.IsDemo)) return "device:" + members[0].Id;
        foreach (var m in members)
        {
            if (NormalizedHardwareId(m.HardwareId) is { } id) return "id:" + id;
        }
        string? best = null;
        int bestCount = int.MaxValue;
        foreach (var m in members)
        {
            var tokens = ModelTokens(MatchName(m));
            if (tokens.Count == 0) continue;
            string key = string.Join(' ', tokens);
            if (tokens.Count < bestCount || (tokens.Count == bestCount && string.CompareOrdinal(key, best) < 0))
            {
                best = key;
                bestCount = tokens.Count;
            }
        }
        return best is not null ? "model:" + best : "device:" + members[0].Id;
    }

    private static int Rank(ScannerInfo device, IReadOnlyList<string> patterns)
    {
        string connection = ConnectionId(device);
        for (int i = 0; i < patterns.Count; i++)
        {
            if (GlobMatches(patterns[i], connection)) return i;
        }
        return patterns.Count;
    }

    /// <summary>'*' matches any run of characters, including none; other characters match themselves, ASCII case ignored.</summary>
    private static bool GlobMatches(string pattern, string text)
    {
        string p = AsciiLowercased(pattern), t = AsciiLowercased(text);
        int pi = 0, ti = 0, star = -1, mark = 0;
        while (ti < t.Length)
        {
            if (pi < p.Length && p[pi] == '*')
            {
                star = pi++;
                mark = ti;
            }
            else if (pi < p.Length && p[pi] == t[ti])
            {
                pi++;
                ti++;
            }
            else if (star >= 0)
            {
                pi = star + 1;
                ti = ++mark;
            }
            else
            {
                return false;
            }
        }
        while (pi < p.Length && p[pi] == '*') pi++;
        return pi == p.Length;
    }

    /// <summary>The text an entry is keyed on: its model when known, otherwise its name.</summary>
    private static string MatchName(ScannerInfo device) =>
        string.IsNullOrWhiteSpace(device.Model) ? device.Name : device.Model;

    /// <summary>The texts an entry is matched on: its model when known, then its name.</summary>
    private static List<string> NamesOf(ScannerInfo device) =>
        string.IsNullOrWhiteSpace(device.Model) ? [device.Name] : [device.Model, device.Name];

    /// <summary>A hardware id reduced to lowercase letters and digits ("urn:uuid:" dropped); null when there is none.</summary>
    private static string? NormalizedHardwareId(string? id)
    {
        if (id is null) return null;
        string text = AsciiLowercased(id.Trim());
        if (text.StartsWith("urn:uuid:", StringComparison.Ordinal)) text = text["urn:uuid:".Length..];
        var kept = new StringBuilder();
        foreach (char c in text)
        {
            if (c is >= 'a' and <= 'z' or >= '0' and <= '9') kept.Append(c);
        }
        return kept.Length > 0 ? kept.ToString() : null;
    }

    private static bool HasDigit(string token) => token.Any(c => c is >= '0' and <= '9');

    /// <summary>A–Z lowered to a–z; every other character unchanged (the same on every platform and culture).</summary>
    private static string AsciiLowercased(string text)
    {
        var chars = text.ToCharArray();
        for (int i = 0; i < chars.Length; i++)
        {
            if (chars[i] is >= 'A' and <= 'Z') chars[i] = (char)(chars[i] + 32);
        }
        return new string(chars);
    }
}
