import Foundation

/// Turns a transcript into a decision. `UtteranceResolver` implements it: `CommandMatcher`, then `FocusResolver`.
public protocol UtteranceResolving: Sendable {
    func resolve(_ transcript: Transcript, focus: FocusSnapshot?) async -> (normalized: String?, decision: Decision)
}

/// `TextInserter` implements it.
public protocol TextInserting: Sendable {
    /// `clipboardFallback` is the preference: with it off, an insertion that fails leaves nothing behind, so a
    /// paste nobody read has to give the user's pasteboard back instead of keeping the text on it.
    func insert(
        _ text: String, plan: InsertionPlan, focus: FocusSnapshot?, clipboardFallback: Bool
    ) async throws(PipelineFailure)
}

/// `ActionRunner` implements it. Returns the exit code; 0 is success.
public protocol ActionRunning: Sendable {
    func run(_ command: ResolvedCommand) async throws(PipelineFailure) -> Int32
}

/// The environment's default, for tests that do not care where text goes: every transcript is copied, as if the
/// clipboard were the destination the user chose, and normalized like a real resolver would.
public struct ClipboardSinkResolver: UtteranceResolving {
    public init() {}

    public func resolve(_ transcript: Transcript, focus: FocusSnapshot?) async -> (
        normalized: String?, decision: Decision
    ) {
        (Normalizer.normalize(transcript.raw), .copy(.chosen))
    }
}

/// The environment's default: every insertion fails, so the reducer's fallback is what runs.
public struct NullTextInserter: TextInserting {
    public init() {}

    public func insert(
        _ text: String, plan: InsertionPlan, focus: FocusSnapshot?, clipboardFallback: Bool
    ) async throws(PipelineFailure) {
        throw .insertionFailed
    }
}

/// Refuses every command, for environments that never run one.
public struct NullActionRunner: ActionRunning {
    public init() {}

    public func run(_ command: ResolvedCommand) async throws(PipelineFailure) -> Int32 {
        throw .actionLaunch
    }
}

/// Everything `PipelineController` calls. Workspace and pasteboard are AppKit-backed and come from HarkApp.
public struct PipelineEnvironment: Sendable {
    public var clock: any WallClock
    public var audio: any AudioInput
    public var engine: any TranscriptionEngine
    public var resolver: any UtteranceResolving
    public var workspace: any Workspace
    public var focus: any FocusProbing
    public var pasteboard: any PasteboardFacade
    public var confirmation: any ConfirmationPrompter
    public var inserter: any TextInserting
    public var actions: any ActionRunning

    public init(
        workspace: any Workspace,
        pasteboard: any PasteboardFacade,
        clock: any WallClock = SystemWallClock(),
        focus: (any FocusProbing)? = nil,
        audio: any AudioInput = NullAudioInput(),
        engine: any TranscriptionEngine = NullTranscriptionEngine(tier: .small),
        resolver: any UtteranceResolving = ClipboardSinkResolver(),
        confirmation: any ConfirmationPrompter = NullConfirmationPrompter(),
        inserter: any TextInserting = NullTextInserter(),
        actions: any ActionRunning = NullActionRunner()
    ) {
        self.clock = clock
        self.audio = audio
        self.engine = engine
        self.resolver = resolver
        self.workspace = workspace
        self.focus = focus ?? WorkspaceFocusProbe(workspace: workspace)
        self.pasteboard = pasteboard
        self.confirmation = confirmation
        self.inserter = inserter
        self.actions = actions
    }
}
