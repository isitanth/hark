import AppKit
import SwiftUI

/// The Ask panel, the second of the app's two NSPanels (CLAUDE.md). Non-activating, so opening it from the Ask key
/// (M9) leaves the source app in front, and allowed to become key, for typing, Return and Esc. A Services call has
/// activated Hark already; every close brings the caller back (`AskPanelModel`).
///
/// Its height follows the SwiftUI content, with the top edge held where it opened.
final class AskPanel: NSPanel {
    static let width: CGFloat = 520
    /// Below and to the right of the pointer, so the Services menu item it was chosen from stays readable.
    private static let offset = NSPoint(x: 8, y: -8)

    private let model: AskPanelModel
    /// The top edge while the panel is open: a resize grows or shrinks it downwards only.
    private var anchoredTop: CGFloat?

    init(model: AskPanelModel) {
        self.model = model
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 160),
            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .floating
        // On the Services path Hark is active and a click in the source app deactivates it: the popup stays.
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        animationBehavior = .utilityWindow
        isMovableByWindowBackground = true

        let host = NSHostingController(rootView: AskView(model: model))
        host.sizingOptions = [.preferredContentSize]
        contentViewController = host
        identifier = NSUserInterfaceItemIdentifier("ask-panel")
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Near the pointer, on its screen, and key without activating Hark.
    func open() {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        model.maxAnswerHeight = (visible.height * 0.6).rounded()
        let x = min(max(pointer.x + Self.offset.x, visible.minX + 8), visible.maxX - Self.width - 8)
        let top = min(pointer.y + Self.offset.y, visible.maxY - 8)
        anchoredTop = top
        setFrame(NSRect(x: x, y: top - frame.height, width: Self.width, height: frame.height), display: false)
        makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        anchoredTop = nil
        orderOut(nil)
    }

    /// Keeps the top edge, and the panel on its screen: a long answer grows downwards until the screen's bottom, and
    /// then the panel moves up.
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        var frame = frameRect
        if let top = anchoredTop {
            frame.origin.y = top - frame.height
            if let visible = screen?.visibleFrame, frame.minY < visible.minY + 8 {
                frame.origin.y = visible.minY + 8
            }
        }
        super.setFrame(frame, display: flag)
        invalidateShadow()
    }

    /// Esc is Cancel wherever the focus is: a text view would take it for completion.
    override func cancelOperation(_ sender: Any?) {
        model.cancel()
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 53,
            event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty
        {
            model.cancel()
            return
        }
        super.sendEvent(event)
    }
}

/// The panel's background: the popover material, blurred behind the window, since Hark is often not the active app.
struct AskPanelBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
