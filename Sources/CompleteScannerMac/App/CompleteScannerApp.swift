#if os(macOS)
import AppKit
import CompleteScannerKit
import SwiftUI

public struct CompleteScannerApp: App {
    @StateObject private var state = AppState.makeForMac()

    public init() {}

    public var body: some Scene {
        WindowGroup("CompleteScanner") {
            // Minimum size lives on ContentView (700x560) — an outer minimum here
            // would override it and force an oversized window on small screens.
            ContentView()
                .environmentObject(state)
                .onAppear { NSApp.activate(ignoringOtherApps: true) }
        }
    }
}

extension AppState {
    /// The Mac app's state: ImageCaptureCore's scanners and the demo scanner, with the Mac's file
    /// actions, troubleshooter links, printing and app lifecycle.
    @MainActor
    static func makeForMac() -> AppState {
        let backends: [any ScannerBackend] = [ICScannerBackend(), AppState.makeDemoBackend()]
        return AppState(backends: backends,
                        fileActions: SystemFileActions(),
                        troubleshooterService: SystemTroubleshooterService(),
                        printService: SystemPrintService(),
                        lifecycle: AppKitLifecycle())
    }
}
#endif
