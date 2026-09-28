import Foundation

/// The engine `PipelineEnvironment` is built with, so the model behind it can change without rebuilding the
/// pipeline.
///
/// `PipelineController` takes its environment once, at launch, when no model is necessarily installed yet. The
/// Model tab has to be able to point it at a `Transcriber` later — and at a different one when the user picks
/// another tier — so the environment holds this instead of the real engine.
public actor SwappableTranscriptionEngine: TranscriptionEngine {
    private var current: any TranscriptionEngine
    /// Engines replaced whose unload has not returned yet: a swap unloads behind a decode still in flight, and quitting
    /// has to wait for those as well as for the engine in use.
    private var retiring: [UInt64: any TranscriptionEngine] = [:]
    private var nextRetiring: UInt64 = 0
    private var closed = false

    public init(_ initial: any TranscriptionEngine = NullTranscriptionEngine(tier: .small)) {
        current = initial
    }

    /// Points the pipeline at `engine` and releases the one it replaces.
    ///
    /// The old engine is unloaded rather than cancelled: a decode in flight belongs to an utterance that is
    /// still being resolved, and `Transcriber` serialises its unload behind that decode anyway.
    /// After `shutdown`, `engine` is shut down in turn and never used: a model picked, or loaded at launch, while the
    /// app quits must not bring a context back.
    public func replace(with engine: any TranscriptionEngine) async {
        guard !closed else {
            await engine.shutdown()
            return
        }
        let previous = current
        current = engine
        let key = nextRetiring
        nextRetiring += 1
        retiring[key] = previous
        await previous.unload()
        retiring[key] = nil
    }

    public func transcribe(_ samples: [Float]) async throws(PipelineFailure) -> Transcript {
        guard !closed else { throw .quitting }
        // Resolved before the await, so a swap mid-decode cannot move an utterance to a different model.
        let engine = current
        return try await engine.transcribe(samples)
    }

    /// Whether a replaced engine is still unloading. For tests.
    public var isRetiring: Bool { !retiring.isEmpty }

    /// Cancels what is decoding, then waits for the engine in use and every one still being retired to let go.
    public func shutdown() async {
        closed = true
        let engines = [current] + Array(retiring.values)
        for engine in engines {
            await engine.cancel()
        }
        for engine in engines {
            await engine.shutdown()
        }
    }

    public func cancel() async {
        await current.cancel()
    }

    public func unload() async {
        await current.unload()
    }
}
