import Foundation

/// What the Ask panel shows.
public enum AskPanelState: Sendable, Equatable {
    /// No ask in flight, or its answer is being applied: the panel is closed and the caller is brought back.
    case closed
    case listening
    case transcribing
    /// The request is out and no word has come yet.
    case thinking
    case streaming
    /// The answer is complete and editable.
    case reviewing
    case failed(LLMFailure)
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
            case .generating?: return streamed ? .streaming : .thinking
            case .reviewing?: return .reviewing
            case .failed(let failure)?: return .failed(failure)
            case nil: return .closed
            }
        case .idle, .resolving, .confirming, .acting, .inserting, .copying:
            return .closed
        }
    }

    /// The selection as the panel quotes it: its first two lines' worth, whitespace collapsed.
    public static func quote(_ selection: String, limit: Int = 160) -> String {
        let collapsed = selection.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        return collapsed.prefix(limit) + "…"
    }
}
