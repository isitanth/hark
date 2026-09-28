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
