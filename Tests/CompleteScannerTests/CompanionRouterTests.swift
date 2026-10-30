import Foundation
import Network
import XCTest
@testable import CompleteScannerKit

// Mirrors windows/LazyScan.Core.Tests/CompanionRouterTests.cs (same cases): the desktop's
// request handling without a network, with the inbox and outbox it serves.

/// A value shared with the tasks the router starts.
final class Guarded<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) {
        stored = value
    }

    var value: Value {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            stored = newValue
            lock.unlock()
        }
    }
}

final class CompanionRouterTests: XCTestCase {
    private let phone = companionHost("192.168.1.30")
    private var directory: URL!
    /// 2026-10-20T08:30:00Z.
    private var now = Date(timeIntervalSince1970: 1_792_485_000)
    private var devices: PairedDeviceStore!
    private var inbox: CompanionInbox!
    private var outbox: CompanionOutbox!
    private var router: CompanionRouter!
    private var pairing: PairingSession?

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("CompleteScannerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        devices = PairedDeviceStore(directory: directory)
        inbox = CompanionInbox(directory: directory.appendingPathComponent("Inbox", isDirectory: true))
        outbox = CompanionOutbox(directory: directory.appendingPathComponent("Outbox", isDirectory: true))
        router = CompanionRouter(devices: devices, inbox: inbox, outbox: outbox, limiter: CompanionRateLimiter(),
                                 clock: { [unowned self] in self.now })
        router.desktopName = { "AYTU-PC" }
        router.currentPairing = { [unowned self] in self.pairing }
        router.queuedPages = { 7 }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func send(_ method: String, _ target: String, body: Data? = nil, device: String? = nil, secret: String? = nil,
                      from: NWEndpoint.Host? = nil, headers: [HttpHeader] = []) async -> CompanionResponse {
        var list = [HttpHeader("Host", "192.168.1.20:52731")]
        if let device { list.append(HttpHeader(CompanionProtocol.deviceIdHeader, device)) }
        if let secret { list.append(HttpHeader("Authorization", "Bearer " + secret)) }
        list += headers
        var length: Int64?
        if let body {
            length = Int64(body.count)
            list.append(HttpHeader("Content-Length", String(body.count)))
        }
        let head = HttpRequestHead(method: method, target: target, headers: list, contentLength: length, expectsContinue: false)
        let requestBody = CompanionRequestBody(length: length ?? 0, prefix: body ?? Data()) { _ in Data() }
        return await router.handle(CompanionRequest(head: head, body: requestBody, remote: from ?? phone))
    }

    private func pairPhone(_ id: String = "phone-0001") async throws -> String {
        let session = try PairingSession(opened: now)
        pairing = session
        let response = await send("POST", CompanionProtocol.pairPath,
                                  body: json(PairRequest(token: session.token, phoneId: id, phoneName: "Aytu's iPhone",
                                                         platform: "ios", appVersion: "1.0")))
        XCTAssertEqual(response.status, 200)
        return try XCTUnwrap(PairResponse.fromJSON(response.body)).deviceSecret
    }

    private func json(_ request: PairRequest) -> Data {
        Data(request.toJSON().utf8)
    }

    private func pairRequest(_ token: String, _ phoneId: String = "phone-0001", name: String = "P") -> Data {
        json(PairRequest(token: token, phoneId: phoneId, phoneName: name, platform: "ios", appVersion: "1"))
    }

    private func code(_ response: CompanionResponse) -> String? {
        CompanionError.fromJSON(response.body)?.code
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("Timed out waiting.")
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func testHealth_AnswersAnyoneAndChecksCredentialsWhenGiven() async throws {
        let anonymous = await send("GET", CompanionProtocol.healthPath)
        XCTAssertEqual(anonymous.status, 200)
        XCTAssertEqual(HealthResponse.fromJSON(anonymous.body), HealthResponse(protocolVersion: 1, paired: false))
        let secret = try await pairPhone()
        let paired = await send("GET", CompanionProtocol.healthPath, device: "phone-0001", secret: secret)
        XCTAssertEqual(HealthResponse.fromJSON(paired.body), HealthResponse(protocolVersion: 1, paired: true))
        let wrong = await send("GET", CompanionProtocol.healthPath, device: "phone-0001", secret: CompanionVectors.secretText)
        XCTAssertEqual(wrong.status, 401)
        XCTAssertTrue(wrong.headers.contains(HttpHeader("WWW-Authenticate", "Bearer")))
        let post = await send("POST", CompanionProtocol.healthPath, body: Data())
        XCTAssertEqual(post.status, 405)
    }

    func testPair_GivesASecretForTheOpenSessionsToken() async throws {
        let session = try PairingSession(opened: now)
        pairing = session
        let paired = Guarded<PairedDevice?>(nil)
        router.onDevicePaired = { paired.value = $0 }
        let response = await send("POST", CompanionProtocol.pairPath,
                                  body: pairRequest(session.token, name: "Aytu's\u{1} iPhone"))
        XCTAssertEqual(response.status, 200)
        let answer = try XCTUnwrap(PairResponse.fromJSON(response.body))
        XCTAssertEqual(answer.desktopId, devices.desktopId)
        XCTAssertEqual(answer.desktopName, "AYTU-PC")
        XCTAssertEqual(answer.protocolVersion, 1)
        XCTAssertNotNil(devices.authenticate(id: "phone-0001", secret: answer.deviceSecret, now: now))
        XCTAssertEqual(paired.value?.name, "Aytu's iPhone")
        // The token was single use.
        let again = await send("POST", CompanionProtocol.pairPath, body: pairRequest(session.token, "phone-0002", name: "Other"))
        XCTAssertEqual(again.status, 403)
        XCTAssertEqual(code(again), CompanionErrorCode.tokenUsed)
    }

    func testPair_RefusesWithoutAnOpenSessionOrTheRightToken() async throws {
        let closed = await send("POST", CompanionProtocol.pairPath, body: pairRequest(CompanionVectors.tokenText))
        XCTAssertEqual(code(closed), CompanionErrorCode.pairingClosed)
        pairing = try PairingSession(opened: now, token: CompanionVectors.token)
        let invalid = await send("POST", CompanionProtocol.pairPath, body: pairRequest("AAECAwQFBgcICQoLDA0ODx"))
        XCTAssertEqual(code(invalid), CompanionErrorCode.tokenInvalid)
        now = now.addingTimeInterval(6 * 60)
        let expired = await send("POST", CompanionProtocol.pairPath, body: pairRequest(CompanionVectors.tokenText))
        XCTAssertEqual(code(expired), CompanionErrorCode.tokenExpired)
        XCTAssertTrue(devices.devices.isEmpty)
    }

    func testPair_RefusesMalformedRequests() async throws {
        let session = try PairingSession(opened: now)
        pairing = session
        let notJson = await send("POST", CompanionProtocol.pairPath, body: Data("not json".utf8))
        XCTAssertEqual(notJson.status, 400)
        let badId = await send("POST", CompanionProtocol.pairPath, body: pairRequest(session.token, "bad id"))
        XCTAssertEqual(badId.status, 400)
        let noLength = await send("POST", CompanionProtocol.pairPath)
        XCTAssertEqual(noLength.status, 411)
        let tooLarge = await send("POST", CompanionProtocol.pairPath, body: Data(count: CompanionProtocol.maxJsonBodyBytes + 1))
        XCTAssertEqual(tooLarge.status, 413)
        // None of these used the token.
        XCTAssertEqual(session.state(at: now), .open)
    }

    func testPair_WaitsForTheUsersAnswer() async throws {
        pairing = try PairingSession(opened: now)
        let asked = Guarded<PairRequest?>(nil)
        router.approvePairing = { request in
            asked.value = request
            return false
        }
        let declined = await send("POST", CompanionProtocol.pairPath, body: pairRequest(pairing!.token, name: ""))
        XCTAssertEqual(declined.status, 403)
        XCTAssertEqual(code(declined), CompanionErrorCode.declined)
        XCTAssertEqual(asked.value?.phoneName, "Phone")
        XCTAssertTrue(devices.devices.isEmpty)

        pairing = try PairingSession(opened: now)
        router.approvalTimeout = 0.05
        router.approvePairing = { _ in
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            return true
        }
        let unanswered = await send("POST", CompanionProtocol.pairPath, body: pairRequest(pairing!.token))
        XCTAssertEqual(code(unanswered), CompanionErrorCode.declined)
    }

    func testPair_CountsEveryTokenCheckUntilItEnds() async throws {
        let settled = Guarded(0)
        router.onApprovalSettled = { settled.value += 1 }
        // Refused tokens: counted while checked, then nothing is left waiting.
        pairing = try PairingSession(opened: now, token: CompanionVectors.token)
        _ = await send("POST", CompanionProtocol.pairPath, body: pairRequest("AAECAwQFBgcICQoLDA0ODx"))
        XCTAssertEqual(router.awaitingApproval, 0)
        XCTAssertEqual(settled.value, 1)

        // A valid token: the used session's request is counted while the user answers.
        let seen = Guarded<(state: PairingSessionState, awaiting: Int)?>(nil)
        let answer = Guarded<Bool?>(nil)
        router.approvePairing = { [unowned self] _ in
            seen.value = (self.pairing!.state(at: self.now), self.router.awaitingApproval)
            while answer.value == nil && !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            return answer.value ?? false
        }
        let request = Task { await self.send("POST", CompanionProtocol.pairPath, body: self.pairRequest(CompanionVectors.tokenText)) }
        try await waitUntil { seen.value != nil }
        XCTAssertEqual(seen.value?.state, .used)
        XCTAssertEqual(seen.value?.awaiting, 1)
        XCTAssertEqual(router.awaitingApproval, 1)
        XCTAssertEqual(settled.value, 1)
        answer.value = true
        let response = await request.value
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(router.awaitingApproval, 0)
        XCTAssertEqual(settled.value, 2)

        // The used token again: refused, counted and settled like the others.
        let reused = await send("POST", CompanionProtocol.pairPath, body: pairRequest(CompanionVectors.tokenText, "phone-0002"))
        XCTAssertEqual(code(reused), CompanionErrorCode.tokenUsed)
        XCTAssertEqual(router.awaitingApproval, 0)
        XCTAssertEqual(settled.value, 3)
    }

    func testHello_NeedsAPairedPhone() async throws {
        let anonymous = await send("GET", CompanionProtocol.helloPath)
        XCTAssertEqual(anonymous.status, 401)
        let secret = try await pairPhone()
        let hello = await send("GET", CompanionProtocol.helloPath, device: "phone-0001", secret: secret)
        XCTAssertEqual(HelloResponse.fromJSON(hello.body),
                       HelloResponse(desktopId: devices.desktopId, desktopName: "AYTU-PC", protocolVersion: 1, queuedPages: 7,
                                     maxUploadBytes: CompanionProtocol.maxUploadBytes))
    }

    func testInbox_ReceivesAPackageOnce() async throws {
        let secret = try await pairPhone()
        let received = Guarded<[(package: ReceivedPackage, device: PairedDevice)]>([])
        router.onPackageReceived = { package, device in received.value.append((package, device)) }
        let package = try CompanionPackage.make(CompanionFixtures.minimal)
        let first = await send("PUT", CompanionProtocol.inboxPrefix + "package-0001", body: package, device: "phone-0001",
                               secret: secret, headers: [HttpHeader(CompanionProtocol.targetHeader, "current")])
        XCTAssertEqual(first.status, 201)
        XCTAssertEqual(InboxResponse.fromJSON(first.body), InboxResponse(packageId: "package-0001", pageCount: 1, duplicate: false))
        XCTAssertEqual(received.value.count, 1)
        let e = try XCTUnwrap(received.value.first)
        XCTAssertEqual(e.package.target, .current)
        XCTAssertEqual(e.device.id, "phone-0001")
        XCTAssertTrue(FileManager.default.fileExists(atPath: e.package.url.path))
        XCTAssertEqual(e.package.document.title, "Scan")

        // A retry, even after the package was imported and released, is answered as a duplicate.
        inbox.release(e.package)
        let again = await send("PUT", CompanionProtocol.inboxPrefix + "package-0001", body: package, device: "phone-0001",
                               secret: secret)
        XCTAssertEqual(again.status, 200)
        XCTAssertEqual(InboxResponse.fromJSON(again.body), InboxResponse(packageId: "package-0001", pageCount: 1, duplicate: true))
        XCTAssertEqual(received.value.count, 1)
        XCTAssertTrue(inbox.pending().isEmpty)
    }

    func testInbox_RefusesBadUploads() async throws {
        let secret = try await pairPhone()
        let package = try CompanionPackage.make(CompanionFixtures.minimal)
        let path = CompanionProtocol.inboxPrefix + "package-0001"
        let anonymous = await send("PUT", path, body: package)
        XCTAssertEqual(anonymous.status, 401)
        let wrong = await send("PUT", path, body: package, device: "phone-0001", secret: CompanionVectors.secretText)
        XCTAssertEqual(wrong.status, 401)
        let traversal = await send("PUT", CompanionProtocol.inboxPrefix + "..%2F..%2Fx", body: package, device: "phone-0001",
                                   secret: secret)
        XCTAssertEqual(traversal.status, 400)
        let short = await send("PUT", CompanionProtocol.inboxPrefix + "short", body: package, device: "phone-0001", secret: secret)
        XCTAssertEqual(short.status, 400)
        let noLength = await send("PUT", path, device: "phone-0001", secret: secret)
        XCTAssertEqual(noLength.status, 411)
        let get = await send("GET", path, device: "phone-0001", secret: secret)
        XCTAssertEqual(get.status, 405)

        var damaged = package
        damaged[damaged.count - 200] ^= 0xFF
        let refused = await send("PUT", CompanionProtocol.inboxPrefix + "package-0002", body: damaged, device: "phone-0001",
                                 secret: secret)
        XCTAssertEqual(refused.status, 422)
        XCTAssertEqual(code(refused), CompanionErrorCode.invalidPackage)
        let notZip = await send("PUT", CompanionProtocol.inboxPrefix + "package-0003", body: Data("not a zip".utf8),
                                device: "phone-0001", secret: secret)
        XCTAssertEqual(notZip.status, 422)
        // Nothing of the refused uploads is kept, and they can be sent again.
        XCTAssertNil(inbox.find(deviceId: "phone-0001", packageId: "package-0002"))
        let folder = directory.appendingPathComponent("Inbox/phone-0001", isDirectory: true)
        let parts = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".part") }
        XCTAssertEqual(parts, [])
        XCTAssertTrue(inbox.pending().isEmpty)
    }

    func testInbox_RefusesAnOversizeUploadBeforeReadingIt() async throws {
        let secret = try await pairPhone()
        let length = Int64(CompanionProtocol.maxUploadBytes) + 1
        let head = HttpRequestHead(method: "PUT", target: CompanionProtocol.inboxPrefix + "package-0001",
                                   headers: [HttpHeader("Host", "x"), HttpHeader(CompanionProtocol.deviceIdHeader, "phone-0001"),
                                             HttpHeader("Authorization", "Bearer " + secret)],
                                   contentLength: length, expectsContinue: true)
        let continued = Guarded(false)
        let body = CompanionRequestBody(length: length, sendContinue: { continued.value = true }) { _ in Data() }
        let response = await router.handle(CompanionRequest(head: head, body: body, remote: phone))
        XCTAssertEqual(response.status, 413)
        XCTAssertFalse(continued.value)
        XCTAssertTrue(body.isWithheld)
    }

    func testInbox_RefusesTheSamePackageWhileItIsReceived() async throws {
        let secret = try await pairPhone()
        XCTAssertTrue(inbox.tryBegin(deviceId: "phone-0001", packageId: "package-0001"))
        let busy = await send("PUT", CompanionProtocol.inboxPrefix + "package-0001",
                              body: try CompanionPackage.make(CompanionFixtures.minimal), device: "phone-0001", secret: secret)
        XCTAssertEqual(busy.status, 409)
        inbox.end(deviceId: "phone-0001", packageId: "package-0001")
    }

    func testOutbox_ListsSendsAndForgets() async throws {
        let secret = try await pairPhone()
        let file = directory.appendingPathComponent("Scan 1.pdf")
        try Data("%PDF-1.7 test".utf8).write(to: file)
        let item = try outbox.add(deviceId: "phone-0001", source: file, name: "Scan 1.pdf", contentType: "application/pdf", now: now)
        let listing = await send("GET", CompanionProtocol.outboxPath, device: "phone-0001", secret: secret)
        XCTAssertEqual(OutboxList.fromJSON(listing.body)?.items, [item])
        let download = await send("GET", CompanionProtocol.outboxPrefix + item.id, device: "phone-0001", secret: secret)
        XCTAssertEqual(download.status, 200)
        XCTAssertEqual(download.length, 13)
        let handle = try XCTUnwrap(download.bodyFile)
        let content = try handle.readToEnd()
        try handle.close()
        XCTAssertEqual(content, Data("%PDF-1.7 test".utf8))
        XCTAssertTrue(download.headers.contains(HttpHeader("Content-Type", "application/pdf")))
        let deleted = await send("DELETE", CompanionProtocol.outboxPrefix + item.id, device: "phone-0001", secret: secret)
        XCTAssertEqual(deleted.status, 204)
        let deletedAgain = await send("DELETE", CompanionProtocol.outboxPrefix + item.id, device: "phone-0001", secret: secret)
        XCTAssertEqual(deletedAgain.status, 404)
        let gone = await send("GET", CompanionProtocol.outboxPrefix + item.id, device: "phone-0001", secret: secret)
        XCTAssertEqual(gone.status, 404)
        // Another phone sees nothing of it.
        let other = try await pairPhone("phone-0002")
        try outbox.add(deviceId: "phone-0001", source: file, name: "Scan 2.pdf", contentType: "application/pdf", now: now)
        let otherListing = await send("GET", CompanionProtocol.outboxPath, device: "phone-0002", secret: other)
        XCTAssertEqual(OutboxList.fromJSON(otherListing.body)?.items, [])
    }

    func testOutbox_ListingWaitsForSomethingToArrive() async throws {
        let secret = try await pairPhone()
        let file = directory.appendingPathComponent("a.pdf")
        try Data("x".utf8).write(to: file)
        let done = Guarded(false)
        let listing = Task { () -> CompanionResponse in
            let response = await self.send("GET", CompanionProtocol.outboxPath + "?wait=5", device: "phone-0001", secret: secret)
            done.value = true
            return response
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(done.value)
        try outbox.add(deviceId: "phone-0001", source: file, name: "a.pdf", contentType: "application/pdf", now: now)
        let response = await listing.value
        XCTAssertEqual(OutboxList.fromJSON(response.body)?.items.count, 1)
        let soon = await send("GET", CompanionProtocol.outboxPath + "?wait=soon", device: "phone-0001", secret: secret)
        XCTAssertEqual(soon.status, 400)
    }

    func testOutbox_DropsItemsAfterAWeek() async throws {
        let secret = try await pairPhone()
        let file = directory.appendingPathComponent("a.pdf")
        try Data("x".utf8).write(to: file)
        try outbox.add(deviceId: "phone-0001", source: file, name: "a.pdf", contentType: "application/pdf", now: now)
        now = now.addingTimeInterval(8 * 24 * 60 * 60)
        let listing = await send("GET", CompanionProtocol.outboxPath, device: "phone-0001", secret: secret)
        XCTAssertEqual(OutboxList.fromJSON(listing.body)?.items, [])
    }

    func testDeviceSelf_ForgetsThePhone() async throws {
        let secret = try await pairPhone()
        let removed = Guarded<PairedDevice?>(nil)
        router.onDeviceRemoved = { removed.value = $0 }
        let response = await send("DELETE", CompanionProtocol.deviceSelfPath, device: "phone-0001", secret: secret)
        XCTAssertEqual(response.status, 204)
        XCTAssertEqual(removed.value?.id, "phone-0001")
        XCTAssertTrue(devices.devices.isEmpty)
        let hello = await send("GET", CompanionProtocol.helloPath, device: "phone-0001", secret: secret)
        XCTAssertEqual(hello.status, 401)
    }

    func testUnknownPaths_AreNotFound() async {
        let root = await send("GET", "/")
        XCTAssertEqual(root.status, 404)
        let newer = await send("GET", "/v2/health")
        XCTAssertEqual(newer.status, 404)
        let put = await send("PUT", CompanionProtocol.outboxPrefix + "0123456789abcdef", body: Data())
        XCTAssertEqual(put.status, 405)
    }

    func testWrongSecrets_AreRateLimited() async throws {
        let secret = try await pairPhone()
        let attacker = companionHost("192.168.1.66")
        for _ in 0..<CompanionRateLimiter.maxFailures {
            let refused = await send("GET", CompanionProtocol.helloPath, device: "phone-0001", secret: CompanionVectors.secretText,
                                     from: attacker)
            XCTAssertEqual(refused.status, 401)
        }
        let limited = await send("GET", CompanionProtocol.helloPath, device: "phone-0001", secret: secret, from: attacker)
        XCTAssertEqual(limited.status, 429)
        XCTAssertTrue(limited.headers.contains { $0.name == "Retry-After" })
        // Others are not affected, and the attacker may try again a minute later.
        let others = await send("GET", CompanionProtocol.helloPath, device: "phone-0001", secret: secret)
        XCTAssertEqual(others.status, 200)
        now = now.addingTimeInterval(60)
        let later = await send("GET", CompanionProtocol.helloPath, device: "phone-0001", secret: secret, from: attacker)
        XCTAssertEqual(later.status, 200)
    }

    func testWrongTokens_AreRateLimitedToo() async throws {
        let session = try PairingSession(opened: now)
        pairing = session
        let attacker = companionHost("192.168.1.66")
        for _ in 0..<PairingSession.maxFailedAttempts {
            _ = await send("POST", CompanionProtocol.pairPath, body: pairRequest(CompanionVectors.tokenText), from: attacker)
        }
        // The session is closed now, even for the right token.
        let closed = await send("POST", CompanionProtocol.pairPath, body: pairRequest(session.token))
        XCTAssertEqual(code(closed), CompanionErrorCode.pairingClosed)
    }
}
