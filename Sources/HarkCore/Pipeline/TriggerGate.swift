import Foundation

/// Turns key-down and key-up on the trigger into start and stop.
///
/// A tap starts dictation and the next tap stops it, which is what a chord like ⌃⌥V needs. Holding the key
/// longer than `holdThreshold` is push-to-talk instead: dictation stops when the key is let go. A key-down while
/// capture is already running and unfinished is a key repeat and is ignored.
public struct TriggerGate: Sendable, Equatable {
    public enum Key: Sendable, Equatable {
        case down
        case up
    }

    public enum Action: Sendable, Equatable {
        case start
        case stop
        case ignore
    }

    private enum State: Sendable, Equatable {
        case idle
        case holding(ContinuousClock.Instant)
        /// Started by a tap: the key is up and capture continues until the next tap.
        case latched
    }

    public let holdThreshold: Duration
    /// A tap started the capture and it goes on with the key up; HotkeyBridge passes it to the HUD's lock glyph.
    public var isLatched: Bool { state == .latched }
    /// No press of this key is under way: a capture going on now was started by something else.
    public var isIdle: Bool { state == .idle }
    private var state = State.idle

    public init(holdThreshold: Duration = .milliseconds(350)) {
        self.holdThreshold = holdThreshold
    }

    /// A capture started elsewhere, by Services › Ask Hark, which the next key-down ends as it would end one started by
    /// a tap. Without it that press would be a new utterance, logged `busy`.
    public mutating func latch() {
        state = .latched
    }

    /// The press is timed from now, not from the key-down: the Ask key reads the selection before the capture starts,
    /// and that wait is not the user holding the key. Nothing happens unless a press is being held.
    public mutating func restartHold(at now: ContinuousClock.Instant) {
        if case .holding = state { state = .holding(now) }
    }

    /// `isCapturing` is the pipeline's own view. A capture that ended on its own (the length limit, a failure) resets
    /// the gate, so the next key-down starts a new one instead of being swallowed.
    public mutating func handle(_ key: Key, at now: ContinuousClock.Instant, isCapturing: Bool) -> Action {
        if !isCapturing, state != .idle {
            state = .idle
        }
        switch (state, key) {
        case (.idle, .down):
            state = .holding(now)
            return .start
        case (.holding, .down):
            return .ignore
        case (.latched, .down):
            state = .idle
            return .stop
        case (.holding(let since), .up):
            guard since.duration(to: now) >= holdThreshold else {
                state = .latched
                return .ignore
            }
            state = .idle
            return .stop
        case (.idle, .up), (.latched, .up):
            return .ignore
        }
    }
}
