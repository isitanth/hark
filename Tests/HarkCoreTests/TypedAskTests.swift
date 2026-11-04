import Foundation
import HarkCore
import Testing

private typealias F = Fixture

/// What a typed ask is played with (M15).
private enum Typed {
    static let words = "Résume ce texte."
    static let at = F.pressedAt.addingTimeInterval(3)
    static let followUpAt = F.pressedAt.addingTimeInterval(14)
    static let reply = "Réunion jeudi."
}

extension ExactRun {
    /// The press, the first character and the submit, with no frame.
    fileprivate mutating func typed(
        _ text: String = Typed.words, intent: CaptureIntent = F.ask, id: UtteranceID = F.id
    ) throws {
        try on(.triggerDown(id, at: F.pressedAt, intent: intent))
        try on(.typingStarted(id))
        try on(.typed(id, text, at: Typed.at))
    }

    /// A free ask answered and in review.
    fileprivate mutating func freeReviewed() throws {
        try typed()
        try on(.generated(F.id, Exact.summary(), reply: Typed.reply))
    }

    /// A follow-up pressed in review, typing started.
    fileprivate mutating func followUpTyping(id: UtteranceID = Exact.second) throws {
        try on(.followUpDown(id, at: F.pressedAt.addingTimeInterval(10)))
        try on(.typingStarted(id))
    }
}

@Suite struct TypedAskTests {
    // MARK: The first character

    @Test(arguments: [F.ask, Exact.assist])
    func typingStartedCancelsTheCaptureAndStaysCapturing(_ intent: CaptureIntent) throws {
        var run = ExactRun()
        try run.on(.triggerDown(F.id, at: F.pressedAt, intent: intent))
        #expect(run.context?.input == .voice)
        #expect(try run.on(.typingStarted(F.id)) == ["cancelCapture"])
        #expect(run.state.phase == .capturing && run.context?.input == .typed)
    }

    @Test func typingStartedIsRejectedForADictation() throws {
        var run = ExactRun()
        try run.on(.triggerDown(F.id, at: F.pressedAt, intent: .dictate))
        #expect(run.rejects(.typingStarted(F.id)))
    }

    @Test func typingStartedIsRejectedASecondTime() throws {
        var run = ExactRun()
        try run.on(.triggerDown(F.id, at: F.pressedAt, intent: F.ask))
        try run.on(.typingStarted(F.id))
        #expect(run.rejects(.typingStarted(F.id)))
    }

    @Test func typingStartedIsRejectedForAnotherID() throws {
        var run = ExactRun()
        try run.on(.triggerDown(F.id, at: F.pressedAt, intent: F.ask))
        #expect(run.rejects(.typingStarted(F.other)))
        #expect(run.rejects(.typed(F.other, Typed.words, at: Typed.at)))
    }

    @Test(arguments: [
        PipelineState.idle, F.askTranscribing, F.generating, F.reviewing, F.replacing, F.awaitingRegion,
        F.assistTranscribing, F.transcribing,
    ])
    func typingIsRejectedOutsideCapturing(_ state: PipelineState) {
        let reducer = PipelineReducer()
        let started = PipelineEvent.typingStarted(F.id)
        let typed = PipelineEvent.typed(F.id, Typed.words, at: Typed.at)
        #expect(reducer.reduce(state, started) == .failure(Rejection(phase: state.phase, event: started)))
        #expect(reducer.reduce(state, typed) == .failure(Rejection(phase: state.phase, event: typed)))
    }

    // MARK: The submit

    @Test func typedIsRejectedBeforeTypingStarted() throws {
        var run = ExactRun()
        try run.on(.triggerDown(F.id, at: F.pressedAt, intent: F.ask))
        #expect(run.rejects(.typed(F.id, Typed.words, at: Typed.at)))
    }

    @Test func typedIsRejectedWhileTranscribing() {
        let reducer = PipelineReducer()
        var context = F.askContext()
        context.input = .typed
        let state = PipelineState.transcribing(context)
        let event = PipelineEvent.typed(F.id, Typed.words, at: Typed.at)
        #expect(reducer.reduce(state, event) == .failure(Rejection(phase: .transcribing, event: event)))
    }

    @Test(arguments: [F.ask, Exact.assist])
    func aTypedAskGoesToTheModelAsASpokenOneDoes(_ intent: CaptureIntent) throws {
        var run = ExactRun(on: false)
        try run.typed(intent: intent)
        #expect(run.labels == ["generate"])
        #expect(run.stage == .generating)
        #expect(run.context?.releasedAt == Typed.at && run.context?.transcribeMs == nil)
        guard case .asking(_, let transcript, _) = run.state else { return #expect(Bool(false)) }
        #expect(transcript.raw == Typed.words && transcript.tier == nil)
        #expect(transcript.normalized == Normalizer.normalize(Typed.words))
    }

    @Test func aTypedInstructionIsCutAtTheCap() throws {
        var run = ExactRun(on: false)
        try run.typed(String(repeating: "é", count: PipelineReducer.maxTypedCharacters + 500))
        guard case .asking(_, let transcript, .generating) = run.state else { return #expect(Bool(false)) }
        #expect(transcript.raw.count == PipelineReducer.maxTypedCharacters)
    }

    @Test func aTypedInstructionAtTheCapIsKeptWhole() throws {
        var run = ExactRun(on: false)
        let text = String(repeating: "a", count: PipelineReducer.maxTypedCharacters)
        try run.typed(text)
        guard case .asking(_, let transcript, .generating) = run.state else { return #expect(Bool(false)) }
        #expect(transcript.raw == text)
    }

    @Test(arguments: ["", "   ", "\n\t "])
    func aBlankTypedAskIsDiscardedAsAnEmptyTranscript(_ text: String) throws {
        var run = ExactRun()
        try run.typed(text)
        #expect(run.state == .idle && run.labels == ["log:discarded:empty_transcript"])
        #expect(run.lines.first?.durationMs == 3_000)
    }
}
