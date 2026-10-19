import XCTest
@testable import CompleteScannerKit

// Mirrors windows/CompleteScanner.Core.Tests/DeviceMergeTests.cs: same tables, same cases.

final class DeviceMergeTests: XCTestCase {

    private func wia(_ name: String, model: String? = nil, id: String = "1") -> ScannerInfo {
        ScannerInfo(id: "wia:\(name)#\(id)", name: name, transport: "WIA", backend: "wia", model: model)
    }

    private func twain(_ name: String, id: String = "1") -> ScannerInfo {
        ScannerInfo(id: "twain:\(name)#\(id)", name: name, transport: "USB", backend: "twain")
    }

    private func escl(_ name: String, uuid: String? = nil, id: String = "1") -> ScannerInfo {
        ScannerInfo(id: "escl:\(name)#\(id)", name: name, transport: "Network", backend: "escl",
                    model: name, hardwareID: uuid)
    }

    private func ic(_ name: String, _ transport: String) -> ScannerInfo {
        ScannerInfo(id: "ic:\(transport):\(name)", name: name, transport: transport, backend: "ic")
    }

    private let demo = ScannerInfo(id: "mock:demo", name: "Demo Scanner", transport: "Demo", isDemo: true, backend: "mock")

    // MARK: - Model keys

    func test_modelKey_normalizesNames() {
        let cases: [(String, String)] = [
            ("EPSON Perfection V600 Photo", "epson perfection v600 photo"),
            ("HP LaserJet MFP M428fdw (192.168.1.20)", "hp laserjet mfp m428fdw"),
            ("Hewlett-Packard ScanJet 200 TWAIN", "hp scanjet 200"),
            ("SEIKO EPSON DS-530 Series", "epson 530"),
            ("Kodak Alaris i2600 Scanner", "kodak i2600"),
            ("Brother MFC-L2710DW fe80::1c2b:3d4e:5f60:7a8b%12", "brother mfc l2710dw"),
            ("Canon MF743C 10.0.0.7:8080", "canon mf743c"),
            ("WIA-Brother ADS-2200 64-bit driver", "brother ads 2200"),
            ("Fujitsu fi-7160 x64 USB", "fujitsu fi 7160"),
            ("Epson ES-400 epson ES-400", "epson es 400"),
            ("Canon LiDE 300 [WSD] {TWAIN}", "canon lide 300"),
            ("Ricoh Café 7500", "ricoh caf 7500"),
            ("Scanner (USB)", ""),
        ]
        for (name, expected) in cases {
            XCTAssertEqual(DeviceMerge.modelKey(name), expected, name)
        }
    }

    // MARK: - Same device

    func test_sameDevice_followsTheRules() {
        let cases: [(String, ScannerInfo, ScannerInfo, Bool)] = [
            ("WIA V600 and TWAIN V600 Photo", wia("EPSON Perfection V600"), twain("EPSON Perfection V600 Photo"), true),
            ("different hardware ids stay apart", escl("HP M428", uuid: "uuid-a"),
             ScannerInfo(id: "twain:m428", name: "HP M428", transport: "USB", backend: "twain", hardwareID: "uuid-b"), false),
            ("equal hardware ids match whatever the names", escl("HP M428", uuid: "uuid-a"),
             ScannerInfo(id: "twain:x", name: "Office printer", transport: "USB", backend: "twain", hardwareID: "UUID-A"), true),
            ("hardware ids compare without urn prefix, case or dashes", escl("HP M428", uuid: "urn:uuid:4509A320-00A0-008F"),
             ScannerInfo(id: "twain:x", name: "Other", transport: "USB", backend: "twain", hardwareID: "4509a32000a0008f"), true),
            ("one hardware id: the names decide", escl("HP LaserJet MFP M428fdw", uuid: "uuid-a"), wia("HP LaserJet MFP M428fdw"), true),
            ("same backend and transport never merge", wia("Canon LiDE 300", id: "1"), wia("Canon LiDE 300", id: "2"), false),
            ("demo devices never merge", demo, wia("Demo Scanner"), false),
            ("containment without a model number", wia("HP Scanjet"), twain("HP Scanjet Pro"), false),
            ("containment sharing one word", wia("Canon"), twain("Canon LiDE 300"), false),
            ("neither contains the other", wia("Epson ET-2850"), twain("Epson ET-4850"), false),
            ("equal words without a digit", wia("Plustek OpticSlim"), twain("Plustek OpticSlim TWAIN"), true),
            ("the model matches when the name does not", wia("Office scanner", model: "Canon Canon LiDE 300"), twain("Canon LiDE 300"), true),
            ("the name matches when the model is generic", wia("EPSON Perfection V600", model: "EPSON WIA Scanner Device"), twain("EPSON Perfection V600 Photo"), true),
            ("names without model words never match", wia("Scanner"), twain("TWAIN Scanner"), false),
            ("macOS USB and Bonjour entries", ic("Brother MFC-L2710DW series", "USB"), ic("Brother MFC-L2710DW", "Network"), true),
        ]
        for (name, a, b, expected) in cases {
            XCTAssertEqual(DeviceMerge.sameDevice(a, b), expected, name)
            XCTAssertEqual(DeviceMerge.sameDevice(b, a), expected, name + " (swapped)")
        }
    }

    // MARK: - Grouping and ranking

    func test_group_mergesWiaAndTwainAndPrefersWia() {
        let twainEntry = twain("EPSON Perfection V600 Photo")
        let wiaEntry = wia("EPSON Perfection V600")
        let groups = DeviceMerge.group([twainEntry, wiaEntry], rankPatterns: DeviceMerge.windowsRanking)

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.key, "model:epson perfection v600")
        XCTAssertEqual(groups.first?.primary, wiaEntry)
        XCTAssertEqual(groups.first?.members, [twainEntry, wiaEntry])
    }

    func test_group_keyDoesNotDependOnListOrder() {
        let a = DeviceMerge.group([twain("EPSON Perfection V600 Photo"), wia("EPSON Perfection V600")],
                                  rankPatterns: DeviceMerge.windowsRanking)
        let b = DeviceMerge.group([wia("EPSON Perfection V600"), twain("EPSON Perfection V600 Photo")],
                                  rankPatterns: DeviceMerge.windowsRanking)
        XCTAssertEqual(a.first?.key, b.first?.key)
    }

    func test_group_keyIsTheHardwareIdWhenAMemberHasOne() {
        let wiaEntry = wia("HP LaserJet MFP M428fdw")
        let esclEntry = escl("HP LaserJet MFP M428fdw", uuid: "4509A320-00A0")
        let groups = DeviceMerge.group([esclEntry, wiaEntry], rankPatterns: DeviceMerge.windowsRanking)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.key, "id:4509a32000a0")
        XCTAssertEqual(groups.first?.primary, wiaEntry)
    }

    func test_group_ranksNetworkAboveTwain() {
        let twainEntry = twain("Brother MFC-L2710DW")
        let esclEntry = escl("Brother MFC-L2710DW", uuid: "uuid-1")
        let groups = DeviceMerge.group([twainEntry, esclEntry], rankPatterns: DeviceMerge.windowsRanking)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.primary, esclEntry)
    }

    func test_group_macRankingPrefersUsb() {
        let bonjour = ic("Brother MFC-L2710DW", "Network")
        let usb = ic("Brother MFC-L2710DW series", "USB")
        let shared = ic("Brother MFC-L2710DW", "Shared")
        let groups = DeviceMerge.group([shared, bonjour, usb], rankPatterns: DeviceMerge.macRanking)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.primary, usb)
        XCTAssertEqual(groups.first?.members.count, 3)
    }

    func test_group_unrankedConnectionsComeLastInListOrder() {
        let first = ScannerInfo(id: "x:1", name: "Canon LiDE 300", transport: "Bluetooth", backend: "other")
        let second = ScannerInfo(id: "y:1", name: "Canon LiDE 300", transport: "Infrared", backend: "else")
        let unranked = DeviceMerge.group([first, second], rankPatterns: DeviceMerge.windowsRanking)
        XCTAssertEqual(unranked.count, 1)
        XCTAssertEqual(unranked.first?.primary, first)
        let twainEntry = twain("Canon LiDE 300")
        let ranked = DeviceMerge.group([first, twainEntry], rankPatterns: DeviceMerge.windowsRanking)
        XCTAssertEqual(ranked.count, 1)
        XCTAssertEqual(ranked.first?.primary, twainEntry)
    }

    func test_group_overrideWins() {
        let wiaEntry = wia("EPSON Perfection V600")
        let twainEntry = twain("EPSON Perfection V600 Photo")
        let overrides = ["model:epson perfection v600": "TWAIN:usb"]
        let groups = DeviceMerge.group([wiaEntry, twainEntry], rankPatterns: DeviceMerge.windowsRanking,
                                       overrides: overrides)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.primary, twainEntry)
    }

    func test_group_overrideForAMissingConnectionFallsBackToRanking() {
        let wiaEntry = wia("EPSON Perfection V600")
        let twainEntry = twain("EPSON Perfection V600 Photo")
        let overrides = ["model:epson perfection v600": "escl:Network"]
        let groups = DeviceMerge.group([twainEntry, wiaEntry], rankPatterns: DeviceMerge.windowsRanking,
                                       overrides: overrides)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.primary, wiaEntry)
    }

    func test_group_twoIdenticalScannersStayTwoRowsWithUniqueKeys() {
        let wia1 = wia("Canon LiDE 300", id: "1")
        let wia2 = wia("Canon LiDE 300", id: "2")
        let twain1 = twain("Canon LiDE 300", id: "1")
        let twain2 = twain("Canon LiDE 300", id: "2")
        let groups = DeviceMerge.group([wia1, wia2, twain1, twain2], rankPatterns: DeviceMerge.windowsRanking)

        XCTAssertEqual(groups.map(\.key), ["model:canon lide 300", "model:canon lide 300#2"])
        XCTAssertEqual(groups.map(\.members), [[wia1, twain1], [wia2, twain2]])
    }

    func test_group_keepsDemoAndUnnamedDevicesApartInListOrder() {
        let wiaEntry = wia("Demo Scanner")
        let unnamed = twain("Scanner")
        let groups = DeviceMerge.group([demo, wiaEntry, unnamed], rankPatterns: DeviceMerge.windowsRanking)

        XCTAssertEqual(groups.map(\.key), ["device:mock:demo", "model:demo", "device:twain:Scanner#1"])
        XCTAssertTrue(groups.allSatisfy { $0.members.count == 1 })
        XCTAssertEqual(groups.first?.primary, demo)
    }

    func test_group_ofNothingIsEmpty() {
        XCTAssertTrue(DeviceMerge.group([], rankPatterns: DeviceMerge.windowsRanking).isEmpty)
    }

    // MARK: - Connections and diagnostics

    func test_connections_haveIdsAndLabels() {
        XCTAssertEqual(DeviceMerge.connectionID(wia("A")), "wia:WIA")
        XCTAssertEqual(DeviceMerge.connectionID(escl("A")), "escl:Network")
        XCTAssertEqual(DeviceMerge.connectionLabel(wia("A")), "WIA")
        XCTAssertEqual(DeviceMerge.connectionLabel(twain("A")), "TWAIN")
        XCTAssertEqual(DeviceMerge.connectionLabel(escl("A")), "Network (eSCL)")
        XCTAssertEqual(DeviceMerge.connectionLabel(demo), "Demo")
        XCTAssertEqual(DeviceMerge.connectionLabel(ic("A", "USB")), "USB")
    }

    func test_diagnosticsReport_listsRawNamesAndKeys() {
        let groups = DeviceMerge.group([twain("EPSON Perfection V600 Photo"),
                                        wia("EPSON Perfection V600", model: "EPSON EPSON Perfection V600")],
                                       rankPatterns: DeviceMerge.windowsRanking)
        XCTAssertEqual(
            DeviceMerge.diagnosticsReport(groups),
            "model:epson perfection v600 -> wia:WIA \"wia:EPSON Perfection V600#1\"\n"
                + "  twain:USB id=\"twain:EPSON Perfection V600 Photo#1\" name=\"EPSON Perfection V600 Photo\" model=\"\" hardwareId=\"\" key=\"epson perfection v600 photo\"\n"
                + "  wia:WIA id=\"wia:EPSON Perfection V600#1\" name=\"EPSON Perfection V600\" model=\"EPSON EPSON Perfection V600\" hardwareId=\"\" key=\"epson perfection v600\"\n")
    }
}
