import XCTest
import Foundation
@testable import LazyScanKit

// Mirrors windows/LazyScan.Core.Tests/PairingSessionTests.cs (same clock steps, same answers).

final class PairingSessionTests: XCTestCase {
    /// 2026-10-20T08:30:00Z.
    private let opened = Date(timeIntervalSince1970: 1_792_485_000)

    private func makeSession() throws -> PairingSession {
        try PairingSession(opened: opened, token: CompanionVectors.token)
    }

    private func minutes(_ value: Double) -> Date { opened.addingTimeInterval(value * 60) }

    func testToken_IsTheGivenBytesOrRandom() throws {
        XCTAssertEqual(try makeSession().token, CompanionVectors.tokenText)
        let a = try PairingSession(opened: opened)
        let b = try PairingSession(opened: opened)
        XCTAssertNotEqual(a.token, b.token)
        XCTAssertEqual(CompanionProtocol.decodeBase64Url(a.token)?.count, 16)
        XCTAssertThrowsError(try PairingSession(opened: opened, token: Data(count: 15)))
    }

    func testRightToken_IsAcceptedOnce() throws {
        let session = try makeSession()
        XCTAssertEqual(session.state(at: opened), .open)
        XCTAssertEqual(session.redeem(CompanionVectors.tokenText, now: minutes(1)), .accepted)
        XCTAssertEqual(session.state(at: minutes(1)), .used)
        XCTAssertEqual(session.redeem(CompanionVectors.tokenText, now: minutes(2)), .alreadyUsed)
        XCTAssertEqual(session.redeem("wrong", now: minutes(2)), .alreadyUsed)
        XCTAssertEqual(session.remaining(at: minutes(2)), 0)
    }

    func testToken_ExpiresAfterFiveMinutes() throws {
        let session = try makeSession()
        XCTAssertEqual(session.remaining(at: opened), 300)
        XCTAssertEqual(session.remaining(at: minutes(5).addingTimeInterval(-1)), 1)
        XCTAssertEqual(session.state(at: minutes(5)), .expired)
        XCTAssertEqual(session.redeem(CompanionVectors.tokenText, now: minutes(5)), .expired)
        XCTAssertEqual(session.redeem(CompanionVectors.tokenText, now: minutes(1)), .expired)
        XCTAssertEqual(try makeSession().redeem(CompanionVectors.tokenText, now: minutes(5).addingTimeInterval(-0.001)), .accepted)
    }

    func testWrongTokens_CloseTheSessionAfterFive() throws {
        let session = try makeSession()
        let almost = String(CompanionVectors.tokenText.dropLast()) + "x"
        for i in 1..<PairingSession.maxFailedAttempts {
            XCTAssertEqual(session.redeem(almost, now: opened), .wrongToken)
            XCTAssertEqual(session.failedAttempts, i)
            XCTAssertEqual(session.state(at: opened), .open)
        }
        XCTAssertEqual(session.redeem(nil, now: opened), .wrongToken)
        XCTAssertEqual(session.state(at: opened), .closed)
        XCTAssertEqual(session.redeem(CompanionVectors.tokenText, now: opened), .closed)
    }

    func testMalformedTokens_CountAsWrong() throws {
        let session = try makeSession()
        XCTAssertEqual(session.redeem("", now: opened), .wrongToken)
        XCTAssertEqual(session.redeem("AAECAwQFBgcICQoLDA0ODw==", now: opened), .wrongToken)
        XCTAssertEqual(session.redeem(CompanionVectors.tokenText + "AA", now: opened), .wrongToken)
        XCTAssertEqual(session.failedAttempts, 3)
        XCTAssertEqual(session.redeem(CompanionVectors.tokenText, now: opened), .accepted)
    }

    func testClose_RefusesTheToken() throws {
        let session = try makeSession()
        session.close()
        XCTAssertEqual(session.state(at: opened), .closed)
        XCTAssertEqual(session.redeem(CompanionVectors.tokenText, now: opened), .closed)
        let used = try makeSession()
        _ = used.redeem(CompanionVectors.tokenText, now: opened)
        used.close()
        XCTAssertEqual(used.state(at: opened), .used)
    }
}
