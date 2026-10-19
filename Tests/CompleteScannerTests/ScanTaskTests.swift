import XCTest
import Foundation
@testable import CompleteScannerKit

// Mirrors windows/CompleteScanner.Core.Tests/ScanTaskTests.cs: the same cases.

private func customized() -> ScanSettings {
    var s = ScanSettings()
    s.intent = .photo
    s.source = .documentFeeder
    s.resolution = 1200
    s.colorMode = .blackWhite
    s.format = .tiff
    s.jpegQuality = 0.5
    s.destinationPath = "/Volumes/Archive/Scans"
    s.namingTemplate = "Mine {counter}"
    s.photoAutoSplit = false
    s.photoAutoDeskew = false
    s.photoMinSideInches = 2.5
    s.photoCropInsetPixels = 6
    s.documentMultiPage = false
    s.pdfSearchable = false
    s.adjustments.brightness = 0.5
    s.adjustments.descreen = true
    s.adjustments.blackWhiteThreshold = 0.25
    s.output.pdfSize = .smallest
    s.duplex = .manual
    s.backBinding = .shortEdge
    s.paperSize = .legal
    return s
}

final class ScanTaskTests: XCTestCase {

    func test_rawValues_areTheStoredNames() {
        XCTAssertEqual(ScanTask.allCases.map(\.rawValue),
                       ["document", "feeder", "photos", "photoRestore", "quickScan", "email", "twoSided"])
    }

    func test_tryParse_isExact() {
        for task in ScanTask.allCases {
            XCTAssertEqual(ScanTask.tryParse(task.rawValue), task)
        }
        XCTAssertNil(ScanTask.tryParse(nil))
        XCTAssertNil(ScanTask.tryParse(""))
        XCTAssertNil(ScanTask.tryParse("whiteboard"))
        XCTAssertNil(ScanTask.tryParse("Document"))
        XCTAssertNil(ScanTask.tryParse("photorestore"))
    }

    func test_catalog_listsEveryTaskOnce_inStartScreenOrder() {
        XCTAssertEqual(TaskCatalog.all.map(\.task), ScanTask.allCases)
        XCTAssertEqual(TaskCatalog.all.map(\.title),
                       ["Document to PDF", "Multi-page from feeder", "Photos", "Old photo restoration", "Quick scan",
                        "Email a document", "Two-sided document"])
        XCTAssertEqual(TaskCatalog.all.map(\.iconKey),
                       ["document", "feeder", "photos", "restore", "quick", "email", "twoSided"])
        for definition in TaskCatalog.all {
            XCTAssertEqual(TaskCatalog.definition(definition.task), definition)
            XCTAssertFalse(definition.subtitle.trimmingCharacters(in: .whitespaces).isEmpty)
            XCTAssertEqual(definition.steps.count, 1)
            let step = definition.steps[0]
            XCTAssertEqual(step.id, "scan")
            XCTAssertTrue(step.repeats)
            XCTAssertTrue(step.requiresCapture)
            XCTAssertFalse(step.skippable)
            XCTAssertFalse(step.prompt.isEmpty)
            XCTAssertFalse(step.primaryActionLabel.isEmpty)
        }
    }

    func test_definitions_flowIntentAndRequiredSource() {
        XCTAssertEqual(TaskCatalog.all.map(\.flow),
                       [.documentQueue, .documentQueue, .photoSplit, .photoSplit, .documentQueue, .documentQueue,
                        .documentQueue])
        XCTAssertEqual(TaskCatalog.all.map(\.intent),
                       [.document, .document, .photo, .photo, .document, .document, .document])
        XCTAssertEqual(TaskCatalog.all.map(\.requiredSource),
                       [nil, .documentFeeder, nil, nil, .flatbed, nil, .documentFeeder])
    }

    func test_apply_keepsDestinationAndDetectionTuning_andLeavesTheInputAlone() {
        let current = customized()
        for task in ScanTask.allCases {
            let s = TaskCatalog.apply(task, to: current)
            XCTAssertEqual(s.destinationPath, "/Volumes/Archive/Scans")
            XCTAssertEqual(s.photoMinSideInches, 2.5)
            XCTAssertEqual(s.photoCropInsetPixels, 6)
            XCTAssertEqual(s.taskId, task.rawValue)
            XCTAssertEqual(s.task, task)
            XCTAssertEqual(s.jpegQuality, 0.9)
            XCTAssertEqual(s.colorMode, .color)
            XCTAssertTrue(s.photoAutoSplit && s.photoAutoDeskew && s.pdfSearchable)
            XCTAssertEqual(s.intent, TaskCatalog.definition(task).intent)
            XCTAssertTrue(TaskCatalog.fits(task, s))
            XCTAssertEqual(TaskCatalog.infer(s), task)
        }
        XCTAssertEqual(current, customized())
    }

    func test_apply_taskSettingsTable() {
        let current = customized()
        let rows = ScanTask.allCases.map { task -> String in
            let s = TaskCatalog.apply(task, to: current)
            return "\(s.intent.rawValue) \(s.source.rawValue) \(s.resolution) \(s.format.rawValue) "
                + "\(s.documentMultiPage) \(s.namingTemplate) \(s.adjustments.restoreFadedColors) \(s.adjustments.autoEnhance) "
                + s.output.pdfSize.rawValue
        }
        XCTAssertEqual(rows, [
            "document flatbed 300 pdf true Scan {date} {counter} false false standard",
            "document documentFeeder 300 pdf true Scan {date} {counter} false false standard",
            "photo flatbed 600 jpeg true Photo {date} {counter} false false standard",
            "photo flatbed 600 png true Photo {date} {counter} true true standard",
            "document flatbed 150 jpeg false Scan {date} {counter} false false standard",
            "document flatbed 300 pdf true Scan {date} {counter} false false compact",
            "document documentFeeder 300 pdf true Scan {date} {counter} false false standard",
        ])
    }

    func test_apply_onlyTheTwoSidedTaskScansBothSides_thePaperIsKept() {
        let current = customized()
        for task in ScanTask.allCases {
            let s = TaskCatalog.apply(task, to: current)
            XCTAssertEqual(s.duplex, task == .twoSided ? .both : .off, task.rawValue)
            XCTAssertEqual(s.backBinding, .shortEdge)
            XCTAssertEqual(s.paperSize, .legal)
        }
    }

    func test_apply_onlyTheTwoSidedTaskSkipsBlankPages_howMuchCountsAsBlankIsKept() {
        var current = customized()
        current.document.removeBlankPages = true
        current.document.blankSensitivity = .high
        for task in ScanTask.allCases {
            let s = TaskCatalog.apply(task, to: current)
            XCTAssertEqual(s.document.removeBlankPages, task == .twoSided, task.rawValue)
            XCTAssertEqual(s.document.blankSensitivity, .high, task.rawValue)
        }
        XCTAssertTrue(current.document.removeBlankPages)
        XCTAssertTrue(TaskCatalog.apply(.twoSided, to: ScanSettings()).document.removeBlankPages)
    }

    func test_apply_onlyTheTwoSidedTaskStraightens_noTaskCrops() {
        var current = customized()
        current.document.autoCrop = true
        current.document.autoStraighten = true
        for task in ScanTask.allCases {
            let s = TaskCatalog.apply(task, to: current)
            XCTAssertFalse(s.document.autoCrop, task.rawValue)
            XCTAssertEqual(s.document.autoStraighten, task == .twoSided, task.rawValue)
        }
        XCTAssertTrue(current.document.autoCrop)
        XCTAssertTrue(TaskCatalog.apply(.twoSided, to: ScanSettings()).document.autoStraighten)
    }

    func test_twoSided_isATwoSidedFeederPDF() {
        XCTAssertEqual(TaskCatalog.definition(.twoSided).steps[0].primaryActionLabel, "Scan stack")
        var s = TaskCatalog.apply(.twoSided, to: ScanSettings())
        XCTAssertEqual(s.intent, .document)
        XCTAssertEqual(s.source, .documentFeeder)
        XCTAssertEqual(s.format, .pdf)
        XCTAssertEqual(s.duplex, .both)
        XCTAssertTrue(TaskCatalog.fits(.twoSided, s))
        s.duplex = .manual
        XCTAssertTrue(TaskCatalog.fits(.twoSided, s))
        // One side by hand ends the task, as leaving the feeder does.
        s.duplex = .off
        XCTAssertFalse(TaskCatalog.fits(.twoSided, s))
        s.duplex = .both
        s.source = .flatbed
        XCTAssertFalse(TaskCatalog.fits(.twoSided, s))
    }

    func test_guidedSteps_turningOverByHandWinsOverTheTask() {
        XCTAssertNil(TaskCatalog.guidedSteps(ScanSettings(), capabilities: nil))
        XCTAssertEqual(TaskCatalog.guidedSteps(TaskCatalog.apply(.document, to: ScanSettings()), capabilities: nil),
                       TaskCatalog.definition(.document).steps)
        var unknown = ScanSettings()
        unknown.taskId = "whiteboard"
        XCTAssertNil(TaskCatalog.guidedSteps(unknown, capabilities: nil))

        let twoSided = TaskCatalog.apply(.twoSided, to: ScanSettings())
        let duplexFeeder = ScannerCapabilities(sources: [.documentFeeder], supportsDuplex: true)
        let simplexFeeder = ScannerCapabilities(sources: [.documentFeeder], supportsDuplex: false)
        XCTAssertEqual(TaskCatalog.guidedSteps(twoSided, capabilities: duplexFeeder), TaskCatalog.definition(.twoSided).steps)
        XCTAssertEqual(TaskCatalog.guidedSteps(twoSided, capabilities: simplexFeeder), DocumentSides.manualSteps)

        // Without a task, too.
        var byHand = ScanSettings()
        byHand.source = .documentFeeder
        byHand.duplex = .manual
        XCTAssertEqual(TaskCatalog.guidedSteps(byHand, capabilities: nil), DocumentSides.manualSteps)
        // Each scan saved at once: nothing to guide.
        byHand.documentMultiPage = false
        XCTAssertNil(TaskCatalog.guidedSteps(byHand, capabilities: nil))
    }

    func test_apply_resetsAdjustmentsToTheTasks() {
        XCTAssertEqual(TaskCatalog.apply(.document, to: customized()).adjustments, AdjustmentSettings())
        var restore = AdjustmentSettings()
        restore.restoreFadedColors = true
        restore.autoEnhance = true
        XCTAssertEqual(TaskCatalog.apply(.photoRestore, to: customized()).adjustments, restore)
    }

    func test_infer_storedTaskWins() {
        var s = ScanSettings()
        s.intent = .photo
        s.taskId = "quickScan"
        XCTAssertEqual(TaskCatalog.infer(s), .quickScan)
    }

    func test_infer_fromTheSettingsWhenNoTaskIsStored() {
        func infer(_ change: (inout ScanSettings) -> Void) -> ScanTask {
            var s = ScanSettings()
            change(&s)
            return TaskCatalog.infer(s)
        }

        XCTAssertEqual(infer { _ in }, .document)
        XCTAssertEqual(infer { $0.intent = .photo }, .photos)
        XCTAssertEqual(infer {
            $0.intent = .photo
            $0.adjustments.restoreFadedColors = true
        }, .photoRestore)
        XCTAssertEqual(infer { $0.source = .documentFeeder }, .feeder)
        XCTAssertEqual(infer {
            $0.source = .documentFeeder
            $0.duplex = .manual
        }, .twoSided)
        // Two-sided on the flatbed means nothing: still a document.
        XCTAssertEqual(infer { $0.duplex = .both }, .document)
        XCTAssertEqual(infer {
            $0.documentMultiPage = false
            $0.format = .jpeg
        }, .quickScan)
        // One PDF per scan is still a document.
        XCTAssertEqual(infer { $0.documentMultiPage = false }, .document)
        // A task of a newer version is inferred from the settings.
        XCTAssertEqual(infer {
            $0.taskId = "receipt"
            $0.intent = .photo
        }, .photos)
    }

    func test_infer_theFiveStarterPresetsOfEarlierVersions() {
        // The settings earlier versions seeded presets.json with, as their cards are badged.
        var compactText = ScanSettings()
        compactText.resolution = 200
        compactText.colorMode = .grayscale
        var photos = ScanSettings()
        photos.intent = .photo
        photos.resolution = 600
        photos.format = .jpeg
        var restore = ScanSettings()
        restore.intent = .photo
        restore.resolution = 600
        restore.format = .png
        restore.adjustments.restoreFadedColors = true
        restore.adjustments.autoEnhance = true
        var quick = ScanSettings()
        quick.resolution = 150
        quick.format = .jpeg
        quick.documentMultiPage = false

        XCTAssertEqual(TaskCatalog.infer(ScanSettings()), .document)
        XCTAssertEqual(TaskCatalog.infer(compactText), .document)
        XCTAssertEqual(TaskCatalog.infer(photos), .photos)
        XCTAssertEqual(TaskCatalog.infer(restore), .photoRestore)
        XCTAssertEqual(TaskCatalog.infer(quick), .quickScan)
    }

    func test_availability_withoutScanner_everythingIsAvailable() {
        for task in ScanTask.allCases {
            XCTAssertEqual(TaskCatalog.availability(of: task, capabilities: nil), .available)
        }
    }

    func test_availability_flatbedOnlyScanner_noFeederTasks() {
        let caps = ScannerCapabilities(sources: [.flatbed])
        for task in [ScanTask.feeder, .twoSided] {
            let availability = TaskCatalog.availability(of: task, capabilities: caps)
            XCTAssertFalse(availability.isAvailable)
            XCTAssertEqual(availability.reason, "This scanner has no document feeder.")
        }
        for task in ScanTask.allCases where task != .feeder && task != .twoSided {
            XCTAssertTrue(TaskCatalog.availability(of: task, capabilities: caps).isAvailable, task.rawValue)
        }
    }

    func test_availability_feederOnlyScanner_noQuickScan() {
        let caps = ScannerCapabilities(sources: [.documentFeeder], supportsOverview: false)
        let quick = TaskCatalog.availability(of: .quickScan, capabilities: caps)
        XCTAssertFalse(quick.isAvailable)
        XCTAssertEqual(quick.reason, "This scanner has no flatbed.")
        // Documents and photos fall back to the feeder (SettingsAdapter).
        for task in ScanTask.allCases where task != .quickScan {
            XCTAssertTrue(TaskCatalog.availability(of: task, capabilities: caps).isAvailable, task.rawValue)
        }
    }

    func test_fits_followsModeAndRequiredSource() {
        var document = TaskCatalog.apply(.document, to: ScanSettings())
        document.source = .documentFeeder
        XCTAssertTrue(TaskCatalog.fits(.document, document))
        document.intent = .photo
        XCTAssertFalse(TaskCatalog.fits(.document, document))

        var feeder = TaskCatalog.apply(.feeder, to: ScanSettings())
        feeder.resolution = 600
        feeder.format = .tiff
        XCTAssertTrue(TaskCatalog.fits(.feeder, feeder))
        feeder.source = .flatbed
        XCTAssertFalse(TaskCatalog.fits(.feeder, feeder))

        var quick = TaskCatalog.apply(.quickScan, to: ScanSettings())
        quick.source = .documentFeeder
        XCTAssertFalse(TaskCatalog.fits(.quickScan, quick))

        var photos = TaskCatalog.apply(.photos, to: ScanSettings())
        photos.source = .documentFeeder
        XCTAssertTrue(TaskCatalog.fits(.photos, photos))
        photos.intent = .document
        XCTAssertFalse(TaskCatalog.fits(.photos, photos))
    }

    func test_flowOf_taskThenMode() {
        XCTAssertEqual(TaskCatalog.flow(of: ScanSettings()), .documentQueue)
        var photo = ScanSettings()
        photo.intent = .photo
        XCTAssertEqual(TaskCatalog.flow(of: photo), .photoSplit)
        for task in ScanTask.allCases {
            XCTAssertEqual(TaskCatalog.flow(of: TaskCatalog.apply(task, to: ScanSettings())),
                           TaskCatalog.definition(task).flow)
        }
        // A stored task that no longer fits (a hand-edited file) does not override the mode.
        var stale = ScanSettings()
        stale.taskId = "photos"
        stale.intent = .document
        XCTAssertEqual(TaskCatalog.flow(of: stale), .documentQueue)
        var unknown = ScanSettings()
        unknown.taskId = "whiteboard"
        unknown.intent = .photo
        XCTAssertEqual(TaskCatalog.flow(of: unknown), .photoSplit)
    }

    func test_summary_oneLine() {
        XCTAssertEqual(TaskCatalog.summary(ScanSettings()), "300 dpi \u{00B7} Color \u{00B7} PDF")
        XCTAssertEqual(TaskCatalog.summary(TaskCatalog.apply(.photoRestore, to: ScanSettings())),
                       "600 dpi \u{00B7} Color \u{00B7} PNG")
        var s = ScanSettings()
        s.resolution = 200
        s.colorMode = .blackWhite
        s.format = .tiff
        XCTAssertEqual(TaskCatalog.summary(s), "200 dpi \u{00B7} Black & White \u{00B7} TIFF")
    }

    func test_summary_namesANonDefaultPDFSize_forPDFsOnly() {
        XCTAssertEqual(TaskCatalog.summary(TaskCatalog.apply(.email, to: ScanSettings())),
                       "300 dpi \u{00B7} Color \u{00B7} Compact PDF")
        var smallest = ScanSettings()
        smallest.resolution = 150
        smallest.colorMode = .grayscale
        smallest.output.pdfSize = .smallest
        XCTAssertEqual(TaskCatalog.summary(smallest), "150 dpi \u{00B7} Grayscale \u{00B7} Smallest PDF")
        smallest.format = .jpeg
        XCTAssertEqual(TaskCatalog.summary(smallest), "150 dpi \u{00B7} Grayscale \u{00B7} JPEG")
        var best = ScanSettings()
        best.output.pdfSize = .best
        XCTAssertEqual(TaskCatalog.summary(best), "300 dpi \u{00B7} Color \u{00B7} Best PDF")
        XCTAssertEqual(TaskCatalog.summary(TaskCatalog.apply(.document, to: best)), "300 dpi \u{00B7} Color \u{00B7} PDF")
    }

    func test_summary_namesTwoSidedFeederScans() {
        let twoSided = TaskCatalog.apply(.twoSided, to: ScanSettings())
        XCTAssertEqual(TaskCatalog.summary(twoSided), "300 dpi \u{00B7} Color \u{00B7} PDF \u{00B7} Both sides")
        let simplexFeeder = ScannerCapabilities(sources: [.documentFeeder], supportsDuplex: false)
        XCTAssertEqual(TaskCatalog.summary(SettingsAdapter.adapt(twoSided, to: simplexFeeder).settings),
                       "300 dpi \u{00B7} Color \u{00B7} PDF \u{00B7} Both sides, turned by hand")
        // On the flatbed the setting does nothing, so it is not named.
        var flatbed = ScanSettings()
        flatbed.duplex = .both
        XCTAssertEqual(TaskCatalog.summary(flatbed), "300 dpi \u{00B7} Color \u{00B7} PDF")
    }

    func test_email_isACompactDocumentPDF_onAnyScanner() {
        var email = TaskCatalog.apply(.email, to: customized())
        XCTAssertEqual(email.intent, .document)
        XCTAssertEqual(email.format, .pdf)
        XCTAssertEqual(email.output.pdfSize, .compact)
        XCTAssertEqual(email.resolution, 300)
        XCTAssertEqual(email.colorMode, .color)
        XCTAssertEqual(TaskCatalog.flow(of: email), .documentQueue)
        XCTAssertEqual(TaskCatalog.definition(.email).steps[0].primaryActionLabel, "Scan page")
        XCTAssertTrue(TaskCatalog.availability(of: .email,
                                               capabilities: ScannerCapabilities(sources: [.documentFeeder])).isAvailable)
        XCTAssertTrue(TaskCatalog.availability(of: .email,
                                               capabilities: ScannerCapabilities(sources: [.flatbed])).isAvailable)
        // Changing the size by hand keeps the task; leaving document mode ends it.
        email.output.pdfSize = .best
        email.source = .documentFeeder
        XCTAssertTrue(TaskCatalog.fits(.email, email))
        email.intent = .photo
        XCTAssertFalse(TaskCatalog.fits(.email, email))
        // Without a stored task a compact PDF is still a plain document.
        var untagged = TaskCatalog.apply(.email, to: ScanSettings())
        untagged.taskId = nil
        XCTAssertEqual(TaskCatalog.infer(untagged), .document)
    }

    func test_fileLabels() {
        XCTAssertEqual(TaskCatalog.all.map(\.fileLabel),
                       ["Document", "Document", "Photo", "Restored photo", "Scan", "Document", "Document"])
    }
}
