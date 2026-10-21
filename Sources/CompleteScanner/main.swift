#if os(macOS)
import AppKit
import CompleteScannerMac

NSApplication.shared.setActivationPolicy(.regular)
CompleteScannerApp.main()
#endif
