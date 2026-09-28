import Foundation

/// The assistant's spoken prefix on the talk key (M9.2): "Arc, quelle est la capitale du Pérou ?" asks the assistant
/// "quelle est la capitale du Pérou ?".
///
/// A prefix matches the transcript's first words exactly once both are normalized (case, accents and punctuation
/// gone), never fuzzily: M9.0 measured that whisper writes a French speaker's "Hark" as "Arc", which a fuzzy rule on
/// "hark" misses while it catches "hard", "Marc" and "parc". Only the start counts: "hark" later in a sentence is text.
public struct SpokenPrefix: Sendable, Equatable {
    /// Each prefix as normalized words, the longest first, so "hey hark" wins over "hey".
    private let prefixes: [[Substring]]

    public init(_ prefixes: [String]) {
        self.prefixes = prefixes.map { Normalizer.normalize($0).split(separator: " ") }
            .filter { !$0.isEmpty }
            .sorted { $0.count > $1.count }
    }

    public static let standard = SpokenPrefix(AssistantConfig.defaultPrefix)

    /// What follows the prefix, cut from `raw` so the request keeps its accents and punctuation; nil when `raw` does
    /// not start with a prefix. Empty when nothing but punctuation follows it: "Hark." alone.
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
            guard words.starts(with: prefix) else { continue }
            let rest: String
            if words.count > prefix.count {
                // A token that runs on past the prefix, "Hark,quelle": its words after the prefix start the request,
                // in their normalized form.
                let spill = words[prefix.count...].joined(separator: " ")
                let after = tokens.dropFirst(consumed).joined(separator: " ")
                rest = after.isEmpty ? spill : spill + " " + after
            } else {
                rest = consumed < tokens.count ? String(raw[tokens[consumed].startIndex...]) : ""
            }
            return String(rest.drop { $0.isWhitespace || $0.isPunctuation })
        }
        return nil
    }
}
