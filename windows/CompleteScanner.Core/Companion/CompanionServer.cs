using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Authentication;
using System.Security.Cryptography.X509Certificates;

namespace CompleteScanner.Core;

/// <summary>Limits and timeouts of the companion server.</summary>
public sealed record CompanionServerOptions
{
    /// <summary>Connections served at once; more are closed at once.</summary>
    public int MaxConnections { get; init; } = 8;
    public TimeSpan HandshakeTimeout { get; init; } = TimeSpan.FromSeconds(10);
    /// <summary>How long the request line and headers may take to arrive.</summary>
    public TimeSpan HeadTimeout { get; init; } = TimeSpan.FromSeconds(10);
    /// <summary>How long a body may stall between two reads, and a response between two writes.</summary>
    public TimeSpan IdleTimeout { get; init; } = TimeSpan.FromSeconds(30);
    /// <summary>A refused request's unread body is read and dropped up to this size before closing.</summary>
    public long MaxDiscardBytes { get; init; } = 1024 * 1024;
    /// <summary>Which peers are answered (others are closed before TLS); every peer when null.</summary>
    public Func<IPAddress, bool>? AllowPeer { get; init; }
    /// <summary>When stopping, how long requests already being served may take to finish before they are cut off.</summary>
    public TimeSpan StopGrace { get; init; } = TimeSpan.FromSeconds(2);
}

/// <summary>
/// The companion server: TLS 1.2/1.3 over TCP with the desktop's own certificate, one request per
/// connection, the small HTTP/1.1 subset of <see cref="CompanionHttp"/>, every request handed to
/// <see cref="CompanionRouter"/>. It listens only on the endpoints it is given (the trusted
/// networks' addresses), closes connections from peers <see cref="CompanionServerOptions.AllowPeer"/>
/// refuses or <see cref="CompanionRateLimiter"/> blocks before TLS, and bounds every step in time.
/// Only the BCL is used (TcpListener, SslStream), so Core stays without dependencies.
/// </summary>
public sealed class CompanionServer : IAsyncDisposable
{
    private readonly X509Certificate2 _certificate;
    private readonly CompanionRouter _router;
    private readonly CompanionRateLimiter _limiter;
    private readonly CompanionServerOptions _options;
    private readonly Func<DateTimeOffset> _clock;
    private readonly List<TcpListener> _listeners = [];
    private readonly List<Task> _acceptLoops = [];
    private readonly HashSet<Task> _connections = [];
    private readonly object _gate = new();
    /// <summary>Cancelled to stop accepting connections.</summary>
    private CancellationTokenSource? _accept;
    /// <summary>Cancelled to cut off the connections being served.</summary>
    private CancellationTokenSource? _stop;
    private SslStreamCertificateContext? _context;

    public CompanionServer(X509Certificate2 certificate, CompanionRouter router, CompanionRateLimiter limiter,
                           CompanionServerOptions? options = null, Func<DateTimeOffset>? clock = null)
    {
        if (!certificate.HasPrivateKey) throw new ArgumentException("The server certificate needs its private key.", nameof(certificate));
        _certificate = certificate;
        _router = router;
        _limiter = limiter;
        _options = options ?? new CompanionServerOptions();
        _clock = clock ?? (() => DateTimeOffset.UtcNow);
    }

    /// <summary>The endpoints listened on (with the ports actually bound); empty when stopped.</summary>
    public IReadOnlyList<IPEndPoint> LocalEndpoints { get; private set; } = [];

    public bool IsRunning => _stop is not null;

    /// <summary>The connections being served now.</summary>
    public int ActiveConnections
    {
        get
        {
            lock (_gate) return _connections.Count;
        }
    }

    /// <summary>
    /// Listens on <paramref name="endpoints"/>. A port of 0 takes one the system picks; the first
    /// endpoint's port is then used for the others, so all share one port. Throws
    /// <see cref="SocketException"/> (nothing left listening) when one cannot be bound.
    /// </summary>
    public IReadOnlyList<IPEndPoint> Start(IReadOnlyList<IPEndPoint> endpoints)
    {
        if (IsRunning) throw new InvalidOperationException("The server is already running.");
        if (endpoints.Count == 0) throw new ArgumentException("Nothing to listen on.", nameof(endpoints));
        _context ??= SslStreamCertificateContext.Create(_certificate, additionalCertificates: null, offline: true);
        var bound = new List<IPEndPoint>();
        int sharedPort = 0;
        try
        {
            foreach (var requested in endpoints)
            {
                int port = requested.Port != 0 ? requested.Port : sharedPort;
                var listener = new TcpListener(new IPEndPoint(requested.Address, port));
                listener.Server.ExclusiveAddressUse = true;
                listener.Start(backlog: 16);
                _listeners.Add(listener);
                var local = (IPEndPoint)listener.LocalEndpoint;
                if (sharedPort == 0) sharedPort = local.Port;
                bound.Add(local);
            }
        }
        catch
        {
            foreach (var listener in _listeners) listener.Stop();
            _listeners.Clear();
            throw;
        }
        _stop = new CancellationTokenSource();
        _accept = new CancellationTokenSource();
        var accept = _accept.Token;
        var stop = _stop.Token;
        foreach (var listener in _listeners) _acceptLoops.Add(Task.Run(() => AcceptLoopAsync(listener, accept, stop)));
        LocalEndpoints = bound;
        return bound;
    }

    /// <summary>
    /// Stops listening at once, lets the requests being served finish for
    /// <see cref="CompanionServerOptions.StopGrace"/> (a phone removing itself still gets its answer),
    /// then cuts off the rest; nothing listens once it completes.
    /// </summary>
    public async Task StopAsync()
    {
        var stop = _stop;
        var accept = _accept;
        if (stop is null || accept is null) return;
        _stop = null;
        _accept = null;
        accept.Cancel();
        foreach (var listener in _listeners) listener.Stop();
        _listeners.Clear();
        Task[] serving;
        lock (_gate) serving = [.. _connections];
        try
        {
            await Task.WhenAll(serving).WaitAsync(_options.StopGrace).ConfigureAwait(false);
        }
        catch (TimeoutException)
        {
            // Cut off below.
        }
        stop.Cancel();
        Task[] pending;
        lock (_gate) pending = [.. _acceptLoops, .. _connections];
        _acceptLoops.Clear();
        try
        {
            await Task.WhenAll(pending).WaitAsync(TimeSpan.FromSeconds(10)).ConfigureAwait(false);
        }
        catch (Exception e) when (e is TimeoutException or OperationCanceledException)
        {
            System.Diagnostics.Trace.TraceWarning($"Companion connections did not end in time: {e.Message}");
        }
        LocalEndpoints = [];
        stop.Dispose();
        accept.Dispose();
    }

    public async ValueTask DisposeAsync() => await StopAsync().ConfigureAwait(false);

    private async Task AcceptLoopAsync(TcpListener listener, CancellationToken accept, CancellationToken stop)
    {
        while (!accept.IsCancellationRequested)
        {
            TcpClient client;
            try
            {
                client = await listener.AcceptTcpClientAsync(accept).ConfigureAwait(false);
            }
            catch (Exception e) when (e is OperationCanceledException or ObjectDisposedException or SocketException
                                          or InvalidOperationException)
            {
                // A connection reset while it was being accepted is no reason to stop accepting; a short
                // pause keeps a listener that fails over and over from spinning.
                if (accept.IsCancellationRequested || e is not SocketException) return;
                try
                {
                    await Task.Delay(100, accept).ConfigureAwait(false);
                }
                catch (OperationCanceledException)
                {
                    return;
                }
                continue;
            }
            var remote = (client.Client.RemoteEndPoint as IPEndPoint)?.Address ?? IPAddress.None;
            bool refused;
            lock (_gate)
            {
                refused = _connections.Count >= _options.MaxConnections
                          || (_options.AllowPeer is { } allow && !allow(remote))
                          || _limiter.IsBlocked(remote, _clock());
            }
            if (refused)
            {
                client.Dispose();
                continue;
            }
            var connection = ServeAsync(client, remote, stop);
            lock (_gate) _connections.Add(connection);
            _ = connection.ContinueWith(done =>
            {
                lock (_gate) _connections.Remove(done);
            }, CancellationToken.None, TaskContinuationOptions.ExecuteSynchronously, TaskScheduler.Default);
        }
    }

    private async Task ServeAsync(TcpClient client, IPAddress remote, CancellationToken stop)
    {
        await Task.Yield();
        using var tcp = client;
        tcp.NoDelay = true;
        try
        {
            await using var tls = new SslStream(tcp.GetStream(), leaveInnerStreamOpen: false);
            using (var handshake = CancellationTokenSource.CreateLinkedTokenSource(stop))
            {
                handshake.CancelAfter(_options.HandshakeTimeout);
                await tls.AuthenticateAsServerAsync(new SslServerAuthenticationOptions
                {
                    ServerCertificateContext = _context,
                    EnabledSslProtocols = SslProtocols.Tls12 | SslProtocols.Tls13,
                    ClientCertificateRequired = false,
                    CertificateRevocationCheckMode = X509RevocationMode.NoCheck,
                }, handshake.Token).ConfigureAwait(false);
            }
            await ServeRequestAsync(tls, remote, stop).ConfigureAwait(false);
        }
        catch (Exception e) when (e is IOException or AuthenticationException or OperationCanceledException
                                      or ObjectDisposedException or SocketException or InvalidOperationException)
        {
            // A client that went away, timed out or failed the handshake: nothing to answer.
        }
    }

    private async Task ServeRequestAsync(SslStream tls, IPAddress remote, CancellationToken stop)
    {
        var buffer = new byte[CompanionHttp.MaxHeadBytes + 4096];
        int filled = 0;
        HttpParseResult parsed;
        using (var headTimeout = CancellationTokenSource.CreateLinkedTokenSource(stop))
        {
            headTimeout.CancelAfter(_options.HeadTimeout);
            while (true)
            {
                int read = await tls.ReadAsync(buffer.AsMemory(filled), headTimeout.Token).ConfigureAwait(false);
                if (read == 0) return;
                filled += read;
                parsed = CompanionHttp.Parse(buffer.AsSpan(0, filled));
                if (parsed.Status != HttpParseStatus.Incomplete) break;
                if (filled == buffer.Length)
                {
                    parsed = new HttpParseResult(HttpParseStatus.Invalid, ErrorStatus: 431);
                    break;
                }
            }
        }
        if (parsed.Status == HttpParseStatus.Invalid || parsed.Head is not { } head)
        {
            await WriteAsync(tls, CompanionResponse.Error(parsed.ErrorStatus, CompanionError.BadRequest), stop).ConfigureAwait(false);
            return;
        }

        var idle = new IdleStream(tls, _options.IdleTimeout);
        var body = new CompanionRequestBody(
            idle, head.ContentLength ?? 0, buffer.AsMemory(parsed.Consumed, filled - parsed.Consumed),
            head.ExpectsContinue ? token => idle.WriteAsync(CompanionHttp.ContinueResponse.ToArray(), token).AsTask() : null);
        CompanionResponse response;
        try
        {
            response = await _router.HandleAsync(new CompanionRequest(head, body, remote), stop).ConfigureAwait(false);
        }
        catch (Exception e) when (e is not (IOException or OperationCanceledException))
        {
            // A connection that broke or timed out ends quietly (above); anything else is a bug, answered 500.
            System.Diagnostics.Trace.TraceError($"A companion request failed: {e}");
            response = CompanionResponse.Error(500, CompanionError.ServerError);
        }
        await WriteAsync(idle, response, stop).ConfigureAwait(false);
        // Leave the client its whole send when it is small, so closing does not cut off the answer.
        await body.DiscardAsync(_options.MaxDiscardBytes, stop).ConfigureAwait(false);
    }

    private static async Task WriteAsync(Stream stream, CompanionResponse response, CancellationToken stop)
    {
        try
        {
            await stream.WriteAsync(CompanionHttp.ResponseHead(response.Status, response.Headers, response.Length), stop).ConfigureAwait(false);
            if (response.BodyStream is { } file)
            {
                await file.CopyToAsync(stream, 81920, stop).ConfigureAwait(false);
            }
            else if (response.Body.Length > 0)
            {
                await stream.WriteAsync(response.Body, stop).ConfigureAwait(false);
            }
            await stream.FlushAsync(stop).ConfigureAwait(false);
        }
        finally
        {
            if (response.BodyStream is { } file) await file.DisposeAsync().ConfigureAwait(false);
        }
    }

    /// <summary>The connection, with each read and write given at most the idle timeout.</summary>
    private sealed class IdleStream(Stream inner, TimeSpan idle) : Stream
    {
        public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default)
        {
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            timeout.CancelAfter(idle);
            return await inner.ReadAsync(buffer, timeout.Token).ConfigureAwait(false);
        }

        public override async ValueTask WriteAsync(ReadOnlyMemory<byte> buffer, CancellationToken cancellationToken = default)
        {
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            timeout.CancelAfter(idle);
            await inner.WriteAsync(buffer, timeout.Token).ConfigureAwait(false);
        }

        public override Task<int> ReadAsync(byte[] buffer, int offset, int count, CancellationToken cancellationToken) =>
            ReadAsync(buffer.AsMemory(offset, count), cancellationToken).AsTask();

        public override Task WriteAsync(byte[] buffer, int offset, int count, CancellationToken cancellationToken) =>
            WriteAsync(buffer.AsMemory(offset, count), cancellationToken).AsTask();

        public override Task FlushAsync(CancellationToken cancellationToken) => inner.FlushAsync(cancellationToken);

        public override int Read(byte[] buffer, int offset, int count) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
        public override void Flush() => inner.Flush();
        public override bool CanRead => true;
        public override bool CanSeek => false;
        public override bool CanWrite => true;
        public override long Length => throw new NotSupportedException();

        public override long Position
        {
            get => throw new NotSupportedException();
            set => throw new NotSupportedException();
        }

        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
    }
}
