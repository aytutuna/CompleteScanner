namespace CompleteScanner.Core;

/// <summary>
/// The network scanners added by address: %APPDATA%\CompleteScanner\escl-hosts.json, a JSON
/// list of address strings (["192.168.1.50", "scanner.local:8080", "https://10.0.0.7"]). The
/// "Add scanner by address" dialog writes it, and entries written by hand keep working.
/// Entries that do not parse as an address are kept but not used. The file follows the
/// settings-file rules (CONTRACTS.md, rule 6): a file that does not decode is kept aside as
/// escl-hosts.unreadable-&lt;timestamp&gt;.json, one that cannot be read is never overwritten.
/// </summary>
public sealed class EsclHostList
{
    public EsclHostList() : this(StoreFiles.DefaultDirectory) { }

    /// <summary>Keeps escl-hosts.json in <paramref name="directory"/> instead of %APPDATA% (tests, harnesses).</summary>
    public EsclHostList(string directory)
    {
        FilePath = Path.Combine(directory, "escl-hosts.json");
    }

    public string FilePath { get; }

    /// <summary>The entries as written, in order; empty when there is no file or it could not be loaded.</summary>
    public List<string> LoadEntries() => StoreFiles.Load<List<string>>(FilePath) ?? [];

    /// <summary>The usable addresses, in order, without duplicates.</summary>
    public List<ScannerAddress> Load()
    {
        var addresses = new List<ScannerAddress>();
        foreach (string entry in LoadEntries())
        {
            if (ScannerAddress.TryParse(entry, out var address, out _) && !addresses.Contains(address!))
            {
                addresses.Add(address!);
            }
        }
        return addresses;
    }

    /// <summary>Adds <paramref name="address"/> in its canonical form; false when it is already listed.</summary>
    public bool Add(ScannerAddress address)
    {
        var entries = LoadEntries();
        if (entries.Any(e => Matches(e, address))) return false;
        entries.Add(address.ToString());
        StoreFiles.Write(entries, FilePath);
        return true;
    }

    /// <summary>Removes every entry meaning <paramref name="address"/>; false when none did.</summary>
    public bool Remove(ScannerAddress address)
    {
        var entries = LoadEntries();
        if (entries.RemoveAll(e => Matches(e, address)) == 0) return false;
        StoreFiles.Write(entries, FilePath);
        return true;
    }

    private static bool Matches(string entry, ScannerAddress address) =>
        ScannerAddress.TryParse(entry, out var parsed, out _) && parsed!.Equals(address);
}
