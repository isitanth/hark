import Foundation

/// The localization gate: pure functions over (sources, catalog), so the real tree and small fixtures
/// go through the same checks. Every function returns problems as strings; an empty array is a pass.
enum StringsGate {
    struct Source: Sendable {
        var path: String
        var text: String
    }

    /// One `L("…")` key as written, with each `\(path)` replaced by `placeholder`.
    struct UsedKey: Hashable, Sendable {
        var template: String
        var location: String
    }

    static let placeholder = "\u{1}"

    // MARK: Sources

    /// Every `L(` call in `sources`: the keys it can resolve, and a problem for each call that is not
    /// one plain string literal whose interpolations are identifiers or member paths.
    static func scan(_ sources: [Source]) -> (keys: [UsedKey], problems: [String]) {
        var keys: [UsedKey] = []
        var problems: [String] = []
        for source in sources {
            let chars = Array(source.text)
            var index = 0
            while index < chars.count {
                guard isCall(chars, at: index) else {
                    index += 1
                    continue
                }
                let location = "\(source.path):\(line(of: index, in: chars))"
                switch literal(chars, from: index + 2) {
                case .success(let (template, end)):
                    keys.append(UsedKey(template: template, location: location))
                    index = end
                case .failure(let reason):
                    problems.append("\(location): L( \(reason.text)")
                    index += 2
                }
            }
        }
        return (keys, problems)
    }

    struct Reason: Error {
        var text: String
    }

    /// `L(` at `index`, not part of a longer identifier (`URL(`) and not the declaration `func L(`.
    private static func isCall(_ chars: [Character], at index: Int) -> Bool {
        guard index + 1 < chars.count, chars[index] == "L", chars[index + 1] == "(" else { return false }
        if index > 0, isIdentifier(chars[index - 1]) { return false }
        let before = String(chars[max(0, index - 5)..<index])
        return before != "func "
    }

    private static func isIdentifier(_ char: Character) -> Bool {
        char == "_" || char.isLetter || char.isNumber
    }

    private static func line(of index: Int, in chars: [Character]) -> Int {
        chars[..<index].reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
    }

    /// Parses `"…")` starting at `start` (just after `L(`), returning the template and the index past `)`.
    private static func literal(_ chars: [Character], from start: Int) -> Result<(String, Int), Reason> {
        var index = start
        guard index < chars.count, chars[index] == "\"" else {
            return .failure(Reason(text: "argument is not a string literal"))
        }
        if index + 2 < chars.count, chars[index + 1] == "\"", chars[index + 2] == "\"" {
            return .failure(Reason(text: "argument is a multi-line literal"))
        }
        index += 1
        var template = ""
        while index < chars.count {
            let char = chars[index]
            switch char {
            case "\n":
                return .failure(Reason(text: "literal is not closed on its line"))
            case "%":
                return .failure(Reason(text: "key contains a literal %, which reads as a format specifier"))
            case "\"":
                guard index + 1 < chars.count, chars[index + 1] == ")" else {
                    return .failure(Reason(text: "argument is more than one string literal"))
                }
                return .success((template, index + 2))
            case "\\":
                guard index + 1 < chars.count else { return .failure(Reason(text: "literal is not closed")) }
                let next = chars[index + 1]
                if next == "(" {
                    guard let close = chars[(index + 2)...].firstIndex(of: ")") else {
                        return .failure(Reason(text: "interpolation is not closed"))
                    }
                    let expression = String(chars[(index + 2)..<close])
                    guard isMemberPath(expression) else {
                        return .failure(Reason(text: "interpolation \\(\(expression)) is not an identifier path"))
                    }
                    template.append(placeholder)
                    index = close + 1
                    continue
                }
                guard let unescaped = simpleEscapes[next] else {
                    return .failure(Reason(text: "key uses the escape \\\(next)"))
                }
                template.append(unescaped)
                index += 2
            default:
                template.append(char)
                index += 1
            }
        }
        return .failure(Reason(text: "literal is not closed"))
    }

    private static let simpleEscapes: [Character: Character] = [
        "n": "\n", "t": "\t", "\"": "\"", "\\": "\\", "'": "'", "0": "\0",
    ]

    /// `line`, `device.name`, `self.x`: identifiers joined by dots, nothing else.
    static func isMemberPath(_ expression: String) -> Bool {
        let parts = expression.split(separator: ".", omittingEmptySubsequences: false)
        return !parts.isEmpty
            && parts.allSatisfy { part in
                guard let first = part.first, first == "_" || first.isLetter else { return false }
                return part.allSatisfy { $0 == "_" || ($0.isASCII && ($0.isLetter || $0.isNumber)) }
            }
    }
}

extension StringsGate {
    // MARK: Format specifiers

    struct Specifier: Hashable, Comparable, Sendable, CustomStringConvertible {
        /// 1-based argument position: explicit (`%2$@`) or implicit, numbered left to right.
        var position: Int
        /// Length modifier and conversion: `@`, `lld`, `d`, `lf`.
        var type: String

        static func < (lhs: Specifier, rhs: Specifier) -> Bool {
            (lhs.position, lhs.type) < (rhs.position, rhs.type)
        }

        var description: String { "\(position)$\(type)" }
    }

    /// Flags, width, precision, length, conversion; `%%` is a literal percent. Computed: `Regex` is not
    /// `Sendable`, so it cannot be a stored static.
    private static var specifierPattern: Regex<(Substring, position: Substring?, type: Substring?)> {
        #/%(?:(?<position>[1-9][0-9]*)\$)?[-+ #0']*(?:[0-9]+|\*)?(?:\.(?:[0-9]+|\*))?(?<type>(?:hh|h|ll|l|q|L|z|t|j)?[@dDiuUxXoOfFeEgGaAcCsSp])|%%/#
    }

    /// The specifiers in `format`, sorted by position, or nil when a `%` starts no valid specifier.
    static func specifiers(in format: String) -> [Specifier]? {
        var result: [Specifier] = []
        var implicit = 0
        var matchedPercents = 0
        for match in format.matches(of: specifierPattern) {
            matchedPercents += format[match.range].filter { $0 == "%" }.count
            guard let type = match.output.type else { continue }
            if let explicit = match.output.position {
                guard let position = Int(explicit) else { return nil }
                result.append(Specifier(position: position, type: String(type)))
            } else {
                implicit += 1
                result.append(Specifier(position: implicit, type: String(type)))
            }
        }
        let percents = format.filter { $0 == "%" }.count
        return percents == matchedPercents ? result.sorted() : nil
    }

    /// `key` with each specifier replaced by `placeholder`, to compare against a source template.
    static func template(ofCatalogKey key: String) -> String {
        key.replacing(specifierPattern) { match in
            match.output.type == nil ? "%" : placeholder
        }
    }
}

extension StringsGate {
    // MARK: Catalog

    /// The subset of the .xcstrings schema the gate reads. Unknown fields are ignored; a missing
    /// `stringUnit` (a plural `variations` entry, say) decodes as nil and fails the presence check.
    struct Catalog: Decodable, Sendable {
        struct Entry: Decodable, Sendable {
            var localizations: [String: Localization]?
        }
        struct Localization: Decodable, Sendable {
            var stringUnit: StringUnit?
        }
        struct StringUnit: Decodable, Sendable {
            var state: String
            var value: String
        }

        var sourceLanguage: String
        var strings: [String: Entry]

        func value(_ key: String, _ language: String) -> String? {
            strings[key]?.localizations?[language]?.stringUnit?.value
        }
    }

    static let languages = ["en", "fr"]

    static func catalog(_ data: Data) throws -> Catalog {
        try JSONDecoder().decode(Catalog.self, from: data)
    }

    /// Every entry has a translated, non-empty `stringUnit` in each of `languages`.
    static func presence(_ catalog: Catalog, name: String) -> [String] {
        var problems: [String] = []
        if catalog.sourceLanguage != "en" {
            problems.append("\(name): sourceLanguage is \(catalog.sourceLanguage), not en")
        }
        for key in catalog.strings.keys.sorted() {
            for language in languages {
                guard let unit = catalog.strings[key]?.localizations?[language]?.stringUnit else {
                    problems.append("\(name): \(key) has no \(language) stringUnit")
                    continue
                }
                if unit.state != "translated" {
                    problems.append("\(name): \(key) \(language) is \(unit.state), not translated")
                }
                if unit.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    problems.append("\(name): \(key) \(language) is empty")
                }
            }
        }
        return problems
    }

    /// Every used key resolves to a catalog key, and every catalog key is used by some call.
    static func coverage(_ used: [UsedKey], _ catalog: Catalog) -> [String] {
        var byTemplate: [String: [String]] = [:]
        for key in catalog.strings.keys {
            byTemplate[template(ofCatalogKey: key), default: []].append(key)
        }
        var problems: [String] = []
        var resolved: Set<String> = []
        for use in used {
            let matches = byTemplate[use.template] ?? []
            switch matches.count {
            case 0: problems.append("\(use.location): \(readable(use.template)) is not in the catalog")
            case 1: resolved.formUnion(matches)
            default:
                problems.append(
                    "\(use.location): \(readable(use.template)) matches \(matches.sorted()) in the catalog")
            }
        }
        for key in catalog.strings.keys.sorted() where !resolved.contains(key) {
            problems.append("catalog key \(key) is not used by any L( call")
        }
        return problems
    }

    static func readable(_ template: String) -> String {
        template.replacingOccurrences(of: placeholder, with: "\\(…)")
    }

    /// en and fr take the arguments the key passes: the same multiset of (position, type), where a
    /// value may reorder with explicit positions. A `%` that starts no specifier is a problem too.
    static func specifierParity(_ catalog: Catalog) -> [String] {
        var problems: [String] = []
        for key in catalog.strings.keys.sorted() {
            guard let expected = specifiers(in: key) else {
                problems.append("\(key): the key has a % that is not a format specifier")
                continue
            }
            for language in languages {
                guard let value = catalog.value(key, language) else { continue }
                guard let actual = specifiers(in: value) else {
                    problems.append("\(key) \(language): \(value) has a % that is not a format specifier")
                    continue
                }
                if actual != expected {
                    problems.append("\(key) \(language): specifiers \(actual) differ from the key's \(expected)")
                }
            }
        }
        return problems
    }

    /// fr is a translation, not a copy of en, unless the key is in `allowed`. An allowed key whose
    /// values differ is reported too, so the list cannot go stale.
    /// French puts a no-break space before : ; ! ? and » and after «, so the mark never wraps onto a line of its own.
    /// An ordinary space there is the mistake; no space at all is left alone, since `apps:` and `version:` are YAML.
    static func frenchSpacing(_ catalog: Catalog) -> [String] {
        var problems: [String] = []
        for key in catalog.strings.keys.sorted() {
            guard let fr = catalog.value(key, "fr") else { continue }
            let chars = Array(fr)
            for (index, char) in chars.enumerated() where char == " " {
                let next = index + 1 < chars.count ? chars[index + 1] : nil
                let previous = index > 0 ? chars[index - 1] : nil
                if let next, ":;!?»".contains(next) {
                    problems.append("\(key): fr has a breaking space before \"\(next)\"; use U+00A0")
                } else if previous == "«" {
                    problems.append("\(key): fr has a breaking space after \"«\"; use U+00A0")
                }
            }
        }
        return problems
    }

    static func translated(_ catalog: Catalog, allowed: Set<String>) -> [String] {
        var problems: [String] = []
        for key in catalog.strings.keys.sorted() {
            guard let en = catalog.value(key, "en"), let fr = catalog.value(key, "fr") else { continue }
            if en == fr, !allowed.contains(key) {
                problems.append("\(key): fr is the en text \"\(en)\"; translate it or allow-list it")
            }
            if en != fr, allowed.contains(key) {
                problems.append("\(key): allow-listed as identical but en and fr differ")
            }
        }
        for key in allowed.sorted() where catalog.strings[key] == nil {
            problems.append("\(key): allow-listed but not in the catalog")
        }
        return problems
    }
}
