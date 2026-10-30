using System.Buffers.Binary;
using System.Text;

namespace LazyScan.Core;

// The protocol between the app and its 32-bit TWAIN helper (LazyScan.TwainHelper.exe),
// which loads scanner drivers installed only for 32-bit programs. Kept here so both ends and
// the tests share one definition. Windows only, like TwainCodes.cs: no Swift twin.
//
// The pipe carries frames: a 4-byte little-endian payload length, then the payload: a message
// type byte, a 4-byte request id (0 for events), then the type's fields. Integers are
// little-endian, doubles IEEE 754 little-endian, booleans one byte (0 or 1), optional booleans
// one byte (0 false, 1 true, 2 none), strings a 4-byte UTF-8 length (-1 for none) and the
// bytes, lists a 4-byte count and the items. A source's resolutions are a list of runs (first
// value, step, count; see Writer.IntRuns), so a fine-grained range such as 50...9600 dpi in 1 dpi
// steps fits in a few bytes. A strip or image announced by a "begin" message is
// followed only by its chunks (and progress messages) until its length is reached. Anything else is malformed
// (TwainProtocolException): the reader never trusts a length it has not checked.

/// <summary>A frame on the helper's pipe that is malformed, cut short or unexpected.</summary>
public sealed class TwainProtocolException(string message) : Exception(message);

/// <summary>The message types of the helper protocol.</summary>
public enum TwainHelperMessageType : byte
{
    // App to helper: requests. Every one but Cancel gets exactly one reply with its id.
    Hello = 1,
    ListSources = 2,
    Open = 3,
    ReadCapabilities = 4,
    Apply = 5,
    Enable = 6,
    /// <summary>Stop the acquisition (<see cref="ITwainTransport.RequestStop"/>); no reply.</summary>
    Cancel = 7,
    Disable = 8,
    ReadDuplex = 9,
    Close = 10,
    Shutdown = 11,

    // Helper to app: replies.
    HelloReply = 64,
    SourceList = 65,
    Done = 66,
    Capabilities = 67,
    Applied = 68,
    Disabled = 69,
    Duplex = 70,
    Failure = 71,

    // Helper to app: events of an acquisition (request id 0), in the order they happened.
    ImageReady = 80,
    StripBegin = 81,
    NativeBegin = 82,
    Chunk = 83,
    TransferFailed = 84,
    TransferCancelled = 85,
    Finished = 86,
    Progress = 87,
}

/// <summary>One message of the helper protocol.</summary>
public abstract record TwainHelperMessage
{
    /// <summary>Pairs a reply with its request; 0 for events.</summary>
    public int RequestId { get; init; }

    public abstract TwainHelperMessageType Type { get; }
}

/// <summary>A data source the helper's Data Source Manager lists.</summary>
/// <param name="Name">The source's product name, exactly as TWAIN reports it (it opens the source).</param>
public sealed record TwainHelperSource(string Name, string? Manufacturer = null, string? ProductFamily = null);

/// <summary>The first request on a new pipe: the app's protocol version.</summary>
public sealed record TwainHelperHello(int Version) : TwainHelperMessage
{
    public override TwainHelperMessageType Type => TwainHelperMessageType.Hello;
}

public sealed record TwainHelperListSources : TwainHelperMessage
{
    public override TwainHelperMessageType Type => TwainHelperMessageType.ListSources;
}

/// <summary>Opens a source by its <see cref="TwainHelperSource.Name"/>, closing the one open before.</summary>
public sealed record TwainHelperOpen(string Name) : TwainHelperMessage
{
    public override TwainHelperMessageType Type => TwainHelperMessageType.Open;
}

public sealed record TwainHelperReadCapabilities : TwainHelperMessage
{
    public override TwainHelperMessageType Type => TwainHelperMessageType.ReadCapabilities;
}

public sealed record TwainHelperApply(TwainScanRequest Request) : TwainHelperMessage
{
    public override TwainHelperMessageType Type => TwainHelperMessageType.Apply;
}

public sealed record TwainHelperEnable(bool ShowDriverWindow) : TwainHelperMessage
{
    public override TwainHelperMessageType Type => TwainHelperMessageType.Enable;
}

public sealed record TwainHelperCancel : TwainHelperMessage
{
    public override TwainHelperMessageType Type => TwainHelperMessageType.Cancel;
}

/// <param name="TimeoutMilliseconds">How long the helper waits for the source to disable; -1 = no limit.</param>
public sealed record TwainHelperDisable(int TimeoutMilliseconds) : TwainHelperMessage
{
    public override TwainHelperMessageType Type => TwainHelperMessageType.Disable;
}

public sealed record TwainHelperReadDuplex : TwainHelperMessage
{
    public override TwainHelperMessageType Type => TwainHelperMessageType.ReadDuplex;
}

public sealed record TwainHelperClose : TwainHelperMessage
{
    public override TwainHelperMessageType Type => TwainHelperMessageType.Close;
}

/// <summary>Closes the open source and ends the helper once the reply is sent.</summary>
public sealed record TwainHelperShutdown : TwainHelperMessage
{
    public override TwainHelperMessageType Type => TwainHelperMessageType.Shutdown;
}

/// <param name="Version">The helper's protocol version; the app uses a helper of its own version only.</param>
/// <param name="ProcessBits">32 for the helper (it exists to load 32-bit drivers).</param>
public sealed record TwainHelperHelloReply(int Version, int ProcessBits) : TwainHelperMessage
{
    public override TwainHelperMessageType Type => TwainHelperMessageType.HelloReply;
}

public sealed record TwainHelperSourceList(TwainAvailability Availability, IReadOnlyList<TwainHelperSource> Sources)
    : TwainHelperMessage
{
    public override TwainHelperMessageType Type => TwainHelperMessageType.SourceList;
}

/// <summary>The request succeeded and has nothing to return (Open, Enable, Close, Shutdown).</summary>
public sealed record TwainHelperDone : TwainHelperMessage
{
    public override TwainHelperMessageType Type => TwainHelperMessageType.Done;
}

public sealed record TwainHelperCapabilities(TwainDeviceCaps Caps) : TwainHelperMessage
{
    public override TwainHelperMessageType Type => TwainHelperMessageType.Capabilities;
}

public sealed record TwainHelperApplied(TwainApplied Applied) : TwainHelperMessage
{
    public override TwainHelperMessageType Type => TwainHelperMessageType.Applied;
}

public sealed record TwainHelperDisabled(bool Succeeded) : TwainHelperMessage
{
    public override TwainHelperMessageType Type => TwainHelperMessageType.Disabled;
}

public sealed record TwainHelperDuplex(bool? Enabled) : TwainHelperMessage
{
    public override TwainHelperMessageType Type => TwainHelperMessageType.Duplex;
}

/// <summary>The request failed; <see cref="Error"/> says how, in terms the app's error handling knows.</summary>
public sealed record TwainHelperFailure(TwainHelperError Error) : TwainHelperMessage
{
    public override TwainHelperMessageType Type => TwainHelperMessageType.Failure;
}

/// <summary><see cref="TwainImageReady"/>.</summary>
public sealed record TwainHelperImageReady(TwainImageInfo? Info) : TwainHelperMessage
{
    public override TwainHelperMessageType Type => TwainHelperMessageType.ImageReady;
}

/// <summary>
/// A <see cref="TwainStripReceived"/> whose <see cref="TwainStrip.Data"/>, <paramref name="Length"/>
/// bytes, follows in <see cref="TwainHelperChunk"/> messages.
/// </summary>
public sealed record TwainHelperStripBegin(int Columns, int Rows, int XOffset, int YOffset, int BytesPerRow,
                                           int Compression, int Length) : TwainHelperMessage
{
    public override TwainHelperMessageType Type => TwainHelperMessageType.StripBegin;
}

/// <summary>
/// A <see cref="TwainNativeImage"/> of <paramref name="Length"/> bytes, which follow in
/// <see cref="TwainHelperChunk"/> messages, with a <see cref="TwainHelperProgress"/> after each chunk
/// when there are several.
/// </summary>
public sealed record TwainHelperNativeBegin(int Length) : TwainHelperMessage
{
    public override TwainHelperMessageType Type => TwainHelperMessageType.NativeBegin;
}

/// <summary>The next at most <see cref="TwainHelperProtocol.ChunkSize"/> bytes of the strip or image being sent.</summary>
public sealed record TwainHelperChunk(byte[] Data) : TwainHelperMessage
{
    public override TwainHelperMessageType Type => TwainHelperMessageType.Chunk;
}

/// <summary><see cref="TwainTransferFailed"/>.</summary>
public sealed record TwainHelperTransferFailed(int ReturnCode, int ConditionCode, string? Detail) : TwainHelperMessage
{
    public override TwainHelperMessageType Type => TwainHelperMessageType.TransferFailed;
}

/// <summary><see cref="TwainTransferCancelled"/>.</summary>
public sealed record TwainHelperTransferCancelled : TwainHelperMessage
{
    public override TwainHelperMessageType Type => TwainHelperMessageType.TransferCancelled;
}

/// <summary><see cref="TwainFinished"/>.</summary>
public sealed record TwainHelperFinished : TwainHelperMessage
{
    public override TwainHelperMessageType Type => TwainHelperMessageType.Finished;
}

/// <summary>How far a long transfer has come, for the app's progress line.</summary>
/// <param name="Fraction">0...1; null when unknown.</param>
public sealed record TwainHelperProgress(double? Fraction, string Message) : TwainHelperMessage
{
    public override TwainHelperMessageType Type => TwainHelperMessageType.Progress;
}

/// <summary>Which kind of error a <see cref="TwainHelperError"/> carries.</summary>
public enum TwainHelperErrorKind : byte
{
    /// <summary>A TWAIN operation failed with return and condition codes (<see cref="TwainException"/>).</summary>
    Twain = 0,
    /// <summary>A failure the helper already put in the app's terms (<see cref="ScanException"/>).</summary>
    Scan = 1,
}

/// <summary>
/// An error raised in the helper, carried to the app and raised there again as the same
/// <see cref="TwainException"/> (which the scan logic maps to a <see cref="ScannerProblem"/>
/// through <see cref="TwainErrors"/>) or the same <see cref="ScanException"/> (message, kind and problem).
/// </summary>
/// <param name="Operation">What was being done, for <see cref="TwainException.Operation"/>.</param>
/// <param name="Problem">The scanner condition of a <see cref="TwainHelperErrorKind.Scan"/> error, when known.</param>
/// <param name="Detail">The text after the error's standard wording (see <see cref="From"/>).</param>
public sealed record TwainHelperError(TwainHelperErrorKind Kind, string Operation, int ReturnCode, int ConditionCode,
                                      ScanErrorKind ScanKind, ScannerProblem? Problem, string? Detail)
{
    /// <summary>
    /// The error for <paramref name="error"/>. A <see cref="ScanException"/> is reduced to its
    /// kind, problem and detail (its message without the wording its factory adds), so the app
    /// builds the same message again; any other exception is a scan failure with its message.
    /// </summary>
    public static TwainHelperError From(Exception error, string operation)
    {
        switch (error)
        {
            case TwainException twain:
                return new(TwainHelperErrorKind.Twain, twain.Operation, twain.ReturnCode, twain.ConditionCode,
                           ScanErrorKind.ScanFailed, null, DetailOf(twain));
            case ScanException scan when scan.Problem is { } problem:
            {
                string described = ScannerProblems.Describe(problem);
                string? detail = null;
                if (scan.Message.StartsWith(described + " (", StringComparison.Ordinal) && scan.Message.EndsWith(')'))
                {
                    detail = scan.Message[(described.Length + 2)..^1];
                }
                return new(TwainHelperErrorKind.Scan, operation, 0, 0, scan.Kind, problem, detail);
            }
            case ScanException scan:
            {
                string prefix = Rebuild(scan.Kind, "").Message;
                string? detail = scan.Kind == ScanErrorKind.Cancelled ? null
                    : scan.Message.StartsWith(prefix, StringComparison.Ordinal) ? scan.Message[prefix.Length..]
                    : scan.Message;
                return new(TwainHelperErrorKind.Scan, operation, 0, 0, scan.Kind, null, detail);
            }
            default:
                return new(TwainHelperErrorKind.Scan, operation, 0, 0, ScanErrorKind.ScanFailed, null, error.Message);
        }
    }

    /// <summary>The exception this error stands for, to be thrown in the app.</summary>
    public Exception ToException() => Kind switch
    {
        TwainHelperErrorKind.Twain => new TwainException(Operation, ReturnCode, ConditionCode, Detail),
        _ when Problem is { } problem => ScanException.ForProblem(problem, Detail),
        _ => Rebuild(ScanKind, Detail ?? ""),
    };

    private static ScanException Rebuild(ScanErrorKind kind, string detail) => kind switch
    {
        ScanErrorKind.DeviceUnavailable => ScanException.DeviceUnavailable(detail),
        ScanErrorKind.SessionFailed => ScanException.SessionFailed(detail),
        ScanErrorKind.Cancelled => ScanException.Cancelled(),
        ScanErrorKind.ExportFailed => ScanException.ExportFailed(detail),
        ScanErrorKind.Unsupported => ScanException.Unsupported(detail),
        _ => ScanException.ScanFailed(detail),
    };

    /// <summary>The detail a <see cref="TwainException"/> was made with: its message after the codes.</summary>
    private static string? DetailOf(TwainException error)
    {
        string bare = new TwainException(error.Operation, error.ReturnCode, error.ConditionCode).Message;
        // "… condition code N)." becomes "… condition code N): detail" with a detail.
        string withDetail = bare[..^1] + ": ";
        return error.Message.StartsWith(withDetail, StringComparison.Ordinal) ? error.Message[withDetail.Length..] : null;
    }
}

/// <summary>Encodes and decodes the helper protocol's frames (see the file comment).</summary>
public static class TwainHelperProtocol
{
    /// <summary>The protocol version; the app and the helper are built together and must agree.</summary>
    public const int Version = 1;

    /// <summary>"CSTW": the first field of <see cref="TwainHelperHello"/> and its reply.</summary>
    public const uint Magic = 0x57545343;

    /// <summary>The most image bytes one <see cref="TwainHelperChunk"/> carries.</summary>
    public const int ChunkSize = 256 * 1024;

    /// <summary>The largest payload a frame may have: a full chunk with room for its header.</summary>
    public const int MaxPayloadLength = ChunkSize + 1024;

    /// <summary>The longest string a message may carry, in UTF-8 bytes.</summary>
    public const int MaxStringBytes = 16 * 1024;

    /// <summary>The most items a list in a message may have.</summary>
    public const int MaxListCount = 4096;

    /// <summary>
    /// The most resolutions a source's capabilities may list: every value
    /// <see cref="ResolutionList.ExpandRange"/> can produce from a driver's range.
    /// </summary>
    public const int MaxResolutionCount = ResolutionList.MaxRangeDpi;

    /// <summary>The frame for <paramref name="message"/>: its length, then its payload.</summary>
    /// <exception cref="ArgumentException">The message is larger than a frame may be (a list too long).</exception>
    public static byte[] EncodeFrame(TwainHelperMessage message)
    {
        var payload = Encode(message);
        if (payload.Length > MaxPayloadLength)
        {
            throw new ArgumentException($"A {message.Type} message of {payload.Length} bytes is larger than a frame may be.", nameof(message));
        }
        var frame = new byte[4 + payload.Length];
        BinaryPrimitives.WriteInt32LittleEndian(frame, payload.Length);
        payload.CopyTo(frame, 4);
        return frame;
    }

    /// <summary>Writes <paramref name="message"/> as one frame.</summary>
    public static void WriteFrame(Stream stream, TwainHelperMessage message)
    {
        stream.Write(EncodeFrame(message));
        stream.Flush();
    }

    /// <summary>
    /// Reads the next frame and decodes it. Null when the stream ended cleanly between frames.
    /// </summary>
    /// <exception cref="TwainProtocolException">The frame is malformed or the stream ended inside it.</exception>
    public static TwainHelperMessage? ReadFrame(Stream stream)
    {
        Span<byte> header = stackalloc byte[4];
        int read = ReadFully(stream, header);
        if (read == 0) return null;
        if (read < header.Length) throw new TwainProtocolException("The pipe closed inside a frame header.");
        int length = BinaryPrimitives.ReadInt32LittleEndian(header);
        if (length < 5 || length > MaxPayloadLength)
        {
            throw new TwainProtocolException($"A frame of {length} bytes is outside the allowed size.");
        }
        var payload = new byte[length];
        if (ReadFully(stream, payload) < length) throw new TwainProtocolException("The pipe closed inside a frame.");
        return Decode(payload);
    }

    private static int ReadFully(Stream stream, Span<byte> buffer)
    {
        int total = 0;
        while (total < buffer.Length)
        {
            int n = stream.Read(buffer[total..]);
            if (n == 0) break;
            total += n;
        }
        return total;
    }

    /// <summary>The payload of <paramref name="message"/>: type, request id, fields.</summary>
    public static byte[] Encode(TwainHelperMessage message)
    {
        var w = new Writer();
        w.Byte((byte)message.Type);
        w.Int(message.RequestId);
        switch (message)
        {
            case TwainHelperHello hello:
                w.UInt(Magic);
                w.Int(hello.Version);
                break;
            case TwainHelperOpen open:
                w.String(open.Name);
                break;
            case TwainHelperApply apply:
                WriteRequest(w, apply.Request);
                break;
            case TwainHelperEnable enable:
                w.Bool(enable.ShowDriverWindow);
                break;
            case TwainHelperDisable disable:
                w.Int(disable.TimeoutMilliseconds);
                break;
            case TwainHelperHelloReply reply:
                w.UInt(Magic);
                w.Int(reply.Version);
                w.Int(reply.ProcessBits);
                break;
            case TwainHelperSourceList list:
                w.Byte((byte)list.Availability);
                w.Count(list.Sources.Count);
                foreach (var source in list.Sources)
                {
                    w.String(source.Name);
                    w.String(source.Manufacturer);
                    w.String(source.ProductFamily);
                }
                break;
            case TwainHelperCapabilities caps:
                WriteCaps(w, caps.Caps);
                break;
            case TwainHelperApplied applied:
                w.Int(applied.Applied.TransferMechanism);
                w.Int(applied.Applied.PixelFlavor);
                w.OptionalBool(applied.Applied.FeederLoaded);
                w.Bool(applied.Applied.MsbFirst);
                w.OptionalBool(applied.Applied.DuplexEnabled);
                break;
            case TwainHelperDisabled disabled:
                w.Bool(disabled.Succeeded);
                break;
            case TwainHelperDuplex duplex:
                w.OptionalBool(duplex.Enabled);
                break;
            case TwainHelperFailure failure:
                WriteError(w, failure.Error);
                break;
            case TwainHelperImageReady ready:
                w.Bool(ready.Info is not null);
                if (ready.Info is { } info) WriteInfo(w, info);
                break;
            case TwainHelperStripBegin strip:
                w.Int(strip.Columns);
                w.Int(strip.Rows);
                w.Int(strip.XOffset);
                w.Int(strip.YOffset);
                w.Int(strip.BytesPerRow);
                w.Int(strip.Compression);
                w.Length(strip.Length);
                break;
            case TwainHelperNativeBegin native:
                w.Length(native.Length);
                break;
            case TwainHelperChunk chunk:
                if (chunk.Data.Length > ChunkSize) throw new ArgumentException("A chunk is larger than the protocol allows.", nameof(message));
                w.Int(chunk.Data.Length);
                w.Bytes(chunk.Data);
                break;
            case TwainHelperTransferFailed failed:
                w.Int(failed.ReturnCode);
                w.Int(failed.ConditionCode);
                w.String(failed.Detail);
                break;
            case TwainHelperProgress progress:
                w.Bool(progress.Fraction is not null);
                if (progress.Fraction is { } fraction) w.Double(Math.Clamp(fraction, 0, 1));
                w.String(progress.Message);
                break;
            case TwainHelperListSources or TwainHelperReadCapabilities or TwainHelperCancel or TwainHelperReadDuplex
                or TwainHelperClose or TwainHelperShutdown or TwainHelperDone or TwainHelperTransferCancelled
                or TwainHelperFinished:
                break;
            default:
                throw new ArgumentException($"No encoding for {message.GetType().Name}.", nameof(message));
        }
        return w.ToArray();
    }

    /// <summary>The message in <paramref name="payload"/>.</summary>
    /// <exception cref="TwainProtocolException">The payload is malformed.</exception>
    public static TwainHelperMessage Decode(ReadOnlySpan<byte> payload)
    {
        var r = new Reader(payload);
        byte rawType = r.Byte();
        int requestId = r.Int();
        if (requestId < 0) throw new TwainProtocolException($"Request id {requestId} is negative.");
        TwainHelperMessage message = (TwainHelperMessageType)rawType switch
        {
            TwainHelperMessageType.Hello => new TwainHelperHello(r.MagicThenInt()),
            TwainHelperMessageType.ListSources => new TwainHelperListSources(),
            TwainHelperMessageType.Open => new TwainHelperOpen(r.RequiredString()),
            TwainHelperMessageType.ReadCapabilities => new TwainHelperReadCapabilities(),
            TwainHelperMessageType.Apply => new TwainHelperApply(ReadRequest(ref r)),
            TwainHelperMessageType.Enable => new TwainHelperEnable(r.Bool()),
            TwainHelperMessageType.Cancel => new TwainHelperCancel(),
            TwainHelperMessageType.Disable => new TwainHelperDisable(r.Timeout()),
            TwainHelperMessageType.ReadDuplex => new TwainHelperReadDuplex(),
            TwainHelperMessageType.Close => new TwainHelperClose(),
            TwainHelperMessageType.Shutdown => new TwainHelperShutdown(),
            TwainHelperMessageType.HelloReply => new TwainHelperHelloReply(r.MagicThenInt(), r.Int()),
            TwainHelperMessageType.SourceList => ReadSourceList(ref r),
            TwainHelperMessageType.Done => new TwainHelperDone(),
            TwainHelperMessageType.Capabilities => new TwainHelperCapabilities(ReadCaps(ref r)),
            TwainHelperMessageType.Applied => new TwainHelperApplied(new TwainApplied(
                r.Int(), r.Int(), r.OptionalBool(), r.Bool(), r.OptionalBool())),
            TwainHelperMessageType.Disabled => new TwainHelperDisabled(r.Bool()),
            TwainHelperMessageType.Duplex => new TwainHelperDuplex(r.OptionalBool()),
            TwainHelperMessageType.Failure => new TwainHelperFailure(ReadError(ref r)),
            TwainHelperMessageType.ImageReady => new TwainHelperImageReady(r.Bool() ? ReadInfo(ref r) : null),
            TwainHelperMessageType.StripBegin => new TwainHelperStripBegin(
                r.Int(), r.Int(), r.Int(), r.Int(), r.Int(), r.Int(), r.Length()),
            TwainHelperMessageType.NativeBegin => new TwainHelperNativeBegin(r.Length()),
            TwainHelperMessageType.Chunk => new TwainHelperChunk(r.ChunkBytes()),
            TwainHelperMessageType.TransferFailed => new TwainHelperTransferFailed(r.Int(), r.Int(), r.OptionalString()),
            TwainHelperMessageType.TransferCancelled => new TwainHelperTransferCancelled(),
            TwainHelperMessageType.Finished => new TwainHelperFinished(),
            TwainHelperMessageType.Progress => new TwainHelperProgress(r.Bool() ? r.Fraction() : null, r.RequiredString()),
            _ => throw new TwainProtocolException($"Unknown message type {rawType}."),
        };
        r.End();
        return message with { RequestId = requestId };
    }

    private static void WriteRequest(Writer w, TwainScanRequest request)
    {
        w.Bool(request.Feeder);
        w.Int(request.PixelType);
        w.Int(request.BitDepth);
        w.Int(request.Resolution);
        w.Bool(request.FrameInches is not null);
        if (request.FrameInches is { } frame)
        {
            w.Double(frame.X);
            w.Double(frame.Y);
            w.Double(frame.Width);
            w.Double(frame.Height);
        }
        w.Int(request.TransferCount);
        w.Bool(request.ShowDriverWindow);
        w.Bool(request.PreferMemory);
        w.Bool(request.Duplex);
        w.Int(request.SupportedSize);
    }

    private static TwainScanRequest ReadRequest(ref Reader r)
    {
        bool feeder = r.Bool();
        int pixelType = r.Int(), bitDepth = r.Int(), resolution = r.Int();
        RectD? frame = r.Bool() ? new RectD(r.Double(), r.Double(), r.Double(), r.Double()) : null;
        return new TwainScanRequest(feeder, pixelType, bitDepth, resolution, frame,
                                    TransferCount: r.Int(), ShowDriverWindow: r.Bool(), PreferMemory: r.Bool(),
                                    Duplex: r.Bool(), SupportedSize: r.Int());
    }

    private static void WriteCaps(Writer w, TwainDeviceCaps caps)
    {
        w.OptionalBool(caps.Online);
        w.Bool(caps.UIControllable);
        w.Bool(caps.HasFlatbed);
        w.Bool(caps.HasFeeder);
        w.Int(caps.DuplexKind);
        w.IntRuns(caps.Resolutions, MaxResolutionCount);
        w.Int(caps.NativeResolution);
        w.Ints(caps.PixelTypes);
        w.OptionalSize(caps.FlatbedSizeInches);
        w.OptionalSize(caps.FeederSizeInches);
        w.Ints(caps.SupportedSizes);
        w.Bool(caps.MemoryTransfer);
    }

    private static TwainDeviceCaps ReadCaps(ref Reader r) => new()
    {
        Online = r.OptionalBool(),
        UIControllable = r.Bool(),
        HasFlatbed = r.Bool(),
        HasFeeder = r.Bool(),
        DuplexKind = r.Int(),
        Resolutions = r.IntRuns(MaxResolutionCount),
        NativeResolution = r.Int(),
        PixelTypes = r.Ints(),
        FlatbedSizeInches = r.OptionalSize(),
        FeederSizeInches = r.OptionalSize(),
        SupportedSizes = r.Ints(),
        MemoryTransfer = r.Bool(),
    };

    private static TwainHelperSourceList ReadSourceList(ref Reader r)
    {
        var availability = (TwainAvailability)r.Byte();
        if (!Enum.IsDefined(availability)) throw new TwainProtocolException($"Unknown TWAIN availability {(int)availability}.");
        int count = r.Count(minItemBytes: 12);
        var sources = new List<TwainHelperSource>(count);
        for (int i = 0; i < count; i++)
        {
            sources.Add(new TwainHelperSource(r.RequiredString(), r.OptionalString(), r.OptionalString()));
        }
        return new TwainHelperSourceList(availability, sources);
    }

    private static void WriteInfo(Writer w, TwainImageInfo info)
    {
        w.Int(info.Width);
        w.Int(info.Height);
        w.Int(info.PixelType);
        w.Int(info.BitsPerPixel);
        w.Double(info.XResolution);
        w.Double(info.YResolution);
        w.Int(info.Compression);
        w.Bool(info.Planar);
    }

    private static TwainImageInfo ReadInfo(ref Reader r) => new(
        r.Int(), r.Int(), r.Int(), r.Int(), XResolution: r.Double(), YResolution: r.Double(),
        Compression: r.Int(), Planar: r.Bool());

    private static void WriteError(Writer w, TwainHelperError error)
    {
        w.Byte((byte)error.Kind);
        w.String(error.Operation);
        w.Int(error.ReturnCode);
        w.Int(error.ConditionCode);
        w.Byte((byte)error.ScanKind);
        w.Int(error.Problem is { } problem ? (int)problem : -1);
        w.String(error.Detail);
    }

    private static TwainHelperError ReadError(ref Reader r)
    {
        var kind = (TwainHelperErrorKind)r.Byte();
        if (!Enum.IsDefined(kind)) throw new TwainProtocolException($"Unknown error kind {(int)kind}.");
        string operation = r.RequiredString();
        int returnCode = r.Int(), conditionCode = r.Int();
        var scanKind = (ScanErrorKind)r.Byte();
        if (!Enum.IsDefined(scanKind)) throw new TwainProtocolException($"Unknown scan error kind {(int)scanKind}.");
        int rawProblem = r.Int();
        if (rawProblem < -1) throw new TwainProtocolException($"Scanner problem {rawProblem} is negative.");
        // A problem this version does not know is still a problem.
        ScannerProblem? problem = rawProblem == -1 ? null
            : Enum.IsDefined((ScannerProblem)rawProblem) ? (ScannerProblem)rawProblem : ScannerProblem.Unknown;
        return new TwainHelperError(kind, operation, returnCode, conditionCode, scanKind, problem, r.OptionalString());
    }

    private sealed class Writer
    {
        private readonly MemoryStream _stream = new();

        public void Byte(byte value) => _stream.WriteByte(value);

        public void Int(int value)
        {
            Span<byte> b = stackalloc byte[4];
            BinaryPrimitives.WriteInt32LittleEndian(b, value);
            _stream.Write(b);
        }

        public void UInt(uint value)
        {
            Span<byte> b = stackalloc byte[4];
            BinaryPrimitives.WriteUInt32LittleEndian(b, value);
            _stream.Write(b);
        }

        /// <summary>A number; one that is not finite (a driver's NaN resolution) is sent as 0, "unknown".</summary>
        public void Double(double value)
        {
            if (!double.IsFinite(value)) value = 0;
            Span<byte> b = stackalloc byte[8];
            BinaryPrimitives.WriteDoubleLittleEndian(b, value);
            _stream.Write(b);
        }

        public void Bool(bool value) => Byte(value ? (byte)1 : (byte)0);

        public void OptionalBool(bool? value) => Byte(value switch { false => 0, true => 1, null => 2 });

        public void Count(int count)
        {
            if (count > MaxListCount) throw new ArgumentException("A list is longer than the protocol allows.");
            Int(count);
        }

        public void Length(int length)
        {
            if (length < 0) throw new ArgumentException("A length is negative.");
            Int(length);
        }

        public void Ints(IReadOnlyList<int> values)
        {
            Count(values.Count);
            foreach (int value in values) Int(value);
        }

        /// <summary>
        /// A list of at most <paramref name="maxValues"/> numbers as runs that each step by the
        /// same amount: a count, then per run its first value, its step and how many values it
        /// has. A range expanded value by value becomes one run; any other list still survives
        /// exactly, in its order.
        /// </summary>
        public void IntRuns(IReadOnlyList<int> values, int maxValues)
        {
            if (values.Count > maxValues) throw new ArgumentException("A list is longer than the protocol allows.");
            var runs = new List<(int First, int Step, int Count)>();
            for (int i = 0; i < values.Count;)
            {
                int first = values[i], count = 1;
                long step = i + 1 < values.Count ? (long)values[i + 1] - first : 0;
                if (step is < int.MinValue or > int.MaxValue) step = 0;
                else
                {
                    while (i + count < values.Count && (long)values[i + count] - values[i + count - 1] == step) count++;
                }
                runs.Add((first, (int)step, count));
                i += count;
            }
            Count(runs.Count);
            foreach (var run in runs)
            {
                Int(run.First);
                Int(run.Step);
                Int(run.Count);
            }
        }

        public void OptionalSize(SizeD? size)
        {
            Bool(size is not null);
            if (size is { } s)
            {
                Double(s.Width);
                Double(s.Height);
            }
        }

        public void String(string? value)
        {
            if (value is null)
            {
                Int(-1);
                return;
            }
            var bytes = Encoding.UTF8.GetBytes(value);
            if (bytes.Length > MaxStringBytes)
            {
                // A driver's message this long is cut short (every character fits in 3 bytes).
                int length = MaxStringBytes / 3;
                if (char.IsHighSurrogate(value[length - 1])) length--;
                bytes = Encoding.UTF8.GetBytes(value[..length]);
            }
            Int(bytes.Length);
            _stream.Write(bytes);
        }

        public void Bytes(ReadOnlySpan<byte> bytes) => _stream.Write(bytes);

        public byte[] ToArray() => _stream.ToArray();
    }

    private ref struct Reader(ReadOnlySpan<byte> data)
    {
        private readonly ReadOnlySpan<byte> _data = data;
        private int _position;

        private ReadOnlySpan<byte> Take(int count)
        {
            if (count < 0 || count > _data.Length - _position)
            {
                throw new TwainProtocolException("A message is shorter than its fields.");
            }
            var span = _data.Slice(_position, count);
            _position += count;
            return span;
        }

        public byte Byte() => Take(1)[0];

        public int Int() => BinaryPrimitives.ReadInt32LittleEndian(Take(4));

        public int MagicThenInt()
        {
            uint magic = BinaryPrimitives.ReadUInt32LittleEndian(Take(4));
            if (magic != Magic) throw new TwainProtocolException("This is not the Lazy Scan TWAIN helper protocol.");
            return Int();
        }

        public double Double()
        {
            double value = BinaryPrimitives.ReadDoubleLittleEndian(Take(8));
            if (!double.IsFinite(value)) throw new TwainProtocolException("A number is not finite.");
            return value;
        }

        public double Fraction()
        {
            double value = Double();
            if (value is < 0 or > 1) throw new TwainProtocolException($"Progress {value} is outside 0...1.");
            return value;
        }

        public bool Bool() => Byte() switch
        {
            0 => false,
            1 => true,
            var other => throw new TwainProtocolException($"{other} is not a boolean."),
        };

        public bool? OptionalBool() => Byte() switch
        {
            0 => false,
            1 => true,
            2 => null,
            var other => throw new TwainProtocolException($"{other} is not an optional boolean."),
        };

        /// <summary>A list count, checked against the bytes left so a forged count cannot make the reader allocate.</summary>
        public int Count(int minItemBytes)
        {
            int count = Int();
            if (count < 0 || count > MaxListCount || (long)count * minItemBytes > _data.Length - _position)
            {
                throw new TwainProtocolException($"A list of {count} items does not fit the message.");
            }
            return count;
        }

        public int Length()
        {
            int length = Int();
            if (length < 0) throw new TwainProtocolException($"Length {length} is negative.");
            return length;
        }

        public int Timeout()
        {
            int value = Int();
            if (value < -1) throw new TwainProtocolException($"Time limit {value} ms is not valid.");
            return value;
        }

        public IReadOnlyList<int> Ints()
        {
            int count = Count(minItemBytes: 4);
            var values = new int[count];
            for (int i = 0; i < count; i++) values[i] = Int();
            return values;
        }

        /// <summary>A list written by <see cref="Writer.IntRuns"/>: never more than <paramref name="maxValues"/> values, each an int.</summary>
        public IReadOnlyList<int> IntRuns(int maxValues)
        {
            int runs = Count(minItemBytes: 12);
            var values = new List<int>();
            for (int i = 0; i < runs; i++)
            {
                int first = Int(), step = Int(), count = Int();
                if (count < 1 || count > maxValues - values.Count)
                {
                    throw new TwainProtocolException($"A run of {count} values does not fit a list of at most {maxValues}.");
                }
                long last = first + (long)step * (count - 1);
                if (last is < int.MinValue or > int.MaxValue) throw new TwainProtocolException("A run goes past the range of a number.");
                for (int k = 0; k < count; k++) values.Add((int)(first + (long)step * k));
            }
            return values;
        }

        public SizeD? OptionalSize() => Bool() ? new SizeD(Double(), Double()) : null;

        public string? OptionalString()
        {
            int length = Int();
            if (length == -1) return null;
            if (length < -1 || length > MaxStringBytes) throw new TwainProtocolException($"A string of {length} bytes is not allowed.");
            try
            {
                return new UTF8Encoding(false, throwOnInvalidBytes: true).GetString(Take(length));
            }
            catch (DecoderFallbackException)
            {
                throw new TwainProtocolException("A string is not valid UTF-8.");
            }
        }

        public string RequiredString() =>
            OptionalString() ?? throw new TwainProtocolException("A required string is missing.");

        public byte[] ChunkBytes()
        {
            int length = Int();
            if (length < 0 || length > ChunkSize) throw new TwainProtocolException($"A chunk of {length} bytes is not allowed.");
            return Take(length).ToArray();
        }

        public readonly void End()
        {
            if (_position != _data.Length) throw new TwainProtocolException("A message has bytes after its fields.");
        }
    }
}
