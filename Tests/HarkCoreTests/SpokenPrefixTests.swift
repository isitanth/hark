import Foundation
import HarkCore
import Testing

struct PrefixCase: Sendable, CustomTestStringConvertible {
    let raw: String
    let request: String?
    var testDescription: String { raw.isEmpty ? "(empty)" : raw }
}

/// The spoken prefix on its golden table (M9.2): what whisper writes for "Hark, …", measured in M9.0, and what must
/// stay dictation.
@Suite struct SpokenPrefixTests {
    static let standard: [PrefixCase] = [
        .init(raw: "Hark, quelle est la capitale du Pérou ?", request: "quelle est la capitale du Pérou ?"),
        .init(raw: "Arc, quelle est la capitale du Pérou ?", request: "quelle est la capitale du Pérou ?"),
        .init(
            raw: "Arc écrit un mail pour décliner la réunion de jeudi.",
            request: "écrit un mail pour décliner la réunion de jeudi."),
        .init(raw: "Hark! What is the capital of Peru?", request: "What is the capital of Peru?"),
        .init(raw: "HARK, translate good morning", request: "translate good morning"),
        .init(raw: "Arc , combien de jours", request: "combien de jours"),
        .init(raw: "— Arc, raconte-moi une blague", request: "raconte-moi une blague"),
        .init(raw: "  Hark,   explique TLS  ", request: "explique TLS  "),
        .init(raw: "Hark, -3 fois 4 ?", request: "-3 fois 4 ?"),
        .init(raw: "Arc, « bonjour » en anglais", request: "« bonjour » en anglais"),
        .init(raw: "Hark: #42 en binaire", request: "#42 en binaire"),
        // The prefix alone: an empty request, which the resolver discards.
        .init(raw: "Hark.", request: ""),
        .init(raw: "Arc", request: ""),
        .init(raw: "Hark, ...", request: ""),
        // Stays dictation: not the first word, not the same word, or no fuzzy match.
        .init(raw: "I asked Hark to write this.", request: nil),
        .init(raw: "Hard to say, really.", request: nil),
        .init(raw: "Marc, tu viens ce soir ?", request: nil),
        .init(raw: "Parc de la Tête d'Or", request: nil),
        .init(raw: "Harke, quelle heure", request: nil),
        .init(raw: "Huck, what is the capital of Peru?", request: nil),
        .init(raw: "Hey hark, what time is it?", request: "what time is it?"),
        .init(raw: "Hey, Hark, how are you?", request: "how are you?"),
        .init(raw: "Hello Arc, quelle heure est-il ?", request: "quelle heure est-il ?"),
        .init(raw: "Hey Ark, please translate it in English.", request: "please translate it in English."),
        .init(
            raw: "Salut Arc ! Est-ce que c'est la bise ou la brise ?",
            request: "Est-ce que c'est la bise ou la brise ?"),
        .init(raw: "Ark, quelle heure est-il ?", request: "quelle heure est-il ?"),
        // A greeting alone is dictation.
        .init(raw: "Salut, ça va ?", request: nil),
        .init(raw: "Hey, what time is it?", request: nil),
        .init(raw: "Hey huck, what time is it?", request: nil),
        .init(raw: "Hello, how are you?", request: nil),
        .init(raw: "Arcade Fire est un groupe.", request: nil),
        // A compound is one word, not the prefix and more.
        .init(raw: "Arc-en-ciel au-dessus du lac.", request: nil),
        .init(raw: "Arc-boutant de la cathédrale", request: nil),
        .init(raw: "Hark's settings are open.", request: nil),
        .init(raw: "Hark,quelle heure est-il", request: nil),
        .init(raw: "", request: nil),
    ]

    @Test(arguments: standard)
    func theStandardPrefixes(_ c: PrefixCase) {
        #expect(SpokenPrefix.standard.request(in: c.raw) == c.request)
    }

    /// A two-word prefix the user added wins over its first word, and an accented one matches its plain spelling.
    @Test func aLongerPrefixWinsAndAccentsDoNotMatter() {
        let prefix = SpokenPrefix(["hey", "hey hark", "Harké"])
        #expect(prefix.request(in: "Hey Hark, what time is it?") == "what time is it?")
        #expect(prefix.request(in: "Hey, what time is it?") == "what time is it?")
        #expect(prefix.request(in: "harke ouvre") == "ouvre")
    }

    /// The user's own greeting goes before any name, and never counts by itself.
    @Test func aGreetingComesBeforeAName() {
        let prefix = SpokenPrefix(["hark"], greetings: ["yo"])
        #expect(prefix.request(in: "Yo Hark, what's up?") == "what's up?")
        #expect(prefix.request(in: "Hark, what's up?") == "what's up?")
        #expect(prefix.request(in: "Yo, what's up?") == nil)
    }

    @Test func noPrefixesMatchNothing() {
        #expect(SpokenPrefix([]).request(in: "Hark, quelle heure") == nil)
        #expect(SpokenPrefix(["!!"]).request(in: "!! quelle heure") == nil)
    }
}
