import Foundation
import HarkCore
import Testing

private func roles(_ formula: String, _ texts: [String], instruction: String = "Total?") throws -> [Int: CellRole] {
    let computation = try solve(formula, texts, instruction: instruction).get()
    return Dictionary(uniqueKeysWithValues: computation.roles.map { ($0.key.index, $0.value) })
}

private func golden(_ prefix: String) throws -> (MathFixtures.GoldenCase, Computation) {
    let golden = try #require(MathFixtures.golden.first { $0.id.hasPrefix(prefix) })
    let computation = try MathEngine.solve(
        reply: golden.exact, finishReason: "stop", sheet: MathFixtures.sheet(golden.grid), instruction: golden.question
    ).get()
    return (golden, computation)
}

@Suite struct CellRoleTests {
    @Test func paidInvoicesAreAddedAndCreditNotesSubtracted() throws {
        let (golden, computation) = try golden("c01")
        #expect(computation.roles.count == computation.read.count)
        for id in computation.read {
            let text = golden.grid[id.index - 1].text
            #expect(computation.roles[id] == (text.hasPrefix("−") ? .subtracted : .added), "\(text)")
        }
    }

    @Test func theLosingArmsOfAMaxAreCompared() throws {
        let (_, computation) = try golden("c15")
        #expect(computation.roles.values.contains(.compared))
        #expect(computation.roles.values.contains(.added))
        #expect(!computation.roles.values.contains(.subtracted))
    }

    @Test func theLosingArmsOfAnArgminAreComparedLabelsIncluded() throws {
        let found = try roles("ARGMIN(C1 / C2 @ C3, C4 / C5 @ C6)", ["4.00", "2", "Small", "9.00", "3", "Large"])
        #expect(found[1] == .added)
        #expect(found[2] == .subtracted)
        #expect(found[3] == .added)
        #expect(found[4] == .compared && found[5] == .compared && found[6] == .compared)
    }

    @Test(arguments: [
        ("C1 - C2", [1: CellRole.added, 2: .added]), ("C1 - C3", [1: .added, 3: .subtracted]),
        ("C1 + C2", [1: .added, 2: .subtracted]),
        ("C1 / C3", [1: .added, 3: .subtracted]), ("C1 * C4%", [1: .added, 4: .rate]),
        ("COUNT(C1, C2)", [1: .counted, 2: .counted]), ("ABS(C2)", [2: .added]), ("-ABS(C2)", [2: .subtracted]),
        ("C1 * 12", [1: .added]), ("C1 / 12", [1: .added]), ("-C2", [2: .added]), ("C1 - C1 * 12", [1: .added]),
        ("(C1 - C3) / C3 * 100", [1: .added, 3: .subtracted]), ("AVG(C1, C2)", [1: .added, 2: .subtracted]),
        ("MIN(C1, C3)", [1: .compared, 3: .added]),
    ])
    func theSignOfTheContributionDecides(_ formula: String, _ expected: [Int: CellRole]) throws {
        #expect(try roles(formula, ["100 €", "-62.50 €", "50 €", "20 %"]) == expected)
    }

    @Test func aCellReadTwiceKeepsItsFirstRoleWithNoWarning() throws {
        let computation = try solve("C1 - C2 + C2 * 0", ["100", "40"], instruction: "total").get()
        #expect(computation.roles[CellID(2)] == .subtracted)
        #expect(computation.warnings.isEmpty)
    }
}
