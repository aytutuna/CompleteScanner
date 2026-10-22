#if os(iOS)
import CompleteScannerKit
import SwiftUI
import UIKit

/// My computer, pushed from Settings (`IOSCompanionModel`): with no computer paired, Pair with a computer
/// (the camera looking for its code, the code's text to enter instead, the check code to compare, the
/// name the computer will list the phone under, Pair); once paired, the computer's name and state
/// (checked when the screen opens, and on Refresh), Unpair, and the documents waiting to be sent with
/// Send again and Remove. A computer that no longer knows the phone is shown with pairing offered again.
/// Local Network access that is off is said with Open Settings.
struct CompanionScreen: View {
    @EnvironmentObject private var state: AppState
    @StateObject private var model: IOSCompanionModel

    init(state: AppState, browser: IOSCompanionBrowser?) {
        _model = StateObject(wrappedValue: IOSCompanionModel(state: state, browser: browser))
    }

    var body: some View {
        Form {
            if let desktop = state.companionDesktop {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(desktop.name)
                            .font(.headline)
                            .accessibilityIdentifier("companion.name")
                        Text(IOSCompanionText.status(state.companionStatus))
                            .font(.subheadline)
                            .foregroundStyle(Color.secondary)
                            .accessibilityIdentifier("companion.status")
                    }
                    .accessibilityElement(children: .combine)
                    if !model.needsPairing {
                        Button {
                            Task { await model.refresh() }
                        } label: {
                            Label(IOSCompanionText.refreshButton, systemImage: "arrow.clockwise")
                        }
                        .disabled(state.companionStatus == .checking)
                        .accessibilityIdentifier("companion.refresh")
                    }
                    Button(role: .destructive) {
                        Task { await model.unpair() }
                    } label: {
                        Label(IOSCompanionText.unpairButton, systemImage: "xmark.circle")
                    }
                    .disabled(model.isPairing)
                    .accessibilityIdentifier("companion.unpair")
                }
            }
            if model.needsPairing {
                pairSection
            }
            if state.companionDesktop != nil || state.companionOutboxCount > 0 {
                Section {
                    Text(IOSCompanionText.waiting(state.companionOutboxCount))
                        .accessibilityIdentifier("companion.outbox")
                    if state.companionOutboxCount > 0 {
                        Button(IOSCompanionText.sendAgainButton) {
                            Task { await model.sendAgain() }
                        }
                        .disabled(model.needsPairing)
                        .accessibilityIdentifier("companion.sendAgain")
                        Button(IOSCompanionText.removeButton, role: .destructive) {
                            model.removeWaiting()
                        }
                        .accessibilityIdentifier("companion.remove")
                    }
                }
            }
            if let browser = model.browser {
                CompanionNetworkLine(browser: browser)
            }
        }
        .navigationTitle(IOSCompanionText.title)
        .onAppear {
            model.appear()
        }
        .onDisappear {
            model.disappear()
        }
    }

    private var pairSection: some View {
        Section {
            if model.code == nil {
                PairingScannerView(onCode: { (value: String) in
                    model.scanned(value)
                })
            }
            TextField(IOSCompanionText.textPlaceholder, text: $model.text, axis: .vertical)
                .lineLimit(1...4)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .disabled(model.isPairing)
                .accessibilityLabel(Text(IOSCompanionText.textLabel))
                .accessibilityIdentifier("companion.text")
            if let problem = model.problem {
                Text(problem)
                    .font(.footnote)
                    .foregroundStyle(Color.red)
                    .accessibilityIdentifier("companion.problem")
            }
            if let check = model.checkCode {
                VStack(alignment: .leading, spacing: 4) {
                    Text(check)
                        .font(.title2.monospacedDigit())
                        .accessibilityIdentifier("companion.checkCode")
                    Text(IOSCompanionText.compareLine)
                        .font(.footnote)
                        .foregroundStyle(Color.secondary)
                }
                .accessibilityElement(children: .combine)
                TextField(IOSCompanionText.phoneNameLabel, text: $model.phoneName)
                    .textInputAutocapitalization(.words)
                    .disabled(model.isPairing)
                    .accessibilityLabel(Text(IOSCompanionText.phoneNameLabel))
                    .accessibilityIdentifier("companion.phoneName")
            }
            if model.isPairing {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(IOSCompanionText.waitingLine)
                        .font(.footnote)
                }
                .accessibilityElement(children: .combine)
            }
            Button {
                Task { await model.pair() }
            } label: {
                Text(IOSCompanionText.pairButton)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canPair)
            .accessibilityIdentifier("companion.pair")
        } header: {
            Text(IOSCompanionText.pairTitle)
        } footer: {
            Text(IOSCompanionText.pairLine)
        }
    }
}

/// Local Network access is off: the one line, with Open Settings (the scanner picker's words).
private struct CompanionNetworkLine: View {
    @ObservedObject var browser: IOSCompanionBrowser

    var body: some View {
        if browser.accessDenied {
            Section {
                Text(IOSNetworkText.deniedLine)
                    .accessibilityIdentifier("companion.denied")
                Button(IOSNetworkText.settingsButton) {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url, options: [:], completionHandler: nil)
                }
                .accessibilityIdentifier("companion.settings")
            }
        }
    }
}
#endif
