import Foundation

/// How an utterance ended. Exactly one per utterance, carried by its `.writeLog` effect.
public enum PipelineOutcome: Sendable, Equatable {
    case command
    case textInserted
    case textClipboard(ClipboardReason)
    case discarded(DiscardReason)
    case failed(PipelineFailure)

    public var resolution: Resolution {
        switch self {
        case .command: .command
        case .textInserted: .textInserted
        case .textClipboard: .textClipboard
        case .discarded: .discarded
        case .failed: .failed
        }
    }
}

/// Why an utterance's text is on the clipboard. Its `code` is the log's `error` on a `text_clipboard` line.
public enum ClipboardReason: Sendable, Equatable {
    /// Clipboard-only mode, or an `apps:` entry that says clipboard: the clipboard is the destination.
    case chosen
    /// Nothing focused takes text: no element, or one that is not text.
    case noTextField
    /// A password field. The copy is concealed and the log keeps no text.
    case secureField
    /// The insertion was tried and failed. The resolver never answers this; only the reducer does.
    case fallback(PipelineFailure)

    /// Nil when the user chose the clipboard, so an `error` on a line always means something did not go as asked.
    public var code: String? {
        switch self {
        case .chosen: nil
        case .noTextField: "no_text_field"
        case .secureField: "secure_field"
        case .fallback(let failure): failure.code
        }
    }
}

/// The log's `resolution` key.
public enum Resolution: String, Sendable, CaseIterable {
    case command
    case textInserted = "text_inserted"
    case textClipboard = "text_clipboard"
    case discarded
    case failed
}
