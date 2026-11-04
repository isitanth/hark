import Foundation
import HarkCore
import Testing

private typealias F = Fixture

/// Where the math core (S1) and the pipeline (S2) meet once both landed (M14): the default engine, the composed reply
/// of a turn with a failed result, and a follow-up's request over the same sheet.
@Suite struct WaveOneJoinTests {
    /// Two entries over `Exact.sheet`: a total, and an empty formula (not retried) that fails alone.
    static let totalAndEmpty =
        #"{"results": [{"understood": "the total", "formula": "SUM(C1, C2)", "unit": "none", "unit_label": ""}, "#
        + #"{"understood": "the share", "formula": "", "unit": "none", "unit_label": ""}]}"#

    private func text(_ message: ChatMessage) -> String {
        message.parts.compactMap { part -> String? in
            if case .text(let text) = part { return text }
            return nil
        }.joined()
    }

    @Test func theDefaultEngineSolvesEveryResult() throws {
        var run = ExactRun()
        try run.ask(read: .success(Exact.sheet))
        try run.on(.planned(F.id, Exact.summary(), reply: Self.totalAndEmpty))
        #expect(run.stage == .reviewing)
        #expect(run.math?.numbers == [1, 2])
        #expect(run.math?.kept.map(\.number) == [1])
        #expect(run.math?.kept.first?.value == 20)
    }

    @Test func aFailedResultKeepsItsUnderstoodInTheComposedReply() throws {
        var run = ExactRun()
        try run.ask(read: .success(Exact.sheet))
        try run.on(.planned(F.id, Exact.summary(), reply: Self.totalAndEmpty))
        let reply = try #require(run.context?.reply)
        #expect(reply.hasPrefix("%% ① the total ② the share\n\n"))
        #expect(reply.hasSuffix("\n② not computed"))
    }

    @Test func aFollowUpOverTheSameSheetListsTheKeptResultsAndTheirFormulas() throws {
        var run = ExactRun()
        try run.ask(read: .success(Exact.sheet))
        try run.on(.planned(F.id, Exact.summary(), reply: Self.totalAndEmpty))
        let kept = try #require(run.math?.kept)
        let turn = AskTurn(
            id: F.id, instruction: "The total and the share.", reply: try #require(run.context?.reply), region: nil,
            sheet: Exact.sheet, formula: "SUM(C1, C2)", formulas: ["SUM(C1, C2)"], results: kept)
        let thread = AskThread(
            rootID: F.id, kind: .assistant, selection: nil,
            pin: ProfilePin(profile: LLMClientHarness.profile, requestedModel: "gemma"), turns: [turn])
        let prompt = try #require(
            PlanPrompt.thread(
                thread, current: ("Multiply result one by two.", nil), sheet: Exact.sheet, images: [:]))
        let history = text(prompt.messages[2])
        #expect(prompt.messages[2].role == .assistant)
        #expect(history.hasSuffix("\nFormula RES1: SUM(C1, C2)"))
        let current = text(try #require(prompt.messages.last))
        #expect(current.contains("\n\nEarlier results, computed by Hark:\nRES1 = "))
        #expect(current.contains(#""the total""#))
    }
}
