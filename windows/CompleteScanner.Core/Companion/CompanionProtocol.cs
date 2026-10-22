using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace CompleteScanner.Core;

// Twin of Sources/CompleteScannerKit/Companion/CompanionProtocol.swift: the same constants, the same
// JSON bytes for the same message and the same lenient reading, so the phone (Swift) and the
// desktop (C# now, Swift on the Mac later) speak exactly one protocol.

/// <summary>
/// The companion link between a paired phone and the desktop app: HTTP/1.1 over TLS, the phone
/// always starting the connection. The desktop's certificate is pinned by its
/// <see cref="SpkiFingerprint"/> from the pairing code; every request after pairing carries the
/// phone's device secret as a bearer token with its id. Endpoints (all JSON unless noted):
/// <list type="bullet">
/// <item><c>GET /v1/health</c>: reachability, answered to anyone (<see cref="HealthResponse"/>; with
/// credentials it also says whether the phone is still paired, a wrong secret gets 401).</item>
/// <item><c>POST /v1/pair</c>: the one call an unpaired phone may make, with the pairing code's token
/// (<see cref="PairRequest"/> → <see cref="PairResponse"/>).</item>
/// <item><c>GET /v1/hello</c>: the desktop's name, its queue and its upload limit (<see cref="HelloResponse"/>).</item>
/// <item><c>PUT /v1/inbox/{packageId}</c>: a <c>.csdoc</c> package (<see cref="CompanionPackage"/>),
/// idempotent by package id (<see cref="InboxResponse"/>); <c>X-Target: new|current</c>.</item>
/// <item><c>GET /v1/outbox[?wait=seconds]</c>, <c>GET /v1/outbox/{id}</c> (the file),
/// <c>DELETE /v1/outbox/{id}</c>: what the desktop sends the phone (<see cref="OutboxList"/>).</item>
/// <item><c>DELETE /v1/devices/self</c>: the phone forgets this desktop.</item>
/// </list>
/// Errors are <see cref="CompanionError"/> with a stable code (<see cref="CompanionErrorCode"/>).
/// </summary>
public static class CompanionProtocol
{
    /// <summary>The protocol version, in the pairing code and every response.</summary>
    public const int Version = 1;
    /// <summary>The DNS-SD service type the desktop advertises while it receives.</summary>
    public const string ServiceType = "_completescan._tcp";
    /// <summary>The <c>service</c> value of <see cref="HealthResponse"/>.</summary>
    public const string ServiceName = "completescanner";
    /// <summary>The port the desktop tries first; another free one is used when it is taken.</summary>
    public const int DefaultPort = 52731;

    public const string HealthPath = "/v1/health";
    public const string PairPath = "/v1/pair";
    public const string HelloPath = "/v1/hello";
    /// <summary>Followed by the package id.</summary>
    public const string InboxPrefix = "/v1/inbox/";
    public const string OutboxPath = "/v1/outbox";
    /// <summary>Followed by the outbox item's id.</summary>
    public const string OutboxPrefix = "/v1/outbox/";
    public const string DeviceSelfPath = "/v1/devices/self";

    /// <summary>The phone's id, sent with its secret on every request after pairing.</summary>
    public const string DeviceIdHeader = "X-Device-Id";
    /// <summary>Where an upload goes: <c>new</c> (a document of its own, the default) or <c>current</c>.</summary>
    public const string TargetHeader = "X-Target";
    public const string JsonContentType = "application/json; charset=utf-8";
    public const string PackageContentType = "application/vnd.completescanner.document";

    /// <summary>The largest JSON request body (a pairing request).</summary>
    public const int MaxJsonBodyBytes = 8192;
    /// <summary>The longest an outbox listing waits for something to arrive.</summary>
    public const int MaxOutboxWaitSeconds = 25;
    /// <summary>The DNS-SD TXT keys: the protocol version and the desktop's id.</summary>
    public const string TxtVersionKey = "v";
    public const string TxtIdKey = "id";

    /// <summary>
    /// The largest upload: a package's pictures may hold <see cref="ZipReadLimits.MaxTotalBytes"/>,
    /// plus room for its manifest and zip headers.
    /// </summary>
    public static long MaxUploadBytes => ZipReadLimits.Standard.MaxTotalBytes + 16L * 1024 * 1024;

    /// <summary>The page strip's label of a page that came from a paired phone.</summary>
    public const string PageLabel = "From phone";
    public const string PageLabelHelp = "Sent from a paired phone";

    /// <summary>
    /// Whether <paramref name="id"/> can be a phone's, desktop's, package's or outbox item's id:
    /// 8 to 64 characters, letters, digits, '-' and '_' (safe as a file name everywhere).
    /// </summary>
    public static bool IsValidId(string? id)
    {
        if (id is null || id.Length < 8 || id.Length > 64) return false;
        foreach (char c in id)
        {
            if (!(c is >= 'a' and <= 'z' or >= 'A' and <= 'Z' or >= '0' and <= '9' or '-' or '_')) return false;
        }
        return true;
    }

    /// <summary>Base64url without padding (RFC 4648 section 5).</summary>
    public static string EncodeBase64Url(ReadOnlySpan<byte> data)
    {
        const string alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
        var text = new StringBuilder((data.Length * 4 + 2) / 3);
        int i = 0;
        for (; i + 3 <= data.Length; i += 3)
        {
            int block = (data[i] << 16) | (data[i + 1] << 8) | data[i + 2];
            text.Append(alphabet[(block >> 18) & 63]).Append(alphabet[(block >> 12) & 63])
                .Append(alphabet[(block >> 6) & 63]).Append(alphabet[block & 63]);
        }
        int rest = data.Length - i;
        if (rest == 1)
        {
            int block = data[i] << 16;
            text.Append(alphabet[(block >> 18) & 63]).Append(alphabet[(block >> 12) & 63]);
        }
        else if (rest == 2)
        {
            int block = (data[i] << 16) | (data[i + 1] << 8);
            text.Append(alphabet[(block >> 18) & 63]).Append(alphabet[(block >> 12) & 63]).Append(alphabet[(block >> 6) & 63]);
        }
        return text.ToString();
    }

    /// <summary>
    /// The bytes of base64url text without padding; null for anything else: padding, other
    /// characters, a length no encoding has, or unused bits that are not zero (so every value has
    /// exactly one text).
    /// </summary>
    public static byte[]? DecodeBase64Url(string? text)
    {
        if (text is null || text.Length % 4 == 1) return null;
        var bytes = new byte[text.Length * 3 / 4];
        int bits = 0, bitCount = 0, count = 0;
        foreach (char c in text)
        {
            int value = c switch
            {
                >= 'A' and <= 'Z' => c - 'A',
                >= 'a' and <= 'z' => c - 'a' + 26,
                >= '0' and <= '9' => c - '0' + 52,
                '-' => 62,
                '_' => 63,
                _ => -1,
            };
            if (value < 0) return null;
            bits = (bits << 6) | value;
            bitCount += 6;
            if (bitCount >= 8)
            {
                bitCount -= 8;
                bytes[count++] = (byte)(bits >> bitCount);
                bits &= (1 << bitCount) - 1;
            }
        }
        if (bits != 0) return null;
        return count == bytes.Length ? bytes : bytes[..count];
    }

    /// <summary>The target an <c>X-Target</c> value names; <see cref="CompanionTarget.New"/> when missing or unknown.</summary>
    public static CompanionTarget Target(string? value) =>
        string.Equals(value?.Trim(), "current", StringComparison.OrdinalIgnoreCase) ? CompanionTarget.Current : CompanionTarget.New;

    /// <summary>The <c>X-Target</c> value for <paramref name="target"/>.</summary>
    public static string TargetValue(CompanionTarget target) => target == CompanionTarget.Current ? "current" : "new";

    /// <summary>"3 pages from Aytu's iPhone added to the queue."</summary>
    public static string AddedMessage(int pageCount, string phoneName) =>
        $"{(pageCount == 1 ? "1 page" : $"{pageCount} pages")} from {phoneName} added to the queue.";

    /// <summary>A JSON body as UTF-8 bytes.</summary>
    internal static byte[] Utf8(string json) => Encoding.UTF8.GetBytes(json);

    /// <summary>
    /// <paramref name="json"/> read as <typeparamref name="T"/> the way settings files are read
    /// (every property on its own, defaults for anything missing or wrong-typed); null when it is
    /// not a JSON object.
    /// </summary>
    internal static T? Decode<T>(ReadOnlySpan<byte> json) where T : class
    {
        try
        {
            return StoreFiles.Decode<T>(json);
        }
        catch (Exception error) when (error is JsonException or InvalidOperationException or NotSupportedException
                                      or ArgumentException or DecoderFallbackException)
        {
            return null;
        }
    }

    internal static string Integer(long value) => value.ToString(CultureInfo.InvariantCulture);

    internal static string Bool(bool value) => value ? "true" : "false";
}

/// <summary>Where an upload goes on the desktop.</summary>
public enum CompanionTarget
{
    /// <summary>The pages are added to the queue as a document of their own.</summary>
    New,
    /// <summary>The pages are added to the document the desktop has open (its queue).</summary>
    Current,
}

/// <summary>The stable error codes of <see cref="CompanionError"/>.</summary>
public static class CompanionErrorCode
{
    public const string Unauthorized = "unauthorized";
    public const string PairingClosed = "pairingClosed";
    public const string TokenInvalid = "tokenInvalid";
    public const string TokenExpired = "tokenExpired";
    public const string TokenUsed = "tokenUsed";
    public const string Declined = "declined";
    public const string TooManyDevices = "tooManyDevices";
    public const string TooLarge = "tooLarge";
    public const string InvalidPackage = "invalidPackage";
    public const string RateLimited = "rateLimited";
    public const string NotFound = "notFound";
    public const string MethodNotAllowed = "methodNotAllowed";
    public const string BadRequest = "badRequest";
    public const string LengthRequired = "lengthRequired";
    public const string Busy = "busy";
    public const string ServerError = "serverError";
}

/// <summary>What went wrong, for the phone: a stable <paramref name="Code"/> and a sentence to show.</summary>
public sealed record CompanionError(string Code, string Message)
{
    public string ToJson() =>
        $"{{\"error\":{CompanionPackage.Quote(Code)},\"message\":{CompanionPackage.Quote(Message)}}}";

    public static CompanionError? FromJson(ReadOnlySpan<byte> json) =>
        CompanionProtocol.Decode<Dto>(json) is { } dto && dto.Error.Length > 0 ? new CompanionError(dto.Error, dto.Message) : null;

    public static CompanionError Unauthorized { get; } =
        new(CompanionErrorCode.Unauthorized, "This computer no longer recognizes this phone. Pair it again.");
    public static CompanionError PairingClosed { get; } =
        new(CompanionErrorCode.PairingClosed, "Pairing is not open on this computer. Choose Pair a phone there and scan the new code.");
    public static CompanionError TokenInvalid { get; } =
        new(CompanionErrorCode.TokenInvalid, "This pairing code is not valid. Scan the code shown on the computer again.");
    public static CompanionError TokenExpired { get; } =
        new(CompanionErrorCode.TokenExpired, "This pairing code has expired. Show a new code on the computer.");
    public static CompanionError TokenUsed { get; } =
        new(CompanionErrorCode.TokenUsed, "This pairing code was already used. Show a new code on the computer.");
    public static CompanionError Declined { get; } =
        new(CompanionErrorCode.Declined, "Pairing was declined on the computer.");
    public static CompanionError TooManyDevices { get; } =
        new(CompanionErrorCode.TooManyDevices,
            $"This computer is paired with {PairedDeviceStore.MaxDevices} phones already. Remove one there first.");
    public static CompanionError TooLarge { get; } =
        new(CompanionErrorCode.TooLarge, "This document is too large to send in one piece.");
    public static CompanionError RateLimited { get; } =
        new(CompanionErrorCode.RateLimited, "Too many attempts. Wait a minute, then try again.");
    public static CompanionError NotFound { get; } = new(CompanionErrorCode.NotFound, "Not found.");
    public static CompanionError MethodNotAllowed { get; } =
        new(CompanionErrorCode.MethodNotAllowed, "This address does not take that request.");
    public static CompanionError BadRequest { get; } = new(CompanionErrorCode.BadRequest, "The request was not understood.");
    public static CompanionError LengthRequired { get; } =
        new(CompanionErrorCode.LengthRequired, "The request must say how long it is (Content-Length).");
    public static CompanionError Busy { get; } =
        new(CompanionErrorCode.Busy, "This document is still being received. Try again in a moment.");
    public static CompanionError ServerError { get; } =
        new(CompanionErrorCode.ServerError, "The computer could not store this document.");

    private sealed class Dto
    {
        public string Error { get; set; } = "";
        public string Message { get; set; } = "";
    }
}

/// <summary>The body of <c>POST /v1/pair</c>: the pairing code's token and who the phone is.</summary>
public sealed record PairRequest(string Token, string PhoneId, string PhoneName, string Platform, string AppVersion)
{
    public string ToJson() =>
        $"{{\"token\":{CompanionPackage.Quote(Token)},\"phoneId\":{CompanionPackage.Quote(PhoneId)}"
        + $",\"phoneName\":{CompanionPackage.Quote(PhoneName)},\"platform\":{CompanionPackage.Quote(Platform)}"
        + $",\"appVersion\":{CompanionPackage.Quote(AppVersion)}}}";

    public static PairRequest? FromJson(ReadOnlySpan<byte> json) =>
        CompanionProtocol.Decode<Dto>(json) is { } dto
            ? new PairRequest(dto.Token, dto.PhoneId, dto.PhoneName, dto.Platform, dto.AppVersion)
            : null;

    /// <summary>The longest phone name kept, in UTF-8 bytes (longer names are cut).</summary>
    public const int MaxNameBytes = 128;

    private sealed class Dto
    {
        public string Token { get; set; } = "";
        public string PhoneId { get; set; } = "";
        public string PhoneName { get; set; } = "";
        public string Platform { get; set; } = "";
        public string AppVersion { get; set; } = "";
    }
}

/// <summary>
/// The answer to a pairing the user allowed: who the desktop is, the phone's secret and, from a
/// desktop that has the cloud sync folder (C2), the key packages put there are sealed with
/// (<see cref="SyncPackage"/>).
/// </summary>
/// <param name="SyncKey">Base64url of the 32-byte sync key; null from a desktop without the sync folder (left out of the JSON).</param>
public sealed record PairResponse(string DesktopId, string DesktopName, string DeviceSecret, int ProtocolVersion,
                                  string? SyncKey = null)
{
    public string ToJson() =>
        $"{{\"protocolVersion\":{CompanionProtocol.Integer(ProtocolVersion)},\"desktopId\":{CompanionPackage.Quote(DesktopId)}"
        + $",\"desktopName\":{CompanionPackage.Quote(DesktopName)},\"deviceSecret\":{CompanionPackage.Quote(DeviceSecret)}"
        + (SyncKey is null ? "" : $",\"syncKey\":{CompanionPackage.Quote(SyncKey)}") + "}";

    public static PairResponse? FromJson(ReadOnlySpan<byte> json) =>
        CompanionProtocol.Decode<Dto>(json) is { } dto
            ? new PairResponse(dto.DesktopId, dto.DesktopName, dto.DeviceSecret, dto.ProtocolVersion, dto.SyncKey)
            : null;

    private sealed class Dto
    {
        [JsonConverter(typeof(WholeNumberConverter))]
        public int ProtocolVersion { get; set; }
        public string DesktopId { get; set; } = "";
        public string DesktopName { get; set; } = "";
        public string DeviceSecret { get; set; } = "";
        public string? SyncKey { get; set; }
    }
}

/// <summary>The answer to <c>GET /v1/health</c>; <paramref name="Paired"/> only when the phone sent valid credentials.</summary>
public sealed record HealthResponse(int ProtocolVersion, bool Paired)
{
    public string ToJson() =>
        $"{{\"service\":{CompanionPackage.Quote(CompanionProtocol.ServiceName)}"
        + $",\"protocolVersion\":{CompanionProtocol.Integer(ProtocolVersion)},\"paired\":{CompanionProtocol.Bool(Paired)}}}";

    /// <summary>Null unless the body says it is CompleteScanner's.</summary>
    public static HealthResponse? FromJson(ReadOnlySpan<byte> json) =>
        CompanionProtocol.Decode<Dto>(json) is { } dto && dto.Service == CompanionProtocol.ServiceName
            ? new HealthResponse(dto.ProtocolVersion, dto.Paired)
            : null;

    private sealed class Dto
    {
        public string Service { get; set; } = "";
        [JsonConverter(typeof(WholeNumberConverter))]
        public int ProtocolVersion { get; set; }
        public bool Paired { get; set; }
    }
}

/// <summary>The answer to <c>GET /v1/hello</c>: the desktop, the pages in its queue, the largest upload it takes.</summary>
public sealed record HelloResponse(string DesktopId, string DesktopName, int ProtocolVersion, int QueuedPages, long MaxUploadBytes)
{
    public string ToJson() =>
        $"{{\"protocolVersion\":{CompanionProtocol.Integer(ProtocolVersion)},\"desktopId\":{CompanionPackage.Quote(DesktopId)}"
        + $",\"desktopName\":{CompanionPackage.Quote(DesktopName)},\"queuedPages\":{CompanionProtocol.Integer(QueuedPages)}"
        + $",\"maxUploadBytes\":{CompanionProtocol.Integer(MaxUploadBytes)}}}";

    public static HelloResponse? FromJson(ReadOnlySpan<byte> json) =>
        CompanionProtocol.Decode<Dto>(json) is { } dto
            ? new HelloResponse(dto.DesktopId, dto.DesktopName, dto.ProtocolVersion, dto.QueuedPages, dto.MaxUploadBytes)
            : null;

    private sealed class Dto
    {
        [JsonConverter(typeof(WholeNumberConverter))]
        public int ProtocolVersion { get; set; }
        public string DesktopId { get; set; } = "";
        public string DesktopName { get; set; } = "";
        [JsonConverter(typeof(WholeNumberConverter))]
        public int QueuedPages { get; set; }
        [JsonConverter(typeof(WholeNumberConverter))]
        public long MaxUploadBytes { get; set; }
    }
}

/// <summary>The answer to an upload: the package, its pages, and whether it had arrived before.</summary>
public sealed record InboxResponse(string PackageId, int PageCount, bool Duplicate)
{
    public string ToJson() =>
        $"{{\"packageId\":{CompanionPackage.Quote(PackageId)},\"pageCount\":{CompanionProtocol.Integer(PageCount)}"
        + $",\"duplicate\":{CompanionProtocol.Bool(Duplicate)}}}";

    public static InboxResponse? FromJson(ReadOnlySpan<byte> json) =>
        CompanionProtocol.Decode<Dto>(json) is { } dto ? new InboxResponse(dto.PackageId, dto.PageCount, dto.Duplicate) : null;

    private sealed class Dto
    {
        public string PackageId { get; set; } = "";
        [JsonConverter(typeof(WholeNumberConverter))]
        public int PageCount { get; set; }
        public bool Duplicate { get; set; }
    }
}

/// <summary>A file waiting in a phone's outbox on the desktop.</summary>
public sealed record OutboxItem(string Id, string Name, string ContentType, long ByteCount, DateTimeOffset Created)
{
    public string ToJson() =>
        $"{{\"id\":{CompanionPackage.Quote(Id)},\"name\":{CompanionPackage.Quote(Name)}"
        + $",\"contentType\":{CompanionPackage.Quote(ContentType)},\"byteCount\":{CompanionProtocol.Integer(ByteCount)}"
        + $",\"created\":{CompanionPackage.Quote(CompanionPackage.FormatDate(Created))}}}";
}

/// <summary>The answer to <c>GET /v1/outbox</c>: what waits for the phone, oldest first.</summary>
public sealed record OutboxList(IReadOnlyList<OutboxItem> Items)
{
    public string ToJson() => $"{{\"items\":[{string.Join(",", Items.Select(item => item.ToJson()))}]}}";

    /// <summary>The listing; items without a valid id or with an unreadable date are left out.</summary>
    public static OutboxList? FromJson(ReadOnlySpan<byte> json)
    {
        if (CompanionProtocol.Decode<Dto>(json) is not { } dto) return null;
        var items = new List<OutboxItem>();
        foreach (var item in dto.Items)
        {
            if (item is null || !CompanionProtocol.IsValidId(item.Id) || CompanionPackage.ParseDate(item.Created) is not { } created)
            {
                continue;
            }
            items.Add(new OutboxItem(item.Id, item.Name, item.ContentType, item.ByteCount, created));
        }
        return new OutboxList(items);
    }

    public bool Equals(OutboxList? other) => other is not null && Items.SequenceEqual(other.Items);

    public override int GetHashCode() => Items.Count;

    private sealed class Dto
    {
        public List<ItemDto?> Items { get; set; } = [];
    }

    private sealed class ItemDto
    {
        public string Id { get; set; } = "";
        public string Name { get; set; } = "";
        public string ContentType { get; set; } = "";
        [JsonConverter(typeof(WholeNumberConverter))]
        public long ByteCount { get; set; }
        public string? Created { get; set; }
    }
}
