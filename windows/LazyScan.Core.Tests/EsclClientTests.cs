using System.Net;
using System.Text;
using LazyScan.Core;
using Xunit;

namespace LazyScan.Core.Tests;

// Mirrored by Tests/CompleteScannerTests/EsclClientTests.swift (same cases; there a URLProtocol stub
// plays the device). EsclClient and EsclScannerSession against a stub HttpMessageHandler that plays a
// device; retry waits run on a fake clock. Pages are "decoded" by a stub decoder: "PAGE w h" becomes a
// w×h image, anything else is unreadable.

[Collection(WallClockCollection.Name)]
public class EsclClientTests
{
    private static readonly Uri Base = new("http://scanner.test/eSCL/");
    private const string Job = "http://scanner.test/eSCL/ScanJobs/7";

    /// <summary>A scripted device: one responder per request, keyed by "METHOD /path"; records every request.</summary>
    private sealed class FakeDevice : HttpMessageHandler
    {
        private readonly object _gate = new();
        private readonly Dictionary<string, Queue<Func<HttpResponseMessage>>> _scripts = [];
        public List<string> Requests { get; } = [];
        public List<string> Bodies { get; } = [];
        public string AdfState { get; set; } = "ScannerAdfLoaded";
        public string State { get; set; } = "Idle";
        /// <summary>Completes the POST only when set (cancel-during-POST test).</summary>
        public TaskCompletionSource? HoldPost { get; set; }

        /// <summary>Queue responses for a request; the last one repeats.</summary>
        public FakeDevice On(string request, params Func<HttpResponseMessage>[] responses)
        {
            _scripts[request] = new Queue<Func<HttpResponseMessage>>(responses);
            return this;
        }

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
        {
            string key = $"{request.Method} {request.RequestUri!.AbsolutePath}";
            lock (_gate)
            {
                Requests.Add(key);
                if (request.Content is not null) Bodies.Add(request.Content.ReadAsStringAsync(token).Result);
            }
            if (request.Method == HttpMethod.Post && HoldPost is { } hold) await hold.Task;
            if (key == "GET /eSCL/ScannerStatus" && !_scripts.ContainsKey(key))
            {
                return Text(HttpStatusCode.OK, Status(State, AdfState));
            }
            Func<HttpResponseMessage> next;
            lock (_gate)
            {
                if (!_scripts.TryGetValue(key, out var queue)) return new HttpResponseMessage(HttpStatusCode.NotFound);
                next = queue.Count > 1 ? queue.Dequeue() : queue.Peek();
            }
            return next();
        }
    }

    private static HttpResponseMessage Text(HttpStatusCode status, string body) =>
        new(status) { Content = new StringContent(body, Encoding.UTF8, "text/xml") };

    private static Func<HttpResponseMessage> Respond(HttpStatusCode status) => () => new HttpResponseMessage(status);

    private static Func<HttpResponseMessage> Page(int width, int height) => () =>
        new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(Encoding.ASCII.GetBytes($"PAGE {width} {height}")) };

    private static Func<HttpResponseMessage> Garbage() => () =>
        new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent("not an image"u8.ToArray()) };

    private static Func<HttpResponseMessage> Created(string location) => () =>
    {
        var response = new HttpResponseMessage(HttpStatusCode.Created);
        response.Headers.Location = new Uri(location, UriKind.RelativeOrAbsolute);
        return response;
    };

    private static string Status(string state, string adfState) => $"""
        <?xml version="1.0" encoding="UTF-8"?>
        <scan:ScannerStatus xmlns:scan="http://schemas.hp.com/imaging/escl/2011/05/03" xmlns:pwg="http://www.pwg.org/schemas/2010/12/sm">
          <pwg:Version>2.6</pwg:Version><pwg:State>{state}</pwg:State><scan:AdfState>{adfState}</scan:AdfState>
        </scan:ScannerStatus>
        """;

    private static RgbaImage Decode(byte[] data)
    {
        string[] parts = Encoding.ASCII.GetString(data).Split(' ');
        if (parts.Length != 3 || parts[0] != "PAGE") throw new FormatException("unknown image format");
        int w = int.Parse(parts[1]), h = int.Parse(parts[2]);
        return new RgbaImage(w, h, new byte[w * h * 4]);
    }

    private sealed class FakeClock
    {
        public TimeSpan Now { get; private set; }
        public List<TimeSpan> Delays { get; } = [];

        public Task Delay(TimeSpan wait, CancellationToken token)
        {
            token.ThrowIfCancellationRequested();
            Delays.Add(wait);
            Now += wait;
            return Task.CompletedTask;
        }
    }

    private static EsclClient Client(FakeDevice device, FakeClock? clock = null)
    {
        clock ??= new FakeClock();
        return new EsclClient(Base, device, Decode, "Fake MFP", validator: null, new EsclClientOptions
        {
            Delay = clock.Delay,
            StartClock = () => () => clock.Now,
        });
    }

    private static EsclCapabilities Caps => EsclCapabilitiesParser.Parse(EsclTests.PlatenAndDuplexAdf);

    private static EsclScanRequest FeederRequest =>
        EsclScanRequest.Create(Caps, ScanSource.DocumentFeeder, ColorMode.Grayscale, 300, selection: null);

    private static Task<EsclJobResult> Scan(EsclClient client, CancellationToken token = default) =>
        client.ScanAsync(FeederRequest, ColorMode.Grayscale, ScanSource.DocumentFeeder, progress: null, token);

    // MARK: - Capabilities

    [Fact]
    public async Task ReadsTheCapabilities()
    {
        var device = new FakeDevice().On("GET /eSCL/ScannerCapabilities",
            () => Text(HttpStatusCode.OK, EsclTests.PlatenAndDuplexAdf));
        using var client = Client(device);
        var caps = await client.GetCapabilitiesAsync();
        Assert.Equal("HP Color LaserJet MFP M479fdw", caps.MakeAndModel);
        Assert.True(caps.HasPlaten && caps.HasAdf);
        Assert.Equal(["GET /eSCL/ScannerCapabilities"], device.Requests);
    }

    [Fact]
    public async Task CapabilitiesFailuresKeepTheirKind()
    {
        using var missing = Client(new FakeDevice());
        await Assert.ThrowsAsync<HttpRequestException>(() => missing.GetCapabilitiesAsync());

        using var notXml = Client(new FakeDevice().On("GET /eSCL/ScannerCapabilities",
            () => Text(HttpStatusCode.OK, "<html>printer home page")));
        await Assert.ThrowsAsync<FormatException>(() => notXml.GetCapabilitiesAsync());
    }

    // MARK: - Jobs

    [Fact]
    public async Task BusyAnswersAreRetriedThenPagesUntil404()
    {
        var device = new FakeDevice()
            .On("POST /eSCL/ScanJobs", Respond(HttpStatusCode.ServiceUnavailable), Created("ScanJobs/7"))
            .On("GET /eSCL/ScanJobs/7/NextDocument",
                Respond(HttpStatusCode.ServiceUnavailable), Page(10, 20), Page(10, 20), Respond(HttpStatusCode.NotFound));
        var clock = new FakeClock();
        using var client = Client(device, clock);
        var progress = new List<string>();
        var result = await client.ScanAsync(FeederRequest, ColorMode.Grayscale, ScanSource.DocumentFeeder,
                                            p => progress.Add(p.Message), CancellationToken.None);

        Assert.Equal(2, result.Pages.Count);
        Assert.Null(result.Stop);
        Assert.All(result.Pages, p =>
        {
            Assert.Equal(300, p.Dpi);
            Assert.Equal(ColorMode.Grayscale, p.ColorMode);
            Assert.Equal(10, p.Image.Width);
        });
        Assert.Equal(["Transferring page 1…", "Transferring page 2…"], progress);
        Assert.Equal([TimeSpan.FromSeconds(0.5), TimeSpan.FromSeconds(0.5)], clock.Delays);
        // A job the device finished (404) is not deleted.
        await client.WhenCleanedUp();
        Assert.Equal(
        [
            "POST /eSCL/ScanJobs", "POST /eSCL/ScanJobs",
            "GET /eSCL/ScanJobs/7/NextDocument", "GET /eSCL/ScanJobs/7/NextDocument",
            "GET /eSCL/ScanJobs/7/NextDocument", "GET /eSCL/ScanJobs/7/NextDocument",
        ], device.Requests);
        Assert.Contains("<pwg:InputSource>Feeder</pwg:InputSource>", device.Bodies[0]);
    }

    [Theory]
    [InlineData("ScanJobs/7")]          // relative to the ScanJobs URL
    [InlineData("/eSCL/ScanJobs/7/")]   // host-relative, with a trailing slash
    [InlineData(Job)]                   // absolute
    public async Task JobLocationsResolve(string location)
    {
        var device = new FakeDevice()
            .On("POST /eSCL/ScanJobs", Created(location))
            .On("GET /eSCL/ScanJobs/7/NextDocument", Page(4, 4), Respond(HttpStatusCode.NotFound));
        using var client = Client(device);
        var result = await Scan(client);
        Assert.Single(result.Pages);
    }

    [Fact]
    public async Task AJobEndingBeforeItsFirstPageReportsTheEmptyFeeder()
    {
        var device = new FakeDevice { AdfState = "ScannerAdfEmpty" }
            .On("POST /eSCL/ScanJobs", Created("ScanJobs/7"))
            .On("GET /eSCL/ScanJobs/7/NextDocument", Respond(HttpStatusCode.NotFound));
        using var client = Client(device);
        var error = await Assert.ThrowsAsync<ScanException>(() => Scan(client));
        Assert.Equal(ScannerProblem.FeederEmpty, error.Problem);
        Assert.Equal(ScannerProblems.Describe(ScannerProblem.FeederEmpty), error.Message);
        await client.WhenCleanedUp();
        Assert.DoesNotContain(device.Requests, r => r.StartsWith("DELETE", StringComparison.Ordinal));
    }

    [Fact]
    public async Task AJobEndingWithoutPagesWhileTheFeederLooksFineReturnsNothing()
    {
        var device = new FakeDevice()
            .On("POST /eSCL/ScanJobs", Created("ScanJobs/7"))
            .On("GET /eSCL/ScanJobs/7/NextDocument", Respond(HttpStatusCode.NotFound));
        using var client = Client(device);
        var result = await Scan(client);
        Assert.Empty(result.Pages);
        Assert.Null(result.Stop);
    }

    [Fact]
    public async Task ARejectedJobIsExplainedByTheStatus()
    {
        var device = new FakeDevice { AdfState = "ScannerAdfJam" }
            .On("POST /eSCL/ScanJobs", Respond(HttpStatusCode.Conflict));
        using var client = Client(device);
        var error = await Assert.ThrowsAsync<ScanException>(() => Scan(client));
        Assert.Equal(ScannerProblem.PaperJam, error.Problem);
        Assert.EndsWith("(HTTP 409)", error.Message);

        var plain = new FakeDevice().On("POST /eSCL/ScanJobs", Respond(HttpStatusCode.BadRequest));
        using var plainClient = Client(plain);
        var rejected = await Assert.ThrowsAsync<ScanException>(() => Scan(plainClient));
        Assert.Equal(ScanErrorKind.ScanFailed, rejected.Kind);
        Assert.Equal("Scan failed: Fake MFP rejected the scan job (HTTP 400).", rejected.Message);
    }

    [Fact]
    public async Task ABusyDeviceThatNeverAcceptsIsReportedBusy()
    {
        var device = new FakeDevice().On("POST /eSCL/ScanJobs", Respond(HttpStatusCode.ServiceUnavailable));
        var clock = new FakeClock();
        using var client = Client(device, clock);
        var error = await Assert.ThrowsAsync<ScanException>(() => Scan(client));
        Assert.Equal(ScannerProblem.Busy, error.Problem);
        Assert.True(clock.Now <= TimeSpan.FromSeconds(60));
        Assert.Equal(16, device.Requests.Count(r => r == "POST /eSCL/ScanJobs"));
    }

    [Fact]
    public async Task AFailureAfterTheFirstPageKeepsThePagesAndDeletesTheJob()
    {
        var device = new FakeDevice { AdfState = "ScannerAdfJam" }
            .On("POST /eSCL/ScanJobs", Created("ScanJobs/7"))
            .On("GET /eSCL/ScanJobs/7/NextDocument", Page(4, 4), Respond(HttpStatusCode.InternalServerError));
        using var client = Client(device);
        var result = await Scan(client);
        Assert.Single(result.Pages);
        Assert.Equal(ScannerProblem.PaperJam, result.Stop?.Problem);
        Assert.Equal("Scanning stopped after 1 page; it was kept. " + ScannerProblems.Describe(ScannerProblem.PaperJam)
                     + " (HTTP 500)", result.Stop!.Message(pagesKept: 1));
        await client.WhenCleanedUp();
        Assert.Equal("DELETE /eSCL/ScanJobs/7", device.Requests[^1]);
    }

    [Fact]
    public async Task AnUnreadablePageStopsTheBatchOrFailsTheScan()
    {
        var later = new FakeDevice()
            .On("POST /eSCL/ScanJobs", Created("ScanJobs/7"))
            .On("GET /eSCL/ScanJobs/7/NextDocument", Page(4, 4), Garbage());
        using var laterClient = Client(later);
        var result = await Scan(laterClient);
        Assert.Single(result.Pages);
        Assert.StartsWith("Scan failed: Fake MFP sent page 2 in a form that could not be read", result.Stop?.Reason);
        await laterClient.WhenCleanedUp();
        Assert.Contains("DELETE /eSCL/ScanJobs/7", later.Requests);

        var first = new FakeDevice()
            .On("POST /eSCL/ScanJobs", Created("ScanJobs/7"))
            .On("GET /eSCL/ScanJobs/7/NextDocument", Garbage());
        using var firstClient = Client(first);
        var error = await Assert.ThrowsAsync<ScanException>(() => Scan(firstClient));
        Assert.Equal(ScanErrorKind.ScanFailed, error.Kind);
    }

    [Fact]
    public async Task CancellingMidJobThrowsCancelledAndDeletesTheJob()
    {
        using var cancellation = new CancellationTokenSource();
        var device = new FakeDevice()
            .On("POST /eSCL/ScanJobs", Created("ScanJobs/7"))
            .On("GET /eSCL/ScanJobs/7/NextDocument", () =>
            {
                cancellation.Cancel(); // the user cancels while page 1 arrives
                return Page(4, 4)();
            });
        using var client = Client(device);
        var error = await Assert.ThrowsAsync<ScanException>(() => Scan(client, cancellation.Token));
        Assert.Equal(ScanErrorKind.Cancelled, error.Kind);
        await client.WhenCleanedUp();
        Assert.Equal("DELETE /eSCL/ScanJobs/7", device.Requests[^1]);
    }

    [Fact]
    public async Task CancellingDuringThePostDeletesTheJobOnceItIsCreated()
    {
        var hold = new TaskCompletionSource();
        var device = new FakeDevice { HoldPost = hold }.On("POST /eSCL/ScanJobs", Created("ScanJobs/7"));
        using var client = Client(device);
        using var cancellation = new CancellationTokenSource();
        var scan = Scan(client, cancellation.Token);
        cancellation.Cancel();
        var error = await Assert.ThrowsAsync<ScanException>(() => scan);
        Assert.Equal(ScanErrorKind.Cancelled, error.Kind);
        hold.SetResult(); // the device answers the POST after the cancel
        await client.WhenCleanedUp();
        Assert.Equal(["POST /eSCL/ScanJobs", "DELETE /eSCL/ScanJobs/7"], device.Requests);
    }

    [Fact]
    public async Task ATimeoutBeforeTheFirstPageIsACommunicationError()
    {
        var device = new FakeDevice()
            .On("POST /eSCL/ScanJobs", Created("ScanJobs/7"))
            .On("GET /eSCL/ScanJobs/7/NextDocument", () => throw new TaskCanceledException("timed out"));
        using var client = Client(device);
        var error = await Assert.ThrowsAsync<ScanException>(() => Scan(client));
        Assert.Equal(ScannerProblem.CommunicationError, error.Problem);
    }

    [Fact]
    public async Task ADroppedConnectionAfterAPageKeepsIt()
    {
        var device = new FakeDevice()
            .On("POST /eSCL/ScanJobs", Created("ScanJobs/7"))
            .On("GET /eSCL/ScanJobs/7/NextDocument", Page(4, 4), () => throw new HttpRequestException("reset"));
        using var client = Client(device);
        var result = await Scan(client);
        Assert.Single(result.Pages);
        Assert.Equal(ScannerProblem.CommunicationError, result.Stop?.Problem);
    }

    // MARK: - Session

    private static EsclScannerSession Session(FakeDevice device, string capabilities)
    {
        var info = new ScannerInfo("escl:test", "Fake MFP", "Network", Backend: "escl");
        return new EsclScannerSession(info, Client(device), EsclCapabilitiesParser.Parse(capabilities));
    }

    [Fact]
    public async Task SessionScansAndReportsAStoppedBatch()
    {
        var device = new FakeDevice { AdfState = "ScannerAdfJam" }
            .On("POST /eSCL/ScanJobs", Created("ScanJobs/7"))
            .On("GET /eSCL/ScanJobs/7/NextDocument", Page(4, 4), Page(4, 4), Respond(HttpStatusCode.InternalServerError));
        var session = Session(device, EsclTests.PlatenAndDuplexAdf);
        var settings = new ScanSettings { Source = ScanSource.DocumentFeeder, Resolution = 300, ColorMode = ColorMode.Color };
        var pages = await session.PerformScanAsync(settings, selection: null);
        Assert.Equal(2, pages.Count);
        Assert.Equal(ScannerProblem.PaperJam, session.LastScanStop?.Problem);

        // The next scan starts without the old stop.
        device.On("GET /eSCL/ScanJobs/7/NextDocument", Page(4, 4), Respond(HttpStatusCode.NotFound));
        pages = await session.PerformScanAsync(settings, selection: null);
        Assert.Single(pages);
        Assert.Null(session.LastScanStop);
        await session.CloseAsync();
    }

    [Fact]
    public async Task SessionWithoutPagesOrPlatenFailsClearly()
    {
        var device = new FakeDevice()
            .On("POST /eSCL/ScanJobs", Created("ScanJobs/7"))
            .On("GET /eSCL/ScanJobs/7/NextDocument", Respond(HttpStatusCode.NotFound));
        var session = Session(device, EsclTests.PlatenAndDuplexAdf);
        var error = await Assert.ThrowsAsync<ScanException>(
            () => session.PerformScanAsync(new ScanSettings(), selection: null));
        Assert.Equal("Scan failed: The scanner did not return any image data.", error.Message);

        var feederOnly = Session(new FakeDevice(), EsclTests.FeederOnly);
        var overview = await Assert.ThrowsAsync<ScanException>(() => feederOnly.PerformOverviewScanAsync(new ScanSettings()));
        Assert.Equal(ScanErrorKind.Unsupported, overview.Kind);
        Assert.False((await feederOnly.GetCapabilitiesAsync()).SupportsOverview);
    }

    [Fact]
    public async Task SessionOverviewUsesTheFlatbedInColor()
    {
        var device = new FakeDevice()
            .On("POST /eSCL/ScanJobs", Created("ScanJobs/7"))
            .On("GET /eSCL/ScanJobs/7/NextDocument", Page(8, 11), Respond(HttpStatusCode.NotFound));
        var session = Session(device, EsclTests.PlatenAndDuplexAdf);
        var image = await session.PerformOverviewScanAsync(new ScanSettings { ColorMode = ColorMode.BlackWhite });
        Assert.Equal(8, image.Width);
        Assert.Contains("<pwg:InputSource>Platen</pwg:InputSource>", device.Bodies[0]);
        Assert.Contains("<scan:ColorMode>RGB24</scan:ColorMode>", device.Bodies[0]);
    }

    [Fact]
    public async Task SessionCancelBeforeTheJobStartsCancelsIt()
    {
        var hold = new TaskCompletionSource();
        var device = new FakeDevice { HoldPost = hold }.On("POST /eSCL/ScanJobs", Created("ScanJobs/7"));
        var session = Session(device, EsclTests.PlatenAndDuplexAdf);
        var scan = session.PerformScanAsync(new ScanSettings { Source = ScanSource.DocumentFeeder }, selection: null);
        session.CancelScan();
        var error = await Assert.ThrowsAsync<ScanException>(() => scan);
        Assert.Equal(ScanErrorKind.Cancelled, error.Kind);
        hold.SetResult();
        await session.Client.WhenCleanedUp();
        Assert.Equal("DELETE /eSCL/ScanJobs/7", device.Requests[^1]);
    }
}
