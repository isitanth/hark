import Foundation
import HarkCore
import Testing

private typealias F = Fixture

@Suite struct ResultLogTests {
    private func reviewed(_ outcomes: [ResultOutcome]) throws -> ExactRun {
        var run = ExactRun(solve: Multi.stub(outcomes))
        try run.ask(read: .success(Exact.sheet))
        try run.on(.planned(F.id, Exact.summary(), reply: "first"))
        return run
    }

    @Test func copyWithAFailedResultCarriesTheFirstFailedReason() throws {
        var run = try reviewed([Multi.total, Multi.zero, Multi.empty])
        try run.on(.askCopy(F.id, "20"))
        try run.on(.copied(F.id))
        let line = try #require(run.lines.last)
        #expect(line.resolution == .textClipboard)
        #expect(line.error == "math_error:division_by_zero")
        #expect(line.context == "region+cells")
        #expect(line.llmModel == Exact.planModel && line.llmMs == 900)
    }

    @Test func copyWithEveryResultComputedHasNoError() throws {
        var run = try reviewed([Multi.total, Multi.gap])
        try run.on(.askCopy(F.id, "20"))
        try run.on(.copied(F.id))
        #expect(run.lines.last?.error == nil)
    }

    @Test func aDiscardedLineKeepsItsOwnReason() throws {
        var run = try reviewed([Multi.total, Multi.zero])
        try run.on(.cancel)
        #expect(run.lines.last?.error == "cancelled")
    }

    @Test func aFollowedUpLineKeepsItsOwnReason() throws {
        var run = try reviewed([Multi.total, Multi.empty])
        try run.followUp()
        let superseded = try #require(run.lines.first { $0.resolution == .discarded })
        #expect(superseded.error == "followed_up")
    }

    @Test func theCutAndAClipboardReasonWin() {
        var context = UtteranceContext(id: F.id, pressedAt: F.pressedAt, intent: Exact.assist)
        context.math = ExactMathContext(results: [Multi.total, Multi.badCell])
        let transcript = Exact.compute
        let inserted = UtteranceRecord(context: context, transcript: transcript, outcome: .textInserted)
        #expect(inserted.error == "plan_invalid:unknown_cell")
        context.capture = CaptureSummary(durationMs: 1800, peakRMS: 0.3, meanRMS: 0.05, reachedMaxDuration: true)
        let cut = UtteranceRecord(context: context, transcript: transcript, outcome: .textInserted)
        #expect(cut.error == "max_duration")
        let secure = UtteranceRecord(
            context: context, transcript: transcript, outcome: .textClipboard(.secureField))
        #expect(secure.error == "secure_field")
    }

    @Test func theLineKeepsFourteenKeys() throws {
        var run = try reviewed([Multi.total, Multi.zero])
        try run.on(.askCopy(F.id, "20"))
        try run.on(.copied(F.id))
        let line = try #require(run.lines.last).jsonLine(timeZone: TimeZone(identifier: "UTC")!)
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        #expect(object.count == 14)
        #expect(!line.contains("the total") && !line.contains("20.00"))
    }
}
