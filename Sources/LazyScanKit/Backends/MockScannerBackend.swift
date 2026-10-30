import CoreGraphics
import CoreText
import Foundation

/// A demo scanner that needs no hardware: it renders deterministic synthetic
/// flatbed images with CoreGraphics, so the whole app (overview, selection,
/// photo splitting, OCR, PDF export) can be exercised end to end. It also has a
/// document feeder holding `feederSheetCount` two-sided letter-size sheets, which it scans one
/// side or both (`feederDuplex`), so two-sided scanning, turning the stack over by hand and paper
/// sizes can be tried without hardware. For the ID card task its glass holds a sample card (an
/// obviously made-up design, no real document), which it turns over after every scan
/// (`idCardTurnedOver`); for the Receipts task it holds two made-up receipts
/// (`demoReceiptPlaces`); for the Batch task its feeder holds a stack of documents with separator
/// sheets between them (`batchSeparatorSheets`: patch-code sheets, or barcode sheets when the stack is
/// split at barcode or QR sheets); for the Book or magazine task its glass holds an open
/// book, whose page it turns after every scan (`bookSpread`). Twin of C# `MockScannerBackend`.
public final class MockScannerBackend: ScannerBackend {

    /// Where the demo receipts lie on the glass (centre and size in inches, tilt in degrees), for checks.
    static var demoReceiptPlaces: [(centerInches: CGPoint, sizeInches: CGSize, angleDegrees: Double)] {
        MockBedRenderer.receiptPlaces
    }

    /// The demo book's spine: this share of the scan's width from its left edge, for checks.
    static var demoBookGutterFraction: Double { MockBedRenderer.bookGutterFraction }

    /// Sheets the demo feeder holds unless `feederSheetCount` is changed.
    public static let defaultFeederSheetCount = 3

    public var onDevicesChanged: (() -> Void)?
    public private(set) var devices: [ScannerInfo] = []

    /// Sheets a feeder scan delivers, read when the scan starts; 0 simulates an empty
    /// feeder (the scan fails with `ScanError.scannerProblem(.feederEmpty)`).
    public var feederSheetCount: Int = 3

    /// Simulates a paper jam: after this many sheets the next one jams, read when the scan
    /// starts. The sheets before it are kept and the session's `lastScanStop` says why the
    /// batch stopped; a jam on the first sheet fails the scan with
    /// `ScanError.scannerProblem(.paperJam)`. nil (the default) never jams.
    public var feederJamsAfter: Int?

    /// The feeder scans both sides in one pass (reported as `ScannerCapabilities.supportsDuplex`,
    /// read when the capabilities are read). Default true; false shows a feeder that scans one side.
    public var feederDuplex: Bool = true

    /// The stack in the feeder is turned over: a one-sided scan delivers the backs, last sheet
    /// first. The demo turns its stack over by itself after every one-sided scan made for turning
    /// over by hand (`.manual`), as the user is asked to; any other feeder scan puts it back the
    /// right way up. A scan cut short by a jam leaves it as it is: the user clears the jam and
    /// scans the rest of the same side. Settable to start from either side.
    public var feederStackTurnedOver: Bool = false

    /// The sheets (counted from 0) whose backs are blank, read when the scan starts: unprinted
    /// paper with the scanner's noise, a few specks of dust and the front showing through faintly,
    /// like the back of a one-sided page in a two-sided stack. Empty by default; the app's demo
    /// scanner has a blank back on its second sheet.
    public var feederBlankBackSheets: Set<Int> = []

    /// Sheets the demo feeder holds for the Batch task unless `batchSheetCount` is changed.
    public static let defaultBatchSheetCount = 7

    /// Sheets a feeder scan for the Batch task delivers, read when the scan starts: a stack of three
    /// documents with a separator sheet in front of the second and the third (`batchSeparatorSheets`).
    public var batchSheetCount: Int = MockScannerBackend.defaultBatchSheetCount

    /// The sheets (counted from 0) of the Batch task's stack that are separator sheets, read when the
    /// scan starts: the Patch T sheet the app prints (`PatchCodeDetector.renderSheet`) on the front,
    /// blank paper on the back; split at barcode or QR sheets (`SplitMode.barcode`), a Code 39 sheet
    /// naming the document after it instead (`batchBarcodeText`). Sheets 2 and 4 by default: documents
    /// of two, one and two sheets.
    public var batchSeparatorSheets: Set<Int> = [2, 4]

    /// The Code 39 text of the demo's barcode separator sheet in front of document `document` (from 1):
    /// the separator prefix and a name, "LS-SEP INVOICE 1002" for the second, which names it
    /// "INVOICE 1002". Twin of C# `MockBedRenderer.BatchBarcodeText`.
    nonisolated static func batchBarcodeText(_ document: Int) -> String {
        "\(BarcodeSeparators.defaultPrefix) INVOICE \(1000 + document)"
    }

    /// A barcode separator sheet as the demo feeder delivers it (`Code39.renderSheet`), for checks.
    /// Twin of C# `MockBedRenderer.RenderBarcodeSeparatorSheet`.
    nonisolated static func renderBarcodeSeparatorSheet(dpi: Int, text: String, sheetInches: CGSize? = nil) -> CGImage? {
        MockBedRenderer.renderBarcodeSeparatorSheet(dpi: dpi, text: text, sheetInches: sheetInches)
    }

    /// The sample ID card on the glass lies with its back up: a scan for the ID card task shows its
    /// back. The demo turns the card over by itself after every such scan, as the user is asked to,
    /// so scans alternate front, back, front… A preview shows the side facing down without turning it.
    public var idCardTurnedOver: Bool = false

    /// The spread the open book on the glass is at (0 = the first): a scan for the Book or magazine task
    /// shows it, and the demo turns the page by itself after every such scan, as the user is asked to. A
    /// preview shows the spread without turning the page.
    public var bookSpread: Int = 0

    public init() {}

    public func startBrowsing() {
        guard devices.isEmpty else { return }
        devices = [ScannerInfo(id: "mock:demo", name: "Demo Scanner", transport: "Demo", isDemo: true,
                               backend: "mock")]
        onDevicesChanged?()
    }

    public func stopBrowsing() {
        guard !devices.isEmpty else { return }
        devices = []
        onDevicesChanged?()
    }

    public func openSession(deviceID: String) async throws -> any ScannerSession {
        guard let info = devices.first(where: { $0.id == deviceID }) else {
            throw ScanError.deviceUnavailable("The demo scanner is not available.")
        }
        return MockScannerSession(info: info, backend: self)
    }
}

// MARK: - Session

@MainActor
private final class MockScannerSession: ScannerSession {

    let info: ScannerInfo
    var progressHandler: ((ScanProgress) -> Void)?
    private(set) var lastScanStop: ScanStop?
    private(set) var lastScanDuplex: Bool?

    private var cancelRequested = false
    /// Source of the feeder's settings, read at the start of each feeder scan, and of where the
    /// sample card and book are. Held strongly, as the C# twin does: the demo's state lives on in a
    /// session whose backend is no longer referenced elsewhere (the backend holds no session).
    private let backend: MockScannerBackend

    private static let bedSizeInches = CGSize(width: 8.5, height: 11.7)

    init(info: ScannerInfo, backend: MockScannerBackend) {
        self.info = info
        self.backend = backend
    }

    func capabilities() async throws -> ScannerCapabilities {
        ScannerCapabilities(supportedResolutions: [75, 150, 200, 300, 600, 1200],
                            sources: [.flatbed, .documentFeeder],
                            flatbedSizeInches: Self.bedSizeInches,
                            supportsOverview: true,
                            feederSizeInches: MockBedRenderer.feederMaxInches,
                            supportsDuplex: backend.feederDuplex)
    }

    func performOverviewScan(settings: ScanSettings) async throws -> CGImage {
        cancelRequested = false
        progressHandler?(ScanProgress(fraction: 0.5, message: "Scanning overview…"))
        let rendered: CGImage?
        switch settings.task {
        case .idCard?:
            rendered = MockBedRenderer.renderIdCardBed(dpi: 100, side: backend.idCardTurnedOver ? .back : .front)
        case .receipt?:
            rendered = MockBedRenderer.renderReceiptBed(dpi: 100)
        case .book?:
            rendered = MockBedRenderer.renderBookSpread(dpi: 100, spreadIndex: backend.bookSpread)
        default:
            rendered = MockBedRenderer.renderBed(dpi: 100, intent: settings.intent)
        }
        guard let image = rendered else {
            throw ScanError.scanFailed("Could not render the demo overview.")
        }
        return image
    }

    func performScan(settings: ScanSettings, selection: CGRect?) async throws -> [ScannedPage] {
        cancelRequested = false
        lastScanStop = nil
        lastScanDuplex = nil
        let dpi = min(settings.resolution, 600) // cap memory use
        if settings.source == .documentFeeder {
            return try await scanFeeder(settings: settings, dpi: dpi)
        }

        progressHandler?(ScanProgress(fraction: 0.2, message: "Warming up…"))
        try await sleepCheckingCancellation(seconds: 0.25)

        progressHandler?(ScanProgress(fraction: 0.6, message: "Scanning…"))
        // The ID card task scans the sample card, then turns it over as the user would.
        let idCard = settings.task == .idCard
        let cardSide: PageSide = backend.idCardTurnedOver ? .back : .front
        // The Book or magazine task scans the open book, then turns its page.
        let book = settings.task == .book
        let spread = backend.bookSpread
        let rendered = idCard
            ? MockBedRenderer.renderIdCardBed(dpi: dpi, side: cardSide)
            : settings.task == .receipt
            ? MockBedRenderer.renderReceiptBed(dpi: dpi)
            : book
            ? MockBedRenderer.renderBookSpread(dpi: dpi, spreadIndex: spread)
            : MockBedRenderer.renderBed(dpi: dpi, intent: settings.intent)
        guard var image = rendered else {
            throw ScanError.scanFailed("Could not render the demo scan.")
        }
        if idCard { backend.idCardTurnedOver = cardSide == .front }
        if book { backend.bookSpread = spread + 1 }
        try await sleepCheckingCancellation(seconds: 0.25)

        progressHandler?(ScanProgress(fraction: 0.9, message: "Transferring…"))
        try await sleepCheckingCancellation(seconds: 0.2)

        // Honor the selection: a normalized rect of the bed with top-left
        // origin, which matches CGImage's cropping coordinate space.
        if let selection {
            let clamped = selection.standardized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            if clamped.width > 0.005, clamped.height > 0.005 {
                let pixelRect = CGRect(x: clamped.origin.x * CGFloat(image.width),
                                       y: clamped.origin.y * CGFloat(image.height),
                                       width: clamped.width * CGFloat(image.width),
                                       height: clamped.height * CGFloat(image.height)).integral
                if let cropped = image.cropping(to: pixelRect) {
                    image = cropped
                }
            }
        }
        return [ScannedPage(image: image, dpi: dpi, colorMode: settings.colorMode)]
    }

    /// The demo feeder (the selection does not apply): one sheet per page, the paper size asked
    /// for (letter for Automatic), each side marked with its sheet number. Two-sided (when asked
    /// for and `feederDuplex`) it delivers front, back, front, back…; one-sided it delivers the
    /// side facing up (`feederStackTurnedOver`), and says so when both sides were asked for
    /// (`lastScanDuplex`). An empty feeder or a jam fails like a real one; a jam keeps the sheets
    /// before it.
    private func scanFeeder(settings: ScanSettings, dpi: Int) async throws -> [ScannedPage] {
        // The Batch task's stack: documents with separator sheets between them.
        let batch = settings.task == .batch && settings.intent == .document
        let sheets = batch
            ? backend.batchSheetCount
            : backend.feederSheetCount
        let separators: Set<Int> = batch ? backend.batchSeparatorSheets : []
        let barcodeSheets = batch && settings.document.splitMode == .barcode
        let jamsAfter = backend.feederJamsAfter
        let twoSided = settings.duplex == .both && backend.feederDuplex
        let turnedOver = backend.feederStackTurnedOver
        let blankBacks = backend.feederBlankBackSheets
        let region = PaperSizes.feederRegionInches(settings.paperSize, max: MockBedRenderer.feederMaxInches)
        let sheetInches = settings.paperSize == .auto ? MockBedRenderer.sheetInches : region.size
        progressHandler?(ScanProgress(fraction: 0.1, message: "Warming up…"))
        try await sleepCheckingCancellation(seconds: 0.25)
        guard sheets > 0 else { throw ScanError.scannerProblem(.feederEmpty) }
        lastScanDuplex = settings.duplex == .both ? twoSided : nil

        var pages: [ScannedPage] = []
        for index in 0..<sheets {
            if let jam = jamsAfter, index >= jam {
                let error = ScanError.scannerProblem(.paperJam)
                if pages.isEmpty { throw error }
                lastScanStop = ScanStop.from(error)
                break
            }
            progressHandler?(ScanProgress(fraction: 0.1 + 0.9 * Double(index) / Double(sheets),
                                          message: "Scanning sheet \(index + 1) of \(sheets)…"))
            // A turned-over stack feeds its last sheet first, showing the backs.
            let sheet = turnedOver && !twoSided ? sheets - 1 - index : index
            let sides: [PageSide] = twoSided ? [.front, .back] : [turnedOver ? .back : .front]
            for side in sides {
                let separator = separators.contains(sheet)
                let blank = side == .back && (separator || blankBacks.contains(sheet))
                // The nth separator sheet of the stack starts document n + 1.
                let document = 2 + separators.filter { $0 < sheet }.count
                let front: CGImage?
                if !separator {
                    front = nil
                } else if barcodeSheets {
                    front = MockBedRenderer.renderBarcodeSeparatorSheet(dpi: dpi, text: MockScannerBackend.batchBarcodeText(document),
                                                                        sheetInches: sheetInches)
                } else {
                    front = MockBedRenderer.renderSeparatorSheet(dpi: dpi, sheetInches: sheetInches)
                }
                let rendered: CGImage?
                if blank {
                    rendered = MockBedRenderer.renderBlankBack(dpi: dpi, intent: settings.intent, sheetIndex: sheet,
                                                               sheetInches: sheetInches, frontImage: front)
                } else if let front {
                    rendered = front
                } else {
                    rendered = MockBedRenderer.renderSheet(dpi: dpi, intent: settings.intent, sheetIndex: sheet,
                                                           side: side, sheetInches: sheetInches)
                }
                guard let image = rendered else {
                    throw ScanError.scanFailed("Could not render the demo scan.")
                }
                pages.append(ScannedPage(image: image, dpi: dpi, colorMode: settings.colorMode))
            }
            try await sleepCheckingCancellation(seconds: 0.15)
        }
        // The user turns the stack over between the two scans of turning over by hand, and loads
        // it the right way up for any other scan; after a jam the rest of the same side comes next.
        if lastScanStop == nil {
            backend.feederStackTurnedOver = settings.duplex == .manual && !twoSided && !turnedOver
        }
        return pages
    }

    func cancelScan() {
        cancelRequested = true
    }

    func close() async {}

    private func sleepCheckingCancellation(seconds: Double) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        if cancelRequested { throw ScanError.cancelled }
    }
}

// MARK: - Rendering

/// Draws the deterministic synthetic flatbed. Everything works in a
/// top-left-origin, y-down coordinate space measured in inches, which is
/// mapped onto the (flipped) CGContext.
private enum MockBedRenderer {

    static let bedInches = CGSize(width: 8.5, height: 11.7)
    /// Sheet size of the demo feeder's stack (US Letter), scanned when the paper size is Automatic.
    static let sheetInches = CGSize(width: 8.5, height: 11)
    /// The largest sheet the demo feeder takes (US Legal).
    static let feederMaxInches = CGSize(width: 8.5, height: 14)

    static func renderBed(dpi: Int, intent: ScanIntent) -> CGImage? {
        let scale = CGFloat(dpi)
        let width = Int(bedInches.width * scale)
        let height = Int(bedInches.height * scale)
        guard width > 0, height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }

        // Flip so (0, 0) is the top-left corner and y grows downward.
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)

        drawBedBackground(in: ctx, width: CGFloat(width), height: CGFloat(height))

        switch intent {
        case .photo:
            drawPhotos(in: ctx, scale: scale, items: photos, firstDesign: 0)
        case .document:
            // A white page lying on the bed, slightly inset from the glass edges.
            drawDocument(in: ctx, scale: scale,
                         pageInches: CGRect(x: 0.25, y: 0.25,
                                            width: bedInches.width - 0.5, height: bedInches.height - 0.5),
                         sheetIndex: nil)
        }
        return ctx.makeImage()
    }

    /// One side of a sheet from the demo feeder, `sheetInches` in size (`MockBedRenderer.sheetInches`
    /// by default). The front of a document sheet is the demo page edge to edge with
    /// `sheetIndex + 1` marks near the bottom left; its back is a shorter page with as many marks
    /// near the bottom right, both upright, as a two-sided feeder delivers long-edge sheets. A photo
    /// sheet's front holds one of the demo photos, centered, cycling through them; its back is
    /// blank paper with a short pencilled note.
    static func renderSheet(dpi: Int, intent: ScanIntent, sheetIndex: Int, side: PageSide = .front,
                            sheetInches size: CGSize? = nil) -> CGImage? {
        let sheetSize = size ?? sheetInches
        let scale = CGFloat(dpi)
        let width = max(1, Int(sheetSize.width * scale))
        let height = max(1, Int(sheetSize.height * scale))
        guard width > 0, height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }

        // Flip so (0, 0) is the top-left corner and y grows downward.
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)

        let page = CGRect(x: 0, y: 0, width: sheetSize.width, height: sheetSize.height)
        switch (intent, side) {
        case (.photo, .back):
            // A note pencilled on the back of the print.
            ctx.setFillColor(gray(1.0))
            ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
            ctx.setFillColor(rgb(0.47, 0.47, 0.50))
            ctx.fill(CGRect(x: 0.75 * scale, y: 0.9 * scale, width: 2.2 * scale, height: 0.12 * scale))
        case (.photo, .front):
            drawBedBackground(in: ctx, width: CGFloat(width), height: CGFloat(height))
            let design = sheetIndex % photos.count
            var centered = photos[design]
            centered.centerInches = CGPoint(x: sheetSize.width / 2, y: sheetSize.height / 2)
            drawPhotos(in: ctx, scale: scale, items: [centered], firstDesign: design)
        case (.document, .back):
            drawDocumentBack(in: ctx, scale: scale, pageInches: page, sheetIndex: sheetIndex)
        case (.document, .front):
            drawDocument(in: ctx, scale: scale, pageInches: page, sheetIndex: sheetIndex)
        }
        return ctx.makeImage()
    }

    /// The back of sheet `sheetIndex` when nothing is printed on it, as a scanner sees it: off-white
    /// paper with noise (σ ≈ 4 levels), a few specks of dust, and the front (`frontImage`, else the
    /// sheet's demo front) showing through mirrored at a tenth of its darkness. Deterministic for a
    /// sheet and size; the same noise and dust as the C# demo (the front itself is drawn by
    /// CoreGraphics here).
    static func renderBlankBack(dpi: Int, intent: ScanIntent, sheetIndex: Int, sheetInches size: CGSize? = nil,
                                frontImage given: CGImage? = nil) -> CGImage? {
        guard let frontImage = given ?? renderSheet(dpi: dpi, intent: intent, sheetIndex: sheetIndex, side: .front, sheetInches: size),
              let front = RgbaImage(cgImage: frontImage) else { return nil }
        let width = front.width, height = front.height
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        var state: UInt32 = 0x9E37_79B9 ^ (UInt32(truncatingIfNeeded: sheetIndex + 1) &* 2_654_435_761)
        func next() -> UInt32 {
            state ^= state << 13
            state ^= state >> 17
            state ^= state << 5
            return state
        }
        for y in 0..<height {
            for x in 0..<width {
                // The front seen from behind: mirrored left to right.
                let fi = (y * width + (width - 1 - x)) * 4
                let frontLuma = (299 * Int(front.pixels[fi]) + 587 * Int(front.pixels[fi + 1])
                                 + 114 * Int(front.pixels[fi + 2]) + 500) / 1000
                let noise = Int(next() % 7 + next() % 7 + next() % 7 + next() % 7) - 12
                let value = min(255, max(0, 246 - (255 - frontLuma) / 10 + noise))
                let i = (y * width + x) * 4
                pixels[i] = UInt8(value)
                pixels[i + 1] = UInt8(value)
                pixels[i + 2] = UInt8(max(0, value - 3))   // a slightly warm paper
            }
        }
        // Dust: specks of one or two pixels at 300 dpi (never less than a pixel).
        for _ in 0..<40 {
            let x = Int(next() % UInt32(width))
            let y = Int(next() % UInt32(height))
            let speck = max(1, (dpi * (1 + Int(next() % 2)) + 150) / 300)
            for py in y..<min(height, y + speck) {
                for px in x..<min(width, x + speck) {
                    let i = (py * width + px) * 4
                    pixels[i] = 70
                    pixels[i + 1] = 70
                    pixels[i + 2] = 70
                }
            }
        }
        return RgbaImage(width: width, height: height, pixels: pixels).makeCGImage()
    }

    /// A separator sheet as the demo feeder delivers it: the Patch T sheet the app prints
    /// (`PatchCodeDetector.renderSheet`), `sheetInches` in size (`sheetInches` by default), on slightly
    /// off-white paper. Drawn pixel by pixel, the same as the C# demo.
    static func renderSeparatorSheet(dpi: Int, sheetInches size: CGSize? = nil) -> CGImage? {
        let inches = size ?? sheetInches
        return onPaper(PatchCodeDetector.renderSheet(.patchT, widthInches: Double(inches.width),
                                                     heightInches: Double(inches.height), dpi: dpi))
    }

    /// A barcode separator sheet as the demo feeder delivers it: `text` in Code 39 (`Code39.renderSheet`),
    /// `sheetInches` in size (`sheetInches` by default), on the same off-white paper as the patch-code
    /// sheet. Drawn pixel by pixel, the same as the C# demo.
    static func renderBarcodeSeparatorSheet(dpi: Int, text: String, sheetInches size: CGSize? = nil) -> CGImage? {
        let inches = size ?? sheetInches
        return onPaper(Code39.renderSheet(text, widthInches: Double(inches.width),
                                          heightInches: Double(inches.height), dpi: dpi))
    }

    /// A drawn sheet (black on white) as scanned: toner a little short of black, paper a little short of white.
    private static func onPaper(_ sheet: GrayImage) -> CGImage? {
        var pixels = [UInt8](repeating: 255, count: sheet.width * sheet.height * 4)
        for i in 0..<sheet.pixels.count {
            // Toner a little short of black, paper a little short of white.
            let value: UInt8 = sheet.pixels[i] == 0 ? 28 : 247
            pixels[i * 4] = value
            pixels[i * 4 + 1] = value
            pixels[i * 4 + 2] = value
        }
        return RgbaImage(width: sheet.width, height: sheet.height, pixels: pixels).makeCGImage()
    }

    // MARK: Book

    /// Where the open demo book lies on the glass, in inches from its top-left corner.
    static let bookInches = CGRect(x: 0.25, y: 0.5, width: 8.0, height: 6.0)
    /// The demo book's spine: this share of the scan's width from its left edge.
    static let bookGutterFraction = 0.52
    /// The spine's shadow darkens the pages by this share at its middle…
    static let bookShadowDepth = 0.25
    /// …fading like a bell curve with this spread (σ), in inches.
    static let bookShadowSigmaInches = 0.1

    /// The glass with a made-up open book on it at `spreadIndex` (0 = the first spread): two pages side
    /// by side (`bookInches`) meeting at the spine at `bookGutterFraction` of the width, each with
    /// text-shaped lines and, near its bottom outer corner, page-number marks (`spreadIndex % 5 + 1`
    /// squares) so spreads can be told apart; the spine's shadow (`bookShadowDepth` deep, σ =
    /// `bookShadowSigmaInches`) darkens the pages around it. Drawn pixel by pixel, as the C# demo draws it.
    static func renderBookSpread(dpi: Int, spreadIndex: Int) -> CGImage? {
        let scale = Double(dpi)
        let width = Int(8.5 * scale), height = Int(11.7 * scale)
        guard width > 0, height > 0 else { return nil }
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        // Near-white bed with a very subtle vertical gradient (0.97 → 0.945 gray), as the C# demo.
        for y in 0..<height {
            let t = Double(y) / Double(max(1, height - 1))
            let v = UInt8(((0.97 + (0.945 - 0.97) * t) * 255).rounded(.toNearestOrEven))
            for x in 0..<width {
                let i = (y * width + x) * 4
                pixels[i] = v
                pixels[i + 1] = v
                pixels[i + 2] = v
            }
        }
        // A rectangle in pixels, as the C# demo's FillRect: from the floor of its corner to the ceiling of its far edge.
        func fill(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ r: UInt8, _ g: UInt8, _ b: UInt8) {
            let x0 = max(0, Int(x)), y0 = max(0, Int(y))
            let x1 = min(width, Int((x + w).rounded(.up))), y1 = min(height, Int((y + h).rounded(.up)))
            guard x0 < x1, y0 < y1 else { return }
            for py in y0..<y1 {
                for px in x0..<x1 {
                    let i = (py * width + px) * 4
                    pixels[i] = r
                    pixels[i + 1] = g
                    pixels[i + 2] = b
                    pixels[i + 3] = 255
                }
            }
        }

        let bookX = Double(bookInches.minX) * scale, bookY = Double(bookInches.minY) * scale
        let bookW = Double(bookInches.width) * scale, bookH = Double(bookInches.height) * scale
        let gutter = bookGutterFraction * Double(width)
        fill(bookX, bookY, bookW, bookH, 252, 251, 247)

        // The lines of each page: text bars of varied length, 0.2 in apart.
        let lineTenths = [33, 34, 32, 34, 21, 0, 34, 33, 34, 31, 34, 17, 0, 34, 32, 33, 34, 30, 34, 26, 0, 33, 34, 28]
        let barHeight = 0.05 * scale, pitch = 0.2 * scale
        let inner = 0.45 * scale, outer = 0.5 * scale
        for side in 0..<2 {
            let pageLeft = side == 0 ? bookX + outer : gutter + inner
            let pageRight = side == 0 ? gutter - inner : bookX + bookW - outer
            let textWidth = pageRight - pageLeft
            var y = bookY + 0.6 * scale
            for line in 0..<lineTenths.count {
                let tenths = lineTenths[(line + 5 * side + 3 * spreadIndex) % lineTenths.count]
                if tenths > 0 { fill(pageLeft, y, textWidth * Double(tenths) / 34.0, barHeight, 60, 60, 64) }
                y += pitch
            }
            // Page-number marks near the page's bottom outer corner.
            let markSide = 0.12 * scale, markPitch = 0.2 * scale
            let markY = bookY + bookH - 0.45 * scale
            for mark in 0..<max(0, spreadIndex % 5 + 1) {
                let x = side == 0 ? pageLeft + Double(mark) * markPitch : pageRight - markSide - Double(mark) * markPitch
                fill(x, markY, markSide, markSide, 60, 60, 64)
            }
        }

        // The spine's shadow, over the book only.
        let sigma = bookShadowSigmaInches * scale
        let x0 = max(0, Int((gutter - 4 * sigma).rounded(.down))), x1 = min(width, Int((gutter + 4 * sigma).rounded(.up)))
        let y0 = max(0, Int(bookY)), y1 = min(height, Int((bookY + bookH).rounded(.up)))
        if x0 < x1 && y0 < y1 {
            for x in x0..<x1 {
                let d = Double(x) + 0.5 - gutter
                let keep = 1 - bookShadowDepth * exp(-d * d / (2 * sigma * sigma))
                for y in y0..<y1 {
                    let i = (y * width + x) * 4
                    for c in 0..<3 {
                        pixels[i + c] = UInt8((Double(pixels[i + c]) * keep).rounded(.toNearestOrEven))
                    }
                }
            }
        }
        return RgbaImage(width: width, height: height, pixels: pixels).makeCGImage()
    }

    // MARK: Receipts

    /// A made-up receipt lying on the glass: where (its centre, inches), its tilt, its size and its lines.
    private struct MockReceipt {
        let centerInches: CGPoint
        let sizeInches: CGSize
        let angleDegrees: Double
        let lines: [String]
    }

    /// The demo receipts: thermal paper (0.93) with faded print (0.6), tilted 3° either way. The shops
    /// are made up; each receipt carries a date for the date reader to find. The same as the C# demo.
    private static let receipts: [MockReceipt] = [
        MockReceipt(centerInches: CGPoint(x: 2.4, y: 3.2), sizeInches: CGSize(width: 3.15, height: 3.2), angleDegrees: 3,
                    lines: ["           DEMO CAFE", "      123 EXAMPLE STREET", "         TEL 555-0100", "",
                            "LATTE                       3.50", "CROISSANT                   2.40", "WATER                       1.20",
                            "MUFFIN                      2.80", "", "SUBTOTAL                    9.90", "TAX                         0.79",
                            "TOTAL                      10.69", "", "CARD ****4242", "", "DATE 12.03.2026         08:41", "",
                            "           THANK YOU"]),
        MockReceipt(centerInches: CGPoint(x: 6.3, y: 3.0), sizeInches: CGSize(width: 2.28, height: 2.3), angleDegrees: -3,
                    lines: ["     SAMPLE MART", "    RECEIPT 0042", "", "BREAD             2.10", "MILK              1.05",
                            "APPLES            2.40", "", "TOTAL             5.55", "", "2026-02-27       18:03", "",
                            "      NO RETURNS"]),
    ]

    /// Thermal paper and faded print, 0...255.
    static let receiptPaper: UInt8 = 237
    static let receiptInk: UInt8 = 153
    /// One unit of the receipts' stroke type, in inches: a character is 4 × 6 units, 5 units apart, a line 9 units tall.
    static let receiptUnitInches = 0.016
    /// The print starts this far from the receipt's top-left corner, in inches.
    static let receiptMarginInches = 0.2
    /// Half the width of a stroke of the receipts' type, in units.
    private static let receiptStrokeHalfWidth = 0.32

    /// Where the demo receipts lie (centre and size in inches, tilt in degrees), for checks.
    static var receiptPlaces: [(centerInches: CGPoint, sizeInches: CGSize, angleDegrees: Double)] {
        receipts.map { ($0.centerInches, $0.sizeInches, $0.angleDegrees) }
    }

    /// The glass with the two demo receipts on it, each tilted 3°: thermal paper barely darker than the
    /// lid, with faded print in a plain stroke type. Drawn pixel by pixel, as the C# demo draws them.
    static func renderReceiptBed(dpi: Int) -> CGImage? {
        let scale = Double(dpi)
        let width = Int(8.5 * scale), height = Int(11.7 * scale)
        guard width > 0, height > 0 else { return nil }
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        // Near-white bed with a very subtle vertical gradient (0.97 → 0.945 gray), as the C# demo.
        for y in 0..<height {
            let t = Double(y) / Double(max(1, height - 1))
            let v = UInt8(((0.97 + (0.945 - 0.97) * t) * 255).rounded())
            for x in 0..<width {
                let i = (y * width + x) * 4
                pixels[i] = v
                pixels[i + 1] = v
                pixels[i + 2] = v
            }
        }
        for receipt in receipts {
            let w = Double(receipt.sizeInches.width) * scale, h = Double(receipt.sizeInches.height) * scale
            let cx = Double(receipt.centerInches.x) * scale, cy = Double(receipt.centerInches.y) * scale
            let angle = receipt.angleDegrees * .pi / 180
            let c = cos(angle), s = sin(angle)
            let halfDiag = (w * w + h * h).squareRoot() / 2
            let minX = max(0, Int(cx - halfDiag)), maxX = min(width - 1, Int((cx + halfDiag).rounded(.up)))
            let minY = max(0, Int(cy - halfDiag)), maxY = min(height - 1, Int((cy + halfDiag).rounded(.up)))
            guard minX <= maxX, minY <= maxY else { continue }
            for py in minY...maxY {
                for px in minX...maxX {
                    let dx = Double(px) + 0.5 - cx, dy = Double(py) + 0.5 - cy
                    // Image → the receipt's own frame, in inches from its top-left corner.
                    let lx = (dx * c + dy * s) / scale + Double(receipt.sizeInches.width) / 2
                    let ly = (-dx * s + dy * c) / scale + Double(receipt.sizeInches.height) / 2
                    guard lx >= 0, ly >= 0, lx < Double(receipt.sizeInches.width), ly < Double(receipt.sizeInches.height) else { continue }
                    let value = receiptPrint(receipt.lines, x: lx - receiptMarginInches, y: ly - receiptMarginInches)
                        ? receiptInk : receiptPaper
                    let i = (py * width + px) * 4
                    pixels[i] = value
                    pixels[i + 1] = value
                    pixels[i + 2] = value
                }
            }
        }
        return RgbaImage(width: width, height: height, pixels: pixels).makeCGImage()
    }

    /// Whether (`x`, `y`) inches from the print's top-left corner is on a stroke of the lines.
    private static func receiptPrint(_ lines: [String], x: Double, y: Double) -> Bool {
        guard x >= 0, y >= 0 else { return false }
        let u = x / receiptUnitInches, v = y / receiptUnitInches
        let line = Int(v / 9), character = Int(u / 5)
        guard line < lines.count else { return false }
        let text = Array(lines[line])
        guard character < text.count, let strokes = receiptStrokes[text[character]] else { return false }
        let gu = u - Double(character * 5), gv = v - Double(line * 9)
        for (x0, y0, x1, y1) in strokes {
            // Distance to the segment: round ends, as a thermal head's dots run together.
            let dx = x1 - x0, dy = y1 - y0
            let t = dx == 0 && dy == 0 ? 0 : min(1, max(0, ((gu - x0) * dx + (gv - y0) * dy) / (dx * dx + dy * dy)))
            let ex = gu - (x0 + t * dx), ey = gv - (y0 + t * dy)
            if ex * ex + ey * ey <= receiptStrokeHalfWidth * receiptStrokeHalfWidth { return true }
        }
        return false
    }

    /// The receipts' type: capitals, digits and the signs the demo receipts use, as polylines on a 4 × 6
    /// grid (x right, y down), "|" between polylines. The same as the C# demo.
    private static let receiptGlyphs: [Character: String] = [
        "A": "0,6 2,0 4,6|1,4 3,4",
        "B": "0,3 3,3 4,4 4,5 3,6 0,6 0,0 3,0 4,1 4,2 3,3",
        "C": "4,1 3,0 1,0 0,1 0,5 1,6 3,6 4,5",
        "D": "0,0 0,6 2,6 4,4 4,2 2,0 0,0",
        "E": "4,0 0,0 0,6 4,6|0,3 3,3",
        "F": "4,0 0,0 0,6|0,3 3,3",
        "G": "4,1 3,0 1,0 0,1 0,5 1,6 3,6 4,5 4,3 2,3",
        "H": "0,0 0,6|4,0 4,6|0,3 4,3",
        "I": "1,0 3,0|2,0 2,6|1,6 3,6",
        "J": "4,0 4,5 3,6 1,6 0,5",
        "K": "0,0 0,6|4,0 0,4|1,3 4,6",
        "L": "0,0 0,6 4,6",
        "M": "0,6 0,0 2,3 4,0 4,6",
        "N": "0,6 0,0 4,6 4,0",
        "O": "1,0 3,0 4,1 4,5 3,6 1,6 0,5 0,1 1,0",
        "P": "0,6 0,0 3,0 4,1 4,2 3,3 0,3",
        "Q": "1,0 3,0 4,1 4,5 3,6 1,6 0,5 0,1 1,0|2,4 4,6",
        "R": "0,6 0,0 3,0 4,1 4,2 3,3 0,3|2,3 4,6",
        "S": "4,1 3,0 1,0 0,1 0,2 1,3 3,3 4,4 4,5 3,6 1,6 0,5",
        "T": "0,0 4,0|2,0 2,6",
        "U": "0,0 0,5 1,6 3,6 4,5 4,0",
        "V": "0,0 2,6 4,0",
        "W": "0,0 1,6 2,2 3,6 4,0",
        "X": "0,0 4,6|4,0 0,6",
        "Y": "0,0 2,3 4,0|2,3 2,6",
        "Z": "0,0 4,0 0,6 4,6",
        "0": "1.2,0 2.8,0 3.6,1 3.6,5 2.8,6 1.2,6 0.4,5 0.4,1 1.2,0",
        "1": "1,1 2,0 2,6|1,6 3,6",
        "2": "0,1 1,0 3,0 4,1 4,2 0,6 4,6",
        "3": "0,1 1,0 3,0 4,1 4,2 3,3 2,3|3,3 4,4 4,5 3,6 1,6 0,5",
        "4": "3,6 3,0 0,4 4,4",
        "5": "4,0 0.4,0 0,3 3,2.6 4,3.6 4,5 3,6 1,6 0,5",
        "6": "4,0.8 3,0 1,0 0,1 0,5 1,6 3,6 4,5 4,4 3,3 1,3 0,4",
        "7": "0,0 4,0 1,6",
        "8": "1,3 0,2 0,1 1,0 3,0 4,1 4,2 3,3 1,3 0,4 0,5 1,6 3,6 4,5 4,4 3,3",
        "9": "4,3 1,3 0,2 0,1 1,0 3,0 4,1 4,5 3,6 1,6",
        ".": "1.6,5.4 2.4,5.4 2.4,6 1.6,6 1.6,5.4|1.6,5.7 2.4,5.7",
        ":": "1.6,1.4 2.4,1.4 2.4,2 1.6,2 1.6,1.4|1.6,1.7 2.4,1.7|1.6,5.4 2.4,5.4 2.4,6 1.6,6 1.6,5.4|1.6,5.7 2.4,5.7",
        "-": "0.5,3 3.5,3",
        "*": "2,1 2,5|0.5,2 3.5,4|3.5,2 0.5,4",
        "/": "4,0 0,6",
    ]

    /// The segments (x0, y0, x1, y1) of each character of `receiptGlyphs`.
    private static let receiptStrokes: [Character: [(Double, Double, Double, Double)]] = {
        var strokes: [Character: [(Double, Double, Double, Double)]] = [:]
        for (character, glyph) in receiptGlyphs {
            var segments: [(Double, Double, Double, Double)] = []
            for polyline in glyph.split(separator: "|") {
                let points: [(Double, Double)] = polyline.split(separator: " ").map { pair in
                    let parts = pair.split(separator: ",")
                    return (Double(parts[0]) ?? 0, Double(parts[1]) ?? 0)
                }
                for k in 1..<max(1, points.count) {
                    segments.append((points[k - 1].0, points[k - 1].1, points[k].0, points[k].1))
                }
            }
            strokes[character] = segments
        }
        return strokes
    }()

    // MARK: ID card

    /// Where the sample card lies on the glass, front down (its centre, in inches from the top-left corner).
    static let idCardCenterInches = CGPoint(x: 2.35, y: 1.75)
    /// The sample card's tilt with its front down; turned over where it lay, the other way.
    static let idCardAngleDegrees: CGFloat = 4

    /// The glass with the sample ID card on it, near the top-left corner and tilted 4°: the `side`
    /// facing the glass. Turned over where it lay, the card's back is tilted the other way. The
    /// design is made up and says SAMPLE: a header band, a grey photo placeholder and field bars on
    /// the front; a barcode, SAMPLE and three lines of code blocks on the back. ID-1 size
    /// (3.370 × 2.125 in), with rounded corners. The same card as the C# demo, drawn with CoreGraphics.
    static func renderIdCardBed(dpi: Int, side: PageSide) -> CGImage? {
        let scale = CGFloat(dpi)
        let width = Int(bedInches.width * scale)
        let height = Int(bedInches.height * scale)
        guard width > 0, height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        // Flip so (0, 0) is the top-left corner and y grows downward.
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        drawBedBackground(in: ctx, width: CGFloat(width), height: CGFloat(height))

        let cardW = CGFloat(IdCardDetector.cardLongSideInches)
        let cardH = CGFloat(IdCardDetector.cardShortSideInches)
        ctx.saveGState()
        ctx.translateBy(x: idCardCenterInches.x * scale, y: idCardCenterInches.y * scale)
        // In this flipped (y-down) space a positive CG rotation appears clockwise on screen.
        ctx.rotate(by: (side == .front ? idCardAngleDegrees : -idCardAngleDegrees) * .pi / 180)
        // From here on, inches from the card's top-left corner.
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -cardW / 2, y: -cardH / 2)
        let card = CGRect(x: 0, y: 0, width: cardW, height: cardH)
        ctx.addPath(CGPath(roundedRect: card, cornerWidth: 0.125, cornerHeight: 0.125, transform: nil))
        ctx.clip()
        let paper = rgb(196 / 255, 224 / 255, 220 / 255)
        let ink = rgb(36 / 255, 44 / 255, 52 / 255)
        let red = rgb(190 / 255, 40 / 255, 40 / 255)
        ctx.setFillColor(paper)
        ctx.fill(card)
        if side == .front {
            // Header band with SAMPLE in white.
            ctx.setFillColor(rgb(30 / 255, 96 / 255, 104 / 255))
            ctx.fill(CGRect(x: 0, y: 0, width: cardW, height: 0.42))
            drawSample(in: ctx, x: 0.2, y: 0.07, cell: 0.04, color: gray(250 / 255))
            // Photo placeholder: a grey box with a head-and-shoulders outline.
            ctx.saveGState()
            let photo = CGRect(x: 0.18, y: 0.58, width: 0.8, height: 1.02)
            ctx.clip(to: photo)
            ctx.setFillColor(rgb(176 / 255, 184 / 255, 190 / 255))
            ctx.fill(photo)
            ctx.setFillColor(rgb(120 / 255, 128 / 255, 136 / 255))
            ctx.fillEllipse(in: CGRect(x: 0.58 - 0.17, y: 0.92 - 0.17, width: 0.34, height: 0.34))
            ctx.fillEllipse(in: CGRect(x: 0.58 - 0.34, y: 1.62 - 0.42, width: 0.68, height: 0.84))
            ctx.restoreGState()
            // Field labels and values.
            for (line, valueWidth) in cardFieldWidths.enumerated() {
                let top = 0.6 + CGFloat(line) * 0.3
                ctx.setFillColor(rgb(90 / 255, 130 / 255, 135 / 255))
                ctx.fill(CGRect(x: 1.15, y: top, width: 0.5, height: 0.05))
                ctx.setFillColor(ink)
                ctx.fill(CGRect(x: 1.15, y: top + 0.08, width: valueWidth, height: 0.09))
            }
            // SAMPLE again along the bottom, in red.
            drawSample(in: ctx, x: 1.15, y: 1.82, cell: 0.032, color: red)
        } else {
            // A barcode.
            ctx.setFillColor(ink)
            var bar = 0
            while 0.2 + CGFloat(bar) * 0.018 < cardW - 0.2 {
                if bar * 7 % 5 < 2 {
                    let x = 0.2 + CGFloat(bar) * 0.018
                    ctx.fill(CGRect(x: x, y: 0.2, width: min(0.018, cardW - 0.2 - x), height: 0.42))
                }
                bar += 1
            }
            drawSample(in: ctx, x: 1.0, y: 0.8, cell: 0.045, color: red)
            // Three lines of code blocks.
            ctx.setFillColor(ink)
            for line in 0..<3 {
                let top = cardH - 0.62 + CGFloat(line) * 0.17
                var cell = 0
                while 0.2 + CGFloat(cell) * 0.085 < cardW - 0.2 {
                    let x = 0.2 + CGFloat(cell) * 0.085
                    if (cell * 3 + line) % 7 != 0 {
                        ctx.fill(CGRect(x: x, y: top, width: min(0.06, cardW - 0.2 - x), height: 0.1))
                    }
                    cell += 1
                }
            }
        }
        ctx.restoreGState()
        return ctx.makeImage()
    }

    /// Lengths of the sample card's field values, in inches.
    private static let cardFieldWidths: [CGFloat] = [1.7, 1.25, 1.45, 0.95]

    /// 5 × 7 blocks of the letters S, A, M, P, L, E.
    private static let sampleGlyphs: [String] = [
        "01111" + "10000" + "10000" + "01110" + "00001" + "00001" + "11110",
        "01110" + "10001" + "10001" + "11111" + "10001" + "10001" + "10001",
        "10001" + "11011" + "10101" + "10101" + "10001" + "10001" + "10001",
        "11110" + "10001" + "10001" + "11110" + "10000" + "10000" + "10000",
        "10000" + "10000" + "10000" + "10000" + "10000" + "10000" + "11111",
        "11111" + "10000" + "10000" + "11110" + "10000" + "10000" + "11111",
    ]

    /// The word SAMPLE in blocks of `cell` inches, its top-left corner at (`x`, `y`) inches on the card.
    private static func drawSample(in ctx: CGContext, x: CGFloat, y: CGFloat, cell: CGFloat, color: CGColor) {
        ctx.setFillColor(color)
        for (letter, glyph) in sampleGlyphs.enumerated() {
            let bits = Array(glyph)
            for row in 0..<7 {
                for column in 0..<5 where bits[row * 5 + column] == "1" {
                    ctx.fill(CGRect(x: x + CGFloat(letter * 6 + column) * cell, y: y + CGFloat(row) * cell,
                                    width: cell, height: cell))
                }
            }
        }
    }

    // MARK: Background

    /// Near-white bed (~0.96) with a very subtle vertical gradient.
    private static func drawBedBackground(in ctx: CGContext, width: CGFloat, height: CGFloat) {
        let colors = [gray(0.97), gray(0.945)] as CFArray
        if let space = CGColorSpace(name: CGColorSpace.sRGB),
           let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) {
            ctx.drawLinearGradient(gradient,
                                   start: CGPoint(x: 0, y: 0),
                                   end: CGPoint(x: 0, y: height),
                                   options: [])
        } else {
            ctx.setFillColor(gray(0.96))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    // MARK: Photos

    private struct MockPhoto {
        var centerInches: CGPoint
        var sizeInches: CGSize
        var angleDegrees: CGFloat
    }

    /// Exactly three well-separated "photos" lying fully inside the bed.
    private static let photos: [MockPhoto] = [
        MockPhoto(centerInches: CGPoint(x: 2.5, y: 2.3), sizeInches: CGSize(width: 4.0, height: 3.0), angleDegrees: -12),
        MockPhoto(centerInches: CGPoint(x: 6.3, y: 6.0), sizeInches: CGSize(width: 3.0, height: 3.0), angleDegrees: 3),
        MockPhoto(centerInches: CGPoint(x: 2.9, y: 9.5), sizeInches: CGSize(width: 3.5, height: 2.5), angleDegrees: 17),
    ]

    /// `firstDesign` is the content design (0, 1, 2+) of the first photo in `items`.
    private static func drawPhotos(in ctx: CGContext, scale: CGFloat, items: [MockPhoto], firstDesign: Int) {
        let border = 0.08 * scale
        for (offset, photo) in items.enumerated() {
            let index = firstDesign + offset
            let w = photo.sizeInches.width * scale
            let h = photo.sizeInches.height * scale
            ctx.saveGState()
            ctx.translateBy(x: photo.centerInches.x * scale, y: photo.centerInches.y * scale)
            // In this flipped (y-down) space a positive CG rotation appears
            // clockwise on screen, matching the app's angle convention.
            ctx.rotate(by: photo.angleDegrees * .pi / 180)

            let outer = CGRect(x: -w / 2, y: -h / 2, width: w, height: h)
            let inner = outer.insetBy(dx: border, dy: border)

            // White print border.
            ctx.setFillColor(gray(1.0))
            ctx.fill(outer)

            switch index {
            case 0:
                fillLinearGradient(in: ctx, rect: inner,
                                   from: rgb(0.36, 0.62, 0.80), to: rgb(0.16, 0.34, 0.55))
                // Dark disc, offset so crops are visually distinct.
                ctx.setFillColor(rgb(0.10, 0.12, 0.16))
                let r = 0.45 * scale
                ctx.fillEllipse(in: CGRect(x: 0.7 * scale - r, y: -0.4 * scale - r, width: 2 * r, height: 2 * r))
            case 1:
                fillLinearGradient(in: ctx, rect: inner,
                                   from: rgb(0.93, 0.62, 0.25), to: rgb(0.75, 0.30, 0.16))
                // Dark square.
                let side = 0.9 * scale
                ctx.setFillColor(rgb(0.15, 0.10, 0.08))
                ctx.fill(CGRect(x: -0.55 * scale - side / 2, y: 0.35 * scale - side / 2, width: side, height: side))
            default:
                ctx.setFillColor(rgb(0.42, 0.40, 0.62))
                ctx.fill(inner)
                // Dark triangle.
                ctx.setFillColor(rgb(0.10, 0.09, 0.15))
                ctx.beginPath()
                ctx.move(to: CGPoint(x: -1.0 * scale, y: 0.6 * scale))
                ctx.addLine(to: CGPoint(x: -0.2 * scale, y: -0.6 * scale))
                ctx.addLine(to: CGPoint(x: 0.6 * scale, y: 0.6 * scale))
                ctx.closePath()
                ctx.fillPath()
            }
            ctx.restoreGState()
        }
    }

    private static func fillLinearGradient(in ctx: CGContext, rect: CGRect, from: CGColor, to: CGColor) {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let gradient = CGGradient(colorsSpace: space, colors: [from, to] as CFArray, locations: [0, 1]) else {
            ctx.setFillColor(from)
            ctx.fill(rect)
            return
        }
        ctx.saveGState()
        ctx.clip(to: rect)
        ctx.drawLinearGradient(gradient,
                               start: CGPoint(x: rect.minX, y: rect.minY),
                               end: CGPoint(x: rect.maxX, y: rect.maxY),
                               options: [])
        ctx.restoreGState()
    }

    // MARK: Document

    private static let documentTitle = "Lazy Scan Demo Document"

    private static let documentBody = [
        "Lazy Scan is a native macOS application for flatbed and",
        "document scanners. It captures multi-page documents, recognizes",
        "the text with on-device optical character recognition, and saves",
        "the result as a searchable PDF file.",
        "",
        "Photos placed on the scanner glass are detected automatically,",
        "straightened, and exported as individual image files. This page",
        "was produced by the built-in demo scanner, which renders a",
        "synthetic but realistic page so that the whole scanning pipeline",
        "can be tested without any hardware attached.",
        "",
        "The quick brown fox jumps over the lazy dog.",
    ]

    /// `pageInches` is the white page, in inches. When `sheetIndex` is set, `sheetIndex + 1`
    /// square marks are drawn near the bottom edge so feeder sheets can be told apart.
    private static func drawDocument(in ctx: CGContext, scale: CGFloat, pageInches: CGRect, sheetIndex: Int?) {
        let page = CGRect(x: pageInches.minX * scale, y: pageInches.minY * scale,
                          width: pageInches.width * scale,
                          height: pageInches.height * scale)
        ctx.setFillColor(gray(1.0))
        ctx.fill(page)

        let pointSize = scale / 72 // 1pt at this dpi
        let textColor = rgb(0.22, 0.22, 0.24)
        let left = page.minX + 0.75 * scale
        var y = page.minY + 0.9 * scale

        drawTextLine(documentTitle, in: ctx, topLeft: CGPoint(x: left, y: y),
                     fontSize: 18 * pointSize, bold: true, color: textColor)
        y += 18 * pointSize * 2.2

        let bodySize = 12 * pointSize
        let lineHeight = bodySize * 1.55
        for line in documentBody {
            if !line.isEmpty {
                drawTextLine(line, in: ctx, topLeft: CGPoint(x: left, y: y),
                             fontSize: bodySize, bold: false, color: textColor)
            }
            y += lineHeight
        }

        if let sheetIndex {
            // Sheet marks: 0.2 in squares, 0.35 in apart, their top 0.9 in above the page's bottom edge.
            let side = 0.2 * scale
            let pitch = 0.35 * scale
            let markY = page.maxY - 0.9 * scale
            ctx.setFillColor(textColor)
            for mark in 0...sheetIndex {
                ctx.fill(CGRect(x: left + CGFloat(mark) * pitch, y: markY, width: side, height: side))
            }
        }
    }

    private static let documentBackBody = [
        "This is the back of a demo sheet. Two-sided scans put it",
        "right after the front of the same sheet, upright, so the",
        "saved document reads in order from the first page to the",
        "last one.",
        "",
        "The marks below tell the sheets apart.",
    ]

    /// The back of a demo sheet: a short paragraph and `sheetIndex + 1` square marks near the
    /// bottom right, so backs can be told from fronts and their orientation seen.
    private static func drawDocumentBack(in ctx: CGContext, scale: CGFloat, pageInches: CGRect, sheetIndex: Int) {
        let page = CGRect(x: pageInches.minX * scale, y: pageInches.minY * scale,
                          width: pageInches.width * scale,
                          height: pageInches.height * scale)
        ctx.setFillColor(gray(1.0))
        ctx.fill(page)

        let textColor = rgb(0.22, 0.22, 0.24)
        let bodySize = 12 * scale / 72
        let left = page.minX + 0.75 * scale
        var y = page.minY + 0.9 * scale
        for line in documentBackBody {
            if !line.isEmpty {
                drawTextLine(line, in: ctx, topLeft: CGPoint(x: left, y: y),
                             fontSize: bodySize, bold: false, color: textColor)
            }
            y += bodySize * 1.55
        }

        // Sheet marks: 0.2 in squares, 0.35 in apart, the first one's right edge 0.75 in from the
        // page's right edge, their top 0.9 in above the bottom edge.
        let side = 0.2 * scale
        let pitch = 0.35 * scale
        let right = page.maxX - 0.75 * scale
        let markY = page.maxY - 0.9 * scale
        ctx.setFillColor(textColor)
        for mark in 0...sheetIndex {
            ctx.fill(CGRect(x: right - side - CGFloat(mark) * pitch, y: markY, width: side, height: side))
        }
    }

    /// Draws one line of real text with CoreText so Vision OCR can read it.
    /// The context is flipped (y down), so un-flip locally around the baseline.
    private static func drawTextLine(_ text: String, in ctx: CGContext, topLeft: CGPoint,
                                     fontSize: CGFloat, bold: Bool, color: CGColor) {
        let fontName = (bold ? "Helvetica-Bold" : "Helvetica") as CFString
        let font = CTFontCreateWithName(fontName, fontSize, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))

        ctx.saveGState()
        ctx.translateBy(x: topLeft.x, y: topLeft.y + CTFontGetAscent(font))
        ctx.scaleBy(x: 1, y: -1)
        ctx.textMatrix = .identity
        ctx.textPosition = .zero
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    // MARK: Colors

    private static func gray(_ value: CGFloat) -> CGColor {
        CGColor(srgbRed: value, green: value, blue: value, alpha: 1)
    }

    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor {
        CGColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }
}
