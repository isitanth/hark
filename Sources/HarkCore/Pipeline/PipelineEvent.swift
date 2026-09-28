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
    /// A press of the talk key (`dictate`), or Services › Ask Hark (`ask`), which starts a capture the same way.
    case triggerDown(UtteranceID, at: Date, intent: CaptureIntent = .dictate)
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
    /// The ask's stream finished with text. The text itself went to the popup, not through here.
    case generated(UtteranceID, LLMCallSummary)
    case generationFailed(UtteranceID, LLMFailure, LLMCallSummary)
    /// Retry in the popup after a failure: the same instruction and selection, sent again.
    case askRetry(UtteranceID)
    /// Copy in the popup: `text` is the suggestion as the user left it.
    case askCopy(UtteranceID, String)
    /// Replace in the popup: `text` goes in place of the selection, once it is checked.
    case askReplace(UtteranceID, String)
    case selectionChecked(UtteranceID, SelectionCheck)

    public var utteranceID: UtteranceID? {
        switch self {
        case .triggerDown(let id, _, _), .focusCaptured(let id, _), .captureLimitReached(let id), .captured(let id, _),
            .transcribed(let id, _, _),
            .resolved(let id, _, _), .confirmed(let id, _), .focusRestored(let id, _), .actionFinished(let id, _),
            .inserted(let id), .copied(let id), .failed(let id, _), .generated(let id, _),
            .generationFailed(let id, _, _), .askRetry(let id), .askCopy(let id, _), .askReplace(let id, _),
            .selectionChecked(let id, _):
            id
        case .triggerUp, .cancel:
            nil
        }
    }
}
