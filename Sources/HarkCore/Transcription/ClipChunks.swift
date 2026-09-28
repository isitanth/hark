import Foundation

/// Where a clip longer than whisper's 30 s window is cut, so that each chunk is decoded on its own.
///
/// Handed a longer clip in one call, with `no_timestamps` and `single_segment`, whisper moves on a full window
/// whatever it wrote, and prompts each window with the text of the one before. A window that stops early, after a
/// short phrase or at a long pause, loses the rest of its 30 s, and the windows after it follow it down. Measured
/// 2026-09-24 on small q8_0 with synthesized French: 72 s came back as its first 30 s and "Je amuse."; a 15 s pause
/// turned what followed into English. Decoded alone and cut at the hard 30 s marks, the chunk that began mid-word
/// was "d'aider à". Cut at the quietest moment before each mark, the whole text came back.
///
/// So a chunk ends at the first long pause, whose silence is skipped, or else at the quietest 20 ms of its last 5 s.
/// A clip that fits in one window is one chunk, which keeps short dictation exactly as M3 measured it.
public enum ClipChunks {
    /// whisper's window, 30 s at 16 kHz.
    public static let maximumSampleCount = 480_000
    /// Where the quietest moment is looked for: the last 5 s before the window ends.
    public static let searchSampleCount = 80_000
    /// A pause this long ends the chunk: 2 s of frames under `quietRMS`.
    public static let pauseSampleCount = 32_000
    /// Kept on each side of a skipped pause, so a soft word ending or onset is not clipped.
    public static let pauseMarginSampleCount = 4_000
    /// A frame quieter than this is silence: `CapturePolicy`'s floor for a whole capture.
    public static let quietRMS = CapturePolicy.standard.silencePeakRMS
    /// 20 ms, as `SampleBuffer` measures the peak.
    static let frameSampleCount = SampleBuffer.rmsWindow
    /// The step of the quietest-moment search: half a frame.
    static let hopSampleCount = SampleBuffer.rmsWindow / 2

    /// The chunks, in order. Every sample is in at most one; only the silence of a skipped pause is left out, so a
    /// clip of silence past the window leaves only its last quarter second, too quiet to be decoded.
    public static func ranges(for samples: [Float]) -> [Range<Int>] {
        guard samples.count > maximumSampleCount else { return [0..<samples.count] }
        let quiet = quietFrames(samples)
        var chunks: [Range<Int>] = []
        var start = 0
        while start < samples.count {
            let limit = start + maximumSampleCount
            if let pause = firstPause(in: quiet, from: start, before: min(limit, samples.count)) {
                let end = min(pause.lowerBound + pauseMarginSampleCount, limit, samples.count)
                // Anything before the pause is kept, however short: a chunk that turns out to be silence is not decoded.
                if pause.lowerBound > start { chunks.append(start..<end) }
                start = max(end, pause.upperBound - pauseMarginSampleCount)
                continue
            }
            guard limit < samples.count else {
                chunks.append(start..<samples.count)
                break
            }
            let cut = quietestPoint(samples, in: (limit - searchSampleCount)..<limit)
            chunks.append(start..<cut)
            start = cut
        }
        return chunks
    }

    /// RMS of the loudest 20 ms frame, the trailing partial frame included: what `SampleBuffer.peakRMS` reports
    /// for a whole capture, here for one chunk.
    public static func peakRMS(_ samples: ArraySlice<Float>) -> Float {
        var peak: Float = 0
        var index = samples.startIndex
        while index < samples.endIndex {
            let end = min(index + frameSampleCount, samples.endIndex)
            peak = max(peak, rms(samples[index..<end]))
            index = end
        }
        return peak
    }

    // MARK: Internals

    /// One flag per whole 20 ms frame: quieter than `quietRMS`.
    private static func quietFrames(_ samples: [Float]) -> [Bool] {
        stride(from: 0, to: samples.count - frameSampleCount + 1, by: frameSampleCount).map {
            rms(samples[$0..<($0 + frameSampleCount)]) < quietRMS
        }
    }

    /// The first run of quiet frames at least `pauseSampleCount` long that begins in `start..<before`, in
    /// samples. The run may reach past `before`.
    private static func firstPause(in quiet: [Bool], from start: Int, before: Int) -> Range<Int>? {
        let framesNeeded = pauseSampleCount / frameSampleCount
        var frame = (start + frameSampleCount - 1) / frameSampleCount
        while frame < quiet.count, frame * frameSampleCount < before {
            guard quiet[frame] else {
                frame += 1
                continue
            }
            var end = frame
            while end < quiet.count, quiet[end] { end += 1 }
            if end - frame >= framesNeeded { return (frame * frameSampleCount)..<(end * frameSampleCount) }
            frame = end
        }
        return nil
    }

    /// The middle of the quietest 20 ms frame in `range`; the latest one on a tie, so chunks stay long.
    private static func quietestPoint(_ samples: [Float], in range: Range<Int>) -> Int {
        var best = range.upperBound
        var lowest = Float.infinity
        var index = range.lowerBound
        while index + frameSampleCount <= range.upperBound {
            let energy = rms(samples[index..<(index + frameSampleCount)])
            if energy <= lowest {
                lowest = energy
                best = index + frameSampleCount / 2
            }
            index += hopSampleCount
        }
        return best
    }

    private static func rms(_ frame: ArraySlice<Float>) -> Float {
        guard !frame.isEmpty else { return 0 }
        let sum = frame.reduce(Float(0)) { $0 + $1 * $1 }
        return (sum / Float(frame.count)).squareRoot()
    }
}
