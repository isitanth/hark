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
    /// 50 %, below `.floating`, Hark's own windows left out; nil when none qualifies, and then there is no layer. A
    /// window below the Dock's level occludes those behind it, eligible or not; a tie goes to the frontmost.
    public static func choose(zone: CGRect, windows: [AnchorCandidate], harkPID: Int32) -> RegionAnchor? {
        let zoneArea = Double(zone.width * zone.height)
        guard zoneArea > 0 else { return nil }
        let dockLevel = Int(CGWindowLevelForKey(.dockWindow))
        let floatingLevel = Int(CGWindowLevelForKey(.floatingWindow))
        var remaining = [zone]
        var best: (window: AnchorCandidate, visible: Double)?
        for window in windows where window.ownerPID != harkPID && window.onScreen {
            let shown = area(remaining.map { $0.intersection(window.bounds) }.filter { !$0.isNull })
            if window.layer < dockLevel { remaining = remaining.flatMap { subtract($0, window.bounds) } }
            guard window.layer < floatingLevel, window.bounds.intersects(zone) else { continue }
            let visible = shown / zoneArea
            if visible > (best?.visible ?? -1) { best = (window, visible) }
        }
        guard let best, best.visible >= 0.5 else { return nil }
        let bounds = best.window.bounds
        return RegionAnchor(
            windowID: best.window.windowID, ownerPID: best.window.ownerPID, layer: best.window.layer,
            windowBounds: bounds, offset: CGPoint(x: zone.minX - bounds.minX, y: zone.minY - bounds.minY),
            size: zone.size, coverage: best.visible)
    }

    /// `a` minus `b`, as up to four rectangles.
    static func subtract(_ a: CGRect, _ b: CGRect) -> [CGRect] {
        let cut = a.intersection(b)
        guard !cut.isNull, cut.width > 0, cut.height > 0 else { return [a] }
        var parts: [CGRect] = []
        if cut.minY > a.minY { parts.append(CGRect(x: a.minX, y: a.minY, width: a.width, height: cut.minY - a.minY)) }
        if cut.maxY < a.maxY { parts.append(CGRect(x: a.minX, y: cut.maxY, width: a.width, height: a.maxY - cut.maxY)) }
        if cut.minX > a.minX {
            parts.append(CGRect(x: a.minX, y: cut.minY, width: cut.minX - a.minX, height: cut.height))
        }
        if cut.maxX < a.maxX {
            parts.append(CGRect(x: cut.maxX, y: cut.minY, width: a.maxX - cut.maxX, height: cut.height))
        }
        return parts
    }

    private static func area(_ rects: [CGRect]) -> Double {
        rects.reduce(0) { $0 + Double($1.width * $1.height) }
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

    /// `new` nil is a window the server no longer lists; a change of 0.25 pt or less is still.
    public static func classify(old: CGRect, new: CGRect?, onScreen: Bool) -> AnchorChange {
        guard let new else { return .gone }
        guard onScreen else { return .offscreen }
        let tolerance: CGFloat = 0.25
        if abs(new.width - old.width) > tolerance || abs(new.height - old.height) > tolerance { return .resized }
        let dx = new.minX - old.minX
        let dy = new.minY - old.minY
        if abs(dx) > tolerance || abs(dy) > tolerance { return .moved(CGVector(dx: dx, dy: dy)) }
        return .still
    }
}
