#if os(iOS)
import Foundation
import SwiftUI
import UIKit

/// The system share sheet (`UIActivityViewController`) for files, in a SwiftUI sheet. `onDone` runs
/// when the user has shared or cancelled, so the sheet closes with it.
struct ActivityView: UIViewControllerRepresentable {
    let items: [URL]
    let onDone: @MainActor () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let activityItems: [Any] = items
        let controller: UIActivityViewController = UIActivityViewController(activityItems: activityItems,
                                                                             applicationActivities: nil)
        let done: @MainActor () -> Void = onDone
        controller.completionWithItemsHandler = { (_: UIActivity.ActivityType?, _: Bool, _: [Any]?, _: Error?) -> Void in
            Task { @MainActor in
                done()
            }
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#endif
