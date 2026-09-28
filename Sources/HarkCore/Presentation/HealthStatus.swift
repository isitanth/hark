import Foundation

public enum HealthSeverity: Int, Sendable, Comparable, CaseIterable {
    case ok
    /// Hark works, with less than it could: insertion or notifications are unavailable.
    case warning
    /// Something the user asked for is not happening. Shows the error icon.
    case error

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A standing problem, as opposed to a failed utterance. Utterances fail in the log; these stay until fixed.
public enum HealthIssue: Sendable, Hashable, CaseIterable {
    /// commands.yaml does not parse. The detail is `ConfigSnapshot.error`; the last good config stays in force.
    case configInvalid
    /// No speech model is loaded, so every press fails with `model_missing`.
    case modelNotLoaded
    case microphoneDenied
    /// Without it Hark cannot see the focused field or post ⌘V, so every dictation lands on the clipboard.
    case accessibilityNotTrusted
    /// The same missing grant, when nothing asks for insertion: clipboard-only mode, and no `apps:` entry that types.
    case accessibilityOptional
    /// M5 posts a notification when text goes to the clipboard.
    case notificationsDenied
    /// The last ask or Test connection failed: the model server was not there, refused the key, or did not answer.
    /// Only an ask depends on it; it stays until the next one succeeds, and Hark never checks in the background.
    case llmUnreachable

    public var severity: HealthSeverity {
        switch self {
        case .configInvalid, .modelNotLoaded, .microphoneDenied, .accessibilityNotTrusted: .error
        case .accessibilityOptional, .notificationsDenied, .llmUnreachable: .warning
        }
    }
}

/// Everything wrong right now, most severe first. HarkApp feeds it the raw facts and renders the result.
public struct HealthStatus: Sendable, Equatable {
    public let issues: [HealthIssue]

    public init(
        configError: ConfigError?,
        modelLoaded: Bool,
        microphone: MicPermissionStatus,
        accessibilityTrusted: Bool,
        accessibilityNeeded: Bool = true,
        notificationsDenied: Bool = false,
        llmUnreachable: Bool = false
    ) {
        var issues: [HealthIssue] = []
        if configError != nil { issues.append(.configInvalid) }
        if !modelLoaded { issues.append(.modelNotLoaded) }
        if microphone == .denied { issues.append(.microphoneDenied) }
        if !accessibilityTrusted {
            issues.append(accessibilityNeeded ? .accessibilityNotTrusted : .accessibilityOptional)
        }
        if notificationsDenied { issues.append(.notificationsDenied) }
        if llmUnreachable { issues.append(.llmUnreachable) }
        // Stable: equal severities keep the order above.
        self.issues = issues.enumerated()
            .sorted { ($0.element.severity, -$0.offset) > ($1.element.severity, -$1.offset) }
            .map(\.element)
    }

    public static let ok = HealthStatus(
        configError: nil, modelLoaded: true, microphone: .granted, accessibilityTrusted: true)

    public var severity: HealthSeverity { issues.map(\.severity).max() ?? .ok }

    public var showsErrorIcon: Bool { severity == .error }

    public func contains(_ issue: HealthIssue) -> Bool { issues.contains(issue) }

    /// Whether launch opens the onboarding window: only while it has never been dismissed and a grant it asks for is
    /// still missing. Quitting with the window open never records the dismissal, so the grants decide as well.
    public static func showsOnboarding(
        dismissed: Bool, microphone: MicPermissionStatus, accessibilityTrusted: Bool, accessibilityNeeded: Bool
    ) -> Bool {
        !dismissed && (microphone != .granted || (accessibilityNeeded && !accessibilityTrusted))
    }
}
