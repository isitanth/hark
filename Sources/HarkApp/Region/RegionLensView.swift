import AppKit
import HarkCore
import SwiftUI

/// What the lens shows: the cells an exact answer read, over the frame's own pixels as captured (M13). The image lives
/// here only while the lens shows, and is never written anywhere.
struct RegionLens: Equatable {
    let highlights: CellHighlights
    let image: CGImage
    /// The tints fade in top to bottom; a "Show Cells" after a hide shows them at once.
    let animated: Bool

    static func == (lhs: RegionLens, rhs: RegionLens) -> Bool {
        lhs.highlights == rhs.highlights && lhs.image === rhs.image && lhs.animated == rhs.animated
    }
}

/// The lens, in the overlay's points from its top-left corner: the captured image at the frame's size, the tints,
/// then the framing border. No dim anywhere, and nothing for VoiceOver: the panel says it all.
struct RegionLensView: View {
    let lens: RegionLens
    let scale: CGFloat
    @State private var shown = false
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityDifferentiateWithoutColor) private var withoutColor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Each cell starts this long after the one above it, the whole fade within `maxStagger`.
    static let stagger = 0.02
    static let maxStagger = 0.3
    static let fadeDuration = 0.2
    static let cornerRadius: CGFloat = 3

    private var frame: CGRect { lens.highlights.frame }
    private var increased: Bool { contrast == .increased }

    var body: some View {
        ZStack(alignment: .topLeading) {
            image
            ForEach(Array(order.enumerated()), id: \.element.id) { index, cell in
                tint(cell)
                    .opacity(shown || !lens.animated ? 1 : 0)
                    .animation(
                        lens.animated && !reduceMotion
                            ? .easeOut(duration: Self.fadeDuration).delay(
                                min(Double(index) * Self.stagger, Self.maxStagger)) : nil,
                        value: shown)
            }
            border
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { shown = true }
    }

    /// Top to bottom, for the fade.
    private var order: [HighlightedCell] {
        lens.highlights.cells.sorted { ($0.box.minY, $0.box.minX) < ($1.box.minY, $1.box.minX) }
    }

    /// 1:1 in backing pixels when the capture's scale is the display's: pixel-identical while nothing moved.
    private var image: some View {
        let pixelsPerPoint = frame.width > 0 ? CGFloat(lens.image.width) / frame.width : scale
        return Image(decorative: lens.image, scale: pixelsPerPoint)
            .interpolation(abs(pixelsPerPoint - scale) < 0.01 ? .none : .high)
            .resizable()
            .frame(width: frame.width, height: frame.height)
            .offset(x: frame.minX, y: frame.minY)
    }

    private var border: some View {
        ZStack(alignment: .topLeading) {
            Path { $0.addRect(frame.insetBy(dx: -0.5, dy: -0.5)) }
                .stroke(Color.black.opacity(0.6), lineWidth: 1)
            Path { $0.addRect(frame.insetBy(dx: 0.75, dy: 0.75)) }
                .stroke(Color.white, lineWidth: 1.5)
        }
    }

    @ViewBuilder
    private func tint(_ cell: HighlightedCell) -> some View {
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius)
        let style = Self.style(cell.role, uncertain: cell.uncertain, increased: increased)
        ZStack(alignment: .topTrailing) {
            shape.fill(style.fill)
            if withoutColor, cell.role == .subtracted {
                Hatch()
                    .stroke(Color(nsColor: .systemOrange).opacity(0.6), lineWidth: 1)
                    .clipShape(shape)
                Text(verbatim: "−")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 3)
                    .background(Color(nsColor: .systemOrange), in: Capsule())
                    .offset(x: 4, y: -4)
            }
            shape.stroke(style.stroke, style: style.line(withoutColor: withoutColor, role: cell.role))
        }
        .frame(width: cell.box.width, height: cell.box.height)
        .offset(x: cell.box.minX, y: cell.box.minY)
    }

    struct Style {
        let fill: Color
        let stroke: Color
        let width: CGFloat
        let dashed: Bool
        let dotted: Bool

        func line(withoutColor: Bool, role: CellRole?) -> StrokeStyle {
            if dotted || (withoutColor && role == .rate) {
                return StrokeStyle(lineWidth: width, lineCap: .round, dash: [0.5, 3])
            }
            return StrokeStyle(lineWidth: width, dash: dashed ? [4, 3] : [])
        }
    }

    /// Fixed system colours, never the accent: blue adds, orange subtracts, a neutral outline for the rest, red only
    /// for the failure's cell.
    static func style(_ role: CellRole?, uncertain: Bool, increased: Bool) -> Style {
        let fillOpacity = increased ? 0.35 : 0.25
        switch role {
        case .added?, .subtracted?:
            let color = Color(nsColor: role == .added ? .systemBlue : .systemOrange)
            return Style(
                fill: color.opacity(fillOpacity), stroke: color, width: increased ? 2 : 1.5, dashed: uncertain,
                dotted: false)
        case .counted?, .compared?, .rate?:
            return Style(
                fill: .clear, stroke: Color(nsColor: .secondaryLabelColor), width: increased ? 2 : 1,
                dashed: uncertain, dotted: role == .rate && !uncertain)
        case nil:
            return Style(fill: .clear, stroke: Color(nsColor: .systemRed), width: 2, dashed: true, dotted: false)
        }
    }
}

/// Diagonal lines, for Differentiate Without Color.
nonisolated private struct Hatch: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        var x = -rect.height
        while x < rect.width {
            path.move(to: CGPoint(x: rect.minX + x, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX + x + rect.height, y: rect.minY))
            x += 6
        }
        return path
    }
}

/// `-HarkDebugPreview overlay-lens`: c01's invoices drawn in code, with its tints. Sample pixels, no capture.
enum RegionLensSample {
    static let rows = 12
    static let rowHeight: CGFloat = 40
    static let header: CGFloat = 60
    /// c01: the credit notes subtract, January's refunded invoice is left out, one cell may be misread.
    static let subtracted: Set<Int> = [2, 5, 9]
    static let excluded = 12
    static let uncertain = 5

    static func highlights(frame: CGRect, displayID: UInt32) -> CellHighlights {
        let cells = (1...rows).filter { $0 != excluded }.map { row in
            let box = CGRect(
                x: frame.minX + frame.width * 0.45, y: frame.minY + header + CGFloat(row - 1) * rowHeight + 8,
                width: frame.width * 0.2, height: rowHeight - 16
            ).insetBy(dx: -AskPresentation.cellPadding, dy: -AskPresentation.cellPadding)
            return HighlightedCell(
                id: CellID(row * 4 + 3), box: box, role: subtracted.contains(row) ? .subtracted : .added,
                uncertain: row == uncertain)
        }
        return CellHighlights(frameID: UtteranceID(1), displayID: displayID, frame: frame, cells: cells)
    }

    /// White rows, grey rules and dark bars where the text would be, at the display's scale.
    static func image(size: CGSize, scale: CGFloat) -> CGImage? {
        let width = Int(size.width * scale)
        let height = Int(size.height * scale)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.scaleBy(x: scale, y: scale)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        for row in 0...rows {
            let y = size.height - header - CGFloat(row) * rowHeight
            context.setFillColor(CGColor(gray: 0.85, alpha: 1))
            context.fill(CGRect(x: 16, y: y, width: size.width - 32, height: 1))
            guard row < rows else { continue }
            context.setFillColor(CGColor(gray: 0.3, alpha: 1))
            context.fill(CGRect(x: 24, y: y - 26, width: size.width * 0.18, height: 10))
            context.fill(CGRect(x: size.width * 0.25, y: y - 26, width: size.width * 0.15, height: 10))
            context.fill(CGRect(x: size.width * 0.47, y: y - 26, width: size.width * 0.12, height: 10))
            context.fill(CGRect(x: size.width * 0.72, y: y - 26, width: size.width * 0.1, height: 10))
        }
        return context.makeImage()
    }
}
