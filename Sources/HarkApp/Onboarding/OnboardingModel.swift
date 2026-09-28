import AppKit
import Foundation
import HarkCore
import Observation
import os

/// Live status of the three permissions, polled while the onboarding window is open, and the requests behind its
/// buttons. Nothing here asks on its own: every prompt follows a click.
@Observable
final class OnboardingModel {
    private(set) var microphone = MicPermission.status
    private(set) var accessibility = AccessibilityPermission.isTrusted
    /// Nil until the first check has come back.
    private(set) var automation: AutomationStatus?
    private(set) var isAskingAutomation = false

    @ObservationIgnored private var polling: Task<Void, Never>?

    private static let logger = Logger(subsystem: "com.anthonychambet.hark", category: "onboarding")
    private static let systemEventsURL = URL(filePath: "/System/Library/CoreServices/System Events.app")

    func startPolling() {
        polling?.cancel()
        polling = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                do {
                    try await Task.sleep(for: .seconds(1.5))
                } catch {
                    return
                }
            }
        }
    }

    func stopPolling() {
        polling?.cancel()
        polling = nil
    }

    func refresh() async {
        microphone = MicPermission.status
        accessibility = AccessibilityPermission.isTrusted
        // An answer the user is giving right now would be overwritten by a stale one.
        guard !isAskingAutomation else { return }
        automation = await Task.detached {
            AutomationPermission.status(for: AutomationPermission.systemEvents, askUserIfNeeded: false)
        }.value
    }

    /// Prompts while the answer is undetermined; after a denial only System Settings can change it.
    func requestMicrophone(orOpen openSettings: () -> Void) {
        guard microphone == .undetermined else {
            openSettings()
            return
        }
        Task { [weak self] in
            _ = await MicPermission.request()
            await self?.refresh()
        }
    }

    func requestAccessibility() {
        AccessibilityPermission.requestWithPrompt()
    }

    /// macOS answers only for a running target, and System Events is not usually running, so it is launched first,
    /// in the background, then asked.
    func requestAutomation() {
        guard !isAskingAutomation else { return }
        isAskingAutomation = true
        Task { [weak self] in
            await Self.launchSystemEvents()
            var status = AutomationStatus.targetNotRunning
            // It takes a moment after launch before the process can be asked.
            for _ in 0..<20 {
                status = await Task.detached {
                    AutomationPermission.status(for: AutomationPermission.systemEvents, askUserIfNeeded: true)
                }.value
                guard status == .targetNotRunning else { break }
                do {
                    try await Task.sleep(for: .milliseconds(100))
                } catch {
                    break
                }
            }
            self?.automation = status
            self?.isAskingAutomation = false
        }
    }

    private static func launchSystemEvents() async {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        do {
            _ = try await NSWorkspace.shared.openApplication(at: systemEventsURL, configuration: configuration)
        } catch {
            logger.error("cannot launch System Events: \(error.localizedDescription, privacy: .public)")
        }
    }
}
