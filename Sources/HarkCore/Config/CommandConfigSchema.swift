import Foundation
import Yams

/// Schema version 3, or 2, read from a composed document. The first problem in document order wins, with one
/// exception: a version that does not read is reported before anything else, because the rest of such a file follows
/// another schema.
enum CommandConfigSchema {
    static let version2Keys = ["version", "defaults", "apps", "open_verbs", "fillers", "commands"]
    /// Version 3 adds `llm:` and `assistant:`.
    static let topKeys = version2Keys + ["llm", "assistant"]
    static let assistantKeys = ["prefix"]
    static let defaultsKeys = ["threshold"]
    static let appKeys = ["insert"]
    static let commandKeys = ["id", "action", "app", "aliases"]

    static func read(_ root: Node) throws(ConfigError) -> CommandConfig {
        let root = try ConfigNodes.visit(root)
        let top = try ConfigNodes.mapping(root, path: "")
        var version = CommandConfig.supportedVersion
        if let node = top["version"], !ConfigNodes.isNull(node) {
            version = try checkVersion(try ConfigNodes.visit(node))
        }
        let allowed = version == 2 ? version2Keys : topKeys
        var config = CommandConfig()
        try ConfigNodes.fields(of: root, path: "", allowed: allowed, required: ["version"]) {
            key, value throws(ConfigError) in
            switch key {
            case "defaults": config.defaults = try defaults(value)
            case "apps": config.apps = try apps(value)
            case "open_verbs": config.openVerbs = try wordLists(value, path: key)
            case "fillers": config.fillers = try wordLists(value, path: key)
            case "commands": config.commands = try commands(value)
            case "llm": config.llm = try llm(value)
            case "assistant": config.assistant = try assistant(value)
            default: break
            }
        }
        return config
    }

    /// One of `CommandConfig.readableVersions`, as a plain integer scalar.
    private static func checkVersion(_ node: Node) throws(ConfigError) -> Int {
        guard case .scalar(let scalar) = node else {
            throw ConfigNodes.error(.wrongType(path: "version", expected: .number), at: node)
        }
        let raw = scalar.string
        guard scalar.style == .plain, raw.wholeMatch(of: /[-+]?[0-9]+/) != nil, let version = Int(raw),
            CommandConfig.readableVersions.contains(version)
        else { throw ConfigNodes.error(.unsupportedVersion(raw), at: node) }
        return version
    }

    private static func defaults(_ node: Node) throws(ConfigError) -> CommandDefaults {
        var defaults = CommandDefaults()
        try ConfigNodes.fields(of: node, path: "defaults", allowed: defaultsKeys) { key, value throws(ConfigError) in
            let path = "defaults.\(key)"
            if key == "threshold" { defaults.threshold = try threshold(value, path: path) }
        }
        return defaults
    }

    /// Bundle ID to override. IDs are compared case-insensitively, as Launch Services does.
    private static func apps(_ node: Node) throws(ConfigError) -> [String: AppOverride] {
        var apps: [String: AppOverride] = [:]
        var seen: Set<String> = []
        for (keyNode, valueNode) in try ConfigNodes.mapping(node, path: "apps") {
            let id = ConfigNodes.keyText(try ConfigNodes.visit(keyNode))
            guard isBundleID(id) else { throw ConfigNodes.error(.invalidBundleID(id), at: keyNode) }
            guard seen.insert(id.lowercased()).inserted else {
                throw ConfigNodes.error(.duplicateKey(id, path: "apps"), at: keyNode)
            }
            let path = "apps.\(id)"
            let value = try ConfigNodes.visit(valueNode)
            guard !ConfigNodes.isNull(value) else {
                throw ConfigNodes.error(.wrongType(path: path, expected: .mapping), at: value)
            }
            var insert = InsertionMode.accessibility
            try ConfigNodes.fields(of: value, path: path, allowed: appKeys, required: appKeys) {
                _, value throws(ConfigError) in
                insert = try ConfigNodes.choice(value, path: "\(path).insert")
            }
            apps[id] = AppOverride(insert: insert)
        }
        return apps
    }

    /// Language -> words, for `open_verbs` and `fillers`. The language is any key, compared as written; a null list is
    /// an empty one, and every word has to leave something once normalized.
    private static func wordLists(_ node: Node, path: String) throws(ConfigError) -> [String: [String]] {
        var lists: [String: [String]] = [:]
        for (keyNode, valueNode) in try ConfigNodes.mapping(node, path: path) {
            let keyNode = try ConfigNodes.visit(keyNode)
            let language = ConfigNodes.keyText(keyNode)
            guard lists[language] == nil else {
                throw ConfigNodes.error(.duplicateKey(language, path: path), at: keyNode)
            }
            let listPath = "\(path).\(language)"
            let value = try ConfigNodes.visit(valueNode)
            var words: [String] = []
            if !ConfigNodes.isNull(value) {
                for (index, item) in try ConfigNodes.list(value, path: listPath).enumerated() {
                    let itemPath = "\(listPath)[\(index)]"
                    let item = try ConfigNodes.visit(item)
                    guard !ConfigNodes.isNull(item) else {
                        throw ConfigNodes.error(.emptyText(path: itemPath), at: item)
                    }
                    words.append(try Self.words(item, path: itemPath).text)
                }
            }
            lists[language] = words
        }
        return lists
    }

    /// A flat list of spoken first words. An empty list sends nothing to the assistant; a field left null keeps the
    /// standard prefixes, as every other null field keeps its default.
    private static func assistant(_ node: Node) throws(ConfigError) -> AssistantConfig {
        var assistant = AssistantConfig()
        try ConfigNodes.fields(of: node, path: "assistant", allowed: assistantKeys) { key, value throws(ConfigError) in
            let path = "assistant.\(key)"
            var words: [String] = []
            if !ConfigNodes.isNull(value) {
                for (index, item) in try ConfigNodes.list(value, path: path).enumerated() {
                    let itemPath = "\(path)[\(index)]"
                    let item = try ConfigNodes.visit(item)
                    guard !ConfigNodes.isNull(item) else {
                        throw ConfigNodes.error(.emptyText(path: itemPath), at: item)
                    }
                    words.append(try Self.words(item, path: itemPath).text)
                }
            }
            assistant.prefix = words
        }
        return assistant
    }

    /// ASCII letters, digits, `-`, `_` and `.`, with at least two components and none of them empty.
    static func isBundleID(_ id: String) -> Bool {
        let components = id.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count >= 2, components.allSatisfy({ !$0.isEmpty }) else { return false }
        return id.unicodeScalars.allSatisfy { scalar in
            switch scalar {
            case "a"..."z", "A"..."Z", "0"..."9", "-", "_", ".": true
            default: false
            }
        }
    }

    /// 0 < threshold <= 1.
    private static func threshold(_ node: Node, path: String) throws(ConfigError) -> Double {
        let value = try ConfigNodes.number(node, path: path)
        guard value > 0 && value <= 1 else { throw outOfRange(node, path: path) }
        return value
    }

    static func outOfRange(_ node: Node, path: String) -> ConfigError {
        ConfigNodes.error(.outOfRange(path: path, value: (try? ConfigNodes.text(node, path: path)) ?? ""), at: node)
    }

    /// Text that has to leave something to match once normalized: an alias, a verb, a filler.
    static func words(_ node: Node, path: String) throws(ConfigError) -> (text: String, normalized: String) {
        let text = try ConfigNodes.text(node, path: path)
        let normalized = Normalizer.normalize(text)
        guard !normalized.isEmpty else { throw ConfigNodes.error(.emptyText(path: path), at: node) }
        return (text, normalized)
    }
}
