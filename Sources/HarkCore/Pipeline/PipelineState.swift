import Foundation

public struct UtteranceID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UInt64

    public init(_ rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public var description: String { "#\(rawValue)" }
}

/// Everything learned about one utterance on its way through the pipeline.
public struct UtteranceContext: Sendable, Equatable {
    public let id: UtteranceID
    public let pressedAt: Date
    public let intent: CaptureIntent
    public var releasedAt: Date?
    public var focus: FocusSnapshot?
    public var capture: CaptureSummary?
    public var transcribeMs: Int?
    public var action: ActionType?
    /// The `clipboardFallback` preference as the resolver read it, so an insertion that fails knows whether the
    /// clipboard may catch the text.
    public var clipboardFallback = true
    /// The model id that answered an ask, and the time from its request to the last token. Nil with no LLM call.
    public var llmModel: String?
    public var llmMs: Int?
    /// What an ask's Copy or Replace applies: the suggestion as the user left it in the popup. Never logged; nil for
    /// dictation, where the transcript is the text.
    public var answer: String?

    public init(id: UtteranceID, pressedAt: Date, intent: CaptureIntent = .dictate) {
        self.id = id
        self.pressedAt = pressedAt
        self.intent = intent
    }
}

public enum ConfirmationStage: Sendable, Equatable {
    case awaitingAnswer
    case restoringFocus
}

/// Where an ask is after its instruction was heard.
public enum AskStage: Sendable, Equatable {
    /// The request is out and the answer streams into the popup, outside the reducer.
    case generating
    /// The answer is complete and waits for Copy, Replace or Cancel.
    case reviewing
    /// The server failed. The popup offers Retry; Cancel ends the ask with this failure on its line.
    case failed(LLMFailure)
    /// Replace was chosen: the caller is being brought back and its selection checked before anything is written.
    case replacing
}

public enum PipelineState: Sendable, Equatable {
    case idle
    case capturing(UtteranceContext)
    case transcribing(UtteranceContext)
    case resolving(UtteranceContext, Transcript)
    case confirming(UtteranceContext, Transcript, ResolvedCommand, ConfirmationStage)
    case acting(UtteranceContext, Transcript, ResolvedCommand)
    case inserting(UtteranceContext, Transcript, InsertionPlan)
    case copying(UtteranceContext, Transcript, ClipboardReason)
    /// An ask, once its instruction is transcribed. The transcript is the instruction.
    case asking(UtteranceContext, Transcript, AskStage)

    public var phase: PipelinePhase {
        switch self {
        case .idle: .idle
        case .capturing: .capturing
        case .transcribing: .transcribing
        case .resolving: .resolving
        case .confirming: .confirming
        case .acting: .acting
        case .inserting: .inserting
        case .copying: .copying
        case .asking: .asking
        }
    }

    public var context: UtteranceContext? {
        switch self {
        case .idle: nil
        case .capturing(let context), .transcribing(let context): context
        case .resolving(let context, _), .confirming(let context, _, _, _), .acting(let context, _, _),
            .inserting(let context, _, _), .copying(let context, _, _), .asking(let context, _, _):
            context
        }
    }

    /// The instruction and the stage while the state is `.asking`, for the popup.
    public var ask: AskProgress? {
        guard case .asking(_, let transcript, let stage) = self else { return nil }
        return AskProgress(instruction: transcript.raw, stage: stage)
    }
}

/// What the Ask panel shows of `.asking`: the instruction as heard, and the stage.
public struct AskProgress: Sendable, Equatable {
    public var instruction: String
    public var stage: AskStage

    public init(instruction: String, stage: AskStage) {
        self.instruction = instruction
        self.stage = stage
    }
}

public enum PipelinePhase: String, Sendable, CaseIterable {
    case idle
    case capturing
    case transcribing
    case resolving
    case confirming
    case acting
    case inserting
    case copying
    case asking
}
