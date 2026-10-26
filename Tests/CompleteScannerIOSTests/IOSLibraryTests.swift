#if os(iOS)
import CoreGraphics
import Foundation
import UniformTypeIdentifiers
import XCTest
@testable import CompleteScannerIOS
@testable import CompleteScannerKit

// The presets, the scans of this session and the saved files without a screen (I15): presets saved,
// renamed, applied and deleted through presets.json in a folder of the test's own; the history's rows;
// the save folder listed newest first with the last save marked, and its files' actions.

/// Whether a closure ran.
@MainActor
private final class LibraryFlag {
    var value: Bool = false
}

/// The addresses the file actions asked the system to open.
@MainActor
private final class LibraryOpened {
    var urls: [URL] = []
}

/// A photo of a sheet on a table, for an import that waits on the corner editor.
private func librarySheetPNG() -> Data {
    let corners: [CGPoint] = [CGPoint(x: 150, y: 80), CGPoint(x: 350, y: 80), CGPoint(x: 350, y: 363),
                              CGPoint(x: 150, y: 363)]
    let photo: CGImage = ImportTestSupport.sheetPhoto(width: 600, height: 450, corners: corners)
    return ImportTestSupport.file(UTType.png, images: [photo])
}

/// A page search that is never sure, so each photo waits on the corner editor.
private func unsureFinder() -> @Sendable (RgbaImage) -> IOSFoundPage {
    let corners = Quad(topLeft: CGPoint(x: 150, y: 80), topRight: CGPoint(x: 350, y: 80),
                       bottomRight: CGPoint(x: 350, y: 363), bottomLeft: CGPoint(x: 150, y: 363))
    let found = IOSFoundPage(corners: corners, reason: .unsure, byVision: false)
    return { (_: RgbaImage) -> IOSFoundPage in
        found
    }
}

/// A small picture of the test's own.
private func libraryPicture(width: Int, height: Int) -> CGImage {
    let context: CGContext = ImportTestSupport.context(width: width, height: height)
    context.setFillColor(CGColor(srgbRed: 0.9, green: 0.9, blue: 0.85, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
}

final class IOSLibraryTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = try ImportTestSupport.makeFolder("library")
    }

    override func tearDownWithError() throws {
        if let folder {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    // MARK: Presets

    @MainActor
    func test_presets_savedRenamedAppliedAndDeleted_throughPresetsJSON() throws {
        let state: AppState = ImportTestSupport.makeState(in: folder)
        let model: IOSPresetsModel = IOSPresetsModel(state: state, importer: IOSImportSession(state: state))
        XCTAssertTrue(model.rows.isEmpty, "A first run has no presets")
        XCTAssertFalse(model.save(named: "   "))
        XCTAssertTrue(state.presets.isEmpty)

        var receipts: ScanSettings = TaskCatalog.apply(.receipt, to: state.settings)
        receipts.resolution = 600
        state.settings = receipts
        XCTAssertTrue(model.save(named: "  Receipts 600 "))
        let rows: [IOSPresetRow] = model.rows
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].name, "Receipts 600")
        XCTAssertEqual(rows[0].taskTitle, TaskCatalog.definition(.receipt).title)
        XCTAssertEqual(rows[0].summary, TaskCatalog.summary(receipts))
        XCTAssertEqual(rows[0].symbol, IOSShell.systemImage(TaskCatalog.definition(.receipt).iconKey))
        XCTAssertEqual(rows[0].accessibilityLabel, "Receipts 600 preset")
        let id: UUID = rows[0].id

        var stored: [Preset] = PresetStore(directory: folder).load()
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored[0].name, "Receipts 600")
        XCTAssertEqual(stored[0].settings.resolution, 600)

        XCTAssertFalse(model.rename(id, to: "  "))
        XCTAssertFalse(model.rename(UUID(), to: "Nobody"))
        XCTAssertTrue(model.rename(id, to: " Till slips "))
        stored = PresetStore(directory: folder).load()
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored[0].name, "Till slips")
        XCTAssertEqual(stored[0].id, id)

        var plain: ScanSettings = state.settings
        plain.taskId = nil
        plain.resolution = 150
        state.settings = plain
        // A PDF picked on the start screen is forgotten: the preset's pages are not added to it.
        state.setAppendTarget(folder.appendingPathComponent("Contract.pdf"))
        let applied: LibraryFlag = LibraryFlag()
        let outcome: IOSPresetApply = model.apply(id) {
            applied.value = true
        }
        XCTAssertEqual(outcome, IOSPresetApply.applied)
        XCTAssertTrue(applied.value)
        XCTAssertEqual(state.settings.resolution, 600)
        XCTAssertEqual(state.activeTask, ScanTask.receipt)
        XCTAssertNil(state.appendTarget)
        XCTAssertTrue(state.statusMessage.contains("Till slips"), state.statusMessage)
        let missing: IOSPresetApply = model.apply(UUID()) {}
        XCTAssertEqual(missing, IOSPresetApply.refused)

        model.delete(id)
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertTrue(PresetStore(directory: folder).load().isEmpty)
    }

    @MainActor
    func test_aPresetTurnedOverByHand_takesBothSides_withNoScanner() throws {
        let state: AppState = ImportTestSupport.makeState(in: folder)
        let model: IOSPresetsModel = IOSPresetsModel(state: state, importer: IOSImportSession(state: state))
        var feeder: ScanSettings = TaskCatalog.apply(.document, to: state.settings)
        feeder.source = .documentFeeder
        feeder.duplex = .manual
        state.settings = feeder
        XCTAssertTrue(model.save(named: "Stack by hand"))
        let id: UUID = try XCTUnwrap(model.rows.first?.id)
        state.settings = TaskCatalog.apply(.document, to: state.settings)
        XCTAssertNil(state.selectedDeviceID)

        XCTAssertEqual(model.apply(id) {}, IOSPresetApply.applied)
        XCTAssertEqual(state.settings.source, .documentFeeder)
        XCTAssertEqual(state.settings.duplex, .both)
        XCTAssertFalse(state.isTurningOverByHand)
        XCTAssertTrue(state.canIngest)
    }

    @MainActor
    func test_presets_notAppliedWhileAnImportRuns() async throws {
        let state: AppState = ImportTestSupport.makeState(in: folder)
        let importer: IOSImportSession = IOSImportSession(state: state, finder: unsureFinder())
        let model: IOSPresetsModel = IOSPresetsModel(state: state, importer: importer)
        var fine: ScanSettings = state.settings
        fine.resolution = 600
        state.settings = fine
        XCTAssertTrue(model.save(named: "Fine"))
        let id: UUID = try XCTUnwrap(model.rows.first?.id)
        var plain: ScanSettings = state.settings
        plain.resolution = 150
        state.settings = plain

        let item = IOSImportItem(name: "sheet.png", data: librarySheetPNG(), kind: .image)
        let importing: Task<IOSImportOutcome, Never> = Task { @MainActor in
            await importer.importItems([item])
        }
        try await ImportTestSupport.waitUntil(timeout: 60) { importer.cornerRequest != nil }
        XCTAssertTrue(importer.isImporting)
        let applied: LibraryFlag = LibraryFlag()
        let during: IOSPresetApply = model.apply(id) {
            applied.value = true
        }
        XCTAssertEqual(during, IOSPresetApply.refused)
        XCTAssertFalse(applied.value)
        XCTAssertEqual(state.settings.resolution, 150)

        importer.answer(PhotoCornersAnswer.skip)
        _ = await importing.value
        XCTAssertFalse(importer.isImporting)
        let after: IOSPresetApply = model.apply(id) {
            applied.value = true
        }
        XCTAssertEqual(after, IOSPresetApply.applied)
        XCTAssertTrue(applied.value)
        XCTAssertEqual(state.settings.resolution, 600)
    }

    @MainActor
    func test_presets_thatDoNotCollectPages_waitForTheQueuedPages() async throws {
        let state: AppState = ImportTestSupport.makeState(in: folder)
        let model: IOSPresetsModel = IOSPresetsModel(state: state, importer: IOSImportSession(state: state))
        let document: ScanSettings = state.settings
        state.settings = TaskCatalog.apply(.photos, to: document)
        XCTAssertTrue(model.save(named: "Holiday"))
        var single: ScanSettings = TaskCatalog.apply(.document, to: document)
        single.documentMultiPage = false
        state.settings = single
        XCTAssertTrue(model.save(named: "One by one"))
        state.settings = TaskCatalog.apply(.book, to: document)
        XCTAssertTrue(model.save(named: "Book"))
        let rows: [IOSPresetRow] = model.rows
        XCTAssertEqual(rows.map(\.name), ["Holiday", "One by one", "Book"])
        let holiday: UUID = rows[0].id
        state.settings = document

        let pages: [ScannedPage] = [0, 1].map { (_: Int) -> ScannedPage in
            ScannedPage(image: libraryPicture(width: 120, height: 160), dpi: 60, colorMode: .color)
        }
        XCTAssertTrue(state.ingest(pages, source: .photo))
        try await ImportTestSupport.waitUntil(timeout: 60) { !state.isBusy && state.scannedPages.count == 2 }
        let files: [URL] = state.scannedPages.compactMap(\.fileURL)
        XCTAssertEqual(files.count, 2)

        let applied: LibraryFlag = LibraryFlag()
        let photos: IOSPresetApply = model.apply(holiday) {
            applied.value = true
        }
        XCTAssertEqual(photos, IOSPresetApply.waitsForPages("Holiday"))
        // Document with Collect pages before saving off has no Save for a queue either.
        let oneByOne: IOSPresetApply = model.apply(rows[1].id) {
            applied.value = true
        }
        XCTAssertEqual(oneByOne, IOSPresetApply.waitsForPages("One by one"))
        XCTAssertFalse(applied.value)
        XCTAssertEqual(IOSShell.shownKind(state.settings), IOSScanKind.document)
        XCTAssertTrue(state.settings.documentMultiPage)
        XCTAssertEqual(state.scannedPages.count, 2)

        let book: IOSPresetApply = model.apply(rows[2].id) {}
        XCTAssertEqual(book, IOSPresetApply.applied)
        XCTAssertEqual(state.activeTask, ScanTask.book)
        XCTAssertEqual(state.scannedPages.count, 2)

        // No preset while a share or a send reads the pages.
        state.queueReaders = 1
        let reading: IOSPresetApply = model.apply(holiday, discardingPages: true) {
            applied.value = true
        }
        XCTAssertEqual(reading, IOSPresetApply.refused)
        XCTAssertEqual(state.scannedPages.count, 2)
        state.queueReaders = 0

        let discarded: IOSPresetApply = model.apply(holiday, discardingPages: true) {
            applied.value = true
        }
        XCTAssertEqual(discarded, IOSPresetApply.applied)
        XCTAssertTrue(applied.value)
        XCTAssertEqual(state.activeTask, ScanTask.photos)
        XCTAssertTrue(state.scannedPages.isEmpty)
        for file in files {
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), file.lastPathComponent)
        }
    }

    // MARK: Scans of this session

    func test_history_rows_sayModeResolutionAndTime() throws {
        var calendar: Calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let locale: Locale = Locale(identifier: "en_US")
        var parts: DateComponents = DateComponents()
        parts.year = 2026
        parts.month = 10
        parts.day = 20
        parts.hour = 16
        parts.minute = 23
        let now: Date = calendar.date(from: parts)!
        parts.day = 19
        parts.hour = 9
        let yesterday: Date = calendar.date(from: parts)!
        let picture: CGImage = libraryPicture(width: 4, height: 6)
        let today: ScanHistoryEntry = ScanHistoryEntry(date: now, intent: .document, dpi: 300, thumbnail: picture,
                                                       pixelSize: CGSize(width: 2550, height: 3510))
        let earlier: ScanHistoryEntry = ScanHistoryEntry(date: yesterday, intent: .photo, dpi: 600, thumbnail: picture,
                                                         pixelSize: CGSize(width: 1800, height: 1200))

        let rows: [IOSHistoryRow] = IOSHistory.rows([today, earlier], now: now, calendar: calendar, locale: locale)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].id, today.id)
        XCTAssertEqual(rows[0].title, "Document \u{00B7} 300 dpi")
        XCTAssertEqual(rows[1].title, "Photos \u{00B7} 600 dpi")
        XCTAssertEqual(rows[0].symbol, "doc.text")
        XCTAssertEqual(rows[1].symbol, "photo")
        XCTAssertTrue(rows[0].time.contains("4:23"), rows[0].time)
        XCTAssertFalse(rows[0].time.contains("Oct"), rows[0].time)
        XCTAssertTrue(rows[1].time.contains("Oct 19"), rows[1].time)
        XCTAssertTrue(rows[0].accessibilityLabel.hasPrefix("Document scan, 300 dpi, 2550 by 3510 pixels, "),
                      rows[0].accessibilityLabel)
        XCTAssertTrue(rows[1].accessibilityLabel.hasPrefix("Photo scan, 600 dpi, 1800 by 1200 pixels, "),
                      rows[1].accessibilityLabel)
        XCTAssertEqual(IOSHistory.countText(1), "1 scan")
        XCTAssertEqual(IOSHistory.countText(13), "13 scans")
        XCTAssertTrue(IOSHistory.rows([], now: now).isEmpty)
    }

    @MainActor
    func test_history_ofThisSession_listsAPageTaken() async throws {
        let state: AppState = ImportTestSupport.makeState(in: folder)
        XCTAssertTrue(IOSHistory.rows(state.scanHistory, now: Date()).isEmpty)
        let page: ScannedPage = ScannedPage(image: libraryPicture(width: 120, height: 160), dpi: 60, colorMode: .color)
        XCTAssertTrue(state.ingest([page], source: .photo))
        try await ImportTestSupport.waitUntil(timeout: 60) { state.scanHistory.count == 1 }
        let rows: [IOSHistoryRow] = IOSHistory.rows(state.scanHistory, now: Date())
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.title, "Document \u{00B7} 60 dpi")
    }

    // MARK: Saved files

    func test_savedFiles_listTheSaveFolder_newestFirst_theLastSaveMarked() throws {
        let saved: URL = folder.appendingPathComponent("Saved", isDirectory: true)
        try FileManager.default.createDirectory(at: saved, withIntermediateDirectories: true)
        let now: Date = Date()
        let names: [String] = ["a.pdf", "b.jpg", "c.txt", "d.xyz", ".hidden.pdf"]
        let ages: [Double] = [300, 100, 200, 50, 10]
        var index: Int = 0
        while index < names.count {
            let url: URL = saved.appendingPathComponent(names[index])
            try Data("file \(index)".utf8).write(to: url)
            let date: Date = now.addingTimeInterval(-ages[index])
            try FileManager.default.setAttributes([FileAttributeKey.modificationDate: date], ofItemAtPath: url.path)
            index += 1
        }
        try FileManager.default.createDirectory(at: saved.appendingPathComponent("e.pdf", isDirectory: true),
                                                withIntermediateDirectories: true)

        let listed: IOSSavedFolder = IOSSavedFiles.list(in: saved, justSaved: [saved.appendingPathComponent("b.jpg")])
        XCTAssertFalse(listed.failed)
        var listedNames: [String] = []
        var marks: [Bool] = []
        for file in listed.files {
            listedNames.append(file.name)
            marks.append(file.isNew)
        }
        XCTAssertEqual(listedNames, ["b.jpg", "c.txt", "a.pdf"])
        XCTAssertEqual(marks, [true, false, false])
        XCTAssertEqual(listed.files[0].symbol, "photo")
        XCTAssertEqual(listed.files[1].symbol, "doc.text")
        XCTAssertEqual(listed.files[2].symbol, "doc.richtext")
        XCTAssertTrue(listed.files[2].detail.contains("\u{00B7}"), listed.files[2].detail)

        let missing: IOSSavedFolder = IOSSavedFiles.list(in: folder.appendingPathComponent("Nowhere", isDirectory: true),
                                                         justSaved: [])
        XCTAssertTrue(missing.files.isEmpty)
        XCTAssertFalse(missing.failed, "A folder not made yet is empty, not a failure")
        let notAFolder: IOSSavedFolder = IOSSavedFiles.list(in: saved.appendingPathComponent("c.txt"), justSaved: [])
        XCTAssertTrue(notAFolder.failed)

        XCTAssertEqual(IOSSavedFiles.moreActions, [FileAction.open, FileAction.openWith, FileAction.email, FileAction.copy])
        XCTAssertEqual(IOSSavedFiles.label(FileAction.reveal), "Show in Files")
        XCTAssertEqual(IOSSavedFiles.label(FileAction.copy), FileAction.copy.label)
    }

    func test_savedFiles_thumbnails_ofAPictureAndAPDF() throws {
        let picture: URL = folder.appendingPathComponent("page.png")
        try ImportTestSupport.file(UTType.png, images: [libraryPicture(width: 400, height: 300)]).write(to: picture)
        let small: CGImage? = IOSSavedFiles.thumbnail(of: picture, maxSide: 100)
        XCTAssertEqual(small.map { (image: CGImage) -> Int in max(image.width, image.height) }, 100)

        let pdf: URL = folder.appendingPathComponent("page.pdf")
        var box: CGRect = CGRect(x: 0, y: 0, width: 612, height: 792)
        let writer: CGContext = try XCTUnwrap(CGContext(pdf as CFURL, mediaBox: &box, nil))
        writer.beginPDFPage(nil)
        writer.setFillColor(CGColor(srgbRed: 0.2, green: 0.2, blue: 0.2, alpha: 1))
        writer.fill(CGRect(x: 72, y: 72, width: 200, height: 100))
        writer.endPDFPage()
        writer.closePDF()
        let first: CGImage? = IOSSavedFiles.thumbnail(of: pdf, maxSide: 160)
        XCTAssertEqual(first?.height, 160)
        XCTAssertNil(IOSSavedFiles.thumbnail(of: folder.appendingPathComponent("notes.txt"), maxSide: 160))
    }

    @MainActor
    func test_savedFiles_shareAndShowInFiles_goThroughTheFileActions() throws {
        let opened: LibraryOpened = LibraryOpened()
        let actions: IOSFileActions = IOSFileActions(pasteboard: nil, openSystemURL: { (url: URL) -> Void in
            opened.urls.append(url)
        })
        let state: AppState = AppState(backends: [], presetStore: PresetStore(directory: folder), fileActions: actions,
                                       orientationScorer: ImportTestScorer(), barcodeReader: ImportTestBarcodes(),
                                       files: AppStateFiles.all(in: folder))
        let file: URL = folder.appendingPathComponent("Scan.pdf")
        try Data("%PDF-1.4\n".utf8).write(to: file)

        XCTAssertTrue(state.runFileAction(FileAction.share, urls: [file]))
        XCTAssertEqual(actions.shareRequest?.urls, [file])
        XCTAssertTrue(state.runFileAction(FileAction.reveal, urls: [file]))
        XCTAssertEqual(opened.urls.count, 1)
        XCTAssertEqual(opened.urls.first?.scheme, "shareddocuments")
        XCTAssertTrue(state.runFileAction(FileAction.open, urls: [file]))
        XCTAssertEqual(actions.previewURL, file)

        // Show in Files for the save folder opens that folder, not the one holding it.
        var settings: ScanSettings = state.settings
        settings.destinationPath = folder.appendingPathComponent("Saved", isDirectory: true).path
        let saveFolder: URL = IOSSavedFiles.folder(settings)
        state.revealInFinder(saveFolder)
        XCTAssertEqual(opened.urls.count, 2)
        XCTAssertEqual(opened.urls.last?.scheme, "shareddocuments")
        XCTAssertEqual(opened.urls.last?.path, saveFolder.path)
    }
}
#endif
