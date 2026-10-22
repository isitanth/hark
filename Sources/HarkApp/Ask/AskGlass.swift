import AppKit
import SwiftUI

/// The panel's background: the popover material, blurred behind the window, since Hark is often not the active app.
/// A press on it drags the panel, which has no title bar to hold.
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
