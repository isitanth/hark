import ApplicationServices
import Foundation

public enum AutomationStatus: Sendable, Equatable {
    case granted
    case denied
    /// Asking would show the consent prompt.
    case notDetermined
    /// macOS only answers for a running target; the question has to wait until it is launched.
    case targetNotRunning
    case unknown(OSStatus)
}

/// Apple Events consent, per target app. AppleScript actions (M6) need it for each app they drive; the onboarding
/// card asks for System Events, which is what keystroke and UI scripting go through.
public enum AutomationPermission {
    public static let systemEvents = "com.apple.systemevents"

    /// Blocks while macOS decides, and with `askUserIfNeeded` while the user answers the prompt. Never call it on the
    /// main thread.
    public static func status(for bundleID: String, askUserIfNeeded: Bool) -> AutomationStatus {
        var target = AEAddressDesc()
        let bytes = Array(bundleID.utf8)
        let created = bytes.withUnsafeBytes {
            AECreateDesc(typeApplicationBundleID, $0.baseAddress, $0.count, &target)
        }
        guard created == noErr else { return .unknown(OSStatus(created)) }
        defer { AEDisposeDesc(&target) }
        return status(for: AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, askUserIfNeeded))
    }

    /// Measured on macOS 27 with System Events not running: `procNotFound` (-600), not a consent answer.
    public static func status(for result: OSStatus) -> AutomationStatus {
        switch result {
        case noErr: .granted
        case OSStatus(errAEEventNotPermitted): .denied
        case OSStatus(errAEEventWouldRequireUserConsent): .notDetermined
        case OSStatus(procNotFound): .targetNotRunning
        default: .unknown(result)
        }
    }
}
