import Foundation

/// Stand-in until a model is installed (M2): every utterance fails with `modelMissing`, so every press still logs one line.
public struct NullTranscriptionEngine: TranscriptionEngine {
    public let tier: ModelTier

    public init(tier: ModelTier) {
        self.tier = tier
    }

    public func transcribe(_ samples: [Float]) async throws(PipelineFailure) -> Transcript {
        throw .modelMissing(tier)
    }

    public func cancel() async {}
}
