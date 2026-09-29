import Foundation

/// One picture of an animation: how it moves the drill of the current icon, which marks it adds, and for how long.
public struct MenuBarFrame: Sendable, Equatable {
    public var rotation: Double
    public var dx: Double
    public var dy: Double
    public var marks: MenuBarGlyph.Marks
    public var movesBadge: Bool
    public var duration: Duration

    public init(
        rotation: Double = 0, dx: Double = 0, dy: Double = 0, marks: MenuBarGlyph.Marks = .none,
        movesBadge: Bool = false, duration: Duration
    ) {
        self.rotation = rotation
        self.dx = dx
        self.dy = dy
        self.marks = marks
        self.movesBadge = movesBadge
        self.duration = duration
    }

    /// Nothing moved and nothing added: the icon of the state as it is.
    public var isRest: Bool {
        rotation == 0 && dx == 0 && dy == 0 && marks == .none
    }
}

/// The menu bar icon's animations, drawn frame by frame over the icon of the current state and always ending on it, so
/// the state's own icon carries the meaning when Reduce Motion turns them off. Each plays once, under half a second;
/// the spin alone repeats, gently, while the work lasts.
public enum MenuBarAnimation: String, Sendable, CaseIterable {
    /// The trigger pulled: the nose kicks up and settles, once, when a capture starts.
    case trigger
    /// The bit turns: marks pass above and below it while Hark works on what was said, or the model writes an answer.
    case spin
    /// The macOS refusal: a damped left-right shake of the drill and its cross, once, when an utterance failed.
    case shake

    public var frames: [MenuBarFrame] {
        switch self {
        case .trigger:
            zip([-4, -8, -9, -6, -2, 1.5, 2, 0.5, 0], [35, 35, 40, 35, 35, 35, 40, 35, 40]).map {
                MenuBarFrame(rotation: $0, duration: .milliseconds($1))
            }
        case .spin:
            [
                (MenuBarGlyph.Marks.dotAbove, 40), (.strokeAbove, 50), (.strokes, 50), (.strokeBelow, 50),
                (.dotBelow, 40), (.none, 60), (.strokeAbove, 50), (.strokeBelow, 50), (.none, 40),
            ].map { MenuBarFrame(marks: $0, duration: .milliseconds($1)) }
        case .shake:
            zip([-1, 0.5, -1, 0.5, -0.5, 0.5, -0.5, 0], [35, 35, 35, 35, 35, 35, 35, 40]).map {
                MenuBarFrame(dx: $0, movesBadge: true, duration: .milliseconds($1))
            }
        }
    }

    public var duration: Duration {
        frames.reduce(.zero) { $0 + $1.duration }
    }

    /// Work shorter than this shows no spin, so a quick dictation does not flicker.
    public static let spinDelay: Duration = .milliseconds(300)
    /// A turn every 1.2 s while the work lasts: the turn, then a rest on the state's icon.
    public static let spinPeriod: Duration = .milliseconds(1200)
}

/// What the end of an utterance says in the menu bar: the cross for a second when it came to nothing the user can see,
/// after a shake when it failed. Nothing after an Escape or a declined confirmation, which the user did themselves, nor
/// for a press refused as busy: it says nothing about the utterance in flight, which may well succeed.
public enum MenuBarOutcome: Sendable, Equatable {
    case dismissed
    case failed

    public static let shown: Duration = .seconds(1)

    public init?(resolution: Resolution, error: String?) {
        switch resolution {
        case .failed:
            self = .failed
        case .discarded:
            let byUser: Set<String> = [
                DiscardReason.cancelled.rawValue, DiscardReason.declined.rawValue, DiscardReason.maxDuration.rawValue,
                DiscardReason.busy.rawValue,
            ]
            guard !byUser.contains(error ?? "") else { return nil }
            self = .dismissed
        case .command, .textInserted, .textClipboard:
            return nil
        }
    }

    public init?(_ record: UtteranceRecord) {
        self.init(resolution: record.resolution, error: record.error)
    }
}
