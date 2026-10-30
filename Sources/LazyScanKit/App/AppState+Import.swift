import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A photo whose page was not found clearly, for the corner editor: the photo (upright), what the page
/// search found and suggests (`PhotoImportPlan`), where it is in the import, and what is cut out of it,
/// which the editor's words name (`kind`: a page; on the iPhone also an ID card, and a photo or receipt for
/// Fix crop). Twin of the Windows `PhotoCornersRequest`.
public struct PhotoCornersRequest: Identifiable {
    public let id = UUID()
    public let photo: RgbaImage
    public let plan: PhotoImportPlan
    public let fileName: String
    public let number: Int
    public let count: Int
    public let kind: CaptureKind
    /// More photos or pages of the import follow this one: the Mac's editor then offers Stop import.
    public let moreFollow: Bool

    public init(photo: RgbaImage, plan: PhotoImportPlan, fileName: String, number: Int, count: Int,
                kind: CaptureKind = .document, moreFollow: Bool = false) {
        self.photo = photo
        self.plan = plan
        self.fileName = fileName
        self.number = number
        self.count = count
        self.kind = kind
        self.moreFollow = moreFollow
    }
}

/// The corner editor's answer: what to do with the photo, and the corners placed when they are used.
/// Twin of the Windows `PhotoCornersAnswer`.
public struct PhotoCornersAnswer: Sendable {
    public var choice: PhotoCornersChoice
    public var corners: Quad?

    public init(choice: PhotoCornersChoice, corners: Quad? = nil) {
        self.choice = choice
        self.corners = corners
    }

    public static let skip = PhotoCornersAnswer(choice: .skip)
}

/// A photo read for import: its pixels as stored, the turn its orientation tag asks for, its file's
/// name, and which page of the file it is (a TIFF may hold several; other files hold one). Twin of the
/// Windows `PhotoFile`.
struct PhotoFile: Sendable {
    let stored: RgbaImage
    let orientation: PhotoOrientation
    let fileName: String
    let page: Int
    let pageCount: Int

    /// The name the user sees: the file's name, with the page when the file holds several (`PhotoImport.pageName`).
    var displayName: String { PhotoImport.pageName(fileName, page: page, pageCount: pageCount) }
}

/// A photo file that could not be read; `message` says why, for the user. Twin of the Windows
/// `PhotoUnreadableException`.
struct PhotoUnreadableError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Reads photos of documents for import with ImageIO (JPEG, PNG, HEIC, TIFF, BMP, WebP): the file
/// is read once into memory and never written, moved or locked. A TIFF file may hold several pages (a
/// fax, a scan): each is read as a photo of its own (`decode` with its page); other files give their
/// main picture. The orientation tag is read, not applied: `PhotoImport.oriented` turns the pixels.
/// Twin of the Windows `PhotoFileReader` (WIC). Its header checks and page count are `package`: the
/// iPhone's photo decoder (`LazyScanIOS`) turns down the same photos before decoding them and
/// reads a TIFF's pages as the Mac does.
package enum PhotoFileReader {
    /// Page `page` (from 1) of the photo file at `url`: `readData`, then `decode`.
    static func read(_ url: URL, page: Int = 1) throws -> PhotoFile {
        try decode(readData(url), fileName: url.lastPathComponent, page: page)
    }

    /// The bytes of the file at `url`, read once. Throws `PhotoUnreadableError` with a message for the
    /// user when the file is gone or cannot be read.
    static func readData(_ url: URL) throws -> Data {
        let name = url.lastPathComponent
        // A file dropped from a sandboxed place may need its access opened; harmless otherwise.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PhotoUnreadableError(message: PhotoImport.unreadableMessage(name, detail: PhotoImport.missingDetail))
        }
        do {
            return try Data(contentsOf: url)
        } catch {
            throw PhotoUnreadableError(message: PhotoImport.unreadableMessage(name, detail: error.localizedDescription))
        }
    }

    /// How many pages the photo file `data` holds: a TIFF's pages, 1 for other files and for files that
    /// cannot be read (`decode` says why). Only the file's header is read, so a page that cannot be
    /// decoded does not hide the pages after it. `package`: the iPhone's photo decoder reads a TIFF's
    /// pages the same way.
    package static func pageCount(_ data: Data) -> Int {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return 1 }
        return pagesIn(source)
    }

    /// A TIFF's pages, 1 for other files.
    package static func pagesIn(_ source: CGImageSource) -> Int {
        let isTiff = CGImageSourceGetType(source).map { ($0 as String) == UTType.tiff.identifier } ?? false
        return isTiff ? max(1, CGImageSourceGetCount(source)) : 1
    }

    /// Page `page` (from 1) of the photo file `data` named `fileName`; its `pageCount` says how many
    /// pages the file holds. The size is read from the file's header before any pixel is decoded, so a
    /// photo of more than `PhotoImport.maxPhotoPixels` is turned down before its pixels take memory.
    static func decode(_ data: Data, fileName: String, page: Int = 1) throws -> PhotoFile {
        // ImageIO reports no size for a PNG or JPEG that claims more pixels than it holds (it does not
        // take the image at all), where WIC on Windows reports what the header says: read the header here.
        if let claimed = headerPixelSize(data), tooLarge(width: claimed.width, height: claimed.height) {
            throw PhotoUnreadableError(message: PhotoImport.unreadableMessage(fileName, detail: PhotoImport.tooLargeDetail))
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else {
            throw PhotoUnreadableError(message: PhotoImport.unreadableMessage(fileName, detail: PhotoImport.unreadableDetail))
        }
        let pageCount = pagesIn(source)
        let shown = PhotoImport.pageName(fileName, page: page, pageCount: pageCount)
        guard page >= 1, page <= pageCount else {
            throw PhotoUnreadableError(message: PhotoImport.unreadableMessage(shown, detail: PhotoImport.unreadableDetail))
        }
        let index = page - 1
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        if tooLarge(width: width, height: height) {
            throw PhotoUnreadableError(message: PhotoImport.unreadableMessage(shown, detail: PhotoImport.tooLargeDetail))
        }
        // The tag ImageIO reports for JPEG, HEIF and TIFF alike; the image itself comes unturned.
        let tag = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        guard let image = CGImageSourceCreateImageAtIndex(source, index, nil), let stored = RgbaImage(cgImage: image) else {
            throw PhotoUnreadableError(message: PhotoImport.unreadableMessage(shown, detail: PhotoImport.unreadableDetail))
        }
        return PhotoFile(stored: stored, orientation: PhotoOrientation.fromExif(tag), fileName: fileName,
                         page: page, pageCount: pageCount)
    }

    /// More than `PhotoImport.maxPhotoPixels`; a damaged header may claim sizes whose product does not
    /// fit an Int, which is too large all the same.
    package static func tooLarge(width: Int, height: Int) -> Bool {
        let pixels = width.multipliedReportingOverflow(by: height)
        return pixels.overflow || pixels.partialValue > PhotoImport.maxPhotoPixels
    }

    /// The pixel size a PNG (its IHDR) or JPEG (its first start-of-frame) header claims, read from the
    /// bytes alone; nil for other files and for headers cut short.
    package static func headerPixelSize(_ data: Data) -> (width: Int, height: Int)? {
        let b = [UInt8](data.prefix(1 << 20))
        func be16(_ at: Int) -> Int { (Int(b[at]) << 8) | Int(b[at + 1]) }
        func be32(_ at: Int) -> Int { (be16(at) << 16) | be16(at + 2) }
        let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        if b.starts(with: pngSignature) {
            // Signature, then the IHDR chunk: length, "IHDR", width, height.
            guard b.count >= 24, Array(b[12..<16]) == Array("IHDR".utf8) else { return nil }
            return (be32(16), be32(20))
        }
        guard b.count >= 4, b[0] == 0xFF, b[1] == 0xD8 else { return nil }
        var at = 2
        while at + 4 <= b.count {
            guard b[at] == 0xFF else { return nil }
            let marker = b[at + 1]
            if marker == 0xFF { at += 1; continue } // fill byte
            // Markers without a length: TEM, RST0-7, SOI.
            if marker == 0x01 || (0xD0...0xD8).contains(marker) { at += 2; continue }
            if marker == 0xD9 || marker == 0xDA { return nil } // end of image, start of scan: no frame header first
            let length = be16(at + 2)
            guard length >= 2 else { return nil }
            // SOF0-15, but DHT (C4), JPG (C8) and DAC (CC): length, precision, height, width.
            if (0xC0...0xCF).contains(marker) && marker != 0xC4 && marker != 0xC8 && marker != 0xCC {
                guard at + 9 <= b.count else { return nil }
                return (be16(at + 7), be16(at + 5))
            }
            at += 2 + length
        }
        return nil
    }
}

/// Importing photos of documents as pages of the queue (Import photos… in the inspector, or photos
/// dropped on the scanner view), `PhotoImport`. Twin of the Windows `AppViewModel.Import.cs`.
extension AppState {
    /// Photos can be imported now: the settings collect pages in the queue (`PhotoImport.isOffered`),
    /// nothing else is running, no review is open, and no stack is being turned over by hand.
    public var canImportPhotos: Bool {
        !isBusy && PhotoImport.isOffered(settings) && !isTurningOverByHand && !showPhotoReview && !showIdCardReview
    }

    /// Adds the photos among `urls` to the queue, one after another: each is read (the file itself is
    /// never changed), turned upright by its orientation tag, its page found and cut out along its
    /// corners; a photo whose page is not found clearly goes to the corner editor (`cornerReview`),
    /// which may also take the whole photo or skip it. Each page goes through the clean-up stage
    /// (`PageProcessor.forPhotoImport`), is spooled with the photo as its other version and added to the
    /// queue at once, so a Cancel keeps the pages already added. Each page of a TIFF of several pages is
    /// imported as a photo of its own. Photos that cannot be read (too large ones too) are listed in one
    /// error at the end; the others are imported. Twin of the Windows `AppViewModel.ImportPhotos`.
    public func importPhotos(_ urls: [URL]) {
        guard !isBusy else { return }
        let files = PhotoImport.photoFiles(urls.map(\.path)).map { URL(fileURLWithPath: $0) }
        guard !files.isEmpty, canImportPhotos else {
            if !urls.isEmpty { errorMessage = files.isEmpty ? PhotoImport.noPhotosMessage : PhotoImport.notOfferedMessage }
            return
        }
        let s = settings
        let scorer = orientationScorer
        let barcodes = barcodeReader
        let model = cornerModel
        let spool = spoolDirectory
        runExclusive { flag in
            var added: [ScannedPage] = []
            var problems: [String] = []
            var skipped = 0
            var lastPreview: CGImage?
            var lastSize: CGSize?
            do {
                for (index, url) in files.enumerated() {
                    if flag.isCancelled { throw ScanError.cancelled }
                    self.statusMessage = PhotoImport.progressMessage(index + 1, of: files.count)
                    let loaded: Result<Data, Error> = await Task.detached(priority: .userInitiated) {
                        Result { try PhotoFileReader.readData(url) }
                    }.value
                    let data: Data
                    switch loaded {
                    case .success(let bytes):
                        data = bytes
                    case .failure(let error):
                        problems.append((error as? PhotoUnreadableError)?.message
                                        ?? PhotoImport.unreadableMessage(url.lastPathComponent, detail: PhotoImport.unreadableDetail))
                        continue
                    }
                    // A TIFF may hold several pages: each is imported in turn. Their count is read from the
                    // file's header, so a page that cannot be decoded does not end the file's import.
                    let pageCount = await Task.detached(priority: .userInitiated) { PhotoFileReader.pageCount(data) }.value
                    for number in 1...pageCount {
                        if flag.isCancelled { throw ScanError.cancelled }
                        let read: Result<PhotoFile, Error> = await Task.detached(priority: .userInitiated) {
                            Result { try PhotoFileReader.decode(data, fileName: url.lastPathComponent, page: number) }
                        }.value
                        let file: PhotoFile
                        switch read {
                        case .success(let photoFile):
                            file = photoFile
                        case .failure(let error):
                            problems.append((error as? PhotoUnreadableError)?.message
                                            ?? PhotoImport.unreadableMessage(url.lastPathComponent, detail: PhotoImport.unreadableDetail))
                            continue
                        }
                        if pageCount > 1 {
                            self.statusMessage = PhotoImport.progressMessage(index + 1, of: files.count, page: number, pageCount: pageCount)
                        }
                        let prepared: (RgbaImage, PhotoImportPlan) = await Task.detached(priority: .userInitiated) {
                            let upright = PhotoImport.oriented(file.stored, orientation: file.orientation)
                            return (upright, PhotoImport.plan(upright, model: model))
                        }.value
                        let photo = prepared.0, plan = prepared.1
                        if flag.isCancelled { throw ScanError.cancelled }
                        var page: ScannedPage?
                        if plan.action == .correct {
                            page = await Task.detached(priority: .userInitiated) {
                                PhotoImport.correctedPage(photo, corners: plan.corners)
                            }.value
                        }
                        if page == nil {
                            let request = PhotoCornersRequest(photo: photo, plan: plan, fileName: file.displayName,
                                                              number: index + 1, count: files.count,
                                                              moreFollow: index + 1 < files.count || number < pageCount)
                            let answer = await self.askCorners(request)
                            if flag.isCancelled { throw ScanError.cancelled }
                            switch answer.choice {
                            case .useCorners:
                                if let corners = answer.corners {
                                    page = await Task.detached(priority: .userInitiated) {
                                        PhotoImport.correctedPage(photo, corners: corners) ?? PhotoImport.wholePhotoPage(photo)
                                    }.value
                                }
                            case .wholePhoto:
                                page = await Task.detached(priority: .userInitiated) { PhotoImport.wholePhotoPage(photo) }.value
                            case .skip:
                                break
                            }
                        }
                        guard let cleaned = page else {
                            skipped += 1
                            continue
                        }
                        // The clean-up stage, then spill the page and the photo it was taken from to disk; keep
                        // only previews in the queue.
                        let done: ([ScannedPage], CGImage?) = try await Task.detached(priority: .userInitiated) {
                            let processed = try PageProcessor.forPhotoImport(s, scorer: scorer, barcodes: barcodes)
                                .process([cleaned], shouldContinue: { !flag.isCancelled }).pages
                            return (Self.spoolPages(processed, to: spool), Self.makePreview(cleaned.image, maxSide: 2600))
                        }.value
                        let spooled = done.0
                        if flag.isCancelled {
                            self.deleteSpoolFiles(of: spooled)
                            throw ScanError.cancelled
                        }
                        self.scannedPages.append(contentsOf: spooled)
                        added.append(contentsOf: spooled)
                        self.recordCaptures(spooled.map(\.id))
                        lastPreview = done.1
                        lastSize = CGSize(width: cleaned.image.width, height: cleaned.image.height)
                    }
                }
            } catch ScanError.cancelled {
                // The pages added before Cancel stay in the queue.
                if let lastPreview { self.setLastScan(preview: lastPreview, pixelSize: lastSize) }
                self.statusMessage = PhotoImport.cancelledMessage(added: added.count, queueCount: self.scannedPages.count)
                if !problems.isEmpty { self.errorMessage = problems.joined(separator: "\n") }
                return
            }
            if let lastPreview { self.setLastScan(preview: lastPreview, pixelSize: lastSize) }
            self.statusMessage = PhotoImport.addedMessage(added: added.count, skipped: skipped, failed: problems.count,
                                                          queueCount: self.scannedPages.count,
                                                          saveTitle: self.settings.format.saveTitle)
            if !added.isEmpty {
                self.statusMessage += self.queueScanNote(added, options: s.document)
                if s.document.autoRotate && !scorer.isAvailable { self.statusMessage += PageTurns.unavailableNote }
                // Pages queued earlier and never read (a reading stopped) are read once the import is done.
                if PageProcessor.readsBarcodes(self.settings) { self.readBarcodesAfterWork = true }
            }
            if !problems.isEmpty { self.errorMessage = problems.joined(separator: "\n") }
        }
    }

    /// Shows the corner editor for `request` and waits for the user's answer (`answerCorners`).
    func askCorners(_ request: PhotoCornersRequest) async -> PhotoCornersAnswer {
        await withCheckedContinuation { (continuation: CheckedContinuation<PhotoCornersAnswer, Never>) in
            cornerReviewContinuation = continuation
            cornerReview = request
        }
    }

    /// The corner editor's answer: the import waiting for it goes on. A second answer (the sheet
    /// dismissed after a button closed it) changes nothing.
    public func answerCorners(_ answer: PhotoCornersAnswer) {
        guard let continuation = cornerReviewContinuation else { return }
        cornerReviewContinuation = nil
        cornerReview = nil
        continuation.resume(returning: answer)
    }
}
