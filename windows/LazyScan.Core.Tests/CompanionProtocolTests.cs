using System.Text;
using LazyScan.Core;
using Xunit;

namespace LazyScan.Core.Tests;

// Mirrored by Tests/CompleteScannerTests/CompanionProtocolTests.swift (same JSON, byte for byte).

public class CompanionProtocolTests
{
    private const string DesktopId = "0123456789abcdef0123456789abcdef";

    [Theory]
    [InlineData("", "")]
    [InlineData("f", "Zg")]
    [InlineData("fo", "Zm8")]
    [InlineData("foo", "Zm9v")]
    [InlineData("foob", "Zm9vYg")]
    [InlineData("fooba", "Zm9vYmE")]
    [InlineData("foobar", "Zm9vYmFy")]
    public void Base64Url_EncodesAndDecodes(string plain, string encoded)
    {
        byte[] bytes = Encoding.ASCII.GetBytes(plain);
        Assert.Equal(encoded, CompanionProtocol.EncodeBase64Url(bytes));
        Assert.Equal(bytes, CompanionProtocol.DecodeBase64Url(encoded));
    }

    [Fact]
    public void Base64Url_UsesTheUrlAlphabet()
    {
        Assert.Equal("-_-_", CompanionProtocol.EncodeBase64Url([0xFB, 0xFF, 0xBF]));
        Assert.Equal(new byte[] { 0xFB, 0xFF, 0xBF }, CompanionProtocol.DecodeBase64Url("-_-_"));
        Assert.Equal(CompanionVectors.SecretText, CompanionProtocol.EncodeBase64Url(CompanionVectors.Secret));
        Assert.Equal(CompanionVectors.TokenText, CompanionProtocol.EncodeBase64Url(CompanionVectors.Token));
    }

    [Theory]
    [InlineData("Zg==")]
    [InlineData("Zh")]
    [InlineData("Z")]
    [InlineData("Zm9v+")]
    [InlineData("Zm9v/A")]
    [InlineData("Zm 9v")]
    [InlineData(null)]
    public void Base64Url_RefusesAnythingElse(string? text) => Assert.Null(CompanionProtocol.DecodeBase64Url(text));

    [Theory]
    [InlineData("abcdefgh", true)]
    [InlineData("ABC-def_123", true)]
    [InlineData("abcdefg", false)]
    [InlineData("abc/defgh", false)]
    [InlineData("abc defgh", false)]
    [InlineData("abcdéfgh", false)]
    [InlineData("..\\..\\abc", false)]
    [InlineData(null, false)]
    public void IsValidId_AllowsSafeNamesOnly(string? id, bool valid) => Assert.Equal(valid, CompanionProtocol.IsValidId(id));

    [Fact]
    public void IsValidId_AllowsUpTo64Characters()
    {
        Assert.True(CompanionProtocol.IsValidId(new string('a', 64)));
        Assert.False(CompanionProtocol.IsValidId(new string('a', 65)));
    }

    [Fact]
    public void Target_DefaultsToNew()
    {
        Assert.Equal(CompanionTarget.Current, CompanionProtocol.Target("current"));
        Assert.Equal(CompanionTarget.Current, CompanionProtocol.Target(" Current "));
        Assert.Equal(CompanionTarget.New, CompanionProtocol.Target("new"));
        Assert.Equal(CompanionTarget.New, CompanionProtocol.Target("somewhere"));
        Assert.Equal(CompanionTarget.New, CompanionProtocol.Target(null));
        Assert.Equal("current", CompanionProtocol.TargetValue(CompanionTarget.Current));
        Assert.Equal("new", CompanionProtocol.TargetValue(CompanionTarget.New));
    }

    [Fact]
    public void Constants_AreTheProtocols()
    {
        Assert.Equal(1, CompanionProtocol.Version);
        Assert.Equal("_completescan._tcp", CompanionProtocol.ServiceType);
        Assert.Equal(52731, CompanionProtocol.DefaultPort);
        Assert.Equal(553_648_128L, CompanionProtocol.MaxUploadBytes);
        Assert.Equal("From phone", CompanionProtocol.PageLabel);
        Assert.Equal("1 page from Aytu's iPhone added to the queue.", CompanionProtocol.AddedMessage(1, "Aytu's iPhone"));
        Assert.Equal("3 pages from Pixel added to the queue.", CompanionProtocol.AddedMessage(3, "Pixel"));
    }

    [Fact]
    public void Messages_HaveTheirExactJson()
    {
        Assert.Equal("""{"error":"unauthorized","message":"x \"y\""}""", new CompanionError("unauthorized", "x \"y\"").ToJson());
        Assert.Equal(
            """{"token":"AAECAwQFBgcICQoLDA0ODw","phoneId":"phone-0001","phoneName":"Aytu's iPhone","platform":"ios","appVersion":"1.0"}""",
            new PairRequest(CompanionVectors.TokenText, "phone-0001", "Aytu's iPhone", "ios", "1.0").ToJson());
        Assert.Equal(
            """{"protocolVersion":1,"desktopId":"0123456789abcdef0123456789abcdef","desktopName":"AYTU-PC","deviceSecret":"AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"}""",
            new PairResponse(DesktopId, "AYTU-PC", CompanionVectors.SecretText, 1).ToJson());
        Assert.Equal(
            """{"protocolVersion":1,"desktopId":"0123456789abcdef0123456789abcdef","desktopName":"AYTU-PC","deviceSecret":"AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8","syncKey":"AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"}""",
            new PairResponse(DesktopId, "AYTU-PC", CompanionVectors.SecretText, 1, CompanionVectors.SecretText).ToJson());
        Assert.Equal("""{"service":"completescanner","protocolVersion":1,"paired":false}""", new HealthResponse(1, false).ToJson());
        Assert.Equal(
            """{"protocolVersion":1,"desktopId":"0123456789abcdef0123456789abcdef","desktopName":"AYTU-PC","queuedPages":12,"maxUploadBytes":553648128}""",
            new HelloResponse(DesktopId, "AYTU-PC", 1, 12, 553_648_128).ToJson());
        Assert.Equal("""{"packageId":"package-0001","pageCount":3,"duplicate":true}""", new InboxResponse("package-0001", 3, true).ToJson());
        Assert.Equal(
            """{"items":[{"id":"0123456789abcdef","name":"Scan 1.pdf","contentType":"application/pdf","byteCount":1234,"created":"2026-10-20T08:30:00Z"}]}""",
            Sample().ToJson());
        Assert.Equal("""{"items":[]}""", new OutboxList([]).ToJson());
    }

    [Fact]
    public void Messages_RoundTrip()
    {
        var error = new CompanionError("busy", "Wait.");
        Assert.Equal(error, CompanionError.FromJson(Utf8(error.ToJson())));
        var pair = new PairRequest(CompanionVectors.TokenText, "phone-0001", "naïve 日本 \u0001", "ios", "1.0");
        Assert.Equal(pair, PairRequest.FromJson(Utf8(pair.ToJson())));
        var response = new PairResponse(DesktopId, "AYTU-PC", CompanionVectors.SecretText, 1);
        Assert.Equal(response, PairResponse.FromJson(Utf8(response.ToJson())));
        var withKey = response with { SyncKey = CompanionVectors.SecretText };
        Assert.Equal(withKey, PairResponse.FromJson(Utf8(withKey.ToJson())));
        Assert.Equal(new HealthResponse(1, true), HealthResponse.FromJson(Utf8(new HealthResponse(1, true).ToJson())));
        var hello = new HelloResponse(DesktopId, "AYTU-PC", 1, 0, CompanionProtocol.MaxUploadBytes);
        Assert.Equal(hello, HelloResponse.FromJson(Utf8(hello.ToJson())));
        var inbox = new InboxResponse("package-0001", 2, false);
        Assert.Equal(inbox, InboxResponse.FromJson(Utf8(inbox.ToJson())));
        Assert.Equal(Sample(), OutboxList.FromJson(Utf8(Sample().ToJson())));
    }

    [Fact]
    public void Messages_AreReadLeniently()
    {
        // Wrong types and unknown keys: only those fields fall back.
        var pair = PairRequest.FromJson(Utf8("""{"token":5,"phoneId":"phone-0001","phoneName":null,"extra":[1]}"""));
        Assert.Equal(new PairRequest("", "phone-0001", "", "", ""), pair);
        var hello = HelloResponse.FromJson(Utf8("""{"protocolVersion":1,"desktopId":"d","queuedPages":"12","maxUploadBytes":-5}"""));
        Assert.Equal(new HelloResponse("d", "", 1, 0, -5), hello);
        Assert.Equal(new InboxResponse("", 0, false), InboxResponse.FromJson(Utf8("{}")));
        // A desktop from before the sync folder sends no key.
        var old = PairResponse.FromJson(Utf8("""{"protocolVersion":1,"desktopId":"d","desktopName":"PC","deviceSecret":"s"}"""));
        Assert.Equal(new PairResponse("d", "PC", "s", 1), old);
        Assert.Null(old!.SyncKey);
        Assert.Null(PairResponse.FromJson(Utf8("""{"deviceSecret":"s","syncKey":5}"""))!.SyncKey);
        // Not an object at all.
        Assert.Null(PairRequest.FromJson(Utf8("[]")));
        Assert.Null(PairRequest.FromJson(Utf8("null")));
        Assert.Null(PairRequest.FromJson(Utf8("not json")));
        Assert.Null(PairRequest.FromJson([]));
        // An error needs its code; a health answer must be CompleteScanner's.
        Assert.Null(CompanionError.FromJson(Utf8("""{"message":"x"}""")));
        Assert.Null(HealthResponse.FromJson(Utf8("""{"service":"other","protocolVersion":1}""")));
        Assert.Equal(new HealthResponse(0, false), HealthResponse.FromJson(Utf8("""{"service":"completescanner"}""")));
    }

    [Fact]
    public void OutboxList_SkipsItemsItCannotUse()
    {
        var list = OutboxList.FromJson(Utf8(
            """{"items":[{"id":"short","created":"2026-10-20T08:30:00Z"},{"id":"0123456789abcdef","name":"a.pdf"},"""
            + """{"id":"fedcba9876543210","name":"b.pdf","contentType":"application/pdf","byteCount":"x","created":"2026-10-20T08:30:00Z"}]}"""));
        Assert.NotNull(list);
        var item = Assert.Single(list.Items);
        Assert.Equal(new OutboxItem("fedcba9876543210", "b.pdf", "application/pdf", 0, Created), item);
        Assert.Equal(new OutboxList([]), OutboxList.FromJson(Utf8("""{"items":[null]}""")));
        Assert.Equal(new OutboxList([]), OutboxList.FromJson(Utf8("""{"items":5}""")));
    }

    private static readonly DateTimeOffset Created = new(2026, 10, 20, 8, 30, 0, TimeSpan.Zero);

    private static OutboxList Sample() => new([new OutboxItem("0123456789abcdef", "Scan 1.pdf", "application/pdf", 1234, Created)]);

    private static byte[] Utf8(string text) => Encoding.UTF8.GetBytes(text);
}
