import XCTest
import Foundation
import CoreGraphics
@testable import CompleteScannerKit

// Mirrors windows/LazyScan.Core.Tests/EsclTests.cs (same cases; a C# theory is one test here
// that loops over the same rows). The fixtures are the shared files in Tests/Fixtures/Escl, hand-written
// in the shape real devices send (namespace prefixes vary between devices).

final class EsclTests: XCTestCase {
    private func capabilities(_ file: String) throws -> EsclCapabilities {
        let xml: String = try EsclFixtures.text(file)
        return try EsclCapabilitiesParser.parse(xml)
    }

    private func region(_ x: Int, _ y: Int, _ width: Int, _ height: Int) -> EsclRegion {
        EsclRegion(xOffset: x, yOffset: y, width: width, height: height)
    }

    private func assertSize(_ expected: CGSize, _ actual: CGSize?, file: StaticString = #filePath, line: UInt = #line) {
        guard let actual = actual else {
            XCTFail("No size", file: file, line: line)
            return
        }
        XCTAssertEqual(Double(actual.width), Double(expected.width), accuracy: 1e-4, file: file, line: line)
        XCTAssertEqual(Double(actual.height), Double(expected.height), accuracy: 1e-4, file: file, line: line)
    }

    // MARK: - Capabilities

    func testParsesPlatenAndFeeder() throws {
        let caps: EsclCapabilities = try capabilities(EsclFixtures.platenAndDuplexAdfFile)
        XCTAssertEqual(caps.version, "2.63")
        XCTAssertEqual(caps.makeAndModel, "HP Color LaserJet MFP M479fdw")
        XCTAssertEqual(caps.uuid, "564e4333-4230-3538-3930-a0b3cce51a2b")

        let platen: EsclInputCaps = try XCTUnwrap(caps.platen)
        assertSize(CGSize(width: 8.5, height: 3508.0 / 300.0), platen.maxSizeInches)
        assertSize(CGSize(width: 8.0 / 300.0, height: 8.0 / 300.0), platen.minSizeInches)
        // 1200 × 600 is not square, so it is not offered.
        XCTAssertEqual(platen.resolutions, [75, 100, 200, 300, 600])
        XCTAssertEqual(platen.colorModes, ["BlackAndWhite1", "Grayscale8", "RGB24"])
        XCTAssertEqual(platen.documentFormats, ["application/pdf", "image/jpeg"])

        let simplex: EsclInputCaps = try XCTUnwrap(caps.adfSimplex)
        XCTAssertNotNil(caps.adfDuplex)
        assertSize(CGSize(width: 8.5, height: 14), simplex.maxSizeInches)
        XCTAssertEqual(simplex.resolutions, [200, 300])
        XCTAssertTrue(caps.supportsDuplex)
        XCTAssertEqual(caps.feeder, caps.adfSimplex)
    }

    func testPlatenAndFeederCapabilities() throws {
        let caps: ScannerCapabilities = try capabilities(EsclFixtures.platenAndDuplexAdfFile).toScannerCapabilities()
        XCTAssertEqual(caps.sources, [.flatbed, .documentFeeder])
        XCTAssertTrue(caps.supportsOverview)
        XCTAssertTrue(caps.supportsDuplex)
        XCTAssertEqual(caps.supportedResolutions, [75, 100, 200, 300, 600])
        XCTAssertEqual(Double(caps.flatbedSizeInches.width), 8.5, accuracy: 1e-4)
        assertSize(CGSize(width: 8.5, height: 14), caps.feederSizeInches)
    }

    func testFeederOnlyScannerHasNoFlatbedAndNoOverview() throws {
        let parsed: EsclCapabilities = try capabilities(EsclFixtures.feederOnlyFile)
        XCTAssertNil(parsed.platen)
        XCTAssertEqual(parsed.makeAndModel, "Brother ADS-1700W")
        XCTAssertEqual(parsed.uuid, "e3248000-80ce-11db-8000-30055c773bcf")
        XCTAssertFalse(parsed.supportsDuplex)

        let caps: ScannerCapabilities = parsed.toScannerCapabilities()
        XCTAssertEqual(caps.sources, [.documentFeeder])
        XCTAssertFalse(caps.supportsOverview)
        // The range expands to its steps; the list is the feeder's.
        XCTAssertEqual(caps.supportedResolutions, [100, 200, 300, 400, 500, 600])
        assertSize(CGSize(width: 8.6, height: 118), caps.feederSizeInches)
    }

    func testBarePlatenGetsDefaults() throws {
        let caps: ScannerCapabilities = try capabilities(EsclFixtures.barePlatenFile).toScannerCapabilities()
        XCTAssertEqual(caps.sources, [.flatbed])
        XCTAssertTrue(caps.supportsOverview)
        XCTAssertEqual(caps.supportedResolutions, [75, 150, 200, 300, 600])
        XCTAssertEqual(caps.flatbedSizeInches, EsclCapabilities.defaultAreaInches)
        XCTAssertNil(caps.feederSizeInches)
        XCTAssertFalse(caps.supportsDuplex)
    }

    func testDuplexCanBeAnnouncedAsAnAdfOption() throws {
        let caps: EsclCapabilities = try capabilities(EsclFixtures.duplexOptionFile)
        XCTAssertTrue(caps.supportsDuplex)
        XCTAssertNil(caps.adfDuplex)
        XCTAssertEqual(caps.toScannerCapabilities().sources, [.documentFeeder])
    }

    func testDeviceListingNoInputIsTreatedAsAFlatbed() throws {
        let caps: ScannerCapabilities = try EsclCapabilitiesParser
            .parse("<ScannerCapabilities><MakeAndModel>X</MakeAndModel></ScannerCapabilities>")
            .toScannerCapabilities()
        XCTAssertEqual(caps.sources, [.flatbed])
        XCTAssertTrue(caps.supportsOverview)
    }

    func testInvalidXmlIsAFormatException() {
        XCTAssertThrowsError(try EsclCapabilitiesParser.parse("<html><body>Login</body>")) { error in
            XCTAssertTrue(error is EsclFormatError)
        }
        XCTAssertThrowsError(try EsclCapabilitiesParser.parse("")) { error in
            XCTAssertTrue(error is EsclFormatError)
        }
    }

    // MARK: - Scan requests

    func testFullPlatenColorRequestSnapshot() throws {
        let caps: EsclCapabilities = try capabilities(EsclFixtures.platenAndDuplexAdfFile)
        let request: EsclScanRequest = EsclScanRequest.create(caps, source: .flatbed, colorMode: .color, dpi: 300,
                                                              selection: nil)
        let expected: String = try EsclFixtures.text(EsclFixtures.platenColorRequestFile)
        XCTAssertEqual(request.toXml(), expected)
        XCTAssertEqual(Array(request.toXml().utf8), Array(expected.utf8))
    }

    func testFeederRequestUsesTheFeederSizeAndIgnoresTheSelection() throws {
        let caps: EsclCapabilities = try capabilities(EsclFixtures.platenAndDuplexAdfFile)
        let request: EsclScanRequest = EsclScanRequest.create(caps, source: .documentFeeder, colorMode: .grayscale,
                                                              dpi: 300,
                                                              selection: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2))
        XCTAssertEqual(request.inputSource, "Feeder")
        XCTAssertEqual(request.region, region(0, 0, 2550, 4200))
        XCTAssertEqual(request.colorMode, "Grayscale8")
        let xml: String = request.toXml()
        XCTAssertTrue(xml.contains("  <pwg:InputSource>Feeder</pwg:InputSource>\n"))
        XCTAssertTrue(xml.contains("      <pwg:Height>4200</pwg:Height>\n"))
    }

    func testTwoSidedFeederRequestSnapshot() throws {
        let caps: EsclCapabilities = try capabilities(EsclFixtures.platenAndDuplexAdfFile)
        let request: EsclScanRequest = EsclScanRequest.create(caps, source: .documentFeeder, colorMode: .color,
                                                              dpi: 300, selection: nil, duplex: true)
        XCTAssertTrue(request.duplex)
        let expected: String = try EsclFixtures.text(EsclFixtures.feederTwoSidedRequestFile)
        XCTAssertEqual(request.toXml(), expected)
        XCTAssertEqual(Array(request.toXml().utf8), Array(expected.utf8))
    }

    func testTwoSidedIsAskedForOnlyFromATwoSidedFeeder() throws {
        let duplexAdf: EsclCapabilities = try capabilities(EsclFixtures.platenAndDuplexAdfFile)
        let flatbed: EsclScanRequest = EsclScanRequest.create(duplexAdf, source: .flatbed, colorMode: .color, dpi: 300,
                                                              selection: nil, duplex: true)
        XCTAssertFalse(flatbed.duplex)
        XCTAssertFalse(flatbed.toXml().contains("Duplex"))
        let oneSided: EsclScanRequest = EsclScanRequest.create(duplexAdf, source: .documentFeeder, colorMode: .color,
                                                               dpi: 300, selection: nil)
        XCTAssertFalse(oneSided.duplex)
        XCTAssertFalse(oneSided.toXml().contains("Duplex"))

        let simplexOnly: EsclCapabilities = try capabilities(EsclFixtures.feederOnlyFile)
        let request: EsclScanRequest = EsclScanRequest.create(simplexOnly, source: .documentFeeder, colorMode: .color,
                                                              dpi: 300, selection: nil, duplex: true)
        XCTAssertFalse(request.duplex)
        XCTAssertFalse(request.toXml().contains("Duplex"))

        // Two-sided announced only as an AdfOption: the feeder's own capabilities are used.
        let optionOnly: EsclCapabilities = try capabilities(EsclFixtures.duplexOptionFile)
        XCTAssertNil(optionOnly.adfDuplex)
        XCTAssertTrue(EsclScanRequest.create(optionOnly, source: .documentFeeder, colorMode: .color, dpi: 300,
                                             selection: nil, duplex: true).duplex)
    }

    func testFeederRequestUsesThePaperSize() throws {
        let caps: EsclCapabilities = try capabilities(EsclFixtures.platenAndDuplexAdfFile)
        func feederRegion(_ size: PaperSize) -> EsclRegion {
            EsclScanRequest.create(caps, source: .documentFeeder, colorMode: .color, dpi: 300, selection: nil,
                                   paperSize: size).region
        }
        XCTAssertEqual(feederRegion(.a4), region(0, 0, 2480, 3508))
        XCTAssertEqual(feederRegion(.letter), region(0, 0, 2550, 3300))
        XCTAssertEqual(feederRegion(.legal), region(0, 0, 2550, 4200))
        XCTAssertEqual(feederRegion(.auto), region(0, 0, 2550, 4200))
        // A long-paper feeder: Automatic is capped, a paper size is not needed to be.
        let longPaper: EsclCapabilities = try capabilities(EsclFixtures.feederOnlyFile)
        XCTAssertEqual(EsclScanRequest.create(longPaper, source: .documentFeeder, colorMode: .color, dpi: 300,
                                              selection: nil, paperSize: .letter).region,
                       region(0, 0, 2550, 3300))
        // The flatbed takes the paper size as a selection (the app's job), not here.
        XCTAssertEqual(EsclScanRequest.create(caps, source: .flatbed, colorMode: .color, dpi: 300, selection: nil,
                                              paperSize: .a5).region,
                       region(0, 0, 2550, 3508))
    }

    func testBlackAndWhiteIsRequestedAsGrayscale() throws {
        // The device offers BlackAndWhite1, but not as PNG/TIFF: 1-bit JPEG is what devices reject.
        let caps: EsclCapabilities = try capabilities(EsclFixtures.platenAndDuplexAdfFile)
        let request: EsclScanRequest = EsclScanRequest.create(caps, source: .flatbed, colorMode: .blackWhite, dpi: 300,
                                                              selection: nil)
        XCTAssertEqual(request.colorMode, "Grayscale8")
        XCTAssertEqual(request.documentFormat, "image/jpeg")
        XCTAssertFalse(request.toXml().contains("BlackAndWhite1"))
    }

    func testGrayFallsBackToColorWhenTheInputHasNoGrayscale() throws {
        let caps: EsclCapabilities = try capabilities(EsclFixtures.feederOnlyFile)
        XCTAssertEqual(EsclScanRequest.create(caps, source: .documentFeeder, colorMode: .grayscale, dpi: 300,
                                              selection: nil).colorMode, "RGB24")
        XCTAssertEqual(EsclScanRequest.create(caps, source: .documentFeeder, colorMode: .blackWhite, dpi: 300,
                                              selection: nil).colorMode, "RGB24")
    }

    func testFormatFallsBackToPngWhenJpegIsNotOffered() throws {
        let caps: EsclCapabilities = try capabilities(EsclFixtures.feederOnlyFile)
        XCTAssertEqual(EsclScanRequest.create(caps, source: .documentFeeder, colorMode: .color, dpi: 300,
                                              selection: nil).documentFormat, "image/png")
    }

    func testNothingListedMeansColorJpeg() throws {
        let caps: EsclCapabilities = try capabilities(EsclFixtures.barePlatenFile)
        let request: EsclScanRequest = EsclScanRequest.create(caps, source: .flatbed, colorMode: .grayscale, dpi: 250,
                                                              selection: nil)
        XCTAssertEqual(request.colorMode, "Grayscale8")
        XCTAssertEqual(request.documentFormat, "image/jpeg")
        XCTAssertEqual(request.resolution, 250)   // nothing to snap to
        XCTAssertEqual(request.region, region(0, 0, 2550, 3510))   // the default 8.5 × 11.7 in area
    }

    func testLongPaperFeederHeightIsCapped() throws {
        let caps: EsclCapabilities = try capabilities(EsclFixtures.feederOnlyFile)
        let request: EsclScanRequest = EsclScanRequest.create(caps, source: .documentFeeder, colorMode: .color, dpi: 300,
                                                              selection: nil)
        XCTAssertEqual(request.region, region(0, 0, 2580, 5100))
    }

    func testResolutionSnapsToTheInputsOwnList() throws {
        let caps: EsclCapabilities = try capabilities(EsclFixtures.platenAndDuplexAdfFile)
        // The feeder offers 200 and 300 only; the platen goes up to 600.
        XCTAssertEqual(EsclScanRequest.create(caps, source: .documentFeeder, colorMode: .color, dpi: 600,
                                              selection: nil).resolution, 300)
        XCTAssertEqual(EsclScanRequest.create(caps, source: .documentFeeder, colorMode: .color, dpi: 150,
                                              selection: nil).resolution, 200)
        XCTAssertEqual(EsclScanRequest.create(caps, source: .flatbed, colorMode: .color, dpi: 600,
                                              selection: nil).resolution, 600)
        XCTAssertEqual(EsclScanRequest.create(caps, source: .flatbed, colorMode: .color, dpi: 120,
                                              selection: nil).resolution, 100)
    }

    func testSelectionBecomesARegionOfThePlaten() throws {
        let caps: EsclCapabilities = try capabilities(EsclFixtures.platenAndDuplexAdfFile)
        let request: EsclScanRequest = EsclScanRequest.create(caps, source: .flatbed, colorMode: .color, dpi: 300,
                                                              selection: CGRect(x: 0.25, y: 0.5, width: 0.5, height: 0.25))
        XCTAssertEqual(request.region, region(638, 1754, 1275, 877))
    }

    func testSelectionNeverPassesThePlatenEdge() throws {
        let caps: EsclCapabilities = try capabilities(EsclFixtures.platenAndDuplexAdfFile)
        // A selection reaching the right and bottom edges stays inside the platen after rounding.
        let request: EsclScanRequest = EsclScanRequest.create(caps, source: .flatbed, colorMode: .color, dpi: 300,
                                                              selection: CGRect(x: 0.3333, y: 0, width: 0.6667, height: 1))
        XCTAssertLessThanOrEqual(request.region.xOffset + request.region.width, 2550)
        XCTAssertLessThanOrEqual(request.region.yOffset + request.region.height, 3508)
        XCTAssertEqual(request.region.xOffset, 850)
        XCTAssertEqual(request.region.width, 1700)
    }

    func testTinySelectionGrowsToTheMinimumSize() throws {
        let platen: String = "<Platen><PlatenInputCaps><MinWidth>300</MinWidth><MinHeight>300</MinHeight>"
            + "<MaxWidth>2550</MaxWidth><MaxHeight>3300</MaxHeight></PlatenInputCaps></Platen><Adf>"
        let xml: String = try EsclFixtures.text(EsclFixtures.feederOnlyFile).replacingOccurrences(of: "<Adf>", with: platen)
        let caps: EsclCapabilities = try EsclCapabilitiesParser.parse(xml)
        let request: EsclScanRequest = EsclScanRequest.create(caps, source: .flatbed, colorMode: .color, dpi: 300,
                                                              selection: CGRect(x: 0.995, y: 0.995, width: 0.004, height: 0.004))
        XCTAssertEqual(request.region, region(2250, 3000, 300, 300))
    }

    func testSelectionOutsideThePlatenScansTheWholePlaten() throws {
        let caps: EsclCapabilities = try capabilities(EsclFixtures.platenAndDuplexAdfFile)
        let request: EsclScanRequest = EsclScanRequest.create(caps, source: .flatbed, colorMode: .color, dpi: 300,
                                                              selection: CGRect(x: 1.5, y: 1.5, width: 0.2, height: 0.2))
        XCTAssertEqual(request.region, region(0, 0, 2550, 3508))
    }

    // MARK: - Job location

    private let scanJobs: URL = URL(string: "http://192.168.1.50:8080/eSCL/ScanJobs")!

    func testResolvesTheJobLocation() {
        let rows: [[String]] = [
            ["http://192.168.1.50:8080/eSCL/ScanJobs/42", "http://192.168.1.50:8080/eSCL/ScanJobs/42"],
            ["/eSCL/ScanJobs/42", "http://192.168.1.50:8080/eSCL/ScanJobs/42"],
            ["/eSCL/ScanJobs/42/", "http://192.168.1.50:8080/eSCL/ScanJobs/42"],
            ["ScanJobs/42", "http://192.168.1.50:8080/eSCL/ScanJobs/42"],
            ["  /eSCL/ScanJobs/urn:uuid:4509a320-00a0-008f-00b6-002507510eca  ",
             "http://192.168.1.50:8080/eSCL/ScanJobs/urn:uuid:4509a320-00a0-008f-00b6-002507510eca"],
            ["https://scanner.local/eSCL/ScanJobs/7", "https://scanner.local/eSCL/ScanJobs/7"],
        ]
        for row in rows {
            XCTAssertEqual(EsclJob.resolveLocation(scanJobs, row[0])?.absoluteString, row[1], row[0])
        }
    }

    func testMissingLocationIsNull() {
        let rows: [String?] = [nil, "", "   "]
        for row in rows {
            XCTAssertNil(EsclJob.resolveLocation(scanJobs, row), String(describing: row))
        }
    }

    func testNextDocumentIsBelowTheJob() {
        XCTAssertEqual(EsclJob.nextDocument(URL(string: "http://h/eSCL/ScanJobs/42")!).absoluteString,
                       "http://h/eSCL/ScanJobs/42/NextDocument")
        XCTAssertEqual(EsclJob.nextDocument(URL(string: "http://h/eSCL/ScanJobs/42/")!).absoluteString,
                       "http://h/eSCL/ScanJobs/42/NextDocument")
    }

    // MARK: - Scanner status

    private func status(_ state: String, _ adfState: String?) -> String {
        let adf: String = adfState.map { "<scan:AdfState>\($0)</scan:AdfState>" } ?? ""
        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <scan:ScannerStatus xmlns:scan="http://schemas.hp.com/imaging/escl/2011/05/03" xmlns:pwg="http://www.pwg.org/schemas/2010/12/sm">
              <pwg:Version>2.6</pwg:Version>
              <pwg:State>\(state)</pwg:State>
              \(adf)
              <scan:Jobs>
                <scan:JobInfo><pwg:JobState>Completed</pwg:JobState></scan:JobInfo>
              </scan:Jobs>
            </scan:ScannerStatus>
            """
    }

    func testParsesTheStatus() throws {
        let parsed: EsclScannerStatus = try XCTUnwrap(EsclScannerStatus.parse(status("Idle", "ScannerAdfEmpty")))
        XCTAssertEqual(parsed.state, "Idle")
        XCTAssertEqual(parsed.adfState, "ScannerAdfEmpty")
        XCTAssertNil(EsclScannerStatus.parse("not xml"))
    }

    func testFeederJobProblems() throws {
        struct Row {
            let state: String
            let adfState: String?
            let expected: ScannerProblem
        }
        let rows: [Row] = [
            Row(state: "Idle", adfState: "ScannerAdfEmpty", expected: .feederEmpty),
            Row(state: "Idle", adfState: "ScannerAdfJam", expected: .paperJam),
            Row(state: "Stopped", adfState: "ScannerAdfHatchOpen", expected: .coverOpen),
            Row(state: "Idle", adfState: "ScannerAdfMultipickDetected", expected: .multiFeed),
            Row(state: "Idle", adfState: "ScannerAdfMispick", expected: .paperProblem),
            Row(state: "Down", adfState: "ScannerAdfLoaded", expected: .offline),
            Row(state: "Processing", adfState: "ScannerAdfProcessing", expected: .busy),
            Row(state: "Testing", adfState: nil, expected: .warmingUp),
            Row(state: "Stopped", adfState: nil, expected: .needsAttention),
        ]
        for row in rows {
            let parsed: EsclScannerStatus = try XCTUnwrap(EsclScannerStatus.parse(status(row.state, row.adfState)))
            XCTAssertEqual(parsed.problem(.documentFeeder), row.expected, "\(row.state) \(row.adfState ?? "-")")
        }
    }

    func testPlatenJobsIgnoreTheFeederState() throws {
        let parsed: EsclScannerStatus = try XCTUnwrap(EsclScannerStatus.parse(status("Idle", "ScannerAdfEmpty")))
        XCTAssertNil(parsed.problem(.flatbed))
        let loaded: EsclScannerStatus = try XCTUnwrap(EsclScannerStatus.parse(status("Idle", "ScannerAdfLoaded")))
        XCTAssertNil(loaded.problem(.documentFeeder))
    }
}
