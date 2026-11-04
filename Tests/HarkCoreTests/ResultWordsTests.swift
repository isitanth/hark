import Foundation
import HarkCore
import Testing

struct HeldOutRow: Sendable, CustomTestStringConvertible {
    let question: String
    let holds: Bool
    let expected: Bool
    let routes: Bool

    var testDescription: String { question }
}

/// M14.0 C's held-out set, with the column `wordcheck_m14.py` gives it.
private let heldOut: [HeldOutRow] = {
    guard let text = try? MathFixtures.text("wordcheck-m14-heldout.tsv") else { return [] }
    return text.split(separator: "\n").compactMap { line in
        guard !line.hasPrefix("#") else { return nil }
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 5 else { return nil }
        return HeldOutRow(
            question: fields[0], holds: fields[2] == "true", expected: fields[3] == "true", routes: fields[4] == "true")
    }
}()

private let nonMath: [String] = {
    guard let text = try? MathFixtures.text("non-math-set.tsv") else { return [] }
    return text.split(separator: "\n").compactMap { line in
        guard !line.hasPrefix("#"), let question = line.split(separator: "\t").first else { return nil }
        return String(question)
    }
}()

@Suite struct ResultWordsTests {
    @Test(arguments: [
        ("le résultat un", [1]), ("Multiplie le résultat un par 12.", [1]), ("result 2", [2]), ("result two", [2]),
        ("Le résultat deux moins le résultat un.", [2, 1]), ("le résultat numéro trois", [3]), ("result number 4", [4]),
        ("résultat n° 5", [5]), ("result no. 6", [6]), ("le résultat dix-sept", [17]), ("result 20", [20]),
        ("RÉSULTAT 12", [12]), ("le deuxième résultat", [2]), ("la première résultat", [1]), ("the first result", [1]),
        ("the sixth result", [6]), ("le dernier résultat", [3]), ("the last result", [3]), ("① plus ③", [1, 3]),
        ("⑳", [20]), ("Multiply result two by three.", [2]), ("Add result one to the total of this table.", [1]),
        ("result one and the last result", [1, 3]),
    ])
    func phrasesNameResults(_ text: String, _ named: [Int]) {
        #expect(ResultWords.named(in: text, count: 3) == named)
    }

    @Test(arguments: [
        "le résultat", "results 2", "les résultats deux", "result 21", "result 0", "resulted 2", "the result's 2",
        "the seventh result", "Le total des deux tableaux.", "the last one", "result2",
    ])
    func otherWordsNameNone(_ text: String) {
        #expect(ResultWords.named(in: text, count: 3).isEmpty)
    }

    @Test func theLastNamesNoneInAnEmptyConversation() {
        #expect(ResultWords.named(in: "the last result", count: 0).isEmpty)
    }

    @Test func aDecomposedAccentStillReads() {
        #expect(ResultWords.named(in: "le re\u{301}sultat deux", count: 2) == [2])
    }

    @Test func strippingTakesThePhrasesOut() {
        #expect(ResultWords.stripped("Le résultat deux moins le résultat un.") == "Le   moins le  .")
        #expect(ResultWords.stripped("Multiply result two by three.") == "Multiply   by three.")
        #expect(ResultWords.stripped("① × 12") == "  × 12")
        #expect(ResultWords.stripped("le total") == "le total")
    }

    @Test func aNamedResultsNumberIsNoSpokenConstant() {
        #expect(!SpokenNumbers.allowed(in: ResultWords.stripped("le résultat 2 fois trois")).contains(2))
        #expect(SpokenNumbers.allowed(in: ResultWords.stripped("le résultat 2 fois trois")).contains(3))
        #expect(SpokenNumbers.allowed(in: ResultWords.stripped("Multiplie le résultat un par 12.")).contains(12))
    }

    @Test func theEngineRefusesTheNamedNumberAsAConstant() {
        let sheet = MathFixtures.sheet(texts: ["10 €"])
        let solved = MathEngine.solve(
            reply: planReply("C1 * 2", unit: "EUR"), finishReason: "stop", sheet: sheet,
            instruction: "Multiplie le résultat 2 par la cellule.")
        #expect(solved == .failure(.plan(.unspokenConstant("2"))))
    }

    @Test(arguments: heldOut)
    func theHeldOutSetRoutesAsTheModel(_ row: HeldOutRow) {
        #expect(MathIntent.isComputation(row.question, holdsResults: row.holds) == row.routes)
    }

    /// The model's seven departures from the written expectation: "Max" the name and « minimum requis » or "minimum
    /// requirements" (the supplement, kept by the user on 2026-11-04), and the frozen "minus" with no result held.
    @Test func theHeldOutDeparturesAreTheKnownSeven() {
        let departures = heldOut.filter { $0.expected != $0.routes }
        #expect(heldOut.count == 38)
        #expect(departures.count == 7)
        #expect(departures.allSatisfy { !$0.expected && !$0.holds })
        #expect(departures.filter { $0.question.contains("Max") || $0.question.contains("minimum") }.count == 6)
    }

    @Test(arguments: nonMath)
    func noNonMathQuestionRoutesEvenWithResultsHeld(_ question: String) {
        #expect(!MathIntent.isComputation(question, holdsResults: false))
        #expect(!MathIntent.isComputation(question, holdsResults: true))
    }

    @Test func theBlockListStillWins() {
        #expect(!MathIntent.isComputation("Explique le résultat 2.", holdsResults: true))
        #expect(!MathIntent.isComputation("Translate result one.", holdsResults: true))
        #expect(MathIntent.isComputation("Le résultat deux moins le résultat un.", holdsResults: true))
        #expect(!MathIntent.isComputation("Le résultat deux, encore.", holdsResults: false))
        #expect(MathIntent.isComputation("Le résultat deux, encore.", holdsResults: true))
    }

    @Test func theSupplementRoutesMaxAndMin() {
        #expect(MathIntent.isComputation("Donne-moi le max des ventes.", holdsResults: false))
        #expect(MathIntent.isComputation("What's the minimum here?", holdsResults: false))
        #expect(!MathIntent.isComputation("Donne-moi le max des ventes."))
        #expect(!MathIntent.isComputation("Explain the max.", holdsResults: false))
        #expect(!MathIntent.isComputation("maxed out", holdsResults: false))
    }
}
