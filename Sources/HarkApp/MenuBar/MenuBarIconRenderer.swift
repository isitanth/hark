import AppKit
import HarkCore

/// Paints Hark's drill (`MenuBarGlyph`) on the same 20×20 pt template canvas for every state and every frame, so the
/// status item never changes width. Template only: states differ by shape and opacity, never by colour.
enum MenuBarIconRenderer {
    static let size = NSSize(width: MenuBarGlyph.canvasWidth, height: MenuBarGlyph.canvasHeight)

    static func image(for state: MenuBarIconState) -> NSImage {
        image(for: MenuBarGlyph(state: state))
    }

    static func image(for glyph: MenuBarGlyph) -> NSImage {
        // Flipped, so the glyph's coordinates run down the canvas as they were drawn.
        let image = NSImage(size: size, flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.setAlpha(glyph.opacity)
            // One layer, so where a fill and a stroke overlap the reduced opacity is not paid twice.
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            context.setLineWidth(DrillShape.lineWidth)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.setFillColor(NSColor.black.cgColor)
            context.setStrokeColor(NSColor.black.cgColor)
            // The design grid, placed as `MenuBarGlyph.placed` says; the stroke grows with it.
            context.translateBy(x: MenuBarGlyph.canvasWidth / 2, y: MenuBarGlyph.canvasHeight / 2)
            context.scaleBy(x: MenuBarGlyph.scale, y: MenuBarGlyph.scale)
            context.translateBy(x: -MenuBarGlyph.inkCentreX, y: -MenuBarGlyph.inkCentreY)
            context.saveGState()
            context.translateBy(x: glyph.dx, y: glyph.dy)
            context.translateBy(x: MenuBarGlyph.pivotX, y: MenuBarGlyph.pivotY)
            context.rotate(by: glyph.rotation * .pi / 180)
            context.translateBy(x: -MenuBarGlyph.pivotX, y: -MenuBarGlyph.pivotY)
            for part in glyph.movingParts { paint(part, in: context) }
            context.restoreGState()
            for part in glyph.fixedParts { paint(part, in: context) }
            context.endTransparencyLayer()
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func paint(_ part: DrillShape.Part, in context: CGContext) {
        let path = CGMutablePath()
        for segment in part.segments {
            switch segment {
            case .move(let x, let y):
                path.move(to: CGPoint(x: x, y: y))
            case .line(let x, let y):
                path.addLine(to: CGPoint(x: x, y: y))
            case .arc(let x, let y, let radius, let from, let to):
                // In this flipped space a growing angle turns clockwise on screen, as the glyph's arcs are drawn.
                path.addArc(
                    center: CGPoint(x: x, y: y), radius: radius, startAngle: from * .pi / 180, endAngle: to * .pi / 180,
                    clockwise: false)
            case .quad(let x, let y, let cx, let cy):
                path.addQuadCurve(to: CGPoint(x: x, y: y), control: CGPoint(x: cx, y: cy))
            case .close:
                path.closeSubpath()
            }
        }
        context.addPath(path)
        switch part.paint {
        case .stroke: context.strokePath()
        case .fill: context.fillPath()
        case .fillAndStroke: context.drawPath(using: .fillStroke)
        }
    }
}

extension MenuBarIconState {
    var label: LocalizedStringResource {
        switch self {
        case .idle: L("state.idle")
        case .recording: L("state.recording")
        case .handsFree: L("state.handsFree")
        case .transcribing: L("state.transcribing")
        case .asking: L("state.asking")
        case .armed: L("state.armed")
        case .error: L("state.error")
        case .dismissed: L("state.dismissed")
        }
    }
}
