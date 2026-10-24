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
    /// The panel's shell: regular glass in a 24 pt rectangle, clipped to it, with no stroke on macOS 26; below, the
    /// popover material clipped at 12 pt with the 0.5 pt separator stroke. Both keep a background a press drags.
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

    /// A footer button: `.borderedProminent` for the primary action and `.glass` for the others on macOS 26; below,
    /// `.borderedProminent` for the primary and the system's default for the others, as today.
    @ViewBuilder
    func askButtonStyle(prominent: Bool) -> some View {
        if #available(macOS 26, *) {
            if prominent {
                // Not `.glassProminent`: its blue follows the window's key state and nothing public holds it, so the
                // primary turned grey whenever the panel lost key (sdk 27, measured 2026-10-24: 5,125,254 key,
                // 66,66,66 not key under `appearsActive`). `.borderedProminent` under `askAppearsActive()` stays
                // 0,111,255 either way.
                buttonStyle(.borderedProminent)
            } else {
                buttonStyle(.glass)
            }
        } else if prominent {
            buttonStyle(.borderedProminent)
        } else {
            self
        }
    }

    /// The footer, and the framing row's button, drawn as in a key window while the panel is not key, on macOS 26.
    /// The panel is non-activating and the user clicks back into the source app while the answer shows, so it is
    /// mostly not key, and the glass buttons' labels then fell to 92,92,92 as if disabled (sdk 27, measured
    /// 2026-10-24); under `appearsActive` they stay white. The glass under them follows the window's key state still,
    /// as the panel's own glass does.
    @ViewBuilder
    func askAppearsActive() -> some View {
        if #available(macOS 26, *) {
            environment(\.appearsActive, true)
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

extension View {
    /// A chip's or a footer group's identity in the panel's namespace, so a change of state morphs it on macOS 26.
    /// Under Reduce Motion nothing morphs.
    func askChipID(_ id: String, in namespace: Namespace.ID) -> some View {
        modifier(AskGlassID(id: id, namespace: namespace))
    }

    /// A removed chip dissolves into the glass rather than morphing into its neighbour; under Reduce Motion it goes.
    func askMaterialize() -> some View {
        modifier(AskMaterialize())
    }
}

private struct AskGlassID: ViewModifier {
    let id: String
    let namespace: Namespace.ID
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if #available(macOS 26, *), !reduceMotion {
            content.glassEffectID(id, in: namespace)
        } else {
            content
        }
    }
}

private struct AskMaterialize: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.glassEffectTransition(reduceMotion ? .identity : .materialize)
        } else {
            content
        }
    }
}

private struct AskPanelChrome: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            // The glass casts a faint shadow of its own past its shape, which the borderless panel cuts at its
            // rectangle: the corners then hold a little alpha and the window's shadow traces the rectangle. Clipped to
            // the shape, the corners are clear and the window's shadow follows the rounded edge.
            content
                .background(AskDragArea())
                .glassEffect(.regular, in: .rect(cornerRadius: AskGlass.radius))
                .containerShape(.rect(cornerRadius: AskGlass.radius))
                .clipShape(.rect(cornerRadius: AskGlass.radius))
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
