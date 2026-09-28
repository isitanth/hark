import Foundation

/// Where the HUD's spectrum window ends in the capture.
///
/// The tap hands audio over 100 ms at a time (4 800 frames at 48 kHz, measured on 2026-09-24). Read as it lands, the
/// spectrum would jump ten times a second and hold still in between. So the window plays the newest buffer out over
/// its own length, as a player would: when a buffer lands the window ends where the one before it did, and it reaches
/// the newest sample as the next buffer is due. The bars trail the voice by one buffer and move at the HUD's rate.
public enum PlayoutCursor {
    /// - Parameters:
    ///   - newest: samples captured so far.
    ///   - lastBuffer: samples the newest tap buffer added.
    ///   - elapsed: time since that buffer landed.
    public static func end(newest: Int, lastBuffer: Int, elapsed: Duration) -> Int {
        let (seconds, attoseconds) = max(elapsed, .zero).components
        let played = Int(seconds) * Int(SampleBuffer.sampleRate) + Int(attoseconds / 62_500_000_000_000)
        let start = max(newest - max(lastBuffer, 0), 0)
        return min(start + played, newest)
    }
}
