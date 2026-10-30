#if os(iOS)
import LazyScanKit
import CoreGraphics
import Foundation
import UniformTypeIdentifiers

/// One thing to import: a photo's or a PDF's bytes, and the name shown for it.
public struct IOSImportItem: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case image
        case pdf
    }

    public let name: String
    public let data: Data
    public let kind: Kind

    public init(name: String, data: Data, kind: Kind) {
        self.name = name
        self.data = data
        self.kind = kind
    }

    /// A PDF when the bytes start as one ("%PDF") or the name says so; any other file is taken as a picture.
    public static func kind(forFileName name: String, data: Data) -> Kind {
        let header: Data = Data("%PDF".utf8)
        if data.count >= header.count && data.prefix(header.count) == header { return .pdf }
        let fileExtension: String = (name as NSString).pathExtension
        if let type = UTType(filenameExtension: fileExtension), type.conforms(to: UTType.pdf) { return .pdf }
        return .image
    }

    /// The file at `url` (from the Files app, or opened in this app from another one), read once; the
    /// file itself is never changed. Throws `IOSImportError` when it cannot be read.
    public static func read(_ url: URL) throws -> IOSImportItem {
        let name: String = url.lastPathComponent
        // A file outside the app's own folder is reached through its security scope.
        let scoped: Bool = url.startAccessingSecurityScopedResource()
        defer {
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw IOSImportError(message: PhotoImport.unreadableMessage(name, detail: error.localizedDescription))
        }
        return IOSImportItem(name: name, data: data, kind: IOSImportItem.kind(forFileName: name, data: data))
    }
}

/// One thing waiting to be imported: the name shown for it, what it is expected to be (from its name; a
/// file's own bytes have the last word), and how its bytes are read once its turn comes, so only the item
/// in hand is in memory: a photo the Photos picker hands over when asked, a file read off the main
/// actor (`file`), or bytes already in hand (`item`). A photo from our camera also carries the outline
/// its live preview showed (`liveOutline`, shares of the upright photo), the corner editor's start
/// when the corner model found no page in the photo itself and the search found none clearly (`shot`), and, in continuous capture, that the
/// corner editor opens only when the photo's own search is unsure (`asksOnlyWhenUnsure`). Only our camera's
/// shots go by camera mode's Items in frame (`isShot`).
public struct IOSImportSource {
    public let name: String
    public let expectedKind: IOSImportItem.Kind
    public let liveOutline: Quad?
    /// A page found clearly in the photo itself (`IOSFoundPage.reason` `.none` before any live outline is
    /// used) goes into the queue along its corners without the corner editor.
    public let asksOnlyWhenUnsure: Bool
    public let isShot: Bool
    let read: @MainActor () async -> Result<IOSImportItem, IOSImportError>

    public init(name: String, expectedKind: IOSImportItem.Kind, liveOutline: Quad? = nil, asksOnlyWhenUnsure: Bool = false,
                isShot: Bool = false, read: @escaping @MainActor () async -> Result<IOSImportItem, IOSImportError>) {
        self.name = name
        self.expectedKind = expectedKind
        self.liveOutline = liveOutline
        self.asksOnlyWhenUnsure = asksOnlyWhenUnsure
        self.isShot = isShot
        self.read = read
    }

    /// Bytes already in hand.
    public static func item(_ item: IOSImportItem) -> IOSImportSource {
        IOSImportSource(name: item.name, expectedKind: item.kind) { () async -> Result<IOSImportItem, IOSImportError> in
            .success(item)
        }
    }

    /// A photo our camera took (`IOSCameraShot`), named `IOSImportText.shotName`, with its live outline; in
    /// continuous capture the corner editor opens only when the photo's own search is unsure.
    public static func shot(_ shot: IOSCameraShot, asksOnlyWhenUnsure: Bool = false) -> IOSImportSource {
        let item = IOSImportItem(name: IOSImportText.shotName, data: shot.data, kind: .image)
        return IOSImportSource(name: item.name, expectedKind: .image, liveOutline: shot.liveOutline,
                               asksOnlyWhenUnsure: asksOnlyWhenUnsure, isShot: true) { () async -> Result<IOSImportItem, IOSImportError> in
            .success(item)
        }
    }

    /// The file at `url` (the Files app, or opened in this app), read through its security scope off the
    /// main actor when its turn comes (`IOSImportItem.read`).
    public static func file(_ url: URL) -> IOSImportSource {
        let name: String = url.lastPathComponent
        let expected: IOSImportItem.Kind = IOSImportItem.kind(forFileName: name, data: Data())
        return IOSImportSource(name: name, expectedKind: expected) { () async -> Result<IOSImportItem, IOSImportError> in
            await Task.detached(priority: .userInitiated) { () -> Result<IOSImportItem, IOSImportError> in
                IOSImportSource.readFile(url)
            }.value
        }
    }

    /// A photo the Photos picker could not hand over (not downloaded from iCloud, say).
    public static func notLoaded() -> IOSImportSource {
        IOSImportSource(name: PhotoImport.label, expectedKind: .image) { () async -> Result<IOSImportItem, IOSImportError> in
            .failure(IOSImportError(message: IOSImportText.photoNotLoadedMessage))
        }
    }

    /// The file at `url` read once (`IOSImportItem.read`), or why it could not be.
    static func readFile(_ url: URL) -> Result<IOSImportItem, IOSImportError> {
        do {
            return .success(try IOSImportItem.read(url))
        } catch let error as IOSImportError {
            return .failure(error)
        } catch {
            return .failure(IOSImportError(message: PhotoImport.unreadableMessage(url.lastPathComponent,
                                                                                  detail: PhotoImport.unreadableDetail)))
        }
    }
}

/// What an import did: pages added, photos skipped in the corner editor, and what could not be read.
public struct IOSImportOutcome: Equatable, Sendable {
    public var added: Int = 0
    public var skipped: Int = 0
    public var problems: [String] = []

    public init() {}

    mutating func merge(_ other: IOSImportOutcome) {
        added += other.added
        skipped += other.skipped
        for problem in other.problems {
            add(problem)
        }
    }

    /// A problem for the list, each line once (photos the Photos picker could not hand over, all named
    /// "Photo", say it once).
    mutating func add(_ problem: String) {
        if problems.contains(problem) { return }
        problems.append(problem)
    }
}

/// The iPhone's short texts of importing and the camera.
public enum IOSImportText {
    /// Our own camera (`CameraScreen`), the default way to take pages.
    public static let cameraLabel = "Camera"
    /// Apple's document scanner (VisionKit), offered beside our camera on the Document, Email and Word tasks.
    public static let scannerLabel = "Use Apple's scanner"
    /// What VoiceOver calls Apple's document scanner's button.
    public static let scannerName = "Use Apple's document scanner"
    /// The name of a photo from our camera as an item; the corner editor, the progress and the messages have
    /// words of their own for a shot (below).
    public static let shotName = "Camera photo"
    /// In place of Skip photo in a shot's corner editor: the photo is dropped and the page taken again.
    public static let retakeLabel = "Retake"
    public static let retakeHint = "Drops this photo. Take it again."
    /// The progress while a shot is read and its page searched.
    public static let readingShot = "Reading the photo\u{2026}"
    /// A shot that could not be read, and one whose page could not be added.
    public static let shotUnreadableMessage = "The photo could not be read. Take it again."
    public static let shotNotAddedMessage = "The photo could not be added. Try again."
    /// The pages Apple's document scanner took, in the message when they could not be added.
    public static let scannedPagesName = "Scanned pages"
    public static let photosLabel = "Photos"
    public static let filesLabel = "Files"
    /// Ends the import after the photo or page in hand.
    public static let stopLabel = "Stop"
    /// The photo review's Stop: the review opens once for each photo or page an import brings in.
    public static let stopImportLabel = "Stop import"
    public static let stopImportHint = "Brings in no more photos or pages; this review stays open"
    /// While a PDF's pages come in: "Importing page 2 of 5…".
    public static func importingPage(_ number: Int, of count: Int) -> String {
        "Importing page \(number) of \(count)\u{2026}"
    }
    /// While a file is read: "Importing scan.pdf…".
    public static func importingFile(_ name: String) -> String {
        "Importing \(name)\u{2026}"
    }
    /// A page that was ready but could not be added (something else was running).
    public static func notAddedMessage(_ name: String) -> String {
        "\(name) could not be added. Try again."
    }
    /// A photo the Photos library could not hand over (not downloaded from iCloud, say).
    public static let photoNotLoadedMessage = "A photo could not be loaded."
    /// What a Text import left out once its page was held: "Text takes one page; the other 2 were not added."
    public static func textTakesOneMessage(_ count: Int) -> String {
        if count == 1 { return "Text takes one page; the other one was not added." }
        return "Text takes one page; the other \(count) were not added."
    }
    /// What an ID card import left out once both sides were in.
    public static func cardFullMessage(_ count: Int) -> String {
        if count == 1 { return "The card already has both sides; the other one was not added." }
        return "The card already has both sides; the other \(count) were not added."
    }
    /// An import refused while a copy is held on the copy screen (the queue's pages after Print…, or a photocopy).
    public static let copyHeldMessage = "Print or discard the copy first; nothing was imported."
    /// What a photocopy's import left out once its first page was held as the copy.
    public static func copyFullMessage(_ count: Int) -> String {
        if count == 1 { return "Print or discard the copy first; the other one was not added." }
        return "Print or discard the copy first; the other \(count) were not added."
    }
    /// An import refused while a stack is being turned over by hand: its steps count the fronts and backs.
    public static let sidesInProgressMessage = "Finish the front and back sides first; nothing was imported."
}

/// Brings photos and PDFs into the queue on the iPhone and iPad, one after another: a photo is read
/// (`IOSPhotoDecoder`: turned upright by its orientation tag; each page of a TIFF as a photo of its own),
/// its page found (`IOSPageFinder`: the corner model, else the shared detector), and the corner editor opens
/// (`cornerRequest`) with the corners found; Use corners hands the photo to the queue with its capture
/// facts (the corners in the photo's pixels, its size and the camera's focal length), so the clean-up
/// stage cuts the page out at its real size (`AppState.ingest`, `PageProcessor.forCapture`:
/// `PerspectiveStep`, `CaptureScale`); Use whole photo takes the photo as it is
/// (`PhotoImport.wholePhotoPage`); Skip leaves it out. Each PDF page is drawn at 300 dpi (`IOSPDFPages`)
/// and goes to the queue as it is. Pages from Apple's document scanner come in through `bringInScans`.
/// Each item's bytes are read only when its turn comes (`IOSImportSource`) and let go once its photo is
/// decoded (a TIFF's and a PDF's while their pages come in), so only one item is in memory at a time;
/// each page is added once the one before is in. What arrives while an import runs (another pick, a
/// file opened in the app) waits and is imported after it; Stop drops what waits and ends the import
/// after the item in hand. What could not be read is listed in one error at the end. Text takes one page and an
/// ID card two sides: once they are in, the rest of the import is left out, said in one line; so is what
/// comes while a copy is held or a stack is being turned over by hand.
///
/// For the tasks that photograph objects (I13, `CaptureObjects.kind(for:)`) a photo is searched for them
/// instead (`IOSObjectFinder`: Vision's rectangles, `MultiQuadPicker`): the receipts or photos of a shot come
/// in together, each a page with its corners (the clean-up stage cuts each out at its real size and the
/// photo review opens), with no corner editor; a shot in which none was found comes in whole
/// (`CaptureObjects.fallbackPage`), for the flatbed's search of the task to look at it; the next photo, or
/// the next page of a PDF, is read once that review is closed. An ID card found clearly in a shot that asks
/// only when unsure (its shape snaps to ID-1) goes in as the step's side without the editor; one found
/// otherwise opens the editor on its corners, one not found on the page finder's; Use whole photo takes the
/// whole photo as the card.
///
/// A camera shot of Photo or Document goes by Items in frame (`IOSShell.itemsInFrame`). A Document shot is
/// searched for loose pages too (the receipts' search), those under 3 % of the photo or 15 % of the largest
/// left out: two or more on Auto, one or more on Several, come in as pages of their own, cut along their
/// outlines with no corner editor, into the queue as any page; fewer, One, or on Auto a page the page finder
/// found, clearly or not, holding the middle of every one found, is the single page as before. Photo on One
/// keeps only the largest print found. A page of the camera's own Document shot 2.2 times as long as wide or
/// more is measured as a receipt roll (`documentKind`); every other import's pages are measured as before.
@MainActor
public final class IOSImportSession: ObservableObject {
    /// The corner editor to show; nil when none is waiting.
    @Published public private(set) var cornerRequest: PhotoCornersRequest?
    /// An import runs.
    @Published public private(set) var isImporting: Bool = false
    /// The item in hand is a photo our camera just took: its corner editor has Retake and no caption, and its
    /// progress reads "Reading the photo…".
    @Published public private(set) var importsShot: Bool = false
    /// More photos or pages follow the one in hand, so the corner editor and the progress offer Stop.
    @Published public private(set) var canStop: Bool = false
    /// "Importing photo 2 of 5…" while an import runs.
    @Published public private(set) var progressText: String?
    /// What the last import did.
    public private(set) var lastOutcome: IOSImportOutcome?

    private let state: AppState
    private let finder: @Sendable (RgbaImage) -> IOSFoundPage
    private let objectFinder: @Sendable (RgbaImage, CaptureKind) -> [Quad]
    /// Where Items in frame is kept.
    private let defaults: UserDefaults
    private var continuation: CheckedContinuation<PhotoCornersAnswer, Never>?
    private var stopRequested: Bool = false
    /// What waits for its turn, in order.
    private var pending: [IOSImportSource] = []
    /// The photos taken so far in this import (for "Photo 2 of 5").
    private var photoNumber: Int = 0
    /// The items and pages this import left out because the kind had taken all it takes (`isFull`).
    private var leftOut: Int = 0

    /// `finder` nil: `IOSPageFinder.find`; `objectFinder` nil: `IOSObjectFinder.find` (tests pass their own).
    public init(state: AppState, finder: (@Sendable (RgbaImage) -> IOSFoundPage)? = nil,
                objectFinder: (@Sendable (RgbaImage, CaptureKind) -> [Quad])? = nil,
                defaults: UserDefaults = UserDefaults.standard) {
        self.state = state
        self.defaults = defaults
        if let finder {
            self.finder = finder
        } else {
            self.finder = { (photo: RgbaImage) -> IOSFoundPage in
                IOSPageFinder.find(photo)
            }
        }
        if let objectFinder {
            self.objectFinder = objectFinder
        } else {
            self.objectFinder = { (photo: RgbaImage, kind: CaptureKind) -> [Quad] in
                IOSObjectFinder.find(photo, kind: kind)
            }
        }
    }

    /// Photos and PDFs can be imported now: the settings' task takes photos (`IOSShell.takesPhotos`: pages
    /// for the queue, the objects of a shot, a side of the ID card), the state can take pages
    /// (`AppState.canIngest`), and no import runs.
    public var canImport: Bool {
        !isImporting && state.canIngest && IOSShell.takesPhotos(state.settings)
    }

    /// How many items wait for their turn.
    public var waitingCount: Int { pending.count }

    /// Imports `sources` in order (see the type). Refused, with the reason shown, when the settings do
    /// not collect pages. While another import runs they wait and are imported after it: that import's
    /// outcome counts them, and this call returns an empty outcome at once.
    @discardableResult
    public func importSources(_ sources: [IOSImportSource]) async -> IOSImportOutcome {
        var outcome = IOSImportOutcome()
        if sources.isEmpty { return outcome }
        guard IOSShell.takesPhotos(state.settings) else {
            state.errorMessage = PhotoImport.notOfferedMessage
            return outcome
        }
        pending.append(contentsOf: sources)
        if isImporting {
            canStop = true
            return outcome
        }
        isImporting = true
        stopRequested = false
        photoNumber = 0
        leftOut = 0
        while !pending.isEmpty {
            if stopRequested {
                // Stop dropped what waited: what is here came in after it, a new import.
                stopRequested = false
                photoNumber = 0
            }
            let source: IOSImportSource = pending.removeFirst()
            let part: IOSImportOutcome = await importSource(source)
            outcome.merge(part)
        }
        stopRequested = false
        if leftOut > 0 {
            outcome.add(leftOutMessage(added: outcome.added))
            leftOut = 0
        }
        finish(outcome)
        return outcome
    }

    /// Imports `items`, bytes in hand (see `importSources`).
    @discardableResult
    public func importItems(_ items: [IOSImportItem]) async -> IOSImportOutcome {
        var sources: [IOSImportSource] = []
        for item in items {
            sources.append(IOSImportSource.item(item))
        }
        return await importSources(sources)
    }

    /// Imports what the Photos picker handed over (nil: a photo it could not hand over), named
    /// "Photo"; the ones missing are listed as one problem.
    @discardableResult
    public func importPicked(_ photos: [Data?]) async -> IOSImportOutcome {
        var sources: [IOSImportSource] = []
        for photo in photos {
            if let data = photo {
                sources.append(IOSImportSource.item(IOSImportItem(name: PhotoImport.label, data: data, kind: .image)))
            } else {
                sources.append(IOSImportSource.notLoaded())
            }
        }
        return await importSources(sources)
    }

    /// Imports the files at `urls` (the Files app, or files opened in this app), each read when its turn
    /// comes; a file that cannot be read is listed and the others go on.
    @discardableResult
    public func importFiles(_ urls: [URL]) async -> IOSImportOutcome {
        var sources: [IOSImportSource] = []
        for url in urls {
            sources.append(IOSImportSource.file(url))
        }
        return await importSources(sources)
    }

    /// The pages Apple's document scanner took (`IOSDocumentCamera.pages`), into the queue together.
    @discardableResult
    public func bringInScans(_ pages: [ScannedPage]) async -> Bool {
        guard !pages.isEmpty else { return false }
        let taken: Bool = await bringIn(pages)
        if !taken {
            state.errorMessage = IOSImportText.notAddedMessage(IOSImportText.scannedPagesName)
        }
        return taken
    }

    /// A photo our camera took, imported as a photo is (see `importSources`): read with its orientation
    /// tag and focal length (`IOSPhotoDecoder`), its page found again in it (`IOSPageFinder`; where the
    /// page is not found clearly, the outline the live preview showed is the editor's start, `seeded`),
    /// the corner editor, then the page into the queue with its capture facts. In continuous capture
    /// (`asksOnlyWhenUnsure`) a page the photo's own search found clearly skips the editor (I7's rule, as
    /// the Mac's and Windows' photo import cut a page found surely at once).
    @discardableResult
    public func importShot(_ shot: IOSCameraShot, asksOnlyWhenUnsure: Bool = false) async -> IOSImportOutcome {
        await importSources([IOSImportSource.shot(shot, asksOnlyWhenUnsure: asksOnlyWhenUnsure)])
    }

    /// The corner editor's answer: the import waiting for it goes on. A second answer changes nothing.
    public func answer(_ answer: PhotoCornersAnswer) {
        guard let waiting = continuation else { return }
        continuation = nil
        cornerRequest = nil
        waiting.resume(returning: answer)
    }

    /// Stops the import after the photo or page in hand: what waits is dropped and a waiting editor is
    /// answered with Skip. Nothing happens when no import runs.
    public func stop() {
        guard isImporting else { return }
        pending.removeAll()
        stopRequested = true
        answer(.skip)
    }

    // MARK: The steps

    private func finish(_ outcome: IOSImportOutcome) {
        isImporting = false
        importsShot = false
        canStop = false
        progressText = nil
        lastOutcome = outcome
        if !outcome.problems.isEmpty {
            state.errorMessage = outcome.problems.joined(separator: "\n")
        }
    }

    /// The photos waiting for their turn.
    private var waitingPhotos: Int {
        var count: Int = 0
        for source in pending where source.expectedKind == .image {
            count += 1
        }
        return count
    }

    /// The message for `name`, which could not be read; a shot has its own.
    private func unreadableMessage(_ name: String) -> String {
        importsShot
            ? IOSImportText.shotUnreadableMessage
            : PhotoImport.unreadableMessage(name, detail: PhotoImport.unreadableDetail)
    }

    /// The message for `name`, which could not be added; a shot has its own.
    private func notAddedMessage(_ name: String) -> String {
        importsShot ? IOSImportText.shotNotAddedMessage : IOSImportText.notAddedMessage(name)
    }

    /// The item in hand: read, then its photo's pages or its PDF's pages imported.
    private func importSource(_ source: IOSImportSource) async -> IOSImportOutcome {
        var outcome = IOSImportOutcome()
        importsShot = source.isShot
        canStop = !pending.isEmpty
        if source.expectedKind == .image {
            photoNumber += 1
            progressText = source.isShot
                ? IOSImportText.readingShot
                : PhotoImport.progressMessage(photoNumber, of: photoNumber + waitingPhotos)
        } else {
            progressText = IOSImportText.importingFile(source.name)
        }
        // The objects of the shot before are in their review: the next shot is read once it is closed.
        await waitForReview()
        if stopRequested && state.showPhotoReview { return outcome }
        if await isFull(leaving: 1) { return outcome }
        // Nothing is read while the state cannot take pages (a review open, say).
        guard await canTakePages() else {
            outcome.add(notAddedMessage(source.name))
            return outcome
        }
        let read: IOSReadItem = await readItem(source)
        switch read {
        case .problem(let message):
            outcome.add(message)
        case .pdf(let item):
            let part: IOSImportOutcome = await importPDF(item)
            outcome.merge(part)
        case .photo(let file):
            let part: IOSImportOutcome = await importPhoto(file)
            outcome.merge(part)
        }
        return outcome
    }

    /// `source`'s bytes read and, for a photo, its first page decoded and searched off the main actor. The
    /// bytes are let go here unless more pages are to come from them (a PDF, a TIFF of several pages).
    private func readItem(_ source: IOSImportSource) async -> IOSReadItem {
        let loaded: Result<IOSImportItem, IOSImportError> = await source.read()
        let item: IOSImportItem
        switch loaded {
        case .success(let read):
            item = read
        case .failure(let error):
            return .problem(error.message)
        }
        if item.kind == .pdf { return .pdf(item) }
        let data: Data = item.data
        let name: String = item.name
        let finder: @Sendable (RgbaImage) -> IOSFoundPage = self.finder
        let objectFinder: @Sendable (RgbaImage, CaptureKind) -> [Quad] = self.objectFinder
        let outline: Quad? = source.liveOutline
        let kind: CaptureKind = CaptureObjects.kind(for: state.settings)
        let items: IOSItemsInFrame? = source.isShot ? IOSShell.itemsInFrame(state.settings, defaults: defaults) : nil
        let byShape: Bool = source.isShot && IOSShell.shownKind(state.settings) == .document && !state.isCopyFlow
        let first: IOSFirstPage = await Task.detached(priority: .userInitiated) { () -> IOSFirstPage in
            let pageCount: Int = IOSPhotoDecoder.pageCount(data)
            let prepared: IOSPreparedPhoto = IOSPreparedPhoto.make(data, fileName: name, page: 1, finder: finder,
                                                                   liveOutline: outline, kind: kind, items: items,
                                                                   objectFinder: objectFinder)
            return IOSFirstPage(pageCount: pageCount, prepared: prepared)
        }.value
        let rest: Data? = first.pageCount > 1 ? data : nil
        return .photo(IOSPhotoFile(name: name, pageCount: first.pageCount, first: first.prepared, rest: rest,
                                   asksOnlyWhenUnsure: source.asksOnlyWhenUnsure, kind: kind, items: items,
                                   byShape: byShape))
    }

    /// The pages of one photo file (one, or a TIFF's several), each through the corner editor. Page 1 is
    /// taken out of `file` when its turn comes and each page after it is decoded from the file's bytes
    /// once the page before is done, so only the page in hand is held; the bytes go with the last page.
    private func importPhoto(_ file: IOSPhotoFile) async -> IOSImportOutcome {
        var outcome = IOSImportOutcome()
        let number: Int = photoNumber
        let name: String = file.name
        let pageCount: Int = file.pageCount
        let finder: @Sendable (RgbaImage) -> IOSFoundPage = self.finder
        let objectFinder: @Sendable (RgbaImage, CaptureKind) -> [Quad] = self.objectFinder
        let kind: CaptureKind = file.kind
        let items: IOSItemsInFrame? = file.items
        var page: Int = 1
        while page <= pageCount {
            if page > 1 && stopRequested { break }
            if page > 1, await isFull(leaving: pageCount - page + 1) { break }
            if page > 1 && CaptureObjects.findsSeveral(kind) {
                // The objects of the page before are in their review: the next page is read once it is closed.
                await waitForReview()
                if stopRequested { break }
            }
            let count: Int = max(number, photoNumber + waitingPhotos)
            canStop = !pending.isEmpty || page < pageCount
            if !importsShot {
                progressText = PhotoImport.progressMessage(number, of: count, page: page, pageCount: pageCount)
            }
            let shownName: String = PhotoImport.pageName(name, page: page, pageCount: pageCount)
            var part = IOSImportOutcome()
            var made: ScannedPage?
            // The photo's pixels live only in this block, so they are gone before its page is brought in,
            // which copies the page again.
            do {
                let prepared: IOSPreparedPhoto
                if page == 1, let first = file.takeFirst() {
                    prepared = first
                } else {
                    guard let data = file.rest else { break }
                    if page == pageCount {
                        file.dropRest()
                    }
                    let pageNumber: Int = page
                    prepared = await Task.detached(priority: .userInitiated) { () -> IOSPreparedPhoto in
                        IOSPreparedPhoto.make(data, fileName: name, page: pageNumber, finder: finder, kind: kind,
                                              items: items, objectFinder: objectFinder)
                    }.value
                }
                if CaptureObjects.findsSeveral(kind) || prepared.splits {
                    part = await importObjects(prepared, shownName: shownName, kind: kind, byShape: file.byShape)
                } else {
                    made = await makePage(prepared, shownName: shownName, number: number, count: count,
                                          asksOnlyWhenUnsure: file.asksOnlyWhenUnsure, kind: kind,
                                          byShape: file.byShape, outcome: &part)
                }
            }
            if let newPage = made {
                if await bringIn([newPage]) {
                    part.added += 1
                } else {
                    part.add(notAddedMessage(shownName))
                }
            }
            outcome.merge(part)
            page += 1
        }
        // Stopped before the last page: the bytes go now.
        file.dropRest()
        return outcome
    }

    /// One photo read and searched: the corner editor (not for a page found clearly when
    /// `asksOnlyWhenUnsure`), then the page made, for the caller to bring in; nil, with why in `outcome`
    /// (or counted as skipped), when there is none. `byShape`: the page is measured by its shape
    /// (`documentKind`).
    private func makePage(_ prepared: IOSPreparedPhoto, shownName: String, number: Int, count: Int,
                          asksOnlyWhenUnsure: Bool, kind: CaptureKind, byShape: Bool,
                          outcome: inout IOSImportOutcome) async -> ScannedPage? {
        if let problem = prepared.problem {
            outcome.add(importsShot ? IOSImportText.shotUnreadableMessage : problem)
            return nil
        }
        guard let decoded = prepared.decoded, let found = prepared.found else {
            outcome.add(unreadableMessage(shownName))
            return nil
        }
        // No editor for a page the state could not take now.
        guard await canTakePages() else {
            outcome.add(notAddedMessage(shownName))
            return nil
        }
        let photo: RgbaImage = decoded.photo
        let plan = PhotoImportPlan(action: .review, corners: found.corners, reason: found.reason,
                                   detection: PhotoDocumentDetection.nothing)
        let request = PhotoCornersRequest(photo: photo, plan: plan, fileName: shownName, number: number, count: count,
                                          kind: kind)
        let reply: PhotoCornersAnswer
        if asksOnlyWhenUnsure && prepared.sure && !stopRequested {
            reply = PhotoCornersAnswer(choice: .useCorners, corners: found.corners)
        } else {
            reply = await askCorners(request)
        }
        let focalLength: Double? = decoded.focalLength
        var page: ScannedPage?
        switch reply.choice {
        case .useCorners:
            if let corners = reply.corners {
                let pageKind: CaptureKind = byShape
                    ? IOSImportSession.documentKind(corners, width: photo.width, height: photo.height, focalLength: focalLength)
                    : (kind == .idCard ? CaptureKind.idCard : CaptureKind.document)
                page = await Task.detached(priority: .userInitiated) { () -> ScannedPage? in
                    IOSImportSession.capturedPage(photo, corners: corners, focalLength: focalLength, kind: pageKind)
                }.value
            }
        case .wholePhoto:
            if kind == .idCard || state.isCopyFlow {
                // The whole photo is the card: measured by its shape as any card is, never at a made-up size
                // without its note. A copy's whole photo is measured too, so it prints at real size only
                // when it snapped to a paper size.
                let whole: Quad = PhotoImport.wholePhoto(width: photo.width, height: photo.height)
                let wholeKind: CaptureKind = kind == .idCard ? CaptureKind.idCard : CaptureKind.document
                page = await Task.detached(priority: .userInitiated) { () -> ScannedPage? in
                    IOSImportSession.capturedPage(photo, corners: whole, focalLength: focalLength, kind: wholeKind)
                }.value
            } else {
                page = await Task.detached(priority: .userInitiated) { () -> ScannedPage? in
                    PhotoImport.wholePhotoPage(photo)
                }.value
            }
        case .skip:
            page = nil
        }
        if page == nil {
            outcome.skipped += 1
        }
        return page
    }

    private func importPDF(_ item: IOSImportItem) async -> IOSImportOutcome {
        var outcome = IOSImportOutcome()
        let data: Data = item.data
        let name: String = item.name
        let counted: Result<Int, IOSImportError> = await Task.detached(priority: .userInitiated) { () -> Result<Int, IOSImportError> in
            do {
                let document = try IOSPDFPages.open(data, fileName: name)
                return .success(document.pageCount)
            } catch let error as IOSImportError {
                return .failure(error)
            } catch {
                return .failure(IOSImportError(message: PhotoImport.unreadableMessage(name, detail: PhotoImport.unreadableDetail)))
            }
        }.value
        let pageCount: Int
        switch counted {
        case .success(let count):
            pageCount = count
        case .failure(let error):
            outcome.add(error.message)
            return outcome
        }
        let kind: CaptureKind = CaptureObjects.kind(for: state.settings)
        var index: Int = 0
        while index < pageCount {
            if stopRequested { break }
            if index > 0, await isFull(leaving: pageCount - index) { break }
            if index > 0 && CaptureObjects.findsSeveral(kind) {
                // The photos or receipts found on the page before are in their review: the next page is
                // read once it is closed.
                await waitForReview()
                if stopRequested { break }
            }
            canStop = !pending.isEmpty || index + 1 < pageCount
            progressText = IOSImportText.importingPage(index + 1, of: pageCount)
            let pageIndex: Int = index
            let page: ScannedPage? = await Task.detached(priority: .userInitiated) { () -> ScannedPage? in
                IOSImportSession.pdfPage(data, fileName: name, index: pageIndex)
            }.value
            let shownName: String = PhotoImport.pageName(name, page: index + 1, pageCount: pageCount)
            if let ready = page {
                if await bringIn([ready]) {
                    outcome.added += 1
                } else {
                    outcome.add(IOSImportText.notAddedMessage(shownName))
                }
            } else {
                outcome.add(PhotoImport.unreadableMessage(shownName, detail: PhotoImport.unreadableDetail))
            }
            index += 1
        }
        return outcome
    }

    /// The objects of one shot (receipts, photos, a Document shot's pages) into the state together, each a page
    /// with its corners; the whole shot when none was found. No corner editor: the photo review that opens has
    /// Fix crop, and a Document's pages have Crop in the page viewer.
    private func importObjects(_ prepared: IOSPreparedPhoto, shownName: String, kind: CaptureKind,
                               byShape: Bool) async -> IOSImportOutcome {
        var outcome = IOSImportOutcome()
        if let problem = prepared.problem {
            outcome.add(importsShot ? IOSImportText.shotUnreadableMessage : problem)
            return outcome
        }
        guard let decoded = prepared.decoded else {
            outcome.add(unreadableMessage(shownName))
            return outcome
        }
        let photo: RgbaImage = decoded.photo
        let quads: [Quad] = prepared.objects
        let focalLength: Double? = decoded.focalLength
        let pages: [ScannedPage] = await Task.detached(priority: .userInitiated) { () -> [ScannedPage] in
            IOSImportSession.objectPages(photo, quads: quads, kind: kind, focalLength: focalLength, byShape: byShape)
        }.value
        guard !pages.isEmpty else {
            outcome.add(unreadableMessage(shownName))
            return outcome
        }
        if await bringIn(pages) {
            outcome.added += pages.count
        } else {
            outcome.add(notAddedMessage(shownName))
        }
        return outcome
    }

    /// Waits while the photo review of the objects brought in before is open (receipts and photos), so the
    /// next shot is read once it is closed; Stop ends the wait.
    private func waitForReview() async {
        while state.showPhotoReview && !stopRequested && CaptureObjects.findsSeveral(CaptureObjects.kind(for: state.settings)) {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// Shows the corner editor for `request` and waits for the answer (`answer`).
    private func askCorners(_ request: PhotoCornersRequest) async -> PhotoCornersAnswer {
        if stopRequested { return .skip }
        return await withCheckedContinuation { (waiting: CheckedContinuation<PhotoCornersAnswer, Never>) in
            continuation = waiting
            cornerRequest = request
        }
    }

    /// Waits until nothing else runs; true when the kind has taken all it takes (Text's page is held for its
    /// screen, or the ID card's steps are past its sides) or nothing comes in until the user is done (a copy
    /// is held, or a stack is being turned over by hand). The `left` pages of the item in hand and what waits
    /// are then left out (`leftOut`), said once at the end rather than as pages that could not be added.
    private func isFull(leaving left: Int) async -> Bool {
        await waitUntilIdle()
        let card: Bool = TaskCatalog.flow(of: state.settings) == .idCard && state.taskFlow != nil
        let cardIn: Bool = card && (state.showIdCardReview || IdCardSteps.sideOf(state.taskFlow?.current?.id) == nil)
        guard cardIn || state.quickScanPage != nil || !state.copyPages.isEmpty || state.isTurningOverByHand else { return false }
        leftOut += left + pending.count
        pending.removeAll()
        return true
    }

    /// The one line for what `isFull` left out of an import that added `added` pages. A copy held before
    /// anything came in refused the whole import, so its line says nothing was imported.
    private func leftOutMessage(added: Int) -> String {
        if !state.copyPages.isEmpty {
            return added > 0 ? IOSImportText.copyFullMessage(leftOut) : IOSImportText.copyHeldMessage
        }
        if state.isTurningOverByHand { return IOSImportText.sidesInProgressMessage }
        if TaskCatalog.flow(of: state.settings) == .idCard { return IOSImportText.cardFullMessage(leftOut) }
        return IOSImportText.textTakesOneMessage(leftOut)
    }

    /// Waits until nothing else runs; true when the state can take pages then (`AppState.canIngest`).
    private func canTakePages() async -> Bool {
        await waitUntilIdle()
        return state.canIngest
    }

    /// Waits until the state can take pages, hands `pages` over (`AppState.ingest`, from a photo) and
    /// waits until they are in; false when the state did not take them.
    private func bringIn(_ pages: [ScannedPage]) async -> Bool {
        await waitUntilIdle()
        guard state.ingest(pages, source: .photo) else { return false }
        await waitUntilIdle()
        return true
    }

    private func waitUntilIdle() async {
        while state.isBusy {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    // MARK: Pages

    /// The photo as a page taken by a camera: the whole photo, with the corners placed (named again,
    /// `Quad.fromCorners`), its size, `kind` (a page, or an ID card's side) and the focal length as its
    /// capture facts, so the clean-up stage cuts the page out at its real size (`PerspectiveStep`).
    /// Labelled as a photo.
    nonisolated static func capturedPage(_ photo: RgbaImage, corners: Quad, focalLength: Double?,
                                         kind: CaptureKind = .document) -> ScannedPage? {
        guard let image = photo.makeCGImage() else { return nil }
        return CaptureObjects.pages(image, quads: [corners], kind: kind, focalLength: focalLength).first
    }

    /// The pages of one shot's objects: a page for each of `quads` (`CaptureObjects.pages`, sharing the
    /// photo's pixels; with `byShape`, a document's pages each measured by their own shape, `documentKind`), or
    /// the whole shot when none was found (`CaptureObjects.fallbackPage`).
    nonisolated static func objectPages(_ photo: RgbaImage, quads: [Quad], kind: CaptureKind,
                                        focalLength: Double?, byShape: Bool = false) -> [ScannedPage] {
        guard let image = photo.makeCGImage() else { return [] }
        if quads.isEmpty {
            return [CaptureObjects.fallbackPage(image)]
        }
        guard kind == .document && byShape else {
            return CaptureObjects.pages(image, quads: quads, kind: kind, focalLength: focalLength)
        }
        var pages: [ScannedPage] = []
        for quad in quads {
            let own: CaptureKind = documentKind(quad, width: photo.width, height: photo.height, focalLength: focalLength)
            pages += CaptureObjects.pages(image, quads: [quad], kind: own, focalLength: focalLength)
        }
        return pages
    }

    /// What a document page cut along `quad` is measured as: a receipt (the 80 and 57 mm rolls) when it is
    /// 2.2 times as long as wide or more, else a page (A4, Letter, Legal). Legal is 1.65, a DL envelope 2.0
    /// and a slip usually 3 or more, so a shape read a little off at a slant stays on its side.
    nonisolated static func documentKind(_ quad: Quad, width: Int, height: Int, focalLength: Double?) -> CaptureKind {
        let shape: Double = CaptureScale.aspect(quad, imageWidth: width, imageHeight: height,
                                                focalLength: focalLength).longOverShort
        return shape >= 2.2 ? CaptureKind.receipt : CaptureKind.document
    }

    /// Where the corner editor starts on a photo from our camera: the page as found in the photo when it
    /// was found clearly (`found.reason` `.none`) or the corner model found it there (`found.byModel`: its corners,
    /// refined on the photo itself, beat the preview's); else the outline the live preview showed
    /// (`liveOutline`, shares of the upright photo of `width` x `height`), in the photo's pixels, kept within
    /// the photo and named again, when the page can be cut out along it; else what the search gave.
    nonisolated static func seeded(_ found: IOSFoundPage, liveOutline: Quad?, width: Int, height: Int) -> IOSFoundPage {
        guard found.reason != PhotoReviewReason.none, !found.byModel, let outline = liveOutline, width > 0,
              height > 0 else { return found }
        let w: Double = Double(width)
        let h: Double = Double(height)
        var points: [CGPoint] = []
        for corner in outline.corners {
            let x: Double = Double(corner.x) * w
            let y: Double = Double(corner.y) * h
            guard x.isFinite, y.isFinite else { return found }
            points.append(CGPoint(x: min(max(x, 0), w), y: min(max(y, 0), h)))
        }
        let corners: Quad = Quad.fromCorners(points)
        guard PhotoImport.canUseCorners(corners) else { return found }
        return IOSFoundPage(corners: corners, reason: PhotoReviewReason.none, byModel: false)
    }

    /// Page `index` of the PDF in `data`, drawn at `IOSPDFPages.dpi`, as a page of the queue.
    nonisolated static func pdfPage(_ data: Data, fileName: String, index: Int) -> ScannedPage? {
        guard let document = try? IOSPDFPages.open(data, fileName: fileName),
              let rendered = IOSPDFPages.render(document, index: index) else { return nil }
        var page: ScannedPage = ScannedPage(image: rendered.image, dpi: rendered.dpi, colorMode: .color)
        page.source = .photo
        return page
    }
}

/// The item in hand once read: why it could not be, a PDF's bytes, or a photo file with its first page
/// read and searched (`IOSPhotoFile`).
enum IOSReadItem {
    case problem(String)
    case pdf(IOSImportItem)
    case photo(IOSPhotoFile)
}

/// A photo file in hand while its pages come in: its name and page count, page 1 read and searched until
/// it is taken (`takeFirst`), and the file's bytes only while more pages are to come (`rest`). A class,
/// so what is taken or dropped is let go even while the item itself is still referred to (the decoded
/// page 1 is not held while the pages after it are in the corner editor).
@MainActor
final class IOSPhotoFile {
    let name: String
    let pageCount: Int
    /// Its pages skip the corner editor when found clearly (`IOSImportSource.asksOnlyWhenUnsure`).
    let asksOnlyWhenUnsure: Bool
    /// What its pages were searched for (`CaptureObjects.kind(for:)` when it was read).
    let kind: CaptureKind
    /// The Items in frame a shot went by; nil for anything else.
    let items: IOSItemsInFrame?
    /// A shot of the camera's own Document: its pages are measured by their shape
    /// (`IOSImportSession.documentKind`).
    let byShape: Bool
    private var first: IOSPreparedPhoto?
    private(set) var rest: Data?

    init(name: String, pageCount: Int, first: IOSPreparedPhoto, rest: Data?, asksOnlyWhenUnsure: Bool = false,
         kind: CaptureKind = .document, items: IOSItemsInFrame? = nil, byShape: Bool = false) {
        self.name = name
        self.pageCount = pageCount
        self.first = first
        self.rest = rest
        self.asksOnlyWhenUnsure = asksOnlyWhenUnsure
        self.kind = kind
        self.items = items
        self.byShape = byShape
    }

    /// Page 1 read and searched, handed over once; nil after that.
    func takeFirst() -> IOSPreparedPhoto? {
        let taken: IOSPreparedPhoto? = first
        first = nil
        return taken
    }

    /// Lets the file's bytes go.
    func dropRest() {
        rest = nil
    }
}

/// A photo file's page count and its first page read and searched, off the main actor.
struct IOSFirstPage: Sendable {
    let pageCount: Int
    let prepared: IOSPreparedPhoto
}

/// A photo read and searched, off the main actor: the photo and where its page is, or why it could not
/// be read; `sure` when the photo's own search found the page clearly (before any live outline was used).
/// For receipts and photos, the objects found in it instead (`objects`, empty when none was); `splits` when a
/// document shot's pages were found in place of its page.
struct IOSPreparedPhoto: Sendable {
    let decoded: IOSDecodedPhoto?
    let found: IOSFoundPage?
    let problem: String?
    var sure: Bool = false
    var objects: [Quad] = []
    var splits: Bool = false

    /// Page `page` (from 1) of the photo file `data`, read and searched; `liveOutline` (shares of the
    /// upright photo) is the start where the corner model found no page in the photo and the search found none
    /// clearly (`IOSImportSession.seeded`).
    /// For receipts and photos (`kind`) its objects are searched for (`objectFinder`) instead of a page, the
    /// largest alone when `items` is One; for a document page with `items` Auto or Several, its loose pages
    /// too (`loosePages`), taken when there are two or more (one or more on Several), except on Auto when the
    /// page finder found a page, clearly or not, holding the middle of every one found; for an ID card the
    /// card first (sure only when its shape snaps to ID-1, `CaptureScale.measure`), then the page finder when
    /// no card was found.
    static func make(_ data: Data, fileName: String, page: Int = 1, finder: (RgbaImage) -> IOSFoundPage,
                     liveOutline: Quad? = nil, kind: CaptureKind = .document, items: IOSItemsInFrame? = nil,
                     objectFinder: ((RgbaImage, CaptureKind) -> [Quad])? = nil) -> IOSPreparedPhoto {
        do {
            let decoded: IOSDecodedPhoto = try IOSPhotoDecoder.decode(data, fileName: fileName, page: page)
            if CaptureObjects.findsSeveral(kind) {
                var objects: [Quad] = []
                if let search = objectFinder {
                    objects = search(decoded.photo, kind)
                }
                if items == .one, let largest = objects.max(by: { (a: Quad, b: Quad) -> Bool in a.area < b.area }) {
                    objects = [largest]
                }
                return IOSPreparedPhoto(decoded: decoded, found: nil, problem: nil, sure: !objects.isEmpty,
                                        objects: objects)
            }
            var finderPage: IOSFoundPage?
            if kind == .document, let items, items != .one, let search = objectFinder {
                if items == .auto {
                    finderPage = finder(decoded.photo)
                }
                // Sheets and slips lie loose on a table as receipts do: the receipts' search takes both shapes.
                let loose: [Quad] = search(decoded.photo, .receipt)
                // Slips or prints lying on a page found, clearly or not, or that page found again, are the
                // page. With nothing found the finder gives the start rectangle, which would hold them all.
                var onPage: Bool = false
                if let sheet = finderPage, sheet.reason != PhotoReviewReason.nothingFound {
                    onPage = loose.allSatisfy { (quad: Quad) -> Bool in sheet.corners.contains(quad.centroid) }
                }
                let pages: [Quad] = onPage ? [] : loosePages(loose, width: decoded.photo.width,
                                                             height: decoded.photo.height)
                if pages.count >= (items == .several ? 1 : 2) {
                    return IOSPreparedPhoto(decoded: decoded, found: nil, problem: nil, sure: true, objects: pages,
                                            splits: true)
                }
            }
            if kind == .idCard, let search = objectFinder, let card = search(decoded.photo, kind).first {
                // The picker allows more slack than the ID-1 snap: a card that would not snap is not sure,
                // so the editor opens on it rather than taking it at a made-up size.
                let scale: CaptureScaleResult = CaptureScale.measure(card, imageWidth: decoded.photo.width,
                                                                     imageHeight: decoded.photo.height, kind: .idCard,
                                                                     focalLength: decoded.focalLength)
                let reason: PhotoReviewReason = scale.isRealSize ? PhotoReviewReason.none : PhotoReviewReason.unsure
                let found = IOSFoundPage(corners: card, reason: reason, byModel: false)
                return IOSPreparedPhoto(decoded: decoded, found: found, problem: nil, sure: scale.isRealSize,
                                        objects: [card])
            }
            let searched: IOSFoundPage = finderPage ?? finder(decoded.photo)
            let found: IOSFoundPage = IOSImportSession.seeded(searched, liveOutline: liveOutline,
                                                              width: decoded.photo.width, height: decoded.photo.height)
            let sure: Bool = searched.reason == PhotoReviewReason.none
            return IOSPreparedPhoto(decoded: decoded, found: found, problem: nil, sure: sure)
        } catch let error as IOSImportError {
            return IOSPreparedPhoto(decoded: nil, found: nil, problem: error.message)
        } catch {
            let message: String = PhotoImport.unreadableMessage(fileName, detail: PhotoImport.unreadableDetail)
            return IOSPreparedPhoto(decoded: nil, found: nil, problem: message)
        }
    }

    /// The loose pages of a Document shot worth a page of their own: none under 3 % of the photo (a pen, a
    /// label) or under 15 % of the largest found. A phone beside an A4 sheet is more, about 17 % of the sheet
    /// and 9 % of the frame, so it comes in as a page unless Items in frame is One.
    static func loosePages(_ quads: [Quad], width: Int, height: Int) -> [Quad] {
        let largest: Double = quads.map(\.area).max() ?? 0
        let least: Double = max(0.03 * Double(width) * Double(height), 0.15 * largest)
        return quads.filter { (quad: Quad) -> Bool in quad.area >= least }
    }
}
#endif
