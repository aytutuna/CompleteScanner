#if os(iOS)
import AVFoundation
import CoreGraphics
import XCTest
@testable import CompleteScannerIOS
@testable import CompleteScannerKit

// How the iPhone opens: the task it starts on, whether the card saying why the camera is asked for comes
// first, and when the scan screen keeps the step card; the kinds (the printer screen's chips and camera
// mode's row), camera mode's options drawer and its floating Save, and the scan screen's options that change
// the task under the hood.

/// A white page of the test's own.
private func flowPage() -> ScannedPage {
    let context: CGContext = ImportTestSupport.context(width: 30, height: 40)
    context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 30, height: 40))
    return ScannedPage(image: context.makeImage()!, dpi: 60, colorMode: .color)
}

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
        // With both sides a sheet's front and back stay together, and the switch (the drawer's chip and the
        // Export sheet's toggle alike) says so.
        XCTAssertEqual(IOSShell.eachPageTitle(on), "One PDF per page")
        XCTAssertEqual(IOSShell.eachPageTitle(IOSShell.settingBothSides(true, in: on)), "One PDF per sheet")
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

    func test_exportFormat_namesThePictureFormatSaved() {
        var s = ScanSettings()
        for format in OutputFormat.allCases {
            s.format = format
            let offered: [OutputFormat] = IOSShell.exportFormats(s)
            XCTAssertEqual(IOSShell.exportFormat(s), format, format.rawValue)
            XCTAssertTrue(offered.contains(format), format.rawValue)
            XCTAssertEqual(offered.count, 4, format.rawValue)
        }
        s.format = .pdf
        XCTAssertEqual(IOSShell.exportFormats(s), [.pdf, .jpeg, .word, .text])
        // PNG or TIFF chosen in Settings is what the segment names, not JPEG.
        s.format = .png
        XCTAssertEqual(IOSShell.exportFormats(s), [.pdf, .png, .word, .text])
        s.format = .tiff
        XCTAssertEqual(IOSShell.exportFormats(s), [.pdf, .tiff, .word, .text])
    }

    // MARK: Camera mode

    func test_cameraKinds_putDocumentInTheMiddle_eachKindOnce() {
        XCTAssertEqual(IOSShell.cameraKinds, [.photos, .receipts, .document, .idCard, .book, .text])
        XCTAssertEqual(Set(IOSShell.cameraKinds), Set(IOSScanKind.allCases))
        var cards: [TaskCard] = []
        for definition in TaskCatalog.all {
            cards.append(TaskCard(definition: definition, availability: .available, isCurrent: false, summary: ""))
        }
        let tiles: [IOSKindTile] = IOSShell.kindTiles(cards, current: .document, order: IOSShell.cameraKinds)
        XCTAssertEqual(tiles.map(\.kind), IOSShell.cameraKinds)
        XCTAssertEqual(tiles.filter(\.isCurrent).map(\.kind), [.document])
    }

    func test_drawerGroups_followWhatIsSaved() {
        let document: ScanSettings = TaskCatalog.apply(.document, to: ScanSettings())
        XCTAssertEqual(CameraDrawerGroup.shown(document, pageCount: 0, torch: true), [.export, .colour, .quality, .flash, .camera])
        var jpeg: ScanSettings = document
        jpeg.format = .jpeg
        XCTAssertEqual(CameraDrawerGroup.shown(jpeg, pageCount: 0, torch: true), [.export, .colour, .flash, .camera])
        // Photos are saved from their review: nothing to export here.
        let photos: ScanSettings = TaskCatalog.apply(.photos, to: ScanSettings())
        XCTAssertEqual(CameraDrawerGroup.shown(photos, pageCount: 3, torch: true), [.colour, .flash, .camera])
        // Pages queued before Collect pages before saving went off keep their Export.
        var single: ScanSettings = document
        single.documentMultiPage = false
        XCTAssertEqual(CameraDrawerGroup.shown(single, pageCount: 0, torch: true), [.colour, .flash, .camera])
        XCTAssertEqual(CameraDrawerGroup.shown(single, pageCount: 2, torch: true), [.export, .colour, .flash, .camera])
        // A camera without a light (some iPads, the Simulator) has no Flash.
        XCTAssertEqual(CameraDrawerGroup.shown(document, pageCount: 0, torch: false), [.export, .colour, .quality, .camera])
        XCTAssertEqual(CameraDrawerGroup.flash.title, "Flash")
        for group in CameraDrawerGroup.allCases {
            XCTAssertFalse(group.title.isEmpty, group.rawValue)
            XCTAssertFalse(group.symbol.isEmpty, group.rawValue)
        }
    }

    func test_floatingSave_saysTheFormatAndThePages() {
        let document: ScanSettings = TaskCatalog.apply(.document, to: ScanSettings())
        let plan: SavePlan = SavePlan.make([flowPage(), flowPage(), flowPage()], options: document.document)
        XCTAssertEqual(IOSShell.floatingSaveTitle(document, plan: plan, target: nil), "Save PDF \u{00B7} 3")
        var word: ScanSettings = document
        word.format = .word
        XCTAssertEqual(IOSShell.floatingSaveTitle(word, plan: plan, target: nil), "Save Word \u{00B7} 3")
        var jpeg: ScanSettings = document
        jpeg.format = .jpeg
        XCTAssertEqual(IOSShell.floatingSaveTitle(jpeg, plan: plan, target: nil), "Save 3 JPEGs")
        let target = URL(fileURLWithPath: "/tmp/Contract.pdf")
        XCTAssertEqual(IOSShell.floatingSaveTitle(document, plan: plan, target: target), "Add to Contract.pdf")
    }

    func test_offersSave_whileCollecting_orWhileADocumentTaskHoldsPages() {
        let document: ScanSettings = TaskCatalog.apply(.document, to: ScanSettings())
        XCTAssertTrue(IOSShell.offersSave(document, pageCount: 0))
        XCTAssertTrue(IOSShell.offersSave(document, pageCount: 3))
        var single: ScanSettings = document
        single.documentMultiPage = false
        XCTAssertFalse(IOSShell.collectsPages(single))
        XCTAssertFalse(IOSShell.offersSave(single, pageCount: 0))
        XCTAssertTrue(IOSShell.offersSave(single, pageCount: 1))
        var word: ScanSettings = single
        word.format = .word
        XCTAssertTrue(IOSShell.offersSave(word, pageCount: 2), "Pages a failed Word save put back")
        for task in [ScanTask.photos, .receipt, .idCard] {
            let settings: ScanSettings = TaskCatalog.apply(task, to: ScanSettings())
            XCTAssertFalse(IOSShell.offersSave(settings, pageCount: 0), task.rawValue)
            XCTAssertFalse(IOSShell.offersSave(settings, pageCount: 2), task.rawValue)
        }
    }

    func test_onlyDocumentAndBook_takeThePagesAlong() {
        let carried: [IOSScanKind] = IOSScanKind.allCases.filter { (kind: IOSScanKind) -> Bool in
            TaskCatalog.carriesPages(kind.task)
        }
        XCTAssertEqual(carried, [.document, .book])
    }

    func test_keepPagesQuestion_countsThePages_andSavesAsSaveWould() {
        XCTAssertEqual(IOSShell.keepPagesTitle(3), "Keep the 3 pages?")
        XCTAssertEqual(IOSShell.keepPagesTitle(1), "Keep the page?")
        XCTAssertEqual(IOSShell.discardPagesLabel(3), "Discard 3 pages")
        XCTAssertEqual(IOSShell.discardPagesLabel(1), "Discard 1 page")
        XCTAssertEqual(IOSShell.keepPagesLine(IOSShell.keepPagesReason(.photos), count: 3, canSave: true),
                       "Photos does not collect pages. Save them first, or discard them.")
        XCTAssertEqual(IOSShell.keepPagesLine(IOSShell.keepPagesReason(.idCard), count: 1, canSave: true),
                       "ID card does not collect pages. Save it first, or discard it.")
        XCTAssertEqual(IOSShell.keepPagesLine(IOSShell.keepPagesReason(preset: "Till slips"), count: 2, canSave: true),
                       "The preset \u{201C}Till slips\u{201D} does not collect pages. Save them first, or discard them.")
        XCTAssertEqual(IOSShell.keepPagesLine(IOSShell.keepPagesReason(package: "Trip.csdoc"), count: 2, canSave: false),
                       "\u{201C}Trip.csdoc\u{201D} opens in their place. They cannot be saved now: discard them, or cancel to keep them.")
        XCTAssertEqual(IOSShell.keepPagesLine(IOSShell.keepPagesReason(.photos), count: 1, canSave: false),
                       "Photos does not collect pages. It cannot be saved now: discard it, or cancel to keep it.")
        let document: ScanSettings = TaskCatalog.apply(.document, to: ScanSettings())
        XCTAssertEqual(IOSShell.saveFirstLabel(document, pageCount: 3, target: nil), "Save PDF first")
        var jpeg: ScanSettings = document
        jpeg.format = .jpeg
        XCTAssertEqual(IOSShell.saveFirstLabel(jpeg, pageCount: 3, target: nil), "Save 3 JPEGs first")
        let target = URL(fileURLWithPath: "/tmp/Contract.pdf")
        XCTAssertEqual(IOSShell.saveFirstLabel(document, pageCount: 3, target: target), "Add to Contract.pdf first")
    }

    func test_colourGroup_picksTheFilterForNewPages_grayAndBWByTheColourMode() {
        let document: ScanSettings = TaskCatalog.apply(.document, to: ScanSettings())
        XCTAssertTrue(IOSShell.offersFilters(document))
        XCTAssertTrue(IOSShell.offersFilters(TaskCatalog.apply(.book, to: ScanSettings())))
        XCTAssertFalse(IOSShell.offersFilters(TaskCatalog.apply(.photos, to: ScanSettings())))
        XCTAssertFalse(IOSShell.offersFilters(TaskCatalog.apply(.receipt, to: ScanSettings())))
        XCTAssertEqual(IOSShell.drawerFilter(document), .enhanced)

        let original: ScanSettings = IOSShell.settingDrawerFilter(.original, in: document)
        XCTAssertEqual(original.colorMode, .color)
        XCTAssertEqual(original.taskOptions.cameraFilter, .original)
        XCTAssertEqual(IOSShell.drawerFilter(original), .original)
        XCTAssertNil(DocumentEnhancer.mode(for: original))

        let gray: ScanSettings = IOSShell.settingDrawerFilter(.grayscale, in: original)
        XCTAssertEqual(gray.colorMode, .grayscale)
        XCTAssertEqual(IOSShell.drawerFilter(gray), .grayscale)
        XCTAssertEqual(DocumentEnhancer.mode(for: gray), .gray)
        let bw: ScanSettings = IOSShell.settingDrawerFilter(.blackAndWhite, in: gray)
        XCTAssertEqual(bw.colorMode, .blackWhite)
        XCTAssertEqual(IOSShell.drawerFilter(bw), .blackAndWhite)
        // Back to colour: Enhanced is picked and stays.
        let enhanced: ScanSettings = IOSShell.settingDrawerFilter(.enhanced, in: bw)
        XCTAssertEqual(enhanced.colorMode, .color)
        XCTAssertEqual(enhanced.taskOptions.cameraFilter, .enhanced)
        XCTAssertEqual(DocumentEnhancer.mode(for: enhanced), .auto)
        XCTAssertEqual(enhanced.task, .document)
    }

    func test_pageViewer_namesThePage_andItsFilters() {
        XCTAssertEqual(PageViewerText.title(number: 3, count: 7), "3 of 7")
        XCTAssertEqual(PageViewerText.pageName(2), "Page 2")
        XCTAssertEqual(PageViewerText.selectedTitle(0), "Select Pages")
        XCTAssertEqual(PageViewerText.selectedTitle(2), "2 Selected")
        var names: [String] = []
        for filter in CaptureFilter.displayOrder {
            names.append(PageViewerText.filterName(filter))
        }
        XCTAssertEqual(names, ["Original", "Enhanced", "Grayscale", "Black and white"])
    }

    func test_deletingAPageInTheViewer_showsTheNextOne_orTheOneBeforeTheLast() {
        let a = UUID(), b = UUID(), c = UUID()
        XCTAssertEqual(PageViewer.pageAfterRemoving(a, from: [a, b, c]), b)
        XCTAssertEqual(PageViewer.pageAfterRemoving(b, from: [a, b, c]), c)
        XCTAssertEqual(PageViewer.pageAfterRemoving(c, from: [a, b, c]), b)
        XCTAssertNil(PageViewer.pageAfterRemoving(a, from: [a]))
        XCTAssertNil(PageViewer.pageAfterRemoving(UUID(), from: [a, b]))
    }
}
#endif
