import XCTest
import Foundation
@testable import LazyScanKit

// Mirrors windows/LazyScan.Core.Tests/SyncPackageTests.cs: the same cases and the same golden
// bytes, pinned there from the C# writer, which CryptoKit must reproduce.

final class SyncPackageTests: XCTestCase {
    private let packageId = "pkg_golden_1234"
    private let phoneId = "phone_golden_1"
    /// 0x01...0x20.
    private let key = Data((1...32).map { UInt8($0) })
    /// 0x10...0x1b.
    private let nonce = Data((0x10...0x1B).map { UInt8($0) })
    private let plaintext = Data("hello sync".utf8)

    /// "CSSYNC01", version 1, target current, the nonce, then "hello sync" sealed and its tag.
    private let golden = "435353594e433031" + "01010000" + "101112131415161718191a1b" + "da8ed674e45b6fdc2533"
        + "7cacc7081262a9c7e1084e3576d63d53"

    private func sealed() throws -> Data {
        try SyncPackage.seal(packageId: packageId, phoneId: phoneId, target: .current, plaintext: plaintext, key: key,
                             nonce: nonce)
    }

    private func refused(_ data: Data, packageId: String? = nil, phoneId: String? = nil, key: Data? = nil,
                         file: StaticString = #filePath, line: UInt = #line) -> SyncPackageError? {
        do {
            _ = try SyncPackage.open(data, packageId: packageId ?? self.packageId, phoneId: phoneId ?? self.phoneId,
                                     key: key ?? self.key)
            XCTFail("Opened", file: file, line: line)
            return nil
        } catch {
            return error as? SyncPackageError
        }
    }

    func test_seal_writesTheGoldenBytes() throws {
        XCTAssertEqual(try sealed(), DocxFixtures.bytes(golden))
    }

    func test_open_givesBackThePackageAndItsTarget() throws {
        let opened = try SyncPackage.open(DocxFixtures.bytes(golden), packageId: packageId, phoneId: phoneId, key: key)
        XCTAssertEqual(opened.target, .current)
        XCTAssertEqual(opened.plaintext, plaintext)

        let fresh = try SyncPackage.seal(packageId: packageId, phoneId: phoneId, target: .new, plaintext: plaintext, key: key)
        XCTAssertEqual(fresh.count, 8 + 16 + plaintext.count + 16)
        XCTAssertEqual(try SyncPackage.open(fresh, packageId: packageId, phoneId: phoneId, key: key).target, .new)
        let again = try SyncPackage.seal(packageId: packageId, phoneId: phoneId, target: .new, plaintext: plaintext, key: key)
        XCTAssertNotEqual(fresh.subdata(in: 12..<24), again.subdata(in: 12..<24))
    }

    func test_open_refusesAnotherKey() throws {
        var other = key
        other[31] ^= 1
        XCTAssertEqual(refused(try sealed(), key: other), .wrongKeyOrTampered)
        XCTAssertEqual(refused(try sealed(), key: key.prefix(16)), .wrongKeyOrTampered)
    }

    func test_open_refusesAFlippedByte() throws {
        for index in [9, 13, 30, -1] {
            var data = try sealed()
            data[index < 0 ? data.count + index : index] ^= 0x40
            XCTAssertEqual(refused(data), .wrongKeyOrTampered, "byte \(index)")
        }
    }

    func test_open_refusesAnotherPackageIdOrPhone() throws {
        XCTAssertEqual(refused(try sealed(), packageId: "pkg_golden_1235"), .wrongKeyOrTampered)
        XCTAssertEqual(refused(try sealed(), phoneId: "phone_golden_2"), .wrongKeyOrTampered)
    }

    func test_open_refusesANewerVersion() throws {
        var data = try sealed()
        data[8] = 2
        XCTAssertEqual(refused(data), .newerVersion)
    }

    func test_open_refusesWhatIsNotASyncPackage() throws {
        var data = try sealed()
        XCTAssertEqual(refused(data.prefix(39)), .notASyncPackage)
        XCTAssertEqual(refused(data.dropLast()), .wrongKeyOrTampered)
        XCTAssertEqual(refused(Data()), .notASyncPackage)
        data[0] = UInt8(ascii: "X")
        XCTAssertEqual(refused(data), .notASyncPackage)
    }
}
