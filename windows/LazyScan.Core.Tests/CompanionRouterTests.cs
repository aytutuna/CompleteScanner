using System.Net;
using System.Text;
using LazyScan.Core;
using Xunit;

namespace LazyScan.Core.Tests;

// The desktop's request handling, without a network (C# only until the Mac server).

[Collection(WallClockCollection.Name)]
public sealed class CompanionRouterTests : IDisposable
{
    private static readonly IPAddress Phone = IPAddress.Parse("192.168.1.30");
    private readonly string _directory;
    private DateTimeOffset _now = new(2026, 10, 20, 8, 30, 0, TimeSpan.Zero);
    private readonly PairedDeviceStore _devices;
    private readonly CompanionInbox _inbox;
    private readonly CompanionOutbox _outbox;
    private readonly CompanionRouter _router;
    private PairingSession? _pairing;

    public CompanionRouterTests()
    {
        _directory = Path.Combine(Path.GetTempPath(), "LazyScanTests-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(_directory);
        _devices = new PairedDeviceStore(_directory);
        _inbox = new CompanionInbox(Path.Combine(_directory, "Inbox"));
        _outbox = new CompanionOutbox(Path.Combine(_directory, "Outbox"));
        _router = new CompanionRouter(_devices, _inbox, _outbox, new CompanionRateLimiter(), () => _now)
        {
            DesktopName = () => "AYTU-PC",
            CurrentPairing = () => _pairing,
            QueuedPages = () => 7,
        };
    }

    public void Dispose()
    {
        try
        {
            Directory.Delete(_directory, recursive: true);
        }
        catch (IOException)
        {
        }
    }

    private async Task<CompanionResponse> Send(string method, string target, byte[]? body = null, string? device = null,
                                               string? secret = null, IPAddress? from = null, params (string, string)[] headers)
    {
        var list = new List<KeyValuePair<string, string>> { new("Host", "192.168.1.20:52731") };
        if (device is not null) list.Add(new(CompanionProtocol.DeviceIdHeader, device));
        if (secret is not null) list.Add(new("Authorization", "Bearer " + secret));
        list.AddRange(headers.Select(h => new KeyValuePair<string, string>(h.Item1, h.Item2)));
        long? length = body?.Length;
        if (length is not null) list.Add(new("Content-Length", length.Value.ToString(System.Globalization.CultureInfo.InvariantCulture)));
        var head = new HttpRequestHead(method, target, list, length, false);
        var stream = new MemoryStream(body ?? []);
        return await _router.HandleAsync(new CompanionRequest(head, new CompanionRequestBody(stream, length ?? 0), from ?? Phone),
                                         CancellationToken.None);
    }

    private async Task<string> PairPhone(string id = "phone-0001")
    {
        _pairing = new PairingSession(_now);
        var response = await Send("POST", CompanionProtocol.PairPath, Json(new PairRequest(_pairing.Token, id, "Aytu's iPhone", "ios", "1.0")));
        Assert.Equal(200, response.Status);
        return PairResponse.FromJson(response.Body)!.DeviceSecret;
    }

    private static byte[] Json(PairRequest request) => Encoding.UTF8.GetBytes(request.ToJson());

    [Fact]
    public async Task Health_AnswersAnyoneAndChecksCredentialsWhenGiven()
    {
        var anonymous = await Send("GET", CompanionProtocol.HealthPath);
        Assert.Equal(200, anonymous.Status);
        Assert.Equal(new HealthResponse(1, false), HealthResponse.FromJson(anonymous.Body));
        string secret = await PairPhone();
        Assert.Equal(new HealthResponse(1, true),
                     HealthResponse.FromJson((await Send("GET", CompanionProtocol.HealthPath, device: "phone-0001", secret: secret)).Body));
        var wrong = await Send("GET", CompanionProtocol.HealthPath, device: "phone-0001", secret: CompanionVectors.SecretText);
        Assert.Equal(401, wrong.Status);
        Assert.Contains(wrong.Headers, h => h.Key == "WWW-Authenticate" && h.Value == "Bearer");
        Assert.Equal(405, (await Send("POST", CompanionProtocol.HealthPath, [])).Status);
    }

    [Fact]
    public async Task Pair_GivesASecretForTheOpenSessionsToken()
    {
        _pairing = new PairingSession(_now);
        PairedDevice? paired = null;
        _router.DevicePaired += (_, device) => paired = device;
        var response = await Send("POST", CompanionProtocol.PairPath, Json(new PairRequest(_pairing.Token, "phone-0001", "Aytu's\u0001 iPhone", "ios", "1.0")));
        Assert.Equal(200, response.Status);
        var answer = PairResponse.FromJson(response.Body)!;
        Assert.Equal(_devices.DesktopId, answer.DesktopId);
        Assert.Equal("AYTU-PC", answer.DesktopName);
        Assert.Equal(1, answer.ProtocolVersion);
        Assert.NotNull(_devices.Authenticate("phone-0001", answer.DeviceSecret, _now));
        Assert.Equal("Aytu's iPhone", paired?.Name);
        // The token was single use.
        var again = await Send("POST", CompanionProtocol.PairPath, Json(new PairRequest(_pairing.Token, "phone-0002", "Other", "ios", "1.0")));
        Assert.Equal(403, again.Status);
        Assert.Equal(CompanionErrorCode.TokenUsed, CompanionError.FromJson(again.Body)!.Code);
    }

    [Fact]
    public async Task Pair_RefusesWithoutAnOpenSessionOrTheRightToken()
    {
        async Task<string> Code(PairRequest request) => CompanionError.FromJson((await Send("POST", CompanionProtocol.PairPath, Json(request))).Body)!.Code;
        Assert.Equal(CompanionErrorCode.PairingClosed, await Code(new PairRequest(CompanionVectors.TokenText, "phone-0001", "P", "ios", "1")));
        _pairing = new PairingSession(_now, CompanionVectors.Token);
        Assert.Equal(CompanionErrorCode.TokenInvalid, await Code(new PairRequest("AAECAwQFBgcICQoLDA0ODx", "phone-0001", "P", "ios", "1")));
        _now = _now.AddMinutes(6);
        Assert.Equal(CompanionErrorCode.TokenExpired, await Code(new PairRequest(CompanionVectors.TokenText, "phone-0001", "P", "ios", "1")));
        Assert.Empty(_devices.Devices);
    }

    [Fact]
    public async Task Pair_RefusesMalformedRequests()
    {
        _pairing = new PairingSession(_now);
        Assert.Equal(400, (await Send("POST", CompanionProtocol.PairPath, Encoding.UTF8.GetBytes("not json"))).Status);
        Assert.Equal(400, (await Send("POST", CompanionProtocol.PairPath, Json(new PairRequest(_pairing.Token, "bad id", "P", "ios", "1")))).Status);
        Assert.Equal(411, (await Send("POST", CompanionProtocol.PairPath)).Status);
        Assert.Equal(413, (await Send("POST", CompanionProtocol.PairPath, new byte[CompanionProtocol.MaxJsonBodyBytes + 1])).Status);
        // None of these used the token.
        Assert.Equal(PairingSessionState.Open, _pairing.StateAt(_now));
    }

    [Fact]
    public async Task Pair_WaitsForTheUsersAnswer()
    {
        _pairing = new PairingSession(_now);
        PairRequest? asked = null;
        _router.ApprovePairing = (request, _) =>
        {
            asked = request;
            return Task.FromResult(false);
        };
        var declined = await Send("POST", CompanionProtocol.PairPath, Json(new PairRequest(_pairing.Token, "phone-0001", "", "ios", "1")));
        Assert.Equal(403, declined.Status);
        Assert.Equal(CompanionErrorCode.Declined, CompanionError.FromJson(declined.Body)!.Code);
        Assert.Equal("Phone", asked?.PhoneName);
        Assert.Empty(_devices.Devices);

        _pairing = new PairingSession(_now);
        _router.ApprovalTimeout = TimeSpan.FromMilliseconds(50);
        _router.ApprovePairing = async (_, cancellation) =>
        {
            await Task.Delay(Timeout.Infinite, cancellation);
            return true;
        };
        var unanswered = await Send("POST", CompanionProtocol.PairPath, Json(new PairRequest(_pairing.Token, "phone-0001", "P", "ios", "1")));
        Assert.Equal(CompanionErrorCode.Declined, CompanionError.FromJson(unanswered.Body)!.Code);
    }

    [Fact]
    public async Task Pair_CountsEveryTokenCheckUntilItEnds()
    {
        int settled = 0;
        _router.ApprovalSettled += (_, _) => settled++;
        // Refused tokens: counted while checked, then nothing is left waiting.
        _pairing = new PairingSession(_now, CompanionVectors.Token);
        await Send("POST", CompanionProtocol.PairPath, Json(new PairRequest("AAECAwQFBgcICQoLDA0ODx", "phone-0001", "P", "ios", "1")));
        Assert.Equal(0, _router.AwaitingApproval);
        Assert.Equal(1, settled);

        // A valid token: the used session's request is counted while the user answers.
        var asked = new TaskCompletionSource<(PairingSessionState State, int Awaiting)>(TaskCreationOptions.RunContinuationsAsynchronously);
        var answer = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        _router.ApprovePairing = (_, cancellation) =>
        {
            asked.TrySetResult((_pairing!.StateAt(_now), _router.AwaitingApproval));
            return answer.Task.WaitAsync(cancellation);
        };
        var pairing = Send("POST", CompanionProtocol.PairPath, Json(new PairRequest(CompanionVectors.TokenText, "phone-0001", "P", "ios", "1")));
        Assert.Equal((PairingSessionState.Used, 1), await asked.Task.WaitAsync(TimeSpan.FromSeconds(10)));
        Assert.Equal(1, _router.AwaitingApproval);
        Assert.Equal(1, settled);
        answer.SetResult(true);
        Assert.Equal(200, (await pairing).Status);
        Assert.Equal(0, _router.AwaitingApproval);
        Assert.Equal(2, settled);

        // The used token again: refused, counted and settled like the others.
        var reused = await Send("POST", CompanionProtocol.PairPath, Json(new PairRequest(CompanionVectors.TokenText, "phone-0002", "P", "ios", "1")));
        Assert.Equal(CompanionErrorCode.TokenUsed, CompanionError.FromJson(reused.Body)!.Code);
        Assert.Equal(0, _router.AwaitingApproval);
        Assert.Equal(3, settled);
    }

    [Fact]
    public async Task Hello_NeedsAPairedPhone()
    {
        Assert.Equal(401, (await Send("GET", CompanionProtocol.HelloPath)).Status);
        string secret = await PairPhone();
        var hello = HelloResponse.FromJson((await Send("GET", CompanionProtocol.HelloPath, device: "phone-0001", secret: secret)).Body);
        Assert.Equal(new HelloResponse(_devices.DesktopId, "AYTU-PC", 1, 7, CompanionProtocol.MaxUploadBytes), hello);
    }

    [Fact]
    public async Task Inbox_ReceivesAPackageOnce()
    {
        string secret = await PairPhone();
        var received = new List<CompanionPackageReceivedEventArgs>();
        _router.PackageReceived += (_, e) => received.Add(e);
        byte[] package = CompanionPackage.Make(CompanionFixtures.Minimal);
        var first = await Send("PUT", CompanionProtocol.InboxPrefix + "package-0001", package, "phone-0001", secret,
                               headers: (CompanionProtocol.TargetHeader, "current"));
        Assert.Equal(201, first.Status);
        Assert.Equal(new InboxResponse("package-0001", 1, false), InboxResponse.FromJson(first.Body));
        var e = Assert.Single(received);
        Assert.Equal(CompanionTarget.Current, e.Package.Target);
        Assert.Equal("phone-0001", e.Device.Id);
        Assert.True(File.Exists(e.Package.Path));
        Assert.Equal("Scan", e.Package.Document.Title);

        // A retry, even after the package was imported and released, is answered as a duplicate.
        _inbox.Release(e.Package);
        var again = await Send("PUT", CompanionProtocol.InboxPrefix + "package-0001", package, "phone-0001", secret);
        Assert.Equal(200, again.Status);
        Assert.Equal(new InboxResponse("package-0001", 1, true), InboxResponse.FromJson(again.Body));
        Assert.Single(received);
        Assert.Empty(_inbox.Pending());
    }

    [Fact]
    public async Task Inbox_RefusesBadUploads()
    {
        string secret = await PairPhone();
        byte[] package = CompanionPackage.Make(CompanionFixtures.Minimal);
        Assert.Equal(401, (await Send("PUT", CompanionProtocol.InboxPrefix + "package-0001", package)).Status);
        Assert.Equal(401, (await Send("PUT", CompanionProtocol.InboxPrefix + "package-0001", package, "phone-0001", CompanionVectors.SecretText)).Status);
        Assert.Equal(400, (await Send("PUT", CompanionProtocol.InboxPrefix + "..%2F..%2Fx", package, "phone-0001", secret)).Status);
        Assert.Equal(400, (await Send("PUT", CompanionProtocol.InboxPrefix + "short", package, "phone-0001", secret)).Status);
        Assert.Equal(411, (await Send("PUT", CompanionProtocol.InboxPrefix + "package-0001", null, "phone-0001", secret)).Status);
        Assert.Equal(405, (await Send("GET", CompanionProtocol.InboxPrefix + "package-0001", null, "phone-0001", secret)).Status);

        var damaged = (byte[])package.Clone();
        damaged[^200] ^= 0xFF;
        var refused = await Send("PUT", CompanionProtocol.InboxPrefix + "package-0002", damaged, "phone-0001", secret);
        Assert.Equal(422, refused.Status);
        Assert.Equal(CompanionErrorCode.InvalidPackage, CompanionError.FromJson(refused.Body)!.Code);
        Assert.Equal(422, (await Send("PUT", CompanionProtocol.InboxPrefix + "package-0003", Encoding.UTF8.GetBytes("not a zip"), "phone-0001", secret)).Status);
        // Nothing of the refused uploads is kept, and they can be sent again.
        Assert.Null(_inbox.Find("phone-0001", "package-0002"));
        Assert.Empty(Directory.GetFiles(Path.Combine(_directory, "Inbox", "phone-0001"), "*.part"));
        Assert.Empty(_inbox.Pending());
    }

    [Fact]
    public async Task Inbox_RefusesAnOversizeUploadBeforeReadingIt()
    {
        string secret = await PairPhone();
        var head = new HttpRequestHead("PUT", CompanionProtocol.InboxPrefix + "package-0001",
            [new("Host", "x"), new(CompanionProtocol.DeviceIdHeader, "phone-0001"), new("Authorization", "Bearer " + secret)],
            CompanionProtocol.MaxUploadBytes + 1, true);
        bool continued = false;
        var body = new CompanionRequestBody(new MemoryStream(), CompanionProtocol.MaxUploadBytes + 1, default, _ =>
        {
            continued = true;
            return Task.CompletedTask;
        });
        var response = await _router.HandleAsync(new CompanionRequest(head, body, Phone), CancellationToken.None);
        Assert.Equal(413, response.Status);
        Assert.False(continued);
        Assert.True(body.IsWithheld);
    }

    [Fact]
    public async Task Inbox_RefusesTheSamePackageWhileItIsReceived()
    {
        string secret = await PairPhone();
        Assert.True(_inbox.TryBegin("phone-0001", "package-0001"));
        var busy = await Send("PUT", CompanionProtocol.InboxPrefix + "package-0001", CompanionPackage.Make(CompanionFixtures.Minimal), "phone-0001", secret);
        Assert.Equal(409, busy.Status);
        _inbox.End("phone-0001", "package-0001");
    }

    [Fact]
    public async Task Outbox_ListsSendsAndForgets()
    {
        string secret = await PairPhone();
        string file = Path.Combine(_directory, "Scan 1.pdf");
        File.WriteAllBytes(file, Encoding.ASCII.GetBytes("%PDF-1.7 test"));
        var item = _outbox.Add("phone-0001", file, "Scan 1.pdf", "application/pdf", _now);
        var list = OutboxList.FromJson((await Send("GET", CompanionProtocol.OutboxPath, device: "phone-0001", secret: secret)).Body)!;
        Assert.Equal(item, Assert.Single(list.Items));
        var download = await Send("GET", CompanionProtocol.OutboxPrefix + item.Id, device: "phone-0001", secret: secret);
        Assert.Equal(200, download.Status);
        Assert.Equal(13, download.Length);
        await using (var stream = download.BodyStream!)
        {
            using var reader = new StreamReader(stream);
            Assert.Equal("%PDF-1.7 test", await reader.ReadToEndAsync());
        }
        Assert.Contains(download.Headers, h => h.Key == "Content-Type" && h.Value == "application/pdf");
        Assert.Equal(204, (await Send("DELETE", CompanionProtocol.OutboxPrefix + item.Id, device: "phone-0001", secret: secret)).Status);
        Assert.Equal(404, (await Send("DELETE", CompanionProtocol.OutboxPrefix + item.Id, device: "phone-0001", secret: secret)).Status);
        Assert.Equal(404, (await Send("GET", CompanionProtocol.OutboxPrefix + item.Id, device: "phone-0001", secret: secret)).Status);
        // Another phone sees nothing of it.
        string other = await PairPhone("phone-0002");
        _outbox.Add("phone-0001", file, "Scan 2.pdf", "application/pdf", _now);
        Assert.Empty(OutboxList.FromJson((await Send("GET", CompanionProtocol.OutboxPath, device: "phone-0002", secret: other)).Body)!.Items);
    }

    [Fact]
    public async Task Outbox_ListingWaitsForSomethingToArrive()
    {
        string secret = await PairPhone();
        string file = Path.Combine(_directory, "a.pdf");
        File.WriteAllText(file, "x");
        var listing = Send("GET", CompanionProtocol.OutboxPath + "?wait=5", device: "phone-0001", secret: secret);
        await Task.Delay(100);
        Assert.False(listing.IsCompleted);
        _outbox.Add("phone-0001", file, "a.pdf", "application/pdf", _now);
        var list = OutboxList.FromJson((await listing.WaitAsync(TimeSpan.FromSeconds(5))).Body)!;
        Assert.Single(list.Items);
        Assert.Equal(400, (await Send("GET", CompanionProtocol.OutboxPath + "?wait=soon", device: "phone-0001", secret: secret)).Status);
    }

    [Fact]
    public async Task Outbox_DropsItemsAfterAWeek()
    {
        string secret = await PairPhone();
        string file = Path.Combine(_directory, "a.pdf");
        File.WriteAllText(file, "x");
        _outbox.Add("phone-0001", file, "a.pdf", "application/pdf", _now);
        _now = _now.AddDays(8);
        Assert.Empty(OutboxList.FromJson((await Send("GET", CompanionProtocol.OutboxPath, device: "phone-0001", secret: secret)).Body)!.Items);
    }

    [Fact]
    public async Task DeviceSelf_ForgetsThePhone()
    {
        string secret = await PairPhone();
        PairedDevice? removed = null;
        _router.DeviceRemoved += (_, device) => removed = device;
        Assert.Equal(204, (await Send("DELETE", CompanionProtocol.DeviceSelfPath, device: "phone-0001", secret: secret)).Status);
        Assert.Equal("phone-0001", removed?.Id);
        Assert.Empty(_devices.Devices);
        Assert.Equal(401, (await Send("GET", CompanionProtocol.HelloPath, device: "phone-0001", secret: secret)).Status);
    }

    [Fact]
    public async Task UnknownPaths_AreNotFound()
    {
        Assert.Equal(404, (await Send("GET", "/")).Status);
        Assert.Equal(404, (await Send("GET", "/v2/health")).Status);
        Assert.Equal(405, (await Send("PUT", CompanionProtocol.OutboxPrefix + "0123456789abcdef", [])).Status);
    }

    [Fact]
    public async Task WrongSecrets_AreRateLimited()
    {
        string secret = await PairPhone();
        var attacker = IPAddress.Parse("192.168.1.66");
        for (int i = 0; i < CompanionRateLimiter.MaxFailures; i++)
        {
            Assert.Equal(401, (await Send("GET", CompanionProtocol.HelloPath, device: "phone-0001", secret: CompanionVectors.SecretText, from: attacker)).Status);
        }
        var limited = await Send("GET", CompanionProtocol.HelloPath, device: "phone-0001", secret: secret, from: attacker);
        Assert.Equal(429, limited.Status);
        Assert.Contains(limited.Headers, h => h.Key == "Retry-After");
        // Others are not affected, and the attacker may try again a minute later.
        Assert.Equal(200, (await Send("GET", CompanionProtocol.HelloPath, device: "phone-0001", secret: secret)).Status);
        _now = _now.AddMinutes(1);
        Assert.Equal(200, (await Send("GET", CompanionProtocol.HelloPath, device: "phone-0001", secret: secret, from: attacker)).Status);
    }

    [Fact]
    public async Task WrongTokens_AreRateLimitedToo()
    {
        _pairing = new PairingSession(_now);
        var attacker = IPAddress.Parse("192.168.1.66");
        for (int i = 0; i < PairingSession.MaxFailedAttempts; i++)
        {
            await Send("POST", CompanionProtocol.PairPath, Json(new PairRequest(CompanionVectors.TokenText, "phone-0001", "P", "ios", "1")), from: attacker);
        }
        // The session is closed now, even for the right token.
        var closed = await Send("POST", CompanionProtocol.PairPath, Json(new PairRequest(_pairing.Token, "phone-0001", "P", "ios", "1")));
        Assert.Equal(CompanionErrorCode.PairingClosed, CompanionError.FromJson(closed.Body)!.Code);
    }
}
