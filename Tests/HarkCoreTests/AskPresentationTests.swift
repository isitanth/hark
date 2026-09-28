import Foundation
import HarkCore
import Testing

private typealias F = Fixture

private func snapshot(_ state: PipelineState) -> PipelineSnapshot {
    PipelineSnapshot(phase: state.phase, utterance: state.context, ask: state.ask)
}

@Suite struct AskPresentationTests {
    @Test(arguments: [
        (F.askCapturing, false, AskPanelState.listening),
        (F.askTranscribing, false, .transcribing),
        (F.generating, false, .thinking),
        (F.generating, true, .streaming),
        (F.reviewing, true, .reviewing),
        (F.askFailed(.keyRefused), false, .failed(.keyRefused)),
        (.copying(F.askContext(), F.instruction, .chosen), true, .closed),
        (.idle, false, .closed),
    ])
    func thePanelFollowsTheAsk(_ state: PipelineState, _ streamed: Bool, _ expected: AskPanelState) {
        #expect(AskPresentation.state(snapshot(state), streamed: streamed) == expected)
    }

    /// A dictation never opens the panel, whatever its phase.
    @Test(arguments: [F.capturingFocused, F.transcribing, F.resolving, F.inserting, F.copying, F.acting])
    func aDictationLeavesItClosed(_ state: PipelineState) {
        #expect(AskPresentation.state(snapshot(state), streamed: true) == .closed)
    }

    /// The HUD stays down for an ask: the panel carries its listening state.
    @Test(arguments: [F.askCapturing, F.askTranscribing, F.generating])
    func theHUDStaysHiddenForAnAsk(_ state: PipelineState) {
        #expect(HUDPresentation.state(snapshot(state), lastLevel: nil, handsFree: true) == .hidden)
    }

    @Test func theQuoteCollapsesWhitespaceAndCutsLongSelections() {
        #expect(AskPresentation.quote("a\n\n  b\tc") == "a b c")
        let long = String(repeating: "mot ", count: 100)
        let quote = AskPresentation.quote(long, limit: 20)
        #expect(quote.count == 21 && quote.hasSuffix("…"))
    }
}
