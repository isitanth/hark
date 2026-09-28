import Foundation
import os

/// Waits for work or for a deadline, whichever comes first, and does not wait for the other. A task group would:
/// it returns only once every child has, and the work this guards — a whisper decode queued ahead of an unload,
/// LaunchServices opening an app behind a Gatekeeper prompt — cannot be cancelled.
public enum Deadline {
    /// `work`'s result, or nil when `limit` passed first on `clock`. The work keeps running either way; only the
    /// wait for it ends.
    public static func first<T: Sendable>(
        of work: @escaping @Sendable () async -> T, within limit: Duration,
        clock: any Clock<Duration> = ContinuousClock()
    ) async -> T? {
        let pending = OSAllocatedUnfairLock<CheckedContinuation<T?, Never>?>(initialState: nil)
        let finish: @Sendable (T?) -> Void = { value in
            let continuation = pending.withLock { waiting -> CheckedContinuation<T?, Never>? in
                defer { waiting = nil }
                return waiting
            }
            continuation?.resume(returning: value)
        }
        return await withCheckedContinuation { continuation in
            pending.withLock { $0 = continuation }
            // The timer answers only when its sleep ran out: cancelled, it would race the result it was cancelled for.
            let timer = Task {
                do {
                    try await clock.sleep(for: limit)
                } catch {
                    return
                }
                finish(nil)
            }
            Task {
                let value = await work()
                finish(value)
                timer.cancel()
            }
        }
    }
}
