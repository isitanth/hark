import Foundation
import HarkCore
import os

/// A `FileWatching` the test drives: `emit()` is one change noticed, on every stream still being iterated.
final class FakeFileWatcher: FileWatching {
    private struct State {
        var nextID = 0
        var continuations: [Int: AsyncStream<Void>.Continuation] = [:]
        var watchedURLs: [URL] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Streams handed out and not yet terminated.
    var activeWatches: Int { state.withLock { $0.continuations.count } }
    var watchedURLs: [URL] { state.withLock { $0.watchedURLs } }

    func changes(of url: URL) -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
        let id = state.withLock { state -> Int in
            state.nextID += 1
            state.continuations[state.nextID] = continuation
            state.watchedURLs.append(url)
            return state.nextID
        }
        continuation.onTermination = { [weak self] _ in
            _ = self?.state.withLock { $0.continuations.removeValue(forKey: id) }
        }
        return stream
    }

    func emit() {
        let continuations = state.withLock { Array($0.continuations.values) }
        for continuation in continuations { continuation.yield() }
    }
}
