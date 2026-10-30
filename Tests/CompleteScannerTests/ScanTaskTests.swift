import XCTest
import Foundation
@testable import CompleteScannerKit

// Mirrors windows/LazyScan.Core.Tests/ScanTaskTests.cs: the same cases, the Archive document
// task included (CONTRACTS.md).

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
    s.taskOptions.idCardPaper = .letter
    s.taskOptions.idCardSaveSidesAsImages = true
    s.taskOptions.copyCount = 4
    s.taskOptions.copyFitToPage = true
    s.taskOptions.copyPrinterName = "Office"
    s.taskOptions.copyAlsoSavePdf = true
    s.taskOptions.receiptNameByDate = false
    s.taskOptions.receiptCombine = true
    s.taskOptions.bookRightToLeft = true
    s.taskOptions.bookRotationQuarterTurns = 3
    return s
}

final class ScanTaskTests: XCTestCase {

    func test_rawValues_areTheStoredNames() {
        XCTAssertEqual(ScanTask.allCases.map(\.rawValue),
                       ["document", "feeder", "photos", "photoRestore", "quickScan", "email", "twoSided", "idCard", "copy", "word",
                        "receipt", "batch", "book", "archive"])
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
                       ["Document to PDF", "Stack from feeder", "Photos", "Restore old photos", "Quick scan",
                        "Email a document", "Two-sided document", "ID card", "Photocopy", "Scan to Word", "Receipts",
                        "Separate documents", "Book or magazine", "Archive document"])
        XCTAssertEqual(TaskCatalog.all.map(\.iconKey),
                       ["document", "feeder", "photos", "restore", "quick", "email", "twoSided", "idCard", "copy", "word",
                        "receipt", "batch", "book", "archive"])
        for definition in TaskCatalog.all {
            XCTAssertEqual(TaskCatalog.definition(definition.task), definition)
            XCTAssertFalse(definition.subtitle.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        // Every task but the ID card has one repeating scan step.
        for definition in TaskCatalog.all where definition.task != .idCard {
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

    func test_catalog_texts_areShort_theFullerGuidanceIsTheHelp() {
        XCTAssertEqual(TaskCatalog.all.map(\.subtitle),
                       ["Page by page into a searchable PDF.", "A stack through the feeder into one PDF.",
                        "Several photos at once, each cropped and straightened.", "Brings back faded colors; saved as PNG.",
                        "Save part of the glass as an image.", "A small PDF, ready to attach.",
                        "Both sides of every sheet, in page order.", "Both sides on one page, at real size.",
                        "Prints at real size, like a photocopier.", "Printed pages into an editable Word file.",
                        "Several at once, small files named by date.", "One stack, a PDF for each document.",
                        "Two pages per scan, split at the spine.", "A searchable PDF/A, made to be kept."])
        XCTAssertEqual(TaskCatalog.all.map { $0.steps[0].prompt },
                       ["Place each page face down and scan, then save.", "Load the pages in the feeder and scan.",
                        "Lay the photos on the glass, apart, and scan.", "Lay the photos on the glass, apart, and scan.",
                        "Preview, drag over the part you need, then scan.", "Scan each page, then save to email it.",
                        "Load the pages in the feeder and scan.", "Place the card face down near a corner and scan.",
                        "Place the original face down, then copy.", "Scan each page, then save as Word.",
                        "Lay up to six receipts apart and scan.", "Put a separator sheet before each document, then scan.",
                        "Open the book face down, spine centered, and scan.", "Scan each page, then save as PDF/A."])
        for definition in TaskCatalog.all {
            XCTAssertTrue((1...3).contains(StatusLine.words(definition.title)), definition.title)
            XCTAssertTrue((1...10).contains(StatusLine.words(definition.subtitle)), definition.subtitle)
            for step in definition.steps {
                // One short line on the banner; the rest behind its info button.
                XCTAssertTrue((1...10).contains(StatusLine.words(step.prompt)), step.prompt)
                XCTAssertFalse(step.help.trimmingCharacters(in: .whitespaces).isEmpty, "\(definition.title): \(step.id)")
                XCTAssertEqual(step.fullPrompt, step.prompt + " " + step.help)
            }
        }
        XCTAssertEqual(TaskCatalog.definition(.document).steps[0].help,
                       "Scan the pages one by one. They are collected until you save the PDF.")
        XCTAssertTrue(TaskCatalog.definition(.batch).steps[0].help.hasPrefix("1. Print separator sheets"))
        XCTAssertEqual(TaskStep(id: "x", title: "t", prompt: "Place it", primaryActionLabel: "Go").fullPrompt, "Place it")
    }

    func test_startScreen_groupsEveryTaskOnce() {
        XCTAssertEqual(TaskGroup.allCases, [.documents, .photosAndImages, .other])
        XCTAssertEqual(TaskGroup.allCases.map(\.title), ["Documents", "Photos & images", "Other"])
        XCTAssertEqual(Set(TaskCatalog.startOrder), Set(ScanTask.allCases))
        XCTAssertEqual(TaskCatalog.startOrder.count, ScanTask.allCases.count)
        let sections: [TaskGroupSection] = TaskCatalog.sections
        XCTAssertEqual(sections.map(\.group), TaskGroup.allCases)
        XCTAssertEqual(sections[0].definitions.map(\.task), [.document, .feeder, .twoSided, .batch, .word, .email, .archive])
        XCTAssertEqual(sections[1].definitions.map(\.task), [.photos, .photoRestore, .quickScan])
        XCTAssertEqual(sections[2].definitions.map(\.task), [.idCard, .copy, .receipt, .book])
        XCTAssertEqual(sections.flatMap { $0.definitions.map(\.task) }, TaskCatalog.startOrder)
        for section in sections {
            for definition in section.definitions {
                XCTAssertEqual(definition.group, section.group, definition.title)
            }
        }
    }

    func test_definitions_flowIntentAndRequiredSource() {
        XCTAssertEqual(TaskCatalog.all.map(\.flow),
                       [.documentQueue, .documentQueue, .photoSplit, .photoSplit, .documentQueue, .documentQueue,
                        .documentQueue, .idCard, .copy, .documentQueue, .receiptSplit, .documentQueue, .documentQueue,
                        .documentQueue])
        XCTAssertEqual(TaskCatalog.all.map(\.intent),
                       [.document, .document, .photo, .photo, .document, .document, .document, .document, .document,
                        .document, .document, .document, .document, .document])
        XCTAssertEqual(TaskCatalog.all.map(\.requiredSource),
                       [nil, .documentFeeder, nil, nil, .flatbed, nil, .documentFeeder, .flatbed, nil, nil, nil, .documentFeeder,
                        .flatbed, nil])
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
            // Thermal print has no color: receipts are scanned in grayscale.
            XCTAssertEqual(s.colorMode, task == .receipt ? .grayscale : .color, task.rawValue)
            XCTAssertTrue(s.photoAutoSplit && s.photoAutoDeskew)
            // The ID card's numbers are better not indexed, and a copy is for paper: no text layer.
            XCTAssertEqual(s.pdfSearchable, task != .idCard && task != .copy, task.rawValue)
            // How the user wants a task done is kept.
            XCTAssertEqual(s.taskOptions.idCardPaper, .letter, task.rawValue)
            XCTAssertTrue(s.taskOptions.idCardSaveSidesAsImages, task.rawValue)
            XCTAssertEqual(s.taskOptions.copyCount, 4, task.rawValue)
            XCTAssertTrue(s.taskOptions.copyFitToPage, task.rawValue)
            XCTAssertEqual(s.taskOptions.copyPrinterName, "Office", task.rawValue)
            XCTAssertTrue(s.taskOptions.copyAlsoSavePdf, task.rawValue)
            XCTAssertFalse(s.taskOptions.receiptNameByDate, task.rawValue)
            XCTAssertTrue(s.taskOptions.receiptCombine, task.rawValue)
            XCTAssertTrue(s.taskOptions.bookRightToLeft, task.rawValue)
            XCTAssertEqual(s.taskOptions.bookRotationQuarterTurns, 3, task.rawValue)
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
                + "\(s.output.pdfSize.rawValue) \(s.document.splitMode.rawValue)"
        }
        XCTAssertEqual(rows, [
            "document flatbed 300 pdf true Scan {date} {counter} false false standard none",
            "document documentFeeder 300 pdf true Scan {date} {counter} false false standard none",
            "photo flatbed 600 jpeg true Photo {date} {counter} false false standard none",
            "photo flatbed 600 png true Photo {date} {counter} true true standard none",
            "document flatbed 150 jpeg false Scan {date} {counter} false false standard none",
            "document flatbed 300 pdf true Scan {date} {counter} false false compact none",
            "document documentFeeder 300 pdf true Scan {date} {counter} false false standard none",
            "document flatbed 300 pdf true ID card {date} false false standard none",
            "document flatbed 300 pdf true Copy {date} {counter} false false standard none",
            "document flatbed 300 word true Scan {date} {counter} false false standard none",
            "document flatbed 300 pdf true Receipt {docdate} {counter} false false compact none",
            "document documentFeeder 300 pdf true Document {label} {date} {counter} false false standard separatorSheet",
            "document flatbed 300 pdf true {task} {date} {counter} false false standard none",
            "document flatbed 300 pdf true Scan {date} {counter} false false best none",
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
            XCTAssertEqual(s.document.removeBlankPages, task == .twoSided || task == .batch, task.rawValue)
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
            XCTAssertEqual(s.document.autoStraighten, task == .twoSided || task == .book, task.rawValue)
        }
        XCTAssertTrue(current.document.autoCrop)
        XCTAssertTrue(TaskCatalog.apply(.twoSided, to: ScanSettings()).document.autoStraighten)
    }

    func test_apply_onlyTheTwoSidedTaskTurnsPagesUpright() {
        var current = customized()
        current.document.autoRotate = true
        for task in ScanTask.allCases {
            XCTAssertEqual(TaskCatalog.apply(task, to: current).document.autoRotate, task == .twoSided || task == .book, task.rawValue)
        }
        XCTAssertTrue(current.document.autoRotate)
        XCTAssertTrue(TaskCatalog.apply(.twoSided, to: ScanSettings()).document.autoRotate)
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

    func test_idCard_isAFlatbedPDFWithItsOwnSteps() {
        let definition = TaskCatalog.definition(.idCard)
        XCTAssertEqual(definition.steps, IdCardSteps.steps)
        XCTAssertEqual(definition.steps[0].primaryActionLabel, "Scan front")
        var s = TaskCatalog.apply(.idCard, to: ScanSettings())
        XCTAssertEqual(s.intent, .document)
        XCTAssertEqual(s.source, .flatbed)
        XCTAssertEqual(s.format, .pdf)
        XCTAssertEqual(s.resolution, 300)
        XCTAssertEqual(s.colorMode, .color)
        XCTAssertEqual(s.duplex, .off)
        XCTAssertFalse(s.pdfSearchable)
        XCTAssertEqual(s.output.afterSave, AfterSaveAction.none)
        XCTAssertEqual(TaskCatalog.flow(of: s), .idCard)
        XCTAssertEqual(TaskCatalog.guidedSteps(s, capabilities: nil), IdCardSteps.steps)
        XCTAssertEqual(TaskCatalog.summary(s), "300 dpi \u{00B7} Color \u{00B7} PDF")
        XCTAssertTrue(TaskCatalog.fits(.idCard, s))
        // Saving JPEG or PNG keeps the task; the feeder or Photos mode ends it.
        s.format = .png
        XCTAssertTrue(TaskCatalog.fits(.idCard, s))
        s.source = .documentFeeder
        XCTAssertFalse(TaskCatalog.fits(.idCard, s))
        XCTAssertEqual(TaskCatalog.flow(of: s), .documentQueue)
        s.source = .flatbed
        s.intent = .photo
        XCTAssertFalse(TaskCatalog.fits(.idCard, s))
        // Settings never look like an ID card without the task stored.
        var untagged = TaskCatalog.apply(.idCard, to: ScanSettings())
        untagged.taskId = nil
        XCTAssertEqual(TaskCatalog.infer(untagged), .document)
    }

    func test_copy_printsAtRealSizeFromAnySource() {
        let definition = TaskCatalog.definition(.copy)
        XCTAssertEqual(definition.steps[0].primaryActionLabel, "Copy")
        var s = TaskCatalog.apply(.copy, to: ScanSettings())
        XCTAssertEqual(s.intent, .document)
        XCTAssertEqual(s.source, .flatbed)
        XCTAssertEqual(s.format, .pdf)
        XCTAssertEqual(s.resolution, 300)
        XCTAssertEqual(s.colorMode, .color)
        XCTAssertEqual(s.duplex, .off)
        XCTAssertFalse(s.pdfSearchable)
        XCTAssertEqual(s.output.afterSave, AfterSaveAction.none)
        XCTAssertEqual(TaskCatalog.flow(of: s), .copy)
        XCTAssertEqual(TaskCatalog.guidedSteps(s, capabilities: nil), definition.steps)
        // Printed at real size, one copy, unless chosen otherwise.
        XCTAssertEqual(s.taskOptions.copyCount, 1)
        XCTAssertFalse(s.taskOptions.copyFitToPage)
        XCTAssertNil(s.taskOptions.copyPrinterName)
        XCTAssertFalse(s.taskOptions.copyAlsoSavePdf)
        // The feeder copies a stack; Photos mode ends the task.
        s.source = .documentFeeder
        XCTAssertTrue(TaskCatalog.fits(.copy, s))
        XCTAssertEqual(TaskCatalog.flow(of: s), .copy)
        s.intent = .photo
        XCTAssertFalse(TaskCatalog.fits(.copy, s))
        XCTAssertEqual(TaskCatalog.flow(of: s), .photoSplit)
        // Settings never look like a copy without the task stored.
        var untagged = TaskCatalog.apply(.copy, to: ScanSettings())
        untagged.taskId = nil
        XCTAssertEqual(TaskCatalog.infer(untagged), .document)
    }

    func test_copy_needsAPrinter_theOtherTasksDoNot() {
        let unavailable = TaskCatalog.availability(of: .copy, capabilities: nil, hasPrinter: false)
        XCTAssertFalse(unavailable.isAvailable)
        XCTAssertEqual(unavailable.reason, "Needs a printer")
        XCTAssertEqual(TaskCatalog.unavailableMessage(.copy, reason: unavailable.reason ?? ""), "Photocopy needs a printer.")
        XCTAssertEqual(TaskCatalog.unavailableMessage(.feeder, reason: TaskCatalog.needsFeederReason),
                       "Stack from feeder needs a document feeder.")
        XCTAssertEqual(TaskCatalog.unavailableMessage(.idCard, reason: " Needs a flatbed. "), "ID card needs a flatbed.")
        XCTAssertEqual(TaskCatalog.availability(of: .copy, capabilities: nil, hasPrinter: true), .available)
        XCTAssertEqual(TaskCatalog.availability(of: .copy, capabilities: nil), .available)
        for task in ScanTask.allCases where task != .copy {
            XCTAssertEqual(TaskCatalog.availability(of: task, capabilities: nil, hasPrinter: false), .available, task.rawValue)
        }
        // Any scanner will do: the glass or the feeder.
        let feederOnly = ScannerCapabilities(sources: [.documentFeeder], supportsOverview: false)
        XCTAssertTrue(TaskCatalog.availability(of: .copy, capabilities: feederOnly, hasPrinter: true).isAvailable)
        XCTAssertEqual(TaskCatalog.availability(of: .idCard, capabilities: feederOnly, hasPrinter: false).reason,
                       "Needs a flatbed")
    }

    func test_summary_ofACopy_saysHowItPrints() {
        var s = TaskCatalog.apply(.copy, to: ScanSettings())
        XCTAssertEqual(TaskCatalog.summary(s), "300 dpi \u{00B7} Color \u{00B7} Actual size")
        s.colorMode = .grayscale
        s.taskOptions.copyFitToPage = true
        s.taskOptions.copyCount = 3
        XCTAssertEqual(TaskCatalog.summary(s), "300 dpi \u{00B7} Grayscale \u{00B7} Fit to page \u{00B7} 3 copies")
        // A count beyond what can be asked for is read as the most.
        s.taskOptions.copyCount = 500
        XCTAssertEqual(TaskCatalog.summary(s), "300 dpi \u{00B7} Grayscale \u{00B7} Fit to page \u{00B7} 99 copies")
        // Without the task the settings describe a file again.
        s.taskId = nil
        XCTAssertEqual(TaskCatalog.summary(s), "300 dpi \u{00B7} Grayscale \u{00B7} PDF")
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
        // One PDF per scan is still a document, and so is the text of each scan.
        XCTAssertEqual(infer { $0.documentMultiPage = false }, .document)
        XCTAssertEqual(infer {
            $0.documentMultiPage = false
            $0.format = .text
        }, .document)
        // A Word document is Scan to Word, collected or not; from the feeder it is a feeder scan.
        XCTAssertEqual(infer { $0.format = .word }, .word)
        XCTAssertEqual(infer {
            $0.documentMultiPage = false
            $0.format = .word
        }, .word)
        XCTAssertEqual(infer {
            $0.source = .documentFeeder
            $0.format = .word
        }, .feeder)
        // A task of a newer version is inferred from the settings.
        XCTAssertEqual(infer {
            $0.taskId = "whiteboard"
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
        for task in [ScanTask.feeder, .twoSided, .batch] {
            let availability = TaskCatalog.availability(of: task, capabilities: caps)
            XCTAssertFalse(availability.isAvailable)
            XCTAssertEqual(availability.reason, "Needs a document feeder")
        }
        for task in ScanTask.allCases where task != .feeder && task != .twoSided && task != .batch {
            XCTAssertTrue(TaskCatalog.availability(of: task, capabilities: caps).isAvailable, task.rawValue)
        }
    }

    func test_availability_feederOnlyScanner_noQuickScanOrIdCard() {
        let caps = ScannerCapabilities(sources: [.documentFeeder], supportsOverview: false)
        for task in [ScanTask.quickScan, .idCard, .book] {
            let availability = TaskCatalog.availability(of: task, capabilities: caps)
            XCTAssertFalse(availability.isAvailable)
            XCTAssertEqual(availability.reason, "Needs a flatbed")
        }
        // Documents and photos fall back to the feeder (SettingsAdapter).
        for task in ScanTask.allCases where task != .quickScan && task != .idCard && task != .book {
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

    func test_carriesPages_onlyIntoTasksThatCollectPages() {
        let carried: Set<ScanTask> = [.document, .feeder, .email, .twoSided, .word, .batch, .book, .archive]
        for task in ScanTask.allCases {
            XCTAssertEqual(TaskCatalog.carriesPages(task), carried.contains(task), task.rawValue)
        }
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
                       ["Document", "Document", "Photo", "Restored photo", "Scan", "Document", "Document", "ID card", "Copy",
                        "Document", "Receipt", "Document", "Book", "Document"])
    }

    func test_word_savesTheTextAsAWordDocument_andEndsWithAnotherFormat() {
        let definition = TaskCatalog.definition(.word)
        XCTAssertEqual(definition.steps[0].primaryActionLabel, "Scan page")
        var s = TaskCatalog.apply(.word, to: ScanSettings())
        XCTAssertEqual(s.format, .word)
        XCTAssertTrue(s.documentMultiPage)
        XCTAssertEqual(TaskCatalog.flow(of: s), .documentQueue)
        XCTAssertEqual(TaskCatalog.summary(s), "300 dpi \u{00B7} Color \u{00B7} Word (.docx)")
        XCTAssertTrue(TaskCatalog.fits(.word, s))
        // Any source will do.
        s.source = .documentFeeder
        XCTAssertTrue(TaskCatalog.fits(.word, s))
        // Another format ends the task.
        s.format = .pdf
        XCTAssertFalse(TaskCatalog.fits(.word, s))
        let feederOnly = ScannerCapabilities(sources: [.documentFeeder], supportsOverview: false)
        XCTAssertEqual(TaskCatalog.availability(of: .word, capabilities: feederOnly), .available)
    }

    func test_receipt_isAGrayCompactSearchablePdf_namedByTheReceiptsDate() {
        let definition = TaskCatalog.definition(.receipt)
        XCTAssertEqual(definition.steps[0].primaryActionLabel, "Scan receipts")
        XCTAssertEqual(definition.iconKey, "receipt")
        XCTAssertEqual(definition.fileLabel, "Receipt")
        var s = TaskCatalog.apply(.receipt, to: ScanSettings())
        XCTAssertEqual(s.intent, .document)
        XCTAssertEqual(s.source, .flatbed)
        XCTAssertEqual(s.format, .pdf)
        XCTAssertEqual(s.resolution, 300)
        XCTAssertEqual(s.colorMode, .grayscale)
        XCTAssertEqual(s.output.pdfSize, .compact)
        XCTAssertTrue(s.pdfSearchable)
        XCTAssertFalse(s.document.autoCrop || s.document.autoStraighten || s.document.removeBlankPages)
        XCTAssertEqual(TaskCatalog.flow(of: s), .receiptSplit)
        XCTAssertEqual(TaskCatalog.summary(s), "300 dpi \u{00B7} Grayscale \u{00B7} Compact PDF")
        XCTAssertTrue(s.taskOptions.receiptNameByDate)
        XCTAssertFalse(s.taskOptions.receiptCombine)
        // The feeder takes one receipt a sheet; another format or size keeps the task; photo mode ends it.
        s.source = .documentFeeder
        s.format = .jpeg
        s.output.pdfSize = .smallest
        XCTAssertTrue(TaskCatalog.fits(.receipt, s))
        XCTAssertEqual(TaskCatalog.flow(of: s), .receiptSplit)
        s.intent = .photo
        XCTAssertFalse(TaskCatalog.fits(.receipt, s))
        XCTAssertTrue(TaskCatalog.availability(of: .receipt, capabilities: ScannerCapabilities(sources: [.documentFeeder])).isAvailable)
    }

    /// Twin of `Apply_OnlyTheArchiveTaskMakesArchivalPdfs`.
    func test_apply_onlyTheArchiveTaskMakesArchivalPdfs() {
        var current = customized()
        current.output.archival = true
        for task in ScanTask.allCases {
            XCTAssertEqual(TaskCatalog.apply(task, to: current).output.archival, task == .archive, task.rawValue)
        }
        XCTAssertTrue(current.output.archival)
        current.output.archival = false
        XCTAssertTrue(TaskCatalog.apply(.archive, to: current).output.archival)
    }

    /// Twin of `Apply_KeepsThePasswordOption_TheArchiveTaskTurnsItOff`.
    func test_apply_keepsThePasswordOption_theArchiveTaskTurnsItOff() {
        var current = customized()
        current.output.protect = true
        for task in ScanTask.allCases {
            let s = TaskCatalog.apply(task, to: current)
            XCTAssertEqual(s.output.protect, task != .archive, task.rawValue)
            XCTAssertFalse(s.output.protect && s.output.archival, task.rawValue)
        }
        XCTAssertTrue(current.output.protect)
        current.output.protect = false
        for task in ScanTask.allCases {
            XCTAssertFalse(TaskCatalog.apply(task, to: current).output.protect, task.rawValue)
        }
    }

    /// Twin of `Apply_KeepsThePageImagesChoice`.
    func test_apply_keepsThePageImagesChoice() {
        // On unless the user turned it off; Scan to Word starts with it on for a new user.
        XCTAssertTrue(TaskCatalog.apply(.word, to: ScanSettings()).output.wordPageImages)
        var current = customized()
        current.output.wordPageImages = false
        for task in ScanTask.allCases {
            XCTAssertFalse(TaskCatalog.apply(task, to: current).output.wordPageImages, task.rawValue)
        }
        XCTAssertFalse(current.output.wordPageImages)
    }

    /// Twin of `Archive_IsABestSizeSearchablePdfA_AndEndsWithAPlainPdf`.
    func test_archive_isABestSizeSearchablePdfA_andEndsWithAPlainPdf() throws {
        let definition = TaskCatalog.definition(.archive)
        XCTAssertEqual(definition.title, "Archive document")
        XCTAssertEqual(definition.steps[0].primaryActionLabel, "Scan page")
        XCTAssertEqual(definition.iconKey, "archive")
        XCTAssertEqual(definition.fileLabel, "Document")
        var s = TaskCatalog.apply(.archive, to: ScanSettings())
        XCTAssertEqual(s.intent, .document)
        XCTAssertEqual(s.source, .flatbed)
        XCTAssertEqual(s.format, .pdf)
        XCTAssertEqual(s.resolution, 300)
        XCTAssertEqual(s.colorMode, .color)
        XCTAssertEqual(s.output.pdfSize, .best)
        XCTAssertTrue(s.pdfSearchable && s.documentMultiPage && s.output.archival)
        XCTAssertEqual(try PDFWriteOptions.forOutput(s.output, title: "Scan").conformance, .pdfA2b)
        XCTAssertEqual(TaskCatalog.flow(of: s), .documentQueue)
        XCTAssertEqual(TaskCatalog.summary(s), "300 dpi \u{00B7} Color \u{00B7} Best PDF")
        XCTAssertTrue(TaskCatalog.fits(.archive, s))
        // Any source and size will do; a plain PDF or another format ends the task.
        s.source = .documentFeeder
        s.output.pdfSize = .compact
        XCTAssertTrue(TaskCatalog.fits(.archive, s))
        s.format = .word
        XCTAssertFalse(TaskCatalog.fits(.archive, s))
        s.format = .pdf
        s.output.archival = false
        XCTAssertFalse(TaskCatalog.fits(.archive, s))
        XCTAssertEqual(TaskCatalog.availability(of: .archive, capabilities: ScannerCapabilities(sources: [.documentFeeder])),
                       .available)
        // Without a stored task an archival PDF is still a plain document.
        var untagged = TaskCatalog.apply(.archive, to: ScanSettings())
        untagged.taskId = nil
        XCTAssertEqual(TaskCatalog.infer(untagged), .document)
    }

    func test_apply_turnsTheTextBesideAPDFOff() {
        var current = customized()
        current.output.alsoSaveText = true
        for task in ScanTask.allCases {
            XCTAssertFalse(TaskCatalog.apply(task, to: current).output.alsoSaveText, task.rawValue)
        }
        XCTAssertTrue(current.output.alsoSaveText)
    }

    func test_batch_splitsAFeederStackAtSeparatorSheets_andEndsWithoutASplit() {
        let definition = TaskCatalog.definition(.batch)
        XCTAssertEqual(definition.steps[0].primaryActionLabel, "Scan stack")
        var s = TaskCatalog.apply(.batch, to: ScanSettings())
        XCTAssertEqual(s.intent, .document)
        XCTAssertEqual(s.source, .documentFeeder)
        XCTAssertEqual(s.format, .pdf)
        XCTAssertEqual(s.duplex, .off)
        XCTAssertEqual(s.document.splitMode, .separatorSheet)
        XCTAssertTrue(s.document.removeBlankPages)
        XCTAssertTrue(s.documentMultiPage && s.pdfSearchable)
        XCTAssertEqual(TaskCatalog.flow(of: s), .documentQueue)
        XCTAssertEqual(TaskCatalog.summary(s), "300 dpi · Color · PDF · Split at separator sheets")
        XCTAssertTrue(TaskCatalog.fits(.batch, s))
        // Another split still fits; no split ends the task, as leaving the feeder does.
        s.document.splitMode = .blankSheet
        XCTAssertTrue(TaskCatalog.fits(.batch, s))
        XCTAssertEqual(TaskCatalog.summary(s), "300 dpi · Color · PDF · Split at blank sheets")
        s.document.splitMode = .sheetCount
        s.document.splitSheetCount = 3
        XCTAssertEqual(TaskCatalog.summary(s), "300 dpi · Color · PDF · Split every 3 sheets")
        s.document.splitSheetCount = 1
        XCTAssertEqual(TaskCatalog.summary(s), "300 dpi · Color · PDF · Split every sheet")
        s.document.splitMode = .none
        XCTAssertFalse(TaskCatalog.fits(.batch, s))
        s.document.splitMode = .separatorSheet
        s.source = .flatbed
        XCTAssertFalse(TaskCatalog.fits(.batch, s))
        // Saved at once, nothing is split: the summary says nothing of it.
        s.documentMultiPage = false
        XCTAssertEqual(TaskCatalog.summary(s), "300 dpi · Color · PDF")
    }

    func test_apply_onlyTheBatchTaskSplits_theSheetCountIsKept() {
        var current = customized()
        current.document.splitMode = .blankSheet
        current.document.splitSheetCount = 4
        for task in ScanTask.allCases {
            let s = TaskCatalog.apply(task, to: current)
            XCTAssertEqual(s.document.splitMode, task == .batch ? .separatorSheet : SplitMode.none, task.rawValue)
            XCTAssertEqual(s.document.splitSheetCount, 4, task.rawValue)
        }
        XCTAssertEqual(current.document.splitMode, .blankSheet)
        // Without a stored task, split documents look like a batch.
        var untagged = TaskCatalog.apply(.batch, to: ScanSettings())
        untagged.taskId = nil
        XCTAssertEqual(TaskCatalog.infer(untagged), .batch)
        untagged.source = .flatbed
        XCTAssertEqual(TaskCatalog.infer(untagged), .batch)
        untagged.document.splitMode = .none
        XCTAssertEqual(TaskCatalog.infer(untagged), .document)
    }

    func test_book_splitsFacingPagesOnTheGlass_andEndsWithoutTheSplit() {
        let definition = TaskCatalog.definition(.book)
        XCTAssertEqual(definition.steps[0].primaryActionLabel, "Scan spread")
        XCTAssertEqual(definition.iconKey, "book")
        XCTAssertEqual(definition.fileLabel, "Book")
        var s = TaskCatalog.apply(.book, to: ScanSettings())
        XCTAssertEqual(s.intent, .document)
        XCTAssertEqual(s.source, .flatbed)
        XCTAssertEqual(s.format, .pdf)
        XCTAssertEqual(s.resolution, 300)
        XCTAssertEqual(s.colorMode, .color)
        XCTAssertEqual(s.duplex, .off)
        XCTAssertTrue(s.documentMultiPage && s.pdfSearchable)
        // Each page is straightened and turned upright on its own; nothing is cropped or skipped.
        XCTAssertTrue(s.document.splitFacingPages)
        XCTAssertTrue(s.document.softenSpineShadow)
        XCTAssertTrue(PageProcessor.softensSpineShadow(s))
        XCTAssertTrue(s.document.autoStraighten)
        XCTAssertTrue(s.document.autoRotate)
        XCTAssertFalse(s.document.autoCrop)
        XCTAssertFalse(s.document.removeBlankPages)
        XCTAssertEqual(s.document.splitMode, SplitMode.none)
        // Left to right and not turned, unless chosen.
        XCTAssertFalse(s.taskOptions.bookRightToLeft)
        XCTAssertEqual(s.taskOptions.bookRotationQuarterTurns, 0)
        XCTAssertEqual(TaskCatalog.flow(of: s), .documentQueue)
        XCTAssertEqual(TaskCatalog.guidedSteps(s, capabilities: nil), definition.steps)
        XCTAssertEqual(TaskCatalog.summary(s), "300 dpi \u{00B7} Color \u{00B7} PDF \u{00B7} Facing pages split")
        s.taskOptions.bookRightToLeft = true
        XCTAssertEqual(TaskCatalog.summary(s), "300 dpi \u{00B7} Color \u{00B7} PDF \u{00B7} Facing pages split, right to left")
        // Two-sided feeder scans keep their pages as scanned: the line does not promise a split.
        var bothSides = s
        bothSides.source = .documentFeeder
        bothSides.duplex = .both
        XCTAssertEqual(TaskCatalog.summary(bothSides), "300 dpi \u{00B7} Color \u{00B7} PDF \u{00B7} Both sides")
        XCTAssertTrue(TaskCatalog.fits(.book, s))
        // Another format or color keeps the task; the feeder or no split ends it.
        s.colorMode = .grayscale
        s.format = .word
        XCTAssertTrue(TaskCatalog.fits(.book, s))
        s.source = .documentFeeder
        XCTAssertFalse(TaskCatalog.fits(.book, s))
        s.source = .flatbed
        s.document.splitFacingPages = false
        XCTAssertFalse(TaskCatalog.fits(.book, s))
        XCTAssertEqual(TaskCatalog.availability(of: .book, capabilities: ScannerCapabilities(sources: [.documentFeeder])).reason,
                       "Needs a flatbed")
        // Saved at once, nothing is split: the summary says nothing of it.
        var once = TaskCatalog.apply(.book, to: ScanSettings())
        once.documentMultiPage = false
        XCTAssertEqual(TaskCatalog.summary(once), "300 dpi \u{00B7} Color \u{00B7} PDF")
    }

    func test_apply_onlyTheBookTaskSplitsFacingPages_itsReadingOrderAndTurnAreKept() {
        var current = customized()
        current.document.splitFacingPages = true
        current.document.softenSpineShadow = true
        for task in ScanTask.allCases {
            let s = TaskCatalog.apply(task, to: current)
            XCTAssertEqual(s.document.splitFacingPages, task == .book, task.rawValue)
            XCTAssertEqual(s.document.softenSpineShadow, task == .book, task.rawValue)
            XCTAssertTrue(s.taskOptions.bookRightToLeft, task.rawValue)
            XCTAssertEqual(s.taskOptions.bookRotationQuarterTurns, 3, task.rawValue)
        }
        XCTAssertTrue(current.document.splitFacingPages)
        XCTAssertTrue(current.document.softenSpineShadow)
        // Without a stored task, split spreads look like a book; split documents still like a batch.
        var untagged = TaskCatalog.apply(.book, to: ScanSettings())
        untagged.taskId = nil
        XCTAssertEqual(TaskCatalog.infer(untagged), .book)
        untagged.document.splitMode = .blankSheet
        XCTAssertEqual(TaskCatalog.infer(untagged), .batch)
        untagged.document.splitMode = .none
        untagged.documentMultiPage = false
        XCTAssertEqual(TaskCatalog.infer(untagged), .document)
    }
}
