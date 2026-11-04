import Foundation
import HarkCore
import Testing

private typealias F = Fixture

/// Follow-up words the frozen check sends to a free ask, unless a kept result is named.
private enum Words {
    static let reuse = Transcript(raw: "Take result one twelve times over.", tier: .small)
    static let explain = Transcript(raw: "Explain result one.", tier: .small)
}

@Suite struct ResultRoutingTests {
    /// Turn 1 answered with one kept result; the words name result one when they say "result one".
    private func answered() throws -> ExactRun {
        var run = ExactRun(solve: Multi.stub([Multi.total]))
        run.reducer.namedResults = { text, count in text.contains("result one") && count >= 1 ? [1] : [] }
        try run.ask(read: .success(Exact.sheet))
        try run.on(.planned(F.id, Exact.summary(), reply: "first"))
        return run
    }

    @Test func theWordsAloneDoNotCompute() {
        #expect(!MathIntent.isComputation(Words.reuse.raw))
        #expect(!MathIntent.isComputation(Words.explain.raw))
    }

    @Test func aNamedResultGoesToTheExactPathOverTheLatestSheet() throws {
        var run = try answered()
        try run.followUp(Words.reuse)
        #expect(run.stage == .planning)
        guard case .plan(_, _, let sheet, _, let thread, _) = run.effects.last else { throw Missing() }
        #expect(sheet == Exact.sheet)
        #expect(thread?.keptResults.map(\.number) == [1])
        #expect(run.context?.sentContext == "region+cells+history")
    }

    @Test func aNamedResultPlansOverANewFrameWithNoAmount() throws {
        var run = try answered()
        try run.followUp(Words.reuse, framed: true, read: .success(Exact.wordsOnly))
        #expect(run.stage == .planning)
        guard case .plan(_, _, let sheet, _, _, _) = run.effects.last else { throw Missing() }
        #expect(sheet == Exact.wordsOnly)
    }

    @Test func aNamedResultWaitsForTheReadAndPlansOverAnySheet() throws {
        var run = try answered()
        try run.followUp(Words.reuse, framed: true)
        #expect(run.stage == .reading)
        try run.on(.regionRead(Exact.second, Exact.wordsOnly))
        #expect(run.stage == .planning)
    }

    @Test func aNewFrameWhoseReadFailsStillStops() throws {
        var run = try answered()
        try run.followUp(Words.reuse, framed: true, read: .failure(.vision))
        #expect(run.stage == .mathFailed(.reader(.vision)))
    }

    @Test func theBlockListWins() throws {
        var run = try answered()
        try run.followUp(Words.explain)
        #expect(run.stage == .generating)
    }

    @Test func noKeptResultNamesNone() throws {
        var run = ExactRun()
        run.reducer.namedResults = { _, _ in [1] }
        try run.ask(Words.reuse, read: .success(Exact.sheet))
        #expect(run.stage == .generating)
    }

    @Test func unnamedWordsWithNoAmountStayFree() throws {
        var run = try answered()
        try run.followUp(
            Transcript(raw: "How much in total?", tier: .small), framed: true, read: .success(Exact.wordsOnly))
        #expect(run.stage == .generating)
    }
}
