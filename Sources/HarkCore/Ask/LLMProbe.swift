import Foundation

/// What Settings › Ask shows after its check, and what the pre-flight learns before the user finishes speaking.
public enum LLMProbeResult: Sendable, Equatable {
    /// The server answered with its models; `model` is the one an ask would use.
    case connected(model: String)
    case failed(LLMFailure)
}

/// Asks `GET {base_url}/models` every time: it is cheap, and it is what shows a stopped server or a refused key
/// before an ask is spent on it.
public struct LLMProbe: Sendable {
    private let client: LLMClient

    public init(client: LLMClient) {
        self.client = client
    }

    /// For a named model, that id once the server answers at all; for `auto`, the first id it lists.
    public func check(_ profile: ProviderProfile) async -> LLMProbeResult {
        switch await client.models(profile: profile) {
        case .failure(let failure):
            return .failed(failure)
        case .success(let ids):
            guard let first = ids.first else { return .failed(.server(status: 200, message: nil)) }
            switch profile.model {
            case .auto: return .connected(model: first)
            case .named(let id): return .connected(model: id)
            }
        }
    }
}

extension LLMProbe {
    /// Whether opening the panel or Settings › Ask may check `profile` on its own (your decision of 2026-09-28): only
    /// once Ask is set up, a key saved or none needed, and only for a server on this Mac. A server elsewhere is
    /// contacted only by Test connection or an ask.
    public static func checksOnOpen(_ profile: ProviderProfile, hasKey: Bool?) -> Bool {
        guard profile.isLoopback else { return false }
        switch profile.key {
        case .none: return true
        case .keychain: return hasKey == true
        }
    }
}
