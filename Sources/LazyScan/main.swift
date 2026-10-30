#if os(macOS)
import AppKit
import LazyScanMac

NSApplication.shared.setActivationPolicy(.regular)
LazyScanApp.main()
#endif
