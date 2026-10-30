import CryptoKit
import Foundation

// Twin of windows/LazyScan.Core/PdfAppender.cs: the same update, byte for byte, with the same
// refusals and messages. The file is opened with open(2) for reading and writing where C# opens a
// FileStream that shares reading only: a read-only file is refused the same way, but another app is
// seen to have the file open only when it holds a lock on it (flock), since nothing else here says
// so. The checked temporary file takes the original's place through FileManager.replaceItemAt where
// C# calls ReplaceFile, with the same backup name in the same folder and the same LeftAsBackup
// outcome; its leading dot hides it, as on every system but Windows. Cancelling is `shouldContinue`,
// polled where C# checks its token.

/// Why pages could not be added to a PDF (`PDFAppendError`).
public enum PDFAppendProblem: CaseIterable, Equatable, Sendable {
    /// The file is not a PDF.
    case notPdf
    /// Its cross-reference data or page tree does not hold up.
    case damaged
    /// It is password-protected (encrypted).
    case encrypted
    /// It is laid out in a way the reader does not handle (bytes before the header, a filter other
    /// than Flate).
    case unsupported
    /// It is read-only, or the user may not change it.
    case readOnly
    /// Another app has it open.
    case inUse
    /// It is no longer where it was picked.
    case missing
    /// It changed while the pages were being added.
    case changed
    /// The updated file did not read back as it should (the original stays as it was).
    case notVerified
    /// The updated file could not be written next to it, say on a full disk (the original stays as
    /// it was).
    case notWritten
    /// The original was moved aside to be replaced, the replacement failed and it could not be moved
    /// back: it is in its folder under the backup name the message gives
    /// (`PDFAppender.leftAsBackupMessage(_:backupName:)`).
    case leftAsBackup
}

/// Pages were not added; `message` says why in words for the user.
public struct PDFAppendError: LocalizedError {
    public let problem: PDFAppendProblem
    public let message: String
    /// What failed underneath (C#'s inner exception); nil when nothing did.
    public let underlying: (any Error)?

    public init(_ problem: PDFAppendProblem, _ message: String, underlying: (any Error)? = nil) {
        self.problem = problem
        self.message = message
        self.underlying = underlying
    }

    public var errorDescription: String? { message }
}

/// A PDF pages are about to be added to, as read before anything is written
/// (`PDFAppender.inspect(path:)`).
public struct PDFAppendTarget: Equatable, Sendable {
    /// The file.
    public let path: String
    /// Its pages now.
    public let pageCount: Int
    /// It carries a signature (`PDFReaderLite.isSigned`).
    public let isSigned: Bool
    /// The PDF/A part it claims; nil when it claims none.
    public let pdfAPart: Int?
    /// The PDF/A level it claims ("A", "B", "U"); nil when none.
    public let pdfAConformance: String?
    /// It claims PDF/A and the added pages keep it so (see `PDFAppender.keepsPdfA`).
    public let keepsPdfA: Bool
    /// Its signature is a certification, which adding pages breaks (`PDFReaderLite.isCertified`).
    public let isCertified: Bool

    public init(path: String, pageCount: Int, isSigned: Bool, pdfAPart: Int?, pdfAConformance: String?,
                keepsPdfA: Bool, isCertified: Bool = false) {
        self.path = path
        self.pageCount = pageCount
        self.isSigned = isSigned
        self.pdfAPart = pdfAPart
        self.pdfAConformance = pdfAConformance
        self.keepsPdfA = keepsPdfA
        self.isCertified = isCertified
    }

    public var isPdfA: Bool { pdfAPart != nil }

    /// What the user should know before pages are added: the signature, a PDF/A level that may not
    /// be kept.
    public var warnings: [String] {
        let name = (path as NSString).lastPathComponent
        var warnings: [String] = []
        if isCertified {
            warnings.append(PDFAppender.certifiedWarning(name))
        } else if isSigned {
            warnings.append(PDFAppender.signedWarning(name))
        }
        if let part = pdfAPart, !keepsPdfA {
            warnings.append(PDFAppender.pdfAWarning(name, part: part, conformance: pdfAConformance))
        }
        return warnings
    }

    /// The question asked before adding pages despite `warnings`; nil when there are none.
    public var confirmMessage: String? {
        let warnings = self.warnings
        if warnings.isEmpty { return nil }
        return warnings.joined(separator: "\n\n") + "\n\n" + PDFAppender.confirmQuestion
    }
}

/// Pages added to a file.
public struct PDFAppendResult: Equatable, Sendable {
    public let path: String
    public let pagesBefore: Int
    public let pagesAdded: Int
    public let bytes: Int

    public init(path: String, pagesBefore: Int, pagesAdded: Int, bytes: Int) {
        self.path = path
        self.pagesBefore = pagesBefore
        self.pagesAdded = pagesAdded
        self.bytes = bytes
    }

    public var pageCount: Int { pagesBefore + pagesAdded }
}

/// Fixed values for tests: the update's new file identifier.
public struct PDFAppendOptions: Sendable {
    /// The identifier's second half after the update (16 bytes); nil: random.
    public var documentId: [UInt8]?

    public init(documentId: [UInt8]? = nil) {
        self.documentId = documentId
    }
}

/// Adds scanned pages to the end of an existing PDF as an incremental update (ISO 32000-1 7.5.6):
/// the original bytes stay exactly as they are, and after them come the new pages' objects (written
/// as `PDFWriter` writes pages, with their image and text layer), the page tree's root again with the
/// new pages added to its /Kids and its /Count, and a cross-reference section of the same kind as the
/// file's newest one (a table, or an uncompressed stream) whose trailer points back at the earlier
/// one (/Prev).
///
/// The new pages hang off the root of the page tree and say their own /MediaBox, /Resources and
/// /Rotate 0 (and /CropBox, when the root has one), so nothing the root passes down to its pages
/// changes them. They use their own copy of the text layer's font.
///
/// Encrypted, damaged and unsupported files are refused (`PDFAppendError`). A file is never changed
/// in place: the original and the update are written to a hidden temporary file next to it, which is
/// read back (page count, the original bytes unchanged at its start) before it replaces the original
/// (`FileManager.replaceItemAt`, keeping the original's creation date and permissions). Every failure
/// is a `PDFAppendError` whose message is for the user.
public enum PDFAppender {
    public static let buttonLabel = "Add to existing PDF…"
    public static let buttonHint = "Add the pages to the end of a PDF you choose"
    public static let savedMenuLabel = "Add the scanned pages to this PDF"
    public static let savedMenuHint = "Add the pages waiting to be saved to the end of this PDF"
    public static let pickerTitle = "Add the pages to which PDF?"
    public static let confirmQuestion = "Add the pages anyway?"

    /// The other item of the Save button's menu, beside `buttonLabel`.
    public static let saveAsNewLabel = "Save as new PDF"

    /// The Save button while the queue goes into a picked PDF (`AppState.appendTarget`).
    public static func saveTitle(_ fileName: String) -> String {
        "Add to \(fileName)"
    }

    /// Said after adding pages while Protect with a password is on: the file decides, and it has none.
    public static let noPasswordNote = "The file has no password, so the added pages have none either."

    /// Why pages could not be added to `fileName`.
    public static func message(_ problem: PDFAppendProblem, _ fileName: String) -> String {
        switch problem {
        case .notPdf:
            return "\(fileName) is not a PDF, so pages can't be added to it."
        case .damaged:
            return "\(fileName) looks damaged, so pages can't be added to it safely. Save them as a new PDF instead."
        case .encrypted:
            return "\(fileName) is password-protected, so pages can't be added to it. Save them as a new PDF instead."
        case .unsupported:
            return "\(fileName) is laid out in a way pages can't be added to here. Save them as a new PDF instead."
        case .readOnly:
            return "\(fileName) can't be changed: it is read-only, or you don't have permission to change it."
        case .inUse:
            return "\(fileName) is open in another app. Close it there, then add the pages again."
        case .missing:
            return "\(fileName) is no longer in its folder. It may have been moved, renamed or deleted."
        case .changed:
            return "\(fileName) was changed by another app while the pages were being added, so it was left as it was. Try again."
        case .notWritten:
            return "The pages could not be added to \(fileName): the updated file could not be written in its folder (the disk may be full), so the original was left as it was."
        case .leftAsBackup:
            return leftAsBackupMessage(fileName, backupName: nil)
        case .notVerified:
            return "The pages could not be added to \(fileName): the updated file did not check out, so the original was left as it was."
        }
    }

    /// For `PDFAppendProblem.leftAsBackup`: where the unchanged file is now, so the user can find it
    /// (`backupName`, the backup's file name; nil: not known).
    public static func leftAsBackupMessage(_ fileName: String, backupName: String?) -> String {
        var text = "The pages could not be added to \(fileName), and the file could not be put back under its name. "
        text += "It is unchanged, in the same folder, "
        if let backupName {
            text += "named \(backupName)"
        } else {
            text += "under a name ending in .pdf.bak"
        }
        text += ". Rename it back to \(fileName), then add the pages again."
        return text
    }

    public static func signedWarning(_ fileName: String) -> String {
        "\(fileName) is signed. Adding pages keeps the signature, but PDF apps will show that the file was changed after it was signed."
    }

    /// For a certified file (`PDFReaderLite.isCertified`): no certification allows adding pages.
    public static func certifiedWarning(_ fileName: String) -> String {
        "\(fileName) is certified. Its certification does not allow adding pages, so PDF apps will show the certification as no longer valid."
    }

    public static func pdfAWarning(_ fileName: String, part: Int, conformance: String?) -> String {
        let level = conformance?.lowercased() ?? ""
        return "\(fileName) is a PDF/A-\(part)\(level) file. The added pages may not meet that standard, so it may no longer pass as PDF/A."
    }

    /// "Added 2 pages to Contract.pdf (now 11 pages, 1.4 MB)", as a save says "Saved …".
    public static func addedMessage(_ added: Int, fileName: String, pageCount: Int, size: String?) -> String {
        let addedPages = added == 1 ? "page" : "pages"
        let allPages = pageCount == 1 ? "page" : "pages"
        let sizeText = size.map { ", " + $0 } ?? ""
        return "Added \(added) \(addedPages) to \(fileName) (now \(pageCount) \(allPages)\(sizeText))"
    }

    /// The added pages keep the file's PDF/A claim when it is part 1, 2 or 3 at level B or U (level A
    /// also asks for a structure the new pages do not have) and its output intent is RGB, which covers
    /// the pages' color images; their font is embedded, and the update keeps the file identifier, the
    /// metadata and the document information as they were.
    public static func keepsPdfA(part: Int?, conformance: String?, outputIntentComponents: Int?) -> Bool {
        guard outputIntentComponents == 3, let part, let conformance else { return false }
        switch part {
        case 1:
            return conformance == "B"
        case 2, 3:
            return conformance == "B" || conformance == "U"
        default:
            return false
        }
    }

    /// Reads what adding pages to `path` means, checking it can be changed; throws `PDFAppendError`.
    public static func inspect(path: String) throws -> PDFAppendTarget {
        let full = fullPath(path)
        let handle = try openForUpdate(full)
        defer { try? handle.close() }
        let reader = try read(handle, full)
        return try describe(reader, path: full)
    }

    package static func describe(_ reader: PDFReaderLite, path: String) throws -> PDFAppendTarget {
        if reader.isEncrypted { throw refusal(.encrypted, path) }
        // The signature and the output intent are read now, from objects the page tree did not need.
        return try mapped(path) { () throws -> PDFAppendTarget in
            let part = try reader.pdfAPart
            let conformance = try reader.pdfAConformance
            let signed = try reader.isSigned
            var keeps = false
            if part != nil {
                let components = try reader.outputIntentComponents
                keeps = keepsPdfA(part: part, conformance: conformance, outputIntentComponents: components)
            }
            let certified = try reader.isCertified
            return PDFAppendTarget(path: path, pageCount: reader.pageCount, isSigned: signed, pdfAPart: part,
                                   pdfAConformance: conformance, keepsPdfA: keeps, isCertified: certified)
        }
    }

    /// The original with `pages` added, in memory.
    public static func append(_ original: Data, pages: [PDFPageInput], options: PDFAppendOptions? = nil) throws -> Data {
        let reader = try PDFReaderLite(data: original)
        if reader.isEncrypted { throw PDFReadError(.encrypted, "The file is encrypted.") }
        var result = original
        try writeUpdate(reader, into: { chunk in result.append(chunk) }, pages: pages, options: options)
        return result
    }

    /// Writes the update for `pages` to `output`, which already holds the file `reader` read (all of
    /// it, in order). Starts with an end of line when the file does not end with one. `progress`
    /// hears "Adding page n of m…" before each page; `shouldContinue` is polled before each page,
    /// and returning false aborts with `ScanError.cancelled`.
    public static func writeUpdate(_ reader: PDFReaderLite, into output: @escaping (Data) throws -> Void,
                                   pages: [PDFPageInput], options: PDFAppendOptions? = nil,
                                   progress: ((String) -> Void)? = nil,
                                   shouldContinue: (() -> Bool)? = nil) throws {
        if pages.isEmpty { throw ScanError.exportFailed("There are no pages to add.") }
        if reader.isEncrypted { throw PDFReadError(.encrypted, "The file is encrypted.") }
        guard let root = reader.pagesRoot, let rootDictionary = reader.pagesRootDictionary,
              let catalogRoot = reader.root else {
            throw PDFReadError.damaged("The catalog has no page tree (/Pages).")
        }
        guard let oldKids = try reader.resolve(rootDictionary["Kids"]) as? PDFArray else {
            throw PDFReadError.damaged("The page tree's root has no /Kids.")
        }

        var hasText = false
        var texts: [String] = []
        for page in pages {
            guard let lines = page.ocrLines else { continue }
            if !lines.isEmpty { hasText = true }
            for line in lines { texts.append(line.text) }
        }

        // Every new object, and an update's cross-reference stream, within PDF's object numbers.
        var lastObject = reader.nextObjectNumber + pages.count * 3 - 1
        if hasText { lastObject += 6 }
        if reader.xrefIsStream { lastObject += 1 }
        if lastObject > PDFReaderLite.maxObjectNumber {
            throw PDFReadError(.unsupported, "The file has no object numbers left for the new pages.")
        }

        var position = reader.length
        let last = try reader.byteAt(position - 1)
        if last != 10 && last != 13 {
            try output(Data([0x0A]))
            position += 1
        }
        let w = try PDFObjectWriter(position: position, output: output)
        let codes = GlyphlessCodes.of(texts)
        var next = reader.nextObjectNumber
        let fontObject = hasText ? next : 0
        if hasText { next += 6 }
        let firstPage = next
        next += pages.count * 3

        let rootGeneration = reader.generationOf(root.number)
        let parent = "\(root.number) \(rootGeneration) R"
        let rootHasCropBox = rootDictionary.contains("CropBox")

        if hasText { try PDFWriter.writeTextFont(w, first: fontObject, codes: codes) }
        var kids: [any PDFObject] = oldKids.items
        for i in 0..<pages.count {
            if shouldContinue?() == false { throw ScanError.cancelled }
            progress?("Adding page \(i + 1) of \(pages.count)…")
            let page = pages[i]
            var extra = " /Rotate 0"
            if rootHasCropBox {
                let dpi = Double(max(page.dpi, 1))
                let width = PDFWriter.f(Double(page.pixelWidth) / dpi * 72.0)
                let height = PDFWriter.f(Double(page.pixelHeight) / dpi * 72.0)
                extra += " /CropBox [0 0 \(width) \(height)]"
            }
            let pageObject = firstPage + i * 3
            try PDFWriter.writePage(w, pageObject: pageObject, imageObject: pageObject + 1,
                                    contentsObject: pageObject + 2, parent: parent, index: i, page: page,
                                    fontObject: fontObject, codes: codes, extraEntries: extra)
            kids.append(PDFReference(pageObject, 0))
        }

        // The root again: its kids end with the new pages, its count says every page under it.
        let updatedRoot = rootDictionary.copy()
        updatedRoot["Kids"] = PDFArray(kids)
        updatedRoot["Count"] = PDFNumber(reader.pageCount + pages.count)
        try w.writeObject(root.number, generation: rootGeneration, updatedRoot.description)

        var newId: [UInt8] = []
        if let given = options?.documentId, given.count == 16 {
            newId = given
        } else {
            newId = try PDFEncryption.randomBytes(PDFEncryption.systemRandom, 16)
        }
        var firstId = PDFEncryption.hex(newId)
        if let ids = try reader.resolve(reader.trailer["ID"]) as? PDFArray, !ids.items.isEmpty,
           let original = try reader.resolve(ids.items[0]) as? PDFString {
            firstId = PDFEncryption.hex(original.bytes)
        }
        var trailer = " /Root "
        catalogRoot.write(to: &trailer)
        if let info = reader.trailer["Info"], !(info is PDFNull), !(info is PDFStream) {
            trailer += " /Info "
            info.write(to: &trailer)
        }
        trailer += " /ID [<\(firstId)> <\(PDFEncryption.hex(newId))>] /Prev \(reader.startXref)"

        if reader.xrefIsStream {
            let xrefObject = next
            try w.finishUpdateStream(xrefObject, "/Size \(xrefObject + 1)\(trailer)")
        } else {
            try w.finishUpdate("/Size \(next)\(trailer)")
        }
    }

    /// Adds `pages` to the end of the PDF at `path`. The file is held open (with a shared lock, so
    /// apps that lock files may read it, not change it) while the original and the update are written
    /// to a hidden temporary file in its folder (on the iPhone in the system's folder for replacing
    /// it, since a file picked in Files comes without its folder); that file is read back and must
    /// have the original's bytes at its start, an update pointing back at the original's last section
    /// and every page;
    /// then it takes the original's place (`replaceOriginal(_:_:)`), keeping what belongs to the file
    /// rather than to its bytes. Any failure leaves the original as it was (under its backup name in
    /// the one case `PDFAppendProblem.leftAsBackup` says), removes the temporary file and is a
    /// `PDFAppendError`; cancelling is `ScanError.cancelled`.
    @discardableResult
    public static func appendToFile(path: String, pages: [PDFPageInput], progress: ((String) -> Void)? = nil,
                                    shouldContinue: (() -> Bool)? = nil,
                                    options: PDFAppendOptions? = nil) throws -> PDFAppendResult {
        if pages.isEmpty { throw ScanError.exportFailed("There are no pages to add.") }
        let full = fullPath(path)
        let manager = FileManager.default
        let original = try openForUpdate(full)
        var isOpen = true
        defer {
            if isOpen { try? original.close() }
        }
        #if os(iOS)
        let directory: String
        do {
            directory = try manager.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                        appropriateFor: URL(fileURLWithPath: full), create: true).path
        } catch {
            throw refusal(.notWritten, full, error)
        }
        defer { try? manager.removeItem(atPath: directory) }
        #else
        let directory = (full as NSString).deletingLastPathComponent
        #endif
        let tmp = (directory as NSString).appendingPathComponent(".\(UUID().uuidString).pdf.tmp")
        do {
            let reader = try read(original, full)
            let target = try describe(reader, path: full)
            let length = reader.length
            let attributes = try manager.attributesOfItem(atPath: full)
            let written = attributes[.modificationDate] as? Date
            let created = attributes[.creationDate] as? Date
            let permissions = attributes[.posixPermissions] as? NSNumber
            let hash = try writeTemporary(tmp, from: original, length: length, reader: reader, pages: pages,
                                          options: options, progress: progress, shouldContinue: shouldContinue,
                                          path: full)
            try verify(tmp, originalLength: length, originalHash: hash, pageCount: target.pageCount + pages.count,
                       previousXref: reader.startXref, sections: reader.sectionCount + 1, path: full)

            try? original.close()
            isOpen = false
            // The lock binds only apps that lock too: it must still be the file that was read.
            let now = try? manager.attributesOfItem(atPath: full)
            let nowLength = (now?[.size] as? NSNumber)?.intValue
            let nowWritten = now?[.modificationDate] as? Date
            if nowLength != length || nowWritten != written { throw refusal(.changed, full) }
            var metadata: [FileAttributeKey: Any] = [:]
            if let created { metadata[.creationDate] = created }
            if let permissions { metadata[.posixPermissions] = permissions }
            // Cosmetic, and replaceItemAt keeps them too: the pages are what matters.
            try? manager.setAttributes(metadata, ofItemAtPath: tmp)
            try replaceOriginal(tmp, full)
            let after = try? manager.attributesOfItem(atPath: full)
            let bytes = (after?[.size] as? NSNumber)?.intValue ?? 0
            return PDFAppendResult(path: full, pagesBefore: target.pageCount, pagesAdded: pages.count, bytes: bytes)
        } catch {
            try? manager.removeItem(atPath: tmp)
            throw error
        }
    }

    /// The checked temporary file takes the original's place with `FileManager.replaceItemAt`, which
    /// keeps what belongs to the original file rather than to its bytes (its creation date and
    /// permissions). The original is moved aside under a backup name in the same folder meanwhile and
    /// removed after. When the new file then cannot take the name and the original is left under the
    /// backup name, it is moved back; if that also fails it stays there, which the refusal gives
    /// (`PDFAppendProblem.leftAsBackup`). The iPhone keeps no backup, as its folder may take no new
    /// file (see `appendToFile`): the two files swap places, or nothing changes.
    package static func replaceOriginal(_ tmp: String, _ path: String) throws {
        let manager = FileManager.default
        #if os(iOS)
        let backupName: String? = nil
        #else
        let backupName: String? = ".\(UUID().uuidString).pdf.bak"
        #endif
        do {
            _ = try manager.replaceItemAt(URL(fileURLWithPath: path), withItemAt: URL(fileURLWithPath: tmp),
                                          backupItemName: backupName, options: [])
        } catch {
            if !manager.fileExists(atPath: path) {
                // The original was moved aside, but the new file could not take its name.
                if let backupName {
                    let folder = (path as NSString).deletingLastPathComponent
                    let backup = (folder as NSString).appendingPathComponent(backupName)
                    if manager.fileExists(atPath: backup) { throw putBack(backup, path, cause: error) }
                }
                throw refusal(.missing, path, error)
            }
            if let cocoa = error as? CocoaError,
               cocoa.code == .fileWriteNoPermission || cocoa.code == .fileReadNoPermission {
                throw refusal(.readOnly, path, error)
            }
            // A folder that takes no new file can also come as an unknown write error over EACCES.
            if let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError,
               underlying.domain == NSPOSIXErrorDomain,
               [EACCES, EPERM, EROFS].contains(Int32(truncatingIfNeeded: underlying.code)) {
                throw refusal(.readOnly, path, error)
            }
            throw refusal(.inUse, path, error)
        }
    }

    /// The original, moved aside to `backup` by a replacement that then failed (`cause`), goes back to
    /// `path`; returns the refusal to throw: inUse when it is back, leftAsBackup naming the backup when
    /// it could not be moved.
    static func putBack(_ backup: String, _ path: String, cause: any Error) -> PDFAppendError {
        do {
            try FileManager.default.moveItem(atPath: backup, toPath: path)
            return refusal(.inUse, path, cause)
        } catch {
            let fileName = (path as NSString).lastPathComponent
            let backupName = (backup as NSString).lastPathComponent
            return PDFAppendError(.leftAsBackup, leftAsBackupMessage(fileName, backupName: backupName), underlying: cause)
        }
    }

    /// Opens the file for reading in a way that also checks it can be replaced: write access (refused
    /// for a read-only file) and a shared lock (refused while another app holds the file locked to
    /// write it).
    private static func openForUpdate(_ path: String) throws -> FileHandle {
        let descriptor = open(path, O_RDWR | O_CLOEXEC)
        if descriptor < 0 {
            let code = errno
            switch code {
            case ENOENT, ENOTDIR:
                throw refusal(.missing, path, posixError(code))
            case EACCES, EPERM, EROFS:
                throw refusal(.readOnly, path, posixError(code))
            default:
                throw posixError(code)
            }
        }
        // A file system without locks (ENOTSUP) says nothing about other apps.
        if flock(descriptor, LOCK_SH | LOCK_NB) != 0 && errno == EAGAIN {
            _ = close(descriptor)
            throw refusal(.inUse, path, posixError(EAGAIN))
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    /// A reader over what `handle` reads, which stays open; what it finds wrong is a refusal in words.
    private static func read(_ handle: FileHandle, _ path: String) throws -> PDFReaderLite {
        try mapped(path) { () throws -> PDFReaderLite in try fileReader(handle) }
    }

    private static func fileReader(_ handle: FileHandle) throws -> PDFReaderLite {
        let end = try handle.seekToEnd()
        let source: (_ offset: Int, _ count: Int) throws -> [UInt8] = { offset, count in
            try handle.seek(toOffset: UInt64(offset))
            var bytes: [UInt8] = []
            bytes.reserveCapacity(count)
            while bytes.count < count {
                guard let chunk = try handle.read(upToCount: count - bytes.count), !chunk.isEmpty else { break }
                bytes.append(contentsOf: chunk)
            }
            return bytes
        }
        return try PDFReaderLite(length: Int(clamping: end), read: source)
    }

    /// `read`, with what the reader finds wrong (it reads objects when they are first asked for, not
    /// only when it opens the file) as a refusal in words for the user.
    private static func mapped<T>(_ path: String, _ read: () throws -> T) throws -> T {
        do {
            return try read()
        } catch let error as PDFReadError {
            throw refusal(problemOf(error.problem), path, error)
        }
    }

    /// The original and the update, written to the new hidden file `tmp`; returns the original's
    /// SHA-256. A folder the user may not create files in is readOnly, a write that fails (a full
    /// disk) notWritten, and what the reader finds wrong while writing as when reading.
    private static func writeTemporary(_ tmp: String, from original: FileHandle, length: Int, reader: PDFReaderLite,
                                       pages: [PDFPageInput], options: PDFAppendOptions?,
                                       progress: ((String) -> Void)?, shouldContinue: (() -> Bool)?,
                                       path: String) throws -> [UInt8] {
        let descriptor = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o666)
        if descriptor < 0 {
            let code = errno
            if code == EACCES || code == EPERM || code == EROFS {
                throw refusal(.readOnly, path, posixError(code))
            }
            throw refusal(.notWritten, path, posixError(code))
        }
        let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? output.close() }
        do {
            let hash = try copyHashing(original, to: output, length: length, shouldContinue: shouldContinue)
            try writeUpdate(reader, into: { chunk in try output.write(contentsOf: chunk) }, pages: pages,
                            options: options, progress: progress, shouldContinue: shouldContinue)
            try output.synchronize()
            return hash
        } catch let error as PDFReadError {
            throw refusal(problemOf(error.problem), path, error)
        } catch let error as ScanError {
            throw error
        } catch {
            throw refusal(.notWritten, path, error)
        }
    }

    private static func copyHashing(_ from: FileHandle, to: FileHandle, length: Int,
                                    shouldContinue: (() -> Bool)?) throws -> [UInt8] {
        var hash = SHA256()
        try from.seek(toOffset: 0)
        var left = length
        while left > 0 {
            if shouldContinue?() == false { throw ScanError.cancelled }
            guard let chunk = try from.read(upToCount: min(1 << 16, left)), !chunk.isEmpty else {
                throw PDFReadError.damaged("Unable to read beyond the end of the stream.")
            }
            hash.update(data: chunk)
            try to.write(contentsOf: chunk)
            left -= chunk.count
        }
        let digest: [UInt8] = Array(hash.finalize())
        return digest
    }

    /// The temporary file read back: the original's bytes first, then an update with every page.
    private static func verify(_ tmp: String, originalLength: Int, originalHash: [UInt8], pageCount: Int,
                               previousXref: Int, sections: Int, path: String) throws {
        do {
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: tmp))
            defer { try? handle.close() }
            var hash = SHA256()
            var left = originalLength
            while left > 0 {
                guard let chunk = try handle.read(upToCount: min(1 << 16, left)), !chunk.isEmpty else {
                    throw refusal(.notVerified, path)
                }
                hash.update(data: chunk)
                left -= chunk.count
            }
            let digest: [UInt8] = Array(hash.finalize())
            let check = try fileReader(handle)
            guard digest == originalHash, !check.isEncrypted, check.pageCount == pageCount,
                  check.sectionCount == sections, check.startXref > originalLength,
                  check.latestPrev == previousXref else {
                throw refusal(.notVerified, path)
            }
        } catch let error as PDFAppendError {
            throw error
        } catch {
            throw refusal(.notVerified, path, error)
        }
    }

    private static func fullPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardized.path
    }

    private static func posixError(_ code: Int32) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }

    private static func problemOf(_ problem: PDFReadProblem) -> PDFAppendProblem {
        switch problem {
        case .notPdf: return .notPdf
        case .encrypted: return .encrypted
        case .unsupported: return .unsupported
        case .damaged: return .damaged
        }
    }

    private static func refusal(_ problem: PDFAppendProblem, _ path: String,
                                _ underlying: (any Error)? = nil) -> PDFAppendError {
        PDFAppendError(problem, message(problem, (path as NSString).lastPathComponent), underlying: underlying)
    }
}
