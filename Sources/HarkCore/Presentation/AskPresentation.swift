import Foundation

/// What the Ask panel shows.
public enum AskPanelState: Sendable, Equatable {
    /// No ask in flight, or its answer is being applied: the panel is closed and the caller is brought back.
    case closed
    case listening
    case transcribing
    /// The instruction is heard; a drag is still open and the request waits for the framed region.
    case awaitingRegion
    /// The request is out and no word has come yet.
    case thinking
    case streaming
    /// The answer is complete and editable.
    case reviewing
    case failed(LLMFailure)
    /// The framed region did not become an image.
    case regionFailed(RegionFailure)
}

/// What the reviewed answer can do besides Copy.
public enum AskApply: Sendable, Equatable {
    /// An ask about a selection: the answer goes in its place.
    case replace
    /// The assistant with a text field focused at the press: the answer goes in at the caret.
    case insert
    /// The assistant with nowhere to write: Copy is the only way out.
    case copyOnly
}

/// The Ask panel's state from the pipeline alone, so HarkApp renders it and computes nothing.
public enum AskPresentation {
    /// How long "Thinking…" stands alone before it names the server it waits for.
    public static let namesServerAfter = Duration.seconds(3)
    /// The same for an ask that sent a frame: reading an image takes a local model 10 to 15 s before the first word
    /// (M11 live checks), a wait that is normal, not a server that is stuck.
    public static let namesServerAfterFrame = Duration.seconds(10)

    /// - Parameter streamed: the answer so far (`PipelineController.askUpdates`) holds text for this utterance.
    public static func state(_ snapshot: PipelineSnapshot, streamed: Bool) -> AskPanelState {
        guard let utterance = snapshot.utterance, utterance.intent.isAsk else { return .closed }
        switch snapshot.phase {
        case .capturing:
            return .listening
        case .transcribing:
            return .transcribing
        case .asking:
            switch snapshot.ask?.stage {
            case .awaitingRegion?: return .awaitingRegion
            case .generating?: return streamed ? .streaming : .thinking
            case .reviewing?: return .reviewing
            case .failed(let failure)?: return .failed(failure)
            case .regionFailed(let failure)?: return .regionFailed(failure)
            case .replacing?, nil: return .closed
            }
        case .idle, .resolving, .confirming, .acting, .inserting, .copying:
            return .closed
        }
    }

    /// Insert is offered when the probe at the press found, in the app the key was pressed in, somewhere a paste or an
    /// AX insertion would land (the rule the panel's Paste follows), and not in a secure field. An ask that carries a
    /// framed region never offers Replace: an image has no text to replace. About a selection, it offers Copy alone:
    /// the selection is still selected in the caller, so Insert would paste over it (M11 review R2). A conversation
    /// follows the same rule from its first framed turn on (M12).
    public static func apply(_ utterance: UtteranceContext?) -> AskApply {
        switch utterance?.intent {
        case .assist(let caller)?:
            return insertOrCopy(utterance, caller: caller)
        case .ask? where utterance?.region != nil || utterance?.thread?.framed == true:
            return .copyOnly
        case .ask?, .dictate?, nil: return .replace
        }
    }

    private static func insertOrCopy(_ utterance: UtteranceContext?, caller: AppIdentity?) -> AskApply {
        guard let caller, utterance?.focus?.app?.processID == caller.processID,
            FocusResolver.pastePlan(focus: utterance?.focus) != nil
        else { return .copyOnly }
        return .insert
    }

    /// The selection as the panel quotes it: its first two lines' worth, whitespace collapsed.
    public static func quote(_ selection: String, limit: Int = 160) -> String {
        let collapsed = selection.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        return collapsed.prefix(limit) + "…"
    }
}

/// One earlier turn of a conversation, as the panel's transcript shows it: folded to its instruction and the answer's
/// first line until a click unfolds it.
public struct AskTurnRow: Sendable, Equatable, Identifiable {
    public let id: UtteranceID
    /// What the model got for this turn.
    public let instruction: String
    /// The reply's `%%` line, from the first framed turn on; nil before, or when the reply has none.
    public let restatement: String?
    /// The reply without its restatement.
    public let answer: String
    /// The frame this turn brought; the panel finds its thumbnail by the row's id.
    public let region: RegionSummary?

    public init(id: UtteranceID, instruction: String, restatement: String?, answer: String, region: RegionSummary?) {
        self.id = id
        self.instruction = instruction
        self.restatement = restatement
        self.answer = answer
        self.region = region
    }

    /// The answer's first line with words, for the folded row.
    public var firstLine: String {
        answer.split(whereSeparator: \.isNewline)
            .lazy.map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
    }
}

/// The footer's line while an answer is in review.
public enum AskFooterHint: Sendable, Equatable {
    /// The Ask key asks again in the same conversation; `turn` of `of` turns are taken.
    case followUp(turn: Int, of: Int)
    /// The conversation holds as many turns, or as much history, as it may: Copy, Replace or Esc end it.
    case full
}

extension AskPresentation {
    /// How long the busy nudge stays: a talk key pressed while the panel shows.
    public static let busyNudgeFor = Duration.seconds(2)

    /// The nudge shows only over an open panel; with the panel closed a busy press says nothing, as before M12.
    public static func showsBusyNudge(_ state: AskPanelState) -> Bool { state != .closed }

    /// The utterance the panel's reset keys on: turn 1 of the conversation, so a follow-up keeps the earlier turns.
    public static func threadRoot(_ utterance: UtteranceContext) -> UtteranceID {
        utterance.thread?.rootID ?? utterance.id
    }

    /// The earlier turns, oldest first: the thread's answered turns, then the parked one during a follow-up. From the
    /// first framed turn on, every reply carries a `%%` restatement, which the row shows apart.
    public static func earlierTurns(_ utterance: UtteranceContext?) -> [AskTurnRow] {
        guard let utterance else { return [] }
        var framed = false
        var rows: [AskTurnRow] = []
        for turn in utterance.thread?.turns ?? [] {
            framed = framed || turn.region != nil
            rows.append(row(turn.id, turn.instruction, turn.reply, turn.region, framed: framed))
        }
        if let parked = utterance.parked {
            let context = parked.context
            framed = framed || context.region != nil
            rows.append(
                row(
                    context.id, context.request ?? parked.transcript.raw, context.reply ?? "", context.region,
                    framed: framed))
        }
        return rows
    }

    private static func row(
        _ id: UtteranceID, _ instruction: String, _ reply: String, _ region: RegionSummary?, framed: Bool
    ) -> AskTurnRow {
        guard framed else {
            return AskTurnRow(id: id, instruction: instruction, restatement: nil, answer: reply, region: region)
        }
        let split = IntentSplit.split(reply, complete: true)
        return AskTurnRow(
            id: id, instruction: instruction, restatement: split.intent, answer: split.answer, region: region)
    }

    /// The live turn's reply starts with a restatement: this turn sent a frame, or an earlier one did.
    public static func expectsRestatement(_ utterance: UtteranceContext) -> Bool {
        utterance.sentContext?.contains("region") == true || utterance.thread?.framed == true
    }

    /// Replace is offered only while no turn has carried a frame: an image has no text to replace.
    public static func allowsReplace(_ utterance: UtteranceContext) -> Bool {
        utterance.region == nil && !expectsRestatement(utterance)
    }

    /// Ask without the image, after a failure: only when this turn's frame is the conversation's only one. With an
    /// earlier frame the retry would carry it again and fail the same way.
    public static func offersAskWithoutImage(_ utterance: UtteranceContext) -> Bool {
        utterance.region != nil && utterance.earlierFrames.count == 0 && utterance.thread?.framed != true
    }

    /// The turns whose thumbnails the panel keeps, by the controller's rule for the pixels: the live turn with a frame
    /// (or one on its way), the parked turn with one, and the thread's framed turns.
    public static func framedTurns(_ utterance: UtteranceContext?) -> Set<UtteranceID> {
        guard let utterance else { return [] }
        var ids = Set(utterance.thread?.turns.filter { $0.region != nil }.map(\.id) ?? [])
        if utterance.region != nil || utterance.regionPending { ids.insert(utterance.id) }
        if let parked = utterance.parked?.context, parked.region != nil { ids.insert(parked.id) }
        return ids
    }

    /// The footer's line, in review only: how to follow up and the turns taken, or that the conversation is full.
    public static func footerHint(_ snapshot: PipelineSnapshot) -> AskFooterHint? {
        guard state(snapshot, streamed: true) == .reviewing, let utterance = snapshot.utterance else { return nil }
        if utterance.conversationFull(instruction: snapshot.ask?.instruction ?? "") { return .full }
        return .followUp(turn: utterance.conversationTurns, of: AskThread.maxTurns)
    }
}
