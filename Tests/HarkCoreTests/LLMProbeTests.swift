import Foundation
import HarkCore
import Testing

private typealias H = LLMClientHarness

struct LLMProbeCase: Sendable, CustomTestStringConvertible {
    let name: String
    let answer: FakeLLMTransport.Answer?
    var model: ModelChoice = .auto
    var hasKey = true
    let result: LLMProbeResult

    var testDescription: String { name }
}

@Suite struct LLMProbeTests {
    static let cases: [LLMProbeCase] = [
        .init(name: "models.json", answer: nil, result: .connected(model: LLMFixtures.model)),
        .init(name: "a named model", answer: nil, model: .named("qwen3-8b"), result: .connected(model: "qwen3-8b")),
        .init(
            name: "401", answer: .status(401, Data(#"{"error":{"message":"missing or invalid API key"}}"#.utf8)),
            result: .failed(.keyRefused)),
        .init(name: "refused", answer: .refuse, result: .failed(.notRunning(endpoint: H.endpoint))),
        .init(name: "no key", answer: .refuse, hasKey: false, result: .failed(.noKey)),
        .init(
            name: "an empty list", answer: .status(200, Data(#"{"object":"list","data":[]}"#.utf8)),
            result: .failed(.server(status: 200, message: nil))),
        .init(
            name: "not a list", answer: .status(200, Data("<html>".utf8)),
            result: .failed(.server(status: 200, message: nil))),
    ]

    @Test(arguments: cases)
    func answers(_ row: LLMProbeCase) async throws {
        let answer = try row.answer ?? .status(200, LLMFixtures.data("models.json"))
        let transport = FakeLLMTransport([answer])
        let client = H.client(transport, secrets: row.hasKey ? H.secrets() : FakeSecretStore())
        var profile = H.profile
        profile.model = row.model
        #expect(await LLMProbe(client: client).check(profile) == row.result)
        #expect(transport.requests.count == (row.hasKey ? 1 : 0))
    }

    @Test func getsModelsUnderTheBaseWithTheKey() async throws {
        let transport = FakeLLMTransport([.status(200, try LLMFixtures.data("models.json"))])
        _ = await LLMProbe(client: H.client(transport)).check(H.profile)
        let request = try #require(transport.requests.first)
        #expect(request.url?.absoluteString == "http://127.0.0.1:8002/v1/models")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(H.key)")
    }

    @Test func aHeadThatNeverComesIsNoAnswerAfterTheConnectLimit() async {
        let transport = FakeLLMTransport([.hang])
        let clock = ManualClock()
        let probe = LLMProbe(client: H.client(transport, clock: clock))
        let result = Task { await probe.check(H.profile) }
        await clock.waitForSleeps(2)
        clock.advance(by: .seconds(2))
        #expect(await result.value == .failed(.noAnswer))
    }

    @Test func aBodyThatNeverEndsIsNoAnswerAfterTheProbeLimit() async {
        let transport = FakeLLMTransport([.pushed(status: 200)])
        let clock = ManualClock()
        let probe = LLMProbe(client: H.client(transport, clock: clock))
        let result = Task { await probe.check(H.profile) }
        await clock.waitForSleeps(2)
        clock.advance(by: .seconds(4))
        transport.push(#"{"object":"list","#)
        clock.advance(by: .seconds(1))
        #expect(await result.value == .failed(.noAnswer))
    }
}
