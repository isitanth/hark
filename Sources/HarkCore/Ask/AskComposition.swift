/// The composition guard's rule (M15): a key pressed while an accent is composed is the accent's before it is the
/// ask's. Measured in M15.4 on an AZERTY Mac: with a dead key pending (^), Esc arrives as `^` + Esc and Return as
/// `^` + Return; handed to the field, the text system commits the ^ (as TextEdit does), then the field sends
/// `cancelOperation:` for the Esc, or submits during the same Return, before the panel sees the committed text. With
/// the press-and-hold bubble open nothing is marked; the field closes the bubble on Esc and sends nothing.
public enum AskComposition {
    /// Where an Esc goes once the panel's follow-up and drag rules have passed: Esc while a frame is dragged drops the
    /// drag, an accent pending or not.
    public enum Escape: Equatable, Sendable {
        /// To the field, which commits the pending accent: the `cancelOperation:` that follows is the accent's.
        case composition
        /// To the listening field: its `cancelOperation:` cancels the ask, unless the accent bubble took the Esc.
        case field
        /// Cancel, as before M15 (in a follow-up, back to the answer).
        case panel
    }

    /// `markedText`: the first responder holds marked text; `listeningField`: the first responder is the listening
    /// panel's field.
    public static func escape(markedText: Bool, listeningField: Bool) -> Escape {
        if markedText { return .composition }
        return listeningField ? .field : .panel
    }

    /// Whether a `cancelOperation:` cancels the ask: never while an accent is marked, nor the one sent by the Esc that
    /// committed it.
    public static func cancels(markedText: Bool, duringComposition: Bool) -> Bool {
        !markedText && !duringComposition
    }

    /// Whether the field's submit sends the typed text (or, before any typing, is Done): not the one sent by the Return
    /// that commits a pending accent, which only commits it.
    public static func submits(duringComposition: Bool) -> Bool {
        !duringComposition
    }
}
