import Foundation
import HarkCore
import Testing

private typealias F = Fixture

/// Outcomes as `solveAll` would give them, built from the one-result engine over `Exact.sheet`.
enum Multi {
    static let total = computed("SUM(C1,C2)", understood: "the total")
    static let gap = computed("C1 - C2", understood: "the gap")
    static let largest = computed("MAX(C1,C2)", understood: "the largest")
    static let zero: ResultOutcome = .failure(.math(.divisionByZero, cell: nil))
    static let badCell: ResultOutcome = .failure(.plan(.unknownCell))
    static let badSyntax: ResultOutcome = .failure(.plan(.syntax))
    static let empty: ResultOutcome = .failure(.plan(.noFormula))

    static func computed(_ formula: String, understood: String) -> ResultOutcome {
        MathEngine.solve(
            reply: planReply(formula, understood: understood), finishReason: "stop", sheet: Exact.sheet,
            instruction: Exact.compute.raw)
    }

    static func stub(_ outcomes: [ResultOutcome]) -> PipelineReducer.Solve {
        { _, _, _, _, _ in .success(outcomes) }
    }

    /// The first reply gets `first`, any later one `second`: the retry's replies are told apart by their text.
    static func retry(_ first: [ResultOutcome], then second: [ResultOutcome]) -> PipelineReducer.Solve {
        { reply, _, _, _, _ in .success(reply == "first" ? first : second) }
    }

    static func answer(_ outcome: ResultOutcome) -> Result<ExactAnswer, MathFailure> {
        outcome.map {
            ExactAnswer($0, sheet: Exact.sheet, policy: .standard, fallback: Locale(identifier: "en_US_POSIX"))
        }
    }

    static func numbers(_ run: ExactRun) -> [Int] { run.math?.numbers ?? [] }
}

@Suite struct MultiResultTransitionTests {
    // MARK: The planned row

    @Test func oneResultIsTodaysReplyByteForByte() throws {
        var run = ExactRun(solve: Multi.stub([Multi.total]))
        try run.ask(read: .success(Exact.sheet))
        #expect(try run.on(.planned(F.id, Exact.summary(), reply: "first")) == ["publishAnswer"])
        #expect(run.stage == .reviewing)
        let today = try Multi.answer(Multi.total).get().reply
        #expect(run.context?.reply == today)
        #expect(run.math?.numbers == [1])
        #expect(run.math?.kept.map(\.number) == [1])
        #expect(run.math?.computation == (try? Multi.total.get()))
    }

    @Test func threeResultsAreReviewedNumberedInTheModelsOrder() throws {
        var run = ExactRun(solve: Multi.stub([Multi.total, Multi.gap, Multi.largest]))
        try run.ask(read: .success(Exact.sheet))
        try run.on(.planned(F.id, Exact.summary(), reply: "first"))
        #expect(run.stage == .reviewing)
        #expect(run.math?.results.count == 3)
        #expect(run.math?.numbers == [1, 2, 3])
        #expect(run.math?.kept.map(\.understood) == ["the total", "the gap", "the largest"])
        #expect(run.math?.kept.map(\.turn) == [F.id, F.id, F.id])
        #expect(run.math?.computation == (try? Multi.total.get()))
        #expect(run.math?.attempts == 1)
    }

    @Test func theComposedReplyNumbersEachResult() throws {
        var run = ExactRun(solve: Multi.stub([Multi.total, Multi.zero]))
        try run.ask(read: .success(Exact.sheet))
        try run.on(.planned(F.id, Exact.summary(), reply: "first"))
        let total = try Multi.answer(Multi.total).get()
        let expected =
            "%% ① the total ② \n\n① " + (total.working ?? "") + "\n① " + total.shownResult + "\n② not computed"
        #expect(run.context?.reply == expected)
        guard case .publishAnswer(_, let published) = run.effects.last else { throw Missing() }
        #expect(published == expected)
    }

    @Test func theCircledDigitsGoToTwenty() {
        #expect(ResultMark.circled(1) == "①")
        #expect(ResultMark.circled(3) == "③")
        #expect(ResultMark.circled(20) == "⑳")
    }

    @Test func aKeptResultIsWhatWasShown() throws {
        var run = ExactRun(solve: Multi.stub([Multi.total]))
        try run.ask(read: .success(Exact.sheet))
        try run.on(.planned(F.id, Exact.summary(), reply: "first"))
        let kept = try #require(run.math?.kept.first)
        let computation = try Multi.total.get()
        #expect(kept.value == computation.value)
        #expect(kept.shown == (try Multi.answer(Multi.total).get().result))
        #expect(kept.scale == 2)
        #expect(kept.unitLabel == nil)
    }

    // MARK: Partial and total failure

    @Test func aFailedResultStaysNumberedAndTheOthersAreReviewed() throws {
        var run = ExactRun(solve: Multi.stub([Multi.total, Multi.zero, Multi.largest]))
        try run.ask(read: .success(Exact.sheet))
        try run.on(.planned(F.id, Exact.summary(), reply: "first"))
        #expect(run.stage == .reviewing)
        #expect(run.math?.numbers == [1, 2, 3])
        #expect(run.math?.kept.map(\.number) == [1, 3])
        #expect(run.context?.reply?.contains("② not computed") == true)
    }

    @Test func everyResultFailedIsMathFailedWithTheFirst() throws {
        var run = ExactRun(solve: Multi.stub([Multi.zero, Multi.empty]))
        try run.ask(read: .success(Exact.sheet))
        #expect(try run.on(.planned(F.id, Exact.summary(), reply: "first")) == [])
        #expect(run.stage == .mathFailed(.math(.divisionByZero, cell: nil)))
        #expect(run.math?.numbers == [])
        #expect(run.math?.kept == [])
    }

    @Test func anEmptyResultListIsMathFailed() throws {
        var run = ExactRun(solve: Multi.stub([]))
        try run.ask(read: .success(Exact.sheet))
        try run.on(.planned(F.id, Exact.summary(), reply: "first"))
        #expect(run.stage == .mathFailed(.plan(.json)))
    }

    // MARK: The retry

    @Test func theRetryNamesEachBadResultByPosition() throws {
        var run = ExactRun(solve: Multi.retry([Multi.total, Multi.badCell, Multi.badSyntax], then: [Multi.total]))
        try run.ask(read: .success(Exact.sheet))
        #expect(try run.on(.planned(F.id, Exact.summary(900), reply: "first")) == ["plan+correction"])
        #expect(run.stage == .planning)
        #expect(run.math?.attempts == 2)
        guard case .plan(_, _, _, _, _, let correction) = run.effects.first else { throw Missing() }
        let note =
            "result 2: " + PlanDefect.unknownCell.correction + "; result 3: " + PlanDefect.syntax.correction
            + ". Keep the other results as they were"
        #expect(correction == PlanCorrection(reply: "first", note: note))
        try run.on(.planned(F.id, Exact.summary(400), reply: "second"))
        #expect(run.stage == .reviewing)
        #expect(run.context?.llmMs == 1300)
    }

    @Test func oneEntrySendsTodaysNote() {
        #expect(PlanPrompt.retryNote(.success([Multi.badCell])) == PlanDefect.unknownCell.correction)
        #expect(
            PlanPrompt.retryNote(.success([.failure(.plan(.unknownResult))]))
                == "refer only to result IDs from the results list")
    }

    @Test func aWholeReplyThatIsNotTheSchemaAsksForTheArray() {
        #expect(
            PlanPrompt.retryNote(.failure(.plan(.json)))
                == "reply with one JSON object with a results array of 1 to 3 entries, each with understood, formula, "
                + "unit and unit_label only")
        #expect(PlanPrompt.retryNote(.failure(.plan(.truncated))) == nil)
        #expect(PlanPrompt.retryNote(.failure(.reader(.vision))) == nil)
    }

    @Test func nothingRetryableIsNoRetry() {
        #expect(PlanPrompt.retryNote(.success([Multi.total, Multi.zero, Multi.empty])) == nil)
        #expect(PlanPrompt.retryNote(.success([])) == nil)
    }

    @Test func aResultThatFailsAgainFailsAlone() throws {
        var run = ExactRun(
            solve: Multi.retry([Multi.total, Multi.badCell], then: [Multi.total, Multi.badCell]))
        try run.ask(read: .success(Exact.sheet))
        try run.on(.planned(F.id, Exact.summary(), reply: "first"))
        #expect(try run.on(.planned(F.id, Exact.summary(), reply: "second")) == ["publishAnswer"])
        #expect(run.stage == .reviewing)
        #expect(run.math?.numbers == [1, 2])
        #expect(run.math?.kept.map(\.number) == [1])
    }

    @Test func theSecondReplyReplacesTheFirst() throws {
        var run = ExactRun(solve: Multi.retry([Multi.badCell, Multi.gap], then: [Multi.largest]))
        try run.ask(read: .success(Exact.sheet))
        try run.on(.planned(F.id, Exact.summary(), reply: "first"))
        try run.on(.planned(F.id, Exact.summary(), reply: "second"))
        #expect(run.math?.kept.map(\.understood) == ["the largest"])
        #expect(run.math?.numbers == [1])
    }

    @Test func aRetryThatFailsEverywhereIsMathFailed() throws {
        var run = ExactRun(solve: Multi.retry([Multi.badCell, Multi.badSyntax], then: [Multi.badSyntax, Multi.zero]))
        try run.ask(read: .success(Exact.sheet))
        try run.on(.planned(F.id, Exact.summary(), reply: "first"))
        try run.on(.planned(F.id, Exact.summary(), reply: "second"))
        #expect(run.stage == .mathFailed(.plan(.syntax)))
    }
}
