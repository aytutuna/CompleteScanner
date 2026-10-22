#if os(iOS)
import CompleteScannerKit
import Foundation
import SwiftUI

/// The iPhone and iPad app: one window with the task start screen and the scan screen. The Xcode
/// project's app target (ios/project.yml) only starts it (`CompleteScannerIOSApp.main()`). A protected PDF's
/// password is asked for with the password sheet (`IOSPasswordPrompt`), which the state keeps, and the
/// question before adding pages to a signed or PDF/A file with an alert (`IOSPDFAppend.confirm`). Network
/// scanners are offered unless the app was launched with `-demoScanner` (the UI tests), which keeps the
/// demo scanner alone and never searches the network, for scanners or for the computer the phone pairs
/// with (`IOSCompanionBrowser`).
public struct CompleteScannerIOSApp: App {
    @StateObject private var fileActions: IOSFileActions
    @StateObject private var state: AppState
    @StateObject private var importer: IOSImportSession
    private let picker: IOSScannerPickerModel
    private let companion: IOSCompanionBrowser?
    private let launchImports: [IOSImportItem]
    private let launchTask: ScanTask?

    public init() {
        let process: ProcessInfo = ProcessInfo.processInfo
        let options: IOSLaunchOptions = IOSLaunchOptions(arguments: process.arguments, environment: process.environment)
        let actions: IOSFileActions = IOSFileActions()
        let network: IOSNetworkScanners? = options.demoScannerOnly ? nil : IOSNetworkScanners()
        let browser: IOSCompanionBrowser? = options.demoScannerOnly ? nil : IOSCompanionBrowser()
        let prompt: IOSPasswordPrompt = IOSPasswordPrompt()
        let appState: AppState = AppState.makeForIOS(options: options, fileActions: actions, networkScanners: network,
                                                     passwordPrompt: prompt,
                                                     confirmAppend: { (question: String) async -> Bool in
                                                         await IOSPDFAppend.confirm(question)
                                                     },
                                                     companion: browser)
        let session: IOSImportSession = IOSImportSession(state: appState)
        _fileActions = StateObject(wrappedValue: actions)
        _state = StateObject(wrappedValue: appState)
        _importer = StateObject(wrappedValue: session)
        picker = IOSScannerPickerModel(state: appState, network: network)
        companion = browser
        launchImports = options.launchImports
        launchTask = options.launchTask
    }

    public var body: some Scene {
        WindowGroup {
            IOSRootView(fileActions: fileActions, importer: importer, picker: picker, launchImports: launchImports,
                        launchTask: launchTask, companion: companion)
                .environmentObject(state)
        }
    }
}
#endif
