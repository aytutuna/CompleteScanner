import XCTest
import Foundation
@testable import CompleteScannerKit

// Mirrors windows/CompleteScanner.Core.Tests/CompanionHttpTests.cs (same requests, same answers).

final class CompanionHttpTests: XCTestCase {
    /// The text as ISO 8859-1 bytes (one byte per character), as the C# twin sends it.
    private func parse(_ text: String) -> HttpParseResult {
        CompanionHttp.parse(text.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) })
    }

    private func assertInvalid(_ status: Int, _ text: String, file: StaticString = #filePath, line: UInt = #line) {
        let result = parse(text)
        XCTAssertEqual(result.status, .invalid, text, file: file, line: line)
        XCTAssertEqual(result.errorStatus, status, text, file: file, line: line)
    }

    func testParse_ReadsAGet() throws {
        let text = "GET /v1/outbox?wait=25&x=1 HTTP/1.1\r\nHost: 192.168.1.20:52731\r\nX-Device-Id:  phone-0001 \r\n"
            + "Authorization: Bearer abc\r\n\r\n"
        let result = parse(text)
        XCTAssertEqual(result.status, .complete)
        XCTAssertEqual(result.consumed, text.utf8.count)
        let head = try XCTUnwrap(result.head)
        XCTAssertEqual(head.method, "GET")
        XCTAssertEqual(head.target, "/v1/outbox?wait=25&x=1")
        XCTAssertEqual(head.path, "/v1/outbox")
        XCTAssertEqual(head.query, "wait=25&x=1")
        XCTAssertEqual(head.header("x-device-id"), "phone-0001")
        XCTAssertEqual(head.bearerToken, "abc")
        XCTAssertNil(head.contentLength)
        XCTAssertFalse(head.expectsContinue)
        XCTAssertEqual(head.headers.count, 3)
        XCTAssertEqual(CompanionHttp.queryParameters(head.query)["wait"], "25")
    }

    func testParse_StopsAtTheBlankLine() throws {
        let head = "PUT /v1/inbox/package-0001 HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nExpect: 100-Continue\r\n\r\n"
        let result = parse(head + "ab\ncd")
        XCTAssertEqual(result.status, .complete)
        XCTAssertEqual(result.consumed, head.utf8.count)
        XCTAssertEqual(result.head?.contentLength, 5)
        XCTAssertEqual(result.head?.expectsContinue, true)
        XCTAssertEqual(result.head?.query, "")
    }

    func testParse_WaitsForTheWholeHead() {
        for text in ["", "GET / HTTP/1.1", "GET / HTTP/1.1\r", "GET / HTTP/1.1\r\nHost: x\r\n", "GET / HTTP/1.1\r\nHost: x\r\n\r"] {
            XCTAssertEqual(parse(text).status, .incomplete, text)
        }
    }

    func testParse_RefusesWhatItDoesNotSpeak() {
        let cases: [(Int, String)] = [
            (400, "GET / HTTP/1.1\nHost: x\r\n\r\n"),                        // bare LF
            (400, "GET / HTTP/1.1\rHost: x\r\n\r\n"),                        // bare CR
            (400, "\r\nGET / HTTP/1.1\r\nHost: x\r\n\r\n"),                  // blank first line
            (400, "GET  / HTTP/1.1\r\nHost: x\r\n\r\n"),                     // two spaces
            (400, "GET / HTTP/1.1\r\n\r\n"),                                 // no Host
            (400, "GET / HTTP/1.1\r\nHost: x\r\nHost: y\r\n\r\n"),           // two Hosts
            (400, "GET v1 HTTP/1.1\r\nHost: x\r\n\r\n"),                     // not origin-form
            (400, "GET /a#b HTTP/1.1\r\nHost: x\r\n\r\n"),                   // fragment
            (400, "GET /\u{e9} HTTP/1.1\r\nHost: x\r\n\r\n"),                // not ASCII
            (400, "G\"T / HTTP/1.1\r\nHost: x\r\n\r\n"),                     // not a token
            (400, "GET / HTTP/1.1\r\nHost: x\r\n folded\r\n\r\n"),           // obsolete folding
            (400, "GET / HTTP/1.1\r\nHost x\r\n\r\n"),                       // no colon
            (400, "GET / HTTP/1.1\r\nBad Name: x\r\nHost: x\r\n\r\n"),       // space in the name
            (400, "GET / HTTP/1.1\r\nHost: x\u{1}\r\n\r\n"),                 // control character
            (400, "PUT / HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nContent-Length: 5\r\n\r\n"),
            (400, "PUT / HTTP/1.1\r\nHost: x\r\nContent-Length: -5\r\n\r\n"),
            (400, "PUT / HTTP/1.1\r\nHost: x\r\nContent-Length: 1234567890123456\r\n\r\n"),
            (400, "GET / HTTP/1\r\nHost: x\r\n\r\n"),
            (501, "PATCH / HTTP/1.1\r\nHost: x\r\n\r\n"),
            (501, "get / HTTP/1.1\r\nHost: x\r\n\r\n"),
            (501, "PUT / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n"),
            (505, "GET / HTTP/1.0\r\nHost: x\r\n\r\n"),
            (505, "GET / HTTP/2.0\r\nHost: x\r\n\r\n"),
            (417, "PUT / HTTP/1.1\r\nHost: x\r\nExpect: something\r\n\r\n"),
        ]
        for (status, text) in cases {
            assertInvalid(status, text)
        }
    }

    func testParse_LimitsTheHead() {
        assertInvalid(414, "GET /" + String(repeating: "a", count: CompanionHttp.maxRequestLineBytes) + " HTTP/1.1\r\n")
        assertInvalid(414, "GET /" + String(repeating: "a", count: CompanionHttp.maxRequestLineBytes))
        var many = "GET / HTTP/1.1\r\nHost: x\r\n"
        for i in 0..<CompanionHttp.maxHeaderCount { many += "X-\(i): y\r\n" }
        assertInvalid(431, many + "\r\n")
        assertInvalid(431, "GET / HTTP/1.1\r\nHost: x\r\nX-Big: " + String(repeating: "a", count: CompanionHttp.maxHeadBytes))
        assertInvalid(431, "GET / HTTP/1.1\r\nHost: x\r\nX-Big: " + String(repeating: "a", count: CompanionHttp.maxHeadBytes) + "\r\n\r\n")
        // Exactly at the header count limit is fine.
        var fits = "GET / HTTP/1.1\r\nHost: x\r\n"
        for i in 1..<CompanionHttp.maxHeaderCount { fits += "X-\(i): y\r\n" }
        XCTAssertEqual(parse(fits + "\r\n").status, .complete)
    }

    func testResponseHead_IsExact() {
        let head = CompanionHttp.responseHead(status: 401, headers: [HttpHeader("Content-Type", "application/json; charset=utf-8"),
                                                                     HttpHeader("WWW-Authenticate", "Bearer")], contentLength: 42)
        XCTAssertEqual(String(decoding: head, as: UTF8.self),
                       "HTTP/1.1 401 Unauthorized\r\nContent-Type: application/json; charset=utf-8\r\nWWW-Authenticate: Bearer\r\n"
                           + "Content-Length: 42\r\nConnection: close\r\n\r\n")
        XCTAssertEqual(String(decoding: CompanionHttp.responseHead(status: 204, headers: [], contentLength: 0), as: UTF8.self),
                       "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        XCTAssertEqual(String(decoding: CompanionHttp.continueResponse, as: UTF8.self), "HTTP/1.1 100 Continue\r\n\r\n")
        XCTAssertEqual(CompanionHttp.reasonPhrase(413), "Content Too Large")
        XCTAssertEqual(CompanionHttp.reasonPhrase(299), "Unknown")
    }

    func testQueryParameters_KeepTheFirstValue() {
        let values = CompanionHttp.queryParameters("a=1&a=2&b&&c=x=y")
        XCTAssertEqual(values["a"], "1")
        XCTAssertEqual(values["b"], "")
        XCTAssertEqual(values["c"], "x=y")
        XCTAssertEqual(values.count, 3)
    }

    func testBearerToken_NeedsTheBearerScheme() {
        func head(_ authorization: String) -> HttpRequestHead? {
            parse("GET / HTTP/1.1\r\nHost: x\r\nAuthorization: \(authorization)\r\n\r\n").head
        }
        XCTAssertEqual(head("bearer abc")?.bearerToken, "abc")
        XCTAssertNil(head("Basic abc")?.bearerToken)
        XCTAssertNil(parse("GET / HTTP/1.1\r\nHost: x\r\n\r\n").head?.bearerToken)
    }
}
