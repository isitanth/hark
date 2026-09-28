import Foundation

/// Silence padding for short clips.
///
/// whisper's encoder always consumes a 30 s window, yet clips under about a second come back with zero segments:
/// the mel tail is too short for the conv stack, and the decoder emits the end token before any text. A dictated
/// "yes" or "undo" lands well inside that hole, so every one of them would log `discarded / empty_transcript`.
///
/// Padding is free: the encoder is billed for `audio_ctx` states whatever the clip length, and `DecodeSpec` never
/// asks for fewer than the floor anyway. The zeros go on the tail so the speech keeps its original offset.
public enum SamplePadding {
    /// Shortest clip that decodes reliably. 1 s is the observed cliff; the extra 250 ms is margin.
    public static let minimumDurationMs = 1_250
    public static let minimumSampleCount = minimumDurationMs * Int(SampleBuffer.sampleRate) / 1_000

    /// The clip, extended with trailing silence to `minimumSampleCount`. Longer clips are returned untouched.
    public static func padded(_ samples: [Float]) -> [Float] {
        let deficit = minimumSampleCount - samples.count
        guard deficit > 0 else { return samples }
        var padded = samples
        padded.reserveCapacity(minimumSampleCount)
        padded.append(contentsOf: repeatElement(0, count: deficit))
        return padded
    }

    /// What `padded` will return for a clip of `count` samples, without building it.
    public static func paddedCount(for count: Int) -> Int {
        max(count, minimumSampleCount)
    }
}
