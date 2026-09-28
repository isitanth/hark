import Foundation
import HarkCore

/// What the client, mapping and probe tests share: the profile MTPLX runs under, a client on a fake transport and a
/// manual clock, and the events of one call.
enum LLMClientHarness {
    static let key = "test-key-not-a-secret"
    static let endpoint = "127.0.0.1:8002"
    static let profile = ProviderProfile(
        name: "local", baseURL: URL(string: "http://127.0.0.1:8002/v1")!, extra: ["enable_thinking": .bool(false)])
    static let messages = [
        ChatMessage(role: .system, content: "Résume le texte."),
        ChatMessage(role: .user, content: "Lyon et Nantes ont migré."),
    ]

    static func secrets() -> FakeSecretStore {
        FakeSecretStore([profile.name: key])
    }

    static func client(
        _ transport: FakeLLMTransport, secrets: FakeSecretStore = secrets(), clock: ManualClock = ManualClock()
    ) -> LLMClient {
        LLMClient(transport: transport, secrets: secrets, clock: clock)
    }

    /// Iterates `stream` in a task of its own, so the test can drive the transport and the clock meanwhile.
    static func collect(_ stream: AsyncStream<LLMEvent>) -> Task<[LLMEvent], Never> {
        Task {
            var events: [LLMEvent] = []
            for await event in stream { events.append(event) }
            return events
        }
    }

    /// The content pieces of an SSE fixture before its first error or `[DONE]`.
    static func texts(inFixture name: String) throws -> [String] {
        var texts: [String] = []
        for item in try LLMFixtures.events(name) {
            switch item {
            case .chunk(let chunk): chunk.content.map { texts.append($0) }
            case .error, .done: return texts
            case .unreadable: continue
            }
        }
        return texts
    }

    /// One content chunk as MTPLX sends it, on one line.
    static func contentLine(_ content: String) -> String {
        "data: {\"model\": \"\(LLMFixtures.model)\", \"choices\": [{\"index\": 0, \"delta\": {\"content\": \"\(content)\"}}]}\n\n"
    }
}

extension [LLMEvent] {
    var texts: [String] {
        compactMap { event in
            if case .text(let text) = event { text } else { nil }
        }
    }

    /// The finished and failed events, of which a call sends exactly one, last.
    var terminals: [LLMEvent] {
        filter { event in
            if case .text = event { false } else { true }
        }
    }

    var failure: LLMFailure? {
        guard case .failed(let failure, _) = last else { return nil }
        return failure
    }

    var summary: LLMCallSummary? {
        switch last {
        case .finished(let summary), .failed(_, let summary): summary
        default: nil
        }
    }
}
