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

// MARK: Late events, and the frame

extension TypedAskTests {
    /// The talk key's latch, Done, a queued limit, or the capture's own end and its words: none lands after typing.
    static let lateEvents: [PipelineEvent] = [
        .triggerUp(at: Typed.at), .captureLimitReached(F.id), .captured(F.id, F.speech), .captured(F.id, F.short),
        .captured(F.id, F.silent), .captured(F.id, F.maxed), .transcribed(F.id, F.instruction, ms: 400),
    ]

    @Test(arguments: lateEvents)
    func aLateCaptureEventAfterTypingIsRejected(_ event: PipelineEvent) throws {
        var run = ExactRun()
        try run.on(.triggerDown(F.id, at: F.pressedAt, intent: F.ask))
        try run.on(.typingStarted(F.id))
        #expect(run.rejects(event))
    }

    @Test(arguments: lateEvents)
    func aLateCaptureEventAfterTheSubmitIsRejected(_ event: PipelineEvent) throws {
        var run = ExactRun(on: false)
        try run.typed()
        #expect(run.rejects(event))
    }

    @Test func aSpokenAskStillStopsItsCapture() throws {
        var run = ExactRun()
        try run.on(.triggerDown(F.id, at: F.pressedAt, intent: F.ask))
        #expect(try run.on(.triggerUp(at: Typed.at)) == ["stopCapture"])
        var limited = ExactRun()
        try limited.on(.triggerDown(F.id, at: F.pressedAt, intent: F.ask))
        #expect(try limited.on(.captureLimitReached(F.id)) == ["stopCapture"])
    }

    @Test func aTypedAskNeverLogsACaptureReason() throws {
        var run = ExactRun(on: false)
        try run.typed()
        for event in Self.lateEvents { _ = run.rejects(event) }
        try run.on(.cancel)
        let errors = run.lines.map(\.error)
        #expect(errors == ["cancelled"])
        #expect(!errors.contains { ["too_short", "no_speech", "max_duration"].contains($0) })
    }

    @Test func aFramedTypedAskWhoseWordsComputeWaitsForTheReader() throws {
        var run = ExactRun()
        try run.on(.triggerDown(F.id, at: F.pressedAt, intent: Exact.assist))
        try run.on(.regionCaptured(F.id, F.region))
        try run.on(.typingStarted(F.id))
        try run.on(.typed(F.id, Exact.compute.raw, at: Typed.at))
        #expect(run.stage == .reading && run.math?.routed == true)
        try run.on(.regionRead(F.id, Exact.sheet))
        #expect(run.stage == .planning && run.labels == ["plan"])
    }

    @Test func aFramedTypedAskWhoseWordsComputeIsPlannedOverItsSheet() throws {
        var run = ExactRun()
        try run.on(.triggerDown(F.id, at: F.pressedAt, intent: Exact.assist))
        try run.on(.regionCaptured(F.id, F.region))
        try run.on(.regionRead(F.id, Exact.sheet))
        try run.on(.typingStarted(F.id))
        #expect(try run.on(.typed(F.id, Exact.compute.raw, at: Typed.at)) == ["plan"])
        #expect(run.stage == .planning)
    }

    @Test func aFramedTypedAskWhoseWordsDoNotComputeGoesToTheModel() throws {
        var run = ExactRun()
        try run.on(.triggerDown(F.id, at: F.pressedAt, intent: Exact.assist))
        try run.on(.regionCaptured(F.id, F.region))
        try run.on(.regionRead(F.id, Exact.sheet))
        try run.on(.typingStarted(F.id))
        try run.on(.typed(F.id, Exact.free.raw, at: Typed.at))
        #expect(run.stage == .generating && run.labels == ["generate+region"])
    }

    @Test func aTypedSubmitWithTheDragStillOpenAwaitsTheFrame() throws {
        var run = ExactRun(on: false)
        try run.on(.triggerDown(F.id, at: F.pressedAt, intent: Exact.assist))
        try run.on(.regionStarted(F.id))
        try run.on(.typingStarted(F.id))
        try run.on(.typed(F.id, Typed.words, at: Typed.at))
        #expect(run.stage == .awaitingRegion)
        try run.on(.regionCaptured(F.id, F.region))
        #expect(run.stage == .generating && run.labels == ["generate+region"])
    }

    @Test func aFrameDrawnWhileTypingIsKept() throws {
        var run = ExactRun(on: false)
        try run.on(.triggerDown(F.id, at: F.pressedAt, intent: Exact.assist))
        try run.on(.typingStarted(F.id))
        try run.on(.regionCaptured(F.id, F.region))
        #expect(run.state.phase == .capturing && run.context?.input == .typed && run.context?.region != nil)
        try run.on(.typed(F.id, Typed.words, at: Typed.at))
        #expect(run.labels == ["generate+region"])
    }
}

// MARK: Follow-ups, and the line

extension TypedAskTests {
    @Test func aTypedFollowUpSupersedesTheParkedTurn() throws {
        var run = ExactRun(on: false)
        try run.freeReviewed()
        try run.followUpTyping()
        #expect(run.labels == ["cancelCapture"] && run.state.phase == .capturing)
        try run.on(.typed(Exact.second, "Plus court.", at: Typed.followUpAt))
        #expect(run.labels == ["log:discarded:followed_up", "generate"] && run.stage == .generating)
        #expect(run.context?.releasedAt == Typed.followUpAt)
    }

    @Test func aBlankTypedFollowUpReturnsToTheAnswer() throws {
        var run = ExactRun(on: false)
        try run.freeReviewed()
        try run.followUpTyping()
        try run.on(.typed(Exact.second, "  ", at: Typed.followUpAt))
        #expect(run.labels == ["log:discarded:empty_transcript"])
        #expect(run.stage == .reviewing && run.context?.id == F.id)
    }

    @Test func escAfterTypingAFollowUpReturnsToTheAnswer() throws {
        var run = ExactRun(on: false)
        try run.freeReviewed()
        try run.followUpTyping()
        try run.on(.cancel)
        #expect(run.labels == ["cancelCapture", "log:discarded:cancelled"])
        #expect(run.stage == .reviewing && run.context?.id == F.id)
    }

    @Test func aFailureRacingTheCancelEndsBothTurns() throws {
        var run = ExactRun(on: false)
        try run.freeReviewed()
        try run.followUpTyping()
        try run.on(.failed(Exact.second, .deviceChanged))
        #expect(run.labels == ["cancelCapture", "log:failed:device_changed", "log:discarded:cancelled"])
        #expect(run.state == .idle)
    }

    @Test func aTypedFollowUpWhoseWordsComputeIsPlannedOverTheEarlierSheet() throws {
        var run = ExactRun()
        try run.reviewed()
        try run.followUpTyping()
        try run.on(.typed(Exact.second, "And the total of both, doubled?", at: Typed.followUpAt))
        #expect(run.stage == .planning && run.labels == ["log:discarded:followed_up", "plan"])
    }

    @Test func aTypedFollowUpRejectsTheLateCaptureEvents() throws {
        var run = ExactRun(on: false)
        try run.freeReviewed()
        try run.followUpTyping()
        #expect(run.rejects(.triggerUp(at: Typed.followUpAt)))
        #expect(run.rejects(.captureLimitReached(Exact.second)))
        #expect(run.rejects(.captured(Exact.second, F.short)))
        #expect(run.rejects(.typingStarted(Exact.second)))
    }

    @Test func aTypedAskLineHasNoTranscriptionAndRunsFromThePressToTheSubmit() throws {
        var run = ExactRun(on: false)
        try run.freeReviewed()
        try run.on(.askCopy(F.id, Typed.reply))
        try run.on(.copied(F.id))
        let line = try #require(run.lines.last)
        #expect(run.lines.count == 1 && line.resolution == .textClipboard && line.error == nil)
        #expect(line.actionType == .ask && line.rawText == Typed.words)
        #expect(line.normalizedText == Normalizer.normalize(Typed.words))
        #expect(line.transcribeMs == nil && line.modelTier == nil && line.llmModel == Exact.planModel)
        #expect(line.durationMs == 3_000)
        let json = try JSONSerialization.jsonObject(with: Data(line.jsonLine(timeZone: F.paris).utf8))
        #expect((json as? [String: Any])?.count == UtteranceRecord.keys.count && UtteranceRecord.keys.count == 14)
    }

    @Test func aCancelledTypedAskWritesNoTranscription() throws {
        var run = ExactRun()
        try run.on(.triggerDown(F.id, at: F.pressedAt, intent: F.ask))
        try run.on(.typingStarted(F.id))
        try run.on(.cancel)
        let line = try #require(run.lines.last)
        #expect(line.error == "cancelled" && line.rawText == nil && line.transcribeMs == nil && line.modelTier == nil)
    }
}
