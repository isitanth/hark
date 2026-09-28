import Foundation
import HarkCore
import Testing

private typealias H = LLMClientHarness

struct BaseURLCase: Sendable, CustomTestStringConvertible {
    let base: String
    var testDescription: String { base }
}

let baseURLCases: [BaseURLCase] = [.init(base: "http://127.0.0.1:8002/v1"), .init(base: "http://127.0.0.1:8002/v1/")]

@Suite struct LLMClientTests {
    /// The request of one call answered 500, so it ends at once.
    private func request(for profile: ProviderProfile) async throws -> URLRequest {
        let transport = FakeLLMTransport([.status(500, Data())])
        let client = H.client(transport)
        _ = await H.collect(client.complete(H.messages, model: LLMFixtures.model, profile: profile)).value
        return try #require(transport.requests.first)
    }

    private func body(of request: URLRequest) throws -> [String: Any] {
        let data = try #require(request.httpBody)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test(arguments: baseURLCases)
    func postsToChatCompletionsUnderTheBase(_ row: BaseURLCase) async throws {
        var profile = H.profile
        profile.baseURL = try #require(URL(string: row.base))
        let request = try await request(for: profile)
        #expect(request.url?.absoluteString == "http://127.0.0.1:8002/v1/chat/completions")
        #expect(request.httpMethod == "POST")
    }

    @Test func sendsTheThreeHeaders() async throws {
        let request = try await request(for: H.profile)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Accept") == "text/event-stream")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(H.key)")
    }

    @Test func sendsNoAuthorizationWithoutAKey() async throws {
        var profile = H.profile
        profile.key = .none
        let request = try await request(for: profile)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func bodyHasTheStandardFieldsAndExtraAtTheTop() async throws {
        let body = try body(of: try await request(for: H.profile))
        #expect(
            Set(body.keys) == ["model", "messages", "stream", "max_tokens", "temperature", "enable_thinking"])
        #expect(body["model"] as? String == LLMFixtures.model)
        #expect(body["stream"] as? Bool == true)
        #expect(body["max_tokens"] as? Int == ProviderProfile.defaultMaxTokens)
        #expect(body["temperature"] as? Double == ProviderProfile.defaultTemperature)
        #expect(body["enable_thinking"] as? Bool == false)
        let messages = try #require(body["messages"] as? [[String: String]])
        #expect(messages == H.messages.map { ["role": $0.role.rawValue, "content": $0.content] })
        #expect(body["response_format"] == nil)
        #expect(body["stream_options"] == nil)
    }

    /// The parser refuses these names in `extra`; a profile built in code gets the standard fields anyway.
    @Test func extraCannotOverrideTheStandardFields() async throws {
        var profile = H.profile
        profile.extra = [
            "stream": .bool(false), "model": .string("other"), "max_tokens": .int(1), "temperature": .double(2),
            "response_format": .string("json_object"), "stream_options": .string("x"),
        ]
        let body = try body(of: try await request(for: profile))
        #expect(body["stream"] as? Bool == true)
        #expect(body["model"] as? String == LLMFixtures.model)
        #expect(body["max_tokens"] as? Int == ProviderProfile.defaultMaxTokens)
        #expect(body["temperature"] as? Double == ProviderProfile.defaultTemperature)
        #expect(body["response_format"] == nil)
        #expect(body["stream_options"] == nil)
    }

    @Test func extraKeepsEachScalarType() async throws {
        var profile = H.profile
        profile.extra = ["top_k": .int(20), "top_p": .double(0.8), "seed_name": .string("hark"), "flag": .bool(true)]
        let body = try body(of: try await request(for: profile))
        #expect(body["top_k"] as? Int == 20)
        #expect(body["top_p"] as? Double == 0.8)
        #expect(body["seed_name"] as? String == "hark")
        #expect(body["flag"] as? Bool == true)
    }

    @Test func streamsTheSummaryInPiecesThenFinishes() async throws {
        let transport = FakeLLMTransport([.pushed(status: 200)])
        let clock = ManualClock()
        let client = H.client(transport, clock: clock)
        let events = H.collect(client.complete(H.messages, model: LLMFixtures.model, profile: H.profile))
        await clock.waitForSleeps(3)
        clock.advance(by: .milliseconds(900))
        let data = try LLMFixtures.data("summary-fr.sse")
        for start in stride(from: 0, to: data.count, by: 97) {
            transport.push(data.subdata(in: start..<min(start + 97, data.count)))
        }
        transport.endBody()
        let received = await events.value

        #expect(received.texts.joined() == LLMFixtures.summaryText)
        #expect(!received.texts.contains(""))
        #expect(received.terminals.count == 1)
        #expect(
            received.last
                == .finished(
                    LLMCallSummary(
                        model: LLMFixtures.model, ms: 900, finishReason: "stop", promptTokens: 94,
                        completionTokens: 24)))
    }

    @Test func aBodyThatEndsWithoutDoneStillFinishes() async throws {
        let transport = FakeLLMTransport([.status(200, Data(H.contentLine("Oui").utf8))])
        let received = await H.collect(
            H.client(transport).complete(H.messages, model: LLMFixtures.model, profile: H.profile)
        ).value
        #expect(received.texts == ["Oui"])
        #expect(received.last == .finished(LLMCallSummary(model: LLMFixtures.model, ms: 0)))
    }

    @Test func aConsumerThatStopsEndsTheBodyAndHearsNothingMore() async throws {
        let transport = FakeLLMTransport([.pushed(status: 200)])
        let clock = ManualClock()
        let client = H.client(transport, clock: clock)
        let stream = client.complete(H.messages, model: LLMFixtures.model, profile: H.profile)
        let consumer = Task {
            var events: [LLMEvent] = []
            for await event in stream {
                events.append(event)
                withUnsafeCurrentTask { $0?.cancel() }
            }
            return events
        }
        await clock.waitForSleeps(3)
        transport.push(H.contentLine("Lyon"))
        let received = await consumer.value
        for _ in 0..<500 where !transport.bodyCancelled {
            try await Task.sleep(for: .milliseconds(2))
        }
        transport.push(H.contentLine(" et Nantes"))
        transport.push("data: [DONE]\n\n")

        #expect(received == [.text("Lyon")])
        #expect(transport.bodyCancelled)
    }
}
