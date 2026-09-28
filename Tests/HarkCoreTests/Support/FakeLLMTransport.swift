import Foundation
import HarkCore
import os

/// A scripted `LLMTransport`: each `send` takes the next answer and records its request. With no answer left it
/// refuses, like a stopped server.
final class FakeLLMTransport: LLMTransport {
    enum Answer: Sendable {
        /// Nothing listens: `.unreachable`.
        case refuse
        case fail(LLMTransportError)
        /// The head never comes. Only cancelling the call ends it.
        case hang
        /// A status and its whole body in one piece.
        case status(Int, Data)
        /// A status whose body the test pushes piece by piece with `push(_:)`, then ends with `endBody()`.
        case pushed(status: Int)
    }

    private struct State {
        var answers: [Answer]
        var requests: [URLRequest] = []
        var body: AsyncThrowingStream<Data, any Error>.Continuation?
        var bodyCancelled = false
    }

    private let state: OSAllocatedUnfairLock<State>

    init(_ answers: [Answer]) {
        state = OSAllocatedUnfairLock(initialState: State(answers: answers))
    }

    var requests: [URLRequest] { state.withLock { $0.requests } }
    /// The consumer stopped reading a pushed body before the test ended it.
    var bodyCancelled: Bool { state.withLock { $0.bodyCancelled } }

    func push(_ piece: String) {
        push(Data(piece.utf8))
    }

    func push(_ piece: Data) {
        _ = state.withLock { $0.body }?.yield(piece)
    }

    func endBody(throwing error: LLMTransportError? = nil) {
        let body = state.withLock { $0.body }
        if let error { body?.finish(throwing: error) } else { body?.finish() }
    }

    func send(_ request: URLRequest) async throws(LLMTransportError) -> LLMHTTPResponse {
        let answer = state.withLock { state -> Answer in
            state.requests.append(request)
            return state.answers.isEmpty ? .refuse : state.answers.removeFirst()
        }
        switch answer {
        case .refuse:
            throw .unreachable
        case .fail(let error):
            throw error
        case .hang:
            await Self.hang()
            throw .cancelled
        case .status(let status, let body):
            let stream = AsyncThrowingStream<Data, any Error> { continuation in
                if !body.isEmpty { continuation.yield(body) }
                continuation.finish()
            }
            return LLMHTTPResponse(status: status, body: stream)
        case .pushed(let status):
            let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
            continuation.onTermination = { [state] termination in
                if case .cancelled = termination { state.withLock { $0.bodyCancelled = true } }
            }
            state.withLock { $0.body = continuation }
            return LLMHTTPResponse(status: status, body: stream)
        }
    }

    /// Returns once the calling task is cancelled.
    private static func hang() async {
        let waiting = OSAllocatedUnfairLock<CheckedContinuation<Void, Never>?>(initialState: nil)
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow = waiting.withLock { waiting -> Bool in
                    if Task.isCancelled { return true }
                    waiting = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        } onCancel: {
            let continuation = waiting.withLock { waiting -> CheckedContinuation<Void, Never>? in
                defer { waiting = nil }
                return waiting
            }
            continuation?.resume()
        }
    }
}
