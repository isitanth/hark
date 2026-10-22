import AppKit
import SwiftUI

/// The one seam between the Ask panel's two looks: Liquid Glass on macOS 26 and later, the popover material below.
/// Every glass API the panel uses is reached through here or behind the same `#available` check.
enum AskGlass {
    /// The panel's outer radius on macOS 26; inner shapes are concentric to it.
    static let radius: CGFloat = 24
    /// Below macOS 26, today's radius.
    static let legacyRadius: CGFloat = 12
    /// The smallest radius an inner surface keeps (the answer) and a chip keeps.
    static let innerRadius: CGFloat = 8
    static let chipRadius: CGFloat = 6

    static var isAvailable: Bool {
        if #available(macOS 26, *) { true } else { false }
    }
}

extension View {
    /// The panel's shell: regular glass in a 24 pt rectangle with no stroke on macOS 26; below, the popover
    /// material clipped at 12 pt with the 0.5 pt separator stroke. Both keep a background a press drags.
    func askPanelChrome() -> some View {
        modifier(AskPanelChrome())
    }

    /// `style` behind the view in a shape concentric to the panel, never under `minimum`; a plain rounded rectangle
    /// of `minimum` below macOS 26.
    @ViewBuilder
    func askFill(_ style: some ShapeStyle, minimum: CGFloat) -> some View {
        if #available(macOS 26, *) {
            background(style, in: ConcentricRectangle(corners: .concentric(minimum: .fixed(minimum))))
        } else {
            background(style, in: RoundedRectangle(cornerRadius: minimum, style: .continuous))
        }
    }

    /// Clips to the same concentric shape as `askFill`.
    @ViewBuilder
    func askClip(minimum: CGFloat) -> some View {
        if #available(macOS 26, *) {
            clipShape(ConcentricRectangle(corners: .concentric(minimum: .fixed(minimum))))
        } else {
            clipShape(RoundedRectangle(cornerRadius: minimum, style: .continuous))
        }
    }

    /// A chip's surface: glass in a concentric shape on macOS 26, interactive when the chip holds a control; a
    /// `.quaternary` fill below.
    @ViewBuilder
    func askChipSurface(interactive: Bool) -> some View {
        if #available(macOS 26, *) {
            glassEffect(
                .regular.interactive(interactive),
                in: ConcentricRectangle(corners: .concentric(minimum: .fixed(AskGlass.chipRadius))))
        } else {
            background(.quaternary, in: RoundedRectangle(cornerRadius: AskGlass.chipRadius, style: .continuous))
        }
    }

    /// A footer button: `.glassProminent` for the primary action and `.glass` for the others on macOS 26; below,
    /// `.borderedProminent` for the primary and the system's default for the others, as today.
    @ViewBuilder
    func askButtonStyle(prominent: Bool) -> some View {
        if #available(macOS 26, *) {
            if prominent {
                buttonStyle(.glassProminent)
            } else {
                buttonStyle(.glass)
            }
        } else if prominent {
            buttonStyle(.borderedProminent)
        } else {
            self
        }
    }

    /// The answer's scroll view: a hard edge where it scrolls under the footer, on macOS 26.
    @ViewBuilder
    func askScrollEdge() -> some View {
        if #available(macOS 26, *) {
            scrollEdgeEffectStyle(.hard, for: .bottom)
        } else {
            self
        }
    }
}

private struct AskPanelChrome: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content
                .background(AskDragArea())
                .glassEffect(.regular, in: .rect(cornerRadius: AskGlass.radius))
                .containerShape(.rect(cornerRadius: AskGlass.radius))
        } else {
            content
                .background(AskPanelBackground())
                .clipShape(RoundedRectangle(cornerRadius: AskGlass.legacyRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: AskGlass.legacyRadius, style: .continuous)
                        .strokeBorder(.separator, lineWidth: 0.5)
                )
        }
    }
}

/// Below macOS 26, the panel's background: the popover material, blurred behind the window, since Hark is often
/// not the active app. A press on it drags the panel, which has no title bar to hold.
struct AskPanelBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = DraggableEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

private final class DraggableEffectView: NSVisualEffectView {
    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

/// On macOS 26, a clear view under the glass that drags the panel, as the material view does below.
private struct AskDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DraggableClearView() }

    func updateNSView(_ view: NSView, context: Context) {}
}

private final class DraggableClearView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}
