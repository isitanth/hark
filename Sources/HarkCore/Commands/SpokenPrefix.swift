import Foundation

/// The assistant's spoken prefix on the talk key (M9.2): "Arc, quelle est la capitale du Pérou ?" asks the assistant
/// "quelle est la capitale du Pérou ?".
///
/// A prefix matches the transcript's first words exactly once both are normalized (case, accents and punctuation
/// gone), never fuzzily: M9.0 measured that whisper writes a French speaker's "Hark" as "Arc", which a fuzzy rule on
/// "hark" misses while it catches "hard", "Marc" and "parc". Only the start counts: "hark" later in a sentence is text.
/// A greeting may come before a prefix ("Hey Hark, …", "Salut Arc, …"), never alone.
public struct SpokenPrefix: Sendable, Equatable {
    /// Each prefix as normalized words, alone and after each greeting, the longest first.
    private let prefixes: [[Substring]]

    public init(_ prefixes: [String], greetings: [String] = []) {
        let words = { (text: String) in Normalizer.normalize(text).split(separator: " ") }
        let names = prefixes.map(words).filter { !$0.isEmpty }
        let greetings = greetings.map(words).filter { !$0.isEmpty }
        self.prefixes = (names + greetings.flatMap { greeting in names.map { greeting + $0 } })
            .sorted { $0.count > $1.count }
    }

    public init(_ config: AssistantConfig) {
        self.init(config.prefix, greetings: config.greetings)
    }

    public static let standard = SpokenPrefix(AssistantConfig.standard)

    /// What follows the prefix, cut from `raw` so the request keeps its accents and punctuation; nil when `raw` does
    /// not start with a prefix. Empty when nothing but separators follows it: "Hark." alone.
    ///
    /// The prefix ends where a word of the transcript ends: "Arc-en-ciel" and "Hark's" are not "Arc" or "Hark" followed
    /// by more words, and stay dictation.
    public func request(in raw: String) -> String? {
        let tokens = raw.split(whereSeparator: \.isWhitespace)
        for prefix in prefixes {
            var words: [Substring] = []
            var consumed = 0
            for token in tokens {
                guard words.count < prefix.count else { break }
                words += Normalizer.normalize(String(token)).split(separator: " ")
                consumed += 1
            }
            guard words == prefix else { continue }
            let rest = consumed < tokens.count ? raw[tokens[consumed].startIndex...] : ""
            return String(rest.drop { $0.isWhitespace || Self.separators.contains($0) })
        }
        return nil
    }

    /// What may sit between the prefix and the request: "Hark, …", "Arc : …". A quote, a minus sign or a # after it
    /// belongs to the request.
    private static let separators: Set<Character> = [",", ".", ";", ":", "!", "?", "…", "—", "–"]
}
