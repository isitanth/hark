import Foundation

public enum PipelineEffect: Sendable, Equatable {
    case startCapture(UtteranceID)
    case probeFocus(UtteranceID)
    case stopCapture(UtteranceID)
    case cancelCapture(UtteranceID)
    case transcribe(UtteranceID)
    case cancelTranscription(UtteranceID)
    /// Emitted once the focus is known, never before.
    case resolve(UtteranceID, Transcript, FocusSnapshot)
    case requestConfirmation(UtteranceID, ResolvedCommand)
    case dismissConfirmation(UtteranceID)
    case restoreFocus(UtteranceID, FocusSnapshot?)
    case runAction(UtteranceID, ResolvedCommand)
    /// `clipboardFallback` travels with the text: the inserter borrows the pasteboard for a paste, and whether it
    /// may keep the text there when nothing reads it is the same preference that decides the log line.
    case insert(UtteranceID, String, InsertionPlan, FocusSnapshot?, clipboardFallback: Bool)
    /// `concealed` when the text came from a secure field: clipboard managers are asked not to record it.
    case copyToClipboard(UtteranceID, String, concealed: Bool)
    case writeLog(UtteranceRecord)
}
