import Foundation
import HarkCore
import Testing

private typealias H = LLMClientHarness

/// Claude's profile as Settings › Ask adds it, and the harness's key under its name.
private let claude = ProviderProfile.claude
private let model = "claude-opus-5-5"

private func secrets() -> FakeSecretStore {
    FakeSecretStore([claude.name: H.key])
}

private func client(_ transport: FakeLLMTransport) -> LLMClient {
    H.client(transport, secrets: secrets())
}

private func events(_ answer: FakeLLMTransport.Answer, profile: ProviderProfile = claude) async -> [LLMEvent] {
    let transport = FakeLLMTransport([answer])
    return await H.collect(client(transport).complete(H.messages, model: model, profile: profile)).value
}

private func stream(_ fixture: String) throws -> FakeLLMTransport.Answer {
    .status(200, try LLMFixtures.data(fixture))
}

struct MessagesItemCase: Sendable, CustomTestStringConvertible {
    let name: String
    let data: String
    let item: ChatStreamItem

    var testDescription: String { name }
}

let messagesItemCases: [MessagesItemCase] = [
    .init(name: "ping", data: #"{"type": "ping"}"#, item: .unreadable),
    .init(
        name: "a thinking delta",
        data: #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Hmm"}}"#,
        item: .unreadable),
    .init(
        name: "an empty text delta",
        data: #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":""}}"#, item: .unreadable),
    .init(
        name: "a fallback block",
        data:
            #"{"type":"content_block_start","index":0,"content_block":{"type":"fallback","from":{"model":"a"},"to":{"model":"b"}}}"#,
        item: .unreadable),
    .init(name: "not JSON", data: "Overloaded", item: .unreadable),
    .init(name: "an OpenAI chunk", data: #"{"choices":[{"delta":{"content":"x"}}]}"#, item: .unreadable),
    .init(
        name: "a text delta",
        data: #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"é"}}"#,
        item: .chunk(ChatStreamChunk(content: "é"))),
    .init(
        name: "max_tokens is length",
        data: #"{"type":"message_delta","delta":{"stop_reason":"max_tokens"},"usage":{"output_tokens":16000}}"#,
        item: .chunk(ChatStreamChunk(finishReason: "length", completionTokens: 16000))),
    .init(
        name: "stop_sequence is stop", data: #"{"type":"message_delta","delta":{"stop_reason":"stop_sequence"}}"#,
        item: .chunk(ChatStreamChunk(finishReason: "stop"))),
    .init(
        name: "a refusal", data: #"{"type":"message_delta","delta":{"stop_reason":"refusal","stop_details":null}}"#,
        item: .refused),
    .init(name: "message_stop", data: #"{"type":"message_stop"}"#, item: .done),
    .init(
        name: "an error without a message", data: #"{"type":"error","error":{"type":"api_error"}}"#,
        item: .error(message: nil)),
]

@Suite struct AnthropicClientTests {
    /// The request of one call answered 500, so it ends at once.
    private func request(for profile: ProviderProfile = claude) async throws -> URLRequest {
        let transport = FakeLLMTransport([.status(500, Data())])
        _ = await H.collect(client(transport).complete(H.messages, model: model, profile: profile)).value
        return try #require(transport.requests.first)
    }

    private func body(of request: URLRequest) throws -> [String: Any] {
        let data = try #require(request.httpBody)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func postsToMessagesUnderTheBase() async throws {
        let request = try await request()
        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(request.httpMethod == "POST")
    }

    @Test func sendsTheKeyInXAPIKeyAndNeverAsABearer() async throws {
        let request = try await request()
        #expect(request.value(forHTTPHeaderField: "x-api-key") == H.key)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "server-side-fallback-2026-07-01")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Accept") == "text/event-stream")
    }

    @Test func movesTheSystemMessageOutAndSendsNoSamplingSetting() async throws {
        let body = try body(of: try await request())
        #expect(body["system"] as? String == "Résume le texte.")
        let messages = try #require(body["messages"] as? [[String: String]])
        #expect(messages == [["role": "user", "content": "Lyon et Nantes ont migré."]])
        #expect(body["model"] as? String == model)
        #expect(body["stream"] as? Bool == true)
        #expect(body["max_tokens"] as? Int == ProviderProfile.defaultAnthropicMaxTokens)
        #expect(body["fallbacks"] as? String == "default")
        #expect(body["output_config"] as? [String: String] == ["effort": "low"])
        #expect(
            Set(body.keys) == ["model", "messages", "stream", "max_tokens", "fallbacks", "system", "output_config"])
    }

    @Test func noEffortWrittenIsNoOutputConfig() async throws {
        var profile = claude
        profile.effort = nil
        let body = try body(of: try await request(for: profile))
        #expect(body["output_config"] == nil)
    }

    @Test func noSystemMessageIsNoSystemField() async throws {
        let transport = FakeLLMTransport([.status(500, Data())])
        let user = [ChatMessage(role: .user, content: "Bonjour")]
        _ = await H.collect(client(transport).complete(user, model: model, profile: claude)).value
        let body = try body(of: try #require(transport.requests.first))
        #expect(body["system"] == nil)
    }

    @Test func aProfileWithoutAKeyStillNamesTheVersion() async throws {
        var profile = claude
        profile.key = .none
        let request = try await request(for: profile)
        #expect(request.value(forHTTPHeaderField: "x-api-key") == nil)
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
    }

    @Test func listsTheModelsWithTheKeyInXAPIKey() async throws {
        let transport = FakeLLMTransport([.status(200, try LLMFixtures.data("anthropic-models.json"))])
        let result = await client(transport).models(profile: claude)
        #expect(result == .success(["claude-opus-5-5", "claude-sonnet-5-5"]))
        let request = try #require(transport.requests.first)
        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/models")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == H.key)
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func aRefusedKeyOnModelsIsKeyRefused() async throws {
        let transport = FakeLLMTransport([.status(401, try LLMFixtures.data("anthropic-unauthorized-401.json"))])
        #expect(await client(transport).models(profile: claude) == .failure(.keyRefused))
    }

    @Test func streamsTheTextAndTheSummary() async throws {
        let events = await events(try stream("anthropic-stream.sse"))
        #expect(events.texts == ["Lyon et Nantes ont achevé", " la migration", " du réseau."])
        #expect(events.terminals.count == 1)
        guard case .finished(let summary) = events.last else {
            Issue.record("not finished: \(events)")
            return
        }
        #expect(summary.model == model)
        #expect(summary.finishReason == "stop")
        #expect(summary.promptTokens == 312)
        #expect(summary.completionTokens == 41)
    }

    @Test func theStreamCutAnywhereGivesTheSameText() throws {
        let data = try LLMFixtures.data("anthropic-stream.sse")
        for size in [1, 7, 64] {
            var parser = SSEParser()
            var items: [ChatStreamItem] = []
            var index = data.startIndex
            while index < data.endIndex {
                let end = data.index(index, offsetBy: size, limitedBy: data.endIndex) ?? data.endIndex
                items += parser.feed(data[index..<end]).map(MessagesStreamItem.item(data:))
                index = end
            }
            items += parser.finish().map(MessagesStreamItem.item(data:))
            let texts = items.compactMap { item -> String? in
                if case .chunk(let chunk) = item { chunk.content } else { nil }
            }
            #expect(texts.joined() == "Lyon et Nantes ont achevé la migration du réseau.", "pieces of \(size)")
            #expect(items.last == .done)
        }
    }

    @Test func aRefusalIsRefusedAndLogsAsAnLLMError() async throws {
        let events = await events(try stream("anthropic-refusal.sse"))
        #expect(events.texts.isEmpty)
        #expect(events.failure == .refused)
        #expect(LLMFailure.refused.pipelineFailure == .llmError(status: nil))
    }

    @Test func anErrorEventKeepsTheWordsBeforeIt() async throws {
        let events = await events(try stream("anthropic-error-in-stream.sse"))
        #expect(events.texts == ["Lyon et Nantes"])
        #expect(events.failure == .server(status: nil, message: "Overloaded"))
    }

    @Test func aRefusedKeyIsKeyRefused() async throws {
        let events = await events(.status(401, try LLMFixtures.data("anthropic-unauthorized-401.json")))
        #expect(events.failure == .keyRefused)
    }

    @Test func anOverloadedServerSaysSo() async throws {
        let events = await events(.status(529, try LLMFixtures.data("anthropic-overloaded-529.json")))
        #expect(events.failure == .server(status: 529, message: "Overloaded"))
    }

    @Test func anAnthropicErrorBodyGivesItsMessage() throws {
        let body = try LLMFixtures.data("anthropic-unauthorized-401.json")
        #expect(LLMErrorBody.message(in: body) == "invalid x-api-key")
    }

    @Test(arguments: messagesItemCases)
    func readsOneEvent(_ row: MessagesItemCase) {
        #expect(MessagesStreamItem.item(data: row.data) == row.item)
    }

    @Test func anUnreachableHostIsNotAServerToStart() async throws {
        let events = await events(.refuse)
        #expect(events.failure == .unreachable(host: "api.anthropic.com"))
        #expect(LLMFailure.unreachable(host: "api.anthropic.com").pipelineFailure == .llmUnreachable)
        let transport = FakeLLMTransport([.refuse])
        #expect(
            await LLMProbe(client: client(transport)).check(claude) == .failed(.unreachable(host: "api.anthropic.com")))
    }

    @Test func aServerOnThisMacIsStillOneToStart() async throws {
        let transport = FakeLLMTransport([.refuse])
        let events = await H.collect(H.client(transport).complete(H.messages, model: model, profile: H.profile)).value
        #expect(events.failure == .notRunning(endpoint: H.endpoint))
    }

    /// A remote head gets 10 s, not the 2 s measured on this Mac: the timer fires at 10 s on the manual clock.
    @Test func aRemoteHeadGetsTheRemoteConnectLimit() async throws {
        let transport = FakeLLMTransport([.hang])
        let clock = ManualClock()
        let client = H.client(transport, secrets: secrets(), clock: clock)
        let events = H.collect(client.complete(H.messages, model: model, profile: claude))
        await clock.waitForSleeps(2)
        clock.advance(by: .seconds(9))
        clock.advance(by: .seconds(1))
        let result = await events.value
        #expect(result.failure == .noAnswer)
        #expect(result.summary?.ms == 10_000)
    }

    /// Before the first word a remote server may stay silent 45 s, where one on this Mac gets 15 s.
    @Test func aRemoteServerGetsTheRemoteSilenceLimit() async throws {
        let transport = FakeLLMTransport([.pushed(status: 200)])
        let clock = ManualClock()
        let client = H.client(transport, secrets: secrets(), clock: clock)
        let events = H.collect(client.complete(H.messages, model: model, profile: claude))
        // total and connect, then silence once the head is in.
        await clock.waitForSleeps(3)
        clock.advance(by: .seconds(44))
        clock.advance(by: .seconds(1))
        let result = await events.value
        #expect(result.failure == .noAnswer)
        #expect(result.summary?.ms == 45_000)
    }

    /// The models list of a remote server may take 7 s, past the 5 s a server on this Mac gets.
    @Test func aRemoteProbeGetsTheRemoteProbeLimit() async throws {
        let transport = FakeLLMTransport([.pushed(status: 200)])
        let clock = ManualClock()
        let probe = LLMProbe(client: H.client(transport, secrets: secrets(), clock: clock))
        let result = Task { await probe.check(claude) }
        await clock.waitForSleeps(2)
        while transport.requests.isEmpty { await Task.yield() }
        clock.advance(by: .seconds(7))
        transport.push(try LLMFixtures.data("anthropic-models.json"))
        transport.endBody()
        #expect(await result.value == .connected(model: model))
    }

    @Test func anOpenAIProfileStillPostsToChatCompletionsWithABearer() async throws {
        let transport = FakeLLMTransport([.status(500, Data())])
        _ = await H.collect(H.client(transport).complete(H.messages, model: model, profile: H.profile)).value
        let request = try #require(transport.requests.first)
        #expect(request.url?.path() == "/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == nil)
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == nil)
        #expect(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true)
    }
}
