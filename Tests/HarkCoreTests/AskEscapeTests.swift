import HarkCore
import Testing

/// The composition guard's rule (M15, measured in M15.4): an Esc is an accent's before it is the ask's.
@Suite struct AskEscapeTests {
    /// A dead key pending: the field commits the accent, in the listening field and in the review editor alike.
    @Test func markedTextSendsEscToTheComposition() {
        #expect(AskEscape.route(markedText: true, listeningField: true) == .composition)
        #expect(AskEscape.route(markedText: true, listeningField: false) == .composition)
    }

    /// The listening field takes a plain Esc first: the press-and-hold bubble marks nothing and closes on it.
    @Test func theListeningFieldTakesAPlainEsc() {
        #expect(AskEscape.route(markedText: false, listeningField: true) == .field)
    }

    /// Anywhere else (the review editor, a panel with no field), the panel's rules, as before M15.
    @Test func elsewhereThePanelTakesEsc() {
        #expect(AskEscape.route(markedText: false, listeningField: false) == .panel)
    }

    /// The cancel sent by the Esc that committed an accent is the accent's, and so is one while text is marked; only a
    /// cancel outside a composition cancels the ask.
    @Test(arguments: [(false, false, true), (false, true, false), (true, false, false), (true, true, false)])
    func onlyACancelOutsideACompositionCancelsTheAsk(markedText: Bool, duringComposition: Bool, cancels: Bool) {
        #expect(AskEscape.cancels(markedText: markedText, duringComposition: duringComposition) == cancels)
    }
}
