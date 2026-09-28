import Foundation

public enum DiscardReason: String, Sendable, CaseIterable {
    case cancelled
    case tooShort = "too_short"
    case noSpeech = "no_speech"
    case emptyTranscript = "empty_transcript"
    case declined
    case busy
    /// Written by builds before 2026-09-24, when the length limit discarded the utterance. No longer produced: the
    /// limit ends the capture and the text so far goes through, with this code as the line's `error`.
    case maxDuration = "max_duration"
    case clipboardFallbackDisabled = "clipboard_fallback_disabled"
    /// Ask Hark was invoked on a selection with no text in it.
    case emptySelection = "empty_selection"
    /// The assistant's spoken prefix with nothing after it: "Hark." alone.
    case emptyRequest = "empty_request"
}

public enum PipelineFailure: Error, Sendable, Equatable {
    case micPermissionDenied
    case noInputDevice
    case deviceChanged
    case audioEngine(code: Int32)
    case modelMissing(ModelTier)
    case modelLoad
    case transcription(code: Int32)
    case actionLaunch
    /// A command named an application that is not where its name or path says.
    case appNotFound(String)
    /// The application opened, but the system left it behind the app in front.
    case appNotActivated(String)
    /// The application opened and quit at once, and nothing else came forward.
    case appExited(String)
    /// The app was quitting and the transcription engine had shut down.
    case quitting
    case actionTimeout
    case actionExit(Int32)
    case automationDenied(bundleID: String)
    case focusNotRestored
    case insertionFailed
    /// The frontmost app at insertion is not the one the trigger went down in. The text goes to the clipboard.
    case focusChanged
    /// The app did not answer the AX insertion in time and may still apply it, so it is not pasted on top: the text
    /// goes to the clipboard instead.
    case insertionTimedOut
    /// ⌘V was posted and no app read the pasteboard: the paste landed nowhere, or the app is stuck. The text stays on
    /// the clipboard rather than the user's old contents coming back.
    case pasteNotConsumed
    case pasteboardWrite
    /// The ask's model server refused the connection or has no route: it is not running where the profile says.
    case llmUnreachable
    /// The server answered 401, or the profile needs a key and the Keychain has none for it.
    case llmUnauthorized
    /// No answer in time: nothing on the stream before the first token, or the whole ask ran past its limit.
    case llmTimeout
    /// Any other refusal: an HTTP status other than 401, or an error the server sent inside the stream (no status).
    case llmError(status: Int?)
    /// The stream finished without a word of content.
    case llmEmpty
    /// Before Replace, the calling app was no longer in front or its selection was no longer the one asked about.
    /// The suggestion goes to the clipboard.
    case selectionChanged

    /// Failures that only the microphone side can raise. Once an utterance's audio is in, a late one is stale.
    public var isCaptureFailure: Bool {
        switch self {
        case .micPermissionDenied, .noInputDevice, .deviceChanged, .audioEngine: true
        default: false
        }
    }

    /// Stable value for the log's `error` key.
    public var code: String {
        switch self {
        case .micPermissionDenied: "mic_permission_denied"
        case .noInputDevice: "no_input_device"
        case .deviceChanged: "device_changed"
        case .audioEngine(let code): "audio_engine:\(code)"
        case .modelMissing(let tier): "model_missing:\(tier.rawValue)"
        case .modelLoad: "model_load"
        case .transcription(let code): "transcription:\(code)"
        case .actionLaunch: "action_launch"
        case .appNotFound(let app): "app_not_found:\(app)"
        case .appNotActivated(let app): "app_not_activated:\(app)"
        case .appExited(let app): "app_exited:\(app)"
        case .quitting: "quitting"
        case .actionTimeout: "action_timeout"
        case .actionExit: "action_exit"
        case .automationDenied(let bundleID): "automation_denied:\(bundleID)"
        case .focusNotRestored: "focus_not_restored"
        case .insertionFailed: "insertion_failed"
        case .focusChanged: "focus_changed"
        case .insertionTimedOut: "insertion_timeout"
        case .pasteNotConsumed: "paste_not_consumed"
        case .pasteboardWrite: "pasteboard_write"
        case .llmUnreachable: "llm_unreachable"
        case .llmUnauthorized: "llm_unauthorized"
        case .llmTimeout: "llm_timeout"
        case .llmError(let status?): "llm_error:\(status)"
        case .llmError(nil): "llm_error"
        case .llmEmpty: "llm_empty"
        case .selectionChanged: "selection_changed"
        }
    }
}
