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
    settings.duplex = .manual
    settings.backBinding = .shortEdge
    settings.paperSize = .a4
    settings.document.removeBlankPages = true
    settings.document.blankSensitivity = .high
    settings.document.autoCrop = true
    settings.document.autoStraighten = true
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
/// "output" object, the sides, the paper size and the "document" object in their sorted places.
private let currentFormatPresetsJSON = presetsJSONBeforePDFSize
    .replacingOccurrences(
        of: "\"documentMultiPage\" : false",
        with: "\"document\" : {\n        \"autoCrop\" : true,\n        \"autoStraighten\" : true,\n"
            + "        \"blankSensitivity\" : \"high\",\n        \"removeBlankPages\" : true\n      },\n"
            + "      \"documentMultiPage\" : false")
    .replacingOccurrences(
        of: "\"pdfSearchable\" : false",
        with: "\"output\" : {\n        \"afterSave\" : \"share\",\n        \"pdfSize\" : \"compact\"\n      },\n"
            + "      \"paperSize\" : \"a4\",\n      \"pdfSearchable\" : false")
    .replacingOccurrences(of: "\"colorMode\" : \"grayscale\"",
                          with: "\"backBinding\" : \"shortEdge\",\n      \"colorMode\" : \"grayscale\"")
    .replacingOccurrences(of: "\"format\" : \"tiff\"",
                          with: "\"duplex\" : \"manual\",\n      \"format\" : \"tiff\"")

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
        let presets = [
            Preset(id: sampleID, name: "Receipts", settings: nonDefaultSettings()),
            Preset(name: "Defaults", settings: ScanSettings()),
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
            "document",
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
            "document",
        ])
        XCTAssertEqual(written["taskId"] as? String, "document")
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
        expected.duplex = .off
        expected.backBinding = .longEdge
        expected.paperSize = .auto
        expected.document = DocumentOptions()
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
            XCTAssertEqual(Set(output.keys), ["pdfSize", "afterSave"])
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
