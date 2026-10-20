import XCTest
import Foundation
@testable import CompleteScannerKit

// Mirrors windows/CompleteScanner.Core.Tests/CompanionProtocolTests.cs (same JSON, byte for byte).

final class CompanionProtocolTests: XCTestCase {
    private let desktopId = "0123456789abcdef0123456789abcdef"
    /// 2026-10-20T08:30:00Z.
    private let created = Date(timeIntervalSince1970: 1_792_485_000)

    private func utf8(_ text: String) -> Data { Data(text.utf8) }

    private func sample() -> OutboxList {
        OutboxList(items: [OutboxItem(id: "0123456789abcdef", name: "Scan 1.pdf", contentType: "application/pdf", byteCount: 1234,
                                      created: created)])
    }

    func testBase64Url_EncodesAndDecodes() {
        let cases = [("", ""), ("f", "Zg"), ("fo", "Zm8"), ("foo", "Zm9v"), ("foob", "Zm9vYg"), ("fooba", "Zm9vYmE"),
                     ("foobar", "Zm9vYmFy")]
        for (plain, encoded) in cases {
            XCTAssertEqual(CompanionProtocol.encodeBase64Url(Data(plain.utf8)), encoded)
            XCTAssertEqual(CompanionProtocol.decodeBase64Url(encoded), Data(plain.utf8))
        }
    }

    func testBase64Url_UsesTheUrlAlphabet() {
        XCTAssertEqual(CompanionProtocol.encodeBase64Url(Data([0xFB, 0xFF, 0xBF])), "-_-_")
        XCTAssertEqual(CompanionProtocol.decodeBase64Url("-_-_"), Data([0xFB, 0xFF, 0xBF]))
        XCTAssertEqual(CompanionProtocol.encodeBase64Url(CompanionVectors.secret), CompanionVectors.secretText)
        XCTAssertEqual(CompanionProtocol.encodeBase64Url(CompanionVectors.token), CompanionVectors.tokenText)
    }

    func testBase64Url_RefusesAnythingElse() {
        for text in ["Zg==", "Zh", "Z", "Zm9v+", "Zm9v/A", "Zm 9v", nil] as [String?] {
            XCTAssertNil(CompanionProtocol.decodeBase64Url(text), text ?? "nil")
        }
    }

    func testIsValidId_AllowsSafeNamesOnly() {
        let cases: [(String?, Bool)] = [("abcdefgh", true), ("ABC-def_123", true), ("abcdefg", false), ("abc/defgh", false),
                                        ("abc defgh", false), ("abcdéfgh", false), ("..\\..\\abc", false), (nil, false)]
        for (id, valid) in cases {
            XCTAssertEqual(CompanionProtocol.isValidId(id), valid, id ?? "nil")
        }
        XCTAssertTrue(CompanionProtocol.isValidId(String(repeating: "a", count: 64)))
        XCTAssertFalse(CompanionProtocol.isValidId(String(repeating: "a", count: 65)))
    }

    func testTarget_DefaultsToNew() {
        XCTAssertEqual(CompanionProtocol.target("current"), .current)
        XCTAssertEqual(CompanionProtocol.target(" Current "), .current)
        XCTAssertEqual(CompanionProtocol.target("new"), .new)
        XCTAssertEqual(CompanionProtocol.target("somewhere"), .new)
        XCTAssertEqual(CompanionProtocol.target(nil), .new)
        XCTAssertEqual(CompanionProtocol.targetValue(.current), "current")
        XCTAssertEqual(CompanionProtocol.targetValue(.new), "new")
    }

    func testConstants_AreTheProtocols() {
        XCTAssertEqual(CompanionProtocol.version, 1)
        XCTAssertEqual(CompanionProtocol.serviceType, "_completescan._tcp")
        XCTAssertEqual(CompanionProtocol.defaultPort, 52731)
        XCTAssertEqual(CompanionProtocol.maxUploadBytes, 553_648_128)
        XCTAssertEqual(CompanionProtocol.pageLabel, "From phone")
        XCTAssertEqual(CompanionProtocol.addedMessage(1, phoneName: "Aytu's iPhone"), "1 page from Aytu's iPhone added to the queue.")
        XCTAssertEqual(CompanionProtocol.addedMessage(3, phoneName: "Pixel"), "3 pages from Pixel added to the queue.")
    }

    func testMessages_HaveTheirExactJson() {
        XCTAssertEqual(CompanionError(code: "unauthorized", message: "x \"y\"").toJSON(), #"{"error":"unauthorized","message":"x \"y\""}"#)
        XCTAssertEqual(
            PairRequest(token: CompanionVectors.tokenText, phoneId: "phone-0001", phoneName: "Aytu's iPhone", platform: "ios",
                        appVersion: "1.0").toJSON(),
            #"{"token":"AAECAwQFBgcICQoLDA0ODw","phoneId":"phone-0001","phoneName":"Aytu's iPhone","platform":"ios","appVersion":"1.0"}"#)
        XCTAssertEqual(
            PairResponse(desktopId: desktopId, desktopName: "AYTU-PC", deviceSecret: CompanionVectors.secretText, protocolVersion: 1).toJSON(),
            #"{"protocolVersion":1,"desktopId":"0123456789abcdef0123456789abcdef","desktopName":"AYTU-PC","deviceSecret":"AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"}"#)
        XCTAssertEqual(HealthResponse(protocolVersion: 1, paired: false).toJSON(),
                       #"{"service":"completescanner","protocolVersion":1,"paired":false}"#)
        XCTAssertEqual(
            HelloResponse(desktopId: desktopId, desktopName: "AYTU-PC", protocolVersion: 1, queuedPages: 12,
                          maxUploadBytes: 553_648_128).toJSON(),
            #"{"protocolVersion":1,"desktopId":"0123456789abcdef0123456789abcdef","desktopName":"AYTU-PC","queuedPages":12,"maxUploadBytes":553648128}"#)
        XCTAssertEqual(InboxResponse(packageId: "package-0001", pageCount: 3, duplicate: true).toJSON(),
                       #"{"packageId":"package-0001","pageCount":3,"duplicate":true}"#)
        XCTAssertEqual(
            sample().toJSON(),
            #"{"items":[{"id":"0123456789abcdef","name":"Scan 1.pdf","contentType":"application/pdf","byteCount":1234,"created":"2026-10-20T08:30:00Z"}]}"#)
        XCTAssertEqual(OutboxList(items: []).toJSON(), #"{"items":[]}"#)
    }

    func testMessages_RoundTrip() {
        let error = CompanionError(code: "busy", message: "Wait.")
        XCTAssertEqual(CompanionError.fromJSON(utf8(error.toJSON())), error)
        let pair = PairRequest(token: CompanionVectors.tokenText, phoneId: "phone-0001", phoneName: "naïve 日本 \u{1}", platform: "ios",
                               appVersion: "1.0")
        XCTAssertEqual(PairRequest.fromJSON(utf8(pair.toJSON())), pair)
        let response = PairResponse(desktopId: desktopId, desktopName: "AYTU-PC", deviceSecret: CompanionVectors.secretText, protocolVersion: 1)
        XCTAssertEqual(PairResponse.fromJSON(utf8(response.toJSON())), response)
        let health = HealthResponse(protocolVersion: 1, paired: true)
        XCTAssertEqual(HealthResponse.fromJSON(utf8(health.toJSON())), health)
        let hello = HelloResponse(desktopId: desktopId, desktopName: "AYTU-PC", protocolVersion: 1, queuedPages: 0,
                                  maxUploadBytes: CompanionProtocol.maxUploadBytes)
        XCTAssertEqual(HelloResponse.fromJSON(utf8(hello.toJSON())), hello)
        let inbox = InboxResponse(packageId: "package-0001", pageCount: 2, duplicate: false)
        XCTAssertEqual(InboxResponse.fromJSON(utf8(inbox.toJSON())), inbox)
        XCTAssertEqual(OutboxList.fromJSON(utf8(sample().toJSON())), sample())
    }

    func testMessages_AreReadLeniently() {
        // Wrong types and unknown keys: only those fields fall back.
        XCTAssertEqual(PairRequest.fromJSON(utf8(#"{"token":5,"phoneId":"phone-0001","phoneName":null,"extra":[1]}"#)),
                       PairRequest(token: "", phoneId: "phone-0001", phoneName: "", platform: "", appVersion: ""))
        XCTAssertEqual(HelloResponse.fromJSON(utf8(#"{"protocolVersion":1,"desktopId":"d","queuedPages":"12","maxUploadBytes":-5}"#)),
                       HelloResponse(desktopId: "d", desktopName: "", protocolVersion: 1, queuedPages: 0, maxUploadBytes: -5))
        XCTAssertEqual(InboxResponse.fromJSON(utf8("{}")), InboxResponse(packageId: "", pageCount: 0, duplicate: false))
        // Not an object at all.
        XCTAssertNil(PairRequest.fromJSON(utf8("[]")))
        XCTAssertNil(PairRequest.fromJSON(utf8("null")))
        XCTAssertNil(PairRequest.fromJSON(utf8("not json")))
        XCTAssertNil(PairRequest.fromJSON(Data()))
        // An error needs its code; a health answer must be CompleteScanner's.
        XCTAssertNil(CompanionError.fromJSON(utf8(#"{"message":"x"}"#)))
        XCTAssertNil(HealthResponse.fromJSON(utf8(#"{"service":"other","protocolVersion":1}"#)))
        XCTAssertEqual(HealthResponse.fromJSON(utf8(#"{"service":"completescanner"}"#)), HealthResponse(protocolVersion: 0, paired: false))
    }

    func testOutboxList_SkipsItemsItCannotUse() throws {
        let list = try XCTUnwrap(OutboxList.fromJSON(utf8(
            #"{"items":[{"id":"short","created":"2026-10-20T08:30:00Z"},{"id":"0123456789abcdef","name":"a.pdf"},"#
                + #"{"id":"fedcba9876543210","name":"b.pdf","contentType":"application/pdf","byteCount":"x","created":"2026-10-20T08:30:00Z"}]}"#)))
        XCTAssertEqual(list.items, [OutboxItem(id: "fedcba9876543210", name: "b.pdf", contentType: "application/pdf", byteCount: 0,
                                               created: created)])
        XCTAssertEqual(OutboxList.fromJSON(utf8(#"{"items":[null]}"#)), OutboxList(items: []))
        XCTAssertEqual(OutboxList.fromJSON(utf8(#"{"items":5}"#)), OutboxList(items: []))
    }
}
