import Foundation
import HarkCore
import Testing

private func decode(_ reply: String, finish: String? = "stop") -> Result<CalculationPlan, PlanDefect> {
    CalculationPlan.decode(reply, finishReason: finish)
}

@Suite struct CalculationPlanTests {
    @Test func aValidPlanDecodes() throws {
        let plan = try decode(#"{"understood": "You want the total.", "formula": "SUM(C1, C2)", "unit": "EUR"}"#).get()
        #expect(plan == CalculationPlan(understood: "You want the total.", formula: "SUM(C1, C2)", unit: .eur))
    }

    @Test(arguments: [
        #"{"formula": "C1", "unit": "EUR"}"#, #"{"understood": "x", "unit": "EUR"}"#,
        #"{"understood": "x", "formula": "C1"}"#, #"{"understood": 3, "formula": "C1", "unit": "EUR"}"#,
        #"{"understood": "x", "formula": ["C1"], "unit": "EUR"}"#,
        #"{"understood": "x", "formula": "C1", "unit": "CHF"}"#,
        #"{"understood": "x", "formula": "C1", "unit": "EUR", "kind": "sum"}"#,
        #"Here is the plan: {"understood": "x", "formula": "C1", "unit": "EUR"}"#,
        #"{"understood": "x", "formula": "C1", "unit": "EUR"} Done."#, "", "[]", "null",
        #"{"understood": "x", "formula": "C1", "unit": null}"#,
    ])
    func refusesWhatTheSchemaDoesNotAllow(_ reply: String) {
        #expect(decode(reply) == .failure(.json))
    }

    @Test(arguments: [
        "```json\n{\"understood\": \"x\", \"formula\": \"C1\", \"unit\": \"none\"}\n```",
        "```\n{\"understood\": \"x\", \"formula\": \"C1\", \"unit\": \"none\"}\n```",
        "  {\"understood\": \"x\", \"formula\": \"C1\", \"unit\": \"none\"}\n",
    ])
    func oneSurroundingFenceIsRemoved(_ reply: String) {
        #expect((try? decode(reply).get())?.formula == "C1")
    }

    @Test func unicodeEscapesDecode() throws {
        let plan = try decode(#"{"understood": "Vous voulez le total à régler 😀.", "formula": "C1", "unit": "none"}"#)
            .get()
        #expect(plan.understood == "Vous voulez le total à régler 😀.")
    }

    @Test func anEmptyFormulaDecodesAndTheEngineCallsItNoFormula() throws {
        let reply = #"{"understood": "Not a calculation.", "formula": "", "unit": "none"}"#
        #expect(try decode(reply).get().formula.isEmpty)
        let result = MathEngine.solve(
            reply: reply, finishReason: "stop", sheet: MathFixtures.sheet(texts: ["1"]), instruction: "")
        #expect(result == .failure(.plan(.noFormula)))
    }

    @Test func aCutReplyIsTruncatedEvenWhenItParses() {
        #expect(
            decode(#"{"understood": "x", "formula": "C1", "unit": "none"}"#, finish: "length") == .failure(.truncated))
    }

    static let defects: [PlanDefect] = [
        .json, .truncated, .syntax, .unknownFunction, .unknownCell, .unspokenConstant("2418.62"), .noFormula,
        .unit("the result is an amount in CHF, which is not in the unit list: write none"), .degenerate,
    ]

    @Test(arguments: defects)
    func aNoteExactlyWhenRetryable(_ defect: PlanDefect) {
        #expect(defect.isRetryable == !defect.correction.isEmpty)
        #expect(defect.isRetryable == ![.truncated, .noFormula].contains(defect))
        #expect(!defect.correction.contains("C1"))
        #expect(!String(describing: defect).contains("Total"))
    }

    @Test func theNotesNameARuleNeverACell() {
        #expect(PlanDefect.json.correction == "reply with one JSON object with understood, formula and unit only")
        #expect(PlanDefect.unit("multiply by 100 for a percent").correction == "multiply by 100 for a percent")
        #expect(
            PlanDefect.unspokenConstant("0.2").correction == "0.2 is not a number the user said: refer to its item")
        #expect(PlanDefect.degenerate.correction == "the formula cancels itself out")
    }

    @Test(arguments: defects)
    func theCodeIsTheReasonOnly(_ defect: PlanDefect) {
        #expect(!defect.code.contains("2418"))
        #expect(MathFailure.plan(defect).pipelineFailure == .planInvalid(defect))
    }
}
