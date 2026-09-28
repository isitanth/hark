import Foundation
import HarkCore
import Testing

struct SimilarityCase: Sendable, CustomTestStringConvertible {
    let a: String
    let b: String
    let score: Double

    var testDescription: String { "\(a) / \(b)" }
}

/// The published reference values, and the edges.
let similarityCases: [SimilarityCase] = [
    .init(a: "martha", b: "marhta", score: 0.9611),
    .init(a: "dwayne", b: "duane", score: 0.84),
    .init(a: "dixon", b: "dicksonx", score: 0.8133),
    .init(a: "open finder", b: "open finder", score: 1),
    .init(a: "", b: "", score: 1),
    .init(a: "", b: "open", score: 0),
    .init(a: "abc", b: "xyz", score: 0),
    // Seven characters of common prefix, counted as four: capped, 0.95; uncapped it would be 0.975.
    .init(a: "abcdefgh", b: "abcdefgz", score: 0.95),
]

/// Pairs the matcher meets: utterances against forms from the spec's table.
let matcherPairs: [(String, String)] = [
    ("open finder please", "open finder"), ("i need to open finder tomorrow", "open finder"),
    ("open", "open finder"), ("open folder", "open finder"), ("finder", "fynder"), ("ouvre le finder", "finder"),
    ("screenshot region", "screenshot the region"), ("new note", "new notes"), ("a", "ab"), ("abca", "aabc"),
]

@Suite struct JaroWinklerTests {
    @Test(arguments: similarityCases)
    func matchesTheReferenceValues(_ scenario: SimilarityCase) {
        #expect(abs(JaroWinkler.similarity(scenario.a, scenario.b) - scenario.score) < 0.0001)
    }

    @Test func isSymmetricAndStaysInTheUnitInterval() {
        for (a, b) in matcherPairs + similarityCases.map({ ($0.a, $0.b) }) {
            let forward = JaroWinkler.similarity(a, b)
            #expect(forward == JaroWinkler.similarity(b, a), "\(a) / \(b)")
            #expect((0...1).contains(forward), "\(a) / \(b)")
        }
    }

    /// Characters, not UTF-16 units: an emoji or a letter with a combining mark is one position.
    @Test func comparesCharacters() {
        #expect(JaroWinkler.similarity("👋🏽 hi", "👋🏽 hi") == 1)
        #expect(JaroWinkler.similarity("e\u{301}", "\u{e9}") == 1)
    }
}
