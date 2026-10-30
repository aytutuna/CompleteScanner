import XCTest
import Foundation
@testable import LazyScanKit

// Mirrors windows/LazyScan.Core.Tests/PairingUriTests.cs (same codes, same refusals).

final class PairingUriTests: XCTestCase {
    private let desktopId = "0123456789abcdef0123456789abcdef"

    private func sample() -> PairingUri {
        PairingUri(desktopId: desktopId, name: "Aytu's PC", fingerprint: CompanionVectors.fingerprintText,
                   addresses: ["192.168.1.20", "fd00::1"], port: 52731, token: CompanionVectors.tokenText)
    }

    private let sampleText =
        "lazyscan://pair?v=1&id=0123456789abcdef0123456789abcdef&n=Aytu%27s%20PC"
            + "&fp=R1STe1-AgDTWPVEg6ThZ8R9D7-BwgdO6tHmWcwlDMS4&a=192.168.1.20,fd00%3A%3A1&p=52731&t=AAECAwQFBgcICQoLDA0ODw"

    private func assertRefused(_ kind: PairingUriErrorKind, _ text: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try PairingUri.parse(text), text, file: file, line: line) { error in
            XCTAssertEqual((error as? PairingUriError)?.kind, kind, text, file: file, line: line)
        }
    }

    func testFormat_WritesTheCode() throws {
        XCTAssertEqual(try sample().format(), sampleText)
        XCTAssertEqual(sample().description, sampleText)
    }

    func testParse_ReadsTheCode() throws {
        let code = try PairingUri.parse(sampleText)
        XCTAssertEqual(code, sample())
        XCTAssertEqual(code.fingerprintBytes, CompanionVectors.fingerprint)
    }

    func testRoundTrip_KeepsNamesAndAddresses() throws {
        let code = PairingUri(desktopId: desktopId, name: "Büro-PC 日本 & co = 100%", fingerprint: CompanionVectors.fingerprintText,
                              addresses: ["10.0.0.5", "fe80::1%12", "::ffff:192.168.0.1", "2001:db8::8a2e:370:7334"], port: 1,
                              token: CompanionVectors.tokenText)
        XCTAssertEqual(try PairingUri.parse(try code.format()), code)
        var noAddresses = code
        noAddresses.addresses = []
        XCTAssertFalse(try noAddresses.format().contains("&a="))
        XCTAssertEqual(try PairingUri.parse(try noAddresses.format()), noAddresses)
    }

    func testParse_IgnoresUnknownPartsAndTheSchemesCase() throws {
        let upper = sampleText.replacingOccurrences(of: "lazyscan://pair?", with: "LazyScan://PAIR?") + "&later=1&x"
        XCTAssertEqual(try PairingUri.parse(upper), sample())
        XCTAssertEqual(try PairingUri.parse(sampleText.replacingOccurrences(of: "&p=", with: "&&p=")), sample())
    }

    func testParse_RefusesOtherCodes() {
        for text in ["https://example.com/pair?v=1", "WIFI:S:Home;T:WPA;P:secret;;", ""] {
            assertRefused(.notPairingCode, text)
        }
    }

    func testParse_RefusesNewerVersions() {
        assertRefused(.newerVersion, "lazyscan://pair?v=2")
        assertRefused(.newerVersion, sampleText.replacingOccurrences(of: "v=1", with: "v=17"))
        XCTAssertThrowsError(try PairingUri.parse("lazyscan://pair?v=2")) { error in
            XCTAssertEqual((error as? PairingUriError)?.message, PairingUri.newerVersionMessage)
        }
    }

    func testParse_RefusesDamagedCodes() {
        for text in ["lazyscan:pair?v=1", "lazyscan://other?v=1", "lazyscan://pair",
                     "lazyscan://pair?v=0", "lazyscan://pair?v=one", "lazyscan://pair?id=x"] {
            assertRefused(.damaged, text)
        }
    }

    func testParse_RefusesBadParts() {
        let id = "&id=0123456789abcdef0123456789abcdef"
        let name = "&n=Aytu%27s%20PC"
        let fp = "&fp=R1STe1-AgDTWPVEg6ThZ8R9D7-BwgdO6tHmWcwlDMS4"
        let addresses = "&a=192.168.1.20,fd00%3A%3A1"
        let cases: [(String, String)] = [
            (id, ""),                                                     // no id
            (id, "&id=short"),                                            // id too short
            (id, id + id),
            (name, "&n="),                                                // empty name
            (name, "&n=Tab%09name"),                                      // control character
            (name, "&n=%FF"),                                             // not UTF-8
            (name, "&n=bad%2"),                                           // cut escape
            (name, "&n=bad%zz"),                                          // not hex
            (name, "&n=a b"),                                             // unescaped space
            (fp, "&fp=R1STe1-AgDTWPVEg6ThZ8R9D7-BwgdO6tHmWcwlDMQ"),       // 31 bytes
            (fp, "&fp=R1STe1+AgDTWPVEg6ThZ8R9D7-BwgdO6tHmWcwlDMS4"),      // base64, not url
            (addresses, "&a=192.168.1.256"),
            (addresses, "&a=192.168.01.2"),
            (addresses, "&a=printer.local"),
            (addresses, "&a=192.168.1.20,"),
            (addresses, "&a=1%3A2%3A3"),
            (addresses, "&a=1%3A%3A2%3A%3A3"),
            (addresses, "&a=1,2,3,4,5,6,7,8,9"),
            ("&p=52731", "&p=0"),
            ("&p=52731", "&p=65536"),
            ("&p=52731", "&p=-1"),
            ("&p=52731", ""),
            ("&t=AAECAwQFBgcICQoLDA0ODw", "&t=AAECAwQFBgcICQoLDA0O"),    // 15 bytes
            ("&t=AAECAwQFBgcICQoLDA0ODw", ""),
        ]
        for (part, replacement) in cases {
            assertRefused(.damaged, sampleText.replacingOccurrences(of: part, with: replacement))
        }
    }

    func testParse_RefusesFragmentsAndOverlongCodes() {
        assertRefused(.damaged, sampleText + "#top")
        assertRefused(.damaged, sampleText + "&pad=" + String(repeating: "a", count: PairingUri.maxLength))
    }

    func testParse_RefusesAnythingButPrintableAscii() {
        // A combining mark after a separator, an unknown key that is not ASCII, a space or a line
        // break in a key: refused alike on both platforms.
        assertRefused(.damaged, sampleText + "&\u{0301}x=1")
        assertRefused(.damaged, sampleText + "&caf\u{00E9}=1")
        assertRefused(.damaged, sampleText + "&a b=1")
        assertRefused(.damaged, sampleText + "\r\n&x=1")
        // Only ASCII letters ignore case in the scheme.
        assertRefused(.notPairingCode, "complete\u{017F}canner://pair?v=1")
    }

    func testFormat_RefusesWhatParseWould() {
        var badPort = sample()
        badPort.port = 0
        XCTAssertThrowsError(try badPort.format())
        var noName = sample()
        noName.name = ""
        XCTAssertThrowsError(try noName.format())
        var host = sample()
        host.addresses = ["host.local"]
        XCTAssertThrowsError(try host.format())
        var shortToken = sample()
        shortToken.token = "short"
        XCTAssertThrowsError(try shortToken.format())
    }

    func testIsValidAddress_ChecksIPLiterals() {
        let cases: [(String, Bool)] = [
            ("0.0.0.0", true), ("255.255.255.255", true), ("::", true), ("::1", true), ("fe80::1%eth0", true),
            ("1:2:3:4:5:6:7:8", true), ("1:2:3:4:5:6:192.168.0.1", true), ("1:2:3:4:5:6:7:8:9", false),
            ("1:2:3:4:5:6:7", false), ("12345::", false), ("fe80::1%", false), ("1.2.3", false), ("1.2.3.4.5", false), ("", false),
        ]
        for (address, valid) in cases {
            XCTAssertEqual(PairingUri.isValidAddress(address), valid, address)
        }
    }

    func testPercentEncoding_KeepsUnreservedCharactersOnly() {
        XCTAssertEqual(PairingUri.percentEncode("a-._~Z9 ,&=%é"), "a-._~Z9%20%2C%26%3D%25%C3%A9")
        XCTAssertEqual(PairingUri.percentDecode("a-._~Z9%20%2C%26%3D%25%C3%A9"), "a-._~Z9 ,&=%é")
        XCTAssertEqual(PairingUri.percentDecode("%c3%a9"), "é")
        XCTAssertNil(PairingUri.percentDecode("a&b"))
        XCTAssertNil(PairingUri.percentDecode("%C3"))
    }
}
