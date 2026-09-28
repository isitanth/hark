import Foundation

/// What the HUD reads from the capture thirty times a second.
///
/// The level is the loudest 20 ms window since the previous read, so a burst between two reads is never lost
/// whatever size the tap's buffers come in. The time is audio captured, not time since the press: the length limit
/// counts samples, so the timer reaches it exactly when the capture stops.
public struct LevelReading: Sendable, Equatable {
    /// Square root of the loudest 20 ms mean-square completed since the last read; 0 when none completed.
    public var rms: Float
    /// `SampleBuffer.durationMs`: audio captured so far.
    public var durationMs: Int

    public init(rms: Float, durationMs: Int) {
        self.rms = rms
        self.durationMs = durationMs
    }
}

/// The capture's live level. Not an `AudioInput` requirement, so the inputs that have no microphone need not
/// conform. Synchronous and nonisolated: the HUD's reads must never queue behind a start or a stop.
public protocol AudioLevelSource: Sendable {
    /// Returns and clears the peak since the last call; nil when no capture is armed.
    func takeLevel() -> LevelReading?
}

/// The end of the capture in progress, which the live text re-decodes.
public protocol AudioTailSource: Sendable {
    /// A copy of the last `maxSamples` samples, or nil when no 20 ms window since the previous take rose above
    /// `minimumRMS`, or no capture is armed. Clears its own peak, which `takeLevel` leaves alone.
    func takeTail(maxSamples: Int, minimumRMS: Float) -> [Float]?
}

/// The audio behind the HUD's spectrum.
public protocol AudioWindowSource: Sendable {
    /// A copy of the last `count` samples up to where the display has played to at `now` (`PlayoutCursor`), fewer
    /// at the start of a capture; nil when no capture is armed or no buffer has landed yet.
    func window(count: Int, at now: ContinuousClock.Instant) -> [Float]?
}
