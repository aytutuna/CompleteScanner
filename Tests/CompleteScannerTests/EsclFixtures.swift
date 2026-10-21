import Foundation
@testable import CompleteScannerKit

// Twin of windows/CompleteScanner.Core.Tests/EsclFixtures.cs: both suites read the same files in
// Tests/Fixtures/Escl (found next to this file, on the Mac and in the iOS Simulator alike), so the eSCL
// cases on the two platforms cannot drift apart.

/// The shared eSCL fixtures.
enum EsclFixtures {
    /// An all-in-one: platen plus a feeder that scans both sides; discrete resolutions.
    static let platenAndDuplexAdfFile = "capabilities-platen-duplex-adf.xml"
    /// A sheet-fed document scanner: feeder only, a resolution range, long-paper height.
    static let feederOnlyFile = "capabilities-feeder-only.xml"
    /// A flatbed-only scanner with no sizes, modes or formats listed.
    static let barePlatenFile = "capabilities-bare-platen.xml"
    /// Duplex announced only through AdfOptions.
    static let duplexOptionFile = "capabilities-duplex-option.xml"
    /// The ScanSettings document of a full-platen color scan of `platenAndDuplexAdfFile`.
    static let platenColorRequestFile = "request-platen-color.xml"
    /// The ScanSettings document of a two-sided color feeder scan of `platenAndDuplexAdfFile`.
    static let feederTwoSidedRequestFile = "request-feeder-two-sided.xml"
    /// A TXT record in the shape HP all-in-ones advertise, one "key=value" entry per line.
    static let hpTxtFile = "txt-hp.txt"

    /// A self-signed scanner certificate (PEM) and the SHA-256 of its SubjectPublicKeyInfo.
    struct CertificateVector {
        let file: String
        let fingerprint: String
        let subject: String
    }

    static let certificates: [CertificateVector] = [
        CertificateVector(file: "certificate-rsa2048.pem",
                          fingerprint: "4ad3ab48789a9c2f6b9b8cb55503d2bdf9fa889488beca7137476c0e1bb4e4e9",
                          subject: "CN=CompleteScanner test scanner RSA-2048"),
        CertificateVector(file: "certificate-p256.pem",
                          fingerprint: "61010433c5795ff33b96976a6bc6f2aa324a36b7182a1ddcab4d234744fe7d6c",
                          subject: "CN=CompleteScanner test scanner P-256"),
        CertificateVector(file: "certificate-p384.pem",
                          fingerprint: "ef13555c8bd3534a2726779408e4e0c0ed39733864f463517d6181263f2fe199",
                          subject: "CN=CompleteScanner test scanner P-384"),
    ]

    /// Tests/Fixtures/Escl in the repository.
    static var directory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CompleteScannerTests
            .deletingLastPathComponent()   // Tests
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent("Escl", isDirectory: true)
    }

    static func url(_ name: String) -> URL {
        directory.appendingPathComponent(name)
    }

    /// A text fixture with "\n" line breaks, whatever a checkout did to them.
    static func text(_ name: String) throws -> String {
        let data: Data = try Data(contentsOf: url(name))
        let text: String = String(decoding: data, as: UTF8.self)
        return text.replacingOccurrences(of: "\r\n", with: "\n")
    }

    /// A text fixture's non-empty lines.
    static func lines(_ name: String) throws -> [String] {
        var lines: [String] = []
        for line in try text(name).components(separatedBy: "\n") where !line.isEmpty {
            lines.append(line)
        }
        return lines
    }

    /// The DER bytes of a PEM certificate fixture.
    static func certificateDER(_ name: String) throws -> Data {
        var body: String = ""
        for line in try lines(name) where !line.hasPrefix("-----") {
            body += line
        }
        guard let der = Data(base64Encoded: body) else {
            throw EsclFormatError("\(name) is not a PEM certificate.")
        }
        return der
    }
}
