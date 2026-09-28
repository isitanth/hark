import Foundation
import HarkCore
import UserNotifications
import os

/// Posts through UNUserNotificationCenter, asking for permission the first time it has something to say.
///
/// It is also the center's delegate, so a notification still shows while Hark is the active app: the one that
/// reports a model selection is typically triggered from the Model tab, and without the delegate macOS would
/// deliver it silently to Notification Center.
final class UserNotificationPoster: NSObject, NotificationPoster, UNUserNotificationCenterDelegate {
    private static let logger = Logger(subsystem: "com.anthonychambet.hark", category: "notifications")

    override init() {
        super.init()
        Self.center?.delegate = self
    }

    /// A binary run outside its bundle has no identity to post under, and the center traps on it.
    private static var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    func post(_ content: NotificationContent) async -> NotificationDelivery {
        guard let center = Self.center else { return .failed }
        guard await authorize(center) else { return .denied }
        let request = UNNotificationRequest(
            identifier: Self.identifier(for: content), content: body(for: content), trigger: nil)
        do {
            try await center.add(request)
            return .delivered
        } catch {
            Self.logger.error("post failed: \(error.localizedDescription, privacy: .public)")
            return .failed
        }
    }

    func isDenied() async -> Bool? {
        guard let center = Self.center else { return nil }
        switch await center.notificationSettings().authorizationStatus {
        case .notDetermined: return nil
        case .authorized, .provisional, .ephemeral: return false
        default: return true
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    private func authorize(_ center: UNUserNotificationCenter) async -> Bool {
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional:
            return true
        case .notDetermined:
            do {
                return try await center.requestAuthorization(options: [.alert, .sound])
            } catch {
                Self.logger.error("authorization failed: \(error.localizedDescription, privacy: .public)")
                return false
            }
        default:
            return false
        }
    }

    /// One identifier per kind, so a new notification replaces the last rather than stacking in Notification
    /// Center. For a copy that matters: only the most recent one is the text actually on the clipboard, and an
    /// older banner left sitting there would say otherwise.
    private static func identifier(for content: NotificationContent) -> String {
        switch content {
        case .modelAutoSelected: "model-auto-selected"
        case .textCopied: "text-copied"
        case .captureCut: "capture-cut"
        case .inputChanged: "input-changed"
        case .commandFailed: "command-failed"
        }
    }

    private func body(for content: NotificationContent) -> UNNotificationContent {
        let body = UNMutableNotificationContent()
        switch content {
        case .modelAutoSelected(let tier):
            let name = ModelCatalog.entry(for: tier).displayName
            body.title = String(localized: L("notification.modelAutoSelected.title"))
            body.body = String(localized: L("notification.modelAutoSelected.body \(name)"))
            body.sound = .default
        case .textCopied(let preview, let fallback, let sound):
            body.title = String(
                localized: fallback ? L("notification.copied.fallback") : L("notification.copied.title"))
            if let preview {
                body.body = String(localized: L("notification.copied.body \(preview)"))
            } else {
                body.body = String(localized: L("notification.copied.concealed"))
            }
            body.sound = sound ? .default : nil
        case .captureCut(let minutes, let sound):
            body.title = String(localized: L("notification.captureCut.title \(minutes)"))
            body.body = String(localized: L("notification.captureCut.body"))
            body.sound = sound ? .default : nil
        case .inputChanged(let sound):
            body.title = String(localized: L("notification.inputChanged.title"))
            body.body = String(localized: L("notification.inputChanged.body"))
            body.sound = sound ? .default : nil
        case .commandFailed(let reason, let code, let sound):
            body.title = String(localized: LogEntry.failureText(reason, code: code))
            // Only a name that matched no app is the user's to fix in the tab; the others found the app.
            if case .appNotFound = reason {
                body.body = String(localized: L("notification.commandFailed.body"))
            } else {
                body.body = String(localized: L("notification.commandFailed.retry"))
            }
            body.sound = sound ? .default : nil
        }
        return body
    }
}
