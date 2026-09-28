import Foundation
import os

/// The HUD's live text: a decode of the capture's last few seconds, every so often, while the key is held.
///
/// Whisper does not stream, so the line is rebuilt from a fresh decode of the tail. The loop runs on its own engine
/// (a second Small context), never has two decodes in flight and never queues one: the next try is timed from the
/// end of the previous one, so a slow decode slows the line down instead of piling up behind itself. A partial
/// writes no log line and never touches the reducer; each result carries the utterance it started from, and
/// `PartialLine` decides on the main actor whether it is still the one on screen.
public actor PartialTranscription {
    public struct Result: Sendable, Equatable {
        public let utterance: UtteranceID
        public let text: String

        public init(utterance: UtteranceID, text: String) {
            self.utterance = utterance
            self.text = text
        }
    }

    /// Short commands end before a partial could help, and under 3 s no partial encode competes with the final.
    public static let firstDecode: Duration = .seconds(3)
    /// Measured from the end of the previous try, decoded or skipped.
    public static let cadence: Duration = .milliseconds(1_500)
    /// 6 s at 16 kHz: about fifteen words, more than one HUD line holds, and one encoder window.
    public static let tailSamples = 96_000
    /// −40 dBFS. A tail with no window above it since the previous try is silence and is not decoded.
    public static let speechRMS: Float = 0.01

    private static let logger = Logger(subsystem: HarkLog.subsystem, category: "partial")

    public nonisolated let results: AsyncStream<Result>
    private let continuation: AsyncStream<Result>.Continuation
    private let engine: any TranscriptionEngine
    private let tail: any AudioTailSource
    private let clock: any Clock<Duration>

    /// The last loop started, kept after it is stopped so the next one can wait for its decode to return.
    private var loop: Task<Void, Never>?
    /// The utterance whose loop is running, nil once stopped.
    private var running: UtteranceID?

    public init(
        engine: any TranscriptionEngine, tail: any AudioTailSource, clock: any Clock<Duration> = ContinuousClock()
    ) {
        (results, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.engine = engine
        self.tail = tail
        self.clock = clock
    }

    deinit {
        loop?.cancel()
        continuation.finish()
    }

    /// Starts the loop for `utterance`, replacing a loop for another one. The new loop's first decode waits for the
    /// previous loop to return, so the engine never sees two decodes at once.
    public func start(_ utterance: UtteranceID) async {
        if running == utterance { return }
        let previous = loop
        if running != nil {
            previous?.cancel()
            await engine.cancel()
        }
        running = utterance
        loop = Task { [engine, tail, clock, continuation] in
            await Self.run(
                utterance, after: previous, engine: engine, tail: tail, clock: clock, continuation: continuation)
        }
    }

    /// Stops the loop and aborts its decode, if one is running. Harmless when nothing runs.
    public func stop() async {
        guard running != nil else { return }
        running = nil
        loop?.cancel()
        await engine.cancel()
    }

    private static func run(
        _ utterance: UtteranceID,
        after previous: Task<Void, Never>?,
        engine: any TranscriptionEngine,
        tail: any AudioTailSource,
        clock: any Clock<Duration>,
        continuation: AsyncStream<Result>.Continuation
    ) async {
        do {
            try await clock.sleep(for: firstDecode)
        } catch {
            return
        }
        await previous?.value
        while !Task.isCancelled {
            if let samples = tail.takeTail(maxSamples: tailSamples, minimumRMS: speechRMS) {
                // A stop landing here aborts a Transcriber whose `begin()` has yet to clear the abort, so the decode
                // would run anyway. This narrows that window, it does not close it: one that slips through costs
                // the final at most one whole partial, 37 ms in M7.0's measurement.
                if Task.isCancelled { return }
                await decode(samples, utterance: utterance, engine: engine, continuation: continuation)
            }
            do {
                try await clock.sleep(for: cadence)
            } catch {
                return
            }
        }
    }

    /// A blank or failed decode yields nothing, so the HUD keeps the line it has.
    private static func decode(
        _ samples: [Float],
        utterance: UtteranceID,
        engine: any TranscriptionEngine,
        continuation: AsyncStream<Result>.Continuation
    ) async {
        do throws(PipelineFailure) {
            let text = try await engine.transcribe(samples).raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !Task.isCancelled else { return }
            continuation.yield(Result(utterance: utterance, text: text))
        } catch {
            logger.debug(
                "partial \(utterance, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        }
    }
}
