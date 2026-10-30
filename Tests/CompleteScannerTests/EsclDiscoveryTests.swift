import XCTest
import Foundation
#if canImport(Darwin)
import Darwin
#endif
@testable import CompleteScannerKit

// Mirrors windows/LazyScan.Core.Tests/EsclDiscoveryTests.cs (same cases; a C# theory is one test
// here that loops over the same rows; the TXT record is the shared fixture Tests/Fixtures/Escl/txt-hp.txt).
// Covers what discovery hands over: TXT records, the addresses users type, and how a scanner's DNS-SD
// services become one endpoint. One deliberate difference: a zoned IPv6 address keeps its zone in
// `baseURLText` ("%25" + zone, RFC 6874), where C#'s `BaseUri.AbsoluteUri` leaves it out.

final class EsclDiscoveryTests: XCTestCase {
    // MARK: - TXT records

    /// A TXT record in the shape HP all-in-ones advertise.
    private func hpTxt() throws -> [String] {
        try EsclFixtures.lines(EsclFixtures.hpTxtFile)
    }

    func testTxtRecordReadsTheEsclKeys() throws {
        let attributes: [String] = try hpTxt()
        let txt: EsclTxtRecord = EsclTxtRecord.parse(attributes)
        XCTAssertEqual(txt.resourcePath, "eSCL")
        XCTAssertEqual(txt.model, "HP Color LaserJet MFP M479fdw")
        XCTAssertEqual(txt.uuid, "564e4333-4230-3538-3930-a0b3cce51a2b")
        XCTAssertEqual(txt.adminUrl, "http://HPA1B2C3.local./#hId-pgAirPrint")
        XCTAssertEqual(txt.version, "2.63")
        XCTAssertEqual(txt.note, "Office")
        XCTAssertEqual(txt.duplex, true)
        XCTAssertEqual(txt.inputSources, ["platen", "adf"])
        XCTAssertEqual(txt.colorSpaces, ["color", "grayscale", "binary"])
        XCTAssertEqual(txt.documentFormats, ["application/pdf", "image/jpeg"])
    }

    func testTxtRecordDefaultsAndOddEntries() {
        let empty: EsclTxtRecord = EsclTxtRecord.parse([])
        XCTAssertEqual(empty.resourcePath, "eSCL")
        XCTAssertNil(empty.model)
        XCTAssertNil(empty.uuid)
        XCTAssertNil(empty.duplex)
        XCTAssertTrue(empty.inputSources.isEmpty)

        let odd: EsclTxtRecord = EsclTxtRecord.parse([
            "RS=/scan/",               // keys ignore case; slashes are trimmed
            "ty=First", "ty=Second",   // only the first occurrence counts
            "duplex=f", "flag", "=novalue", "is=Platen, ADF ,platen",
        ])
        XCTAssertEqual(odd.resourcePath, "scan")
        XCTAssertEqual(odd.model, "First")
        XCTAssertEqual(odd.duplex, false)
        XCTAssertEqual(odd.inputSources, ["platen", "adf"])

        // A present but empty rs means the root of the host.
        XCTAssertEqual(EsclTxtRecord.parse(["rs="]).resourcePath, "")
        XCTAssertNil(EsclTxtRecord.parse(["duplex=maybe"]).duplex)
    }

    func testUuidKeysCompareTheFormsDevicesUse() {
        let key: String = "564e4333423035383930a0b3cce51a2b"
        XCTAssertEqual(EsclTxtRecord.uuidKey("564E4333-4230-3538-3930-A0B3CCE51A2B"), key)
        XCTAssertEqual(EsclTxtRecord.uuidKey("urn:uuid:564e4333-4230-3538-3930-a0b3cce51a2b"), key)
        XCTAssertEqual(EsclTxtRecord.uuidKey("{564e4333-4230-3538-3930-a0b3cce51a2b}"), key)
        XCTAssertNil(EsclTxtRecord.uuidKey("  "))
        XCTAssertNil(EsclTxtRecord.uuidKey(nil))
    }

    // MARK: - Addresses users type

    func testAddressesParseAndNormalize() throws {
        struct Row {
            let text: String
            let secure: Bool
            let host: String
            let port: Int
            let path: String
            let canonical: String
            let baseURLText: String
        }
        let rows: [Row] = [
            Row(text: "192.168.1.50", secure: false, host: "192.168.1.50", port: 80, path: "eSCL",
                canonical: "192.168.1.50", baseURLText: "http://192.168.1.50/eSCL/"),
            Row(text: " 192.168.001.050 ", secure: false, host: "192.168.1.50", port: 80, path: "eSCL",
                canonical: "192.168.1.50", baseURLText: "http://192.168.1.50/eSCL/"),
            Row(text: "Scanner.Local", secure: false, host: "scanner.local", port: 80, path: "eSCL",
                canonical: "scanner.local", baseURLText: "http://scanner.local/eSCL/"),
            Row(text: "epson.local:8080", secure: false, host: "epson.local", port: 8080, path: "eSCL",
                canonical: "epson.local:8080", baseURLText: "http://epson.local:8080/eSCL/"),
            Row(text: "http://192.168.1.50", secure: false, host: "192.168.1.50", port: 80, path: "eSCL",
                canonical: "192.168.1.50", baseURLText: "http://192.168.1.50/eSCL/"),
            Row(text: "https://10.0.0.7", secure: true, host: "10.0.0.7", port: 443, path: "eSCL",
                canonical: "https://10.0.0.7", baseURLText: "https://10.0.0.7/eSCL/"),
            Row(text: "https://10.0.0.7:8443/eSCL/", secure: true, host: "10.0.0.7", port: 8443, path: "eSCL",
                canonical: "https://10.0.0.7:8443", baseURLText: "https://10.0.0.7:8443/eSCL/"),
            Row(text: "http://host:9090/scan/v2", secure: false, host: "host", port: 9090, path: "scan/v2",
                canonical: "http://host:9090/scan/v2", baseURLText: "http://host:9090/scan/v2/"),
            Row(text: "http://10.0.0.7/eSCL/ScannerCapabilities", secure: false, host: "10.0.0.7", port: 80, path: "eSCL",
                canonical: "10.0.0.7", baseURLText: "http://10.0.0.7/eSCL/"),
            Row(text: "10.0.0.7/eSCL", secure: false, host: "10.0.0.7", port: 80, path: "eSCL",
                canonical: "10.0.0.7", baseURLText: "http://10.0.0.7/eSCL/"),
            // C#'s BaseUri.AbsoluteUri is "http://[fe80::1]:8080/eSCL/": System.Uri leaves the zone out.
            Row(text: "[fe80::1%12]:8080", secure: false, host: "fe80::1%12", port: 8080, path: "eSCL",
                canonical: "[fe80::1%12]:8080", baseURLText: "http://[fe80::1%2512]:8080/eSCL/"),
            Row(text: "2001:DB8::5", secure: false, host: "2001:db8::5", port: 80, path: "eSCL",
                canonical: "[2001:db8::5]", baseURLText: "http://[2001:db8::5]/eSCL/"),
            Row(text: "[2001:db8::5]", secure: false, host: "2001:db8::5", port: 80, path: "eSCL",
                canonical: "[2001:db8::5]", baseURLText: "http://[2001:db8::5]/eSCL/"),
            Row(text: "https://[2001:db8::5]:9443", secure: true, host: "2001:db8::5", port: 9443, path: "eSCL",
                canonical: "https://[2001:db8::5]:9443", baseURLText: "https://[2001:db8::5]:9443/eSCL/"),
        ]
        for row in rows {
            var error: String = ""
            let parsed: ScannerAddress? = ScannerAddress.tryParse(row.text, error: &error)
            let address: ScannerAddress = try XCTUnwrap(parsed, "\(row.text): \(error)")
            XCTAssertEqual(address.secure, row.secure, row.text)
            XCTAssertEqual(address.host, row.host, row.text)
            XCTAssertEqual(address.port, row.port, row.text)
            XCTAssertEqual(address.resourcePath, row.path, row.text)
            XCTAssertEqual(address.description, row.canonical, row.text)
            XCTAssertEqual(address.baseURLText, row.baseURLText, row.text)
            if !row.baseURLText.contains("%") {
                XCTAssertEqual(address.baseURL?.absoluteString, row.baseURLText, row.text)
            }
            // The canonical text reads back as the same address.
            XCTAssertEqual(try ScannerAddress.parse(row.canonical), address, row.text)
        }
    }

    func testZonedIPv6AddressesStayUsable() throws {
        let address: ScannerAddress = try ScannerAddress.parse("[fe80::1%12]:8080")
        XCTAssertEqual(address.host, "fe80::1%12")
        XCTAssertEqual(address.port, 8080)
        XCTAssertEqual(address.authority, "[fe80::1%12]:8080")
        // The zone stays in the URL text and reads back as the same authority.
        XCTAssertEqual(EsclUrlText.authority(address.baseURLText + "ScannerCapabilities"), "[fe80::1%12]:8080")
    }

    /// The loopback interface's name, as the system's interface-name lookup takes it.
    private let loopbackName: String = "lo0"

    func testNamedZonesReadAsTheirInterfaceIndex() throws {
        let index: UInt32 = if_nametoindex(loopbackName)
        XCTAssertGreaterThan(index, 0)
        let address: ScannerAddress = try ScannerAddress.parse("[fe80::1%\(loopbackName)]:8080")
        XCTAssertEqual(address.host, "fe80::1%\(index)")
        XCTAssertEqual(address.description, "[fe80::1%\(index)]:8080")
        XCTAssertEqual(try ScannerAddress.parse(address.description), address)
        XCTAssertEqual(try ScannerAddress.parse("http://[fe80::1%\(loopbackName)]:8080").host, "fe80::1%\(index)")
        // A zone of 0 or none at all is no zone; one that names no interface is refused, not dropped.
        XCTAssertEqual(try ScannerAddress.parse("[fe80::1%0]").host, "fe80::1")
        XCTAssertEqual(try ScannerAddress.parse("[fe80::1%]").host, "fe80::1")
        var error: String = ""
        XCTAssertNil(ScannerAddress.tryParse("[fe80::1%nosuch0]", error: &error))
    }

    func testBadAddressesSayWhatIsWrong() {
        let rows: [[String]] = [
            ["", "Enter the scanner's IP address or host name."],
            ["   ", "Enter the scanner's IP address or host name."],
            ["192.168.1", "\"192.168.1\" is not a valid IP address or host name."],
            ["300.1.1.1", "\"300.1.1.1\" is not a valid IP address or host name."],
            ["scanner:0", "The port must be a number from 1 to 65535."],
            ["scanner:70000", "The port must be a number from 1 to 65535."],
            ["scanner:http", "The port must be a number from 1 to 65535."],
            ["my scanner", "An address cannot contain spaces."],
            ["ftp://10.0.0.7", "Use an address that starts with http:// or https://, or just the IP address or host name."],
            ["http://user:pw@10.0.0.7", "Leave out the user name and password; scanners do not need them."],
            ["[fe80::1", "An IPv6 address in brackets needs its closing \"]\"."],
            ["[fe80::1]x", "That is not a valid address."],
            ["bad_host!", "\"bad_host!\" is not a valid IP address or host name."],
            ["[fe80::1%nosuch0]", "\"fe80::1%nosuch0\" is not a valid IP address or host name."],
            ["fe80::1%99999999999", "\"fe80::1%99999999999\" is not a valid IP address or host name."],
            ["http://[fe80::1%nosuch0]:8080", "That is not a valid address."],
        ]
        for row in rows {
            var error: String = ""
            XCTAssertNil(ScannerAddress.tryParse(row[0], error: &error), row[0])
            XCTAssertEqual(error, row[1], row[0])
            XCTAssertThrowsError(try ScannerAddress.parse(row[0]), row[0]) { thrown in
                XCTAssertEqual((thrown as? EsclFormatError)?.message, row[1], row[0])
            }
        }
    }

    func testAddressesCompareByTheirCanonicalForm() throws {
        XCTAssertEqual(try ScannerAddress.parse("http://SCANNER.local:80/eSCL"), try ScannerAddress.parse("scanner.local"))
        XCTAssertNotEqual(try ScannerAddress.parse("https://scanner.local"), try ScannerAddress.parse("scanner.local"))
        XCTAssertNotEqual(try ScannerAddress.parse("scanner.local:8080"), try ScannerAddress.parse("scanner.local"))
        XCTAssertNil(ScannerAddress.create(secure: false, host: "host", port: 0, resourcePath: "eSCL"))
        XCTAssertNil(ScannerAddress.create(secure: false, host: "not a host", port: 80, resourcePath: "eSCL"))
        XCTAssertEqual(ScannerAddress.create(secure: false, host: "host", port: 80, resourcePath: "")?.baseURLText,
                       "http://host/")
    }

    // MARK: - Services → endpoints

    private func service(_ instance: String, secure: Bool, _ addresses: [String], _ txt: [String], port: Int = 0,
                         host: String? = "HPA1B2C3.local") -> EsclService {
        let defaultPort: Int = secure ? 443 : 80
        return EsclService(id: "id-\(instance)-\(secure)", instanceName: instance, secure: secure, hostName: host,
                           addresses: addresses, port: port == 0 ? defaultPort : port, textAttributes: txt)
    }

    func testBothServicesOfOneScannerMergeHttpsFirst() throws {
        let txt: [String] = try hpTxt()
        let endpoints: [EsclEndpoint] = EsclEndpoint.choose([
            service("HP M479 (A1B2C3)", secure: false, ["fe80::1", "192.168.1.20", "2001:db8::20"], txt),
            service("HP M479 (A1B2C3)", secure: true, ["192.168.1.20"], txt),
        ])
        XCTAssertEqual(endpoints.count, 1)
        let endpoint: EsclEndpoint = try XCTUnwrap(endpoints.first)
        XCTAssertEqual(endpoint.key, "uuid:564e4333423035383930a0b3cce51a2b")
        XCTAssertEqual(endpoint.name, "HP Color LaserJet MFP M479fdw")
        XCTAssertEqual(endpoint.uuid, "564e4333-4230-3538-3930-a0b3cce51a2b")
        // HTTPS first; IPv4, then the host name, then IPv6; link-local without a zone skipped.
        var texts: [String] = []
        for address in endpoint.addresses {
            texts.append(address.description)
        }
        XCTAssertEqual(texts, ["https://192.168.1.20", "https://hpa1b2c3.local",
                               "192.168.1.20", "hpa1b2c3.local", "[2001:db8::20]"])
    }

    func testEndpointsKeepTheResourcePathPortAndZonedAddresses() throws {
        let endpoints: [EsclEndpoint] = EsclEndpoint.choose([
            service("Canon", secure: false, ["fe80::5%7"], ["rs=/scan", "ty=Canon MF743C"], port: 8080, host: nil),
        ])
        XCTAssertEqual(endpoints.count, 1)
        let endpoint: EsclEndpoint = try XCTUnwrap(endpoints.first)
        XCTAssertEqual(endpoint.key, "name:canon")
        XCTAssertNil(endpoint.uuid)
        XCTAssertEqual(endpoint.addresses.count, 1)
        let address: ScannerAddress = try XCTUnwrap(endpoint.addresses.first)
        // C#'s BaseUri.AbsoluteUri is "http://[fe80::5]:8080/scan/", with the zone in its DnsSafeHost.
        XCTAssertEqual(address.baseURLText, "http://[fe80::5%257]:8080/scan/")
        XCTAssertEqual(address.host, "fe80::5%7")
    }

    func testAddressesWhoseZoneNamesNoInterfaceAreSkipped() throws {
        let index: UInt32 = if_nametoindex(loopbackName)
        let endpoints: [EsclEndpoint] = EsclEndpoint.choose([
            service("Canon", secure: false, ["fe80::5%nosuch0", "2001:db8::9%nosuch0", "fe80::6%\(loopbackName)"],
                    ["ty=Canon MF743C"], host: nil),
        ])
        XCTAssertEqual(endpoints.count, 1)
        let endpoint: EsclEndpoint = try XCTUnwrap(endpoints.first)
        var texts: [String] = []
        for address in endpoint.addresses {
            texts.append(address.description)
        }
        XCTAssertEqual(texts, ["[fe80::6%\(index)]"])
    }

    func testScannersStayApartAndUnusableServicesAreDropped() throws {
        let other: [String] = ["ty=Epson ET-4850", "UUID=cfe92100-67c4-11d4-a45f-f8d0273e1a0b"]
        let txt: [String] = try hpTxt()
        let endpoints: [EsclEndpoint] = EsclEndpoint.choose([
            service("HP", secure: false, ["192.168.1.20"], txt),
            service("Epson", secure: false, ["192.168.1.30"], other),
            service("Broken port", secure: false, ["192.168.1.40"], ["ty=X"], port: 70000),
            service("No address", secure: false, ["fe80::9"], ["ty=Y"], host: nil),
            // The _uscans service of the HP without a UUID of its own: the instance name ties it.
            service("HP", secure: true, ["192.168.1.20"], ["ty=HP Color LaserJet MFP M479fdw"]),
        ])
        var names: [String] = []
        for endpoint in endpoints {
            names.append(endpoint.name)
        }
        XCTAssertEqual(names, ["HP Color LaserJet MFP M479fdw", "Epson ET-4850"])
        XCTAssertEqual(endpoints.count, 2)
        if endpoints.count == 2 {
            XCTAssertEqual(endpoints[0].addresses.first?.description, "https://192.168.1.20")
            XCTAssertEqual(endpoints[1].key, "uuid:cfe9210067c411d4a45ff8d0273e1a0b")
        }
    }

    func testWithoutAModelTheInstanceNameIsTheName() throws {
        let endpoints: [EsclEndpoint] = EsclEndpoint.choose([service("Office scanner", secure: false, ["10.0.0.9"], [])])
        XCTAssertEqual(endpoints.count, 1)
        let endpoint: EsclEndpoint = try XCTUnwrap(endpoints.first)
        XCTAssertEqual(endpoint.name, "Office scanner")
        XCTAssertEqual(endpoint.txt.resourcePath, "eSCL")
    }
}
