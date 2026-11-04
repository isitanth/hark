/// Esc in the Ask panel: the composition guard's rule (M15). Measured in M15.4 on an AZERTY Mac: with a dead key
/// pending (^), Esc commits the accent, as TextEdit does, and the field then sends `cancelOperation:`; with the
/// press-and-hold bubble open nothing is marked, and the field closes the bubble and sends nothing. The panel's
/// follow-up and drag rules come first: Esc while a frame is dragged drops the drag, an accent pending or not.
public enum AskEscape: Equatable, Sendable {
    /// To the field, which commits the pending accent: the `cancelOperation:` that follows is the accent's.
    case composition
    /// To the listening field: its `cancelOperation:` cancels the ask, unless the accent bubble took the Esc.
    case field
    /// Cancel, as before M15 (in a follow-up, back to the answer).
    case panel

    /// Where an Esc goes once the follow-up and drag rules have passed. `markedText`: the first responder holds marked
    /// text; `listeningField`: the first responder is the listening panel's field.
    public static func route(markedText: Bool, listeningField: Bool) -> AskEscape {
        if markedText { return .composition }
        return listeningField ? .field : .panel
    }

    /// Whether a `cancelOperation:` cancels the ask: never while an accent is marked, nor the one sent by the Esc that
    /// committed it.
    public static func cancels(markedText: Bool, duringComposition: Bool) -> Bool {
        !markedText && !duringComposition
    }
}
