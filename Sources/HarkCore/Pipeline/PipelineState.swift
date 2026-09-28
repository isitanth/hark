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

public enum PipelineState: Sendable, Equatable {
    case idle
    case capturing(UtteranceContext)
    case transcribing(UtteranceContext)
    case resolving(UtteranceContext, Transcript)
    case confirming(UtteranceContext, Transcript, ResolvedCommand, ConfirmationStage)
    case acting(UtteranceContext, Transcript, ResolvedCommand)
    case inserting(UtteranceContext, Transcript, InsertionPlan)
    case copying(UtteranceContext, Transcript, ClipboardReason)

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
        }
    }

    public var context: UtteranceContext? {
        switch self {
        case .idle: nil
        case .capturing(let context), .transcribing(let context): context
        case .resolving(let context, _), .confirming(let context, _, _, _), .acting(let context, _, _),
            .inserting(let context, _, _), .copying(let context, _, _):
            context
        }
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
}
