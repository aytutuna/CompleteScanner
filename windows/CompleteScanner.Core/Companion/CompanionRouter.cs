using System.Globalization;
using System.Net;
using System.Security.Cryptography;

namespace CompleteScanner.Core;

/// <summary>
/// A request's body: exactly its Content-Length of bytes (none without one), from what was read
/// with the head and then the connection. A client that sent <c>Expect: 100-continue</c> is told
/// to send its body only when the body is first read, so a request refused before that never
/// sends it.
/// </summary>
public sealed class CompanionRequestBody : Stream
{
    private readonly Stream _source;
    private readonly ReadOnlyMemory<byte> _prefix;
    private readonly Func<CancellationToken, Task>? _sendContinue;
    private int _prefixUsed;
    private long _remaining;

    /// <param name="source">The connection after the head (or the whole body in tests).</param>
    /// <param name="length">The body's length (Content-Length; 0 without one).</param>
    /// <param name="prefix">Bytes of the body that arrived with the head.</param>
    /// <param name="sendContinue">Sends "100 Continue"; null when the client did not ask for it.</param>
    public CompanionRequestBody(Stream source, long length, ReadOnlyMemory<byte> prefix = default,
                                Func<CancellationToken, Task>? sendContinue = null)
    {
        _source = source;
        _remaining = length;
        _prefix = prefix.Length > length ? prefix[..(int)length] : prefix;
        _sendContinue = sendContinue;
        BodyLength = length;
    }

    /// <summary>The body's length.</summary>
    public long BodyLength { get; }

    /// <summary>The bytes not read yet.</summary>
    public long Remaining => _remaining;

    /// <summary>Reading began (and "100 Continue" was sent when asked for).</summary>
    public bool HasStarted { get; private set; }

    /// <summary>The client still holds its body back: it asked to wait and was not told to send it.</summary>
    public bool IsWithheld => _sendContinue is not null && !HasStarted && _remaining > 0;

    /// <summary>
    /// Reads and drops the rest of the body when it is at most <paramref name="maxBytes"/>, so the
    /// connection can be closed without cutting the client off mid-send; a withheld body needs no
    /// reading. Returns whether nothing is left unread.
    /// </summary>
    public async Task<bool> DiscardAsync(long maxBytes, CancellationToken cancellation)
    {
        if (IsWithheld || _remaining == 0) return true;
        if (_remaining > maxBytes) return false;
        var buffer = new byte[81920];
        while (_remaining > 0)
        {
            if (await ReadAsync(buffer, cancellation).ConfigureAwait(false) == 0) return false;
        }
        return true;
    }

    public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default)
    {
        if (_remaining <= 0 || buffer.Length == 0) return 0;
        if (!HasStarted)
        {
            HasStarted = true;
            if (_sendContinue is not null) await _sendContinue(cancellationToken).ConfigureAwait(false);
        }
        int count;
        if (_prefixUsed < _prefix.Length)
        {
            count = Math.Min(buffer.Length, _prefix.Length - _prefixUsed);
            _prefix.Slice(_prefixUsed, count).CopyTo(buffer);
            _prefixUsed += count;
        }
        else
        {
            count = await _source.ReadAsync(buffer[..(int)Math.Min(buffer.Length, _remaining)], cancellationToken).ConfigureAwait(false);
            if (count == 0) return 0;
        }
        _remaining -= count;
        return count;
    }

    public override Task<int> ReadAsync(byte[] buffer, int offset, int count, CancellationToken cancellationToken) =>
        ReadAsync(buffer.AsMemory(offset, count), cancellationToken).AsTask();

    public override int Read(byte[] buffer, int offset, int count) =>
        ReadAsync(buffer.AsMemory(offset, count)).AsTask().GetAwaiter().GetResult();

    public override bool CanRead => true;
    public override bool CanSeek => false;
    public override bool CanWrite => false;
    public override long Length => BodyLength;

    public override long Position
    {
        get => BodyLength - _remaining;
        set => throw new NotSupportedException();
    }

    public override void Flush() { }
    public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
    public override void SetLength(long value) => throw new NotSupportedException();
    public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
}

/// <summary>One request to the companion server: its head, its body and where it came from.</summary>
public sealed record CompanionRequest(HttpRequestHead Head, CompanionRequestBody Body, IPAddress Remote);

/// <summary>A response: its status, headers and body (bytes, or a file streamed and then closed).</summary>
public sealed class CompanionResponse
{
    private CompanionResponse(int status, IReadOnlyList<KeyValuePair<string, string>> headers, byte[] body, Stream? stream, long length)
    {
        Status = status;
        Headers = headers;
        Body = body;
        BodyStream = stream;
        Length = length;
    }

    public int Status { get; }
    /// <summary>Headers besides Content-Length and Connection, which the server adds.</summary>
    public IReadOnlyList<KeyValuePair<string, string>> Headers { get; }
    public byte[] Body { get; }
    /// <summary>A file to send instead of <see cref="Body"/>; the server disposes of it.</summary>
    public Stream? BodyStream { get; }
    public long Length { get; }

    public static CompanionResponse Json(int status, string json, params KeyValuePair<string, string>[] headers)
    {
        var body = CompanionProtocol.Utf8(json);
        return new CompanionResponse(status, [new("Content-Type", CompanionProtocol.JsonContentType), .. headers], body, null, body.Length);
    }

    public static CompanionResponse Error(int status, CompanionError error, params KeyValuePair<string, string>[] headers) =>
        Json(status, error.ToJson(), headers);

    public static CompanionResponse Empty(int status) => new(status, [], [], null, 0);

    public static CompanionResponse File(Stream stream, long length, string contentType) =>
        new(200, [new("Content-Type", contentType)], [], stream, length);

    /// <summary>The body as text (tests).</summary>
    public string Text => System.Text.Encoding.UTF8.GetString(Body);
}

/// <summary>A package received from a paired phone (<see cref="CompanionRouter.PackageReceived"/>).</summary>
public sealed class CompanionPackageReceivedEventArgs(ReceivedPackage package, PairedDevice device) : EventArgs
{
    public ReceivedPackage Package { get; } = package;
    public PairedDevice Device { get; } = device;
}

/// <summary>
/// What the companion server does with each request (see <see cref="CompanionProtocol"/> for the
/// endpoints). Unpaired clients may only check reachability and pair with the open pairing
/// session's token; everything else needs a paired phone's id and secret, and a wrong secret
/// gets 401. Every request counts towards the sender's rate limit, every failed secret or token
/// towards its failure limit. Events are raised on the request's thread.
/// </summary>
public sealed class CompanionRouter
{
    private readonly PairedDeviceStore _devices;
    private readonly CompanionInbox _inbox;
    private readonly CompanionOutbox _outbox;
    private readonly CompanionRateLimiter _limiter;
    private readonly Func<DateTimeOffset> _clock;
    private int _awaitingApproval;

    public CompanionRouter(PairedDeviceStore devices, CompanionInbox inbox, CompanionOutbox outbox,
                           CompanionRateLimiter limiter, Func<DateTimeOffset>? clock = null)
    {
        _devices = devices;
        _inbox = inbox;
        _outbox = outbox;
        _limiter = limiter;
        _clock = clock ?? (() => DateTimeOffset.UtcNow);
    }

    /// <summary>The name phones show for this desktop.</summary>
    public Func<string> DesktopName { get; set; } = () => Environment.MachineName;

    /// <summary>The pairing session open now; null when pairing is not open.</summary>
    public Func<PairingSession?> CurrentPairing { get; set; } = () => null;

    /// <summary>
    /// Asks the user whether the phone that presented a valid token may pair. Without an answer
    /// within <see cref="ApprovalTimeout"/> the pairing is declined. The default allows it: the
    /// token was only on this desktop's screen.
    /// </summary>
    public Func<PairRequest, CancellationToken, Task<bool>> ApprovePairing { get; set; } = (_, _) => Task.FromResult(true);

    public TimeSpan ApprovalTimeout { get; set; } = TimeSpan.FromMinutes(2);

    /// <summary>The pages in the desktop's queue, for <see cref="HelloResponse"/>.</summary>
    public Func<int> QueuedPages { get; set; } = () => 0;

    public event EventHandler<PairedDevice>? DevicePaired;
    public event EventHandler<CompanionPackageReceivedEventArgs>? PackageReceived;
    /// <summary>A phone forgot this desktop (<c>DELETE /v1/devices/self</c>).</summary>
    public event EventHandler<PairedDevice>? DeviceRemoved;

    /// <summary>
    /// Phones that presented a valid token and wait for the user's answer (their session is used
    /// already), and pairing requests whose token is being checked; the desktop keeps listening for
    /// them until the answer is in.
    /// </summary>
    public int AwaitingApproval => Volatile.Read(ref _awaitingApproval);

    /// <summary>A pairing request counted in <see cref="AwaitingApproval"/> ended: paired, declined, refused or cut off.</summary>
    public event EventHandler? ApprovalSettled;

    public async Task<CompanionResponse> HandleAsync(CompanionRequest request, CancellationToken cancellation)
    {
        var now = _clock();
        if (!_limiter.TryRequest(request.Remote, now))
        {
            return CompanionResponse.Error(429, CompanionError.RateLimited, Header("Retry-After", "60"));
        }
        var head = request.Head;
        string path = head.Path;
        switch (path)
        {
            case CompanionProtocol.HealthPath:
                return head.Method == "GET" ? Health(request, now) : NotAllowed("GET");
            case CompanionProtocol.PairPath:
                return head.Method == "POST" ? await PairAsync(request, now, cancellation).ConfigureAwait(false) : NotAllowed("POST");
            case CompanionProtocol.HelloPath:
                return head.Method == "GET" ? Hello(request, now) : NotAllowed("GET");
            case CompanionProtocol.OutboxPath:
                return head.Method == "GET" ? await OutboxListAsync(request, now, cancellation).ConfigureAwait(false) : NotAllowed("GET");
            case CompanionProtocol.DeviceSelfPath:
                return head.Method == "DELETE" ? RemoveSelf(request, now) : NotAllowed("DELETE");
        }
        if (path.StartsWith(CompanionProtocol.InboxPrefix, StringComparison.Ordinal))
        {
            return head.Method == "PUT"
                ? await InboxAsync(request, path[CompanionProtocol.InboxPrefix.Length..], now, cancellation).ConfigureAwait(false)
                : NotAllowed("PUT");
        }
        if (path.StartsWith(CompanionProtocol.OutboxPrefix, StringComparison.Ordinal))
        {
            string id = path[CompanionProtocol.OutboxPrefix.Length..];
            return head.Method switch
            {
                "GET" => OutboxGet(request, id, now),
                "DELETE" => OutboxDelete(request, id, now),
                _ => NotAllowed("GET, DELETE"),
            };
        }
        return CompanionResponse.Error(404, CompanionError.NotFound);
    }

    private static KeyValuePair<string, string> Header(string name, string value) => new(name, value);

    private static CompanionResponse NotAllowed(string allow) =>
        CompanionResponse.Error(405, CompanionError.MethodNotAllowed, Header("Allow", allow));

    private static CompanionResponse Unauthorized() =>
        CompanionResponse.Error(401, CompanionError.Unauthorized, Header("WWW-Authenticate", "Bearer"));

    /// <summary>The paired phone the request comes from; null (a failure counted) when its id and secret do not match one.</summary>
    private PairedDevice? Authenticate(CompanionRequest request, DateTimeOffset now)
    {
        var device = _devices.Authenticate(request.Head.Header(CompanionProtocol.DeviceIdHeader), request.Head.BearerToken, now);
        if (device is null) _limiter.RecordFailure(request.Remote, now);
        return device;
    }

    private CompanionResponse Health(CompanionRequest request, DateTimeOffset now)
    {
        bool paired = false;
        if (request.Head.BearerToken is not null || request.Head.Header(CompanionProtocol.DeviceIdHeader) is not null)
        {
            if (Authenticate(request, now) is null) return Unauthorized();
            paired = true;
        }
        return CompanionResponse.Json(200, new HealthResponse(CompanionProtocol.Version, paired).ToJson());
    }

    private CompanionResponse Hello(CompanionRequest request, DateTimeOffset now)
    {
        if (Authenticate(request, now) is null) return Unauthorized();
        return CompanionResponse.Json(200, new HelloResponse(_devices.DesktopId, DesktopName(), CompanionProtocol.Version,
                                                             QueuedPages(), CompanionProtocol.MaxUploadBytes).ToJson());
    }

    private async Task<CompanionResponse> PairAsync(CompanionRequest request, DateTimeOffset now, CancellationToken cancellation)
    {
        if (request.Head.ContentLength is not { } length) return CompanionResponse.Error(411, CompanionError.LengthRequired);
        if (length > CompanionProtocol.MaxJsonBodyBytes) return CompanionResponse.Error(413, CompanionError.TooLarge);
        byte[]? body = await ReadAllAsync(request.Body, length, cancellation).ConfigureAwait(false);
        if (body is null || PairRequest.FromJson(body) is not { } pair || !CompanionProtocol.IsValidId(pair.PhoneId))
        {
            return CompanionResponse.Error(400, CompanionError.BadRequest);
        }
        if (CurrentPairing() is not { } session) return CompanionResponse.Error(403, CompanionError.PairingClosed);
        // Counted from before the token is used until the phone is stored (or refused), so the
        // desktop never stops listening in between: once the session is used it no longer keeps
        // the link on.
        Interlocked.Increment(ref _awaitingApproval);
        try
        {
            switch (session.Redeem(pair.Token, now))
            {
                case PairingRedeemResult.WrongToken:
                    _limiter.RecordFailure(request.Remote, now);
                    return CompanionResponse.Error(403, CompanionError.TokenInvalid);
                case PairingRedeemResult.Expired:
                    return CompanionResponse.Error(403, CompanionError.TokenExpired);
                case PairingRedeemResult.AlreadyUsed:
                    return CompanionResponse.Error(403, CompanionError.TokenUsed);
                case PairingRedeemResult.Closed:
                    return CompanionResponse.Error(403, CompanionError.PairingClosed);
            }
            string name = PairedDeviceStore.CleanName(pair.PhoneName);
            pair = pair with { PhoneName = name.Length > 0 ? name : "Phone" };
            return await ApproveAndPairAsync(pair, cancellation).ConfigureAwait(false);
        }
        finally
        {
            Interlocked.Decrement(ref _awaitingApproval);
            ApprovalSettled?.Invoke(this, EventArgs.Empty);
        }
    }

    private async Task<CompanionResponse> ApproveAndPairAsync(PairRequest pair, CancellationToken cancellation)
    {
        bool approved;
        using (var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellation))
        {
            timeout.CancelAfter(ApprovalTimeout);
            try
            {
                approved = await ApprovePairing(pair, timeout.Token).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (!cancellation.IsCancellationRequested)
            {
                approved = false;
            }
        }
        if (!approved) return CompanionResponse.Error(403, CompanionError.Declined);
        string secret;
        try
        {
            secret = _devices.Pair(pair.PhoneId, pair.PhoneName, pair.Platform, pair.AppVersion, _clock());
        }
        catch (InvalidOperationException)
        {
            return CompanionResponse.Error(409, CompanionError.TooManyDevices);
        }
        catch (IOException)
        {
            return CompanionResponse.Error(500, CompanionError.ServerError);
        }
        if (_devices.Devices.FirstOrDefault(d => d.Id == pair.PhoneId) is { } device) DevicePaired?.Invoke(this, device);
        string? syncKey = null;
        try
        {
            if (_devices.SyncKey(pair.PhoneId) is { } key) syncKey = CompanionProtocol.EncodeBase64Url(key);
        }
        catch (CryptographicException)
        {
            // Paired without the sync folder.
        }
        return CompanionResponse.Json(200, new PairResponse(_devices.DesktopId, DesktopName(), secret, CompanionProtocol.Version,
                                                            syncKey).ToJson());
    }

    private async Task<CompanionResponse> InboxAsync(CompanionRequest request, string packageId, DateTimeOffset now,
                                                     CancellationToken cancellation)
    {
        if (Authenticate(request, now) is not { } device) return Unauthorized();
        if (!CompanionProtocol.IsValidId(packageId)) return CompanionResponse.Error(400, CompanionError.BadRequest);
        if (request.Head.ContentLength is not { } length) return CompanionResponse.Error(411, CompanionError.LengthRequired);
        if (length > CompanionProtocol.MaxUploadBytes) return CompanionResponse.Error(413, CompanionError.TooLarge);
        var target = CompanionProtocol.Target(request.Head.Header(CompanionProtocol.TargetHeader));
        if (await DuplicateAsync().ConfigureAwait(false) is { } duplicate) return duplicate;
        if (!_inbox.TryBegin(device.Id, packageId)) return CompanionResponse.Error(409, CompanionError.Busy);
        try
        {
            // It may have been received while this request waited.
            if (await DuplicateAsync().ConfigureAwait(false) is { } late) return late;
            var package = await _inbox.ReceiveAsync(device.Id, packageId, target, request.Body, length, now, cancellation).ConfigureAwait(false);
            PackageReceived?.Invoke(this, new CompanionPackageReceivedEventArgs(package, device));
            return CompanionResponse.Json(201, new InboxResponse(packageId, package.Document.Pages.Count, false).ToJson());
        }
        catch (CompanionPackageException error)
        {
            return CompanionResponse.Error(422, new CompanionError(CompanionErrorCode.InvalidPackage, error.Message));
        }
        catch (EndOfStreamException)
        {
            return CompanionResponse.Error(400, CompanionError.BadRequest);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            System.Diagnostics.Trace.TraceWarning($"Could not store a document from a phone: {error.Message}");
            return CompanionResponse.Error(500, CompanionError.ServerError);
        }
        finally
        {
            _inbox.End(device.Id, packageId);
        }

        async Task<CompanionResponse?> DuplicateAsync()
        {
            if (_inbox.Find(device.Id, packageId) is not { } received) return null;
            // Received before: the body is not needed again (a withheld one is never sent).
            await request.Body.DiscardAsync(long.MaxValue, cancellation).ConfigureAwait(false);
            return CompanionResponse.Json(200, new InboxResponse(packageId, received.PageCount, true).ToJson());
        }
    }

    private async Task<CompanionResponse> OutboxListAsync(CompanionRequest request, DateTimeOffset now, CancellationToken cancellation)
    {
        if (Authenticate(request, now) is not { } device) return Unauthorized();
        int wait = 0;
        if (CompanionHttp.QueryParameters(request.Head.Query).TryGetValue("wait", out string? text))
        {
            if (!int.TryParse(text, NumberStyles.None, CultureInfo.InvariantCulture, out wait)) return CompanionResponse.Error(400, CompanionError.BadRequest);
            wait = Math.Min(wait, CompanionProtocol.MaxOutboxWaitSeconds);
        }
        var items = _outbox.List(device.Id, now);
        if (items.Count == 0 && wait > 0)
        {
            await _outbox.WaitAsync(device.Id, TimeSpan.FromSeconds(wait), cancellation).ConfigureAwait(false);
            items = _devices.Authenticate(device.Id, request.Head.BearerToken, _clock()) is null ? [] : _outbox.List(device.Id, _clock());
        }
        return CompanionResponse.Json(200, new OutboxList(items).ToJson());
    }

    private CompanionResponse OutboxGet(CompanionRequest request, string id, DateTimeOffset now)
    {
        if (Authenticate(request, now) is not { } device) return Unauthorized();
        if (_outbox.Open(device.Id, id) is not { } opened) return CompanionResponse.Error(404, CompanionError.NotFound);
        return CompanionResponse.File(opened.Stream, opened.Stream.Length,
                                      opened.Item.ContentType.Length > 0 ? opened.Item.ContentType : "application/octet-stream");
    }

    private CompanionResponse OutboxDelete(CompanionRequest request, string id, DateTimeOffset now)
    {
        if (Authenticate(request, now) is not { } device) return Unauthorized();
        return _outbox.Remove(device.Id, id) ? CompanionResponse.Empty(204) : CompanionResponse.Error(404, CompanionError.NotFound);
    }

    private CompanionResponse RemoveSelf(CompanionRequest request, DateTimeOffset now)
    {
        if (Authenticate(request, now) is not { } device) return Unauthorized();
        _devices.Remove(device.Id);
        _outbox.RemoveDevice(device.Id);
        DeviceRemoved?.Invoke(this, device);
        return CompanionResponse.Empty(204);
    }

    /// <summary>The whole body (small ones only); null when it ended early.</summary>
    private static async Task<byte[]?> ReadAllAsync(CompanionRequestBody body, long length, CancellationToken cancellation)
    {
        var bytes = new byte[length];
        int filled = 0;
        while (filled < length)
        {
            int read = await body.ReadAsync(bytes.AsMemory(filled), cancellation).ConfigureAwait(false);
            if (read == 0) return null;
            filled += read;
        }
        return bytes;
    }
}
