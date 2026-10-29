import Foundation
import HarkCore
import Testing

private typealias F = Fixture

/// What an exact ask is played with: two amounts and a label, words that compute and words that do not.
enum Exact {
    static let sheet = MathFixtures.sheet(texts: ["12.50", "7.50", "Total"])
    static let otherSheet = MathFixtures.sheet(texts: ["100", "40"])
    static let wordsOnly = MathFixtures.sheet(texts: ["Bonjour", "Merci"])
    static let compute = Transcript(raw: "How much in total?", tier: .small)
    static let free = Transcript(raw: "Résume ce texte.", tier: .small)
    static let understood = "You want the sum of the two amounts."
    static let solved = planReply("SUM(C1,C2)", understood: understood)
    static let unknownCell = planReply("C99")
    static let notJSON = "The total is 20."
    static let pin = ProfilePin(
        name: "local", baseURL: URL(string: "http://127.0.0.1:8000/v1")!, api: .openAI, model: .auto,
        requestedModel: "gemma")
    static let planModel = "gemma-plan"
    static func summary(_ ms: Int = 900, model: String? = planModel, finish: String? = "stop") -> LLMCallSummary {
        LLMCallSummary(model: model, ms: ms, finishReason: finish, pin: pin)
    }
    static let second = UtteranceID(2)
    static let third = UtteranceID(3)
    static let assist = CaptureIntent.assist(caller: F.textEdit)
}

/// A reducer played event by event, from idle, the way the controller would.
struct ExactRun {
    var reducer: PipelineReducer
    var state = PipelineState.idle
    var effects: [PipelineEffect] = []
    var all: [PipelineEffect] = []

    typealias Solve = @Sendable (String, String?, CellSheet, String) -> Result<Computation, MathFailure>

    init(on: Bool = true, solve: Solve? = nil) {
        reducer = PipelineReducer()
        reducer.exactMath = on
        if let solve { reducer.solve = solve }
    }

    @discardableResult
    mutating func on(_ event: PipelineEvent) throws -> [String] {
        let transition = try reducer.reduce(state, event).get()
        state = transition.state
        effects = transition.effects
        all += transition.effects
        return labels
    }

    func rejects(_ event: PipelineEvent) -> Bool {
        reducer.reduce(state, event) == .failure(Rejection(phase: state.phase, event: event))
    }

    var labels: [String] { effects.map(\.label) }
    var stage: AskStage? {
        guard case .asking(_, _, let stage) = state else { return nil }
        return stage
    }
    var math: ExactMathContext? { state.context?.math }
    var context: UtteranceContext? { state.context }
    var lines: [UtteranceRecord] {
        all.compactMap {
            guard case .writeLog(let record) = $0 else { return nil }
            return record
        }
    }

    /// The press, a frame captured while the key is held, the release and the words.
    mutating func ask(
        _ words: Transcript = Exact.compute, intent: CaptureIntent = Exact.assist, id: UtteranceID = F.id,
        framed: Bool = true, read: Result<CellSheet, ReaderFailure>? = nil
    ) throws {
        try on(.triggerDown(id, at: F.pressedAt, intent: intent))
        if framed { try on(.regionCaptured(id, F.region)) }
        switch read {
        case .success(let sheet)?: try on(.regionRead(id, sheet))
        case .failure(let failure)?: try on(.regionReadFailed(id, failure))
        case nil: break
        }
        try on(.triggerUp(at: F.pressedAt.addingTimeInterval(2)))
        try on(.captured(id, F.speech))
        try on(.transcribed(id, words, ms: 400))
    }

    /// An exact answer in review: turn 1 planned over `Exact.sheet` and solved.
    mutating func reviewed(intent: CaptureIntent = Exact.assist) throws {
        try ask(intent: intent, read: .success(Exact.sheet))
        try on(.planned(F.id, Exact.summary(), reply: Exact.solved))
    }

    /// A follow-up's capture and words.
    mutating func followUp(
        _ words: Transcript = Exact.compute, id: UtteranceID = Exact.second, framed: Bool = false,
        read: Result<CellSheet, ReaderFailure>? = nil
    ) throws {
        try on(.followUpDown(id, at: F.pressedAt.addingTimeInterval(10)))
        if framed { try on(.regionCaptured(id, F.region)) }
        switch read {
        case .success(let sheet)?: try on(.regionRead(id, sheet))
        case .failure(let failure)?: try on(.regionReadFailed(id, failure))
        case nil: break
        }
        try on(.triggerUp(at: F.pressedAt.addingTimeInterval(12)))
        try on(.captured(id, F.speech))
        try on(.transcribed(id, words, ms: 400))
    }
}

@Suite struct MathTransitionTests {
    // MARK: The stamp

    @Test(arguments: [true, false])
    func anAskIsStampedAtItsPress(_ on: Bool) throws {
        for intent in [F.ask, Exact.assist] {
            var run = ExactRun(on: on)
            try run.on(.triggerDown(F.id, at: F.pressedAt, intent: intent))
            #expect(run.math == (on ? ExactMathContext() : nil))
        }
    }

    @Test func aDictationIsNeverStamped() throws {
        var run = ExactRun()
        try run.on(.triggerDown(F.id, at: F.pressedAt, intent: .dictate))
        #expect(run.math == nil)
    }

    @Test(arguments: [true, false])
    func aChangeMidAskLeavesTheAskInFlight(_ on: Bool) throws {
        var run = ExactRun(on: on)
        try run.on(.triggerDown(F.id, at: F.pressedAt, intent: Exact.assist))
        run.reducer.exactMath = !on
        try run.on(.regionCaptured(F.id, F.region))
        #expect(run.labels == (on ? ["readRegion"] : []))
        #expect((run.math != nil) == on)
    }

    @Test func aFollowUpIsStampedAtItsOwnPress() throws {
        var run = ExactRun()
        try run.reviewed()
        run.reducer.exactMath = false
        try run.on(.followUpDown(Exact.second, at: F.pressedAt))
        #expect(run.math == nil)
    }

    // MARK: The read before the words

    @Test func aFrameIsReadWhileTheUserSpeaks() throws {
        var run = ExactRun()
        try run.on(.triggerDown(F.id, at: F.pressedAt, intent: Exact.assist))
        #expect(try run.on(.regionCaptured(F.id, F.region)) == ["readRegion"])
        #expect(run.math?.reading == .pending)
        try run.on(.triggerUp(at: F.pressedAt))
        #expect(try run.on(.regionCaptured(F.id, F.region)) == ["cancelReading", "readRegion"])
        #expect(try run.on(.regionRead(F.id, Exact.sheet)) == [])
        #expect(run.math?.reading == .read(Exact.sheet))
        #expect(run.state.phase == .transcribing)
    }

    @Test func aFrameCapturedWhileTranscribingIsRead() throws {
        var run = ExactRun()
        try run.on(.triggerDown(F.id, at: F.pressedAt, intent: Exact.assist))
        try run.on(.triggerUp(at: F.pressedAt))
        #expect(try run.on(.regionCaptured(F.id, F.region)) == ["readRegion"])
        #expect(try run.on(.regionReadFailed(F.id, .vision)) == [])
        #expect(run.math?.reading == .failed(.vision))
    }

    @Test func aNewDragOrTheChipsCrossStopsTheRead() throws {
        var run = ExactRun()
        try run.on(.triggerDown(F.id, at: F.pressedAt, intent: Exact.assist))
        try run.on(.regionCaptured(F.id, F.region))
        #expect(try run.on(.regionStarted(F.id)) == ["cancelReading"])
        #expect(run.math?.reading == .idle)
        try run.on(.regionCaptured(F.id, F.region))
        #expect(try run.on(.regionRemoved(F.id)) == ["cancelReading"])
        #expect(run.math?.reading == .idle)
        #expect(try run.on(.regionStarted(F.id)) == [])
    }

    @Test func aReadNoLongerPendingIsRejected() throws {
        var run = ExactRun()
        try run.on(.triggerDown(F.id, at: F.pressedAt, intent: Exact.assist))
        #expect(run.rejects(.regionRead(F.id, Exact.sheet)))
        try run.on(.regionCaptured(F.id, F.region))
        try run.on(.regionRemoved(F.id))
        #expect(run.rejects(.regionRead(F.id, Exact.sheet)))
        #expect(run.rejects(.regionReadFailed(F.id, .timeout)))
        try run.on(.regionCaptured(F.id, F.region))
        try run.on(.regionRead(F.id, Exact.sheet))
        #expect(run.rejects(.regionRead(F.id, Exact.otherSheet)))
    }

    @Test func mathOffReadsNothing() throws {
        var run = ExactRun(on: false)
        try run.on(.triggerDown(F.id, at: F.pressedAt, intent: Exact.assist))
        #expect(try run.on(.regionCaptured(F.id, F.region)) == [])
        #expect(run.rejects(.regionRead(F.id, Exact.sheet)))
    }

    // MARK: Routing at the transcript

    struct Route: Sendable, CustomTestStringConvertible {
        let name: String
        let words: Transcript
        let framed: Bool
        let read: Result<CellSheet, ReaderFailure>?
        let stage: AskStage
        let effects: [String]
        let routed: Bool

        var testDescription: String { name }
    }

    static let routes: [Route] = [
        Route(
            name: "read, computing: planning", words: Exact.compute, framed: true, read: .success(Exact.sheet),
            stage: .planning, effects: ["plan"], routed: true),
        Route(
            name: "pending, computing: reading", words: Exact.compute, framed: true, read: nil, stage: .reading,
            effects: [], routed: true),
        Route(
            name: "vision failure: mathFailed", words: Exact.compute, framed: true, read: .failure(.vision),
            stage: .mathFailed(.reader(.vision)), effects: [], routed: true),
        Route(
            name: "timeout: mathFailed", words: Exact.compute, framed: true, read: .failure(.timeout),
            stage: .mathFailed(.reader(.timeout)), effects: [], routed: true),
        Route(
            name: "free words with a frame: today's", words: Exact.free, framed: true, read: .success(Exact.sheet),
            stage: .generating, effects: ["generate+region"], routed: false),
        Route(
            name: "free words, read pending: today's", words: Exact.free, framed: true, read: nil,
            stage: .generating, effects: ["generate+region"], routed: false),
        Route(
            name: "computing with no frame: today's", words: Exact.compute, framed: false, read: nil,
            stage: .generating, effects: ["generate"], routed: false),
        Route(
            name: "a sheet with no amount: today's", words: Exact.compute, framed: true,
            read: .success(Exact.wordsOnly), stage: .generating, effects: ["generate+region"], routed: false),
    ]

    @Test(arguments: routes)
    func routing(_ route: Route) throws {
        var run = ExactRun()
        try run.ask(route.words, framed: route.framed, read: route.read)
        #expect(run.stage == route.stage)
        #expect(run.labels == route.effects)
        #expect(run.math?.routed == route.routed)
        #expect(run.math?.fallback == nil)
        // A free ask no longer waits for the read: the controller cancels it.
        if !route.routed { #expect(run.math?.reading != .pending) }
    }

    @Test func theComputationalWordsAreTheWordChecks() {
        #expect(MathIntent.isComputation(Exact.compute.raw))
        #expect(!MathIntent.isComputation(Exact.free.raw))
    }

    @Test func aFrameAwaitedByARoutedInstructionIsReadThen() throws {
        var run = ExactRun()
        try run.on(.triggerDown(F.id, at: F.pressedAt, intent: Exact.assist))
        try run.on(.regionStarted(F.id))
        try run.on(.triggerUp(at: F.pressedAt))
        try run.on(.captured(F.id, F.speech))
        try run.on(.transcribed(F.id, Exact.compute, ms: 400))
        #expect(run.stage == .awaitingRegion)
        #expect(try run.on(.regionCaptured(F.id, F.region)) == ["readRegion"])
        #expect(run.stage == .reading)
        #expect(try run.on(.regionRead(F.id, Exact.sheet)) == ["plan"])
        #expect(run.stage == .planning)
    }

    @Test func aFrameAwaitedByAFreeInstructionIsNotRead() throws {
        var run = ExactRun()
        try run.on(.triggerDown(F.id, at: F.pressedAt, intent: Exact.assist))
        try run.on(.regionStarted(F.id))
        try run.on(.triggerUp(at: F.pressedAt))
        try run.on(.captured(F.id, F.speech))
        try run.on(.transcribed(F.id, Exact.free, ms: 400))
        #expect(try run.on(.regionCaptured(F.id, F.region)) == ["generate+region"])
        #expect(run.math?.reading == .idle)
    }

    // MARK: The reading stage

    @Test func theReadArrivingInReadingPlans() throws {
        var run = ExactRun()
        try run.ask()
        #expect(try run.on(.regionRead(F.id, Exact.sheet)) == ["plan"])
        #expect(run.stage == .planning)
        #expect(run.math?.attempts == 1)
    }

    @Test func aSheetWithNoAmountArrivingInReadingIsTodaysAsk() throws {
        var run = ExactRun()
        try run.ask()
        #expect(try run.on(.regionRead(F.id, Exact.wordsOnly)) == ["generate+region"])
        #expect(run.stage == .generating)
        #expect(run.math?.routed == false)
        #expect(run.math?.fallback == nil)
    }

    @Test(arguments: ReaderFailure.allCases)
    func aReaderFailureInReadingStops(_ failure: ReaderFailure) throws {
        var run = ExactRun()
        try run.ask()
        #expect(try run.on(.regionReadFailed(F.id, failure)) == [])
        #expect(run.stage == .mathFailed(.reader(failure)))
    }

    // MARK: The planning stage

    @Test func aSolvedPlanIsReviewedWithTheComposedReply() throws {
        var run = ExactRun()
        try run.ask(read: .success(Exact.sheet))
        #expect(try run.on(.planned(F.id, Exact.summary(), reply: Exact.solved)) == ["publishAnswer"])
        #expect(run.stage == .reviewing)
        let computation = try #require(run.math?.computation)
        let composed = ExactAnswer(
            computation, sheet: Exact.sheet, policy: .standard, fallback: Locale(identifier: "en_US_POSIX")
        ).reply
        #expect(run.context?.reply == composed)
        #expect(composed.hasPrefix(IntentSplit.marker + " " + Exact.understood))
        #expect(run.effects == [.publishAnswer(F.id, composed)])
        #expect(run.context?.answer == nil)
        #expect(run.context?.pin == Exact.pin)
        #expect(run.context?.llmModel == Exact.planModel && run.context?.llmMs == 900)
        #expect(computation.value == 20)
    }

    @Test func theResultIsWrittenInTheReducersLocale() throws {
        var run = ExactRun()
        run.reducer.resultLocale = Locale(identifier: "fr_FR")
        try run.ask(read: .success(MathFixtures.sheet(texts: ["1.25", "2.5"])))
        try run.on(.planned(F.id, Exact.summary(), reply: Exact.solved))
        #expect(run.context?.reply?.hasSuffix("3,75") == true)
    }

    static let retryable: [PlanDefect] = [
        .json, .syntax, .unknownFunction, .unknownCell, .unspokenConstant("1.2"), .unit("money and percent"),
        .degenerate,
    ]

    @Test(arguments: retryable)
    func aRetryableDefectIsAskedAgainOnceWithItsNote(_ defect: PlanDefect) throws {
        var run = ExactRun(solve: { _, _, _, _ in .failure(.plan(defect)) })
        try run.ask(read: .success(Exact.sheet))
        #expect(try run.on(.planned(F.id, Exact.summary(), reply: "first")) == ["plan+correction"])
        #expect(run.stage == .planning)
        #expect(run.math?.attempts == 2)
        guard case .plan(_, _, _, _, _, let correction) = run.effects.first else { throw Missing() }
        #expect(correction == PlanCorrection(reply: "first", note: defect.correction))
        #expect(try run.on(.planned(F.id, Exact.summary(), reply: "second")) == [])
        #expect(run.stage == .mathFailed(.plan(defect)))
    }

    static let final: [MathFailure] =
        [.plan(.noFormula), .plan(.truncated)]
        + MathDefect.allCases.flatMap { [MathFailure.math($0, cell: CellID(2)), .math($0, cell: nil)] }

    @Test(arguments: final)
    func aFinalFailureStopsAtOnceAndKeepsItsCell(_ failure: MathFailure) throws {
        var run = ExactRun(solve: { _, _, _, _ in .failure(failure) })
        try run.ask(read: .success(Exact.sheet))
        #expect(try run.on(.planned(F.id, Exact.summary(), reply: "plan")) == [])
        #expect(run.stage == .mathFailed(failure))
    }

    @Test func theRealEngineRetriesAnUnknownCellAndANonJSONReply() throws {
        var run = ExactRun()
        try run.ask(read: .success(Exact.sheet))
        #expect(try run.on(.planned(F.id, Exact.summary(), reply: Exact.unknownCell)) == ["plan+correction"])
        #expect(try run.on(.planned(F.id, Exact.summary(), reply: Exact.notJSON)) == [])
        #expect(run.stage == .mathFailed(.plan(.json)))
    }

    @Test func aRetryReportsBothCallsTimeAndTheModelThatAnswered() throws {
        var run = ExactRun()
        try run.ask(read: .success(Exact.sheet))
        try run.on(.planned(F.id, Exact.summary(700, model: "first"), reply: Exact.unknownCell))
        try run.on(.planned(F.id, Exact.summary(1_100, model: "second"), reply: Exact.solved))
        #expect(run.stage == .reviewing)
        #expect(run.context?.llmMs == 1_800)
        #expect(run.context?.llmModel == "second")
    }

    @Test func aTruncatedReplyIsNotRetried() throws {
        var run = ExactRun()
        try run.ask(read: .success(Exact.sheet))
        try run.on(.planned(F.id, Exact.summary(finish: "length"), reply: Exact.solved))
        #expect(run.stage == .mathFailed(.plan(.truncated)))
    }

    @Test func aServerFailureOfThePlanFailsAndRetryPlansAgain() throws {
        var run = ExactRun()
        try run.ask(read: .success(Exact.sheet))
        try run.on(.planned(F.id, Exact.summary(700), reply: Exact.unknownCell))
        #expect(try run.on(.generationFailed(F.id, .noAnswer, Exact.summary(300))) == [])
        #expect(run.stage == .failed(.noAnswer))
        #expect(run.context?.llmMs == 1_000)
        #expect(try run.on(.askRetry(F.id)) == ["plan"])
        #expect(run.stage == .planning)
        #expect(run.math?.attempts == 1)
        #expect(run.context?.llmMs == nil && run.context?.llmModel == nil)
    }

    @Test func aFreeAsksRetryStaysFree() throws {
        var run = ExactRun()
        try run.ask(Exact.free, read: .success(Exact.sheet))
        try run.on(.generationFailed(F.id, .noAnswer, Exact.summary()))
        #expect(try run.on(.askRetry(F.id)) == ["generate+region"])
    }

    @Test func askingWithoutTheImageAfterAPlanFailureLeavesExactMath() throws {
        var run = ExactRun()
        try run.ask(read: .success(Exact.sheet))
        try run.on(.generationFailed(F.id, .noVision(model: "m", reason: .noVision), Exact.summary()))
        #expect(try run.on(.askRetryWithoutRegion(F.id)) == ["generate"])
        #expect(run.math?.routed == false)
        try run.on(.generationFailed(F.id, .noAnswer, Exact.summary()))
        #expect(try run.on(.askRetry(F.id)) == ["generate"])
    }

    @Test func aPlanEventOutsidePlanningIsRejected() throws {
        var run = ExactRun()
        try run.ask(read: .success(Exact.sheet))
        try run.on(.planned(F.id, Exact.summary(), reply: Exact.solved))
        #expect(run.rejects(.planned(F.id, Exact.summary(), reply: Exact.solved)))
        #expect(run.rejects(.regionRead(F.id, Exact.sheet)))
        #expect(run.rejects(.askWithoutExactMath(F.id)))
    }
}

struct Missing: Error {}
