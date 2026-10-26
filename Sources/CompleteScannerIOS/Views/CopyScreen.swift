#if os(iOS)
import CompleteScannerKit
import CoreGraphics
import SwiftUI
import UIKit

/// The photocopy's screen, full screen once its pages are in (`AppState.copyPages`, I16): the first page
/// large, with how many there are when several, then Copies, Fit to page (on and fixed, with why, when a
/// page has no known size), Also save a PDF, the printer the copy goes to and the status while it prints;
/// Print shows AirPrint's printer picker, Copy again prints on the printer picked last without it, and
/// Discard lets the pages go and closes the screen (Close, for the queue's pages printed from Save's menu,
/// which stay in the queue). It stays open after printing, for another copy. It
/// shows the error alert itself, since the root's cannot show over it.
struct CopyScreen: View {
    @ObservedObject var model: IOSCopyModel
    @EnvironmentObject private var state: AppState

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ZStack {
                    Color(uiColor: .secondarySystemBackground)
                    if let image = model.image {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .scaledToFit()
                            .padding(12)
                            .accessibilityLabel(Text(IOSCopyText.pageName))
                            .accessibilityIdentifier("copy.image")
                    }
                }
                Divider()
                footer
            }
            .navigationTitle(IOSCopyText.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if state.copyIsOfQueue {
                        Button(IOSCopyText.closeLabel) {
                            model.discard()
                        }
                        .disabled(!model.canAct)
                        .accessibilityIdentifier("copy.discard")
                    } else {
                        Button(IOSCopyText.discardLabel, role: .destructive) {
                            model.discard()
                        }
                        .disabled(!model.canAct)
                        .accessibilityHint(Text(IOSCopyText.discardHint))
                        .accessibilityIdentifier("copy.discard")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    if state.isBusy {
                        ProgressView()
                    }
                }
            }
        }
        .modifier(ErrorAlert(state: state))
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let pages = model.pageCountLine {
                Text(pages)
                    .font(.footnote)
                    .foregroundStyle(Color.secondary)
                    .accessibilityIdentifier("copy.pages")
            }
            Stepper(value: copies, in: 1...PrintCopies.maxCount) {
                Text(IOSCopyText.copiesTitle(model.copies))
            }
            .disabled(state.isBusy)
            .accessibilityIdentifier("copy.copies")
            Toggle(IOSCopyText.fitLabel, isOn: fit)
                .disabled(model.fitIsForced || state.isBusy)
                .accessibilityHint(Text(IOSCopyText.fitHint))
                .accessibilityIdentifier("copy.fit")
            if model.fitIsForced {
                Label(PrintText.realSizeUnavailable, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("copy.fitReason")
            }
            // The queue's pages are saved by its own Save (After saving's Print saves them once this closes).
            if !state.copyIsOfQueue {
                Toggle(IOSCopyText.pdfLabel, isOn: alsoPDF)
                    .disabled(state.isBusy)
                    .accessibilityHint(Text(IOSCopyText.pdfHint))
                    .accessibilityIdentifier("copy.pdf")
            }
            Label(model.printerLine, systemImage: "printer")
                .font(.footnote)
                .foregroundStyle(Color.secondary)
                .accessibilityIdentifier("copy.printer")
            Text(state.statusMessage)
                .font(.footnote)
                .foregroundStyle(Color.secondary)
                .lineLimit(2)
                .accessibilityIdentifier("copy.status")
            HStack(spacing: 12) {
                if let printer = model.printerName {
                    Button {
                        model.printAgain()
                    } label: {
                        Label(IOSCopyText.againLabel, systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!model.canAct)
                    .accessibilityHint(Text(IOSCopyText.againHint(printer)))
                    .accessibilityIdentifier("copy.again")
                }
                Button {
                    model.print()
                } label: {
                    Label(IOSCopyText.printLabel, systemImage: "printer")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canAct)
                .accessibilityHint(Text(IOSCopyText.printHint))
                .accessibilityIdentifier("copy.print")
            }
        }
        .padding(16)
    }

    private var copies: Binding<Int> {
        let copyModel: IOSCopyModel = model
        return Binding<Int>(get: { copyModel.copies },
                            set: { (count: Int) in copyModel.setCopies(count) })
    }

    private var fit: Binding<Bool> {
        let copyModel: IOSCopyModel = model
        return Binding<Bool>(get: { copyModel.fitsToPage },
                             set: { (on: Bool) in copyModel.setFitsToPage(on) })
    }

    private var alsoPDF: Binding<Bool> {
        let copyModel: IOSCopyModel = model
        return Binding<Bool>(get: { copyModel.alsoSavesPDF },
                             set: { (on: Bool) in copyModel.setAlsoSavesPDF(on) })
    }
}
#endif
