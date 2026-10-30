using System.Text;
using LazyScan.Core;
using Xunit;

namespace LazyScan.Core.Tests;

// Mirrored by Tests/CompleteScannerTests/CompanionHttpTests.swift (same requests, same answers).

public class CompanionHttpTests
{
    private static HttpParseResult Parse(string text) => CompanionHttp.Parse(Encoding.Latin1.GetBytes(text));

    private static void AssertInvalid(int status, string text)
    {
        var result = Parse(text);
        Assert.Equal(HttpParseStatus.Invalid, result.Status);
        Assert.Equal(status, result.ErrorStatus);
    }

    [Fact]
    public void Parse_ReadsAGet()
    {
        const string text = "GET /v1/outbox?wait=25&x=1 HTTP/1.1\r\nHost: 192.168.1.20:52731\r\nX-Device-Id:  phone-0001 \r\n"
                            + "Authorization: Bearer abc\r\n\r\n";
        var result = Parse(text);
        Assert.Equal(HttpParseStatus.Complete, result.Status);
        Assert.Equal(text.Length, result.Consumed);
        var head = result.Head!;
        Assert.Equal("GET", head.Method);
        Assert.Equal("/v1/outbox?wait=25&x=1", head.Target);
        Assert.Equal("/v1/outbox", head.Path);
        Assert.Equal("wait=25&x=1", head.Query);
        Assert.Equal("phone-0001", head.Header("x-device-id"));
        Assert.Equal("abc", head.BearerToken);
        Assert.Null(head.ContentLength);
        Assert.False(head.ExpectsContinue);
        Assert.Equal(3, head.Headers.Count);
        Assert.Equal("25", CompanionHttp.QueryParameters(head.Query)["wait"]);
    }

    [Fact]
    public void Parse_StopsAtTheBlankLine()
    {
        const string head = "PUT /v1/inbox/package-0001 HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nExpect: 100-Continue\r\n\r\n";
        var result = Parse(head + "ab\ncd");
        Assert.Equal(HttpParseStatus.Complete, result.Status);
        Assert.Equal(head.Length, result.Consumed);
        Assert.Equal(5, result.Head!.ContentLength);
        Assert.True(result.Head.ExpectsContinue);
        Assert.Equal("", result.Head.Query);
    }

    [Theory]
    [InlineData("")]
    [InlineData("GET / HTTP/1.1")]
    [InlineData("GET / HTTP/1.1\r")]
    [InlineData("GET / HTTP/1.1\r\nHost: x\r\n")]
    [InlineData("GET / HTTP/1.1\r\nHost: x\r\n\r")]
    public void Parse_WaitsForTheWholeHead(string text) => Assert.Equal(HttpParseStatus.Incomplete, Parse(text).Status);

    [Theory]
    [InlineData(400, "GET / HTTP/1.1\nHost: x\r\n\r\n")]                       // bare LF
    [InlineData(400, "GET / HTTP/1.1\rHost: x\r\n\r\n")]                       // bare CR
    [InlineData(400, "\r\nGET / HTTP/1.1\r\nHost: x\r\n\r\n")]                 // blank first line
    [InlineData(400, "GET  / HTTP/1.1\r\nHost: x\r\n\r\n")]                    // two spaces
    [InlineData(400, "GET / HTTP/1.1\r\n\r\n")]                                // no Host
    [InlineData(400, "GET / HTTP/1.1\r\nHost: x\r\nHost: y\r\n\r\n")]          // two Hosts
    [InlineData(400, "GET v1 HTTP/1.1\r\nHost: x\r\n\r\n")]                    // not origin-form
    [InlineData(400, "GET /a#b HTTP/1.1\r\nHost: x\r\n\r\n")]                  // fragment
    [InlineData(400, "GET /é HTTP/1.1\r\nHost: x\r\n\r\n")]               // not ASCII
    [InlineData(400, "G\"T / HTTP/1.1\r\nHost: x\r\n\r\n")]                    // not a token
    [InlineData(400, "GET / HTTP/1.1\r\nHost: x\r\n folded\r\n\r\n")]          // obsolete folding
    [InlineData(400, "GET / HTTP/1.1\r\nHost x\r\n\r\n")]                      // no colon
    [InlineData(400, "GET / HTTP/1.1\r\nBad Name: x\r\nHost: x\r\n\r\n")]      // space in the name
    [InlineData(400, "GET / HTTP/1.1\r\nHost: x\u0001\r\n\r\n")]               // control character
    [InlineData(400, "PUT / HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nContent-Length: 5\r\n\r\n")]
    [InlineData(400, "PUT / HTTP/1.1\r\nHost: x\r\nContent-Length: -5\r\n\r\n")]
    [InlineData(400, "PUT / HTTP/1.1\r\nHost: x\r\nContent-Length: 1234567890123456\r\n\r\n")]
    [InlineData(400, "GET / HTTP/1\r\nHost: x\r\n\r\n")]
    [InlineData(501, "PATCH / HTTP/1.1\r\nHost: x\r\n\r\n")]
    [InlineData(501, "get / HTTP/1.1\r\nHost: x\r\n\r\n")]
    [InlineData(501, "PUT / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n")]
    [InlineData(505, "GET / HTTP/1.0\r\nHost: x\r\n\r\n")]
    [InlineData(505, "GET / HTTP/2.0\r\nHost: x\r\n\r\n")]
    [InlineData(417, "PUT / HTTP/1.1\r\nHost: x\r\nExpect: something\r\n\r\n")]
    public void Parse_RefusesWhatItDoesNotSpeak(int status, string text) => AssertInvalid(status, text);

    [Fact]
    public void Parse_LimitsTheHead()
    {
        AssertInvalid(414, "GET /" + new string('a', CompanionHttp.MaxRequestLineBytes) + " HTTP/1.1\r\n");
        AssertInvalid(414, "GET /" + new string('a', CompanionHttp.MaxRequestLineBytes));
        var many = new StringBuilder("GET / HTTP/1.1\r\nHost: x\r\n");
        for (int i = 0; i < CompanionHttp.MaxHeaderCount; i++) many.Append("X-").Append(i).Append(": y\r\n");
        AssertInvalid(431, many + "\r\n");
        AssertInvalid(431, "GET / HTTP/1.1\r\nHost: x\r\nX-Big: " + new string('a', CompanionHttp.MaxHeadBytes));
        AssertInvalid(431, "GET / HTTP/1.1\r\nHost: x\r\nX-Big: " + new string('a', CompanionHttp.MaxHeadBytes) + "\r\n\r\n");
        // Exactly at the header count limit is fine.
        var fits = new StringBuilder("GET / HTTP/1.1\r\nHost: x\r\n");
        for (int i = 1; i < CompanionHttp.MaxHeaderCount; i++) fits.Append("X-").Append(i).Append(": y\r\n");
        Assert.Equal(HttpParseStatus.Complete, Parse(fits + "\r\n").Status);
    }

    [Fact]
    public void ResponseHead_IsExact()
    {
        var head = CompanionHttp.ResponseHead(401, [new("Content-Type", "application/json; charset=utf-8"), new("WWW-Authenticate", "Bearer")], 42);
        Assert.Equal("HTTP/1.1 401 Unauthorized\r\nContent-Type: application/json; charset=utf-8\r\nWWW-Authenticate: Bearer\r\n"
                     + "Content-Length: 42\r\nConnection: close\r\n\r\n", Encoding.ASCII.GetString(head));
        Assert.Equal("HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
                     Encoding.ASCII.GetString(CompanionHttp.ResponseHead(204, [], 0)));
        Assert.Equal("HTTP/1.1 100 Continue\r\n\r\n", Encoding.ASCII.GetString(CompanionHttp.ContinueResponse));
        Assert.Equal("Content Too Large", CompanionHttp.ReasonPhrase(413));
        Assert.Equal("Unknown", CompanionHttp.ReasonPhrase(299));
    }

    [Fact]
    public void QueryParameters_KeepTheFirstValue()
    {
        var values = CompanionHttp.QueryParameters("a=1&a=2&b&&c=x=y");
        Assert.Equal("1", values["a"]);
        Assert.Equal("", values["b"]);
        Assert.Equal("x=y", values["c"]);
        Assert.Equal(3, values.Count);
    }

    [Fact]
    public void BearerToken_NeedsTheBearerScheme()
    {
        static HttpRequestHead Head(string authorization) =>
            Parse($"GET / HTTP/1.1\r\nHost: x\r\nAuthorization: {authorization}\r\n\r\n").Head!;
        Assert.Equal("abc", Head("bearer abc").BearerToken);
        Assert.Null(Head("Basic abc").BearerToken);
        Assert.Null(Parse("GET / HTTP/1.1\r\nHost: x\r\n\r\n").Head!.BearerToken);
    }
}
