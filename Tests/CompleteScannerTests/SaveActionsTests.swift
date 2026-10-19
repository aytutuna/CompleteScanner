import XCTest
import Foundation
@testable import CompleteScannerKit

// Twin of windows/CompleteScanner.Core.Tests/SaveActionsTests.cs: what happens after a save,
// the actions offered for saved files, what Copy puts on the clipboard and how files are sent.
// (The C# case of an enum value outside the declared ones has no Swift counterpart.)

private let onePDF = [URL(fileURLWithPath: "/Scans/Scan 2026-10-19 1.pdf")]
private let threePhotos = ["Photo 1.jpg", "Photo 2.jpg", "Photo 3.jpg"].map { URL(fileURLWithPath: "/Scans/" + $0) }

private func decodeSettings(_ json: String) throws -> ScanSettings {
    try JSONDecoder().decode(ScanSettings.self, from: Data(json.utf8))
}

/// Encoded exactly the way the stores write files.
private func encodeSettings(_ settings: ScanSettings) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(settings)
}

final class SaveActionsTests: XCTestCase {

    func test_afterSave_noneIsTheFirstCaseAndTheDefault() {
        XCTAssertEqual(AfterSaveAction.allCases.map(\.rawValue), ["none", "open", "reveal", "share"])
        XCTAssertEqual(OutputOptions().afterSave, AfterSaveAction.none)
        XCTAssertEqual(ScanSettings().output.afterSave, AfterSaveAction.none)
    }

    func test_afterSave_labels() {
        XCTAssertEqual(AfterSaveAction.allCases.map(\.label), ["Do nothing", "Open", "Show in folder", "Share\u{2026}"])
        for action in AfterSaveAction.allCases {
            XCTAssertFalse(action.hint.isEmpty, action.rawValue)
        }
        XCTAssertEqual(FileAction.allCases.map(\.label),
                       ["Open", "Open with\u{2026}", "Show in folder", "Share\u{2026}", "Email\u{2026}", "Copy"])
    }

    func test_plan_nothingToDo() {
        XCTAssertNil(SaveActions.plan(AfterSaveAction.none, saved: onePDF))
        XCTAssertNil(SaveActions.plan(AfterSaveAction.none, saved: threePhotos))
        for action in AfterSaveAction.allCases {
            XCTAssertNil(SaveActions.plan(action, saved: []), action.rawValue)
        }
    }

    func test_plan_oneFile_doesWhatWasChosen() {
        XCTAssertEqual(SaveActions.plan(.open, saved: onePDF), SaveFollowUp(action: .open, urls: onePDF))
        XCTAssertEqual(SaveActions.plan(.reveal, saved: onePDF), SaveFollowUp(action: .reveal, urls: onePDF))
        XCTAssertEqual(SaveActions.plan(.share, saved: onePDF), SaveFollowUp(action: .share, urls: onePDF))
    }

    func test_plan_severalFiles_areShownInsteadOfOpenedOneByOne() {
        XCTAssertEqual(SaveActions.plan(.open, saved: threePhotos), SaveFollowUp(action: .reveal, urls: threePhotos))
        XCTAssertEqual(SaveActions.plan(.reveal, saved: threePhotos), SaveFollowUp(action: .reveal, urls: threePhotos))
        XCTAssertEqual(SaveActions.plan(.share, saved: threePhotos), SaveFollowUp(action: .share, urls: threePhotos))
    }

    func test_followUp_isCarriedOutByItsFileAction() {
        XCTAssertEqual(SaveActions.plan(.open, saved: onePDF)?.fileAction, .open)
        XCTAssertEqual(SaveActions.plan(.open, saved: threePhotos)?.fileAction, .reveal)
        XCTAssertEqual(SaveActions.plan(.reveal, saved: onePDF)?.fileAction, .reveal)
        XCTAssertEqual(SaveActions.plan(.share, saved: threePhotos)?.fileAction, .share)
    }

    func test_plan_copiesThePaths() throws {
        var urls = onePDF
        let plan = try XCTUnwrap(SaveActions.plan(.share, saved: urls))
        urls.append(URL(fileURLWithPath: "/Scans/later.pdf"))
        XCTAssertEqual(plan.urls, onePDF)
    }

    func test_offered_dependsOnTheNumberOfFiles() {
        XCTAssertEqual(SaveActions.offered(fileCount: 0), [])
        XCTAssertEqual(SaveActions.offered(fileCount: 1), [.open, .openWith, .reveal, .share, .email, .copy])
        XCTAssertEqual(SaveActions.offered(fileCount: 2), [.reveal, .share, .email, .copy])
        XCTAssertEqual(SaveActions.offered(fileCount: 40), SaveActions.offered(fileCount: 2))
    }

    func test_isImageFile_byExtension() {
        for name in ["a.jpg", "a.JPG", "a.jpeg", "a.png", "a.tif", "a.TIFF", "Scan 1.2.png"] {
            XCTAssertTrue(SaveActions.isImageFile(URL(fileURLWithPath: "/Scans/" + name)), name)
        }
        for name in ["a.pdf", "a.txt", "a", "jpg", "a.jpg.pdf", "a.webp"] {
            XCTAssertFalse(SaveActions.isImageFile(URL(fileURLWithPath: "/Scans/" + name)), name)
        }
    }

    func test_clipboardContent_thePictureOnlyForOneImage() {
        let photo = URL(fileURLWithPath: "/Scans/Photo 1.jpg")
        let tiff = URL(fileURLWithPath: "/Scans/Scan.tiff")
        XCTAssertEqual(SaveActions.clipboardContent(for: [photo]), ClipboardContent(files: [photo], imageFile: photo))
        XCTAssertEqual(SaveActions.clipboardContent(for: [tiff]), ClipboardContent(files: [tiff], imageFile: tiff))
        XCTAssertEqual(SaveActions.clipboardContent(for: onePDF), ClipboardContent(files: onePDF, imageFile: nil))
        XCTAssertEqual(SaveActions.clipboardContent(for: threePhotos), ClipboardContent(files: threePhotos, imageFile: nil))
        XCTAssertEqual(SaveActions.clipboardContent(for: []), ClipboardContent(files: [], imageFile: nil))
    }

    func test_emailRoute_composeThenShareThenFolder() {
        XCTAssertEqual(SaveActions.emailRoute(SendProbe(canCompose: true, canShare: true)), .compose)
        XCTAssertEqual(SaveActions.emailRoute(SendProbe(canCompose: true, canShare: false)), .compose)
        XCTAssertEqual(SaveActions.emailRoute(SendProbe(canCompose: false, canShare: true)), .shareSheet)
        XCTAssertEqual(SaveActions.emailRoute(SendProbe(canCompose: false, canShare: false)), .showInFolder)
    }

    func test_shareRoute_shareThenFolder() {
        XCTAssertEqual(SaveActions.shareRoute(SendProbe(canCompose: true, canShare: true)), .shareSheet)
        XCTAssertEqual(SaveActions.shareRoute(SendProbe(canCompose: false, canShare: true)), .shareSheet)
        XCTAssertEqual(SaveActions.shareRoute(SendProbe(canCompose: true, canShare: false)), .showInFolder)
        XCTAssertEqual(SaveActions.shareRoute(SendProbe(canCompose: false, canShare: false)), .showInFolder)
    }

    func test_shareTitle_namesOneFileOrCountsThem() {
        XCTAssertEqual(SaveActions.shareTitle(onePDF), "Scan 2026-10-19 1.pdf")
        XCTAssertEqual(SaveActions.shareTitle([URL(fileURLWithPath: "/Scans/folder/Scan.pdf")]), "Scan.pdf")
        XCTAssertEqual(SaveActions.shareTitle(threePhotos), "3 files")
    }

    // MARK: The setting in settings files (CONTRACTS.md, rule 6)

    func test_afterSave_isWrittenUnderOutput_andRoundTrips() throws {
        for action in AfterSaveAction.allCases {
            var settings = ScanSettings()
            settings.output.afterSave = action
            let data = try encodeSettings(settings)
            let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            let output = try XCTUnwrap(object["output"] as? [String: Any])
            XCTAssertEqual(Set(output.keys), ["pdfSize", "afterSave"])
            XCTAssertEqual(output["afterSave"] as? String, action.rawValue)
            XCTAssertEqual(try JSONDecoder().decode(ScanSettings.self, from: data).output.afterSave, action)
        }
    }

    func test_settingsWithoutAfterSave_getNone_restIntact() throws {
        XCTAssertEqual(try decodeSettings("{}").output.afterSave, AfterSaveAction.none)
        let settings = try decodeSettings(#"{"resolution": 150, "output": {"pdfSize": "compact"}}"#)
        XCTAssertEqual(settings.output.afterSave, AfterSaveAction.none)
        XCTAssertEqual(settings.output.pdfSize, .compact)
        XCTAssertEqual(settings.resolution, 150)
    }

    func test_unknownOrCorruptAfterSave_fallsBackToNone_restIntact() throws {
        for value in [#""print""#, #""Share""#, #""SHARE""#, "3", "null", "true", "{}", #"["share"]"#] {
            let settings = try decodeSettings(
                #"{"resolution": 150, "output": {"pdfSize": "smallest", "afterSave": "# + value + #"}, "pdfSearchable": false}"#)
            XCTAssertEqual(settings.output.afterSave, AfterSaveAction.none, value)
            XCTAssertEqual(settings.output.pdfSize, .smallest, value)
            XCTAssertEqual(settings.resolution, 150, value)
            XCTAssertFalse(settings.pdfSearchable, value)
        }
    }

    func test_copy_carriesTheAfterSaveAction() {
        var settings = ScanSettings()
        settings.output.afterSave = .share
        var copy = settings
        XCTAssertEqual(copy.output.afterSave, .share)
        copy.output.afterSave = .open
        XCTAssertEqual(settings.output.afterSave, .share)
        XCTAssertNotEqual(settings.output, copy.output)
    }

    // MARK: Tasks

    func test_emailTask_sharesAfterSaving_otherTasksDoNothing() {
        var current = ScanSettings()
        current.output.afterSave = .open
        for task in ScanTask.allCases {
            let expected: AfterSaveAction = task == .email ? .share : AfterSaveAction.none
            XCTAssertEqual(TaskCatalog.apply(task, to: current).output.afterSave, expected, task.rawValue)
        }
        XCTAssertEqual(current.output.afterSave, .open)
        // Choosing another action by hand keeps the task.
        var email = TaskCatalog.apply(.email, to: current)
        email.output.afterSave = .reveal
        XCTAssertTrue(TaskCatalog.fits(.email, email))
        XCTAssertTrue(TaskCatalog.definition(.email).steps[0].prompt.contains("share window"))
    }
}
