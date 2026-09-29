import Foundation

/// The menu bar icon's states: one form of Hark's drill each (`MenuBarGlyph`).
public enum MenuBarIconState: String, Sendable, CaseIterable {
    case idle
    case recording
    /// Recording, latched by a tap: nothing is held, so the icon says the microphone stays open.
    case handsFree
    case transcribing
    /// The model is asked, from the answer being written until the Ask panel closes: seconds, often more, which the
    /// transcribing icon would pass off as Whisper stuck.
    case asking
    /// Always-on listening, set aside: never shown.
    case armed
    case error
    /// For a second after an utterance that came to nothing (`MenuBarOutcome`).
    case dismissed

    /// Error-severity health issues are what turn the idle icon into the error icon; warnings do not.
    public init(
        phase: PipelinePhase, isLatched: Bool = false, isArmed: Bool = false, health: HealthStatus,
        dismissed: Bool = false
    ) {
        self.init(
            phase: phase, isLatched: isLatched, isArmed: isArmed, hasError: health.showsErrorIcon, dismissed: dismissed)
    }

    /// Recording beats busy, busy beats a dismissed utterance, which beats an error, which beats armed.
    public init(
        phase: PipelinePhase, isLatched: Bool = false, isArmed: Bool = false, hasError: Bool = false,
        dismissed: Bool = false
    ) {
        switch phase {
        case .capturing:
            self = isLatched ? .handsFree : .recording
        case .asking:
            self = .asking
        case .transcribing, .resolving, .confirming, .acting, .inserting, .copying:
            self = .transcribing
        case .idle:
            self = dismissed ? .dismissed : hasError ? .error : isArmed ? .armed : .idle
        }
    }

    /// Whether the bit turns: while what was said is worked on, and while the model writes an answer, but not while a
    /// command waits for its confirmation or an answer waits in the Ask panel.
    public static func isWorking(_ phase: PipelinePhase, ask: AskProgress?) -> Bool {
        switch phase {
        case .transcribing, .resolving, .acting, .inserting, .copying: true
        case .asking: ask?.stage == .generating
        case .idle, .capturing, .confirming: false
        }
    }
}
