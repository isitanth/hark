import Foundation

public struct Transcript: Sendable, Equatable {
    public var raw: String
    /// Set by the resolver. Nil until the utterance has been resolved.
    public var normalized: String?
    /// The tier whose model produced this transcript, stamped by the engine. The log's `model_tier`.
    public var tier: ModelTier?

    public init(raw: String, normalized: String? = nil, tier: ModelTier? = nil) {
        self.raw = raw
        self.normalized = normalized
        self.tier = tier
    }

    var isBlank: Bool {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
