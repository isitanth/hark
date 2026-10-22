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
    /// the selection is still selected in the caller, so Insert would paste over it (M11 review R2).
    public static func apply(_ utterance: UtteranceContext?) -> AskApply {
        switch utterance?.intent {
        case .assist(let caller)?:
            return insertOrCopy(utterance, caller: caller)
        case .ask? where utterance?.region != nil:
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
