import HarkCore
import SwiftUI

/// One row per tier, plus the decode language. The row is the whole model manager: what it costs, what state it
/// is in, and the one button that state allows.
struct ModelSettingsView: View {
    let models: ModelsModel
    @Binding var vocabulary: [String]
    @State private var confirmingPurge = false

    var body: some View {
        Form {
            Section {
                ForEach(models.catalog, id: \.tier) { entry in
                    ModelRow(
                        entry: entry,
                        state: models.state(for: entry.tier),
                        isLoaded: models.loadedTier == entry.tier,
                        isWarmingUp: models.isWarmingUp && models.loadedTier == entry.tier,
                        isSelected: models.selectedTier == entry.tier,
                        failedToLoad: models.loadFailure == entry.tier,
                        models: models)
                }
            } header: {
                Text(L("settings.model.section"))
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("settings.model.footer"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if models.hasAnyInstalled {
                        Button(role: .destructive) {
                            confirmingPurge = true
                        } label: {
                            Text(L("settings.model.purge"))
                        }
                        .controlSize(.small)
                    }
                }
            }

            Section {
                Toggle(isOn: Binding(get: { models.useCoreML }, set: { models.useCoreML = $0 })) {
                    Text(L("settings.model.coreML"))
                }
                Text(L("settings.model.coreML.help"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Picker(selection: Binding(get: { models.language }, set: { models.language = $0 })) {
                    Text(L("settings.model.language.auto")).tag(TranscriptionLanguage.auto)
                    Text(L("settings.model.language.english")).tag(TranscriptionLanguage.english)
                    Text(L("settings.model.language.french")).tag(TranscriptionLanguage.french)
                } label: {
                    Text(L("settings.model.language"))
                }
                Text(L("settings.model.language.help"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VocabularySection(vocabulary: $vocabulary)
        }
        .formStyle(.grouped)
        .confirmationDialog(
            Text(L("settings.model.purge.confirm")), isPresented: $confirmingPurge, titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                models.purge()
            } label: {
                Text(L("settings.model.purge.confirmAction"))
            }
            Button(role: .cancel) {
            } label: {
                Text(L("settings.model.purge.keep"))
            }
        } message: {
            Text(L("settings.model.purge.detail"))
        }
    }
}

private struct ModelRow: View {
    let entry: ModelCatalogEntry
    let state: ModelInstallState
    let isLoaded: Bool
    let isWarmingUp: Bool
    let isSelected: Bool
    let failedToLoad: Bool
    let models: ModelsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: entry.displayName)
                if isLoaded {
                    Text(isWarmingUp ? L("settings.model.warmingUp") : L("settings.model.inUse"))
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
                Spacer()
                Text(verbatim: downloadSize.formatted(.byteCount(style: .file)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            HStack(spacing: 8) {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(state.failure == nil ? Color.secondary : Color.red)
                Spacer()
                actions
            }

            if let progress = state.progress, state.isActive {
                ProgressView(value: progress.fraction)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }

    /// What a download of this tier actually fetches, which depends on whether its encoder is wanted.
    private var downloadSize: Int64 {
        models.useCoreML ? entry.downloadByteCount : entry.weights.byteCount
    }

    /// Only the transitions the state actually allows, so there is never a button that does nothing.
    @ViewBuilder private var actions: some View {
        switch state.phase {
        case .notInstalled, .failed:
            Button(L("settings.model.download")) { models.download(entry.tier) }
        case .downloading:
            Button(L("settings.model.pause")) { models.pause(entry.tier) }
            Button(L("settings.model.cancel")) { models.cancel(entry.tier) }
        case .paused, .interrupted:
            Button(L("settings.model.resume")) { models.download(entry.tier) }
            Button(L("settings.model.cancel")) { models.cancel(entry.tier) }
        case .verifying, .extracting, .compilingCoreML:
            ProgressView().controlSize(.small)
        case .installed:
            if !isSelected || failedToLoad {
                Button(L("settings.model.use")) { models.use(entry.tier) }
            }
            Button(L("settings.model.delete"), role: .destructive) { models.delete(entry.tier) }
                .disabled(isLoaded)
        }
    }

    private var status: LocalizedStringResource {
        if failedToLoad { return L("settings.model.state.loadFailed") }
        if let failure = state.failure { return failureText(failure) }
        return switch state.phase {
        case .notInstalled: L("settings.model.state.notInstalled")
        case .downloading: L("settings.model.state.downloading")
        case .paused: L("settings.model.state.paused")
        case .interrupted: L("settings.model.state.interrupted")
        case .verifying: L("settings.model.state.verifying")
        case .extracting: L("settings.model.state.extracting")
        case .compilingCoreML: L("settings.model.state.compilingCoreML")
        case .installed: L("settings.model.state.installed")
        case .failed: L("settings.model.state.failed")
        }
    }

    /// The failure codes a user can act on get their own line; everything else falls back to the code, which is
    /// also what the log carries.
    private func failureText(_ failure: ModelInstallFailure) -> LocalizedStringResource {
        switch failure {
        case .insufficientSpace: L("settings.model.state.noSpace")
        case .checksumMismatch: L("settings.model.state.checksumMismatch")
        case .forbiddenOrigin: L("settings.model.state.forbiddenOrigin")
        default: L("settings.model.state.failed")
        }
    }
}

/// Names and terms whisper should expect. They become its `initial_prompt`, which is a bias and not a constraint.
private struct VocabularySection: View {
    @Binding var vocabulary: [String]
    @State private var draft = ""

    var body: some View {
        Section {
            ForEach(vocabulary, id: \.self) { term in
                HStack {
                    Text(verbatim: term)
                    Spacer()
                    Button {
                        vocabulary.removeAll { $0 == term }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help(Text(L("settings.model.vocabulary.remove")))
                }
            }
            HStack {
                TextField(text: $draft, prompt: Text(L("settings.model.vocabulary.placeholder"))) {
                    Text(L("settings.model.vocabulary.add"))
                }
                .labelsHidden()
                .onSubmit(add)
                Button(action: add) {
                    Text(L("settings.model.vocabulary.add"))
                }
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text(help)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text(L("settings.model.vocabulary"))
        }
    }

    private var help: AttributedString {
        let fitting = Vocabulary.termsInPrompt(vocabulary)
        var text = AttributedString(localized: L("settings.model.vocabulary.help"))
        if fitting < vocabulary.count {
            text += AttributedString(" ")
            text += AttributedString(
                localized: L("settings.model.vocabulary.overBudget \(fitting) \(vocabulary.count)"))
        }
        return text
    }

    private func add() {
        vocabulary.append(draft)
        draft = ""
    }
}
