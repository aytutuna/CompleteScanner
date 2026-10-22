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
        .commands {
            // File > Import from iPhone or iPad: Continuity Camera, taken by ContentView's importsItemProviders.
            ImportFromDevicesCommands()
        }
    }
}

extension AppState {
    /// The Mac app's state: ImageCaptureCore's scanners and the demo scanner, with the Mac's file
    /// actions, troubleshooter links, printing and app lifecycle, the password dialog of a protected
    /// PDF (`PDFPasswordWindow`) and the question before adding pages to a signed or PDF/A file.
    @MainActor
    static func makeForMac() -> AppState {
        let backends: [any ScannerBackend] = [ICScannerBackend(), AppState.makeDemoBackend()]
        let state = AppState(backends: backends,
                             fileActions: SystemFileActions(),
                             troubleshooterService: SystemTroubleshooterService(),
                             printService: SystemPrintService(),
                             lifecycle: AppKitLifecycle())
        state.askPDFPassword = { PDFPasswordWindow.ask() }
        state.confirmAppend = { AppState.confirmAppendAlert($0) }
        return state
    }
}
#endif
