import AppKit
import HarkCore
import QuartzCore

/// The layer's drawing (M14): the cells' tints, the zone's border and a failure's red cell, as Core Animation shapes in
/// one layer-backed view, built once per show; following the window moves the panel and redraws nothing. No copy of the
/// screen, no image type at all (a check.sh gate). Fixed system colours, never the accent: blue adds, orange subtracts,
/// a blue outline with no fill for the rest (b4 §6.2), red only for the failure's cell.
final class RegionLayerView: NSView {
    /// Each cell starts this long after the one above it, the whole fade within `maxStagger`.
    static let stagger = 0.02
    static let maxStagger = 0.3
    static let fadeDuration = 0.2
    static let cornerRadius: CGFloat = 3

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Replaces the drawing: `cells` in the zone's points from its top-left corner, drawn `margin` in from the view's
    /// edge, the border round the zone.
    func draw(cells: [HighlightedCell], zoneSize: CGSize, margin: CGFloat, animated: Bool) {
        guard let root = layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for sublayer in root.sublayers ?? [] { sublayer.removeFromSuperlayer() }
        let workspace = NSWorkspace.shared
        let increased = workspace.accessibilityDisplayShouldIncreaseContrast
        let withoutColor = workspace.accessibilityDisplayShouldDifferentiateWithoutColor
        let fade = animated && !workspace.accessibilityDisplayShouldReduceMotion
        let ordered = cells.sorted { ($0.box.minY, $0.box.minX) < ($1.box.minY, $1.box.minX) }
        let now = CACurrentMediaTime()
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        for (index, cell) in ordered.enumerated() {
            let box = cell.box.offsetBy(dx: margin, dy: margin)
            let tint = Self.tint(cell, in: box, increased: increased, withoutColor: withoutColor, scale: scale)
            root.addSublayer(tint)
            guard fade else { continue }
            let animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = 0
            animation.toValue = 1
            animation.duration = Self.fadeDuration
            animation.beginTime = now + min(Double(index) * Self.stagger, Self.maxStagger)
            animation.fillMode = .backwards
            animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            tint.add(animation, forKey: "fade")
        }
        let zone = CGRect(origin: CGPoint(x: margin, y: margin), size: zoneSize)
        root.addSublayer(Self.stroke(zone.insetBy(dx: -0.5, dy: -0.5), color: .black.withAlphaComponent(0.6), width: 1))
        root.addSublayer(Self.stroke(zone.insetBy(dx: 0.75, dy: 0.75), color: .white, width: 1.5))
        CATransaction.commit()
    }

    /// The minus badges' text follows the display the panel is on.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard let scale = window?.backingScaleFactor else { return }
        for group in layer?.sublayers ?? [] {
            for case let text as CATextLayer in group.sublayers ?? [] {
                text.contentsScale = scale
            }
        }
    }

    private static func stroke(_ rect: CGRect, color: NSColor, width: CGFloat) -> CAShapeLayer {
        let shape = CAShapeLayer()
        shape.path = CGPath(rect: rect, transform: nil)
        shape.fillColor = nil
        shape.strokeColor = color.cgColor
        shape.lineWidth = width
        return shape
    }

    /// One cell: its fill, its outline, and with Differentiate Without Color a hatch and a minus badge on a subtracted
    /// one, a dotted outline on a rate.
    private static func tint(
        _ cell: HighlightedCell, in box: CGRect, increased: Bool, withoutColor: Bool, scale: CGFloat
    ) -> CALayer {
        let group = CALayer()
        group.frame = box
        let bounds = CGRect(origin: .zero, size: box.size)
        let path = CGPath(
            roundedRect: bounds, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        let style = Style(cell.role, uncertain: cell.uncertain, increased: increased)
        let fill = CAShapeLayer()
        fill.path = path
        fill.fillColor = style.fill?.cgColor
        group.addSublayer(fill)
        if withoutColor, cell.role == .subtracted {
            group.addSublayer(hatch(bounds, clip: path))
            group.addSublayer(badge(at: CGPoint(x: bounds.maxX + 4, y: -4), scale: scale))
        }
        let outline = CAShapeLayer()
        outline.path = path
        outline.fillColor = nil
        outline.strokeColor = style.stroke.cgColor
        outline.lineWidth = style.width
        if style.dotted || (withoutColor && cell.role == .rate && !cell.uncertain) {
            outline.lineCap = .round
            outline.lineDashPattern = [0.5, 3]
        } else if style.dashed {
            outline.lineDashPattern = [4, 3]
        }
        group.addSublayer(outline)
        return group
    }

    private static func hatch(_ bounds: CGRect, clip: CGPath) -> CALayer {
        let lines = CGMutablePath()
        var x = -bounds.height
        while x < bounds.width {
            lines.move(to: CGPoint(x: x, y: bounds.maxY))
            lines.addLine(to: CGPoint(x: x + bounds.height, y: bounds.minY))
            x += 6
        }
        let shape = CAShapeLayer()
        shape.path = lines
        shape.strokeColor = NSColor.systemOrange.withAlphaComponent(0.6).cgColor
        shape.lineWidth = 1
        let mask = CAShapeLayer()
        mask.path = clip
        shape.mask = mask
        shape.frame = bounds
        return shape
    }

    /// The "−" badge at a subtracted cell's top-right corner, its centre at `corner` less its half width.
    private static func badge(at corner: CGPoint, scale: CGFloat) -> CALayer {
        let size = CGSize(width: 12, height: 12)
        let text = CATextLayer()
        text.string = "−"
        text.font = NSFont.systemFont(ofSize: 9, weight: .bold)
        text.fontSize = 9
        text.alignmentMode = .center
        text.foregroundColor = NSColor.white.cgColor
        text.backgroundColor = NSColor.systemOrange.cgColor
        text.cornerRadius = size.height / 2
        text.contentsScale = scale
        text.frame = CGRect(x: corner.x - size.width, y: corner.y, width: size.width, height: size.height)
        return text
    }

    struct Style {
        let fill: NSColor?
        let stroke: NSColor
        let width: CGFloat
        let dashed: Bool
        let dotted: Bool

        init(_ role: CellRole?, uncertain: Bool, increased: Bool) {
            let fillOpacity: CGFloat = increased ? 0.35 : 0.25
            switch role {
            case .added?, .subtracted?:
                let color: NSColor = role == .added ? .systemBlue : .systemOrange
                fill = color.withAlphaComponent(fillOpacity)
                stroke = color
                width = increased ? 2 : 1.5
                dashed = uncertain
                dotted = false
            case .counted?, .compared?, .rate?:
                // A fixed colour: a dynamic grey resolves against Hark's appearance, not the page under the layer,
                // and faded to nothing over a white page in dark mode (M14.7).
                fill = nil
                stroke = .systemBlue
                width = increased ? 2 : 1
                dashed = uncertain
                dotted = role == .rate && !uncertain
            case nil:
                fill = nil
                stroke = .systemRed
                width = 2
                dashed = true
                dotted = false
            }
        }
    }
}
