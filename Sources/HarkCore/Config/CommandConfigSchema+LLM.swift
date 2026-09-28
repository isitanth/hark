import Foundation
import Yams

/// `llm:`, version 3 only. No key is ever read from the file, and no problem found here repeats what looked like one:
/// those are `keyInFile`, which carries only the path.
extension CommandConfigSchema {
    static let llmKeys = ["provider", "profiles", "max_selection_chars"]
    static let profileKeys = ["base_url", "key", "model", "temperature", "max_tokens", "extra"]
    /// The fields the request builder writes itself. `extra` may not set them.
    static let standardRequestFields: Set<String> = [
        "model", "messages", "stream", "stream_options", "max_tokens", "temperature", "response_format",
    ]
    /// A field is taken for a secret when a word of its name, split at `_` and `-`, is or ends with one of these:
    /// `api_key`, `apiKey`, `access_token` and `oauth` are; `max_tokens` and `skip_special_tokens` are not.
    static let secretWords = [
        "key", "token", "secret", "auth", "authorization", "password", "passwd", "bearer", "credential", "credentials",
    ]
    static let maxSelectionCharsRange = 1...100_000
    static let temperatureRange = 0.0...2.0
    static let maxTokensRange = 1...131_072

    static func llm(_ node: Node) throws(ConfigError) -> LLMConfig {
        var provider: (name: String, node: Node)?
        var profiles = LLMConfig.standard.profiles
        var maxSelectionChars = LLMConfig.defaultMaxSelectionChars
        try ConfigNodes.fields(of: node, path: "llm", allowed: llmKeys) { key, value throws(ConfigError) in
            let path = "llm.\(key)"
            switch key {
            case "provider": provider = (try ConfigNodes.text(value, path: path), value)
            case "profiles": profiles = try Self.profiles(value)
            case "max_selection_chars": maxSelectionChars = try integer(value, path: path, in: maxSelectionCharsRange)
            default: break
            }
        }
        let name = provider?.name ?? ProviderProfile.local.name
        guard profiles[name] != nil else { throw ConfigNodes.error(.unknownProfile(name), at: provider?.node ?? node) }
        return LLMConfig(provider: name, profiles: profiles, maxSelectionChars: maxSelectionChars)
    }

    /// A profile name is a Keychain account: lowercase ASCII, digits, `_` and `-`, 32 at most.
    static func isProfileName(_ name: String) -> Bool {
        name.wholeMatch(of: /[a-z0-9][a-z0-9_-]{0,31}/) != nil
    }

    static func looksSecret(_ name: String) -> Bool {
        let words = name.lowercased().split { $0 == "_" || $0 == "-" }
        return words.contains { word in secretWords.contains { word.hasSuffix($0) } }
    }

    private static func profiles(_ node: Node) throws(ConfigError) -> [String: ProviderProfile] {
        var profiles: [String: ProviderProfile] = [:]
        for (keyNode, valueNode) in try ConfigNodes.mapping(node, path: "llm.profiles") {
            let keyNode = try ConfigNodes.visit(keyNode)
            let name = ConfigNodes.keyText(keyNode)
            guard isProfileName(name) else {
                throw ConfigNodes.error(.outOfRange(path: "llm.profiles", value: name), at: keyNode)
            }
            guard profiles[name] == nil else {
                throw ConfigNodes.error(.duplicateKey(name, path: "llm.profiles"), at: keyNode)
            }
            let value = try ConfigNodes.visit(valueNode)
            let path = "llm.profiles.\(name)"
            guard !ConfigNodes.isNull(value) else {
                throw ConfigNodes.error(.wrongType(path: path, expected: .mapping), at: value)
            }
            profiles[name] = try profile(value, name: name, path: path)
        }
        return profiles
    }

    private static func profile(_ node: Node, name: String, path: String) throws(ConfigError) -> ProviderProfile {
        // `api_key:` is an unknown key, but saying so would not tell the user why it can never be one.
        for (keyNode, _) in try ConfigNodes.mapping(node, path: path) {
            let key = ConfigNodes.keyText(keyNode)
            if !profileKeys.contains(key) && looksSecret(key) {
                throw ConfigNodes.error(.keyInFile(path: "\(path).\(key)"), at: keyNode)
            }
        }
        var baseURL: URL?
        var key = KeySource.keychain
        var model = ModelChoice.auto
        var temperature = ProviderProfile.defaultTemperature
        var maxTokens = ProviderProfile.defaultMaxTokens
        var extra: [String: RequestValue] = [:]
        try ConfigNodes.fields(of: node, path: path, allowed: profileKeys, required: ["base_url"]) {
            field, value throws(ConfigError) in
            let fieldPath = "\(path).\(field)"
            switch field {
            case "base_url": baseURL = try Self.baseURL(value, path: fieldPath)
            case "key": key = try keySource(value, path: fieldPath)
            case "model": model = try Self.model(value, path: fieldPath)
            case "temperature": temperature = try Self.temperature(value, path: fieldPath)
            case "max_tokens": maxTokens = try integer(value, path: fieldPath, in: maxTokensRange)
            case "extra": extra = try Self.extra(value, path: fieldPath)
            default: break
            }
        }
        // `fields` has already refused a profile without it; the guard only satisfies the compiler.
        guard let baseURL else { throw ConfigNodes.error(.missingKey("base_url", path: path), at: node) }
        return ProviderProfile(
            name: name, baseURL: baseURL, key: key, model: model, temperature: temperature, maxTokens: maxTokens,
            extra: extra)
    }

    /// An absolute http or https URL with a host and nothing a key could hide in: no user, no password, no query, no
    /// fragment. Plain http only to this Mac. A refused URL is quoted without its query and fragment.
    private static func baseURL(_ node: Node, path: String) throws(ConfigError) -> URL {
        let raw = try ConfigNodes.text(node, path: path)
        guard let components = URLComponents(string: raw) else {
            if raw.contains("@") { throw ConfigNodes.error(.keyInFile(path: path), at: node) }
            throw ConfigNodes.error(.invalidURL(path: path, value: withoutQuery(raw)), at: node)
        }
        if components.user != nil || components.password != nil {
            throw ConfigNodes.error(.keyInFile(path: path), at: node)
        }
        let scheme = components.scheme?.lowercased()
        guard scheme == "http" || scheme == "https", let host = components.host, !host.isEmpty,
            components.query == nil, components.fragment == nil, let url = URL(string: raw)
        else { throw ConfigNodes.error(.invalidURL(path: path, value: withoutQuery(raw)), at: node) }
        if scheme == "http" && !ProviderProfile.isLoopback(host: url.host(percentEncoded: false)) {
            throw ConfigNodes.error(.insecureURL(path: path, value: raw), at: node)
        }
        return url
    }

    private static func withoutQuery(_ raw: String) -> String {
        String(raw.prefix { $0 != "?" && $0 != "#" })
    }

    /// `keychain` or `none`. Anything else is taken for a key written in the file, and is never repeated.
    private static func keySource(_ node: Node, path: String) throws(ConfigError) -> KeySource {
        if case .scalar(let scalar) = node, let source = KeySource(rawValue: scalar.string) {
            return source
        }
        throw ConfigNodes.error(.keyInFile(path: path), at: node)
    }

    private static func model(_ node: Node, path: String) throws(ConfigError) -> ModelChoice {
        let text = try ConfigNodes.text(node, path: path)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConfigNodes.error(.emptyText(path: path), at: node)
        }
        return text == "auto" ? .auto : .named(text)
    }

    private static func temperature(_ node: Node, path: String) throws(ConfigError) -> Double {
        let value = try ConfigNodes.number(node, path: path)
        guard temperatureRange.contains(value) else { throw outOfRange(node, path: path) }
        return value
    }

    /// A plain decimal integer in `range`. A number that is not an integer is out of range too.
    static func integer(_ node: Node, path: String, in range: ClosedRange<Int>) throws(ConfigError) -> Int {
        _ = try ConfigNodes.number(node, path: path)
        guard case .scalar(let scalar) = node, scalar.string.wholeMatch(of: /[-+]?[0-9]+/) != nil,
            let value = Int(scalar.string), range.contains(value)
        else { throw outOfRange(node, path: path) }
        return value
    }

    /// Top-level request fields, scalars only. A name that could be a secret is `keyInFile`; a name that is not a
    /// JSON-friendly identifier, or that the request builder writes itself, is out of range. A null value is absent.
    private static func extra(_ node: Node, path: String) throws(ConfigError) -> [String: RequestValue] {
        var extra: [String: RequestValue] = [:]
        for (keyNode, valueNode) in try ConfigNodes.mapping(node, path: path) {
            let keyNode = try ConfigNodes.visit(keyNode)
            let name = ConfigNodes.keyText(keyNode)
            let fieldPath = "\(path).\(name)"
            guard !standardRequestFields.contains(name) else {
                throw ConfigNodes.error(.outOfRange(path: path, value: name), at: keyNode)
            }
            if looksSecret(name) { throw ConfigNodes.error(.keyInFile(path: fieldPath), at: keyNode) }
            guard name.wholeMatch(of: /[a-z_][a-z0-9_]*/) != nil else {
                throw ConfigNodes.error(.outOfRange(path: path, value: name), at: keyNode)
            }
            guard extra[name] == nil else { throw ConfigNodes.error(.duplicateKey(name, path: path), at: keyNode) }
            let value = try ConfigNodes.visit(valueNode)
            if ConfigNodes.isNull(value) { continue }
            extra[name] = try requestValue(value, path: fieldPath)
        }
        return extra
    }

    /// Typed by how it is written: a plain `true` is a boolean, a plain `2` an integer, a plain `0.5` a number, and
    /// anything else, or anything quoted, is text.
    private static func requestValue(_ node: Node, path: String) throws(ConfigError) -> RequestValue {
        guard case .scalar(let scalar) = node else {
            throw ConfigNodes.error(.wrongType(path: path, expected: .text), at: node)
        }
        guard scalar.style == .plain else { return .string(scalar.string) }
        if let flag = try? ConfigNodes.boolean(node, path: path) { return .bool(flag) }
        if scalar.string.wholeMatch(of: /[-+]?[0-9]+/) != nil, let value = Int(scalar.string) { return .int(value) }
        if let value = try? ConfigNodes.number(node, path: path) { return .double(value) }
        return .string(scalar.string)
    }
}
