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
        (F.awaitingRegion, false, .awaitingRegion),
        (
            .asking(F.regionContext(failure: .captureFailed), F.instruction, .regionFailed(.captureFailed)), false,
            .regionFailed(.captureFailed)
        ),
        (F.regionAskFailed, false, .failed(.noVision(model: F.bonsai, reason: .noVision))),
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

    /// Replace for an ask; for the assistant, Insert where the probe found a field and Copy alone elsewhere.
    @Test func whatTheAnswerCanDo() {
        var assistant = Fixture.assistContext()
        #expect(AskPresentation.apply(assistant) == .insert)
        assistant.focus = FocusSnapshot(app: Fixture.textEdit, element: FocusedElement(role: "AXOutline"))
        #expect(AskPresentation.apply(assistant) == .copyOnly)
        assistant.focus = nil
        #expect(AskPresentation.apply(assistant) == .copyOnly)
        assistant.focus = FocusSnapshot(
            app: Fixture.textEdit, element: FocusedElement(role: "AXTextField", subrole: "AXSecureTextField"),
            isSecureInput: true)
        #expect(AskPresentation.apply(assistant) == .copyOnly)
        #expect(AskPresentation.apply(Fixture.askContext()) == .replace)
        // The probe found a field in another app than the one the key was pressed in, or in Hark itself: Copy.
        var elsewhere = Fixture.assistContext(
            focus: FocusSnapshot(app: Fixture.mail, element: FocusedElement(role: "AXTextField")))
        #expect(AskPresentation.apply(elsewhere) == .copyOnly)
        elsewhere = UtteranceContext(id: Fixture.id, pressedAt: Fixture.pressedAt, intent: .assist(caller: nil))
        elsewhere.focus = Fixture.backInTextEdit
        #expect(AskPresentation.apply(elsewhere) == .copyOnly)
    }

    /// A framed region never offers Replace: Insert where a field has the focus in the caller, else Copy alone.
    /// About a selection, Insert would paste over it, still selected in the caller: a framed ask offers Copy alone. With
    /// nothing selected (the assistant), Insert where a field has the focus.
    @Test func anAskWithAFrameOffersInsertOrCopy() {
        #expect(AskPresentation.apply(F.regionContext()) == .replace)
        var framed = F.regionContext(region: F.region)
        #expect(AskPresentation.apply(framed) == .copyOnly)
        framed.focus = F.backInTextEdit
        #expect(AskPresentation.apply(framed) == .copyOnly)
        #expect(AskPresentation.apply(F.regionContext(intent: F.assist, region: F.region)) == .insert)
    }
}
