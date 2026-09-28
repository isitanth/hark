import AppKit
import HarkCore
import KeyboardShortcuts
import ServiceManagement
import SwiftUI

enum SettingsTab: Hashable {
    case general
    case audio
    case model
    case commands
    case log
    case about
}

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        TabView(selection: $model.settingsTab) {
            GeneralSettingsView(model: model)
                .tabItem { tab(L("settings.tab.general"), "gear") }
                .tag(SettingsTab.general)
            AudioSettingsView(model: model)
                .tabItem { tab(L("settings.tab.audio"), "waveform") }
                .tag(SettingsTab.audio)
            ModelSettingsView(
                models: model.models,
                vocabulary: Binding(
                    get: { model.preferences.vocabulary },
                    set: { model.preferences.vocabulary = Vocabulary.sanitized($0) })
            )
            .tabItem { tab(L("settings.tab.model"), "cpu") }
            .tag(SettingsTab.model)
            CommandsSettingsView(model: model)
                .tabItem { tab(L("settings.tab.commands"), "terminal") }
                .tag(SettingsTab.commands)
            LogSettingsView(model: model)
                .tabItem { tab(L("settings.tab.log"), "doc.text") }
                .tag(SettingsTab.log)
            AboutSettingsView()
                .tabItem { tab(L("settings.tab.about"), "info.circle") }
                .tag(SettingsTab.about)
        }
        .frame(width: 520)
        .onAppear { NSApplication.shared.activate() }
        .background(
            WindowReader { window in
                // Hark has no Dock icon, so every click in another app deactivates it. The Settings scene is
                // panel-backed and NSPanel hides itself on deactivation, which made the window vanish the moment
                // you looked at anything else — including while watching a model download. It closes when you
                // close it, and not before.
                window.hidesOnDeactivate = false
            }
        )
    }

    private func tab(_ title: LocalizedStringResource, _ symbol: String) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: symbol)
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
            }
        }
        .formStyle(.grouped)
        .onAppear { launchAtLogin.refresh() }
    }

    private func preference<Value>(_ keyPath: WritableKeyPath<DictationPreferences, Value>) -> Binding<Value> {
        Binding(get: { model.preferences[keyPath: keyPath] }, set: { model.preferences[keyPath: keyPath] = $0 })
    }
}

/// Hands back the `NSWindow` hosting this view, for the handful of things SwiftUI does not expose.
private struct WindowReader: NSViewRepresentable {
    let configure: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    /// The window is nil until the view is in a hierarchy, so this runs on update rather than on creation, and
    /// is written to be safe to run more than once.
    func updateNSView(_ view: NSView, context: Context) {
        guard let window = view.window else { return }
        configure(window)
    }
}
