#if os(iOS)
import CompleteScannerKit
import Foundation
import SwiftUI

/// The iPhone and iPad app: one window with the task start screen and the scan screen. The Xcode
/// project's app target (ios/project.yml) only starts it (`CompleteScannerIOSApp.main()`).
public struct CompleteScannerIOSApp: App {
    @StateObject private var fileActions: IOSFileActions
    @StateObject private var state: AppState

    public init() {
        let options: IOSLaunchOptions = IOSLaunchOptions(arguments: ProcessInfo.processInfo.arguments)
        let actions: IOSFileActions = IOSFileActions()
        let appState: AppState = AppState.makeForIOS(options: options, fileActions: actions)
        _fileActions = StateObject(wrappedValue: actions)
        _state = StateObject(wrappedValue: appState)
    }

    public var body: some Scene {
        WindowGroup {
            IOSRootView(fileActions: fileActions)
                .environmentObject(state)
        }
    }
}
#endif
