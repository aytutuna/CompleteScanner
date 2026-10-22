#if os(macOS)
import AppKit
import CompleteScannerKit
import SwiftUI

/// The bar under the tab bar when a paired phone's document was added to the queue or waits for it
/// (`AppState.phoneBarMessage`), with a close button. It is announced, and the Dock icon bounces once
/// when the app is in the background. Twin of the Windows phone bar (MainWindow.Phone.cs).
struct PhoneBarView: View {
    @EnvironmentObject var state: AppState

    let message: String

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "iphone")
                .font(.system(size: 15))
                .foregroundStyle(Color.accentColor)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.12)))
                .accessibilityHidden(true)
            Text(message)
                .font(.callout)
                .lineLimit(2)
            Spacer(minLength: 8)
            Button {
                state.dismissPhoneBar()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Close")
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .onAppear { arrived(message) }
        .onChange(of: message) { _, changed in arrived(changed) }
    }

    private func arrived(_ text: String) {
        AccessibilityNotification.Announcement(text).post()
        if !NSApp.isActive { _ = NSApp.requestUserAttention(.informationalRequest) }
    }
}
#endif
