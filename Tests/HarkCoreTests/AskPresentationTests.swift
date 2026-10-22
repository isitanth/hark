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

/// A conversation in the panel (M12): its earlier turns, the footer, and what a frame changes.
@Suite struct AskConversationPresentationTests {
    private static let pin = ProfilePin(
        name: "local", baseURL: URL(string: "http://127.0.0.1:8000/v1")!, api: .openAI, model: .auto,
        requestedModel: F.bonsai)
    private static let turn1 = AskTurn(
        id: UtteranceID(11), instruction: "Résume.", reply: "Un résumé.\nSuite.", region: nil)
    private static let framedTurn = AskTurn(
        id: UtteranceID(12), instruction: "Et ici ?", reply: "%% Tu veux le total.\n\n802 €", region: F.region)
    private static let wordsAfterFrame = AskTurn(
        id: UtteranceID(13), instruction: "En dollars ?", reply: "%% Tu veux le total en dollars.\n\n870 $", region: nil
    )

    /// A follow-up's context: its own id, turn 1's intent.
    private static func context(_ id: UtteranceID) -> UtteranceContext {
        UtteranceContext(id: id, pressedAt: F.pressedAt, intent: F.ask)
    }

    private static func thread(_ turns: [AskTurn], kind: AskThread.Kind = .selection) -> AskThread {
        AskThread(rootID: turns.first?.id ?? F.id, kind: kind, selection: "texte", pin: pin, turns: turns)
    }

    /// A context in review whose thread holds `turns`.
    private static func live(_ turns: [AskTurn], region: RegionSummary? = nil, reply: String? = "Réponse.")
        -> UtteranceContext
    {
        var context = F.regionContext(region: region)
        context.thread = turns.isEmpty ? nil : thread(turns)
        context.reply = reply
        return context
    }

    @Test func theRowsOfAThreadWithoutAFrameKeepTheirReplyWhole() {
        let rows = AskPresentation.earlierTurns(Self.live([Self.turn1]))
        #expect(
            rows == [
                AskTurnRow(
                    id: UtteranceID(11), instruction: "Résume.", restatement: nil, answer: "Un résumé.\nSuite.",
                    region: nil)
            ])
        #expect(rows.first?.firstLine == "Un résumé.")
    }

    /// From the first framed turn on, every reply is split, a turn in words after it included; the one before is not.
    @Test func theRowsFromTheFirstFrameOnShowTheirRestatement() {
        let rows = AskPresentation.earlierTurns(Self.live([Self.turn1, Self.framedTurn, Self.wordsAfterFrame]))
        #expect(rows.map(\.restatement) == [nil, "Tu veux le total.", "Tu veux le total en dollars."])
        #expect(rows.map(\.answer) == ["Un résumé.\nSuite.", "802 €", "870 $"])
        #expect(rows.map(\.region) == [nil, F.region, nil])
    }

    /// During a follow-up's capture the turn it follows up is parked: it is the last row, with its own frame.
    @Test func theParkedTurnIsTheLastRow() {
        var parked = F.regionContext(region: F.region)
        parked.reply = "%% Tu veux la somme.\n\n42"
        var context = Self.context(UtteranceID(20))
        context.thread = Self.thread([Self.turn1])
        context.parked = .turn(parked, F.instruction)
        let rows = AskPresentation.earlierTurns(context)
        #expect(rows.count == 2)
        #expect(
            rows.last
                == AskTurnRow(
                    id: F.id, instruction: F.instruction.raw, restatement: "Tu veux la somme.", answer: "42",
                    region: F.region))
        #expect(AskPresentation.earlierTurns(nil).isEmpty)
        #expect(AskPresentation.earlierTurns(F.askContext()).isEmpty)
    }

    @Test(arguments: [("", ""), ("\n  \nDeux\nTrois", "Deux"), ("  Un  ", "Un")])
    func theFoldedRowShowsTheFirstLineWithWords(_ answer: String, _ expected: String) {
        #expect(
            AskTurnRow(id: F.id, instruction: "", restatement: nil, answer: answer, region: nil).firstLine == expected)
    }

    private static func reviewing(_ context: UtteranceContext, _ instruction: Transcript = F.instruction)
        -> PipelineSnapshot
    {
        let state = PipelineState.asking(context, instruction, .reviewing)
        return PipelineSnapshot(phase: state.phase, utterance: state.context, ask: state.ask)
    }

    @Test func theFooterCountsTheTurnsInReview() {
        #expect(AskPresentation.footerHint(Self.reviewing(Self.live([]))) == .followUp(turn: 1, of: 6))
        #expect(AskPresentation.footerHint(Self.reviewing(Self.live([Self.turn1]))) == .followUp(turn: 2, of: 6))
        let generating = PipelineState.asking(Self.live([Self.turn1]), F.instruction, .generating)
        #expect(
            AskPresentation.footerHint(
                PipelineSnapshot(phase: generating.phase, utterance: generating.context, ask: generating.ask))
                == nil)
    }

    /// Full at the sixth turn, not the fifth; and full early when the history reaches its cap.
    @Test func theFooterSaysWhenTheConversationIsFull() {
        let five = Array(repeating: Self.turn1, count: 5)
        #expect(AskPresentation.footerHint(Self.reviewing(Self.live(five))) == .full)
        #expect(
            AskPresentation.footerHint(Self.reviewing(Self.live(Array(five.prefix(4))))) == .followUp(turn: 5, of: 6))
        let long = String(repeating: "x", count: AskThread.maxHistoryChars)
        #expect(AskPresentation.footerHint(Self.reviewing(Self.live([Self.turn1], reply: long))) == .full)
    }

    @Test func theBusyNudgeShowsOverAnOpenPanelForTwoSeconds() {
        #expect(AskPresentation.busyNudgeFor == .seconds(2))
        #expect(AskPresentation.showsBusyNudge(.reviewing))
        #expect(AskPresentation.showsBusyNudge(.listening))
        #expect(!AskPresentation.showsBusyNudge(.closed))
    }

    /// Replace goes from the first framed turn on, and a framed selection thread gives Copy alone; an assistant thread
    /// keeps Insert.
    @Test func aFramedThreadHidesReplace() {
        #expect(AskPresentation.allowsReplace(Self.live([Self.turn1])))
        #expect(AskPresentation.apply(Self.live([Self.turn1])) == .replace)
        #expect(!AskPresentation.allowsReplace(Self.live([Self.turn1], region: F.region)))
        let framed = Self.live([Self.turn1, Self.framedTurn])
        #expect(!AskPresentation.allowsReplace(framed))
        #expect(AskPresentation.apply(framed) == .copyOnly)
        #expect(AskPresentation.expectsRestatement(framed))
        #expect(!AskPresentation.expectsRestatement(Self.live([Self.turn1])))
        var assistant = F.assistContext()
        assistant.thread = Self.thread([Self.framedTurn], kind: .assistant)
        #expect(AskPresentation.apply(assistant) == .insert)
    }

    /// Without the image only when this turn's frame is the conversation's only one.
    @Test func askWithoutTheImageOnlyForTheOnlyFrame() {
        #expect(AskPresentation.offersAskWithoutImage(Self.live([], region: F.region)))
        #expect(AskPresentation.offersAskWithoutImage(Self.live([Self.turn1], region: F.region)))
        #expect(!AskPresentation.offersAskWithoutImage(Self.live([Self.framedTurn], region: F.region)))
        #expect(!AskPresentation.offersAskWithoutImage(Self.live([Self.turn1])))
    }

    /// The thumbnails kept are the turns the state names with a frame: turn 1's stays through two follow-ups.
    @Test func theThumbnailsKeptAreTheFramedTurnsNamed() {
        let root = AskTurn(id: UtteranceID(11), instruction: "Ça ?", reply: "%% Ça.\n\nOui", region: F.region)
        var parked = Self.context(UtteranceID(12))
        parked.reply = "%% Et ça.\n\nNon"
        var second = Self.context(UtteranceID(13))
        second.regionPending = true
        second.thread = Self.thread([root])
        second.parked = .turn(parked, F.instruction)
        #expect(AskPresentation.framedTurns(second) == [UtteranceID(11), UtteranceID(13)])
        second.regionPending = false
        #expect(AskPresentation.framedTurns(second) == [UtteranceID(11)])
        parked.region = F.region
        second.parked = .turn(parked, F.instruction)
        #expect(AskPresentation.framedTurns(second) == [UtteranceID(11), UtteranceID(12)])
        #expect(AskPresentation.framedTurns(nil).isEmpty)
    }

    /// The reset keys on turn 1: a follow-up's new id keeps the same root.
    @Test func theResetKeysOnTheRoot() {
        #expect(AskPresentation.threadRoot(F.askContext()) == F.id)
        var followUp = Self.context(UtteranceID(30))
        followUp.thread = Self.thread([Self.turn1])
        #expect(AskPresentation.threadRoot(followUp) == UtteranceID(11))
    }
}
