import CoreGraphics
import Foundation

/// A drag turned into what the capture asks for: a rect local to the display it began on, and its pixel size.
public struct CaptureGeometry: Sendable, Equatable {
    /// Display-local points, origin top-left, y down: what `SCStreamConfiguration.sourceRect` takes.
    public let sourceRect: CGRect
    /// The native pixels of that rect.
    public let pixelSize: CGSize

    public init(sourceRect: CGRect, pixelSize: CGSize) {
        self.sourceRect = sourceRect
        self.pixelSize = pixelSize
    }
}

/// The smallest side a frame may have, in points: anything thinner is a click, not a frame.
public let minimumFrameSide: CGFloat = 8

/// A drag in Cocoa global points (origin bottom-left of the primary display, y up) to the capture geometry. `screen`
/// is the Cocoa frame of the display the drag began on, and the drag is clamped to it: the overlay that took the
/// mouse-down draws the frame there, so what is shown is what is sent. The rect is flipped against that display's own
/// frame and snapped outward to whole pixels, so its edge never cuts a glyph in half. Nil for a click or a frame
/// under `minimumFrameSide` in either side.
public func captureGeometry(start: CGPoint, end: CGPoint, screen: CGRect, scale: CGFloat) -> CaptureGeometry? {
    guard scale > 0 else { return nil }
    let drag = CGRect(
        x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
    let clamped = drag.intersection(screen)
    guard !clamped.isNull, clamped.width >= minimumFrameSide, clamped.height >= minimumFrameSide else { return nil }
    let pixels = CGRect(
        x: (clamped.minX - screen.minX) * scale, y: (screen.maxY - clamped.maxY) * scale,
        width: clamped.width * scale, height: clamped.height * scale
    ).integral
    return CaptureGeometry(
        sourceRect: CGRect(
            x: pixels.minX / scale, y: pixels.minY / scale, width: pixels.width / scale,
            height: pixels.height / scale),
        pixelSize: pixels.size)
}
