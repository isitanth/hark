import AppKit
import HarkCore
import KeyboardShortcuts
import ServiceManagement
import SwiftUI
import os

enum SettingsTab: Hashable {
    case general
    case audio
    case model
    case commands
    case ask
    case log
    case about
}

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var toolbarTabs = EqualToolbarTabs()

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
            AskSettingsView(model: model)
                .tabItem { tab(L("settings.tab.ask"), "text.bubble") }
                .tag(SettingsTab.ask)
            LogSettingsView(model: model)
                .tabItem { tab(L("settings.tab.log"), "doc.text") }
                .tag(SettingsTab.log)
            AboutSettingsView()
                .tabItem { tab(L("settings.tab.about"), "info.circle") }
                .tag(SettingsTab.about)
        }
        // Seven tabs at the width of the longest label, Commandes in French, fit with even margins from 600 pt; at
        // 560 the last one went into the toolbar's overflow menu.
        .frame(width: 600)
        .onAppear { NSApplication.shared.activate() }
        .background(
            WindowReader { [toolbarTabs] window in
                // Hark has no Dock icon, so every click in another app deactivates it. The Settings scene is
                // panel-backed and NSPanel hides itself on deactivation, which made the window vanish the moment
                // you looked at anything else — including while watching a model download. It closes when you
                // close it, and not before.
                window.hidesOnDeactivate = false
                toolbarTabs.attach(to: window)
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
            }
        }
        .formStyle(.grouped)
        .onAppear { launchAtLogin.refresh() }
    }

    private func preference<Value>(_ keyPath: WritableKeyPath<DictationPreferences, Value>) -> Binding<Value> {
        Binding(get: { model.preferences[keyPath: keyPath] }, set: { model.preferences[keyPath: keyPath] = $0 })
    }
}

/// Gives every tab of the Settings toolbar the width of the longest label, so the selection and the pointer's
/// highlight are the same size on every tab instead of following each label.
///
/// `possibleLabels` is how AppKit sizes a toolbar item for the longest text it may show. Each item gets every item's
/// label, read from the toolbar, so it holds in any display language. SwiftUI fills the toolbar on its own schedule,
/// so this runs again when an item is added, when the window becomes key and when it resizes, always on a later turn
/// of the main actor, and changes nothing once the labels are in place. Should the equal tabs not fit, the toolbar
/// would hide the last ones behind a "»" menu: they go back to their own widths instead, for as long as the window
/// keeps that width. A restored frame narrower than the content can be measured once before SwiftUI widens it.
private final class EqualToolbarTabs: NSObject {
    private static let logger = Logger(subsystem: "com.anthonychambet.hark", category: "settings")
    private weak var window: NSWindow?
    private var scheduled = false
    private var overflowedWidth: CGFloat?

    func attach(to window: NSWindow) {
        if window !== self.window {
            let center = NotificationCenter.default
            center.removeObserver(self)
            self.window = window
            // Any toolbar: SwiftUI may fill this one before the window holds it. A stranger's item costs a no-op.
            center.addObserver(
                self, selector: #selector(toolbarMayHaveChanged), name: NSToolbar.willAddItemNotification, object: nil)
            center.addObserver(
                self, selector: #selector(toolbarMayHaveChanged), name: NSWindow.didBecomeKeyNotification,
                object: window)
            center.addObserver(
                self, selector: #selector(toolbarMayHaveChanged), name: NSWindow.didResizeNotification, object: window)
        }
        schedule()
    }

    @objc private func toolbarMayHaveChanged(_ notification: Notification) {
        schedule()
    }

    /// The item announced by `willAddItem` is in the toolbar by the next turn; any number of requests until then
    /// come to one pass.
    private func schedule() {
        guard !scheduled else { return }
        scheduled = true
        Task { [weak self] in self?.apply() }
    }

    private func apply() {
        scheduled = false
        guard let window, let toolbar = window.toolbar else { return }
        let items = toolbar.items
        // SwiftUI may add an item before naming it; a later pass finds it named.
        guard !items.isEmpty, !items.contains(where: { $0.label.isEmpty }) else { return }
        let width = window.frame.width
        let overflowed = overflowedWidth == width
        let labels: Set<String> = overflowed ? [] : Set(items.map(\.label))
        for item in items where item.possibleLabels != labels {
            item.possibleLabels = labels
        }
        guard !overflowed, window.isVisible else { return }
        window.layoutIfNeeded()
        // A toolbar not laid out yet shows no item at all, which is not an overflow; becoming key asks again.
        guard let shown = toolbar.visibleItems?.count, shown > 0, shown < items.count else { return }
        overflowedWidth = width
        for item in items {
            item.possibleLabels = []
        }
        Self.logger.notice(
            "the Settings tabs do not fit in \(Int(width)) pt (\(shown) of \(items.count) shown); own widths again")
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
