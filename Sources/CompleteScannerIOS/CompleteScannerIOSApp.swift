#if os(iOS)
import CompleteScannerKit
import Foundation
import SwiftUI

/// The iPhone and iPad app: one window with the task start screen and the scan screen. The Xcode
/// project's app target (ios/project.yml) only starts it (`CompleteScannerIOSApp.main()`). Network
/// scanners are offered unless the app was launched with `-demoScanner` (the UI tests), which keeps the
/// demo scanner alone and never searches the network.
public struct CompleteScannerIOSApp: App {
    @StateObject private var fileActions: IOSFileActions
    @StateObject private var state: AppState
    @StateObject private var importer: IOSImportSession
    private let picker: IOSScannerPickerModel
    private let launchImport: IOSImportItem?

    public init() {
        let process: ProcessInfo = ProcessInfo.processInfo
        let options: IOSLaunchOptions = IOSLaunchOptions(arguments: process.arguments, environment: process.environment)
        let actions: IOSFileActions = IOSFileActions()
        let network: IOSNetworkScanners? = options.demoScannerOnly ? nil : IOSNetworkScanners()
        let appState: AppState = AppState.makeForIOS(options: options, fileActions: actions, networkScanners: network)
        let session: IOSImportSession = IOSImportSession(state: appState)
        _fileActions = StateObject(wrappedValue: actions)
        _state = StateObject(wrappedValue: appState)
        _importer = StateObject(wrappedValue: session)
        picker = IOSScannerPickerModel(state: appState, network: network)
        launchImport = options.launchImport
    }

    public var body: some Scene {
        WindowGroup {
            IOSRootView(fileActions: fileActions, importer: importer, picker: picker, launchImport: launchImport)
                .environmentObject(state)
        }
    }
}
#endif
