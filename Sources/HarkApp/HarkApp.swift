import HarkCore
import SwiftUI
import os

@main
enum HarkMain {
    static func main() {
        if CommandLine.arguments.contains(SelfTest.flag) {
            SelfTest.run()
        }
        HarkApp.main()
    }
}

struct HarkApp: App {
    @NSApplicationDelegateAdaptor(HarkAppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            PanelView(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Window(Text(L("onboarding.window")), id: OnboardingView.windowID) {
            OnboardingView(model: model)
        }
        .windowResizability(.contentSize)

        // Opened only by `-HarkDebugPreview panel`.
        Window(Text(verbatim: "Hark panel preview"), id: PanelView.previewWindowID) {
            PanelView(model: model)
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsView(model: model)
        }
    }
}

/// Quitting shuts the transcription engine down first. `exit()` runs ggml's static destructors, and its Metal device
/// aborts while a whisper context still holds buffers: until 2026-09-23 every quit, from the panel or by AppleScript,
/// ended in a crash report.
///
/// Before that, the pipeline ends the utterance in flight: one capturing, transcribing or resolving is cancelled and
/// writes its line; one inserting, copying or acting is waited on and writes its own outcome. The shutdown cancels a
/// decode, but whisper only checks between graph computes, and a first Core ML load cannot be interrupted at all.
/// Past the deadline the process leaves with `_exit`, which skips the destructors that abort. What Hark has written is
/// on disk or with cfprefsd by then; only an utterance still in flight at the deadline, an app still opening, goes
/// without its line. The lifecycle log says which step held the quit: "the pipeline is idle" is written between them.
final class HarkAppDelegate: NSObject, NSApplicationDelegate {
    /// Set by `AppModel`: what has to finish before the process exits.
    static var beforeQuit: (@Sendable () async -> Void)?
    /// Set by `AppModel`: the Services menu's Ask Hark. A service call can be what launched Hark, so the provider is
    /// in place before the launch finishes.
    static var servicesProvider: AskService?
    private static let deadline = Duration.seconds(3)
    private static var isQuitting = false
    private static let logger = Logger(subsystem: "com.anthonychambet.hark", category: "lifecycle")

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = Self.servicesProvider
        NSUpdateDynamicServices()
        Self.logger.notice("services provider in place: \(Self.servicesProvider != nil, privacy: .public)")
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // A second request — Cmd-Q after Quit, a logout's quit event — waits for the reply already on its way.
        guard !Self.isQuitting else { return .terminateLater }
        guard let beforeQuit = Self.beforeQuit else { return .terminateNow }
        Self.isQuitting = true
        Task {
            guard await Deadline.first(of: beforeQuit, within: Self.deadline) != nil else {
                Self.logger.error("the quit did not finish within the deadline; leaving without exit()")
                _exit(0)
            }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

/// The status item. It is the one view that exists from launch, so it is what opens the onboarding window.
private struct MenuBarLabel: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Image(nsImage: MenuBarIconRenderer.image(for: model.iconState))
            .accessibilityLabel(Text(model.iconState.label))
            .task {
                if model.debugPreview.contains("panel") { openWindow(id: PanelView.previewWindowID) }
                if model.debugPreview.contains("settings") { openSettings() }
                model.showHUDPreview()
                model.showAskPreview()
                model.refreshPermissions()
                guard model.needsOnboarding else { return }
                openWindow(id: OnboardingView.windowID)
                NSApplication.shared.activate()
            }
    }
}
