using System.Security.Cryptography;
using System.Text;

namespace CompleteScanner.Core;

// Twin of Sources/CompleteScannerKit/Companion/PairedDeviceStore.swift: the same rules for pairing,
// checking and removing phones; each platform keeps its own file in its own settings folder.

/// <summary>A phone paired with this desktop (an entry of companion-devices.json).</summary>
public sealed class PairedDevice
{
    /// <summary>The phone's id (<see cref="CompanionProtocol.IsValidId"/>), sent with every request.</summary>
    public string Id { get; set; } = "";
    /// <summary>The phone's name as it gave it when pairing ("Aytu's iPhone").</summary>
    public string Name { get; set; } = "";
    /// <summary>"ios", "ipados", "android"…, as the phone said.</summary>
    public string Platform { get; set; } = "";
    public string AppVersion { get; set; } = "";
    /// <summary>
    /// SHA-256 of the phone's secret, lowercase hex (<see cref="PairedDeviceStore.HashSecret"/>).
    /// The secret itself is never stored: a copy of this file does not let anyone pose as the phone.
    /// </summary>
    public string SecretHash { get; set; } = "";
    public DateTimeOffset? Paired { get; set; }
    /// <summary>When the phone last made a request, to the minute.</summary>
    public DateTimeOffset? LastSeen { get; set; }

    internal PairedDevice Copy() => new()
    {
        Id = Id,
        Name = Name,
        Platform = Platform,
        AppVersion = AppVersion,
        SecretHash = SecretHash,
        Paired = Paired,
        LastSeen = LastSeen,
    };
}

/// <summary>The contents of companion-devices.json.</summary>
public sealed class PairedDevicesFile
{
    /// <summary>This desktop's id for phones (32 hex digits), made on first use.</summary>
    public string DesktopId { get; set; } = "";
    public List<PairedDevice> Devices { get; set; } = [];
}

/// <summary>
/// The phones paired with this desktop (companion-devices.json in the settings folder, rule 6 of
/// CONTRACTS.md). Pairing makes a random 256-bit secret, hands it to the phone once and keeps only
/// its SHA-256; a request is accepted when its device id and secret match an entry. The file is
/// re-read for every check and before every change, so a phone removed by another window of the
/// app is refused at once; a phone removed while the file could not be written stays removed for
/// the rest of the session. Safe to use from any thread.
/// </summary>
public sealed class PairedDeviceStore
{
    public const string FileName = "companion-devices.json";
    /// <summary>The secret's length in bytes.</summary>
    public const int SecretByteCount = 32;
    /// <summary>How many phones can be paired at once.</summary>
    public const int MaxDevices = 16;
    /// <summary>A phone's last-seen time is written at most this often.</summary>
    public static readonly TimeSpan LastSeenResolution = TimeSpan.FromMinutes(1);

    private readonly string _path;
    private readonly object _gate = new();
    private PairedDevicesFile _file;
    /// <summary>Phones removed in this session: never accepted again, whatever the file says.</summary>
    private readonly HashSet<string> _removed = [];

    public PairedDeviceStore() : this(StoreFiles.DefaultDirectory) { }

    /// <summary>Keeps companion-devices.json in <paramref name="directory"/> (tests, harnesses).</summary>
    public PairedDeviceStore(string directory)
    {
        _path = Path.Combine(directory, FileName);
        _file = StoreFiles.Load<PairedDevicesFile>(_path) ?? new PairedDevicesFile();
    }

    /// <summary>Raised after a phone was paired or removed (on the thread that changed it).</summary>
    public event EventHandler? Changed;

    /// <summary>This desktop's id; made and saved the first time it is asked for.</summary>
    public string DesktopId
    {
        get
        {
            lock (_gate)
            {
                Reload();
                if (!CompanionProtocol.IsValidId(_file.DesktopId))
                {
                    _file.DesktopId = Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(16));
                    StoreFiles.Write(_file, _path);
                }
                return _file.DesktopId;
            }
        }
    }

    /// <summary>The paired phones (copies), in the order they were paired.</summary>
    public IReadOnlyList<PairedDevice> Devices
    {
        get
        {
            lock (_gate)
            {
                Reload();
                return [.. _file.Devices.Select(d => d.Copy())];
            }
        }
    }

    public int Count
    {
        get
        {
            lock (_gate)
            {
                Reload();
                return _file.Devices.Count;
            }
        }
    }

    /// <summary>
    /// Pairs the phone <paramref name="id"/> (pairing again replaces its entry and secret) and
    /// returns its new secret (base64url of 32 bytes), to be sent to the phone once. Throws
    /// <see cref="InvalidOperationException"/> when <see cref="MaxDevices"/> other phones are
    /// paired, <see cref="ArgumentException"/> for an invalid id, and <see cref="IOException"/>
    /// when the pairing cannot be saved (a phone must not believe it is paired when it is not).
    /// </summary>
    public string Pair(string id, string name, string platform, string appVersion, DateTimeOffset now) =>
        Pair(id, name, platform, appVersion, now, RandomNumberGenerator.GetBytes(SecretByteCount));

    /// <summary>Same as <see cref="Pair(string, string, string, string, DateTimeOffset)"/> with a given secret (tests).</summary>
    internal string Pair(string id, string name, string platform, string appVersion, DateTimeOffset now, byte[] secret)
    {
        if (!CompanionProtocol.IsValidId(id)) throw new ArgumentException("The phone's id is not valid.", nameof(id));
        if (secret.Length != SecretByteCount) throw new ArgumentException("A device secret has 32 bytes.", nameof(secret));
        lock (_gate)
        {
            Reload();
            var others = _file.Devices.Where(d => d.Id != id).ToList();
            if (others.Count >= MaxDevices) throw new InvalidOperationException("Too many phones are paired.");
            var device = new PairedDevice
            {
                Id = id,
                Name = CleanName(name),
                Platform = CleanName(platform),
                AppVersion = CleanName(appVersion),
                SecretHash = HashSecret(secret),
                Paired = now,
                LastSeen = now,
            };
            var previous = _file.Devices;
            _file.Devices = [.. others, device];
            if (!StoreFiles.Write(_file, _path))
            {
                _file.Devices = previous;
                throw new IOException("The pairing could not be saved.");
            }
            _removed.Remove(id);
        }
        Changed?.Invoke(this, EventArgs.Empty);
        return CompanionProtocol.EncodeBase64Url(secret);
    }

    /// <summary>
    /// The paired phone <paramref name="id"/> when <paramref name="secret"/> is its secret (compared
    /// in constant time); null otherwise. Records when it was last seen.
    /// </summary>
    public PairedDevice? Authenticate(string? id, string? secret, DateTimeOffset now)
    {
        if (!CompanionProtocol.IsValidId(id) || CompanionProtocol.DecodeBase64Url(secret) is not { Length: SecretByteCount } bytes)
        {
            return null;
        }
        byte[] presented = Convert.FromHexString(HashSecret(bytes));
        lock (_gate)
        {
            Reload();
            if (_removed.Contains(id!)) return null;
            var device = _file.Devices.FirstOrDefault(d => d.Id == id);
            if (device is null || device.SecretHash.Length != 64 || !IsHex(device.SecretHash)) return null;
            if (!CryptographicOperations.FixedTimeEquals(presented, Convert.FromHexString(device.SecretHash))) return null;
            if (device.LastSeen is not { } seen || now - seen >= LastSeenResolution || now < seen)
            {
                device.LastSeen = now;
                StoreFiles.Write(_file, _path);
            }
            return device.Copy();
        }
    }

    /// <summary>Unpairs the phone <paramref name="id"/>; it is refused from now on. False when it was not paired.</summary>
    public bool Remove(string id)
    {
        bool removed;
        lock (_gate)
        {
            Reload();
            _removed.Add(id);
            removed = _file.Devices.RemoveAll(d => d.Id == id) > 0;
            if (removed) StoreFiles.Write(_file, _path);
        }
        if (removed) Changed?.Invoke(this, EventArgs.Empty);
        return removed;
    }

    /// <summary>Unpairs every phone; returns how many were paired.</summary>
    public int RemoveAll()
    {
        int count;
        lock (_gate)
        {
            Reload();
            count = _file.Devices.Count;
            foreach (var device in _file.Devices) _removed.Add(device.Id);
            _file.Devices = [];
            StoreFiles.Write(_file, _path);
        }
        if (count > 0) Changed?.Invoke(this, EventArgs.Empty);
        return count;
    }

    /// <summary>SHA-256 of a device secret's bytes, lowercase hex.</summary>
    public static string HashSecret(ReadOnlySpan<byte> secret) => Convert.ToHexStringLower(SHA256.HashData(secret));

    /// <summary>A name as kept: control characters removed, trimmed, cut to <see cref="PairRequest.MaxNameBytes"/> UTF-8 bytes.</summary>
    public static string CleanName(string? name)
    {
        var text = new StringBuilder();
        int bytes = 0;
        foreach (var rune in (name ?? "").EnumerateRunes())
        {
            if (rune.Value < 0x20 || rune.Value is >= 0x7F and <= 0x9F) continue;
            if (bytes + rune.Utf8SequenceLength > PairRequest.MaxNameBytes) break;
            bytes += rune.Utf8SequenceLength;
            text.Append(rune.ToString());
        }
        return text.ToString().Trim();
    }

    /// <summary>Re-reads the file (under <see cref="_gate"/>); an unreadable one keeps what was loaded.</summary>
    private void Reload()
    {
        var file = StoreFiles.Load<PairedDevicesFile>(_path) ?? _file;
        if (file != _file && !CompanionProtocol.IsValidId(file.DesktopId) && CompanionProtocol.IsValidId(_file.DesktopId))
        {
            file.DesktopId = _file.DesktopId;
        }
        _file = file;
    }

    private static bool IsHex(string text) => text.All(c => c is >= '0' and <= '9' or >= 'a' and <= 'f');
}
