import Foundation
import Yams

extension CommandConfigSchema {
    /// Where a normalized alias first appeared.
    struct Occurrence {
        let path: String
        let location: ConfigLocation
    }

    /// Two commands answering to the same normalized text would make matching arbitrary, so that is refused, at the
    /// second one, and so is an `id` used twice. Within one command a repeated alias is harmless and is dropped
    /// instead, keeping the first spelling; the app's own name counts as the first.
    static func commands(_ node: Node) throws(ConfigError) -> [CommandEntry] {
        var earlier: [String: Occurrence] = [:]
        var ids: [String: ConfigLocation] = [:]
        var entries: [CommandEntry] = []
        for (index, item) in try ConfigNodes.list(node, path: "commands").enumerated() {
            let (entry, forms, idLocation) = try command(
                try ConfigNodes.visit(item), path: "commands[\(index)]", earlier: earlier, ids: ids)
            entries.append(entry)
            ids[entry.id] = idLocation
            for (normalized, occurrence) in forms where earlier[normalized] == nil {
                earlier[normalized] = occurrence
            }
        }
        return entries
    }

    /// One command, the normalized form of its app name and aliases in document order, and where its `id` is.
    private static func command(
        _ item: Node, path: String, earlier: [String: Occurrence], ids: [String: ConfigLocation]
    ) throws(ConfigError) -> (CommandEntry, [(String, Occurrence)], ConfigLocation) {
        var id: (text: String, location: ConfigLocation)?
        var action: ActionType?
        var app: (text: String, normalized: String)?
        var aliases: [(text: String, normalized: String)] = []
        var forms: [(String, Occurrence)] = []

        func location(of node: Node) -> ConfigLocation {
            node.mark.map(ConfigNodes.location) ?? ConfigLocation(line: 1, column: 1)
        }

        func note(_ normalized: String, at node: Node, path: String) throws(ConfigError) {
            if let other = earlier[normalized] {
                throw ConfigError(
                    .collision(
                        normalized: normalized, path: path, otherPath: other.path, otherLocation: other.location),
                    at: location(of: node))
            }
            forms.append((normalized, Occurrence(path: path, location: location(of: node))))
        }

        let required = ["id", "action", "app"]
        try ConfigNodes.fields(of: item, path: path, allowed: commandKeys, required: required) {
            key, value throws(ConfigError) in
            let keyPath = "\(path).\(key)"
            switch key {
            case "id":
                let text = try ConfigNodes.text(value, path: keyPath)
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ConfigNodes.error(.emptyText(path: keyPath), at: value)
                }
                if let first = ids[text] {
                    throw ConfigNodes.error(.duplicateID(text, otherLocation: first), at: value)
                }
                id = (text, location(of: value))
            case "action":
                action = try ConfigNodes.choice(value, path: keyPath)
            case "app":
                let text = try ConfigNodes.text(value, path: keyPath)
                let normalized = Normalizer.normalize(CommandEntry.spokenName(of: text))
                guard !normalized.isEmpty else { throw ConfigNodes.error(.emptyText(path: keyPath), at: value) }
                try note(normalized, at: value, path: keyPath)
                app = (text, normalized)
            case "aliases":
                for (index, aliasNode) in try ConfigNodes.list(value, path: keyPath).enumerated() {
                    let aliasPath = "\(keyPath)[\(index)]"
                    let aliasNode = try ConfigNodes.visit(aliasNode)
                    guard !ConfigNodes.isNull(aliasNode) else {
                        throw ConfigNodes.error(.emptyText(path: aliasPath), at: aliasNode)
                    }
                    let alias = try Self.words(aliasNode, path: aliasPath)
                    try note(alias.normalized, at: aliasNode, path: aliasPath)
                    aliases.append(alias)
                }
            default:
                break
            }
        }
        // `fields` has already refused a command without these; the guard only satisfies the compiler.
        guard let id, let action, let app else { throw ConfigNodes.error(.missingKey("id", path: path), at: item) }
        var kept: Set<String> = [app.normalized]
        let entry = CommandEntry(
            id: id.text, action: action, app: app.text,
            aliases: aliases.filter { kept.insert($0.normalized).inserted }.map(\.text))
        return (entry, forms, id.location)
    }
}
