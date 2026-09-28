import Foundation

/// The five menu bar icon states from the design brief.
public enum MenuBarIconState: String, Sendable, CaseIterable {
    case idle
    case recording
    case transcribing
    case armed
    case error

    /// Error-severity health issues are what turn the idle icon into the error icon; warnings do not.
    public init(phase: PipelinePhase, isArmed: Bool = false, health: HealthStatus) {
        self.init(phase: phase, isArmed: isArmed, hasError: health.showsErrorIcon)
    }

    /// Recording beats busy, busy beats error, error beats armed.
    public init(phase: PipelinePhase, isArmed: Bool = false, hasError: Bool = false) {
        switch phase {
        case .capturing:
            self = .recording
        case .transcribing, .resolving, .confirming, .acting, .inserting, .copying:
            self = .transcribing
        case .idle:
            self = hasError ? .error : isArmed ? .armed : .idle
        }
    }
}
