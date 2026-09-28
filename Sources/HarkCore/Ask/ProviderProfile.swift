import Foundation

/// commands.yaml's `llm:`: which provider profile an ask uses, the profiles, and the selection cap. A file without
/// `llm:` reads as `LLMConfig.standard`.
public struct LLMConfig: Sendable, Equatable {
    public static let defaultMaxSelectionChars = 12_000

    /// The name of the profile an ask uses. Always a key of `profiles`: the parser refuses a file where it is not.
    public var provider: String
    /// Keyed by profile name, which is also the profile's Keychain account.
    public var profiles: [String: ProviderProfile]
    /// A selection longer than this, in characters, is cut before it is sent, and the popup says so.
    public var maxSelectionChars: Int

    public init(
        provider: String, profiles: [String: ProviderProfile],
        maxSelectionChars: Int = LLMConfig.defaultMaxSelectionChars
    ) {
        self.provider = provider
        self.profiles = profiles
        self.maxSelectionChars = maxSelectionChars
    }

    /// The local profile alone: MTPLX on its default port. What an ask uses when commands.yaml has no `llm:`.
    public static let standard = LLMConfig(
        provider: ProviderProfile.local.name, profiles: [ProviderProfile.local.name: .local])

    /// The profile named by `provider`.
    public var activeProfile: ProviderProfile? {
        profiles[provider]
    }
}

/// One OpenAI-compatible endpoint. The key is never here: `key` says only whether the endpoint takes one, and the
/// Keychain holds it under the profile's `name` (service `SecretStoreService.llm`).
public struct ProviderProfile: Sendable, Equatable {
    public var name: String
    /// Up to the version path, `http://127.0.0.1:8002/v1`: requests go to `chat/completions` and `models` under it.
    public var baseURL: URL
    public var key: KeySource
    public var model: ModelChoice
    public var temperature: Double
    public var maxTokens: Int
    /// Top-level request fields beyond the standard ones, sent as written: `enable_thinking: false` for MTPLX.
    public var extra: [String: RequestValue]

    public init(
        name: String, baseURL: URL, key: KeySource = .keychain, model: ModelChoice = .auto,
        temperature: Double = ProviderProfile.defaultTemperature, maxTokens: Int = ProviderProfile.defaultMaxTokens,
        extra: [String: RequestValue] = [:]
    ) {
        self.name = name
        self.baseURL = baseURL
        self.key = key
        self.model = model
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.extra = extra
    }

    /// Measured in M8.0: at the server's default of 1.0 the tone case invented content.
    public static let defaultTemperature = 0.3
    /// The largest answer measured in M8.0 was 113 tokens.
    public static let defaultMaxTokens = 1024

    /// MTPLX on its default port, thinking off (on, the first word waited 7.4 s instead of 0.9 s in M8.0).
    public static let local = ProviderProfile(
        name: "local", baseURL: URL(string: "http://127.0.0.1:8000/v1")!, key: .keychain, model: .auto,
        extra: ["enable_thinking": .bool(false)])

    /// `host:port`, the way the popup names a server that is not running: `127.0.0.1:8002`.
    public var endpoint: String {
        let host = baseURL.host(percentEncoded: false) ?? baseURL.absoluteString
        let shown = host.contains(":") ? "[\(host)]" : host
        return baseURL.port.map { "\(shown):\($0)" } ?? shown
    }

    /// The request never leaves this Mac: 127.0.0.0/8, ::1 or localhost. Plain http is allowed only then.
    public var isLoopback: Bool {
        Self.isLoopback(host: baseURL.host(percentEncoded: false))
    }

    public static func isLoopback(host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        if host == "localhost" || host == "::1" || host == "[::1]" { return true }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        return octets.count == 4 && octets[0] == "127" && octets.allSatisfy { UInt8($0) != nil }
    }
}

/// Where a profile's key comes from. There is no third case: a key is never written in the file.
public enum KeySource: String, Sendable, CaseIterable {
    /// The Keychain item for the profile's name.
    case keychain
    /// The endpoint takes no key.
    case none
}

public enum ModelChoice: Sendable, Equatable {
    /// The first id `GET {base_url}/models` answers.
    case auto
    case named(String)
}

/// A JSON scalar for `extra`.
public enum RequestValue: Sendable, Equatable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
}
