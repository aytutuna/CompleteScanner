#if os(iOS)
import LazyScanKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// My computer, pushed from Settings (`IOSCompanionModel`): with no computer paired, Pair with a computer
/// (the camera looking for its code, the code's text to enter instead, the check code to compare, the
/// name the computer will list the phone under, Pair); once paired, the computer's name and state
/// (checked when the screen opens, and on Refresh), Unpair, and the documents waiting to be sent with
/// Send again and Remove, and those in the cloud folder the computer has not taken yet. For a computer that
/// handed out a sync key, the cloud folder (Choose…, Clear) documents go to when it cannot be reached. A
/// computer that no longer knows the phone is shown with pairing offered again. Local Network access that
/// is off is said with Open Settings. Documents left for a computer no longer paired have a line and a Remove
/// of their own.
struct CompanionScreen: View {
    @EnvironmentObject private var state: AppState
    @StateObject private var model: IOSCompanionModel
    @State private var choosingFolder: Bool = false

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
                    if model.inCloudFolder > 0 {
                        Text(IOSCompanionText.inCloudFolder(model.inCloudFolder))
                            .accessibilityIdentifier("companion.inCloudFolder")
                    }
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
            if state.companionOtherOutboxCount > 0 {
                otherOutboxSection
            }
            if model.offersCloudFolder && !model.needsPairing {
                cloudFolderSection
            }
            if let browser = model.browser {
                CompanionNetworkLine(browser: browser)
            }
        }
        .navigationTitle(IOSCompanionText.title)
        .onAppear {
            model.appear()
        }
        .onChange(of: state.companionOutboxCount) { (_: Int, _: Int) in
            model.lookAtCloudFolder()
        }
        .onDisappear {
            model.disappear()
        }
    }

    private var otherOutboxSection: some View {
        Section {
            Text(IOSCompanionText.forUnpairedComputer(state.companionOtherOutboxCount))
                .accessibilityIdentifier("companion.otherOutbox")
            Button(IOSCompanionText.removeButton, role: .destructive) {
                model.removeOtherWaiting()
            }
            .accessibilityIdentifier("companion.otherOutbox.remove")
        }
    }

    private var cloudFolderSection: some View {
        Section {
            LabeledContent(IOSCompanionText.cloudFolderLabel) {
                Text(model.cloudFolderValue)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .accessibilityIdentifier("companion.cloudFolder")
            HStack {
                Button(IOSCompanionText.chooseFolderButton) {
                    choosingFolder = true
                }
                .accessibilityIdentifier("companion.cloudFolder.choose")
                if state.companionDesktop?.syncFolderBookmark != nil {
                    Spacer()
                    Button(IOSCompanionText.clearButton) {
                        model.clearCloudFolder()
                    }
                    .accessibilityIdentifier("companion.cloudFolder.clear")
                }
            }
            .buttonStyle(.borderless)
            .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [UTType.folder]) { (result: Result<URL, Error>) in
                switch result {
                case .success(let url):
                    model.chooseCloudFolder(url)
                case .failure(let error):
                    state.errorMessage = error.localizedDescription
                }
            }
        } footer: {
            Text(CompanionText.syncFolderLine)
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
