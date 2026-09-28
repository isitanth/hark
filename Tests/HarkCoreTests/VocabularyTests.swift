import Foundation
import HarkCore
import Testing

struct SanitizeCase: Sendable, CustomTestStringConvertible {
    let name: String
    let terms: [String]
    let sanitized: [String]

    var testDescription: String { name }
}

private let longest = String(repeating: "k", count: Vocabulary.maximumTermLength)
private let tooLong = longest + "k"
/// 64 characters, 128 scalars: the limit counts what the user sees, not the encoding.
private let longestDecomposed = String(repeating: "e\u{0301}", count: Vocabulary.maximumTermLength)

/// `Character.isWhitespace` was checked for the separators below: tab, newline, CRLF, U+00A0, U+202F, U+2028 and
/// U+3000 are whitespace; U+200B, the zero-width space, is not.
let sanitizeCases: [SanitizeCase] = [
    .init(name: "nothing", terms: [], sanitized: []),
    .init(name: "trimmed", terms: ["  Hark ", "\tKubernetes\n"], sanitized: ["Hark", "Kubernetes"]),
    .init(
        name: "inner whitespace collapses to one space",
        terms: ["Visual   Studio \t Code", "Émile\u{00A0}Zola", "Jean\u{202F}Jaurès", "two\r\nlines", "a\u{2028}b"],
        sanitized: ["Visual Studio Code", "Émile Zola", "Jean Jaurès", "two lines", "a b"]),
    .init(
        name: "a zero-width space is not whitespace", terms: ["Hark\u{200B}Core"], sanitized: ["Hark\u{200B}Core"]),
    .init(name: "empties dropped", terms: ["", " ", "\n\t", "\u{3000}", "Hark"], sanitized: ["Hark"]),
    .init(
        name: "duplicates ignoring case keep the first spelling",
        terms: ["macOS", "MacOS", "MACOS", "École", "école", "Hark"], sanitized: ["macOS", "École", "Hark"]),
    .init(
        name: "a duplicate is found after cleaning", terms: ["Visual Studio", " visual   studio "],
        sanitized: ["Visual Studio"]),
    .init(
        name: "canonically equivalent spellings are duplicates", terms: ["Émile", "E\u{0301}mile"],
        sanitized: ["Émile"]),
    .init(
        name: "the longest term is kept and one more character is dropped", terms: [tooLong, longest, "Hark"],
        sanitized: [longest, "Hark"]),
    .init(name: "length counts characters", terms: [longestDecomposed], sanitized: [longestDecomposed]),
    .init(
        name: "length is measured after cleaning", terms: ["  " + longest + "  "], sanitized: [longest]),
    .init(
        name: "a dropped over-long term does not shadow a later short spelling", terms: [tooLong, "Kk"],
        sanitized: ["Kk"]),
]

/// Distinct, comma-free terms of an exact length, so the budget arithmetic in the tests is the whole story.
private func term(_ index: Int, length: Int) -> String {
    let stem = "term \(index) "
    return stem + String(repeating: "x", count: length - stem.count)
}

@Suite struct VocabularyTests {
    @Test(arguments: sanitizeCases)
    func sanitized(_ expected: SanitizeCase) {
        #expect(Vocabulary.sanitized(expected.terms) == expected.sanitized)
    }

    @Test func sanitizingTwiceChangesNothing() {
        for expected in sanitizeCases {
            #expect(Vocabulary.sanitized(expected.sanitized) == expected.sanitized)
        }
    }

    /// The cap counts kept terms: empties and duplicates before it do not use up places.
    @Test func theCapKeepsTheFirstHundredKeptTerms() {
        let distinct = (0..<150).map { "word\($0)" }
        #expect(Vocabulary.sanitized(distinct) == Array(distinct.prefix(Vocabulary.maximumTerms)))

        let noisy = distinct.flatMap { [$0, "", $0.uppercased()] }
        #expect(Vocabulary.sanitized(noisy) == Array(distinct.prefix(Vocabulary.maximumTerms)))
    }

    /// Fifteen 50-character terms cost 15 x 50 + 14 separators = 778 of the 793 the label leaves; a sixteenth after
    /// ", " has 13 characters left. A term that does not fit ends the prompt even when a shorter one behind it would.
    @Test(arguments: [
        (13, [String](), 16),
        (14, [], 15),
        (14, ["z"], 15),
    ])
    func termsInPromptAgreesWithThePrompt(_ lastLength: Int, _ behind: [String], _ fitting: Int) throws {
        let terms = (0..<15).map { term($0, length: 50) } + [term(15, length: lastLength)] + behind
        #expect(Vocabulary.sanitized(terms) == terms)

        let count = Vocabulary.termsInPrompt(terms)
        let prompt = try #require(DecodeSpec.prompt(from: terms))
        #expect(count == fitting)
        #expect(prompt == DecodeSpec.promptLabel + terms.prefix(fitting).joined(separator: ", ") + ".")
        #expect(prompt.dropFirst(DecodeSpec.promptLabel.count).dropLast().components(separatedBy: ", ").count == count)
        #expect(prompt.count <= DecodeSpec.promptCharacterBudget + 1)
        if fitting == 16 {
            #expect(prompt.count == DecodeSpec.promptCharacterBudget + 1)
        }
    }

    @Test func aVocabularyThatFitsIsPromptedWhole() {
        let terms = ["Hark", "Kubernetes", "Émile Zola"]
        #expect(Vocabulary.termsInPrompt(terms) == 3)
        #expect(DecodeSpec.prompt(from: terms) == "Terms: Hark, Kubernetes, Émile Zola.")
        #expect(Vocabulary.termsInPrompt([]) == 0)
        #expect(DecodeSpec.prompt(from: []) == nil)
    }

    /// The cap and the budget are independent: a full vocabulary of the longest terms is mostly cut by the budget.
    @Test func aFullVocabularyOfLongTermsIsCutByTheBudget() {
        let terms = Vocabulary.sanitized((0..<200).map { term($0, length: Vocabulary.maximumTermLength) })
        #expect(terms.count == Vocabulary.maximumTerms)
        // Twelve cost 64 + 11 x 66 = 790 of 793; a thirteenth would reach 856.
        #expect(Vocabulary.termsInPrompt(terms) == 12)
    }
}
