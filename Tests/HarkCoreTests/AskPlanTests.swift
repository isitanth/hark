import CoreGraphics
import Foundation
import HarkCore
import Testing

private typealias H = LLMClientHarness
private typealias S = PlanSheets

/// The engine's planner (M13): one schema-constrained request per plan, with the same profile, pin and gates as an
/// answer.
@Suite(.timeLimit(.minutes(1)))
struct AskPlanTests {
    static let region = RegionSummary(rect: .zero, pixelWidth: 10, pixelHeight: 10, bytes: 4, displayID: 1)
    static let reply = Data((H.contentLine("{\\\"formula\\\": \\\"C4\\\"}") + "data: [DONE]\n\n").utf8)

    private static func profile(_ model: ModelChoice = .auto, baseURL: String? = nil) -> ProviderProfile {
        var profile = H.profile
        profile.model = model
        if let baseURL { profile.baseURL = URL(string: baseURL)! }
        return profile
    }

    private func engine(
        _ transport: FakeLLMTransport, profile: ProviderProfile = profile(),
        vision: VisionCapability = VisionCapability()
    ) -> AskEngine {
        let config = LLMConfig(provider: profile.name, profiles: [profile.name: profile])
        return AskEngine(client: H.client(transport), settings: AskSettings(config), vision: vision)
    }

    private static func thread() -> AskThread {
        AskThread(
            rootID: UtteranceID(1), kind: .assistant, selection: nil,
            pin: ProfilePin(profile: profile(), requestedModel: "pinned-model"),
            turns: [
                AskTurn(
                    id: UtteranceID(1), instruction: "Total ?", reply: "%% You want the total.\n\n2.50",
                    region: region, sheet: S.one, formula: "SUM(C4)")
            ])
    }

    private func body(_ request: URLRequest?) throws -> [String: Any] {
        let data = try #require(request?.httpBody)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func plan(
        _ engine: AskEngine, thread: AskThread? = nil, frames: [UtteranceID: ImagePart] = [:],
        correction: PlanCorrection? = nil
    ) -> AsyncStream<LLMEvent> {
        engine.plan(
            instruction: "Total ?", sheet: S.one, selection: nil, image: S.image, thread: thread, frames: frames,
            correction: correction)
    }

    @Test func aPlanIsOneRequestUnderTheSchemaWithThePinOnTurnOne() async throws {
        let transport = FakeLLMTransport([.status(200, try LLMFixtures.data("models.json")), .status(200, Self.reply)])
        let events = await H.collect(plan(engine(transport))).value
        #expect(events.texts.joined() == #"{"formula": "C4"}"#)
        #expect(events.terminals.count == 1)
        guard case .finished = events.last else {
            Issue.record("expected finished")
            return
        }
        #expect(events.summary?.pin == ProfilePin(profile: Self.profile(), requestedModel: LLMFixtures.model))
        #expect(transport.requests.map { $0.url?.lastPathComponent } == ["models", "completions"])
        let sent = try body(transport.requests.last)
        #expect(sent["model"] as? String == LLMFixtures.model)
        let format = try #require(sent["response_format"] as? [String: Any])
        let schema = try #require(format["json_schema"] as? [String: Any])
        #expect(schema["name"] as? String == CalculationPlan.schema.name)
        let messages = try #require(sent["messages"] as? [[String: Any]])
        #expect(messages.first?["content"] as? String == PlanPrompt.system)
        #expect(messages.count == 2)
    }

    @Test func aNamedModelIsAskedWithoutAProbe() async throws {
        let transport = FakeLLMTransport([.status(200, Self.reply)])
        _ = await H.collect(plan(engine(transport, profile: Self.profile(.named("gemma"))))).value
        #expect(transport.requests.map { $0.url?.lastPathComponent } == ["completions"])
        #expect(try body(transport.requests.first)["model"] as? String == "gemma")
    }

    @Test func aFollowUpPlansWithThePinnedModelAndNoProbe() async throws {
        let transport = FakeLLMTransport([.status(200, Self.reply)])
        let events = await H.collect(plan(engine(transport), thread: Self.thread(), frames: [UtteranceID(1): S.image]))
            .value
        #expect(events.summary?.pin == nil)
        #expect(transport.requests.map { $0.url?.lastPathComponent } == ["completions"])
        let sent = try body(transport.requests.first)
        #expect(sent["model"] as? String == "pinned-model")
        #expect(sent["response_format"] != nil)
        let messages = try #require(sent["messages"] as? [[String: Any]])
        #expect(messages.map { $0["role"] as? String } == ["system", "user", "assistant", "user"])
        #expect(messages[2]["content"] as? String == "%% You want the total.\n\n2.50\nFormula: SUM(C4)")
    }

    @Test(arguments: [
        profile(.auto, baseURL: "http://127.0.0.1:9000/v1"), profile(.named("pinned-model")), ProviderProfile.claude,
    ])
    func aProfileSwitchSendsNothing(_ active: ProviderProfile) async {
        let transport = FakeLLMTransport([.refuse])
        let events = await H.collect(
            plan(engine(transport, profile: active), thread: Self.thread(), frames: [UtteranceID(1): S.image])
        ).value
        #expect(events == [.failed(.profileChanged, LLMCallSummary())])
        #expect(transport.requests.isEmpty)
    }

    @Test func aMissingFrameSendsNothing() async {
        let transport = FakeLLMTransport([.refuse])
        let events = await H.collect(plan(engine(transport), thread: Self.thread(), frames: [:])).value
        #expect(events == [.failed(.frameMissing, LLMCallSummary())])
        #expect(transport.requests.isEmpty)
    }

    @Test func aBlindModelIsRefusedBeforeSending() async {
        let transport = FakeLLMTransport([.refuse])
        let vision = VisionCapability()
        let named = Self.profile(.named("text-only"))
        vision.record(false, profile: named, model: "text-only")
        let events = await H.collect(plan(engine(transport, profile: named, vision: vision))).value
        #expect(events == [.failed(.noVision(model: "text-only", reason: .knownBeforeSending), LLMCallSummary())])
        #expect(transport.requests.isEmpty)
    }

    @Test func aCorrectionSendsTheOriginalMessagesThenTheTwo() async throws {
        let first = FakeLLMTransport([.status(200, Self.reply)])
        let named = Self.profile(.named("gemma"))
        _ = await H.collect(plan(engine(first, profile: named))).value
        let second = FakeLLMTransport([.status(200, Self.reply)])
        let correction = PlanCorrection(reply: #"{"formula":"C9"}"#, note: "C9 is not in the listing")
        _ = await H.collect(plan(engine(second, profile: named), correction: correction)).value
        let original = try #require(try body(first.requests.first)["messages"] as? [[String: Any]])
        let retried = try #require(try body(second.requests.first)["messages"] as? [[String: Any]])
        #expect(retried.count == original.count + 2)
        #expect(retried[original.count]["role"] as? String == "assistant")
        #expect(retried[original.count]["content"] as? String == #"{"formula":"C9"}"#)
        #expect(
            retried.last?["content"] as? String
                == "Hark could not use that plan: C9 is not in the listing. Reply with a corrected plan.")
        let originalBytes = try JSONSerialization.data(withJSONObject: original, options: [.sortedKeys])
        let prefixBytes = try JSONSerialization.data(
            withJSONObject: Array(retried.prefix(original.count)), options: [.sortedKeys])
        #expect(originalBytes == prefixBytes)
    }

    @Test func aFailureCarriesThePinAndPassesThrough() async throws {
        let transport = FakeLLMTransport([
            .status(200, try LLMFixtures.data("models.json")),
            .status(400, Data(#"{"error":{"message":"response_format unsupported"}}"#.utf8)),
        ])
        let events = await H.collect(plan(engine(transport))).value
        #expect(events.failure == .formatRefused(model: LLMFixtures.model))
        #expect(events.summary?.pin == ProfilePin(profile: Self.profile(), requestedModel: LLMFixtures.model))
    }

    @Test func generateSendsNoFormat() async throws {
        let transport = FakeLLMTransport([.status(200, try LLMFixtures.data("summary-fr.sse"))])
        _ = await H.collect(
            engine(transport, profile: Self.profile(.named("gemma"))).generate(
                instruction: "Total ?", selection: nil, image: S.image)
        ).value
        #expect(try body(transport.requests.first)["response_format"] == nil)
    }

    /// Cancelling the reader, as the controller does on Cancel, cancels the plan under way.
    @Test func cancellingTheReaderCancelsThePlan() async throws {
        let transport = FakeLLMTransport([.pushed(status: 200)])
        let stream = plan(engine(transport, profile: Self.profile(.named("gemma"))))
        let firstPiece = AsyncStream.makeStream(of: Void.self)
        let reader = Task {
            for await event in stream {
                if case .text = event { firstPiece.continuation.yield() }
            }
        }
        while !transport.bodyOpen { try await Task.sleep(for: .milliseconds(2)) }
        transport.push(H.contentLine("{"))
        var iterator = firstPiece.stream.makeAsyncIterator()
        await iterator.next()
        reader.cancel()
        await reader.value
        for _ in 0..<200 where !transport.bodyCancelled {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(transport.bodyCancelled)
    }
}
