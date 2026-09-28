import Foundation
import HarkCore
import os

/// A model server scripted for the controller: the pieces, then `ending`, or nothing more until the consumer lets go
/// when `ending` is nil. It records what it was asked and whether the stream was closed from the consumer's side.
final class ScriptedAsker: AskGenerating {
    private struct State {
        var requests: [(instruction: String, selection: String?)] = []
        var closedByConsumer = 0
    }

    let pieces: [String]
    let ending: LLMEvent?
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(pieces: [String], ending: LLMEvent?) {
        self.pieces = pieces
        self.ending = ending
    }

    var requests: [(instruction: String, selection: String?)] { state.withLock { $0.requests } }
    var closedByConsumer: Int { state.withLock { $0.closedByConsumer } }

    func generate(instruction: String, selection: String?) -> AsyncStream<LLMEvent> {
        state.withLock { $0.requests.append((instruction, selection)) }
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
