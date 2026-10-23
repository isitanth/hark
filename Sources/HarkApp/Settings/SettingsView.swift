import AppKit
import HarkCore
import KeyboardShortcuts
import ServiceManagement
import SwiftUI

enum SettingsTab: Hashable, CaseIterable {
    case general
    case audio
    case model
    case commands
    case ask
    case log
    case about

    var title: LocalizedStringResource {
        switch self {
        case .general: L("settings.tab.general")
        case .audio: L("settings.tab.audio")
        case .model: L("settings.tab.model")
        case .commands: L("settings.tab.commands")
        case .ask: L("settings.tab.ask")
        case .log: L("settings.tab.log")
        case .about: L("settings.tab.about")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gear"
        case .audio: "waveform"
        case .model: "cpu"
        case .commands: "terminal"
        case .ask: "text.bubble"
        case .log: "doc.text"
        case .about: "info.circle"
        }
    }
}

/// The Settings window: the panes in a sidebar, the one on show filling the rest, and its name as the window's title.
/// The selection is the model's, so the panel and the Ask panel can open Settings on the pane that fixes a problem.
struct SettingsView: View {
    static let windowID = "settings"

    @Bindable var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(SettingsTab.allCases, id: \.self, selection: selection) { tab in
                Label {
                    Text(tab.title)
                } icon: {
                    Image(systemName: tab.symbol)
                }
            }
            // Fixed, so the window's minimum width always leaves the pane the same room.
            .navigationSplitViewColumnWidth(200)
        } detail: {
            pane
                .navigationTitle(Text(model.settingsTab.title))
        }
        .frame(minWidth: Self.minimumSize.width, minHeight: Self.minimumSize.height)
        .onAppear { NSApplication.shared.activate() }
    }

    /// Below the toolbar, which adds 52 pt to the window. The pane gets 600 pt, the width every pane was laid out for
    /// in the toolbar-tab window. The height is French Commands', the longest pane that is not a scrolling form, with
    /// its table at its minimum: 481 pt measured at that width with a Test's answer, 570 with a broken commands.yaml's
    /// notice as well. The window's minimum does not follow the pane on show (measured), so this one is set for the
    /// common case, and Commands scrolls when a longer error or longer lists in the file outgrow it.
    static let minimumSize = CGSize(width: 800, height: 580)

    /// Never empty: a click that would leave no pane selected keeps the one on show.
    private var selection: Binding<SettingsTab?> {
        Binding(get: { model.settingsTab }, set: { if let tab = $0 { model.settingsTab = tab } })
    }

    @ViewBuilder private var pane: some View {
        switch model.settingsTab {
        case .general:
            GeneralSettingsView(model: model)
        case .audio:
            AudioSettingsView(model: model)
        case .model:
            ModelSettingsView(
                models: model.models,
                vocabulary: Binding(
                    get: { model.preferences.vocabulary },
                    set: { model.preferences.vocabulary = Vocabulary.sanitized($0) }))
        case .commands:
            CommandsSettingsView(model: model)
        case .ask:
            AskSettingsView(model: model)
        case .log:
            LogSettingsView(model: model)
        case .about:
            AboutSettingsView()
        }
    }
}

struct GeneralSettingsView: View {
    let model: AppModel
    @State private var launchAtLogin = LaunchAtLogin()
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    KeyboardShortcuts.Recorder(for: .pushToTalk)
                } label: {
                    Text(L("settings.general.trigger"))
                }
                LabeledContent {
                    KeyboardShortcuts.Recorder(for: .cancelUtterance)
                } label: {
                    Text(L("settings.general.cancelTrigger"))
                }
                Text(L("settings.general.triggerHelp"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                LabeledContent {
                    KeyboardShortcuts.Recorder(for: .ask)
                } label: {
                    Text(L("settings.general.askTrigger"))
                }
                Text(L("settings.general.askHelp"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Picker(selection: preference(\.insertionMode)) {
                    Text(L("settings.general.insertion.accessibility")).tag(InsertionMode.accessibility)
                    Text(L("settings.general.insertion.paste")).tag(InsertionMode.paste)
                    Text(L("settings.general.insertion.clipboard")).tag(InsertionMode.clipboard)
                } label: {
                    Text(L("settings.general.insertion"))
                }
                LabeledContent {
                    Button {
                        model.revealCommandsFile()
                    } label: {
                        Text(L("settings.general.perApp.reveal"))
                    }
                } label: {
                    let count = model.config.config.apps.count
                    Text(L("settings.general.perApp \(count)"))
                }
                Toggle(isOn: preference(\.clipboardFallback)) {
                    Text(L("settings.general.clipboardFallback"))
                }
                Toggle(isOn: preference(\.partialTranscript)) {
                    Text(L("settings.general.partialTranscript"))
                }
                Text(
                    model.models.state(for: .small).phase == .installed
                        ? L("settings.general.partialTranscript.help")
                        : L("settings.general.partialTranscript.needsSmall")
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                Toggle(isOn: preference(\.lowerOtherAudio)) {
                    Text(L("settings.general.lowerOtherAudio"))
                }
                Text(L("settings.general.lowerOtherAudio.help"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Picker(selection: preference(\.notificationStyle)) {
                    Text(L("settings.general.notifications.standard")).tag(NotificationStyle.standard)
                    Text(L("settings.general.notifications.silent")).tag(NotificationStyle.silent)
                    Text(L("settings.general.notifications.off")).tag(NotificationStyle.off)
                } label: {
                    Text(L("settings.general.notifications"))
                }
                Text(L("settings.general.dictation.help"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text(L("settings.general.dictation"))
            }

            Section {
                LabeledContent {
                    Button {
                        openWindow(id: OnboardingView.windowID)
                        NSApplication.shared.activate()
                    } label: {
                        Text(L("settings.general.permissions.review"))
                    }
                } label: {
                    Text(L("settings.general.permissions"))
                }
            }

            Section {
                Picker(selection: Binding(get: { model.displayLanguage }, set: { model.displayLanguage = $0 })) {
                    Text(L("settings.general.language.system")).tag(DisplayLanguage.system)
                    // Each language in its own name, so it can be found whatever language is on show.
                    Text(verbatim: "English").tag(DisplayLanguage.english)
                    Text(verbatim: "Français").tag(DisplayLanguage.french)
                } label: {
                    Text(L("settings.general.language"))
                }
                Text(L("settings.general.language.help"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if model.displayLanguage != model.launchDisplayLanguage {
                    LabeledContent {
                        Button {
                            AppRelauncher.relaunch()
                        } label: {
                            Text(L("settings.general.language.restart"))
                        }
                    } label: {
                        Text(L("settings.general.language.restartNeeded"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Section {
                Toggle(isOn: Binding(get: { launchAtLogin.isOn }, set: { launchAtLogin.set($0) })) {
                    Text(L("settings.general.launchAtLogin"))
                }
                if launchAtLogin.status == .requiresApproval {
                    LabeledContent {
                        Button {
                            SMAppService.openSystemSettingsLoginItems()
                        } label: {
                            Text(L("settings.general.openLoginItems"))
                        }
                    } label: {
                        Text(L("settings.general.requiresApproval"))
                    }
                }
                if let failure = launchAtLogin.failure {
                    LabeledContent {
                        Text(verbatim: failure)
                            .foregroundStyle(.secondary)
                    } label: {
                        Label {
                            Text(L("settings.general.launchAtLoginFailed"))
                        } icon: {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                    }
                }
                Toggle(isOn: Binding(get: { model.showsInDock }, set: { model.showsInDock = $0 })) {
                    Text(L("settings.general.showInDock"))
                }
                Text(L("settings.general.showInDock.help"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .onAppear { launchAtLogin.refresh() }
    }

    private func preference<Value>(_ keyPath: WritableKeyPath<DictationPreferences, Value>) -> Binding<Value> {
        Binding(get: { model.preferences[keyPath: keyPath] }, set: { model.preferences[keyPath: keyPath] = $0 })
    }
}
