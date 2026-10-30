#if os(macOS)
import LazyScanKit
import SwiftUI

/// The banner under the tab bar while a `.lsdoc` opened by hand is offered (`AppState.pendingPackage`):
/// "Opened Receipt.lsdoc: 3 pages", Add to pages, Open as new and a close button that drops the offer.
/// The two buttons wait while something runs or a review is open. Twin of the Windows package banner.
struct PackageBannerView: View {
    @EnvironmentObject var state: AppState

    let package: PendingPackage
    /// Open as new asks first while it would drop queued pages (the replace alert), as the iPhone does.
    @State private var asksReplace = false

    var body: some View {
        let pageCount: Int = state.scannedPages.count
        let replaceTitle: String = pageCount == 1 ? "Replace the page in the queue?" : "Replace the \(pageCount) pages in the queue?"
        let replaceLine: String = pageCount == 1
            ? "It has not been saved. \u{201C}\(package.fileName)\u{201D} opens in its place."
            : "They have not been saved. \u{201C}\(package.fileName)\u{201D} opens in their place."
        let discardLabel: String = "Discard \(pageCount) page\(pageCount == 1 ? "" : "s")"
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 15))
                .foregroundStyle(Color.accentColor)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.12)))
                .accessibilityHidden(true)
            Text(PackageText.openedMessage(package.fileName, pageCount: package.pageCount))
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Group {
                Button(PackageText.addToPages) { state.addPendingPackageToPages() }
                    .help(state.isTurningOverByHand ? DocumentSides.notWhileTurningOverReason : "Add the pages after the pages in the queue")
                Button(PackageText.openAsNew) { openAsNew() }
                    .help(state.isTurningOverByHand ? DocumentSides.notWhileTurningOverReason : "Clear the queue and open the document's pages in it")
            }
            .disabled(!state.canIngest)
            Button {
                state.dismissPendingPackage()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Close without adding the pages")
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .alert(replaceTitle, isPresented: $asksReplace) {
            Button(discardLabel, role: .destructive) { state.openPendingPackageAsNew() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(replaceLine)
        }
    }

    private func openAsNew() {
        // Where the settings collect no pages the click only says why, and the queue stays.
        if state.canTakePhonePages && !state.scannedPages.isEmpty {
            asksReplace = true
        } else {
            state.openPendingPackageAsNew()
        }
    }
}
#endif
