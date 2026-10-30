import CoreGraphics
import Foundation
import ImageIO

// Twin of windows/LazyScan.App/AppViewModel.Package.cs: a `.lsdoc` opened by hand (dropped,
// opened from Files or the Finder, or through the file association) is offered, not added: a banner
// adds its pages to the queue or opens it as a new one, unlike a paired phone's documents, which C1
// adds on its own. The queue can also be written as a `.lsdoc`, for the iPhone's share sheet.

/// The banner's texts for a `.lsdoc` opened by hand. Twin of C# `PackageText`.
public enum PackageText {
    public static let addToPages = "Add to pages"
    public static let openAsNew = "Open as new"
    public static let notOfferedMessage =
        "A document's pages are added to the page queue: choose Document mode, or a document task, with Collect pages before saving on, to add them."

    /// "Opened Receipt.lsdoc: 3 pages"
    public static func openedMessage(_ fileName: String, pageCount: Int) -> String {
        "Opened \(fileName): \(pageCount) page\(pageCount == 1 ? "" : "s")"
    }

    /// "Receipt.lsdoc cannot be opened: one of its pictures cannot be read."
    public static func unreadablePictureMessage(_ fileName: String) -> String {
        "\(fileName) cannot be opened: one of its pictures cannot be read."
    }
}

/// A `.lsdoc` opened by hand and waiting on the banner: its file's name, its pages decoded as the
/// queue takes them (`source == .phone`, as C1's), and the name its document carries ("" for none).
/// Twin of C# `PendingPackage`, plus the file it was read from (`url`), which says whether it came
/// from the paired desktop.
public struct PendingPackage {
    public let fileName: String
    public let url: URL
    public let pages: [ScannedPage]
    public let documentName: String

    public var pageCount: Int { pages.count }

    /// The package at `url` with every picture decoded and turned by the rotation still to apply, its
    /// side and sheet, its picture as photographed kept as the other version and what the camera
    /// recorded, as `CompanionPages.ToScannedPages` does for a phone's document added to the current
    /// one. Throws `CompanionPackageError`: a newer format is refused with `newerVersionMessage`, a
    /// picture that cannot be decoded, or whose header claims more than `PhotoImport.maxPhotoPixels`,
    /// with `PackageText.unreadablePictureMessage`.
    public static func read(_ url: URL) throws -> PendingPackage {
        let name = url.lastPathComponent
        // A file opened from a sandboxed place may need its access opened; harmless otherwise.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let document = try CompanionPackage.read(contentsOf: url)
        let created = Date()
        var pages: [ScannedPage] = []
        for source in document.pages {
            guard let image = picture(source.image, turns: source.rotationQuarterTurns) else {
                throw CompanionPackageError(.unsupportedImage, PackageText.unreadablePictureMessage(name))
            }
            var page = ScannedPage(image: image, dpi: source.image.dpi, colorMode: source.image.colorMode, createdAt: created)
            page.side = source.side
            page.sheetIndex = source.sheetIndex
            page.source = .phone
            page.capture = source.capture
            if let original = source.original {
                guard let photographed = picture(original, turns: source.rotationQuarterTurns) else {
                    throw CompanionPackageError(.unsupportedImage, PackageText.unreadablePictureMessage(name))
                }
                var other = ScannedPage(image: photographed, dpi: source.image.dpi, colorMode: source.image.colorMode,
                                        id: page.id, createdAt: created)
                other.side = source.side
                other.sheetIndex = source.sheetIndex
                other.source = .phone
                other.capture = source.capture
                page = other.withGeometry(image, geometry: PageGeometry(cropped: true, angleDegrees: 0, basis: .perspective))
            }
            pages.append(page)
        }
        let documentName = (document.suggestedName ?? document.title).trimmingCharacters(in: .whitespacesAndNewlines)
        return PendingPackage(fileName: name, url: url, pages: pages, documentName: documentName)
    }

    /// The pages as Open as new adds them: the first carries the document's name.
    public var asNewDocument: [ScannedPage] {
        guard !documentName.isEmpty, let first = pages.first else { return pages }
        var named = pages
        named[0] = first.withDocumentLabel(documentName)
        return named
    }

    private static func picture(_ image: CompanionImage, turns: Int) -> CGImage? {
        // A file opened by hand can come from anywhere, not only a paired phone: a picture too large
        // is turned down from its header, as an imported photo is, before decoding takes the memory.
        if let claimed = PhotoFileReader.headerPixelSize(image.data),
           PhotoFileReader.tooLarge(width: claimed.width, height: claimed.height) { return nil }
        guard let source = CGImageSourceCreateWithData(image.data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        guard !PhotoFileReader.tooLarge(width: width, height: height),
              let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return turns > 0 && turns <= 3 ? ImagePipeline.rotate(decoded, quarterTurns: turns) : decoded
    }
}

extension AppState {
    /// Reads the `.lsdoc` at `url` off the main actor and offers it (`pendingPackage`), replacing one
    /// offered before; a package that cannot be read is said in `errorMessage`. When another file is
    /// opened before the read ends, the read is dropped: the file opened last is the one offered. The
    /// queue is not touched, so a package can be opened while a scan runs.
    public func openPackage(at url: URL) async {
        packageOpens += 1
        let opening = packageOpens
        let read: Result<PendingPackage, Error> = await Task.detached(priority: .userInitiated) {
            Result { try PendingPackage.read(url) }
        }.value
        guard opening == packageOpens else { return }
        switch read {
        case .success(let package):
            pendingPackage = package
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }

    /// Add to pages: the offered pages join the queue after its pages (`ingest`, as a phone's pages).
    /// Returns whether they were taken; not while something runs or a review is open (the offer stays),
    /// nor while the settings do not collect pages (said in `errorMessage`).
    @discardableResult
    public func addPendingPackageToPages() -> Bool {
        guard let package = pendingPackage else { return false }
        return takePackage(package.pages)
    }

    /// Open as new: the queue is cleared and the offered pages become it, under the document's name.
    /// Refused as Add to pages is, or while a share or a send reads the pages (`readsQueue`), and the queue
    /// is then left alone.
    @discardableResult
    public func openPendingPackageAsNew() -> Bool {
        guard let package = pendingPackage, !readsQueue, canTakePackage() else { return false }
        clearPages()
        return takePackage(package.asNewDocument)
    }

    public func dismissPendingPackage() {
        guard let package = pendingPackage else { return }
        pendingPackage = nil
        receivedPackageAnswered(package)
    }

    private func canTakePackage() -> Bool {
        // Without Collect pages before saving, ingest would save the pages at once instead of queueing them.
        guard PhotoImport.isOffered(settings), settings.documentMultiPage else {
            errorMessage = PackageText.notOfferedMessage
            return false
        }
        return canIngest
    }

    private func takePackage(_ pages: [ScannedPage]) -> Bool {
        guard let package = pendingPackage, canTakePackage(), ingest(pages, source: .phone) else { return false }
        pendingPackage = nil
        receivedPackageAnswered(package)
        return true
    }

    /// Writes the queued pages as one `.lsdoc` in `folder`, named as the next saved file would be
    /// (the running number is read, not taken), and returns the file, for the share sheet. Each page
    /// is its picture as shown at full resolution, a black & white page as a bilevel TIFF and the
    /// others as a JPEG at the settings' quality, with its side, sheet and capture facts; the
    /// document breaks and the recognized text are not carried.
    public func exportPackage(to folder: URL) async throws -> URL {
        queueReaders += 1
        defer { queueReaders -= 1 }
        // Filters and crops tapped before land first: a cut takes its page's old file away.
        await pageEditChain?.value
        let pages = scannedPages
        guard !pages.isEmpty else { throw CompanionPackageError(.noPages, CompanionPackage.noPagesMessage) }
        let s = settings
        let counter = UserDefaults.standard.integer(forKey: Self.counterKey) + 1
        let name = NamingTemplate(s.namingTemplate)
            .baseFilename(NamingContext(counter: counter, date: Date(), intent: s.intent, task: TaskCatalog.infer(s),
                                        label: pages[0].documentLabel))
        let url = NamingTemplate.uniqueURL(in: folder, base: name, fileExtension: CompanionPackage.fileExtension)
        try await Task.detached(priority: .userInitiated) {
            var document = try Self.packageDocument(pages, name: name, jpegQuality: s.jpegQuality)
            document.created = Date()
            document.taskId = s.taskId
            document.namingTemplate = s.namingTemplate
            try CompanionPackage.make(document).write(to: url, options: .atomic)
        }.value
        return url
    }

    /// The pages as one package document named `name`. Twin of C# `CompanionPages.ToDocument`.
    nonisolated static func packageDocument(_ pages: [ScannedPage], name: String, jpegQuality: Double) throws
        -> CompanionDocument {
        var packaged: [CompanionPage] = []
        for (index, page) in pages.enumerated() {
            let full = fullImage(of: page)
            // A spooled page whose file went (the queue saved or cleared meanwhile) comes back as its
            // preview: refused rather than written small.
            guard page.fileURL == nil || full !== page.image else {
                throw CompanionPackageError(.invalidDocument,
                                            "\(CompanionPackage.subject(index + 1, original: false)) could not be written.")
            }
            let encoded: Data?
            let format: CompanionImageFormat
            if page.colorMode == .blackWhite {
                encoded = RgbaImage(cgImage: full).map { BilevelTIFF.make($0, dpi: page.dpi) }
                format = .tiff
            } else {
                encoded = PDFImageEncoding.encodeJPEG(full, quality: jpegQuality)
                format = .jpeg
            }
            guard let data = encoded else {
                throw CompanionPackageError(.invalidDocument,
                                            "\(CompanionPackage.subject(index + 1, original: false)) could not be written.")
            }
            let image = CompanionImage(data: data, format: format, pixelWidth: full.width, pixelHeight: full.height,
                                       dpi: page.dpi, colorMode: page.colorMode)
            packaged.append(CompanionPage(image: image, side: page.side, sheetIndex: page.sheetIndex, capture: page.capture))
        }
        #if os(iOS)
        let platform = "ios"
        #else
        let platform = "macos"
        #endif
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        return CompanionDocument(title: name, pages: packaged,
                                 writer: CompanionWriterInfo(app: "Lazy Scan", appVersion: version, platform: platform),
                                 suggestedName: name)
    }
}
