import HarkCore
import Testing

/// The composition guard's rule (M15, measured in M15.4): a key pressed while an accent is composed is the accent's
/// before it is the ask's.
@Suite struct AskCompositionTests {
    /// A dead key pending: the field commits the accent, in the listening field and in the review editor alike.
    @Test func markedTextSendsEscToTheComposition() {
        #expect(AskComposition.escape(markedText: true, listeningField: true) == .composition)
        #expect(AskComposition.escape(markedText: true, listeningField: false) == .composition)
    }

    /// The listening field takes a plain Esc first: the press-and-hold bubble marks nothing and closes on it.
    @Test func theListeningFieldTakesAPlainEsc() {
        #expect(AskComposition.escape(markedText: false, listeningField: true) == .field)
    }

    /// Anywhere else (the review editor, a panel with no field), Cancel, as before M15.
    @Test func elsewhereThePanelTakesEsc() {
        #expect(AskComposition.escape(markedText: false, listeningField: false) == .panel)
    }

    /// The cancel sent by the Esc that committed an accent is the accent's, and so is one while text is marked; only a
    /// cancel outside a composition cancels the ask.
    @Test(arguments: [(false, false, true), (false, true, false), (true, false, false), (true, true, false)])
    func onlyACancelOutsideACompositionCancelsTheAsk(markedText: Bool, duringComposition: Bool, cancels: Bool) {
        #expect(AskComposition.cancels(markedText: markedText, duringComposition: duringComposition) == cancels)
    }

    /// The submit sent by the Return that commits an accent only commits it: it neither sends a lone ^ nor ends the
    /// capture as Done. Any other submit goes as before.
    @Test func theReturnThatCommitsAnAccentSubmitsNothing() {
        #expect(!AskComposition.submits(duringComposition: true))
        #expect(AskComposition.submits(duringComposition: false))
    }
}
