import Foundation

/// What a capture is for, fixed at the press that starts it. An ask's transcript is a spoken instruction about a
/// selection: it is never matched as a command or typed at the caret.
public enum CaptureIntent: Sendable, Equatable {
    case dictate
    case ask(SelectionSnapshot)

    public var isAsk: Bool {
        if case .ask = self { true } else { false }
    }
}
