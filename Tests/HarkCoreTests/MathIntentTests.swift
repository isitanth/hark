import Foundation
import HarkCore
import Testing

struct WordCheckRow: Sendable, CustomTestStringConvertible {
    let question: String
    let lang: String
    let expected: Bool

    var testDescription: String { question }
}

/// `wordcheck-table.tsv` and `non-math-set.tsv`, frozen in M13.0 and copied as is.
private func rows(_ name: String) -> [WordCheckRow] {
    guard let text = try? MathFixtures.text(name) else { return [] }
    return text.split(separator: "\n").compactMap { line in
        guard !line.hasPrefix("#"), !line.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 2 else { return nil }
        let expected = fields.count > 2 ? fields[2].trimmingCharacters(in: .whitespaces) == "true" : false
        return WordCheckRow(question: fields[0], lang: fields[1], expected: expected)
    }
}

private let table = rows("wordcheck-table.tsv")
private let nonMath = rows("non-math-set.tsv")

@Suite struct MathIntentTests {
    @Test(arguments: table)
    func theFrozenTableHolds(_ row: WordCheckRow) {
        #expect(MathIntent.isComputation(row.question) == row.expected)
    }

    @Test(arguments: nonMath)
    func theNonMathSetStaysOnTodaysPath(_ row: WordCheckRow) {
        #expect(!MathIntent.isComputation(row.question))
    }

    @Test(arguments: MathFixtures.parity)
    func theTwentyEightCaseQuestionsCompute(_ parityCase: MathFixtures.ParityCase) {
        #expect(MathIntent.isComputation(parityCase.question))
    }

    @Test func theSetsAreTheFrozenOnes() {
        #expect(table.count == 130)
        #expect(table.filter(\.expected).count == 68)
        #expect(nonMath.count >= 30)
        #expect(Set(nonMath.map(\.lang)) == ["en", "fr"])
        let recorded = [
            "Qui est le titulaire de la carte ?", "Translate the table's title into English.",
            "What does this page show, in one sentence?", "Which merchant is the hotel?",
        ]
        for question in recorded { #expect(nonMath.contains { $0.question == question }) }
    }

    @Test func theWordListsAreTheFrozenOnes() throws {
        let lists = try JSONDecoder().decode(
            [String: [String]].self, from: try MathFixtures.data("wordcheck-lists.json"))
        #expect(MathIntent.computeEnglish == lists["COMPUTE_EN"])
        #expect(MathIntent.computeFrench == lists["COMPUTE_FR"])
        #expect(MathIntent.fillers == lists["FILLERS"])
        #expect(MathIntent.blockEnglish == lists["BLOCK_EN"])
        #expect(MathIntent.blockFrench == lists["BLOCK_FR"])
    }

    @Test(arguments: [
        ("Combien j'ai payé en tout ?", true), ("En tout cas, merci", false), ("ÇA FAIT COMBIEN ?", true),
        ("Traduis le total en anglais", false), ("What’s the total?", true), ("Explain the total", false),
        ("Quel est le montant TTC ?", true), ("Hello", false), ("", false),
    ])
    func normalizationAndBlocks(_ question: String, _ expected: Bool) {
        #expect(MathIntent.isComputation(question) == expected)
    }
}
