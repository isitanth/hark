import Foundation
import HarkCore
import Testing

/// A plan reply as the model writes it, with `unit_label` when one is given, as from 0.1.0.
func planReply(
    _ formula: String, unit: String = "none", understood: String = "You want it.", unitLabel: String? = nil
) -> String {
    let escaped = formula.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    let label = unitLabel.map { #", "unit_label": "\#($0)""# } ?? ""
    return #"{"understood": "\#(understood)", "formula": "\#(escaped)", "unit": "\#(unit)"\#(label)}"#
}

func solve(
    _ formula: String, _ texts: [String], unit: String = "none", instruction: String = "How much in total?"
) -> Result<Computation, MathFailure> {
    MathEngine.solve(
        reply: planReply(formula, unit: unit), finishReason: "stop", sheet: MathFixtures.sheet(texts: texts),
        instruction: instruction)
}

private func value(_ formula: String, _ texts: [String], unit: String = "none") -> Decimal? {
    try? solve(formula, texts, unit: unit).get().value
}

private func failure(_ formula: String, _ texts: [String], unit: String = "none", instruction: String = "Total?")
    -> MathFailure?
{
    guard case .failure(let failure) = solve(formula, texts, unit: unit, instruction: instruction) else { return nil }
    return failure
}

private let numbers = ["10", "20", "30", "-5", "2.345", "-2.345", "2.5", "0", "Label", "1,915.3ł"]

/// A unit defect, whatever its note.
private func isUnit(_ failure: MathFailure?) -> Bool {
    guard case .plan(.unit) = failure else { return false }
    return true
}

private func isDeclaredUnit(_ failure: MathFailure?) -> Bool {
    guard case .plan(.declaredUnit) = failure else { return false }
    return true
}

@Suite struct MathEngineTests {
    @Test(arguments: [
        ("SUM(C1, C2, C3)", "60"), ("AVG(C1, C2, C3)", "20"), ("AVERAGE(C1, C2)", "15"), ("MIN(C1, C4)", "-5"),
        ("MAX(C4, C1)", "10"), ("ABS(C4)", "5"), ("ROUND(C5, 2)", "2.35"), ("ROUND(C6, 2)", "-2.35"),
        ("ROUND(C7)", "3"), ("COUNT(C1, C9)", "2"), ("C1 + C2 * C3", "610"), ("(C1 + C2) * C3", "900"),
        ("C3 - C2 - C1", "0"), ("C3 / C1 / 100", "0.03"), ("-C4", "5"), ("C2%", "0.2"), ("C1 * 12", "120"),
    ])
    func values(_ formula: String, _ expected: String) {
        #expect(value(formula, numbers) == Decimal(string: expected))
    }

    @Test func theAverageOfThreeKeepsItsDigits() throws {
        let average = try #require(value("AVG(C1, C2, C3)", ["52 340.10", "52 381.25", "52 631.70"]))
        #expect(RoundingPolicy.round(average, scale: 4, rule: .halfUp) == Decimal(string: "52451.0167"))
    }

    @Test func picksNameTheirWinnerAndATieKeepsTheFirstArm() throws {
        let texts = ["4.00", "Small", "3.00", "Medium", "3.00", "Large"]
        let low = try solve("ARGMIN(C1 @ C2, C3 @ C4, C5 @ C6)", texts).get()
        #expect(low.value == 3)
        #expect(low.winner == Winner(label: CellID(4), read: [CellID(3), CellID(4)]))
        #expect(low.warnings.contains(.tie(CellID(4))))
        let high = try solve("ARGMAX(C1 @ C2, C3 @ C4)", texts).get()
        #expect(high.winner?.label == CellID(2))
        #expect(!high.warnings.contains(.tie(CellID(2))))
    }

    @Test func readIsDistinctInFirstReadOrderWithCountsAndLabels() throws {
        let computation = try solve(
            "ROUND(ABS(C3 - C1), 2) + C3 + COUNT(C9) + ARGMAX(C1 @ C9, C2 @ C9)", numbers
        ).get()
        #expect(computation.read.map(\.index) == [3, 1, 9, 2])
    }

    @Test(arguments: [
        ("C99", MathFailure.plan(.unknownCell)), ("ARGMIN(C1 @ C99, C2 @ C9)", .plan(.unknownCell)),
        ("C9 + C1", .math(.noNumber, cell: CellID(9))), ("C1 + C10", .math(.garbled, cell: CellID(10))),
        ("C1 / C8", .math(.divisionByZero, cell: CellID(8))), ("C1 / (C2 - C2 * 1)", .math(.divisionByZero, cell: nil)),
        ("C1 / 0", .math(.divisionByZero, cell: nil)),
    ])
    func defects(_ formula: String, _ expected: MathFailure) {
        #expect(failure(formula, numbers) == expected)
    }

    @Test func anEmptyCellHasNoNumber() {
        #expect(failure("C1 + C2", ["10", ""]) == .math(.noNumber, cell: CellID(2)))
    }

    @Test func aHugeProductOverflows() {
        let huge = String(repeating: "9", count: 38)
        #expect(failure("C1 * C1 * C1 * C1 * C1", [huge]) == .math(.overflow, cell: nil))
    }

    @Test func theSnapRemovesTheDivisionResidue() throws {
        let computation = try solve("(C1 / 3) * 3 * 1.5", ["0.01"], instruction: "a third, 1.5 times").get()
        #expect(RoundingPolicy.round(computation.value, scale: 20, rule: .halfUp) == Decimal(string: "0.015"))
    }

    // MARK: Units, b2 §4.3, both orders

    @Test(
        arguments: [
            ("C1 + C2", ["10 €", "5"], MathUnit.money(.eur)), ("C2 + C1", ["10 €", "5"], .money(.eur)),
            ("C1 + C2", ["10 %", "5 %"], .percent), ("C1 - C2", ["7h30", "2h"], .hours),
            ("C1 * C2", ["3", "4 €"], .money(.eur)), ("C2 * C1", ["3", "4 €"], .money(.eur)),
            ("COUNT(C1) * C2", ["x", "4 €"], .money(.eur)), ("C2 * COUNT(C1)", ["x", "4 €"], .money(.eur)),
            ("COUNT(C1) * C2", ["x", "2h"], .hours), ("C1 * C2", ["2h", "40 €"], .money(.eur)),
            ("C2 * C1", ["2h", "40 €"], .money(.eur)), ("COUNT(C1) * COUNT(C2)", ["x", "y"], .number),
            ("C1 / C2", ["10 €", "5"], .money(.eur)), ("C1 / C2", ["10 €", "5 €"], .number),
            ("C1 / COUNT(C2)", ["10 €", "x"], .money(.eur)), ("C1 / C2", ["10 €", "2h"], .money(.eur)),
            ("C1 / C2", ["10 %", "5 %"], .number), ("C1 / C2", ["4h", "2h"], .number),
            ("COUNT(C1, C2) / COUNT(C1)", ["x", "y"], .number), ("C1 / COUNT(C2)", ["10", "x"], .number),
            ("C1%", ["20 %"], .number), ("C1 * C2%", ["100 €", "20 %"], .money(.eur)),
            ("ABS(C1)", ["-4 €"], .money(.eur)),
            ("ROUND(C1, 1)", ["4.25 €"], .money(.eur)), ("COUNT(C1)", ["x"], .count),
            ("SUM(C1, C2)", ["£1", "£2"], .money(.gbp)), ("MAX(C1, C2)", ["1 h", "2"], .hours),
        ] as [(String, [String], MathUnit)])
    func unitsCombine(_ formula: String, _ texts: [String], _ unit: MathUnit) throws {
        #expect(try solve(formula, texts).get().unit == unit)
    }

    @Test(arguments: [
        ("C1 + C2", ["10 €", "5 $"]), ("C1 + C2", ["10 €", "5 %"]), ("C2 + C1", ["10 €", "5 %"]),
        ("C1 + C2", ["10 €", "2h"]), ("C1 + COUNT(C2)", ["10 €", "x"]), ("C1 + C2", ["10 %", "2h"]),
        ("C1 * C2", ["10 €", "5 €"]), ("C1 * C2", ["10 €", "5 %"]), ("C2 * C1", ["10 €", "5 %"]),
        ("C1 * C2", ["10 %", "5 %"]), ("C1 * C2", ["2h", "3h"]), ("C2 / C1", ["10 €", "5"]),
        ("C2 / C1", ["10 %", "5"]), ("C1 / C2", ["10 €", "5 $"]), ("C1 / C2", ["10 €", "5 %"]), ("C1%", ["10 €"]),
        ("MIN(C1, C2)", ["10 €", "5 £"]), ("ARGMAX(C1 @ C3, C2 @ C3)", ["10 €", "5 %", "x"]),
    ])
    func unitsAreRefused(_ formula: String, _ texts: [String]) {
        #expect(isUnit(failure(formula, texts)))
    }

    /// The retry's note is the frozen engine's (M13.0 change 1): its codes in the algebra, words for the declared unit.
    @Test(
        arguments: [
            ("C1 + C2", ["10 €", "5 %"], "none", "M:EUR and P cannot be added or compared"),
            ("C1 * C2", ["10 €", "5 %"], "none", "M:EUR times P is refused; write the rate as an item with %"),
            ("C1 * C2", ["2h", "3h"], "none", "H times H is refused"),
            ("C2 / C1", ["10 €", "5"], "none", "n divided by M:EUR is refused"),
            ("C1%", ["10 €"], "none", "M:EUR cannot take %"),
        ] as [(String, [String], String, String)])
    func aUnitDefectNamesItsUnits(_ formula: String, _ texts: [String], _ unit: String, _ note: String) {
        #expect(failure(formula, texts, unit: unit) == .plan(.unit(note)))
    }

    /// A unit the model declared against the cells' is a defect of its own, for the words the user reads.
    @Test(
        arguments: [
            ("C1", ["10 CHF"], "EUR", "the result is an amount in CHF, which is not in the unit list: write none"),
            ("C1", ["10 €"], "USD", "the result is an amount in EUR, not USD"),
            ("C1", ["10 %"], "count", "the result is a percent, not count"),
            ("COUNT(C1)", ["x"], "hours", "the result is a count, not hours"),
        ] as [(String, [String], String, String)])
    func aDeclaredUnitDefectNamesBothUnits(_ formula: String, _ texts: [String], _ unit: String, _ note: String) {
        #expect(failure(formula, texts, unit: unit) == .plan(.declaredUnit(note)))
    }

    // MARK: Declared against computed, b2 §4.4

    @Test(
        arguments: [
            ("C1", ["10 €"], "EUR", true), ("C1", ["10 €"], "USD", false), ("C1", ["10 €"], "percent", false),
            ("C1", ["10 €"], "count", false), ("C1", ["10 €"], "hours", false), ("C1", ["10 €"], "none", true),
            ("C1", ["10 CHF"], "EUR", false), ("C1", ["10 CHF"], "none", true), ("C1", ["10 %"], "EUR", false),
            ("C1", ["10 %"], "percent", true), ("C1", ["10 %"], "count", false), ("C1", ["10 %"], "hours", false),
            ("C1", ["10 %"], "none", true), ("COUNT(C1)", ["x"], "EUR", false), ("COUNT(C1)", ["x"], "percent", false),
            ("COUNT(C1)", ["x"], "count", true), ("COUNT(C1)", ["x"], "hours", false),
            ("COUNT(C1)", ["x"], "none", true),
            ("C1", ["2h"], "EUR", false), ("C1", ["2h"], "percent", false), ("C1", ["2h"], "count", false),
            ("C1", ["2h"], "hours", true), ("C1", ["2h"], "none", true), ("C1", ["10"], "EUR", true),
            ("C1", ["10"], "percent", true), ("C1", ["10"], "count", true), ("C1", ["10"], "hours", true),
            ("C1", ["10"], "none", true), ("C1", ["10", "5 £"], "EUR", false), ("C1", ["10", "5 €"], "EUR", true),
        ] as [(String, [String], String, Bool)])
    func theDeclaredUnitMeetsTheComputedOne(_ formula: String, _ texts: [String], _ unit: String, _ accepted: Bool) {
        let result = solve(formula, texts, unit: unit)
        if accepted {
            #expect((try? result.get()) != nil)
        } else if case .failure(let failure) = result {
            #expect(isDeclaredUnit(failure))
        } else {
            Issue.record("\(formula) declared \(unit) was accepted")
        }
    }

    @Test func aPercentOfLikeUnitsNeedsItsHundred() {
        let texts = ["120 €", "100 €"]
        let hundred = MathFailure.plan(.percentScale)
        #expect(failure("(C1 - C2) / C2", texts, unit: "percent", instruction: "growth?") == hundred)
        #expect(failure("ROUND((C1 - C2) / C2, 2)", texts, unit: "percent", instruction: "growth") == hundred)
        #expect((try? solve("(C1 - C2) / C2 * 100", texts, unit: "percent").get().value) == 20)
    }

    /// A hundred on both sides cancels: the ratio is still a fraction, and the check asks for its hundred.
    @Test func aHundredOnBothSidesIsNoPercent() {
        let texts = ["120 €", "100 €"]
        #expect(
            failure("100 * C1 / (100 * C2)", texts, unit: "percent", instruction: "ratio in percent")
                == .plan(.percentScale))
    }

    /// A hundred already in the numerator makes the ratio a percent: refusing it would send the model a note that
    /// asks for a second hundred.
    @Test(arguments: ["100 * (C1 - C2) / C2", "(C1 - C2) * 100 / C2", "ROUND(100 * (C1 - C2) / C2, 2)"])
    func aHundredInTheNumeratorIsAPercent(_ formula: String) throws {
        let texts = ["120 €", "100 €"]
        #expect(try solve(formula, texts, unit: "percent", instruction: "growth in percent").get().value == 20)
    }

    /// Every quotient of like units, wherever it sits, comes out scaled by exactly one hundred: none in `C1 / C2 - 1`
    /// (0,2 % for 20 %), two in `100 * C1 / (C2 / 100)` (12000 % for 120 %). A rate's `%` is no hundred.
    @Test(
        arguments: [
            ("C1 / C2 - 1", nil), ("(C1 / C2 - 1) * 100", "20"), ("100 * C1 / C2", "120"),
            ("(C1 - C2) / C2 * 100", "20"), ("100 * C1 / (100 * C2)", nil), ("100 * C1 / (C2 / 100)", nil),
            ("C1 / C2 * 100", "120"), ("C3 * C4%", "20"), ("C5 / SUM(C1, C2, C5) * 100", "12"),
            ("100 - C5 / C2 * 100", "70"), ("100 / (C2 / C6)", "50"), ("AVG(C1 / C2, C5 / C2) * 100", "75"),
            ("ROUND((C1 / C2 - 1) * 100, 1)", "20"), ("C1 / C2 / (C5 / C2)", nil), ("C1 / C2 / (C5 / C2) * 100", "400"),
            ("(100 * C1 - 100 * C2) / C2", "20"), ("(100 * C1 - 100 * C2) / C2 * 100", nil),
            ("(100 * C1 - C2) / C2", nil), ("(100 + 100) * C1 / C2", nil),
        ] as [(String, String?)])
    func aPercentIsScaledByExactlyOneHundred(_ formula: String, _ expected: String?) {
        let texts = ["120 €", "100 €", "40", "50 %", "30 €", "50 €"]
        let result = solve(formula, texts, unit: "percent", instruction: "growth in percent")
        if let expected {
            #expect((try? result.get().value) == Decimal(string: expected), "\(result)")
        } else {
            #expect(result == .failure(.plan(.percentScale)), "\(result)")
        }
    }

    /// The three right percents of the 0.1.0 review, as written there: C3 a plain number inside the sum, C9 a rate.
    @Test(arguments: [("C1 / C2 * 100", "60"), ("C3 * C9%", "20"), ("C5 / SUM(C1, C2, C3) * 100", "10")])
    func theReviewsRightPercentsPass(_ formula: String, _ expected: String) throws {
        let texts = ["60 €", "100 €", "40", "x", "20 €", "x", "x", "x", "50 %"]
        let value = try solve(formula, texts, unit: "percent", instruction: "share in percent").get().value
        #expect(value == Decimal(string: expected))
    }

    // MARK: Constants, b2 §6

    @Test(arguments: [
        ("C1 * 1.18 / 4", "Split the bill four ways with an 18% tip", true),
        ("C1 * 0.82", "with an 18% discount", true),
        ("C1 / 4", "partage en quatre", true), ("C1 * 0.5", "la moitié", true), ("C1 / 3", "a third of it", true),
        ("C1 * 25%", "vingt-cinq pour cent", true), ("C1 * 12", "per year", true), ("C1 / 1000", "per kilo", true),
        ("ROUND(C1, 3)", "total", true), ("C1 * 1.2", "total", false), ("C1 * 0 + C1 * 1", "total", true),
        ("C1 + 2418.62", "total", false),
    ])
    func constantsMustBeSpokenOrAConversion(_ formula: String, _ instruction: String, _ accepted: Bool) {
        let result = solve(formula, ["10 €"], instruction: instruction)
        if accepted {
            #expect((try? result.get()) != nil, "\(formula)")
        } else {
            guard case .failure(.plan(.unspokenConstant(let literal))) = result else {
                Issue.record("\(formula) gave \(result)")
                return
            }
            #expect(formula.contains(literal))
        }
    }

    @Test func theRefusedConstantIsCarriedAsWritten() {
        #expect(failure("C1 * 1.20", ["10"]) == .plan(.unspokenConstant("1.20")))
    }

    @Test(arguments: [
        ("SUM(C1, C2) - SUM(C1, C2)", true), ("C1 / C1", true), ("COUNT(C1, C1)", true), ("C1 - C2", false),
        ("ABS(C1 - C1)", true),
    ])
    func degenerateShapes(_ formula: String, _ degenerate: Bool) {
        let result = solve(formula, ["10", "4"])
        #expect((result == .failure(.plan(.degenerate))) == degenerate)
    }

    @Test(arguments: [
        ("SUM(C1, C99) * 7.5", MathFailure.plan(.unknownCell)), ("C1 * 7.5 + C1 / C1", .plan(.unspokenConstant("7.5"))),
        ("MEDIAN(C1) + C99", .plan(.unknownFunction)), ("C1 / C1 + C3", .plan(.degenerate)),
        ("C3 + C1 + 10 €", .plan(.syntax)), ("C3 + C1 + C2", .math(.noNumber, cell: CellID(3))),
    ])
    func theFirstDefectInOrderWins(_ formula: String, _ expected: MathFailure) {
        #expect(failure(formula, ["10 €", "4 %", "label"]) == expected)
    }

    @Test func aCutReplyIsTruncatedBeforeAnythingElse() {
        let result = MathEngine.solve(
            reply: "not json", finishReason: "length", sheet: MathFixtures.sheet(texts: ["1"]), instruction: "")
        #expect(result == .failure(.plan(.truncated)))
    }

    @Test func anEmptyFormulaIsNoFormula() {
        #expect(failure("", ["1"]) == .plan(.noFormula))
    }

    @Test func warningsMarkTheCellsRead() throws {
        let computation = try solve("C1 + C2 + C3 + C4", ["1,915.35ą", "(12.00)", "1.2k", "3.10"]).get()
        #expect(computation.warnings.contains(.parenthesized(CellID(2))))
        #expect(computation.warnings.contains(.approximate))
        let rounded = try solve("C1 / 4", ["189.39 $"], instruction: "split four ways").get()
        #expect(rounded.warnings.contains(.rounded(exact: rounded.value)))
    }

    /// A division's residue is not a rounding: the mark compares with the value snapped as `ExactAnswer.exact` does.
    @Test func aResidueIsNoRounding() throws {
        let computation = try solve("C1 / 3 * 3", ["100,00 €"], instruction: "divide by 3 then times 3").get()
        #expect(!computation.warnings.contains { if case .rounded = $0 { true } else { false } })
    }

    /// The log writes a failure's code alone: no cell text, and not the number a model wrote, which the panel's
    /// `unspokenConstant` keeps.
    @Test func aFailureLogsItsCodeOnly() {
        let marker = "SECRET-7731"
        let failures: [MathFailure] = [
            failure("C1 + C2", [marker, "1"]), failure("C1 * 7731", ["1"], instruction: marker),
        ].compactMap { $0 }
        #expect(failures.count == 2)
        for item in failures {
            #expect(!item.pipelineFailure.code.contains("SECRET"))
            #expect(!item.pipelineFailure.code.contains("7731"))
        }
        #expect(!String(describing: failures[0]).contains("SECRET"))
        for defect in MathDefect.allCases { #expect(!String(describing: defect).contains("SECRET")) }
    }
}

// M14: a plan of several results, and RES references to the conversation's kept results.

private func kept(
    _ number: Int, _ value: String, _ unit: MathUnit, scale: Int = 2, unitLabel: String? = nil
) -> KeptResult {
    let decimal = dec(value)
    return KeptResult(
        number: number, value: decimal, unit: unit, unitLabel: unitLabel, scale: scale, shown: value,
        understood: "result \(number)", turn: UtteranceID(1))
}

private func setReply(_ entries: [(formula: String, unit: String)]) -> String {
    let items = entries.map {
        #"{"understood": "x", "formula": "\#($0.formula)", "unit": "\#($0.unit)", "unit_label": ""}"#
    }
    return #"{"results": [\#(items.joined(separator: ", "))]}"#
}

private func solveAll(
    _ entries: [(formula: String, unit: String)], _ texts: [String], kept: [KeptResult] = [],
    instruction: String = "How much in total?", finish: String? = "stop"
) -> Result<[ResultOutcome], MathFailure> {
    MathEngine.solveAll(
        reply: setReply(entries), finishReason: finish, sheet: MathFixtures.sheet(texts: texts),
        instruction: instruction, kept: kept)
}

private func one(
    _ formula: String, unit: String, _ texts: [String] = [], kept: [KeptResult], instruction: String
) -> Result<Computation, MathFailure> {
    switch solveAll([(formula, unit)], texts, kept: kept, instruction: instruction) {
    case .success(let outcomes): outcomes[0]
    case .failure(let failure): .failure(failure)
    }
}

/// m01's two results, m02's total and exact average: what m09 to m12 refer to.
private let m01 = [kept(1, "89.67", .money(.eur)), kept(2, "29.34", .money(.eur))]
private let m02Average = dec("157353.05") / 3
private let m02 = [
    kept(1, "157353.05", .money(.usd)),
    KeptResult(
        number: 2, value: m02Average, unit: .money(.usd), unitLabel: nil, scale: 2, shown: "52451.02",
        understood: "the average", turn: UtteranceID(1)),
]

@Suite struct SolveAllTests {
    @Test func eachResultIsSolvedAloneInTheModelsOrder() throws {
        let outcomes = try solveAll([("SUM(C1, C2)", "EUR"), ("C3", "EUR"), ("C9", "EUR")], ["10 €", "20 €", "5 €"])
            .get()
        #expect(outcomes.count == 3)
        #expect(try outcomes[0].get().value == 30)
        #expect(try outcomes[1].get().value == 5)
        #expect(outcomes[2] == .failure(.plan(.unknownCell)))
    }

    @Test func aWholeReplyDefectFailsTheSet() {
        #expect(solveAll([("C1", "none")], ["1"], finish: "length") == .failure(.plan(.truncated)))
        #expect(
            MathEngine.solveAll(
                reply: #"{"results": []}"#, finishReason: "stop", sheet: MathFixtures.sheet(texts: ["1"]),
                instruction: "", kept: []) == .failure(.plan(.json)))
    }

    @Test func todaysFlatReplySolvesAsSolveDoes() throws {
        let sheet = MathFixtures.sheet(texts: ["10 €", "20 €"])
        let reply = planReply("SUM(C1, C2)", unit: "EUR")
        let today = MathEngine.solve(reply: reply, finishReason: "stop", sheet: sheet, instruction: "Total?")
        let all = MathEngine.solveAll(reply: reply, finishReason: "stop", sheet: sheet, instruction: "Total?", kept: [])
        #expect(try all.get() == [today])
    }

    @Test func m09MultipliesResultOneByTwelve() throws {
        let computed = try one("RES1 * 12", unit: "EUR", kept: m01, instruction: "Multiplie le résultat un par 12.")
            .get()
        #expect(computed.value == dec("1076.04"))
        #expect(computed.unit == .money(.eur))
        #expect(computed.read.isEmpty && computed.roles.isEmpty)
    }

    @Test func m10SubtractsResultOneFromResultTwo() throws {
        let computed = try one(
            "RES2 - RES1", unit: "EUR", kept: m01, instruction: "Le résultat deux moins le résultat un."
        ).get()
        #expect(computed.value == dec("-60.33"))
        #expect(computed.unit == .money(.eur))
    }

    @Test func m11ReadsTheExactKeptAverage() throws {
        let computed = try one("RES2 * 3", unit: "USD", kept: m02, instruction: "Multiply result two by three.").get()
        // The exact average times three: 157353.05 once the division residue is snapped, not 52451.02 × 3.
        #expect(RoundingPolicy.round(computed.value, scale: 20, rule: .halfUp) == dec("157353.05"))
        #expect(!computed.warnings.contains { if case .rounded = $0 { true } else { false } })
    }

    @Test func m12AddsAResultToANewSheet() throws {
        let computed = try one(
            "RES1 + SUM(C1, C2, C3)", unit: "USD", ["$58,000.00", "$60,558.10", "$58,000.00"], kept: m02,
            instruction: "Add result one to the total of this table."
        ).get()
        #expect(computed.value == dec("333911.15"))
        #expect(computed.read == [CellID(1), CellID(2), CellID(3)])
        #expect(computed.roles[CellID(1)] == .added)
    }

    @Test func anUnknownOrFailedResultIsUnknownResult() {
        // Result 3 failed: it keeps its number, but no `KeptResult`.
        #expect(one("RES3 * 3", unit: "USD", kept: m02, instruction: "three") == .failure(.plan(.unknownResult)))
        #expect(one("RES1", unit: "EUR", kept: [], instruction: "x") == .failure(.plan(.unknownResult)))
    }

    @Test func theUnknownResultCheckComesRightAfterTheCells() {
        #expect(one("RES9 + C9", unit: "EUR", ["1 €"], kept: m01, instruction: "x") == .failure(.plan(.unknownCell)))
        #expect(one("RES9 * 7", unit: "EUR", kept: m01, instruction: "x") == .failure(.plan(.unknownResult)))
    }

    @Test func aCopiedFigureIsAnUnspokenConstant() {
        #expect(
            one("52451.02 * 3", unit: "USD", kept: m02, instruction: "Multiply result two by three.")
                == .failure(.plan(.unspokenConstant("52451.02"))))
    }

    @Test func aResultInCountIsSyntax() {
        #expect(
            one("COUNT(RES1, C1)", unit: "count", ["1"], kept: m02, instruction: "x") == .failure(.plan(.syntax)))
    }

    @Test func aPercentResultIsAPercent() throws {
        let quarter = [kept(1, "25", .percent)]
        let computed = try one(
            "C1 * RES1%", unit: "USD", ["$52,318.75"], kept: quarter, instruction: "a quarter"
        ).get()
        #expect(RoundingPolicy.round(computed.value, scale: 2, rule: .halfUp) == dec("13079.69"))
        #expect(computed.roles[CellID(1)] == .added)
        #expect(one("RES1 + C1", unit: "none", ["3"], kept: quarter, instruction: "x").isSuccess)
        #expect(isUnitFailure(one("RES1 * C1", unit: "none", ["$3"], kept: quarter, instruction: "x")))
    }

    @Test func euroResultsKeepTheirUnit() throws {
        #expect(try one("RES1 * 12", unit: "none", kept: m01, instruction: "12").get().unit == .money(.eur))
        let dollars = [kept(3, "10", .money(.usd))]
        #expect(isUnitFailure(one("RES1 - RES3", unit: "none", kept: m01 + dollars, instruction: "x")))
        #expect(
            one("RES1 * 12", unit: "USD", kept: m01, instruction: "12").failure.map {
                if case .plan(.declaredUnit) = $0 { true } else { false }
            } == true)
    }

    @Test func aReferencedResultsScaleJoinsTheCells() throws {
        let precise = [kept(1, "1.2345", .number, scale: 4)]
        let computed = try one("RES1 * 2", unit: "none", kept: precise, instruction: "2").get()
        let policy = RoundingPolicy.standard
        let empty = MathFixtures.sheet(texts: [])
        let decimals = policy.decimals(for: .number, read: [], sheet: empty, referenced: precise)
        #expect(decimals?.maximum == 4 && decimals?.minimum == 4)
        #expect(computed.value == dec("2.469"))
    }
}

private func isUnitFailure(_ result: Result<Computation, MathFailure>) -> Bool {
    if case .failure(.plan(.unit)) = result { return true }
    return false
}

extension Result {
    fileprivate var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }

    fileprivate var failure: Failure? {
        if case .failure(let failure) = self { return failure }
        return nil
    }
}

private func dec(_ text: String) -> Decimal { Decimal(string: text) ?? .nan }
