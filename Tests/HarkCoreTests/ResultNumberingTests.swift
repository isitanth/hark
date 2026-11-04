import Foundation
import HarkCore
import Testing

private typealias F = Fixture

/// A turn 1 of two results, the second failed, then a follow-up of two: the kept results reach the engine.
private let twoThenTwo: PipelineReducer.Solve = { reply, _, _, _, kept in
    if reply == "turn1" { return .success([Multi.total, Multi.zero]) }
    if reply == "fail" { return .success([Multi.empty]) }
    return .success(kept.map(\.number) == [1] ? [Multi.gap, Multi.largest] : [Multi.empty])
}

@Suite struct ResultNumberingTests {
    private func answered() throws -> ExactRun {
        var run = ExactRun(solve: twoThenTwo)
        try run.ask(read: .success(Exact.sheet))
        try run.on(.planned(F.id, Exact.summary(), reply: "turn1"))
        return run
    }

    @Test func aFollowUpCountsOnFromEveryNumberGiven() throws {
        var run = try answered()
        try run.followUp()
        #expect(run.stage == .planning)
        try run.on(.planned(Exact.second, Exact.summary(), reply: "turn2"))
        #expect(run.stage == .reviewing)
        #expect(run.math?.numbers == [3, 4])
        #expect(run.math?.kept.map(\.turn) == [Exact.second, Exact.second])
        // The conversation's results are the earlier turns'; the turn in review holds its own.
        #expect(run.context?.keptResults.map(\.number) == [1])
    }

    @Test func supersedeKeepsTheShownResultsAndFormulas() throws {
        var run = try answered()
        try run.followUp()
        let turn = try #require(run.context?.thread?.turns.first)
        #expect(turn.results.map(\.number) == [1])
        #expect(turn.numbers == [1, 2])
        #expect(turn.formulas == ["SUM(C1,C2)"])
        #expect(turn.formula == "SUM(C1,C2)")
        #expect(turn.sheet == Exact.sheet)
        #expect(run.context?.thread?.lastResultNumber == 2)
    }

    @Test func aReturnToTheParkedTurnKeepsItsNumbers() throws {
        var run = try answered()
        try run.on(.followUpDown(Exact.second, at: F.pressedAt.addingTimeInterval(10)))
        #expect(run.context?.keptResults.map(\.number) == [1])
        try run.on(.cancel)
        #expect(run.stage == .reviewing)
        #expect(run.math?.numbers == [1, 2])
        #expect(run.math?.kept.map(\.number) == [1])
        try run.followUp(id: Exact.third)
        try run.on(.planned(Exact.third, Exact.summary(), reply: "turn2"))
        #expect(run.math?.numbers == [3, 4])
    }

    @Test func aTurnThatEndsWithoutReviewGivesNone() throws {
        var run = try answered()
        try run.followUp()
        try run.on(.planned(Exact.second, Exact.summary(), reply: "fail"))
        #expect(run.stage == .mathFailed(.plan(.noFormula)))
        #expect(run.math?.numbers == [])
        try run.on(.askWithoutExactMath(Exact.second))
        #expect(run.math?.kept == [])
        #expect(run.context?.keptResults.map(\.number) == [1])
    }

    @Test func aFreeAnswerOverAFailedPlanKeepsNoResult() throws {
        var run = ExactRun(solve: Multi.stub([Multi.zero]))
        try run.ask(read: .success(Exact.sheet))
        try run.on(.planned(F.id, Exact.summary(), reply: "first"))
        try run.on(.askWithoutExactMath(F.id))
        try run.on(.generated(F.id, Exact.summary(), reply: "free"))
        #expect(run.math?.kept == [])
        #expect(run.math?.results == [])
    }

    @Test(arguments: [false, true])
    func everyPathToIdleFreesTheKeptResults(_ copy: Bool) throws {
        var run = try answered()
        try run.followUp()
        try run.on(.planned(Exact.second, Exact.summary(), reply: "turn2"))
        if copy {
            try run.on(.askCopy(Exact.second, "4"))
            try run.on(.copied(Exact.second))
        } else {
            try run.on(.cancel)
        }
        #expect(run.state == .idle)
        #expect(run.context == nil)
    }

    @Test func aTurnsNumbersDefaultToItsResults() throws {
        let kept = KeptResult(
            number: 4, value: 1, unit: .number, unitLabel: nil, scale: 0, shown: "1", understood: "one", turn: F.id)
        let turn = AskTurn(id: F.id, instruction: "i", reply: "r", region: nil, results: [kept])
        #expect(turn.numbers == [4])
        let thread = AskThread(rootID: F.id, kind: .assistant, selection: nil, pin: Exact.pin, turns: [turn])
        #expect(thread.lastResultNumber == 4)
        #expect(AskThread(rootID: F.id, kind: .assistant, selection: nil, pin: Exact.pin).lastResultNumber == 0)
    }
}
