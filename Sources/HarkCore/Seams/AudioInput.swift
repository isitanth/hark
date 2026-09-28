import Foundation

/// Capture that ends without a `stop` call.
public enum AudioInputEvent: Sendable, Equatable {
    /// The length limit was reached while the trigger was still held. The capture is over; the utterance goes on
    /// with what was captured.
    case reachedMaxDuration(UtteranceID, CaptureSummary)
    /// The input device went away, or the engine could not continue after a configuration change.
    case interrupted(UtteranceID, PipelineFailure)
}

/// The microphone. `AudioCapture` is the real implementation.
public protocol AudioInput: Sendable {
    /// Unsolicited events. `PipelineController` consumes this stream for its whole life.
    var events: AsyncStream<AudioInputEvent> { get }
    func start(_ id: UtteranceID) async throws(PipelineFailure)
    func stop(_ id: UtteranceID) async throws(PipelineFailure) -> CapturedAudio
    func cancel(_ id: UtteranceID) async
}

/// Every press fails with `noInputDevice`, so it still logs one line. Used where no microphone is wanted.
public struct NullAudioInput: AudioInput {
    public let events = AsyncStream<AudioInputEvent> { $0.finish() }

    public init() {}

    public func start(_ id: UtteranceID) async throws(PipelineFailure) {
        throw .noInputDevice
    }

    public func stop(_ id: UtteranceID) async throws(PipelineFailure) -> CapturedAudio {
        throw .noInputDevice
    }

    public func cancel(_ id: UtteranceID) async {}
}
