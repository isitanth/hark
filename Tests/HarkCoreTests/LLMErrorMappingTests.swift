import Foundation
import HarkCore
import Testing

private typealias H = LLMClientHarness

struct LLMMappingCase: Sendable, CustomTestStringConvertible {
    enum Script: Sendable {
        case answer(FakeLLMTransport.Answer)
        case fixture(status: Int, name: String)
    }

    enum Secrets: Sendable {
        case key
        case missing
        case broken
    }

    /// What the test does to the transport and the clock while the call runs.
    enum Drive: Sendable {
        case nothing
        /// Advance past the connect limit once the request is out.
        case connectLimit
        /// Once the head is in, 15 s with no piece.
        case silence
        /// A heartbeat every 10 s from the head on, until the total limit.
        case heartbeatsPastTotal
    }

    let name: String
    let script: Script
    var secrets: Secrets = .key
    var drive: Drive = .nothing
    let failure: LLMFailure
    let code: String
    /// Nil only when no request was sent.
    var ms: Int? = 0
    /// The SSE fixture whose text pieces come before the failure.
    var textFixture: String?

    var testDescription: String { name }

    func answer() throws -> FakeLLMTransport.Answer {
        switch script {
        case .answer(let answer): answer
        case .fixture(let status, let name): .status(status, try LLMFixtures.data(name))
        }
    }
}

let llmMappingCases: [LLMMappingCase] = [
    .init(
        name: "refused", script: .answer(.refuse), failure: .notRunning(endpoint: "127.0.0.1:8002"),
        code: "llm_unreachable"),
    .init(
        name: "401", script: .fixture(status: 401, name: "unauthorized-401.json"), failure: .keyRefused,
        code: "llm_unauthorized"),
    .init(
        name: "no Keychain item", script: .answer(.refuse), secrets: .missing, failure: .noKey,
        code: "llm_unauthorized", ms: nil),
    .init(
        name: "a Keychain error", script: .answer(.refuse), secrets: .broken, failure: .noKey,
        code: "llm_unauthorized", ms: nil),
    .init(
        name: "the head never comes", script: .answer(.hang), drive: .connectLimit, failure: .noAnswer,
        code: "llm_timeout", ms: 2000),
    .init(
        name: "15 s of silence", script: .answer(.pushed(status: 200)), drive: .silence, failure: .noAnswer,
        code: "llm_timeout", ms: 15_000),
    .init(
        name: "heartbeats past the total", script: .answer(.pushed(status: 200)), drive: .heartbeatsPastTotal,
        failure: .noAnswer, code: "llm_timeout", ms: 60_000),
    .init(
        name: "500", script: .fixture(status: 500, name: "server-error-500.json"),
        failure: .server(status: 500, message: "Model is still loading, try again in a minute"),
        code: "llm_error:500"),
    .init(
        name: "404 not JSON", script: .answer(.status(404, Data("Not Found".utf8))),
        failure: .server(status: 404, message: nil), code: "llm_error:404"),
    .init(
        name: "an error in the stream", script: .fixture(status: 200, name: "error-in-stream.sse"),
        failure: .server(status: nil, message: "The model crashed while generating"), code: "llm_error",
        textFixture: "error-in-stream.sse"),
    .init(
        name: "thinking only", script: .fixture(status: 200, name: "thinking-on.sse"), failure: .empty,
        code: "llm_empty"),
    .init(
        name: "transport other", script: .answer(.fail(.other(code: -1017))),
        failure: .server(status: nil, message: nil), code: "llm_error"),
]

@Suite struct LLMErrorMappingTests {
    @Test(arguments: llmMappingCases)
    func mapsToItsFailureAndCode(_ row: LLMMappingCase) async throws {
        let transport = FakeLLMTransport([try row.answer()])
        let clock = ManualClock()
        let secrets =
            switch row.secrets {
            case .key: H.secrets()
            case .missing: FakeSecretStore()
            case .broken: FakeSecretStore([H.profile.name: H.key], failure: SecretStoreError(status: -25_293))
            }
        let client = H.client(transport, secrets: secrets, clock: clock)
        let events = H.collect(client.complete(H.messages, model: LLMFixtures.model, profile: H.profile))
        await Self.run(row.drive, transport: transport, clock: clock)
        let received = await events.value

        #expect(received.failure == row.failure)
        #expect(row.failure.pipelineFailure.code == row.code)
        #expect(received.terminals.count == 1)
        #expect(received.summary?.ms == row.ms)
        #expect(received.texts == (try row.textFixture.map(H.texts(inFixture:)) ?? []))
        if row.ms == nil { #expect(transport.requests.isEmpty) }
    }

    @Test func heartbeatsBeforeTheFirstWordKeepTheCallAlive() async {
        let transport = FakeLLMTransport([.pushed(status: 200)])
        let clock = ManualClock()
        let client = H.client(transport, clock: clock)
        let events = H.collect(client.complete(H.messages, model: LLMFixtures.model, profile: H.profile))
        // total and connect, then silence once the head is in.
        await clock.waitForSleeps(3)
        for beat in 1...5 {
            clock.advance(by: .seconds(10))
            transport.push(": keep-alive\n")
            await clock.waitForSleeps(3 + beat)
        }
        transport.push(H.contentLine("Bonjour"))
        transport.push("data: [DONE]\n\n")
        let received = await events.value

        #expect(received.texts == ["Bonjour"])
        #expect(received.terminals.count == 1)
        guard case .finished(let summary) = received.last else {
            Issue.record("not finished: \(received)")
            return
        }
        #expect(summary.ms == 50_000)
    }

    private static func run(_ drive: LLMMappingCase.Drive, transport: FakeLLMTransport, clock: ManualClock) async {
        switch drive {
        case .nothing:
            return
        case .connectLimit:
            await clock.waitForSleeps(2)
            clock.advance(by: .seconds(2))
        case .silence:
            await clock.waitForSleeps(3)
            clock.advance(by: .seconds(15))
        case .heartbeatsPastTotal:
            await clock.waitForSleeps(3)
            for beat in 1...5 {
                clock.advance(by: .seconds(10))
                transport.push(": keep-alive\n")
                await clock.waitForSleeps(3 + beat)
            }
            clock.advance(by: .seconds(10))
        }
    }
}

struct ImageRefusalCase: Sendable, CustomTestStringConvertible {
    let fixture: String
    let status: Int
    /// The failure when the request carried an image; without one, it is always `.server(status, message)`.
    let withImage: LLMFailure?
    var testDescription: String { fixture }
}

/// Report a5, §4: each refusal with and without an image in the request.
@Suite struct LLMImageRefusalTests {
    static let model = LLMFixtures.model

    static let cases: [ImageRefusalCase] = [
        .init(fixture: "no-vision-400.json", status: 400, withImage: .noVision(model: model, reason: .noVision)),
        .init(
            fixture: "vision-ar-mode-400.json", status: 400, withImage: .noVision(model: model, reason: .needsMTPMode)),
        .init(fixture: "openai-no-vision-400.json", status: 400, withImage: .noVision(model: model, reason: .noVision)),
        .init(
            fixture: "llamacpp-no-mmproj-500.json", status: 500, withImage: .noVision(model: model, reason: .noVision)),
        .init(fixture: "mlxlm-text-only-404.json", status: 404, withImage: .noVision(model: model, reason: .noVision)),
        .init(
            fixture: "vllm-not-multimodal-400.json", status: 400, withImage: .noVision(model: model, reason: .noVision)),
        .init(fixture: "anthropic-image-too-large-400.json", status: 400, withImage: nil),
        .init(fixture: "probable-400.json", status: 400, withImage: nil),
        .init(fixture: "server-error-500.json", status: 500, withImage: nil),
    ]

    private func failure(_ row: ImageRefusalCase, image: Bool) async throws -> LLMFailure? {
        let body = try LLMFixtures.data(row.fixture)
        let transport = FakeLLMTransport([.status(row.status, body)])
        var parts: [ContentPart] = [.text("Combien ?")]
        if image { parts.insert(.image(ImagePart(data: Data([1]))), at: 0) }
        let events = await H.collect(
            H.client(transport).complete(
                [ChatMessage(role: .user, parts: parts)], model: Self.model, profile: H.profile)
        ).value
        guard case .failed(let failure, _) = events.last else { return nil }
        return failure
    }

    @Test(arguments: cases)
    func withAnImage(_ row: ImageRefusalCase) async throws {
        let server = LLMFailure.server(
            status: row.status, message: LLMErrorBody.message(in: try LLMFixtures.data(row.fixture)))
        #expect(try await failure(row, image: true) == (row.withImage ?? server))
    }

    @Test(arguments: cases)
    func withoutAnImageTheMappingIsTodays(_ row: ImageRefusalCase) async throws {
        let message = LLMErrorBody.message(in: try LLMFixtures.data(row.fixture))
        #expect(try await failure(row, image: false) == .server(status: row.status, message: message))
    }

    @Test(arguments: [401, 403, 413, 429, 503])
    func anotherStatusIsNeverNoVision(_ status: Int) {
        #expect(LLMFailure.imageRefusal(status: status, message: "image input is not supported", model: "m") == nil)
    }

    @Test func visionAndNotSupportedTogetherAreCertain() {
        #expect(
            LLMFailure.imageRefusal(status: 400, message: "Vision is NOT SUPPORTED here", model: nil)
                == .noVision(model: nil, reason: .noVision))
        #expect(LLMFailure.imageRefusal(status: 400, message: "vision tower loading", model: nil) == nil)
        #expect(LLMFailure.imageRefusal(status: 400, message: nil, model: nil) == nil)
    }
}
