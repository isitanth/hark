import Foundation

/// The HUD's live line, and the rule for which partial results may land on it.
///
/// The partial loop cannot see the pipeline, so the check happens here, on the main actor, in the same turn as the
/// write. A cancel followed at once by a press goes capturing -> idle -> capturing, and a result of the first
/// utterance can arrive after the second is armed: a result counts only for the utterance being captured, while
/// the setting is on. The line is cleared when that utterance changes, so every utterance, and every command under
/// the first partial's 3 s, starts with no line.
public struct PartialLine: Sendable, Equatable {
    public private(set) var text: String?
    /// The utterance the line belongs to.
    private var utterance: UtteranceID?

    public init() {}

    /// Clears the line when the setting is off or another utterance is being captured.
    public mutating func follow(_ snapshot: PipelineSnapshot, enabled: Bool) {
        guard enabled else {
            text = nil
            return
        }
        guard snapshot.phase == .capturing, let current = snapshot.utterance?.id else { return }
        if current != utterance {
            utterance = current
            text = nil
        }
    }

    /// Shows `result` when it belongs to the utterance being captured; otherwise drops it and keeps the line.
    /// Returns whether the line took it.
    @discardableResult
    public mutating func accept(_ result: PartialTranscription.Result, snapshot: PipelineSnapshot, enabled: Bool)
        -> Bool
    {
        follow(snapshot, enabled: enabled)
        guard enabled, snapshot.phase == .capturing, result.utterance == snapshot.utterance?.id else { return false }
        let words = result.text.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return false }
        text = words.joined(separator: " ")
        return true
    }
}
