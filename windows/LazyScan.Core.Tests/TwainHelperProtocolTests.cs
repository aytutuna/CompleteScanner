using LazyScan.Core;
using Xunit;

namespace LazyScan.Core.Tests;

// TWAIN is Windows-only: no Swift counterpart. The 32-bit helper's protocol: every message
// encodes and decodes to itself, malformed and random input is refused with
// TwainProtocolException only (never another exception, never a huge allocation), and errors
// cross the pipe as the same exceptions.

public class TwainHelperProtocolTests
{
    /// <summary>One message of every type, with values off their defaults.</summary>
    internal static List<TwainHelperMessage> Samples() =>
    [
        new TwainHelperHello(TwainHelperProtocol.Version) { RequestId = 1 },
        new TwainHelperListSources { RequestId = 2 },
        new TwainHelperOpen("Canon DR-C225 (é ✓)") { RequestId = 3 },
        new TwainHelperReadCapabilities { RequestId = 4 },
        new TwainHelperApply(new TwainScanRequest(true, TwainPixelTypes.Gray, 8, 300, new RectD(0.25, 0.5, 8.5, 11.7), -1,
                                                  ShowDriverWindow: true, PreferMemory: false, Duplex: true, SupportedSize: 3))
        {
            RequestId = 5,
        },
        new TwainHelperApply(new TwainScanRequest(false, TwainPixelTypes.Rgb, 8, 150, null, 1, false, true)) { RequestId = 6 },
        new TwainHelperEnable(true) { RequestId = 7 },
        new TwainHelperCancel(),
        new TwainHelperDisable(15000) { RequestId = 8 },
        new TwainHelperDisable(-1) { RequestId = 9 },
        new TwainHelperReadDuplex { RequestId = 10 },
        new TwainHelperClose { RequestId = 11 },
        new TwainHelperShutdown { RequestId = 12 },
        new TwainHelperHelloReply(TwainHelperProtocol.Version, 32) { RequestId = 1 },
        new TwainHelperSourceList(TwainAvailability.Available,
                                  [new TwainHelperSource("A", "Acme", "Family"), new TwainHelperSource("B ", null, null)]) { RequestId = 2 },
        new TwainHelperSourceList(TwainAvailability.NoDataSourceManager, []) { RequestId = 2 },
        new TwainHelperDone { RequestId = 3 },
        new TwainHelperCapabilities(new TwainDeviceCaps
        {
            Online = false,
            UIControllable = false,
            HasFlatbed = false,
            HasFeeder = true,
            DuplexKind = TwainDuplexKinds.OnePass,
            Resolutions = [100, 200, 300],
            NativeResolution = 600,
            PixelTypes = [0, 1, 2],
            FlatbedSizeInches = new SizeD(8.5, 11.7),
            FeederSizeInches = null,
            SupportedSizes = [1, 3, 5],
            MemoryTransfer = false,
        }) { RequestId = 4 },
        new TwainHelperCapabilities(new TwainDeviceCaps()) { RequestId = 4 },
        new TwainHelperApplied(new TwainApplied(TwainTransferMechanisms.Memory, TwainPixelFlavors.Vanilla, false, false, true)) { RequestId = 5 },
        new TwainHelperApplied(new TwainApplied(TwainTransferMechanisms.Native)) { RequestId = 5 },
        new TwainHelperDisabled(false) { RequestId = 8 },
        new TwainHelperDuplex(null) { RequestId = 10 },
        new TwainHelperDuplex(true) { RequestId = 10 },
        new TwainHelperFailure(new TwainHelperError(TwainHelperErrorKind.Twain, "Starting the scan", 1, 20,
                                                    ScanErrorKind.ScanFailed, null, "jam")) { RequestId = 7 },
        new TwainHelperFailure(new TwainHelperError(TwainHelperErrorKind.Scan, "Opening the scanner", 0, 0,
                                                    ScanErrorKind.DeviceUnavailable, ScannerProblem.Offline, null)) { RequestId = 3 },
        new TwainHelperImageReady(new TwainImageInfo(850, -1, TwainPixelTypes.BlackWhite, 1, 200.5, 199.5, 0, true)),
        new TwainHelperImageReady(null),
        new TwainHelperStripBegin(850, 10, 0, 20, 107, 0, 1070),
        new TwainHelperNativeBegin(1_000_000),
        new TwainHelperChunk([1, 2, 3, 255]),
        new TwainHelperChunk(new byte[TwainHelperProtocol.ChunkSize]),
        new TwainHelperTransferFailed(TwainReturnCodes.Failure, TwainConditionCodes.PaperJam, "jammed"),
        new TwainHelperTransferFailed(TwainReturnCodes.Failure, TwainConditionCodes.Bummer, null),
        new TwainHelperTransferCancelled(),
        new TwainHelperFinished(),
        new TwainHelperProgress(0.5, "Receiving the page…"),
        new TwainHelperProgress(null, ""),
    ];

    private static TwainHelperMessage RoundTrip(TwainHelperMessage message)
    {
        using var stream = new MemoryStream(TwainHelperProtocol.EncodeFrame(message));
        var decoded = TwainHelperProtocol.ReadFrame(stream);
        Assert.NotNull(decoded);
        Assert.Null(TwainHelperProtocol.ReadFrame(stream));
        return decoded;
    }

    [Fact]
    public void EveryMessage_DecodesToItself()
    {
        var samples = Samples();
        // Every type is covered.
        Assert.Equal(Enum.GetValues<TwainHelperMessageType>().Order(), samples.Select(s => s.Type).Distinct().Order());
        foreach (var message in samples)
        {
            var decoded = RoundTrip(message);
            Assert.Equal(message.GetType(), decoded.GetType());
            Assert.Equal(message.RequestId, decoded.RequestId);
            // Lists and capabilities have no value equality: the encodings are compared.
            Assert.Equal(TwainHelperProtocol.Encode(message), TwainHelperProtocol.Encode(decoded));
        }
    }

    [Fact]
    public void Fields_SurviveTheTrip()
    {
        var request = Assert.IsType<TwainHelperApply>(RoundTrip(Samples()[4])).Request;
        Assert.Equal(Samples().OfType<TwainHelperApply>().First().Request, request);
        var caps = Assert.IsType<TwainHelperCapabilities>(RoundTrip(Samples().OfType<TwainHelperCapabilities>().First())).Caps;
        Assert.Equal((false, false, false, true, 1, 600, false), (caps.Online, caps.UIControllable, caps.HasFlatbed, caps.HasFeeder,
                                                                  caps.DuplexKind, caps.NativeResolution, caps.MemoryTransfer));
        Assert.Equal([100, 200, 300], caps.Resolutions);
        Assert.Equal(new SizeD(8.5, 11.7), caps.FlatbedSizeInches);
        Assert.Null(caps.FeederSizeInches);
        var list = Assert.IsType<TwainHelperSourceList>(RoundTrip(Samples().OfType<TwainHelperSourceList>().First()));
        Assert.Equal([new TwainHelperSource("A", "Acme", "Family"), new TwainHelperSource("B ", null, null)], list.Sources);
        var info = Assert.IsType<TwainHelperImageReady>(RoundTrip(Samples().OfType<TwainHelperImageReady>().First())).Info;
        Assert.Equal(new TwainImageInfo(850, -1, TwainPixelTypes.BlackWhite, 1, 200.5, 199.5, 0, true), info);
        Assert.Equal("Canon DR-C225 (é ✓)", Assert.IsType<TwainHelperOpen>(RoundTrip(Samples()[2])).Name);
    }

    public static TheoryData<string, int[]> ResolutionLists => new()
    {
        { "none", [] },
        { "one", [300] },
        { "a ladder", [75, 100, 150, 200, 300, 600, 1200] },
        { "even steps", [100, 200, 300, 400] },
        { "repeats and out of order", [300, 300, 300, 100, 150] },
        { "the extremes", [int.MinValue, int.MaxValue, 0, -5, int.MaxValue, int.MinValue] },
        { "a fine range", [.. ResolutionList.ExpandRange(50, 9600, 1)] },
        { "a stepped range", [.. ResolutionList.ExpandRange(50, 4800, 25)] },
        { "the widest range", [.. ResolutionList.ExpandRange(1, int.MaxValue, 1)] },
    };

    [Theory]
    [MemberData(nameof(ResolutionLists))]
    public void Resolutions_CrossExactly_HoweverManyARangeGives(string why, int[] resolutions)
    {
        var caps = new TwainDeviceCaps { HasFlatbed = true, Resolutions = resolutions, NativeResolution = 1200 };
        var frame = TwainHelperProtocol.EncodeFrame(new TwainHelperCapabilities(caps) { RequestId = 4 });
        var decoded = Assert.IsType<TwainHelperCapabilities>(RoundTrip(new TwainHelperCapabilities(caps) { RequestId = 4 })).Caps;
        Assert.True(resolutions.SequenceEqual(decoded.Resolutions), why);
        Assert.Equal(TwainScanRequests.Capabilities(caps).SupportedResolutions, TwainScanRequests.Capabilities(decoded).SupportedResolutions);
        // A range is one run, however many values it has.
        if (why.EndsWith("range", StringComparison.Ordinal)) Assert.True(frame.Length < 100, $"{why}: {frame.Length} bytes");
    }

    [Fact]
    public void MoreResolutionsThanARangeCanGive_AreRefusedWhenEncoding()
    {
        var caps = new TwainDeviceCaps { Resolutions = [.. Enumerable.Range(1, TwainHelperProtocol.MaxResolutionCount + 1)] };
        Assert.Throws<ArgumentException>(() => TwainHelperProtocol.EncodeFrame(new TwainHelperCapabilities(caps) { RequestId = 4 }));
    }

    [Fact]
    public void ReadFrame_EndsCleanlyOnlyBetweenFrames()
    {
        Assert.Null(TwainHelperProtocol.ReadFrame(new MemoryStream()));
        var frame = TwainHelperProtocol.EncodeFrame(new TwainHelperOpen("scanner") { RequestId = 1 });
        for (int cut = 1; cut < frame.Length; cut++)
        {
            Assert.Throws<TwainProtocolException>(() => TwainHelperProtocol.ReadFrame(new MemoryStream(frame[..cut])));
        }
    }

    /// <summary>A payload: type, request id, then <paramref name="fields"/>.</summary>
    private static byte[] Payload(TwainHelperMessageType type, int requestId, params byte[][] fields)
    {
        var bytes = new List<byte> { (byte)type };
        bytes.AddRange(BitConverter.GetBytes(requestId));
        foreach (var field in fields) bytes.AddRange(field);
        return [.. bytes];
    }

    private static byte[] I(int value) => BitConverter.GetBytes(value);
    private static byte[] U(uint value) => BitConverter.GetBytes(value);
    private static byte[] D(double value) => BitConverter.GetBytes(value);
    private static byte[] B(params byte[] values) => values;

    public static TheoryData<string, byte[]> Malformed => new()
    {
        { "empty", [] },
        { "no request id", [(byte)TwainHelperMessageType.Done, 0, 0] },
        { "unknown type", Payload((TwainHelperMessageType)200, 1) },
        { "negative request id", Payload(TwainHelperMessageType.Done, -5) },
        { "trailing bytes", Payload(TwainHelperMessageType.Done, 1, B(0)) },
        { "wrong magic", Payload(TwainHelperMessageType.Hello, 1, U(0x12345678), I(1)) },
        { "boolean 2", Payload(TwainHelperMessageType.Enable, 1, B(2)) },
        { "optional boolean 3", Payload(TwainHelperMessageType.Duplex, 1, B(3)) },
        { "string longer than the message", Payload(TwainHelperMessageType.Open, 1, I(100), B(65, 66)) },
        { "string over the limit", Payload(TwainHelperMessageType.Open, 1, I(TwainHelperProtocol.MaxStringBytes + 1)) },
        { "string length below -1", Payload(TwainHelperMessageType.Open, 1, I(-2)) },
        { "required string missing", Payload(TwainHelperMessageType.Open, 1, I(-1)) },
        { "invalid UTF-8", Payload(TwainHelperMessageType.Open, 1, I(2), B(0xC3, 0x28)) },
        { "forged list count", Payload(TwainHelperMessageType.SourceList, 1, B(1), I(int.MaxValue)) },
        { "negative list count", Payload(TwainHelperMessageType.SourceList, 1, B(1), I(-1)) },
        { "unknown availability", Payload(TwainHelperMessageType.SourceList, 1, B(9), I(0)) },
        { "chunk over the limit", Payload(TwainHelperMessageType.Chunk, 0, I(TwainHelperProtocol.ChunkSize + 1)) },
        { "chunk shorter than said", Payload(TwainHelperMessageType.Chunk, 0, I(10), B(1, 2, 3)) },
        { "negative image length", Payload(TwainHelperMessageType.NativeBegin, 0, I(-1)) },
        { "negative strip length", Payload(TwainHelperMessageType.StripBegin, 0, I(1), I(1), I(0), I(0), I(1), I(0), I(-3)) },
        { "time limit below -1", Payload(TwainHelperMessageType.Disable, 1, I(-2)) },
        { "not a number", Payload(TwainHelperMessageType.ImageReady, 0, B(1), I(1), I(1), I(1), I(8), D(double.NaN), D(0), I(0), B(0)) },
        { "infinite size", Payload(TwainHelperMessageType.Progress, 0, B(1), D(double.PositiveInfinity), I(0)) },
        { "progress over 1", Payload(TwainHelperMessageType.Progress, 0, B(1), D(1.5), I(0)) },
        { "unknown error kind", Payload(TwainHelperMessageType.Failure, 1, B(7), I(0), I(0), I(0), B(0), I(-1), I(-1)) },
        { "unknown scan error kind", Payload(TwainHelperMessageType.Failure, 1, B(1), I(0), I(0), I(0), B(99), I(-1), I(-1)) },
        { "negative problem", Payload(TwainHelperMessageType.Failure, 1, B(1), I(0), I(0), I(0), B(2), I(-7), I(-1)) },
        { "forged run count", Payload(TwainHelperMessageType.Capabilities, 1, B(2, 0, 0, 0), I(0), I(int.MaxValue)) },
        { "empty run", Payload(TwainHelperMessageType.Capabilities, 1, B(2, 0, 0, 0), I(0), I(1), I(100), I(1), I(0)) },
        { "negative run", Payload(TwainHelperMessageType.Capabilities, 1, B(2, 0, 0, 0), I(0), I(1), I(100), I(1), I(-3)) },
        { "runs over the resolution limit", Payload(TwainHelperMessageType.Capabilities, 1, B(2, 0, 0, 0), I(0), I(2),
                                                    I(1), I(1), I(TwainHelperProtocol.MaxResolutionCount), I(1), I(1), I(1)) },
        { "run past the largest number", Payload(TwainHelperMessageType.Capabilities, 1, B(2, 0, 0, 0), I(0), I(1),
                                                 I(int.MaxValue - 1), I(1), I(3)) },
        { "run past the smallest number", Payload(TwainHelperMessageType.Capabilities, 1, B(2, 0, 0, 0), I(0), I(1),
                                                  I(int.MinValue + 1), I(-2), I(2)) },
    };

    [Theory]
    [MemberData(nameof(Malformed))]
    public void MalformedPayloads_AreRefused(string why, byte[] payload)
    {
        Assert.False(string.IsNullOrEmpty(why));
        Assert.Throws<TwainProtocolException>(() => TwainHelperProtocol.Decode(payload));
    }

    [Fact]
    public void FrameLengths_OutsideTheLimits_AreRefusedBeforeReading()
    {
        foreach (int length in new[] { -1, 0, 4, TwainHelperProtocol.MaxPayloadLength + 1, int.MaxValue })
        {
            // Only the header: a reader that trusted the length would wait for (or allocate) the payload.
            var stream = new MemoryStream(BitConverter.GetBytes(length));
            var error = Assert.Throws<TwainProtocolException>(() => TwainHelperProtocol.ReadFrame(stream));
            Assert.Contains("outside the allowed size", error.Message);
        }
    }

    [Fact]
    public void Encoding_ForgivesWhatADriverGetsWrong()
    {
        // A NaN resolution is sent as 0, "unknown".
        var ready = Assert.IsType<TwainHelperImageReady>(RoundTrip(new TwainHelperImageReady(
            new TwainImageInfo(10, 10, TwainPixelTypes.Gray, 8, double.NaN, double.PositiveInfinity))));
        Assert.Equal((0.0, 0.0), (ready.Info!.XResolution, ready.Info.YResolution));
        // A message longer than the limit is cut short, never split inside a character.
        string detail = new string('é', 3) + string.Concat(Enumerable.Repeat("😀", 20000));
        var failed = Assert.IsType<TwainHelperTransferFailed>(RoundTrip(new TwainHelperTransferFailed(1, 1, detail)));
        Assert.StartsWith("ééé😀", failed.Detail);
        Assert.True(System.Text.Encoding.UTF8.GetByteCount(failed.Detail!) <= TwainHelperProtocol.MaxStringBytes);
        Assert.False(char.IsHighSurrogate(failed.Detail![^1]));
        // A list too large for one frame is refused before it is sent.
        var huge = new TwainHelperSourceList(TwainAvailability.Available,
                                             [.. Enumerable.Range(0, 100).Select(i => new TwainHelperSource(new string('x', 5000) + i))]);
        Assert.Throws<ArgumentException>(() => TwainHelperProtocol.EncodeFrame(huge));
    }

    [Fact]
    public void AProblemFromANewerVersion_IsStillAProblem()
    {
        var payload = Payload(TwainHelperMessageType.Failure, 1, B(1), I(0), I(0), I(0), B(2), I(500), I(-1));
        var failure = Assert.IsType<TwainHelperFailure>(TwainHelperProtocol.Decode(payload));
        Assert.Equal(ScannerProblem.Unknown, failure.Error.Problem);
    }

    private static readonly TwainHelperMessageType[] Types = Enum.GetValues<TwainHelperMessageType>();

    [Fact]
    public void RandomPayloads_FailOnlyWithProtocolErrors()
    {
        var random = new Random(20261020);
        var buffer = new byte[64];
        for (int i = 0; i < 20000; i++)
        {
            int length = random.Next(buffer.Length + 1);
            random.NextBytes(buffer);
            // Bias the type byte towards real types, so the field readers are reached.
            if (length > 0 && random.Next(2) == 0) buffer[0] = (byte)Types[random.Next(Types.Length)];
            DecodeOrRefuse(buffer.AsSpan(0, length).ToArray());
        }
    }

    [Fact]
    public void DamagedMessages_FailOnlyWithProtocolErrors()
    {
        var random = new Random(7);
        var payloads = Samples().Where(s => s is not TwainHelperChunk { Data.Length: > 64 })
                                .Select(TwainHelperProtocol.Encode).ToList();
        for (int i = 0; i < 20000; i++)
        {
            var payload = payloads[random.Next(payloads.Count)].ToArray();
            switch (random.Next(4))
            {
                case 0:
                    // Flip a few bits.
                    for (int n = random.Next(1, 4); n > 0; n--) payload[random.Next(payload.Length)] ^= (byte)(1 << random.Next(8));
                    break;
                case 1:
                    payload = payload[..random.Next(payload.Length)];
                    break;
                case 2:
                    payload = [.. payload, .. Enumerable.Range(0, random.Next(1, 8)).Select(_ => (byte)random.Next(256))];
                    break;
                default:
                    // Overwrite a 4-byte field with an extreme value.
                    if (payload.Length >= 9)
                    {
                        int at = random.Next(5, payload.Length - 3);
                        BitConverter.GetBytes(new[] { int.MaxValue, int.MinValue, -1, 0x7FFF0000 }[random.Next(4)]).CopyTo(payload, at);
                    }
                    break;
            }
            DecodeOrRefuse(payload);
        }
    }

    [Fact]
    public void RandomStreams_FailOnlyWithProtocolErrors()
    {
        var random = new Random(99);
        for (int i = 0; i < 2000; i++)
        {
            var bytes = new byte[random.Next(0, 200)];
            random.NextBytes(bytes);
            // Plausible lengths now and then.
            if (bytes.Length >= 4 && random.Next(2) == 0) BitConverter.GetBytes(random.Next(5, bytes.Length + 4)).CopyTo(bytes, 0);
            var stream = new MemoryStream(bytes);
            try
            {
                while (TwainHelperProtocol.ReadFrame(stream) is not null)
                {
                }
            }
            catch (TwainProtocolException)
            {
            }
        }
    }

    private static void DecodeOrRefuse(byte[] payload)
    {
        try
        {
            var message = TwainHelperProtocol.Decode(payload);
            // Whatever decodes encodes again.
            Assert.Equal(message.GetType(), TwainHelperProtocol.Decode(TwainHelperProtocol.Encode(message)).GetType());
        }
        catch (TwainProtocolException)
        {
        }
    }

    // MARK: - Errors across the pipe

    private static Exception Across(Exception error) =>
        Assert.IsType<TwainHelperFailure>(RoundTrip(new TwainHelperFailure(TwainHelperError.From(error, "Opening the scanner"))
        {
            RequestId = 1,
        })).Error.ToException();

    [Fact]
    public void TwainErrors_CrossAsTheSameTwainException()
    {
        foreach (var error in new[]
                 {
                     new TwainException("Starting the scan", TwainReturnCodes.Failure, TwainConditionCodes.PaperJam),
                     new TwainException("Setting up the scan", TwainReturnCodes.Failure, TwainConditionCodes.Bummer, "the driver said no"),
                 })
        {
            var back = Assert.IsType<TwainException>(Across(error));
            Assert.Equal((error.Operation, error.ReturnCode, error.ConditionCode, error.Message),
                         (back.Operation, back.ReturnCode, back.ConditionCode, back.Message));
            // The app maps it to the scanner problem as for an in-process driver.
            Assert.Equal(TwainErrors.ToScanException(error).Problem, TwainErrors.ToScanException(back).Problem);
        }
    }

    [Fact]
    public void ScanErrors_CrossWithTheSameMessageKindAndProblem()
    {
        var errors = new List<ScanException>
        {
            ScanException.DeviceUnavailable("The TWAIN driver \"X\" is no longer installed."),
            ScanException.SessionFailed("the TWAIN driver could not open the scanner (TWCC_BUMMER)."),
            ScanException.ScanFailed("Scan failed: nested text: with colons"),
            ScanException.Cancelled(),
            ScanException.ExportFailed("disk full"),
            ScanException.Unsupported("no flatbed"),
            ScanException.DeviceUnavailable(""),
        };
        foreach (var problem in Enum.GetValues<ScannerProblem>())
        {
            errors.Add(ScanException.ForProblem(problem));
            errors.Add(ScanException.ForProblem(problem, "TWAIN TWCC_PAPERJAM (code)"));
        }
        foreach (var error in errors)
        {
            var back = Assert.IsType<ScanException>(Across(error));
            Assert.Equal((error.Kind, error.Problem, error.Message), (back.Kind, back.Problem, back.Message));
        }
    }

    [Fact]
    public void OtherErrors_CrossAsScanFailures()
    {
        var back = Assert.IsType<ScanException>(Across(new InvalidOperationException("Something broke.")));
        Assert.Equal(ScanErrorKind.ScanFailed, back.Kind);
        Assert.Equal(ScanException.ScanFailed("Something broke.").Message, back.Message);
    }

    // MARK: - Which sources are listed

    [Fact]
    public void Usable_LeavesOutTheWiaBridge64BitDriversAndBlanks()
    {
        TwainHelperSource S(string name) => new(name, "Acme");
        var usable = TwainHelperSources.Usable(
            [S("Acme 100"), S("WIA-Canon LiDE 120"), S("  "), S("Epson V600 "), S("Acme 100"), S("Old Scanner")],
            ["epson v600", "Other"]);
        Assert.Equal(["Acme 100", "Old Scanner"], usable.Select(s => s.Name));
    }

    [Fact]
    public void Info_NamesTheDriverAndRanksAfterTheOtherConnections()
    {
        var info = TwainHelperSources.Info(new TwainHelperSource("Fujitsu fi-6130 ", "Fujitsu"));
        Assert.Equal(("twain32:Fujitsu fi-6130 ", "Fujitsu fi-6130 (32-bit driver)", "TWAIN (32-bit driver)", "twain32", "Fujitsu Fujitsu fi-6130"),
                     (info.Id, info.Name, info.Transport, info.Backend, info.Model));
        Assert.Equal("Fujitsu fi-6130 ", TwainHelperSources.SourceName(info.Id));
        Assert.Null(TwainHelperSources.SourceName("twain:Fujitsu fi-6130"));
        Assert.Equal("TWAIN (32-bit driver)", DeviceMerge.ConnectionLabel(info));

        // One row with the WIA and 64-bit TWAIN connections of the same scanner; WIA, then 64-bit TWAIN, are preferred.
        var wia = new ScannerInfo("wia:1", "fi-6130", "WIA", Backend: "wia", Model: "FUJITSU fi-6130");
        var group = Assert.Single(DeviceMerge.Group([info, wia], DeviceMerge.WindowsRanking));
        Assert.Equal("wia:1", group.Primary.Id);
        Assert.Equal(2, group.Members.Count);
        var withTwain = Assert.Single(DeviceMerge.Group([info, new ScannerInfo("twain:x", "Fujitsu fi-6130", "TWAIN", Backend: "twain")],
                                                        DeviceMerge.WindowsRanking));
        Assert.Equal("twain:x", withTwain.Primary.Id);
        // Two 32-bit entries never merge with each other (two identical scanners stay apart).
        Assert.Equal(2, DeviceMerge.Group([info, info with { Id = "twain32:other" }], DeviceMerge.WindowsRanking).Count);
    }

    [Fact]
    public void HelperReport_SaysHowTheHelperIsDoingAndWhatWasLeftOut()
    {
        Assert.Equal("TWAIN 32-bit helper: not needed (no 32-bit-only drivers)\n",
                     TwainDiagnostics.HelperReport(TwainHelperStatus.NotNeeded, null, [], new HashSet<string>()));
        Assert.Equal("TWAIN 32-bit helper: works\n  source \"Old Scanner\"\n"
                     + "  left out (WIA bridge, or also a 64-bit driver) \"WIA-Canon\"\n",
                     TwainDiagnostics.HelperReport(TwainHelperStatus.Available, null, ["Old Scanner", "WIA-Canon"],
                                                   new HashSet<string> { "Old Scanner" }));
        // Its only driver is also a 64-bit one: it still works (and keeps running).
        Assert.Equal("TWAIN 32-bit helper: works\n  left out (WIA bridge, or also a 64-bit driver) \"Old Scanner\"\n",
                     TwainDiagnostics.HelperReport(TwainHelperStatus.Available, null, ["Old Scanner"], new HashSet<string>()));
        // Only the WIA bridge: the helper was stopped again, so it is not said to run.
        Assert.Equal("TWAIN 32-bit helper: reached no usable driver\n  left out (WIA bridge, or also a 64-bit driver) \"WIA-Canon\"\n",
                     TwainDiagnostics.HelperReport(TwainHelperStatus.Available, null, ["WIA-Canon"], new HashSet<string>()));
        Assert.Equal("TWAIN 32-bit helper: failed (it needs the x86 runtime)\n",
                     TwainDiagnostics.HelperReport(TwainHelperStatus.Failed, " it needs the x86 runtime ", [], new HashSet<string>()));
        Assert.Equal("TWAIN 32-bit helper: failed (the helper started, but its TWAIN Data Source Manager would not open)\n",
                     TwainDiagnostics.HelperReport(TwainHelperStatus.Failed,
                                                   "the helper started, but its TWAIN Data Source Manager would not open", [],
                                                   new HashSet<string>()));
    }

    [Fact]
    public void HelperProblem_SaysWhyThe32BitDriversAreNotReached_AndWhatToDo()
    {
        Assert.Null(TwainDiagnostics.HelperProblem(TwainHelperStatus.Unknown, null, reachedAny: false));
        Assert.Null(TwainDiagnostics.HelperProblem(TwainHelperStatus.NotNeeded, null, reachedAny: false));
        Assert.Null(TwainDiagnostics.HelperProblem(TwainHelperStatus.Available, null, reachedAny: true));
        Assert.Equal("It started, but its TWAIN Data Source Manager lists no driver it can use, which happens when a driver "
                     + "did not install completely. Reinstall the scanner maker's driver, then restart Lazy Scan.",
                     TwainDiagnostics.HelperProblem(TwainHelperStatus.Available, null, reachedAny: false));
        Assert.Equal("It found no 32-bit TWAIN Data Source Manager (TWAINDSM.dll or twain_32.dll) to load the driver with. "
                     + "Reinstall the scanner maker's driver, then restart Lazy Scan.",
                     TwainDiagnostics.HelperProblem(TwainHelperStatus.NoDataSourceManager, null, reachedAny: false));
        Assert.Equal("It cannot run: it needs the .NET 10 Desktop Runtime for 32-bit programs (x86), which is not installed.",
                     TwainDiagnostics.HelperProblem(TwainHelperStatus.Failed,
                                                    " it needs the .NET 10 Desktop Runtime for 32-bit programs (x86), which is not installed. ",
                                                    reachedAny: false));
        Assert.Equal("It did not work this time, and Lazy Scan tries again on its own. If the scanner still does not "
                     + "appear, restart Lazy Scan.",
                     TwainDiagnostics.HelperProblem(TwainHelperStatus.Failed, null, reachedAny: false));
    }
}
