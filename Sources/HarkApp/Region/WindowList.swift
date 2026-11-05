import AppKit
import CoreGraphics
import HarkCore

/// The window server's list, read synchronously (M14): the anchor's choice at the mouse-up, and the layer's 10 Hz poll.
/// Geometry, owner and layer only, never a title or a pixel.
enum WindowList {
    /// One entry of the anchored window, as a poll reads it.
    struct Entry {
        let bounds: CGRect
        let ownerPID: Int32
        let onScreen: Bool
    }

    /// Every on-screen window, front to back.
    static func candidates() -> [AnchorCandidate] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        return entries(CGWindowListCopyWindowInfo(options, kCGNullWindowID)).compactMap(candidate)
    }

    /// The anchored window alone, wherever it is: nil once the server no longer lists it, or lists it at alpha 0. The
    /// single-window query leaves out a window minimised to the Dock (M14.7, measured: `.optionIncludingWindow` returned
    /// nothing while `.optionAll` listed it off screen at its own bounds), so the whole list is read when it finds
    /// nothing. A window its app keeps hidden (minimised, the app hidden) reads off screen; a closed window, or one at
    /// alpha 0, reads as gone.
    static func entry(_ windowID: UInt32) -> Entry? {
        entry(windowID, in: CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID))
            ?? entry(windowID, in: CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID))
    }

    private static func entry(_ windowID: UInt32, in list: CFArray?) -> Entry? {
        guard let candidate = entries(list).lazy.compactMap(candidate).first(where: { $0.windowID == windowID }) else {
            return nil
        }
        return Entry(bounds: candidate.bounds, ownerPID: candidate.ownerPID, onScreen: candidate.onScreen)
    }

    /// Whether a window in front of `windowID`, other than Hark's and below the Dock's level, overlaps `zone` (global,
    /// top-left origin).
    static func covers(_ zone: CGRect, above windowID: UInt32, harkPID: Int32) -> Bool {
        let dock = Int(CGWindowLevelForKey(.dockWindow))
        let above = entries(CGWindowListCopyWindowInfo([.optionOnScreenAboveWindow], windowID)).compactMap(candidate)
        return above.contains { window in
            window.ownerPID != harkPID && window.layer < dock && window.windowID != windowID
                && window.bounds.intersection(zone).width > 0.5 && window.bounds.intersection(zone).height > 0.5
        }
    }

    private static func entries(_ list: CFArray?) -> [[String: Any]] {
        (list as? [[String: Any]]) ?? []
    }

    private static func candidate(_ info: [String: Any]) -> AnchorCandidate? {
        guard let number = info[kCGWindowNumber as String] as? NSNumber,
            let pid = info[kCGWindowOwnerPID as String] as? NSNumber,
            let layer = info[kCGWindowLayer as String] as? NSNumber,
            let boundsInfo = info[kCGWindowBounds as String] as? NSDictionary,
            let bounds = CGRect(dictionaryRepresentation: boundsInfo)
        else { return nil }
        if let alpha = info[kCGWindowAlpha as String] as? NSNumber, alpha.doubleValue == 0 {
            return nil
        }
        let onScreen = (info[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
        return AnchorCandidate(
            windowID: number.uint32Value, ownerPID: pid.int32Value, layer: layer.intValue, bounds: bounds,
            onScreen: onScreen)
    }
}

/// Where the layer's pieces lie (M14): the zone in its window, the search band, and the conversions between the window
/// server's global points (top-left origin) and Cocoa's (bottom-left, the main display's).
enum LayerGeometry {
    /// The display's origin in global points, top-left origin.
    static func displayOrigin(_ displayID: UInt32) -> CGPoint {
        CGDisplayBounds(displayID).origin
    }

    /// The search band of c3b §3.2, in window-local points: the zone grown by the window's height above and below and
    /// by one zone width each side, clipped to the window.
    nonisolated static func band(zone: CGRect, windowSize: CGSize) -> CGRect {
        let grown = CGRect(
            x: zone.minX - zone.width, y: zone.minY - windowSize.height, width: zone.width * 3,
            height: zone.height + windowSize.height * 2)
        return grown.intersection(CGRect(origin: .zero, size: windowSize)).integral
    }

    /// A global rect, top-left origin, in Cocoa's screen coordinates.
    static func cocoa(_ rect: CGRect) -> CGRect {
        let height = CGDisplayBounds(CGMainDisplayID()).height
        return CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
    }

    /// The backing scale of the display that holds most of `rect` (global, top-left origin).
    static func scale(of rect: CGRect) -> CGFloat? {
        let cocoaRect = cocoa(rect)
        let best = NSScreen.screens.max { lhs, rhs in
            area(lhs.frame.intersection(cocoaRect)) < area(rhs.frame.intersection(cocoaRect))
        }
        guard let best, area(best.frame.intersection(cocoaRect)) > 0 else { return nil }
        return best.backingScaleFactor
    }

    private static func area(_ rect: CGRect) -> CGFloat {
        rect.isNull ? 0 : rect.width * rect.height
    }
}
