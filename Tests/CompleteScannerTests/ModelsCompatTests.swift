import XCTest
import Foundation
@testable import CompleteScannerKit

// MARK: - Helpers

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSONDecoder().decode(type, from: Data(json.utf8))
}

/// Encoded exactly the way the stores write files.
private func encode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(value)
}

private func jsonObject(_ data: Data) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private let sampleID = UUID(uuidString: "3F2504E0-4F89-41D3-9A0C-0305E82C3301")!

/// Every field set to a non-default value. Values are exactly representable in binary
/// so equality after a JSON round trip does not depend on decimal parsing.
private func nonDefaultSettings() -> ScanSettings {
    var settings = ScanSettings()
    settings.intent = .photo
    settings.source = .documentFeeder
    settings.resolution = 600
    settings.colorMode = .grayscale
    settings.format = .tiff
    settings.jpegQuality = 0.625
    settings.destinationPath = "/Users/someone/Scans"
    settings.namingTemplate = "Receipt {date}"
    settings.photoAutoSplit = false
    settings.photoAutoDeskew = false
    settings.photoMinSideInches = 2.5
    settings.photoCropInsetPixels = 4
    settings.documentMultiPage = false
    settings.pdfSearchable = false
    settings.ocrLanguages = ["de-DE", "en-US"]
    settings.adjustments.autoEnhance = true
    settings.adjustments.brightness = 0.25
    settings.adjustments.contrast = 1.5
    settings.adjustments.saturation = 0.75
    settings.adjustments.sharpness = -0.5
    settings.adjustments.descreen = true
    settings.adjustments.restoreFadedColors = true
    settings.adjustments.blackWhiteThreshold = 0.375
    settings.output.pdfSize = .compact
    settings.output.afterSave = .share
    settings.output.alsoSaveText = true
    settings.output.archival = true
    settings.output.protect = true
    settings.output.wordPageImages = false
    settings.duplex = .manual
    settings.backBinding = .shortEdge
    settings.paperSize = .a4
    settings.document.removeBlankPages = true
    settings.document.blankSensitivity = .high
    settings.document.autoCrop = true
    settings.document.autoStraighten = true
    settings.document.splitMode = .sheetCount
    settings.document.splitSheetCount = 3
    settings.document.autoRotate = true
    settings.document.splitFacingPages = true
    settings.document.softenSpineShadow = true
    settings.document.barcodeStartsDocument = true
    settings.document.splitBarcodePrefix = "DOC"
    settings.taskOptions.idCardPaper = .letter
    settings.taskOptions.idCardSaveSidesAsImages = true
    settings.taskOptions.copyCount = 3
    settings.taskOptions.copyFitToPage = true
    settings.taskOptions.copyPrinterName = "Office printer"
    settings.taskOptions.copyAlsoSavePdf = true
    settings.taskOptions.receiptNameByDate = false
    settings.taskOptions.receiptCombine = true
    settings.taskOptions.bookRightToLeft = true
    settings.taskOptions.bookRotationQuarterTurns = 1
    settings.taskOptions.cameraFrontsFirst = true
    settings.taskOptions.cameraSpreads = true
    return settings
}

/// `nonDefaultSettings()` as a presets file written by the synthesized Codable
/// implementation (pretty-printed, sorted keys, every property present), before the PDF size, the
/// after-save action and two-sided scanning existed: it has no "output", "duplex", "backBinding"
/// or "paperSize".
private let presetsJSONBeforePDFSize = """
[
  {
    "id" : "3F2504E0-4F89-41D3-9A0C-0305E82C3301",
    "name" : "Receipts",
    "settings" : {
      "adjustments" : {
        "autoEnhance" : true,
        "blackWhiteThreshold" : 0.375,
        "brightness" : 0.25,
        "contrast" : 1.5,
        "descreen" : true,
        "restoreFadedColors" : true,
        "saturation" : 0.75,
        "sharpness" : -0.5
      },
      "colorMode" : "grayscale",
      "destinationPath" : "/Users/someone/Scans",
      "documentMultiPage" : false,
      "format" : "tiff",
      "intent" : "photo",
      "jpegQuality" : 0.625,
      "namingTemplate" : "Receipt {date}",
      "ocrLanguages" : [
        "de-DE",
        "en-US"
      ],
      "pdfSearchable" : false,
      "photoAutoDeskew" : false,
      "photoAutoSplit" : false,
      "photoCropInsetPixels" : 4,
      "photoMinSideInches" : 2.5,
      "resolution" : 600,
      "source" : "documentFeeder"
    }
  }
]
"""

/// `nonDefaultSettings()` as this version writes it: `presetsJSONBeforePDFSize` with the
/// "output" object, the sides, the paper size, the "document" object and the "taskOptions" object
/// in their sorted places.
private let currentFormatPresetsJSON = presetsJSONBeforePDFSize
    .replacingOccurrences(
        of: "\"documentMultiPage\" : false",
        with: "\"document\" : {\n        \"autoCrop\" : true,\n        \"autoRotate\" : true,\n        \"autoStraighten\" : true,\n"
            + "        \"barcodeStartsDocument\" : true,\n"
            + "        \"blankSensitivity\" : \"high\",\n        \"removeBlankPages\" : true,\n"
            + "        \"softenSpineShadow\" : true,\n        \"splitBarcodePrefix\" : \"DOC\",\n"
            + "        \"splitFacingPages\" : true,\n"
            + "        \"splitMode\" : \"sheetCount\",\n        \"splitSheetCount\" : 3\n      },\n"
            + "      \"documentMultiPage\" : false")
    .replacingOccurrences(
        of: "\"pdfSearchable\" : false",
        with: "\"output\" : {\n        \"afterSave\" : \"share\",\n        \"alsoSaveText\" : true,\n        \"archival\" : true,\n"
            + "        \"pdfSize\" : \"compact\",\n        \"protect\" : true,\n        \"wordPageImages\" : false\n      },\n"
            + "      \"paperSize\" : \"a4\",\n      \"pdfSearchable\" : false")
    .replacingOccurrences(of: "\"colorMode\" : \"grayscale\"",
                          with: "\"backBinding\" : \"shortEdge\",\n      \"colorMode\" : \"grayscale\"")
    .replacingOccurrences(of: "\"format\" : \"tiff\"",
                          with: "\"duplex\" : \"manual\",\n      \"format\" : \"tiff\"")
    .replacingOccurrences(of: "\"source\" : \"documentFeeder\"",
                          with: "\"source\" : \"documentFeeder\",\n      \"taskOptions\" : {\n"
                              + "        \"bookRightToLeft\" : true,\n        \"bookRotationQuarterTurns\" : 1,\n"
                              + "        \"cameraFrontsFirst\" : true,\n        \"cameraSpreads\" : true,\n"
                              + "        \"copyAlsoSavePdf\" : true,\n        \"copyCount\" : 3,\n        \"copyFitToPage\" : true,\n"
                              + "        \"copyPrinterName\" : \"Office printer\",\n        \"idCardPaper\" : \"letter\",\n"
                              + "        \"idCardSaveSidesAsImages\" : true,\n        \"receiptCombine\" : true,\n"
                              + "        \"receiptNameByDate\" : false\n      }")

// MARK: - Decoding compatibility

final class ModelsCompatTests: XCTestCase {

    func test_emptyObject_decodesToDefaults() throws {
        XCTAssertEqual(try decode(ScanSettings.self, "{}"), ScanSettings())
        XCTAssertEqual(try decode(AdjustmentSettings.self, "{}"), AdjustmentSettings())
    }

    func test_missingKeys_keepPresentValuesAndDefaultTheRest() throws {
        let settings = try decode(ScanSettings.self, """
            {"resolution": 600, "colorMode": "grayscale", "adjustments": {"contrast": 1.5}}
            """)
        var expected = ScanSettings()
        expected.resolution = 600
        expected.colorMode = .grayscale
        expected.adjustments.contrast = 1.5
        XCTAssertEqual(settings, expected)
    }

    func test_presetMissingEverything_getsNameAndDefaultSettings() throws {
        let preset = try decode(Preset.self, "{}")
        XCTAssertEqual(preset.name, Preset.fallbackName)
        XCTAssertEqual(preset.settings, ScanSettings())
    }

    func test_presetMissingID_getsFreshIDAndKeepsTheRest() throws {
        let preset = try decode(Preset.self, #"{"name": "Mine", "settings": {"resolution": 150}}"#)
        XCTAssertEqual(preset.name, "Mine")
        XCTAssertEqual(preset.settings.resolution, 150)
        XCTAssertNotEqual(preset.id, try decode(Preset.self, #"{"name": "Mine"}"#).id)
    }

    func test_unknownEnumValues_fallBackToDefault_restOfPresetIntact() throws {
        let json = currentFormatPresetsJSON
            .replacingOccurrences(of: "\"grayscale\"", with: "\"hyperspectral\"")
            .replacingOccurrences(of: "\"tiff\"", with: "\"webp\"")
            .replacingOccurrences(of: "\"photo\"", with: "\"receipt\"")
            .replacingOccurrences(of: "\"documentFeeder\"", with: "\"transparencyUnit\"")
        let presets = try decode([Preset].self, json)

        XCTAssertEqual(presets.count, 1)
        var expected = nonDefaultSettings()
        expected.colorMode = ScanSettings().colorMode
        expected.format = ScanSettings().format
        expected.intent = ScanSettings().intent
        expected.source = ScanSettings().source
        XCTAssertEqual(presets[0].id, sampleID)
        XCTAssertEqual(presets[0].name, "Receipts")
        XCTAssertEqual(presets[0].settings, expected)
    }

    func test_numericOrMiscasedEnumValues_fallBackToDefault() throws {
        // Enums decode only their exact raw value: no numbers, no other casing.
        let settings = try decode(ScanSettings.self, """
            {"colorMode": 1, "format": "Tiff", "intent": "PHOTO", "source": "documentFeeder"}
            """)
        var expected = ScanSettings()
        expected.source = .documentFeeder
        XCTAssertEqual(settings, expected)
    }

    func test_wrongTypedField_fallsBackToDefault_restIntact() throws {
        let settings = try decode(ScanSettings.self, """
            {"resolution": "high", "pdfSearchable": false, "ocrLanguages": "en-US"}
            """)
        var expected = ScanSettings()
        expected.pdfSearchable = false
        XCTAssertEqual(settings, expected)
    }

    func test_nullListElement_resetsThatField() throws {
        let settings = try decode(ScanSettings.self, """
            {"resolution": 150, "ocrLanguages": ["de-DE", null]}
            """)
        var expected = ScanSettings()
        expected.resolution = 150
        XCTAssertEqual(settings, expected)
    }

    func test_corruptNestedObject_resetsOnlyThatField() throws {
        let settings = try decode(ScanSettings.self, """
            {"resolution": 1200, "adjustments": "not an object"}
            """)
        var expected = ScanSettings()
        expected.resolution = 1200
        XCTAssertEqual(settings, expected)
    }

    func test_corruptNestedField_resetsOnlyThatNestedField() throws {
        let settings = try decode(ScanSettings.self, """
            {"adjustments": {"brightness": "bright", "contrast": 2.5, "descreen": true}}
            """)
        var expected = ScanSettings()
        expected.adjustments.contrast = 2.5
        expected.adjustments.descreen = true
        XCTAssertEqual(settings, expected)
    }

    func test_nullValues_fallBackToDefault() throws {
        let preset = try decode(Preset.self, #"{"name": "Nulls", "settings": null}"#)
        XCTAssertEqual(preset.name, "Nulls")
        XCTAssertEqual(preset.settings, ScanSettings())

        let settings = try decode(ScanSettings.self, #"{"resolution": null, "adjustments": null}"#)
        XCTAssertEqual(settings, ScanSettings())

        let named = try decode(Preset.self, #"{"id": null, "name": null}"#)
        XCTAssertEqual(named.name, Preset.fallbackName)
    }

    func test_keysFromNewerVersions_areIgnored() throws {
        let settings = try decode(ScanSettings.self, """
            {"resolution": 200, "staple": "corner", "hologram": {"depth": 3}}
            """)
        var expected = ScanSettings()
        expected.resolution = 200
        XCTAssertEqual(settings, expected)
    }

    func test_currentFormatJSON_decodesIdentically() throws {
        let presets = try decode([Preset].self, currentFormatPresetsJSON)
        XCTAssertEqual(presets, [Preset(id: sampleID, name: "Receipts", settings: nonDefaultSettings())])
    }

    func test_roundTrip_preservesEveryField() throws {
        var bookmarked = ScanSettings()
        bookmarked.destinationBookmark = Data([0, 1, 2, 250, 251, 255])
        let presets = [
            Preset(id: sampleID, name: "Receipts", settings: nonDefaultSettings()),
            Preset(name: "Defaults", settings: ScanSettings()),
            Preset(name: "iCloud Drive", settings: bookmarked),
        ]
        let decoded = try JSONDecoder().decode([Preset].self, from: encode(presets))
        XCTAssertEqual(decoded, presets)
    }

    func test_encoding_writesTheSameKeysAsBefore() throws {
        let settings = try jsonObject(encode(nonDefaultSettings()))
        XCTAssertEqual(Set(settings.keys), [
            "intent", "source", "resolution", "colorMode", "format", "jpegQuality",
            "destinationPath", "namingTemplate", "photoAutoSplit", "photoAutoDeskew",
            "photoMinSideInches", "photoCropInsetPixels", "documentMultiPage",
            "pdfSearchable", "ocrLanguages", "adjustments", "output", "duplex", "backBinding", "paperSize",
            "document", "taskOptions",
        ])
        let adjustments = try XCTUnwrap(settings["adjustments"] as? [String: Any])
        XCTAssertEqual(Set(adjustments.keys), [
            "autoEnhance", "brightness", "contrast", "saturation", "sharpness",
            "descreen", "restoreFadedColors", "blackWhiteThreshold",
        ])
        XCTAssertEqual(settings["colorMode"] as? String, "grayscale")
        XCTAssertEqual(settings["source"] as? String, "documentFeeder")

        let preset = try jsonObject(encode(Preset(id: sampleID, name: "P", settings: ScanSettings())))
        XCTAssertEqual(Set(preset.keys), ["id", "name", "settings"])
        XCTAssertEqual(preset["id"] as? String, sampleID.uuidString)
    }

    func test_encoding_matchesCurrentFormatFile() throws {
        let written = try JSONSerialization.jsonObject(
            with: encode([Preset(id: sampleID, name: "Receipts", settings: nonDefaultSettings())]))
        let expected = try JSONSerialization.jsonObject(with: Data(currentFormatPresetsJSON.utf8))
        XCTAssertEqual(written as? NSArray, expected as? NSArray)
    }

    // MARK: Task (CONTRACTS.md, rule 6: the task is stored as text)

    func test_oldSettingsWithoutTask_loadWithNoTask() throws {
        let presets = try decode([Preset].self, currentFormatPresetsJSON)
        XCTAssertNil(presets[0].settings.taskId)
        XCTAssertNil(presets[0].settings.task)
        XCTAssertNil(try decode(ScanSettings.self, "{}").task)
    }

    func test_unknownTask_loadsAsNoTask_andIsWrittenBackUnchanged() throws {
        let settings = try decode(ScanSettings.self, #"{"resolution": 200, "taskId": "whiteboard"}"#)
        XCTAssertEqual(settings.taskId, "whiteboard")
        XCTAssertNil(settings.task)
        XCTAssertEqual(settings.resolution, 200)
        let written = try jsonObject(encode(settings))
        XCTAssertEqual(written["taskId"] as? String, "whiteboard")
    }

    func test_knownTask_roundTrips() throws {
        var settings = nonDefaultSettings()
        settings.taskId = "photoRestore"
        let back = try JSONDecoder().decode(ScanSettings.self, from: encode(settings))
        XCTAssertEqual(back.task, .photoRestore)
        XCTAssertEqual(back, settings)
    }

    func test_wrongTypedOrNullTask_isNoTask_restIntact() throws {
        let number = try decode(ScanSettings.self, #"{"taskId": 5, "resolution": 150}"#)
        XCTAssertNil(number.taskId)
        XCTAssertEqual(number.resolution, 150)
        let object = try decode(ScanSettings.self, #"{"taskId": {"id": "photos"}, "pdfSearchable": false}"#)
        XCTAssertNil(object.taskId)
        XCTAssertFalse(object.pdfSearchable)
        XCTAssertNil(try decode(ScanSettings.self, #"{"taskId": null}"#).taskId)
    }

    func test_noTask_isLeftOutOfTheFile() throws {
        XCTAssertNil(try jsonObject(encode(ScanSettings()))["taskId"])
        let data = try encode([Preset(id: sampleID, name: "P", settings: nonDefaultSettings())])
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("taskId"))
    }

    func test_task_isWrittenWithTheEarlierKeys() throws {
        var settings = nonDefaultSettings()
        settings.taskId = "document"
        let written = try jsonObject(encode(settings))
        XCTAssertEqual(Set(written.keys), [
            "intent", "source", "resolution", "colorMode", "format", "jpegQuality",
            "destinationPath", "namingTemplate", "photoAutoSplit", "photoAutoDeskew",
            "photoMinSideInches", "photoCropInsetPixels", "documentMultiPage",
            "pdfSearchable", "ocrLanguages", "adjustments", "taskId", "output", "duplex", "backBinding", "paperSize",
            "document", "taskOptions",
        ])
        XCTAssertEqual(written["taskId"] as? String, "document")
    }

    // MARK: Save folder (CONTRACTS.md, rule 6; the iPhone's bookmark and container)

    func test_noBookmark_isLeftOutOfTheFile() throws {
        XCTAssertNil(try jsonObject(encode(ScanSettings()))["destinationBookmark"])
        XCTAssertNil(try decode([Preset].self, currentFormatPresetsJSON)[0].settings.destinationBookmark)
    }

    func test_bookmark_isWrittenAsBase64_withTheEarlierKeys() throws {
        var settings = nonDefaultSettings()
        settings.destinationBookmark = Data([0, 1, 2, 250, 251, 255])
        let written = try jsonObject(encode(settings))
        XCTAssertEqual(Set(written.keys), [
            "intent", "source", "resolution", "colorMode", "format", "jpegQuality",
            "destinationPath", "destinationBookmark", "namingTemplate", "photoAutoSplit", "photoAutoDeskew",
            "photoMinSideInches", "photoCropInsetPixels", "documentMultiPage",
            "pdfSearchable", "ocrLanguages", "adjustments", "output", "duplex", "backBinding", "paperSize",
            "document", "taskOptions",
        ])
        XCTAssertEqual(written["destinationBookmark"] as? String, "AAEC+vv/")
        XCTAssertEqual(try JSONDecoder().decode(ScanSettings.self, from: encode(settings)), settings)
    }

    func test_wrongTypedBookmark_isNone_restIntact() throws {
        let number = try decode(ScanSettings.self, #"{"destinationBookmark": 5, "resolution": 150}"#)
        XCTAssertNil(number.destinationBookmark)
        XCTAssertEqual(number.resolution, 150)
        XCTAssertNil(try decode(ScanSettings.self, #"{"destinationBookmark": "not base64!"}"#).destinationBookmark)
        XCTAssertNil(try decode(ScanSettings.self, #"{"destinationBookmark": null}"#).destinationBookmark)
    }

    func test_savePath_inAnEarlierInstallsDocuments_movesIntoThisOnes() {
        let documents = URL(fileURLWithPath: "/var/mobile/Containers/Data/Application/0B3C9D1E-5F0A-4C2B-9E7D-1A2B3C4D5E6F/Documents",
                            isDirectory: true)
        let earlier = "/private/var/mobile/Containers/Data/Application/7A1F2E3D-4C5B-4A69-8778-96A5B4C3D2E1/Documents"
        XCTAssertEqual(ScanSettings.rebasedDestinationPath(earlier + "/CompleteScanner", documents: documents),
                       documents.path + "/CompleteScanner")
        XCTAssertEqual(ScanSettings.rebasedDestinationPath(earlier + "/CompleteScanner/Receipts", documents: documents),
                       documents.path + "/CompleteScanner/Receipts")
        XCTAssertEqual(ScanSettings.rebasedDestinationPath(earlier, documents: documents), documents.path)
        XCTAssertEqual(ScanSettings.rebasedDestinationPath(documents.path + "/CompleteScanner", documents: documents),
                       documents.path + "/CompleteScanner")
        // The Mac keeps every path.
        XCTAssertEqual(ScanSettings.rebasedDestinationPath(earlier + "/CompleteScanner", documents: nil),
                       earlier + "/CompleteScanner")
    }

    func test_savePath_outsideAnAppsDocuments_isKept() {
        let documents = URL(fileURLWithPath: "/var/mobile/Containers/Data/Application/0B3C9D1E-5F0A-4C2B-9E7D-1A2B3C4D5E6F/Documents",
                            isDirectory: true)
        let kept = [
            "/private/var/mobile/Library/Mobile Documents/com~apple~CloudDocs/Scans",
            "/Users/someone/Documents/CompleteScanner",
            "/var/mobile/Containers/Data/Application/7A1F2E3D-4C5B-4A69-8778-96A5B4C3D2E1/tmp/Documents",
            "/var/mobile/Containers/Data/Application/not-a-uuid/Documents/CompleteScanner",
        ]
        for path in kept {
            XCTAssertEqual(ScanSettings.rebasedDestinationPath(path, documents: documents), path)
        }
    }

    // MARK: PDF size (CONTRACTS.md, rule 6; standard is the default for everyone)

    func test_pdfSize_standardIsTheFirstCaseAndTheDefault() {
        XCTAssertEqual(PDFSizePreset.allCases.map(\.rawValue), ["standard", "best", "compact", "smallest"])
        XCTAssertEqual(ScanSettings().output.pdfSize, .standard)
        XCTAssertEqual(OutputOptions().pdfSize, .standard)
    }

    func test_settingsWithoutPDFSize_getStandard_restIntact() throws {
        let presets = try decode([Preset].self, presetsJSONBeforePDFSize)
        var expected = nonDefaultSettings()
        expected.output.pdfSize = .standard
        expected.output.afterSave = AfterSaveAction.none
        expected.output.alsoSaveText = false
        expected.output.archival = false
        expected.output.protect = false
        expected.output.wordPageImages = true
        expected.duplex = .off
        expected.backBinding = .longEdge
        expected.paperSize = .auto
        expected.document = DocumentOptions()
        expected.taskOptions = TaskOptions()
        XCTAssertEqual(presets[0].settings, expected)
        XCTAssertEqual(try decode(ScanSettings.self, "{}").output.pdfSize, .standard)
        XCTAssertEqual(try decode(ScanSettings.self, #"{"output": {}}"#).output.pdfSize, .standard)
    }

    func test_unknownOrCorruptPDFSize_fallsBackToStandard_restIntact() throws {
        for output in [#"{"pdfSize": "tiny"}"#, #"{"pdfSize": "Compact"}"#, #"{"pdfSize": 2}"#,
                       #"{"pdfSize": null}"#, #""compact""#, "null", "[]"] {
            let settings = try decode(ScanSettings.self,
                                      #"{"resolution": 150, "output": "# + output + #", "pdfSearchable": false}"#)
            XCTAssertEqual(settings.output.pdfSize, .standard, output)
            XCTAssertEqual(settings.resolution, 150, output)
            XCTAssertFalse(settings.pdfSearchable, output)
        }
        let nested = try decode(ScanSettings.self, #"{"output": {"pdfSize": "smallest", "afterSave": "share"}}"#)
        XCTAssertEqual(nested.output.pdfSize, .smallest)
        XCTAssertEqual(nested.output.afterSave, .share)
    }

    func test_pdfSize_isWrittenUnderOutput_andRoundTrips() throws {
        for size in PDFSizePreset.allCases {
            var settings = ScanSettings()
            settings.output.pdfSize = size
            let data = try encode(settings)
            let output = try XCTUnwrap(try jsonObject(data)["output"] as? [String: Any])
            XCTAssertEqual(Set(output.keys), ["pdfSize", "afterSave", "alsoSaveText", "archival", "protect", "wordPageImages"])
            XCTAssertEqual(output["pdfSize"] as? String, size.rawValue)
            XCTAssertEqual(try JSONDecoder().decode(ScanSettings.self, from: data).output.pdfSize, size)
        }
    }

    func test_copy_carriesTheOutputOptions() {
        var settings = ScanSettings()
        settings.output.pdfSize = .smallest
        var copy = settings
        XCTAssertEqual(copy.output.pdfSize, .smallest)
        copy.output.pdfSize = .best
        XCTAssertEqual(settings.output.pdfSize, .smallest)
    }

    // MARK: Text output (CONTRACTS.md, rule 6)

    func test_formats_newCasesComeLast_withTheirStoredNames() throws {
        XCTAssertEqual(OutputFormat.allCases.map(\.rawValue), ["pdf", "jpeg", "png", "tiff", "text", "word"])
        XCTAssertEqual(try decode(ScanSettings.self, #"{"format": "word"}"#).format, .word)
        XCTAssertEqual(try decode(ScanSettings.self, #"{"format": "text"}"#).format, .text)
        // A format of a newer version is read as PDF.
        XCTAssertEqual(try decode(ScanSettings.self, #"{"format": "markdown", "resolution": 150}"#).format, .pdf)
    }

    func test_alsoSaveText_offByDefault_andInFilesWithoutIt() throws {
        XCTAssertFalse(ScanSettings().output.alsoSaveText)
        XCTAssertFalse(try decode([Preset].self, presetsJSONBeforePDFSize)[0].settings.output.alsoSaveText)
        XCTAssertFalse(try decode(ScanSettings.self, #"{"output": {"pdfSize": "compact", "afterSave": "share"}}"#)
            .output.alsoSaveText)
        for value in [#""yes""#, "1", "null", "{}"] {
            let settings = try decode(ScanSettings.self,
                                      #"{"output": {"pdfSize": "best", "alsoSaveText": "# + value + #"}, "resolution": 150}"#)
            XCTAssertFalse(settings.output.alsoSaveText, value)
            XCTAssertEqual(settings.output.pdfSize, .best, value)
            XCTAssertEqual(settings.resolution, 150, value)
        }
        XCTAssertTrue(try decode(ScanSettings.self, #"{"output": {"alsoSaveText": true}}"#).output.alsoSaveText)
    }

    func test_copy_carriesAlsoSaveText() {
        var settings = ScanSettings()
        settings.output.alsoSaveText = true
        var copy = settings
        XCTAssertTrue(copy.output.alsoSaveText)
        copy.output.alsoSaveText = false
        XCTAssertTrue(settings.output.alsoSaveText)
        XCTAssertNotEqual(settings.output, copy.output)
    }

    // MARK: Archival PDF (CONTRACTS.md, rule 6)

    func test_archival_offByDefault_andInFilesWithoutIt() throws {
        XCTAssertFalse(ScanSettings().output.archival)
        XCTAssertFalse(try decode([Preset].self, presetsJSONBeforePDFSize)[0].settings.output.archival)
        XCTAssertFalse(try decode(ScanSettings.self, #"{"output": {"pdfSize": "compact", "alsoSaveText": true}}"#)
            .output.archival)
        for value in [#""yes""#, "1", "null", "{}", "[]"] {
            let settings = try decode(ScanSettings.self,
                                      #"{"output": {"pdfSize": "best", "archival": "# + value + #", "alsoSaveText": true}, "resolution": 150}"#)
            XCTAssertFalse(settings.output.archival, value)
            XCTAssertEqual(settings.output.pdfSize, .best, value)
            XCTAssertTrue(settings.output.alsoSaveText, value)
            XCTAssertEqual(settings.resolution, 150, value)
        }
        XCTAssertTrue(try decode(ScanSettings.self, #"{"output": {"archival": true}}"#).output.archival)
    }

    func test_copy_carriesArchival() {
        var settings = ScanSettings()
        settings.output.archival = true
        var copy = settings
        XCTAssertTrue(copy.output.archival)
        copy.output.archival = false
        XCTAssertTrue(settings.output.archival)
        XCTAssertNotEqual(settings.output, copy.output)
    }

    /// Twin of `ArchiveTaskSettings_RoundTrip_AsTheMacReadsThem`: what the Archive document task
    /// writes reads as that task with the archival flag on both platforms, and comes back unchanged.
    func test_archiveTaskSettings_roundTrip() throws {
        let json = #"{"resolution": 300, "taskId": "archive", "output": {"pdfSize": "best", "archival": true}}"#
        let settings = try decode(ScanSettings.self, json)
        XCTAssertEqual(settings.taskId, "archive")
        XCTAssertEqual(settings.task, .archive)
        XCTAssertTrue(settings.output.archival)
        XCTAssertEqual(settings.output.pdfSize, .best)
        let written = try jsonObject(encode(settings))
        XCTAssertEqual(written["taskId"] as? String, "archive")
        let output = try XCTUnwrap(written["output"] as? [String: Any])
        XCTAssertEqual(output["archival"] as? Bool, true)
    }

    // MARK: Page pictures in Word documents (CONTRACTS.md, rule 6)

    /// Twin of `WordPageImages_OnByDefault_AndInFilesWithoutIt`.
    func test_wordPageImages_onByDefault_andInFilesWithoutIt() throws {
        XCTAssertTrue(ScanSettings().output.wordPageImages)
        XCTAssertTrue(try decode([Preset].self, presetsJSONBeforePDFSize)[0].settings.output.wordPageImages)
        XCTAssertTrue(try decode(ScanSettings.self, #"{"output": {"pdfSize": "compact", "alsoSaveText": true}}"#)
            .output.wordPageImages)
        for value in [#""no""#, "0", "null", "{}", "[]"] {
            let settings = try decode(ScanSettings.self,
                                      #"{"output": {"pdfSize": "best", "wordPageImages": "# + value + #", "alsoSaveText": true}, "resolution": 150}"#)
            XCTAssertTrue(settings.output.wordPageImages, value)
            XCTAssertEqual(settings.output.pdfSize, .best, value)
            XCTAssertTrue(settings.output.alsoSaveText, value)
            XCTAssertEqual(settings.resolution, 150, value)
        }
        XCTAssertFalse(try decode(ScanSettings.self, #"{"output": {"wordPageImages": false}}"#).output.wordPageImages)
    }

    /// Twin of `Clone_CopiesWordPageImages`.
    func test_copy_carriesWordPageImages() {
        var settings = ScanSettings()
        settings.output.wordPageImages = false
        var copy = settings
        XCTAssertFalse(copy.output.wordPageImages)
        copy.output.wordPageImages = true
        XCTAssertFalse(settings.output.wordPageImages)
        XCTAssertNotEqual(settings.output, copy.output)
    }

    // MARK: Password-protected PDFs (CONTRACTS.md, rule 6)

    /// Twin of `Protect_OffByDefault_AndInFilesWithoutIt`.
    func test_protect_offByDefault_andInFilesWithoutIt() throws {
        XCTAssertFalse(ScanSettings().output.protect)
        XCTAssertFalse(try decode([Preset].self, presetsJSONBeforePDFSize)[0].settings.output.protect)
        XCTAssertFalse(try decode(ScanSettings.self, #"{"output": {"pdfSize": "compact", "archival": true}}"#)
            .output.protect)
        for value in [#""yes""#, "1", "null", "{}", "[]"] {
            let settings = try decode(ScanSettings.self,
                                      #"{"output": {"pdfSize": "best", "protect": "# + value + #", "alsoSaveText": true}, "resolution": 150}"#)
            XCTAssertFalse(settings.output.protect, value)
            XCTAssertEqual(settings.output.pdfSize, .best, value)
            XCTAssertTrue(settings.output.alsoSaveText, value)
            XCTAssertEqual(settings.resolution, 150, value)
        }
        XCTAssertTrue(try decode(ScanSettings.self, #"{"output": {"protect": true}}"#).output.protect)
    }

    /// Twin of `Clone_CopiesProtect`.
    func test_copy_carriesProtect() {
        var settings = ScanSettings()
        settings.output.protect = true
        var copy = settings
        XCTAssertTrue(copy.output.protect)
        copy.output.protect = false
        XCTAssertTrue(settings.output.protect)
        XCTAssertNotEqual(settings.output, copy.output)
    }

    /// Twin of `ProtectSettings_KeepOnlyTheSwitch`: only "protect" is written; a settings file never
    /// holds a password, whatever it was read from.
    func test_protectSettings_keepOnlyTheSwitch() throws {
        let json = #"{"output": {"pdfSize": "standard", "protect": true, "password": "Şifre 2026"}}"#
        let settings = try decode(ScanSettings.self, json)
        XCTAssertTrue(settings.output.protect)
        let data = try encode(settings)
        let written = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(written.lowercased().contains("password"))
        XCTAssertFalse(written.contains("Şifre"))
        let output = try XCTUnwrap(try jsonObject(data)["output"] as? [String: Any])
        XCTAssertEqual(output["protect"] as? Bool, true)
    }

    // MARK: Two-sided scanning and paper size (CONTRACTS.md, rule 6)

    func test_sides_firstCasesAreTheDefaults() {
        XCTAssertEqual(DuplexMode.allCases.map(\.rawValue), ["off", "both", "manual"])
        XCTAssertEqual(DuplexBinding.allCases.map(\.rawValue), ["longEdge", "shortEdge"])
        XCTAssertEqual(PaperSize.allCases.map(\.rawValue),
                       ["auto", "letter", "legal", "executive", "a4", "a5", "a6", "b5Jis", "idCard"])
        let settings = ScanSettings()
        XCTAssertEqual(settings.duplex, .off)
        XCTAssertEqual(settings.backBinding, .longEdge)
        XCTAssertEqual(settings.paperSize, .auto)
    }

    func test_settingsWithoutSides_scanOneSideOnTheWholeArea() throws {
        let settings = try decode(ScanSettings.self, #"{"resolution": 150, "source": "documentFeeder"}"#)
        XCTAssertEqual(settings.duplex, .off)
        XCTAssertEqual(settings.backBinding, .longEdge)
        XCTAssertEqual(settings.paperSize, .auto)
        XCTAssertEqual(settings.resolution, 150)
    }

    func test_unknownOrCorruptSides_fallBackToTheDefaults_restIntact() throws {
        for sides in [#""duplex": "triple", "backBinding": "spiral", "paperSize": "tabloid""#,
                      #""duplex": "Both", "backBinding": "LongEdge", "paperSize": "A4""#,
                      #""duplex": 1, "backBinding": true, "paperSize": {"width": 8}"#,
                      #""duplex": null, "backBinding": null, "paperSize": null"#] {
            let settings = try decode(ScanSettings.self, #"{"resolution": 150, "# + sides + #", "pdfSearchable": false}"#)
            XCTAssertEqual(settings.duplex, .off, sides)
            XCTAssertEqual(settings.backBinding, .longEdge, sides)
            XCTAssertEqual(settings.paperSize, .auto, sides)
            XCTAssertEqual(settings.resolution, 150, sides)
            XCTAssertFalse(settings.pdfSearchable, sides)
        }
        let known = try decode(ScanSettings.self, #"{"duplex": "both", "backBinding": "shortEdge", "paperSize": "b5Jis"}"#)
        XCTAssertEqual(known.duplex, .both)
        XCTAssertEqual(known.backBinding, .shortEdge)
        XCTAssertEqual(known.paperSize, .b5Jis)
    }

    func test_sides_roundTrip() throws {
        for duplex in DuplexMode.allCases {
            for paper in PaperSize.allCases {
                var settings = ScanSettings()
                settings.duplex = duplex
                settings.backBinding = .shortEdge
                settings.paperSize = paper
                let back = try JSONDecoder().decode(ScanSettings.self, from: encode(settings))
                XCTAssertEqual(back.duplex, duplex)
                XCTAssertEqual(back.backBinding, .shortEdge)
                XCTAssertEqual(back.paperSize, paper)
            }
        }
        let copy = nonDefaultSettings()
        XCTAssertEqual(copy.duplex, .manual)
        XCTAssertEqual(copy.backBinding, .shortEdge)
        XCTAssertEqual(copy.paperSize, .a4)
    }

    // MARK: Blank pages (CONTRACTS.md, rule 6)

    func test_blankSensitivity_mediumIsTheFirstCaseAndTheDefault() {
        XCTAssertEqual(BlankSensitivity.allCases.map(\.rawValue), ["medium", "low", "high"])
        let document = ScanSettings().document
        XCTAssertFalse(document.removeBlankPages)
        XCTAssertEqual(document.blankSensitivity, .medium)
        XCTAssertEqual(BlankSensitivity.displayOrder, [.low, .medium, .high])
    }

    func test_settingsWithoutDocument_keepEveryPage_restIntact() throws {
        let presets = try decode([Preset].self, presetsJSONBeforePDFSize)
        XCTAssertFalse(presets[0].settings.document.removeBlankPages)
        XCTAssertEqual(presets[0].settings.document.blankSensitivity, .medium)
        XCTAssertFalse(try decode(ScanSettings.self, #"{"document": {}}"#).document.removeBlankPages)
        XCTAssertEqual(presets[0].settings.resolution, 600)
        XCTAssertEqual(presets[0].settings.output.pdfSize, .standard)
    }

    func test_unknownOrCorruptDocument_fallsBackToTheDefaults_restIntact() throws {
        for document in [#""document": {"removeBlankPages": true, "blankSensitivity": "extreme"}"#,
                         #""document": {"removeBlankPages": true, "blankSensitivity": "High"}"#,
                         #""document": {"removeBlankPages": true, "blankSensitivity": 2}"#,
                         #""document": {"removeBlankPages": true, "blankSensitivity": null}"#] {
            let settings = try decode(ScanSettings.self, #"{"resolution": 150, "# + document + #", "pdfSearchable": false}"#)
            XCTAssertTrue(settings.document.removeBlankPages, document)
            XCTAssertEqual(settings.document.blankSensitivity, .medium, document)
            XCTAssertEqual(settings.resolution, 150, document)
            XCTAssertFalse(settings.pdfSearchable, document)
        }
        for document in [#""document": "skip blanks""#,
                         #""document": null"#,
                         #""document": {"removeBlankPages": "yes", "blankSensitivity": "low"}"#] {
            let settings = try decode(ScanSettings.self, #"{"resolution": 150, "# + document + #", "pdfSearchable": false}"#)
            XCTAssertFalse(settings.document.removeBlankPages, document)
            XCTAssertEqual(settings.resolution, 150, document)
            XCTAssertFalse(settings.pdfSearchable, document)
        }
        let low = try decode(ScanSettings.self, #"{"document": {"removeBlankPages": "yes", "blankSensitivity": "low"}}"#)
        XCTAssertEqual(low.document.blankSensitivity, .low)
    }

    func test_document_roundTrips_andCopyIsIndependent() throws {
        for sensitivity in BlankSensitivity.allCases {
            for remove in [false, true] {
                var settings = ScanSettings()
                settings.document.removeBlankPages = remove
                settings.document.blankSensitivity = sensitivity
                let back = try JSONDecoder().decode(ScanSettings.self, from: encode(settings))
                XCTAssertEqual(back.document.removeBlankPages, remove)
                XCTAssertEqual(back.document.blankSensitivity, sensitivity)
                XCTAssertEqual(back.document, settings.document)
            }
        }
        let original = nonDefaultSettings()
        var copy = original
        XCTAssertEqual(copy.document, original.document)
        copy.document.removeBlankPages = false
        copy.document.blankSensitivity = .low
        XCTAssertTrue(original.document.removeBlankPages)
        XCTAssertEqual(original.document.blankSensitivity, .high)
    }

    // MARK: Splitting into documents (CONTRACTS.md, rule 6)

    func test_split_isOffByDefault_andInFilesWithoutIt() throws {
        let document = ScanSettings().document
        XCTAssertEqual(document.splitMode, SplitMode.none)
        XCTAssertEqual(document.splitSheetCount, 1)
        let presets = try decode([Preset].self, presetsJSONBeforePDFSize)
        XCTAssertEqual(presets[0].settings.document.splitMode, SplitMode.none)
        XCTAssertEqual(presets[0].settings.document.splitSheetCount, 1)
        // A "document" object written before splitting existed keeps its other settings.
        let older = try decode(ScanSettings.self,
                               #"{"document": {"removeBlankPages": true, "blankSensitivity": "low", "autoStraighten": true}}"#)
        XCTAssertTrue(older.document.removeBlankPages)
        XCTAssertEqual(older.document.blankSensitivity, .low)
        XCTAssertTrue(older.document.autoStraighten)
        XCTAssertEqual(older.document.splitMode, SplitMode.none)
        XCTAssertEqual(older.document.splitSheetCount, 1)
    }

    func test_unknownOrCorruptSplit_fallsBackToOff_restIntact() throws {
        // A mode of a newer version, a wrong case, a number, a null: off; a corrupt count: 1.
        for document in [
            #""document": {"removeBlankPages": true, "splitMode": "everyPage", "splitSheetCount": 4}"#,
            #""document": {"removeBlankPages": true, "splitMode": "Barcode", "splitSheetCount": 4}"#,
            #""document": {"removeBlankPages": true, "splitMode": "SeparatorSheet", "splitSheetCount": 4}"#,
            #""document": {"removeBlankPages": true, "splitMode": 1, "splitSheetCount": 4}"#,
            #""document": {"removeBlankPages": true, "splitMode": null, "splitSheetCount": 4}"#,
        ] {
            let settings = try decode(ScanSettings.self, #"{"resolution": 150, "# + document + #", "pdfSearchable": false}"#)
            XCTAssertEqual(settings.document.splitMode, SplitMode.none, document)
            XCTAssertEqual(settings.document.splitSheetCount, 4, document)
            XCTAssertTrue(settings.document.removeBlankPages, document)
            XCTAssertEqual(settings.resolution, 150)
            XCTAssertFalse(settings.pdfSearchable)
        }
        let count = try decode(ScanSettings.self, #"{"document": {"splitMode": "blankSheet", "splitSheetCount": "three"}}"#)
        XCTAssertEqual(count.document.splitMode, .blankSheet)
        XCTAssertEqual(count.document.splitSheetCount, 1)
    }

    func test_split_roundTrips_andCopyIsIndependent() throws {
        for mode in SplitMode.displayOrder {
            var settings = ScanSettings()
            settings.document.splitMode = mode
            settings.document.splitSheetCount = 7
            let back = try JSONDecoder().decode(ScanSettings.self, from: encode(settings))
            XCTAssertEqual(back.document.splitMode, mode)
            XCTAssertEqual(back.document.splitSheetCount, 7)
            XCTAssertEqual(back.document, settings.document)
            var copy = settings
            copy.document.splitMode = .none
            copy.document.splitSheetCount = 2
            XCTAssertEqual(settings.document.splitMode, mode)
            XCTAssertEqual(settings.document.splitSheetCount, 7)
        }
        let written = try [SplitMode.separatorSheet, .blankSheet, .sheetCount, .barcode].map { mode -> String? in
            var settings = ScanSettings()
            settings.document.splitMode = mode
            let document = try XCTUnwrap(jsonObject(encode(settings))["document"] as? [String: Any])
            return document["splitMode"] as? String
        }
        XCTAssertEqual(written, ["separatorSheet", "blankSheet", "sheetCount", "barcode"])
    }

    func test_splitLabelsAndHints() {
        XCTAssertEqual(SplitMode.displayOrder.map(\.label),
                       ["Off", "At separator sheets", "At blank sheets", "Every few sheets", "At QR codes or barcodes"])
        XCTAssertEqual(SplitMode.displayOrder.map(\.hint),
                       ["All pages in one document", "A separator sheet starts each document",
                        "A blank sheet between documents splits them", "A new document every few sheets",
                        "A code starts each document and can name it"])
        XCTAssertEqual(SplitMode.displayOrder.map(\.caption),
                       ["", "Separator sheets are left out", "Blank sheets are left out", "", ""])
        for mode in SplitMode.displayOrder {
            XCTAssertFalse(mode.steps.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        XCTAssertTrue(SplitMode.separatorSheet.steps
            .hasPrefix("1. Save or print a separator sheet. 2. Put one in front of each document after the first."))
        XCTAssertTrue(SplitMode.barcode.steps.hasSuffix("Only codes starting with CS-SEP count."))
        XCTAssertEqual(SplitMode.blankSheet.steps,
                       "Put an empty sheet between documents. With both sides scanned, only a sheet blank on both sides splits.")
        XCTAssertEqual(BarcodeSeparators.startsDocumentCaption(true), "Pages are kept")
        XCTAssertEqual(BarcodeSeparators.startsDocumentCaption(false), "Sheets are left out")
    }

    // MARK: The settings' short texts (the text spec: tooltips of a few words)

    func test_choiceTexts_areShort_andNeverRepeatTheLabel() {
        XCTAssertEqual([ScanSource.flatbed, .documentFeeder].map(\.label), ["Flatbed", "Document feeder"])
        XCTAssertEqual(ScanSource.documentFeeder.hint, "Automatic document feeder (ADF)")
        XCTAssertEqual(ScanSource.flatbed.hint, "The scanner's glass")
        XCTAssertEqual(PDFSizePreset.displayOrder.map(\.hint),
                       ["Full quality, largest files", "Good for most documents", "Smaller, for email and uploads",
                        "Smallest, for strict size limits"])
        XCTAssertEqual(PDFSizePreset.standard.detail, "Up to 300 dpi (black & white 600), gray pages saved in gray.")
        XCTAssertEqual([AfterSaveAction.none, .open, .reveal, .share].map(\.hint),
                       ["Stay here", "Open the file (several: show the folder)", "Show the files in their folder",
                        "Email or send to an app"])
        XCTAssertEqual([DuplexMode.off, .both, .manual].map(\.hint),
                       ["Front only", "Both sides in one pass", "Scan the fronts, flip the stack, scan the backs"])
        XCTAssertEqual([DuplexBinding.longEdge, .shortEdge].map(\.label), ["Long edge (book)", "Short edge (calendar)"])
        XCTAssertEqual(DuplexBinding.pickerHint, "Which edge the sheets turn on")
        XCTAssertEqual(BlankSensitivity.displayOrder.map(\.hint),
                       ["Only empty pages", "Also dust or a page number", "Also pages with small marks"])
        XCTAssertEqual(BlankSensitivity.highWarning, "Check flagged pages before saving")
        // A tooltip says more than the label, in fifteen words at most.
        var tips: [(String, String)] = []
        tips += PDFSizePreset.displayOrder.map { ($0.label, $0.hint) }
        tips += AfterSaveAction.allCases.map { ($0.label, $0.hint) }
        tips += DuplexMode.allCases.map { ($0.label, $0.hint) }
        tips += BlankSensitivity.displayOrder.map { ($0.label, $0.hint) }
        tips += SplitMode.displayOrder.map { ($0.label, $0.hint) }
        tips += ScanSource.allCases.map { ($0.label, $0.hint) }
        for (label, hint) in tips {
            XCTAssertNotEqual(label, hint)
            XCTAssertTrue((1...15).contains(StatusLine.words(hint)), hint)
        }
    }

    // MARK: Renamed tasks (CONTRACTS.md, rule 6): files keep the raw values, only the titles changed

    func test_renamedTasks_stillDecode_fromSettingsAndPresetsWrittenBefore() throws {
        let renamed: [(String, ScanTask, String)] = [
            ("feeder", .feeder, "Stack from feeder"),
            ("photoRestore", .photoRestore, "Restore old photos"),
            ("copy", .copy, "Photocopy"),
            ("batch", .batch, "Separate documents"),
        ]
        for (rawValue, task, title) in renamed {
            let settings = try decode(ScanSettings.self, "{\"resolution\": 300, \"taskId\": \"\(rawValue)\"}")
            XCTAssertEqual(settings.taskId, rawValue)
            XCTAssertEqual(settings.task, task)
            XCTAssertEqual(settings.task.map { TaskCatalog.definition($0).title }, title)
            // Written back as it was read: the raw value, never the title.
            let written = try jsonObject(encode(settings))
            XCTAssertEqual(written["taskId"] as? String, rawValue)

            // A preset saved for the task by an earlier version keeps its name and its task.
            let presetJSON = "[{\"id\": \"7B0F4C84-3C55-4F56-9D0F-0B4B5F1D2A09\", \"name\": \"My \(rawValue) preset\", "
                + "\"settings\": {\"intent\": \"document\", \"taskId\": \"\(rawValue)\"}}]"
            let presets = try decode([Preset].self, presetJSON)
            XCTAssertEqual(presets.count, 1)
            XCTAssertEqual(presets.first?.name, "My \(rawValue) preset")
            XCTAssertEqual(presets.first.map { TaskCatalog.infer($0.settings) }, task)
        }
    }

    // MARK: Barcode and QR separator sheets (CONTRACTS.md, rule 6)

    func test_barcodeStartsDocument_isOffByDefault_andInFilesWithoutIt() throws {
        XCTAssertFalse(ScanSettings().document.barcodeStartsDocument)
        XCTAssertFalse(try decode([Preset].self, presetsJSONBeforePDFSize)[0].settings.document.barcodeStartsDocument)
        // A "document" object written before it existed keeps its other settings, the barcode split too.
        let older = try decode(ScanSettings.self, #"{"document": {"splitMode": "barcode", "softenSpineShadow": true}}"#)
        XCTAssertEqual(older.document.splitMode, .barcode)
        XCTAssertTrue(older.document.softenSpineShadow)
        XCTAssertFalse(older.document.barcodeStartsDocument)
        for value in ["null", #""yes""#, "1", "{}"] {
            let settings = try decode(ScanSettings.self,
                                      #"{"document": {"splitMode": "barcode", "barcodeStartsDocument": "# + value + #", "autoRotate": true}, "resolution": 150}"#)
            XCTAssertFalse(settings.document.barcodeStartsDocument, value)
            XCTAssertEqual(settings.document.splitMode, .barcode, value)
            XCTAssertTrue(settings.document.autoRotate, value)
            XCTAssertEqual(settings.resolution, 150)
        }
        XCTAssertTrue(try decode(ScanSettings.self, #"{"document": {"barcodeStartsDocument": true}}"#).document.barcodeStartsDocument)
    }

    func test_barcodeStartsDocument_roundTrips_andCopyIsIndependent() throws {
        for starts in [false, true] {
            var settings = ScanSettings()
            settings.document.splitMode = .barcode
            settings.document.barcodeStartsDocument = starts
            let back = try JSONDecoder().decode(ScanSettings.self, from: encode(settings))
            XCTAssertEqual(back.document.splitMode, .barcode)
            XCTAssertEqual(back.document.barcodeStartsDocument, starts)
            XCTAssertEqual(back.document, settings.document)
        }
        let original = nonDefaultSettings()
        var copy = original
        copy.document.barcodeStartsDocument = false
        XCTAssertTrue(original.document.barcodeStartsDocument)
        XCTAssertNotEqual(original.document, copy.document)
    }

    func test_splitBarcodePrefix_isCsSepByDefault_andInFilesWithoutIt() throws {
        XCTAssertEqual(ScanSettings().document.splitBarcodePrefix, "CS-SEP")
        XCTAssertEqual(try decode([Preset].self, presetsJSONBeforePDFSize)[0].settings.document.splitBarcodePrefix, "CS-SEP")
        let older = try decode(ScanSettings.self, #"{"document": {"splitMode": "barcode", "barcodeStartsDocument": true}}"#)
        XCTAssertEqual(older.document.splitMode, .barcode)
        XCTAssertTrue(older.document.barcodeStartsDocument)
        XCTAssertEqual(older.document.splitBarcodePrefix, "CS-SEP")
        for value in ["null", "1", "true", "{}", "[]"] {
            let settings = try decode(ScanSettings.self,
                                      #"{"document": {"splitMode": "barcode", "splitBarcodePrefix": "# + value + #", "autoRotate": true}, "resolution": 150}"#)
            XCTAssertEqual(settings.document.splitBarcodePrefix, "CS-SEP", value)
            XCTAssertEqual(settings.document.splitMode, .barcode, value)
            XCTAssertTrue(settings.document.autoRotate, value)
            XCTAssertEqual(settings.resolution, 150)
        }
        // Any text is kept as written, an empty one too (every code makes a separator sheet).
        XCTAssertEqual(try decode(ScanSettings.self, #"{"document": {"splitBarcodePrefix": " Doc: "}}"#).document.splitBarcodePrefix, " Doc: ")
        XCTAssertEqual(try decode(ScanSettings.self, #"{"document": {"splitBarcodePrefix": ""}}"#).document.splitBarcodePrefix, "")
    }

    func test_splitBarcodePrefix_roundTrips_andCopyIsIndependent() throws {
        for prefix in ["CS-SEP", "", "Fatura №"] {
            var settings = ScanSettings()
            settings.document.splitBarcodePrefix = prefix
            let back = try JSONDecoder().decode(ScanSettings.self, from: encode(settings))
            XCTAssertEqual(back.document.splitBarcodePrefix, prefix)
            XCTAssertEqual(back.document, settings.document)
        }
        let original = nonDefaultSettings()
        var copy = original
        copy.document.splitBarcodePrefix = "OTHER"
        XCTAssertEqual(original.document.splitBarcodePrefix, "DOC")
        XCTAssertNotEqual(original.document, copy.document)
    }

    // MARK: Crop and straighten (CONTRACTS.md, rule 6)

    func test_cropAndStraighten_areOffByDefault_andInFilesWithoutThem() throws {
        let document = ScanSettings().document
        XCTAssertFalse(document.autoCrop)
        XCTAssertFalse(document.autoStraighten)
        let presets = try decode([Preset].self, presetsJSONBeforePDFSize)
        XCTAssertFalse(presets[0].settings.document.autoCrop)
        XCTAssertFalse(presets[0].settings.document.autoStraighten)
        // A "document" object written before crop and straighten existed keeps its blank-page settings.
        let older = try decode(ScanSettings.self, #"{"document": {"removeBlankPages": true, "blankSensitivity": "low"}}"#)
        XCTAssertTrue(older.document.removeBlankPages)
        XCTAssertEqual(older.document.blankSensitivity, .low)
        XCTAssertFalse(older.document.autoCrop)
        XCTAssertFalse(older.document.autoStraighten)
    }

    func test_corruptCropOrStraighten_fallsBackToOff_restIntact() throws {
        let settings = try decode(ScanSettings.self,
                                  #"{"resolution": 150, "document": {"removeBlankPages": true, "autoCrop": "yes", "autoStraighten": 1}, "pdfSearchable": false}"#)
        XCTAssertFalse(settings.document.autoCrop)
        XCTAssertFalse(settings.document.autoStraighten)
        XCTAssertTrue(settings.document.removeBlankPages)
        XCTAssertEqual(settings.resolution, 150)
        XCTAssertFalse(settings.pdfSearchable)
        let straighten = try decode(ScanSettings.self, #"{"document": {"autoCrop": null, "autoStraighten": true}}"#)
        XCTAssertFalse(straighten.document.autoCrop)
        XCTAssertTrue(straighten.document.autoStraighten)
    }

    func test_cropAndStraighten_roundTrip_andCopyIsIndependent() throws {
        for crop in [false, true] {
            for straighten in [false, true] {
                var settings = ScanSettings()
                settings.document.autoCrop = crop
                settings.document.autoStraighten = straighten
                let back = try JSONDecoder().decode(ScanSettings.self, from: encode(settings))
                XCTAssertEqual(back.document.autoCrop, crop)
                XCTAssertEqual(back.document.autoStraighten, straighten)
                XCTAssertEqual(back.document, settings.document)
            }
        }
        let original = nonDefaultSettings()
        var copy = original
        copy.document.autoCrop = false
        copy.document.autoStraighten = false
        XCTAssertTrue(original.document.autoCrop)
        XCTAssertTrue(original.document.autoStraighten)
        XCTAssertNotEqual(original.document, copy.document)
    }

    // MARK: Rotate pages upright (CONTRACTS.md, rule 6)

    func test_rotatePagesUpright_isOffByDefault_andInFilesWithoutIt() throws {
        XCTAssertFalse(ScanSettings().document.autoRotate)
        let presets = try decode([Preset].self, presetsJSONBeforePDFSize)
        XCTAssertFalse(presets[0].settings.document.autoRotate)
        // A "document" object written before it existed keeps its other settings.
        let older = try decode(ScanSettings.self,
                               #"{"document": {"removeBlankPages": true, "autoStraighten": true, "splitMode": "blankSheet"}}"#)
        XCTAssertTrue(older.document.removeBlankPages)
        XCTAssertTrue(older.document.autoStraighten)
        XCTAssertEqual(older.document.splitMode, .blankSheet)
        XCTAssertFalse(older.document.autoRotate)
    }

    func test_corruptRotatePagesUpright_fallsBackToOff_restIntact() throws {
        let settings = try decode(ScanSettings.self, #"{"resolution": 150, "document": {"autoStraighten": true, "autoRotate": "yes"}}"#)
        XCTAssertFalse(settings.document.autoRotate)
        XCTAssertTrue(settings.document.autoStraighten)
        XCTAssertEqual(settings.resolution, 150)
        XCTAssertFalse(try decode(ScanSettings.self, #"{"document": {"autoRotate": null}}"#).document.autoRotate)
        XCTAssertTrue(try decode(ScanSettings.self, #"{"document": {"autoRotate": true}}"#).document.autoRotate)
    }

    func test_rotatePagesUpright_roundTrips_andCopyIsIndependent() throws {
        for rotate in [false, true] {
            var settings = ScanSettings()
            settings.document.autoRotate = rotate
            let back = try JSONDecoder().decode(ScanSettings.self, from: encode(settings))
            XCTAssertEqual(back.document.autoRotate, rotate)
            XCTAssertEqual(back.document, settings.document)
        }
        let original = nonDefaultSettings()
        var copy = original
        copy.document.autoRotate = false
        XCTAssertTrue(original.document.autoRotate)
        XCTAssertNotEqual(original.document, copy.document)
    }

    // MARK: Task options (CONTRACTS.md, rule 6)

    func test_taskOptions_automaticPaperAndNoSideImagesByDefault_andInFilesWithoutThem() throws {
        XCTAssertEqual(IdCardPaper.allCases.map(\.rawValue), ["auto", "a4", "letter"])
        let options = ScanSettings().taskOptions
        XCTAssertEqual(options.idCardPaper, .auto)
        XCTAssertFalse(options.idCardSaveSidesAsImages)
        let presets = try decode([Preset].self, presetsJSONBeforePDFSize)
        XCTAssertEqual(presets[0].settings.taskOptions, TaskOptions())
        XCTAssertEqual(try decode(ScanSettings.self, #"{"taskOptions": {}}"#).taskOptions, TaskOptions())
    }

    func test_unknownOrCorruptTaskOptions_fallBackToTheDefaults_restIntact() throws {
        for taskOptions in [#""taskOptions": {"idCardPaper": "tabloid", "idCardSaveSidesAsImages": true}"#,
                            #""taskOptions": {"idCardPaper": "A4", "idCardSaveSidesAsImages": true}"#,
                            #""taskOptions": {"idCardPaper": 1, "idCardSaveSidesAsImages": true}"#,
                            #""taskOptions": {"idCardPaper": null, "idCardSaveSidesAsImages": true}"#] {
            let settings = try decode(ScanSettings.self, #"{"resolution": 150, "# + taskOptions + #", "pdfSearchable": false}"#)
            XCTAssertEqual(settings.taskOptions.idCardPaper, .auto, taskOptions)
            XCTAssertTrue(settings.taskOptions.idCardSaveSidesAsImages, taskOptions)
            XCTAssertEqual(settings.resolution, 150, taskOptions)
            XCTAssertFalse(settings.pdfSearchable, taskOptions)
        }
        for taskOptions in [#""taskOptions": "id card""#,
                            #""taskOptions": null"#,
                            #""taskOptions": []"#,
                            #""taskOptions": {"idCardPaper": "a4", "idCardSaveSidesAsImages": "yes"}"#] {
            let settings = try decode(ScanSettings.self, #"{"resolution": 150, "# + taskOptions + #", "pdfSearchable": false}"#)
            XCTAssertFalse(settings.taskOptions.idCardSaveSidesAsImages, taskOptions)
            XCTAssertEqual(settings.resolution, 150, taskOptions)
            XCTAssertFalse(settings.pdfSearchable, taskOptions)
        }
        let a4 = try decode(ScanSettings.self, #"{"taskOptions": {"idCardPaper": "a4", "idCardSaveSidesAsImages": "yes"}}"#)
        XCTAssertEqual(a4.taskOptions.idCardPaper, .a4)
    }

    func test_taskOptions_roundTrip_andCopyIsIndependent() throws {
        for paper in IdCardPaper.allCases {
            for sides in [false, true] {
                var settings = ScanSettings()
                settings.taskOptions.idCardPaper = paper
                settings.taskOptions.idCardSaveSidesAsImages = sides
                let data = try encode(settings)
                let written = try XCTUnwrap(try jsonObject(data)["taskOptions"] as? [String: Any])
                // No printer chosen: the key is left out (C# leaves out a null too).
                XCTAssertEqual(Set(written.keys), ["idCardPaper", "idCardSaveSidesAsImages", "copyCount", "copyFitToPage",
                                                   "copyAlsoSavePdf", "receiptNameByDate", "receiptCombine",
                                                   "bookRightToLeft", "bookRotationQuarterTurns", "cameraFrontsFirst",
                                                   "cameraSpreads"])
                XCTAssertEqual(written["idCardPaper"] as? String, paper.rawValue)
                XCTAssertEqual(try JSONDecoder().decode(ScanSettings.self, from: data).taskOptions, settings.taskOptions)
            }
        }
        var copyOptions = ScanSettings()
        copyOptions.taskOptions.copyCount = 12
        copyOptions.taskOptions.copyFitToPage = true
        copyOptions.taskOptions.copyPrinterName = "Microsoft Print to PDF"
        copyOptions.taskOptions.copyAlsoSavePdf = true
        let copyData = try encode(copyOptions)
        let writtenCopy = try XCTUnwrap(try jsonObject(copyData)["taskOptions"] as? [String: Any])
        XCTAssertEqual(writtenCopy["copyCount"] as? Int, 12)
        XCTAssertEqual(writtenCopy["copyPrinterName"] as? String, "Microsoft Print to PDF")
        XCTAssertEqual(try JSONDecoder().decode(ScanSettings.self, from: copyData).taskOptions, copyOptions.taskOptions)

        let original = nonDefaultSettings()
        var copy = original
        XCTAssertEqual(copy.taskOptions, original.taskOptions)
        copy.taskOptions.idCardPaper = .a4
        copy.taskOptions.idCardSaveSidesAsImages = false
        copy.taskOptions.copyCount = 1
        copy.taskOptions.copyPrinterName = nil
        XCTAssertEqual(original.taskOptions.idCardPaper, .letter)
        XCTAssertTrue(original.taskOptions.idCardSaveSidesAsImages)
        XCTAssertEqual(original.taskOptions.copyCount, 3)
        XCTAssertEqual(original.taskOptions.copyPrinterName, "Office printer")
    }

    func test_copyOptions_oneCopyAtRealSizeOnTheDefaultPrinter_byDefaultAndInFilesWithoutThem() throws {
        let options = ScanSettings().taskOptions
        XCTAssertEqual(options.copyCount, 1)
        XCTAssertFalse(options.copyFitToPage)
        XCTAssertNil(options.copyPrinterName)
        XCTAssertFalse(options.copyAlsoSavePdf)
        // Files of the ID card version have task options without the copy keys.
        let idCardOnly = try decode(ScanSettings.self,
                                    #"{"taskOptions": {"idCardPaper": "a4", "idCardSaveSidesAsImages": true}}"#).taskOptions
        XCTAssertEqual(idCardOnly.idCardPaper, .a4)
        XCTAssertTrue(idCardOnly.idCardSaveSidesAsImages)
        XCTAssertEqual(idCardOnly.copyCount, 1)
        XCTAssertFalse(idCardOnly.copyFitToPage)
        XCTAssertNil(idCardOnly.copyPrinterName)
        XCTAssertFalse(idCardOnly.copyAlsoSavePdf)
    }

    func test_receiptOptions_namedByDateInSeparateFiles_byDefaultAndInFilesWithoutThem() throws {
        let options = ScanSettings().taskOptions
        XCTAssertTrue(options.receiptNameByDate)
        XCTAssertFalse(options.receiptCombine)
        // Files of the copy version have task options without the receipt keys.
        let copyOnly = try decode(ScanSettings.self, #"{"taskOptions": {"copyCount": 2, "copyAlsoSavePdf": true}}"#).taskOptions
        XCTAssertEqual(copyOnly.copyCount, 2)
        XCTAssertTrue(copyOnly.copyAlsoSavePdf)
        XCTAssertTrue(copyOnly.receiptNameByDate)
        XCTAssertFalse(copyOnly.receiptCombine)
        var settings = ScanSettings()
        settings.taskOptions.receiptNameByDate = false
        settings.taskOptions.receiptCombine = true
        XCTAssertEqual(try JSONDecoder().decode(ScanSettings.self, from: try encode(settings)).taskOptions, settings.taskOptions)
        var copy = settings
        copy.taskOptions.receiptCombine = false
        XCTAssertFalse(copy.taskOptions.receiptCombine)
        XCTAssertTrue(settings.taskOptions.receiptCombine)
    }

    // MARK: Book or magazine (CONTRACTS.md, rule 6)

    func test_bookOptions_areOffByDefault_andInFilesWithoutThem() throws {
        let settings = ScanSettings()
        XCTAssertFalse(settings.document.splitFacingPages)
        XCTAssertFalse(settings.taskOptions.bookRightToLeft)
        XCTAssertEqual(settings.taskOptions.bookRotationQuarterTurns, 0)
        let presets = try decode([Preset].self, presetsJSONBeforePDFSize)
        XCTAssertFalse(presets[0].settings.document.splitFacingPages)
        // Objects written before they existed keep their other settings.
        let older = try decode(ScanSettings.self, """
            {"document": {"autoStraighten": true, "autoRotate": true}, "taskOptions": {"copyCount": 2, "receiptCombine": true}}
            """)
        XCTAssertTrue(older.document.autoStraighten)
        XCTAssertTrue(older.document.autoRotate)
        XCTAssertFalse(older.document.splitFacingPages)
        XCTAssertEqual(older.taskOptions.copyCount, 2)
        XCTAssertTrue(older.taskOptions.receiptCombine)
        XCTAssertFalse(older.taskOptions.bookRightToLeft)
        XCTAssertEqual(older.taskOptions.bookRotationQuarterTurns, 0)
    }

    func test_corruptBookOptions_fallBackOneByOne_restIntact() throws {
        let settings = try decode(ScanSettings.self, """
            {"resolution": 150, "document": {"autoRotate": true, "splitFacingPages": "yes"},
             "taskOptions": {"copyCount": 2, "bookRightToLeft": 1, "bookRotationQuarterTurns": "left"}, "pdfSearchable": false}
            """)
        XCTAssertEqual(settings.resolution, 150)
        XCTAssertFalse(settings.pdfSearchable)
        XCTAssertTrue(settings.document.autoRotate)
        XCTAssertFalse(settings.document.splitFacingPages)
        XCTAssertEqual(settings.taskOptions.copyCount, 2)
        XCTAssertFalse(settings.taskOptions.bookRightToLeft)
        XCTAssertEqual(settings.taskOptions.bookRotationQuarterTurns, 0)
        let nulls = try decode(ScanSettings.self, """
            {"document": {"splitFacingPages": null}, "taskOptions": {"bookRightToLeft": true, "bookRotationQuarterTurns": null}}
            """)
        XCTAssertFalse(nulls.document.splitFacingPages)
        XCTAssertTrue(nulls.taskOptions.bookRightToLeft)
        XCTAssertEqual(nulls.taskOptions.bookRotationQuarterTurns, 0)
        // A turn out of range is kept as written and read through BookSplitter.normalizedTurns.
        let turns = try decode(ScanSettings.self, #"{"taskOptions": {"bookRotationQuarterTurns": 7}}"#)
        XCTAssertEqual(turns.taskOptions.bookRotationQuarterTurns, 7)
        XCTAssertEqual(BookSplitOptions.of(turns).rotationQuarterTurns, 3)
    }

    func test_bookOptions_roundTrip_andCopyIsIndependent() throws {
        for split in [false, true] {
            for turns in [0, 1, 2, 3] {
                var settings = ScanSettings()
                settings.document.splitFacingPages = split
                settings.taskOptions.bookRightToLeft = !split
                settings.taskOptions.bookRotationQuarterTurns = turns
                let back = try JSONDecoder().decode(ScanSettings.self, from: encode(settings))
                XCTAssertEqual(back.document, settings.document)
                XCTAssertEqual(back.taskOptions, settings.taskOptions)
            }
        }
        let original = nonDefaultSettings()
        var copy = original
        copy.document.splitFacingPages = false
        copy.taskOptions.bookRightToLeft = false
        copy.taskOptions.bookRotationQuarterTurns = 0
        XCTAssertTrue(original.document.splitFacingPages)
        XCTAssertTrue(original.taskOptions.bookRightToLeft)
        XCTAssertEqual(original.taskOptions.bookRotationQuarterTurns, 1)
        XCTAssertNotEqual(original.document, copy.document)
        XCTAssertNotEqual(original.taskOptions, copy.taskOptions)
    }

    // MARK: The iPhone camera's choices (CONTRACTS.md, rule 6)

    func test_cameraOptions_areOffByDefault_readLeniently_andRoundTrip() throws {
        let settings = ScanSettings()
        XCTAssertFalse(settings.taskOptions.cameraFrontsFirst)
        XCTAssertFalse(settings.taskOptions.cameraSpreads)
        let older = try decode(ScanSettings.self, """
            {"taskOptions": {"copyCount": 2, "bookRightToLeft": true}}
            """)
        XCTAssertEqual(older.taskOptions.copyCount, 2)
        XCTAssertTrue(older.taskOptions.bookRightToLeft)
        XCTAssertFalse(older.taskOptions.cameraFrontsFirst)
        XCTAssertFalse(older.taskOptions.cameraSpreads)
        let corrupt = try decode(ScanSettings.self, """
            {"resolution": 150, "taskOptions": {"cameraFrontsFirst": "yes", "cameraSpreads": true, "copyCount": 4}}
            """)
        XCTAssertEqual(corrupt.resolution, 150)
        XCTAssertEqual(corrupt.taskOptions.copyCount, 4)
        XCTAssertFalse(corrupt.taskOptions.cameraFrontsFirst)
        XCTAssertTrue(corrupt.taskOptions.cameraSpreads)
        let nulls = try decode(ScanSettings.self, """
            {"taskOptions": {"cameraFrontsFirst": true, "cameraSpreads": null}}
            """)
        XCTAssertTrue(nulls.taskOptions.cameraFrontsFirst)
        XCTAssertFalse(nulls.taskOptions.cameraSpreads)
        for frontsFirst in [false, true] {
            for spreads in [false, true] {
                var chosen = ScanSettings()
                chosen.taskOptions.cameraFrontsFirst = frontsFirst
                chosen.taskOptions.cameraSpreads = spreads
                let back = try JSONDecoder().decode(ScanSettings.self, from: try encode(chosen))
                XCTAssertEqual(back.taskOptions, chosen.taskOptions)
            }
        }
        // Picking a task keeps them: they say how the user takes that task with the camera.
        let kept = TaskCatalog.apply(.book, to: nonDefaultSettings())
        XCTAssertTrue(kept.taskOptions.cameraFrontsFirst)
        XCTAssertTrue(kept.taskOptions.cameraSpreads)
        var copy = kept
        copy.taskOptions.cameraSpreads = false
        XCTAssertTrue(kept.taskOptions.cameraSpreads)
        XCTAssertNotEqual(kept.taskOptions, copy.taskOptions)
    }

    // MARK: Softening the spine's shadow (CONTRACTS.md, rule 6)

    /// Twin of `SoftenSpineShadow_OffByDefault_AndInFilesWithoutIt`.
    func test_softenSpineShadow_offByDefault_andInFilesWithoutIt() throws {
        XCTAssertFalse(ScanSettings().document.softenSpineShadow)
        XCTAssertFalse(try decode([Preset].self, presetsJSONBeforePDFSize)[0].settings.document.softenSpineShadow)
        // A "document" object written before it existed keeps its other settings.
        let older = try decode(ScanSettings.self, #"{"document": {"autoStraighten": true, "splitFacingPages": true}}"#)
        XCTAssertTrue(older.document.autoStraighten)
        XCTAssertTrue(older.document.splitFacingPages)
        XCTAssertFalse(older.document.softenSpineShadow)
        for value in [#""yes""#, "1", "null", "{}", "[]"] {
            let settings = try decode(ScanSettings.self,
                                      #"{"document": {"splitFacingPages": true, "softenSpineShadow": "# + value + #", "autoRotate": true}, "resolution": 150}"#)
            XCTAssertFalse(settings.document.softenSpineShadow, value)
            XCTAssertTrue(settings.document.splitFacingPages, value)
            XCTAssertTrue(settings.document.autoRotate, value)
            XCTAssertEqual(settings.resolution, 150, value)
        }
        XCTAssertTrue(try decode(ScanSettings.self, #"{"document": {"softenSpineShadow": true}}"#).document.softenSpineShadow)
    }

    /// Twin of `SoftenSpineShadow_RoundTrips_AndCloneIsIndependent`.
    func test_softenSpineShadow_roundTrips_andCopyIsIndependent() throws {
        for soften in [false, true] {
            var settings = ScanSettings()
            settings.document.softenSpineShadow = soften
            let back = try JSONDecoder().decode(ScanSettings.self, from: encode(settings))
            XCTAssertEqual(back.document.softenSpineShadow, soften)
            XCTAssertEqual(back.document, settings.document)
        }
        let original = nonDefaultSettings()
        var copy = original
        copy.document.softenSpineShadow = false
        XCTAssertTrue(original.document.softenSpineShadow)
        XCTAssertNotEqual(original.document, copy.document)
    }

    func test_corruptReceiptOptions_fallBackOneByOne_restIntact() throws {
        let options = try decode(ScanSettings.self, """
            {"resolution": 150, "taskOptions": {"copyCount": 2, "receiptNameByDate": "no", "receiptCombine": true},
             "pdfSearchable": false}
            """)
        XCTAssertEqual(options.resolution, 150)
        XCTAssertFalse(options.pdfSearchable)
        XCTAssertEqual(options.taskOptions.copyCount, 2)
        XCTAssertTrue(options.taskOptions.receiptNameByDate)
        XCTAssertTrue(options.taskOptions.receiptCombine)
        let nulls = try decode(ScanSettings.self,
                               #"{"taskOptions": {"receiptNameByDate": false, "receiptCombine": null}}"#).taskOptions
        XCTAssertFalse(nulls.receiptNameByDate)
        XCTAssertFalse(nulls.receiptCombine)
    }

    func test_corruptCopyOptions_fallBackOneByOne_restIntact() throws {
        let settings = try decode(ScanSettings.self, """
            {"resolution": 150, "taskOptions": {"idCardPaper": "letter", "copyCount": "three", "copyFitToPage": 1,
             "copyPrinterName": 42, "copyAlsoSavePdf": true}, "pdfSearchable": false}
            """)
        XCTAssertEqual(settings.resolution, 150)
        XCTAssertFalse(settings.pdfSearchable)
        XCTAssertEqual(settings.taskOptions.idCardPaper, .letter)
        XCTAssertEqual(settings.taskOptions.copyCount, 1)
        XCTAssertFalse(settings.taskOptions.copyFitToPage)
        XCTAssertNil(settings.taskOptions.copyPrinterName)
        XCTAssertTrue(settings.taskOptions.copyAlsoSavePdf)
        let nulls = try decode(ScanSettings.self,
                               #"{"taskOptions": {"copyCount": null, "copyPrinterName": null, "copyFitToPage": true}}"#).taskOptions
        XCTAssertEqual(nulls.copyCount, 1)
        XCTAssertTrue(nulls.copyFitToPage)
        XCTAssertNil(nulls.copyPrinterName)
        // A count out of range is kept as written and read through PrintCopies.clamp.
        let many = try decode(ScanSettings.self, #"{"taskOptions": {"copyCount": 500}}"#).taskOptions
        XCTAssertEqual(many.copyCount, 500)
        XCTAssertEqual(PrintCopies.clamp(many.copyCount), 99)
    }

    func test_copy_carriesTheTask() {
        var settings = ScanSettings()
        settings.taskId = "feeder"
        var copy = settings
        XCTAssertEqual(copy.task, .feeder)
        copy.taskId = nil
        XCTAssertEqual(settings.taskId, "feeder")
    }
}

// MARK: - Store files

final class PresetStoreFileTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CompleteScannerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var presetsURL: URL { directory.appendingPathComponent("presets.json") }
    private var settingsURL: URL { directory.appendingPathComponent("settings.json") }

    private func keptFiles(prefix: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix(prefix) }
            .sorted()
    }

    func test_missingPresetsFile_startsEmptyWithoutKeepingAnything() throws {
        let presets = PresetStore(directory: directory).load()

        // New installs get no starter presets: the start screen's task cards replace them.
        XCTAssertEqual(presets, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: presetsURL.path))
        XCTAssertEqual(try keptFiles(prefix: "presets.unreadable-"), [])
        // The written file is what the next launch reads.
        XCTAssertEqual(PresetStore(directory: directory).load(), [])
    }

    func test_starterPresetsOfEarlierVersions_stayAndKeepWorking() throws {
        // A presets.json as earlier versions seeded it (two of the five starters).
        let json = """
        [
          {
            "id" : "7B0F4C84-3C55-4F56-9D0F-0B4B5F1D2A01",
            "name" : "Document \u{2192} PDF (300 dpi)",
            "settings" : { "intent" : "document", "resolution" : 300, "colorMode" : "color", "format" : "pdf",
                           "pdfSearchable" : true, "documentMultiPage" : true }
          },
          {
            "id" : "7B0F4C84-3C55-4F56-9D0F-0B4B5F1D2A02",
            "name" : "Old photo restoration (600 dpi, PNG)",
            "settings" : { "intent" : "photo", "resolution" : 600, "colorMode" : "color", "format" : "png",
                           "adjustments" : { "restoreFadedColors" : true, "autoEnhance" : true } }
          }
        ]
        """
        try Data(json.utf8).write(to: presetsURL)

        let presets = PresetStore(directory: directory).load()

        XCTAssertEqual(presets.map(\.name), ["Document \u{2192} PDF (300 dpi)", "Old photo restoration (600 dpi, PNG)"])
        XCTAssertEqual(presets.map { TaskCatalog.infer($0.settings) }, [.document, .photoRestore])
        XCTAssertTrue(presets.allSatisfy { $0.settings.taskId == nil })
        XCTAssertEqual(try keptFiles(prefix: "presets.unreadable-"), [])
    }

    func test_unreadablePresetsFile_isKeptBeforeSeeding() throws {
        let garbage = Data("this is not JSON {".utf8)
        try garbage.write(to: presetsURL)

        let presets = PresetStore(directory: directory).load()

        XCTAssertEqual(presets, [])
        let kept = try keptFiles(prefix: "presets.unreadable-")
        XCTAssertEqual(kept.count, 1)
        let name = try XCTUnwrap(kept.first)
        XCTAssertNotNil(name.range(of: #"^presets\.unreadable-\d{8}-\d{6}\.json$"#,
                                   options: .regularExpression), name)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(name)), garbage)
        // An empty list was written to a fresh presets.json; the next launch keeps nothing new.
        XCTAssertEqual(PresetStore(directory: directory).load(), presets)
        XCTAssertEqual(try keptFiles(prefix: "presets.unreadable-").count, 1)
    }

    func test_wrongShapePresetsFile_isKept() throws {
        let wrongShape = Data(#"{"presets": []}"#.utf8)
        try wrongShape.write(to: presetsURL)

        _ = PresetStore(directory: directory).load()

        let kept = try keptFiles(prefix: "presets.unreadable-")
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(kept[0])), wrongShape)
    }

    func test_nullPresetsFile_isKept() throws {
        for json in ["null", "[null]"] {
            try Data(json.utf8).write(to: presetsURL)

            let presets = PresetStore(directory: directory).load()

            XCTAssertEqual(presets, [], json)
            let kept = try keptFiles(prefix: "presets.unreadable-")
            XCTAssertEqual(kept.count, 1, json)
            let name = try XCTUnwrap(kept.first)
            let keptURL = directory.appendingPathComponent(name)
            XCTAssertEqual(try Data(contentsOf: keptURL), Data(json.utf8), json)
            try FileManager.default.removeItem(at: keptURL)
        }
    }

    func test_unreadableFile_takenName_getsNumberedSuffix() throws {
        // Occupy the kept names (plain and -2) for this second and the next few, so the
        // load below finds them taken whenever it runs.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let now = Date()
        var taken: [String] = []
        for second in 0...5 {
            let stamp = formatter.string(from: now.addingTimeInterval(TimeInterval(second)))
            for name in ["presets.unreadable-\(stamp).json", "presets.unreadable-\(stamp)-2.json"] {
                try Data("taken".utf8).write(to: directory.appendingPathComponent(name))
                taken.append(name)
            }
        }
        let garbage = Data("this is not JSON {".utf8)
        try garbage.write(to: presetsURL)

        _ = PresetStore(directory: directory).load()

        let added = try keptFiles(prefix: "presets.unreadable-").filter { !taken.contains($0) }
        XCTAssertEqual(added.count, 1)
        let kept = try XCTUnwrap(added.first)
        XCTAssertNotNil(kept.range(of: #"^presets\.unreadable-\d{8}-\d{6}-3\.json$"#,
                                   options: .regularExpression), kept)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(kept)), garbage)
        for name in taken {
            XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(name)), Data("taken".utf8), name)
        }
    }

    /// Makes `url` unreadable for the duration of `body`; skipped when running as root,
    /// where permissions do not stop reads.
    private func withoutReadPermission(_ url: URL, _ body: () throws -> Void) throws {
        try XCTSkipIf(getuid() == 0, "file permissions do not apply to root")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        }
        try body()
    }

    func test_inaccessiblePresetsFile_isLeftInPlaceAndNotOverwritten() throws {
        let saved = [Preset(id: sampleID, name: "Receipts", settings: nonDefaultSettings())]
        PresetStore(directory: directory).save(saved)
        let original = try Data(contentsOf: presetsURL)

        try withoutReadPermission(presetsURL) {
            XCTAssertEqual(PresetStore(directory: directory).load(), [])
        }

        XCTAssertEqual(try keptFiles(prefix: "presets.unreadable-"), [])
        XCTAssertEqual(try Data(contentsOf: presetsURL), original)
        // Writes stay refused for the session even once the file is readable again.
        PresetStore(directory: directory).save([])
        XCTAssertEqual(try Data(contentsOf: presetsURL), original)
    }

    func test_inaccessibleSettingsFile_isLeftInPlaceAndNotOverwritten() throws {
        SettingsStore.save(nonDefaultSettings(), directory: directory)
        let original = try Data(contentsOf: settingsURL)

        try withoutReadPermission(settingsURL) {
            XCTAssertNil(SettingsStore.load(directory: directory))
        }

        XCTAssertEqual(try keptFiles(prefix: "settings.unreadable-"), [])
        XCTAssertEqual(try Data(contentsOf: settingsURL), original)
        SettingsStore.save(ScanSettings(), directory: directory)
        XCTAssertEqual(SettingsStore.load(directory: directory), nonDefaultSettings())
    }

    func test_presetsFileWithUnknownValues_loadsInPlace() throws {
        let json = currentFormatPresetsJSON.replacingOccurrences(of: "\"tiff\"", with: "\"webp\"")
        try Data(json.utf8).write(to: presetsURL)

        let presets = PresetStore(directory: directory).load()

        XCTAssertEqual(presets.count, 1)
        XCTAssertEqual(presets[0].id, sampleID)
        XCTAssertEqual(presets[0].settings.format, ScanSettings().format)
        XCTAssertEqual(presets[0].settings.resolution, 600)
        XCTAssertEqual(try keptFiles(prefix: "presets.unreadable-"), [])
    }

    // Notepad's "UTF-16 LE" and Windows PowerShell 5.1's Out-File write UTF-16 with a
    // byte-order mark; JSONDecoder also reads UTF-32 and UTF-16 without one.
    func test_presetsFileInOtherUnicodeEncodings_loadsInPlace() throws {
        let cases: [(bom: [UInt8], encoding: String.Encoding)] = [
            ([0xEF, 0xBB, 0xBF], .utf8),
            ([0xFF, 0xFE], .utf16LittleEndian),
            ([0xFE, 0xFF], .utf16BigEndian),
            ([0xFF, 0xFE, 0x00, 0x00], .utf32LittleEndian),
            ([0x00, 0x00, 0xFE, 0xFF], .utf32BigEndian),
            ([], .utf16LittleEndian),
            ([], .utf16BigEndian),
            ([], .utf32LittleEndian),
            ([], .utf32BigEndian),
        ]
        for (bom, encoding) in cases {
            let label = "\(encoding) with \(bom.count)-byte byte-order mark"
            let text = try XCTUnwrap(currentFormatPresetsJSON.data(using: encoding), label)
            try (Data(bom) + text).write(to: presetsURL)

            let presets = PresetStore(directory: directory).load()

            XCTAssertEqual(presets.map { $0.id }, [sampleID], label)
            XCTAssertEqual(try keptFiles(prefix: "presets.unreadable-"), [], label)
        }
    }

    func test_invalidUTF16PresetsFile_isKept() throws {
        // A byte-order mark followed by an unpaired high surrogate inside a string.
        var damaged: [UInt8] = [0xFF, 0xFE]
        damaged += [UInt8](try XCTUnwrap("[{\"name\": \"".data(using: .utf16LittleEndian)))
        damaged += [0x00, 0xD8]
        damaged += [UInt8](try XCTUnwrap("\"}]".data(using: .utf16LittleEndian)))
        try Data(damaged).write(to: presetsURL)

        let presets = PresetStore(directory: directory).load()

        XCTAssertEqual(presets, [])
        let kept = try keptFiles(prefix: "presets.unreadable-")
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(try XCTUnwrap(kept.first))), Data(damaged))
    }

    // JSONDecoder takes a comma before a closing bracket; the C# twin's reader does not, so
    // neither app reads such a file.
    func test_presetsFileWithATrailingComma_isKept() throws {
        let json = Data(currentFormatPresetsJSON.replacingOccurrences(of: "\"name\"", with: "\"future\":[1,],\"name\"").utf8)
        try json.write(to: presetsURL)

        XCTAssertEqual(PresetStore(directory: directory).load(), [])
        XCTAssertEqual(try keptFiles(prefix: "presets.unreadable-").count, 1)
    }

    func test_trailingCommasAreFoundOutsideStringsOnly() {
        XCTAssertTrue(StoreFiles.hasTrailingComma(Array("[1,]".utf8)))
        XCTAssertTrue(StoreFiles.hasTrailingComma(Array("{\"a\":1 ,\n }".utf8)))
        XCTAssertFalse(StoreFiles.hasTrailingComma(Array("{\"a,]\":\"\\\",}\"}".utf8)))
        XCTAssertFalse(StoreFiles.hasTrailingComma(Array("[1,2]".utf8)))
    }

    func test_presetsSaveThenLoad_roundTrips() throws {
        let presets = [Preset(id: sampleID, name: "Receipts", settings: nonDefaultSettings())]
        PresetStore(directory: directory).save(presets)
        XCTAssertEqual(PresetStore(directory: directory).load(), presets)
    }

    func test_missingSettingsFile_returnsNilWithoutKeepingAnything() throws {
        XCTAssertNil(SettingsStore.load(directory: directory))
        XCTAssertEqual(try keptFiles(prefix: "settings.unreadable-"), [])
    }

    func test_missingFolder_countsAsMissing() throws {
        let absent = directory.appendingPathComponent("absent", isDirectory: true)
        XCTAssertNil(SettingsStore.load(directory: absent))
        // Not protected: the first save creates the folder and the file.
        SettingsStore.save(nonDefaultSettings(), directory: absent)
        XCTAssertEqual(SettingsStore.load(directory: absent), nonDefaultSettings())
    }

    func test_unreadableSettingsFile_isKept() throws {
        let garbage = Data([0xFF, 0x00, 0x7B])
        try garbage.write(to: settingsURL)

        XCTAssertNil(SettingsStore.load(directory: directory))

        let kept = try keptFiles(prefix: "settings.unreadable-")
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(kept[0])), garbage)
        XCTAssertFalse(FileManager.default.fileExists(atPath: settingsURL.path))
    }

    func test_settingsSaveThenLoad_roundTrips() throws {
        SettingsStore.save(nonDefaultSettings(), directory: directory)
        XCTAssertEqual(SettingsStore.load(directory: directory), nonDefaultSettings())
    }
}
