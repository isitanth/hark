import AppKit
import HarkCore

/// The anchored layer's window (M14, plan §4.5): the zone's size plus its border, over the window the zone was framed on,
/// just below the Ask panel and the HUD. Borderless, non-activating, click-through, never key or main, no shadow, no
/// animation, hidden from VoiceOver. It draws vector shapes only, never a copy of the screen (a check.sh gate).
final class RegionLayerPanel: NSPanel {
    /// Room around the zone for the border, in points.
    static let margin: CGFloat = 3

    private let layerView = RegionLayerView(frame: .zero)

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true)
        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
        collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle, .transient]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        canHide = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        ignoresMouseEvents = true
        isMovable = false
        contentView = layerView
        setAccessibilityElement(false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// The cells to draw, in the zone's own points from its top-left corner, and the zone's size.
    func draw(cells: [HighlightedCell], zoneSize: CGSize, animated: Bool) {
        layerView.draw(cells: cells, zoneSize: zoneSize, margin: Self.margin, animated: animated)
    }

    /// The zone's place in Cocoa's screen coordinates: the panel takes it, grown by its margin. A move redraws nothing.
    func place(zone: CGRect) {
        let frame = zone.insetBy(dx: -Self.margin, dy: -Self.margin)
        if self.frame.size == frame.size {
            setFrameOrigin(frame.origin)
        } else {
            setFrame(frame, display: false)
        }
    }
}
