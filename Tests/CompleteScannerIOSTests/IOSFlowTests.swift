#if os(iOS)
import AVFoundation
import XCTest
@testable import CompleteScannerIOS
@testable import CompleteScannerKit

// How the iPhone opens: the task it starts on, whether our camera opens by itself (and when the card saying
// why comes first), and when the scan screen keeps the step card.

final class IOSFlowTests: XCTestCase {
    func test_launchTask_isTheOneSetUpLastTime_elseDocumentToPDF() {
        XCTAssertEqual(IOSShell.launchTask(ScanSettings()), .document)
        for task in [ScanTask.receipt, .idCard, .batch, .copy, .document] {
            XCTAssertEqual(IOSShell.launchTask(TaskCatalog.apply(task, to: ScanSettings())), task, task.rawValue)
        }
        var unknown = ScanSettings()
        unknown.taskId = "somethingNewer"
        XCTAssertEqual(IOSShell.launchTask(unknown), .document)
    }

    func test_cameraOnOpen_opensWhereTheCameraCanBeUsed() {
        for status in [AVAuthorizationStatus.authorized, .notDetermined] {
            XCTAssertEqual(IOSShell.cameraOnOpen(offersCamera: true, camera: .available, authorization: status,
                                                 introShown: true, demo: false), .open)
        }
    }

    func test_cameraOnOpen_saysWhyBeforeTheFirstPrompt_once() {
        XCTAssertEqual(IOSShell.cameraOnOpen(offersCamera: true, camera: .available, authorization: .notDetermined,
                                             introShown: false, demo: false), .introduce)
        // Asked already: no card, whether it was shown or not.
        XCTAssertEqual(IOSShell.cameraOnOpen(offersCamera: true, camera: .available, authorization: .authorized,
                                             introShown: false, demo: false), .open)
        XCTAssertEqual(IOSShell.cameraIntroKey, "camera.introShown")
    }

    func test_cameraOnOpen_staysWithoutACamera_accessOff_orTheDemoScanner() {
        let stays: [(Bool, IOSCameraAvailability, AVAuthorizationStatus, Bool)] = [
            (true, .noCamera, .notDetermined, false),
            (true, .denied, .denied, false),
            (true, .restricted, .restricted, false),
            (false, .available, .authorized, false),
            (true, .available, .authorized, true),
            (true, .available, .notDetermined, true),
        ]
        for (offers, camera, status, demo) in stays {
            XCTAssertEqual(IOSShell.cameraOnOpen(offersCamera: offers, camera: camera, authorization: status,
                                                 introShown: false, demo: demo), .stay,
                           "\(offers) \(camera) \(status.rawValue) \(demo)")
        }
    }

    func test_stepCard_onlyWhileAStepNeedsIt() {
        let options = TaskOptions()
        let network: ScannerInfo = ScannerInfo(id: "escl:x", name: "Office MFP", transport: "Network", backend: "escl")
        XCTAssertFalse(IOSShell.showsStepCard(.document, options: options, sides: nil, newDocument: false,
                                              turningOverByHand: false, device: nil))
        XCTAssertFalse(IOSShell.showsStepCard(.twoSided, options: options, sides: CameraSides(mode: .flip),
                                              newDocument: false, turningOverByHand: false, device: nil))
        XCTAssertTrue(IOSShell.showsStepCard(.idCard, options: options, sides: nil, newDocument: false,
                                             turningOverByHand: false, device: nil))
        XCTAssertTrue(IOSShell.showsStepCard(.batch, options: options, sides: nil, newDocument: true,
                                             turningOverByHand: false, device: nil))
        var flip = CameraSides(mode: .flip)
        flip.took([UUID()])
        XCTAssertTrue(IOSShell.showsStepCard(.twoSided, options: options, sides: flip, newDocument: false,
                                             turningOverByHand: false, device: nil))
        XCTAssertTrue(IOSShell.showsStepCard(.document, options: options, sides: nil, newDocument: false,
                                             turningOverByHand: false, device: network))
        XCTAssertTrue(IOSShell.showsStepCard(.twoSided, options: options, sides: nil, newDocument: false,
                                             turningOverByHand: true, device: nil))
    }
}
#endif
