import Foundation
import HarkCore
import Testing

/// What the frozen Python engine writes for a computation or a failure.
enum EngineCode {
    static func unit(_ unit: MathUnit) -> String {
        switch unit {
        case .money(let currency): "M:\(currency.code)"
        case .percent: "P"
        case .count: "k"
        case .hours: "H"
        case .number: "n"
        }
    }

    static func defect(_ failure: MathFailure) -> String {
        switch failure {
        case .plan(let defect): "plan_invalid:\(defect.code)"
        case .math(let defect, _): "math_error:\(defect.rawValue)"
        case .reader(let failure): "reader_failed:\(failure.rawValue)"
        }
    }

    /// Python keeps 34 significant digits and Decimal 38: both agree to 15 places.
    static func same(_ value: Decimal, _ python: String?) -> Bool {
        guard let python, let expected = Decimal(string: python) else { return false }
        return RoundingPolicy.round(value, scale: 15, rule: .halfUp)
            == RoundingPolicy.round(expected, scale: 15, rule: .halfUp)
    }

    /// Whether Swift's outcome is Python's: the same defect code, or the same value, unit and winner.
    static func matches(_ result: Result<Computation, MathFailure>, _ python: MathFixtures.Outcome) -> Bool {
        switch result {
        case .failure(let failure):
            return python.defect == defect(failure)
        case .success(let computation):
            return python.defect == nil && same(computation.value, python.value)
                && python.unit == unit(computation.unit) && python.winner == computation.winner?.label.description
        }
    }
}

@Suite struct EngineParityTests {
    /// Every recorded plan of the 28 cases (G4's runs C, C2, C3 over the split exact-cell listing), evaluated by the
    /// engine, gives the frozen Python engine's result.
    @Test(arguments: MathFixtures.parity)
    func everyRecordedPlanMatchesTheFrozenEngine(_ parityCase: MathFixtures.ParityCase) {
        let sheet = MathFixtures.sheet(parityCase.items)
        for row in parityCase.rows {
            let result = MathEngine.solve(
                reply: row.reply, finishReason: "stop", sheet: sheet, instruction: parityCase.question)
            #expect(EngineCode.matches(result, row.python), "\(row.reply) gave \(result)")
        }
    }

    @Test func theTableHoldsTheTwentyEightCases() {
        #expect(MathFixtures.parity.count == 28)
        #expect(MathFixtures.parity.allSatisfy { !$0.rows.isEmpty })
    }
}
