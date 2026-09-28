import Foundation

/// Speech to text. `Transcriber` (M2) is the whisper.cpp implementation.
public protocol TranscriptionEngine: Sendable {
    func transcribe(_ samples: [Float]) async throws(PipelineFailure) -> Transcript
    func cancel() async
    /// Give up whatever the engine is holding. Swapping the selected model calls this on the one being replaced.
    func unload() async
    /// Give it up for good, because the app is quitting: nothing loads again, and a decode asked for afterwards fails
    /// with `quitting`. `exit()` runs ggml's static destructors, which abort while a whisper context holds buffers.
    func shutdown() async
}

extension TranscriptionEngine {
    /// Engines that hold no model have nothing to release.
    public func unload() async {}
    public func shutdown() async { await unload() }
}
