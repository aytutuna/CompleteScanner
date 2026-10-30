import Foundation
import XCTest
@testable import LazyScanKit

// CompanionClient against a stub desktop (CompanionFakes.swift): the requests the C# FakePhone sends
// (windows/LazyScan.Core.Tests/CompanionLoopbackTests.cs), the answers the C# router gives and
// the errors they map to. The certificate check is tested on `accepts` with the shared test
// certificate; a URLProtocol stub never reaches TLS.

final class CompanionClientTests: XCTestCase {
    private func makeClient(_ fake: CompanionFakeDesktop, secret: Data? = CompanionVectors.secret,
                        addresses: [String] = [CompanionLink.address]) -> CompanionClient {
        CompanionClient(desktop: CompanionLink.desktop(fake, addresses: addresses), secret: secret,
                        protocolClasses: [CompanionStubProtocol.self])
    }

    func test_pair_sendsTheCodesTokenAndUsesTheSecretAfterwards() async throws {
        let fake = CompanionFakeDesktop()
        fake.on("POST " + CompanionProtocol.pairPath, CompanionLink.pairResponse())
        fake.on("GET " + CompanionProtocol.helloPath, CompanionLink.hello())
        let client = makeClient(fake, secret: nil)

        let response = try await client.pair(token: CompanionVectors.tokenText, phoneId: CompanionLink.phoneId,
                                             phoneName: "Test phone", platform: "ios", appVersion: "1.0")

        XCTAssertEqual(response.desktopId, CompanionLink.desktopId)
        XCTAssertEqual(response.desktopName, "Office PC")
        XCTAssertEqual(response.deviceSecret, CompanionVectors.secretText)
        let pair = try XCTUnwrap(fake.requests("POST " + CompanionProtocol.pairPath).first)
        XCTAssertEqual(pair.host, CompanionLink.address)
        XCTAssertEqual(pair.header("Content-Type"), CompanionProtocol.jsonContentType)
        XCTAssertEqual(pair.header("Content-Length"), String(pair.body.count))
        XCTAssertNil(pair.header("Authorization"))
        XCTAssertNil(pair.header(CompanionProtocol.deviceIdHeader))
        XCTAssertEqual(PairRequest.fromJSON(pair.body),
                       PairRequest(token: CompanionVectors.tokenText, phoneId: CompanionLink.phoneId,
                                   phoneName: "Test phone", platform: "ios", appVersion: "1.0"))
        // The address was found with an anonymous health check first.
        XCTAssertEqual(fake.requests.first?.key, "GET " + CompanionProtocol.healthPath)
        XCTAssertNil(fake.requests.first?.header("Authorization"))

        _ = try await client.hello()
        let hello = try XCTUnwrap(fake.requests("GET " + CompanionProtocol.helloPath).first)
        XCTAssertEqual(hello.header("Authorization"), "Bearer " + CompanionVectors.secretText)
        XCTAssertEqual(hello.header(CompanionProtocol.deviceIdHeader), CompanionLink.phoneId)
    }

    func test_pair_answerWithoutAUsableSecretIsRefused() async {
        let fake = CompanionFakeDesktop()
        fake.on("POST " + CompanionProtocol.pairPath,
                .json(200, PairResponse(desktopId: CompanionLink.desktopId, desktopName: "Office PC",
                                        deviceSecret: "short", protocolVersion: 1).toJSON()))
        do {
            _ = try await makeClient(fake, secret: nil).pair(token: CompanionVectors.tokenText,
                                                             phoneId: CompanionLink.phoneId, phoneName: "Test phone",
                                                             platform: "ios", appVersion: "1.0")
            XCTFail("A secret that is not 32 bytes was taken")
        } catch {
            guard case .badResponse? = error as? CompanionClientError else { return XCTFail("\(error)") }
        }
    }

    func test_hello_readsTheDesktop() async throws {
        let fake = CompanionFakeDesktop()
        fake.on("GET " + CompanionProtocol.helloPath, CompanionLink.hello(queuedPages: 7))

        let hello = try await makeClient(fake).hello()

        XCTAssertEqual(hello.desktopId, CompanionLink.desktopId)
        XCTAssertEqual(hello.desktopName, "Office PC")
        XCTAssertEqual(hello.queuedPages, 7)
        XCTAssertEqual(hello.maxUploadBytes, CompanionProtocol.maxUploadBytes)
    }

    func test_send_putsThePackageWithItsLengthAndTarget_newThenDuplicate() async throws {
        let fake = CompanionFakeDesktop()
        let packageId = "pkg-0001-abcd"
        fake.on("PUT " + CompanionProtocol.inboxPrefix + packageId,
                .json(201, InboxResponse(packageId: packageId, pageCount: 3, duplicate: false).toJSON()),
                .json(200, InboxResponse(packageId: packageId, pageCount: 3, duplicate: true).toJSON()))
        let client = makeClient(fake)
        let package = Data("PK fake package".utf8)

        let first = try await client.send(packageId: packageId, data: package, target: .current)
        let second = try await client.send(packageId: packageId, data: package, target: .current)

        XCTAssertEqual(first, InboxResponse(packageId: packageId, pageCount: 3, duplicate: false))
        XCTAssertEqual(second, InboxResponse(packageId: packageId, pageCount: 3, duplicate: true))
        let put = try XCTUnwrap(fake.requests("PUT " + CompanionProtocol.inboxPrefix + packageId).first)
        XCTAssertEqual(put.body, package)
        XCTAssertEqual(put.header("Content-Length"), String(package.count))
        XCTAssertNil(put.header("Transfer-Encoding"))
        XCTAssertEqual(put.header(CompanionProtocol.targetHeader), "current")
        XCTAssertEqual(put.header("Content-Type"), CompanionProtocol.packageContentType)
        XCTAssertEqual(put.header("Expect"), "100-continue")
        XCTAssertEqual(put.header("Authorization"), "Bearer " + CompanionVectors.secretText)
        XCTAssertEqual(put.header(CompanionProtocol.deviceIdHeader), CompanionLink.phoneId)
    }

    func test_401_isUnauthorized() async {
        let fake = CompanionFakeDesktop()
        fake.on("GET " + CompanionProtocol.helloPath, CompanionLink.unauthorized)
        do {
            _ = try await makeClient(fake).hello()
            XCTFail("401 was taken")
        } catch {
            guard case .unauthorized? = error as? CompanionClientError else { return XCTFail("\(error)") }
            XCTAssertEqual(error.localizedDescription, CompanionError.unauthorized.message)
        }
    }

    func test_429_isRateLimitedForRetryAfter() async {
        let fake = CompanionFakeDesktop()
        fake.on("GET " + CompanionProtocol.helloPath, .error(429, CompanionError.rateLimited, headers: ["Retry-After": "60"]))
        do {
            _ = try await makeClient(fake).hello()
            XCTFail("429 was taken")
        } catch {
            guard case .rateLimited(let seconds)? = error as? CompanionClientError else { return XCTFail("\(error)") }
            XCTAssertEqual(seconds, 60)
        }
    }

    func test_errorBody_isSurfacedWithItsCodeAndMessage() async {
        let fake = CompanionFakeDesktop()
        fake.on("POST " + CompanionProtocol.pairPath, .error(403, CompanionError.tokenExpired))
        fake.on("PUT " + CompanionProtocol.inboxPrefix + "*",
                .error(422, CompanionError(code: CompanionErrorCode.invalidPackage, message: "Page 2's picture is damaged.")))
        let client = makeClient(fake, secret: nil)
        do {
            _ = try await client.pair(token: CompanionVectors.tokenText, phoneId: CompanionLink.phoneId,
                                      phoneName: "Test phone", platform: "ios", appVersion: "1.0")
            XCTFail("403 was taken")
        } catch {
            guard case .refused(let status, let refusal)? = error as? CompanionClientError else { return XCTFail("\(error)") }
            XCTAssertEqual(status, 403)
            XCTAssertEqual(refusal.code, CompanionErrorCode.tokenExpired)
            XCTAssertEqual(error.localizedDescription, CompanionError.tokenExpired.message)
        }
        do {
            _ = try await client.send(packageId: "pkg-0002-abcd", data: Data("x".utf8), target: .new)
            XCTFail("422 was taken")
        } catch {
            guard case .invalidPackage(let refusal)? = error as? CompanionClientError else { return XCTFail("\(error)") }
            XCTAssertEqual(refusal.code, CompanionErrorCode.invalidPackage)
            XCTAssertEqual(error.localizedDescription, "Page 2's picture is damaged.")
        }
    }

    func test_statusWithoutABody_saysTheStatus() async {
        let fake = CompanionFakeDesktop()
        fake.on("PUT " + CompanionProtocol.inboxPrefix + "*", .empty(501))
        do {
            _ = try await makeClient(fake).send(packageId: "pkg-0003-abcd", data: Data("x".utf8), target: .new)
            XCTFail("501 was taken")
        } catch {
            guard case .refused(501, _)? = error as? CompanionClientError else { return XCTFail("\(error)") }
            XCTAssertEqual(error.localizedDescription, CompanionText.refusedMessage(501))
        }
    }

    func test_addresses_theSecondIsTriedWhenTheFirstDoesNotAnswer() async throws {
        let fake = CompanionFakeDesktop()
        fake.on("GET " + CompanionProtocol.helloPath, CompanionLink.hello())
        fake.downHosts = [CompanionLink.address]
        let client = makeClient(fake, addresses: [CompanionLink.address, "10.0.0.5"])

        _ = try await client.hello()
        _ = try await client.hello()

        XCTAssertEqual(client.address, "10.0.0.5")
        var seen: [String] = []
        for request in fake.requests {
            seen.append("\(request.key) @\(request.host)")
        }
        XCTAssertEqual(seen, [
            "GET \(CompanionProtocol.healthPath) @\(CompanionLink.address)",
            "GET \(CompanionProtocol.healthPath) @10.0.0.5",
            "GET \(CompanionProtocol.helloPath) @10.0.0.5",
            "GET \(CompanionProtocol.helloPath) @10.0.0.5",
        ])
    }

    func test_addresses_noneAnswering_isUnreachable() async {
        let fake = CompanionFakeDesktop()
        fake.downHosts = [CompanionLink.address, "10.0.0.5"]
        do {
            _ = try await makeClient(fake, addresses: [CompanionLink.address, "10.0.0.5"]).hello()
            XCTFail("Nothing answered")
        } catch {
            guard case .unreachable? = error as? CompanionClientError else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(fake.requests.count, 2)
    }

    func test_addresses_theOneInUseStopsAnswering_theOthersAreTriedAgain() async throws {
        let fake = CompanionFakeDesktop()
        fake.on("GET " + CompanionProtocol.helloPath, CompanionLink.hello())
        let client = makeClient(fake, addresses: [CompanionLink.address, "10.0.0.5"])
        _ = try await client.hello()
        XCTAssertEqual(client.address, CompanionLink.address)

        fake.downHosts = [CompanionLink.address]
        _ = try await client.hello()

        XCTAssertEqual(client.address, "10.0.0.5")
    }

    func test_send_aConnectionThatBrokeUnderTheBody_desktopNotAnswering_isNotSentAgain() async throws {
        let fake = CompanionFakeDesktop()
        fake.on("GET " + CompanionProtocol.helloPath, CompanionLink.hello(),
                CompanionStubAnswer(failure: .networkConnectionLost))
        fake.on("PUT " + CompanionProtocol.inboxPrefix + "*", CompanionStubAnswer(failure: .networkConnectionLost))
        let client = makeClient(fake, addresses: [CompanionLink.address, "10.0.0.5"])
        _ = try await client.hello()

        do {
            _ = try await client.send(packageId: "pkg-0001-abcd", data: Data("PK fake package".utf8), target: .new)
            XCTFail("The connection broke")
        } catch {
            guard case .unreachable? = error as? CompanionClientError else { return XCTFail("\(error)") }
        }
        var seen: [String] = []
        for request in fake.requests {
            seen.append("\(request.method) \(request.host)")
        }
        XCTAssertEqual(seen, ["GET \(CompanionLink.address)", "GET \(CompanionLink.address)", "PUT \(CompanionLink.address)",
                              "GET \(CompanionLink.address)"])
    }

    func test_send_aConnectionThatBrokeUnderTheBody_then401_isUnauthorized() async {
        let fake = CompanionFakeDesktop()
        fake.on("GET " + CompanionProtocol.helloPath, CompanionLink.unauthorized)
        fake.on("PUT " + CompanionProtocol.inboxPrefix + "*", CompanionStubAnswer(failure: .networkConnectionLost))
        do {
            _ = try await makeClient(fake).send(packageId: "pkg-0001-abcd", data: Data("PK fake package".utf8), target: .new)
            XCTFail("The desktop no longer knows the phone")
        } catch {
            guard case .unauthorized? = error as? CompanionClientError else { return XCTFail("\(error)") }
        }
        let hello = fake.requests("GET " + CompanionProtocol.helloPath)
        XCTAssertEqual(hello.count, 1)
        XCTAssertEqual(hello.first?.header("Authorization"), "Bearer " + CompanionVectors.secretText)
        XCTAssertEqual(hello.first?.body, Data())
        XCTAssertEqual(fake.requests.filter { $0.method == "PUT" }.count, 1)
    }

    func test_send_aConnectionThatBrokeUnderTheBody_desktopAnswering_isSentOnceMore() async throws {
        let fake = CompanionFakeDesktop()
        let packageId = "pkg-0001-abcd"
        fake.on("GET " + CompanionProtocol.helloPath, CompanionLink.hello())
        fake.on("PUT " + CompanionProtocol.inboxPrefix + packageId, CompanionStubAnswer(failure: .networkConnectionLost),
                .json(200, InboxResponse(packageId: packageId, pageCount: 2, duplicate: true).toJSON()))
        let package = Data("PK fake package".utf8)

        let response = try await makeClient(fake).send(packageId: packageId, data: package, target: .new)

        XCTAssertEqual(response, InboxResponse(packageId: packageId, pageCount: 2, duplicate: true))
        var keys: [String] = []
        for request in fake.requests {
            keys.append(request.key)
        }
        XCTAssertEqual(keys, ["GET " + CompanionProtocol.healthPath, "PUT " + CompanionProtocol.inboxPrefix + packageId,
                              "GET " + CompanionProtocol.helloPath, "PUT " + CompanionProtocol.inboxPrefix + packageId])
        XCTAssertEqual(fake.requests("PUT " + CompanionProtocol.inboxPrefix + packageId).last?.body, package)
    }

    func test_outbox_waitIsClampedAndTheItemDownloadedAndAcked() async throws {
        let fake = CompanionFakeDesktop()
        let item = OutboxItem(id: "item-0001-abcd", name: "Receipt.lsdoc", contentType: CompanionProtocol.packageContentType,
                              byteCount: 5, created: Date(timeIntervalSince1970: 1_790_000_000))
        fake.on("GET " + CompanionProtocol.outboxPath, .json(200, OutboxList(items: [item]).toJSON()))
        fake.on("GET " + CompanionProtocol.outboxPrefix + item.id,
                CompanionStubAnswer(status: 200, body: Data("bytes".utf8),
                                    headers: ["Content-Type": CompanionProtocol.packageContentType]))
        fake.on("DELETE " + CompanionProtocol.outboxPrefix + item.id, .empty(204))
        let client = makeClient(fake)

        let list = try await client.outbox(wait: 60)
        let data = try await client.outboxItem(id: item.id)
        try await client.ack(id: item.id)

        XCTAssertEqual(list.items, [item])
        XCTAssertEqual(fake.requests("GET " + CompanionProtocol.outboxPath).first?.query, "wait=25")
        XCTAssertEqual(data, Data("bytes".utf8))
        let ack = try XCTUnwrap(fake.requests("DELETE " + CompanionProtocol.outboxPrefix + item.id).first)
        XCTAssertEqual(ack.header("Authorization"), "Bearer " + CompanionVectors.secretText)
    }

    func test_unpair_deletesItself() async throws {
        let fake = CompanionFakeDesktop()
        fake.on("DELETE " + CompanionProtocol.deviceSelfPath, .empty(204))

        try await makeClient(fake).unpair()

        XCTAssertEqual(fake.requests("DELETE " + CompanionProtocol.deviceSelfPath).count, 1)
    }

    func test_accepts_onlyTheCertificateWithThePinnedKey() {
        XCTAssertTrue(CompanionClient.accepts(CompanionVectors.certificate, pinned: CompanionVectors.fingerprint))
        var other = CompanionVectors.fingerprint
        other[0] ^= 0x01
        XCTAssertFalse(CompanionClient.accepts(CompanionVectors.certificate, pinned: other))
        XCTAssertFalse(CompanionClient.accepts(CompanionVectors.certificate, pinned: nil))
        XCTAssertFalse(CompanionClient.accepts(nil, pinned: CompanionVectors.fingerprint))
        XCTAssertFalse(CompanionClient.accepts(Data("not a certificate".utf8), pinned: CompanionVectors.fingerprint))
        XCTAssertFalse(CompanionClient.accepts(CompanionVectors.certificate, pinned: CompanionVectors.fingerprint.prefix(16)))
    }

    func test_url_bracketsIPv6() {
        XCTAssertEqual(CompanionClient.url("192.168.1.20", port: 52731, path: "/v1/health")?.absoluteString,
                       "https://192.168.1.20:52731/v1/health")
        XCTAssertEqual(CompanionClient.url("fe80::1", port: 52731, path: "/v1/hello")?.absoluteString,
                       "https://[fe80::1]:52731/v1/hello")
    }
}
