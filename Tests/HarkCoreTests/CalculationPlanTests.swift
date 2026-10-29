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
        .json, .truncated, .syntax, .unknownFunction, .unknownCell, .unspokenConstant("2418.62"), .noFormula, .unit,
        .degenerate,
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
        #expect(PlanDefect.unit.correction == "the unit does not match the cells (multiply by 100 for a percent)")
        #expect(PlanDefect.degenerate.correction == "the formula cancels itself out")
    }

    @Test(arguments: defects)
    func theCodeIsTheReasonOnly(_ defect: PlanDefect) {
        #expect(!defect.code.contains("2418"))
        #expect(MathFailure.plan(defect).pipelineFailure == .planInvalid(defect))
    }
}

@Suite struct PlanSchemaTests {
    private func object() throws -> [String: Any] {
        let data = try #require(CalculationPlan.schema.json.data(using: .utf8))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func theSchemaIsTheFrozenOneByteForByte() throws {
        #expect(CalculationPlan.schema.name == "plan")
        #expect(CalculationPlan.schema.json == (try MathFixtures.text("plan-schema.json")))
    }

    @Test func itUsesOnlyEveryEnforcersSubset() throws {
        let allowed: Set<String> = ["type", "properties", "required", "enum", "additionalProperties"]
        let schema = try object()
        #expect(Set(schema.keys).isSubset(of: allowed))
        #expect(schema["additionalProperties"] as? Bool == false)
        let properties = try #require(schema["properties"] as? [String: [String: Any]])
        for property in properties.values { #expect(Set(property.keys).isSubset(of: ["type", "enum"])) }
        #expect(schema["required"] as? [String] == ["understood", "formula", "unit"])
    }

    @Test func understoodComesFirst() throws {
        let json = CalculationPlan.schema.json
        let order = ["\"understood\"", "\"formula\"", "\"unit\""].compactMap { json.range(of: $0)?.lowerBound }
        #expect(order.count == 3 && order == order.sorted())
    }

    @Test func theEnumIsTheResultUnits() throws {
        let properties = try #require(try object()["properties"] as? [String: [String: Any]])
        #expect(properties["unit"]?["enum"] as? [String] == ResultUnit.allCases.map(\.rawValue))
    }
}

@Suite struct SpokenNumbersTests {
    @Test(arguments: [
        ("Split the bill four ways with an 18% tip", ["4", "18"]), ("partage en quatre", ["4"]),
        ("la moitié", ["2", "0.5"]), ("a third of it", ["3"]), ("a quarter", ["4", "0.25"]),
        ("vingt-cinq pour cent", ["25", "20", "5", "100"]), ("soixante et onze", ["71", "60", "11"]),
        ("quatre-vingt-dix", ["90"]), ("soixante-dix", ["70"]), ("twenty-five", ["25"]), ("a dozen", ["12"]),
        ("2,5 fois", ["2.5"]), ("1.5 times", ["1.5"]), ("12 %", ["12"]), ("ninety-nine", ["99"]),
        ("trois-cents", ["300", "3", "100"]), ("deux mille", ["2", "1000"]), ("twice", ["2"]),
    ])
    func spokenNumbersAreRead(_ instruction: String, _ expected: [String]) {
        let spoken = SpokenNumbers.spoken(in: instruction)
        for text in expected {
            let number = Decimal(string: text) ?? .nan
            #expect(spoken.contains { $0 == number }, "\(instruction) lacks \(text)")
        }
    }

    @Test func eachSpokenNumberBringsItsPercentForms() {
        let allowed = SpokenNumbers.allowed(in: "with an 18% tip")
        for text in ["18", "0.18", "1.18", "0.82", "0", "1", "100", "1000", "12", "52", "7", "24", "60", "365", "3600"]
        {
            let number = Decimal(string: text) ?? .nan
            #expect(allowed.contains { $0 == number }, "\(text)")
        }
    }

    @Test func aTranscriptWithNoNumberAllowsTheTableOnly() {
        #expect(SpokenNumbers.spoken(in: "How much did I pay?").isEmpty)
        #expect(SpokenNumbers.allowed(in: "How much did I pay?").count == SpokenNumbers.conversions.count + 2)
    }
}
