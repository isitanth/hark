import Foundation

/// A command the matcher found: the verb the utterance starts with, and the app named after it.
public struct CommandMatch: Sendable, Equatable {
    public let command: ResolvedCommand
    /// Normalized, as said.
    public let verb: String
    /// The normalized alias that matched: the app's name or one of its aliases.
    public let alias: String
    /// 1 when the alias was said as written; otherwise the lowest Jaro-Winkler score among its words.
    public let score: Double

    public init(command: ResolvedCommand, verb: String, alias: String, score: Double) {
        self.command = command
        self.verb = verb
        self.alias = alias
        self.score = score
    }
}

/// Decides whether a normalized utterance is a command, by your template (2026-09-23, amended 2026-09-24):
///
///     [opening verb] [fillers skipped] [first app named] (nothing after it)
///
/// The utterance has to start with a verb from `open_verbs`, any language. After it, fillers are skipped and each
/// position is tried against every app name and alias; the first position where one matches decides. The app has to
/// end what was said: "ouvre le Finder pour demain", "ouvre Finder et Safari" and "ouvre Finder quand tu peux" are
/// text, and nothing further along is looked at. Only the app name is matched approximately:
/// each of its words has to be said as written or score at or above the threshold. No verb first, or no app after it,
/// and the utterance is text. At one position, an alias said as written beats one that is close, then the higher score
/// wins, then the alias of more words, then the alias as written over one stripped of its leading fillers, then the
/// earlier one in the file.
///
/// A filler is not skipped when an app name said as written starts with it or runs past it: "open the Clock" opens
/// "The Clock", and "open Clock" still opens "Clock" rather than The Clock without its "the".
///
/// When that finds nothing, the utterance is tried once more without the fillers inside the app name: whisper cuts
/// "TextEdit" into "texte d'édit", whose "d" is a filler (2026-09-29). Only what fails the first pass gets a second.
public struct CommandMatcher: Sendable {
    public typealias Scorer = @Sendable (String, String) -> Double

    private struct Alias: Sendable {
        /// What has to be said: the alias, or the alias without the fillers it starts with.
        let words: [String]
        /// The alias as normalized, for `CommandMatch.alias`.
        let text: String
        let command: Int
        /// The alias stripped of its leading fillers rather than as written.
        let isVariant: Bool
    }

    private let commands: [ResolvedCommand]
    /// Each command's app name, then its aliases, in file order.
    private let aliases: [Alias]
    /// Word sequences, longest first, so a verb of several words wins over one it starts with.
    private let verbs: [[String]]
    private let fillers: [[String]]
    private let threshold: Double
    private let scorer: Scorer

    public init(config: CommandConfig, scorer: @escaping Scorer = JaroWinkler.similarity) {
        let fillers = Self.sequences(config.fillers)
        commands = config.commands.map(\.resolved)
        aliases = config.commands.enumerated().flatMap { index, entry in
            entry.forms.flatMap { written in
                let words = Self.words(Normalizer.normalize(written))
                let text = words.joined(separator: " ")
                return Self.withoutLeadingFillers(words, fillers).enumerated().map { position, variant in
                    Alias(words: variant, text: text, command: index, isVariant: position > 0)
                }
            }
        }
        verbs = Self.sequences(config.openVerbs)
        self.fillers = fillers
        threshold = config.defaults.threshold
        self.scorer = scorer
    }

    public static let empty = CommandMatcher(config: .empty)

    /// `normalized` is `Normalizer.normalize` of what was said. Nil means it is text.
    public func match(_ normalized: String) -> CommandMatch? {
        let words = Self.words(normalized)
        guard let verb = verbs.first(where: { words.starts(with: $0) }) else { return nil }
        if let found = match(words, verb: verb) { return found }
        let compact = withoutInnerFillers(words, after: verb.count)
        return compact.count < words.count ? match(compact, verb: verb) : nil
    }

    /// The words with every single-word filler after the first word that is not one removed: the fillers before the
    /// name stay, for the first pass's rules; the ones inside it go.
    private func withoutInnerFillers(_ words: [String], after start: Int) -> [String] {
        let single = Set(fillers.filter { $0.count == 1 }.map { $0[0] })
        guard let first = words.indices.dropFirst(start).first(where: { !single.contains(words[$0]) }) else {
            return words
        }
        return Array(words[..<(first + 1)]) + words[(first + 1)...].filter { !single.contains($0) }
    }

    private func match(_ words: [String], verb: [String]) -> CommandMatch? {
        var index = verb.count
        while index < words.count {
            // An app named here decides: one of the names that ends the utterance, or text.
            if let filler = fillers.first(where: { words[index...].starts(with: $0) }) {
                if saidThrough(filler.count, at: index, in: words) != nil {
                    guard let found = saidThrough(filler.count, at: index, in: words, ending: true) else { return nil }
                    return CommandMatch(
                        command: commands[found.command], verb: verb.joined(separator: " "), alias: found.text,
                        score: 1)
                }
                index += filler.count
                continue
            }
            if best(at: index, in: words) != nil {
                guard let found = best(at: index, in: words, ending: true) else { return nil }
                return CommandMatch(
                    command: commands[found.alias.command], verb: verb.joined(separator: " "),
                    alias: found.alias.text, score: found.score)
            }
            index += 1
        }
        return nil
    }

    /// `ending`: only the names that reach the last word.
    private func best(at index: Int, in words: [String], ending: Bool = false) -> (alias: Alias, score: Double)? {
        var best: (alias: Alias, score: Double, exact: Bool)?
        for alias in aliases
        where ending ? index + alias.words.count == words.count : index + alias.words.count <= words.count {
            let said = words[index..<index + alias.words.count]
            let exact = said.elementsEqual(alias.words)
            let score = exact ? 1 : zip(said, alias.words).map { $0 == $1 ? 1 : scorer($0, $1) }.min() ?? 0
            guard exact || score >= threshold else { continue }
            if let current = best, !Self.ranks(alias, score, exact, above: current) { continue }
            best = (alias, score, exact)
        }
        return best.map { ($0.alias, $0.score) }
    }

    private static func ranks(
        _ alias: Alias, _ score: Double, _ exact: Bool, above current: (alias: Alias, score: Double, exact: Bool)
    ) -> Bool {
        if exact != current.exact { return exact }
        if score != current.score { return score > current.score }
        if alias.words.count != current.alias.words.count { return alias.words.count > current.alias.words.count }
        return !alias.isVariant && current.alias.isVariant
    }

    /// An alias said as written that starts inside the filler at `index` and runs past its end: the longest one, then
    /// the earliest in the file.
    private func saidThrough(_ fillerLength: Int, at index: Int, in words: [String], ending: Bool = false) -> Alias? {
        var best: Alias?
        for offset in 0..<fillerLength {
            let start = index + offset
            for alias in aliases where !alias.isVariant && alias.words.count > fillerLength - offset {
                guard ending ? start + alias.words.count == words.count : start + alias.words.count <= words.count,
                    words[start..<start + alias.words.count].elementsEqual(alias.words),
                    alias.words.count > (best?.words.count ?? 0)
                else { continue }
                best = alias
            }
            if best != nil { return best }
        }
        return nil
    }

    /// Whether `text` is exactly one filler from `config`, so that it could never be heard as an app: the matcher skips
    /// it before looking. A name of several fillers ("de la", "The The") is heard, said as written, because it runs past
    /// the first filler.
    public static func isOnlyFillers(_ text: String, in config: CommandConfig) -> Bool {
        let said = words(Normalizer.normalize(text))
        return !said.isEmpty && sequences(config.fillers).contains(said)
    }

    /// The alias, then the alias without each filler it starts with, as long as something is left: fillers are
    /// skipped before an app is looked for, so "The Unarchiver" would otherwise need a "the" that is never tried.
    ///
    /// A rest made only of fillers (the second "the" of "The The") is passed over, not indexed: the matcher skips it
    /// before it looks, so it can never be said as itself, and fuzzily it would only catch the words next to a filler
    /// ("their", "them"). Stripping goes on past it, so with fillers "the new" and "the", "The The New" still answers
    /// to "new".
    private static func withoutLeadingFillers(_ words: [String], _ fillers: [[String]]) -> [[String]] {
        var variants = [words]
        var rest = words[...]
        while let filler = fillers.first(where: { rest.starts(with: $0) && rest.count > $0.count }) {
            rest = rest.dropFirst(filler.count)
            if !onlyFillers(rest, fillers) { variants.append(Array(rest)) }
        }
        return variants
    }

    /// Whether `words` is nothing, or nothing but fillers one after another.
    private static func onlyFillers(_ words: ArraySlice<String>, _ fillers: [[String]]) -> Bool {
        var rest = words
        while let filler = fillers.first(where: { rest.starts(with: $0) }) {
            rest = rest.dropFirst(filler.count)
        }
        return rest.isEmpty
    }

    private static func words(_ normalized: String) -> [String] {
        normalized.split(separator: " ").map(String.init)
    }

    /// Every language's words, normalized, without repeats, longest first.
    private static func sequences(_ lists: [String: [String]]) -> [[String]] {
        var seen: Set<[String]> = []
        let all = lists.keys.sorted().flatMap { lists[$0] ?? [] }.map { words(Normalizer.normalize($0)) }
        return all.filter { !$0.isEmpty && seen.insert($0).inserted }.sorted { $0.count > $1.count }
    }
}
