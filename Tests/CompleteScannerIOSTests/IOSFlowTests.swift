#if os(iOS)
import AVFoundation
import XCTest
@testable import CompleteScannerIOS
@testable import CompleteScannerKit

// How the iPhone opens: the task it starts on, whether our camera opens by itself (and when the card saying
// why comes first), and when the scan screen keeps the step card; what the task sheet asks (the kinds) and
// the scan screen's options that change the task under the hood.

final class IOSFlowTests: XCTestCase {
    func test_launchTask_isTheOneSetUpLastTime_elseDocumentToPDF() {
        XCTAssertEqual(IOSShell.launchTask(ScanSettings()), .document)
        for task in [ScanTask.receipt, .idCard, .batch, .document] {
            XCTAssertEqual(IOSShell.launchTask(TaskCatalog.apply(task, to: ScanSettings())), task, task.rawValue)
        }
        // The photocopy and Email are Save's Print… and Email… on the iPhone.
        for task in [ScanTask.copy, .email] {
            XCTAssertEqual(IOSShell.launchTask(TaskCatalog.apply(task, to: ScanSettings())), .document, task.rawValue)
            let preset: ScanSettings = IOSShell.savingActionsAsDocument(TaskCatalog.apply(task, to: ScanSettings()))
            XCTAssertEqual(preset.task, .document, task.rawValue)
        }
        let receipt: ScanSettings = TaskCatalog.apply(.receipt, to: ScanSettings())
        XCTAssertEqual(IOSShell.savingActionsAsDocument(receipt), receipt)
        var unknown = ScanSettings()
        unknown.taskId = "somethingNewer"
        XCTAssertEqual(IOSShell.launchTask(unknown), .document)
    }

    @MainActor
    func test_anEmailPreset_isAppliedAsDocument_withoutTheShareSheetAfterSaving() throws {
        let folder: URL = try ImportTestSupport.makeFolder("emailPreset")
        defer { try? FileManager.default.removeItem(at: folder) }
        let state: AppState = ImportTestSupport.makeState(in: folder)
        let model: IOSPresetsModel = IOSPresetsModel(state: state, importer: IOSImportSession(state: state))
        state.settings = TaskCatalog.apply(.email, to: state.settings)
        XCTAssertTrue(model.save(named: "Mail"))
        let id: UUID = try XCTUnwrap(model.rows.first?.id)
        state.settings = TaskCatalog.apply(.photos, to: state.settings)

        let applied: IOSPresetApply = model.apply(id) {}
        XCTAssertEqual(applied, IOSPresetApply.applied)
        XCTAssertEqual(state.activeTask, ScanTask.document)
        XCTAssertEqual(IOSShell.shownKind(state.settings), .document)
        XCTAssertEqual(state.settings.output.afterSave, AfterSaveAction.none)
        // The size is in Options, so it stays as the preset had it.
        XCTAssertEqual(state.settings.output.pdfSize, .compact)
    }

    func test_cameraOnOpen_opensWhereTheCameraCanBeUsed() {
        for status in [AVAuthorizationStatus.authorized, .notDetermined] {
            XCTAssertEqual(IOSShell.cameraOnOpen(offersCamera: true, camera: .available, authorization: status,
                                                 introShown: true, demo: false), .open)
        }
    }

    func test_cameraOnOpen_saysWhyBeforeTheFirstPrompt_once() {
        XCTAssertEqual(IOSShell.cameraOnOpen(offersCamera: true, camera: .available, authorization: .notDetermined,
                                             introShown: false, demo: false), .introduce)
        // Asked already: no card, whether it was shown or not.
        XCTAssertEqual(IOSShell.cameraOnOpen(offersCamera: true, camera: .available, authorization: .authorized,
                                             introShown: false, demo: false), .open)
        XCTAssertEqual(IOSShell.cameraIntroKey, "camera.introShown")
    }

    func test_cameraOnOpen_staysWithoutACamera_accessOff_orTheDemoScanner() {
        let stays: [(Bool, IOSCameraAvailability, AVAuthorizationStatus, Bool)] = [
            (true, .noCamera, .notDetermined, false),
            (true, .denied, .denied, false),
            (true, .restricted, .restricted, false),
            (false, .available, .authorized, false),
            (true, .available, .authorized, true),
            (true, .available, .notDetermined, true),
        ]
        for (offers, camera, status, demo) in stays {
            XCTAssertEqual(IOSShell.cameraOnOpen(offersCamera: offers, camera: camera, authorization: status,
                                                 introShown: false, demo: demo), .stay,
                           "\(offers) \(camera) \(status.rawValue) \(demo)")
        }
    }

    func test_stepCard_onlyWhileAStepNeedsIt() {
        let options = TaskOptions()
        XCTAssertFalse(IOSShell.showsStepCard(.document, options: options, sides: nil, newDocument: false,
                                              turningOverByHand: false, printer: false))
        XCTAssertFalse(IOSShell.showsStepCard(.twoSided, options: options, sides: CameraSides(mode: .flip),
                                              newDocument: false, turningOverByHand: false, printer: false))
        XCTAssertTrue(IOSShell.showsStepCard(.idCard, options: options, sides: nil, newDocument: false,
                                             turningOverByHand: false, printer: false))
        XCTAssertTrue(IOSShell.showsStepCard(.batch, options: options, sides: nil, newDocument: true,
                                             turningOverByHand: false, printer: false))
        var flip = CameraSides(mode: .flip)
        flip.took([UUID()])
        XCTAssertTrue(IOSShell.showsStepCard(.twoSided, options: options, sides: flip, newDocument: false,
                                             turningOverByHand: false, printer: false))
        XCTAssertTrue(IOSShell.showsStepCard(.document, options: options, sides: nil, newDocument: false,
                                             turningOverByHand: false, printer: true))
        XCTAssertTrue(IOSShell.showsStepCard(.twoSided, options: options, sides: nil, newDocument: false,
                                             turningOverByHand: true, printer: false))
    }

    // MARK: Kinds and options

    func test_kindOf_everyTask() {
        let expected: [ScanTask: IOSScanKind] = [
            .document: .document, .feeder: .document, .twoSided: .document, .batch: .document,
            .email: .document, .word: .document, .archive: .document, .copy: .document,
            .photos: .photos, .photoRestore: .photos, .receipt: .receipts, .idCard: .idCard,
            .book: .book, .quickScan: .text,
        ]
        XCTAssertEqual(expected.count, ScanTask.allCases.count)
        for task in ScanTask.allCases {
            XCTAssertEqual(IOSShell.kind(of: task), expected[task], task.rawValue)
        }
    }

    func test_eachKind_startsItsTask_andIsShownAsItself() {
        XCTAssertEqual(IOSScanKind.allCases.map(\.task), [.document, .photos, .receipt, .idCard, .book, .quickScan])
        XCTAssertEqual(IOSScanKind.allCases.map(\.title), ["Document", "Photos", "Receipts", "ID card", "Book", "Text"])
        for kind in IOSScanKind.allCases {
            XCTAssertEqual(IOSShell.kind(of: kind.task), kind, kind.rawValue)
            XCTAssertEqual(IOSShell.shownKind(TaskCatalog.apply(kind.task, to: ScanSettings())), kind, kind.rawValue)
        }
        // Settings without a task are shown as the kind they look like.
        var byHand: ScanSettings = TaskCatalog.apply(.photoRestore, to: ScanSettings())
        byHand.taskId = nil
        XCTAssertEqual(IOSShell.shownKind(byHand), .photos)
        XCTAssertEqual(IOSShell.shownKind(ScanSettings()), .document)
    }

    func test_kindTiles_areTheSixKinds_withTheCurrentOne() {
        var cards: [TaskCard] = []
        for definition in TaskCatalog.all {
            cards.append(TaskCard(definition: definition, availability: .available, isCurrent: false, summary: "300 dpi"))
        }
        let tiles: [IOSKindTile] = IOSShell.kindTiles(cards, current: .photos)
        XCTAssertEqual(tiles.map(\.kind), IOSScanKind.allCases)
        XCTAssertEqual(tiles.filter(\.isCurrent).map(\.kind), [.photos])
        XCTAssertEqual(tiles[1].accessibilityValue, "Current")
        XCTAssertEqual(tiles[0].accessibilityValue, "")
    }

    func test_bothSides_isTheTwoSidedTask_andBack_keepingTheOtherChoices() {
        var s: ScanSettings = TaskCatalog.apply(.document, to: ScanSettings())
        s.output.pdfSize = .compact
        s.output.alsoSaveText = true
        s.resolution = 200
        let on: ScanSettings = IOSShell.settingBothSides(true, in: s)
        XCTAssertEqual(on.task, .twoSided)
        XCTAssertTrue(TaskCatalog.fits(.twoSided, on))
        XCTAssertEqual(on.duplex, .both)
        XCTAssertEqual(IOSShell.shownKind(on), .document)
        let off: ScanSettings = IOSShell.settingBothSides(false, in: on)
        XCTAssertEqual(off.task, .document)
        XCTAssertEqual(off.duplex, .off)
        XCTAssertEqual(off.source, .flatbed)
        for kept in [on, off] {
            XCTAssertEqual(kept.output.pdfSize, .compact)
            XCTAssertTrue(kept.output.alsoSaveText)
            XCTAssertEqual(kept.resolution, 200)
        }
    }

    func test_restore_isRestoreOldPhotos_andBack() {
        var s: ScanSettings = TaskCatalog.apply(.photos, to: ScanSettings())
        s.resolution = 300
        let on: ScanSettings = IOSShell.settingRestore(true, in: s)
        XCTAssertEqual(on.task, .photoRestore)
        XCTAssertTrue(TaskCatalog.fits(.photoRestore, on))
        XCTAssertTrue(on.adjustments.restoreFadedColors)
        XCTAssertEqual(on.format, .png)
        XCTAssertEqual(IOSShell.shownKind(on), .photos)
        let off: ScanSettings = IOSShell.settingRestore(false, in: on)
        XCTAssertEqual(off.task, .photos)
        XCTAssertFalse(off.adjustments.restoreFadedColors)
        XCTAssertEqual(off.format, .jpeg)
        XCTAssertEqual(off.resolution, 300)
    }

    func test_separateDocuments_isTheSeparateDocumentsTask_andBack() {
        var s: ScanSettings = TaskCatalog.apply(.document, to: ScanSettings())
        s.output.pdfSize = .best
        let on: ScanSettings = IOSShell.settingSeparate(true, in: s)
        XCTAssertEqual(on.task, .batch)
        XCTAssertTrue(TaskCatalog.fits(.batch, on))
        XCTAssertTrue(IOSShell.separatesDocuments(on))
        XCTAssertEqual(on.output.pdfSize, .best)
        // Each document's name goes into its file's, as the task's tile set it.
        XCTAssertEqual(on.namingTemplate, TaskCatalog.apply(.batch, to: ScanSettings()).namingTemplate)
        // QR code sheets chosen before stay chosen.
        var qr: ScanSettings = on
        qr.document.splitMode = .barcode
        XCTAssertEqual(IOSShell.settingSeparate(true, in: qr).document.splitMode, .barcode)
        let off: ScanSettings = IOSShell.settingSeparate(false, in: on)
        XCTAssertEqual(off.task, .document)
        XCTAssertFalse(IOSShell.separatesDocuments(off))
        XCTAssertEqual(off.source, .flatbed)
        XCTAssertEqual(off.namingTemplate, s.namingTemplate)
        // Both sides takes over from it: one task at a time.
        let sides: ScanSettings = IOSShell.settingBothSides(true, in: on)
        XCTAssertEqual(sides.task, .twoSided)
        XCTAssertFalse(IOSShell.separatesDocuments(sides))
        // And it takes over from Both sides, whose sides end with it.
        let separate: ScanSettings = IOSShell.settingSeparate(true, in: sides)
        XCTAssertEqual(separate.task, .batch)
        XCTAssertEqual(separate.duplex, .off)
        XCTAssertFalse(separate.document.autoStraighten)
        XCTAssertEqual(IOSShell.settingSeparate(false, in: separate).duplex, .off)
    }

    func test_onePDFPerPage_isANewDocumentEverySheet() {
        let s: ScanSettings = TaskCatalog.apply(.document, to: ScanSettings())
        XCTAssertFalse(IOSShell.savesEachPage(s))
        let on: ScanSettings = IOSShell.settingEachPage(true, in: s)
        XCTAssertTrue(IOSShell.savesEachPage(on))
        XCTAssertEqual(on.document.splitMode, .sheetCount)
        XCTAssertEqual(on.task, .document)
        XCTAssertFalse(IOSShell.savesEachPage(IOSShell.settingEachPage(false, in: on)))
    }

    func test_anOptionThatEndsTheTask_keepsItsKind() {
        var word: ScanSettings = TaskCatalog.apply(.word, to: ScanSettings())
        word.format = .pdf
        XCTAssertEqual(IOSShell.keepingKind(word).task, .document)
        var archive: ScanSettings = TaskCatalog.apply(.archive, to: ScanSettings())
        archive.output.archival = false
        XCTAssertEqual(IOSShell.keepingKind(archive).task, .document)
        let twoSided: ScanSettings = TaskCatalog.apply(.twoSided, to: ScanSettings())
        XCTAssertEqual(IOSShell.keepingKind(twoSided), twoSided)
    }

    func test_exportFormat_namesPicturesAsJPEG() {
        XCTAssertEqual(IOSShell.exportFormats, [.pdf, .jpeg, .word, .text])
        let shownAs: [(OutputFormat, OutputFormat)] = [(.pdf, .pdf), (.jpeg, .jpeg), (.png, .jpeg), (.tiff, .jpeg),
                                                       (.word, .word), (.text, .text)]
        var s = ScanSettings()
        for (format, shown) in shownAs {
            s.format = format
            XCTAssertEqual(IOSShell.exportFormat(s), shown, format.rawValue)
        }
    }
}
#endif
