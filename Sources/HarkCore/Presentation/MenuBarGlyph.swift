import Foundation

/// Hark's drill on an 18-point design grid, y down: the paths the renderer fills and strokes, at one weight everywhere,
/// SF Symbols regular at that size. Drawn from the app icon, a cordless drill: a body with a rounded back, a pistol
/// grip, a battery foot, a solid chuck and a short bit, 14 by 12.3 points on the grid. `MenuBarGlyph` places the grid in
/// the menu bar 15 % larger.
public enum DrillShape {
    public static let lineWidth = 1.3

    public enum Segment: Sendable, Equatable {
        case move(Double, Double)
        case line(Double, Double)
        /// A circular arc from `from` to `to` degrees, the angle growing clockwise on screen.
        case arc(centerX: Double, centerY: Double, radius: Double, from: Double, to: Double)
        case quad(Double, Double, controlX: Double, controlY: Double)
        case close
    }

    public enum Paint: Sendable, Equatable {
        case stroke
        case fill
        /// Filled, with the stroke around it, so a filled part is as large as its outline.
        case fillAndStroke
    }

    public struct Part: Sendable, Equatable {
        public let segments: [Segment]
        public let paint: Paint
    }

    /// The body and the grip, open at the grip's foot, where the battery's top edge closes them.
    static func body(filled: Bool) -> Part {
        var segments: [Segment] = [
            .move(5.5, 11.5), .line(6.5, 7.5), .line(5.5, 7.5),
            .arc(centerX: 5.5, centerY: 5.5, radius: 2, from: 90, to: 270),
            .line(12.5, 3.5), .line(12.5, 7.5), .line(9.5, 7.5), .line(8.5, 11.5),
        ]
        if filled { segments.append(.close) }
        return Part(segments: segments, paint: filled ? .fillAndStroke : .stroke)
    }

    static func battery(filled: Bool) -> Part {
        Part(
            segments: roundedRect(minX: 3.5, minY: 11.5, maxX: 10.5, maxY: 14.5, radius: 1),
            paint: filled ? .fillAndStroke : .stroke)
    }

    static let chuck = Part(
        segments: [
            .move(12.5, 4), .line(13.8, 4), .line(14.4, 4.6), .line(14.4, 6.4), .line(13.8, 7), .line(12.5, 7), .close,
        ],
        paint: .fill)

    static let bit = Part(segments: [.move(14.4, 5.5), .line(16.2, 5.5)], paint: .stroke)

    /// Beside the battery, under the chuck.
    static func badge(_ badge: MenuBarGlyph.Badge) -> [Part] {
        switch badge {
        case .none:
            []
        case .dot:
            [Part(segments: circle(14.6, 13.3, radius: 1.75), paint: .fill)]
        case .sparkle:
            // The four-pointed star Apple uses for its AI features.
            [
                Part(
                    segments: [
                        .move(14.8, 10), .quad(16.8, 12.6, controlX: 15.1, controlY: 12.3),
                        .quad(14.8, 15.2, controlX: 15.1, controlY: 12.9),
                        .quad(12.8, 12.6, controlX: 14.5, controlY: 12.9),
                        .quad(14.8, 10, controlX: 14.5, controlY: 12.3), .close,
                    ], paint: .fill)
            ]
        case .exclamation:
            [
                Part(segments: [.move(15, 9.6), .line(15, 11.8)], paint: .stroke),
                Part(segments: circle(15, 14.5, radius: 0.85), paint: .fill),
            ]
        case .cross:
            [
                Part(
                    segments: [.move(13.1, 11.8), .line(16.2, 14.9), .move(16.2, 11.8), .line(13.1, 14.9)],
                    paint: .stroke)
            ]
        }
    }

    /// Above and below the bit: a dot where a mark appears or fades, a short stroke where it passes.
    static func marks(_ marks: MenuBarGlyph.Marks) -> [Part] {
        let above = Part(segments: [.move(15.3, 2.9), .line(16.1, 2.1)], paint: .stroke)
        let below = Part(segments: [.move(15.3, 8.1), .line(16.1, 8.9)], paint: .stroke)
        return switch marks {
        case .none: []
        case .dotAbove: [Part(segments: circle(15.7, 2.5, radius: 0.65), paint: .fill)]
        case .strokeAbove: [above]
        case .strokes: [above, below]
        case .strokeBelow: [below]
        case .dotBelow: [Part(segments: circle(15.7, 8.5, radius: 0.65), paint: .fill)]
        }
    }

    static func circle(_ x: Double, _ y: Double, radius: Double) -> [Segment] {
        [.move(x + radius, y), .arc(centerX: x, centerY: y, radius: radius, from: 0, to: 360), .close]
    }

    static func roundedRect(minX: Double, minY: Double, maxX: Double, maxY: Double, radius r: Double) -> [Segment] {
        [
            .move(minX + r, minY), .line(maxX - r, minY), .quad(maxX, minY + r, controlX: maxX, controlY: minY),
            .line(maxX, maxY - r), .quad(maxX - r, maxY, controlX: maxX, controlY: maxY),
            .line(minX + r, maxY), .quad(minX, maxY - r, controlX: minX, controlY: maxY),
            .line(minX, minY + r), .quad(minX + r, minY, controlX: minX, controlY: minY), .close,
        ]
    }
}

/// What the menu bar icon draws: the drill in the form of a state, moved by a frame of an animation. A plain value, so
/// the states and the animations are tested here; HarkApp only paints the parts.
///
/// The forms follow SF Symbols' outline and fill: the outline at rest, everything filled while the microphone is open,
/// the battery alone filled while what was said is worked on, and a badge beside the battery for what else there is to
/// say. States differ by shape, never by colour.
public struct MenuBarGlyph: Sendable, Equatable {
    public enum Fill: Sendable, Equatable {
        case outline
        case filled
        case battery
    }

    public enum Badge: Sendable, Equatable {
        case none
        /// The capture is latched: hands-free, nothing held.
        case dot
        /// The model is asked.
        case sparkle
        case exclamation
        /// What was said came to nothing.
        case cross
    }

    /// The marks that make the bit turn.
    public enum Marks: Sendable, Equatable {
        case none
        case dotAbove
        case strokeAbove
        case strokes
        case strokeBelow
        case dotBelow
    }

    /// The foot of the grip, where the rotation of a frame pivots, on the design grid.
    public static let pivotX = 7.0
    public static let pivotY = 11.5

    /// The status item's canvas, in points: 2 points wider than the 18 of the first drill, so the larger drill keeps
    /// room for the shake and the trigger's recoil, and as tall, for the marks of the turning bit. The menu bar's height
    /// does not change.
    public static let canvasWidth = 20.0
    public static let canvasHeight = 20.0
    /// The design grid is drawn this much larger: at 1 the drill read smaller and lighter than its neighbours in the
    /// menu bar, 27 by 24 pixels against 32 by 24 for Wi-Fi (the user's screenshot of 2026-09-29). The stroke grows with
    /// it, 1.3 to about 1.5.
    public static let scale = 1.15
    /// The centre of the drill's ink on the design grid, which lands on the centre of the canvas.
    public static let inkCentreX = 9.85
    public static let inkCentreY = 9.0

    public var fill: Fill
    public var badge: Badge
    public var marks: Marks = .none
    /// Degrees, clockwise on screen, about the pivot.
    public var rotation: Double = 0
    public var dx: Double = 0
    public var dy: Double = 0
    /// Whether the badge moves with the drill, or stays where it is while the drill does.
    public var badgeMoves = false
    public var opacity: Double = 1

    public init(fill: Fill, badge: Badge = .none, opacity: Double = 1) {
        self.fill = fill
        self.badge = badge
        self.opacity = opacity
    }

    public init(state: MenuBarIconState) {
        switch state {
        case .idle: self.init(fill: .outline)
        case .recording: self.init(fill: .filled)
        case .handsFree: self.init(fill: .filled, badge: .dot)
        // Transcribing keeps today's 60 %: Hark works, the microphone is closed.
        case .transcribing: self.init(fill: .battery, opacity: 0.6)
        case .asking: self.init(fill: .outline, badge: .sparkle)
        case .armed: self.init(fill: .outline, badge: .dot)
        case .error: self.init(fill: .outline, badge: .exclamation)
        case .dismissed: self.init(fill: .outline, badge: .cross)
        }
    }

    /// The glyph as a frame moves it; itself without one, or with a frame at rest.
    public func applying(_ frame: MenuBarFrame?) -> MenuBarGlyph {
        guard let frame, !frame.isRest else { return self }
        var moved = self
        moved.rotation = frame.rotation
        moved.dx = frame.dx
        moved.dy = frame.dy
        moved.marks = frame.marks
        moved.badgeMoves = frame.movesBadge
        return moved
    }

    /// The drill and its marks, drawn under the frame's move, and the badge too when it moves with them.
    public var movingParts: [DrillShape.Part] {
        [
            DrillShape.body(filled: fill == .filled), DrillShape.battery(filled: fill != .outline), DrillShape.chuck,
            DrillShape.bit,
        ] + DrillShape.marks(marks) + (badgeMoves ? DrillShape.badge(badge) : [])
    }

    /// The badge when it stays put.
    public var fixedParts: [DrillShape.Part] {
        badgeMoves ? [] : DrillShape.badge(badge)
    }

    /// Where a point of a moving part lands: turned about the pivot, then shifted.
    public func moved(_ x: Double, _ y: Double) -> (x: Double, y: Double) {
        let angle = rotation * .pi / 180
        let (rx, ry) = (x - Self.pivotX, y - Self.pivotY)
        return (
            Self.pivotX + rx * cos(angle) - ry * sin(angle) + dx, Self.pivotY + rx * sin(angle) + ry * cos(angle) + dy
        )
    }

    /// Where a point of the design grid lands on the canvas: scaled about the drill's ink centre, which lands on the
    /// canvas's centre.
    public static func placed(_ x: Double, _ y: Double) -> (x: Double, y: Double) {
        (canvasWidth / 2 + (x - inkCentreX) * scale, canvasHeight / 2 + (y - inkCentreY) * scale)
    }

    /// How far the ink reaches on the canvas, stroke included, once moved and placed: what has to stay inside it.
    /// Control points count as ink, so the box is never smaller than the drawing.
    public var inkBounds: (minX: Double, minY: Double, maxX: Double, maxY: Double) {
        var box = (minX: Double.infinity, minY: Double.infinity, maxX: -Double.infinity, maxY: -Double.infinity)
        func add(_ parts: [DrillShape.Part], moving: Bool) {
            for part in parts {
                let pad = part.paint == .fill ? 0 : DrillShape.lineWidth * Self.scale / 2
                for (x, y) in Self.points(part.segments) {
                    let onGrid = moving ? moved(x, y) : (x: x, y: y)
                    let point = Self.placed(onGrid.x, onGrid.y)
                    box.minX = min(box.minX, point.x - pad)
                    box.minY = min(box.minY, point.y - pad)
                    box.maxX = max(box.maxX, point.x + pad)
                    box.maxY = max(box.maxY, point.y + pad)
                }
            }
        }
        add(movingParts, moving: true)
        add(fixedParts, moving: false)
        return box
    }

    /// Every point a part passes through or bends towards, arcs sampled every 5 degrees.
    static func points(_ segments: [DrillShape.Segment]) -> [(Double, Double)] {
        segments.flatMap { segment -> [(Double, Double)] in
            switch segment {
            case .move(let x, let y), .line(let x, let y): [(x, y)]
            case .quad(let x, let y, let cx, let cy): [(x, y), (cx, cy)]
            case .close: []
            case .arc(let cx, let cy, let r, let from, let to):
                stride(from: from, through: to, by: 5).map { cx + r * cos($0 * .pi / 180) }
                    .enumerated().map { index, x in (x, cy + r * sin((from + Double(index) * 5) * .pi / 180)) }
            }
        }
    }
}
