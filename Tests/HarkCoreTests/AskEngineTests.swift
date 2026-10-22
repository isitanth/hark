import CoreGraphics
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

    /// No selection: the assistant's rules and the request alone.
    @Test func theAssistantSendsItsOwnPrompt() async throws {
        let transport = FakeLLMTransport([
            .status(200, try LLMFixtures.data("models.json")), .status(200, try LLMFixtures.data("summary-fr.sse")),
        ])
        _ = await H.collect(engine(transport).generate(instruction: "Quelle heure est-il à Tokyo ?", selection: nil))
            .value
        let messages = try #require(try body(transport.requests.last)["messages"] as? [[String: String]])
        #expect(messages.first?["content"] == AskPrompt.assistantSystem)
        #expect(messages.last?["content"] == AskPrompt(request: "Quelle heure est-il à Tokyo ?").messages[1].content)
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

/// An image ask: the image part goes only to a model not known to be blind, and each answer teaches the verdict.
@Suite(.timeLimit(.minutes(1)))
struct AskEngineImageTests {
    static let image = ImagePart(data: Data([0x89, 0x50, 0x4E, 0x47]))

    private func engine(
        _ transport: FakeLLMTransport, model: ModelChoice = .auto, vision: VisionCapability = VisionCapability()
    ) -> AskEngine {
        var profile = H.profile
        profile.model = model
        let config = LLMConfig(provider: profile.name, profiles: [profile.name: profile])
        return AskEngine(client: H.client(transport), settings: AskSettings(config), vision: vision)
    }

    private func profile(_ model: ModelChoice) -> ProviderProfile {
        var profile = H.profile
        profile.model = model
        return profile
    }

    @Test func anImageAskSendsTheImagePromptAndLearnsTheModelSees() async throws {
        let transport = FakeLLMTransport([
            .status(200, try LLMFixtures.data("models.json")), .status(200, try LLMFixtures.data("summary-fr.sse")),
        ])
        let engine = engine(transport)
        let events = await H.collect(
            engine.generate(instruction: "Combien ?", selection: nil, image: Self.image)
        ).value
        #expect(events.texts.joined() == LLMFixtures.summaryText)
        let data = try #require(transport.requests.last?.httpBody)
        let sent = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let messages = try #require(sent["messages"] as? [[String: Any]])
        #expect(messages.first?["content"] as? String == AskPrompt.imageSystem)
        let parts = try #require(messages.last?["content"] as? [[String: Any]])
        #expect(parts.map { $0["type"] as? String } == ["image_url", "text"])
        #expect(engine.vision.verdict(profile: profile(.auto), model: LLMFixtures.model) == true)
    }

    @Test func aModelTheListSaysIsBlindIsNeverSentTheImage() async throws {
        let transport = FakeLLMTransport([.status(200, try LLMFixtures.data("models-no-vision.json"))])
        let events = await H.collect(
            engine(transport).generate(instruction: "Combien ?", selection: "x", image: Self.image)
        ).value
        #expect(
            events == [.failed(.noVision(model: LLMFixtures.model, reason: .knownBeforeSending), LLMCallSummary())])
        #expect(transport.requests.map { $0.url?.lastPathComponent } == ["models"])
    }

    @Test func aRefusalTeachesTheNextAskToSendNothing() async throws {
        let transport = FakeLLMTransport([.status(400, try LLMFixtures.data("no-vision-400.json"))])
        let vision = VisionCapability()
        let engine = engine(transport, model: .named("text-only"), vision: vision)
        let first = await H.collect(engine.generate(instruction: "a", selection: nil, image: Self.image)).value
        #expect(first.failure == .noVision(model: "text-only", reason: .noVision))
        #expect(vision.verdict(profile: profile(.named("text-only")), model: "text-only") == false)
        let second = await H.collect(engine.generate(instruction: "a", selection: nil, image: Self.image)).value
        #expect(second.failure == .noVision(model: "text-only", reason: .knownBeforeSending))
        #expect(transport.requests.count == 1)
    }

    @Test func aTextAskStillGoesToABlindModel() async throws {
        let transport = FakeLLMTransport([.status(200, try LLMFixtures.data("summary-fr.sse"))])
        let vision = VisionCapability()
        vision.record(false, profile: profile(.named("text-only")), model: "text-only")
        let events = await H.collect(
            engine(transport, model: .named("text-only"), vision: vision).generate(instruction: "a", selection: "b")
        ).value
        #expect(events.texts.joined() == LLMFixtures.summaryText)
    }

    /// AR mode is the server's, not the model's: a restart in MTP mode lets the same model see.
    @Test func anARModeRefusalTeachesNothing() async throws {
        let transport = FakeLLMTransport([.status(400, try LLMFixtures.data("vision-ar-mode-400.json"))])
        let engine = engine(transport, model: .named("bonsai"))
        let events = await H.collect(engine.generate(instruction: "a", selection: nil, image: Self.image)).value
        #expect(events.failure == .noVision(model: "bonsai", reason: .needsMTPMode))
        #expect(engine.vision.verdict(profile: profile(.named("bonsai")), model: "bonsai") == nil)
    }
}

/// A follow-up (M12): the pinned model, no probe, nothing sent after a profile switch or with a frame missing.
@Suite(.timeLimit(.minutes(1)))
struct AskEngineThreadTests {
    static let image = ImagePart(data: Data([0x89, 0x50, 0x4E, 0x47]))
    static let region = RegionSummary(rect: .zero, pixelWidth: 10, pixelHeight: 10, bytes: 4, displayID: 1)

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

    private static func thread(framedTurnOne: Bool = false, pin: ProfilePin? = nil) -> AskThread {
        AskThread(
            rootID: UtteranceID(1), kind: .selection, selection: "Lyon.",
            pin: pin ?? ProfilePin(profile: profile(), requestedModel: "pinned-model"),
            turns: [
                AskTurn(
                    id: UtteranceID(1), instruction: "Résume.", reply: "Lyon, en bref.",
                    region: framedTurnOne ? region : nil)
            ])
    }

    private func body(_ request: URLRequest?) throws -> [String: Any] {
        let data = try #require(request?.httpBody)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func turnOnesFinishedSummaryCarriesThePin() async throws {
        let transport = FakeLLMTransport([
            .status(200, try LLMFixtures.data("models.json")), .status(200, try LLMFixtures.data("summary-fr.sse")),
        ])
        let events = await H.collect(engine(transport).generate(instruction: "a", selection: "b")).value
        #expect(events.summary?.pin == ProfilePin(profile: Self.profile(), requestedModel: LLMFixtures.model))
    }

    @Test func turnOnesFailureCarriesThePinItWentTo() async {
        let transport = FakeLLMTransport([.refuse])
        let named = Self.profile(.named("qwen3-8b"))
        let events = await H.collect(engine(transport, profile: named).generate(instruction: "a", selection: "b"))
            .value
        #expect(
            events == [
                .failed(
                    .notRunning(endpoint: H.endpoint),
                    LLMCallSummary(ms: 0, pin: ProfilePin(profile: named, requestedModel: "qwen3-8b")))
            ])
    }

    @Test func aFollowUpAsksThePinnedModelWithoutListingTheModels() async throws {
        let transport = FakeLLMTransport([.status(200, try LLMFixtures.data("summary-fr.sse"))])
        let events = await H.collect(
            engine(transport).generate(
                instruction: "Plus court.", selection: "Lyon.", image: nil, thread: Self.thread(), frames: [:])
        ).value
        #expect(events.texts.joined() == LLMFixtures.summaryText)
        #expect(events.summary?.pin == nil)
        #expect(transport.requests.map { $0.url?.lastPathComponent } == ["completions"])
        let sent = try body(transport.requests.first)
        #expect(sent["model"] as? String == "pinned-model")
        let messages = try #require(sent["messages"] as? [[String: String]])
        #expect(messages.map { $0["role"] } == ["system", "user", "assistant", "user"])
        #expect(messages[2]["content"] == "Lyon, en bref.")
        #expect(messages[3]["content"]?.hasPrefix(AskPrompt.followUpLeadLine) == true)
    }

    @Test(arguments: [
        profile(.auto, baseURL: "http://127.0.0.1:9000/v1"), profile(.named("pinned-model")),
        ProviderProfile.claude,
    ])
    func aProfileSwitchSendsNothing(_ active: ProviderProfile) async {
        let transport = FakeLLMTransport([.refuse])
        let events = await H.collect(
            engine(transport, profile: active).generate(
                instruction: "a", selection: "Lyon.", image: nil, thread: Self.thread(), frames: [:])
        ).value
        #expect(events == [.failed(.profileChanged, LLMCallSummary())])
        #expect(transport.requests.isEmpty)
    }

    @Test func aMissingFrameSendsNothing() async {
        let transport = FakeLLMTransport([.refuse])
        let events = await H.collect(
            engine(transport).generate(
                instruction: "a", selection: "Lyon.", image: nil, thread: Self.thread(framedTurnOne: true), frames: [:])
        ).value
        #expect(events == [.failed(.frameMissing, LLMCallSummary())])
        #expect(transport.requests.isEmpty)
    }

    /// The frame is turn 1's; this turn brings none. The request still holds an image, so a blind model gets nothing.
    @Test func aBlindModelWithAnEarlierFrameIsRefusedBeforeSending() async {
        let transport = FakeLLMTransport([.refuse])
        let vision = VisionCapability()
        vision.record(false, profile: Self.profile(), model: "pinned-model")
        let events = await H.collect(
            engine(transport, vision: vision).generate(
                instruction: "a", selection: "Lyon.", image: nil, thread: Self.thread(framedTurnOne: true),
                frames: [UtteranceID(1): Self.image])
        ).value
        #expect(events == [.failed(.noVision(model: "pinned-model", reason: .knownBeforeSending), LLMCallSummary())])
        #expect(transport.requests.isEmpty)
    }

    @Test func aBlindModelWithThisTurnsFrameIsRefusedBeforeSending() async {
        let transport = FakeLLMTransport([.refuse])
        let vision = VisionCapability()
        vision.record(false, profile: Self.profile(), model: "pinned-model")
        let events = await H.collect(
            engine(transport, vision: vision).generate(
                instruction: "a", selection: "Lyon.", image: Self.image, thread: Self.thread(), frames: [:])
        ).value
        #expect(events.failure == .noVision(model: "pinned-model", reason: .knownBeforeSending))
        #expect(transport.requests.isEmpty)
    }

    /// An earlier frame teaches the verdict as an image ask does.
    @Test func aFollowUpOnAFramedThreadLearnsTheModelSees() async throws {
        let transport = FakeLLMTransport([.status(200, try LLMFixtures.data("summary-fr.sse"))])
        let engine = engine(transport)
        _ = await H.collect(
            engine.generate(
                instruction: "a", selection: "Lyon.", image: nil, thread: Self.thread(framedTurnOne: true),
                frames: [UtteranceID(1): Self.image])
        ).value
        #expect(engine.vision.verdict(profile: Self.profile(), model: "pinned-model") == true)
    }

    @Test func cancellingAFollowUpClosesTheStream() async throws {
        let transport = FakeLLMTransport([.pushed(status: 200)])
        let stream = engine(transport).generate(
            instruction: "a", selection: "Lyon.", image: nil, thread: Self.thread(), frames: [:])
        let firstWord = AsyncStream.makeStream(of: Void.self)
        let reader = Task {
            for await event in stream {
                if case .text = event { firstWord.continuation.yield() }
            }
        }
        while transport.requests.isEmpty { try await Task.sleep(for: .milliseconds(2)) }
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
