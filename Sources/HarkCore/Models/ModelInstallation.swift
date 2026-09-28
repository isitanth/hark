import Foundation

/// A model that passed verification and is ready to load. `ModelStore` produces it, `Transcriber` consumes it.
public struct ModelInstallation: Sendable, Equatable {
    public let tier: ModelTier
    /// The ggml weights, e.g. `.../models/ggml-small-q8_0.bin`.
    public let weights: URL
    /// The compiled Core ML encoder, when one is installed.
    ///
    /// whisper.cpp does not take this path as a parameter; it derives it from `weights`. See
    /// `coreMLEncoderURL(for:)`, which is the single place that spelling lives.
    public let coreMLEncoder: URL?

    public init(tier: ModelTier, weights: URL, coreMLEncoder: URL? = nil) {
        self.tier = tier
        self.weights = weights
        self.coreMLEncoder = coreMLEncoder
    }

    /// Where whisper.cpp will look for the Core ML encoder that belongs to `weights`.
    ///
    /// It drops the extension, drops a trailing quantisation suffix, and appends `-encoder.mlmodelc`. The
    /// second step is the one worth knowing: there is one encoder per model, shared by every quantisation of
    /// it, so `ggml-small-q8_0.bin` and `ggml-small.bin` both resolve to `ggml-small-encoder.mlmodelc` — which
    /// is also exactly the name the published archive unpacks under, so nothing needs renaming.
    ///
    /// Observed from whisper.cpp b5130 on 2026-09-21, which logged all three of these paths while looking for
    /// encoders. Getting it wrong is silent: the model still loads, just on Metal alone, and only whisper's own
    /// "failed to load Core ML model" line in the log says otherwise.
    public static func coreMLEncoderURL(for weights: URL) -> URL {
        var stem = weights.deletingPathExtension().lastPathComponent
        if let quantisation = stem.range(of: "-q[0-9]+_[0-9]+$", options: .regularExpression) {
            stem.removeSubrange(quantisation)
        }
        return weights.deletingLastPathComponent()
            .appending(path: "\(stem)-encoder.mlmodelc", directoryHint: .isDirectory)
    }
}
