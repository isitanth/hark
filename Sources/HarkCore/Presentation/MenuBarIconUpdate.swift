import Foundation

/// What one pipeline snapshot does to the menu bar icon beyond its state: the animation to play once, the cross of the
/// last utterance, whether the bit turns, and whether the talk key's latch is over. Decided here so it is tested; the
/// app only runs the timers.
public struct MenuBarIconUpdate: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        /// No new line: the cross, if any, runs its second.
        case keep
        case show(MenuBarOutcome)
        /// A new line that came to something, or a new capture: the cross of an earlier one goes.
        case clear
    }

    public var play: MenuBarAnimation?
    public var outcome: Outcome
    public var working: Bool
    /// The capture ended: a latch left from it must not show the next, held, capture as hands-free.
    public var endsLatch: Bool

    public init(play: MenuBarAnimation? = nil, outcome: Outcome = .keep, working: Bool = false, endsLatch: Bool = false)
    {
        self.play = play
        self.outcome = outcome
        self.working = working
        self.endsLatch = endsLatch
    }

    public init(from old: PipelineSnapshot, to new: PipelineSnapshot) {
        let startsCapture = new.phase == .capturing && old.phase != .capturing
        var outcome = Outcome.keep
        if let record = new.lastRecord, record != old.lastRecord {
            outcome = MenuBarOutcome(record).map(Outcome.show) ?? .clear
        }
        if startsCapture { outcome = .clear }
        self.init(
            play: startsCapture ? .trigger : outcome == .show(.failed) ? .shake : nil, outcome: outcome,
            working: MenuBarIconState.isWorking(new.phase, ask: new.ask),
            endsLatch: old.phase == .capturing && new.phase != .capturing)
    }
}
