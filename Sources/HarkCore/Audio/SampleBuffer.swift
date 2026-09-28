import Foundation

/// 16 kHz mono Float32 samples for one utterance. Linear and capped: once full it ignores further input, which is
/// how the length limit reaches the pipeline as `reachedMaxDuration`. The limit ends the capture, not the
/// utterance: what was said until then is transcribed.
public struct SampleBuffer: Sendable {
    public static let sampleRate: Double = 16_000
    /// The length limit of one utterance: about sixty whisper windows to decode, and where a key held down by
    /// accident stops. Thirty minutes is 115 MB of samples by the end, grown as needed and released afterwards.
    public static let defaultMaxDuration: Duration = .seconds(1_800)
    /// One minute of samples: what is reserved up front and kept between utterances. Storage beyond it is what a
    /// long recording grew into, and `reset` gives it back.
    public static let reservedSampleCount = 960_000
    /// 20 ms at 16 kHz.
    public static let rmsWindow = 320

    private static let samplesPerMs = 16
    private static let attosecondsPerSample: Int64 = 62_500_000_000_000

    public private(set) var samples: [Float] = []
    public let capacity: Int

    private var sumOfSquares: Double = 0
    private var windowSumOfSquares: Double = 0
    private var windowFill = 0
    private var peakWindowMeanSquare: Double = 0
    private var livePeakMeanSquare: Double = 0
    private var tailPeakMeanSquare: Double = 0

    public init(maxDuration: Duration = Self.defaultMaxDuration) {
        let (seconds, attoseconds) = maxDuration.components
        let count = seconds * Int64(Self.sampleRate) + attoseconds / Self.attosecondsPerSample
        capacity = Int(clamping: max(0, count))
    }

    public var isFull: Bool { samples.count >= capacity }

    public var durationMs: Int { samples.count / Self.samplesPerMs }

    /// Appends as many samples as fit. Returns true only on the call that fills the buffer.
    @discardableResult
    public mutating func append(_ chunk: some Collection<Float>) -> Bool {
        let room = capacity - samples.count
        guard room > 0, !chunk.isEmpty else { return false }
        if samples.isEmpty {
            samples.reserveCapacity(min(capacity, Self.reservedSampleCount))
        }

        let accepted = chunk.prefix(room)
        samples.append(contentsOf: accepted)
        for sample in accepted {
            let square = Double(sample) * Double(sample)
            sumOfSquares += square
            windowSumOfSquares += square
            windowFill += 1
            if windowFill == Self.rmsWindow {
                let meanSquare = windowSumOfSquares / Double(Self.rmsWindow)
                peakWindowMeanSquare = max(peakWindowMeanSquare, meanSquare)
                livePeakMeanSquare = max(livePeakMeanSquare, meanSquare)
                tailPeakMeanSquare = max(tailPeakMeanSquare, meanSquare)
                windowSumOfSquares = 0
                windowFill = 0
            }
        }
        return samples.count == capacity
    }

    /// Loudest 20 ms window, the trailing partial window included.
    public var peakRMS: Float {
        let partial = windowFill > 0 ? windowSumOfSquares / Double(windowFill) : 0
        return Float(max(peakWindowMeanSquare, partial).squareRoot())
    }

    public var meanRMS: Float {
        samples.isEmpty ? 0 : Float((sumOfSquares / Double(samples.count)).squareRoot())
    }

    /// Returns the loudest completed 20 ms window since the last call and clears it, so a burst between two reads is
    /// held until the next one whatever the tap buffer size. A window still filling counts when it completes, at a
    /// later read. The utterance's own peak, `peakRMS`, is left alone.
    public mutating func takeLevel() -> LevelReading {
        let reading = LevelReading(rms: Float(livePeakMeanSquare.squareRoot()), durationMs: durationMs)
        livePeakMeanSquare = 0
        return reading
    }

    /// The last `maxSamples` samples, or nil when no completed 20 ms window since the last call rose to
    /// `minimumRMS`. Clears its own peak and leaves `takeLevel`'s alone, so the HUD's reads thirty times a second
    /// never starve the live text's gate, and the reverse. Always a copy, like `window(endingAt:count:)`.
    public mutating func takeTail(maxSamples: Int, minimumRMS: Float) -> [Float]? {
        let peak = tailPeakMeanSquare
        tailPeakMeanSquare = 0
        guard Float(peak.squareRoot()) >= minimumRMS else { return nil }
        return window(endingAt: samples.count, count: maxSamples)
    }

    /// A copy of up to `count` samples ending at `end`, both clamped to what is there.
    ///
    /// Always a copy of its own. `Array(samples[a..<b])` hands back the buffer's own storage when the range is the
    /// whole buffer, and the tap's next `append` would then copy the whole reservation, a minute of samples, while
    /// holding the sink's lock.
    public func window(endingAt end: Int, count: Int) -> [Float] {
        let end = min(max(end, 0), samples.count)
        let start = max(end - max(count, 0), 0)
        return samples.withUnsafeBufferPointer { Array(UnsafeBufferPointer(rebasing: $0[start..<end])) }
    }

    public func summary() -> CaptureSummary {
        CaptureSummary(durationMs: durationMs, peakRMS: peakRMS, meanRMS: meanRMS, reachedMaxDuration: isFull)
    }

    /// Empties the buffer. The reserved storage stays for the next utterance; what a long recording grew beyond it
    /// is released.
    public mutating func reset() {
        if samples.count > Self.reservedSampleCount {
            samples = []
        } else {
            samples.removeAll(keepingCapacity: true)
        }
        sumOfSquares = 0
        windowSumOfSquares = 0
        windowFill = 0
        peakWindowMeanSquare = 0
        livePeakMeanSquare = 0
        tailPeakMeanSquare = 0
    }
}
