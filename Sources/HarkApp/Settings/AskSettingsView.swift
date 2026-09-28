import HarkCore
import SwiftUI

/// The server an ask goes to and its key (the user's request of 2026-09-28). The address is written to commands.yaml
/// like every setting; the key goes to the Keychain and is never shown again. Test connection checks what is typed,
/// once commands.yaml would take it, before anything is saved.
struct AskSettingsView: View {
    let model: AppModel
    @State private var address = ""
    @State private var key = ""
    @State private var busy = false
    /// What the last Save, Remove or Test here came to.
    @State private var status: Status?

    private enum Status: Equatable {
        case connected(String)
        case failed(LLMFailure)
        case address(AppModel.ServerAddressProblem)
        case keychain(Int32)
    }

    /// The profile an ask uses now: the last good commands.yaml's, or the standard one.
    private var profile: ProviderProfile? {
        model.config.config.effectiveLLM.activeProfile
    }

    private var savedAddress: String {
        profile?.baseURL.absoluteString ?? ""
    }

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    HStack {
                        TextField(text: $address, prompt: Text(verbatim: ProviderProfile.local.baseURL.absoluteString))
                        {
                            Text(L("settings.ask.server"))
                        }
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 160)
                        .onSubmit(saveAddress)
                        Button(action: saveAddress) {
                            Text(L("settings.ask.save"))
                        }
                        .fixedSize()
                        .disabled(busy || address.isEmpty || address == savedAddress)
                    }
                } label: {
                    Text(L("settings.ask.server"))
                }
                LabeledContent {
                    HStack {
                        SecureField(text: $key, prompt: Text(keyPrompt)) {
                            Text(L("settings.ask.key"))
                        }
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 120)
                        .onSubmit(saveKey)
                        // Buttons at their own width: in French, Enregistrer was cut to "Enregist…".
                        Button(action: saveKey) {
                            Text(L("settings.ask.save"))
                        }
                        .fixedSize()
                        .disabled(busy || key.isEmpty)
                        if model.ask.hasKey == true {
                            Button(action: removeKey) {
                                Text(L("settings.ask.key.remove"))
                            }
                            .fixedSize()
                            .disabled(busy)
                        }
                    }
                } label: {
                    Text(L("settings.ask.key"))
                }
                Text(L("settings.ask.key.help"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text(L("settings.ask.section.server"))
            }

            Section {
                LabeledContent {
                    Text(verbatim: model.ask.model ?? "–")
                        .textSelection(.enabled)
                        .foregroundStyle(model.ask.model == nil ? .secondary : .primary)
                } label: {
                    Text(L("settings.ask.model"))
                }
                LabeledContent {
                    HStack(spacing: 8) {
                        if busy { ProgressView().controlSize(.small) }
                        Button(action: test) {
                            Text(L("settings.ask.test"))
                        }
                        .disabled(busy)
                    }
                } label: {
                    statusView
                }
                Text(L("settings.ask.help"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text(L("settings.ask.section.connection"))
            }
        }
        .formStyle(.grouped)
        // Tall enough for the longest state, a French warning of three lines, so the form never scrolls its first
        // section out of sight.
        .frame(height: 470)
        .onAppear {
            address = savedAddress
            guard let profile else { return }
            Task {
                switch await model.ask.checkOnOpen(profile) {
                case .connected(let id)?: status = .connected(id)
                case .failed(let failure)?: status = .failed(failure)
                case nil: break
                }
            }
        }
        .onChange(of: savedAddress) { _, saved in address = saved }
    }

    private var keyPrompt: LocalizedStringResource {
        switch model.ask.hasKey {
        case true?: L("settings.ask.key.saved")
        case false?: L("settings.ask.key.none")
        case nil: L("settings.ask.key.unknown")
        }
    }

    /// What the last action here came to; before any, what the last ask or test left behind.
    @ViewBuilder private var statusView: some View {
        switch status {
        case .connected(let id)?:
            Label {
                Text(L("settings.ask.connected \(id)"))
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
        case .failed(let failure)?:
            warning(failure.settingsText)
        case .address(.notAnAddress)?:
            warning(L("settings.ask.invalidAddress"))
        case .address(.write(.invalid(let error)))?:
            warning(Self.addressText(error))
        case .address(.write(let error))?:
            warning(error.text)
        case .keychain(let code)?:
            let code = Int(code)
            warning(L("settings.ask.key.saveFailed \(code)"))
        case nil:
            if let failure = model.ask.lastFailure {
                warning(failure.settingsText)
            } else {
                Text(verbatim: "")
            }
        }
    }

    /// The address problems in the tab's own words, without the path in commands.yaml; anything else as the file
    /// would report it.
    private static func addressText(_ error: ConfigError) -> LocalizedStringResource {
        switch error.problem {
        case .insecureURL: L("settings.ask.insecureAddress")
        case .invalidURL: L("settings.ask.invalidAddress")
        case .keyInFile: L("settings.ask.credentialsInAddress")
        default: ConfigWriteError.invalid(error).text
        }
    }

    /// Verbatim once localized: a message can quote an address, and Markdown would turn it into a link.
    private func warning(_ text: LocalizedStringResource) -> some View {
        Label {
            Text(verbatim: String(localized: text))
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    private func saveAddress() {
        guard !busy, !address.isEmpty, address != savedAddress else { return }
        run {
            if let problem = await model.saveServerAddress(address) { status = .address(problem) }
        }
    }

    private func saveKey() {
        guard !busy, !key.isEmpty, let profile else { return }
        run {
            if let code = await model.ask.saveKey(key, for: profile) {
                status = .keychain(code)
            } else {
                key = ""
            }
        }
    }

    private func removeKey() {
        guard !busy, let profile else { return }
        run {
            if let code = await model.ask.removeKey(for: profile) { status = .keychain(code) }
        }
    }

    /// What is typed, if commands.yaml would take it; the saved address otherwise.
    private func test() {
        guard !busy else { return }
        let typed = address.isEmpty ? savedAddress : address
        run {
            switch model.profile(forServerAddress: typed) {
            case .failure(let problem):
                status = .address(problem)
            case .success(let profile):
                switch await model.ask.test(profile) {
                case .connected(let id): status = .connected(id)
                case .failed(let failure): status = .failed(failure)
                }
            }
        }
    }

    private func run(_ work: @escaping () async -> Void) {
        busy = true
        status = nil
        Task {
            await work()
            busy = false
        }
    }
}
