import Foundation

/// A conversation in the Ask panel (M12): turn 1's context and every answered turn, so a follow-up's request is built
/// again whole. It lives in the pipeline's state, so it holds no pixels: a framed turn keeps its `RegionSummary`, and
/// its image stays in the controller's store until the conversation ends.
public struct AskThread: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// Turn 1 was about selected text: follow-ups revise the previous result, and Replace stays guarded on turn 1's
        /// selection while no turn has carried a frame.
        case selection
        /// Turn 1 was the assistant: a request with nothing selected.
        case assistant
    }

    /// The most turns a conversation holds, turn 1 included.
    public static let maxTurns = 6
    /// The most frames a conversation holds, and their encoded bytes: under Anthropic's request size once base64 is
    /// added.
    public static let maxFrames = 3
    public static let maxFrameBytes = 20_000_000
    /// The most characters of history a follow-up carries: every earlier turn's instruction and reply.
    public static let maxHistoryChars = 24_000

    /// Turn 1's utterance: the panel keys its reset on it.
    public let rootID: UtteranceID
    public let kind: Kind
    /// Turn 1's selected text, as the intent held it; nil on an assistant thread.
    public let selection: String?
    /// The answered turns, oldest first. The turn in review or parked is not among them yet.
    public private(set) var turns: [AskTurn]
    /// Where turn 1's request went: a follow-up goes there or nowhere.
    public let pin: ProfilePin

    public init(rootID: UtteranceID, kind: Kind, selection: String?, pin: ProfilePin, turns: [AskTurn] = []) {
        self.rootID = rootID
        self.kind = kind
        self.selection = selection
        self.pin = pin
        self.turns = turns
    }

    /// Whether any answered turn carried a frame: from then on the thread follows the image rules.
    public var framed: Bool { turns.contains { $0.region != nil } }

    /// The answered turns' instructions and replies, in characters.
    public var historyChars: Int { turns.reduce(0) { $0 + $1.instruction.count + $1.reply.count } }

    public func appending(_ turn: AskTurn) -> AskThread {
        var thread = self
        thread.turns.append(turn)
        return thread
    }
}

/// One answered turn of a conversation.
public struct AskTurn: Sendable, Equatable {
    public let id: UtteranceID
    /// What the model got: the transcript, or what followed a spoken prefix.
    public let instruction: String
    /// The model's raw reply, its `%%` line included, never the answer as the user edited it: each history message is
    /// sent byte for byte again on every later turn.
    public let reply: String
    /// The frame this turn brought: its size and place, never its bytes.
    public let region: RegionSummary?

    public init(id: UtteranceID, instruction: String, reply: String, region: RegionSummary?) {
        self.id = id
        self.instruction = instruction
        self.reply = reply
        self.region = region
    }
}

/// The profile a conversation started on: its name, what `VisionCapability` compares to tell a profile edited in place
/// (base URL, api, model choice), and the model turn 1 asked for. A follow-up goes only where this still names the
/// active profile, so a selection or a frame never crosses from this Mac to a remote API unless the user chooses it.
public struct ProfilePin: Sendable, Equatable {
    public let name: String
    public let baseURL: URL
    public let api: ProviderAPI
    public let model: ModelChoice
    /// The id turn 1 requested: the profile's named model, or the one `.auto` found.
    public let requestedModel: String

    public init(name: String, baseURL: URL, api: ProviderAPI, model: ModelChoice, requestedModel: String) {
        self.name = name
        self.baseURL = baseURL
        self.api = api
        self.model = model
        self.requestedModel = requestedModel
    }

    public init(profile: ProviderProfile, requestedModel: String) {
        self.init(
            name: profile.name, baseURL: profile.baseURL, api: profile.api, model: profile.model,
            requestedModel: requestedModel)
    }

    /// Whether `profile` is the one this pin names: the same name and the same signature.
    public func matches(_ profile: ProviderProfile) -> Bool {
        name == profile.name && baseURL == profile.baseURL && api == profile.api && model == profile.model
    }
}

/// The answered turn a follow-up started from, kept whole until the follow-up has words: Esc, or a follow-up with none,
/// returns to it. Indirect, because a context cannot hold a context directly.
public indirect enum ParkedTurn: Sendable, Equatable {
    case turn(UtteranceContext, Transcript)

    public var context: UtteranceContext {
        switch self {
        case .turn(let context, _): context
        }
    }

    public var transcript: Transcript {
        switch self {
        case .turn(_, let transcript): transcript
        }
    }
}

/// The frames a conversation already holds, before the turn being captured.
public struct FrameTally: Sendable, Equatable {
    public var count: Int
    public var bytes: Int

    public init(count: Int, bytes: Int) {
        self.count = count
        self.bytes = bytes
    }
}

extension UtteranceContext {
    /// The turns of this ask's conversation: the thread's answered turns, plus the turn in review (before a follow-up)
    /// or the parked one (during a follow-up's capture). 1 for an ask with no follow-up.
    public var conversationTurns: Int { (thread?.turns.count ?? 0) + 1 }

    /// The frames of the thread's turns and of the parked turn: what a new frame in this turn would join.
    public var earlierFrames: FrameTally {
        var regions = thread?.turns.compactMap(\.region) ?? []
        if let region = parked?.context.region { regions.append(region) }
        return FrameTally(count: regions.count, bytes: regions.reduce(0) { $0 + $1.bytes })
    }

    /// Whether this turn may take a frame: always when the drag replaces its own, otherwise while the earlier frames are
    /// under both caps.
    public var acceptsFrame: Bool {
        guard region == nil else { return true }
        let earlier = earlierFrames
        return earlier.count < AskThread.maxFrames && earlier.bytes < AskThread.maxFrameBytes
    }

    /// Whether the conversation can take no further turn, for the answer in review whose instruction is `instruction`:
    /// `maxTurns` reached, or the history a follow-up would carry at `maxHistoryChars`.
    public func conversationFull(instruction: String) -> Bool {
        let history = (thread?.historyChars ?? 0) + instruction.count + (reply?.count ?? 0)
        return conversationTurns >= AskThread.maxTurns || history >= AskThread.maxHistoryChars
    }
}
