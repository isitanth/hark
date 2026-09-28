import Foundation

/// What a capture is for, fixed at the press that starts it. An ask's transcript is a spoken instruction for the
/// model: it is never matched as a command or typed at the caret as it was said.
public enum CaptureIntent: Sendable, Equatable {
    case dictate
    /// Services › Ask Hark, or the Ask key over a selection: an instruction about the selected text.
    case ask(SelectionSnapshot)
    /// The Ask key with nothing selected: the request goes to the model alone. `caller` is the app in front at the
    /// press, which a hotkey leaves in front.
    case assist(caller: AppIdentity?)

    /// Both kinds of ask: the Ask panel, not the HUD, and the model, not the resolver.
    public var isAsk: Bool {
        if case .dictate = self { false } else { true }
    }

    /// The text an ask is about; nil for the assistant, which has none.
    public var selection: SelectionSnapshot? {
        if case .ask(let selection) = self { selection } else { nil }
    }

    /// What Replace or Insert must still find in the caller before writing: the selection asked about, or for the
    /// assistant, nothing selected. Nil for a dictation.
    public var expectedSelection: SelectionSnapshot? {
        switch self {
        case .dictate: nil
        case .ask(let selection): selection
        case .assist(let caller): SelectionSnapshot(text: "", caller: caller)
        }
    }
}
