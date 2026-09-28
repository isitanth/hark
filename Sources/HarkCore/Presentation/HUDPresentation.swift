import Foundation

/// What the recording HUD shows.
public enum HUDState: Sendable, Equatable {
    case hidden
    /// Bars, the timer and, when on, the live text. `handsFree` adds the lock beside the timer.
    case listening(handsFree: Bool)
    /// The capture has stopped and the text is not in yet: frozen bars and time over a status line.
    case transcribing(TranscribingReason)

    public enum TranscribingReason: Sendable, Equatable {
        /// The capture stopped at the length limit: "Length limit reached. Transcribing…".
        case limitReached
        /// A clip longer than one whisper window, decoded in chunks: "Transcribing…".
        case longClip
    }
}

/// The HUD's state from the pipeline alone, so HarkApp renders it and computes nothing.
public enum HUDPresentation {
    /// One whisper window. A clip this long or shorter is one chunk, decoded in well under a second, and a
    /// "Transcribing…" line would only flash; a longer one is decoded in chunks and the wait needs saying.
    static let longClipMs = ClipChunks.maximumSampleCount / (Int(SampleBuffer.sampleRate) / 1_000)

    /// - Parameters:
    ///   - lastLevel: the last reading the HUD holds. After a key up the capture's summary is not in the snapshot
    ///     until the stop returns, and a long clip is told from this in that gap.
    ///   - handsFree: `TriggerGate.isLatched`: the capture was started by a tap and goes on with the key up.
    public static func state(_ snapshot: PipelineSnapshot, lastLevel: LevelReading?, handsFree: Bool) -> HUDState {
        switch snapshot.phase {
        case .capturing:
            return .listening(handsFree: handsFree)
        case .transcribing:
            guard let utterance = snapshot.utterance else { return .hidden }
            // The limit stops the capture without a key up, and nothing else leaves `releasedAt` unset here.
            if utterance.releasedAt == nil { return .transcribing(.limitReached) }
            let durationMs = utterance.capture?.durationMs ?? lastLevel?.durationMs ?? 0
            return durationMs > longClipMs ? .transcribing(.longClip) : .hidden
        case .idle, .resolving, .confirming, .acting, .inserting, .copying:
            return .hidden
        }
    }
}
