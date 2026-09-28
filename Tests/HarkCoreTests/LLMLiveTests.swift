import Foundation
import HarkCore
import Testing

/// Against a real server through URLSession: MTPLX on this Mac. Runs only when HARK_TEST_LLM_URL (the base, up to
/// `/v1`) and HARK_TEST_LLM_KEY are both set; the key goes into a fake store, never the Keychain.
@Suite(
    .enabled(
        if: ProcessInfo.processInfo.environment["HARK_TEST_LLM_URL"] != nil
            && ProcessInfo.processInfo.environment["HARK_TEST_LLM_KEY"] != nil),
    .serialized)
struct LLMLiveTests {
    struct ProbeFailed: Error {
        let result: LLMProbeResult
    }

    private static let environment = ProcessInfo.processInfo.environment

    private func profile(base: String? = nil) throws -> ProviderProfile {
        let url = try #require(URL(string: base ?? Self.environment["HARK_TEST_LLM_URL"] ?? ""))
        return ProviderProfile(name: "live-test", baseURL: url, extra: ["enable_thinking": .bool(false)])
    }

    private func client(key: String? = environment["HARK_TEST_LLM_KEY"]) -> LLMClient {
        LLMClient(transport: URLSessionLLMTransport(), secrets: FakeSecretStore(key.map { ["live-test": $0] } ?? [:]))
    }

    private func modelID(_ client: LLMClient, _ profile: ProviderProfile) async throws -> String {
        let result = await LLMProbe(client: client).check(profile)
        guard case .connected(let model) = result else { throw ProbeFailed(result: result) }
        return model
    }

    @Test func probeConnects() async throws {
        let profile = try profile()
        #expect(try await !modelID(client(), profile).isEmpty)
    }

    @Test func aShortFrenchAskStreamsAndFinishes() async throws {
        let client = client()
        let profile = try profile()
        let model = try await modelID(client, profile)
        let messages = [
            ChatMessage(role: .system, content: "Réponds en une phrase."),
            ChatMessage(role: .user, content: "Résume : Lyon et Nantes ont achevé la migration du réseau."),
        ]
        var events: [LLMEvent] = []
        for await event in client.complete(messages, model: model, profile: profile) { events.append(event) }

        #expect(!events.texts.joined().isEmpty)
        #expect(events.terminals.count == 1)
        guard case .finished(let summary) = events.last else {
            Issue.record("not finished: \(String(describing: events.last))")
            return
        }
        #expect(summary.model?.isEmpty == false)
    }

    @Test func aWrongKeyIsRefused() async throws {
        let client = client(key: "wrong-\(UUID().uuidString)")
        var events: [LLMEvent] = []
        let messages = [ChatMessage(role: .user, content: "Bonjour")]
        for await event in client.complete(messages, model: "any", profile: try profile()) { events.append(event) }
        #expect(events.failure == .keyRefused)
    }

    @Test func aClosedPortIsNotRunning() async throws {
        let profile = try profile(base: "http://127.0.0.1:1/v1")
        var events: [LLMEvent] = []
        let messages = [ChatMessage(role: .user, content: "Bonjour")]
        for await event in client().complete(messages, model: "any", profile: profile) { events.append(event) }
        #expect(events.failure == .notRunning(endpoint: "127.0.0.1:1"))
    }
}
