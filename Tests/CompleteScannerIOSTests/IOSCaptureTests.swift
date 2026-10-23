#if os(iOS)
import AVFoundation
import CoreGraphics
import Foundation
import UIKit
import XCTest
@testable import CompleteScannerIOS
@testable import CompleteScannerKit

// Apple's document scanner behind the Document, Email and Word cards (`IOSDocumentCamera`): its pages
// sized by their shape and brought in whole, the camera's availability and its one-line reasons (the
// Simulator has none), and what the scan screen offers to save (`IOSShell`); the launch option the
// import UI test uses. The scanner itself needs a device and is not opened here.

/// A white page of `width` × `height` with a dark bar.
private func scannedPicture(width: Int, height: Int) -> CGImage {
    let ctx: CGContext = ImportTestSupport.context(width: width, height: height)
    ctx.setFillColor(CGColor(srgbRed: 0.97, green: 0.97, blue: 0.96, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    ctx.setFillColor(CGColor(srgbRed: 0.1, green: 0.1, blue: 0.12, alpha: 1))
    ctx.fill(CGRect(x: width / 8, y: height / 2, width: width * 3 / 4, height: max(4, height / 30)))
    return ctx.makeImage()!
}

final class IOSCaptureTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = try ImportTestSupport.makeFolder("IOSCaptureTests")
    }

    override func tearDown() async throws {
        // The settings are written 0.4 s after they change: let that write land before the folder goes.
        try await Task.sleep(nanoseconds: 600_000_000)
        try? FileManager.default.removeItem(at: folder)
    }

    func test_scannerPages_areSizedByTheirShape_andMeasuredAlready() throws {
        let letter: CGImage = scannedPicture(width: 1275, height: 1650)
        let square: CGImage = scannedPicture(width: 900, height: 900)
        let pages: [ScannedPage] = IOSDocumentCamera.pages([letter, square])
        XCTAssertEqual(pages.count, 2)
        // Letter's shape: 1650 px over 11 in.
        let first: CaptureScaleResult = try XCTUnwrap(pages[0].capture?.scale)
        XCTAssertEqual(first.basis, .paper)
        XCTAssertEqual(first.size, "letter")
        XCTAssertEqual(pages[0].dpi, 150)
        XCTAssertEqual(first, CaptureScale.fromAspect(pixelWidth: 1275, pixelHeight: 1650, kind: .document))
        // No paper's shape: the nominal 200 dpi, the size made up.
        let second: CaptureScaleResult = try XCTUnwrap(pages[1].capture?.scale)
        XCTAssertEqual(second.basis, .nominal)
        XCTAssertFalse(second.isRealSize)
        XCTAssertEqual(pages[1].dpi, CaptureScale.nominalDPI)
        // Taken whole: the whole picture is its outline, in its own pixels.
        let facts: CaptureFacts = try XCTUnwrap(pages[0].capture)
        XCTAssertEqual(facts.quad, PhotoImport.wholePhoto(width: 1275, height: 1650))
        XCTAssertEqual(facts.sourceWidth, 1275)
        XCTAssertEqual(facts.sourceHeight, 1650)
        XCTAssertEqual(facts.kind, .document)
        XCTAssertNil(facts.focalLength)
        XCTAssertEqual(pages[0].source, .photo)
        XCTAssertTrue(pages[0].image === letter)
        // Measured already: the clean-up stage does not cut it again.
        let again: ScannedPage = PerspectiveStep().apply(pages[0])
        XCTAssertNil(again.geometry)
        XCTAssertTrue(again.image === letter)
        XCTAssertEqual(IOSDocumentCamera.tasks, [.document, .email, .word])
    }

    @MainActor
    func test_scannerPages_comeIntoTheQueue_asTheyAre() async throws {
        let state: AppState = ImportTestSupport.makeState(in: folder)
        let importer = IOSImportSession(state: state)
        let pages: [ScannedPage] = IOSDocumentCamera.pages([scannedPicture(width: 1275, height: 1650),
                                                            scannedPicture(width: 1240, height: 1754)])
        let taken: Bool = await importer.bringInScans(pages)
        XCTAssertTrue(taken)
        try await ImportTestSupport.waitUntil(timeout: 60) { !state.isBusy }
        defer { state.deleteSpoolFiles(of: state.scannedPages) }
        XCTAssertNil(state.errorMessage)
        XCTAssertEqual(state.scannedPages.count, 2)
        XCTAssertEqual(state.scannedPages[0].dpi, 150)
        XCTAssertEqual(state.scannedPages[1].capture?.scale?.size, "a4")
        XCTAssertEqual(state.scannedPages[1].dpi, 150)
        for page in state.scannedPages {
            XCTAssertNil(page.geometry)
            XCTAssertEqual(page.source, .photo)
        }
        XCTAssertEqual(state.scannedPages[0].fullPixelSize, CGSize(width: 1275, height: 1650))
        // Nothing to bring in.
        let none: Bool = await importer.bringInScans([])
        XCTAssertFalse(none)
    }

    func test_cameraAvailability_andItsReasons() {
        XCTAssertEqual(IOSCameraAvailability.resolve(isSupported: false, authorization: .authorized), .noCamera)
        XCTAssertEqual(IOSCameraAvailability.resolve(isSupported: false, authorization: .denied), .noCamera)
        XCTAssertEqual(IOSCameraAvailability.resolve(isSupported: true, authorization: .denied), .denied)
        XCTAssertEqual(IOSCameraAvailability.resolve(isSupported: true, authorization: .restricted), .restricted)
        XCTAssertEqual(IOSCameraAvailability.resolve(isSupported: true, authorization: .notDetermined), .available)
        XCTAssertEqual(IOSCameraAvailability.resolve(isSupported: true, authorization: .authorized), .available)
        XCTAssertNil(IOSCameraAvailability.available.reason)
        XCTAssertTrue(IOSCameraAvailability.available.isAvailable)
        XCTAssertEqual(IOSCameraAvailability.noCamera.reason, "No camera here")
        XCTAssertEqual(IOSCameraAvailability.denied.reason, "Camera access is off")
        XCTAssertEqual(IOSCameraAvailability.restricted.reason, "Camera not allowed")
        XCTAssertTrue(IOSCameraAvailability.denied.opensSettings)
        XCTAssertFalse(IOSCameraAvailability.noCamera.opensSettings)
        // Each reason is a few words, as the start screen's are.
        for availability in [IOSCameraAvailability.noCamera, .denied, .restricted] {
            let words: Int = (availability.reason ?? "").split(separator: " ").count
            XCTAssertLessThanOrEqual(words, 4)
        }
    }

    @MainActor
    func test_theSimulator_hasNoDocumentCamera() throws {
        #if targetEnvironment(simulator)
        XCTAssertEqual(IOSCameraAvailability.current, .noCamera)
        #else
        throw XCTSkip("Runs on the Simulator, where VisionKit's document camera is not supported.")
        #endif
    }

    func test_theScanScreen_offersTheCamera_onDocumentEmailAndWord() {
        XCTAssertTrue(IOSShell.offersCamera(.document))
        XCTAssertTrue(IOSShell.offersCamera(.email))
        XCTAssertTrue(IOSShell.offersCamera(.word))
        XCTAssertFalse(IOSShell.offersCamera(.feeder))
        XCTAssertFalse(IOSShell.offersCamera(.photos))
        XCTAssertFalse(IOSShell.offersCamera(nil))
        // The camera's cards are offered; the others stay as they were, dimmed with their reasons.
        for task in IOSDocumentCamera.tasks {
            XCTAssertTrue(IOSShell.offers(task), task.rawValue)
        }
    }

    func test_save_writesPictures_whileTheQueueIsSavedAsJPEG() {
        var settings = ScanSettings()
        settings.format = .pdf
        XCTAssertFalse(IOSShell.savesImages(settings))
        settings.format = .jpeg
        XCTAssertTrue(IOSShell.savesImages(settings))
        settings.format = .word
        XCTAssertFalse(IOSShell.savesImages(settings))

        let first = ScannedPage(image: scannedPicture(width: 40, height: 50), dpi: 100, colorMode: .color)
        let second = ScannedPage(image: scannedPicture(width: 40, height: 50), dpi: 100, colorMode: .color)
        let plan: SavePlan = SavePlan.make([first, second], options: ScanSettings().document)
        XCTAssertEqual(plan.pageCount, 2)
        settings.format = .jpeg
        XCTAssertEqual(IOSShell.saveTitle(settings, plan: plan), "Save 2 JPEGs")
        settings.format = .pdf
        XCTAssertEqual(IOSShell.saveTitle(settings, plan: plan), plan.saveTitle(.pdf))
    }

    func test_theImportLaunchOption_carriesOnePhoto() {
        let bytes = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
        let environment: [String: String] = [IOSLaunchOptions.importFixtureVariable: bytes.base64EncodedString()]
        let options = IOSLaunchOptions(arguments: ["CompleteScanner", "-demoScanner", "-importFixture"],
                                       environment: environment)
        XCTAssertTrue(options.demoScannerOnly)
        XCTAssertEqual(options.launchImport, IOSImportItem(name: "fixture.png", data: bytes, kind: .image))
        // Without the argument, or without readable bytes, nothing is imported.
        XCTAssertNil(IOSLaunchOptions(arguments: ["CompleteScanner"], environment: environment).launchImport)
        XCTAssertNil(IOSLaunchOptions(arguments: ["CompleteScanner", "-importFixture"],
                                      environment: [IOSLaunchOptions.importFixtureVariable: "%%%"]).launchImport)
        XCTAssertNil(IOSLaunchOptions(arguments: ["CompleteScanner", "-importFixture"]).launchImport)
        XCTAssertNil(IOSLaunchOptions(demoScannerOnly: true).launchImport)
        XCTAssertEqual(IOSLaunchOptions.importFixtureArgument, "-importFixture")
    }

    func test_theImportLaunchOption_carriesSeveralFiles_aPDFAsOne() {
        let photo = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
        let pdf = Data("%PDF-1.4\n%fixture\n".utf8)
        let text: String = photo.base64EncodedString() + "," + pdf.base64EncodedString()
        let options = IOSLaunchOptions(arguments: ["CompleteScanner", "-demoScanner", "-importFixture", "-importTask", "twoSided"],
                                       environment: [IOSLaunchOptions.importFixtureVariable: text])
        XCTAssertEqual(options.launchImports, [IOSImportItem(name: "fixture.png", data: photo, kind: .image),
                                               IOSImportItem(name: "fixture.pdf", data: pdf, kind: .pdf)])
        XCTAssertEqual(options.launchImport, options.launchImports.first)
        XCTAssertEqual(options.launchTask, .twoSided)
        // A part that does not read is left out; the others come in.
        let mixed = IOSLaunchOptions(arguments: ["CompleteScanner", "-importFixture"],
                                     environment: [IOSLaunchOptions.importFixtureVariable: "%%%," + pdf.base64EncodedString()])
        XCTAssertEqual(mixed.launchImports.map(\.kind), [.pdf])
        XCTAssertTrue(IOSLaunchOptions(demoScannerOnly: false).launchImports.isEmpty)
    }

    func test_anUprightPicture_isKept_andATurnedOneIsDrawnUpright() throws {
        let picture: CGImage = scannedPicture(width: 30, height: 20)
        let upright = UIImage(cgImage: picture, scale: 1, orientation: .up)
        XCTAssertTrue(IOSDocumentCamera.uprightImage(upright) === picture)
        let turned = UIImage(cgImage: picture, scale: 1, orientation: .right)
        let drawn: CGImage = try XCTUnwrap(IOSDocumentCamera.uprightImage(turned))
        XCTAssertEqual(drawn.width, 20)
        XCTAssertEqual(drawn.height, 30)
    }
}
#endif
