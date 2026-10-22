import Foundation

/// What Settings › Ask shows after its check, and what the pre-flight learns before the user finishes speaking.
public enum LLMProbeResult: Sendable, Equatable {
    /// The server answered with its models; `model` is the one an ask would use.
    case connected(model: String)
    case failed(LLMFailure)
}

/// A probe's result and, once connected, whether the model reads images: nil when the server does not say.
public struct LLMProbeReport: Sendable, Equatable {
    public var result: LLMProbeResult
    public var vision: Bool?

    public init(result: LLMProbeResult, vision: Bool?) {
        self.result = result
        self.vision = vision
    }
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
        await inspect(profile).result
    }

    /// `check`, and whether the model it names reads images, as its entry in the list says. Anthropic's API lists
    /// `capabilities`; without them, Claude is taken to read images.
    public func inspect(_ profile: ProviderProfile) async -> LLMProbeReport {
        switch await client.listing(profile: profile) {
        case .failure(let failure):
            return LLMProbeReport(result: .failed(failure), vision: nil)
        case .success(let listing):
            guard let first = listing.first else {
                return LLMProbeReport(result: .failed(.server(status: 200, message: nil)), vision: nil)
            }
            let model: String
            switch profile.model {
            case .auto: model = first.id
            case .named(let id): model = id
            }
            let vision = listing.first { $0.id == model }?.vision ?? (profile.api == .anthropic ? true : nil)
            return LLMProbeReport(result: .connected(model: model), vision: vision)
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
