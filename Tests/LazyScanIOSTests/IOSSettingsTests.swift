#if os(iOS)
import CoreGraphics
import Foundation
import SwiftUI
import XCTest
@testable import LazyScanIOS
@testable import LazyScanKit
import LazyScanModel

// The settings screen, the file name editor and the iPad's layout without a screen (I15): the sections
// built on the shared InspectorSections (each once, in order, with their summaries), which are open, the
// adjustments' sliders, the naming editor's parts, example and problems, the sidebar's width rule, the
// keyboard shortcuts, moving a page of the strip by dragging it, a dropped file, and the save folder (I3:
// a folder picked in Files kept as a bookmark, the app's folder moved with the container).

/// A page of the test's own, its own every time.
private func settingsPage() -> ScannedPage {
    let context: CGContext = ImportTestSupport.context(width: 30, height: 40)
    context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 30, height: 40))
    return ScannedPage(image: context.makeImage()!, dpi: 60, colorMode: .color)
}

final class IOSSettingsTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = try ImportTestSupport.makeFolder("settings")
    }

    override func tearDownWithError() throws {
        if let folder {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    // MARK: The sections

    func test_sections_areTheSharedOnes_eachOnce_inOrder_withTheirSummaries() {
        let s: ScanSettings = ScanSettings()
        let sections: [IOSSettingsSection] = IOSSettingsSections.sections(s)
        var ids: [String] = []
        for section in sections {
            ids.append(section.id)
            XCTAssertEqual(section.title, InspectorSections.title(section.id, for: s))
            XCTAssertEqual(section.summary, InspectorSections.summary(section.id, for: s), section.id)
            XCTAssertEqual(section.changed, InspectorSections.changed(section.id, for: s), section.id)
        }
        XCTAssertEqual(ids, InspectorSections.shown(s))
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertEqual(ids, ["scanner", "output", "adjustments", "pages", "split", "archive", "more"])
        XCTAssertEqual(sections[0].accessibilityLabel, "Scanner, Flatbed \u{00B7} 300 dpi \u{00B7} Color")
        XCTAssertEqual(sections[1].summary, "PDF \u{00B7} Standard")
        XCTAssertEqual(sections[3].accessibilityLabel, "Pages")

        var protected: ScanSettings = ScanSettings()
        protected.output.protect = true
        var archiveLocked: Bool = false
        for section in IOSSettingsSections.sections(protected) where section.id == InspectorSections.archive {
            archiveLocked = section.locked
            XCTAssertEqual(section.summary, "Password on")
        }
        XCTAssertTrue(archiveLocked)
    }

    func test_sections_inCameraMode_haveNoScanner_andPagesCountsWhatRunsOnTheCamerasPages() {
        var ids: [String] = []
        for section in IOSSettingsSections.sections(ScanSettings(), camera: true) {
            ids.append(section.id)
        }
        XCTAssertEqual(ids, ["output", "adjustments", "pages", "split", "archive", "more"])

        // The camera's pages are cut along their corners already: never cropped or straightened.
        var cut: ScanSettings = ScanSettings()
        cut.document.autoCrop = true
        cut.document.autoStraighten = true
        let camera: IOSSettingsSection? = pagesSection(cut, camera: true)
        XCTAssertEqual(camera?.summary, "")
        XCTAssertEqual(camera?.changed, false)
        XCTAssertEqual(camera?.accessibilityLabel, "Pages")
        let printer: IOSSettingsSection? = pagesSection(cut, camera: false)
        XCTAssertEqual(printer?.summary, "Crop \u{00B7} Straighten")
        XCTAssertEqual(printer?.changed, true)
        XCTAssertEqual(printer?.accessibilityLabel, "Pages, 2 options on")

        // Facing pages are split only from spreads taken whole (the Book kind's Whole spread).
        var book: ScanSettings = TaskCatalog.apply(.book, to: ScanSettings())
        XCTAssertEqual(pagesSection(book, camera: false)?.summary, "Straighten \u{00B7} Upright +1")
        XCTAssertEqual(pagesSection(book, camera: true)?.summary, "Upright")
        book.taskOptions.cameraSpreads = true
        XCTAssertEqual(pagesSection(book, camera: true)?.summary, "Upright \u{00B7} Facing pages")
        XCTAssertEqual(pagesSection(book, camera: true)?.accessibilityLabel, "Pages, 2 options on")
    }

    func test_sections_aQueueSavedAsPictures_writesNoPDF_soArchiveIsHidden() {
        var pictures: ScanSettings = ScanSettings()
        pictures.format = .jpeg
        pictures.output.alsoSaveText = true
        XCTAssertTrue(InspectorSections.shown(pictures).contains(InspectorSections.archive), "The desktop saves a PDF")
        XCTAssertFalse(IOSSettingsSections.writesPDF(pictures))
        XCTAssertFalse(IOSSettingsSections.textApplies(pictures))
        var ids: [String] = []
        var more: String?
        for section in IOSSettingsSections.sections(pictures) {
            ids.append(section.id)
            if section.id == InspectorSections.more { more = section.summary }
        }
        XCTAssertEqual(ids, ["scanner", "output", "adjustments", "pages", "split", "more"])
        XCTAssertEqual(more, "")

        var receipts: ScanSettings = TaskCatalog.apply(.receipt, to: ScanSettings())
        receipts.format = .pdf
        let receiptSections: [IOSSettingsSection] = IOSSettingsSections.sections(receipts)
        XCTAssertEqual(receiptSections.first?.id, InspectorSections.task)
        XCTAssertEqual(receiptSections.first?.title, "Receipts")

        var photos: ScanSettings = ScanSettings()
        photos.intent = .photo
        var titles: [String] = []
        for section in IOSSettingsSections.sections(photos) {
            titles.append(section.title)
        }
        XCTAssertEqual(titles, ["Scanner", "Photos", "Adjustments", "More options"])
    }

    func test_sections_moreOptions_leavesOutTheActionAfterSaving_whichExportSets() {
        var s: ScanSettings = ScanSettings()
        s.output.afterSave = .reveal
        XCTAssertEqual(InspectorSections.summary(InspectorSections.more, for: s), "Show in folder after saving",
                       "The desktop's names it")
        var more: IOSSettingsSection?
        for section in IOSSettingsSections.sections(s) where section.id == InspectorSections.more {
            more = section
        }
        XCTAssertEqual(more?.summary, "")
        XCTAssertEqual(more?.changed, false)
        XCTAssertEqual(more?.accessibilityLabel, "More options")

        s.output.alsoSaveText = true
        var withText: IOSSettingsSection?
        for section in IOSSettingsSections.sections(s) where section.id == InspectorSections.more {
            withText = section
        }
        XCTAssertEqual(withText?.summary, ".txt")
        XCTAssertEqual(withText?.changed, true)
    }

    func test_output_showsTheFormatSaved_aPictureForText_aPDFForAnIdCardInWord() {
        // The Text kind's screen saves its page as a picture whatever format was picked before.
        var text: ScanSettings = TaskCatalog.apply(.quickScan, to: ScanSettings())
        text.format = .pdf
        XCTAssertEqual(InspectorSections.shownFormat(text), .pdf, "The desktop saves the format chosen")
        XCTAssertEqual(IOSSettingsSections.shownFormat(text), .jpeg)
        XCTAssertFalse(IOSSettingsSections.writesPDF(text))
        XCTAssertFalse(IOSSettingsSections.textApplies(text))
        var ids: [String] = []
        var output: String?
        for section in IOSSettingsSections.sections(text) {
            ids.append(section.id)
            if section.id == InspectorSections.output { output = section.summary }
        }
        XCTAssertFalse(ids.contains(InspectorSections.archive))
        XCTAssertEqual(output, "JPEG")

        // With Collect pages on, its pages go to the queue and are saved in the format picked.
        text.documentMultiPage = true
        XCTAssertEqual(IOSSettingsSections.shownFormat(text), .pdf)
        XCTAssertTrue(IOSSettingsSections.writesPDF(text))
        XCTAssertTrue(IOSSettingsSections.textApplies(text))

        var idCard: ScanSettings = TaskCatalog.apply(.idCard, to: ScanSettings())
        idCard.format = .word
        XCTAssertEqual(InspectorSections.shownFormat(idCard), .pdf)
        XCTAssertEqual(IOSSettingsSections.shownFormat(idCard), .pdf)
        var cardIds: [String] = []
        var cardOutput: String?
        for section in IOSSettingsSections.sections(idCard) {
            cardIds.append(section.id)
            if section.id == InspectorSections.output { cardOutput = section.summary }
        }
        XCTAssertEqual(cardIds, ["scanner", "output", "adjustments", "archive", "more"])
        XCTAssertEqual(cardOutput, "PDF \u{00B7} Standard")
    }

    func test_openSections_keptAsText_theTaskScannerAndOutputOpenAtFirst() {
        XCTAssertEqual(IOSSettingsSections.defaultText, "task,scanner,output")
        XCTAssertEqual(IOSSettingsSections.open("scanner,bogus,more"), Set<String>(["scanner", "more"]))
        XCTAssertEqual(IOSSettingsSections.open(""), Set<String>())
        XCTAssertEqual(IOSSettingsSections.text(Set<String>(["more", "scanner"])), "scanner,more")
        let stored: Set<String> = IOSSettingsSections.open(IOSSettingsSections.defaultText)
        XCTAssertTrue(IOSSettingsSections.isOpen("scanner", stored: stored, openedByTask: []))
        XCTAssertFalse(IOSSettingsSections.isOpen("pages", stored: stored, openedByTask: []))
        XCTAssertTrue(IOSSettingsSections.isOpen("pages", stored: stored, openedByTask: ["pages"]))
    }

    func test_adjustments_mapTheSlidersOntoTheSettings() {
        let neutral: AdjustmentSettings = AdjustmentSettings()
        for adjustment in IOSAdjustment.allCases {
            XCTAssertEqual(adjustment.amount(neutral), 0, accuracy: 1e-9, adjustment.label)
            let changed: AdjustmentSettings = adjustment.setting(37, in: neutral)
            XCTAssertEqual(adjustment.amount(changed), 37, accuracy: 1e-9, adjustment.label)
        }
        XCTAssertEqual(IOSAdjustment.brightness.setting(100, in: neutral).brightness, 1, accuracy: 1e-9)
        XCTAssertEqual(IOSAdjustment.contrast.setting(100, in: neutral).contrast, 4, accuracy: 1e-9)
        XCTAssertEqual(IOSAdjustment.contrast.setting(-100, in: neutral).contrast, 0.25, accuracy: 1e-9)
        XCTAssertEqual(IOSAdjustment.saturation.setting(-100, in: neutral).saturation, 0, accuracy: 1e-9)
        XCTAssertEqual(IOSAdjustment.sharpness.setting(100, in: neutral).sharpness, 2, accuracy: 1e-9)
        XCTAssertEqual(IOSAdjustment.amountText(12.4), "+12")
        XCTAssertEqual(IOSAdjustment.amountText(-5), "-5")
        XCTAssertEqual(IOSAdjustment.amountText(0.3), "0")

        var edited: AdjustmentSettings = IOSAdjustment.brightness.setting(40, in: neutral)
        edited.descreen = true
        XCTAssertFalse(IOSAdjustment.isNeutral(edited))
        let reset: AdjustmentSettings = IOSAdjustment.neutral(edited)
        XCTAssertTrue(IOSAdjustment.isNeutral(reset))
        XCTAssertTrue(reset.descreen, "Reset puts the sliders back, not the switches")
    }

    func test_scannerRows_needASelectedScanner_andListTheSourceChosen() {
        XCTAssertEqual(IOSSettingsSections.scannerRowsReason(selected: nil), IOSSettingsText.noScannerReason)
        // Shown in printer mode, which the app never names.
        XCTAssertFalse(IOSSettingsText.noScannerReason.contains("printer mode"))
        XCTAssertNil(IOSSettingsSections.scannerRowsReason(selected: "escl:office"))
        // Both sides set up for the camera chose the feeder before the scanner's sources are known.
        XCTAssertEqual(IOSSettingsSections.offeredSources(nil, chosen: .documentFeeder), [.flatbed, .documentFeeder])
        XCTAssertEqual(IOSSettingsSections.offeredSources(nil, chosen: .flatbed), [.flatbed])
        let both = ScannerCapabilities(sources: [.flatbed, .documentFeeder])
        XCTAssertEqual(IOSSettingsSections.offeredSources(both, chosen: .documentFeeder), [.flatbed, .documentFeeder])
        // The lock's reason speaks of the phone, which has no Document mode.
        XCTAssertFalse(IOSSettingsText.idCardHeldReason.contains("Document mode"))
    }

    func test_scannerRows_lockTheSource_underIdCardBookAndText_andWhileACardIsHeld() {
        let sources: [ScanSource] = [.flatbed, .documentFeeder]
        XCTAssertEqual(IOSSettingsSections.sourceLockReason(task: .idCard, cardHeld: false, sources: sources),
                       "ID card is scanned on the flatbed. Pick Document to use the feeder.")
        XCTAssertEqual(IOSSettingsSections.sourceLockReason(task: .book, cardHeld: false, sources: sources),
                       "Book is scanned on the flatbed. Pick Document to use the feeder.")
        // Quick scan is the Text kind on the phone.
        XCTAssertEqual(IOSSettingsSections.sourceLockReason(task: .quickScan, cardHeld: false, sources: sources),
                       "Text is scanned on the flatbed. Pick Document to use the feeder.")
        // Document and Both sides leave it free, as do settings without a task.
        XCTAssertNil(IOSSettingsSections.sourceLockReason(task: .document, cardHeld: false, sources: sources))
        XCTAssertNil(IOSSettingsSections.sourceLockReason(task: .twoSided, cardHeld: false, sources: sources))
        XCTAssertNil(IOSSettingsSections.sourceLockReason(task: nil, cardHeld: false, sources: sources))
        // So does a scanner with only a flatbed, or one whose sources are not known yet: no feeder to pick.
        XCTAssertNil(IOSSettingsSections.sourceLockReason(task: .idCard, cardHeld: false, sources: [.flatbed]))
        let tasks: [ScanTask?] = [.idCard, .document, nil]
        for task in tasks {
            XCTAssertEqual(IOSSettingsSections.sourceLockReason(task: task, cardHeld: true, sources: sources),
                           IOSSettingsText.idCardHeldReason)
            XCTAssertEqual(IOSSettingsSections.sourceLockReason(task: task, cardHeld: true, sources: [.flatbed]),
                           IOSSettingsText.idCardHeldReason)
        }
    }

    func test_version_fromTheAppsInfo() {
        let info: [String: Any] = ["CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "7"]
        XCTAssertEqual(IOSSettingsText.version(info), "Version 0.1.0 (7)")
        let noBuild: [String: Any] = ["CFBundleShortVersionString": "0.1.0"]
        XCTAssertEqual(IOSSettingsText.version(noBuild), "Version 0.1.0")
        XCTAssertEqual(IOSSettingsText.version(nil), "Version ?")
    }

    func test_licences_theTextsGoWithTheApp() {
        XCTAssertTrue(FastViTCornerModel.licence("DocAligner-LICENSE")?.contains("Apache License") == true)
        XCTAssertTrue(FastViTCornerModel.licence("ONNXRuntime-LICENSE")?.contains("MIT License") == true)
        XCTAssertNil(FastViTCornerModel.licence("Nowhere-LICENSE"))
    }

    // MARK: After saving

    func test_afterSave_runsTheCheckedActionsInOrder_sendingOnlyWhilePaired() throws {
        let suite: String = "IOSSettingsTests.afterSave"
        let defaults: UserDefaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(IOSAfterSave.steps(defaults, paired: true), [], "Nothing checked at first")
        for action in IOSAfterSave.rows {
            defaults.set(true, forKey: action.key)
        }
        XCTAssertEqual(IOSAfterSave.steps(defaults, paired: true), [.send, .print, .email])
        XCTAssertEqual(IOSAfterSave.steps(defaults, paired: false), [.print, .email], "No computer: skipped")
        defaults.set(false, forKey: IOSAfterSave.print.key)
        XCTAssertEqual(IOSAfterSave.steps(defaults, paired: true), [.send, .email])
        XCTAssertEqual(IOSAfterSave.rows.map { (action: IOSAfterSave) -> String in action.label },
                       ["Email", "Print", "Send to computer"])
    }

    func test_afterSave_saysWhenSendToPCsPagesWait() {
        let reason: String = CompanionText.notOnNetworkReason("Office PC")
        XCTAssertEqual(IOSAfterSave.notSentMessage(.unreachable(reason: reason), waiting: 1),
                       "Office PC is not on this network. The pages wait on this phone and are sent once it answers.")
        XCTAssertEqual(IOSAfterSave.notSentMessage(.unreachable(reason: reason), waiting: 1, inFolder: 1),
                       "Office PC is not on this network. The document is in the cloud folder; the computer takes it from there.")
        XCTAssertEqual(IOSAfterSave.notSentMessage(.unreachable(reason: reason), waiting: 2, inFolder: 1),
                       "Office PC is not on this network. The pages wait on this phone and are sent once it answers.",
                       "One of them waits on this phone")
        XCTAssertEqual(IOSAfterSave.notSentMessage(.unpaired(byDesktop: "Office PC"), waiting: 2),
                       "This phone is no longer paired with Office PC. The pages were not sent.")
        XCTAssertNil(IOSAfterSave.notSentMessage(.reachable(desktopName: "Office PC", queuedPages: 0), waiting: 1),
                     "The computer answered: what waits is on its way")
        XCTAssertNil(IOSAfterSave.notSentMessage(.unreachable(reason: reason), waiting: 0), "Nothing waits")
    }

    func test_afterSave_thenOffersTheKitsActions_inThePhonesWords() {
        XCTAssertEqual(IOSAfterSave.thenTitle, "Then")
        XCTAssertEqual(IOSAfterSave.emailInsteadReason, "Email is sent instead")
        var labels: [String] = []
        for action in AfterSaveAction.allCases {
            labels.append(IOSAfterSave.thenLabel(action))
        }
        XCTAssertEqual(labels, ["Do nothing", "Open", "Show in Files", "Share\u{2026}"])
        XCTAssertEqual(IOSAfterSave.thenLabel(.reveal), IOSSavedFiles.revealLabel)
        XCTAssertEqual(AfterSaveAction.reveal.label, "Show in folder", "The desktop's words stay")
        XCTAssertEqual(IOSAfterSave.thenHint(.open), "Open the file (several: show them in Files)")
        XCTAssertEqual(IOSAfterSave.thenHint(.reveal), "Show the files in the Files app")
        XCTAssertEqual(IOSAfterSave.thenHint(.share), AfterSaveAction.share.hint)
        XCTAssertEqual(IOSAfterSave.thenHint(AfterSaveAction.none), "Stay here")
    }

    // MARK: The file name

    @MainActor
    func test_namingEditor_putsTheTemplateInUse_showsTheNextName_andWhatIsWrong() {
        let state: AppState = ImportTestSupport.makeState(in: folder)
        let model: IOSNamingModel = IOSNamingModel(state: state)
        XCTAssertEqual(model.text, state.settings.namingTemplate)
        XCTAssertEqual(model.parts.count, 7)
        // The phone has no page strip to name a document in: its name comes from a QR sheet.
        let documentName: NamingToken? = model.parts.first(where: { (part: NamingToken) -> Bool in part.token == "{label}" })
        XCTAssertEqual(documentName?.help, "The document\u{2019}s name from its QR sheet")
        XCTAssertNil(model.problem)

        model.setText("Invoice {date}")
        XCTAssertEqual(state.settings.namingTemplate, "Invoice {date}")
        XCTAssertNil(model.problem)
        XCTAssertTrue(model.example.hasPrefix("Invoice "), model.example)
        XCTAssertTrue(model.example.hasSuffix(".pdf"), model.example)

        model.setText("   ")
        XCTAssertEqual(model.problem, NamingTokens.emptyProblem)
        XCTAssertEqual(state.settings.namingTemplate, "Invoice {date}", "A blank name keeps the last one in use")

        model.setText("Invoice {foo}")
        XCTAssertEqual(model.problem, "Unknown part {foo}")
        XCTAssertEqual(state.settings.namingTemplate, "Invoice {foo}")

        model.insert("{counter}")
        XCTAssertEqual(model.text, "Invoice {foo} {counter}")
        XCTAssertEqual(state.settings.namingTemplate, "Invoice {foo} {counter}")

        // The scan screen saves a picture a page as JPEGs.
        state.settings.format = .jpeg
        XCTAssertEqual(model.format, OutputFormat.jpeg)
        XCTAssertTrue(model.example.hasSuffix(".jpg"), model.example)

        model.reset()
        XCTAssertEqual(model.text, "Scan {date} {counter}")
        XCTAssertEqual(state.settings.namingTemplate, "Scan {date} {counter}")
    }

    // MARK: The iPad

    func test_layout_theSidebar_onlyOnARegularWidthOnAnIPad() {
        XCTAssertTrue(IOSLayout.usesSidebar(UserInterfaceSizeClass.regular, pad: true))
        XCTAssertFalse(IOSLayout.usesSidebar(UserInterfaceSizeClass.compact, pad: true))
        XCTAssertFalse(IOSLayout.usesSidebar(nil, pad: true))
        // A large iPhone turned sideways is regular too, and keeps the phone's layout.
        XCTAssertFalse(IOSLayout.usesSidebar(UserInterfaceSizeClass.regular, pad: false))
    }

    @MainActor
    func test_shortcuts_saveNewDocumentSettingsAndTheShutter() {
        XCTAssertEqual(IOSShortcuts.save.key, "s")
        XCTAssertTrue(IOSShortcuts.save.command)
        XCTAssertEqual(IOSShortcuts.newDocument.key, "n")
        XCTAssertTrue(IOSShortcuts.newDocument.command)
        XCTAssertEqual(IOSShortcuts.settings.key, ",")
        XCTAssertTrue(IOSShortcuts.settings.command)
        XCTAssertEqual(IOSShortcuts.shutter.key, " ")
        XCTAssertFalse(IOSShortcuts.shutter.command)
        var seen: Set<String> = []
        for shortcut in IOSShortcuts.all {
            XCTAssertFalse(shortcut.title.isEmpty)
            seen.insert("\(shortcut.command)-\(shortcut.key)")
        }
        XCTAssertEqual(seen.count, IOSShortcuts.all.count, "No two actions share a key")
        XCTAssertEqual(IOSShortcuts.save.keyboardShortcut.modifiers, EventModifiers.command)
        XCTAssertEqual(IOSShortcuts.shutter.keyboardShortcut.modifiers, EventModifiers())
    }

    @MainActor
    func test_pageDrop_aPageDraggedOntoAnother_takesItsPlace() {
        let state: AppState = ImportTestSupport.makeState(in: folder)
        let pages: [ScannedPage] = [settingsPage(), settingsPage(), settingsPage(), settingsPage()]
        let a: UUID = pages[0].id
        let b: UUID = pages[1].id
        let c: UUID = pages[2].id
        let d: UUID = pages[3].id
        XCTAssertEqual(IOSPageDrop.offset(moving: a, onto: c, in: [a, b, c, d]), 2)
        XCTAssertEqual(IOSPageDrop.offset(moving: d, onto: b, in: [a, b, c, d]), -2)
        XCTAssertNil(IOSPageDrop.offset(moving: a, onto: a, in: [a, b, c, d]))
        XCTAssertNil(IOSPageDrop.offset(moving: UUID(), onto: a, in: [a, b, c, d]))
        XCTAssertEqual(IOSPageDrop.pageID(a.uuidString), a)
        XCTAssertNil(IOSPageDrop.pageID("not a page"))

        state.scannedPages = pages
        XCTAssertTrue(IOSPageDrop.move(a, onto: c, in: state))
        XCTAssertEqual(order(state), [b, c, a, d])
        XCTAssertTrue(IOSPageDrop.move(d, onto: b, in: state))
        XCTAssertEqual(order(state), [d, b, c, a])
        XCTAssertFalse(IOSPageDrop.move(c, onto: c, in: state))
        XCTAssertFalse(IOSPageDrop.move(UUID(), onto: c, in: state))
        XCTAssertEqual(order(state), [d, b, c, a])
    }

    @MainActor
    func test_pageSelection_movesThePagesPicked_keepingTheirOrder() {
        let state: AppState = ImportTestSupport.makeState(in: folder)
        let pages: [ScannedPage] = [settingsPage(), settingsPage(), settingsPage(), settingsPage(), settingsPage()]
        let a: UUID = pages[0].id
        let b: UUID = pages[1].id
        let c: UUID = pages[2].id
        let d: UUID = pages[3].id
        let e: UUID = pages[4].id
        XCTAssertEqual(IOSPageSelection.ordered([e, b, d], in: pages), [b, d, e])

        state.scannedPages = pages
        IOSPageSelection.move([d, b], toStart: true, in: state)
        XCTAssertEqual(order(state), [b, d, a, c, e])
        IOSPageSelection.move([b, a], toStart: false, in: state)
        XCTAssertEqual(order(state), [d, c, e, b, a])
        IOSPageSelection.move([d, c], toStart: true, in: state)
        XCTAssertEqual(order(state), [d, c, e, b, a])
    }

    func test_pageSelection_writesThePagesPicked_namedByTheirNumber() async throws {
        let pages: [ScannedPage] = [settingsPage(), settingsPage(), settingsPage()]
        let urls: [URL] = try await IOSPageSelection.writeImages([pages[2].id, pages[0].id], of: pages, format: .jpeg,
                                                                 jpegQuality: 0.9)
        XCTAssertEqual(urls.map(\.lastPathComponent), ["Page 1.jpg", "Page 3.jpg"])
        for url in urls {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), url.lastPathComponent)
        }
    }

    func test_droppedFiles_comeInByTheirKind() {
        let pdf: IOSImportItem = IOSDroppedFile(data: Data("%PDF-1.4".utf8), kind: .pdf).item
        XCTAssertEqual(pdf.kind, IOSImportItem.Kind.pdf)
        XCTAssertEqual(pdf.name, "Dropped PDF")
        let picture: IOSImportItem = IOSDroppedFile(data: Data([0x89, 0x50]), kind: .image).item
        XCTAssertEqual(picture.kind, IOSImportItem.Kind.image)
        XCTAssertEqual(picture.name, "Dropped picture")
    }

    // MARK: The save folder

    @MainActor
    func test_saveFolder_aBookmarkThatDoesNotOpenNow_isKept_andTheSaveGoesToTheAppsFolder() throws {
        let state: AppState = ImportTestSupport.makeState(in: folder)
        state.resolveDestinationBookmark = { (bookmark: Data) -> (folder: URL, bookmark: Data)? in
            IOSSaveFolder.resolve(bookmark)
        }
        let unplugged: String = folder.appendingPathComponent("Unplugged", isDirectory: true).path
        state.settings.destinationBookmark = Data("not a bookmark".utf8)
        state.settings.destinationPath = unplugged
        XCTAssertNil(state.openBookmarkedFolder())
        XCTAssertEqual(state.settings.destinationBookmark, Data("not a bookmark".utf8))
        XCTAssertEqual(state.settings.destinationPath, unplugged)
        XCTAssertNil(state.errorMessage)

        XCTAssertEqual(try state.destinationDirectory().path, ScanSettings.defaultDestinationPath)
        XCTAssertEqual(state.errorMessage,
                       "The save folder could not be opened, so this save went to the app's folder.")
        XCTAssertEqual(state.settings.destinationBookmark, Data("not a bookmark".utf8))
        XCTAssertEqual(state.settings.destinationPath, unplugged)
        XCTAssertEqual(IOSSavedFiles.folder(state.settings).path, unplugged)
        // The list shows where that save went, not the folder nobody can reach.
        XCTAssertEqual(IOSSavedFiles.shownFolder(state.settings).path, ScanSettings.defaultDestinationPath)
    }

    @MainActor
    func test_saveFolder_aPickedFolder_isBookmarked_andSavesGoThere() throws {
        let picked: URL = folder.appendingPathComponent("Picked", isDirectory: true)
        try FileManager.default.createDirectory(at: picked, withIntermediateDirectories: true)
        let state: AppState = ImportTestSupport.makeState(in: folder)
        state.resolveDestinationBookmark = { (bookmark: Data) -> (folder: URL, bookmark: Data)? in
            IOSSaveFolder.resolve(bookmark)
        }
        state.settings = try IOSSaveFolder.choosing(picked, in: state.settings)
        XCTAssertNotNil(state.settings.destinationBookmark)
        XCTAssertEqual(state.settings.destinationPath, picked.path)
        guard let opened = state.openBookmarkedFolder() else {
            throw XCTSkip("A bookmark of a temporary folder does not resolve here.")
        }
        XCTAssertEqual(opened.resolvingSymlinksInPath().path, picked.resolvingSymlinksInPath().path)
        XCTAssertEqual(try state.destinationDirectory().resolvingSymlinksInPath().path,
                       picked.resolvingSymlinksInPath().path)
        XCTAssertNotNil(state.settings.destinationBookmark)

        let back: ScanSettings = IOSSaveFolder.appFolder(state.settings)
        XCTAssertNil(back.destinationBookmark)
        XCTAssertEqual(back.destinationPath, ScanSettings.defaultDestinationPath)
    }

    @MainActor
    func test_saveFolder_words_theAppsFolderOfAnEarlierInstall_andShowInFiles() throws {
        XCTAssertEqual(IOSSettingsText.saveToLabel, "Save to")
        XCTAssertEqual(IOSSettingsText.chooseFolderLabel, "Choose\u{2026}")
        XCTAssertEqual(IOSSettingsText.appFolderLabel, "Use app folder")

        let documents: URL = try XCTUnwrap(IOSShell.documentsFolder)
        var settings: ScanSettings = ScanSettings()
        settings.destinationPath =
            "/var/mobile/Containers/Data/Application/7A1F2E3D-4C5B-4A69-8778-96A5B4C3D2E1/Documents/Lazy Scan"
        XCTAssertEqual(IOSSavedFiles.folder(settings).path, documents.appendingPathComponent("Lazy Scan").path)
        let otherApp: String =
            "/private/var/mobile/Containers/Data/Application/0B9C8D7E-6F5A-4B3C-9D2E-1F0A9B8C7D6E/Documents/Scans"
        settings.destinationPath = otherApp
        settings.destinationBookmark = Data("picked".utf8)
        XCTAssertEqual(IOSSavedFiles.folder(settings).path, otherApp)
        let actions = IOSFileActions(pasteboard: nil, openSystemURL: { (_: URL) -> Void in })
        let made: AppState = AppState.makeForIOS(options: IOSLaunchOptions(demoScannerOnly: true), fileActions: actions)
        XCTAssertEqual(made.documentsFolder, documents)
        XCTAssertNotNil(made.resolveDestinationBookmark)

        let iCloud = URL(fileURLWithPath: "/private/var/mobile/Library/Mobile Documents/com~apple~CloudDocs/Scans",
                         isDirectory: true)
        XCTAssertEqual(IOSFileActions.filesAppURL(for: [iCloud])?.absoluteString,
                       "shareddocuments:///private/var/mobile/Library/Mobile%20Documents/com~apple~CloudDocs/Scans/")
    }

    private func pagesSection(_ s: ScanSettings, camera: Bool) -> IOSSettingsSection? {
        var pages: IOSSettingsSection?
        for section in IOSSettingsSections.sections(s, camera: camera) where section.id == InspectorSections.pages {
            pages = section
        }
        return pages
    }

    @MainActor
    private func order(_ state: AppState) -> [UUID] {
        var ids: [UUID] = []
        for page in state.scannedPages {
            ids.append(page.id)
        }
        return ids
    }
}
#endif
