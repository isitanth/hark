import CoreGraphics
import Foundation
import HarkCore
import Testing

/// The conversation's state (M12): its turns, its pin, and the caps the context counts against.
@Suite struct AskThreadTests {
    static let pin = ProfilePin(profile: LLMClientHarness.profile, requestedModel: "gemma")

    static func region(bytes: Int = 1_000) -> RegionSummary {
        RegionSummary(
            rect: CGRect(x: 0, y: 0, width: 10, height: 10), pixelWidth: 20, pixelHeight: 20, bytes: bytes,
            displayID: 1)
    }

    static func turn(_ n: UInt64, region: RegionSummary? = nil, instruction: String = "do", reply: String = "done")
        -> AskTurn
    {
        AskTurn(id: UtteranceID(n), instruction: instruction, reply: reply, region: region)
    }

    /// A context whose thread holds `answered` turns, the frames in `framedTurns` (1-based).
    static func context(answered: Int, framedTurns: Set<Int> = [], bytes: Int = 1_000) -> UtteranceContext {
        let turns = (1...max(answered, 1)).prefix(answered).map {
            turn(UInt64($0), region: framedTurns.contains($0) ? region(bytes: bytes) : nil)
        }
        var context = UtteranceContext(id: UtteranceID(100), pressedAt: Date(timeIntervalSince1970: 0))
        if answered > 0 {
            context.thread = AskThread(rootID: UtteranceID(1), kind: .selection, selection: "s", pin: pin, turns: turns)
        }
        return context
    }

    @Test func appendingKeepsTheOrderAndLeavesTheOriginal() {
        let thread = AskThread(rootID: UtteranceID(1), kind: .assistant, selection: nil, pin: Self.pin)
        let longer = thread.appending(Self.turn(1)).appending(Self.turn(2, region: Self.region()))
        #expect(thread.turns.isEmpty)
        #expect(longer.turns.map(\.id) == [UtteranceID(1), UtteranceID(2)])
        #expect(longer.rootID == UtteranceID(1) && longer.pin == Self.pin && longer.kind == .assistant)
    }

    @Test(arguments: [([], false), ([2], true), ([1, 3], true)] as [([Int], Bool)])
    func framedWhenAnyTurnHasARegion(_ framed: [Int], _ expected: Bool) {
        #expect(Self.context(answered: 3, framedTurns: Set(framed)).thread?.framed == expected)
    }

    @Test func theHistoryCountsInstructionsAndReplies() {
        let thread = AskThread(
            rootID: UtteranceID(1), kind: .selection, selection: "s", pin: Self.pin,
            turns: [Self.turn(1, instruction: "abc", reply: "de"), Self.turn(2, instruction: "é", reply: "fghi")])
        #expect(thread.historyChars == 10)
    }

    @Test func theReplyIsKeptRaw() {
        let raw = "%% The user wants the sum.\n\n42"
        #expect(Self.turn(1, reply: raw).reply == raw)
    }

    @Test func theCapsAreTheMeasuredOnes() {
        #expect(AskThread.maxTurns == 6 && AskThread.maxFrames == 3)
        #expect(AskThread.maxFrameBytes == 20_000_000 && AskThread.maxHistoryChars == 24_000)
    }

    /// The turn in review counts: 4 answered + 1 is 5 turns, 5 + 1 is 6 (full), 6 + 1 is 7 (full).
    @Test(arguments: [(4, 5, false), (5, 6, true), (6, 7, true)])
    func theConversationIsFullAtSixTurns(_ answered: Int, _ turns: Int, _ full: Bool) {
        let context = Self.context(answered: answered)
        #expect(context.conversationTurns == turns)
        #expect(context.conversationFull(instruction: "x") == full)
    }

    @Test func anAskWithNoThreadIsOneTurn() {
        let context = Self.context(answered: 0)
        #expect(context.conversationTurns == 1 && context.earlierFrames == FrameTally(count: 0, bytes: 0))
        #expect(context.acceptsFrame && !context.conversationFull(instruction: "x"))
    }

    @Test func theHistoryCapCountsTheTurnInReview() {
        var context = Self.context(answered: 1)
        let used = context.thread!.historyChars
        context.reply = String(repeating: "r", count: AskThread.maxHistoryChars - used - 3)
        #expect(!context.conversationFull(instruction: "ab"))
        #expect(context.conversationFull(instruction: "abc"))
    }

    /// Earlier frames are the thread's and the parked turn's.
    @Test(arguments: [(2, true), (3, false), (4, false)])
    func aFrameIsTakenUnderThreeFrames(_ frames: Int, _ accepts: Bool) {
        let context = Self.context(answered: 4, framedTurns: Set(1...frames).filter { $0 <= 4 })
        var parkedFrame = context
        if frames == 4 {
            // The fourth is the parked turn's, not yet among the thread's turns.
            var parkedContext = UtteranceContext(id: UtteranceID(99), pressedAt: Date())
            parkedContext.region = Self.region()
            parkedFrame = Self.context(answered: 3, framedTurns: [1, 2, 3])
            parkedFrame.parked = .turn(parkedContext, Transcript(raw: "x"))
        }
        #expect(parkedFrame.earlierFrames.count == frames)
        #expect(parkedFrame.acceptsFrame == accepts)
    }

    @Test func theParkedTurnsFrameCounts() {
        var parkedContext = UtteranceContext(id: UtteranceID(99), pressedAt: Date())
        parkedContext.region = Self.region(bytes: 500)
        var context = Self.context(answered: 2, framedTurns: [1], bytes: 700)
        context.parked = .turn(parkedContext, Transcript(raw: "x"))
        #expect(context.earlierFrames == FrameTally(count: 2, bytes: 1_200))
        #expect(context.parked?.transcript == Transcript(raw: "x") && context.parked?.context.id == UtteranceID(99))
    }

    @Test func theBytesCapRefusesAFrame() {
        #expect(Self.context(answered: 1, framedTurns: [1], bytes: AskThread.maxFrameBytes - 1).acceptsFrame)
        #expect(!Self.context(answered: 1, framedTurns: [1], bytes: AskThread.maxFrameBytes).acceptsFrame)
    }

    /// A drag that replaces this turn's own frame is not a new frame.
    @Test func aDragReplacingItsOwnFrameIsTakenAtTheCap() {
        var context = Self.context(answered: 3, framedTurns: [1, 2, 3])
        #expect(!context.acceptsFrame)
        context.region = Self.region()
        #expect(context.acceptsFrame)
    }

    @Test(arguments: [
        ("other", "http://127.0.0.1:8002/v1", ProviderAPI.openAI, ModelChoice.auto, false),
        ("local", "http://127.0.0.1:9000/v1", .openAI, .auto, false),
        ("local", "http://127.0.0.1:8002/v1", .anthropic, .auto, false),
        ("local", "http://127.0.0.1:8002/v1", .openAI, .named("gemma"), false),
        ("local", "http://127.0.0.1:8002/v1", .openAI, .auto, true),
    ])
    func aPinMatchesItsNameAndSignature(
        _ name: String, _ url: String, _ api: ProviderAPI, _ model: ModelChoice, _ matches: Bool
    ) {
        var profile = LLMClientHarness.profile
        profile.name = name
        profile.baseURL = URL(string: url)!
        profile.api = api
        profile.model = model
        #expect(Self.pin.matches(profile) == matches)
    }

    @Test func aPinIgnoresWhatDoesNotRouteTheRequest() {
        var profile = LLMClientHarness.profile
        profile.temperature = 0.9
        profile.maxTokens = 99
        #expect(Self.pin.matches(profile))
        #expect(Self.pin.requestedModel == "gemma")
    }
}
