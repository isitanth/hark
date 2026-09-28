import Foundation
import HarkCore
import Testing

private typealias H = LLMClientHarness

@Suite(.timeLimit(.minutes(1)))
struct AskEngineTests {
    private func engine(_ transport: FakeLLMTransport, model: ModelChoice = .auto, cap: Int = 12_000) -> AskEngine {
        var profile = H.profile
        profile.model = model
        let config = LLMConfig(provider: profile.name, profiles: [profile.name: profile], maxSelectionChars: cap)
        return AskEngine(client: H.client(transport), settings: AskSettings(config))
    }

    private func body(_ request: URLRequest?) throws -> [String: Any] {
        let data = try #require(request?.httpBody)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// `auto`: the model the server lists first is the one asked, with the spoken instruction and the selection.
    @Test func anAskUsesTheListedModelAndStreamsTheAnswer() async throws {
        let transport = FakeLLMTransport([
            .status(200, try LLMFixtures.data("models.json")), .status(200, try LLMFixtures.data("summary-fr.sse")),
        ])
        let events = await H.collect(engine(transport).generate(instruction: "Résume ça.", selection: "Lyon.")).value

        #expect(events.texts.joined() == LLMFixtures.summaryText)
        #expect(events.terminals.count == 1 && events.summary?.model == LLMFixtures.model)
        #expect(transport.requests.map { $0.url?.lastPathComponent } == ["models", "completions"])
        let sent = try body(transport.requests.last)
        #expect(sent["model"] as? String == LLMFixtures.model)
        let messages = try #require(sent["messages"] as? [[String: String]])
        let user = try #require(messages.last?["content"])
        #expect(user.hasPrefix(AskPrompt.leadLine))
        #expect(user.contains("Instruction: Résume ça.") && user.contains("<selection>\nLyon.\n</selection>"))
    }

    @Test func aNamedModelIsAskedWithoutListingTheModels() async throws {
        let transport = FakeLLMTransport([.status(200, try LLMFixtures.data("summary-fr.sse"))])
        let events = await H.collect(
            engine(transport, model: .named("qwen3-8b")).generate(instruction: "a", selection: "b")
        )
        .value
        #expect(events.terminals.count == 1)
        #expect(try body(transport.requests.first)["model"] as? String == "qwen3-8b")
    }

    /// A stopped server is known from `GET /models` and nothing more is sent.
    @Test func aServerThatIsNotThereFailsBeforeTheRequest() async {
        let transport = FakeLLMTransport([.refuse])
        let events = await H.collect(engine(transport).generate(instruction: "a", selection: "b")).value
        #expect(events == [.failed(.notRunning(endpoint: H.endpoint), LLMCallSummary())])
        #expect(transport.requests.count == 1)
    }

    @Test func theSelectionIsCutToTheConfiguredCap() async throws {
        let transport = FakeLLMTransport([
            .status(200, try LLMFixtures.data("models.json")), .status(200, try LLMFixtures.data("summary-fr.sse")),
        ])
        _ = await H.collect(engine(transport, cap: 5).generate(instruction: "a", selection: "abcdefghij")).value
        let messages = try #require(try body(transport.requests.last)["messages"] as? [[String: String]])
        let user = try #require(messages.last?["content"])
        #expect(user.contains("<selection>\nabcde\n</selection>"))
        #expect(user.contains("Only the first 5 characters of the selection are included."))
    }

    /// Cancelling the task that reads the stream, as the controller does on Cancel, cancels the request under way.
    @Test func cancellingTheReaderCancelsTheRequest() async throws {
        let transport = FakeLLMTransport([.status(200, try LLMFixtures.data("models.json")), .pushed(status: 200)])
        let stream = engine(transport).generate(instruction: "a", selection: "b")
        let firstWord = AsyncStream.makeStream(of: Void.self)
        let reader = Task {
            for await event in stream {
                if case .text = event { firstWord.continuation.yield() }
            }
        }
        while transport.requests.count < 2 { try await Task.sleep(for: .milliseconds(2)) }
        transport.push(H.contentLine("Lyon"))
        var iterator = firstWord.stream.makeAsyncIterator()
        await iterator.next()
        reader.cancel()
        await reader.value
        for _ in 0..<200 where !transport.bodyCancelled {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(transport.bodyCancelled)
    }
}
