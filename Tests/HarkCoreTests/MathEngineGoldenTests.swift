import Foundation
import HarkCore
import Testing

/// The two golden sets of the 20 cases of 2026-10-26 (b2 §13, §14), on the listings their plans were written against.
@Suite struct MathEngineGoldenTests {
    /// The exact-cell plans (C) over their oracle grids give each case's answer, rounded for display.
    @Test(arguments: MathFixtures.golden)
    func theExactCellPlansGiveTheAnswers(_ golden: MathFixtures.GoldenCase) throws {
        let sheet = MathFixtures.sheet(golden.grid)
        let computation = try MathEngine.solve(
            reply: golden.exact, finishReason: "stop", sheet: sheet, instruction: golden.question
        ).get()
        let unit = RoundingPolicy.displayUnit(
            computation.unit, declared: computation.plan.unit, value: computation.value)
        let shown = RoundingPolicy.standard.round(computation.value, unit: unit, read: computation.read, sheet: sheet)
        #expect(shown == Decimal(string: golden.expected.value))
        #expect(EngineCode.matches(.success(computation), golden.exactPython))
        #expect(
            !computation.warnings.contains {
                if case .scaleMismatch = $0 { return true }
                return false
            }, "no false mark")
    }

    /// b2 §14: the plain-Vision plans over their readings. No wrong total without a failure or a mark; c12 needs the
    /// sheet builder's split (S2's tests own it).
    @Test(arguments: MathFixtures.golden.filter { !$0.id.hasPrefix("c12") })
    func thePlainVisionPlansGiveNoWrongTotalWithoutAMark(_ golden: MathFixtures.GoldenCase) {
        let sheet = MathFixtures.sheet(golden.vision)
        let result = MathEngine.solve(
            reply: golden.plain, finishReason: "stop", sheet: sheet, instruction: golden.question)
        let expected: [String: String] = [
            "c04": "math_error:garbled", "c05": "math_error:garbled", "c16": "math_error:garbled",
            "c06": "math_error:no_number", "c08": "math_error:no_number", "c18": "math_error:no_number",
            "c20": "plan_invalid:degenerate",
        ]
        let key = String(golden.id.prefix(3))
        switch result {
        case .failure(let failure):
            #expect(EngineCode.defect(failure) == expected[key], "\(golden.id)")
        case .success(let computation):
            #expect(expected[key] == nil, "\(golden.id) computed \(computation.value)")
            let unit = RoundingPolicy.displayUnit(
                computation.unit, declared: computation.plan.unit, value: computation.value)
            let shown = RoundingPolicy.standard.round(
                computation.value, unit: unit, read: computation.read, sheet: sheet)
            let right = shown == Decimal(string: golden.expected.value)
            let marked = computation.warnings.contains {
                if case .scaleMismatch = $0 { return true }
                if case .doubt = $0 { return true }
                return false
            }
            #expect(right || marked, "\(golden.id) shows \(shown) unmarked")
            if key == "c07" { #expect(marked) }
            if key == "c19" { #expect(right && marked) }
        }
    }
}
