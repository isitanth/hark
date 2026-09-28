import Foundation

/// What the pipeline needs to know about a finished capture. The samples stay out of reducer state.
public struct CaptureSummary: Sendable, Equatable {
    public var durationMs: Int
    public var peakRMS: Float
    public var meanRMS: Float
    public var reachedMaxDuration: Bool

    public init(durationMs: Int, peakRMS: Float, meanRMS: Float, reachedMaxDuration: Bool = false) {
        self.durationMs = durationMs
        self.peakRMS = peakRMS
        self.meanRMS = meanRMS
        self.reachedMaxDuration = reachedMaxDuration
    }
}

/// 16 kHz mono Float32 samples plus their summary, as returned by `AudioInput.stop`.
public struct CapturedAudio: Sendable {
    public var summary: CaptureSummary
    public var samples: [Float]

    public init(summary: CaptureSummary, samples: [Float]) {
        self.summary = summary
        self.samples = samples
    }
}

/// Decides, before transcription, whether a capture is worth transcribing. A capture cut at the length limit is
/// judged like any other: only its duration and its loudness count.
public struct CapturePolicy: Sendable, Equatable {
    public var minimumDurationMs: Int
    public var silencePeakRMS: Float

    public static let standard = CapturePolicy(minimumDurationMs: 250, silencePeakRMS: 0.01)

    public init(minimumDurationMs: Int, silencePeakRMS: Float) {
        self.minimumDurationMs = minimumDurationMs
        self.silencePeakRMS = silencePeakRMS
    }

    public func discardReason(for summary: CaptureSummary) -> DiscardReason? {
        if summary.durationMs < minimumDurationMs { return .tooShort }
        if summary.peakRMS < silencePeakRMS { return .noSpeech }
        return nil
    }
}
