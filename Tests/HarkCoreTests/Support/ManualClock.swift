import Foundation
import os

/// A `Clock` that moves only when a test calls `advance(by:)`.
///
/// `waitForSleeps(_:)` suspends until that many sleeps have started in total, so a test can post an event, wait for
/// the code under test to start its timer, and only then advance — without which the advance could land first.
/// Counting starts rather than live sleepers tells a restarted timer apart from the one it replaced.
final class ManualClock: Clock, Sendable {
    struct Instant: InstantProtocol {
        let offset: Duration

        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private struct Sleeper {
        let id: UInt64
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct Waiter {
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct State {
        var now = Instant(offset: .zero)
        var nextID: UInt64 = 0
        var started = 0
        var sleepers: [Sleeper] = []
        var waiters: [Waiter] = []

        /// Removes and returns the waiters whose count is now met.
        mutating func satisfiedWaiters() -> [Waiter] {
            let met = waiters.filter { $0.count <= started }
            waiters.removeAll { $0.count <= started }
            return met
        }
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var now: Instant { state.withLock { $0.now } }
    var minimumResolution: Duration { .zero }

    /// Sleepers registered and not yet resumed.
    var sleeperCount: Int { state.withLock { $0.sleepers.count } }

    func sleep(until deadline: Instant, tolerance: Duration? = nil) async throws {
        let id = state.withLock { state -> UInt64 in
            state.nextID += 1
            return state.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let (resumeNow, waiters) = state.withLock { state -> (Bool, [Waiter]) in
                    state.started += 1
                    let resumeNow = Task.isCancelled || deadline <= state.now
                    if !resumeNow {
                        state.sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
                    }
                    return (resumeNow, state.satisfiedWaiters())
                }
                if resumeNow {
                    if Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        continuation.resume()
                    }
                }
                for waiter in waiters { waiter.continuation.resume() }
            }
        } onCancel: {
            let sleeper = state.withLock { state -> Sleeper? in
                guard let index = state.sleepers.firstIndex(where: { $0.id == id }) else { return nil }
                return state.sleepers.remove(at: index)
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Moves `now` forward and resumes every sleeper now due, earliest deadline first.
    func advance(by duration: Duration) {
        let due = state.withLock { state -> [Sleeper] in
            state.now = state.now.advanced(by: duration)
            let now = state.now
            let due = state.sleepers.filter { $0.deadline <= now }.sorted { $0.deadline < $1.deadline }
            state.sleepers.removeAll { $0.deadline <= now }
            return due
        }
        for sleeper in due { sleeper.continuation.resume() }
    }

    /// Returns once at least `count` sleeps have started since the clock was made.
    func waitForSleeps(_ count: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let ready = state.withLock { state -> Bool in
                if state.started >= count { return true }
                state.waiters.append(Waiter(count: count, continuation: continuation))
                return false
            }
            if ready { continuation.resume() }
        }
    }
}
