import Foundation

/// How one log entry ended, in terms the UI can put into words: the log's `resolution` and `error` codes read back
/// into a closed set, with anything this build does not know kept as its raw code.
public enum EntryOutcome: Sendable, Equatable {
    /// `cut`: the capture stopped at the length limit and what was said until then went through.
    case command(action: String?, cut: Bool = false)
    /// `app` is the log's `target_app`: a bundle ID, a name, or `pid:N`.
    case inserted(app: String?, cut: Bool = false)
    case copied(CopyReason)
    /// The discard reasons are a closed set already (`DiscardReason`); an unknown code is kept as it is.
    case discarded(DiscardReason?, code: String?)
    case failed(FailureReason)

    /// Why text is on the clipboard rather than in a field.
    public enum CopyReason: Sendable, Equatable {
        /// Clipboard-only mode, or an `apps:` entry that says clipboard: the copy is what the user asked for. Also a
        /// line from the builds before M6, which wrote no reason for any copy the resolver made.
        case chosen
        /// Nothing that takes text had focus.
        case noTextField
        /// A password field: the text is on the clipboard, marked concealed, and not in the log.
        case secureField
        case focusChanged
        case insertionFailed
        case insertionTimedOut
        case pasteNotConsumed
        /// An ask's Replace found another app in front, or another selection than the one asked about.
        case selectionChanged
        /// A code this build does not know.
        case other(String)

        /// The text was meant for a field and did not get there.
        public var isFallback: Bool {
            switch self {
            case .chosen, .noTextField, .secureField: false
            case .focusChanged, .insertionFailed, .insertionTimedOut, .pasteNotConsumed, .selectionChanged, .other:
                true
            }
        }
    }

    public enum FailureReason: Sendable, Equatable {
        case microphoneDenied
        case noInputDevice
        case deviceChanged
        case audioEngine(code: Int?)
        case modelMissing
        case modelLoad
        case transcription(code: Int?)
        /// The text reached neither the field nor the clipboard; it is still in the log and in LAST.
        case pasteboardWrite
        case actionLaunch
        /// `name` is the app as commands.yaml wrote it.
        case appNotFound(name: String?)
        /// It opened behind the app in front.
        case appNotActivated(name: String?)
        /// It quit as soon as it opened.
        case appExited(name: String?)
        /// Hark was quitting.
        case quitting
        case actionTimeout
        case actionExit
        case automationDenied
        case focusNotRestored
        /// An ask: the model server is not running where the profile says.
        case llmUnreachable
        /// An ask: the server refused the key, or no key is set for a profile that needs one.
        case llmUnauthorized
        /// An ask: the server did not answer in time.
        case llmTimeout
        /// An ask: the server refused the request, with the HTTP status when there was one.
        case llmError(status: Int?)
        /// An ask: the answer had no text in it.
        case llmEmpty
        /// A code this build does not know, or none.
        case other(String?)
    }

    /// The line alone decides: a `text_clipboard` line names in `error` why the text is not in a field, and writes
    /// none when the clipboard is where the user asked it to go.
    public init(_ entry: LogEntry) {
        let code = entry.error
        let cut = code == DiscardReason.maxDuration.rawValue
        switch entry.resolution {
        case .command:
            self = .command(action: entry.actionType, cut: cut)
        case .textInserted:
            self = .inserted(app: entry.targetApp, cut: cut)
        case .textClipboard:
            if entry.rawText == nil {
                self = .copied(.secureField)
            } else if let code {
                self = .copied(Self.copyReason(code))
            } else {
                self = .copied(.chosen)
            }
        case .discarded:
            self = .discarded(code.flatMap(DiscardReason.init(rawValue:)), code: code)
        case .failed:
            self = .failed(Self.failureReason(code))
        }
    }

    /// A command or an insertion from a capture that stopped at the length limit.
    public var isCut: Bool {
        switch self {
        case .command(_, let cut), .inserted(_, let cut): cut
        case .copied, .discarded, .failed: false
        }
    }

    /// Text that was meant for a field and ended up on the clipboard.
    public var isFallback: Bool {
        if case .copied(let reason) = self { reason.isFallback } else { false }
    }

    private static func copyReason(_ code: String) -> CopyReason {
        switch code {
        case ClipboardReason.noTextField.code: .noTextField
        case ClipboardReason.secureField.code: .secureField
        case PipelineFailure.focusChanged.code: .focusChanged
        case PipelineFailure.insertionFailed.code: .insertionFailed
        case PipelineFailure.insertionTimedOut.code: .insertionTimedOut
        case PipelineFailure.pasteNotConsumed.code: .pasteNotConsumed
        case PipelineFailure.selectionChanged.code: .selectionChanged
        default: .other(code)
        }
    }

    /// Codes with a payload are `name:value` (`model_missing:small`, `audio_engine:-10868`).
    static func failureReason(_ code: String?) -> FailureReason {
        guard let code else { return .other(nil) }
        let parts = code.split(separator: ":", maxSplits: 1).map(String.init)
        let value = parts.count > 1 ? Int(parts[1]) : nil
        switch parts.first ?? "" {
        case "mic_permission_denied": return .microphoneDenied
        case "no_input_device": return .noInputDevice
        case "device_changed": return .deviceChanged
        case "audio_engine": return .audioEngine(code: value)
        case "model_missing": return .modelMissing
        case "model_load": return .modelLoad
        case "transcription": return .transcription(code: value)
        case "pasteboard_write": return .pasteboardWrite
        case "action_launch": return .actionLaunch
        case "app_not_found": return .appNotFound(name: parts.count > 1 ? parts[1] : nil)
        case "app_not_activated": return .appNotActivated(name: parts.count > 1 ? parts[1] : nil)
        case "app_exited": return .appExited(name: parts.count > 1 ? parts[1] : nil)
        case "quitting": return .quitting
        case "action_timeout": return .actionTimeout
        case "action_exit": return .actionExit
        case "automation_denied": return .automationDenied
        case "focus_not_restored": return .focusNotRestored
        case "llm_unreachable": return .llmUnreachable
        case "llm_unauthorized": return .llmUnauthorized
        case "llm_timeout": return .llmTimeout
        case "llm_error": return .llmError(status: value)
        case "llm_empty": return .llmEmpty
        default: return .other(code)
        }
    }
}
