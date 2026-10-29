import Foundation
import HarkCore
import Testing

private func c(_ index: Int) -> Formula { .cell(CellID(index)) }
private func n(_ text: String) -> Formula { .constant(Decimal(string: text) ?? .nan) }

private func parse(_ text: String) -> Formula? {
    try? Formula.parse(text).get()
}

private func defect(_ text: String) -> PlanDefect? {
    guard case .failure(let defect) = Formula.parse(text) else { return nil }
    return defect
}

@Suite struct FormulaTests {
    @Test(
        arguments: [
            ("C1", c(1)), ("c12", c(12)), ("12.5", n("12.5")), ("SUM(C1, C2)", .call(.sum, [c(1), c(2)])),
            ("sum(C1,C2)", .call(.sum, [c(1), c(2)])), ("AVG(C1, C2, C3)", .call(.avg, [c(1), c(2), c(3)])),
            ("AVERAGE(C1)", .call(.avg, [c(1)])), ("MIN(C1, C2)", .call(.min, [c(1), c(2)])),
            ("MAX(C1, -C2)", .call(.max, [c(1), .negate(c(2))])), ("ABS(C1)", .call(.abs, [c(1)])),
            ("COUNT(C1, C2, C9)", .count([CellID(1), CellID(2), CellID(9)])), ("ROUND(C1)", .round(c(1), digits: 0)),
            ("ROUND(C1, 2)", .round(c(1), digits: 2)), ("ROUND(C1, 6)", .round(c(1), digits: 6)),
            (
                "ARGMIN(C1 / C2 @ C3, C4 / C5 @ C6)",
                .pick(
                    .argmin,
                    [
                        PickArm(value: .binary(.divide, c(1), c(2)), label: CellID(3)),
                        PickArm(value: .binary(.divide, c(4), c(5)), label: CellID(6)),
                    ])
            ),
            (
                "argmax(C1 @ C2, C3 @ C4)",
                .pick(
                    .argmax,
                    [
                        PickArm(value: c(1), label: CellID(2)), PickArm(value: c(3), label: CellID(4)),
                    ])
            ),
            ("1 + 2 * 3", .binary(.add, n("1"), .binary(.multiply, n("2"), n("3")))),
            ("8 - 3 - 2", .binary(.subtract, .binary(.subtract, n("8"), n("3")), n("2"))),
            ("8 / 4 / 2", .binary(.divide, .binary(.divide, n("8"), n("4")), n("2"))),
            ("-C1", .negate(c(1))), ("--C1", .negate(.negate(c(1)))), ("+C1", c(1)),
            ("-(C1 + C2)", .negate(.binary(.add, c(1), c(2)))), ("C1 * -C2", .binary(.multiply, c(1), .negate(c(2)))),
            ("18%", .rate(n("18"))), ("C9%", .rate(c(9))), ("-18%", .negate(.rate(n("18")))),
            ("(C1 + C2)%", .rate(.binary(.add, c(1), c(2)))), ("C3 * C9%", .binary(.multiply, c(3), .rate(c(9)))),
            ("C1 − C2", .binary(.subtract, c(1), c(2))), ("C1 × C2", .binary(.multiply, c(1), c(2))),
            ("C1 ÷ C2", .binary(.divide, c(1), c(2))), ("SUM(\n\tC1,\r\n C2 )", .call(.sum, [c(1), c(2)])),
            ("SUM(C1,C2)", .call(.sum, [c(1), c(2)])),
        ] as [(String, Formula)])
    func parses(_ text: String, _ formula: Formula) {
        #expect(parse(text) == formula)
    }

    @Test(
        arguments: [
            ("", PlanDefect.noFormula), ("   ", .noFormula), ("C1 C2", .syntax), ("(C1", .syntax), ("C1)", .syntax),
            ("SUM()", .syntax), ("SUM(C1,)", .syntax), ("SUM(1,18)", .syntax), ("1,5", .syntax), ("C1 * 1,18", .syntax),
            ("1e5", .unknownFunction), ("C", .unknownFunction), ("C0", .unknownFunction),
            ("MEDIAN(C1)", .unknownFunction),
            ("FUNCTION(C1)", .unknownFunction), ("IF(C1)", .unknownFunction), ("\"C1\"", .syntax), ("C1 ^ 2", .syntax),
            ("C1 < C2", .syntax), ("ROUND(C1, 7)", .syntax), ("ROUND(C1, C2)", .syntax), ("ROUND(C1, 2.0)", .syntax),
            ("ROUND(C1, 2, 3)", .syntax), ("COUNT(C1 + C2)", .syntax), ("COUNT(3)", .syntax), ("ABS(C1, C2)", .syntax),
            ("ARGMIN(C1 @ C2)", .syntax), ("ARGMIN(C1, C2)", .syntax), ("ARGMIN(C1 @ 3, C2 @ C4)", .syntax),
            ("SUM(C1 @ C2)", .syntax), ("C1 + é", .syntax),
        ] as [(String, PlanDefect)])
    func refuses(_ text: String, _ expected: PlanDefect) {
        #expect(defect(text) == expected)
    }

    @Test func theLengthLimitIsFourThousandCharacters() {
        let base = "C1" + String(repeating: " ", count: 3998)
        #expect(base.count == 4000)
        #expect(parse(base) == c(1))
        #expect(defect(base + " ") == .syntax)
    }

    @Test func theCellLimitIsFiveHundred() {
        let ids = { (count: Int) in "SUM(" + (1...count).map { "C\($0)" }.joined(separator: ",") + ")" }
        #expect(parse(ids(500)) != nil)
        #expect(defect(ids(501)) == .syntax)
    }

    @Test func theDepthLimitIsThirtyTwo() {
        let nested = { (depth: Int) in
            String(repeating: "(", count: depth) + "C1" + String(repeating: ")", count: depth)
        }
        #expect(parse(nested(32)) == c(1))
        #expect(defect(nested(33)) == .syntax)
    }

    @Test func cellsListEveryReferenceInOrderWithRepeatsAndLabels() throws {
        let formula = try #require(parse("SUM(C3, C1) - C3 + ARGMIN(C4 @ C5, C6 @ C7) + COUNT(C8)"))
        #expect(formula.cells.map(\.index) == [3, 1, 3, 4, 5, 6, 7, 8])
    }

    @Test func constantsLeaveRoundsDigitsOut() throws {
        let formula = try #require(parse("ROUND(C1 * 1.18 / 4, 2) + 12"))
        #expect(formula.constants == [Decimal(string: "1.18"), 4, 12])
    }
}
