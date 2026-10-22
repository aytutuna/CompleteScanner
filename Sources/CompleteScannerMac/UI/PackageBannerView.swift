#if os(macOS)
import CompleteScannerKit
import SwiftUI

/// The banner under the tab bar while a `.csdoc` opened by hand is offered (`AppState.pendingPackage`):
/// "Opened Receipt.csdoc: 3 pages", Add to pages, Open as new and a close button that drops the offer.
/// The two buttons wait while something runs or a review is open. Twin of the Windows package banner.
struct PackageBannerView: View {
    @EnvironmentObject var state: AppState

    let package: PendingPackage

    var body: some View {
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
                    .help("Add the pages after the pages in the queue")
                Button(PackageText.openAsNew) { state.openPendingPackageAsNew() }
                    .help("Clear the queue and open the document's pages in it")
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
    }
}
#endif
