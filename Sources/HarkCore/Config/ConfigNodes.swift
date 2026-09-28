import Foundation
import Yams

/// Typed reads of composed YAML nodes, each failing with the problem and the location a person should look at.
///
/// Scalars are read by style, never through Yams' resolver, whose YAML 1.1 rules would turn `yes` into a boolean: a
/// boolean or a number has to be a plain scalar spelled the YAML 1.2 core-schema way, and quoting makes anything text.
enum ConfigNodes {
    static func location(_ mark: Mark) -> ConfigLocation {
        ConfigLocation(line: mark.line, column: mark.column)
    }

    static func error(_ problem: ConfigProblem, at node: Node) -> ConfigError {
        ConfigError(problem, at: node.mark.map(location))
    }

    /// Every node the walker reads passes through here. Yams resolves an alias by copying the anchored node, anchor
    /// included, so refusing anchors refuses aliases too, at the anchor, before any expansion is walked.
    static func visit(_ node: Node) throws(ConfigError) -> Node {
        if case .alias = node {
            throw error(.anchorsNotSupported, at: node)
        }
        guard node.anchor == nil else { throw error(.anchorsNotSupported, at: node) }
        return node
    }

    /// The core-schema null. Only a plain scalar can be one: `""` and `"~"` are text.
    static func isNull(_ node: Node) -> Bool {
        guard case .scalar(let scalar) = node, scalar.style == .plain else { return false }
        return ["", "~", "null", "Null", "NULL"].contains(scalar.string)
    }

    static func mapping(_ node: Node, path: String) throws(ConfigError) -> Node.Mapping {
        guard case .mapping(let mapping) = node else {
            throw error(.wrongType(path: path, expected: .mapping), at: node)
        }
        return mapping
    }

    static func list(_ node: Node, path: String) throws(ConfigError) -> Node.Sequence {
        guard case .sequence(let sequence) = node else {
            throw error(.wrongType(path: path, expected: .list), at: node)
        }
        return sequence
    }

    /// Any scalar, as written: `phrase: 42` is the text "42".
    static func text(_ node: Node, path: String) throws(ConfigError) -> String {
        guard case .scalar(let scalar) = node else { throw error(.wrongType(path: path, expected: .text), at: node) }
        return scalar.string
    }

    static func boolean(_ node: Node, path: String) throws(ConfigError) -> Bool {
        if case .scalar(let scalar) = node, scalar.style == .plain {
            switch scalar.string {
            case "true", "True", "TRUE": return true
            case "false", "False", "FALSE": return false
            default: break
            }
        }
        throw error(.wrongType(path: path, expected: .boolean), at: node)
    }

    /// A plain decimal integer or float, `1`, `0.85`, `.5`, `2e1`. Hex, octal, `.inf` and `.nan` are numbers to YAML
    /// but no key here wants them, so they are out of range along with every other scalar that is not a number.
    static func number(_ node: Node, path: String) throws(ConfigError) -> Double {
        guard case .scalar(let scalar) = node else { throw error(.wrongType(path: path, expected: .number), at: node) }
        let raw = scalar.string
        guard scalar.style == .plain, raw.wholeMatch(of: /[-+]?(\.[0-9]+|[0-9]+(\.[0-9]*)?)([eE][-+]?[0-9]+)?/) != nil,
            let value = Double(raw), value.isFinite
        else { throw error(.outOfRange(path: path, value: raw), at: node) }
        return value
    }

    static func choice<Choice: RawRepresentable & CaseIterable>(
        _ node: Node, path: String
    ) throws(ConfigError) -> Choice where Choice.RawValue == String {
        let raw = try text(node, path: path)
        guard let choice = Choice(rawValue: raw) else {
            throw error(.invalidChoice(path: path, value: raw, allowed: Choice.allCases.map(\.rawValue)), at: node)
        }
        return choice
    }

    /// Walks a mapping in document order: each key is checked against `allowed` and against the keys before it, then
    /// its value goes to `body`, unless the value is null, which counts as the key being absent. A required key that
    /// never showed up is reported last, at the mapping, so a misspelt key is reported first with its suggestion.
    static func fields(
        of node: Node, path: String, allowed: [String], required: [String] = [],
        _ body: (_ key: String, _ value: Node) throws(ConfigError) -> Void
    ) throws(ConfigError) {
        var present: Set<String> = []
        var seen: Set<String> = []
        for (keyNode, valueNode) in try mapping(node, path: path) {
            let key = keyText(try visit(keyNode))
            guard allowed.contains(key) else {
                throw error(.unknownKey(key, path: path, suggestion: suggestion(for: key, in: allowed)), at: keyNode)
            }
            guard seen.insert(key).inserted else { throw error(.duplicateKey(key, path: path), at: keyNode) }
            let value = try visit(valueNode)
            if isNull(value) {
                continue
            }
            present.insert(key)
            try body(key, value)
        }
        if let missing = required.first(where: { !present.contains($0) }) {
            throw error(.missingKey(missing, path: path), at: node)
        }
    }

    /// A scalar key as written. A list or mapping used as a key is never valid, and is named by its brackets.
    static func keyText(_ node: Node) -> String {
        switch node {
        case .scalar(let scalar): scalar.string
        case .sequence: "[…]"
        case .mapping, .alias: "{…}"
        }
    }

    /// The closest allowed key at an edit distance of 2 or less, ignoring case; the first in `allowed` on a tie.
    static func suggestion(for key: String, in allowed: [String]) -> String? {
        let typed = Array(key.lowercased())
        var best: (key: String, distance: Int)?
        for candidate in allowed {
            let distance = editDistance(typed, Array(candidate.lowercased()))
            if distance <= 2 && distance < (best?.distance ?? .max) {
                best = (candidate, distance)
            }
        }
        return best?.key
    }

    /// Levenshtein distance, one row at a time.
    private static func editDistance(_ lhs: [Character], _ rhs: [Character]) -> Int {
        var previous = Array(0...rhs.count)
        for (i, left) in lhs.enumerated() {
            var current = [i + 1]
            for (j, right) in rhs.enumerated() {
                current.append(min(previous[j + 1] + 1, current[j] + 1, previous[j] + (left == right ? 0 : 1)))
            }
            previous = current
        }
        return previous[rhs.count]
    }
}
