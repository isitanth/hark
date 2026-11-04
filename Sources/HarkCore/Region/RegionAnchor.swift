import CoreGraphics
import Foundation

// The window a frame was drawn on, and how it changed (M14, c3a §2.3, §4). Geometry only, never pixels.

/// The window under the framed zone at the mouse-up: the layer follows it. Kept as a number and a position, freed with
/// the frame, never logged.
public struct RegionAnchor: Sendable, Equatable {
    /// `kCGWindowNumber`.
    public let windowID: UInt32
    public let ownerPID: Int32
    /// `kCGWindowLayer`: only a window below `.floating` gets a layer.
    public let layer: Int
    /// The window's bounds at the frame, global, top-left origin.
    public let windowBounds: CGRect
    /// The zone's origin minus the window's: the zone in window coordinates is `(offset, size)`.
    public let offset: CGPoint
    public let size: CGSize
    /// The visible fraction of the zone the window showed, for the choice (never written to the JSONL).
    public let coverage: Double

    public init(
        windowID: UInt32, ownerPID: Int32, layer: Int, windowBounds: CGRect, offset: CGPoint, size: CGSize,
        coverage: Double
    ) {
        self.windowID = windowID
        self.ownerPID = ownerPID
        self.layer = layer
        self.windowBounds = windowBounds
        self.offset = offset
        self.size = size
        self.coverage = coverage
    }

    /// The window the zone lies on, from the window server's list front to back: the most visible overlap of at least
    /// 50 %, below `.floating`, Hark's own windows left out; nil when none qualifies, and then there is no layer. The
    /// contract's stub anchors nothing.
    public static func choose(zone: CGRect, windows: [AnchorCandidate], harkPID: Int32) -> RegionAnchor? {
        nil
    }
}

/// One entry of the window server's list, as the anchor's choice reads it.
public struct AnchorCandidate: Sendable, Equatable {
    public let windowID: UInt32
    public let ownerPID: Int32
    public let layer: Int
    public let bounds: CGRect
    public let onScreen: Bool

    public init(windowID: UInt32, ownerPID: Int32, layer: Int, bounds: CGRect, onScreen: Bool) {
        self.windowID = windowID
        self.ownerPID = ownerPID
        self.layer = layer
        self.bounds = bounds
        self.onScreen = onScreen
    }
}

/// What a poll of the anchor's bounds says (c3a §4): follow a move, hide on anything else.
public enum AnchorChange: Sendable, Equatable {
    case still
    /// The origin moved by this many points, the size unchanged: the layer follows.
    case moved(CGVector)
    case resized
    /// No entry for the window: closed.
    case gone
    /// Minimised, hidden or on another Space.
    case offscreen

    /// `new` nil is a window the server no longer lists. The contract's stub calls every poll gone.
    public static func classify(old: CGRect, new: CGRect?, onScreen: Bool) -> AnchorChange {
        .gone
    }
}
