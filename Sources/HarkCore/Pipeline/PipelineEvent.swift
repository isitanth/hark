import Foundation

public enum Decision: Sendable, Equatable {
    case command(ResolvedCommand)
    /// `fallback` is the `clipboardFallback` preference: whether an insertion that fails may still reach the
    /// clipboard, or ends the utterance as `discarded(clipboard_fallback_disabled)`.
    case insert(InsertionPlan, fallback: Bool)
    case copy(ClipboardReason)
    case discard(DiscardReason)

    /// The usual insertion: a failure falls back to the clipboard.
    public static func insert(_ plan: InsertionPlan) -> Decision { .insert(plan, fallback: true) }
}

public enum PipelineEvent: Sendable, Equatable {
    case triggerDown(UtteranceID, at: Date)
    case focusCaptured(UtteranceID, FocusSnapshot)
    case triggerUp(at: Date)
    case cancel
    /// The length limit was reached while the key was still held. It only ends the capture: the audio arrives with
    /// `captured`, from the stop it triggers, like after a release.
    case captureLimitReached(UtteranceID)
    case captured(UtteranceID, CaptureSummary)
    case transcribed(UtteranceID, Transcript, ms: Int)
    case resolved(UtteranceID, normalized: String?, Decision)
    case confirmed(UtteranceID, Bool)
    case focusRestored(UtteranceID, Bool)
    case actionFinished(UtteranceID, exit: Int32)
    case inserted(UtteranceID)
    case copied(UtteranceID)
    case failed(UtteranceID, PipelineFailure)

    public var utteranceID: UtteranceID? {
        switch self {
        case .triggerDown(let id, _), .focusCaptured(let id, _), .captureLimitReached(let id), .captured(let id, _),
            .transcribed(let id, _, _),
            .resolved(let id, _, _), .confirmed(let id, _), .focusRestored(let id, _), .actionFinished(let id, _),
            .inserted(let id), .copied(let id), .failed(let id, _):
            id
        case .triggerUp, .cancel:
            nil
        }
    }
}
