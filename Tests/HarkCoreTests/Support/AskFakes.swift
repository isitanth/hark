import Foundation
import HarkCore
import os

/// A model server scripted for the controller: the pieces, then `ending`, or nothing more until the consumer lets go
/// when `ending` is nil. `endings` overrides it request by request, in order. It records what it was asked and whether
/// the stream was closed from the consumer's side.
final class ScriptedAsker: AskGenerating {
    private struct State {
        var requests: [(instruction: String, selection: String?)] = []
        var images: [ImagePart?] = []
        var threads: [AskThread?] = []
        var frames: [[UtteranceID: ImagePart]] = []
        var closedByConsumer = 0
    }

    let pieces: [String]
    let ending: LLMEvent?
    let endings: [LLMEvent?]
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(pieces: [String], ending: LLMEvent?, endings: [LLMEvent?] = []) {
        self.pieces = pieces
        self.ending = ending
        self.endings = endings
    }

    var requests: [(instruction: String, selection: String?)] { state.withLock { $0.requests } }
    /// The image each request carried, in order: nil for one without a framed region.
    var images: [ImagePart?] { state.withLock { $0.images } }
    /// Each request's conversation so far: nil for a single ask.
    var threads: [AskThread?] { state.withLock { $0.threads } }
    /// Each request's earlier frames, by turn.
    var frames: [[UtteranceID: ImagePart]] { state.withLock { $0.frames } }
    var closedByConsumer: Int { state.withLock { $0.closedByConsumer } }

    func generate(
        instruction: String, selection: String?, image: ImagePart?, thread: AskThread?,
        frames: [UtteranceID: ImagePart]
    ) -> AsyncStream<LLMEvent> {
        let index = state.withLock {
            $0.requests.append((instruction, selection))
            $0.images.append(image)
            $0.threads.append(thread)
            $0.frames.append(frames)
            return $0.requests.count - 1
        }
        let ending = index < endings.count ? endings[index] : self.ending
        return AsyncStream { continuation in
            continuation.onTermination = { [state] reason in
                if case .cancelled = reason { state.withLock { $0.closedByConsumer += 1 } }
            }
            for piece in pieces { continuation.yield(.text(piece)) }
            if let ending {
                continuation.yield(ending)
                continuation.finish()
            }
        }
    }
}

/// Always hears the same words.
struct FixedTranscriptionEngine: TranscriptionEngine {
    let transcript: Transcript

    func transcribe(_ samples: [Float]) async throws(PipelineFailure) -> Transcript { transcript }
    func cancel() async {}
}

/// Hears each transcript in turn, then the last one again.
final class SequencedTranscriptionEngine: TranscriptionEngine {
    private let transcripts: [Transcript]
    private let heard = OSAllocatedUnfairLock(initialState: 0)

    init(_ transcripts: [Transcript]) {
        self.transcripts = transcripts
    }

    func transcribe(_ samples: [Float]) async throws(PipelineFailure) -> Transcript {
        let index = heard.withLock {
            defer { $0 += 1 }
            return $0
        }
        return transcripts[min(index, transcripts.count - 1)]
    }

    func cancel() async {}
}

/// A planner scripted for the controller, the mirror of `ScriptedAsker`: each request takes the next of `scripts` (the
/// last one again past the end), its pieces then its ending, or nothing more until the consumer lets go when the ending
/// is nil. It records each request with its correction and images.
final class ScriptedPlanner: AskPlanning {
    struct Request: Sendable {
        let instruction: String
        let sheet: CellSheet
        let selection: String?
        let image: ImagePart?
        let thread: AskThread?
        let frames: [UtteranceID: ImagePart]
        let correction: PlanCorrection?
    }

    private struct State {
        var requests: [Request] = []
        var closedByConsumer = 0
    }

    let scripts: [(pieces: [String], ending: LLMEvent?)]
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(_ scripts: [(pieces: [String], ending: LLMEvent?)]) {
        self.scripts = scripts
    }

    var requests: [Request] { state.withLock { $0.requests } }
    var closedByConsumer: Int { state.withLock { $0.closedByConsumer } }

    func plan(
        instruction: String, sheet: CellSheet, selection: String?, image: ImagePart?, thread: AskThread?,
        frames: [UtteranceID: ImagePart], correction: PlanCorrection?
    ) -> AsyncStream<LLMEvent> {
        let index = state.withLock {
            $0.requests.append(
                Request(
                    instruction: instruction, sheet: sheet, selection: selection, image: image, thread: thread,
                    frames: frames, correction: correction))
            return $0.requests.count - 1
        }
        let script = scripts[min(index, scripts.count - 1)]
        return AsyncStream { continuation in
            continuation.onTermination = { [state] reason in
                if case .cancelled = reason { state.withLock { $0.closedByConsumer += 1 } }
            }
            for piece in script.pieces { continuation.yield(.text(piece)) }
            if let ending = script.ending {
                continuation.yield(ending)
                continuation.finish()
            }
        }
    }
}

/// A reader scripted for the controller: `result` after `delay`, or never when `result` is nil. It counts the reads and
/// the reads cancelled before they answered.
final class ScriptedReader: RegionReading {
    private struct State {
        var reads = 0
        var cancels = 0
    }

    let result: Result<CellSheet, ReaderFailure>?
    let delay: Duration
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(_ result: Result<CellSheet, ReaderFailure>?, delay: Duration = .zero) {
        self.result = result
        self.delay = delay
    }

    var reads: Int { state.withLock { $0.reads } }
    var cancels: Int { state.withLock { $0.cancels } }

    func read(_ raster: RegionRaster) async -> Result<CellSheet, ReaderFailure> {
        state.withLock { $0.reads += 1 }
        do {
            if let result {
                try await Task.sleep(for: delay)
                return result
            }
            while true { try await Task.sleep(for: .seconds(3600)) }
        } catch {
            state.withLock { $0.cancels += 1 }
            return .failure(.vision)
        }
    }

    func prewarm() async {}
}
