import CoreGraphics
import Foundation

// Finding the framed zone again after the page moved (M14, c3b §4.2, §5): Accelerate's cross-correlation, then a pixel
// check in each tinted cell, against the window-alone reference captured at the frame. Pure; it writes nothing, and no
// value it computes reaches a result: it outputs a pixel offset or nothing. The contract's stub; S3 implements it.

/// Where the zone is in a fresh capture of its window.
public enum ZoneMatch: Sendable, Equatable {
    /// Found with certainty: the zone moved by this many pixels from where the reference holds it.
    case found(CGVector)
    /// Two places pass the cell check (identical rows): never choose, the tints stay hidden.
    case ambiguous
    case notFound
}

public enum ZoneRegistration {
    /// `reference` is the window alone at the frame, in grey; `recapture` the same window now; `zone` and `cells` (the
    /// tinted boxes) in the reference's pixels. Both images live in memory only and are freed by the caller. The
    /// contract's stub finds nothing.
    public static func find(reference: CGImage, recapture: CGImage, zone: CGRect, cells: [CGRect]) -> ZoneMatch {
        .notFound
    }
}

/// One input event over the anchored window, as the stillness detector reads it (c3b §3): never its content.
public struct InputRecord: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// A scroll event; `momentumEnded` on the last event of a trackpad's momentum.
        case scroll(momentumEnded: Bool)
        case key
        case buttonDown
        case buttonUp
    }

    public let kind: Kind
    /// On the detector's clock, from any origin.
    public let at: Duration

    public init(kind: Kind, at: Duration) {
        self.kind = kind
        self.at = at
    }
}

/// Hide on the first event that may move the page, recapture once it is still: 250 ms with no event, momentum ended,
/// no button down (c3b §2.3, the quiet delay M14.0 B3 sets). A pure reducer over timed records, with a test clock.
/// `momentumEnded` is true on any scroll that leaves no momentum running (a wheel's notch, a trackpad's last momentum
/// event); a scroll with momentum still to come keeps the detector waiting for one that ends it.
public struct StillnessDetector: Sendable, Equatable {
    public static let quiet: Duration = .milliseconds(250)

    public enum Action: Sendable, Equatable {
        case none
        case hide
        /// Still long enough: capture the window once and look for the zone.
        case recapture
    }

    /// Hidden and waiting for stillness.
    private var waiting = false
    private var lastEvent: Duration?
    private var buttonDown = false
    private var momentum = false

    public init() {}

    public mutating func record(_ event: InputRecord) -> Action {
        lastEvent = event.at
        switch event.kind {
        case .buttonUp:
            buttonDown = false
            return .none
        case .buttonDown:
            buttonDown = true
        case .key:
            break
        case .scroll(let momentumEnded):
            momentum = !momentumEnded
        }
        guard !waiting else { return .none }
        waiting = true
        return .hide
    }

    /// Called on the clock: `.recapture` once, when the page has been still for `quiet`.
    public mutating func tick(at: Duration) -> Action {
        guard waiting, !buttonDown, !momentum, let lastEvent, at - lastEvent >= Self.quiet else { return .none }
        waiting = false
        return .recapture
    }
}
