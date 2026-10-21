import CoreGraphics
import Foundation

/// The ID card task (`IdCardSteps`): the front and the back are scanned on the flatbed, the card is
/// found on each scan and cut out straight (`IdCardDetector`), and both sides are saved on one page
/// at their real size (`IdCardComposer`). Nothing of the card is spooled or kept in the scan
/// history; its scans stay in memory only until the sides are saved or discarded. The stored state
/// is in AppState.swift (`idCardFront`, `idCardBack`, `showIdCardReview`, …). Port of the ID card
/// members of the Windows `AppViewModel`.
extension AppState {
    /// The steps guide the ID card task: front, back, then the review.
    public var isIdCardFlow: Bool { taskFlow != nil && flowTask == .idCard && !flowIsManual }

    /// A side of an ID card is held in memory and not saved yet.
    public var hasIdCardCaptures: Bool { idCardFront != nil || idCardBack != nil }

    /// The page the ID card is saved on: the choice in the review; Automatic is the default printer's
    /// paper when it is A4 or Letter, else the paper usual where the user lives.
    public var idCardPaperSize: PaperSize {
        IdCardPapers.resolve(settings.taskOptions.idCardPaper, regionCode: Self.regionCode,
                             printerPaper: defaultPrinterPaper)
    }

    /// How the review's paper picker names a choice, Automatic with the paper it is now.
    public func idCardPaperChoiceLabel(_ paper: IdCardPaper) -> String {
        IdCardPapers.choiceLabel(paper, regionCode: Self.regionCode, printerPaper: defaultPrinterPaper)
    }

    /// The user's country or region (two letters), for the paper usual there; nil when unknown.
    public nonisolated static var regionCode: String? { Locale.current.region?.identifier }

    /// Resolution of the page picture in the review.
    static let idCardPreviewDPI = 40

    /// One side of the ID card was scanned and found (`AppState.performScan`): the step records it
    /// and moves on (past a back already scanned or skipped, when the front was scanned again), and
    /// once the sides are in, the review opens. `source` (the scan) is kept only while the side is,
    /// so its crop can be fixed, with what it covers (`area`).
    func recordIdCardSide(_ side: PageSide, photo: DetectedPhoto, note: String?, source: CGImage,
                          area: IdCardScanArea) {
        guard isIdCardFlow else {
            dropIdCardScanOutsideTask()
            return
        }
        idCardSourceImages[photo.sourcePageID ?? photo.id] = source
        idCardScanAreas[photo.sourcePageID ?? photo.id] = area
        setIdCardSide(side, photo: photo, note: note)
        if taskFlow != nil {
            taskFlow?.record(stepID: IdCardSteps.stepID(side), captureID: photo.id)
            taskFlow?.advance()
            if taskFlow?.current?.id == IdCardSteps.backStepID,
               idCardBack != nil || taskFlow?.isSkipped(IdCardSteps.backStepID) == true {
                taskFlow?.advance()
            }
        }
        let check = note.map { " \($0)" } ?? ""
        if taskFlow?.current?.id == IdCardSteps.reviewStepID {
            statusMessage = "\(side == .front ? "Front" : "Back") scanned. Check the sides, then save.\(check)"
            openIdCardReview()
        } else {
            statusMessage = "Front scanned. Turn the card over where it lies and scan the back, or skip it.\(check)"
        }
    }

    /// A scan of the ID card finished outside its steps (the task ended while it ran): nothing of it
    /// is kept, a side never stays held without the task, and the stage no longer shows the card.
    /// Twin of the Windows `AppViewModel.DropIdCardScanOutsideTask`.
    func dropIdCardScanOutsideTask() {
        clearIdCard(clearCanvas: true)
        statusMessage = "The ID card task ended during the scan. Nothing of the card was kept."
    }

    /// Puts a side in place (nil: none), dropping the scan the one it replaces came from.
    func setIdCardSide(_ side: PageSide, photo: DetectedPhoto?, note: String?) {
        let old = side == .front ? idCardFront : idCardBack
        if side == .front {
            idCardFront = photo
            idCardFrontNote = note
        } else {
            idCardBack = photo
            idCardBackNote = note
        }
        if let id = old?.sourcePageID, idCardFront?.sourcePageID != id, idCardBack?.sourcePageID != id {
            idCardSourceImages[id] = nil
            idCardScanAreas[id] = nil
        }
    }

    /// Which side of the ID card the photo with `id` is; nil for any other photo.
    func idCardSide(ofPhoto id: UUID) -> PageSide? {
        if idCardFront?.id == id { return .front }
        if idCardBack?.id == id { return .back }
        return nil
    }

    /// Opens the review of the ID card's sides, once there is a front.
    func openIdCardReview() {
        guard idCardFront != nil else { return }
        showIdCardReview = true
        refreshIdCardPreview()
    }

    /// Draws the page the sides go on again (after a turn, a new crop, swapping the sides or another
    /// paper), small and off the main actor, with what it holds and whether it is at real size. A
    /// picture overtaken by a newer one is dropped.
    public func refreshIdCardPreview() {
        idCardPreviewRevision += 1
        let revision = idCardPreviewRevision
        let paper = idCardPaperSize
        guard let paperInches = PaperSizes.inches(paper), let front = idCardFront else {
            idCardPreview = nil
            idCardLayoutCaption = ""
            idCardSizeWarning = nil
            return
        }
        let back = idCardBack
        let previewDPI = Self.idCardPreviewDPI
        Task { @MainActor [weak self] in
            let drawn: (CGImage?, IdCardLayoutResult)? = await Task.detached(priority: .userInitiated) { () -> (CGImage?, IdCardLayoutResult)? in
                guard let f = AppState.idCardSide(of: front) else { return nil }
                let b = back.flatMap { AppState.idCardSide(of: $0) }
                let layout = IdCardLayout.place(front: f.inches, back: b?.inches, paper: paperInches)
                let page = IdCardComposer.compose(front: f, back: b, dpi: previewDPI, paperInches: paperInches)
                return (page.makeCGImage(), layout)
            }.value
            guard let self, revision == self.idCardPreviewRevision, let drawn else { return }
            self.idCardPreview = drawn.0
            self.idCardLayoutCaption = IdCardLayout.caption(paper: paper, hasBack: back != nil,
                                                            scaledToFit: drawn.1.scaledToFit)
            self.idCardSizeWarning = drawn.1.scaledToFit ? IdCardLayout.notRealSizeMessage : nil
        }
    }

    /// A side as it is saved: turned as the user turned it, as an `RgbaImage`.
    nonisolated static func idCardSide(of photo: DetectedPhoto) -> IdCardSide? {
        let turned = photo.rotationQuarterTurns == 0
            ? photo.image
            : ImagePipeline.rotate(photo.image, quarterTurns: photo.rotationQuarterTurns)
        guard let rgba = RgbaImage(cgImage: turned) else { return nil }
        return IdCardSide(image: rgba, dpi: photo.dpi)
    }

    /// Turns a side of the ID card 90° clockwise.
    public func rotateIdCardSide(_ side: PageSide) {
        guard !isBusy else { return }
        if side == .front, var photo = idCardFront {
            photo.rotationQuarterTurns = (photo.rotationQuarterTurns + 1) % 4
            idCardFront = photo
        } else if side == .back, var photo = idCardBack {
            photo.rotationQuarterTurns = (photo.rotationQuarterTurns + 1) % 4
            idCardBack = photo
        } else {
            return
        }
        refreshIdCardPreview()
    }

    /// The front becomes the back and the back the front (scanned in the wrong order).
    public func swapIdCardSides() {
        guard !isBusy, let front = idCardFront, let back = idCardBack else { return }
        let frontNote = idCardFrontNote
        idCardFront = back
        idCardFrontNote = idCardBackNote
        idCardBack = front
        idCardBackNote = frontNote
        statusMessage = "Front and back swapped."
        refreshIdCardPreview()
    }

    /// Scans a side of the ID card again, or the back after all: the review closes, the side goes and
    /// the steps go back to it. The other side stays.
    public func retakeIdCardSide(_ side: PageSide) {
        guard !isBusy, isIdCardFlow, taskFlow != nil else { return }
        taskFlow?.retake(stepID: IdCardSteps.stepID(side))
        setIdCardSide(side, photo: nil, note: nil)
        showIdCardReview = false
        idCardPreview = nil
        idCardPreviewRevision += 1
        statusMessage = taskFlow?.current?.prompt ?? ""
        // The only side held went: a scanner switch that waited for the card is made now.
        endOfWork()
    }

    /// Manual crop correction of a side of the ID card (the crop editor, through `recropPhoto`): cut
    /// out again from its scan with the region the user adjusted, turned straight, off the main
    /// actor. The side keeps its turn; nothing changes when the side was scanned again, swapped or
    /// saved meanwhile.
    func recropIdCardSide(_ side: PageSide, region: DetectedPhotoRegion) {
        guard let photo = side == .front ? idCardFront : idCardBack,
              let source = photoSource(for: photo) else { return }
        Task { @MainActor [weak self] in
            let image = await Task.detached(priority: .userInitiated) {
                PhotoDetector.extractPhoto(from: source, region: region, deskew: true)
            }.value
            guard let self, !self.isBusy, let image else { return }
            guard (side == .front ? self.idCardFront?.id : self.idCardBack?.id) == photo.id else { return }
            var updated = DetectedPhoto(region: region, image: image, dpi: photo.dpi,
                                        id: photo.id, sourcePageID: photo.sourcePageID, colorMode: photo.colorMode)
            updated.rotationQuarterTurns = (side == .front ? self.idCardFront : self.idCardBack)?.rotationQuarterTurns ?? 0
            self.setIdCardSide(side, photo: updated, note: nil)
            self.statusMessage = "Crop updated."
            self.refreshIdCardPreview()
        }
    }

    /// The paper the ID card is laid out on (saved with the settings); the page is drawn again.
    public func setIdCardPaper(_ paper: IdCardPaper) {
        guard settings.taskOptions.idCardPaper != paper else { return }
        settings.taskOptions.idCardPaper = paper
        refreshIdCardPreview()
    }

    /// Saves the ID card: both sides on one page at real size on the paper chosen, as a PDF or an
    /// image in the chosen format, and each side as an image of its own when asked for. All or
    /// nothing: a failed or cancelled save removes what it wrote, and the review stays open. Once
    /// saved, the sides and their scans are dropped from memory, the stage is cleared, and the steps
    /// start again.
    public func saveIdCard() {
        guard let front = idCardFront else { return }
        let back = idCardBack
        let s = settings
        let paper = idCardPaperSize
        guard let paperInches = PaperSizes.inches(paper) else { return }
        // The page at the scan's resolution, at most 600 dpi; each side's own image keeps the scan's.
        let pageDPI = IdCardComposer.pageDPI(front.dpi)
        // The sides are what they were scanned as, whatever the color mode is now.
        let pageMode = IdCardComposer.pageColorMode(front: front.colorMode, back: back?.colorMode)
        runExclusive { flag in
            self.statusMessage = "Saving the ID card\u{2026}"
            let composed: (page: CGImage, front: IdCardSide, back: IdCardSide?)? = await Task.detached(priority: .userInitiated) { () -> (page: CGImage, front: IdCardSide, back: IdCardSide?)? in
                guard let f = AppState.idCardSide(of: front) else { return nil }
                let b = back.flatMap { AppState.idCardSide(of: $0) }
                let page = IdCardComposer.compose(front: f, back: b, dpi: pageDPI, paperInches: paperInches)
                guard let image = page.makeCGImage() else { return nil }
                return (page: image, front: f, back: b)
            }.value
            guard let composed else { throw ScanError.exportFailed("The page could not be drawn.") }
            if flag.isCancelled { throw ScanError.cancelled }
            var saved: [URL] = []
            // The card is a picture: a PDF or an image, never a text format.
            let pageFormat = s.format.pageFormat
            do {
                let url: URL
                if pageFormat == .pdf {
                    url = try self.outputURL(fileExtension: "pdf")
                    let page = ScannedPage(image: composed.page, dpi: pageDPI, colorMode: pageMode)
                    try await Task.detached(priority: .userInitiated) {
                        try AppState.writePDFAtomically(pages: [page], searchable: s.pdfSearchable,
                                                        languages: s.ocrLanguages, pdfSize: s.output.pdfSize, to: url,
                                                        shouldContinue: { !flag.isCancelled }) { [weak self] msg in
                            Task { @MainActor in self?.statusMessage = msg }
                        }
                    }.value
                    saved.append(url)
                    self.notePDFSize(of: url)
                } else {
                    url = try self.outputURL(fileExtension: pageFormat.fileExtension)
                    let image = composed.page
                    try await Task.detached(priority: .userInitiated) {
                        try ImageExporter.write(image, to: url, format: pageFormat, dpi: pageDPI,
                                                jpegQuality: s.jpegQuality, colorMode: pageMode)
                    }.value
                    saved.append(url)
                }
                if s.taskOptions.idCardSaveSidesAsImages {
                    let sideFormat = s.format.imageFormatOrJPEG
                    let folder = url.deletingLastPathComponent()
                    let base = url.deletingPathExtension().lastPathComponent
                    var sides: [(PageSide, IdCardSide)] = [(.front, composed.front)]
                    if let backSide = composed.back { sides.append((.back, backSide)) }
                    for (side, sideImage) in sides {
                        if flag.isCancelled { throw ScanError.cancelled }
                        guard let image = sideImage.image.makeCGImage() else {
                            throw ScanError.exportFailed("A side of the card could not be saved.")
                        }
                        let sideURL = NamingTemplate.uniqueURL(in: folder,
                                                               base: IdCardComposer.sideFileBase(base, side: side),
                                                               fileExtension: sideFormat.fileExtension)
                        let dpi = sideImage.dpi
                        // The mode the side was scanned in: a black & white TIFF is G4.
                        let sideMode = side == .front ? front.colorMode : (back?.colorMode ?? .color)
                        try await Task.detached(priority: .userInitiated) {
                            try ImageExporter.write(image, to: sideURL, format: sideFormat, dpi: dpi,
                                                    jpegQuality: s.jpegQuality, colorMode: sideMode)
                        }.value
                        saved.append(sideURL)
                    }
                }
            } catch {
                // All or nothing: what this save wrote goes again, and the review stays open.
                for url in saved { try? FileManager.default.removeItem(at: url) }
                throw error
            }
            self.lastSavedURLs = saved
            self.clearIdCard(clearCanvas: true)
            self.resetFlow()
            let name = saved.first?.lastPathComponent ?? ""
            let sizeNote = pageFormat == .pdf ? self.pdfSizeSuffix : ""
            self.statusMessage = saved.count == 1
                ? "Saved the ID card on one \(paper.label) page: \(name)\(sizeNote)"
                : "Saved the ID card on one \(paper.label) page: \(name)\(sizeNote), and each side as an image"
            self.runAfterSave(s.output.afterSave, saved: saved)
        }
    }

    /// Drops the ID card's sides without saving them, and starts the steps again.
    public func discardIdCard() {
        guard !isBusy else { return }
        clearIdCard(clearCanvas: true)
        resetFlow()
        statusMessage = "ID card discarded. Nothing of it was kept."
        endOfWork()
    }

    /// Drops everything of the ID card from memory: its sides, the scans they came from, the review
    /// and its page and, with `clearCanvas`, the preview and the last scan on the stage, which show
    /// the card too.
    func clearIdCard(clearCanvas: Bool) {
        idCardFront = nil
        idCardBack = nil
        idCardFrontNote = nil
        idCardBackNote = nil
        idCardSourceImages = [:]
        idCardScanAreas = [:]
        if showIdCardReview { showIdCardReview = false }
        idCardPreview = nil
        idCardLayoutCaption = ""
        idCardSizeWarning = nil
        idCardPreviewRevision += 1
        if clearCanvas && (overviewImage != nil || lastScanImage != nil) {
            overviewImage = nil
            lastScanImage = nil
            lastScanPixelSize = nil
            selectionRect = nil
        }
        // A scanner switch that waited for the card is made now, after whatever dropped it (it may
        // be in the middle of a switch already).
        Task { @MainActor [weak self] in self?.endOfWork() }
    }

    /// Runs `action`, which ends the ID card task (leaving it, picking a task or a preset), at once;
    /// while a side of the card is held and not saved, only once the user discards the card
    /// (`pendingIdCardLeave`, asked by `ContentView`). Refused while an operation runs: the card
    /// cannot be discarded then. Twin of the Windows `MainWindow.ConfirmDropIdCard`.
    public func leaveIdCard(then action: @escaping @MainActor () -> Void) {
        guard !isBusy else { return }
        guard hasIdCardCaptures else {
            action()
            return
        }
        pendingIdCardLeave = IdCardLeave(action: action)
    }

    /// The user chose Discard: the card is dropped, then what was asked for runs.
    public func discardIdCard(andThen leave: IdCardLeave) {
        pendingIdCardLeave = nil
        guard !isBusy else { return }
        discardIdCard()
        leave.action()
    }
}

/// Something asked for that would end the ID card task while a side is held and not saved, waiting
/// for the user to discard the card (`AppState.pendingIdCardLeave`).
public struct IdCardLeave: Identifiable {
    public let id = UUID()
    let action: @MainActor () -> Void
}
