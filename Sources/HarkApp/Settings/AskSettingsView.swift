import HarkCore
import SwiftUI

/// The server an ask goes to and its key (the user's request of 2026-09-28), and since 2026-10-12 which provider: the
/// local server or Claude, each profile with its own key. The provider and the address are written to commands.yaml
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

    /// The two templates first, then any other profile the file names.
    private var providerNames: [String] {
        let templates = [ProviderProfile.local.name, ProviderProfile.claude.name]
        let others = Set(model.config.config.effectiveLLM.profiles.keys).subtracting(templates)
        return templates + others.sorted()
    }

    private var provider: Binding<String> {
        Binding(get: { profile?.name ?? ProviderProfile.local.name }, set: selectProvider)
    }

    var body: some View {
        Form {
            Section {
                Picker(selection: provider) {
                    ForEach(providerNames, id: \.self) { name in
                        providerLabel(name).tag(name)
                    }
                } label: {
                    Text(L("settings.ask.provider"))
                }
                .disabled(busy)
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
                Text(helpText)
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
        .frame(height: 500)
        .onAppear {
            address = savedAddress
            guard let profile else { return }
            Task {
                let result = await model.ask.checkOnOpen(profile)
                // Picked another provider meanwhile: this check was about the one before.
                guard self.profile?.name == profile.name else { return }
                switch result {
                case .connected(let id)?: status = .connected(id)
                case .failed(let failure)?: status = .failed(failure)
                case nil: break
                }
            }
        }
        .onChange(of: savedAddress) { _, saved in address = saved }
        // A key typed for one provider and not saved never goes to the other one.
        .onChange(of: profile?.name) {
            status = nil
            key = ""
        }
    }

    @ViewBuilder private func providerLabel(_ name: String) -> some View {
        switch name {
        case ProviderProfile.local.name: Text(L("settings.ask.provider.local"))
        case ProviderProfile.claude.name: Text(L("settings.ask.provider.claude"))
        default: Text(verbatim: name)
        }
    }

    /// Where the selection goes, and that it leaves this Mac when it does.
    private var helpText: LocalizedStringResource {
        guard let host = profile?.remoteHost else { return L("settings.ask.help") }
        return L("settings.ask.help.remote \(host)")
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

    private func selectProvider(_ name: String) {
        guard !busy, name != profile?.name else { return }
        run {
            if let problem = await model.saveProvider(name) { status = .address(problem) }
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
