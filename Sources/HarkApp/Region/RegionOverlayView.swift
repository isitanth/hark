import SwiftUI

/// What one display's overlay draws, in the overlay's points with the origin at its top left.
struct RegionOverlayState: Equatable {
    /// The display's size in points.
    var screenSize: CGSize
    /// The rectangle being dragged, clamped to this display; nil before a drag.
    var rect: CGRect?
    /// The pointer's tip, while it is on this display.
    var pointer: CGPoint?
    /// Framing cannot work now: the dot shows a slash.
    var blocked: Bool
    /// The display's backing scale: the label shows the frame's size in pixels, as it goes to the model.
    var scale: CGFloat = 2
}

/// The framing overlay, drawn from a value and computing nothing: the screen dimmed outside the frame, the frame's
/// border, its size in pixels, and the dot that follows the pointer. Only the size label is glass.
struct RegionOverlayView: View {
    let state: RegionOverlayState

    /// 30% read too weak on a white page (A7).
    static let dimming = 0.4
    static let dotSize: CGFloat = 10
    /// The dot's centre, below and right of the pointer's tip.
    static let dotOffset = CGSize(width: 12, height: 12)

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let rect = state.rect {
                dimming(around: rect)
                border(rect)
                label(rect)
            }
            if let pointer = state.pointer {
                RegionDot(blocked: state.blocked)
                    .position(x: pointer.x + Self.dotOffset.width, y: pointer.y + Self.dotOffset.height)
            }
        }
        .frame(width: state.screenSize.width, height: state.screenSize.height, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Black at 40% over the whole display, with the frame cut out by the even-odd rule.
    private func dimming(around rect: CGRect) -> some View {
        Path { path in
            path.addRect(CGRect(origin: .zero, size: state.screenSize))
            path.addRect(rect)
        }
        .fill(Color.black.opacity(Self.dimming), style: FillStyle(eoFill: true))
    }

    /// A 1.5 pt white border inside the frame's edge and a 1 pt dark hairline outside it, so it reads on white and on
    /// black pages alike.
    private func border(_ rect: CGRect) -> some View {
        ZStack(alignment: .topLeading) {
            Path { $0.addRect(rect.insetBy(dx: -0.5, dy: -0.5)) }
                .stroke(Color.black.opacity(0.6), lineWidth: 1)
            Path { $0.addRect(rect.insetBy(dx: 0.75, dy: 0.75)) }
                .stroke(Color.white, lineWidth: 1.5)
        }
    }

    /// The frame's size in pixels, in a glass capsule inside its bottom-right corner.
    private func label(_ rect: CGRect) -> some View {
        let width = Int((rect.width * state.scale).rounded())
        let height = Int((rect.height * state.scale).rounded())
        return Color.clear
            .frame(width: rect.width, height: rect.height)
            .overlay(alignment: .bottomTrailing) {
                Text(verbatim: "\(width) × \(height)")
                    .font(.caption.monospacedDigit())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .regionCapsule()
                    .fixedSize()
                    .padding(6)
            }
            .offset(x: rect.minX, y: rect.minY)
    }
}

/// The cue that ⌃⌥ are held: the accent colour at 65% in a 1 pt white ring, with a slash when framing is blocked.
private struct RegionDot: View {
    let blocked: Bool

    var body: some View {
        let size = RegionOverlayView.dotSize
        ZStack {
            Circle()
                .fill(Color.accentColor.opacity(0.65))
            Circle()
                .strokeBorder(Color.white, lineWidth: 1)
            if blocked {
                Path { path in
                    path.move(to: CGPoint(x: size * 0.15, y: size * 0.85))
                    path.addLine(to: CGPoint(x: size * 0.85, y: size * 0.15))
                }
                .stroke(Color.white, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            }
        }
        .frame(width: size, height: size)
    }
}

extension View {
    /// The size label's capsule: glass on macOS 26, the HUD material below.
    @ViewBuilder
    fileprivate func regionCapsule() -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular, in: .capsule)
        } else {
            background(.regularMaterial, in: Capsule())
        }
    }
}
